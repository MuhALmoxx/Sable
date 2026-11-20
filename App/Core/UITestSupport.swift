#if DEBUG
import Foundation

// OWNER: build/QA agent. DEBUG-only hooks driven by launch arguments from UITests:
//   -uiTesting            reset library on launch, disable animations
//   -seedLibrary          import bundled fixtures (UITestFixtures/*) into the library
//   -mockTranslation      register a deterministic offline translation provider (labelled as a mock)
enum UITestSupport {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var isUITesting: Bool { arguments.contains("-uiTesting") }
    static var useMockTranslation: Bool { arguments.contains("-mockTranslation") }

    /// Runs before AppServices is created (e.g. wipe the library for a clean test).
    static func prepareFileSystemIfNeeded(root: URL) {}

    /// Runs after AppServices is created (e.g. seed fixtures, install mock providers).
    @MainActor
    static func configure(_ services: AppServices) {}
}
#endif
