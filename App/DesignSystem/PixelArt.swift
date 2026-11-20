import SwiftUI

// OWNER: design agent. Small empty-state illustrations composed from pixel grids.
// Inks: "+" frame (borderStrong), "#" detail (textTertiary), "o" highlight (textSecondary),
// "a" accent (one small amber element per artwork), "." empty. Rendered on whole device pixels.
// `python3 design/icons/contact_sheet.py` validates and previews these too.

enum PixelArtwork: String, CaseIterable {
    /// Film strip with a play frame — empty library.
    case library
    /// Screen with two subtitle bars (left- and right-aligned) — nothing playing / player error.
    case player
    /// Speech box with dotted lines — no subtitle tracks.
    case subtitles
}

/// Pixel illustration for empty states. `pixelSize` is the size of one art pixel in points
/// (rounded to whole device pixels). Decorative: hidden from accessibility.
struct PixelEmptyArt: View {
    let artwork: PixelArtwork
    var pixelSize: CGFloat

    init(_ artwork: PixelArtwork, pixelSize: CGFloat = 4) {
        self.artwork = artwork
        self.pixelSize = pixelSize
    }

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let rows = PixelArtworkArt.rows(for: artwork)
        let columns = rows.map(\.count).max() ?? 0
        let cell = PixelSnap.lineWidth(pixelSize, scale: displayScale)
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                var x = 0
                let chars = Array(row)
                while x < chars.count {
                    let ink = chars[x]
                    guard let color = PixelArtworkArt.color(for: ink) else { x += 1; continue }
                    let start = x
                    while x < chars.count && chars[x] == ink { x += 1 }
                    let rect = CGRect(x: CGFloat(start) * cell, y: CGFloat(y) * cell,
                                      width: CGFloat(x - start) * cell, height: cell)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(columns) * cell, height: CGFloat(rows.count) * cell)
        .accessibilityHidden(true)
    }
}

enum PixelArtworkArt {
    static func rows(for artwork: PixelArtwork) -> [String] {
        art[artwork] ?? []
    }

    static func color(for ink: Character) -> Color? {
        switch ink {
        case "+": return Palette.borderStrong
        case "#": return Palette.textTertiary
        case "o": return Palette.textSecondary
        case "a": return Palette.accent
        default: return nil
        }
    }

    /// Problems with every artwork (rectangular grid, known inks, some ink). Empty = valid.
    static func validationErrors() -> [String] {
        var errors: [String] = []
        for artwork in PixelArtwork.allCases {
            guard let rows = art[artwork], let width = rows.first?.count else {
                errors.append("\(artwork.rawValue): no art")
                continue
            }
            if rows.contains(where: { $0.count != width }) { errors.append("\(artwork.rawValue): rows differ in length") }
            if rows.contains(where: { $0.contains(where: { !"+#oa.".contains($0) }) }) {
                errors.append("\(artwork.rawValue): unknown ink")
            }
            if !rows.contains(where: { $0.contains(where: { $0 != "." }) }) { errors.append("\(artwork.rawValue): no ink") }
        }
        return errors
    }

    static let art: [PixelArtwork: [String]] = [
        .library: [
            "........................",
            ".++++++++++++++++++++++.",
            ".+.##..##..##..##..##.+.",
            ".++++++++++++++++++++++.",
            ".+......+......+......+.",
            ".+......+..a...+......+.",
            ".+......+..aa..+......+.",
            ".+......+..aaa.+......+.",
            ".+......+..aa..+......+.",
            ".+......+..a...+......+.",
            ".+......+......+......+.",
            ".++++++++++++++++++++++.",
            ".+.##..##..##..##..##.+.",
            ".++++++++++++++++++++++.",
            "........................",
        ],
        .player: [
            "........................",
            "..++++++++++++++++++++..",
            ".+....................+.",
            ".+..........a.........+.",
            ".+..........aa........+.",
            ".+..........aaa.......+.",
            ".+..........aa........+.",
            ".+..........a.........+.",
            ".+....................+.",
            ".+...oooooooooo.......+.",
            ".+....................+.",
            ".+.......oooooooooooo.+.",
            ".+....................+.",
            "..++++++++++++++++++++..",
            "..........++++..........",
            "........++++++++........",
        ],
        .subtitles: [
            "........................",
            "...++++++++++++++++++...",
            "..+..............a...+..",
            "..+..#.#.#.#.#.#.a...+..",
            "..+..............a...+..",
            "..+..................+..",
            "..+.......#.#.#.#.#..+..",
            "..+..................+..",
            "...++++++++++++++++++...",
            "....++..................",
            "....+...................",
            "........................",
        ],
    ]
}
