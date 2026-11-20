import SwiftUI

// OWNER: design agent. Every case below is used by feature code; keep the case names.
// Glyphs are drawn on a 12x12 grid ("#" = ink, "." = empty) and rendered with Canvas, snapped
// to whole device pixels so they stay crisp at any size. Grid rules (docs/DESIGN.md):
//  - one empty cell of margin on every side (live area 10x10),
//  - object pictograms use 1-cell outlines; marks/actions (play, close, plus, check, chevrons)
//    use solid shapes or 2-cell strokes,
//  - optically centred on the grid centre (6, 6); containers have notched corners.
// Run `python3 design/icons/contact_sheet.py` after editing: it validates every grid and renders
// design/icons/contact-sheet.png.

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
    case volume, mute, brightness, edit, eye, eyeOff, loop
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
        let bitmap = PixelGlyphArt.bitmap(for: glyph)
        let scale = displayScale
        Canvas { context, canvasSize in
            context.fill(bitmap.path(in: canvasSize, scale: scale), with: .foreground)
        }
        .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A parsed square pixel grid (row-major, `true` = ink). Used by glyphs and `PixelEmptyArt`.
struct PixelBitmap: Equatable {
    let width: Int
    let height: Int
    let cells: [Bool]

    init(rows: [String], ink: Character = "#") {
        height = rows.count
        width = rows.map(\.count).max() ?? 0
        var cells = [Bool](repeating: false, count: width * height)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == ink {
                cells[y * width + x] = true
            }
        }
        self.cells = cells
    }

    func isInk(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return cells[y * width + x]
    }

    /// Bounding box of the ink in cells (inclusive), or nil when empty.
    var inkBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where cells[y * width + x] {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    /// Integer-snapped placement of the grid inside `size` points at `scale` device pixels per point.
    /// Every cell is a whole number of device pixels. The larger of two candidate cell sizes is used
    /// when the live area (the grid minus `margin` empty cells per side) still fits; the empty margin
    /// may then overhang the frame. The choice depends only on grid size, margin, frame and scale —
    /// never on a glyph's own ink — so every glyph gets the same cell size at a given point size.
    func layout(in size: CGSize, scale: CGFloat, margin: Int = 1) -> (cell: CGFloat, origin: CGPoint) {
        let s = max(scale, 1)
        let deviceW = size.width * s, deviceH = size.height * s
        let n = CGFloat(max(width, height, 1))
        let m = CGFloat(max(0, margin))
        let live = max(1, n - 2 * m)
        var perCell = max(1, floor(min(deviceW, deviceH) / n))
        let bigger = perCell + 1
        let bx = ((deviceW - bigger * n) / 2).rounded()
        let by = ((deviceH - bigger * n) / 2).rounded()
        if bx + m * bigger >= 0, bx + (m + live) * bigger <= deviceW,
           by + m * bigger >= 0, by + (m + live) * bigger <= deviceH {
            perCell = bigger
        }
        let total = perCell * n
        let ox = ((deviceW - total) / 2).rounded()
        let oy = ((deviceH - total) / 2).rounded()
        return (perCell / s, CGPoint(x: ox / s, y: oy / s))
    }

    /// Ink as a path of horizontal runs (no seams between neighbouring cells).
    func path(in size: CGSize, scale: CGFloat) -> Path {
        let (cell, origin) = layout(in: size, scale: scale)
        var path = Path()
        for y in 0..<height {
            var x = 0
            while x < width {
                guard cells[y * width + x] else { x += 1; continue }
                let start = x
                while x < width && cells[y * width + x] { x += 1 }
                path.addRect(CGRect(x: origin.x + CGFloat(start) * cell, y: origin.y + CGFloat(y) * cell,
                                    width: CGFloat(x - start) * cell, height: cell))
            }
        }
        return path
    }
}

enum PixelGlyphArt {
    /// Every glyph grid is `gridSize` x `gridSize`.
    static let gridSize = 12

    /// 12x12 grids. Unknown glyphs fall back to a hollow square so nothing is invisible.
    static func rows(for glyph: PixelGlyph) -> [String] {
        art[glyph] ?? fallback
    }

