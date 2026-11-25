// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Dark navy radial backdrop matching docs/brand/triptych-icon.svg.
struct TriptychBackdrop: View {
    var body: some View {
        ZStack {
            TriptychPalette.canvasDeep
            TriptychPalette.backdrop
        }
        .ignoresSafeArea()
    }
}

/// Shared card surface with subtle hairline edge and optional panel accent rim.
struct TriptychPanelCard<Content: View>: View {
    var accent: Color? = nil
    var raised: Bool = false
    var cornerRadius: CGFloat = 20
    var padding: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (raised ? TriptychPalette.surfaceRaised : TriptychPalette.surface),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(accent?.opacity(0.32) ?? TriptychPalette.hairline, lineWidth: 1)
            )
    }
}

extension View {
    /// Applies Triptych's card surface and border directly to a container.
    func triptychCard(accent: Color? = nil, raised: Bool = false, radius: CGFloat = 20) -> some View {
        background(
            (raised ? TriptychPalette.surfaceRaised : TriptychPalette.surface),
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(accent?.opacity(0.32) ?? TriptychPalette.hairline, lineWidth: 1)
        )
    }

    /// Constrains scroll content to a comfortable reading column on iPad.
    func triptychColumn() -> some View {
        frame(maxWidth: 700).frame(maxWidth: .infinity)
    }
}

/// Shared section header with optional trailing detail and accent bar.
struct TriptychSectionHeader: View {
    let title: String
    var detail: String? = nil
    var accent: Color? = nil
    var identifier: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let accent {
                Capsule()
                    .fill(accent)
                    .frame(width: 4, height: 14)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(TriptychPalette.textSecondary)
                .modifier(OptionalAccessibilityID(id: identifier))
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TriptychPalette.textMuted)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct OptionalAccessibilityID: ViewModifier {
    let id: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

/// Compact status pill badge.
struct TriptychStatusPill: View {
    enum Tone {
        case good, warn, bad, neutral, custom(Color)

        var color: Color {
            switch self {
            case .good: return TriptychPalette.good
            case .warn: return TriptychPalette.warn
            case .bad: return TriptychPalette.bad
            case .neutral: return TriptychPalette.neutral
            case .custom(let c): return c
            }
        }
    }

    let text: String
    var tone: Tone = .neutral
    var symbol: String? = nil
    var identifier: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
            } else {
                Circle()
                    .fill(tone.color)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tone.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(tone.color.opacity(0.28), lineWidth: 0.75))
        .modifier(OptionalAccessibilityID(id: identifier))
    }
}

/// Primary gradient call-to-action button style.
struct TriptychPrimaryButtonStyle: ButtonStyle {
    var panel: TriptychPanel = .mac
    var enabled: Bool = true
    var height: CGFloat = 52

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(enabled ? TriptychPalette.textPrimary : TriptychPalette.textMuted)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                if enabled {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(panel.gradient)
                } else {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(TriptychPalette.surfaceRaised)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(enabled ? TriptychPalette.hinge.opacity(0.25) : TriptychPalette.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary button style on raised dark navy surface.
struct TriptychSecondaryButtonStyle: ButtonStyle {
    var accent: Color = TriptychPalette.macLight

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(TriptychPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accent.opacity(0.28), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Interactive press feedback for card links.
struct TriptychCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Compact fact tile (e.g. Disk, Last used, Memory).
struct TriptychFactTile: View {
    let title: String
    let value: String
    var accent: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TriptychPalette.textMuted)
            Text(value)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(TriptychPalette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .triptychCard(accent: accent, radius: 16)
    }
}

/// Progress bar using panel gradient fill.
struct TriptychProgressBar: View {
    let fraction: Double
    var panel: TriptychPanel = .mac
    var height: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(TriptychPalette.surfaceRaised)
                Capsule()
                    .fill(panel.gradient)
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Inline alert / notice banner card.
struct TriptychNoticeBanner: View {
    let symbol: String
    let text: String
    var trailing: String? = nil
    var tint: Color = TriptychPalette.macLight

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(TriptychPalette.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(14)
        .triptychCard(accent: tint, raised: true, radius: 16)
    }
}

/// Metallic hinge connector placed between the three hinged panels on Home.
struct TriptychHingeStrip: View {
    var body: some View {
        VStack(spacing: 14) {
            hingePin
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [TriptychPalette.hinge.opacity(0.15), TriptychPalette.hinge.opacity(0.65), TriptychPalette.hinge.opacity(0.15)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 2)
            hingePin
        }
        .frame(width: 10)
        .padding(.vertical, 22)
        .accessibilityHidden(true)
    }

    private var hingePin: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(TriptychPalette.hinge.opacity(0.85))
            .frame(width: 6, height: 14)
            .shadow(color: TriptychPalette.hinge.opacity(0.45), radius: 4)
    }
}
