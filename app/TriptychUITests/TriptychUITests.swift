// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

private extension XCTestCase {
    func sessionButton(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[id]
        if !button.isHittable {
            let controls = app.buttons["session-controls"]
            if controls.exists && controls.label == "Show session controls" { controls.tap() }
        }
        XCTAssertTrue(button.waitForExistence(timeout: 10), id)
        return button
    }

    func checkDisplay(_ view: XCUIElement, in app: XCUIApplication,
                      screenshot: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(view.waitForExistence(timeout: 15), "display view", file: file, line: line)
        let window = app.windows.firstMatch
        let actual = view.frame
        let expected = window.frame
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
        XCTAssertFalse(app.navigationBars.firstMatch.isHittable, "session navigation bar", file: file, line: line)
        if let screenshot {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = screenshot
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func framebufferSize(_ view: XCUIElement) -> [Int] {
        (view.value as? String ?? "").split(separator: " ").first { $0.contains("x") }?
            .split(separator: "x").compactMap { Int($0) } ?? []
    }

    func checkGuestAspect(_ width: Int, _ height: Int, display: XCUIElement,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(width, 0, file: file, line: line)
        XCTAssertGreaterThan(height, 0, file: file, line: line)
        guard width > 0, height > 0, display.frame.height > 0 else { return }
        XCTAssertEqual(Double(width) / Double(height), display.frame.width / display.frame.height,
                       accuracy: 0.01, file: file, line: line)
    }
}

final class TriptychUITests: XCTestCase {
    func testHomeListsAllThreeSystems() {
        let app = XCUIApplication(); app.launch()
        for id in ["engine-windows", "engine-macos", "engine-linux"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10), id)
        }
        attach(app, "home")
    }

    func testHomeControlsAreLabelledAndIdentified() {
        let app = XCUIApplication(); app.launch()
        for id in ["panel-windows", "panel-mac", "panel-linux", "setup-button", "settings-button", "home-toolbar-settings"] {
            let b = app.buttons[id]
            XCTAssertTrue(b.waitForExistence(timeout: 10), id)
            XCTAssertFalse(b.label.isEmpty, "\(id) has no accessibility label")
        }
        XCTAssertTrue(app.buttons["panel-mac"].label.contains("Mac"))
    }

