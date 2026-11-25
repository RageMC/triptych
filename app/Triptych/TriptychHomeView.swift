// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Home screen: three hinged panels (Windows, Mac, Linux), each opening its system's machines and apps,
/// plus direct engine cards, shared Setup, Settings, Export logs, and About.
struct TriptychHomeView: View {
    @EnvironmentObject var session: SessionState
    @ObservedObject private var machines = Machines.shared
    @State private var jitOn = JIT.isEnabled
    @State private var confirmWindows = false
    @State private var windowsError: String?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                TriptychBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        hingedPanelsHero

                        if let a = session.activeEngine {
                            TriptychNoticeBanner(
                                symbol: "bolt.circle.fill",
                                text: SessionState.canShareLaunch.contains { $0.contains(a) && $0.count > 1 }
                                    ? "\(a.title) is running. Systems that can share a launch start alongside it; any other restarts Triptych into it (one tap)."
                                    : "\(a.title) is running. Opening another system restarts Triptych into it (one tap).",
                                tint: a.panel.accent
                            )
                        }

                        TriptychSectionHeader(title: "Systems", accent: TriptychPalette.hinge)
                        systemsCards

                        TriptychSectionHeader(title: "Easel & Settings", accent: TriptychPalette.macLight)
                        setupAndSettingsRow

