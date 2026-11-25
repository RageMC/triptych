// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// A file the user picked from Files (an ISO), kept across launches as a security-scoped bookmark: the picker's URL
/// is only valid for this run, so without the bookmark every relaunch asked for the ISO again.
final class PickedFile {
    private let key: String
    private(set) var url: URL?
    private var scoped = false
    init(defaultsKey: String) {
        key = defaultsKey
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
            UserDefaults.standard.removeObject(forKey: key); return   // the file is gone: forget it
        }
        scoped = u.startAccessingSecurityScopedResource()
        url = u
        if stale { save() }
    }
    /// Takes the picker's URL: access starts now and lasts until another file replaces it.
    func set(_ u: URL) {
        if scoped { url?.stopAccessingSecurityScopedResource() }
        scoped = u.startAccessingSecurityScopedResource()
        url = u
        save()
    }
    func clear() {
        if scoped { url?.stopAccessingSecurityScopedResource() }
        scoped = false; url = nil
        UserDefaults.standard.removeObject(forKey: key)
    }
    private func save() {
        guard let u = url, let data = try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// The Windows PC page: the "winarm" virtual ARM64 PC (engines/winvm, on Henge's CPU core) that boots UEFI and any ACPI OS,
/// meant for Windows 11 on Arm from the user's own ISO. Needs JIT on a device.
final class WinPC: ObservableObject {
    static let shared = WinPC()
    private let iso = PickedFile(defaultsKey: "winpc.iso.bookmark")
    @Published var isoURL: URL?
    @Published var status = "Pick your own Windows 11 ARM ISO, or start without one to see the firmware."
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    private(set) var generation = 0
    @Published var error: String?
    /// Guest memory and CPUs (kept across launches). Windows 11 Setup refuses less than 4 GB and 2 CPUs.
    static let ramChoices: [Int] = [2048, 3072, 4096, 6144, 8192].filter { UInt64($0) << 20 <= ProcessInfo.processInfo.physicalMemory / 4 * 3 }
    static let cpuChoices: [Int] = Array(1...max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
    @Published var ramMB: Int { didSet { UserDefaults.standard.set(ramMB, forKey: "winpc.ramMB") } }
    @Published var cpus: Int { didSet { UserDefaults.standard.set(cpus, forKey: "winpc.cpus") } }
    init() {
        let r = UserDefaults.standard.integer(forKey: "winpc.ramMB")
        ramMB = Self.ramChoices.contains(r) ? r : (Self.ramChoices.contains(4096) ? 4096 : Self.ramChoices.last ?? 2048)
        let c = UserDefaults.standard.integer(forKey: "winpc.cpus")
        cpus = Self.cpuChoices.contains(c) ? c : min(2, Self.cpuChoices.last ?? 1)
        isoURL = iso.url
        if let u = isoURL { status = "ISO: \(u.lastPathComponent)" }
    }

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WindowsPC")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    var diskURL: URL { Self.dir.appendingPathComponent("disk.nvme.img") }
    var varsURL: URL { Self.dir.appendingPathComponent("vars.fd") }
    var tpmURL: URL { Self.dir.appendingPathComponent("tpm-state.bin") }

    func forgetISO() {
        iso.clear(); isoURL = nil
        status = "Pick your own Windows 11 ARM ISO, or start without one to see the firmware."
    }

    func pick(_ url: URL) {
        iso.set(url)
        isoURL = url
        status = "ISO: \(url.lastPathComponent)"
    }

    /// Creates the sparse NVMe disk, the UEFI variable store and the TPM state file (only when missing), then starts the board.
    func start(app: SessionState, display: GuestDisplaySize, ramMB: Int? = nil, diskGB: Int = 64) {
        guard !running, !stopping, app.canStart(.winpc) else { return }
        let ramMB = ramMB ?? self.ramMB
        guard let code = Bundle.main.path(forResource: "QEMU_EFI", ofType: "fd"),
              let varsTemplate = Bundle.main.path(forResource: "QEMU_VARS", ofType: "fd") else {
            error = "The UEFI firmware is not in this build (scripts/build-edk2.sh)."; return
        }
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: varsURL.path) { try fm.copyItem(atPath: varsTemplate, toPath: varsURL.path) }
            if !fm.fileExists(atPath: diskURL.path) {
                fm.createFile(atPath: diskURL.path, contents: nil)
                let h = try FileHandle(forWritingTo: diskURL); try h.truncate(atOffset: UInt64(diskGB) << 30); try h.close() // sparse
            }
            if !fm.fileExists(atPath: tpmURL.path) { fm.createFile(atPath: tpmURL.path, contents: nil) }
        } catch { self.error = "Cannot create the VM files: \(error.localizedDescription)"; return }
        // The guest's serial console (firmware, boot loader, kernel debug output) goes to WindowsPC/serial.log, the previous
        // run's to serial-prev.log, for Export logs. WINVM_SERIAL_LOG=0 turns it off.
        let serial = Self.dir.appendingPathComponent("serial.log")
        let logSerial = ProcessInfo.processInfo.environment["WINVM_SERIAL_LOG"] != "0"
        if logSerial { TriptychLog.rotate(serial) }
        TriptychLog.log("winpc", "starting: \(ramMB) MB, \(cpus) CPUs, disk \(diskGB) GB, ISO \(isoURL?.lastPathComponent ?? "none"), TPM \(winvm_host_has_tpm() != 0 ? "yes" : "no")")
        var err = [CChar](repeating: 0, count: 256)
        // TPM 2.0 (libtpms) when libwinvm was built with it (scripts/build-libtpms-ios.sh); Windows 11 Setup requires one.
        let tpm: String? = winvm_host_has_tpm() != 0 ? tpmURL.path : nil
        CuratorFallbackModel.shared.prepareForEngineStart()
        let r = winvm_host_start(code, varsURL.path, Int32(ramMB), Int32(cpus), UInt32(display.width), UInt32(display.height), diskURL.path, isoURL?.path, tpm, logSerial ? serial.path : nil, &err, 256)
        if r != 0 { error = String(cString: err); TriptychLog.log("winpc", "start failed: \(error ?? "")"); return }
        app.markStarted(.winpc)
        generation += 1
        running = true
        status = "Running"
    }

    func stop() {
        guard running, !stopping else { return }
        stopping = true
        DispatchQueue.global(qos: .userInitiated).async {
            winvm_host_stop()
            DispatchQueue.main.async {
                self.stopping = false
                self.updateStopped()
            }
        }
    }

    func updateStopped() {
        guard running, !stopping, winvm_host_state() == 2 else { return }
        running = false
        status = "Stopped"
    }
}

