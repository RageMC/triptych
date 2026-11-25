// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Size the guest against the window that contains it, including in a resizable iPad scene.
struct GuestDisplaySize: Equatable {
    var width: Int
    var height: Int

    init(_ points: CGSize, scale: CGFloat, longestEdge: CGFloat = 1600, minimumShortEdge: CGFloat = 0) {
        let longest = max(points.width, points.height)
        let shortest = min(points.width, points.height)
        guard shortest > 0 else {
            width = 1024
            height = 768
            return
        }

        let factor = min(max(scale, minimumShortEdge / shortest), longestEdge / longest)
        width = max(2, Int((points.width * factor / 2).rounded()) * 2)
        height = max(2, Int((points.height * factor / 2).rounded()) * 2)
    }
}

struct SystemWindowMetrics: Equatable {
    let size: CGSize
    let scale: CGFloat

    func guestSize(longestEdge: CGFloat = 1600, minimumShortEdge: CGFloat = 0) -> GuestDisplaySize {
        GuestDisplaySize(size, scale: scale, longestEdge: longestEdge, minimumShortEdge: minimumShortEdge)
    }
}

/// The underlying UIKit window size includes the safe area and is stable when the keyboard appears.
struct SystemWindowReader: UIViewRepresentable {
    let update: (SystemWindowMetrics) -> Void

    func makeUIView(context: Context) -> Reader {
        let view = Reader()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Reader, context: Context) {
        view.update = update
        view.report()
    }

    final class Reader: UIView {
        var update: ((SystemWindowMetrics) -> Void)?
        private var previous: SystemWindowMetrics?

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        func report() {
            guard let window, !window.bounds.isEmpty else { return }
            let metrics = SystemWindowMetrics(size: window.bounds.size, scale: window.traitCollection.displayScale)
            guard metrics != previous else { return }
            previous = metrics
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.previous == metrics else { return }
                self.update?(metrics)
            }
        }
    }
}

/// Overlay controls stay inside the safe area while the guest display fills the window.
struct SystemDisplay<Content: View, Controls: View, Bottom: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let bottom: () -> Bottom

    @State private var expanded = true
    @State private var activity = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            ViewThatFits(in: .horizontal) {
                controlRow
                ScrollView(.horizontal) { controlRow }.scrollIndicators(.hidden)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .overlay(alignment: .bottom) { bottom() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task(id: activity) {
            guard expanded, !voiceOver else { return }
            do {
                try await Task.sleep(for: .seconds(8))
            } catch { return }
            expanded = false
        }
        .onReceive(NotificationCenter.default.publisher(for: Trackpad.revealTap)) { _ in
            expanded = true
            activity += 1
        }
        .onChange(of: voiceOver) { _, enabled in
            if enabled { expanded = true }
            activity += 1
        }
    }

    private var controlRow: some View {
        HStack(spacing: 12) {
            if expanded {
                controls()
                ExportLogsButton(compact: true)
            }
            Button {
                expanded.toggle()
                activity += 1
            } label: {
                Image(systemName: expanded ? "chevron.right" : "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(expanded ? "Hide session controls" : "Show session controls")
            .accessibilityIdentifier("session-controls")
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .padding(.leading, expanded ? 12 : 0)
        .background(.black.opacity(0.8), in: Capsule())
        .simultaneousGesture(TapGesture().onEnded { activity += 1 })
    }
}

extension SystemDisplay where Bottom == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder controls: @escaping () -> Controls) {
        self.init(content: content, controls: controls, bottom: { EmptyView() })
    }
}

struct SessionBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .frame(minWidth: 32, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Back")
        .accessibilityIdentifier("session-back")
    }
}
