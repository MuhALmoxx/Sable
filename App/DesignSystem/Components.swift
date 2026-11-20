import SwiftUI

// OWNER: design agent. Component NAMES and initialisers are the contract; visuals may be refined.

/// Rectangle with stepped ("notched") pixel corners.
struct PixelRect: Shape {
    var step: CGFloat = Spacing.px

    func path(in rect: CGRect) -> Path {
        let s = min(step, rect.width / 4, rect.height / 4)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + s, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + s))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - s))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.maxY - s))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - s))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - s))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + s))
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.minY + s))
        p.closeSubpath()
        return p
    }
}

extension View {
    /// Pixel-cornered surface with a 1-art-pixel border.
    func pixelPanel(fill: Color = Palette.surfaceRaised, border: Color = Palette.border) -> some View {
        background(PixelRect().fill(fill))
            .overlay(PixelRect().stroke(border, lineWidth: 1))
    }
}

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

struct PixelButtonStyle: ButtonStyle {
    var kind: PixelButtonKind = .secondary
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(compact ? Typo.callout : Typo.bodyMedium)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? Spacing.sm : Spacing.md)
            .frame(minHeight: compact ? 36 : Spacing.touch)
            .background(PixelRect().fill(background(pressed: pressed)))
            .overlay(PixelRect().stroke(borderColor, lineWidth: kind == .ghost ? 0 : 1))
            .offset(y: pressed ? 1 : 0)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Palette.onAccent
        case .secondary, .ghost: return Palette.textPrimary
        case .destructive: return Palette.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? Palette.accent.opacity(0.8) : Palette.accent
        case .secondary: return pressed ? Palette.surfaceHigh : Palette.surfaceRaised
        case .ghost: return pressed ? Palette.surfaceRaised : .clear
        case .destructive: return pressed ? Palette.danger.opacity(0.2) : Palette.surfaceRaised
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: return Palette.accent
        case .secondary: return Palette.border
        case .ghost: return .clear
        case .destructive: return Palette.danger.opacity(0.5)
        }
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
            PixelIcon(glyph, size: size, color: isActive ? Palette.accent : tint)
                .frame(width: max(Spacing.touch, size + 16), height: max(Spacing.touch, size + 16))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Uppercase micro section label.
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    init(_ text: String, trailing: String? = nil) { self.text = text; self.trailing = trailing }

    var body: some View {
        HStack {
            Text(text.uppercased()).font(Typo.micro).tracking(1).foregroundStyle(Palette.textTertiary)
            Spacer()
            if let trailing { Text(trailing.uppercased()).font(Typo.micro).foregroundStyle(Palette.textTertiary) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Segmented pixel progress bar (0...1).
struct PixelProgressBar: View {
    var value: Double
    var height: CGFloat = 6
    var tint: Color = Palette.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.surfaceHigh)
                Rectangle().fill(tint)
                    .frame(width: (geo.size.width * min(1, max(0, value))).rounded(.down))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int((min(1, max(0, value)) * 100).rounded())) percent")
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
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .overlay(Rectangle().stroke(tint.opacity(0.6), lineWidth: 1))
    }
}

/// Standard sheet chrome: title row with close button, content below on black.
struct PixelSheet<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.title).foregroundStyle(Palette.textPrimary)
                    if let subtitle { Text(subtitle).font(Typo.callout).foregroundStyle(Palette.textSecondary) }
                }
                Spacer()
                PixelIconButton(.close, label: "Close", size: 16, action: onClose)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xs)
            Rectangle().fill(Palette.border).frame(height: 1)
            content()
        }
        .background(Palette.background.ignoresSafeArea())
    }
}

/// Empty/error state block.
struct PixelMessage: View {
    let glyph: PixelGlyph
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Spacing.sm) {
            PixelIcon(glyph, size: 36, color: Palette.textTertiary)
            Text(title).font(Typo.headline).foregroundStyle(Palette.textPrimary)
            Text(message).font(Typo.reading).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
        }
        .padding(Spacing.lg)
        .accessibilityElement(children: .combine)
    }
}
