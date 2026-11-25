// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// One shared Settings screen for Triptych (JIT method & status, device memory, mouse/trackpad input,
/// Mac VM performance, Instant Resume, appearance, and diagnostics).
struct TriptychSettingsView: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = false
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    @AppStorage(VolumeClicks.swapKey) private var swapButtons = false
    @AppStorage(PhysicalMouseButtons.swapKey) private var swapMouseButtons = false
    @AppStorage(EngineTuning.refreshKey) private var refreshRate = 60
    @AppStorage(EngineTuning.fastFlushKey) private var fastFlush = true
    @AppStorage(EngineTuning.wfiSpinKey) private var wfiSpin = false
    @AppStorage(EngineTuning.superblocksKey) private var superblocks = false
    @AppStorage(JITBootstrap.codeCacheKey) private var codeCacheMB = JITBootstrap.defaultCodeCacheMB
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system
    @AppStorage(InstantResume.key) private var instantResume = false

    private var jitState: JITBootstrap.JITState {
        _ = jit.attachGeneration
        return JITBootstrap.state
    }

    private var inputDescription: String {
        if inputMode == .touchscreen {
            return "Tap to click once. Tap then hold to begin dragging. Quickly tap with two fingers to right-click."
        }
        switch volumeMode {
        case .delayHold:
            return "Delay hold waits to see if you're holding or just clicking the volume button, which makes all clicks ~0.5s long."
        case .tapThenDrag:
            return "Tap then drag clicks immediately; if held, it switches to dragging."
        case .intercept:
            return "Uses the camera pipeline to intercept volume keys like physical mouse buttons, at higher power/temperature."
        }
    }

    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    curatorAccountSection
                    jitSection
                    memorySection
                    inputSection
                    performanceSection
                    instantResumeSection
                    appearanceSection
                    diagnosticsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
    }

    // MARK: - Sections

    @State private var curatorSignedIn = false
    @State private var curatorLogin: String?
    @State private var showingCuratorSignIn = false
    @State private var curatorAccountRevision = 0

    private var reporter: GitHubReporter { CuratorUploadBridge.reporter }

    @ViewBuilder private var curatorAccountSection: some View {
        TriptychSectionHeader(title: "Curator", accent: TriptychPalette.macLight)
        TriptychPanelCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GitHub account")
                    Text(curatorLogin.map { "@\($0)" } ?? (curatorSignedIn ? "Signed in" : "Signed out"))
                        .foregroundStyle(TriptychPalette.textSecondary)
                        .accessibilityIdentifier("curator-account-status")
                }
                Spacer()
                if curatorSignedIn {
                    Button("Sign out") {
                        reporter.signOut()
                        curatorSignedIn = reporter.isSignedIn
                        curatorLogin = nil
                        curatorAccountRevision += 1
                    }
                    .accessibilityIdentifier("curator-sign-out")
                } else if reporter.canSignInWithOAuth {
                    Button("Sign in with GitHub") { showingCuratorSignIn = true }
                        .accessibilityIdentifier("curator-settings-sign-in")
                }
            }
        }
        .task(id: curatorAccountRevision) {
            curatorSignedIn = reporter.isSignedIn
            guard curatorSignedIn else { return }
            let login = try? await reporter.accountLogin()
            guard !Task.isCancelled else { return }
            curatorLogin = login
            curatorSignedIn = reporter.isSignedIn
        }
        .fullScreenCover(isPresented: $showingCuratorSignIn, onDismiss: { curatorAccountRevision += 1 }) {
            CuratorGitHubSignInView(reporter: reporter)
        }
    }

    @ViewBuilder private var jitSection: some View {
        TriptychSectionHeader(title: "JIT", accent: TriptychPalette.macLight)
        TriptychPanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Status")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(TriptychPalette.textPrimary)
                    Spacer()
                    Text(JITBootstrap.statusText(jitState))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(jitState == .on ? TriptychPalette.good : TriptychPalette.textSecondary)
                        .accessibilityIdentifier("settings-jit-status")
                }

                if case .failed(let why) = jitState {
                    Text(why)
                        .font(.system(size: 12))
                        .foregroundStyle(TriptychPalette.bad)
                }

                divider

                HStack {
                    Text("Method")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(TriptychPalette.textPrimary)
                    Spacer()
                    Picker("Method", selection: $jit.method) {
                        ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                    }
                    .tint(TriptychPalette.macLight)
                }

                Text(jit.method == .automatic ? jit.automaticDescription : "Triptych uses \(jit.method.title).")
                    .font(.system(size: 12))
                    .foregroundStyle(TriptychPalette.textSecondary)

                NavigationLink { SetupView() } label: {
                    Label("Easel · JIT & Image Setup", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.macLight))
                .accessibilityIdentifier("settings-open-setup")

                divider

                Toggle("Turn on JIT when Triptych opens", isOn: $jitAtLaunch)
                    .font(.system(size: 15))
                    .foregroundStyle(TriptychPalette.textPrimary)
                    .tint(TriptychPalette.macDeep)

                if jitAtLaunch {
                    Text("Triptych connects LocalDevVPN first when it is off, then returns.")
                        .font(.system(size: 12))
                        .foregroundStyle(TriptychPalette.textSecondary)
                }

                divider

                infoRow("Code region", "\(JITBootstrap.jitBytes >> 20) MB, claimed once per launch")
                infoRow(
                    "Trusted Execution Monitor",
                    TXMDetection.fromDeviceTree == nil
                        ? (JITBootstrap.deviceEnforcesTXM ? "Expected for this model" : "Not expected for this model")
                        : (JITBootstrap.deviceEnforcesTXM ? "Present" : "Not present")
                )
            }
        }
    }

    @ViewBuilder private var memorySection: some View {
        TriptychSectionHeader(title: "Memory", accent: TriptychPalette.windowsLight)
        TriptychPanelCard {
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Extra memory entitlement", Entitlements.increasedMemory ? "On" : "Off")
                divider
                infoRow("App memory limit", Entitlements.memoryLimitAtLaunch == 0 && EngineRegistry.isSimulator ? "Unlimited (Simulator)" : ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                divider
                let freeMem = henge_available_memory()
                infoRow("Free for Triptych", freeMem == 0 && EngineRegistry.isSimulator ? "Unlimited (Simulator)" : ByteText.string(UInt64(freeMem)))
                Text(
                    Entitlements.increasedMemory
                        ? "Guest memory is kept outside this limit once JIT is on. If iOS refuses that, Triptych backs it with storage."
                        : "This install is not signed with the increased memory limit entitlement."
                )
                .font(.system(size: 12))
                .foregroundStyle(TriptychPalette.textSecondary)
            }
        }
    }

    @ViewBuilder private var inputSection: some View {
        if Device.isPad {
            TriptychSectionHeader(title: "Mouse and Trackpad", accent: TriptychPalette.macLight)
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Pointer speed").font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                            Spacer()
                            Text(String(format: "%.1fx", mouseSpeed)).font(.system(size: 13)).foregroundStyle(TriptychPalette.textSecondary)
                        }
                        Slider(value: $mouseSpeed, in: 0.5...3).tint(TriptychPalette.macLight)
                    }
                    divider
                    Toggle("Reverse scrolling", isOn: $reverseScrolling)
                        .font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary).tint(TriptychPalette.macDeep)
                    divider
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Scroll speed").font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                            Spacer()
                            Text(String(format: "%.1fx", scrollSpeed)).font(.system(size: 13)).foregroundStyle(TriptychPalette.textSecondary)
                        }
                        Slider(value: $scrollSpeed, in: 0.1...1.5).tint(TriptychPalette.macLight)
                    }
                    divider
                    Toggle("Swap physical right and middle buttons", isOn: $swapMouseButtons)
                        .font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary).tint(TriptychPalette.macDeep)
                    Text("Only enable this if your physical mouse's right and middle buttons are reversed in macOS. Pointer speed applies on next Mac start.")
                        .font(.system(size: 12))
                        .foregroundStyle(TriptychPalette.textSecondary)
                }
            }
        } else {
            TriptychSectionHeader(title: "Trackpad", accent: TriptychPalette.macLight)
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Input mode").font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                        Spacer()
                        Picker("Input mode", selection: $inputMode) {
                            Text("Touchscreen").tag(VolumeClicks.InputMode.touchscreen)
                            Text("Volume buttons").tag(VolumeClicks.InputMode.volumeButtons)
                        }
                        .tint(TriptychPalette.macLight)
                    }
                    if inputMode == .volumeButtons {
                        divider
                        HStack {
                            Text("Button mode").font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                            Spacer()
                            Picker("Button mode", selection: $volumeMode) {
                                Text("Delay hold").tag(VolumeClicks.Mode.delayHold)
                                Text("Tap then drag").tag(VolumeClicks.Mode.tapThenDrag)
                                Text("Camera intercept").tag(VolumeClicks.Mode.intercept)
                            }
                            .tint(TriptychPalette.macLight)
                        }
                        divider
                        Toggle("Swap buttons", isOn: $swapButtons)
                            .font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary).tint(TriptychPalette.macDeep)
                    }
                    Text("Triptych emulates a Magic Trackpad for macOS gestures.\n\n\(inputDescription)")
                        .font(.system(size: 12))
                        .foregroundStyle(TriptychPalette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private var performanceSection: some View {
        TriptychSectionHeader(title: "Mac Performance", accent: TriptychPalette.macLight)
        TriptychPanelCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mac refresh rate").font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                    Picker("Mac refresh rate", selection: $refreshRate) {
                        Text("30 Hz").tag(30)
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }
                    .pickerStyle(.segmented)
                }
                divider
                Toggle("Faster disk writes", isOn: $fastFlush)
                    .font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary).tint(TriptychPalette.macDeep)
                divider
                Toggle("Quicker wake from idle", isOn: $wfiSpin)
                    .font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary).tint(TriptychPalette.macDeep)
                divider
                Toggle("Superblocks (experimental)", isOn: $superblocks)
                    .font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary).tint(TriptychPalette.macDeep)
                divider
                HStack {
                    Text("Code cache").font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                    Spacer()
                    Picker("Code cache", selection: $codeCacheMB) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("1.5 GB").tag(1536)
                    }
                    .tint(TriptychPalette.macLight)
                }
                Text("A larger code cache flushes less often and takes ~1.75x its size in memory. Changes apply the next time Triptych opens or a Mac starts.")
                    .font(.system(size: 12))
                    .foregroundStyle(TriptychPalette.textSecondary)
            }
        }
    }

    @ViewBuilder private var instantResumeSection: some View {
        TriptychSectionHeader(title: "Instant Resume", accent: TriptychPalette.linuxLight)
        TriptychPanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Resume where you left off", isOn: $instantResume)
                    .font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary).tint(TriptychPalette.macDeep)
                Text("When leaving Triptych, a running Mac is saved to storage and resumes quickly on return. Experimental.")
                    .font(.system(size: 12))
                    .foregroundStyle(TriptychPalette.textSecondary)
            }
        }
    }

    @ViewBuilder private var appearanceSection: some View {
        TriptychSectionHeader(title: "Appearance", accent: TriptychPalette.windowsLight)
        TriptychPanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(DeskAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Triptych uses its dark navy theme across its screens; this preference controls guest session windows.")
                    .font(.system(size: 12))
                    .foregroundStyle(TriptychPalette.textSecondary)
            }
        }
    }

    @ViewBuilder private var diagnosticsSection: some View {
        TriptychSectionHeader(title: "Diagnostics & Info", accent: TriptychPalette.hinge)
        TriptychPanelCard {
            VStack(alignment: .leading, spacing: 12) {
                ExportLogsButton()
                divider
                NavigationLink { AboutView() } label: {
                    HStack {
                        Label("About and licences", systemImage: "info.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TriptychPalette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TriptychPalette.textMuted)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(TriptychPalette.textSecondary)
            Spacer()
            Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(TriptychPalette.textPrimary)
        }
    }

    private var divider: some View {
        Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
    }
}