    func testLinuxBootsAlpineAndRunsCommands() {
        let app = XCUIApplication()
        app.launchArguments = ["-linux.root", "alpine"]
        app.launchEnvironment["TRIPTYCH_UI_TEST"] = "1"
        app.launch()
        app.buttons["engine-linux"].tap()
        app.buttons["linux-start"].tap()
        let out = app.descendants(matching: .any)["linux-output"]
        let input = out
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let promptDeadline = Date().addingTimeInterval(15)
        while Date() < promptDeadline && !(((out.value as? String) ?? "").contains("#")) { sleep(1) }
        input.tap()
        input.typeText("cat /etc/alpine-release; uname -m; echo node=$(uname -n) proc=$(cat /proc/sys/kernel/hostname) sh=$(hostname); echo sum=$((6*7)); ls /bin | head -3; echo DONE\n")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline && !(((out.value as? String) ?? "").contains("DONE\n") || ((out.value as? String) ?? "").hasSuffix("DONE") || ((out.value as? String) ?? "").components(separatedBy: "DONE").count > 2) { sleep(1) }
        checkDisplay(out, in: app, screenshot: "fullscreen-linux-terminal")
        let text = ((out.value as? String) ?? "")
        print("LINUX-OUTPUT-BEGIN\n\(text)\nLINUX-OUTPUT-END")
        XCTAssertTrue(text.contains("3.22"), "alpine-release")
        XCTAssertTrue(text.contains("aarch64"), "uname -m")
        XCTAssertTrue(text.contains("sum=42"), "shell arithmetic")
        // The guest has a fixed neutral host name, never the host's (in the Simulator, the Mac's name).
        XCTAssertTrue(text.contains("node=triptych proc=triptych sh=triptych"), "neutral host name")
        XCTAssertTrue(text.contains("triptych:"), "prompt shows the neutral host name")
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? ""
        if host.count > 2, host.lowercased() != "triptych", host.lowercased() != "localhost" {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(host), "the host's name reached the guest")
        }
    }

    /// The device's console path: iOS refuses apps a pseudo-terminal, so the console is a socket pair there.
    func testLinuxBootsWithSocketConsole() {
        let app = XCUIApplication()
        app.launchArguments = ["-linux.root", "alpine"]
        app.launchEnvironment["TRIPTYCH_UI_TEST"] = "1"
        app.launchEnvironment["TRIPTYCH_LINUX_NO_PTY"] = "1"
        app.launch()
        app.buttons["engine-linux"].tap()
        app.buttons["linux-start"].tap()
        let out = app.descendants(matching: .any)["linux-output"]
        XCTAssertTrue(out.waitForExistence(timeout: 10))
        let prompt = NSPredicate(format: "value CONTAINS %@", "#")
        guard XCTWaiter.wait(for: [expectation(for: prompt, evaluatedWith: out)], timeout: 15) == .completed else {
            XCTFail("The socket console did not show a shell prompt")
            return
        }
        out.tap()
        out.typeText("uname -m; echo sum=$((6*7)); stty size < /dev/tty && echo CONSOLE-''READY\n")
        // The marker only appears in command output, since its spelling in the input includes quotes.
        let ready = NSPredicate(format: "value CONTAINS %@", "CONSOLE-READY")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: ready, evaluatedWith: out)], timeout: 60), .completed)
        attach(app, "linux-socket-console")
        let text = (out.value as? String) ?? ""
        print("SOCKET-OUTPUT-BEGIN\n\(text)\nSOCKET-OUTPUT-END")
        XCTAssertTrue(text.contains("aarch64"), "uname -m")
        XCTAssertTrue(text.contains("sum=42"), "shell arithmetic")
        func terminalSize(_ output: String) -> [Int]? {
            output.split(separator: "\n").compactMap { line -> [Int]? in
                let dimensions = line.split(separator: " ").compactMap { Int($0) }
                return dimensions.count == 2 && line.allSatisfy { $0.isNumber || $0 == " " } ? dimensions : nil
            }.last
        }
        let size = terminalSize(text)
        XCTAssertNotNil(size, "controlling tty size")
        if let size {
            // SwiftTerm uses a 13-point monospaced cell. Allow for an integral row/column and font metrics.
            XCTAssertEqual(Double(size[0]), out.frame.height / 16, accuracy: 6)
            XCTAssertEqual(Double(size[1]), out.frame.width / 8, accuracy: 5)
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        checkDisplay(out, in: app, screenshot: "fullscreen-linux-terminal-landscape")
        out.tap()
        out.typeText("stty size; echo ROTATED-''READY\n")
        let rotated = NSPredicate(format: "value CONTAINS %@", "ROTATED-READY")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: rotated, evaluatedWith: out)], timeout: 15), .completed)
        if let landscape = terminalSize(out.value as? String ?? "") {
            XCTAssertGreaterThan(landscape[1], size?.last ?? 0, "columns should grow after rotation")
            XCTAssertLessThan(landscape[0], size?.first ?? 0, "rows should shrink after rotation")
        }
        out.typeText("exit 7\n")
        XCTAssertTrue(app.staticTexts["Exited (7)"].waitForExistence(timeout: 10))
    }

    /// Downloads Ubuntu Base (arm64, glibc) from cdimage.ubuntu.com, checks its sha256,
    /// imports it into fakefs and boots it. Needs the network.
    func testLinuxDownloadsUbuntuAndBootsIt() {
        installAndBootLinuxDistro(
            id: "ubuntu",
            installTimeout: 600,
            command: "grep PRETTY /etc/os-release; grep nameserver /etc/resolv.conf; ls /usr/bin/apt; ldd --version | head -1; echo DONE\n",
            screenshotName: "ubuntu",
            expected: ["Ubuntu", "nameserver", "/usr/bin/apt"]
        )
    }

    func testLinuxDownloadsAlpineLatestAndBootsIt() {
        installAndBootLinuxDistro(
            id: "alpine-latest",
            installTimeout: 180,
            command: "cat /etc/alpine-release; grep nameserver /etc/resolv.conf; apk update && echo APK-OK; echo DONE\n",
            screenshotName: "alpine-latest",
            expected: ["3.", "nameserver", "APK-OK"]
        )
    }

    func testLinuxDownloadsDebianAndBootsIt() {
        installAndBootLinuxDistro(
            id: "debian",
            installTimeout: 360,
            command: "grep PRETTY /etc/os-release; grep nameserver /etc/resolv.conf; ls -la /usr/share/man/man7/PAM.7.gz /usr/share/man/man7/pam.7.gz; ls /usr/bin/apt; echo DONE\n",
            screenshotName: "debian",
            expected: ["Debian", "nameserver", "2323", "pam.7.gz -> PAM.7.gz", "/usr/bin/apt"]
        )
    }

    func testLinuxDownloadsFedoraAndBootsIt() {
        installAndBootLinuxDistro(
            id: "fedora",
            installTimeout: 420,
            command: "grep PRETTY /etc/os-release; grep nameserver /etc/resolv.conf; ls /usr/share/terminfo/a /usr/share/terminfo/A >/dev/null && echo TERMINFO-OK; ls /usr/share/man/man2/_Exit.2.gz /usr/share/man/man2/_exit.2.gz; dnf --version | head -1; echo DONE\n",
            screenshotName: "fedora",
            expected: ["Fedora", "nameserver", "TERMINFO-OK", "_Exit.2.gz", "_exit.2.gz", "dnf5"]
        )
    }

    func testLinuxDownloadsArchAndBootsIt() {
        installAndBootLinuxDistro(
            id: "arch",
            installTimeout: 900,
            command: "grep NAME= /etc/os-release; grep nameserver /etc/resolv.conf; pacman --version | grep Pacman; echo DONE\n",
            screenshotName: "arch",
            expected: ["Arch Linux ARM", "nameserver", "Pacman"]
        )
    }

    func testLinuxImportsCustomZstdRootfsAndBootsIt() throws {
        let alpineData = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../build/resources/alpine-fs/data").standardized
        let busybox = alpineData.appendingPathComponent("bin/busybox")
        let musl = alpineData.appendingPathComponent("lib/ld-musl-aarch64.so.1")
        guard FileManager.default.fileExists(atPath: busybox.path),
              FileManager.default.fileExists(atPath: musl.path) else {
            throw XCTSkip("Starter alpine-fs binaries not present at \(alpineData.path)")
        }
        let archiveURL = URL(fileURLWithPath: "/tmp/triptych-custom-zst-\(UUID().uuidString).tar.zst")
        try Self.makeMinimalCustomTarZst(at: archiveURL, busybox: busybox, musl: musl)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let app = XCUIApplication()
        app.launchEnvironment = ["TRIPTYCH_IMPORT_ARCHIVE": archiveURL.path, "TRIPTYCH_UI_TEST": "1"]
        app.launch()
        app.buttons["engine-linux"].tap()
        app.buttons["linux-systems"].tap()
        let importBtn = app.buttons["distro-import-files"]
        XCTAssertTrue(importBtn.waitForExistence(timeout: 10))
        importBtn.tap()
        let status = app.staticTexts["distro-status"]
        let importDeadline = Date().addingTimeInterval(60)
        while Date() < importDeadline && !(status.exists && (status.label.lowercased().contains("imported") || status.label.lowercased().contains("failed"))) { sleep(1) }
        attach(app, "custom-zst-import")
        XCTAssertTrue(status.label.contains("imported"), status.label)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        runLinuxTerminalAndAssert(
            app: app,
            command: "cat /etc/custom-import; grep nameserver /etc/resolv.conf; cat /etc/CaseFile /etc/casefile; echo DONE\n",
            timeout: 60,
            screenshotName: "custom-zst",
            expected: ["CUSTOM_ZST_OK", "nameserver", "UPPER", "lower"]
        )
    }

    private func installAndBootLinuxDistro(id: String, installTimeout: TimeInterval, command: String,
                                           screenshotName: String, expected: [String]) {
        let app = XCUIApplication()
        app.launchEnvironment["TRIPTYCH_UI_TEST"] = "1"
        app.launch()
        app.buttons["engine-linux"].tap()
        app.buttons["linux-systems"].tap()
        let get = app.buttons["distro-get-\(id)"]
        if get.waitForExistence(timeout: 5) {
            get.tap()
            let status = app.staticTexts["distro-status"]
            let deadline = Date().addingTimeInterval(installTimeout)
            while Date() < deadline && !(status.exists && (status.label.lowercased().contains("installed") || status.label.lowercased().contains("failed"))) { sleep(2) }
            attach(app, "\(id)-install")
            XCTAssertTrue(status.label.contains("installed"), status.label)
        } else {
            let useBtn = app.buttons["distro-use-\(id)"]
            if useBtn.waitForExistence(timeout: 5) && useBtn.isEnabled { useBtn.tap() }
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        runLinuxTerminalAndAssert(app: app, command: command, timeout: 120, screenshotName: screenshotName, expected: expected)
    }

    private func runLinuxTerminalAndAssert(app: XCUIApplication, command: String, timeout: TimeInterval,
                                           screenshotName: String, expected: [String]) {
        app.buttons["linux-start"].tap()
        let out = app.descendants(matching: .any)["linux-output"]
        XCTAssertTrue(out.waitForExistence(timeout: 10))
        let promptDeadline = Date().addingTimeInterval(20)
        while Date() < promptDeadline && !(((out.value as? String) ?? "").contains("#")) { sleep(1) }
        out.tap()
        out.typeText(command)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && ((out.value as? String) ?? "").components(separatedBy: "DONE").count < 3 { sleep(1) }
        attach(app, screenshotName)
        let text = ((out.value as? String) ?? "")
        print("\(screenshotName.uppercased())-OUTPUT-BEGIN\n\(text)\n\(screenshotName.uppercased())-OUTPUT-END")
        for needle in expected {
            XCTAssertTrue(text.contains(needle), "Missing '\(needle)' in \(screenshotName) output")
        }
    }

    /// Builds a valid RFC 8878 raw-block .tar.zst rootfs containing Alpine's dynamic busybox + musl
    /// plus custom/case-colliding files so importFile + zstd + case_aliases are tested in-app.
    private static func makeMinimalCustomTarZst(at url: URL, busybox: URL, musl: URL) throws {
        var tar = Data()
        func appendTarEntry(path: String, typeflag: UInt8, mode: Int, data: Data = Data(), link: String = "") {
            var hdr = [UInt8](repeating: 0, count: 512)
            func put(_ str: String, at offset: Int, maxLen: Int) {
                for (i, b) in str.utf8.prefix(maxLen).enumerated() { hdr[offset + i] = b }
            }
            put(path, at: 0, maxLen: 100)
            put(String(format: "%07o", mode), at: 100, maxLen: 7)
            put("0000000", at: 108, maxLen: 7)
            put("0000000", at: 116, maxLen: 7)
            put(String(format: "%011o", data.count), at: 124, maxLen: 11)
            put("00000000000", at: 136, maxLen: 11)
            for i in 148..<156 { hdr[i] = 0x20 }
            hdr[156] = typeflag
            put(link, at: 157, maxLen: 100)
            put("ustar", at: 257, maxLen: 5)
            hdr[262] = 0
            hdr[263] = 0x30; hdr[264] = 0x30
            let sum = hdr.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", sum), at: 148, maxLen: 6)
            hdr[154] = 0; hdr[155] = 0x20
            tar.append(contentsOf: hdr)
            if !data.isEmpty {
                tar.append(data)
                let rem = data.count % 512
                if rem != 0 { tar.append(Data(count: 512 - rem)) }
            }
        }
        for d in ["./", "./bin/", "./lib/", "./etc/", "./tmp/", "./proc/", "./dev/"] {
            appendTarEntry(path: d, typeflag: 0x35, mode: 0o755)
        }
        appendTarEntry(path: "./bin/busybox", typeflag: 0x30, mode: 0o755, data: try Data(contentsOf: busybox))
        appendTarEntry(path: "./bin/sh", typeflag: 0x32, mode: 0o777, link: "busybox")
        appendTarEntry(path: "./bin/cat", typeflag: 0x32, mode: 0o777, link: "busybox")
        appendTarEntry(path: "./bin/grep", typeflag: 0x32, mode: 0o777, link: "busybox")
        appendTarEntry(path: "./lib/ld-musl-aarch64.so.1", typeflag: 0x30, mode: 0o755, data: try Data(contentsOf: musl))
        appendTarEntry(path: "./lib/libc.musl-aarch64.so.1", typeflag: 0x32, mode: 0o777, link: "ld-musl-aarch64.so.1")
        appendTarEntry(path: "./etc/custom-import", typeflag: 0x30, mode: 0o644, data: Data("CUSTOM_ZST_OK\n".utf8))
        appendTarEntry(path: "./etc/CaseFile", typeflag: 0x30, mode: 0o644, data: Data("UPPER\n".utf8))
        appendTarEntry(path: "./etc/casefile", typeflag: 0x30, mode: 0o644, data: Data("lower\n".utf8))
        tar.append(Data(count: 1024))

        var zst = Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58])
        var offset = 0
        while offset < tar.count {
            let end = min(offset + 131_072, tar.count)
            let chunk = tar[offset..<end]
            offset = end
            let last = (offset == tar.count) ? 1 : 0
            let hdr = (chunk.count << 3) | last
            zst.append(contentsOf: [UInt8(hdr & 0xff), UInt8((hdr >> 8) & 0xff), UInt8((hdr >> 16) & 0xff)])
            zst.append(chunk)
        }
        try zst.write(to: url)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}

