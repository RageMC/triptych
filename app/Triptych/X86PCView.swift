// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// The x86 PC page: a whole x86-64 PC (QEMU system emulation, engines/x86pc) for x86 ISOs such as Linux, SteamOS or
/// x86 Windows, from the user's own media. Without JIT it runs the TCTI interpreter build: very slow, not for games.
final class X86PCVM: ObservableObject {
    static let shared = X86PCVM()
    static let defaultDiskGB = 16

    private let iso = PickedFile(defaultsKey: "x86pc.iso.bookmark")
    @Published var isoURL: URL?
    @Published var uefi = false                 // Alpine boots with BIOS; Linux Mint, SteamOS and Windows want UEFI
    @Published var ramMB = 2048
    @Published var vcpus = min(4, ProcessInfo.processInfo.activeProcessorCount)
    @Published var slirp = true                  // user-mode NAT with DHCP and DNS, no host setup
    @Published var status = "Pick your own x86-64 ISO, or start with an empty disk."
    @Published var error: String?
    @Published var running = false
    @Published var commandLine = ""
    @Published var serialTail = ""               // last serial line, for debugging and tests

    init() {
        isoURL = iso.url
        if let u = isoURL { status = "ISO: \(u.lastPathComponent)" }
    }

    private var timer: Timer?
    private var startedAt = Date()
    private var enterSent = false
    private let keyQueue = DispatchQueue(label: "x86pc.keys")

    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("x86pc")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    var diskURL: URL { Self.dir.appendingPathComponent("disk.qcow2") }
    var varsURL: URL { Self.dir.appendingPathComponent("vars.fd") }
    var serialURL: URL { Self.dir.appendingPathComponent("serial.log") }

