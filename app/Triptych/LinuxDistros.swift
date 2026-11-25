// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// Root filesystems for the Linux engine. Each lives in Application Support/Linux/<id>
/// in LinuxRunner's fakefs format (meta.db + data). The bundled Alpine is the starter;
/// others are downloaded from the distribution's own servers, checked against the
/// checksum it publishes, and imported with LinuxRunner's fakefs importer.
struct LinuxDistro: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String

    static let catalogue: [LinuxDistro] = [
        .init(id: "alpine", name: "Alpine Linux (bundled)", note: "Small, musl. Included in the app."),
        .init(id: "alpine-latest", name: "Alpine Linux, latest stable", note: "About 4 MB download. sha256 from alpinelinux.org."),
        .init(id: "ubuntu", name: "Ubuntu Base 26.04", note: "About 30 MB download, glibc, apt. sha256 from cdimage.ubuntu.com."),
        .init(id: "debian", name: "Debian 13 (Trixie) ARM64", note: "About 90 MB download, glibc, apt. sha256 from linuxcontainers.org."),
        .init(id: "fedora", name: "Fedora Linux ARM64", note: "About 156 MB download, glibc, dnf. sha256 from fedoraproject.org."),
        .init(id: "arch", name: "Arch Linux ARM", note: "About 830 MB download, pacman. md5 from archlinuxarm.org."),
    ]

    static func dir(_ id: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Linux/\(id)", isDirectory: true)
    }
    static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: dir(id).appendingPathComponent("meta.db").path)
    }
    static var installedIDs: [String] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Linux")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return ids.filter(isInstalled).sorted()
    }
    static var selected: String {
        get { UserDefaults.standard.string(forKey: "linux.root") ?? "alpine" }
        set { UserDefaults.standard.set(newValue, forKey: "linux.root") }
    }
}

enum DistroError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Where to download a distro and the checksum its publisher lists for that file.
private struct Source { let url: URL; let sha256: String?; let md5: String? }

@MainActor
final class DistroInstaller: ObservableObject {
    static let shared = DistroInstaller()
    @Published var busy: String?
    @Published var progress: Double = 0
    @Published var status = ""

