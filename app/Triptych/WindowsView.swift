// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

/// The Windows engine: Madeira (Wine ARM64EC + FEX + DXMT + madeira-d3d12) with its
/// own library, game pages, JIT setup and controls, built as MadeiraRuntime.framework
/// (scripts/build-windows-engine.sh). It is loaded only here, so the 1.1 GB address
/// claim at 0x140000000, Wine/FEX's signal handlers and Madeira's Rust runtime never
/// touch a macOS or Linux launch.
enum MadeiraRuntime {
    typealias MakeRoot = @convention(c) () -> UnsafeMutableRawPointer
    typealias OpenURL = @convention(c) (UnsafePointer<CChar>) -> Int32

    static var path: String? {
        guard let fw = Bundle.main.privateFrameworksPath else { return nil }
        let p = fw + "/MadeiraRuntime.framework/MadeiraRuntime"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }
    static var isBundled: Bool { path != nil }

    private static var handle: UnsafeMutableRawPointer?
    private(set) static var loadError: String?

    /// dlopen once. Madeira can't be unloaded (Wine keeps threads and mappings).
    static func load() -> Bool {
        if handle != nil { return true }
        guard let p = path else { loadError = "Pane is unavailable in this build."; return false }
        tp_release_madeira_va()
        guard let h = dlopen(p, RTLD_NOW | RTLD_LOCAL) else {
            loadError = String(cString: dlerror()); return false
        }
        handle = h
        return true
    }

    static func makeRoot() -> UIViewController? {
        guard load(), let s = dlsym(handle, "madeira_embed_make_root") else { return nil }
        let f = unsafeBitCast(s, to: MakeRoot.self)
        return Unmanaged<UIViewController>.fromOpaque(f()).takeRetainedValue()
    }

    /// madeira://… links and .madeirasetup files. Only once Windows is running.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard handle != nil, let s = dlsym(handle, "madeira_embed_open_url") else { return false }
        return url.absoluteString.withCString { unsafeBitCast(s, to: OpenURL.self)($0) } != 0
    }
}

/// Starts Windows. Madeira's controller then fills Triptych's window as the only content of its SwiftUI root, the
/// same shape as Madeira's own app (a SwiftUI WindowGroup), with nothing presented over it: Madeira's input code
/// treats any presented controller as an open menu (HardwareInput.swift), and its pointer lock hooks the window's
/// root controller. Wine cannot be unloaded, so Windows stays until Triptych is quit.
enum WindowsLauncher {
    @MainActor static func start(_ session: SessionState) -> String? {
        if let a = session.activeEngine, a != .windows {
            return "\(a.title) is running. Quit and reopen Triptych to start Windows."
        }
        if session.windowsRoot != nil { session.showWindows = true; return nil }
        // A Mac started from Henge's screens this launch (they don't go through activeEngine).
        if henge_vm_generation() != 0 { return "macOS ran in this session. Quit and reopen Triptych to start Windows." }
        CuratorFallbackModel.shared.prepareForEngineStart()
        guard let vc = MadeiraRuntime.makeRoot() else { return MadeiraRuntime.loadError ?? "Could not start Pane." }
        session.markStarted(.windows)
        session.windowsRoot = vc
        session.showWindows = true
        return nil
    }
}

struct HostedController: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}