final class TriptychMacTests: XCTestCase {
    func testMacEngineLinksAndProbesJIT() {
        let app = XCUIApplication(); app.launch()
        let macBtn = app.buttons["engine-macos"]
        for _ in 0..<4 where !macBtn.isHittable { app.swipeUp() }
        XCTAssertTrue(macBtn.waitForExistence(timeout: 10))
        macBtn.tap()
        let sample = app.buttons["macos-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 15))
        for _ in 0..<4 where !sample.isHittable { app.swipeUp() }
        sample.tap()
        XCTAssertTrue(app.buttons["macos-run"].waitForExistence(timeout: 10))
        app.buttons["macos-run"].tap()
        let out = app.staticTexts["macos-output"]
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline && !out.label.contains("exit=") { sleep(1) }
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "macos"; a.lifetime = .keepAlways; add(a)
        print("MACOS-OUTPUT-BEGIN\n\(out.label)\nMACOS-OUTPUT-END")
        XCTAssertTrue(out.label.contains("selftest=0"), "engine links and runs")
        // The Simulator grants MAP_JIT but refuses a writable alias of it, which Henge's
        // split-mode JIT needs, so the program itself only runs on a device.
        XCTAssertTrue(out.label.contains("mapjit=1") || out.label.contains("PASS hello"), "JIT probe ran")
    }
}

final class TriptychAtelierUITests: XCTestCase {
    /// Triptych's hinged panels, Mac system page (with Install macOS), shared Setup, and Settings.
    func testAtelierShowsMacOSInstallAndEasel() {
        let app = XCUIApplication(); app.launch()
        let shotDir = ProcessInfo.processInfo.environment["TRIPTYCH_SHOT_DIR"]
        func saveShot(_ name: String) {
            let shot = app.screenshot()
            let a = XCTAttachment(screenshot: shot); a.name = name; a.lifetime = .keepAlways; add(a)
            if let shotDir {
                try? shot.pngRepresentation.write(to: URL(fileURLWithPath: shotDir).appendingPathComponent("\(name).png"))
            }
        }

        // Home: three hinged panels
        for id in ["panel-windows", "panel-mac", "panel-linux"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10), id)
        }
        saveShot("20261121-triptych-home")

        // Open Mac panel -> MacSystemView -> Install macOS
        app.buttons["panel-mac"].tap()
        XCTAssertTrue(app.navigationBars["Atelier · macOS"].waitForExistence(timeout: 10), "Mac system page")
        saveShot("20261121-triptych-mac-system")
        let installBtn = app.buttons["mac-install-button"]
        XCTAssertTrue(installBtn.waitForExistence(timeout: 10), "Install macOS button")
        installBtn.tap()
        XCTAssertTrue(app.navigationBars["Install macOS"].waitForExistence(timeout: 10), "Install macOS screen")
        saveShot("20261121-triptych-mac-install")

        // Back to Home -> Setup -> Settings
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let setupBtn = app.buttons["home-toolbar-setup"]
        XCTAssertTrue(setupBtn.waitForExistence(timeout: 10))
        setupBtn.tap()
        XCTAssertTrue(app.navigationBars["Easel · Setup"].waitForExistence(timeout: 10), "Shared Setup screen")
        XCTAssertTrue(app.otherElements["setup-jit-pill"].exists || app.staticTexts["setup-jit-pill"].exists || app.buttons["setup-pick-win-iso"].waitForExistence(timeout: 5))
        saveShot("20261121-triptych-setup")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let settingsBtn = app.buttons["home-toolbar-settings"]
        XCTAssertTrue(settingsBtn.waitForExistence(timeout: 10))
        settingsBtn.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Shared Settings screen")
        XCTAssertTrue(app.staticTexts["settings-jit-status"].waitForExistence(timeout: 5))
        saveShot("20261121-triptych-settings")
    }
}