    /// Firmware staged by scripts/build-x86pc.sh and copied into the app as x86pc-fw/ (pc-bios subset + raw edk2 images).
    var firmwareDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("x86pc-fw") }

    var build: X86PCBuild { x86pc_host_build_for_process() }
    var buildName: String { build == x86pc_host_build_jit() ? "native TCG (JIT)" : "TCTI interpreter (no JIT, very slow)" }

    func pick(_ url: URL) {
        iso.set(url)
        isoURL = url
        status = "ISO: \(url.lastPathComponent)"
    }

    /// The qemu-system command line. Serial goes to a file, the monitor and QMP listen on loopback only.
    func arguments(fw: URL, display: GuestDisplaySize) -> [String] {
        var a = ["qemu-system-x86_64", "-M", "q35", "-cpu", "max", "-accel", "tcg,thread=multi",
                 "-smp", "\(vcpus)", "-m", "\(ramMB)", "-display", "triptych", "-device", "virtio-tablet-pci", "-L", fw.path,
                 "-vga", "none", "-device", "VGA,edid=on,xres=\(display.width),yres=\(display.height)",
                 "-monitor", "tcp:127.0.0.1:\(x86pc_host_hmp_port()),server=on,wait=off",
                 "-qmp", "tcp:127.0.0.1:\(x86pc_host_qmp_port()),server=on,wait=off",
                 "-serial", "file:\(serialURL.path)",
                 "-drive", "file=\(diskURL.path),format=qcow2,if=virtio"]
        if uefi {
            a += ["-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(fw.appendingPathComponent("edk2-x86_64-code.fd").path)",
                  "-drive", "if=pflash,format=raw,unit=1,file=\(varsURL.path)"]
        }
        if let iso = isoURL { a += ["-cdrom", iso.path] }
        a += slirp ? ["-nic", "user,model=virtio-net-pci"] : ["-nic", "none"]
        return a
    }

    func start(app: SessionState, display: GuestDisplaySize) {
        guard app.canStart(.x86pc) else { return }
        guard let fw = firmwareDir, FileManager.default.fileExists(atPath: fw.path) else {
            error = "The x86 firmware is not in this build (scripts/build-x86pc.sh, then rebuild the app)."; return
        }
        guard x86pc_host_build_bundled(build) else {
            error = "The QEMU \(build == x86pc_host_build_jit() ? "JIT" : "TCTI") framework is not in this build (scripts/build-x86pc.sh)."; return
        }
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: varsURL.path) {
                try fm.copyItem(at: fw.appendingPathComponent("edk2-i386-vars.fd"), to: varsURL)   // raw pflash template
            }
        } catch { self.error = "Cannot create the firmware variables: \(error.localizedDescription)"; return }
        if !fm.fileExists(atPath: diskURL.path) {
            var err = [CChar](repeating: 0, count: 256)
            let r = x86pc_host_create_qcow2(diskURL.path, UInt64(Self.defaultDiskGB) << 30, &err, 256)
            if r != 0 { error = String(cString: err); return }
        }
        TriptychLog.rotate(serialURL) // the previous run's console stays as serial-prev.log for Export logs
        let args = arguments(fw: fw, display: display)
        commandLine = args.joined(separator: " ")
        var err = [CChar](repeating: 0, count: 256)
        CuratorFallbackModel.shared.prepareForEngineStart()
        let r = x86pc_host_start(args, build, &err, 256)
        TriptychLog.log("x86pc", "starting: \(args.joined(separator: " "))")
        if r != 0 { error = String(cString: err); TriptychLog.log("x86pc", "start failed: \(error ?? "")"); return }
        app.markStarted(.x86pc)
        running = true
        enterSent = false
        startedAt = Date()
        status = "Booting (\(buildName))"
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        if !x86pc_host_is_running() {
            timer?.invalidate(); timer = nil
            status = "Stopped. Relaunch Triptych to start another PC."
            return
        }
        // The Alpine ISO boots by itself; the UEFI GRUB menu waits for Return (research/X86PC.md, measured at ~90 s).
        if uefi && !enterSent && Date().timeIntervalSince(startedAt) > 90 {
            enterSent = true
            send("ret")
        }
        let serial = serialURL
        DispatchQueue.global(qos: .utility).async {
            let text = (try? String(contentsOf: serial, encoding: .utf8)) ?? ""
            let last = text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " | ")
            DispatchQueue.main.async {
                self.serialTail = String(last.suffix(200))
                if text.contains("login:") {
                    self.status = "Reached \"localhost login:\" on the serial console"
                } else if self.running && self.status.hasPrefix("Booting") {
                    self.status = "Booting (\(self.buildName)), \(Int(Date().timeIntervalSince(self.startedAt))) s"
                }
            }
        }
    }

    /// USB HID keyboard usages (UIKeyboardHIDUsage raw values) for the named keys the page offers as buttons.
    static let namedKeys: [String: Int] = ["ret": 0x28, "esc": 0x29, "backspace": 0x2a, "tab": 0x2b,
                                           "right": 0x4f, "left": 0x50, "down": 0x51, "up": 0x52]

    /// US layout: one character as (HID usage, needs shift), nil when there is no key for it.
    static func hid(for c: Character) -> (usage: Int, shift: Bool)? {
        guard let a = c.asciiValue else { return nil }
        let n = Int(a)
        switch n {
        case 97...122: return (4 + n - 97, false)
        case 65...90: return (4 + n - 65, true)
        case 49...57: return (0x1e + n - 49, false)
        case 48: return (0x27, false)
        case 10: return (0x28, false)
        case 9: return (0x2b, false)
        case 32: return (0x2c, false)
        default: break
        }
        let plain: [Character: Int] = ["-": 0x2d, "=": 0x2e, "[": 0x2f, "]": 0x30, "\\": 0x31, ";": 0x33, "'": 0x34,
                                       "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38]
        if let u = plain[c] { return (u, false) }
        let shifted: [Character: Int] = ["!": 0x1e, "@": 0x1f, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24,
                                         "*": 0x25, "(": 0x26, ")": 0x27, "_": 0x2d, "+": 0x2e, "{": 0x2f, "}": 0x30,
                                         "|": 0x31, ":": 0x33, "\"": 0x34, "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38]
        if let u = shifted[c] { return (u, true) }
        return nil
    }

    /// A key tap by HID usage, in order with every other typed key (press, short hold, release).
    func tap(_ usage: Int, shift: Bool = false) {
        keyQueue.async {
            if shift { x86pc_host_key(0xe1, 1) }
            x86pc_host_key(Int32(usage), 1)
            usleep(25_000)
            x86pc_host_key(Int32(usage), 0)
            if shift { x86pc_host_key(0xe1, 0) }
            usleep(15_000)
        }
    }

    func send(_ key: String) { if let u = Self.namedKeys[key] { tap(u) } }

    func type(_ text: String) {
        for c in text { if let k = Self.hid(for: c) { tap(k.usage, shift: k.shift) } }
    }

    /// Powers the PC off from the host side (display unregistered, QEMU shutdown requested, QEMU thread joined).
    func quit() {
        status = "Stopping…"
        DispatchQueue.global(qos: .userInitiated).async {
            x86pc_host_stop()
            DispatchQueue.main.async { self.running = false; self.status = "Stopped. Relaunch Triptych to start another PC." }
        }
    }
}

struct X86PCView: View {
    @EnvironmentObject var app: SessionState
    @ObservedObject var vm = X86PCVM.shared
    @State private var picking = false
    @Environment(\.dismiss) private var dismiss
    @State private var window: SystemWindowMetrics?
    @State private var appliedTestArguments = false
    @State private var showConsole = false
    @State private var typed = ""
    @State private var showKeyboard = false

    var body: some View {
        Group {
            if vm.running {
                running
            } else {
                setup
            }
        }
        .navigationTitle("x86 PC").navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data, .data]) { r in
            if case .success(let u) = r { vm.pick(u) }
        }
        .alert("x86 PC", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(vm.error ?? "") }
        .toolbar(vm.running ? .hidden : .visible, for: .navigationBar)
        .background {
            SystemWindowReader { metrics in
                window = metrics
                guard !appliedTestArguments else { return }
                appliedTestArguments = true
                autostartFromArguments()
            }
        }
    }

    private var setup: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TriptychPanelCard(accent: TriptychPalette.linuxLight, raised: true) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Very slow without JIT. Not for games: use it for desktops, installers and apps.", systemImage: "tortoise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(TriptychPalette.warn)
                                .accessibilityIdentifier("x86pc-banner")
                            Text(vm.build == x86pc_host_build_jit()
                                 ? "This run uses the native JIT build."
                                 : "This run uses the TCTI build (no JIT). Attach a debugger, e.g. StikDebug, for the native build.")
                                .font(.footnote)
                                .foregroundStyle(TriptychPalette.textSecondary)
                        }
                    }

                    TriptychSectionHeader(title: "Install media", accent: TriptychPalette.linuxLight)
                    TriptychPanelCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Button(vm.isoURL?.lastPathComponent ?? "Choose ISO from Files…") { picking = true }
                                .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.linuxLight))
                                .accessibilityIdentifier("x86pc-pick-iso")
                            Text(vm.status)
                                .font(.footnote)
                                .foregroundStyle(TriptychPalette.textSecondary)
                                .accessibilityIdentifier("x86pc-status")
                        }
                    }

                    TriptychSectionHeader(title: "Virtual hardware", accent: TriptychPalette.linuxLight)
                    TriptychPanelCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Stepper("Memory: \(vm.ramMB) MB", value: $vm.ramMB, in: 512...8192, step: 512)
                                .font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                            Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                            Stepper("CPUs: \(vm.vcpus)", value: $vm.vcpus, in: 1...8)
                                .font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                            Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                            Picker("Firmware", selection: $vm.uefi) {
                                Text("BIOS").tag(false)
                                Text("UEFI").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("x86pc-firmware")
                            Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                            Toggle("Network (NAT, DHCP, DNS)", isOn: $vm.slirp)
                                .font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                                .tint(TriptychPalette.linuxDeep)
                                .accessibilityIdentifier("x86pc-net-toggle")
                            Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                            HStack {
                                Text("Disk").font(.system(size: 14)).foregroundStyle(TriptychPalette.textSecondary)
                                Spacer()
                                Text("\(X86PCVM.defaultDiskGB) GB qcow2 (sparse)")
                                    .font(.system(size: 14, weight: .medium)).foregroundStyle(TriptychPalette.textPrimary)
                            }
                            Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                            HStack {
                                Text("Network").font(.system(size: 14)).foregroundStyle(TriptychPalette.textSecondary)
                                Spacer()
                                Text(vm.slirp ? "user (slirp, virtio-net-pci)" : "none")
                                    .font(.system(size: 14, weight: .medium)).foregroundStyle(TriptychPalette.textPrimary)
                                    .accessibilityIdentifier("x86pc-net")
                            }
                        }
                    }

                    Button("Start") { startVM() }
                        .buttonStyle(TriptychPrimaryButtonStyle(panel: .linux, enabled: app.activeEngine == nil || app.activeEngine == .x86pc))
                        .disabled(!app.canStart(.x86pc))
                        .accessibilityIdentifier("x86pc-start")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
    }

    private var running: some View {
        SystemDisplay {
            X86PCDisplay(keyboard: showKeyboard)
        } controls: {
            SessionBackButton { dismiss() }
            Button("Stop", role: .destructive) { vm.quit() }
                .accessibilityIdentifier("x86pc-quit")
            Button { showKeyboard.toggle() } label: {
                Image(systemName: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
            }
            .accessibilityLabel("Keyboard")
            .accessibilityIdentifier("x86pc-keyboard")
            Button { showConsole.toggle() } label: { Image(systemName: "terminal") }
                .accessibilityLabel("Serial console and guest keys")
                .accessibilityIdentifier("x86pc-console")
        } bottom: {
            if showConsole {
                console
            }
        }
    }

    private var console: some View {
        VStack(spacing: 6) {
            Text(vm.status).accessibilityIdentifier("x86pc-status")
            Text("Network: \(vm.slirp ? "user (slirp, virtio-net-pci)" : "none")")
                .accessibilityIdentifier("x86pc-net")
            Text(vm.serialTail).lineLimit(1).accessibilityIdentifier("x86pc-serial")
            ScrollView(.horizontal) {
                HStack {
                    ForEach(["ret", "esc", "tab", "backspace", "up", "down", "left", "right"], id: \.self) { key in
                        Button(key) { vm.send(key) }.buttonStyle(.bordered)
                    }
                }
            }.scrollIndicators(.hidden)
            TextField("Type text, return sends it", text: $typed)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityIdentifier("x86pc-type")
                .onSubmit {
                    vm.type(typed + "\n")
                    typed = ""
                }
        }
        .font(.caption.monospaced())
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(8)
    }

    private func startVM() {
        guard let window else { return }
        vm.start(app: app, display: window.guestSize())
    }

    /// Test and debugging hook: `-x86pc.autostart 1 -x86pc.iso <path>` boots straight away (headless UI tests).
    private func autostartFromArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-x86pc.autostart"), !vm.running else { return }
        if let i = args.firstIndex(of: "-x86pc.iso"), i + 1 < args.count {
            vm.isoURL = URL(fileURLWithPath: args[i + 1])
        }
        if args.contains("-x86pc.noiso") { vm.isoURL = nil }
        if args.contains("-x86pc.uefi") { vm.uefi = true }
        if let i = args.firstIndex(of: "-x86pc.ram"), i + 1 < args.count, let mb = Int(args[i + 1]) { vm.ramMB = mb }
        startVM()
    }
}

