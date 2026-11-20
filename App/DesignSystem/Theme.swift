import SwiftUI
import UIKit
import CoreText

// OWNER: design agent. Token NAMES are the contract every feature uses; values may be tuned.

/// Colour tokens. Black-first palette with one restrained accent (phosphor amber).
enum Palette {
    /// App background — true black (OLED).
    static let background = Color(hex: 0x000000)
    /// Raised surfaces, from lowest to highest.
    static let surface = Color(hex: 0x0B0B0C)
    static let surfaceRaised = Color(hex: 0x141416)
    static let surfaceHigh = Color(hex: 0x1D1D20)
    /// 1-pixel borders.
    static let border = Color(hex: 0x2B2B30)
    static let borderStrong = Color(hex: 0x45454C)

    static let textPrimary = Color(hex: 0xF2F1EC)
    static let textSecondary = Color(hex: 0xA3A29C)
    static let textTertiary = Color(hex: 0x6E6D68)

    /// The single accent. Use for the active/primary element on screen, progress and focus only.
    static let accent = Color(hex: 0xFFB43C)
    static let accentDim = Color(hex: 0xFFB43C).opacity(0.16)
    static let onAccent = Color(hex: 0x120C00)

    static let danger = Color(hex: 0xFF5D52)
    static let success = Color(hex: 0x7BD88F)

    /// Player chrome scrim over video.
    static let scrim = Color.black.opacity(0.55)
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
}

/// Typography roles. Pixel type for chrome and headings; Plex Sans Arabic for Arabic and long
/// reading text. All roles scale with Dynamic Type via `relativeTo:`.
enum Typo {
    static let display = Font.custom(SableFonts.pixelBold, size: 30, relativeTo: .largeTitle)
    static let title = Font.custom(SableFonts.pixelSemiBold, size: 22, relativeTo: .title2)
    static let headline = Font.custom(SableFonts.pixelSemiBold, size: 17, relativeTo: .headline)
    static let body = Font.custom(SableFonts.pixelRegular, size: 16, relativeTo: .body)
    static let bodyMedium = Font.custom(SableFonts.pixelMedium, size: 16, relativeTo: .body)
    static let callout = Font.custom(SableFonts.pixelRegular, size: 14, relativeTo: .callout)
    /// Uppercase micro labels ("AUDIO", "SUBTITLES"). Keep to short strings.
    static let micro = Font.custom(SableFonts.micro, size: 10, relativeTo: .caption2)
    static let microBold = Font.custom(SableFonts.microBold, size: 10, relativeTo: .caption2)
    /// Timecodes and numeric readouts (fixed-width digits).
    static let mono = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let monoLarge = Font.system(size: 28, weight: .semibold, design: .monospaced)
    /// Readable explanatory text (Latin + Arabic).
    static let reading = Font.custom(SableFonts.arabicRegular, size: 15, relativeTo: .body)
    static let readingMedium = Font.custom(SableFonts.arabicMedium, size: 15, relativeTo: .body)
    /// Arabic UI/content text.
    static let arabic = Font.custom(SableFonts.arabicMedium, size: 17, relativeTo: .body)
}