final class TriptychWinPCTests: XCTestCase {
    func testWindowsPCPageHasPickerAndStart() {
        let app = XCUIApplication(); app.launch()
        app.buttons["engine-winpc"].tap()
        XCTAssertTrue(app.buttons["winpc-pick-iso"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["winpc-start"].exists)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "winpc-setup"; a.lifetime = .keepAlways; add(a)
    }

    /// The picked ISO survives a relaunch (security-scoped bookmark), so users don't pick a 5 GB ISO again every time.
    func testWindowsPCRemembersISOAcrossLaunches() {
        let file = URL(fileURLWithPath: #filePath)                 // any existing file stands in for the ISO
        let app = XCUIApplication(); app.launchArguments = ["-winpc.iso", file.path]; app.launch()
        app.buttons["engine-winpc"].tap()
        let pick = app.buttons["winpc-pick-iso"]
        XCTAssertTrue(pick.waitForExistence(timeout: 10))
        XCTAssertEqual(pick.label, file.lastPathComponent)
        app.terminate()
        let again = XCUIApplication(); again.launch()               // no hook this time: the bookmark must bring it back
        again.buttons["engine-winpc"].tap()
        let pick2 = again.buttons["winpc-pick-iso"]
        XCTAssertTrue(pick2.waitForExistence(timeout: 10))
        XCTAssertEqual(pick2.label, file.lastPathComponent, "the ISO was forgotten after a relaunch")
    }

    /// The user's own Windows 11 ARM64 ISO boots to Setup in the app with nobody pressing a key: the board answers
    /// cdboot's "Press any key to boot from CD or DVD" on a blank disk. Runs only when TRIPTYCH_WIN_ISO names an ISO
    /// (xcodebuild: TEST_RUNNER_TRIPTYCH_WIN_ISO=...); the ISO is read in place, never copied. Uses a fresh disk.
    func testWindowsPCBootsInstallerISOToSetup() throws {
        guard let iso = ProcessInfo.processInfo.environment["TRIPTYCH_WIN_ISO"], FileManager.default.fileExists(atPath: iso) else {
            throw XCTSkip("set TRIPTYCH_WIN_ISO to a Windows 11 ARM64 ISO")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-winpc.iso", iso, "-winpc.ram", "4096", "-winpc.freshdisk", "-winpc.autostart"]
        app.launchEnvironment = ["WINVM_SERIAL_LOG": "1"]
        app.launch()
        app.buttons["engine-winpc"].tap()
        let d = app.descendants(matching: .any)["winpc-display"]
        XCTAssertTrue(d.waitForExistence(timeout: 30))
        func isoMB() -> Int { let v = (d.value as? String) ?? ""; return v.range(of: "isoMB=").map { Int(v[$0.upperBound...].prefix { $0.isNumber }) ?? 0 } ?? 0 }
        // Setup's boot.wim is several hundred MB: past 300 MB, cdboot's prompt was answered and WinPE is loading.
        let deadline = Date().addingTimeInterval(1500)
        while Date() < deadline && isoMB() < 300 { sleep(10) }
        print("WINPC-ISO \((d.value as? String) ?? "")")
        XCTAssertGreaterThanOrEqual(isoMB(), 300, "the installer never loaded: \((d.value as? String) ?? "")")
        sleep(UInt32(ProcessInfo.processInfo.environment["TRIPTYCH_WIN_ISO_SETTLE"].flatMap { UInt32($0) } ?? 600))
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "winpc-setup-from-iso"; a.lifetime = .keepAlways; add(a)
    }

    /// Starts the board without an ISO: EDK2's firmware must draw its ramfb on the page.
    func testWindowsPCStopsAndStartsAgain() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-winpc.noiso", "-winpc.freshdisk", "-winpc.ram", "1024"]
        app.launch()
        app.buttons["engine-winpc"].tap()
        let start = app.buttons["winpc-start"]
        let display = app.descendants(matching: .any)["winpc-display"]

        for _ in 0..<2 {
            XCTAssertTrue(start.waitForExistence(timeout: 20))
            start.tap()
            let frames = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'frames='"), object: display)
            XCTAssertEqual(XCTWaiter.wait(for: [frames], timeout: 90), .completed)
            sessionButton("winpc-stop", in: app).tap()
            XCTAssertTrue(start.waitForExistence(timeout: 30))
            XCTAssertEqual(app.staticTexts["winpc-status"].label, "Stopped")
            XCTAssertFalse(display.exists)
        }
    }

    func testWindowsPCBootsFirmwareAndShowsDisplay() {
        let app = XCUIApplication(); app.launchArguments = ["-winpc.autostart", "1", "-winpc.noiso"]; app.launchEnvironment = ["WINVM_DEBUG": "1"]; app.launch()
        app.buttons["engine-winpc"].tap()
        let d = app.descendants(matching: .any)["winpc-display"]
        XCTAssertTrue(d.waitForExistence(timeout: 20))
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline && !(((d.value as? String) ?? "").contains("frames=")) { sleep(2) }
        sleep(20) // let EDK2 reach its boot manager
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "winpc-display"; a.lifetime = .keepAlways; add(a)
        print("WINPC-DISPLAY \((d.value as? String) ?? "")")
        XCTAssertTrue(((d.value as? String) ?? "").contains("frames="), "guest display")
        checkDisplay(d, in: app, screenshot: "fullscreen-casement")
        let dims = framebufferSize(d)
        XCTAssertEqual(dims.count, 2)
        if dims.count == 2 { checkGuestAspect(dims[0], dims[1], display: d) }
        // TPM 2.0 (libtpms + OpenSSL built for iOS): EDK2's Tcg2 driver must have sent it commands (Startup, SelfTest, PCR extends).
        let v = (d.value as? String) ?? ""
        let tpm = v.range(of: "tpm=").map { Int(v[$0.upperBound...].prefix { $0.isNumber }) ?? 0 } ?? 0
        XCTAssertGreaterThan(tpm, 0, "the firmware never used the TPM: \(v)")
    }
}

final class TriptychSharedLaunchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLinuxAndWindowsPCShareLaunch() {
        checkBothOrders(engine: "winpc", arguments: ["-winpc.noiso", "-winpc.ram", "1024"]) { app in
            app.buttons["winpc-start"].tap()
            self.waitForFrames(app, display: "winpc-display")
        }
    }

    func testLinuxAndMacAppsShareLaunch() {
        checkBothOrders(engine: "macapps") { app in
            let sample = app.buttons["macapp-TestMacApp"]
            if !sample.exists { app.buttons["macapps-import-sample"].tap() }
            XCTAssertTrue(sample.waitForExistence(timeout: 20))
            sample.tap()
            let button = app.buttons["NSButton"]
            XCTAssertTrue(button.waitForExistence(timeout: 20))
            button.tap()
            let clicked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Click Me (1)'"), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [clicked], timeout: 10), .completed)
            sessionButton("macapp-close", in: app).tap()
        }
    }

    func testLinuxAndX86PCShareLaunch() {
        checkBothOrders(engine: "x86pc", arguments: ["-x86pc.autostart", "-x86pc.noiso", "-x86pc.ram", "256"]) { app in
            self.waitForFrames(app, display: "x86pc-display")
        }
    }

    private func checkBothOrders(engine: String, arguments: [String] = [], verify: (XCUIApplication) -> Void) {
        for linuxFirst in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-linux.root", "alpine"] + arguments
            app.launchEnvironment["TRIPTYCH_UI_TEST"] = "1"
            app.launch()
            if linuxFirst {
                app.buttons["engine-linux"].tap()
                app.buttons["linux-start"].tap()
                checkShell(app, expression: "6*7", result: "42")
                goHome(app)
            }

            app.buttons["engine-\(engine)"].tap()
            verify(app)
            goHome(app)
            app.buttons["engine-linux"].tap()
            if !linuxFirst { app.buttons["linux-start"].tap() }
            checkShell(app, expression: "8*9", result: "72")
            app.terminate()
        }
    }

    private func goHome(_ app: XCUIApplication) {
        if app.buttons["session-controls"].exists {
            sessionButton("session-back", in: app).tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.buttons["engine-linux"].waitForExistence(timeout: 10))
    }

    private func checkShell(_ app: XCUIApplication, expression: String, result: String) {
        let terminal = app.descendants(matching: .any)["linux-output"]
        let prompt = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '#'"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [prompt], timeout: 30), .completed)
        terminal.tap()
        terminal.typeText("echo SHARED_$((\(expression)))_OK\n")
        let output = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "SHARED_\(result)_OK"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [output], timeout: 30), .completed)
    }

    private func waitForFrames(_ app: XCUIApplication, display: String) {
        let view = app.descendants(matching: .any)[display]
        let frames = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'frames='"), object: view)
        XCTAssertEqual(XCTWaiter.wait(for: [frames], timeout: 90), .completed)
    }
}

