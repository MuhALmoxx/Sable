import SwiftUI
import UIKit
import CoreText

// OWNER: design agent. Token NAMES are the contract every feature uses; values may be tuned.
// Contrast ratios for these values are computed by design/tokens/contrast.py and recorded in
// docs/DESIGN.md. Keep hex literals in the `Color(hex: 0xRRGGBB)` form so the script can read them.

/// Colour tokens. Black-first palette (warm neutrals) with one restrained accent (phosphor amber).
enum Palette {
    /// App background — true black (OLED).
    static let background = Color(hex: 0x000000)
    /// Raised surfaces, from lowest to highest.
    static let surface = Color(hex: 0x0D0C0B)
    static let surfaceRaised = Color(hex: 0x161513)
    static let surfaceHigh = Color(hex: 0x201E1B)
    /// 1-pixel separators and decorative outlines (not relied on to identify a control).
    static let border = Color(hex: 0x2E2C29)
    /// Boundaries that identify a control (text field, switch track, slider track, segmented
    /// outline). At least 3:1 against background and surfaces (WCAG 1.4.11).
    static let borderStrong = Color(hex: 0x6E6A62)

    /// Text. All three meet WCAG AA (>= 4.5:1) on background and every surface.
    static let textPrimary = Color(hex: 0xF2F1EC)
    static let textSecondary = Color(hex: 0xA3A29C)
    /// Section labels, hints, disabled controls.
    static let textTertiary = Color(hex: 0x8E8B84)

    /// The single accent. Use for the active/primary element on screen, progress and focus only.
    static let accent = Color(hex: 0xFFB43C)
    static let accentDim = Color(hex: 0xFFB43C).opacity(0.16)
    /// Pressed state of an accent fill.
    static let accentPressed = Color(hex: 0xD9952B)
    /// Text/icons drawn on an accent fill.
    static let onAccent = Color(hex: 0x120C00)

    static let danger = Color(hex: 0xFF5D52)
    static let dangerDim = Color(hex: 0xFF5D52).opacity(0.16)
    static let success = Color(hex: 0x7BD88F)

    /// Keyboard/switch-control focus ring.
    static let focus = Color(hex: 0xFFB43C)

    /// Player chrome scrim over video.
    static let scrim = Color.black.opacity(0.55)
    /// Darker scrim for text panels over video (toasts, HUD readouts).
    static let scrimStrong = Color.black.opacity(0.8)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Spacing scale on a 4-pt grid; `px` is the size of one "art pixel" for borders/icons.
enum Spacing {
    static let px: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    /// Minimum interactive size (HIG).
    static let touch: CGFloat = 44
    /// Border/divider thickness in points (whole device pixels on every iPhone).
    static let line: CGFloat = 1
    /// Icon sizes (glyph cells are always whole device pixels; see PixelBitmap.layout).
    static let iconSmall: CGFloat = 16
    static let icon: CGFloat = 20
    static let iconLarge: CGFloat = 24
    /// Minimum height of a two-line list row.
    static let rowTall: CGFloat = 56
}

/// Bundled typefaces (all SIL OFL 1.1, see licenses/).
enum SableFonts {
    static let pixelRegular = "PixelifySans-Regular"
    static let pixelMedium = "PixelifySans-Medium"
    static let pixelSemiBold = "PixelifySans-SemiBold"
    static let pixelBold = "PixelifySans-Bold"
    static let micro = "Silkscreen-Regular"
    static let microBold = "Silkscreen-Bold"
    static let arabicRegular = "IBMPlexSansArabic-Regular"
    static let arabicMedium = "IBMPlexSansArabic-Medium"
    static let arabicSemiBold = "IBMPlexSansArabic-SemiBold"
    static let arabicBold = "IBMPlexSansArabic-Bold"

    /// Every PostScript name above.
    static let all: [String] = [
        pixelRegular, pixelMedium, pixelSemiBold, pixelBold, micro, microBold,
        arabicRegular, arabicMedium, arabicSemiBold, arabicBold,
    ]

