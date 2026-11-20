import XCTest
@testable import LibraryKit
import SubtitleKit

final class LibraryFileNamingTests: XCTestCase {
    func testTitles() {
        XCTAssertEqual(LibraryFileNaming.title(fromFileName: "The.Night_Roof.2024.mkv"), "The Night Roof 2024")
        XCTAssertEqual(LibraryFileNaming.title(fromFileName: "night-roof.mp4"), "night-roof")
        XCTAssertEqual(LibraryFileNaming.title(fromFileName: "__a..b__.avi"), "a b")
        XCTAssertEqual(LibraryFileNaming.title(fromFileName: "Mr. Smith  Goes.mov"), "Mr Smith Goes")
        XCTAssertEqual(LibraryFileNaming.title(fromFileName: "..._.mkv"), "..._")
        XCTAssertEqual(LibraryFileNaming.title(fromFileName: "noext"), "noext")
    }

    func testUniqueFileName() {
        var taken: Set<String> = []
        func next(_ name: String) -> String {
            let n = LibraryFileNaming.uniqueFileName(name) { taken.contains($0) }
            taken.insert(n)
            return n
        }
        XCTAssertEqual(next("a.mkv"), "a.mkv")
        XCTAssertEqual(next("a.mkv"), "a (2).mkv")
        XCTAssertEqual(next("a.mkv"), "a (3).mkv")
        XCTAssertEqual(next("README"), "README")
        XCTAssertEqual(next("README"), "README (2)")
    }

    func testSanitizedFileName() {
        XCTAssertEqual(LibraryFileNaming.sanitizedFileName(".hidden.mkv"), "hidden.mkv")
        XCTAssertEqual(LibraryFileNaming.sanitizedFileName("a/b:c.mkv"), "a-b-c.mkv")
        XCTAssertEqual(LibraryFileNaming.sanitizedFileName(".mkv", fallbackExtension: "mkv"), "file.mkv")
        let long = String(repeating: "x", count: 300) + ".mkv"
        let cut = LibraryFileNaming.sanitizedFileName(long)
        XCTAssertLessThanOrEqual(cut.utf8.count, 200)
        XCTAssertTrue(cut.hasSuffix(".mkv"))
    }

    func testSafeComponent() {
        XCTAssertEqual(LibraryFileNaming.safeComponent("tr:ar:emb:mkv:3"), "tr_ar_emb_mkv_3")
        XCTAssertEqual(LibraryFileNaming.safeComponent("ext:AB-12"), "ext_AB-12")
    }

    func testFileKinds() {
        XCTAssertEqual(LibraryFileNaming.kind(ofFileExtension: "MKV"), .video)
        XCTAssertEqual(LibraryFileNaming.kind(ofFileExtension: "mp4"), .video)
        XCTAssertEqual(LibraryFileNaming.kind(ofFileExtension: "srt"), .subtitle)
        XCTAssertEqual(LibraryFileNaming.kind(ofFileExtension: "ASS"), .subtitle)
        XCTAssertEqual(LibraryFileNaming.kind(ofFileExtension: "pdf"), .unknown)
    }

    func testLanguageGuessing() {
        let cases: [(String, String?)] = [
            ("movie.ar.srt", "ar"),
            ("movie.eng.srt", "en"),
            ("movie.en-US.srt", "en-US"),
            ("movie.pt_br.srt", "pt-BR"),
            ("movie.zh-hans.srt", "zh-Hans"),
            ("movie.es-419.vtt", "es-419"),
            ("movie.ara.ass", "ar"),
            ("movie.fre.srt", "fr"),
            ("movie.cze.srt", "cs"),
            ("movie.en.forced.srt", "en"),
            ("movie.en.sdh.srt", "en"),
            ("movie.en.hi.srt", "en"),
            ("movie.hi.srt", "hi"),
            ("Movie.2024.1080p.English.srt", "en"),
            ("night-roof.late.en.srt", "en"),
            ("Movie_English.srt", "en"),
            ("movie-eng.srt", "en"),
            ("movie_ar.srt", "ar"),
            ("Movie Arabic.srt", "ar"),
            ("movie.srt", nil),
            ("movie.final.srt", nil),
            ("movie.2.srt", nil),
            ("movie.v2.srt", nil),
            ("the_end.srt", nil),
            ("en.srt", nil),
            ("movie.und.srt", nil),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(LibraryFileNaming.guessLanguage(fromFileName: name)?.rawValue, expected, name)
        }
    }

    func testGuessedLanguagesAreNormalized() {
        XCTAssertEqual(LibraryFileNaming.guessLanguage(fromFileName: "x.ARA.srt"), .arabic)
        XCTAssertEqual(LibraryFileNaming.guessLanguage(fromFileName: "x.EN.srt"), .english)
        XCTAssertEqual(LibraryFileNaming.guessLanguage(fromFileName: "x.en-US.srt")?.primary, "en")
        XCTAssertTrue(LibraryFileNaming.guessLanguage(fromFileName: "x.ar.srt")?.isRightToLeft ?? false)
    }
}
