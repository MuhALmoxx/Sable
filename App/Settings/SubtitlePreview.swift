import SwiftUI
import LibraryKit

// OWNER: library agent.

/// Live preview of the default subtitle style over a dark sample frame: an English line and the
/// Arabic line "مرحبًا بك في سابل" (IBM Plex Sans Arabic, right-to-left). With "show original
/// under translation" on, it shows the translated layout (Arabic, English underneath, smaller).
struct SubtitlePreview: View {
    let style: SubtitleStyle

    static let englishLine = "Welcome to Sable."
    static let arabicLine = "مرحبًا بك في سابل"

    /// Base size in the preview frame (the player scales its own base with the video size).
    private let baseSize: CGFloat = 17

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                SampleNightFrame()
                VStack(spacing: 4 * style.scale) {
                    if style.showOriginalUnderTranslation {
                        arabicText(size: baseSize * style.scale)
                        latinText(Self.englishLine, size: baseSize * style.scale * 0.72)
                    } else {
                        latinText(Self.englishLine, size: baseSize * style.scale)
                        arabicText(size: baseSize * style.scale)
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, max(Spacing.xs, geo.size.height * style.bottomMargin))
                .frame(maxWidth: .infinity)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipped()
        .overlay(Rectangle().stroke(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subtitle preview")
        .accessibilityValue(accessibilityDescription)
        .accessibilityIdentifier(AX.Settings.subtitlePreview)
    }

    private var accessibilityDescription: String {
        let size = "\(Int((style.scale * 100).rounded())) percent"
        let layout = style.showOriginalUnderTranslation ? "Arabic line with the English original underneath" : "an English line and an Arabic line"
        return "\(layout), \(size), \(style.background.rawValue) background, \(style.font.rawValue) font"
    }

    private func latinText(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(latinFont(size: size))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .modifier(SubtitleBackgroundStyle(background: style.background))
    }

    private func arabicText(size: CGFloat) -> some View {
        // Arabic always uses Plex (never a pixel font), RTL paragraph direction.
        Text("\u{200F}" + Self.arabicLine)
            .font(Font.custom(SableFonts.arabicSemiBold, fixedSize: size))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .modifier(SubtitleBackgroundStyle(background: style.background))
            .environment(\.layoutDirection, .rightToLeft)
    }

    private func latinFont(size: CGFloat) -> Font {
        switch style.font {
        case .plex: return Font.custom(SableFonts.arabicSemiBold, fixedSize: size)
        case .system: return Font.system(size: size, weight: .semibold)
        case .pixel: return Font.custom(SableFonts.pixelMedium, fixedSize: size)
        }
    }
}

/// Outline (four hard 1-pt shadows), soft drop shadow, or a translucent black box.
struct SubtitleBackgroundStyle: ViewModifier {
    let background: SubtitleBackground

    @ViewBuilder
    func body(content: Content) -> some View {
        switch background {
        case .outline:
            content
                .shadow(color: .black, radius: 0, x: 1, y: 0)
                .shadow(color: .black, radius: 0, x: -1, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: 1)
                .shadow(color: .black, radius: 0, x: 0, y: -1)
        case .shadow:
            content
                .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 2)
        case .box:
            content
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.75))
        }
    }
}

/// Dark, flat "night roof" scene drawn with pixel blocks (no gradients), so subtitle contrast
/// can be judged against something other than pure black.
struct SampleNightFrame: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x10131A)))
            let block = max(2, (w / 96).rounded(.down))
            // Moon.
            context.fill(Path(CGRect(x: w * 0.78, y: h * 0.14, width: block * 5, height: block * 5)),
                         with: .color(Color(hex: 0x3A3A40)))
            // Skyline.
            let skyline: [(x: CGFloat, width: CGFloat, height: CGFloat)] = [
                (0.00, 0.14, 0.42), (0.14, 0.09, 0.55), (0.23, 0.16, 0.36), (0.39, 0.07, 0.62),
                (0.46, 0.15, 0.40), (0.61, 0.10, 0.50), (0.71, 0.13, 0.33), (0.84, 0.16, 0.46),
            ]
            for building in skyline {
                let rect = CGRect(x: w * building.x, y: h * (1 - building.height),
                                  width: w * building.width + 1, height: h * building.height)
                context.fill(Path(rect), with: .color(Color(hex: 0x07080B)))
                // A few lit windows.
                var y = rect.minY + block * 3
                var row = 0
                while y < rect.maxY - block * 4 {
                    var x = rect.minX + block * 2
                    var column = 0
                    while x < rect.maxX - block * 2 {
                        if (row * 3 + column * 5 + Int(building.x * 100)) % 7 == 0 {
                            context.fill(Path(CGRect(x: x, y: y, width: block, height: block)),
                                         with: .color(Color(hex: 0x4A4536)))
                        }
                        x += block * 3
                        column += 1
                    }
                    y += block * 3
                    row += 1
                }
            }
        }
        .accessibilityHidden(true)
    }
}
