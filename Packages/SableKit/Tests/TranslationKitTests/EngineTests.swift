import XCTest
import SubtitleKit
@testable import TranslationKit

final class EngineTests: XCTestCase {
    private func engine(_ dir: URL = temporaryDirectory(), sleeps: Recorder<TimeInterval>? = nil) -> TranslationEngine {
        let recorder = sleeps
        return TranslationEngine(storeDirectory: dir, sleep: { seconds in recorder?.add(seconds) })
    }

    func testHappyPathPreservesIDsTimingStyleAndReportsProgress() async throws {
        let doc = makeDocument(count: 10)
        let provider = FakeProvider()
        let progress = Recorder<TranslationProgress>()
        let result = try await engine().run(makeSpec(doc), provider: provider, progress: { progress.add($0) })

        XCTAssertEqual(result.cues.map(\.id), doc.cues.map(\.id))
        XCTAssertEqual(result.cues.map(\.start), doc.cues.map(\.start))
        XCTAssertEqual(result.cues.map(\.end), doc.cues.map(\.end))
        XCTAssertEqual(result.cues.map(\.index), doc.cues.map(\.index))
        XCTAssertEqual(result.cues.map(\.style), doc.cues.map(\.style))
        XCTAssertTrue(result.cues.allSatisfy { $0.rawText == nil })
        XCTAssertEqual(result.cues.first?.text, "سطر 1")
        XCTAssertEqual(result.language, .arabic)
        XCTAssertEqual(result.format, .srt)
        XCTAssertEqual(result.title, "Night Roof — Arabic")
        XCTAssertNil(result.header)

        XCTAssertEqual(provider.callCount, 3, "10 cues in chunks of 4")
        let counts = progress.items.map(\.completedCues)
        XCTAssertEqual(counts.first, 0)
        XCTAssertEqual(counts.last, 10)
        XCTAssertEqual(counts, counts.sorted(), "monotonic")
        XCTAssertTrue(progress.items.contains { $0.completedCues == 4 && $0.completedChunks == 1 && $0.totalChunks == 3 })
        XCTAssertEqual(progress.items.last?.usage, TokenUsage(inputTokens: 300, outputTokens: 150))
        XCTAssertEqual(progress.items.last?.requestsSent, 3)
    }

    func testEmptyCuesPassThroughWithoutRequest() async throws {
        let doc = makeDocument(["Hello there.", "", "♪ ♪", "Goodbye now."])
        let provider = FakeProvider()
        let result = try await engine().run(makeSpec(doc, chunkSize: 10), provider: provider, progress: { _ in })
        XCTAssertEqual(provider.requestedIDs, ["1", "4"])
        XCTAssertEqual(result.cues.map(\.text), ["سطر 1", "", "♪ ♪", "سطر 4"])
    }

    func testNothingToTranslate() async {
        do {
            _ = try await engine().run(makeSpec(makeDocument(["", " "])), provider: FakeProvider(), progress: { _ in })
            XCTFail("expected nothingToTranslate")
        } catch {
            XCTAssertEqual(error as? TranslationError, .nothingToTranslate)
        }
    }

    func testRepairRequestsOnlyMissingIDsWithContext() async throws {
        let doc = makeDocument(count: 4)
        let provider = FakeProvider { call, request in
            call == 1 ? FakeProvider.arabic(for: request, dropping: ["3"]) : FakeProvider.arabic(for: request)
        }
        let progress = Recorder<TranslationProgress>()
        let result = try await engine().run(makeSpec(doc), provider: provider, progress: { progress.add($0) })
        XCTAssertEqual(provider.callCount, 2)
        let repair = provider.requests[1]
        XCTAssertEqual(repair.units.map(\.id), ["3"])
        XCTAssertEqual(repair.precedingContext.map(\.id), ["1", "2"])
        XCTAssertEqual(repair.precedingContext.map(\.translation), ["سطر 1", "سطر 2"], "context carries known translations")
        XCTAssertEqual(repair.followingContext.map(\.id), ["4"])
        XCTAssertEqual(result.cues[2].text, "سطر 3")
        XCTAssertEqual(progress.items.last?.repairRequests, 1)
    }

    func testUnexpectedIDsAreIgnoredAndReported() async throws {
        let provider = FakeProvider { _, request in
            var r = FakeProvider.arabic(for: request)
            r.translations["999"] = "زائد"
            return r
        }
        let progress = Recorder<TranslationProgress>()
        let result = try await engine().run(makeSpec(makeDocument(count: 2)), provider: provider, progress: { progress.add($0) })
        XCTAssertEqual(result.cues.count, 2)
        XCTAssertEqual(progress.items.last?.ignoredUnexpectedIDs, 1)
    }

