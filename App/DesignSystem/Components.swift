import SwiftUI
import UIKit

// OWNER: design agent. Component NAMES and initialisers are the contract; visuals may be refined.
// Catalogue and usage rules: docs/DESIGN.md. More components: Controls.swift (toggle, segmented,
// slider, text field), Feedback.swift (spinner, toast), Layout.swift (divider, list row, adaptive
// text), PixelArt.swift (empty-state illustrations).

// MARK: - Shapes

/// Rectangle with stepped pixel corners: each corner is cut by two stairs of `step / 2` points
/// (a one-art-pixel "rounded" corner). `step: 0` gives a plain rectangle.
struct PixelRect: Shape {
    var step: CGFloat = Spacing.px

    func path(in rect: CGRect) -> Path {
        PixelRect.stairs(in: rect, unit: step / 2, count: step > 0 ? 2 : 0)
    }

    /// Rectangle whose four corners are cut by `count` stairs of `unit` points each.
    static func stairs(in rect: CGRect, unit: CGFloat, count: Int) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let n = max(0, count)
        let maxCut = min(rect.width, rect.height) / 4
        let u = n == 0 ? 0 : min(max(0, unit), maxCut / CGFloat(n))
        guard u > 0 else { return Path(rect) }
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        let cut = u * CGFloat(n)
        var p = Path()
        p.move(to: CGPoint(x: x0 + cut, y: y0))
        p.addLine(to: CGPoint(x: x1 - cut, y: y0))
        for i in 0..<n {
            let k = CGFloat(i)
            p.addLine(to: CGPoint(x: x1 - cut + k * u, y: y0 + (k + 1) * u))
            p.addLine(to: CGPoint(x: x1 - cut + (k + 1) * u, y: y0 + (k + 1) * u))
        }
        p.addLine(to: CGPoint(x: x1, y: y1 - cut))
        for i in 0..<n {
            let k = CGFloat(i)
            p.addLine(to: CGPoint(x: x1 - (k + 1) * u, y: y1 - cut + k * u))
            p.addLine(to: CGPoint(x: x1 - (k + 1) * u, y: y1 - cut + (k + 1) * u))
        }
        p.addLine(to: CGPoint(x: x0 + cut, y: y1))
        for i in 0..<n {
            let k = CGFloat(i)
            p.addLine(to: CGPoint(x: x0 + cut - k * u, y: y1 - (k + 1) * u))
            p.addLine(to: CGPoint(x: x0 + cut - (k + 1) * u, y: y1 - (k + 1) * u))
        }
        p.addLine(to: CGPoint(x: x0, y: y0 + cut))
        for i in 0..<n {
            let k = CGFloat(i)
            p.addLine(to: CGPoint(x: x0 + (k + 1) * u, y: y0 + cut - k * u))
            p.addLine(to: CGPoint(x: x0 + (k + 1) * u, y: y0 + cut - (k + 1) * u))
        }
        p.closeSubpath()
        return p
    }
}

/// The ring between a `PixelRect` and the same shape inset by `lineWidth`: a border drawn
/// entirely inside the frame, so a 1-pt border covers whole device pixels (a centred stroke
/// would straddle pixel boundaries and blur at @3x). Fill it with `FillStyle(eoFill: true)`,
/// or use `.pixelBorder(_:)`.
struct PixelBorderShape: Shape {
    var step: CGFloat = Spacing.px
    var lineWidth: CGFloat = Spacing.line

    func path(in rect: CGRect) -> Path {
        let n = step > 0 ? 2 : 0
        let u = step / 2
        var p = PixelRect.stairs(in: rect, unit: u, count: n)
        let w = max(0, lineWidth)
        let inner = rect.insetBy(dx: w, dy: w)
        guard w > 0, inner.width > 0, inner.height > 0 else { return p }
        let innerCount = u > 0 ? max(0, n - Int((w / u).rounded())) : 0
        p.addPath(PixelRect.stairs(in: inner, unit: u, count: innerCount))
        return p
    }
}

extension View {
    /// Pixel-cornered surface with a crisp 1-pt border drawn inside the frame.
    func pixelPanel(fill: Color = Palette.surfaceRaised, border: Color = Palette.border) -> some View {
        background { PixelRect().fill(fill) }
            .pixelBorder(border)
    }

