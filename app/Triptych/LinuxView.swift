// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftTerm
import SwiftUI

/// Copies the bundled starter root filesystem (Alpine minirootfs, imported
/// into LinuxRunner's fakefs format at build time) into Application Support.
enum LinuxRootfs {
    static var root: URL { LinuxDistro.dir("alpine") }
    static func prepare() throws -> URL {
        let fm = FileManager.default
        let chosen = LinuxDistro.selected
        #if targetEnvironment(simulator)
        // UI tests: TRIPTYCH_SEED_ROOTFS names a host rootfs (e.g. build/linux/ubuntu-fs with Xfce) cloned in as the chosen system.
        if chosen != "alpine", !LinuxDistro.isInstalled(chosen), let seed = ProcessInfo.processInfo.environment["TRIPTYCH_SEED_ROOTFS"] {
            try fm.createDirectory(at: LinuxDistro.dir(chosen).deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: seed), to: LinuxDistro.dir(chosen))
        }
        #endif
        if chosen != "alpine", LinuxDistro.isInstalled(chosen) { return LinuxDistro.dir(chosen) }
        if fm.fileExists(atPath: root.appendingPathComponent("meta.db").path) { return root }
        guard let src = Bundle.main.url(forResource: "alpine-fs", withExtension: nil) else {
            throw NSError(domain: "Triptych", code: 1, userInfo: [NSLocalizedDescriptionKey: "No starter rootfs in this build"])
        }
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: root)
        return root
    }
}

/// The app end of the running guest's console, backed by a host pty or a socket pair.
/// Raw bytes go to the terminal view; a cleaned copy (escape sequences dropped) is kept for accessibility
/// and the UI tests.
final class LinuxSession: ObservableObject {
    static let shared = LinuxSession()
    @Published var state = "Not started"
    /// The running system's rootfs.
    private(set) var root: URL?
    private(set) var plainText = ""
    private(set) var fd: Int32 = -1
    private var source: DispatchSourceRead?
    /// Receives the guest's output (on the main queue).
    var onOutput: ((ArraySlice<UInt8>) -> Void)?
    private var terminalHistory: [UInt8] = []

