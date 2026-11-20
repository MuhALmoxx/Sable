import SwiftUI
import UIKit

// OWNER: design agent. Activity and transient feedback: PixelSpinner, PixelToast (+ presenter).

// MARK: - Spinner

/// Animated 3x3 pixel loader: a bright cell (with a two-cell trail) runs clockwise around the
/// ring. With Reduce Motion it shows a static pattern. Accessible as one "Loading" element.
struct PixelSpinner: View {
    var size: CGFloat
    var color: Color
    var label: String

    init(size: CGFloat = 18, color: Color = Palette.accent, label: String = "Loading") {
        self.size = size
        self.color = color
        self.label = label
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    /// Seconds per frame (8 frames per revolution).
    static let frameInterval: TimeInterval = 0.09

    var body: some View {
        Group {
            if reduceMotion {
                PixelSpinnerFrame(head: nil, color: color, scale: displayScale)
            } else {
                TimelineView(.periodic(from: .now, by: PixelSpinner.frameInterval)) { timeline in
                    let tick = Int(timeline.date.timeIntervalSinceReferenceDate / PixelSpinner.frameInterval)
                    PixelSpinnerFrame(head: tick % PixelSpinnerFrame.ring.count, color: color, scale: displayScale)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct PixelSpinnerFrame: View {
    /// Index into `ring` of the brightest cell; nil = static (Reduce Motion) pattern.
    let head: Int?
    let color: Color
    let scale: CGFloat

    /// Outer cells clockwise from the top-left corner, as (column, row).
    static let ring: [(Int, Int)] = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1)]

    /// Opacity of ring cell `index` for a given head position.
    static func opacity(index: Int, head: Int?) -> Double {
        guard let head else { return index % 2 == 0 ? 0.9 : 0.35 }
        switch (head - index + ring.count) % ring.count {
        case 0: return 1
        case 1: return 0.55
        case 2: return 0.3
        default: return 0.12
        }
    }

    var body: some View {
        Canvas { context, size in
            // 3 cells + 2 gaps with cell:gap = 2:1 -> 8 units; units are whole device pixels.
            let s = max(scale, 1)
            let unit = max(1, floor(min(size.width, size.height) * s / 8)) / s
            let cell = unit * 2
            let total = unit * 8
            let ox = PixelSnap.round((size.width - total) / 2, scale: s)
            let oy = PixelSnap.round((size.height - total) / 2, scale: s)
            for (i, pos) in PixelSpinnerFrame.ring.enumerated() {
                let rect = CGRect(x: ox + CGFloat(pos.0) * (cell + unit), y: oy + CGFloat(pos.1) * (cell + unit),
                                  width: cell, height: cell)
                context.fill(Path(rect), with: .color(color.opacity(PixelSpinnerFrame.opacity(index: i, head: head))))
            }
        }
    }
}

// MARK: - Toast

enum PixelToastKind: Equatable {
    case info, success, warning, error

    var glyph: PixelGlyph {
        switch self {
        case .info: return .info
        case .success: return .check
        case .warning, .error: return .warning
        }
    }

    var tint: Color {
        switch self {
        case .info: return Palette.textSecondary
        case .success: return Palette.success
        case .warning: return Palette.accent
        case .error: return Palette.danger
        }
    }

    var border: Color {
        switch self {
        case .info, .success: return Palette.border
        case .warning: return Palette.accent.opacity(0.5)
        case .error: return Palette.danger.opacity(0.6)
        }
    }
}

/// One transient message. Present with `.pixelToast($item)`.
struct PixelToastItem: Identifiable, Equatable {
    let id: UUID
    var kind: PixelToastKind
    var message: String
    var duration: TimeInterval
    var actionTitle: String?
    var action: (() -> Void)?

    init(_ message: String, kind: PixelToastKind = .info, duration: TimeInterval = 3,
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.id = UUID()
        self.kind = kind
        self.message = message
        self.duration = duration
        self.actionTitle = actionTitle
        self.action = action
    }

    static func == (lhs: PixelToastItem, rhs: PixelToastItem) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.message == rhs.message
    }
}

/// Banner: status glyph, message, optional action and a dismiss button.
struct PixelToast: View {
    let item: PixelToastItem
    var onDismiss: (() -> Void)?

    init(_ item: PixelToastItem, onDismiss: (() -> Void)? = nil) {
        self.item = item
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            PixelIcon(item.kind.glyph, size: Spacing.icon, color: item.kind.tint)
            AdaptiveText(item.message, font: Typo.callout, arabicFont: Typo.arabicSmall)
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let title = item.actionTitle, let action = item.action {
                Button(title) {
                    action()
                    onDismiss?()
                }
                .buttonStyle(PixelButtonStyle(kind: .ghost, compact: true))
            }
            if let onDismiss {
                PixelIconButton(.close, label: "Dismiss", size: 12, tint: Palette.textSecondary, action: onDismiss)
            }
        }
        .padding(.leading, Spacing.md)
        .padding(.trailing, onDismiss == nil ? Spacing.md : 0)
        .padding(.vertical, Spacing.xxs)
        .frame(minHeight: Spacing.touch + Spacing.xs)
        .pixelPanel(fill: Palette.surfaceHigh, border: item.kind.border)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Shows `item` as a banner at the bottom (or top) edge, announces it to VoiceOver and clears
    /// it after `item.duration` seconds (at least 6 s while VoiceOver runs). Setting a new item
    /// replaces the current one.
    func pixelToast(_ item: Binding<PixelToastItem?>, edge: VerticalEdge = .bottom) -> some View {
        modifier(PixelToastPresenter(item: item, edge: edge))
    }
}

private struct PixelToastPresenter: ViewModifier {
    @Binding var item: PixelToastItem?
    let edge: VerticalEdge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: overlayAlignment) {
                if let current = item {
                    toast(current)
                }
            }
            .animation(animation, value: item?.id)
    }

    private var overlayAlignment: Alignment { edge == .top ? .top : .bottom }
    private var insertionEdge: Edge { edge == .top ? .top : .bottom }
    private var paddingEdge: Edge.Set { edge == .top ? .top : .bottom }
    private var animation: Animation { reduceMotion ? .linear(duration: 0.1) : .easeOut(duration: 0.18) }

    private var transition: AnyTransition {
        reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: insertionEdge).combined(with: .opacity)
    }

    private func toast(_ current: PixelToastItem) -> some View {
        let id = current.id
        let message = current.message
        let duration = current.duration
        return PixelToast(current, onDismiss: { dismiss(id) })
            .padding(.horizontal, Spacing.md)
            .padding(paddingEdge, Spacing.md)
            .transition(transition)
            .id(id)
            .task(id: id) {
                await autoDismiss(id: id, message: message, duration: duration)
            }
    }

    private func autoDismiss(id: UUID, message: String, duration: TimeInterval) async {
        let voiceOver = await MainActor.run { () -> Bool in
            UIAccessibility.post(notification: .announcement, argument: message)
            return UIAccessibility.isVoiceOverRunning
        }
        let seconds = voiceOver ? max(duration, 6) : duration
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        await MainActor.run { dismiss(id) }
    }

    private func dismiss(_ id: UUID) {
        if item?.id == id { item = nil }
    }
}
