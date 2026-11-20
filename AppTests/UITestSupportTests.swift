#if DEBUG
import XCTest
@testable import Sable

/// The DEBUG test hooks and the fixtures they depend on.
final class UITestSupportTests: XCTestCase {
    func testDebugBundleCarriesEveryUITestFixture() throws {
        let directory = try XCTUnwrap(UITestSupport.fixturesDirectory, "UITestFixtures folder missing from the Debug bundle")
        for name in ["night-roof.mkv", "night-roof.mp4", "night-roof.late.en.srt", "reference-translations.ar.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                          "\(name) is missing from UITestFixtures")
        }
    }

    func testReferenceTranslationsCoverEveryFixtureLine() throws {
        let translations = UITestSupport.referenceTranslations()
        XCTAssertNil(translations["_comment"], "Metadata keys must not be offered as translations")
        let directory = try XCTUnwrap(UITestSupport.fixturesDirectory)
        let srt = try String(contentsOf: directory.appendingPathComponent("night-roof.late.en.srt"), encoding: .utf8)
        let lines = Self.plainCueTexts(fromSRT: srt)
        XCTAssertEqual(lines.count, 9)
        for line in lines {
            let arabic = try XCTUnwrap(translations[line], "No reference Arabic for '\(line)' (the mock provider needs it)")
            XCTAssertTrue(arabic.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }, "'\(arabic)' is not Arabic")
            XCTAssertEqual(arabic.components(separatedBy: "\n").count, line.components(separatedBy: "\n").count,
                           "Line breaks should match the English cue for '\(line)'")
        }
    }

    func testHooksAreInactiveInUnitTestRuns() {
        // Hosted unit tests launch the app without the UI-test arguments.
        XCTAssertFalse(UITestSupport.isUITesting)
        XCTAssertFalse(UITestSupport.shouldSeedLibrary)
        XCTAssertFalse(UITestSupport.useMockTranslation)
        XCTAssertEqual(UITestSupport.mockTranslationDelay, 0.8, accuracy: 0.0001)
    }

    func testSeedTitlesMatchTheUITests() {
        XCTAssertEqual(UITestSupport.SeedTitles.mkv, "Night Roof (MKV)")
        XCTAssertEqual(UITestSupport.SeedTitles.mp4, "Night Roof (MP4)")
        XCTAssertEqual(AX.Library.item(UITestSupport.SeedTitles.mp4), "library.item.Night Roof (MP4)")
    }

    /// Minimal SRT reader for the fixture (counter, timing line, text lines, blank separator),
    /// with inline tags removed — independent of SubtitleKit so it works before integration.
    static func plainCueTexts(fromSRT srt: String) -> [String] {
        let normalized = srt.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { block -> String? in
            let rows = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let arrow = rows.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let text = rows[(arrow + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "</?[ibuIBU]>", with: "", options: .regularExpression)
            return text.isEmpty ? nil : text
        }
    }
}
#endif
