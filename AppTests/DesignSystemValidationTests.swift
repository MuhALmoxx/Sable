import XCTest
import SwiftUI
@testable import Sable

final class DesignSystemValidationTests: XCTestCase {
    func testEveryGlyphGridIsValid() {
        XCTAssertEqual(PixelGlyphArt.validationErrors(), [])
    }

    func testGridValidatorRejectsMalformedGrids() {
        XCTAssertFalse(PixelGlyphArt.isValid(["###"]))
        XCTAssertFalse(PixelGlyphArt.isValid(Array(repeating: "............", count: 12)))
        XCTAssertTrue(PixelGlyphArt.isValid(PixelGlyphArt.fallback))
    }

    func testEmptyStateArtworksAreValid() {
        XCTAssertEqual(PixelArtworkArt.validationErrors(), [])
    }

    func testGlyphCellsAreWholeDevicePixelsAndConsistent() {
        for scale in [2.0, 3.0] as [CGFloat] {
            for size in [12, 16, 20, 22, 24, 36] as [CGFloat] {
                let frame = CGSize(width: size, height: size)
                let reference = PixelGlyphArt.bitmap(for: .play).layout(in: frame, scale: scale).cell
                XCTAssertEqual(reference * scale, (reference * scale).rounded(), accuracy: 1e-9)
                for glyph in PixelGlyph.allCases {
                    let cell = PixelGlyphArt.bitmap(for: glyph).layout(in: frame, scale: scale).cell
                    XCTAssertEqual(cell, reference, "\(glyph) \(size)@\(scale)")
                }
            }
        }
    }

    func testBundledFontsLoad() {
        SableFonts.registerAll()
        XCTAssertEqual(SableFonts.missingFonts(), [])
    }

    func testArabicHelpers() {
        XCTAssertTrue(ArabicScript.containsArabic("مرحبا"))
        XCTAssertFalse(ArabicScript.containsArabic("Hello"))
        XCTAssertEqual(ArabicScript.rtlLines("أ\nب"), "\u{200F}أ\n\u{200F}ب")
    }

    @MainActor
    func testSliderSnapping() {
        XCTAssertEqual(PixelSlider.snap(0.26, in: 0...1, step: 0.25), 0.25)
        XCTAssertEqual(PixelSlider.snap(2, in: 0...1, step: 0.1), 1)
        XCTAssertEqual(PixelSlider.value(at: 0.5, in: -5...5, step: 1), 0)
        XCTAssertEqual(PixelSlider.stepCount(range: 0...2, step: 0.25), 8)
    }
}