    private static var registered = false

    /// Registers every .ttf in the bundle's Fonts folder (no Info.plist UIAppFonts needed).
    static func registerAll() {
        guard !registered else { return }
        registered = true
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// PostScript names that cannot be loaded (empty when every bundled face is available).
    /// Call after `registerAll()`; useful in tests and debug assertions.
    static func missingFonts() -> [String] {
        all.filter { UIFont(name: $0, size: 12) == nil }
    }
}

/// Typography roles. Pixel type for chrome and headings; Plex Sans Arabic for Arabic and long
/// reading text. All roles scale with Dynamic Type (`relativeTo:` / text styles).
///
/// Neither pixel face has tabular digits (the "1" is narrower in both Silkscreen and Pixelify
/// Sans), so timecodes use the system monospaced face.
enum Typo {
    static let display = Font.custom(SableFonts.pixelBold, size: 32, relativeTo: .largeTitle)
    static let title = Font.custom(SableFonts.pixelSemiBold, size: 22, relativeTo: .title2)
    static let headline = Font.custom(SableFonts.pixelSemiBold, size: 17, relativeTo: .headline)
    static let body = Font.custom(SableFonts.pixelRegular, size: 16, relativeTo: .body)
    static let bodyMedium = Font.custom(SableFonts.pixelMedium, size: 16, relativeTo: .body)
    static let callout = Font.custom(SableFonts.pixelRegular, size: 14, relativeTo: .callout)
    /// Uppercase micro labels ("AUDIO", "SUBTITLES"). Keep to short strings.
    /// Silkscreen is drawn on a 1/8-em grid: 32/3 pt puts every art pixel on exactly 4 device
    /// pixels at @3x (crisp, no grey fringes).
    static let micro = Font.custom(SableFonts.micro, size: 32.0 / 3.0, relativeTo: .caption2)
    static let microBold = Font.custom(SableFonts.microBold, size: 32.0 / 3.0, relativeTo: .caption2)
    /// Timecodes and numeric readouts (fixed-width digits).
    static let mono = Font.system(.footnote, design: .monospaced, weight: .medium)
    static let monoLarge = Font.system(.title, design: .monospaced, weight: .semibold)
    /// Small fixed-width readouts (tags, offsets in lists).
    static let monoSmall = Font.system(.caption, design: .monospaced, weight: .medium)
    /// Readable explanatory text (Latin + Arabic).
    static let reading = Font.custom(SableFonts.arabicRegular, size: 15, relativeTo: .body)
    static let readingMedium = Font.custom(SableFonts.arabicMedium, size: 15, relativeTo: .body)
    /// Arabic UI/content text.
    static let arabic = Font.custom(SableFonts.arabicMedium, size: 17, relativeTo: .body)
    /// Secondary Arabic text (subtitles in lists, previews).
    static let arabicSmall = Font.custom(SableFonts.arabicRegular, size: 14, relativeTo: .callout)
}

/// Helpers for drawing Arabic correctly (IBM Plex Sans Arabic, right-to-left paragraphs).
enum ArabicScript {
    /// Right-to-left mark, prefixed to each displayed Arabic line.
    static let rlm: Character = "\u{200F}"

    /// True when `text` contains any Arabic-script character.
    static func containsArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                return true
            default:
                return false
            }
        }
    }

    /// Prefixes every line with U+200F (once) so mixed Latin/Arabic lines start right-to-left.
    static func rtlLines(_ text: String) -> String {
        let lines: [String] = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let s = String(line)
            return s.first == rlm ? s : String(rlm) + s
        }
        return lines.joined(separator: "\n")
    }
}

/// Pixel snapping: whole device pixels for crisp 1-px borders and pixel art.
enum PixelSnap {
    /// Rounds `value` (points) to the nearest device pixel.
    static func round(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        return (value * s).rounded() / s
    }

    /// A line width of at least one device pixel, rounded to whole device pixels.
    static func lineWidth(_ points: CGFloat, scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        return max(1, (points * s).rounded()) / s
    }
}
