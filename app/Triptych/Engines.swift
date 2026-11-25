// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum EngineKind: String, CaseIterable, Identifiable {
    case windows, winpc, macos, macapps, linux, android, x86pc
    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: return "Pane · Windows games & apps"
        case .winpc: return "Casement · Windows 11 PC"
        case .macos: return "Atelier · macOS"
        case .macapps: return "Atelier · Mac apps"
        case .linux: return "Fresco · Linux"
        case .android: return "Android apps"
        case .x86pc: return "x86 PC"
        }
    }
    var symbol: String {
        switch self {
        case .windows: return "gamecontroller"
        case .winpc: return "pc"
        case .macos: return "macwindow"
        case .macapps: return "square.grid.2x2"
        case .linux: return "terminal"
        case .android: return "apps.iphone"
        case .x86pc: return "cpu"
        }
    }
    var summary: String {
        switch self {
        case .windows: return "Run x86 and x64 Windows games and apps with FEX-Emu, Wine and Direct3D translation on Metal."
        case .winpc: return "A full virtual ARM64 PC for Windows 11 on Arm from your own ISO, powered by Gesso."
        case .macos: return "A virtual Mac powered by Gesso. Install macOS from an Apple restore image."
        case .macapps: return "Import individual Mac apps from a .dmg, .pkg or .zip. Triptych adapts supported arm64 apps to run on a UIKit-backed AppKit layer."
        case .linux: return "ARM64 Linux userspace on an interpreter (JIT optional), with a terminal and an Xfce desktop. From LinuxRunner / iSH."
        case .android: return "Android apps from your own APKs: their arm64 code runs natively with Android's libraries supplied around it, with full LineageOS under QEMU as the fallback. Based on Husk."
        case .x86pc: return "A whole x86-64 PC for x86 ISOs (Linux, SteamOS, x86 Windows) on QEMU, the way UTM does it. Slow: for desktops and apps, not games."
        }
    }
    /// Where it really stands (docs/STATUS.md), shown under the readiness on the Home screen.
    var stage: String {
        switch self {
        case .windows: return "Device build available. Launching games and apps on a device is untested."
        case .winpc: return "Windows 11 installs and reaches the desktop on a Mac with a TPM 2.0 (libtpms) and a network adapter. On an iPad the installer reaches the Windows kernel and stops; not working on devices yet."
        case .macos: return "The Simulator passes the JIT probe. Installing and booting macOS requires device testing with JIT."
        case .macapps: return "The Simulator retags and launches sample apps. CrossOver Preview creates bottles from its own window. Device launch is untested."
        case .linux: return "Alpine, Ubuntu, Debian, Fedora, Arch and custom root filesystems boot in the Simulator. Xfce uses software rendering."
        case .android: return "The translation layer builds. Running APKs in Triptych is pending."
        case .x86pc: return "Alpine and Linux Mint boot in the Simulator, with display, touch and keyboard. Device boot is untested."
        }
    }
}

enum EngineAvailability: Equatable {
    case ready
    case needsDevice(String)
    case notBuilt(String)
    case notInApp(String)
}

enum EngineRegistry {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static func availability(_ kind: EngineKind) -> EngineAvailability {
        switch kind {
        case .linux:
            return tp_linux_available() ? .ready : .notBuilt("Run scripts/build-linux-engine.sh for this SDK.")
        case .winpc, .macapps:
            return .ready
        case .macos:
            return tp_macos_available() ? .ready : .notBuilt("Run scripts/build-macos-engine.sh for this SDK.")
        case .android: return .notInApp("The Husk translation layer builds (engines/android/build.sh) but has no page in Triptych yet.")
        case .x86pc:
            // Simulator uses the JIT build; devices fall back to TCTI, so either one bundled counts as ready.
            let bundled = x86pc_host_build_bundled(x86pc_host_build_jit()) || x86pc_host_build_bundled(x86pc_host_build_tcti())
            return bundled ? .ready : .notBuilt("Run scripts/build-x86pc.sh for this SDK, then rebuild the app.")
        case .windows:
            if isSimulator { return .needsDevice("FEX, Wine and DXMT are built for iphoneos only, and need JIT from a debugger.") }
            return MadeiraRuntime.isBundled ? .ready : .notBuilt("Run scripts/build-windows-engine.sh, then rebuild the app.")
        }
    }
}
