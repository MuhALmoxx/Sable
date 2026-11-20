import SwiftUI

// OWNER: library agent. Small settings controls built from design-system tokens. Named
// "Settings…" so they never clash with components the design system may add later.

/// Screen title bar with a pixel back button (the system navigation bar is hidden).
struct SettingsScreenHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xxs) {
                PixelIconButton(.back, label: "Back", size: 18, action: onBack)
                    .accessibilityIdentifier(AX.Settings.back)
                Text(title)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, Spacing.xxs)
            .padding(.vertical, Spacing.xxs)
            Rectangle().fill(Palette.border).frame(height: 1)
        }
        .background(Palette.background)
    }
}

/// Section: micro label above a bordered panel of rows, optional footer below.
struct SettingsGroup<Content: View>: View {
    let title: String
    let footer: String?
    let content: () -> Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pixelPanel(fill: Palette.surface)
            if let footer {
                Text(footer)
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 1-px separator between rows of a group.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Palette.border).frame(height: 1)
    }
}

/// Title + optional explanation + a control underneath.
struct SettingsItem<Control: View>: View {
    let title: String
    let detail: String?
    let control: () -> Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(Typo.bodyMedium)
                .foregroundStyle(Palette.textPrimary)
            if let detail {
                Text(detail)
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control()
                .padding(.top, Spacing.xxs)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label/value line (About, Storage).
struct SettingsValueRow: View {
    let title: String
    let value: String
    var axID: String? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                titleText
                Spacer(minLength: Spacing.sm)
                valueText.multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                titleText
                valueText
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: Spacing.touch, alignment: .leading)
        .accessibilityElement(children: .combine)
        .modifier(OptionalIdentifier(id: axID))
    }

    private var titleText: some View {
        Text(title).font(Typo.body).foregroundStyle(Palette.textPrimary)
    }

    private var valueText: some View {
        Text(value).font(Typo.reading).foregroundStyle(Palette.textSecondary)
    }
}

struct OptionalIdentifier: ViewModifier {
    let id: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

/// Pixel on/off switch row. The whole row toggles; VoiceOver reads it as a switch.
struct SettingsToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    let axID: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .font(Typo.bodyMedium)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(Typo.reading)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsSwitch(isOn: isOn)
            }
            .padding(Spacing.md)
            .frame(minHeight: Spacing.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(detail ?? "")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier(axID)
    }
}

/// The switch graphic: a stepped track with a square knob; amber when on.
struct SettingsSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            PixelRect(step: Spacing.px)
                .fill(isOn ? Palette.accent : Palette.surfaceHigh)
            PixelRect(step: Spacing.px)
                .stroke(isOn ? Palette.accent : Palette.borderStrong, lineWidth: 1)
            Rectangle()
                .fill(isOn ? Palette.onAccent : Palette.textSecondary)
                .frame(width: 16, height: 16)
                .padding(5)
        }
        .frame(width: 48, height: 26)
        .animation(.easeOut(duration: 0.12), value: isOn)
        .accessibilityHidden(true)
    }
}

/// Segmented choice. The selected segment uses the dim accent fill and amber text.
struct SettingsSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var accessibilityLabelFor: ((Value) -> String)? = nil
    let axID: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(Typo.callout)
                        .foregroundStyle(selected ? Palette.accent : Palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, Spacing.xxs)
                        .frame(maxWidth: .infinity, minHeight: Spacing.touch)
                        .background(selected ? Palette.accentDim : Palette.surfaceRaised)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .leading) {
                    if index > 0 { Rectangle().fill(Palette.border).frame(width: 1) }
                }
                .accessibilityLabel(accessibilityLabelFor?(option) ?? label(option))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("\(axID).\(label(option))")
            }
        }
        .overlay(Rectangle().stroke(selectionBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(axID)
    }

    private var selectionBorder: Color { Palette.border }
}

/// "−  value  +" stepper; VoiceOver adjusts it with swipe up/down.
struct SettingsStepper: View {
    let valueText: String
    let accessibilityLabel: String
    let canDecrement: Bool
    let canIncrement: Bool
    let decrement: () -> Void
    let increment: () -> Void
    let axID: String

    var body: some View {
        HStack(spacing: 0) {
            stepButton(.minus, label: "Decrease", enabled: canDecrement, action: decrement)
            Rectangle().fill(Palette.border).frame(width: 1)
            Text(valueText)
                .font(Typo.bodyMedium)
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .frame(minWidth: 76, minHeight: Spacing.touch)
                .padding(.horizontal, Spacing.xs)
            Rectangle().fill(Palette.border).frame(width: 1)
            stepButton(.plus, label: "Increase", enabled: canIncrement, action: increment)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.surfaceRaised)
        .overlay(Rectangle().stroke(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if canIncrement { increment() }
            case .decrement: if canDecrement { decrement() }
            @unknown default: break
            }
        }
        .accessibilityIdentifier(axID)
    }

    private func stepButton(_ glyph: PixelGlyph, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PixelIcon(glyph, size: 14, color: enabled ? Palette.textPrimary : Palette.textTertiary.opacity(0.5))
                .frame(width: Spacing.touch, height: Spacing.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