    func testPersistentGapsSplitTheChunkInHalves() async throws {
        // The provider loses the last unit whenever it gets more than two at once.
        let provider = FakeProvider { _, request in
            request.units.count > 2 ? FakeProvider.arabic(for: request, dropping: [request.units.last!.id]) : FakeProvider.arabic(for: request)
        }
        let doc = makeDocument(count: 8)
        let result = try await engine().run(makeSpec(doc, chunkSize: 8), provider: provider, progress: { _ in })
        XCTAssertEqual(result.cues.map(\.text), (1...8).map { "سطر \($0)" })
        XCTAssertTrue(provider.requests.contains { $0.units.count <= 2 }, "split into smaller requests")
    }

    func testMalformedResponseSplitsImmediately() async throws {
        let provider = FakeProvider { _, request in
            if request.units.count > 2 { throw TranslationError.malformedResponse("The reply was cut off (max_tokens).") }
            return FakeProvider.arabic(for: request)
        }
        let result = try await engine().run(makeSpec(makeDocument(count: 4)), provider: provider, progress: { _ in })
        XCTAssertEqual(result.cues.count, 4)
        XCTAssertEqual(provider.requests.map(\.units.count), [4, 2, 2])
    }

    func testSingleFailingCueFailsWithMappingMismatchAndKeepsCheckpoint() async throws {
        let provider = FakeProvider { _, request in FakeProvider.arabic(for: request, dropping: ["6"]) }
        let dir = temporaryDirectory()
        let e = engine(dir)
        let spec = makeSpec(makeDocument(count: 8))
        do {
            _ = try await e.run(spec, provider: provider, progress: { _ in })
            XCTFail("expected mappingMismatch")
        } catch let TranslationError.mappingMismatch(missing, _) {
            XCTAssertEqual(missing, ["6"])
        }
        let checkpoint = await e.checkpointProgress(for: spec)
        XCTAssertEqual(checkpoint?.completedCues, 4, "first chunk is kept for resume")
        let cached = await e.cachedResult(for: spec)
        XCTAssertNil(cached)
    }

    func testGlossaryPropagatesToLaterChunks() async throws {
        let provider = FakeProvider { call, request in
            call == 1 ? FakeProvider.arabic(for: request, names: [GlossaryEntry(source: "Mara", target: "مارا")])
                : FakeProvider.arabic(for: request)
        }
        _ = try await engine().run(makeSpec(makeDocument(count: 8)), provider: provider, progress: { _ in })
        XCTAssertTrue(provider.requests[0].glossary.isEmpty)
        XCTAssertEqual(provider.requests[1].glossary, [GlossaryEntry(source: "Mara", target: "مارا")])
    }

    func testCancellationMidJobThenResumeSkipsCompletedIDs() async throws {
        let dir = temporaryDirectory()
        let spec = makeSpec(makeDocument(count: 12))
        let blocking = FakeProvider { call, request in
            if call >= 3 { try await Task.sleep(nanoseconds: 30_000_000_000) }
            return FakeProvider.arabic(for: request)
        }
        let first = engine(dir)
        let task = Task { try await first.run(spec, provider: blocking, progress: { _ in }) }
        let deadline = Date().addingTimeInterval(10)
        while blocking.callCount < 3, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        let saved = await first.checkpointProgress(for: spec)
        XCTAssertEqual(saved?.completedCues, 8)
        XCTAssertEqual(saved?.completedChunks, 2)
        XCTAssertEqual(saved?.totalChunks, 3)

        // A new engine instance (as after an app relaunch) resumes from the checkpoint.
        let resumed = FakeProvider()
        let progress = Recorder<TranslationProgress>()
        let result = try await engine(dir).run(spec, provider: resumed, progress: { progress.add($0) })
        XCTAssertEqual(resumed.requestedIDs, ["9", "10", "11", "12"], "completed ids are not translated again")
        XCTAssertEqual(progress.items.first?.completedCues, 8)
        XCTAssertEqual(result.cues.map(\.text), (1...12).map { "سطر \($0)" })
        let after = await engine(dir).checkpointProgress(for: spec)
        XCTAssertNil(after, "checkpoint removed after success")
    }

    func testCacheHitAvoidsProviderCalls() async throws {
        let dir = temporaryDirectory()
        let spec = makeSpec(makeDocument(count: 5))
        let original = try await engine(dir).run(spec, provider: FakeProvider(), progress: { _ in })
        let failing = FakeProvider { _, _ in throw TranslationError.invalidAPIKey }
        let e = engine(dir)
        let cachedDoc = await e.cachedResult(for: spec)
        XCTAssertEqual(cachedDoc, original)
        let again = try await e.run(spec, provider: failing, progress: { _ in })
        XCTAssertEqual(again, original)
        XCTAssertEqual(failing.callCount, 0)
        await e.discardCachedResult(for: spec)
        let gone = await e.cachedResult(for: spec)
        XCTAssertNil(gone)
    }

    func testRateLimitAndServerErrorsRetryWithBackoff() async throws {
        let sleeps = Recorder<TimeInterval>()
        let provider = FakeProvider { call, request in
            switch call {
            case 1: throw TranslationError.rateLimited(retryAfter: 7)
            case 2: throw TranslationError.rateLimited(retryAfter: nil)
            case 3: throw TranslationError.server(status: 529, message: "Overloaded")
            default: return FakeProvider.arabic(for: request)
            }
        }
        let result = try await engine(sleeps: sleeps).run(makeSpec(makeDocument(count: 2)), provider: provider, progress: { _ in })
        XCTAssertEqual(result.cues.count, 2)
        XCTAssertEqual(sleeps.items, [7, 4, 8])
    }

