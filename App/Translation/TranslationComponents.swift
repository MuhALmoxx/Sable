import SwiftUI

// OWNER: translation agent. Small building blocks shared by the Translate sheet and settings.

/// Selectable row (radio-style) with title, optional tags and explanation.
struct TranslationChoiceRow: View {
    let title: String
    var nativeTitle: String? = nil
    var detail: String? = nil
    var tags: [String] = []
    let isSelected: Bool
    var isEnabled: Bool = true
    var accessibilityID: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Rectangle()
                    .fill(isSelected ? Palette.accent : Color.clear)
                    .frame(width: 12, height: 12)
                    .overlay(Rectangle().stroke(isSelected ? Palette.accent : Palette.borderStrong, lineWidth: 1))
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Text(title)
                            .font(Typo.bodyMedium)
                            .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
                        if let nativeTitle {
                            Text(nativeTitle)
                                .font(Typo.arabic)
                                .foregroundStyle(isEnabled ? Palette.textSecondary : Palette.textTertiary)
                        }
                    }
                    if !tags.isEmpty {
                        HStack(spacing: Spacing.xxs) {
                            ForEach(tags, id: \.self) { PixelTag($0, tint: isEnabled ? Palette.textSecondary : Palette.textTertiary) }
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(Typo.reading)
                            .foregroundStyle(isEnabled ? Palette.textSecondary : Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: Spacing.touch, alignment: .leading)
            .pixelPanel(fill: isSelected ? Palette.surfaceHigh : Palette.surfaceRaised,
                        border: isSelected ? Palette.accent : Palette.border)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title] + tags + [detail].compactMap { $0 }).joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier(accessibilityID ?? "")
    }
}

/// Pixel checkbox row (Toggle semantics) with a 44-pt hit area.
struct PixelCheckRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var accessibilityID: String = ""

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: Spacing.sm) {
                ZStack {
                    Rectangle().stroke(isOn ? Palette.accent : Palette.borderStrong, lineWidth: 1)
                    if isOn { PixelIcon(.check, size: 14, color: Palette.accent) }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.body).foregroundStyle(Palette.textPrimary)
                    if let detail {
                        Text(detail).font(Typo.reading).foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.touch, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(detail ?? "")
        .accessibilityIdentifier(accessibilityID)
    }
}

/// Error/notice banner with a glyph, a message and optional actions.
struct TranslationBanner<Actions: View>: View {
    let glyph: PixelGlyph
    let message: String
    var tint: Color = Palette.danger
    var accessibilityID: String = ""
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                PixelIcon(glyph, size: 18, color: tint)
                Text(message)
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(accessibilityID)
                Spacer(minLength: 0)
            }
            actions()
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelPanel(fill: Palette.surface, border: tint.opacity(0.6))
    }
}

/// Arabic lines rendered right-to-left with IBM Plex Sans Arabic.
struct ArabicPreview: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(Self.rtl(line))
                    .font(Typo.arabic)
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelPanel(fill: Palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AX.Translation.preview)
    }

    /// Prefixes every line with RIGHT-TO-LEFT MARK so punctuation lands on the correct side.
    static func rtl(_ text: String) -> String {
        text.components(separatedBy: "\n").map { "\u{200F}" + $0 }.joined(separator: "\n")
    }
}

/// "Label ........ value" line for estimates.
struct TranslationFactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Typo.callout).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Spacing.sm)
            Text(value).font(Typo.mono).foregroundStyle(Palette.textPrimary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
