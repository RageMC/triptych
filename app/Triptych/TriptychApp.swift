// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import MacAppsKit

@main
struct TriptychApp: App {
    /// Henge's external-display scene handling before iOS 27 (LegacyExternalDisplay.swift).
    @UIApplicationDelegateAdaptor(HengeAppDelegate.self) private var appDelegate
    @StateObject private var session = SessionState()
    @State private var confirmStopPane = false
    init() {
        TriptychLog.start()
        // CrossOver Preview's Wine commands run in Pane (PaneWineCommand.c): its first command loads Pane.
        PaneWineCommandSetLoader {
            if Thread.isMainThread { return MadeiraRuntime.load() ? 1 : 0 }
            return DispatchQueue.main.sync { MadeiraRuntime.load() ? 1 : 0 }
        }
        #if DEBUG && targetEnvironment(simulator)
        if let mode = ProcessInfo.processInfo.environment["TRIPTYCH_CURATOR_UI_TEST"] {
            CuratorReportingUITestFixture.install(mode: mode)
            TriptychLog.log("macapps", "Sample returned -1: Turn on JIT first.")
            CuratorReportUITestStub.install(mode: ProcessInfo.processInfo.environment["TRIPTYCH_CURATOR_REPORT_STUB"])
            CuratorReportUITestStub.installLocalRelay(ProcessInfo.processInfo.environment["TRIPTYCH_CURATOR_LOCAL_RELAY"])
        }
        // UI tests only: put a real (scrubbed) device log where Provenance looks, so Curator triages it.
        if let sample = ProcessInfo.processInfo.environment["TRIPTYCH_CURATOR_SAMPLE_LOG"] {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let target = docs.appending(path: "device-sample.log")
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: sample), to: target)
            // Provenance reads newest first; date the copy ahead so Curator reads it before this run's own logs.
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: target.path)
        }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if session.showWindows, let windows = session.windowsRoot {
                    SystemDisplay {
                        HostedController(controller: windows)
                    } controls: {
                        SessionBackButton { session.showWindows = false }
                        Button("Stop", role: .destructive) { confirmStopPane = true }
                    }
                    .confirmationDialog("Stop Pane?", isPresented: $confirmStopPane, titleVisibility: .visible) {
                        Button("Restart Triptych", role: .destructive) { Relaunch.restart(into: .windows) }
                    }
                } else {
                    TriptychHomeView()
                        .preferredColorScheme(.dark)
                }
            }
            .environmentObject(session)
            #if DEBUG && targetEnvironment(simulator)
            .onAppear {
                if session.windowsRoot == nil && ProcessInfo.processInfo.arguments.contains("-pane.display-preview") {
                    let preview = UIViewController()
                    preview.view.backgroundColor = .black
                    preview.view.accessibilityIdentifier = "pane-display"
                    preview.view.isAccessibilityElement = true
                    session.windowsRoot = preview
                    session.showWindows = true
                }
            }
            #endif
            .onOpenURL { url in
                // madeira:// links and .madeirasetup files go to Windows (started first if nothing else runs).
                guard url.scheme == "madeira" || url.pathExtension == "madeirasetup",
                      EngineRegistry.availability(.windows) == .ready else { return }
                if session.activeEngine == nil { _ = WindowsLauncher.start(session) }
                if session.activeEngine == .windows {
                    session.showWindows = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MadeiraRuntime.open(url) }
                }
            }
        }
    }
}

/// Engines keep process-wide resources after startup. Track everyone that has used the launch.
final class SessionState: ObservableObject {
    @Published private(set) var activeEngine: EngineKind? {
        didSet { if activeEngine != oldValue { TriptychLog.log("engine", "\(activeEngine?.title ?? "none") is now the running system") } }
    }
    /// Engine combinations exercised together. Linux uses a private PTY, and both PC engines write serial to files.
    /// Keep larger combinations behind the restart prompt until they have been exercised together.
    static let canShareLaunch: Set<Set<EngineKind>> = [
        [.winpc, .macapps],
        [.linux, .winpc],
        [.linux, .macapps],
        [.linux, .x86pc],
    ]
    @Published private(set) var started: Set<EngineKind> = []
    func canStart(_ kind: EngineKind) -> Bool {
        let engines = started.union([kind])
        return engines.count == 1 || Self.canShareLaunch.contains(engines)
    }
    /// Record a system as started (keeps the first as activeEngine).
    func markStarted(_ k: EngineKind) {
        CuratorFallbackModel.shared.prepareForEngineStart()
        started.insert(k)
        DeviceInfo.recordRan(k)
        if activeEngine == nil { activeEngine = k } else if activeEngine != k { TriptychLog.log("engine", "\(k.title) started alongside \(activeEngine!.title)") }
    }
    @Published var showWindows = false
    /// Keep the controller alive while returning to the Triptych library.
    @Published var windowsRoot: UIViewController?
}
