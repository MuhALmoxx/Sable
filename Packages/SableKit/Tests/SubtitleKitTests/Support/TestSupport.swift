import Foundation
import XCTest
@testable import SubtitleKit

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") { return url }
        let local = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // SubtitleKitTests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        throw XCTSkip("fixture \(name) not found")
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func document(_ name: String) throws -> SubtitleDocument {
        try SubtitleParser.parse(data: data(name), fileExtension: URL(fileURLWithPath: name).pathExtension)
    }
}

extension XCTestCase {
    /// Writes bytes to a unique temporary file removed after the test.
    func temporaryFile(_ bytes: [UInt8], ext: String = "mkv") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sable-test-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Same timing (within 1 ms) and text; ids compared only when asked.
    func assertSameCues(_ actual: [SubtitleCue], _ expected: [SubtitleCue], compareIDs: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "cue count", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.start, e.start, accuracy: 0.001, "start of \(e.id)", file: file, line: line)
            XCTAssertEqual(a.end, e.end, accuracy: 0.001, "end of \(e.id)", file: file, line: line)
            XCTAssertEqual(a.text, e.text, "text of \(e.id)", file: file, line: line)
            if compareIDs { XCTAssertEqual(a.id, e.id, file: file, line: line) }
        }
    }
}

func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

func base64(_ s: String) -> [UInt8] { [UInt8](Data(base64Encoded: s) ?? Data()) }