    static func bitmap(for glyph: PixelGlyph) -> PixelBitmap {
        bitmaps[glyph] ?? PixelBitmap(rows: fallback)
    }

    private static let bitmaps: [PixelGlyph: PixelBitmap] = art.mapValues { PixelBitmap(rows: $0) }

    /// Problems with one grid: wrong row count/length, characters other than "#"/".", no ink, or
    /// ink in the one-cell outer margin. Empty when the grid is valid.
    static func problems(in rows: [String], size: Int = PixelGlyphArt.gridSize) -> [String] {
        var out: [String] = []
        if rows.count != size { out.append("has \(rows.count) rows, expected \(size)") }
        for (i, row) in rows.enumerated() {
            if row.count != size { out.append("row \(i) has \(row.count) characters, expected \(size)") }
            if row.contains(where: { $0 != "#" && $0 != "." }) { out.append("row \(i) has characters other than # and .") }
        }
        if !rows.contains(where: { $0.contains("#") }) { out.append("has no ink") }
        let marginInk = rows.first?.contains("#") == true || rows.last?.contains("#") == true
            || rows.contains(where: { $0.first == "#" || $0.last == "#" })
        if marginInk { out.append("has ink in the outer margin") }
        return out
    }

    /// True when `rows` is exactly `size` rows of `size` characters of "#"/"." with some ink.
    static func isValid(_ rows: [String], size: Int = PixelGlyphArt.gridSize) -> Bool {
        problems(in: rows, size: size).isEmpty
    }

