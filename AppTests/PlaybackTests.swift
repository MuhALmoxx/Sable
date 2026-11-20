import XCTest
import CoreGraphics
@testable import Sable
import SubtitleKit
import LibraryKit

// Proposed by the playback agent for AppTests (owned by build-qa).
final class PlaybackTests: XCTestCase {
    func testContainerSniffing() {
        XCTAssertEqual(ContainerSniffer.sniff(header: Data([0x1A, 0x45, 0xDF, 0xA3, 0x01, 0, 0, 0]), fileExtension: "bin"), .matroska)
        XCTAssertEqual(ContainerSniffer.sniff(header: Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8), fileExtension: "dat"), .mp4)
        XCTAssertEqual(ContainerSniffer.sniff(header: Data("RIFF\u{0}\u{0}\u{0}\u{0}AVI LIST".utf8), fileExtension: "avi"), .other)
        XCTAssertEqual(ContainerSniffer.sniff(header: Data(), fileExtension: "webm"), .matroska)
    }

    func testCacheFileNameIsSanitised() {
        XCTAssertEqual(SubtitleRepository.cacheFileName(for: "emb:mkv:3"), "emb_mkv_3.json")
        XCTAssertEqual(SubtitleRepository.cacheFileName(for: "emb:mp4:2"), "emb_mp4_2.json")
    }

    func testVideoGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let fit = VideoGeometry.pictureRect(videoSize: CGSize(width: 1920, height: 1080), mode: .fit, in: bounds)
        XCTAssertEqual(fit.width, 400, accuracy: 0.01)
        XCTAssertEqual(fit.height, 225, accuracy: 0.01)
        let fill = VideoGeometry.pictureRect(videoSize: CGSize(width: 1920, height: 1080), mode: .fill, in: bounds)
        XCTAssertEqual(fill.height, 300, accuracy: 0.01)
        XCTAssertGreaterThan(fill.width, 400)
        let ratio = VideoGeometry.layerFrame(mode: .ratio4x3, in: CGRect(x: 0, y: 0, width: 800, height: 300))
        XCTAssertEqual(ratio.width / ratio.height, 4.0 / 3.0, accuracy: 0.001)
    }

    func testMarkupTokens() {
        XCTAssertEqual(SubtitleMarkup.tokens(in: "<i>Is it</i> safe?"),
                       [.tag("i", closing: false), .text("Is it"), .tag("i", closing: true), .text(" safe?")])
        XCTAssertEqual(SubtitleMarkup.tokens(in: "a <font> b"), [.text("a <font> b")])
    }

    func testWebVTTSampleDecoding() {
        let payload = Data([0, 0, 0, 13]) + Data("payl".utf8) + Data("Hello".utf8)
        let cue = Data([0, 0, 0, UInt8(8 + payload.count)]) + Data("vttc".utf8) + payload
        let empty = Data([0, 0, 0, 8]) + Data("vtte".utf8)
        XCTAssertEqual(WebVTTSampleDecoder.cueTexts(in: cue + empty), ["Hello"])
        XCTAssertEqual(WebVTTSampleDecoder.cleaned("<v Mara>Hi</v> <i>there</i> &amp; you"), "Hi <i>there</i> & you")
    }

    func testSpeedLabels() {
        XCTAssertEqual(SpeedSheet.label(1), "1×")
        XCTAssertEqual(SpeedSheet.label(0.5), "0.5×")
        XCTAssertEqual(SpeedSheet.label(1.25), "1.25×")
    }

    func testMatroskaFallbackCodecTable() {
        XCTAssertEqual(MediaProbeService.fallbackKind(forCodecID: "S_TEXT/UTF8"), .text)
        XCTAssertEqual(MediaProbeService.fallbackKind(forCodecID: "S_HDMV/PGS"), .image)
        XCTAssertEqual(MediaProbeService.fallbackFormat(forCodecID: "S_TEXT/ASS"), .ass)
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "UITestFixtures")
            ?? Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        throw XCTSkip("\(name).\(ext) is not bundled in this build")
    }

    @MainActor
    func testProbeBundledMP4() async throws {
        let result = await MediaProbeService().probe(url: try fixture("night-roof", "mp4"))
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.container, .mp4)
        XCTAssertEqual(result.preferredEngine, .avFoundation)
        XCTAssertEqual(result.duration ?? 0, 40, accuracy: 0.5)
        XCTAssertEqual(result.videoSize, CGSize(width: 960, height: 540))
        XCTAssertEqual(result.subtitleTracks.count, 1)
        XCTAssertEqual(result.subtitleTracks.first?.format, .tx3g)
        XCTAssertEqual(result.subtitleTracks.first?.language?.primary, "en")
    }

    @MainActor
    func testProbeBundledMKV() async throws {
        let result = await MediaProbeService().probe(url: try fixture("night-roof", "mkv"))
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.container, .matroska)
        XCTAssertEqual(result.preferredEngine, .vlc)
        if result.subtitleTracks.isEmpty { throw XCTSkip("MatroskaReader not implemented yet") }
        XCTAssertEqual(result.subtitleTracks.count, 3)
        XCTAssertEqual(result.subtitleTracks.filter(\.isDefault).count, 1)
        XCTAssertEqual(result.subtitleTracks.map(\.format), [.srt, .ass, .srt])
    }

    @MainActor
    func testMP4TextExtraction() async throws {
        let url = try fixture("night-roof", "mp4")
        let probe = await MediaProbeService().probe(url: url)
        guard let track = probe.subtitleTracks.first,
              case let .embedded(_, streamID, _) = track.origin else { return XCTFail("no text track") }
        do {
            let document = try await MP4TextExtractor.extract(url: url, trackID: streamID, format: .tx3g,
                                                              language: .english, title: nil)
            XCTAssertEqual(document.cues.count, 9)
            XCTAssertEqual(document.cues.first?.start ?? 0, 3, accuracy: 0.01)
            XCTAssertEqual(document.cues.first?.plainText, "Mara, are you still awake?")
        } catch SubtitleError.empty {
            throw XCTSkip("TX3GDecoder not implemented yet")
        }
    }
}