    /// Crisp inside border with stepped corners (`step: 0` for square corners).
    func pixelBorder(_ color: Color = Palette.border, lineWidth: CGFloat = Spacing.line,
                     step: CGFloat = Spacing.px) -> some View {
        overlay {
            PixelBorderShape(step: step, lineWidth: lineWidth)
                .fill(color, style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
        }
    }

    /// Accent focus ring drawn just outside the view when `isFocused` (keyboard / Switch Control).
    func pixelFocusRing(_ isFocused: Bool, outset: CGFloat = 3) -> some View {
        overlay {
            if isFocused {
                PixelBorderShape(step: Spacing.px * 2, lineWidth: 2)
                    .fill(Palette.focus, style: FillStyle(eoFill: true))
                    .padding(-outset)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Buttons

enum PixelButtonKind {
    /// Accent fill — at most one per screen.
    case primary
    /// Raised surface with border.
    case secondary
    /// Text/icon only.
    case ghost
    /// Destructive actions.
    case destructive
}

/// Pixel button. States: pressed (darker fill, label sinks 1 pt), focused (amber ring),
/// disabled (textTertiary label, no fill). `compact` draws a 36-pt tall button but keeps a
/// 44-pt hit area.
struct PixelButtonStyle: ButtonStyle {
    var kind: PixelButtonKind = .secondary
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        PixelButtonChrome(label: configuration.label, isPressed: configuration.isPressed,
                          kind: kind, compact: compact)
    }
}

private struct PixelButtonChrome<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let kind: PixelButtonKind
    let compact: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let pressed = isPressed && isEnabled
        let visualHeight: CGFloat = compact ? 36 : Spacing.touch
        label
            .font(compact ? Typo.callout : Typo.bodyMedium)
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .padding(.horizontal, compact ? Spacing.sm : Spacing.md)
            .padding(.vertical, Spacing.xxs)
            .frame(minHeight: visualHeight)
            .background { PixelRect().fill(fill(pressed: pressed)) }
            .pixelBorder(border(pressed: pressed))
            .offset(y: pressed ? 1 : 0)
            .pixelFocusRing(isFocused && isEnabled)
            .padding(.vertical, (Spacing.touch - visualHeight) / 2)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        guard isEnabled else { return Palette.textTertiary }
        switch kind {
        case .primary: return Palette.onAccent
        case .secondary, .ghost: return Palette.textPrimary
        case .destructive: return Palette.danger
        }
    }

    private func fill(pressed: Bool) -> Color {
        guard isEnabled else { return .clear }
        switch kind {
        case .primary: return pressed ? Palette.accentPressed : Palette.accent
        case .secondary: return pressed ? Palette.surfaceHigh : Palette.surfaceRaised
        case .ghost: return pressed ? Palette.surfaceRaised : .clear
        case .destructive: return pressed ? Palette.dangerDim : Palette.surfaceRaised
        }
    }

    private func border(pressed: Bool) -> Color {
        guard isEnabled else { return kind == .ghost ? .clear : Palette.border }
        switch kind {
        case .primary: return pressed ? Palette.accentPressed : Palette.accent
        case .secondary: return pressed ? Palette.borderStrong : Palette.border
        case .ghost: return .clear
        case .destructive: return Palette.danger.opacity(0.6)
        }
    }
}

/// Style behind `PixelIconButton`, usable on any icon-only `Button`.
struct PixelIconButtonStyle: ButtonStyle {
    var size: CGFloat = 22
    var tint: Color = Palette.textPrimary
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        PixelIconButtonChrome(label: configuration.label, isPressed: configuration.isPressed,
                              size: size, tint: tint, isActive: isActive)
    }
}

private struct PixelIconButtonChrome<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let size: CGFloat
    let tint: Color
    let isActive: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let side = max(Spacing.touch, size + 16)
        label
            .foregroundStyle(color)
            .frame(width: side, height: side)
            .background {
                if isPressed && isEnabled {
                    PixelRect().fill(Palette.surfaceHigh).padding(Spacing.xxs)
                }
            }
            .pixelFocusRing(isFocused && isEnabled, outset: -2)
            .contentShape(Rectangle())
    }

    private var color: Color {
        guard isEnabled else { return Palette.textTertiary }
        return isActive ? Palette.accent : tint
    }
}

/// Square icon-only button with an accessible label and a 44-pt hit area.
struct PixelIconButton: View {
    let glyph: PixelGlyph
    let label: String
    var size: CGFloat = 22
    var tint: Color = Palette.textPrimary
    var isActive: Bool = false
    let action: () -> Void

    init(_ glyph: PixelGlyph, label: String, size: CGFloat = 22, tint: Color = Palette.textPrimary,
         isActive: Bool = false, action: @escaping () -> Void) {
        self.glyph = glyph; self.label = label; self.size = size; self.tint = tint
        self.isActive = isActive; self.action = action
    }