    private func text(_ url: String) async throws -> String {
        guard let parsed = URL(string: url) else { throw DistroError.message("Invalid URL: \(url)") }
        let (d, r) = try await URLSession.shared.data(from: parsed)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw DistroError.message("\(url): HTTP error") }
        return String(decoding: d, as: UTF8.self)
    }

    private func resolve(_ id: String) async throws -> Source {
        switch id {
        case "alpine-latest":
            let base = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/"
            let yaml = try await text(base + "latest-releases.yaml")
            // Entries are "-\n  title: ...\n  flavor: alpine-minirootfs\n ... file: ...\n ... sha256: ..."
            for block in yaml.components(separatedBy: "\n-\n") where block.contains("flavor: alpine-minirootfs") {
                func field(_ k: String) -> String? {
                    block.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(k + ":") }
                        .flatMap { line -> String? in
                            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                            guard parts.count == 2 else { return nil }
                            return parts[1].trimmingCharacters(in: .whitespaces)
                        }
                }
                if let f = field("file"), !f.isEmpty, let h = field("sha256"), !h.isEmpty,
                   let url = URL(string: base + f) {
                    return Source(url: url, sha256: h, md5: nil)
                }
            }
            throw DistroError.message("Alpine's release list has no minirootfs entry")
        case "ubuntu":
            let base = "https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/"
            let sums = try await text(base + "SHA256SUMS")
            let lines = sums.split(separator: "\n").filter { $0.hasSuffix("-base-arm64.tar.gz") }
            // Highest point release: compare file names (26.04 < 26.04.1 < 26.04.2).
            guard let best = lines.max(by: {
                ($0.split(separator: "*").last ?? $0).compare($1.split(separator: "*").last ?? $1, options: .numeric) == .orderedAscending
            }) else {
                throw DistroError.message("No arm64 Ubuntu Base in SHA256SUMS")
            }
            let parts = best.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let last = parts.last else {
                throw DistroError.message("Malformed SHA256SUMS entry")
            }
            let sha256 = String(parts[0])
            let file = String(last).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard !sha256.isEmpty, !file.isEmpty, let url = URL(string: base + file) else {
                throw DistroError.message("Malformed SHA256SUMS entry")
            }
            return Source(url: url, sha256: sha256, md5: nil)
        case "arch":
            let u = "https://fl.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
            guard let md5 = try await text(u + ".md5").split(whereSeparator: \.isWhitespace).first.map(String.init),
                  !md5.isEmpty,
                  let url = URL(string: u) else {
                throw DistroError.message("Missing md5 checksum for Arch Linux ARM")
            }
            return Source(url: url, sha256: nil, md5: md5)
        case "debian":
            let base = "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/"
            let html = try await text(base)
            let snaps = Self.matches(in: html, pattern: #"href="([0-9]{8}_[0-9]{2}(?::|%3[Aa])[0-9]{2}/)""#)
            guard let latest = snaps.max() else {
                throw DistroError.message("No Debian Trixie ARM64 snapshot found")
            }
            let snapURL = base + latest
            let sums = try await text(snapURL + "SHA256SUMS")
            guard let line = sums.split(separator: "\n").first(where: {
                $0.split(whereSeparator: \.isWhitespace).last == "rootfs.tar.xz"
            }),
            let sha = line.split(whereSeparator: \.isWhitespace).first.map(String.init),
            !sha.isEmpty,
            let url = URL(string: snapURL + "rootfs.tar.xz") else {
                throw DistroError.message("Missing rootfs.tar.xz entry in Debian SHA256SUMS")
            }
            return Source(url: url, sha256: sha, md5: nil)
        case "fedora":
            let base = "https://dl.fedoraproject.org/pub/fedora/linux/releases/"
            let html = try await text(base)
            let releases = Set(Self.matches(in: html, pattern: #"href="([0-9]+)/""#))
                .sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
            for rel in releases.prefix(3) {
                let imagesBase = "\(base)\(rel)/Container/aarch64/images/"
                guard let imgHTML = try? await text(imagesBase),
                      let checksumFile = Self.matches(in: imgHTML, pattern: #"href="(Fedora-Container-[0-9]+-[^"]*-aarch64-CHECKSUM)""#).last,
                      let checksumText = try? await text(imagesBase + checksumFile) else { continue }
                for rawLine in checksumText.split(separator: "\n") {
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let wslRange = line.range(of: #"Fedora-WSL-Base-[0-9]+-[^)]*[.-]aarch64\.wsl"#, options: .regularExpression),
                       let hashRange = line.range(of: #"[0-9a-fA-F]{64}$"#, options: .regularExpression),
                       let url = URL(string: imagesBase + String(line[wslRange])) {
                        return Source(url: url, sha256: String(line[hashRange]), md5: nil)
                    }
                }
            }
            throw DistroError.message("No Fedora ARM64 WSL/container rootfs checksum found")
        default:
            throw DistroError.message("Unknown distro \(id)")
        }
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
    }

    func install(_ distro: LinuxDistro) async {
        guard busy == nil else { return }
        busy = distro.id; progress = 0; status = "Looking up the current release…"
        defer { busy = nil }
        do {
            let src = try await resolve(distro.id)
            status = "Downloading \(src.url.lastPathComponent)…"
            let file = try await download(src.url)
            defer { try? FileManager.default.removeItem(at: file) }
            status = "Checking the checksum…"
            try verify(file, src)
            try await importArchive(file, as: distro.id)
            LinuxDistro.selected = distro.id
            status = "\(distro.name) installed."
        } catch { status = "Failed: \(error.localizedDescription)" }
    }

    func importFile(_ url: URL) async {
        guard busy == nil else { return }
        let id = "custom-" + url.deletingPathExtension().deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        busy = id; progress = 0; status = "Copying \(url.lastPathComponent)…"
        defer { busy = nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await importArchive(tmp, as: id)
            LinuxDistro.selected = id
            status = "\(id) imported."
        } catch { status = "Failed: \(error.localizedDescription)" }
    }

    private func download(_ url: URL) async throws -> URL {
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        return try await withCheckedThrowingContinuation { cont in
            let delegate = DownloadDelegate(destination: dst, onProgress: { [weak self] frac in
                Task { @MainActor in self?.progress = frac * 0.8 }
            }, completion: { result in
                cont.resume(with: result)
            })
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }

    private func verify(_ file: URL, _ src: Source) throws {
        guard src.sha256 != nil || src.md5 != nil else {
            throw DistroError.message("Missing checksum for download")
        }
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var sha = SHA256(), md5 = Insecure.MD5()
        while let chunk = try h.read(upToCount: 1 << 22), !chunk.isEmpty {
            if src.sha256 != nil { sha.update(data: chunk) } else { md5.update(data: chunk) }
        }
        let hex: (any Sequence<UInt8>) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
        if let want = src.sha256, hex(sha.finalize()) != want.lowercased() { throw DistroError.message("sha256 mismatch: download corrupted or tampered with") }
        if let want = src.md5, src.sha256 == nil, hex(md5.finalize()) != want.lowercased() { throw DistroError.message("md5 mismatch: download corrupted") }
    }

    private func importArchive(_ file: URL, as id: String) async throws {
        status = "Unpacking into the Linux file system…"
        let dir = LinuxDistro.dir(id)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let box = Unmanaged.passRetained(self)
        defer { box.release() }
        let err: String? = await Task.detached {
            var buf = [CChar](repeating: 0, count: 512)
            let rc = tp_linux_import(file.path, dir.path, box.toOpaque(), { cookie, p in
                let me = Unmanaged<DistroInstaller>.fromOpaque(cookie!).takeUnretainedValue()
                Task { @MainActor in me.progress = 0.8 + p * 0.2 }
            }, &buf, Int32(buf.count))
            return rc == 0 ? nil : String(cString: buf)
        }.value
        if let err { try? FileManager.default.removeItem(at: dir); throw DistroError.message("Import failed: \(err)") }
        progress = 1
    }
}

struct LinuxDistrosView: View {
    @ObservedObject private var inst = DistroInstaller.shared
    @State private var selected = LinuxDistro.selected
    @State private var installed = LinuxDistro.installedIDs
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !inst.status.isEmpty {
                        TriptychPanelCard(accent: TriptychPalette.linuxLight, raised: true) {
                            Text(inst.status)
                                .font(.footnote)
                                .foregroundStyle(TriptychPalette.textPrimary)
                                .accessibilityIdentifier("distro-status")
                        }
                    }

                    TriptychSectionHeader(title: "Systems", accent: TriptychPalette.linuxLight)
                    TriptychPanelCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(LinuxDistro.catalogue.enumerated()), id: \.element.id) { idx, d in
                                let have = d.id == "alpine" || LinuxDistro.isInstalled(d.id)
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(d.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(TriptychPalette.textPrimary)
                                        Text(d.note)
                                            .font(.caption)
                                            .foregroundStyle(TriptychPalette.textSecondary)
                                    }
                                    Spacer()
                                    if inst.busy == d.id {
                                        ProgressView(value: inst.progress).frame(width: 70).tint(TriptychPalette.linuxLight)
                                    } else if have {
                                        Button(selected == d.id ? "In use" : "Use") { choose(d.id) }
                                            .buttonStyle(.bordered)
                                            .tint(TriptychPalette.linuxLight)
                                            .disabled(selected == d.id)
                                            .accessibilityIdentifier("distro-use-\(d.id)")
                                    } else {
                                        Button("Get") { Task { await inst.install(d); refresh() } }
                                            .buttonStyle(.borderedProminent)
                                            .tint(TriptychPalette.linuxDeep)
                                            .disabled(inst.busy != nil)
                                            .accessibilityIdentifier("distro-get-\(d.id)")
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                if idx < LinuxDistro.catalogue.count - 1 || !installed.filter({ $0.hasPrefix("custom-") }).isEmpty {
                                    Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                                }
                            }
                            let customs = installed.filter { $0.hasPrefix("custom-") }
                            ForEach(Array(customs.enumerated()), id: \.element) { idx, id in
                                HStack {
                                    Text(id.dropFirst(7))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(TriptychPalette.textPrimary)
                                    Spacer()
                                    Button(selected == id ? "In use" : "Use") { choose(id) }
                                        .buttonStyle(.bordered)
                                        .tint(TriptychPalette.linuxLight)
                                        .disabled(selected == id)
                                        .accessibilityIdentifier("distro-use-\(id)")
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                if idx < customs.count - 1 {
                                    Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                                }
                            }
                        }
                    }

                    Text("The system in use starts the next time Linux starts (quit and reopen Triptych if Linux is running).")
                        .font(.footnote)
                        .foregroundStyle(TriptychPalette.textSecondary)

                    TriptychSectionHeader(title: "Custom Archive", accent: TriptychPalette.linuxLight)
                    TriptychPanelCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Button("Import a root file system from Files…") {
                                if let testPath = ProcessInfo.processInfo.environment["TRIPTYCH_IMPORT_ARCHIVE"], !testPath.isEmpty {
                                    Task { await inst.importFile(URL(fileURLWithPath: testPath)); refresh() }
                                } else {
                                    importing = true
                                }
                            }
                            .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.linuxLight))
                            .disabled(inst.busy != nil)
                            .accessibilityIdentifier("distro-import-files")

                            Text("An ARM64 (aarch64) Linux root file system archive: .tar, .tar.gz, .tar.xz, .tar.bz2, .tar.zst or .wsl.")
                                .font(.footnote)
                                .foregroundStyle(TriptychPalette.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle("Linux systems")
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importableTypes) { r in
            if case .success(let url) = r { Task { await inst.importFile(url); refresh() } }
        }
    }

    private static var importableTypes: [UTType] {
        var types: [UTType] = [.archive, .gzip, .bz2, .data]
        for ext in ["tar", "xz", "zst", "wsl"] {
            if let ut = UTType(filenameExtension: ext) { types.append(ut) }
        }
        return types
    }

    private func choose(_ id: String) { LinuxDistro.selected = id; selected = id }
    private func refresh() { installed = LinuxDistro.installedIDs; selected = LinuxDistro.selected }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var completion: ((Result<URL, Error>) -> Void)?
    private let lock = NSLock()
    var session: URLSession?

    init(destination: URL, onProgress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        self.completion = completion
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let cb = completion
        completion = nil
        let sess = session
        session = nil
        lock.unlock()
        sess?.finishTasksAndInvalidate()
        cb?(result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(DistroError.message("Download failed (HTTP \(http.statusCode))")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else { finish(.failure(DistroError.message("Download finished without file"))) }
    }
}