                        TriptychSectionHeader(title: "Help & Credits", accent: TriptychPalette.hinge)
                        helpAndAboutCards
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .triptychColumn()
                }
            }
            .navigationTitle("Triptych")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { SetupView() } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(jitOn ? TriptychPalette.good : TriptychPalette.warn)
                                .frame(width: 7, height: 7)
                            Text(jitOn ? "Easel · JIT On" : "Easel")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .accessibilityIdentifier("home-toolbar-setup")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { TriptychSettingsView() } label: {
                        Image(systemName: "gearshape")
                            .accessibilityLabel("Settings")
                    }
                    .accessibilityIdentifier("home-toolbar-settings")
                }
            }
            .confirmationDialog("Start Pane?", isPresented: $confirmWindows, titleVisibility: .visible) {
                Button("Start Pane") { windowsError = WindowsLauncher.start(session) }
            } message: {
                Text("Quit and reopen Triptych to switch systems after starting Pane.")
            }
            .alert("Pane", isPresented: Binding(get: { windowsError != nil }, set: { if !$0 { windowsError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(windowsError ?? "") }
            .navigationDestination(for: TriptychPanel.self) { panel in
                switch panel {
                case .windows: WindowsHubView(confirmWindows: $confirmWindows)
                case .mac: MacSystemView()
                case .linux: LinuxHubView()
                }
            }
            .navigationDestination(for: EngineKind.self) { kind in
                // A system this launch can't run alongside the current one: offer the one-tap restart instead of its page.
                if EngineRegistry.availability(kind) == .ready, !session.canStart(kind), !session.started.contains(kind) {
                    SwitchSystemView(kind: kind)
                } else {
                switch kind {
                case .macos: MacSystemView()
                case .linux: LinuxView()
                case .winpc: WindowsPCView()
                case .x86pc: X86PCView()
                case .macapps: MacAppLibraryView()
                default: EngineInfoView(kind: kind)
                }
                }
            }
            .task {
                // The JIT region is claimed once per launch while the debugger is fresh; a Mac app (CrossOver) opened first
                // otherwise found none. Claim it here, as soon as a debugger is attached.
                for _ in 0..<100 where !JITBootstrap.prewarmed {
                    if JITBootstrap.debuggedFlag || JITBootstrap.canGrantOwnJIT {
                        TriptychMacBoot.start() // the trap guard and Henge's logs, which the claim needs
                        let ok = JITBootstrap.prewarm()
                        TriptychLog.log("jit", "claimed at launch from Home: \(ok ? "yes" : "no") (\(JITBootstrap.statusText(JITBootstrap.state)))")
                        jitOn = JIT.isEnabled
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            .onAppear {
                if let k = Relaunch.takePending() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { path.append(k) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                jitOn = JIT.isEnabled
            }
        }
    }

    // MARK: - Three Hinged Panels Hero

    private var hingedPanelsHero: some View {
        HStack(alignment: .bottom, spacing: 2) {
            NavigationLink(value: TriptychPanel.windows) {
                HingedPanelCard(
                    panel: .windows,
                    badge: panelBadge(.windows),
                    isCenter: false
                )
            }
            .buttonStyle(TriptychCardButtonStyle())
            .accessibilityIdentifier("panel-windows")
            .accessibilityHint("Opens the Windows panel")

            TriptychHingeStrip()

            NavigationLink(value: TriptychPanel.mac) {
                HingedPanelCard(
                    panel: .mac,
                    badge: panelBadge(.mac),
                    isCenter: true
                )
            }
            .buttonStyle(TriptychCardButtonStyle())
            .accessibilityIdentifier("panel-mac")
            .accessibilityHint("Opens the Mac panel")

            TriptychHingeStrip()

            NavigationLink(value: TriptychPanel.linux) {
                HingedPanelCard(
                    panel: .linux,
                    badge: panelBadge(.linux),
                    isCenter: false
                )
            }
            .buttonStyle(TriptychCardButtonStyle())
            .accessibilityIdentifier("panel-linux")
            .accessibilityHint("Opens the Linux panel")
        }
        .padding(.top, 4)
    }

    private func panelBadge(_ panel: TriptychPanel) -> String {
        switch panel {
        case .windows:
            return "Games & PC"
        case .mac:
            let count = machines.all.count
            return count > 0 ? "\(count) Mac\(count == 1 ? "" : "s")" : "Mac apps"
        case .linux:
            return "Shell & Xfce"
        }
    }

    // MARK: - Grouped Engine Cards

    private var systemsCards: some View {
        TriptychPanelCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(EngineKind.allCases.enumerated()), id: \.element.id) { index, kind in
                    engineCardRow(kind)
                    if index < EngineKind.allCases.count - 1 {
                        Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func engineCardRow(_ kind: EngineKind) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if kind == .windows && EngineRegistry.availability(.windows) == .ready {
                Button { confirmWindows = true } label: {
                    engineRowLinkBody(kind)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("engine-\(kind.rawValue)")
            } else {
                NavigationLink(value: kind) {
                    engineRowLinkBody(kind)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("engine-\(kind.rawValue)")
            }
            EngineStatusLine(kind: kind)
                .padding(.leading, 48)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func engineRowLinkBody(_ kind: EngineKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(TriptychPalette.textPrimary)
                .frame(width: 36, height: 36)
                .background(kind.panel.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TriptychPalette.textPrimary)
                Text(kind.stage)
                    .font(.system(size: 11))
                    .foregroundStyle(TriptychPalette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TriptychPalette.textMuted)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Setup & Settings

    private var setupAndSettingsRow: some View {
        HStack(spacing: 10) {
            NavigationLink { SetupView() } label: {
                TriptychPanelCard(accent: TriptychPalette.macLight) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(TriptychPalette.macLight)
                            Spacer()
                            TriptychStatusPill(
                                text: EngineRegistry.isSimulator ? "Sim" : (jitOn ? "JIT On" : "JIT Off"),
                                tone: EngineRegistry.isSimulator ? .neutral : (jitOn ? .good : .warn)
                            )
                        }
                        Text("Easel")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(TriptychPalette.textPrimary)
                        Text("Setup for JIT, storage & images")
                            .font(.system(size: 12))
                            .foregroundStyle(TriptychPalette.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            .buttonStyle(TriptychCardButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("setup-button")

            NavigationLink { TriptychSettingsView() } label: {
                TriptychPanelCard(accent: TriptychPalette.windowsLight) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(TriptychPalette.windowsLight)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(TriptychPalette.textMuted)
                        }
                        Text("Settings")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(TriptychPalette.textPrimary)
                        Text("Memory, input & tuning")
                            .font(.system(size: 12))
                            .foregroundStyle(TriptychPalette.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            .buttonStyle(TriptychCardButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-button")
        }
    }

    // MARK: - Help & About

    private var helpAndAboutCards: some View {
        VStack(spacing: 10) {
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 8) {
                    CuratorButton()
                    ExportLogsButton()
                    Text("Packs every system's logs (this run and the one before) with device and app details.")
                        .font(.system(size: 12))
                        .foregroundStyle(TriptychPalette.textSecondary)
                }
            }

            NavigationLink { AboutView() } label: {
                TriptychPanelCard {
                    HStack {
                        Label("About and licences", systemImage: "doc.text")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TriptychPalette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TriptychPalette.textMuted)
                    }
                }
            }
            .buttonStyle(TriptychCardButtonStyle())
            .accessibilityIdentifier("About and licences")
        }
    }
}

/// Visual hinged panel card matching the three-panel triptych icon.
private struct HingedPanelCard: View {
    let panel: TriptychPanel
    let badge: String
    let isCenter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: panel.symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(TriptychPalette.textPrimary)
                .frame(width: 34, height: 34)
                .background(panel.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Spacer(minLength: 4)

            Text(panel.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(TriptychPalette.textPrimary)
                .lineLimit(1)

            Text(panel.subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TriptychPalette.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(height: 28, alignment: .topLeading)

            Text(badge)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(panel.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(panel.deepAccent.opacity(0.24), in: Capsule())
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: isCenter ? 160 : 148)
        .accessibilityElement(children: .combine)
        .background(
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: isCenter ? 22 : 16, style: .continuous)
                    .fill(TriptychPalette.surfaceRaised)
                LinearGradient(
                    colors: [panel.accent.opacity(0.24), panel.deepAccent.opacity(0.06), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: isCenter ? 22 : 16, style: .continuous))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: isCenter ? 22 : 16, style: .continuous)
                .stroke(panel.accent.opacity(0.45), lineWidth: 1.2)
        )
    }
}

/// Windows panel hub: Windows games (Madeira), Windows PC (winarm), x86 PC (QEMU).
struct WindowsHubView: View {
    @EnvironmentObject var session: SessionState
    @Binding var confirmWindows: Bool

    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TriptychPanelCard(accent: TriptychPalette.windowsLight, raised: true) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Windows on Triptych")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(TriptychPalette.textPrimary)
                            Text("Use Pane for Windows games and apps, Casement for a Windows 11 PC, or x86 PC for x86-64 systems.")
                                .font(.system(size: 13))
                                .foregroundStyle(TriptychPalette.textSecondary)
                        }
                    }

                    TriptychSectionHeader(title: "Windows Systems", accent: TriptychPalette.windowsLight)
                    TriptychPanelCard(padding: 0) {
                        VStack(spacing: 0) {
                            if EngineRegistry.availability(.windows) == .ready {
                                Button { confirmWindows = true } label: {
                                    hubRow(.windows)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("hub-windows-pane")
                            } else {
                                NavigationLink(value: EngineKind.windows) {
                                    hubRow(.windows)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("hub-windows-pane")
                            }
                            divider
                            NavigationLink(value: EngineKind.winpc) {
                                hubRow(.winpc)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("hub-windows-casement")
                            divider
                            NavigationLink(value: EngineKind.x86pc) {
                                hubRow(.x86pc)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("hub-x86pc")
                        }
                    }

                    NavigationLink { SetupView() } label: {
                        Label("Easel · JIT & Windows ISOs", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.windowsLight))
                    .accessibilityIdentifier("hub-easel")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle("Windows")
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
    }

    private func hubRow(_ kind: EngineKind) -> some View {
        HStack(spacing: 12) {
            EngineRow(kind: kind)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TriptychPalette.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var divider: some View {
        Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
    }
}

/// Linux panel hub: ARM64 Linux (shell, distros, Xfce desktop), x86 PC, Android apps.
struct LinuxHubView: View {
    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TriptychPanelCard(accent: TriptychPalette.linuxLight, raised: true) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Linux & Open Systems")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(TriptychPalette.textPrimary)
                            Text("Run ARM64 Linux distributions with terminal & Xfce desktop without JIT, boot x86-64 Linux ISOs on QEMU, or inspect Android status.")
                                .font(.system(size: 13))
                                .foregroundStyle(TriptychPalette.textSecondary)
                        }
                    }

                    TriptychSectionHeader(title: "Systems", accent: TriptychPalette.linuxLight)
                    TriptychPanelCard(padding: 0) {
                        VStack(spacing: 0) {
                            NavigationLink(value: EngineKind.linux) {
                                hubRow(.linux)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("hub-linux")
                            divider
                            NavigationLink(value: EngineKind.x86pc) {
                                hubRow(.x86pc)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("hub-x86pc")
                            divider
                            NavigationLink(value: EngineKind.android) {
                                hubRow(.android)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("hub-android")
                        }
                    }

                    NavigationLink { LinuxDistrosView() } label: {
                        Label("Manage Linux Distributions", systemImage: "square.stack.3d.up")
                    }
                    .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.linuxLight))
                    .accessibilityIdentifier("hub-linux-distros")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle(EngineKind.linux.title)
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
    }

    private func hubRow(_ kind: EngineKind) -> some View {
        HStack(spacing: 12) {
            EngineRow(kind: kind)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TriptychPalette.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var divider: some View {
        Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
    }
}

struct EngineStatusLine: View {
    let kind: EngineKind
    var body: some View {
        let status = self.status
        Text(status.label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(status.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("engine-status-\(kind.rawValue)")
    }

    private var status: (label: String, color: Color) {
        switch EngineRegistry.availability(kind) {
        case .ready:
            switch (kind, EngineRegistry.isSimulator) {
            case (.linux, true), (.x86pc, true):
                return ("Ready · no JIT needed", TriptychPalette.good)
            case (.winpc, true):
                return ("Firmware preview", TriptychPalette.textSecondary)
            case (.macos, true):
                return ("Needs a device with JIT", TriptychPalette.textSecondary)
            case (.macapps, _), (.linux, false), (.x86pc, false):
                return ("Preview · no JIT setup needed", TriptychPalette.textSecondary)
            case (.windows, _), (.winpc, false), (.macos, false):
                return ("Device preview · needs JIT", TriptychPalette.textSecondary)
            case (.android, _):
                return ("Not in the app yet", TriptychPalette.textSecondary)
            }
        case .needsDevice: return ("Needs a real iPhone or iPad", TriptychPalette.textSecondary)
        case .notBuilt: return ("Not in this build", TriptychPalette.textSecondary)
        case .notInApp: return ("Not in the app yet", TriptychPalette.textSecondary)
        }
    }
}

struct EngineRow: View {
    let kind: EngineKind
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(TriptychPalette.textPrimary)
                .frame(width: 36, height: 36)
                .background(kind.panel.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TriptychPalette.textPrimary)
                EngineStatusLine(kind: kind)
                Text(kind.stage)
                    .font(.system(size: 11))
                    .foregroundStyle(TriptychPalette.textSecondary)
            }
        }
    }
}

struct EngineInfoView: View {
    let kind: EngineKind
    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TriptychPanelCard(accent: kind.panel.accent, raised: true) {
                        Text(kind.summary)
                            .font(.system(size: 15))
                            .foregroundStyle(TriptychPalette.textPrimary)
                    }

                    TriptychSectionHeader(title: "Status", accent: kind.panel.accent)
                    TriptychPanelCard {
                        VStack(alignment: .leading, spacing: 8) {
                            switch EngineRegistry.availability(kind) {
                            case .ready:
                                TriptychStatusPill(text: "Ready", tone: .good)
                            case .needsDevice(let why):
                                Text(why).font(.system(size: 14)).foregroundStyle(TriptychPalette.warn)
                            case .notBuilt(let why):
                                Text(why).font(.system(size: 14)).foregroundStyle(TriptychPalette.textSecondary)
                            case .notInApp(let why):
                                Text(why).font(.system(size: 14)).foregroundStyle(TriptychPalette.textSecondary)
                            }
                            Text(kind.stage)
                                .font(.system(size: 13))
                                .foregroundStyle(TriptychPalette.textSecondary)
                        }
                    }

                    TriptychPanelCard {
                        ExportLogsButton()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
    }
}