struct X86PCDisplay: UIViewRepresentable {
    var keyboard: Bool
    func makeUIView(context: Context) -> X86FBView { X86FBView() }
    func updateUIView(_ v: X86FBView, context: Context) { v.setSoftKeyboard(keyboard) }
    static func dismantleUIView(_ v: X86FBView, coordinator: ()) { v.stopDrawing() }
}

/// The guest display on a CALayer (frames pulled from QEMU's `triptych` display backend), touch as the virtio tablet
/// hardware keys by HID usage and the soft keyboard as ASCII taps.
final class X86FBView: UIView, UIKeyInput {
    private var link: CADisplayLink?
    private var frames = 0
    private var lastGeneration: UInt64 = 0
    private var fbSize = CGSize.zero
    private var buttons = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        isAccessibilityElement = true; accessibilityIdentifier = "x86pc-display"; accessibilityValue = "waiting for the guest display"
        isMultipleTouchEnabled = false
        link = CADisplayLink(target: self, selector: #selector(tick)); link?.preferredFramesPerSecond = 30; link?.add(to: .main, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { link?.invalidate() }
    func stopDrawing() { link?.invalidate(); link = nil }
    private let noKeyboard = UIView(frame: .zero)
    private var wantsSoftKeyboard = false
    override var inputView: UIView? { wantsSoftKeyboard ? nil : noKeyboard }
    func setSoftKeyboard(_ on: Bool) {
        guard wantsSoftKeyboard != on else { return }
        wantsSoftKeyboard = on
        _ = resignFirstResponder()
        _ = becomeFirstResponder()
        reloadInputViews()
    }
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() { if window != nil { _ = becomeFirstResponder() } }

    @objc private func tick() {
        var w: UInt32 = 0, h: UInt32 = 0, s: UInt32 = 0
        guard let p = x86pc_host_fb(&w, &h, &s) else { return }
        let gen = x86pc_host_fb_generation()
        guard gen != lastGeneration else { return }
        lastGeneration = gen
        // x8r8g8b8 little-endian in memory is B,G,R,X.
        guard let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: p), width: Int(w), height: Int(h), bitsPerComponent: 8,
                                  bytesPerRow: Int(s), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
              let img = ctx.makeImage() else { return }
        layer.contents = img           // makeImage copies the pixels, the host reuses its buffer on the next pull
        fbSize = CGSize(width: Int(w), height: Int(h)); frames += 1
        accessibilityValue = "fb \(w)x\(h) frames=\(frames)"
    }