final class TriptychX86PCTests: XCTestCase {
    /// The Alpine ISO fetched by scripts/build-x86pc.sh (build/x86pc/downloads), found from this file's location.
    static var alpineISO: String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return ProcessInfo.processInfo.environment["TRIPTYCH_X86PC_ISO"]
            ?? repo.appendingPathComponent("build/x86pc/downloads/alpine-standard-3.22.2-x86_64.iso").path
    }

    func testX86PCPageHasControlsAndBanner() {
        let app = XCUIApplication(); app.launch()
        app.buttons["engine-x86pc"].tap()
        XCTAssertTrue(app.staticTexts["x86pc-banner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["x86pc-pick-iso"].exists)
        let start = app.buttons["x86pc-start"]
        for _ in 0..<4 where !start.exists { app.swipeUp() }   // the Form is lazy: Start sits below the hardware rows
        XCTAssertTrue(start.exists)
        XCTAssertTrue(app.switches["x86pc-net-toggle"].exists || app.switches["x86pc-net-toggle"].waitForExistence(timeout: 2))
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "x86pc-setup"; a.lifetime = .keepAlways; add(a)
    }

    /// Boots the Alpine x86-64 ISO on QEMU in the app (BIOS, NAT network) and waits for "localhost login:" on serial.
    func testX86PCBootsAlpineToLoginWithSlirp() {
        let iso = Self.alpineISO
        XCTAssertTrue(FileManager.default.fileExists(atPath: iso), "missing \(iso)")
        let app = XCUIApplication()
        app.launchArguments = ["-x86pc.autostart", "-x86pc.iso", iso]
        app.launch()
        app.buttons["engine-x86pc"].tap()                     // autostart runs when the page appears
        sessionButton("x86pc-console", in: app).tap()
        let status = app.staticTexts["x86pc-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 60))
        let net = app.staticTexts["x86pc-net"]
        let deadline = Date().addingTimeInterval(420)
        while Date() < deadline && !((status.label).contains("login:")) { sleep(3) }
        XCTAssertTrue(status.label.contains("login:"), "serial login: \(status.label)")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "x86pc-alpine-login"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(app.descendants(matching: .any)["x86pc-display"].exists)
        XCTAssertTrue(net.waitForExistence(timeout: 5), "network line on the running page")
        XCTAssertTrue(net.label.contains("virtio-net-pci"), "slirp network: \(net.label)")
        // The display backend delivered frames (not a black placeholder).
        let disp = app.descendants(matching: .any)["x86pc-display"]
        XCTAssertTrue((disp.value as? String ?? "").contains("frames="), "framebuffer frames: \(String(describing: disp.value))")
        sessionButton("x86pc-console", in: app).tap()
        checkDisplay(disp, in: app, screenshot: "fullscreen-x86pc")
        print("X86PC-DISPLAY \(disp.value as? String ?? "")")
        let dims = framebufferSize(disp)
        XCTAssertEqual(dims.count, 2)
        if dims.count == 2 { checkGuestAspect(dims[0], dims[1], display: disp) }
    }

    /// Typing through the page goes HID usage -> QKeyCode -> guest: log in as root on the Alpine serial console, then
    /// make the shell write an arithmetic result to the serial port (keys reach the VGA console, so the echo is not on serial); it only appears there if the keys arrived intact.
    func testX86PCKeyboardReachesTheGuest() {
        let iso = Self.alpineISO
        XCTAssertTrue(FileManager.default.fileExists(atPath: iso), "missing \(iso)")
        let app = XCUIApplication()
        app.launchArguments = ["-x86pc.autostart", "-x86pc.iso", iso]
        app.launch()
        app.buttons["engine-x86pc"].tap()
        sessionButton("x86pc-console", in: app).tap()
        let status = app.staticTexts["x86pc-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 60))
        var deadline = Date().addingTimeInterval(420)
        while Date() < deadline && !status.label.contains("login:") { sleep(3) }
        XCTAssertTrue(status.label.contains("login:"), "serial login: \(status.label)")
        let field = app.textFields["x86pc-type"]
        field.tap(); field.typeText("root\n")
        sleep(8)
        field.tap(); field.typeText("echo TRIPTYCH_$((40+2))_OK > /dev/ttyS0\n")
        let serial = app.staticTexts["x86pc-serial"]
        deadline = Date().addingTimeInterval(60)
        while Date() < deadline && !serial.label.contains("TRIPTYCH_42_OK") { sleep(2) }
        XCTAssertTrue(serial.label.contains("TRIPTYCH_42_OK"), "typed command ran in the guest: \(serial.label)")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "x86pc-alpine-keyboard"; a.lifetime = .keepAlways; add(a)
    }

    /// UEFI Linux Mint 22.3 Xfce live ISO (TRIPTYCH_MINT_ISO or build/x86pc/isos): the page returns past GRUB and the
    /// guest display delivers frames. Slow: Mint takes minutes to reach its desktop on TCG in the Simulator.
    func testX86PCBootsLinuxMintUEFI() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let iso = ProcessInfo.processInfo.environment["TRIPTYCH_MINT_ISO"]
            ?? repo.appendingPathComponent("build/x86pc/isos/linuxmint-22.3-xfce-64bit.iso").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: iso), "no Linux Mint ISO at \(iso)")
        let app = XCUIApplication()
        app.launchArguments = ["-x86pc.autostart", "-x86pc.iso", iso, "-x86pc.uefi", "1", "-x86pc.ram", "4096"]
        app.launch()
        app.buttons["engine-x86pc"].tap()
        sessionButton("x86pc-console", in: app).tap()
        XCTAssertTrue(app.staticTexts["x86pc-status"].waitForExistence(timeout: 60))
        let disp = app.descendants(matching: .any)["x86pc-display"]
        XCTAssertTrue(disp.waitForExistence(timeout: 30))
        let deadline = Date().addingTimeInterval(1500)
        var frames = 0
        while Date() < deadline {
            let v = (disp.value as? String) ?? ""
            if let r = v.range(of: "frames="), let n = Int(v[r.upperBound...]) { frames = n }
            if frames >= 40 { break }
            sleep(5)
        }
        XCTAssertGreaterThan(frames, 0, "display frames from the UEFI guest: \(String(describing: disp.value))")
        // Touch goes in through virtio-tablet-pci: a tap and a drag must be accepted and the guest display keeps updating.
        disp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        disp.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: disp.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        sleep(10)
        let v2 = (disp.value as? String) ?? ""
        var frames2 = frames
        if let r = v2.range(of: "frames="), let n = Int(v2[r.upperBound...]) { frames2 = n }
        XCTAssertGreaterThanOrEqual(frames2, frames, "display after touch: \(v2)")
        let shot = app.screenshot()
        let a = XCTAttachment(screenshot: shot); a.name = "x86pc-mint-uefi"; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["TRIPTYCH_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("x86pc-mint-uefi.png"))
        }
        // Quit stops QEMU through x86pc_host_stop() and the page returns to its setup form.
        sessionButton("x86pc-quit", in: app).tap()
        let start = app.buttons["x86pc-start"]
        for _ in 0..<4 where !start.waitForExistence(timeout: 30) { app.swipeUp() }
        XCTAssertTrue(start.exists, "setup form after Quit")
    }
}

final class TriptychMacAppsTests: XCTestCase {
    /// macpkg extracts the bundled sample zip into the library, the list shows it, and tapping it runs the guest on the AppKit shim.
    func testImportSampleListsAndLaunchesMacApp() {
        let app = XCUIApplication(); app.launch()
        app.buttons["engine-macapps"].tap()
        XCTAssertTrue(app.buttons["macapps-import"].waitForExistence(timeout: 10))
        app.buttons["macapps-import-sample"].tap()
        let row = app.buttons["macapp-TestMacApp"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "imported app is listed")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "macapps-list"; a.lifetime = .keepAlways; add(a)
        if !row.isHittable { print("HIER", app.debugDescription) }
        row.tap()
        let title = app.staticTexts["NSWindowTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "guest NSWindow")
        let button = app.buttons["NSButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.label.contains("Click Me"), button.label)
        button.tap()
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Click Me (1)'"), object: button)
        wait(for: [exp], timeout: 5)
        let window = app.descendants(matching: .any)["mac-app-window"]
        sessionButton("macapp-stop", in: app).tap()
        XCTAssertTrue(app.buttons["Restart Triptych"].waitForExistence(timeout: 5))
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        }
        checkDisplay(window, in: app, screenshot: "fullscreen-mac-apps")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        checkDisplay(window, in: app, screenshot: "fullscreen-mac-apps-landscape")
    }
}

extension TriptychMacAppsTests {
    /// A Mac-built (not retagged) app imports, gets retagged and ad-hoc signed in process, and launches.
    func testMacBuiltAppIsRetaggedOnImportAndLaunches() {
        let app = XCUIApplication(); app.launch()
        app.buttons["engine-macapps"].tap()
        XCTAssertTrue(app.buttons["macapps-import-mac-sample"].waitForExistence(timeout: 10))
        app.buttons["macapps-import-mac-sample"].tap()
        let row = app.buttons["macapp-MacBuiltApp"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "imported app is listed")
        XCTAssertTrue(row.isEnabled, "retag + sign must have made it launchable")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "macapps-macbuilt-list"; a.lifetime = .keepAlways; add(a)
        if !row.isHittable { print("HIER", app.debugDescription) }
        row.tap()
        XCTAssertTrue(app.staticTexts["NSWindowTitle"].waitForExistence(timeout: 30), "guest NSWindow")
        let button = app.buttons["NSButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Click Me (1)'"), object: button)
        wait(for: [exp], timeout: 5)
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "macapps-macbuilt-running"; b.lifetime = .keepAlways; add(b)
    }

    func testCrossOverPreviewImportsAndLaunches() throws {
        try launchCrossOverPreview(requireLicensedWindow: false)
    }

    func testCrossOverPreviewStartsWithDeviceLoader() throws {
        try launchCrossOverPreview(requireLicensedWindow: false, forceTL: true)
    }

    func testCrossOverPreviewUnlockRevealsRegistration() throws {
        try launchCrossOverPreview(requireLicensedWindow: false, testUnlock: true)
    }

    /// Run on the provisioned Simulator with parallel testing disabled.
    func testCrossOverPreviewOpensSteamCatalogEntry() throws {
        guard ProcessInfo.processInfo.environment["TRIPTYCH_CROSSOVER_REQUIRE_LICENSE"] == "1" else {
            throw XCTSkip("Licensed launch requires an explicitly provisioned Simulator")
        }
        try launchCrossOverPreview(requireLicensedWindow: true)
    }

