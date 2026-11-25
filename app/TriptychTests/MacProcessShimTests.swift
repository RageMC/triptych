// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Security
import CommonCrypto
import UIKit
@testable import Triptych
import MacAppsKit

final class MacProcessShimTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("macshim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - ASN.1 DER test builders (for X.509 cert & CMS SignedData)

    private func derLen(_ len: Int) -> Data {
        if len < 0x80 { return Data([UInt8(len)]) }
        var bytes: [UInt8] = []
        var v = len
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }

    private func derTLV(_ tag: UInt8, _ content: Data) -> Data {
        var d = Data([tag])
        d.append(derLen(content.count))
        d.append(content)
        return d
    }

    private func derSeq(_ items: [Data]) -> Data {
        derTLV(0x30, items.reduce(Data(), +))
    }

    private func derSet(_ items: [Data]) -> Data {
        derTLV(0x31, items.reduce(Data(), +))
    }

    private func derBitString(_ content: Data) -> Data {
        var body = Data([0x00])
        body.append(content)
        return derTLV(0x03, body)
    }

    private func derInt(_ bytes: [UInt8]) -> Data {
        var b = bytes
        if let first = b.first, first & 0x80 != 0 { b.insert(0x00, at: 0) }
        return derTLV(0x02, Data(b))
    }

    private func sha256RSAAlgId() -> Data {
        // 1.2.840.113549.1.1.11 + NULL
        let oid = derTLV(0x06, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]))
        return derSeq([oid, derTLV(0x05, Data())])
    }

    private func sha256AlgId() -> Data {
        // 2.16.840.1.101.3.4.2.1 + NULL
        let oid = derTLV(0x06, Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]))
        return derSeq([oid, derTLV(0x05, Data())])
    }

    private func spkiFromRSAPublicKey(_ pkcs1: Data) -> Data {
        let rsaOid = derTLV(0x06, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]))
        let alg = derSeq([rsaOid, derTLV(0x05, Data())])
        return derSeq([alg, derBitString(pkcs1)])
    }

    private func pemWrap(_ label: String, der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(b64)\n-----END \(label)-----\n"
    }

    private func generateRSAKeyPair() throws -> (priv: SecKey, pubPKCS1: Data) {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw err!.takeRetainedValue()
        }
        guard let pub = SecKeyCopyPublicKey(priv),
              let pubData = SecKeyCopyExternalRepresentation(pub, &err) as Data? else {
            throw err!.takeRetainedValue()
        }
        return (priv, pubData)
    }

    private func buildSelfSignedCert(priv: SecKey, pubPKCS1: Data, cn: String = "Triptych Test") throws -> Data {
        let ver = derTLV(0xA0, derInt([2])) // v3
        let serial = derInt([1])
        let sigAlg = sha256RSAAlgId()
        let cnOid = derTLV(0x06, Data([0x55, 0x04, 0x03]))
        let cnStr = derTLV(0x0C, Data(cn.utf8))
        let name = derSeq([derSet([derSeq([cnOid, cnStr])])])
        let notBefore = derTLV(0x17, Data("250101000000Z".utf8))
        let notAfter  = derTLV(0x17, Data("350101000000Z".utf8))
        let validity = derSeq([notBefore, notAfter])
        let spki = spkiFromRSAPublicKey(pubPKCS1)
        let bcOid = derTLV(0x06, Data([0x55, 0x1D, 0x13])) // basicConstraints
        let bcVal = derTLV(0x04, derSeq([derTLV(0x01, Data([0xFF]))])) // CA:TRUE
        let ext = derTLV(0xA3, derSeq([derSeq([bcOid, derTLV(0x01, Data([0xFF])), bcVal])]))
        let tbs = derSeq([ver, serial, sigAlg, name, validity, name, spki, ext])

        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &err) as Data? else {
            throw err!.takeRetainedValue()
        }
        return derSeq([tbs, sigAlg, derBitString(sig)])
    }

    private func buildCMSSignedData(priv: SecKey, certDER: Data, content: Data, detached: Bool) throws -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        content.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(content.count), &digest) }
        let digestData = Data(digest)

        // signedAttrs: contentType (data) + messageDigest
        let attrCT = derSeq([
            derTLV(0x06, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03])),
            derSet([derTLV(0x06, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]))]),
        ])
        let attrMD = derSeq([
            derTLV(0x06, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04])),
            derSet([derTLV(0x04, digestData)]),
        ])
        let attrsForSigning = derSet([attrCT, attrMD])
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA256, attrsForSigning as CFData, &err) as Data? else {
            throw err!.takeRetainedValue()
        }
        let implicitAttrs = derTLV(0xA0, attrCT + attrMD)

        // IssuerAndSerialNumber (match cert)
        let cnOid = derTLV(0x06, Data([0x55, 0x04, 0x03]))
        let cnStr = derTLV(0x0C, Data("Triptych Test".utf8))
        let issuer = derSeq([derSet([derSeq([cnOid, cnStr])])])
        let sid = derSeq([issuer, derInt([1])])

        let signerInfo = derSeq([derInt([1]), sid, sha256AlgId(), implicitAttrs, sha256RSAAlgId(), derTLV(0x04, sig)])
        let dataOid = derTLV(0x06, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]))
        let eci = detached ? derSeq([dataOid]) : derSeq([dataOid, derTLV(0xA0, derTLV(0x04, content))])
        let certs = derTLV(0xA0, certDER)
        let signedData = derSeq([derInt([1]), derSet([sha256AlgId()]), eci, certs, derSet([signerInfo])])
        let sdOid = derTLV(0x06, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]))
        return derSeq([sdOid, derTLV(0xA0, signedData)])
    }

    // MARK: - Spawn / Pipe helpers

    private func runPosixSpawn(path: String, args: [String], stdinData: Data? = nil, environment: [String] = []) throws -> (rc: Int32, stdout: String, stderr: String) {
        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&inPipe), 0)
        XCTAssertEqual(pipe(&outPipe), 0)
        XCTAssertEqual(pipe(&errPipe), 0)

        var fa: posix_spawn_file_actions_t?
        XCTAssertEqual(MacShim_posix_spawn_file_actions_init(&fa), 0)
        XCTAssertEqual(MacShim_posix_spawn_file_actions_adddup2(&fa, inPipe[0], STDIN_FILENO), 0)
        XCTAssertEqual(MacShim_posix_spawn_file_actions_adddup2(&fa, outPipe[1], STDOUT_FILENO), 0)
        XCTAssertEqual(MacShim_posix_spawn_file_actions_adddup2(&fa, errPipe[1], STDERR_FILENO), 0)

        let cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { if let p = $0 { free(p) } } }
        var env = environment.map { strdup($0) } + [nil]
        defer { env.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnErr = path.withCString { p in
            cArgs.withUnsafeBufferPointer { ab in
                env.withUnsafeMutableBufferPointer { eb in
                    MacShim_posix_spawn(&pid, p, &fa, nil, UnsafeMutablePointer(mutating: ab.baseAddress!), eb.baseAddress!)
                }
            }
        }
        MacShim_posix_spawn_file_actions_destroy(&fa)
        close(inPipe[0])
        close(outPipe[1])
        close(errPipe[1])
        XCTAssertEqual(spawnErr, 0)

        if let stdinData {
            stdinData.withUnsafeBytes { buf in
                if let base = buf.baseAddress { _ = write(inPipe[1], base, buf.count) }
            }
        }
        close(inPipe[1])

        let outStr = readAll(outPipe[0])
        let errStr = readAll(errPipe[0])
        close(outPipe[0])
        close(errPipe[0])

        var status: Int32 = 0
        XCTAssertEqual(MacShim_waitpid(pid, &status, 0), pid)
        let code = (status >> 8) & 0xFF
        return (code, outStr, errStr)
    }

    private func readAll(_ fd: Int32) -> String {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(buf, count: n) }
            else { break }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - OpenSSL Verify Tests

    func testOpenSSLDgstVerifySHA256AndSHA1OverPipes() throws {
        let (priv, pubPKCS1) = try generateRSAKeyPair()
        let spkiPEM = pemWrap("PUBLIC KEY", der: spkiFromRSAPublicKey(pubPKCS1))
        let keyURL = tmpDir.appendingPathComponent("pub.pem")
        try spkiPEM.write(to: keyURL, atomically: true, encoding: .utf8)

        let payload = Data("CrossOver license verification test payload\n".utf8)
        let dataURL = tmpDir.appendingPathComponent("payload.txt")
        try payload.write(to: dataURL)

        var cfErr: Unmanaged<CFError>?
        let sig256 = try XCTUnwrap(SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA256, payload as CFData, &cfErr) as Data?)
        let sig256URL = tmpDir.appendingPathComponent("payload.sha256")
        try sig256.write(to: sig256URL)

        let sig1 = try XCTUnwrap(SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA1, payload as CFData, &cfErr) as Data?)
        let sig1URL = tmpDir.appendingPathComponent("payload.sha1")
        try sig1.write(to: sig1URL)

        // Valid SHA-256 via file path
        let r1 = try runPosixSpawn(path: "/usr/bin/openssl",
                                   args: ["openssl", "dgst", "-sha256", "-verify", keyURL.path, "-signature", sig256URL.path, dataURL.path])
        XCTAssertEqual(r1.rc, 0)
        XCTAssertTrue(r1.stdout.contains("Verified OK"), r1.stdout)

        // Valid SHA-1 via stdin pipe
        let r2 = try runPosixSpawn(path: "/usr/bin/openssl",
                                   args: ["openssl", "dgst", "-sha1", "-verify", keyURL.path, "-signature", sig1URL.path],
                                   stdinData: payload)
        XCTAssertEqual(r2.rc, 0)
        XCTAssertTrue(r2.stdout.contains("Verified OK"), r2.stdout)

        // Tampered payload fails
        let badPayload = Data("Tampered payload\n".utf8)
        let r3 = try runPosixSpawn(path: "/usr/bin/openssl",
                                   args: ["openssl", "dgst", "-sha256", "-verify", keyURL.path, "-signature", sig256URL.path],
                                   stdinData: badPayload)
        XCTAssertNotEqual(r3.rc, 0)
        XCTAssertTrue(r3.stdout.contains("Verification failure"), r3.stdout)
    }

    func testOpenSSLSMIMEAndX509Verify() throws {
        let (priv, pubPKCS1) = try generateRSAKeyPair()
        let certDER = try buildSelfSignedCert(priv: priv, pubPKCS1: pubPKCS1)
        let certPEM = pemWrap("CERTIFICATE", der: certDER)
        let caURL = tmpDir.appendingPathComponent("ca.pem")
        try certPEM.write(to: caURL, atomically: true, encoding: .utf8)

        let content = Data("Signed CMS payload\n".utf8)
        let contentURL = tmpDir.appendingPathComponent("content.txt")
        try content.write(to: contentURL)

        let cmsDetached = try buildCMSSignedData(priv: priv, certDER: certDER, content: content, detached: true)
        let cmsPEM = pemWrap("PKCS7", der: cmsDetached)
        let p7URL = tmpDir.appendingPathComponent("sig.p7s")
        try cmsPEM.write(to: p7URL, atomically: true, encoding: .utf8)

        // smime -verify detached with -CAfile over pipe
        let r1 = try runPosixSpawn(path: "/usr/bin/openssl",
                                   args: ["openssl", "smime", "-verify", "-inform", "PEM", "-in", p7URL.path,
                                          "-content", contentURL.path, "-CAfile", caURL.path])
        XCTAssertEqual(r1.rc, 0, r1.stderr)
        XCTAssertEqual(r1.stdout, "Signed CMS payload\n")
        XCTAssertTrue(r1.stderr.contains("Verification successful"), r1.stderr)

        // smime -verify fails on tampered content
        let badURL = tmpDir.appendingPathComponent("bad.txt")
        try Data("Wrong content\n".utf8).write(to: badURL)
        let r2 = try runPosixSpawn(path: "/usr/bin/openssl",
                                   args: ["openssl", "smime", "-verify", "-inform", "PEM", "-in", p7URL.path,
                                          "-content", badURL.path, "-CAfile", caURL.path])
        XCTAssertNotEqual(r2.rc, 0)

        // x509 -verify with CAfile
        let r3 = try runPosixSpawn(path: "/usr/bin/openssl",
                                   args: ["openssl", "x509", "-in", caURL.path, "-CAfile", caURL.path, "-verify"])
        XCTAssertEqual(r3.rc, 0, r3.stderr)
        XCTAssertTrue(r3.stdout.contains("Verification successful"), r3.stdout)

        let untrusted = try runPosixSpawn(path: "/usr/bin/openssl",
                                          args: ["openssl", "verify", caURL.path])
        XCTAssertNotEqual(untrusted.rc, 0, "An input certificate must not become its own trust anchor")

        let missingCA = try runPosixSpawn(path: "/usr/bin/openssl",
                                          args: ["openssl", "smime", "-verify", "-inform", "PEM", "-in", p7URL.path,
                                                 "-content", contentURL.path, "-CAfile", caURL.path + ".missing"])
        XCTAssertNotEqual(missingCA.rc, 0, "An unreadable CA file must fail verification")
    }

    // MARK: - Builtins, fork/execve, system, popen

    func testUnsupportedPerlWrapperAndProcessReplacement() throws {
        let wrapper = tmpDir.appendingPathComponent("wine")
        try Data("#!/usr/bin/perl\nexit 0;\n".utf8).write(to: wrapper)
        // Without a Perl runtime (MacAppsKit installs PerlCommand's when a Mac app launches).
        MacProcessShimSetPerlRuntime(nil)
        XCTAssertEqual(MacShim_posix_spawn(nil, wrapper.path, nil, nil, nil, nil), ENOTSUP)
        XCTAssertEqual(MacShim_posix_spawn(nil, wrapper.path + ".missing", nil, nil, nil, nil), ENOENT)

        var attributes: posix_spawnattr_t?
        XCTAssertEqual(posix_spawnattr_init(&attributes), 0)
        defer { posix_spawnattr_destroy(&attributes) }
        XCTAssertEqual(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC)), 0)
        XCTAssertEqual(MacShim_posix_spawn(nil, "/usr/bin/true", nil, &attributes, nil, nil), ENOTSUP)
    }

    func testCrossOverRuntimeDispatch() throws {
        let support = tmpDir.appendingPathComponent("Contents/SharedSupport/CrossOver")
        let bin = support.appendingPathComponent("bin")
        let loader = support.appendingPathComponent("lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Minimal Mach-O headers are enough for command resolution. No vendor
        // binary is loaded by the test.
        let armHeader: [UInt32] = [0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 0, 0]
        let x86Header: [UInt32] = [0xfeedfacf, 0x01000007, 0, 2, 0, 0, 0, 0]
        let server = bin.appendingPathComponent("wineserver-arm64")
        try armHeader.withUnsafeBytes { try Data($0).write(to: server) }
        try armHeader.withUnsafeBytes { try Data($0).write(to: loader) }
        try x86Header.withUnsafeBytes { try Data($0).write(to: bin.appendingPathComponent("wineserver-x86")) }
        let scripts = ["wine", "wineprefixcreate", "cxbottle", "cxstart"]
        for name in scripts {
            try Data("#!/usr/bin/perl\n".utf8).write(to: bin.appendingPathComponent(name))
        }

        MacProcessShimInstallForBundle(tmpDir.path)
        defer {
            MacProcessShimSetWineRuntime(nil)
            MacProcessShimSetPerlRuntime(nil)
        }
        XCTAssertEqual(MacShim_posix_spawn(nil, server.path, nil, nil, nil, nil), ENOTSUP)
        XCTAssertEqual(MacShim_posix_spawn(nil, "wine", nil, nil, nil, nil), ENOTSUP)
        XCTAssertEqual(MacShim_posix_spawn(nil, tmpDir.appendingPathComponent("wine").path, nil, nil, nil, nil), ENOENT)

        MacProcessShimSetWineRuntime { path, argv, env, _, stdout, _ in
            guard let path, let argument = argv?[1], let prefix = env?[0] else { return 99 }
            let output = "\(String(cString: path))|\(String(cString: argument))|\(String(cString: prefix))"
            _ = output.withCString { write(stdout, $0, output.utf8.count) }
            return 42
        }
        MacProcessShimSetPerlRuntime { path, argv, env, _, stdout, stderr in
            guard let path else { return 99 }
            if let target = argv?[1], let operation = argv?[2] {
                if String(cString: operation) == "--system" {
                    let status = MacShim_system("wineserver --system")
                    return (status >> 8) & 0xFF
                }
                if String(cString: operation) == "--popen" {
                    guard let stream = MacShim_popen("wineserver --popen", "r") else { return 98 }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = buffer.withUnsafeMutableBytes {
                        fread($0.baseAddress, 1, $0.count, stream)
                    }
                    _ = buffer.withUnsafeBytes { write(stdout, $0.baseAddress, count) }
                    let status = MacShim_pclose(stream)
                    return (status >> 8) & 0xFF
                }
                if String(cString: operation) == "--spawn" {
                    var pid: pid_t = 0
                    var args: [UnsafeMutablePointer<CChar>?] = [target, operation, nil]
                    let result = args.withUnsafeMutableBufferPointer {
                        MacShim_posix_spawn(&pid, target, nil, nil, $0.baseAddress, nil)
                    }
                    guard result == 0 else { return result }
                    var status: Int32 = 0
                    guard MacShim_waitpid(pid, &status, 0) == pid else { return 98 }
                    return (status >> 8) & 0xFF
                }
                let args = [target, argv?[2], nil]
                return args.withUnsafeBufferPointer { buffer in
                    MacShim_execve(target, UnsafeMutablePointer(mutating: buffer.baseAddress!), env)
                }
            }
            _ = write(stderr, path, strlen(path))
            return 43
        }

        for path in ["wineserver", "wineserver-x86", loader.path] {
            let env = "WINEPREFIX=" + tmpDir.appendingPathComponent("Bottles/LAB Steam").path
            let result = try runPosixSpawn(path: path, args: [path, "--version"], environment: [env])
            let resolved = path == "wineserver" ? server.path :
                path == "wineserver-x86" ? bin.appendingPathComponent(path).path : path
            // Command lookup canonicalizes the active bundle path.
            XCTAssertEqual(result.stdout.replacingOccurrences(of: "/private/var", with: "/var"),
                           "\(resolved)|--version|\(env)".replacingOccurrences(of: "/private/var", with: "/var"))
            XCTAssertEqual(result.rc, 42)
        }
        for name in scripts {
            let result = try runPosixSpawn(path: name, args: [name])
            XCTAssertTrue(result.stderr.hasSuffix("/bin/" + name))
            XCTAssertEqual(result.rc, 43)
        }

        // CrossOver's Wine wrapper ends with exec, preserving its redirected I/O.
        let env = "WINEPREFIX=" + tmpDir.appendingPathComponent("Bottles/LAB Steam").path
        let replacement = try runPosixSpawn(path: "wine", args: ["wine", loader.path, "steam.exe"], environment: [env])
        XCTAssertTrue(replacement.stdout.hasSuffix("/MacOS/wine|steam.exe|" + env))
        XCTAssertEqual(replacement.rc, 42)

        // A separate subprocess inherits the wrapper's environment and I/O too.
        let spawned = try runPosixSpawn(path: "wine", args: ["wine", loader.path, "--spawn"], environment: [env])
        XCTAssertTrue(spawned.stdout.hasSuffix("/MacOS/wine|--spawn|" + env))
        XCTAssertEqual(spawned.rc, 42)

        for operation in ["--system", "--popen"] {
            let result = try runPosixSpawn(path: "wine", args: ["wine", loader.path, operation], environment: [env])
            XCTAssertTrue(result.stdout.hasSuffix("/bin/wineserver-arm64|\(operation)|" + env))
            XCTAssertEqual(result.rc, 42)
        }
    }

    func testBuiltinsPopenSystemAndForkExecve() throws {
        // popen("sw_vers -productName", "r")
        let f1 = try XCTUnwrap(MacShim_popen("sw_vers -productName", "r"))
        let out1 = readAll(fileno(f1))
        XCTAssertEqual(MacShim_pclose(f1), 0)
        XCTAssertEqual(out1, "macOS\n")

        // popen("/bin/sh -c 'uname -m'", "r")
        let f2 = try XCTUnwrap(MacShim_popen("/bin/sh -c 'uname -m'", "r"))
        let out2 = readAll(fileno(f2))
        XCTAssertEqual(MacShim_pclose(f2), 0)
        XCTAssertEqual(out2, "arm64\n")

        // system("uname -s")
        XCTAssertEqual(MacShim_system("uname -s"), 0)

        // gzip compress -> gunzip -dc roundtrip over pipe
        let sampleGZ = Data("CrossOver c4p payload\n".utf8)
        let gzRes = try runPosixSpawn(path: "gzip", args: ["gzip", "-c"], stdinData: sampleGZ)
        XCTAssertEqual(gzRes.rc, 0)
        // Binary gzip stream roundtrip via tmp file + gunzip -dc
        let plainURL = tmpDir.appendingPathComponent("note.txt")
        try sampleGZ.write(to: plainURL)
        let gzFileRes = try runPosixSpawn(path: "gzip", args: ["gzip", "-k", plainURL.path])
        XCTAssertEqual(gzFileRes.rc, 0)
        let ungzRes = try runPosixSpawn(path: "gunzip", args: ["gunzip", "-c", plainURL.path + ".gz"])
        XCTAssertEqual(ungzRes.rc, 0)
        XCTAssertEqual(ungzRes.stdout, "CrossOver c4p payload\n")
        let whichRes = try runPosixSpawn(path: "which", args: ["which", "openssl", "gzip"])
        XCTAssertEqual(whichRes.rc, 0)
        XCTAssertEqual(whichRes.stdout, "/usr/bin/openssl\n/usr/bin/gzip\n")

        // fork + dup2 + close + execve + waitpid
        var outPipe: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&outPipe), 0)
        let pid = MacShim_fork()
        if pid == 0 {
            MacShim_close(outPipe[0])
            MacShim_dup2(outPipe[1], STDOUT_FILENO)
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/uname"), strdup("-m"), nil]
            var envp: [UnsafeMutablePointer<CChar>?] = [nil]
            _ = "/usr/bin/uname".withCString { p in
                argv.withUnsafeBufferPointer { ab in
                    envp.withUnsafeMutableBufferPointer { eb in
                        MacShim_execve(p, UnsafeMutablePointer(mutating: ab.baseAddress!), eb.baseAddress!)
                    }
                }
            }
            MacShim__exit(127)
        }
        XCTAssertGreaterThan(pid, 0)
        close(outPipe[1])
        let forkOut = readAll(outPipe[0])
        close(outPipe[0])
        var status: Int32 = 0
        XCTAssertEqual(MacShim_waitpid(pid, &status, 0), pid)
        XCTAssertEqual((status >> 8) & 0xFF, 0)
        XCTAssertEqual(forkOut, "arm64\n")
    }

    // MARK: - Device loader launch

    @MainActor
    func testForcedTLLoaderLaunchesMacBuiltSample() throws {
        let oldForceTL = ProcessInfo.processInfo.environment["TRIPTYCH_FORCE_TL"]
        setenv("TRIPTYCH_FORCE_TL", "1", 1)
        defer {
            if let oldForceTL { setenv("TRIPTYCH_FORCE_TL", oldForceTL, 1) }
            else { unsetenv("TRIPTYCH_FORCE_TL") }
        }
        let zip = try XCTUnwrap(MacAppLibrary.bundledMacBuiltSampleZipPath())
        let names = try XCTUnwrap(MacAppLibrary.importFile(atPath: zip, error: nil))
        XCTAssertTrue(names.contains("MacBuiltApp"), "\(names)")
        let app = try XCTUnwrap(MacAppLibrary.installedApps().first { $0.name == "MacBuiltApp" })
        defer { MacAppLibrary.removeApp(atPath: app.path) }
        XCTAssertTrue(app.launchable)

        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let vc = UIViewController()
        vc.view.frame = window.bounds
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 380, height: 640))
        vc.view.addSubview(container)

        var sawWindow = false
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.3, 0, 0, 0) { _ in
            if let nsAppCls = NSClassFromString("NSApplication") as? NSObject.Type {
                let nsApp = nsAppCls.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as AnyObject?
                if let wins = nsApp?.value(forKey: "windows") as? [AnyObject], !wins.isEmpty {
                    sawWindow = true
                }
                _ = nsApp?.perform(NSSelectorFromString("terminate:"), with: nil)
            } else {
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)

        var err: NSString?
        let rc = MacAppLibrary.runAppWithTLLoader(atPath: app.path,
                                                  hostWindow: window,
                                                  viewController: vc,
                                                  containerView: container,
                                                  error: &err)
        XCTAssertEqual(rc, 0, "tl_loader error: \(err ?? "")")
        XCTAssertNil(err)
        XCTAssertTrue(sawWindow, "MacBuiltApp should create an NSWindow on libShim_AppKit under tl_loader")

        for sym in ["_fork", "_vfork", "_execve", "_posix_spawn", "_posix_spawnp", "_waitpid", "_system", "_popen"] {
            let expected = MacProcessShimLookup(sym)
            let resolved = tl_runtime_lookup(sym)
            XCTAssertNotNil(expected, "MacProcessShimLookup(\(sym)) missing")
            XCTAssertEqual(resolved, expected, "tl_runtime_lookup(\(sym)) did not delegate to MacProcessShimLookup")
        }
    }
}