struct WindowsPCView: View {
    @EnvironmentObject var app: SessionState
    @ObservedObject var pc = WinPC.shared
    @Environment(\.dismiss) private var dismiss
    @State private var window: SystemWindowMetrics?
    @State private var picking = false
    @State private var showKeyBar = true
    @State private var showKeyboard = false
    @State private var testRAM: Int?
    @State private var appliedTestArguments = false

    var body: some View {
        Group {
            if pc.running {
                SystemDisplay {
                    WinDisplay(keyboard: showKeyboard)
                } controls: {
                    SessionBackButton { dismiss() }
                    Button(pc.stopping ? "Stopping…" : "Stop", role: .destructive) {
                        showKeyboard = false
                        pc.stop()
                    }
                    .disabled(pc.stopping)
                    .accessibilityIdentifier("winpc-stop")
                    Button { showKeyboard.toggle() } label: {
                        Image(systemName: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
                    }
                    .accessibilityLabel("Keyboard")
                    .accessibilityIdentifier("winpc-keyboard")
                    Button { showKeyBar.toggle() } label: {
                        Image(systemName: "rectangle.bottomthird.inset.filled")
                    }
                    .accessibilityLabel(showKeyBar ? "Hide guest keys" : "Show guest keys")
                } bottom: {
                    if showKeyBar && !showKeyboard {
                        WinKeyBar().accessibilityIdentifier("winpc-keybar")
                    }
                }
            } else {
                ZStack {
                    TriptychBackdrop()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            TriptychPanelCard(accent: TriptychPalette.windowsLight, raised: true) {
                                Text("A virtual ARM64 PC with UEFI, NVMe, USB and a framebuffer, for Windows 11 on Arm and other ARM64 systems. Bring your own ISO; Triptych never downloads Windows or its keys.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(TriptychPalette.textSecondary)
                            }

                            if !EngineRegistry.isSimulator && !JIT.isEnabled {
                                TriptychNoticeBanner(
                                    symbol: "bolt.slash",
                                    text: "Needs JIT. Open Easel to enable it.",
                                    tint: TriptychPalette.warn
                                )
                                .accessibilityIdentifier("winpc-needs-jit")
                            }

                            TriptychSectionHeader(title: "Install media", accent: TriptychPalette.windowsLight)
                            TriptychPanelCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Button(pc.isoURL?.lastPathComponent ?? "Choose ISO from Files…") { picking = true }
                                        .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.windowsLight))
                                        .accessibilityIdentifier("winpc-pick-iso")
                                    Text(pc.status)
                                        .font(.footnote)
                                        .foregroundStyle(TriptychPalette.textSecondary)
                                        .accessibilityIdentifier("winpc-status")
                                }
                            }

                            hardwareSection

                            Button("Start") { start(ram: testRAM) }
                                .buttonStyle(TriptychPrimaryButtonStyle(panel: .windows, enabled: app.canStart(.winpc)))
                                .disabled(!app.canStart(.winpc))
                                .accessibilityIdentifier("winpc-start")

                            if let other = app.activeEngine, !app.canStart(.winpc) {
                                Text("\(other.title) is running and can't share this launch with the Windows PC.")
                                    .font(.footnote)
                                    .foregroundStyle(TriptychPalette.warn)
                                    .accessibilityIdentifier("winpc-locked")
                                SwitchSystemButton(kind: .winpc)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 28)
                        .triptychColumn()
                    }
                }
            }
        }
        .navigationTitle(EngineKind.winpc.title).navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
        .toolbar(pc.running ? .hidden : .visible, for: .navigationBar)
        .background {
            SystemWindowReader { metrics in
                window = metrics
                applyTestArguments()
            }
        }
        .task(id: pc.running) {
            while pc.running && !Task.isCancelled {
                pc.updateStopped()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data, .data]) { r in
            if case .success(let u) = r { pc.pick(u) }
        }
        .alert(EngineKind.winpc.title, isPresented: Binding(get: { pc.error != nil }, set: { if !$0 { pc.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(pc.error ?? "") }

    }

    private func start(ram: Int?) {
        guard let window else { return }
        pc.start(app: app, display: window.guestSize(longestEdge: 1920, minimumShortEdge: 800), ramMB: ram)
    }

    private var hardwareSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TriptychSectionHeader(title: "Virtual hardware", accent: TriptychPalette.windowsLight)
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Memory").font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                        Spacer()
                        Picker("Memory", selection: $pc.ramMB) {
                            ForEach(WinPC.ramChoices, id: \.self) { Text(Self.gb($0)).tag($0) }
                        }
                        .tint(TriptychPalette.windowsLight)
                        .accessibilityIdentifier("winpc-ram")
                    }
                    Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                    HStack {
                        Text("CPUs").font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                        Spacer()
                        Picker("CPUs", selection: $pc.cpus) { ForEach(WinPC.cpuChoices, id: \.self) { Text("\($0)").tag($0) } }
                            .tint(TriptychPalette.windowsLight)
                            .accessibilityIdentifier("winpc-cpus")
                    }
                    Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                    HStack {
                        Text("Disk").font(.system(size: 14)).foregroundStyle(TriptychPalette.textSecondary)
                        Spacer()
                        Text("64 GB NVMe (sparse)").font(.system(size: 14, weight: .medium)).foregroundStyle(TriptychPalette.textPrimary)
                    }
                    Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                    HStack {
                        Text("TPM 2.0").font(.system(size: 14)).foregroundStyle(TriptychPalette.textSecondary)
                        Spacer()
                        Text(winvm_host_has_tpm() != 0 ? "Yes (libtpms)" : "No (built without libtpms)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(TriptychPalette.textPrimary)
                            .accessibilityIdentifier("winpc-tpm")
                    }
                }
            }
            if pc.ramMB < 4096 || pc.cpus < 2 {
                Text("Windows 11 Setup needs at least 4 GB of memory and 2 CPUs.")
                    .font(.footnote)
                    .foregroundStyle(TriptychPalette.warn)
                    .padding(.horizontal, 4)
            }
        }
    }

    private static func gb(_ mb: Int) -> String { mb % 1024 == 0 ? "\(mb / 1024) GB" : String(format: "%.1f GB", Double(mb) / 1024) }

    /// Test and debugging hooks (UI tests can't drive the Files picker):
    ///   -winpc.noiso         forget the remembered ISO
    ///   -winpc.freshdisk     start from a blank disk, new UEFI variables and a new TPM
    ///   -winpc.iso <path>    pick that file as if from Files
    ///   -winpc.ram <MB>      memory for the firmware-only test (autostart defaults to 1024)
    ///   -winpc.autostart     start the board straight away
    private func applyTestArguments() {
        guard !appliedTestArguments else { return }
        appliedTestArguments = true
        let args: [String] = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("-winpc.noiso") { pc.forgetISO() }
        if args.contains("-winpc.freshdisk"), !pc.running {
            for u: URL in [pc.diskURL, pc.varsURL, pc.tpmURL] { try? FileManager.default.removeItem(at: u) }
        }
        if let p = value("-winpc.iso") { pc.pick(URL(fileURLWithPath: p)) }
        testRAM = value("-winpc.ram").flatMap(Int.init)
        if args.contains("-winpc.autostart"), !pc.running { start(ram: testRAM ?? 1024) }
    }
}

