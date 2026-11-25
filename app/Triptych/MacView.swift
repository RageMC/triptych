// SPDX-License-Identifier: GPL-3.0-or-later
import AVFAudio
import SwiftUI
import UniformTypeIdentifiers

/// Henge core startup, run once when the Mac system page opens.
@MainActor enum TriptychMacBoot {
    private static var started = false
    static func start() {
        guard !started else { return }
        started = true
        JITScriptAlias.install()
        HengeLog.start()
        HengeLog.log("boot", "address space: \(henge_largest_reservation_gb()) GB can be reserved in one piece")
        EngineTuning.apply()
        HengeLog.logFootprint("app-launch")
        JITBootstrap.noteLaunchState()
        HengeLog.log("app", "increased memory limit: \(Entitlements.increasedMemory ? "yes" : "no"); extended addressing: \(Entitlements.extendedAddressing ? "yes" : "no"); limit \(Entitlements.memoryLimitAtLaunch >> 20) MB")
        JITBootstrap.installTrapGuard()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        Machines.shared.collectImports()
    }
}

/// Kept so upstream Henge Swift files (HomeView.swift, JITSetupView.swift) continue to compile while
/// app/project.yml build paths remain unchanged; Triptych never presents Henge's RootView or HomeView.
enum RootView {
    enum Tab: Hashable { case macs, install, settings }
}

extension View {
    func hengeDestination<D: Hashable, C: View>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        navigationDestination(for: data, destination: destination)
    }
}

/// Triptych's Mac system screen: virtual Macs, macOS installer, Mac apps, and sample program self-test.
struct MacSystemView: View {
    @EnvironmentObject private var session: SessionState
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var installer = Installer.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var running: VirtualMac?
    @State private var chosen: UUID?
    @State private var pickingFolder = false
    @State private var showInstall = false
    @State private var jitReady = JITBootstrap.ready

    private var mac: VirtualMac? {
        if let chosen, let found = machines.all.first(where: { $0.id == chosen }) { return found }
        return machines.all.max { ($0.lastUsed ?? $0.added) < ($1.lastUsed ?? $1.added) }
    }

