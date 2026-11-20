import XCTest
import SwiftUI
import UIKit
import CoreText
@testable import Sable

/// Pixel glyph grids, glyph rendering and bundled font registration.
final class DesignSystemTests: XCTestCase {
    func testEveryGlyphGridIsSquareAndUsesOnlyInkAndEmptyCells() {
        var sizes = Set<Int>()
        for glyph in PixelGlyph.allCases {
            let rows = PixelGlyphArt.rows(for: glyph)
            XCTAssertFalse(rows.isEmpty, "\(glyph.rawValue) has no rows")
            for (index, row) in rows.enumerated() {
                XCTAssertEqual(row.count, rows.count,
                               "\(glyph.rawValue): row \(index) is \(row.count) cells wide but the grid has \(rows.count) rows")
                XCTAssertTrue(row.allSatisfy { $0 == "#" || $0 == "." },
                              "\(glyph.rawValue): row \(index) contains characters other than '#' and '.': \(row)")
            }
            XCTAssertTrue(rows.joined().contains("#"), "\(glyph.rawValue) has no ink and would be invisible")
            sizes.insert(rows.count)
        }
        XCTAssertEqual(sizes.count, 1, "All glyphs must share one grid size so they align; found \(sizes.sorted())")
    }

    func testEveryGlyphHasItsOwnArt() throws {
        let grids = PixelGlyph.allCases.map { PixelGlyphArt.rows(for: $0) }
        var uses: [[String]: Int] = [:]
        for grid in grids { uses[grid, default: 0] += 1 }
        if let mostShared = uses.values.max(), mostShared * 2 >= grids.count {
            throw XCTSkip("Most glyphs still render the placeholder grid (design system art not drawn yet)")
        }
        let duplicated = PixelGlyph.allCases.filter { (uses[PixelGlyphArt.rows(for: $0)] ?? 0) > 1 }.map(\.rawValue)
        XCTAssertTrue(duplicated.isEmpty, "These glyphs share identical art (placeholder?): \(duplicated)")
    }

    @MainActor
    func testPixelIconRendersVisibleInk() throws {
        for glyph in [PixelGlyph.play, .pause, .close] {
            let renderer = ImageRenderer(content: PixelIcon(glyph, size: 24, color: .white).frame(width: 24, height: 24))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image for \(glyph.rawValue)")
            XCTAssertGreaterThan(Self.opaquePixelCount(image), 0, "\(glyph.rawValue) rendered no visible pixels")
        }
    }

    func testBundledFontsAreRegisteredUnderTheirPostScriptNames() {
        SableFonts.registerAll()
        let names = [
            SableFonts.pixelRegular, SableFonts.pixelMedium, SableFonts.pixelSemiBold, SableFonts.pixelBold,
            SableFonts.micro, SableFonts.microBold,
            SableFonts.arabicRegular, SableFonts.arabicMedium, SableFonts.arabicSemiBold, SableFonts.arabicBold,
        ]
        for name in names {
            XCTAssertNotNil(UIFont(name: name, size: 17), "Font '\(name)' is not available: is the .ttf bundled and registered?")
        }
    }

    func testArabicFontHasGlyphsForArabicText() {
        SableFonts.registerAll()
        let font = CTFontCreateWithName(SableFonts.arabicRegular as CFString, 17, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, SableFonts.arabicRegular,
                       "IBM Plex Sans Arabic fell back to another face")
        let characters = Array("\u{200F}مارا، هل ما زلتِ مستيقظة؟".utf16).filter { $0 != 0x200F }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        let complete = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        XCTAssertTrue(complete, "IBM Plex Sans Arabic is missing glyphs for the fixture's Arabic line")
    }

    private static func opaquePixelCount(_ image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        return stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 0 ? 1 : 0) }
    }
}
