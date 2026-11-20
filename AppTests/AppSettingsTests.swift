import XCTest
import LibraryKit
@testable import Sable

/// AppSettings persistence through an isolated UserDefaults suite.
final class AppSettingsTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "com.murisixz.sable.tests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    @MainActor
    func testFreshSettingsUseValidDefaults() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        XCTAssertTrue(AppSettings.doubleTapOptions.contains(settings.doubleTapSeekSeconds),
                      "Default double-tap seek \(settings.doubleTapSeekSeconds) is not one of the offered options")
        XCTAssertTrue(AppSettings.rateOptions.contains(settings.defaultRate),
                      "Default rate \(settings.defaultRate) is not one of the offered options")
        XCTAssertEqual(settings.subtitleStyle, SubtitleStyle.default)
        XCTAssertFalse(settings.translationProviderID.isEmpty)
        XCTAssertFalse(settings.claudeModelID.isEmpty)
        XCTAssertEqual(LibrarySort(rawValue: settings.librarySortRaw), settings.librarySort)
    }

    @MainActor
    func testEverySettingSurvivesARoundTrip() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let style = SubtitleStyle(scale: 1.4, bottomMargin: 0.12, background: .box, font: .pixel,
                                  showOriginalUnderTranslation: true)
        let seek = AppSettings.doubleTapOptions.last ?? 30
        let rate = AppSettings.rateOptions.first { $0 != settings.defaultRate } ?? 1.5
        settings.doubleTapSeekSeconds = seek
        settings.defaultRate = rate
        settings.resumePlayback = !settings.resumePlayback
        let resume = settings.resumePlayback
        settings.subtitleStyle = style
        settings.translationProviderID = "anthropic-claude"
        settings.claudeModelID = "claude-roundtrip-test"
        settings.librarySort = .title
        settings.preferVLCForAll = !settings.preferVLCForAll
        let preferVLC = settings.preferVLCForAll

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.doubleTapSeekSeconds, seek)
        XCTAssertEqual(reloaded.defaultRate, rate)
        XCTAssertEqual(reloaded.resumePlayback, resume)
        XCTAssertEqual(reloaded.subtitleStyle, style)
        XCTAssertEqual(reloaded.translationProviderID, "anthropic-claude")
        XCTAssertEqual(reloaded.claudeModelID, "claude-roundtrip-test")
        XCTAssertEqual(reloaded.librarySort, .title)
        XCTAssertEqual(reloaded.preferVLCForAll, preferVLC)
    }

    @MainActor
    func testSettingsDoNotLeakBetweenSuites() throws {
        let first = AppSettings(defaults: try makeDefaults())
        first.claudeModelID = "only-in-first-suite"
        let second = AppSettings(defaults: try makeDefaults())
        XCTAssertNotEqual(second.claudeModelID, "only-in-first-suite")
    }

    @MainActor
    func testUnknownSortValueFallsBackToADefault() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        settings.librarySortRaw = "not-a-sort"
        XCTAssertTrue(LibrarySort.allCases.contains(settings.librarySort))
    }
}