    private var runningBinding: Binding<VirtualMac?> {
        Binding(
            get: { running },
            set: { next in
                if next != nil {
                    guard session.activeEngine == nil || session.activeEngine == .macos else { return }
                    session.markStarted(.macos)
                }
                running = next
            }
        )
    }

    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    notices
                    if let mac {
                        MacHeroCard(
                            mac: mac,
                            jitReady: jitReady,
                            disabled: session.activeEngine != nil && session.activeEngine != .macos,
                            start: { runningBinding.wrappedValue = mac },
                            turnOnJIT: { jit.enable() },
                            jitNote: jitReady ? nil : (JITBootstrap.lastFailure ?? jit.automaticDescription)
                        )
                        HStack(spacing: 10) {
                            TriptychFactTile(title: "Disk", value: ByteText.string(UInt64(max(mac.bytesUsed, 0))), accent: TriptychPalette.macLight)
                            TriptychFactTile(title: "Last used", value: mac.lastUsedText, accent: TriptychPalette.macLight)
                        }
                        otherMacs(besides: mac)
                    } else {
                        emptyMacCard
                    }
                    toolsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle(EngineKind.macos.title)
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showInstall = true } label: { Label("Install macOS…", systemImage: "arrow.down.circle") }
                    Button { pickingFolder = true } label: { Label("Bring in a Mac from Files…", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a Mac")
            }
        }
        .navigationDestination(for: VirtualMac.self) { MacDetailView(mac: $0) }
        .navigationDestination(isPresented: $showInstall) { MacInstallView() }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { machines.importFolder(url) }
        }
        .fullScreenCover(item: runningBinding) { activeMac in
            SessionView(mac: activeMac) { self.running = nil }
                .environment(\.colorScheme, .dark)
        }
        .sheet(isPresented: $jit.showSetup) {
            NavigationStack {
                SetupView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { jit.showSetup = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .onAppear {
            tp_release_madeira_va()
            TriptychMacBoot.start()
            jitReady = JITBootstrap.ready
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-mac.display-preview") {
                runningBinding.wrappedValue = VirtualMac(name: "Display preview", ecid: 0, seed: 0, ramMB: 0, diskBytes: 0)
            }
            #endif
        }
        .task {
            while !Task.isCancelled {
                jitReady = JITBootstrap.ready
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            machines.collectImports()
            jit.enableAtLaunchIfAsked()
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                if JITBootstrap.prewarmed || JITBootstrap.isLive {
                    jit.objectWillChange.send()
                    return
                }
                if JITBootstrap.debuggedFlag || JITBootstrap.canGrantOwnJIT {
                    JITBootstrap.prewarm()
                    jit.objectWillChange.send()
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
        }
        .onChange(of: jit.attachGeneration) { _, _ in
            JITBootstrap.prewarm()
            jit.objectWillChange.send()
            TriptychLog.log("jit", "debugger attached; JIT is now \(JITBootstrap.statusText(JITBootstrap.state))")
        }
        .task {
            // Autopilot can start Henge's translation layer directly.
            if Autopilot.enabled { CuratorFallbackModel.shared.prepareForEngineStart() }
            await Autopilot.run { mac in
                guard session.activeEngine == nil || session.activeEngine == .macos else { return }
                session.markStarted(.macos)
                guard running != nil else { running = mac; return }
                running = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { running = mac }
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if Device.chipTooOld {
            TriptychNoticeBanner(symbol: "exclamationmark.triangle.fill", text: Device.chipTooOldText, tint: TriptychPalette.bad)
        }
        if installer.busy {
            Button { showInstall = true } label: {
                TriptychNoticeBanner(symbol: "arrow.down.circle.fill", text: "Installing \(installer.machineName)…", trailing: "See", tint: TriptychPalette.macLight)
            }
            .buttonStyle(.plain)
        }
        if let name = machines.importing {
            TriptychNoticeBanner(
                symbol: "square.and.arrow.down.fill",
                text: machines.unpacked > 0 ? String(format: "Unpacking %@'s disk… %.0f%%", name, machines.unpacked * 100) : "Bringing in \(name)…",
                tint: TriptychPalette.macLight
            )
        }
        if let error = machines.lastError {
            TriptychNoticeBanner(symbol: "exclamationmark.triangle.fill", text: error, tint: TriptychPalette.bad)
        }
    }

    private var emptyMacCard: some View {
        TriptychPanelCard(accent: TriptychPalette.macLight, raised: true) {
            VStack(spacing: 14) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(TriptychPalette.macLight)
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .background(TriptychPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("No virtual Mac yet")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(TriptychPalette.textPrimary)
                Text("Install macOS directly on this \(Device.name), or import a Mac folder exported from a computer.")
                    .font(.system(size: 14))
                    .foregroundStyle(TriptychPalette.textSecondary)
                    .multilineTextAlignment(.center)
                NavigationLink { MacInstallView() } label: {
                    Label("Install macOS", systemImage: "arrow.down.circle")
                }
                .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
                .accessibilityIdentifier("mac-install-button")

                Button { pickingFolder = true } label: {
                    Label("Bring in a Mac from Files…", systemImage: "folder")
                }
                .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.macLight))
                .accessibilityIdentifier("mac-import-folder")
            }
        }
    }

    @ViewBuilder private func otherMacs(besides shown: VirtualMac) -> some View {
        let rest = machines.all.filter { $0.id != shown.id }
        if !rest.isEmpty {
            TriptychSectionHeader(title: "Other Macs", accent: TriptychPalette.macLight)
            TriptychPanelCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(rest) { other in
                        Button { chosen = other.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(other.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(TriptychPalette.textPrimary)
                                    Text(other.summary)
                                        .font(.system(size: 12))
                                        .foregroundStyle(TriptychPalette.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(TriptychPalette.textMuted)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if other.id != rest.last?.id {
                            Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var toolsSection: some View {
        TriptychSectionHeader(title: "Mac Tools & Apps", accent: TriptychPalette.macLight)
        TriptychPanelCard(padding: 0) {
            VStack(spacing: 0) {
                toolRow(title: "Install macOS", detail: "Download Apple's restore image and create a Mac", symbol: "arrow.down.circle", id: "mac-install-link") {
                    MacInstallView()
                }
                divider
                toolRow(title: EngineKind.macapps.title, detail: "Import .dmg, .pkg or .zip onto the AppKit shim", symbol: "square.grid.2x2", id: "mac-apps-link") {
                    MacAppLibraryView()
                }
                divider
                toolRow(title: "Sample program", detail: "Run the bundled Hello (C) macOS binary and probe JIT", symbol: "terminal", id: "macos-sample") {
                    SampleMacProgramView()
                }
                divider
                toolRow(title: "Easel · JIT & storage", detail: "Configure JIT, pairing, and restore images", symbol: "wrench.and.screwdriver", id: "mac-setup-link") {
                    SetupView()
                }
                divider
                toolRow(title: "Settings", detail: "Memory, performance, trackpad and appearance", symbol: "gearshape", id: "mac-settings-link") {
                    TriptychSettingsView()
                }
            }
        }
    }

    private func toolRow<Dest: View>(title: String, detail: String, symbol: String, id: String, @ViewBuilder destination: () -> Dest) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TriptychPalette.macLight)
                    .frame(width: 32, height: 32)
                    .background(TriptychPalette.macDeep.opacity(0.25), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(TriptychPalette.textPrimary)
                    Text(detail).font(.system(size: 12)).foregroundStyle(TriptychPalette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(TriptychPalette.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var divider: some View {
        Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
    }
}

private struct MacHeroCard: View {
    let mac: VirtualMac
    let jitReady: Bool
    let disabled: Bool
    let start: () -> Void
    let turnOnJIT: () -> Void
    let jitNote: String?
    @AppStorage("henge.cpus") private var cpus = 4

    var body: some View {
        TriptychPanelCard(accent: TriptychPalette.macLight, raised: true) {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink(value: mac) {
                    VStack(alignment: .leading, spacing: 10) {
                        preview
                        HStack {
                            Text(mac.name)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(TriptychPalette.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            TriptychStatusPill(
                                text: jitReady ? "JIT on" : "JIT off",
                                tone: jitReady ? .good : .warn
                            )
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TriptychPalette.textMuted)
                        }
                        Text("\(mac.summary) · \(cpus) CPUs")
                            .font(.system(size: 14))
                            .foregroundStyle(TriptychPalette.textSecondary)
                    }
                }
                .buttonStyle(.plain)

                if jitReady {
                    Button(action: start) {
                        if InstantResume.enabled && InstantResume.hasSave(for: mac) {
                            Label("Resume", systemImage: "play.fill")
                        } else {
                            Label("Start", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac, enabled: !disabled))
                    .disabled(disabled)
                } else {
                    if let jitNote {
                        Text(jitNote)
                            .font(.system(size: 13))
                            .foregroundStyle(TriptychPalette.textSecondary)
                    }
                    Button("Turn On JIT", action: turnOnJIT)
                        .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
                }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            TriptychPalette.surface
            if let image = UIImage(contentsOfFile: MacPreview.file(for: mac).path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(TriptychPalette.textMuted)
            }
        }
        .aspectRatio(mac.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(TriptychPalette.hairline, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Triptych's macOS installer view (replaces Henge's InstallView).
struct MacInstallView: View {
    @ObservedObject private var installer = Installer.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var jitReady = JITBootstrap.ready
    @StateObject private var display = DisplayRouter()
    @State private var release = MacOSRelease.all.first(where: Installer.haveImage) ?? MacOSRelease.recommended
    @State private var name = "Mac"
    @State private var ramGB = Device.suggestedRAMGB
    @State private var deleteAfter = false
    @State private var refresh = 0
    @State private var details = false
    @State private var stageStarted = Date()
    @State private var stageSeen = -1
    @State private var confirmDeleteDownload: MacOSRelease?
    @AppStorage("henge.cpus") private var cpus = 4

    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch installer.phase {
                    case .idle: chooser
                    case .checking:
                        TriptychPanelCard {
                            HStack(spacing: 12) {
                                ProgressView().tint(TriptychPalette.macLight)
                                Text("Preparing to install macOS…")
                                    .font(.system(size: 15))
                                    .foregroundStyle(TriptychPalette.textPrimary)
                            }
                        }
                    case .downloading, .preparing, .installing: progressView
                    case .done(let text): finished(text)
                    case .failed(let text): failed(text)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle(installer.busy ? "Installing" : "Install macOS")
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
        .task {
            while !Task.isCancelled {
                jitReady = JITBootstrap.ready
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @ViewBuilder private var chooser: some View {
        TriptychSectionHeader(title: "macOS Version", accent: TriptychPalette.macLight)
        TriptychPanelCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(MacOSRelease.all) { r in
                    HStack(spacing: 0) {
                        Button { release = r } label: { versionRow(r) }
                            .buttonStyle(.plain)
                        if (Installer.haveImage(r) || Installer.partSize(r) != nil) && !installer.busy {
                            Button { confirmDeleteDownload = r } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(TriptychPalette.textMuted)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete the \(r.name) download")
                            .padding(.trailing, 6)
                        }
                    }
                    if r.id != MacOSRelease.all.last?.id {
                        Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                    }
                }
            }
        }
        .id(refresh)
        .confirmationDialog(
            "Delete this download?",
            isPresented: Binding(get: { confirmDeleteDownload != nil }, set: { if !$0 { confirmDeleteDownload = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Download", role: .destructive) {
                if let r = confirmDeleteDownload { Installer.deleteImage(r) }
                refresh += 1
            }
        }

        TriptychSectionHeader(title: "New Mac", accent: TriptychPalette.macLight)
        TriptychPanelCard(padding: 0) {
            VStack(spacing: 0) {
                TextField("Name", text: $name)
                    .font(.system(size: 15))
                    .foregroundStyle(TriptychPalette.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                Stepper(value: $ramGB, in: Device.memoryChoices) {
                    HStack {
                        Text("Memory").font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                        Spacer()
                        Text("\(ramGB) GB").font(.system(size: 15, weight: .semibold)).foregroundStyle(TriptychPalette.macLight)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                if let note = Device.memoryNote(ramGB) {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(TriptychPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
                Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                Toggle("Delete the download after", isOn: $deleteAfter)
                    .font(.system(size: 15))
                    .foregroundStyle(TriptychPalette.textPrimary)
                    .tint(TriptychPalette.macDeep)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }

        Button(Installer.haveImage(release) ? "Install" : "Download and Install") {
            installer.start(release, name: name.isEmpty ? "Mac" : name, ramMB: ramGB * 1024, cpus: cpus, keepImage: !deleteAfter)
        }
        .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac, enabled: jitReady && !Device.chipTooOld))
        .disabled(!jitReady || Device.chipTooOld)
        .accessibilityIdentifier("mac-install-start")

        Text(
            Device.chipTooOld ? Device.chipTooOldText
                : jitReady ? "Keep Triptych open and the \(Device.name) plugged in. Needs about \(ByteText.string(UInt64(Installer.spaceNeeded(release)))) free."
                : (JITBootstrap.lastFailure ?? "Turn on JIT first. \(jit.automaticDescription)")
        )
        .font(.system(size: 13))
        .foregroundStyle(TriptychPalette.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)

        if !jitReady && !Device.chipTooOld {
            NavigationLink { SetupView() } label: {
                Label("Set up JIT in Easel", systemImage: "bolt.fill")
            }
            .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.macLight))
        }
    }

    private func versionRow(_ r: MacOSRelease) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(TriptychPalette.textPrimary)
                if let size = Installer.imageSize(r) {
                    Text("Downloaded, \(ByteText.string(UInt64(size)))").font(.system(size: 12)).foregroundStyle(TriptychPalette.good)
                } else if let part = Installer.partSize(r) {
                    Text("\(ByteText.string(UInt64(part))) of \(ByteText.string(UInt64(r.bytes))) downloaded (resumable)")
                        .font(.system(size: 12)).foregroundStyle(TriptychPalette.warn)
                } else {
                    Text("\(ByteText.string(UInt64(r.bytes))) download").font(.system(size: 12)).foregroundStyle(TriptychPalette.textSecondary)
                }
                Text(r.note).font(.system(size: 12)).foregroundStyle(TriptychPalette.textMuted)
            }
            Spacer()
            if release == r {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TriptychPalette.macLight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private static let stages = ["Download", "Start installer", "Write macOS", "Check macOS", "Finish"]

    private var stage: Int {
        switch installer.phase {
        case .downloading: return 0
        case .preparing: return 1
        default:
            switch installer.step {
            case 0, 1: return 1
            case 2: return 2
            case 3: return 3
            default: return 4
            }
        }
    }

    private var fraction: Double {
        if case .downloading = installer.phase {
            return installer.expected > 0 ? Double(installer.received) / Double(installer.expected) : 0
        }
        return installer.stepProgress
    }

    private var timeLeft: String? {
        let elapsed = Date().timeIntervalSince(stageStarted)
        guard stageSeen == stage, fraction > 0.03, fraction < 1, elapsed > 10 else { return nil }
        let minutes = Int((elapsed / fraction * (1 - fraction) / 60).rounded(.up))
        return minutes <= 1 ? "About a minute left in this step" : "About \(minutes) minutes left in this step"
    }

    @ViewBuilder private var progressView: some View {
        Text("\(release.name) on this \(Device.name). Keep Triptych open.")
            .font(.system(size: 15))
            .foregroundStyle(TriptychPalette.textSecondary)

        TimelineView(.periodic(from: .now, by: 1)) { _ in
            TriptychPanelCard(accent: TriptychPalette.macLight, raised: true) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 56, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(TriptychPalette.textPrimary)
                    Text(timeLeft ?? "Step \(stage + 1) of \(Self.stages.count)")
                        .font(.system(size: 14))
                        .foregroundStyle(TriptychPalette.textSecondary)
                    TriptychProgressBar(fraction: fraction, panel: .mac, height: 11)
                }
            }
        }
        .onChange(of: stage) { _, value in
            stageSeen = value
            stageStarted = Date()
        }
        .onAppear {
            stageSeen = stage
            stageStarted = Date()
        }

        TriptychSectionHeader(title: "Steps", accent: TriptychPalette.macLight)
        TriptychPanelCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, title in
                    HStack {
                        Text(title)
                            .font(.system(size: 15, weight: i == stage ? .semibold : .regular))
                            .foregroundStyle(i > stage ? TriptychPalette.textMuted : TriptychPalette.textPrimary)
                        Spacer()
                        if i < stage {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(TriptychPalette.good)
                        } else if i == stage {
                            ProgressView().controlSize(.small).tint(TriptychPalette.macLight)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    if i < Self.stages.count - 1 {
                        Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                    }
                }
            }
        }

        Button(details ? "Hide details" : "Show details") { withAnimation { details.toggle() } }
            .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.macLight))

        if details {
            TriptychPanelCard {
                VStack(spacing: 12) {
                    if case .installing = installer.phase {
                        BootDisplay(display: display, role: .device)
                            .aspectRatio(16.0 / 10.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    MacLogTailView()
                }
            }
        }
    }

    private func finished(_ text: String) -> some View {
        TriptychPanelCard(accent: TriptychPalette.good, raised: true) {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(TriptychPalette.good)
                Text("Installed")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(TriptychPalette.textPrimary)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(TriptychPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func failed(_ text: String) -> some View {
        TriptychPanelCard(accent: TriptychPalette.bad, raised: true) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Install did not finish")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(TriptychPalette.textPrimary)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(TriptychPalette.textSecondary)
                Text("Quit Triptych and open it again before retrying: only one Mac can start per launch.")
                    .font(.system(size: 12))
                    .foregroundStyle(TriptychPalette.textMuted)
                Button("Back") { installer.reset() }
                    .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
            }
        }
        TriptychSectionHeader(title: "Log", accent: TriptychPalette.bad)
        TriptychPanelCard { MacLogTailView() }
    }
}

private struct MacLogTailView: View {
    @State private var lines: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TriptychPalette.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                lines = Array(HengeLog.recentLines(14))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

/// Triptych's per-Mac configuration screen (replaces Henge's MacSettingsView).
struct MacDetailView: View {
    @ObservedObject private var machines = Machines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mac: VirtualMac
    @State private var confirmDelete = false
    @State private var movingExport = false
    @AppStorage("henge.cpus") private var cpus = 4

    init(mac: VirtualMac) { _mac = State(initialValue: mac) }

    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TriptychSectionHeader(title: "Name", accent: TriptychPalette.macLight)
                    TriptychPanelCard {
                        TextField("Name", text: $mac.name)
                            .font(.system(size: 15))
                            .foregroundStyle(TriptychPalette.textPrimary)
                            .submitLabel(.done)
                            .onSubmit(save)
                    }

                    TriptychSectionHeader(title: "Memory & Processors", accent: TriptychPalette.macLight)
                    TriptychPanelCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(mac.ramMB / 1024) GB")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(TriptychPalette.textPrimary)
                                Spacer()
                                Text(Entitlements.increasedMemory ? "Outside app limit with JIT" : "Backed by storage if needed")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TriptychPalette.textSecondary)
                            }
                            Stepper(
                                "Memory",
                                value: Binding(get: { mac.ramMB / 1024 }, set: { mac.ramMB = $0 * 1024; save() }),
                                in: Device.memoryChoices
                            )
                            .font(.system(size: 15))
                            .foregroundStyle(TriptychPalette.textPrimary)
                            if let note = Device.memoryNote(mac.ramMB / 1024) {
                                Text(note).font(.system(size: 12)).foregroundStyle(TriptychPalette.textSecondary)
                            }
                            Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                            Stepper(value: $cpus, in: 1...6) {
                                HStack {
                                    Text("CPUs").font(.system(size: 15)).foregroundStyle(TriptychPalette.textPrimary)
                                    Spacer()
                                    Text("\(cpus)").font(.system(size: 15, weight: .semibold)).foregroundStyle(TriptychPalette.macLight)
                                }
                            }
                        }
                    }

                    if Device.fittingScreen.height != 1080 {
                        TriptychSectionHeader(title: "Screen", accent: TriptychPalette.macLight)
                        TriptychPanelCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker(
                                    "Screen",
                                    selection: Binding(
                                        get: {
                                            if mac.isRetina { return "retina" }
                                            if max(mac.screen.width, mac.screen.height) <= Device.performanceScreen.width { return "performance" }
                                            return "standard"
                                        },
                                        set: { choice in
                                            mac.retina = choice == "retina"
                                            switch choice {
                                            case "retina": break
                                            case "performance": (mac.screenWidth, mac.screenHeight) = Device.performanceScreen
                                            default: (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
                                            }
                                            save()
                                        }
                                    )
                                ) {
                                    if Device.isPad {
                                        Text("Retina").tag("retina")
                                    }
                                    Text("Performance").tag("performance")
                                    Text("Standard").tag("standard")
                                }
                                .pickerStyle(.segmented)
                                Text("Fits this window at up to \(max(mac.screen.width, mac.screen.height)) pixels on the longest edge.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TriptychPalette.textSecondary)
                            }
                        }
                    }

                    TriptychSectionHeader(title: "Storage", accent: TriptychPalette.macLight)
                    TriptychPanelCard {
                        VStack(spacing: 10) {
                            HStack {
                                Text("\(ByteText.string(UInt64(max(mac.bytesUsed, 0)))) used")
                                    .font(.system(size: 15))
                                    .foregroundStyle(TriptychPalette.textPrimary)
                                Spacer()
                                Text("of \(ByteText.string(UInt64(max(mac.diskBytes, 0))))")
                                    .font(.system(size: 14))
                                    .foregroundStyle(TriptychPalette.textSecondary)
                            }
                            TriptychProgressBar(
                                fraction: Double(mac.bytesUsed) / Double(max(mac.diskBytes, 1)),
                                panel: .mac
                            )
                        }
                    }

                    TriptychSectionHeader(title: "Manage", accent: TriptychPalette.bad)
                    TriptychPanelCard(padding: 0) {
                        VStack(spacing: 0) {
                            if let name = machines.exporting {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Exporting \(name)… keep Triptych open")
                                        .font(.system(size: 14))
                                        .foregroundStyle(TriptychPalette.textPrimary)
                                    TriptychProgressBar(fraction: machines.exported, panel: .mac)
                                }
                                .padding(16)
                            } else {
                                Button { machines.export(mac) } label: {
                                    HStack {
                                        Text("Export").font(.system(size: 15, weight: .semibold)).foregroundStyle(TriptychPalette.macLight)
                                        Spacer()
                                        Image(systemName: "square.and.arrow.up").foregroundStyle(TriptychPalette.macLight)
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 14)
                                }
                                .buttonStyle(.plain)
                            }
                            if let folder = machines.lastExport {
                                Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Saved in Files under Exports/\(folder.lastPathComponent).")
                                        .font(.system(size: 12))
                                        .foregroundStyle(TriptychPalette.textSecondary)
                                    Button("Move Out of Triptych…") { movingExport = true }
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(TriptychPalette.macLight)
                                }
                                .padding(16)
                            }
                            Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                            Button { confirmDelete = true } label: {
                                HStack {
                                    Text("Delete this Mac").font(.system(size: 15, weight: .semibold)).foregroundStyle(TriptychPalette.bad)
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
        .onDisappear(perform: save)
        .fileMover(isPresented: $movingExport, file: machines.lastExport) { result in
            switch result {
            case .success: machines.lastExport = nil
            case .failure(let error): machines.lastError = error.localizedDescription
            }
        }
        .confirmationDialog("Delete \(mac.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                machines.delete(mac.id)
                dismiss()
            }
        } message: {
            Text("Its disk is removed from this \(Device.name).")
        }
    }

    private func save() {
        if mac.name.isEmpty { mac.name = "Mac" }
        machines.update(mac)
    }
}

/// Runs Henge's "Hello (C)" arm64 macOS sample through the in-process Mach-O loader and probes MAP_JIT.
struct SampleMacProgramView: View {
    @EnvironmentObject var app: SessionState
    @State private var log = ""
    @State private var running = false

    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TriptychPanelCard(accent: TriptychPalette.macLight) {
                        Text(EngineKind.macos.summary)
                            .font(.system(size: 14))
                            .foregroundStyle(TriptychPalette.textSecondary)
                    }

                    TriptychSectionHeader(title: "Mac program without macOS", accent: TriptychPalette.macLight)
                    TriptychPanelCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Button(running ? "Running…" : "Run sample Mac program") { run() }
                                .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac, enabled: !running && (app.activeEngine == nil || app.activeEngine == .macos)))
                                .disabled(running || (app.activeEngine != nil && app.activeEngine != .macos))
                                .accessibilityIdentifier("macos-run")

                            Text(log.isEmpty ? "Runs “Hello (C)”, an arm64 macOS sample built from source, through the Mach-O loader." : log)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(TriptychPalette.textPrimary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("macos-output")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle("Sample program")
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
    }

    private func run() {
        guard let exe = Bundle.main.path(forResource: "Hello (C)", ofType: nil) else { log = "sample missing"; return }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        let out = dir.appendingPathComponent("tl-out.txt").path
        let copy = dir.appendingPathComponent("hello").path
        do {
            if (try? fm.attributesOfItem(atPath: copy)) != nil { try fm.removeItem(atPath: copy) }
            try fm.copyItem(atPath: exe, toPath: copy)
        } catch {
            log = "Failed to prepare sample: \(error.localizedDescription)"
            return
        }
        app.markStarted(.macos)
        running = true
        DispatchQueue.global().async {
            var msg = [CChar](repeating: 0, count: 1024)
            var aux = [CChar](repeating: 0, count: 256)
            let st = tp_macos_selftest(dir.path, &aux, Int32(aux.count))
            let rc = tp_macos_run_program(copy, out, &msg, Int32(msg.count))
            let text = (try? String(contentsOfFile: out, encoding: .utf8)) ?? "(no output)"
            let summary = "selftest=\(st) \(String(cString: aux))\n\(String(cString: msg))\nexit=\(rc)\n--- program output ---\n\(text)"
            DispatchQueue.main.async { log = summary; running = false }
        }
    }
}