    @discardableResult
    func start() -> Bool {
        guard fd < 0 else { return true }
        do {
            let root = try LinuxRootfs.prepare()
            if let bind = LinuxDesktop.prepareGuestTools() { setenv("ISH_BIND_MOUNTS", bind, 1) }
            var m: Int32 = -1
            CuratorFallbackModel.shared.prepareForEngineStart()
            let rc = tp_linux_start(root.path, &m)
            guard rc == 0 else { state = "Start failed (\(rc))"; TriptychLog.log("linux", "start failed: tp_linux_start returned \(rc) (root \(root.lastPathComponent))"); return false }
            TriptychLog.log("linux", "started \(root.lastPathComponent)")
            fd = m
            self.root = root
            state = "Running"
            let src = DispatchSource.makeReadSource(fileDescriptor: m, queue: .global())
            src.setEventHandler { [weak self] in
                var buf = [UInt8](repeating: 0, count: 16384)
                let n = read(m, &buf, buf.count)
                if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { self?.source?.cancel(); return } /* EOF/EIO: stop, or the source spins */
                guard n > 0 else { return }
                let bytes = Array(buf[0..<n])
                DispatchQueue.main.async { self?.received(bytes) }
            }
            src.setCancelHandler { [weak self] in close(m); DispatchQueue.main.async { if self?.fd == m { self?.fd = -1 } } }
            src.resume(); source = src
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                var st: Int32 = 0
                if tp_linux_has_exited(&st) { self?.state = "Exited (\(st))"; TriptychLog.log("linux", "exited with status \(st)"); t.invalidate() }
            }
            return true
        } catch { state = error.localizedDescription; TriptychLog.log("linux", "start failed: \(error.localizedDescription)"); return false }
    }

    private func received(_ bytes: [UInt8]) {
        plainText += Self.clean(String(decoding: bytes, as: UTF8.self))
        if plainText.count > 200_000 { plainText.removeFirst(50_000) }
        terminalHistory.append(contentsOf: bytes)
        if terminalHistory.count > 200_000 { terminalHistory.removeFirst(50_000) }
        onOutput?(bytes[...])
        objectWillChange.send()
    }

    /// Rebuild the terminal when returning from another system, including output received off-screen.
    func attach(_ sink: @escaping (ArraySlice<UInt8>) -> Void) {
        onOutput = sink
        if !terminalHistory.isEmpty { sink(terminalHistory[...]) }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard fd >= 0 else { return }
        bytes.withUnsafeBufferPointer { p in
            var off = 0
            while off < p.count {
                let n = write(fd, p.baseAddress! + off, p.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard fd >= 0, cols > 0, rows > 0, state == "Running" else { return }
        tp_linux_resize(fd, UInt16(clamping: cols), UInt16(clamping: rows))
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
         .replacingOccurrences(of: "\u{1B}[()][0-9A-Za-z]", with: "", options: .regularExpression)
         .replacingOccurrences(of: "\r", with: "")
    }
}

/// SwiftTerm's xterm-compatible terminal (colours, cursor addressing, alternate screen, mouse, UTF-8),
/// wired to the guest's console.
struct LinuxTerminal: UIViewRepresentable {
    var keyboard: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TerminalView {
        var opts = TerminalOptions.default
        if ProcessInfo.processInfo.environment["TRIPTYCH_UI_TEST"] == "1" {
            // A blinking UIView animation prevents XCUITest from reaching idle before each tap/type.
            opts.cursorStyle = .steadyBlock
        }
        let t = TerminalView(frame: .zero, options: opts)
        t.terminalDelegate = context.coordinator
        t.contentInsetAdjustmentBehavior = .never
        t.nativeBackgroundColor = .black
        t.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        t.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        t.optionAsMetaKey = true
        t.isAccessibilityElement = true
        t.accessibilityIdentifier = "linux-output"
        LinuxSession.shared.attach { [weak t] bytes in
            t?.feed(byteArray: bytes)
            t?.accessibilityValue = LinuxSession.shared.plainText
        }
        t.inputView = keyboard ? nil : context.coordinator.noKeyboard
        if keyboard { DispatchQueue.main.async { _ = t.becomeFirstResponder() } }
        return t
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        let hidden = view.inputView != nil
        guard hidden == keyboard else { return }
        view.inputView = keyboard ? nil : context.coordinator.noKeyboard
        _ = view.resignFirstResponder()
        _ = view.becomeFirstResponder()
        view.reloadInputViews()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let noKeyboard = UIView(frame: .zero)
        func send(source: TerminalView, data: ArraySlice<UInt8>) { LinuxSession.shared.send(data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { LinuxSession.shared.resize(cols: newCols, rows: newRows) }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let u = URL(string: link), u.scheme == "https" || u.scheme == "http" { UIApplication.shared.open(u) }
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

struct LinuxView: View {
    enum Mode: String, CaseIterable { case terminal = "Terminal", desktop = "Desktop" }
    @EnvironmentObject var app: SessionState
    @ObservedObject private var s = LinuxSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.terminal
    @State private var showKeyboard = false
    @State private var confirmStop = false
    @State private var window: SystemWindowMetrics?
    private var running: Bool { s.state == "Running" && s.root != nil }

    var body: some View {
        Group {
            if running, let root = s.root {
                SystemDisplay {
                    if mode == .desktop {
                        LinuxDesktopPane(root: root, mode: $mode, windowSize: window?.size)
                    } else {
                        LinuxTerminal(keyboard: showKeyboard).background(Color.black)
                    }
                } controls: {
                    SessionBackButton { dismiss() }
                    Button("Stop", role: .destructive) { confirmStop = true }
                    Button(mode == .terminal ? "Desktop" : "Terminal") {
                        showKeyboard = false
                        mode = mode == .terminal ? .desktop : .terminal
                    }
                    if mode == .terminal {
                        Button { showKeyboard.toggle() } label: {
                            Image(systemName: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
                        }
                        .accessibilityLabel("Keyboard")
                        .accessibilityIdentifier("linux-keyboard")
                    }
                }
            } else if s.root != nil {
                LinuxTerminal(keyboard: false).background(Color.black)
            } else {
                ZStack {
                    TriptychBackdrop()
                    VStack(spacing: 14) {
                        TriptychPanelCard(accent: TriptychPalette.linuxLight, raised: true) {
                            VStack(spacing: 12) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 38, weight: .semibold))
                                    .foregroundStyle(TriptychPalette.linuxLight)
                                Text("ARM64 Linux")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(TriptychPalette.textPrimary)
                                Text("Tap Start to boot Linux on the interpreter (no JIT required). Use the stack button to pick or download a distribution.")
                                    .font(.system(size: 14))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(TriptychPalette.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 16)
                    .triptychColumn()
                }
            }
        }
        .background {
            SystemWindowReader { window = $0 }
        }
        .toolbar(running ? .hidden : .visible, for: .navigationBar)
        .confirmationDialog("Stop Linux?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Restart Triptych", role: .destructive) { Relaunch.restart(into: .linux) }
        } message: {
            Text("Restarting stops every system running in Triptych.")
        }
        .navigationTitle(EngineKind.linux.title)
        .exportLogsToolbar()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { LinuxDistrosView() } label: { Image(systemName: "square.stack.3d.up") }
                    .accessibilityLabel("Linux systems").accessibilityIdentifier("linux-systems")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if s.state == "Not started" {
                    Button("Start") { tp_release_madeira_va(); if s.start() { app.markStarted(.linux) } }
                        .disabled(!app.canStart(.linux))
                        .accessibilityIdentifier("linux-start")
                } else { Text(s.state).font(.caption) }
            }
        }
    }
}
