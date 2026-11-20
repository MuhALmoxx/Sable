import SwiftUI

// OWNER: design agent. Pixel form controls: PixelToggleStyle / PixelToggle, PixelSegmented,
// PixelSlider, PixelTextFieldStyle / PixelTextField. See docs/DESIGN.md.

// MARK: - Toggle

/// Pixel switch row: label on the leading side, square-thumb switch on the trailing side.
/// The whole row (>= 44 pt) toggles. Use `.toggleStyle(.pixel)`.
struct PixelToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        PixelToggleRow(configuration: configuration)
    }
}

extension ToggleStyle where Self == PixelToggleStyle {
    static var pixel: PixelToggleStyle { PixelToggleStyle() }
}

private struct PixelToggleRow: View {
    let configuration: ToggleStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Spacing.sm) {
                configuration.label
                    .font(Typo.body)
                    .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PixelSwitch(isOn: configuration.isOn, isEnabled: isEnabled)
                    .pixelFocusRing(isFocused && isEnabled)
            }
            .frame(minHeight: Spacing.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The switch graphic on its own (decorative; the row carries the accessibility semantics).
struct PixelSwitch: View {
    let isOn: Bool
    var isEnabled: Bool = true

    init(isOn: Bool, isEnabled: Bool = true) {
        self.isOn = isOn
        self.isEnabled = isEnabled
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let trackSize = CGSize(width: 44, height: 24)
    static let thumb: CGFloat = 14

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            PixelRect()
                .fill(trackFill)
                .pixelBorder(trackBorder)
            Rectangle()
                .fill(thumbColor)
                .frame(width: PixelSwitch.thumb, height: PixelSwitch.thumb)
                .padding(.horizontal, (PixelSwitch.trackSize.height - PixelSwitch.thumb) / 2)
        }
        .frame(width: PixelSwitch.trackSize.width, height: PixelSwitch.trackSize.height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isOn)
        .accessibilityHidden(true)
    }

    private var trackFill: Color {
        guard isEnabled else { return .clear }
        return isOn ? Palette.accent : Palette.surfaceHigh
    }

    private var trackBorder: Color {
        guard isEnabled else { return Palette.border }
        return isOn ? Palette.accent : Palette.borderStrong
    }

    private var thumbColor: Color {
        guard isEnabled else { return Palette.textTertiary }
        return isOn ? Palette.onAccent : Palette.textSecondary
    }
}

/// Convenience toggle row with an optional secondary line.
struct PixelToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(Typo.callout).foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .toggleStyle(PixelToggleStyle())
    }
}

// MARK: - Segmented picker

