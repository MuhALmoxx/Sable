import SwiftUI
import SubtitleKit
import LibraryKit

// OWNER: playback agent. Draws the session's visible cues over the video picture.
//
// - Size scales with the displayed picture height (and the user's subtitle size), so subtitles
//   look the same in portrait, landscape and every aspect mode.
// - Readable over any picture: outline (stacked hard shadows), shadow (soft + thin outline) or a
//   solid box behind the text.
// - Arabic / RTL: IBM Plex Sans Arabic, each line prefixed with U+200F, right-to-left layout
//   direction, centred, never italic or pixel type.

struct SubtitleOverlay: View {
    let session: PlayerSession
    /// Height at the bottom of this view covered by player controls; subtitles move above it.
    var reservedBottom: CGFloat = 0

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let picture = visiblePicture(in: bounds)
            let style = session.subtitleStyle
            let fontSize = SubtitleMetrics.fontSize(pictureHeight: picture.height, scale: style.scale,
                                                    dynamicType: dynamicTypeSize)
            let groups = SubtitleGroups(cues: session.visibleCues)
            let bottomPadding = max(picture.height * style.bottomMargin,
                                    picture.maxY - (bounds.height - reservedBottom) + Spacing.xs, 4)

            VStack(spacing: 0) {
                if !groups.top.isEmpty {
                    SubtitleBlock(cues: groups.top, style: style, fontSize: fontSize,
                                  identifier: groups.primary == .top ? AX.Player.subtitleText : nil)
                }
                Spacer(minLength: 0)
                if !groups.middle.isEmpty {
                    SubtitleBlock(cues: groups.middle, style: style, fontSize: fontSize,
                                  identifier: groups.primary == .middle ? AX.Player.subtitleText : nil)
                }
                Spacer(minLength: 0)
                if !groups.bottom.isEmpty {
                    SubtitleBlock(cues: groups.bottom, style: style, fontSize: fontSize,
                                  identifier: groups.primary == .bottom ? AX.Player.subtitleText : nil)
                }
            }
            .padding(.top, max(picture.height * 0.05, 4))
            .padding(.bottom, bottomPadding)
            .padding(.horizontal, max(picture.width * 0.05, Spacing.xs))
            .frame(width: max(picture.width, 1), height: max(picture.height, 1))
            .position(x: picture.midX, y: picture.midY)
            .animation(nil, value: session.visibleCues)
        }
        .allowsHitTesting(false)
    }

    /// The part of the picture that is on screen (Fill extends past the view).
    private func visiblePicture(in bounds: CGRect) -> CGRect {
        let picture = VideoGeometry.pictureRect(videoSize: session.videoSize, mode: session.aspectMode, in: bounds)
        let visible = picture.intersection(bounds)
        return visible.isNull || visible.isEmpty ? bounds : visible
    }
}

enum SubtitleMetrics {
    /// ~5.8 % of the picture height, clamped, times the user's size and a capped Dynamic Type factor.
    static func fontSize(pictureHeight: CGFloat, scale: Double, dynamicType: DynamicTypeSize) -> CGFloat {
        let base = min(max(pictureHeight * 0.058, 14), 46)
        let clampedScale = min(max(scale, 0.6), 2.0)
        return (base * CGFloat(clampedScale) * dynamicTypeFactor(dynamicType)).rounded()
    }

    static func dynamicTypeFactor(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall, .small, .medium, .large: return 1
        case .xLarge: return 1.06
        case .xxLarge: return 1.12
        case .xxxLarge: return 1.18
        default: return 1.3 // accessibility sizes
        }
    }
}

/// Cues split by vertical position (ASS numpad alignment: 7-9 top, 4-6 middle, else bottom).
struct SubtitleGroups {
    enum Position { case top, middle, bottom }
    var top: [DisplayCue] = []
    var middle: [DisplayCue] = []
    var bottom: [DisplayCue] = []

    init(cues: [DisplayCue]) {
        for cue in cues {
            switch cue.style?.alignment ?? 2 {
            case 7, 8, 9: top.append(cue)
            case 4, 5, 6: middle.append(cue)
            default: bottom.append(cue)
            }
        }
    }

    /// The group that carries the accessibility identifier (bottom first: dialogue).
    var primary: Position? {
        if !bottom.isEmpty { return .bottom }
        if !top.isEmpty { return .top }
        if !middle.isEmpty { return .middle }
        return nil
    }
}

/// One group of simultaneous cues drawn as a single text element.
struct SubtitleBlock: View {
    let cues: [DisplayCue]
    let style: SubtitleStyle
    let fontSize: CGFloat
    let identifier: String?

    var body: some View {
        let isRTL = cues.contains { $0.isRightToLeft }
        let text = Text(SubtitleMarkup.attributedText(for: cues, fontSize: fontSize, fontChoice: style.font))
            .multilineTextAlignment(.center)
            .lineSpacing(fontSize * 0.08)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)

