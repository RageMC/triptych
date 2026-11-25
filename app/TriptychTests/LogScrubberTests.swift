// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Triptych

final class LogScrubberTests: XCTestCase {
    private func s(_ t: String) -> String { LogScrubber.scrub(t) }

    func testHostAndContainerPaths() {
        XCTAssertEqual(s("dladdr: /Users/jdoeuser/Library/Developer/Triptych.app/Triptych"),
                       "dladdr: /Users/<user>/Library/Developer/Triptych.app/Triptych")
        XCTAssertEqual(s("LC_HOME_PATH=/private/var/mobile/Containers/Data/Application/6F1B2C3D-0A1B-4C5D-8E9F-112233445566/Documents/LiveContainer"),
                       "LC_HOME_PATH=/var/mobile/Containers/Data/Application/<app-uuid>/Documents/LiveContainer")
        XCTAssertEqual(s("cd /home/alice/.wine"), "cd /home/<user>/.wine")
        XCTAssertEqual(s(#"C:\Users\Bob\AppData"#), #"C:\Users\<win-user>\AppData"#)
        XCTAssertEqual(s(#"C:\Users\Public\Desktop"#), #"C:\Users\Public\Desktop"#)
        XCTAssertEqual(s("/Users/Shared/x"), "/Users/Shared/x")
    }

    func testUUIDsEmailsAppleID() {
        XCTAssertEqual(s("session 123E4567-E89B-12D3-A456-426614174000 started"), "session <uuid> started")
        XCTAssertEqual(s("login failed for jane.doe+steam@example.co.uk"), "login failed for <email>")
        XCTAssertEqual(s("Apple ID: someone@icloud.com"), "Apple ID: <apple-id>")
        XCTAssertEqual(s("appleid=johnny"), "appleid=<apple-id>")
    }

    func testNetwork() {
        XCTAssertEqual(s("dns 203.0.113.7 via 192.168.1.20"), "dns <ip> via <ip>")
        XCTAssertEqual(s("slirp guest 10.0.2.15 gw 10.0.2.2 lo 127.0.0.1"), "slirp guest 10.0.2.15 gw 10.0.2.2 lo 127.0.0.1")
        XCTAssertEqual(s("10.0.3.4 and 10.0.2.200"), "<ip> and 10.0.2.200")
        XCTAssertEqual(s("version 1.2.3 build 999.1.1.1"), "version 1.2.3 build 999.1.1.1")
        XCTAssertEqual(s("addr 2001:db8:85a3::8a2e:370:7334 up"), "addr <ip> up")
        XCTAssertEqual(s("lo ::1"), "lo ::1")
        XCTAssertEqual(s("wifi aa:bb:cc:dd:ee:ff"), "wifi <mac>")
        XCTAssertEqual(s("at 12:34:56 std::string Foo::bar"), "at 12:34:56 std::string Foo::bar")
    }

    func testSerialsAndSecrets() {
        XCTAssertEqual(s("Serial Number: F2LXK1ABCDEF"), "Serial Number: <serial>")
        XCTAssertEqual(s("UDID=00008110-001A2B3C4D5E801E"), "UDID=<serial>")
        XCTAssertEqual(s("token ghp_" + String(repeating: "a1B2", count: 9)), "token <redacted-token>")
        XCTAssertEqual(s("Authorization: Bearer abc.def-123"), "Authorization: Bearer <redacted-token>")
        XCTAssertEqual(s("wine.exe --AUTH_PASSWORD=hunter2 -foo"), "wine.exe --AUTH_PASSWORD=<redacted-token> -foo")
        XCTAssertEqual(s("key " + String(repeating: "deadbeef", count: 8)), "key <hex>")
        XCTAssertEqual(s("blob dGhpcy1pcy1hLXNlY3JldC1rZXktMTIzNDU2Nzg5MEFCQ0RFRkdISUo= end"), "blob <redacted-key> end")
    }

    func testEngineMessagesStayReadable() {
        let lines = """
        [qemu] -machine virt,accel=tcg -cpu max -m 2048
        [wine] fixme:ntdll:NtQuerySystemInformation info_class SYSTEM_PERFORMANCE_INFORMATION
        /usr/lib/x86_64-linux-gnu/libc.so.6 loaded at 0x7f12a4000000
        Triptych 1.2.3 (45) iPhone18,1 iOS 27.0
        """
        XCTAssertEqual(s(lines), lines)
    }

    func testRealisticSamplesLeakNothing() {
        let pat = "github_pat_" + String(repeating: "11AbCdEf0", count: 4) + "_xYz"
        let samples: [(raw: String, secrets: [String])] = [
            ("LC_HOME_PATH=/var/mobile/Containers/Data/Application/6F1B2C3D-0A1B-4C5D-8E9F-112233445566/Documents/LiveContainer", ["6F1B2C3D"]),
            ("open /private/var/mobile/Containers/Shared/AppGroup/AABBCCDD-0A1B-4C5D-8E9F-112233445566/LiveContainer/Tweaks", ["AABBCCDD"]),
            ("bundle /private/var/mobile/Containers/Data/PluginKitPlugin/0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D/tmp", ["0A1B2C3D"]),
            ("cache /Users/jsmith/Library/Caches/com.apple.dt.Xcode/x", ["jsmith"]),
            ("ln /Users/john.doe-dev/Desktop/win11.iso", ["john.doe-dev"]),
            ("img /Users/jsmith/Library/Application Support/Triptych", ["jsmith"]),
            ("en0 ether a4:83:e7:1f:2b:9c", ["a4:83:e7"]),
            ("mac A4-83-E7-1F-2B-9C seen", ["A4-83-E7"]),
            ("inet6 fe80::1c2b:3dff:fe4a:5b6c%en0", ["1c2b:3dff"]),
            ("route 2a02:6b8:0:1::1 via 2001:4860:4860:0:0:0:0:8888", ["2a02:6b8", "4860:4860"]),
            ("user jane_doe99@gmail.com failed", ["jane_doe99"]),
            ("From: Bob Smith <bob.smith@corp.example.org>", ["bob.smith"]),
            ("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.SflKxwRJSMeKKF2QT4fw", ["eyJhbGci", "SflKxw"]),
            ("curl -H 'Authorization: Bearer abcDEF123456'", ["abcDEF123456"]),
            ("push https://x-access-token:ghs_" + String(repeating: "Q9wE", count: 9) + "@github.com/RageMC/triptych.git", ["Q9wEQ9wE"]),
            ("GITHUB_TOKEN=ghp_" + String(repeating: "Zx8Y", count: 9), ["Zx8YZx8Y"]),
            ("gh auth: " + pat, ["11AbCdEf0"]),
            ("export GH_TOKEN=gho_" + String(repeating: "aB3d", count: 8), ["aB3daB3d"]),
            ("Apple ID: jane.doe@icloud.com signed in", ["jane.doe"]),
            ("appleid=jane@me.com", ["jane@me.com"]),
            ("ECID: 0x001A2B3C4D5E6F70 chip", ["001A2B3C4D5E6F70"]),
            ("ecid=1234567890123456", ["1234567890123456"]),
            ("UDID: 00008110-001A2B3C4D5E801E", ["001A2B3C4D5E801E"]),
            ("udid 00008112-000A1B2C3D4E5F6A", ["000A1B2C3D4E5F6A"]),
            ("device 00008110-001A2B3C4D5E801E paired", ["001A2B3C4D5E801E"]),
            ("SerialNumber = DMPXK1ABCD23", ["DMPXK1ABCD23"]),
            ("password=Sup3rS3cret!", ["Sup3rS3cret"]),
            ("cookie: session=abc123def456", ["abc123def456"]),
            ("ssh jane@203.0.113.77 -p 22", ["203.0.113.77", "jane@"]),
            ("PEER 198.51.100.4:51820", ["198.51.100.4"]),
        ]
        for (raw, secrets) in samples {
            let out = s(raw)
            for secret in secrets {
                XCTAssertFalse(out.contains(secret), "leaked \(secret) in: \(raw) -> \(out)")
            }
            XCTAssertEqual(s(out), out, "not idempotent: \(raw)")
        }
    }

    func testDeterministicAndIdempotent() {
        let raw = "/Users/me/x 203.0.113.9 me@mail.com Bearer tok123 123E4567-E89B-12D3-A456-426614174000 serial: ABCDEF123"
        XCTAssertEqual(s(raw), s(raw))
        XCTAssertEqual(s(s(raw)), s(raw))
        for leak in ["/Users/me/", "203.0.113.9", "me@mail.com", "tok123", "ABCDEF123"] { XCTAssertFalse(s(raw).contains(leak)) }
    }
}

final class DeviceContextTests: XCTestCase {
    func testContextLinesStateBuildDeviceOSJITAndSystems() {
        let l = DeviceInfo.contextLines(info: ["TriptychCommit": "abc1234 2026-11-24T02:00Z"], model: "iPad16,6", os: "27.2",
                                        jit: "LiveContainer", systems: [.linux, .winpc])
        XCTAssertEqual(l[0], "Triptych build: abc1234 2026-11-24T02:00Z")
        XCTAssertEqual(l[1], "Device: iPad16,6")
        XCTAssertEqual(l[2], "iPadOS: 27.2")
        XCTAssertEqual(l[3], "JIT source: LiveContainer")
        XCTAssertEqual(l[4], "Systems run this launch: \(EngineKind.linux.title), \(EngineKind.winpc.title)")
    }

    func testUnstampedBuildAndNoSystems() {
        let l = DeviceInfo.contextLines(info: [:], model: "x", os: "1", jit: "none", systems: [])
        XCTAssertEqual(l[0], "Triptych build: unstamped")
        XCTAssertEqual(l[4], "Systems run this launch: none")
    }

    func testJITSource() {
        XCTAssertEqual(DeviceInfo.jitSource(inLiveContainer: true, debugged: true), "LiveContainer")
        XCTAssertEqual(DeviceInfo.jitSource(inLiveContainer: false, debugged: true), "StikDebug")
        XCTAssertEqual(DeviceInfo.jitSource(inLiveContainer: true, debugged: false), "none")
    }

    func testContextSurvivesScrubber() {
        let text = DeviceInfo.contextLines(info: ["TriptychCommit": "abc1234"], model: "iPad16,6", os: "27.2", jit: "StikDebug", systems: [.macapps]).joined(separator: "\n")
        XCTAssertTrue(LogScrubber.scrub(text).contains("iPad16,6"))
    }
}