/// Pixel segmented picker. The selected segment is the screen's active element: amber label on
/// `accentDim` with a 2-pt amber base line. Every segment is >= 44 pt tall.
struct PixelSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: String
    let title: (Value) -> String
    var identifier: ((Value) -> String)?

    /// - Parameters:
    ///   - label: accessibility label for the whole control ("Playback speed").
    ///   - title: visible text of each option (a trailing closure binds here).
    ///   - identifier: optional accessibility identifier per option (UI tests).
    init(_ label: String, selection: Binding<Value>, options: [Value],
         title: @escaping (Value) -> String, identifier: ((Value) -> String)? = nil) {
        self.label = label
        self._selection = selection
        self.options = options
        self.identifier = identifier
        self.title = title
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                segment(option)
                if index < options.count - 1 {
                    Rectangle()
                        .fill(Palette.border)
                        .frame(width: Spacing.line)
                        .padding(.vertical, Spacing.xs)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(Spacing.line)
        .pixelBorder(isEnabled ? Palette.borderStrong : Palette.border)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(_ option: Value) -> some View {
        let selected = option == selection
        let text = title(option)
        return Button {
            selection = option
        } label: {
            Text(text)
                .font(Typo.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(foreground(selected: selected))
                .padding(.horizontal, Spacing.xs)
                .frame(maxWidth: .infinity, minHeight: Spacing.touch - 2 * Spacing.line)
                .background(selected && isEnabled ? Palette.accentDim : Color.clear)
                .overlay(alignment: .bottom) {
                    if selected {
                        Rectangle().fill(isEnabled ? Palette.accent : Palette.textTertiary).frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier?(option) ?? "segment.\(text)")
    }

    private func foreground(selected: Bool) -> Color {
        guard isEnabled else { return Palette.textTertiary }
        return selected ? Palette.accent : Palette.textSecondary
    }
}

// MARK: - Slider

/// Stepped pixel slider: block track (amber up to the value) with a square thumb.
/// Snaps to `step` (pass 0 for continuous). VoiceOver: adjustable (swipe up/down by one step).
struct PixelSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    var valueText: ((Double) -> String)?
    var onEditingChanged: (Bool) -> Void

    init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double> = 0...1,
         step: Double = 0.1, valueText: ((Double) -> String)? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.valueText = valueText
        self.onEditingChanged = onEditingChanged
    }

    @State private var isDragging = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale

    static let thumbSize: CGFloat = 16
    static let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            sliderContent(size: geo.size)
        }
        .frame(height: Spacing.touch)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValueText)
        .accessibilityAdjustableAction { direction in
            adjust(direction)
        }
    }

    private var accessibilityValueText: String {
        if let valueText { return valueText(value) }
        return PixelSlider.defaultText(value)
    }

    private func sliderContent(size: CGSize) -> some View {
        let thumb = PixelSlider.thumbSize
        let usable = max(1, size.width - thumb)
        let fraction = PixelSlider.fraction(of: value, in: range)
        let thumbX = PixelSnap.round(CGFloat(fraction) * usable, scale: displayScale)
        let thumbY = PixelSnap.round((size.height - thumb) / 2, scale: displayScale)
        let trackY = PixelSnap.round((size.height - PixelSlider.trackHeight) / 2, scale: displayScale)
        return ZStack(alignment: .topLeading) {
            track(fraction: fraction)
                .frame(width: size.width, height: PixelSlider.trackHeight)
                .offset(y: trackY)
            thumbView
                .offset(x: thumbX, y: thumbY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(dragGesture(usable: usable))
    }

    private var thumbView: some View {
        Rectangle()
            .fill(thumbColor)
            .frame(width: PixelSlider.thumbSize, height: PixelSlider.thumbSize)
            .pixelBorder(Palette.background, step: 0)
    }

    private func dragGesture(usable: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled else { return }
                if !isDragging {
                    isDragging = true
                    onEditingChanged(true)
                }
                let raw = Double((gesture.location.x - PixelSlider.thumbSize / 2) / usable)
                setValue(PixelSlider.value(at: raw, in: range, step: step))
            }
            .onEnded { _ in
                guard isDragging else { return }
                isDragging = false
                onEditingChanged(false)
            }
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard isEnabled else { return }
        let delta = step > 0 ? step : (range.upperBound - range.lowerBound) / 20
        switch direction {
        case .increment: setValue(PixelSlider.snap(value + delta, in: range, step: step))
        case .decrement: setValue(PixelSlider.snap(value - delta, in: range, step: step))
        @unknown default: break
        }
    }

    private func track(fraction: Double) -> some View {
        let scale = displayScale
        let enabled = isEnabled
        let steps = PixelSlider.stepCount(range: range, step: step)
        let thumb = PixelSlider.thumbSize
        return Canvas { context, size in
            let filledX = thumb / 2 + CGFloat(fraction) * max(1, size.width - thumb)
            let count = (steps.map { $0 >= 2 && $0 <= 24 } ?? false) ? steps : nil
            for rect in PixelProgressBar.segments(width: size.width, height: size.height, scale: scale, count: count) {
                let on = rect.midX <= filledX
                let color: Color = enabled ? (on ? Palette.accent : Palette.borderStrong) : Palette.border
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    private var thumbColor: Color {
        guard isEnabled else { return Palette.textTertiary }
        return isDragging ? Palette.accent : Palette.textPrimary
    }

    private func setValue(_ newValue: Double) {
        if newValue != value { value = newValue }
    }

    /// Position of `value` in `range` as 0...1.
    static func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, value.isFinite else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    /// Clamps to `range` and rounds to the nearest `step` from the lower bound (step <= 0: no rounding).
    static func snap(_ value: Double, in range: ClosedRange<Double>, step: Double) -> Double {
        guard value.isFinite else { return range.lowerBound }
        var v = min(range.upperBound, max(range.lowerBound, value))
        if step > 0 {
            v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step
            v = min(range.upperBound, max(range.lowerBound, v))
        }
        return v
    }

    /// Value at a 0...1 position along the track, snapped.
    static func value(at fraction: Double, in range: ClosedRange<Double>, step: Double) -> Double {
        let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return snap(range.lowerBound + f * (range.upperBound - range.lowerBound), in: range, step: step)
    }

    /// Number of step intervals, or nil when continuous/unbounded.
    static func stepCount(range: ClosedRange<Double>, step: Double) -> Int? {
        let span = range.upperBound - range.lowerBound
        guard step > 0, span > 0 else { return nil }
        let n = (span / step).rounded()
        guard n.isFinite, n >= 1, n < 10_000 else { return nil }
        return Int(n)
    }

    static func defaultText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

// MARK: - Text field

/// Pixel text field chrome: dark inset surface, 1-pt boundary (`borderStrong`, amber when
/// focused, red when invalid), >= 44 pt tall. Typed text uses `Typo.reading` (Latin + Arabic).
/// A style cannot observe focus itself; pass `isFocused`, or use `PixelTextField`.
struct PixelTextFieldStyle: TextFieldStyle {
    var isFocused: Bool = false
    var isInvalid: Bool = false

    init(isFocused: Bool = false, isInvalid: Bool = false) {
        self.isFocused = isFocused
        self.isInvalid = isInvalid
    }

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(Typo.reading)
            .foregroundStyle(Palette.textPrimary)
            .tint(Palette.accent)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: Spacing.touch)
            .background { PixelRect().fill(Palette.surface) }
            .pixelBorder(isInvalid ? Palette.danger : (isFocused ? Palette.accent : Palette.borderStrong))
    }
}

/// Text (or secure) field with focus-aware pixel chrome and an optional helper/error line.
struct PixelTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String?
    var isSecure: Bool
    var isInvalid: Bool
    var message: String?

    init(_ title: String, text: Binding<String>, prompt: String? = nil, isSecure: Bool = false,
         isInvalid: Bool = false, message: String? = nil) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.isSecure = isSecure
        self.isInvalid = isInvalid
        self.message = message
    }

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            field
                .textFieldStyle(PixelTextFieldStyle(isFocused: isFocused, isInvalid: isInvalid))
                .focused($isFocused)
                .accessibilityLabel(title)
            if let message {
                Text(message)
                    .font(Typo.callout)
                    .foregroundStyle(isInvalid ? Palette.danger : Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var field: some View {
        let promptText: Text = Text(prompt ?? title).foregroundStyle(Palette.textTertiary)
        if isSecure {
            SecureField(title, text: $text, prompt: promptText)
        } else {
            TextField(title, text: $text, prompt: promptText)
        }
    }
}
