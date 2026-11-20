import SwiftUI

// OWNER: design agent. Layout primitives: PixelDivider, PixelListRow (+ PixelAccessory,
// PixelRowButtonStyle), AdaptiveText.

// MARK: - Divider

/// 1-pt rule on whole device pixels. `.dotted` draws 2-pt pixel dashes.
struct PixelDivider: View {
    enum Style { case solid, dotted }

    var color: Color
    var axis: Axis
    var style: Style
    var inset: CGFloat

    init(color: Color = Palette.border, axis: Axis = .horizontal, style: Style = .solid, inset: CGFloat = 0) {
        self.color = color
        self.axis = axis
        self.style = style
        self.inset = inset
    }

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let thickness = PixelSnap.lineWidth(Spacing.line, scale: displayScale)
        let scale = displayScale
        let color = self.color
        let axis = self.axis
        Group {
            switch style {
            case .solid:
                Rectangle().fill(color)
            case .dotted:
                Canvas { context, size in
                    let dash = PixelSnap.round(2, scale: scale)
                    let length = axis == .horizontal ? size.width : size.height
                    var position: CGFloat = 0
                    while position < length {
                        let run = min(dash, length - position)
                        let rect = axis == .horizontal
                            ? CGRect(x: position, y: 0, width: run, height: size.height)
                            : CGRect(x: 0, y: position, width: size.width, height: run)
                        context.fill(Path(rect), with: .color(color))
                        position += dash * 2
                    }
                }
            }
        }
        .frame(width: axis == .vertical ? thickness : nil, height: axis == .horizontal ? thickness : nil)
        .padding(axis == .horizontal ? .leading : .top, inset)
        .accessibilityHidden(true)
    }
}

// MARK: - Adaptive text

/// Text that switches to IBM Plex Sans Arabic, right-to-left lines (U+200F per line) and RTL
/// paragraph alignment when the string contains Arabic; otherwise uses `font`.
struct AdaptiveText: View {
    let text: String
    var font: Font
    var arabicFont: Font

    init(_ text: String, font: Font = Typo.body, arabicFont: Font = Typo.arabic) {
        self.text = text
        self.font = font
        self.arabicFont = arabicFont
    }

    var body: some View {
        if ArabicScript.containsArabic(text) {
            Text(ArabicScript.rtlLines(text))
                .font(arabicFont)
                .environment(\.layoutDirection, .rightToLeft)
        } else {
            Text(text).font(font)
        }
    }
}

// MARK: - List row

/// List row: optional leading glyph, title, optional subtitle, trailing accessory.
/// >= 44 pt (56 pt with a subtitle). Wrap in a `Button` with `PixelRowButtonStyle()` to make it
/// tappable. `isActive` marks the current choice (amber glyph + leading bar, `.isSelected`).
struct PixelListRow<Accessory: View>: View {
    let glyph: PixelGlyph?
    let title: String
    var subtitle: String?
    var isActive: Bool
    let accessory: Accessory

    init(glyph: PixelGlyph? = nil, title: String, subtitle: String? = nil, isActive: Bool = false,
         @ViewBuilder accessory: () -> Accessory) {
        self.glyph = glyph
        self.title = title
        self.subtitle = subtitle
        self.isActive = isActive
        self.accessory = accessory()
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if let glyph {
                PixelIcon(glyph, size: Spacing.icon, color: iconColor)
                    .frame(width: Spacing.lg)
            }
            VStack(alignment: .leading, spacing: 2) {
                AdaptiveText(title, font: Typo.body, arabicFont: Typo.arabic)
                    .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
                if let subtitle {
                    AdaptiveText(subtitle, font: Typo.callout, arabicFont: Typo.arabicSmall)
                        .foregroundStyle(isEnabled ? Palette.textSecondary : Palette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .frame(minHeight: subtitle == nil ? Spacing.touch : Spacing.rowTall)
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle().fill(Palette.accent).frame(width: 2).padding(.vertical, Spacing.xs)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var iconColor: Color {
        guard isEnabled else { return Palette.textTertiary }
        return isActive ? Palette.accent : Palette.textSecondary
    }
}

extension PixelListRow where Accessory == EmptyView {
    init(glyph: PixelGlyph? = nil, title: String, subtitle: String? = nil, isActive: Bool = false) {
        self.init(glyph: glyph, title: title, subtitle: subtitle, isActive: isActive) { EmptyView() }
    }
}

/// Standard trailing accessories for `PixelListRow`.
enum PixelAccessory: View {
    case chevron
    case check(Bool)
    case value(String)
    case valueChevron(String)
    case tag(String)

    var body: some View {
        switch self {
        case .chevron:
            PixelIcon(.chevronRight, size: Spacing.iconSmall, color: Palette.textTertiary)
        case .check(let on):
            PixelIcon(.check, size: Spacing.iconSmall, color: Palette.accent)
                .opacity(on ? 1 : 0)
        case .value(let text):
            Text(text).font(Typo.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
        case .valueChevron(let text):
            HStack(spacing: Spacing.xxs) {
                Text(text).font(Typo.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                PixelIcon(.chevronRight, size: Spacing.iconSmall, color: Palette.textTertiary)
            }
        case .tag(let text):
            PixelTag(text)
        }
    }
}

/// Pressed highlight for tappable rows (full-bleed `surfaceRaised`).
struct PixelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.surfaceRaised : Color.clear)
    }
}