    func testRetriesGiveUpAfterFourTries() async throws {
        let sleeps = Recorder<TimeInterval>()
        let provider = FakeProvider { _, _ in throw TranslationError.network("offline") }
        do {
            _ = try await engine(sleeps: sleeps).run(makeSpec(makeDocument(count: 2)), provider: provider, progress: { _ in })
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? TranslationError, .network("offline"))
        }
        XCTAssertEqual(provider.callCount, 4)
        XCTAssertEqual(sleeps.items, [2, 4, 8])
    }

    func testFatalErrorsFailImmediately() async throws {
        for fatal in [TranslationError.invalidAPIKey, .quotaExceeded, .refused("no"), .server(status: 400, message: "bad")] {
            let sleeps = Recorder<TimeInterval>()
            let provider = FakeProvider { _, _ in throw fatal }
            do {
                _ = try await engine(sleeps: sleeps).run(makeSpec(makeDocument(count: 2)), provider: provider, progress: { _ in })
                XCTFail("expected \(fatal)")
            } catch {
                XCTAssertEqual(error as? TranslationError, fatal)
            }
            XCTAssertEqual(provider.callCount, 1)
            XCTAssertTrue(sleeps.items.isEmpty)
        }
    }

    func testLongRetryAfterFailsInsteadOfWaiting() async throws {
        let provider = FakeProvider { _, _ in throw TranslationError.rateLimited(retryAfter: 900) }
        do {
            _ = try await engine().run(makeSpec(makeDocument(count: 2)), provider: provider, progress: { _ in })
            XCTFail("expected rate limit")
        } catch {
            XCTAssertEqual(error as? TranslationError, .rateLimited(retryAfter: 900))
        }
        XCTAssertEqual(provider.callCount, 1)
    }

    func testEstimateSanity() async throws {
        let dir = temporaryDirectory()
        let doc = makeDocument(count: 840)
        let spec = makeSpec(doc, chunkSize: 40, contextSize: 6)
        let e = engine(dir)
        let estimate = await e.estimate(for: spec)
        XCTAssertEqual(estimate.cueCount, 840)
        XCTAssertEqual(estimate.requestCount, 21)
        XCTAssertEqual(estimate.characterCount, doc.cues.reduce(0) { $0 + $1.text.count })
        let sourceTokens = Double(estimate.characterCount) / 3.5
        XCTAssertGreaterThan(Double(estimate.estimatedInputTokens), sourceTokens + Double(21 * TranslationEngine.promptOverheadTokens))
        XCTAssertLessThan(Double(estimate.estimatedInputTokens), sourceTokens * 4 + Double(21 * 2_500))
        XCTAssertGreaterThan(Double(estimate.estimatedOutputTokens), Double(estimate.characterCount) * 1.3 / 3)
        let range = estimate.costRange(inputPricePerMTok: 4, outputPricePerMTok: 20)
        XCTAssertGreaterThan(range.lowerBound, 0)
        XCTAssertGreaterThan(range.upperBound, range.lowerBound)
        XCTAssertLessThan(range.upperBound, 5, "a feature-length track costs dollars at most, not tens")

        let small = await e.estimate(for: makeSpec(makeDocument(count: 40), chunkSize: 40, contextSize: 6))
        XCTAssertEqual(small.requestCount, 1)
        XCTAssertLessThan(small.estimatedInputTokens, estimate.estimatedInputTokens)
    }

    func testEstimateCountsOnlyRemainingWorkAfterCheckpoint() async throws {
        let dir = temporaryDirectory()
        let spec = makeSpec(makeDocument(count: 12))
        let provider = FakeProvider { call, request in
            if call == 2 { throw TranslationError.invalidAPIKey }
            return FakeProvider.arabic(for: request)
        }
        let e = engine(dir)
        _ = try? await e.run(spec, provider: provider, progress: { _ in })
        let remaining = await e.estimate(for: spec)
        XCTAssertEqual(remaining.cueCount, 8)
        XCTAssertEqual(remaining.requestCount, 2)
        await e.discardCheckpoint(for: spec)
        let fresh = await e.estimate(for: spec)
        XCTAssertEqual(fresh.cueCount, 12)
    }

    func testProviderWithoutContextGetsNoContextOrGlossary() async throws {
        let provider = FakeProvider(usesContext: false) { _, request in
            FakeProvider.arabic(for: request, names: [GlossaryEntry(source: "Mara", target: "مارا")])
        }
        _ = try await engine().run(makeSpec(makeDocument(count: 8)), provider: provider, progress: { _ in })
        XCTAssertTrue(provider.requests.allSatisfy { $0.precedingContext.isEmpty && $0.followingContext.isEmpty && $0.glossary.isEmpty })
    }
}