struct WinDisplay: UIViewRepresentable {
    var keyboard: Bool
    func makeUIView(context: Context) -> WinFBView { WinFBView() }
    func updateUIView(_ v: WinFBView, context: Context) { v.setSoftKeyboard(keyboard) }
    static func dismantleUIView(_ v: WinFBView, coordinator: ()) { v.stopDrawing() }
}

/// The guest's ramfb on a CALayer, touch as the USB tablet, hardware keys (HID usages) and the soft keyboard as the USB keyboard.
final class WinFBView: UIView, UIKeyInput {
    private var link: CADisplayLink?
    private var frames = 0
    private var fbSize = CGSize.zero
    private var lastPixels = Data()
    private var buttons = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; layer.contentsGravity = .resizeAspect
        isAccessibilityElement = true; accessibilityIdentifier = "winpc-display"; accessibilityTraits.insert(.updatesFrequently); accessibilityValue = "waiting for the guest display"
        isMultipleTouchEnabled = true
        addGestureRecognizer(longPress); addGestureRecognizer(scroll)
        link = CADisplayLink(target: self, selector: #selector(tick)); link?.preferredFramesPerSecond = 30; link?.add(to: .main, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { link?.invalidate() }
    func hasHardwareFocus() { _ = becomeFirstResponder() }
    /// The system keyboard appears only when the view becomes first responder while asking for it; the view is already
    /// first responder (for hardware keys), so toggling did nothing. Show it by resigning and becoming again with the
    /// software keyboard allowed, and hide it by swapping in an empty input view.
    private var wantsSoftKeyboard = false
    private let noKeyboard = UIView(frame: .zero)
    override var inputView: UIView? { wantsSoftKeyboard ? nil : noKeyboard }
    func setSoftKeyboard(_ on: Bool) {
        guard on != wantsSoftKeyboard else { return }
        wantsSoftKeyboard = on
        // Changing first responder inside SwiftUI's update pass re-enters the hosting view's graph and loops on an attribute cycle.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            _ = self.resignFirstResponder()
            _ = self.becomeFirstResponder()
            self.reloadInputViews()
            TriptychLog.log("winpc", "on-screen keyboard \(on ? "shown" : "hidden")")
        }
    }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }

    // Mouse beyond a left click: long press = right click, two-finger drag = scroll wheel.
    private lazy var longPress: UILongPressGestureRecognizer = {
        let g = UILongPressGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        g.minimumPressDuration = 0.5; g.cancelsTouchesInView = false; return g
    }()
    private lazy var scroll: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(wheel(_:)))
        g.minimumNumberOfTouches = 2; g.maximumNumberOfTouches = 2; g.cancelsTouchesInView = true; return g
    }()
    private var wheelRest: CGFloat = 0
    private func guestPoint(_ p: CGPoint) -> (Int32, Int32)? {
        guard fbSize.width > 0 else { return nil }
        let sc = min(bounds.width / fbSize.width, bounds.height / fbSize.height)
        let fit = CGSize(width: fbSize.width * sc, height: fbSize.height * sc)
        let o = CGPoint(x: (bounds.width - fit.width) / 2, y: (bounds.height - fit.height) / 2)
        let x = max(0, min(1, (p.x - o.x) / fit.width)), y = max(0, min(1, (p.y - o.y) / fit.height))
        return (Int32(x * 32767), Int32(y * 32767))
    }
    @objc private func rightClick(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let (x, y) = guestPoint(g.location(in: self)) else { return }
        buttons = 0
        winvm_host_tablet(x, y, 0, 0)          // the left press that started the touch: let go of it
        winvm_host_tablet(x, y, 2, 0)          // right button down and up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { winvm_host_tablet(x, y, 0, 0) }
    }
    @objc private func wheel(_ g: UIPanGestureRecognizer) {
        guard let (x, y) = guestPoint(g.location(in: self)) else { return }
        if g.state == .began { buttons = 0; winvm_host_tablet(x, y, 0, 0); wheelRest = 0 }
        let dy = g.translation(in: self).y; g.setTranslation(.zero, in: self)
        wheelRest += dy / 24                   // about one notch per 24 points, finger-down scrolls content up
        let notches = Int(wheelRest.rounded(.towardZero))
        if notches != 0 { wheelRest -= CGFloat(notches); winvm_host_tablet(x, y, 0, Int32(notches)) }
    }
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() {
        guard window != nil else { return }
        _ = becomeFirstResponder()
        // SwiftUI can take focus back while the cover animates in: ask again once it has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.window != nil else { return }
            let ok = self.isFirstResponder || self.becomeFirstResponder()
            TriptychLog.log("winpc", "display keyboard focus: \(ok ? "yes" : "no")")
        }
    }
    private var loggedKeys = 0

    func stopDrawing() { link?.invalidate(); link = nil }

    private struct Frame {
        var pixels = Data()
        var width = 0
        var height = 0
        var stride = 0
    }

    @objc private func tick() {
        var frame = Frame()
        withUnsafeMutablePointer(to: &frame) { framePtr in
            winvm_host_read_fb({ opaque, pixels, width, height, stride in
                guard let opaque, let pixels else { return }
                opaque.assumingMemoryBound(to: Frame.self).pointee = Frame(
                    pixels: Data(bytes: pixels, count: Int(stride) * Int(height)),
                    width: Int(width), height: Int(height), stride: Int(stride)
                )
            }, UnsafeMutableRawPointer(framePtr))
        }
        let w = frame.width, h = frame.height
        // An unchanged picture is not re-uploaded: constant commits keep the app from ever going idle for UI tests.
        if w > 0, w == Int(fbSize.width), h == Int(fbSize.height), frame.pixels == lastPixels {
            frames += 1
            return
        }
        lastPixels = frame.pixels
        guard w > 0, let provider = CGDataProvider(data: frame.pixels as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: frame.stride, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: [CGBitmapInfo.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        layer.contents = img
        let newSize = CGSize(width: Int(w), height: Int(h))
        let sizeChanged = newSize != fbSize
        fbSize = newSize; frames += 1
        // Rewriting the value every frame floods the accessibility tree and stalls UI queries.
        guard frames == 1 || sizeChanged || frames % 30 == 0 else { return }
        accessibilityValue = "fb \(w)x\(h) frames=\(frames) tpm=\(winvm_host_has_tpm() != 0 ? String(winvm_host_tpm_commands()) : "none") isoMB=\(winvm_host_iso_read_mb())"
    }

    /// The fitted picture inside the view (the layer letterboxes), so touches map to the guest's pixels.
    private func tablet(_ t: UITouch, down: Bool?) {
        guard fbSize.width > 0 else { return }
        let sc = min(bounds.width / fbSize.width, bounds.height / fbSize.height)
        let fit = CGSize(width: fbSize.width * sc, height: fbSize.height * sc)
        let o = CGPoint(x: (bounds.width - fit.width) / 2, y: (bounds.height - fit.height) / 2)
        let p = t.location(in: self)
        let x = max(0, min(1, (p.x - o.x) / fit.width)), y = max(0, min(1, (p.y - o.y) / fit.height))
        if let d = down { buttons = d ? 1 : 0 }
        winvm_host_tablet(Int32(x * 32767), Int32(y * 32767), Int32(buttons), 0)
    }
    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
        if !isFirstResponder { _ = becomeFirstResponder() } // a hardware keyboard types into whatever was tapped last
        // One finger is the mouse; a second finger means scrolling (the pan above), so the button lets go.
        if (e?.allTouches?.count ?? 1) > 1 { if let t = t.first { tablet(t, down: false) }; return }
        if let t = t.first { tablet(t, down: true) }
    }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) {
        guard (e?.allTouches?.count ?? 1) == 1, let t = t.first else { return }
        tablet(t, down: nil)
    }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { if let t = t.first { tablet(t, down: false) } }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { if let t = t.first { tablet(t, down: false) } }

    // Hardware keyboard: UIKeyboardHIDUsage raw values are the USB HID usages the board's keyboard wants.
    override func pressesBegan(_ presses: Set<UIPress>, with e: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for p in presses {
            guard let k = p.key else { unhandled.insert(p); continue }
            if loggedKeys < 20 { loggedKeys += 1; TriptychLog.log("winpc", "hardware key down: usage \(k.keyCode.rawValue)") }
            winvm_host_key(Int32(k.keyCode.rawValue), 1)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: e) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with e: UIPressesEvent?) {
        for p in presses { if let k = p.key { winvm_host_key(Int32(k.keyCode.rawValue), 0) } }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with e: UIPressesEvent?) { pressesEnded(presses, with: e) }

    // Soft keyboard (UIKeyInput): ASCII to HID usages.
    var hasText: Bool { true }
    func deleteBackward() { tap(0x2a, shift: false) }
    func insertText(_ text: String) {
        for ch in text.unicodeScalars {
            let c = Int(ch.value)
            switch c {
            case 97...122: tap(UInt8(4 + c - 97), shift: false)
            case 65...90: tap(UInt8(4 + c - 65), shift: true)
            case 49...57: tap(UInt8(0x1e + c - 49), shift: false)
            case 48: tap(0x27, shift: false)
            case 10: tap(0x28, shift: false)
            case 32: tap(0x2c, shift: false)
            case 45: tap(0x2d, shift: false)
            case 61: tap(0x2e, shift: false)
            case 46: tap(0x37, shift: false)
            case 44: tap(0x36, shift: false)
            case 47: tap(0x38, shift: false)
            case 59: tap(0x33, shift: false)
            case 9: tap(0x2b, shift: false)
            default: break
            }
        }
    }
    private func tap(_ u: UInt8, shift: Bool) {
        if shift { winvm_host_key(0xe1, 1) }
        winvm_host_key(Int32(u), 1)
        let generation = WinPC.shared.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard WinPC.shared.generation == generation else { return }
            winvm_host_key(Int32(u), 0)
            if shift { winvm_host_key(0xe1, 0) }
        }
    }
}