    private func tablet(_ t: UITouch, down: Bool?) {
        guard fbSize.width > 0, !bounds.isEmpty else { return }
        let p = t.location(in: self)
        let x = max(0, min(1, p.x / bounds.width)), y = max(0, min(1, p.y / bounds.height))
        if let d = down { buttons = d ? 1 : 0 }
        x86pc_host_tablet(Int32(x * 32767), Int32(y * 32767), Int32(buttons), 0)
    }
    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) { if let t = t.first { tablet(t, down: nil); tablet(t, down: true) } }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) { if let t = t.first { tablet(t, down: nil) } }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { if let t = t.first { tablet(t, down: false) } }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { if let t = t.first { tablet(t, down: false) } }

    // Hardware keyboard: UIKeyboardHIDUsage raw values are USB HID usages; the backend translates them to QEMU key codes.
    override func pressesBegan(_ presses: Set<UIPress>, with e: UIPressesEvent?) {
        for p in presses { if let k = p.key { x86pc_host_key(Int32(k.keyCode.rawValue), 1) } }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with e: UIPressesEvent?) {
        for p in presses { if let k = p.key { x86pc_host_key(Int32(k.keyCode.rawValue), 0) } }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with e: UIPressesEvent?) { pressesEnded(presses, with: e) }

    // Soft keyboard (UIKeyInput): ASCII to HID usages through the VM's ordered key queue.
    var hasText: Bool { true }
    func deleteBackward() { X86PCVM.shared.tap(0x2a) }
    func insertText(_ text: String) { X86PCVM.shared.type(text) }
}
