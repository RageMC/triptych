// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import MacAppsKit

/// The Mac apps page: import a .dmg/.pkg/.zip from Files (engines/macapps' macpkg reads it), list the installed
/// .app bundles with their icons, and run one on the AppKit shim.
struct MacAppLibraryView: View {
    @EnvironmentObject var session: SessionState
    @State private var apps: [MacAppInfo] = []
    @State private var picking = false
    @State private var message = ""
    @State private var running: MacAppInfo?
    @State private var confirmStop = false
    @State private var importing = false
    #if DEBUG
    @State private var attemptedTestImport = false
    #endif

    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TriptychPanelCard(accent: TriptychPalette.macLight, raised: true) {
                        Text(EngineKind.macapps.summary)
                            .font(.system(size: 14))
                            .foregroundStyle(TriptychPalette.textSecondary)
                    }

                    TriptychSectionHeader(title: "Installed", accent: TriptychPalette.macLight)
                    TriptychPanelCard(padding: 0) {
                        VStack(spacing: 0) {
                            if apps.isEmpty {
                                Text("No Mac apps yet. Import a .dmg, .pkg or .zip, or add the bundled sample.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(TriptychPalette.textSecondary)
                                    .padding(16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("macapps-empty")
                            }
                            ForEach(Array(apps.enumerated()), id: \.element.path) { idx, app in
                                Button {
                                    session.markStarted(.macapps)
                                    running = app
                                } label: {
                                    HStack(spacing: 12) {
                                        MacAppIcon(path: app.iconPath)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.name)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(TriptychPalette.textPrimary)
                                            Text(app.launchable ? "Runs on the AppKit shim" : "The selected loader can’t run this executable.")
                                                .font(.caption)
                                                .foregroundStyle(app.launchable ? TriptychPalette.good : TriptychPalette.textSecondary)
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
                                .disabled(!app.launchable || !session.canStart(.macapps) || MacAppHostController.guestHasStarted())
                                .accessibilityIdentifier("macapp-\(app.name)")
                                .contextMenu {
                                    Button("Remove", role: .destructive) { MacAppLibrary.removeApp(atPath: app.path); reload() }
                                }
                                if idx < apps.count - 1 {
                                    Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                                }
                            }
                        }
                    }

                    TriptychSectionHeader(title: "Import", accent: TriptychPalette.macLight)
                    TriptychPanelCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Button("Import .dmg, .pkg or .zip…") { picking = true }
                                .buttonStyle(TriptychPrimaryButtonStyle(panel: .mac, enabled: !importing))
                                .disabled(importing)
                                .accessibilityIdentifier("macapps-import")

                            if importing {
                                ProgressView("Importing…")
                                    .tint(TriptychPalette.macLight)
                                    .accessibilityIdentifier("macapps-importing")
                            }

                            Button("Add the bundled sample (TestMacApp.zip)") { importFile(MacAppLibrary.bundledSampleZipPath()) }
                                .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.macLight))
                                .accessibilityIdentifier("macapps-import-sample")

                            Button("Add a Mac-built sample (retagged on import)") { importFile(MacAppLibrary.bundledMacBuiltSampleZipPath()) }
                                .buttonStyle(TriptychSecondaryButtonStyle(accent: TriptychPalette.macLight))
                                .accessibilityIdentifier("macapps-import-mac-sample")

                            if !message.isEmpty {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(TriptychPalette.textSecondary)
                                    .accessibilityIdentifier("macapps-message")
                            }
                        }
                    }

                    Text("Your own files only; Triptych downloads nothing. Once a Mac app starts, it keeps the run loop: quit and reopen Triptych to start another.")
                        .font(.footnote)
                        .foregroundStyle(TriptychPalette.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle(EngineKind.macapps.title)
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
        .onAppear {
            reload()
            #if DEBUG
            // UI tests hand a host path in (the Simulator reads the Mac's file system); XCUITest can't drive Files.
            let environment = ProcessInfo.processInfo.environment
            if !attemptedTestImport, let path = environment["TRIPTYCH_MACAPPS_IMPORT"], !path.isEmpty,
               let name = environment["TRIPTYCH_MACAPPS_IMPORT_NAME"],
               environment["TRIPTYCH_MACAPPS_REIMPORT"] == "1" || !apps.contains(where: { $0.name == name }) {
                attemptedTestImport = true
                importFile(path)
            }
            #endif
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .data], allowsMultipleSelection: false) { r in
            guard case .success(let urls) = r, let u = urls.first else { return }
            let ok = u.startAccessingSecurityScopedResource()
            importFile(u.path) { if ok { u.stopAccessingSecurityScopedResource() } }
        }
        .fullScreenCover(item: Binding(get: { running.map { RunningApp(app: $0) } }, set: { if $0 == nil { running = nil } })) { r in
            SystemDisplay {
                MacAppHostView(path: r.app.path)
            } controls: {
                Button("Close") { running = nil }
                    .accessibilityIdentifier("macapp-close")
                Button("Stop", role: .destructive) { confirmStop = true }
                    .accessibilityIdentifier("macapp-stop")
            }
            .confirmationDialog("Stop this Mac app?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Restart Triptych", role: .destructive) { Relaunch.restart(into: .macapps) }
            } message: {
                Text("Restarting stops every system running in Triptych.")
            }
        }
    }

    /// Off the main thread: a large app (CrossOver: 2 GB, ~14,000 files, ~200 Mach-O files to retag) takes a while.
    private func importFile(_ path: String?, done: @escaping () -> Void = {}) {
        guard let path else { message = "Sample missing from this build."; done(); return }
        importing = true
        message = ""
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSString?
            let names = MacAppLibrary.importFile(atPath: path, error: &err)
            DispatchQueue.main.async {
                if let names { message = "Imported: " + names.joined(separator: ", ") }
                else { message = "Import failed: " + ((err as String?) ?? "unknown") }
                importing = false
                reload()
                done()
            }
        }
    }
    private func reload() { apps = MacAppLibrary.installedApps() }
}

private struct RunningApp: Identifiable { let app: MacAppInfo; var id: String { app.path } }

private struct MacAppHostView: UIViewControllerRepresentable {
    let path: String
    func makeUIViewController(context: Context) -> MacAppHostController { MacAppHostController(appPath: path) }
    func updateUIViewController(_ vc: MacAppHostController, context: Context) {}
}

private struct MacAppIcon: View {
    let path: String?
    var body: some View {
        Group {
            if let path, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                Image(decorative: img, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary).padding(8)
            }
        }.frame(width: 44, height: 44)
    }
}