    /// CrossOver creates a bottle from its own UI; cxbottle runs in Triptych's Perl (PerlCommand.c) and its Wine
    /// commands reach Pane (PaneWineCommand.c). In the Simulator Pane's Wine isn't loaded, so that is where it stops.
    func testCrossOverCreatesBottleThroughPane() throws {
        guard ProcessInfo.processInfo.environment["TRIPTYCH_CROSSOVER_REQUIRE_LICENSE"] == "1" else {
            throw XCTSkip("Licensed launch requires an explicitly provisioned Simulator")
        }
        // A bottle left by an earlier run changes CrossOver's first screen; start without one and leave none.
        Self.removeCrossOverBottle("Steam")
        addTeardownBlock { Self.removeCrossOverBottle("Steam") }
        let app = try launchLicensedCrossOver()
        attachShot(app, "crossover-bottle-0-main")
        let search = app.searchFields["Search"].firstMatch
        if search.waitForExistence(timeout: 5) { search.typeText("Steam") }
        let steam = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Steam,")).firstMatch
        XCTAssertTrue(steam.waitForExistence(timeout: 15), "Steam in CrossOver's catalog")
        steam.tap()
        let install = app.buttons.matching(NSPredicate(format: "label == %@", "Install")).firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 30), "Steam's install page")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "bottle named 'Steam'")).firstMatch.exists)
        XCTAssertTrue(install.isHittable, "CrossOver's window fits the screen")
        attachShot(app, "crossover-bottle-1-steam-page")
        install.tap()

        // CrossOver runs `cxbottle --bottle Steam --create` (Triptych's Perl), whose template setup runs CrossOver's
        // `wine` wrapper (Perl again), which runs the Wine loader in Pane. The app's log for the Mac app records each.
        let log = Self.macAppLog("CrossOver Preview")
        var text = ""
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline && !text.contains("PaneWineCommand: wine") {
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            text = log.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        }
        attachShot(app, "crossover-bottle-2-after-install")
        let lines = text.split(separator: "\n").filter {
            $0.hasPrefix("PerlCommand:") || $0.hasPrefix("PaneWineCommand:") || $0.contains("Creating the Steam bottle")
        }
        let trace = XCTAttachment(string: lines.joined(separator: "\n"))
        trace.name = "crossover-bottle-commands"
        trace.lifetime = .keepAlways
        add(trace)
        XCTAssertNotNil(log, "the Mac app's log")
        XCTAssertTrue(lines.contains { $0.hasPrefix("PerlCommand:") && $0.contains("/bin/cxbottle --bottle") }, "cxbottle ran in Perl")
        XCTAssertTrue(lines.contains { $0.hasPrefix("PerlCommand:") && $0.contains("/bin/wine") }, "CrossOver's wine wrapper ran in Perl")
        XCTAssertTrue(lines.contains { $0.hasPrefix("PaneWineCommand: wine") && $0.contains("Bottles/Steam") }, "Wine reached Pane for the Steam bottle")
        let bottleConf = log?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CrossOver/Bottles/Steam/cxbottle.conf")
        XCTAssertTrue(bottleConf.map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "CrossOver created the bottle")
    }

    /// Before the bottle existed it was CrossOver that made it; record that, then remove it.
    private static func removeCrossOverBottle(_ name: String) {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let fm = FileManager.default
        for c in (try? fm.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)) ?? [] {
            let bottle = c.appendingPathComponent("Library/Application Support/CrossOver/Bottles/\(name)")
            if fm.fileExists(atPath: bottle.path) {
                print("CrossOver bottle \(name): \((try? fm.contentsOfDirectory(atPath: bottle.path)) ?? [])")
                try? fm.removeItem(at: bottle)
            }
        }
    }

    /// <data container>/Library/Application Support/MacApps/<name>.log of the app under test (a sibling of the runner's
    /// container in the Simulator), the most recently written one.
    private static func macAppLog(_ name: String) -> URL? {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let fm = FileManager.default
        let candidates = (try? fm.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)) ?? []
        return candidates
            .map { $0.appendingPathComponent("Library/Application Support/MacApps/\(name).log") }
            .filter { fm.fileExists(atPath: $0.path) }
            .max {
                let a = (try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? .distantPast
                let b = (try? fm.attributesOfItem(atPath: $1.path)[.modificationDate] as? Date) ?? .distantPast
                return a < b
            }
    }

    private func attachShot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launchLicensedCrossOver() throws -> XCUIApplication {
        let zip = ProcessInfo.processInfo.environment["TRIPTYCH_CROSSOVER_ZIP"]
            ?? (NSHomeDirectory().components(separatedBy: "/Library/Developer").first ?? "") + "/Downloads/crossover-preview-arm64.zip"
        guard FileManager.default.fileExists(atPath: zip) else { throw XCTSkip("No local CrossOver Preview zip") }
        let app = XCUIApplication()
        let name = "CrossOver Preview"
        app.launchEnvironment["TRIPTYCH_MACAPPS_IMPORT"] = zip
        app.launchEnvironment["TRIPTYCH_MACAPPS_IMPORT_NAME"] = name
        app.launch()
        app.buttons["engine-macapps"].tap()
        let row = app.buttons["macapp-\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 240) && row.isEnabled, "CrossOver must be imported and launchable")
        row.tap()
        let main = app.staticTexts["Popular Applications"]
        XCTAssertTrue(main.waitForExistence(timeout: 90), "CrossOver's licensed main window")
        return app
    }

    private func launchCrossOverPreview(requireLicensedWindow: Bool, testUnlock: Bool = false, forceTL: Bool = false) throws {
        let zip = ProcessInfo.processInfo.environment["TRIPTYCH_CROSSOVER_ZIP"]
            ?? (NSHomeDirectory().components(separatedBy: "/Library/Developer").first ?? "") + "/Downloads/crossover-preview-arm64.zip"
        guard FileManager.default.fileExists(atPath: zip) else {
            if requireLicensedWindow {
                XCTFail("Licensed launch requires a local CrossOver Preview zip")
                return
            }
            throw XCTSkip("No local CrossOver Preview zip")
        }

        let app = XCUIApplication()
        let name = "CrossOver Preview"
        if forceTL { app.launchEnvironment["TRIPTYCH_FORCE_TL"] = "1" }
        // Each loader must import its own copy. The Simulator's dlopen import retags the fixture.
        app.launchEnvironment["TRIPTYCH_MACAPPS_REIMPORT"] = "1"
        app.launchEnvironment["TRIPTYCH_MACAPPS_IMPORT"] = zip
        app.launchEnvironment["TRIPTYCH_MACAPPS_IMPORT_NAME"] = name
        app.launch()
        app.buttons["engine-macapps"].tap()
        let message = app.staticTexts["macapps-message"]
        let imported = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "Imported:"),
            object: message
        )
        guard XCTWaiter.wait(for: [imported], timeout: 240) == .completed else {
            XCTFail("The CrossOver fixture must be imported with the selected loader")
            return
        }
        let row = app.buttons["macapp-\(name)"]
        guard row.waitForExistence(timeout: 240), row.isEnabled else {
            XCTFail("CrossOver must be imported and launchable")
            return
        }
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "crossover-list"; a.lifetime = .keepAlways; add(a)
        row.tap()
        let status = app.staticTexts["host-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let running = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "Running"), object: status)
        guard XCTWaiter.wait(for: [running], timeout: 30) == .completed else {
            XCTFail("CrossOver guest entry point did not start")
            return
        }

        if forceTL { XCTAssertTrue(status.label.contains("(tl_loader)")) }
        let trial = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Unlock with Purchase Info")).firstMatch
        let mainWindow = app.staticTexts["Popular Applications"]
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline && !mainWindow.exists && !trial.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if requireLicensedWindow {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "crossover-licensed-window-check"
            shot.lifetime = .keepAlways
            add(shot)
            guard mainWindow.exists, !trial.exists else {
                XCTFail("CrossOver did not reach its licensed main window (trial dialog: \(trial.exists))")
                return
            }
        } else {
            XCTAssertTrue(mainWindow.exists || trial.exists, "CrossOver must draw its main window or trial dialog")
        }
        print("CrossOver window markers: main=\(mainWindow.exists), trial=\(trial.exists)")
        XCTAssertFalse(app.staticTexts["Install Rosetta"].exists, "Rosetta prompt")
        XCTAssertFalse(app.buttons["Install"].exists, "Rosetta prompt")
        XCTAssertFalse(app.buttons["Check Automatically"].exists, "Sparkle prompt")
        if testUnlock {
            guard trial.exists else { throw XCTSkip("Unlock requires an unlicensed Simulator") }
            trial.tap()
            let passwordField = app.secureTextFields.firstMatch
            XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Unlock must reveal the registration form")
            XCTAssertTrue(passwordField.isHittable, "The sheet's controls must be reachable")
            // Typing must reach CrossOver's form (two-way bindings): Unlock is enabled only once both fields
            // hold text. Synthetic values only; the test never taps Unlock, so nothing is sent to CodeWeavers.
            let unlock = app.buttons.matching(NSPredicate(format: "label == %@", "Unlock")).firstMatch
            XCTAssertTrue(unlock.waitForExistence(timeout: 5), "Unlock button")
            XCTAssertFalse(unlock.isEnabled, "Unlock waits for the login and password")
            let login = app.textFields.firstMatch
            XCTAssertTrue(login.waitForExistence(timeout: 5))
            login.tap(); login.typeText("tester@example.invalid")
            let visiblePassword = app.secureTextFields.allElementsBoundByIndex.first { $0.isHittable } ?? passwordField
            visiblePassword.tap(); visiblePassword.typeText("synthetic-password")
            let typed = (visiblePassword.value as? String) ?? ""
            print("password field value length \(typed.count), secure fields \(app.secureTextFields.count)")
            XCTAssertFalse(typed.isEmpty || typed == visiblePassword.placeholderValue, "password dots show what was typed")
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: unlock)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "typed details reach CrossOver and enable Unlock")
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "crossover-unlock-filled"; shot.lifetime = .keepAlways; add(shot)
            let cancel = app.buttons.matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch
            guard cancel.waitForExistence(timeout: 5) else {
                XCTFail("Registration must offer Cancel")
                return
            }
            cancel.tap()
            XCTAssertTrue(trial.waitForExistence(timeout: 10), "Cancel must restore the trial dialog")
            XCTAssertFalse(passwordField.exists)
        }
        if requireLicensedWindow {
            let install = app.buttons["Install a Windows Application"].firstMatch
            guard install.waitForExistence(timeout: 15), install.isHittable else {
                XCTFail("CrossOver must offer Install a Windows Application")
                return
            }
            install.tap()
            let steam = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Steam")
            ).firstMatch
            let found = steam.waitForExistence(timeout: 30)
            if found && steam.isHittable { steam.tap() }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "crossover-steam-catalog"
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertTrue(found, "Steam must appear in CrossOver's application catalog")
            return
        }
        // CrossOver's first window here is its fixed-size trial dialog: it is shown at its own size, centered,
        // with its title bar (as on a Mac); resizable windows fill the screen.
        let window = app.descendants(matching: .any)["mac-app-window"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let screen = app.windows.firstMatch.frame
        XCTAssertEqual(window.frame.midX, screen.midX, accuracy: 2, "dialog centered")
        XCTAssertEqual(window.frame.midY, screen.midY, accuracy: 2, "dialog centered")
        XCTAssertFalse(app.navigationBars.firstMatch.isHittable, "session navigation bar hidden")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "fullscreen-crossover"; shot.lifetime = .keepAlways; add(shot)
    }
}