/// On-screen keys for what a touch keyboard can't send: boot menus need arrows and Enter, Setup needs Tab and
/// Shift+F10, Windows needs Esc, Win, Alt+Tab and Ctrl+Alt+Del. Modifiers latch for the next key (tap again to release).
struct WinKeyBar: View {
    @State private var latched: Set<Int32> = []
    private static let mods: [(String, Int32)] = [("Ctrl", 0xe0), ("Shift", 0xe1), ("Alt", 0xe2), ("Win", 0xe3)]
    private static let keys: [(String, Int32)] = [
        ("Esc", 0x29), ("Tab", 0x2b), ("◀︎", 0x50), ("▲", 0x52), ("▼", 0x51), ("▶︎", 0x4f), ("Enter", 0x28),
        ("⌫", 0x2a), ("Del", 0x4c), ("Space", 0x2c), ("Home", 0x4a), ("End", 0x4d), ("PgUp", 0x4b), ("PgDn", 0x4e),
    ] + (1...12).map { ("F\($0)", Int32(0x39 + $0)) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.mods, id: \.1) { m in
                    keyButton(m.0, on: latched.contains(m.1)) { if latched.contains(m.1) { latched.remove(m.1) } else { latched.insert(m.1) } }
                }
                keyButton("Ctrl+Alt+Del") { press(0x4c, with: [0xe0, 0xe2]) }
                ForEach(Self.keys, id: \.1) { k in keyButton(k.0) { press(k.1, with: latched); latched = [] } }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }

    private func keyButton(_ title: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold)).frame(minWidth: 34).padding(.horizontal, 10).padding(.vertical, 9)
                .background(on ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).accessibilityIdentifier("winpc-key-\(title)")
    }

    private func press(_ usage: Int32, with mods: Set<Int32>) {
        TriptychLog.log("winpc", "on-screen key: usage \(usage) mods \(mods.sorted())")
        let held = mods.sorted()
        DispatchQueue.global(qos: .userInteractive).async {
            for m in held { winvm_host_key(m, 1); usleep(15_000) }
            winvm_host_key(usage, 1); usleep(60_000); winvm_host_key(usage, 0)
            for m in held.reversed() { usleep(15_000); winvm_host_key(m, 0) }
        }
    }
}