    /// Validates every glyph: art exists for each case, each grid is valid, no two glyphs are
    /// identical. Returns human-readable errors (empty = all good). Unit-testable.
    static func validationErrors() -> [String] {
        var errors: [String] = []
        var seen: [String: PixelGlyph] = [:]
        for glyph in PixelGlyph.allCases {
            guard let rows = art[glyph] else { errors.append("\(glyph.rawValue): no art"); continue }
            errors += problems(in: rows).map { "\(glyph.rawValue): \($0)" }
            let key = rows.joined(separator: "\n")
            if let other = seen[key] { errors.append("\(glyph.rawValue): identical to \(other.rawValue)") }
            seen[key] = glyph
        }
        return errors
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
            "...####.....",
            "...#####....",
            "...#######..",
            "...#######..",
            "...#####....",
            "...####.....",
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
        .stop: [
            "............",
            "............",
            "..########..",
            "..########..",
            "..########..",
            "..########..",
            "..########..",
            "..########..",
            "..########..",
            "..########..",
            "............",
            "............",
        ],
        .skipBack: [
            "............",
            ".....#....#.",
            "....##...##.",
            "...###..###.",
            "..####.####.",
            ".##########.",
            ".##########.",
            "..####.####.",
            "...###..###.",
            "....##...##.",
            ".....#....#.",
            "............",
        ],
        .skipForward: [
            "............",
            ".#....#.....",
            ".##...##....",
            ".###..###...",
            ".####.####..",
            ".##########.",
            ".##########.",
            ".####.####..",
            ".###..###...",
            ".##...##....",
            ".#....#.....",
            "............",
        ],
        .previous: [
            "............",
            "..##.....#..",
            "..##....##..",
            "..##...###..",
            "..##..####..",
            "..##.#####..",
            "..##.#####..",
            "..##..####..",
            "..##...###..",
            "..##....##..",
            "..##.....#..",
            "............",
        ],
        .next: [
            "............",
            "..#.....##..",
            "..##....##..",
            "..###...##..",
            "..####..##..",
            "..#####.##..",
            "..#####.##..",
            "..####..##..",
            "..###...##..",
            "..##....##..",
            "..#.....##..",
            "............",
        ],
        .subtitles: [
            "............",
            "............",
            "..########..",
            ".#........#.",
            ".#.######.#.",
            ".#........#.",
            ".#.####...#.",
            ".#........#.",
            "..########..",
            "..##........",
            "..#.........",
            "............",
        ],
        .audio: [
            "............",
            "............",
            "....####....",
            "..##....##..",
            ".#........#.",
            ".#........#.",
            ".###....###.",
            ".###....###.",
            ".###....###.",
            ".###....###.",
            "............",
            "............",
        ],
        .translate: [
            "............",
            ".######.....",
            ".#....#.....",
            ".###.##.##..",
            ".###.##..#..",
            ".######.###.",
            ".........#..",
            ".....######.",
            ".....#....#.",
            ".....#.##.#.",
            ".....######.",
            "............",
        ],
        .sync: [
            "............",
            ".......#....",
            ".######.#...",
            ".######..#..",
            ".######.#...",
            ".......#....",
            "....#.......",
            "...#.######.",
            "..#..######.",
            "...#.######.",
            "....#.......",
            "............",
        ],
        .timer: [
            "............",
            "....####....",
            "..##....##..",
            ".#........#.",
            ".#...#....#.",
            ".#...#....#.",
            ".#...####.#.",
            ".#........#.",
            ".#........#.",
            "..##....##..",
            "....####....",
            "............",
        ],
        .speed: [
            "............",
            "............",
            "............",
            "....####....",
            "..##....##..",
            ".#......#.#.",
            ".#.....#..#.",
            ".#....#...#.",
            ".#...##...#.",
            ".#...##...#.",
            "............",
            "............",
        ],
        .aspect: [
            "............",
            "............",
            ".###....###.",
            ".#........#.",
            ".#........#.",
            "............",
            "............",
            ".#........#.",
            ".#........#.",
            ".###....###.",
            "............",
            "............",
        ],
        .pip: [
            "............",
            "............",
            "..########..",
            ".#........#.",
            ".#........#.",
            ".#...####.#.",
            ".#...####.#.",
            ".#...####.#.",
            ".#........#.",
            "..########..",
            "............",
            "............",
        ],
        .rotate: [
            "............",
            "....####....",
            "...#....#...",
            "..#....###..",
            "........#...",
            ".######.....",
            ".#....#.....",
            ".#....#.....",
            ".#....#.....",
            ".#....#.....",
            ".######.....",
            "............",
        ],
        .lock: [
            "............",
            "....####....",
            "...#....#...",
            "...#....#...",
            "...#....#...",
            "..########..",
            "..########..",
            "..###..###..",
            "..###..###..",
            "..########..",
            "..########..",
            "............",
        ],
        .unlock: [
            "............",
            "....####....",
            "...#....#...",
            "...#........",
            "...#........",
            "..########..",
            "..########..",
            "..###..###..",
            "..###..###..",
            "..########..",
            "..########..",
            "............",
        ],
        .fullscreen: [
            "............",
            ".####..####.",
            ".###....###.",
            ".##......##.",
            ".#........#.",
            "............",
            "............",
            ".#........#.",
            ".##......##.",
            ".###....###.",
            ".####..####.",
            "............",
        ],
        .exitFullscreen: [
            "............",
            "....#..#....",
            "...##..##...",
            "..###..###..",
            ".####..####.",
            "............",
            "............",
            ".####..####.",
            "..###..###..",
            "...##..##...",
            "....#..#....",
            "............",
        ],
        .settings: [
            "............",
            ".....##.....",
            "..#.####.#..",
            "..########..",
            "..###..###..",
            ".###....###.",
            ".###....###.",
            "..###..###..",
            "..########..",
            "..#.####.#..",
            ".....##.....",
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
        .back: [
            "............",
            "............",
            "......##....",
            ".....##.....",
            "....##......",
            "...##.......",
            "...##.......",
            "....##......",
            ".....##.....",
            "......##....",
            "............",
            "............",
        ],
        .chevronRight: [
            "............",
            "............",
            "....##......",
            ".....##.....",
            "......##....",
            ".......##...",
            ".......##...",
            "......##....",
            ".....##.....",
            "....##......",
            "............",
            "............",
        ],
        .chevronDown: [
            "............",
            "............",
            "............",
            "............",
            "..#......#..",
            "..##....##..",
            "...##..##...",
            "....####....",
            ".....##.....",
            "............",
            "............",
            "............",
        ],
        .chevronUp: [
            "............",
            "............",
            "............",
            ".....##.....",
            "....####....",
            "...##..##...",
            "..##....##..",
            "..#......#..",
            "............",
            "............",
            "............",
            "............",
        ],
        .plus: [
            "............",
            "............",
            ".....##.....",
            ".....##.....",
            ".....##.....",
            "..########..",
            "..########..",
            ".....##.....",
            ".....##.....",
            ".....##.....",
            "............",
            "............",
        ],
        .minus: [
            "............",
            "............",
            "............",
            "............",
            "............",
            "..########..",
            "..########..",
            "............",
            "............",
            "............",
            "............",
            "............",
        ],
        .search: [
            "............",
            "...####.....",
            "..#....#....",
            ".#......#...",
            ".#......#...",
            ".#......#...",
            ".#......#...",
            "..#....#....",
            "...####.##..",
            ".........##.",
            "............",
            "............",
        ],
        .sort: [
            "............",
            "...#....#...",
            "..###...#...",
            ".#####..#...",
            "...#....#...",
            "...#....#...",
            "...#....#...",
            "...#....#...",
            "...#..#####.",
            "...#...###..",
            "...#....#...",
            "............",
        ],
        .trash: [
            "............",
            "....####....",
            ".##########.",
            "..#......#..",
            "..#.#..#.#..",
            "..#.#..#.#..",
            "..#.#..#.#..",
            "..#.#..#.#..",
            "..#......#..",
            "..#......#..",
            "...######...",
            "............",
        ],
        .folder: [
            "............",
            "............",
            ".####.......",
            ".#...######.",
            ".#........#.",
            ".#........#.",
            ".#........#.",
            ".#........#.",
            ".#........#.",
            ".##########.",
            "............",
            "............",
        ],
        .film: [
            "............",
            ".##########.",
            ".#.#....#.#.",
            ".###....###.",
            ".#.#....#.#.",
            ".###....###.",
            ".#.#....#.#.",
            ".###....###.",
            ".#.#....#.#.",
            ".###....###.",
            ".##########.",
            "............",
        ],
        .file: [
            "............",
            "..#####.....",
            "..#...##....",
            "..#...#.#...",
            "..#...####..",
            "..#......#..",
            "..#......#..",
            "..#......#..",
            "..#......#..",
            "..#......#..",
            "..########..",
            "............",
        ],
        .export: [
            "............",
            ".....##.....",
            "....####....",
            "...######...",
            ".....##.....",
            ".##..##..##.",
            ".#...##...#.",
            ".#...##...#.",
            ".#........#.",
            ".#........#.",
            ".##########.",
            "............",
        ],
        .importFile: [
            "............",
            ".....##.....",
            ".....##.....",
            ".....##.....",
            "...######...",
            ".##.####.##.",
            ".#...##...#.",
            ".#........#.",
            ".#........#.",
            ".#........#.",
            ".##########.",
            "............",
        ],
        .check: [
            "............",
            "............",
            ".........##.",
            "........##..",
            ".......##...",
            "......##....",
            ".##..##.....",
            "..####......",
            "...##.......",
            "............",
            "............",
            "............",
        ],
        .undo: [
            "............",
            "............",
            "...#........",
            "..##........",
            ".########...",
            "..##.....#..",
            "...#......#.",
            "..........#.",
            ".........#..",
            "......###...",
            "............",
            "............",
        ],
        .reset: [
            "............",
            "....#.......",
            "...##.......",
            "..#######...",
            "...##....#..",
            "....#.....#.",
            ".#........#.",
            ".#........#.",
            ".#........#.",
            "..#......#..",
            "...######...",
            "............",
        ],
        .flag: [
            "............",
            "..########..",
            "..########..",
            "..######....",
            "..########..",
            "..########..",
            "..#.........",
            "..#.........",
            "..#.........",
            "..#.........",
            "..#.........",
            "............",
        ],
        .waveform: [
            "............",
            ".....##.....",
            ".....##.#...",
            "...#.##.#...",
            "...#.##.#.#.",
            ".#.#.##.#.#.",
            ".#.#.##.#.#.",
            "...#.##.#.#.",
            "...#.##.#...",
            ".....##.#...",
            ".....##.....",
            "............",
        ],
        .key: [
            "............",
            "............",
            "............",
            ".####.......",
            ".#..#.......",
            ".#..#######.",
            ".#..#######.",
            ".#..#..#.##.",
            ".####.......",
            "............",
            "............",
            "............",
        ],
        .warning: [
            "............",
            ".....##.....",
            "....#..#....",
            "....#..#....",
            "...#.##.#...",
            "...#.##.#...",
            "..#..##..#..",
            "..#......#..",
            ".#...##...#.",
            ".#........#.",
            ".##########.",
            "............",
        ],
        .info: [
            "............",
            "....####....",
            "..##....##..",
            ".#...##...#.",
            ".#........#.",
            ".#...##...#.",
            ".#...##...#.",
            ".#...##...#.",
            ".#...##...#.",
            "..##....##..",
            "....####....",
            "............",
        ],
        .more: [
            "............",
            "............",
            "............",
            "............",
            "............",
            ".##..##..##.",
            ".##..##..##.",
            "............",
            "............",
            "............",
            "............",
            "............",
        ],
        .list: [
            "............",
            "............",
            "............",
            ".##.#######.",
            "............",
            "............",
            ".##.#######.",
            "............",
            "............",
            ".##.#######.",
            "............",
            "............",
        ],
        .grid: [
            "............",
            ".####..####.",
            ".#..#..#..#.",
            ".#..#..#..#.",
            ".####..####.",
            "............",
            "............",
            ".####..####.",
            ".#..#..#..#.",
            ".#..#..#..#.",
            ".####..####.",
            "............",
        ],
        .cloud: [
            "............",
            "............",
            "............",
            ".....###....",
            "....#...#...",
            "..##.....#..",
            ".#........#.",
            ".#........#.",
            "..########..",
            "............",
            "............",
            "............",
        ],
        .sparkle: [
            "............",
            ".........#..",
            "........###.",
            "....#....#..",
            "....#.......",
            "...###......",
            ".#######....",
            "...###......",
            "....#.......",
            "....#.......",
            "............",
            "............",
        ],
        .volume: [
            "............",
            "............",
            "....##..#...",
            "...###...#..",
            ".#####.#..#.",
            ".#####..#.#.",
            ".#####..#.#.",
            ".#####.#..#.",
            "...###...#..",
            "....##..#...",
            "............",
            "............",
        ],
        .mute: [
            "............",
            "............",
            "....##......",
            "...###......",
            ".#####.#..#.",
            ".#####..##..",
            ".#####..##..",
            ".#####.#..#.",
            "...###......",
            "....##......",
            "............",
            "............",
        ],
        .brightness: [
            "............",
            ".....##.....",
            "..#..##..#..",
            "...#....#...",
            ".....##.....",
            ".##.####.##.",
            ".##.####.##.",
            ".....##.....",
            "...#....#...",
            "..#..##..#..",
            ".....##.....",
            "............",
        ],
        .edit: [
            "............",
            "........#...",
            ".......###..",
            "......#.###.",
            ".....#...#..",
            "....#...#...",
            "...#...#....",
            "..##..#.....",
            "..###.......",
            "..##........",
            "............",
            "............",
        ],
        .eye: [
            "............",
            "............",
            "............",
            "....####....",
            "..##....##..",
            ".#...##...#.",
            ".#...##...#.",
            "..##....##..",
            "....####....",
            "............",
            "............",
            "............",
        ],
        .eyeOff: [
            "............",
            "............",
            "............",
            "............",
            ".#........#.",
            "..##....##..",
            "....####....",
            "..#..##..#..",
            ".#...##...#.",
            "............",
            "............",
            "............",
        ],
        .loop: [
            "............",
            "............",
            "........#...",
            "..#######...",
            ".#......#...",
            ".#..........",
            "..........#.",
            "...#......#.",
            "...#######..",
            "...#........",
            "............",
            "............",
        ],
    ]
}