/// Linux desktop: Ubuntu 26.04 with Xfce (build/linux/ubuntu-fs, made by engines/linux-desktop/proto) is cloned in,
/// booted, and Xfce started from the Desktop tab; the desktop must show in the Metal canvas and the input agent connect.
final class TriptychLinuxDesktopTests: XCTestCase {
    func testXfceDesktopShows() throws {
        let seed = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../build/linux/ubuntu-fs").standardized
        guard FileManager.default.fileExists(atPath: seed.appendingPathComponent("data/usr/bin/xfce4-session").path) else {
            throw XCTSkip("no Xfce rootfs at \(seed.path)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-linux.root", "fullscreen-xfce"]
        app.launchEnvironment = ["TRIPTYCH_SEED_ROOTFS": seed.path]
        app.launch()
        app.buttons["engine-linux"].tap()
        app.buttons["linux-start"].tap()
        sleep(5)
        sessionButton("Desktop", in: app).tap()
        let start = app.buttons["linux-desktop-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Xfce should be seen as installed")
        attach(app, "desktop-tab")
        start.tap()
        let canvas = app.descendants(matching: .any)["linux-desktop"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        // Xfce on the interpreter: the panel and backdrop take a while. "colors N" counts distinct sampled colours.
        func colors() -> Int {
            let v = (canvas.value as? String) ?? ""
            return Int(v.components(separatedBy: "colors ").last ?? "") ?? 0
        }
        let deadline = Date().addingTimeInterval(420)
        while Date() < deadline && colors() < 12 { sleep(5) }
        sleep(10)
        checkDisplay(canvas, in: app, screenshot: "fullscreen-linux-desktop")
        let value = (canvas.value as? String) ?? ""
        print("LINUX-DESKTOP: \(value)")
        let dims = value.components(separatedBy: " ").first?.components(separatedBy: "x").compactMap { Int($0) } ?? []
        let (guestW, guestH) = dims.count == 2 ? (dims[0], dims[1]) : (1280, 720)
        checkGuestAspect(guestW, guestH, display: canvas)
        XCTAssertGreaterThanOrEqual(colors(), 12, value)
        let input = app.descendants(matching: .any)["linux-desktop-input"]
        let inputDeadline = Date().addingTimeInterval(60)
        while Date() < inputDeadline && (input.value as? String) != "connected" { sleep(2) }
        XCTAssertEqual(input.value as? String, "connected")
        // Long-press empty wallpaper to open Xfce's menu through XTest. The top screen edge
        // belongs to iOS gesture handling when the guest panel reaches the edge of the display.
        func frames() -> Int {
            let v = (canvas.value as? String) ?? ""
            return Int(v.components(separatedBy: "frames ").last?.components(separatedBy: " ").first ?? "") ?? 0
        }
        let before = frames()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.45)).press(forDuration: 0.65)
        let menuDeadline = Date().addingTimeInterval(30)
        while Date() < menuDeadline && frames() <= before { sleep(1) }
        sleep(3)
        attach(app, "xfce-context-menu")
        XCTAssertGreaterThan(frames(), before, "the long press should redraw the desktop (context menu)")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}

/// The whole in-app path: download Ubuntu, boot it, Install Xfce (apt, long), Start Xfce; the Xvfb size must follow the pane.
/// Long (tens of minutes on the interpreter); runs only with TRIPTYCH_LONG_INSTALL=1 in the test process environment.
final class TriptychLinuxInstallXfceTests: XCTestCase {
    func testInstallXfceInAppThenStart() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/tmp/triptych-long-install"), "touch /tmp/triptych-long-install to run")
        let app = XCUIApplication()
        app.launchArguments = ["-linux.root", "ubuntu"]
        app.launch()
        app.buttons["engine-linux"].tap()
        app.buttons["linux-systems"].tap()
        let get = app.buttons["distro-get-ubuntu"]
        if get.waitForExistence(timeout: 5) {
            get.tap()
            let status = app.staticTexts["distro-status"]
            let deadline = Date().addingTimeInterval(900)
            while Date() < deadline && !(status.exists && (status.label.contains("installed") || status.label.contains("fail") || status.label.contains("mismatch"))) { sleep(2) }
            XCTAssertTrue(status.label.contains("installed"), status.label)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["linux-start"].tap()
        sleep(5)
        sessionButton("Desktop", in: app).tap()
        let install = app.buttons["linux-desktop-install"]
        let alreadyInstalled = !install.waitForExistence(timeout: 10) && app.buttons["linux-desktop-start"].exists
        if !alreadyInstalled {
            XCTAssertTrue(install.waitForExistence(timeout: 10), "Install Xfce should be offered")
            install.tap()
            let out = app.descendants(matching: .any)["linux-output"]
            XCTAssertTrue(out.waitForExistence(timeout: 10))
            // The typed command echoes XFCE-INSTALLED once; the finished apt line prints it again (2 occurrences = done).
            let deadline = Date().addingTimeInterval(3 * 3600)
            var text = ""
            while Date() < deadline {
                text = (out.value as? String) ?? ""
                if text.contains("\nXFCE-INSTALLED") || text.contains("\nE: ") { break }
                sleep(30)
            }
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = "install-finished"; a.lifetime = .keepAlways; add(a)
            print("INSTALL-TAIL: \(text.suffix(600))")
            XCTAssertTrue(text.contains("\nXFCE-INSTALLED"), "apt install should finish")
        }
        sessionButton("Desktop", in: app).tap()
        let start = app.buttons["linux-desktop-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Xfce should now be seen as installed")
        start.tap()
        let canvas = app.descendants(matching: .any)["linux-desktop"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        func colors() -> Int { Int(((canvas.value as? String) ?? "").components(separatedBy: "colors ").last ?? "") ?? 0 }
        let d2 = Date().addingTimeInterval(600)
        while Date() < d2 && colors() < 12 { sleep(5) }
        sleep(10)
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "xfce-after-install"; b.lifetime = .keepAlways; add(b)
        let value = (canvas.value as? String) ?? ""
        print("INSTALLED-DESKTOP: \(value) frame \(canvas.frame)")
        XCTAssertGreaterThanOrEqual(colors(), 12, value)
    }
}

/// Home lists every system with an honest readiness line; About shows every CREDITS.md section.
final class TriptychHomeAboutTests: XCTestCase {
    func testHomeListsEverySystemAndAboutShowsCredits() {
        let app = XCUIApplication(); app.launch()
        for id in ["windows", "winpc", "macos", "macapps", "linux", "android", "x86pc"] {
            let row = app.buttons["engine-\(id)"]
            if !row.waitForExistence(timeout: 5) { app.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 5), id)
        }
        let casement = app.buttons["engine-winpc"]
        XCTAssertTrue(casement.label.contains("Casement · Windows 11 PC"))
        XCTAssertTrue(casement.label.contains("reaches the desktop on a Mac"))
        XCTAssertTrue(casement.label.contains("TPM 2.0"))
        XCTAssertTrue(casement.label.contains("network adapter"))
        XCTAssertEqual(app.staticTexts["engine-status-winpc"].label, "Firmware preview")
        XCTAssertEqual(app.staticTexts["engine-status-android"].label, "Not in the app yet")
        XCTAssertEqual(app.staticTexts["engine-status-x86pc"].label, "Ready · no JIT needed")  // x86pc page + bundled QEMU frameworks
        XCTAssertEqual(app.staticTexts["engine-status-linux"].label, "Ready · no JIT needed")
        attach(app, "home")
        app.buttons["engine-x86pc"].tap()
        XCTAssertTrue(app.navigationBars["x86 PC"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let about = app.buttons["About and licences"]
        for _ in 0..<4 where !about.isHittable { app.swipeUp() }
        about.tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        // Every "## " heading of CREDITS.md, read from the repo, must appear as a section header.
        let credits = (try? String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../CREDITS.md").standardized.path, encoding: .utf8)) ?? ""
        let headings = credits.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) }
        XCTAssertGreaterThan(headings.count, 3)
        attach(app, "about")
        for h in headings {
            let header = app.staticTexts["credits-\(h)"]
            var tries = 0
            while !header.exists && tries < 40 { app.swipeUp(velocity: .slow); tries += 1 }
            XCTAssertTrue(header.exists, "credits section \(h)")
        }
        attach(app, "about-end")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}

/// Export logs: one zip of every system's logs (this run and the previous one) plus device/app details, then the share sheet.
final class TriptychLogExportTests: XCTestCase {
    private func shareSheetShows(_ app: XCUIApplication) -> Bool {
        app.otherElements["ActivityListView"].waitForExistence(timeout: 15)
            || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 5)
            || app.buttons["Copy"].waitForExistence(timeout: 5)
    }

