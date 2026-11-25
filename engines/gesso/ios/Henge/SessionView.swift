import SwiftUI
import GameController

/// A running Mac, with its display and trackpad filling the current window.
struct SessionView: View {
    let mac: VirtualMac
    let close: () -> Void

    @StateObject private var display = DisplayRouter()
    @State private var error: String?
    @State private var state: Int32 = 0
    @State private var bootAttempt = 0
    @State private var cpusOn: Int32 = 0
    @State private var userCode = false
    @State private var blocksPerSecond: Double = 0
    @State private var framesOut: UInt64 = 0
    @State private var framesIn: UInt64 = 0
    @State private var log: [String] = []
    @State private var started = Date()
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @State private var bootRAM: UInt64 = 0 /* what the Mac was started with, which a save is for */
    @AppStorage("henge.cpus") private var cpus = 4
    @AppStorage("henge.matchScreenColors") private var matchScreenColors = true
    @AppStorage("henge.display.brightness") private var screenBrightness = 1.0
    @AppStorage("henge.cursor.scale") private var cursorScale = Device.isPad ? 1 : 3
    @AppStorage("henge.cursor.sharp") private var sharpCursor = true
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3

    @State private var window: SystemWindowMetrics?
    @State private var typing = false
    @State private var zoomed = false
    @State private var showDetails = false
    @State private var pointerRefused = false
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    /// Once per install: macOS's moving wallpapers and aerial screen saver are video, decoded by the emulated
    /// CPUs (a phone ran about 30% faster with a still one).
    @AppStorage("henge.tips.stillWallpaperShown") private var stillWallpaperTipShown = false
    @State private var showWallpaperTip = false
    @State private var confirmStop = false
    @State private var zoomCentre = CGPoint(x: 0.5, y: 0.5) // where the zoomed view is, 0...1 of the Mac's screen
    @State private var map: UIImage?
    @State private var zoomFollowing: Task<Void, Never>?
    @State private var helperRunning = false
    @State private var shown = CGSize(width: 0.5, height: 0.5) // how much of the Mac's screen the zoomed view shows
    @Environment(\.scenePhase) private var scenePhase


