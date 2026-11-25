// SPDX-License-Identifier: GPL-3.0-or-later
// Switching systems without the user quitting the app by hand. Some systems can't share one process (docs/ARCHITECTURE.md:
// each claims process-wide state), so switching needs a fresh launch. Triptych does that itself: it remembers where to go,
// asks whatever gave it JIT to start it again (LiveContainer, or StikDebug), and quits. The new launch opens that system.
import SwiftUI
import UIKit

enum Relaunch {
    private static let pendingKey = "triptych.relaunch.open"

    /// The app bundle's folder name, as LiveContainer lists it (Bundle.main is not reliable once a Mac app ran in process).
    static var bundleFolderName: String {
        var dl = Dl_info()
        if dladdr(#dsohandle, &dl) != 0, let f = dl.dli_fname {
            return URL(fileURLWithPath: String(cString: f)).deletingLastPathComponent().lastPathComponent
        }
        return URL(fileURLWithPath: Bundle.main.bundlePath).lastPathComponent
    }

    static var bundleID: String { (DeviceInfo.ownInfo["CFBundleIdentifier"] as? String) ?? "app.triptych.Triptych" }

    /// The URL that starts Triptych again with JIT, or nil when nothing can (then the app quits and the user taps its icon).
    static var relaunchURL: URL? {
        var c = URLComponents()
        if JIT.isInLiveContainer {
            // LiveContainer starts the app again, with JIT when the app's "Launch with JIT" setting is on.
            c.scheme = "livecontainer"; c.host = "livecontainer-launch"
            c.queryItems = [URLQueryItem(name: "bundle-name", value: bundleFolderName)]
        } else {
            // StikDebug launches the app by bundle ID and attaches with Triptych's script (no pid: this process is quitting).
            c.scheme = "stikdebug"; c.host = "enable-jit"
            var q = [URLQueryItem(name: "bundle-id", value: bundleID)]
            if let s = JIT.scriptBase64 { q.append(URLQueryItem(name: "script-data", value: s)) }
            c.queryItems = q
        }
        return c.url
    }

    /// Restart Triptych and open `kind` when it is back.
    static func restart(into kind: EngineKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: pendingKey)
        UserDefaults.standard.synchronize()
        TriptychLog.log("relaunch", "restarting into \(kind.title) via \(relaunchURL?.scheme ?? "none")")
        guard let url = relaunchURL else { quitSoon(); return }
        UIApplication.shared.open(url) { ok in
            TriptychLog.log("relaunch", ok ? "relaunch requested" : "relaunch URL refused; quitting (tap Triptych to reopen)")
            quitSoon()
        }
    }

    private static func quitSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
    }

    /// The system a restart asked for, once.
    static func takePending() -> EngineKind? {
        guard let raw = UserDefaults.standard.string(forKey: pendingKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        TriptychLog.log("relaunch", "opening \(raw), as the restart asked")
        return EngineKind(rawValue: raw)
    }
}

/// "Switch to X" for a system this launch can't start: one tap restarts Triptych into it.
struct SwitchSystemButton: View {
    let kind: EngineKind
    var body: some View {
        Button { Relaunch.restart(into: kind) } label: {
            Label("Restart Triptych into \(kind.title)", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("switch-\(kind.rawValue)")
    }
}

/// Shown in place of a system's page when this launch can't run it alongside the one already running.
struct SwitchSystemView: View {
    @EnvironmentObject var session: SessionState
    let kind: EngineKind
    var body: some View {
        List {
            Section {
                Text("\(session.activeEngine?.title ?? "Another system") is running and can't share this launch with \(kind.title). Triptych restarts itself and opens \(kind.title); unsaved work in the running system is lost.")
                SwitchSystemButton(kind: kind)
            }
        }
        .navigationTitle(kind.title)
        .exportLogsToolbar()
        .onAppear { TriptychLog.log("engine", "\(kind.title) can't share this launch with \(session.activeEngine?.title ?? "?"): offering a restart") }
    }
}