    private func dismissShareSheet(_ app: XCUIApplication) {
        // The share sheet runs in another process, so queries for its own elements are unreliable: wait until the
        // page under it takes taps again. A tap outside dismisses it on iPad, a swipe down on iPhone.
        let under = app.navigationBars.firstMatch
        for attempt in 0..<5 {
            sleep(1)
            if under.isHittable && !app.buttons["header.closeButton"].exists { break }
            if UIDevice.current.userInterfaceIdiom == .pad { app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap() }
            else if attempt % 2 == 0, app.buttons["header.closeButton"].exists { app.buttons["header.closeButton"].tap() }
            else { app.swipeDown(velocity: .fast) }
        }
    }

    func testExportLogsFromHomeAboutAndSystemPages() {
        let app = XCUIApplication(); app.launch()
        // Home: Help section.
        let export = app.buttons["export-logs"].firstMatch
        for _ in 0..<5 where !export.isHittable { app.swipeUp() }
        export.tap()
        XCTAssertTrue(shareSheetShows(app), "share sheet from Home")
        attach(app, "export-logs-share")
        dismissShareSheet(app)
        let result = app.staticTexts["export-logs-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.hasPrefix("Triptych-logs-") && result.label.contains(".zip"), result.label)
        attach(app, "export-logs-result")

        // x86 PC page: toolbar button.
        reveal(app, app.buttons["engine-x86pc"]).tap()
        XCTAssertTrue(app.navigationBars["x86 PC"].waitForExistence(timeout: 5))
        app.navigationBars["x86 PC"].buttons["export-logs"].tap()
        XCTAssertTrue(shareSheetShows(app), "share sheet from x86 PC")
        dismissShareSheet(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Windows PC page.
        reveal(app, app.buttons["engine-winpc"]).tap()
        XCTAssertTrue(app.navigationBars["Casement · Windows 11 PC"].buttons["export-logs"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // macOS page: toolbar button.
        reveal(app, app.buttons["engine-macos"]).tap()
        let nav = app.navigationBars["Atelier · macOS"].waitForExistence(timeout: 15)
        attach(app, "macos-page")
        XCTAssertTrue(nav, "macOS page open")
        let mac = app.navigationBars["Atelier · macOS"].buttons["export-logs"]
        XCTAssertTrue(mac.waitForExistence(timeout: 15), "Export logs on the macOS page")
        mac.tap()
        XCTAssertTrue(shareSheetShows(app), "share sheet from macOS")
        attach(app, "export-logs-macos")
    }

    /// Scrolls the home list until `e` can be tapped (it starts scrolled to the Help section).
    private func reveal(_ app: XCUIApplication, _ e: XCUIElement) -> XCUIElement {
        _ = e.waitForExistence(timeout: 5)
        for i in 0..<6 where !e.isHittable { if i < 3 { app.swipeDown() } else { app.swipeUp() } }
        return e
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}

final class TriptychFullscreenTests: XCTestCase {
    func testPaneHostFillsWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["-pane.display-preview"]
        app.launch()
        checkDisplay(app.descendants(matching: .any)["pane-display"], in: app)
        let toggle = app.buttons["session-controls"]
        let hidden = NSPredicate(format: "label == %@", "Show session controls")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: hidden, evaluatedWith: toggle)], timeout: 15), .completed)
        sessionButton("session-back", in: app).tap()
        XCTAssertTrue(app.buttons["engine-windows"].waitForExistence(timeout: 10))
    }

    func testAtelierDisplayFillsWindowInBothOrientations() {
        let app = XCUIApplication()
        app.launchArguments = ["-mac.display-preview"]
        app.launch()
        app.buttons["engine-macos"].tap()
        let display = app.descendants(matching: .any)["mac-display"]
        checkDisplay(display, in: app, screenshot: "fullscreen-atelier")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        checkDisplay(display, in: app, screenshot: "fullscreen-atelier-landscape")
        sessionButton("session-back", in: app).tap()
        XCTAssertTrue(app.navigationBars["Atelier · macOS"].waitForExistence(timeout: 10))
    }
}

final class WinPCKeyBarUITests: XCTestCase {
    func testKeyBarAndKeyboardToggle() {
        let app = XCUIApplication(); app.launchArguments = ["-winpc.autostart"]; app.launch()
        // The autostart flag may already have opened the page; otherwise open it from Home.
        let bar = app.descendants(matching: .any)["winpc-keybar"]
        if !bar.waitForExistence(timeout: 10) {
            let row = app.buttons["engine-winpc"]
            _ = row.waitForExistence(timeout: 5)
            for i in 0..<6 where !row.isHittable { if i < 3 { app.swipeDown() } else { app.swipeUp() } }
            row.tap()
        }

        XCTAssertTrue(bar.waitForExistence(timeout: 20), "key bar")
        for k in ["Esc", "Enter", "F10"] {
            XCTAssertTrue(app.buttons["winpc-key-\(k)"].waitForExistence(timeout: 5), k)
        }
        app.buttons["winpc-key-Ctrl"].tap()
        app.buttons["winpc-key-Esc"].tap()
        XCTAssertTrue(app.buttons["winpc-key-Esc"].exists, "still alive after Ctrl+Esc")

        let kb = app.buttons["winpc-keyboard"]
        XCTAssertTrue(kb.waitForExistence(timeout: 5))
        kb.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard shows")
        kb.tap()
        let deadline = Date().addingTimeInterval(5)
        while app.keyboards.count > 0 && Date() < deadline { usleep(200_000) }
        XCTAssertEqual(app.keyboards.count, 0, "keyboard hides")
    }
}
