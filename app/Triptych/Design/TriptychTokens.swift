// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

extension Color {
    /// Creates a Color from a 24-bit RGB hex value (e.g. `0x2563EB`).
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

/// Colour tokens derived from docs/brand/triptych-icon.svg:
/// dark navy canvas (#07070F -> #121329 -> #23264A), blue Windows (#4FD1FF / #2563EB),
/// violet Mac (#F5F3FF / #C4B5FD / #7C3AED), and amber Linux (#FFD166 / #F97316).
enum TriptychPalette {
    // MARK: Navy canvas & surfaces
    static let canvasDeep = Color(hex: 0x07070F)
    static let canvasMid = Color(hex: 0x121329)
    static let canvasNavy = Color(hex: 0x23264A)
    static let surface = Color(hex: 0x151730)
    static let surfaceRaised = Color(hex: 0x1D2042)
    static let surfaceInteractive = Color(hex: 0x252952)

    // MARK: Hinges & hairlines
    static let hinge = Color(hex: 0xE0E7FF)
    static let hairline = Color(hex: 0xE0E7FF, opacity: 0.14)
    static let hairlineStrong = Color(hex: 0xE0E7FF, opacity: 0.26)

    // MARK: Typography
    static let textPrimary = Color(hex: 0xF5F3FF)
    static let textSecondary = Color(hex: 0xB8BED9)
    static let textMuted = Color(hex: 0x7E84A6)

    // MARK: Panel accents (from triptych-icon.svg)
    static let windowsLight = Color(hex: 0x4FD1FF)
    static let windowsDeep = Color(hex: 0x2563EB)

    static let macHighlight = Color(hex: 0xF5F3FF)
    static let macLight = Color(hex: 0xC4B5FD)
    static let macDeep = Color(hex: 0x7C3AED)

    static let linuxLight = Color(hex: 0xFFD166)
    static let linuxDeep = Color(hex: 0xF97316)

    // MARK: Semantic status
    static let good = Color(hex: 0x34D399)
    static let warn = Color(hex: 0xFFD166)
    static let bad = Color(hex: 0xFB7185)
    static let neutral = Color(hex: 0x94A3B8)

    // MARK: Gradients
    static let backdrop = RadialGradient(
        colors: [canvasNavy, canvasMid, canvasDeep],
        center: UnitPoint(x: 0.5, y: 0.22),
        startRadius: 20,
        endRadius: 680
    )

    static let windowsGradient = LinearGradient(
        colors: [windowsLight, windowsDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let macGradient = LinearGradient(
        colors: [macLight, macDeep],
        startPoint: .top,
        endPoint: .bottom
    )

    static let linuxGradient = LinearGradient(
        colors: [linuxLight, linuxDeep],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )
}

/// The three hinged panels of Triptych.
enum TriptychPanel: String, CaseIterable, Identifiable, Hashable {
    case windows, mac, linux
    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: return "Windows"
        case .mac: return "Atelier"
        case .linux: return "Fresco"
        }
    }

    var subtitle: String {
        switch self {
        case .windows: return "Casement & Pane"
        case .mac: return "macOS & Mac apps"
        case .linux: return "Linux systems"
        }
    }

    var symbol: String {
        switch self {
        case .windows: return "pc"
        case .mac: return "macwindow"
        case .linux: return "terminal"
        }
    }

    var accent: Color {
        switch self {
        case .windows: return TriptychPalette.windowsLight
        case .mac: return TriptychPalette.macLight
        case .linux: return TriptychPalette.linuxLight
        }
    }

    var deepAccent: Color {
        switch self {
        case .windows: return TriptychPalette.windowsDeep
        case .mac: return TriptychPalette.macDeep
        case .linux: return TriptychPalette.linuxDeep
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .windows: return TriptychPalette.windowsGradient
        case .mac: return TriptychPalette.macGradient
        case .linux: return TriptychPalette.linuxGradient
        }
    }

    var engines: [EngineKind] {
        switch self {
        case .windows: return [.windows, .winpc, .x86pc]
        case .mac: return [.macos, .macapps]
        case .linux: return [.linux, .x86pc, .android]
        }
    }
}

extension EngineKind {
    var panel: TriptychPanel {
        switch self {
        case .windows, .winpc: return .windows
        case .macos, .macapps: return .mac
        case .linux, .android, .x86pc: return .linux
        }
    }
}
