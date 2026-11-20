import SwiftUI

// OWNER: design agent. Every case below is used by feature code; keep the case names.
// Glyphs are drawn on a square grid ("#" = ink, "." = empty) and rendered with Canvas, snapped
// to whole device pixels so they stay crisp at any size.

enum PixelGlyph: String, CaseIterable {
    case play, pause, stop
    case skipBack, skipForward          // "back/forward N seconds"
    case previous, next                 // previous/next cue or item
    case subtitles, audio, translate, sync, timer, speed, aspect, pip, rotate, lock, unlock
    case fullscreen, exitFullscreen
    case settings, close, back, chevronRight, chevronDown, chevronUp
    case plus, minus, search, sort, trash, folder, film, file, export, importFile
    case check, undo, reset, flag, waveform, key, warning, info, more, list, grid
    case cloud, sparkle
}

struct PixelIcon: View {
    let glyph: PixelGlyph
    var size: CGFloat = 20
    var color: Color? = nil

    init(_ glyph: PixelGlyph, size: CGFloat = 20, color: Color? = nil) {
        self.glyph = glyph
        self.size = size
        self.color = color
    }

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let rows = PixelGlyphArt.rows(for: glyph)
        Canvas { context, canvasSize in
            let n = max(rows.count, 1)
            // Whole device pixels per art pixel for crispness.
            let devicePerCell = max(1, floor(min(canvasSize.width, canvasSize.height) * displayScale / CGFloat(n)))
            let cell = devicePerCell / displayScale
            let total = cell * CGFloat(n)
            let originX = ((canvasSize.width - total) / 2 * displayScale).rounded() / displayScale
            let originY = ((canvasSize.height - total) / 2 * displayScale).rounded() / displayScale
            var path = Path()
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    path.addRect(CGRect(x: originX + CGFloat(x) * cell, y: originY + CGFloat(y) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .foreground)
        }
        .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum PixelGlyphArt {
    /// 12x12 grids. Unknown glyphs fall back to a hollow square so nothing is invisible.
    static func rows(for glyph: PixelGlyph) -> [String] {
        art[glyph] ?? fallback
    }

    static let fallback: [String] = [
        "............",
        ".##########.",
        ".#........#.",
        ".#........#.",
        ".#........#.",
        ".#........#.",
        ".#........#.",
        ".#........#.",
        ".#........#.",
        ".#........#.",
        ".##########.",
        "............",
    ]

    static let art: [PixelGlyph: [String]] = [
        .play: [
            "............",
            "...#........",
            "...##.......",
            "...###......",
            "...####.....",
            "...#####....",
            "...#####....",
            "...####.....",
            "...###......",
            "...##.......",
            "...#........",
            "............",
        ],
        .pause: [
            "............",
            "..###..###..",
            "..###..###..",
            "..###..###..",
            "..###..###..",
            "..###..###..",
            "..###..###..",
            "..###..###..",
            "..###..###..",
            "..###..###..",
            "..###..###..",
            "............",
        ],
        .close: [
            "............",
            ".##......##.",
            ".###....###.",
            "..###..###..",
            "...######...",
            "....####....",
            "....####....",
            "...######...",
            "..###..###..",
            ".###....###.",
            ".##......##.",
            "............",
        ],
    ]
}