    var body: some View {
        Button(action: action) {
            PixelIcon(glyph, size: size)
        }
        .buttonStyle(PixelIconButtonStyle(size: size, tint: tint, isActive: isActive))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Labels and indicators

/// Uppercase micro section label.
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    init(_ text: String, trailing: String? = nil) { self.text = text; self.trailing = trailing }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased()).font(Typo.micro).tracking(1).foregroundStyle(Palette.textTertiary)
            Spacer(minLength: Spacing.xs)
            if let trailing {
                Text(trailing.uppercased()).font(Typo.micro).tracking(1).foregroundStyle(Palette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Segmented pixel progress bar (0...1): square-ish blocks on whole device pixels; the block
/// that is partly done is drawn at half strength.
struct PixelProgressBar: View {
    var value: Double
    var height: CGFloat = 6
    var tint: Color = Palette.accent

    init(value: Double, height: CGFloat = 6, tint: Color = Palette.accent) {
        self.value = value; self.height = height; self.tint = tint
    }

    @Environment(\.displayScale) var displayScale

    var body: some View {
        let fraction = PixelProgressBar.clamp(value)
        let scale = displayScale
        let tint = self.tint
        Canvas { context, size in
            let filled = size.width * fraction
            for segment in PixelProgressBar.segments(width: size.width, height: size.height, scale: scale) {
                let color: Color
                if segment.maxX <= filled + 0.01 {
                    color = tint
                } else if segment.minX < filled {
                    color = tint.opacity(0.45)
                } else {
                    color = Palette.border
                }
                context.fill(Path(segment), with: .color(color))
            }
        }
        .frame(height: PixelSnap.round(height, scale: scale))
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// Block rects for a bar of `width` x `height` points, edges on whole device pixels.
    /// `count` forces the number of blocks (e.g. one per slider step); by default blocks are
    /// roughly square.
    static func segments(width: CGFloat, height: CGFloat, scale: CGFloat, count: Int? = nil) -> [CGRect] {
        guard width > 0, height > 0 else { return [] }
        let gap = PixelSnap.lineWidth(max(1, (height / 3).rounded()), scale: scale)
        let target = max(4, height)
        let fitted = max(1, Int(((width + gap) / (target + gap)).rounded(.down)))
        let count = max(1, min(count ?? fitted, Int(width / 2)))
        let pitch = (width + gap) / CGFloat(count)
        return (0..<count).map { i in
            let x0 = PixelSnap.round(CGFloat(i) * pitch, scale: scale)
            let x1 = i == count - 1 ? width : PixelSnap.round(CGFloat(i + 1) * pitch - gap, scale: scale)
            return CGRect(x: x0, y: 0, width: max(0, x1 - x0), height: height)
        }
    }
}

/// Small rectangular tag ("MKV", "PGS · IMAGE", "AR").
struct PixelTag: View {
    let text: String
    var tint: Color = Palette.textSecondary

    init(_ text: String, tint: Color = Palette.textSecondary) { self.text = text; self.tint = tint }

    var body: some View {
        Text(text.uppercased())
            .font(Typo.micro)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .pixelBorder(tint.opacity(0.6), step: 0)
    }
}

// MARK: - Containers

/// Standard sheet chrome: title row with close button, content below on black.
struct PixelSheet<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    init(title: String, subtitle: String? = nil, onClose: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.onClose = onClose; self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.title).foregroundStyle(Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        AdaptiveText(subtitle, font: Typo.callout, arabicFont: Typo.arabicSmall)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer(minLength: Spacing.xs)
                PixelIconButton(.close, label: "Close", size: Spacing.iconSmall, action: onClose)
            }
            .padding(.leading, Spacing.md)
            .padding(.trailing, Spacing.xxs)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xxs)
            PixelDivider()
            content()
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Palette.background.ignoresSafeArea())
    }
}

/// Empty/error state block. Pass `actionTitle` + `action` for a single primary way out.
struct PixelMessage: View {
    let glyph: PixelGlyph
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    init(glyph: PixelGlyph, title: String, message: String, actionTitle: String? = nil,
         action: (() -> Void)? = nil) {
        self.glyph = glyph; self.title = title; self.message = message
        self.actionTitle = actionTitle; self.action = action
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            VStack(spacing: Spacing.sm) {
                PixelIcon(glyph, size: 36, color: Palette.textTertiary)
                    .padding(.bottom, Spacing.xxs)
                Text(title).font(Typo.headline).foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
                AdaptiveText(message, font: Typo.reading, arabicFont: Typo.arabicSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PixelButtonStyle(kind: .primary))
                    .padding(.top, Spacing.xs)
            }
        }
        .padding(Spacing.lg)
    }
}