    var body: some View {
        SystemDisplay {
            GeometryReader { geo in
                let layout = Layout(size: geo.size, zoomed: zoomed, centre: zoomCentre)
                ZStack(alignment: .topLeading) {
                    Color.black
                    BootDisplay(display: display, role: .device)
                        .opacity(display.isExternal ? 0 : 1)
                        .frame(width: layout.screen.width, height: layout.screen.height)
                        .position(x: layout.screen.midX, y: layout.screen.midY)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Mac display")
                        .accessibilityIdentifier("mac-display")
                        .allowsHitTesting(false)
                    if display.isExternal && state != 2 {
                        Label("Mac on external display", systemImage: "display")
                            .position(x: layout.touch.midX, y: layout.touch.midY)
                    }
                    if state != 2 {
                        Trackpad()
                            .frame(width: layout.touch.width, height: layout.touch.height)
                        if inputMode == .volumeButtons && volumeMode == .intercept {
                            CaptureInteractionView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .allowsHitTesting(false)
                        }
                        if pointerRefused {
                            Label("Make Triptych full screen to use the trackpad or mouse as the Mac's", systemImage: "cursorarrow.rays")
                                .font(.footnote)
                                .padding(12)
                                .deskGlass(in: Capsule())
                                .position(x: layout.touch.midX, y: layout.touch.height - 68)
                                .allowsHitTesting(false)
                        }
                        if showWallpaperTip {
                            Text("For more speed, give this Mac a still wallpaper and set its screen saver to Never in System Settings.")
                                .font(.footnote)
                                .padding(12)
                                .deskGlass(in: Capsule())
                                .frame(maxWidth: 520)
                                .position(x: layout.touch.midX, y: layout.touch.height - 110)
                                .allowsHitTesting(false)
                        }
                    } else {
                        StoppedMacView(outcome: henge_vm_exit_outcome(), reason: String(cString: henge_vm_exit_reason()),
                                       start: { bootAttempt += 1 }, close: close)
                            .frame(width: min(max(0, layout.touch.width - 32), 360))
                            .position(x: layout.touch.midX, y: layout.touch.midY)
                    }
                    if let error { errorCard(error, layout) }
                    if zoomed { zoomMap(layout) }
                    KeyboardCatcher(active: $typing).frame(width: 0, height: 0)
                }
                .clipped()
                .animation(.easeInOut(duration: 0.25), value: zoomed)
                .animation(.easeInOut(duration: 0.25), value: showWallpaperTip)
                .onAppear { shown = layout.shown }
                .onChange(of: layout.shown) { shown = $0 }
            }
        } controls: {
            SessionBackButton { stopTapped() }
            if state != 2 {
                tool("keyboard", "Keyboard") { typing.toggle() }
                pasteTool
                tool(zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomed ? "Zoom out" : "Zoom in") { zoomed.toggle() }
                tool("info.circle", "Details") { showDetails = true }
                tool("power", "Shut down", tint: Desk.bad) { stopTapped() }
            }
        }
        .background {
            SystemWindowReader { metrics in
                window = metrics
                let engineState = henge_vm_state()
                if engineState == 1 || engineState == 4 { setDisplay(metrics) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPointerLockState.didChangeNotification)) { _ in
            pointerRefused = PointerLock.refused
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pointerRefused = PointerLock.refused }
        }
        .sheet(isPresented: $showDetails) { details }
        .confirmationDialog("Shut down \(mac.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Shut Down", role: .destructive) { finish() }
        } message: {
            Text("This turns the Mac off at once. Anything not saved on it is lost.")
        }
        .onChange(of: zoomed) { on in
            zoomFollowing?.cancel()
            zoomFollowing = on ? Task { await followPointer() } : nil
        }
        .onChange(of: pointerNeeded) { PointerLock.set(!$0) }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else {
                display.refresh()
                InstantResume.cameBack(mac)
                return
            }
            HardwareKeys.releaseAll()
            HardwareMouse.shared.releaseButtons()
            VolumeClicks.shared.releaseButtons()
            if phase == .inactive { InstantResume.pause() }
            if phase == .background && bootRAM > 0 { InstantResume.suspend(mac, ramMB: bootRAM, cpus: cpus) }
        }
        .onChange(of: showDetails) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onChange(of: confirmStop) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            HengeAudio.shared.activate()
            HardwareMouse.shared.start()
            VolumeClicks.shared.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            zoomFollowing?.cancel()
            StickyKeys.shared.releaseAll()
            HardwareKeys.releaseAll()
            HardwareMouse.shared.stop()
            VolumeClicks.shared.stop()
        }
        .modifier(ExternalMacDisplayModifier(presentation: MacPresentation(display: display, aspect: displayAspect)))
        .task(id: window == nil ? nil : bootAttempt) {
            guard let window else { return }
            setDisplay(window)
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-mac.display-preview") { return }
            #endif
            await run()
        }
        .task { await Sharing.followMacClipboard() }
    }

    /// When there is something of the app's to point at, iPadOS gets its own pointer back.
    private var pointerNeeded: Bool { state == 2 || showDetails || confirmStop || error != nil }

    // MARK: Layout

    /// Where everything goes, in points from the device's top left corner.
    private struct Layout {
        let screen: CGRect
        let touch: CGRect     // what is a trackpad besides the pad itself
        var shown: CGSize {
            CGSize(width: min(touch.width / max(screen.width, 1), 1), height: min(touch.height / max(screen.height, 1), 1))
        }

        init(size: CGSize, zoomed: Bool, centre: CGPoint) {
            touch = CGRect(origin: .zero, size: size)
            let width = size.width * (zoomed ? 2 : 1)
            let height = size.height * (zoomed ? 2 : 1)
            let x = min(0, max(size.width - width, size.width / 2 - centre.x * width))
            let y = min(0, max(size.height - height, size.height / 2 - centre.y * height))
            screen = CGRect(x: x, y: y, width: width, height: height)
        }
    }

    private func guestSize(_ metrics: SystemWindowMetrics) -> GuestDisplaySize {
        metrics.guestSize(longestEdge: CGFloat(max(mac.screen.width, mac.screen.height)), minimumShortEdge: 640)
    }

    private var displayAspect: CGFloat {
        guard let window else { return mac.aspect }
        let size = guestSize(window)
        return CGFloat(size.width) / CGFloat(size.height)
    }

    private func setDisplay(_ metrics: SystemWindowMetrics) {
        let size = guestSize(metrics)
        if mac.isRetina {
            henge_vm_set_display_mm(UInt32((Double(size.width) / 264 * 25.4).rounded()),
                                    UInt32((Double(size.height) / 264 * 25.4).rounded()))
        } else {
            henge_vm_set_display_mm(0, 0)
        }
        henge_vm_set_display(UInt32(size.width), UInt32(size.height))
        HengeLog.log("session", "screen \(size.width)x\(size.height) retina \(mac.isRetina)")
    }

    /// The system's paste button: iOS asks no permission for it, as it would if the app read the clipboard itself.
    private var pasteTool: some View {
        PasteButton(payloadType: String.self) { texts in
            if let text = texts.first { Sharing.paste(text) }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .tint(Desk.raised)
    }

    private func tool(_ symbol: String, _ label: String, tint: Color = Desk.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// The whole screen, small, with where the zoomed view is on it.
    private func zoomMap(_ layout: Layout) -> some View {
        let width: CGFloat = 92, height = width / displayAspect
        let viewW = min(layout.touch.width / layout.screen.width, 1) * width
        let viewH = min(layout.touch.height / layout.screen.height, 1) * height
        let left = (-layout.screen.minX / layout.screen.width) * width
        let top = (-layout.screen.minY / layout.screen.height) * height
        return ZStack(alignment: .topLeading) {
            Color.black
            if let map { Image(uiImage: map).resizable() }
            RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5)
                .frame(width: viewW, height: viewH)
                .offset(x: left, y: top)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(3)
        .deskGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .position(x: layout.touch.width - width / 2 - 15, y: layout.touch.height - height / 2 - 25)
        .allowsHitTesting(false)
    }

    /// Keeps the pointer in view: the view moves when the pointer nears its edge.
    private func followPointer() async {
        var tick = 0
        while !Task.isCancelled {
            var x: Int32 = 0, y: Int32 = 0
            if let window, henge_vm_pointer(&x, &y) == 0 {
                let size = guestSize(window)
                moveZoom(toward: CGPoint(x: CGFloat(x) / CGFloat(size.width), y: CGFloat(y) / CGFloat(size.height)))
            }
            if tick % 60 == 0, let image = MacPreview.capture(width: 224, height: Int(224 / displayAspect)) { map = UIImage(cgImage: image) }
            tick += 1
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private func moveZoom(toward p: CGPoint) {
        // How much of the screen the view shows, and a margin inside that.
        let shownX = shown.width, shownY = shown.height
        let reachX = shownX * 0.3, reachY = shownY * 0.3
        var c = zoomCentre
        if p.x < c.x - reachX { c.x = p.x + reachX } else if p.x > c.x + reachX { c.x = p.x - reachX }
        if p.y < c.y - reachY { c.y = p.y + reachY } else if p.y > c.y + reachY { c.y = p.y - reachY }
        c.x = min(max(c.x, shownX / 2), 1 - shownX / 2)
        c.y = min(max(c.y, shownY / 2), 1 - shownY / 2)
        guard c != zoomCentre else { return }
        withAnimation(.linear(duration: 0.08)) { zoomCentre = c }
    }

    // MARK: Status

    private func errorCard(_ text: String, _ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Mac could not start").font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim)
            Button("Close") { close() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(18)
        .frame(width: min(max(0, layout.touch.width - 32), 358), alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: layout.touch.midX, y: layout.touch.midY)
    }

    private var phase: String {
        switch state {
        case 0: return error == nil ? "Starting…" : "Not started"
        case 1: return userCode ? "macOS is running" : "Booting"
        case 3: return "Finishing shutdown…"
        default: return "Stopped (\(String(cString: henge_vm_exit_reason())))"
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section(phase) {
                    LabeledContent("CPUs on", value: "\(cpusOn) of \(cpus)")
                    LabeledContent("Temperature", value: Self.thermalLabel(thermalState))
                    LabeledContent("Translated blocks", value: String(format: "%.1f M/s", blocksPerSecond / 1e6))
                    LabeledContent("Network frames", value: "\(framesOut) out, \(framesIn) in")
                    LabeledContent("Up", value: "\(Int(Date().timeIntervalSince(started))) s")
                }
                Section("Display") {
                    Toggle("Color matching", isOn: $matchScreenColors)
                    LabeledContent("Brightness", value: "\(Int(screenBrightness * 100))%")
                    Slider(value: $screenBrightness, in: 0.4...1)
                    Text("Brightness dims only the Mac's screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Pointer") {
                    Picker("Size", selection: $cursorScale) {
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                        Text("3×").tag(3)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Sharp edges", isOn: $sharpCursor)
                    LabeledContent("Scroll speed", value: String(format: "%.1f×", scrollSpeed))
                    Slider(value: $scrollSpeed, in: 0.1...1.5)
                    Text("The Mac supplies a small pointer image. Enlarging it can look blurry; 1× is the sharpest on an iPad. Scroll speed changes apply immediately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sharing") {
                    LabeledContent("Clipboard and folder", value: helperRunning ? "On" : "Not set up")
                    if !helperRunning {
                        Button("Type the Set Up Command") {
                            showDetails = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await Sharing.typeSetUpCommand()
                            }
                        }
                    }
                    Text(helperRunning
                         ? "Put files in Files, Triptych, Shared to see them in the shared folder in this Mac's home folder. What you copy on the Mac is copied here too, and the paste button pastes from here into the Mac."
                         : "Once for each Mac: open Terminal on the Mac, tap this, then press Return. Choose Allow when macOS asks for local network access for the sharing helper. The command needs the Mac's U.S. keyboard layout.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Lighter macOS") {
                    Button("Type the Lighter macOS Command") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.lightenCommand)
                        }
                    }
                    Button("Type the Undo Command") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.unlightenCommand)
                        }
                    }
                    Text("Less drawing for the emulated CPUs: window and Dock animations, desktop widgets, the screen saver and a moving wallpaper go. Open Terminal on the Mac, tap the button and press Return, then log out and back in. Also turn on Reduce Motion and Reduce Transparency in the Mac's System Settings, Accessibility. Undo puts it back, apart from the wallpaper. Needs the Mac's keyboard layout to be U.S.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Log") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.suffix(30).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Running

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot — performance reduced"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func run() async {
        error = nil
        state = 0
        userCode = false
        cpusOn = 0
        blocksPerSecond = 0
        framesOut = 0
        framesIn = 0
        zoomed = false
        zoomCentre = CGPoint(x: 0.5, y: 0.5)
        map = nil
        showWallpaperTip = false
        while henge_vm_state() == 3 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !Task.isCancelled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        HardwareMouse.shared.start()
        let ram = GuestMemory.prepare(mac)
        HengeLog.log("session", "available memory \(henge_available_memory() >> 20) MB")
        guard ram >= 1024 else {
            error = "There is not room for this Mac's memory: it needs a few GB of free storage."
            return
        }
        var buffer = [CChar](repeating: 0, count: 256)
        JITBootstrap.releaseLingeringDebugger()
        Sharing.prepare()
        EngineTuning.apply()
        // About This Mac's chip: this device's ("Apple A20 Pro"), where it said "Apple M1 (Virtual)". henge-env.txt can name another.
        if getenv("HV_SOC_NAME") == nil, let chip = Device.chipName {
            setenv("HV_SOC_NAME", String(chip.prefix(31)), 1)
            HengeLog.log("session", "chip name for the Mac: \(chip)")
        }
        var rc: Int32 = -1
        if InstantResume.enabled, let at = InstantResume.saved(for: mac, ramMB: ram, cpus: cpus) {
            HengeLog.log("resume", "picking up the Mac saved \(Int(Date().timeIntervalSince(at))) s ago")
            let t0 = Date()
            rc = henge_vm_resume(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, ram, Int32(cpus),
                                 InstantResume.file(for: mac).path, InstantResume.ident(for: mac, ramMB: ram, cpus: cpus), &buffer, buffer.count)
            if rc == 0 {
                HengeLog.log("resume", String(format: "resumed in %.1f s", Date().timeIntervalSince(t0)))
            } else {
                HengeLog.log("resume", "could not resume (\(String(cString: buffer))); starting it from cold")
                buffer = [CChar](repeating: 0, count: 256)
            }
        }
        InstantResume.discard(for: mac) /* used or out of date: the disk moves on from here */
        if rc != 0 {
            rc = henge_vm_boot(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, ram, Int32(cpus), &buffer, buffer.count)
        }
        if rc != 0 {
            error = String(cString: buffer)
            return
        }
        bootRAM = ram
        started = Date()
        var used = mac
        used.lastUsed = started
        Machines.shared.update(used)
        var lastBlocks = henge_vm_blocks()
        var lastTime = Date()
        var lastGPUFrames = henge_vm_gpu_frames()
        var tick = 0
        while !Task.isCancelled {
            state = henge_vm_state()
            if state == 3 || state == 4 { /* starting, stopping, or paused while Henge is in the background */
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            cpusOn = henge_vm_cpus_on()
            userCode = userCode || henge_vm_guest_el0() != 0
            let now = Date(), blocks = henge_vm_blocks()
            blocksPerSecond = Double(blocks &- lastBlocks) / max(now.timeIntervalSince(lastTime), 0.001)
            lastBlocks = blocks
            lastTime = now
            framesOut = henge_vm_net_frames(1)
            framesIn = henge_vm_net_frames(0)
            helperRunning = Sharing.helperRunning
            log = Array(HengeLog.recentLines(200))
            let heat = ProcessInfo.processInfo.thermalState
            if heat.rawValue != thermalState.rawValue {
                thermalState = heat
                HengeLog.log("session", "thermal state: \(Self.thermalLabel(heat))")
            }
            if state == 2 {
                typing = false
                showDetails = false
                confirmStop = false
                zoomFollowing?.cancel()
                StickyKeys.shared.releaseAll()
                HardwareKeys.releaseAll()
                HardwareMouse.shared.stop()
                UIApplication.shared.isIdleTimerDisabled = false
                HengeLog.log("session", "showing stopped Mac: \(String(cString: henge_vm_exit_reason()))")
                if henge_vm_exit_outcome() == Int32(HENGE_VM_OUTCOME_RESTART.rawValue) && henge_vm_can_start() != 0 {
                    bootAttempt += 1
                }
                break
            }
            tick += 1
            if tick % 10 == 0 {
                let gpuFrames = henge_vm_gpu_frames()
                HengeLog.log("perf", "blocks/s \(String(format: "%.0f", blocksPerSecond)), GPU frames/10s \(gpuFrames &- lastGPUFrames), "
                             + "network tx \(framesOut), rx \(framesIn), dns \(henge_vm_dns(0)) answered \(henge_vm_dns(2)) unanswered, "
                             + "thermal \(Self.thermalLabel(heat))")
                lastGPUFrames = gpuFrames
                JITBootstrap.releaseLingeringDebugger()
            }
            if tick == 60 && !stillWallpaperTipShown { // about when the desktop is up after a login
                stillWallpaperTipShown = true
                showWallpaperTip = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { showWallpaperTip = false }
            }
            if tick % 30 == 0 { HengeLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
            if tick % 60 == 0 { MacPreview.save(for: mac) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func stopTapped() {
        let engineState = henge_vm_state()
        if engineState == 1 || engineState == 4 { confirmStop = true } else { close() }
    }

    private func finish() {
        if state == 1 || state == 4 {
            MacPreview.saveNow(for: mac)
            henge_vm_stop()
        }
        InstantResume.discard(for: mac) /* turned off: nothing to pick up */
        close()
    }
}
