// SPDX-License-Identifier: GPL-3.0-or-later
import MacAppsKit
import SwiftUI
import UniformTypeIdentifiers

/// One shared Setup screen across Triptych:
/// 1) JIT (executable memory status, quick StikDebug / Built-in StikJIT / TrollStore / Jailbreak / LiveContainer walkthroughs)
/// 2) Storage (device free space + Macs, restore images, Windows PC, x86 PC, Linux rootfs, Mac apps)
/// 3) Images & files the user supplies (Windows ISO, x86 ISO, macOS restore images, Linux rootfs, Mac app packages)
struct SetupView: View {
    enum Step: Hashable {
        case pairOnDevice, importFile, connect, enable, stikDebug, trollStore, jailbreak, liveContainer
    }

    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var winpc = WinPC.shared
    @ObservedObject private var x86pc = X86PCVM.shared

    @State private var jitOn = JIT.isEnabled
    @State private var path: [Step] = []
    @State private var pickingPairing = false
    @State private var pickingWinISO = false
    @State private var pickingX86ISO = false
    @State private var confirmDeleteRelease: MacOSRelease?
    @State private var refreshCounter = 0

    private var device: String { OnDevicePairing.deviceKind }
    private var jitState: JITBootstrap.JITState {
        _ = jit.attachGeneration
        return JITBootstrap.state
    }

    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    jitSection
                    CuratorModelSetupView()
                    storageSection
                    suppliedImagesSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle("Easel · Setup")
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
        .navigationDestination(for: Step.self) { step in
            jitStepDestination(step)
        }
        .fileImporter(isPresented: $pickingPairing, allowedContentTypes: [.propertyList, .data]) { result in
            if case .success(let url) = result { jit.importPairingFile(url) }
        }
        .fileImporter(isPresented: $pickingWinISO, allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data, .data]) { result in
            if case .success(let url) = result { winpc.pick(url) }
        }
        .fileImporter(isPresented: $pickingX86ISO, allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data, .data]) { result in
            if case .success(let url) = result { x86pc.pick(url) }
        }
        .confirmationDialog(
            "Delete downloaded restore image?",
            isPresented: Binding(get: { confirmDeleteRelease != nil }, set: { if !$0 { confirmDeleteRelease = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Download", role: .destructive) {
                if let r = confirmDeleteRelease {
                    Installer.deleteImage(r)
                    refreshCounter += 1
                }
            }
        }
        .onAppear {
            jitOn = JIT.isEnabled
            jit.refreshPairingStatus()
            pairing.reset()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            jitOn = JIT.isEnabled
        }
    }

    // MARK: - JIT Section

    @ViewBuilder private var jitSection: some View {
        TriptychSectionHeader(title: "Executable Memory (JIT)", detail: "Windows · macOS", accent: TriptychPalette.macLight)

        TriptychPanelCard(accent: jitStatusTone.color, raised: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("JIT status")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(TriptychPalette.textPrimary)
                        Text(jitSubtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(TriptychPalette.textSecondary)
                    }
                    Spacer()
                    TriptychStatusPill(
                        text: jitPillText,
                        tone: jitStatusTone,
                        symbol: jitPillSymbol,
                        identifier: "setup-jit-pill"
                    )
                }

                if !EngineRegistry.isSimulator {
                    HStack(spacing: 10) {
                        Button {
                            TriptychLog.log("jit", "Setup: asking StikDebug to enable JIT")
                            JIT.requestFromStikDebug()
                        } label: {
                            Label("Enable with StikDebug", systemImage: "ant.fill")
                        }
                        .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac, enabled: !jitOn, height: 46))
                        .disabled(jitOn)
                        .accessibilityIdentifier("setup-stikdebug-enable")

                        Button("Auto Enable") {
                            jit.enable()
                        }
                        .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.macLight))
                        .disabled(jitOn || jit.busy)
                        .accessibilityIdentifier("setup-jit-auto")
                    }
                } else {
                    TriptychNoticeBanner(
                        symbol: "desktopcomputer",
                        text: "Simulator builds run as Mac processes. On a real iPhone or iPad, pair this device or use StikDebug to grant JIT.",
                        tint: TriptychPalette.windowsLight
                    )
                }
            }
        }

        TriptychPanelCard(padding: 0) {
            VStack(spacing: 0) {
                if LiveContainerHost.isHosting {
                    jitWayRow(
                        title: "Inside LiveContainer",
                        symbol: "shippingbox",
                        detail: LiveContainerHost.runsHelperProcesses
                            ? "Helper Process Support is on; the built-in helper works here."
                            : "Turn on Helper Process Support, or launch with Triptych's JIT script.",
                        done: LiveContainerHost.runsHelperProcesses,
                        step: .liveContainer
                    )
                    divider
                }
                let builtInReason = HengeBuiltInJIT.unavailableReason
                jitWayRow(
                    title: "Pair on this \(device)",
                    symbol: "iphone.radiowaves.left.and.right",
                    detail: builtInReason ?? (!OnDevicePairing.isSupported ? "Needs iOS 27 or later."
                        : jit.pairingSource == .onDevice ? "Paired on this \(device)."
                        : "No computer needed. Pairs via Developer Mode."),
                    done: jit.pairingSource == .onDevice,
                    enabled: builtInReason == nil && OnDevicePairing.isSupported,
                    step: .pairOnDevice
                )
                divider
                jitWayRow(
                    title: "Use a pairing file",
                    symbol: "doc.badge.plus",
                    detail: builtInReason ?? (jit.pairingSource == .imported ? "Pairing file imported."
                        : "Import a remote pairing file made on a computer."),
                    done: jit.pairingSource == .imported,
                    enabled: builtInReason == nil,
                    step: .importFile
                )
                divider
                jitWayRow(
                    title: "Use StikDebug",
                    symbol: "ant",
                    detail: JITBootstrap.isStikDebugInstalled ? "StikDebug is installed."
                        : "Enable JIT through the StikDebug app.",
                    done: jit.method == .stikDebug,
                    step: .stikDebug
                )
                divider
                jitWayRow(
                    title: "Use TrollStore",
                    symbol: "sparkles",
                    detail: JITBootstrap.isTrollStoreInstalled ? "TrollStore is installed."
                        : "For Triptych installed through TrollStore (iOS 14–17.0).",
                    done: jit.method == .trollStore,
                    step: .trollStore
                )
                divider
                jitWayRow(
                    title: "Use a jailbreak",
                    symbol: "lock.open",
                    detail: JITBootstrap.debuggedAtLaunch ? "JIT was already on when Triptych opened."
                        : JITBootstrap.isJailbroken ? "Jailbreak detected. Turn on Allow JIT in Apps."
                        : "Dopamine can give apps JIT with one setting.",
                    done: jit.method == .jailbreak || JITBootstrap.debuggedAtLaunch,
                    step: .jailbreak
                )
            }
        }

        if jit.hasPairing && HengeBuiltInJIT.isAvailable {
            NavigationLink(value: Step.connect) {
                Label("Continue with current pairing (LocalDevVPN)", systemImage: "arrow.right")
            }
            .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.macLight))
        }
    }

    private var jitStatusTone: TriptychStatusPill.Tone {
        if EngineRegistry.isSimulator { return .neutral }
        switch jitState {
        case .on: return .good
        case .claiming: return .warn
        case .failed: return .bad
        case .off: return jitOn ? .good : .neutral
        }
    }

    private var jitPillText: String {
        if EngineRegistry.isSimulator { return "Simulator" }
        switch jitState {
        case .on: return "On"
        case .claiming: return "Claiming"
        case .failed: return "Failed"
        case .off: return jitOn ? "On" : "Off"
        }
    }

    private var jitPillSymbol: String {
        if EngineRegistry.isSimulator { return "laptopcomputer" }
        switch jitState {
        case .on: return "bolt.fill"
        case .claiming: return "hourglass"
        case .failed: return "exclamationmark.triangle.fill"
        case .off: return jitOn ? "bolt.fill" : "bolt.slash"
        }
    }

    private var jitSubtitle: String {
        if EngineRegistry.isSimulator {
            return "Windows and macOS require device JIT; Linux, Mac apps, and x86 PC (TCTI) run without it."
        }
        switch jitState {
        case .on: return "Executable memory is active. Windows games, Windows PC, and macOS can start."
        case .claiming: return "A debugger is attached; claiming the executable code region…"
        case .failed(let why): return why
        case .off: return "Windows games, Windows PC, and macOS need JIT. Linux runs without it."
        }
    }

    private func jitWayRow(
        title: String,
        symbol: String,
        detail: String,
        done: Bool,
        enabled: Bool = true,
        step: Step
    ) -> some View {
        NavigationLink(value: step) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TriptychPalette.macLight)
                    .frame(width: 34, height: 34)
                    .background(TriptychPalette.macDeep.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TriptychPalette.textPrimary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(TriptychPalette.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: done ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: done ? 17 : 12, weight: .semibold))
                    .foregroundStyle(done ? TriptychPalette.good : TriptychPalette.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.48)
    }

    // MARK: - Storage Section

    @ViewBuilder private var storageSection: some View {
        let _ = refreshCounter
        TriptychSectionHeader(title: "Storage", detail: "This \(device)", accent: TriptychPalette.windowsLight)

        let freeBytes = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let macDiskTotal = machines.all.reduce(Int64(0)) { $0 + max($1.bytesUsed, 0) }
        let ipswTotal = MacOSRelease.all.reduce(Int64(0)) { acc, r in
            acc + (Installer.imageSize(r) ?? Installer.partSize(r) ?? 0)
        }
        let winPCSize = fileAllocatedSize(winpc.diskURL)
        let x86Size = fileAllocatedSize(x86pc.diskURL)
        let linuxCount = LinuxDistro.installedIDs.count + (LinuxDistro.isInstalled("alpine") ? 0 : 1)
        let macAppsCount = MacAppLibrary.installedApps().count

        HStack(spacing: 10) {
            TriptychFactTile(title: "Free on device", value: ByteText.string(UInt64(max(freeBytes, 0))), accent: TriptychPalette.windowsLight)
            TriptychFactTile(title: "Virtual Macs", value: "\(machines.all.count) (\(ByteText.string(UInt64(macDiskTotal))))", accent: TriptychPalette.macLight)
        }

        TriptychPanelCard(padding: 0) {
            VStack(spacing: 0) {
                storageRow("macOS restore images", value: ipswTotal > 0 ? ByteText.string(UInt64(ipswTotal)) : "None downloaded")
                divider
                storageRow("Casement disk", value: winPCSize > 0 ? ByteText.string(UInt64(winPCSize)) : "Not created yet (64 GB sparse)")
                divider
                storageRow("x86 PC disk", value: x86Size > 0 ? ByteText.string(UInt64(x86Size)) : "Not created yet (16 GB qcow2)")
                divider
                storageRow("Linux root filesystems", value: "\(linuxCount) installed")
                divider
                storageRow("Imported Mac apps", value: "\(macAppsCount) installed")
            }
        }
    }

    private func storageRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(TriptychPalette.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(TriptychPalette.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func fileAllocatedSize(_ url: URL) -> Int64 {
        let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(vals?.totalFileAllocatedSize ?? vals?.fileSize ?? 0)
    }

    // MARK: - Supplied Images Section

    @ViewBuilder private var suppliedImagesSection: some View {
        TriptychSectionHeader(title: "Images & Files You Supply", detail: "No OS or keys bundled", accent: TriptychPalette.linuxLight)

        TriptychPanelCard(accent: TriptychPalette.linuxLight) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Triptych never ships Windows, macOS, or copyrighted software. Bring your own ISOs, installers, root filesystems, and app packages.")
                    .font(.system(size: 13))
                    .foregroundStyle(TriptychPalette.textSecondary)

                // Windows 11 ARM64 ISO
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Casement · Windows 11 ARM64 ISO", systemImage: "opticaldisc")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TriptychPalette.windowsLight)
                        Spacer()
                        if winpc.isoURL != nil {
                            Button("Clear") { winpc.forgetISO() }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(TriptychPalette.bad)
                        }
                    }
                    Button { pickingWinISO = true } label: {
                        HStack {
                            Text(winpc.isoURL?.lastPathComponent ?? "Choose Windows ISO from Files…")
                                .font(.system(size: 13))
                                .foregroundStyle(TriptychPalette.textPrimary)
                            Spacer()
                            Image(systemName: "folder")
                                .foregroundStyle(TriptychPalette.windowsLight)
                        }
                        .padding(10)
                        .background(TriptychPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("setup-pick-win-iso")
                }

                divider

                // x86-64 ISO
                VStack(alignment: .leading, spacing: 6) {
                    Label("x86-64 ISO (Linux, SteamOS, x86 Windows)", systemImage: "cpu")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TriptychPalette.linuxLight)
                    Button { pickingX86ISO = true } label: {
                        HStack {
                            Text(x86pc.isoURL?.lastPathComponent ?? "Choose x86-64 ISO from Files…")
                                .font(.system(size: 13))
                                .foregroundStyle(TriptychPalette.textPrimary)
                            Spacer()
                            Image(systemName: "folder")
                                .foregroundStyle(TriptychPalette.linuxLight)
                        }
                        .padding(10)
                        .background(TriptychPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("setup-pick-x86-iso")
                }

                divider

                // Downloaded macOS restore images
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("macOS restore images", systemImage: "macwindow")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TriptychPalette.macLight)
                        Spacer()
                        NavigationLink("Install macOS") { MacInstallView() }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TriptychPalette.macLight)
                    }
                    let downloaded = MacOSRelease.all.filter { Installer.haveImage($0) || Installer.partSize($0) != nil }
                    if downloaded.isEmpty {
                        Text("No macOS restore image downloaded yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(TriptychPalette.textMuted)
                    } else {
                        ForEach(downloaded) { rel in
                            HStack {
                                Text(rel.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(TriptychPalette.textPrimary)
                                Spacer()
                                if let sz = Installer.imageSize(rel) {
                                    Text(ByteText.string(UInt64(sz)))
                                        .font(.system(size: 12))
                                        .foregroundStyle(TriptychPalette.good)
                                } else if let part = Installer.partSize(rel) {
                                    Text("\(ByteText.string(UInt64(part))) partial")
                                        .font(.system(size: 12))
                                        .foregroundStyle(TriptychPalette.warn)
                                }
                                Button { confirmDeleteRelease = rel } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13))
                                        .foregroundStyle(TriptychPalette.bad)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                divider

                // Quick links to Linux & Mac app libraries
                HStack(spacing: 10) {
                    NavigationLink { LinuxDistrosView() } label: {
                        Label("Fresco · Linux distributions", systemImage: "square.stack.3d.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.linuxLight))

                    NavigationLink { MacAppLibraryView() } label: {
                        Label(EngineKind.macapps.title, systemImage: "shippingbox")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.macLight))
                }
            }
        }
    }

    // MARK: - JIT Walkthrough Sub-pages

    @ViewBuilder
    private func jitStepDestination(_ step: Step) -> some View {
        switch step {
        case .pairOnDevice: pairOnDevicePage
        case .importFile: importFilePage
        case .connect: connectPage
        case .enable: enablePage
        case .stikDebug: stikDebugPage
        case .trollStore: trollStorePage
        case .jailbreak: jailbreakPage
        case .liveContainer: liveContainerPage
        }
    }

    private var pairedOnDevice: Bool {
        if case .paired = pairing.phase { return true }
        return false
    }

    private var pairOnDevicePage: some View {
        jitPage(
            symbol: "iphone.radiowaves.left.and.right",
            title: "Pair on this \(device)",
            subtitle: "Triptych advertises itself on your Wi-Fi so your \(device) pairs with it the same way it pairs with a Mac."
        ) {
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    stepPoint(1, "Turn on Wi-Fi, tap **Start pairing** below and allow Local Network access.", done: pairing.phase != .idle)
                    stepPoint(2, "Open **Settings › Privacy & Security › Developer Mode**, scroll down and tap **Pair with \(OnDevicePairing.hostName)**.", done: pairing.isShowingPin || pairedOnDevice)
                    stepPoint(3, "Enter the code shown here (also delivered as a notification).", done: pairedOnDevice)
                    stepPoint(4, "Return to Triptych.", done: pairedOnDevice)
                }
            }
            pairingStatusCard
        } actions: {
            switch pairing.phase {
            case .idle, .failed:
                Button { pairing.start() } label: {
                    Label("Start pairing", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
            case .waiting, .pin:
                Button("Cancel pairing", role: .cancel) { pairing.cancel() }
                    .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.textSecondary))
            case .paired:
                Button("Continue") { path.append(.connect) }
                    .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
            }
        }
    }

    @ViewBuilder private var pairingStatusCard: some View {
        switch pairing.phase {
        case .idle:
            EmptyView()
        case .waiting:
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView().tint(TriptychPalette.macLight)
                        Text("Waiting for your \(device)…")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TriptychPalette.textPrimary)
                    }
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TriptychPalette.macLight)
                    if pairing.backgroundLimited {
                        Text("This installation can only wait about 30 seconds in the background, so go to Settings straight away.")
                            .font(.system(size: 13))
                            .foregroundStyle(TriptychPalette.warn)
                    }
                }
            }
        case .pin(let pin):
            TriptychPanelCard(accent: TriptychPalette.macLight, raised: true) {
                VStack(spacing: 8) {
                    Text("Enter this code on your \(device)")
                        .font(.system(size: 14))
                        .foregroundStyle(TriptychPalette.textSecondary)
                    Text(pin)
                        .font(.system(size: 38, weight: .bold, design: .monospaced))
                        .tracking(6)
                        .foregroundStyle(TriptychPalette.textPrimary)
                        .textSelection(.enabled)
                        .accessibilityLabel("Pairing code \(pin.map(String.init).joined(separator: " "))")
                }
                .frame(maxWidth: .infinity)
            }
        case .paired(let name):
            TriptychNoticeBanner(symbol: "checkmark.circle.fill", text: "Paired with \(name)", tint: TriptychPalette.good)
        case .failed(let message):
            TriptychNoticeBanner(symbol: "exclamationmark.triangle.fill", text: message, tint: TriptychPalette.bad)
        }
    }

    private var importFilePage: some View {
        jitPage(
            symbol: "doc.badge.plus",
            title: "Use a pairing file",
            subtitle: "A pairing file made on a computer lets Triptych's built-in helper attach to this \(device)."
        ) {
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    stepPoint(1, "On a computer, create this \(device)'s pairing file with the [StikDebug pairing-file guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md).", done: jit.pairingSource == .imported)
                    stepPoint(2, "Save it to Files, or AirDrop it to this \(device).", done: jit.pairingSource == .imported)
                    stepPoint(3, "Tap **Choose pairing file** below and select it.", done: jit.pairingSource == .imported)
                }
            }
            Label("The pairing file stays in Triptych's Documents folder and is only sent to Triptych's own helper.", systemImage: "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(TriptychPalette.textSecondary)
            if let error = jit.error {
                TriptychNoticeBanner(symbol: "exclamationmark.triangle.fill", text: error, tint: TriptychPalette.bad)
            }
        } actions: {
            if jit.pairingSource == .imported {
                Button("Continue") { path.append(.connect) }
                    .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
                Button("Choose another file") { pickingPairing = true }
                    .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.macLight))
            } else {
                Button { pickingPairing = true } label: {
                    Label("Choose pairing file", systemImage: "folder")
                }
                .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
            }
        }
    }

    private var connectPage: some View {
        jitPage(
            symbol: "network.badge.shield.half.filled",
            title: "Connect LocalDevVPN",
            subtitle: "Triptych's built-in helper reaches this \(device)'s debugging service over a local loopback VPN. Nothing leaves your \(device)."
        ) {
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    stepPoint(1, "Install [LocalDevVPN](\(LocalDevVPN.appStore.absoluteString)) from the App Store.", done: LocalDevVPN.isInstalled)
                    stepPoint(2, "Tap **Connect LocalDevVPN** to switch the tunnel on and return to Triptych.", done: LocalDevVPN.isConnected)
                    stepPoint(3, "Keep it connected whenever enabling JIT.")
                }
            }
        } actions: {
            Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
            Button("It's connected") { path.append(.enable) }
                .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.macLight))
        }
    }

    private var attached: Bool { jitState == .on }

    private var enablePage: some View {
        jitPage(
            symbol: "bolt.badge.checkmark",
            title: "Turn on JIT",
            subtitle: "The first check downloads and mounts Apple's Developer Disk Image, which can take a minute."
        ) {
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    stepPoint(1, "Tap **Check setup** to verify LocalDevVPN and prepare the Developer Disk Image.", done: jit.prepared || attached)
                    stepPoint(2, "Tap **Enable JIT** so Triptych's helper can attach and reserve executable memory.", done: attached)
                }
            }
            if jit.busy {
                TriptychPanelCard(raised: true) {
                    HStack(spacing: 10) {
                        ProgressView().tint(TriptychPalette.macLight)
                        Text(jit.status ?? "Working…")
                            .font(.system(size: 14))
                            .foregroundStyle(TriptychPalette.textPrimary)
                    }
                }
            } else if attached {
                TriptychNoticeBanner(symbol: "checkmark.circle.fill", text: "JIT is on. Windows and macOS can start.", tint: TriptychPalette.good)
                    .accessibilityIdentifier("setup-jit-outcome")
            } else if jit.error == nil, case .failed(let why) = jitState {
                TriptychNoticeBanner(symbol: "exclamationmark.triangle.fill", text: why, tint: TriptychPalette.bad)
                    .accessibilityIdentifier("setup-jit-outcome")
            } else if jit.error == nil, jitState == .claiming {
                TriptychPanelCard(raised: true) {
                    HStack(spacing: 10) {
                        ProgressView().tint(TriptychPalette.macLight)
                        Text("A debugger is attached. Claiming the JIT region…")
                            .font(.system(size: 14))
                            .foregroundStyle(TriptychPalette.textPrimary)
                    }
                }
                .task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if JITBootstrap.state == .claiming { JITBootstrap.prewarm() }
                    jit.objectWillChange.send()
                }
            } else if let error = jit.error {
                VStack(alignment: .leading, spacing: 8) {
                    TriptychNoticeBanner(symbol: "exclamationmark.triangle.fill", text: error, tint: TriptychPalette.bad)
                    if jit.advice?.actions.contains(.pairAgain) == true {
                        Button(OnDevicePairing.isSupported ? "Pair again" : "Import a new pairing file") {
                            path = [OnDevicePairing.isSupported ? .pairOnDevice : .importFile]
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TriptychPalette.macLight)
                    }
                    if jit.advice?.actions.contains(.connectLocalDevVPN) == true {
                        Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TriptychPalette.macLight)
                    }
                }
            } else if let status = jit.status {
                TriptychNoticeBanner(symbol: "checkmark.circle.fill", text: status, tint: TriptychPalette.good)
            }
            if !attached {
                Button("Reset Developer Disk Image", role: .destructive) { jit.resetDDI() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TriptychPalette.bad)
                    .disabled(jit.busy)
            }
        } actions: {
            if attached {
                Button("Done") { path.removeAll() }
                    .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
            } else if jit.prepared {
                Button { jit.enableBuiltIn() } label: {
                    Label("Enable JIT", systemImage: "bolt.fill")
                }
                .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac, enabled: !jit.busy))
                .disabled(jit.busy)
            } else {
                Button("Check setup") { jit.prepareBuiltIn() }
                    .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac, enabled: !jit.busy))
                    .disabled(jit.busy)
            }
        }
    }

    private var stikDebugPage: some View {
        jitPage(
            symbol: "ant",
            title: "Use StikDebug",
            subtitle: "StikDebug is an external app that attaches to Triptych. Triptych sends its unified JIT script inline."
        ) {
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    stepPoint(1, "Install [StikDebug](https://github.com/StikDebug/StikDebug/releases/latest).", done: JITBootstrap.isStikDebugInstalled)
                    stepPoint(2, "Import this \(device)'s pairing file into StikDebug.")
                    stepPoint(3, "Install and connect [LocalDevVPN](\(LocalDevVPN.appStore.absoluteString)).", done: LocalDevVPN.isConnected)
                    stepPoint(4, "Tap **Enable with StikDebug** in Triptych when starting Windows or macOS.")
                }
            }
        } actions: {
            Button("Use StikDebug") {
                jit.method = .stikDebug
                TriptychLog.log("jit", "JIT method set to StikDebug")
                path.removeAll()
            }
            .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
        }
    }

    private var liveContainerPage: some View {
        jitPage(
            symbol: "shippingbox",
            title: "Inside LiveContainer",
            subtitle: "LiveContainer runs Triptych as a guest app. Either enable Helper Process Support or launch with Triptych's JIT script."
        ) {
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Built-in helper")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TriptychPalette.textPrimary)
                    stepPoint(1, "Use a LiveContainer nightly build with **Helper Process Support**.", done: LiveContainerHost.runsHelperProcesses)
                    stepPoint(2, "Turn on **Helper Process Support** for Triptych in LiveContainer and reopen.", done: LiveContainerHost.runsHelperProcesses)
                    stepPoint(3, "Pair this \(device) or import a pairing file, and connect LocalDevVPN.", done: jit.hasPairing)
                }
            }
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("StikDebug at launch")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TriptychPalette.textPrimary)
                    stepPoint(1, "Save Triptych's JIT script to Files.")
                    stepPoint(2, "In LiveContainer's settings for Triptych, turn on **Launch with JIT** and pick that script.")
                    if let script = JITBootstrap.scriptFileURL {
                        ShareLink(item: script) {
                            Label("Save Triptych's JIT script", systemImage: "square.and.arrow.up")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TriptychPalette.macLight)
                    }
                }
            }
        } actions: {
            if LiveContainerHost.runsHelperProcesses {
                Button("Continue") {
                    jit.method = .builtIn
                    path.append(jit.hasPairing ? .connect : (OnDevicePairing.isSupported ? .pairOnDevice : .importFile))
                }
                .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
            } else {
                Button("Use StikDebug") {
                    jit.method = .stikDebug
                    path.removeAll()
                }
                .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
            }
        }
    }

    private var trollStorePage: some View {
        jitPage(
            symbol: "sparkles",
            title: "Use TrollStore",
            subtitle: "TrollStore enables JIT for apps it installed, with no pairing file or VPN."
        ) {
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    stepPoint(1, "Install Triptych through TrollStore on iOS 14.0–17.0.", done: JITBootstrap.isInstalledWithTrollStore)
                    stepPoint(2, "Enable **URL Scheme** in TrollStore's Settings.")
                    stepPoint(3, "Triptych asks TrollStore for JIT automatically when needed.")
                }
            }
            if !JITBootstrap.isTrollStoreInstalled {
                TriptychNoticeBanner(symbol: "info.circle", text: "TrollStore was not detected on this \(device).", tint: TriptychPalette.textSecondary)
            }
        } actions: {
            Button("Use TrollStore") {
                jit.method = .trollStore
                path.removeAll()
            }
            .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
        }
    }

    private var jailbreakPage: some View {
        jitPage(
            symbol: "lock.open",
            title: "Use a jailbreak",
            subtitle: "On Dopamine, turning on Allow JIT in Apps marks Triptych as debugged at launch."
        ) {
            TriptychPanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    stepPoint(1, "Open Dopamine Settings.", done: JITBootstrap.isJailbroken)
                    stepPoint(2, "Enable **Allow JIT in Apps**.")
                    stepPoint(3, "Quit Triptych completely and reopen it.", done: JITBootstrap.debuggedAtLaunch)
                }
            }
            if JITBootstrap.debuggedAtLaunch {
                TriptychNoticeBanner(symbol: "checkmark.circle.fill", text: "Triptych launched with JIT enabled.", tint: TriptychPalette.good)
            }
        } actions: {
            Button("Use the jailbreak") {
                jit.method = .jailbreak
                path.removeAll()
            }
            .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac))
        }
    }

    // MARK: - Helpers

    private func jitPage<Content: View, Actions: View>(
        symbol: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(TriptychPalette.macLight)
                        .frame(width: 52, height: 52)
                        .background(TriptychPalette.macDeep.opacity(0.28), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    Text(title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(TriptychPalette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(TriptychPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .triptychColumn()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) { actions() }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .background(TriptychPalette.canvasDeep.opacity(0.92))
        }
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
    }

    private func stepPoint(_ number: Int, _ text: String, done: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? TriptychPalette.good.opacity(0.2) : TriptychPalette.macDeep.opacity(0.32))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(TriptychPalette.good)
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(TriptychPalette.macLight)
                }
            }
            .frame(width: 24, height: 24)
            Text(.init(text))
                .font(.system(size: 14))
                .foregroundStyle(TriptychPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var divider: some View {
        Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
    }
}