        styled(text)
            .frame(maxWidth: .infinity, alignment: horizontalAlignment)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cues.map { SubtitleMarkup.plain($0.text) }.joined(separator: "\n"))
            .accessibilityAddTraits(.isStaticText)
            .modifier(OptionalIdentifier(identifier: identifier))
    }

    @ViewBuilder
    private func styled(_ text: some View) -> some View {
        let unit = max(1, (fontSize / 16).rounded())
        switch style.background {
        case .outline:
            text
                .shadow(color: .black, radius: 0, x: unit, y: unit)
                .shadow(color: .black, radius: 0, x: -unit, y: -unit)
                .shadow(color: .black, radius: 0, x: unit, y: -unit)
                .shadow(color: .black, radius: 0, x: -unit, y: unit)
                .shadow(color: .black.opacity(0.55), radius: unit * 2)
        case .shadow:
            text
                .shadow(color: .black.opacity(0.9), radius: 0, x: unit * 0.5, y: unit * 0.5)
                .shadow(color: .black.opacity(0.85), radius: unit * 1.5, x: 0, y: unit)
                .shadow(color: .black.opacity(0.7), radius: unit * 4)
        case .box:
            text
                .padding(.horizontal, fontSize * 0.45)
                .padding(.vertical, fontSize * 0.18)
                .background(Rectangle().fill(Color.black.opacity(0.8)))
        }
    }

    private var horizontalAlignment: Alignment {
        // RTL lines stay centred; Latin lines honour left/right alignment hints.
        guard !cues.contains(where: \.isRightToLeft), let alignment = cues.first?.style?.alignment else { return .center }
        switch alignment {
        case 1, 4, 7: return .leading
        case 3, 6, 9: return .trailing
        default: return .center
        }
    }
}

private struct OptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// Inline <i>/<b>/<u> markup -> AttributedString with Sable's subtitle fonts.
enum SubtitleMarkup {
    static let primaryColor = Palette.textPrimary
    static let originalColor = Palette.textPrimary.opacity(0.82)

    static func attributedText(for cues: [DisplayCue], fontSize: CGFloat, fontChoice: SubtitleFontChoice) -> AttributedString {
        var result = AttributedString()
        for (index, cue) in cues.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            result.append(attributed(cue.text, size: fontSize, fontChoice: fontChoice,
                                     forceRTL: cue.isRightToLeft, color: primaryColor))
            if let original = cue.originalText, !plain(original).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(AttributedString("\n"))
                result.append(attributed(original, size: (fontSize * 0.72).rounded(), fontChoice: fontChoice,
                                         forceRTL: false, color: originalColor))
            }
        }
        return result
    }

    /// Builds one cue's text: lines with Arabic/Hebrew get U+200F and Plex Sans Arabic.
    static func attributed(_ text: String, size: CGFloat, fontChoice: SubtitleFontChoice,
                           forceRTL: Bool, color: Color) -> AttributedString {
        var result = AttributedString()
        var bold = false
        var italic = false
        var underline = false
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 { result.append(AttributedString("\n")) }
            let lineRTL = forceRTL || TextDirection.containsRightToLeft(line)
            if lineRTL, !line.hasPrefix("\u{200F}") {
                result.append(run("\u{200F}", size: size, fontChoice: fontChoice, rtl: true,
                                  bold: false, italic: false, underline: false, color: color))
            }
            for token in tokens(in: line) {
                switch token {
                case let .tag(name, closing):
                    switch name {
                    case "b": bold = !closing
                    case "i": italic = !closing
                    case "u": underline = !closing
                    default: break
                    }
                case let .text(segment):
                    result.append(run(segment, size: size, fontChoice: fontChoice, rtl: lineRTL,
                                      bold: bold, italic: italic, underline: underline, color: color))
                }
            }
        }
        return result
    }

    private static func run(_ string: String, size: CGFloat, fontChoice: SubtitleFontChoice, rtl: Bool,
                            bold: Bool, italic: Bool, underline: Bool, color: Color) -> AttributedString {
        var run = AttributedString(string)
        run.font = font(size: size, choice: fontChoice, rtl: rtl, bold: bold, italic: italic)
        run.foregroundColor = color
        if underline { run.underlineStyle = Text.LineStyle.single }
        return run
    }

    static func font(size: CGFloat, choice: SubtitleFontChoice, rtl: Bool, bold: Bool, italic: Bool) -> Font {
        if rtl {
            // Arabic: always Plex Sans Arabic, never italic, never pixel type.
            return Font.custom(bold ? SableFonts.arabicBold : SableFonts.arabicSemiBold, fixedSize: size)
        }
        if italic {
            // Plex Sans Arabic and the pixel faces have no italics; SF does.
            return Font.system(size: size, weight: bold ? .bold : .semibold).italic()
        }
        switch choice {
        case .plex: return Font.custom(bold ? SableFonts.arabicBold : SableFonts.arabicSemiBold, fixedSize: size)
        case .system: return Font.system(size: size, weight: bold ? .bold : .semibold)
        case .pixel: return Font.custom(bold ? SableFonts.pixelBold : SableFonts.pixelSemiBold, fixedSize: size)
        }
    }

    enum Token: Equatable {
        case text(String)
        case tag(String, closing: Bool)
    }

    /// Splits "<i>Is it</i> safe?" into text and b/i/u tag tokens; unknown tags stay literal.
    static func tokens(in line: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "<", let close = line[index...].firstIndex(of: ">") {
                let inner = line[line.index(after: index)..<close].lowercased()
                let closing = inner.hasPrefix("/")
                let name = closing ? String(inner.dropFirst()) : inner
                if ["b", "i", "u"].contains(name) {
                    if !buffer.isEmpty { tokens.append(.text(buffer)); buffer = "" }
                    tokens.append(.tag(name, closing: closing))
                    index = line.index(after: close)
                    continue
                }
            }
            buffer.append(line[index])
            index = line.index(after: index)
        }
        if !buffer.isEmpty { tokens.append(.text(buffer)) }
        return tokens
    }

    /// Text without inline tags (for accessibility labels).
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "</?[ibuIBU]>", with: "", options: .regularExpression)
    }
}
