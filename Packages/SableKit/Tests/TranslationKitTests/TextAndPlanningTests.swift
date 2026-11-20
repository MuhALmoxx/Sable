import XCTest
import SubtitleKit
@testable import TranslationKit

final class TranslationContractTests: XCTestCase {
    func testArabicProfileExists() {
        XCTAssertEqual(TargetLanguages.arabic.code, .arabic)
        XCTAssertTrue(TargetLanguages.arabic.isRightToLeft)
        XCTAssertEqual(TargetLanguages.arabic.maxLineLength, 42)
    }
}

final class SHA256Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(SHA256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256.hex("The quick brown fox jumps over the lazy dog"),
                       "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
    }

    func testMillionAAndMultiByte() {
        var d = SHA256Digest()
        let chunk = [UInt8](repeating: 0x61, count: 1000)
        for _ in 0..<1000 { d.update(chunk) }
        XCTAssertEqual(d.hexDigest(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        // UTF-8 input; streaming update must equal one-shot.
        var a = SHA256Digest(); a.update("مارا، هل ما زلتِ مستيقظة؟")
        var b = SHA256Digest(); for ch in "مارا، هل ما زلتِ مستيقظة؟" { b.update(String(ch)) }
        XCTAssertEqual(a.hexDigest(), b.hexDigest())
    }

    func testCacheKeyDependsOnContentTargetProviderModel() {
        let doc = makeDocument(count: 3)
        let base = TranslationEngine.cacheKey(for: makeSpec(doc))
        XCTAssertEqual(base.count, 64)
        XCTAssertEqual(base, TranslationEngine.cacheKey(for: makeSpec(doc)))
        XCTAssertNotEqual(base, TranslationEngine.cacheKey(for: makeSpec(doc, model: "other")))
        XCTAssertNotEqual(base, TranslationEngine.cacheKey(for: makeSpec(doc, provider: "other")))
        var edited = doc
        edited.cues[1].end += 0.01
        XCTAssertNotEqual(base, TranslationEngine.cacheKey(for: makeSpec(edited)))
        var retitled = doc
        retitled.title = "Another title"
        XCTAssertEqual(base, TranslationEngine.cacheKey(for: makeSpec(retitled)), "title is not part of the content")
        // Chunking parameters do not change the result, so they are not part of the key.
        XCTAssertEqual(base, TranslationEngine.cacheKey(for: makeSpec(doc, chunkSize: 10, contextSize: 0)))
    }
}

final class ArabicPostProcessorTests: XCTestCase {
    func p(_ s: String, source: String = "x") -> String { ArabicPostProcessor.process(s, source: source) }

    func testPunctuationIsArabic() {
        XCTAssertEqual(p("مارا, هل ما زلتِ مستيقظة?"), "مارا، هل ما زلتِ مستيقظة؟")
        XCTAssertEqual(p("انتظر; لا تذهب"), "انتظر؛ لا تذهب")
        XCTAssertEqual(p("حقًا?!"), "حقًا؟!")
    }

    func testSpacingAroundPunctuation() {
        XCTAssertEqual(p("كيف حالك ؟"), "كيف حالك؟")
        XCTAssertEqual(p("مرحبًا ،كيف حالك"), "مرحبًا، كيف حالك")
        XCTAssertEqual(p("لا !"), "لا!")
    }

    func testNumbersURLsAndTagsUntouched() {
        XCTAssertEqual(p("دفعت 1,000 دولار, تقريبًا"), "دفعت 1,000 دولار، تقريبًا")
        XCTAssertEqual(p("زر www.example.com/a?b=1,2 الآن"), "زر www.example.com/a?b=1,2 الآن")
        XCTAssertEqual(p("<i>هل هو آمن?</i>"), "<i>هل هو آمن؟</i>")
        XCTAssertEqual(p("Hello, world?"), "Hello, world?", "Latin-only lines keep ASCII punctuation")
    }

    func testWhitespaceAndBidiControlsRemoved() {
        XCTAssertEqual(p("\u{200F}  مرحبًا    يا\u{200E} صديقي  \u{202B}"), "مرحبًا يا صديقي")
        XCTAssertEqual(p("السطر الأول\r\n\r\n  السطر الثاني "), "السطر الأول\nالسطر الثاني")
        XCTAssertEqual(p("السطر الأول\\nالسطر الثاني"), "السطر الأول\nالسطر الثاني", "literal \\n from a model becomes a break")
    }

    func testTagsBalancedOrStripped() {
        XCTAssertEqual(p("<I>مرحبًا</I>"), "<i>مرحبًا</i>")
        XCTAssertEqual(p("<i>مرحبًا"), "مرحبًا")
        XCTAssertEqual(p("<i>مرحبًا</b>"), "مرحبًا")
        XCTAssertEqual(p("<b>قف</b> <i></i>هنا"), "<b>قف</b> هنا")
        XCTAssertEqual(p("<i>سطر\nثانٍ</i>"), "<i>سطر\nثانٍ</i>")
    }

    func testWholeLineTagRestored() {
        XCTAssertEqual(p("هل هو آمن؟", source: "<i>Is it safe?</i>"), "<i>هل هو آمن؟</i>")
        XCTAssertEqual(p("هل هو آمن؟", source: "<i>Is</i> it safe?"), "هل هو آمن؟")
    }

    func testCapToTwoLinesAndRebalance() {
        let three = p("هذا هو السطر الأول من الحوار\nوهذا هو السطر الثاني منه\nوهذا هو الثالث")
        XCTAssertEqual(three.components(separatedBy: "\n").count, 2)
        XCTAssertEqual(three.replacingOccurrences(of: "\n", with: " "), "هذا هو السطر الأول من الحوار وهذا هو السطر الثاني منه وهذا هو الثالث")

        let long = "كل ضوء هناك في الأسفل هو حكاية أحدهم في هذه المدينة الكبيرة"
        let split = p(long).components(separatedBy: "\n")
        XCTAssertEqual(split.count, 2)
        XCTAssertLessThanOrEqual(abs(split[0].count - split[1].count), 8, "split near the middle")
        XCTAssertEqual(split.joined(separator: " "), long)

        XCTAssertEqual(p("قصير جدًا"), "قصير جدًا", "short lines stay on one line")
        XCTAssertEqual(p("- من هناك؟\n- أنا"), "- من هناك؟\n- أنا", "dialogue dashes keep their lines")
        XCTAssertEqual(p("سطر\nقصير\nثالث"), "سطر قصير ثالث", "three short lines merge into one")
    }

    func testGenericTargetSkipsArabicPunctuation() {
        let french = TargetLanguageProfile(code: LanguageCode("fr"), englishName: "French", nativeName: "Français",
                                           isRightToLeft: false, promptGuidance: "", maxLineLength: 42)
        XCTAssertEqual(TranslationPostProcessor.process("  Bonjour ,  Mara ? ", source: "Hi", target: french), "Bonjour , Mara ?")
    }

    func testPromptGuidanceCoversTheStyleGuide() {
        let g = TargetLanguages.arabic.promptGuidance
        for needle in ["Modern Standard Arabic", "42", "2 lines", "feminine", "glossary", "، ؛ ؟", "Western digits",
                       "<i>", "[door slams]", "fragments", "Never add notes"] {
            XCTAssertTrue(g.contains(needle), "guidance mentions \(needle)")
        }
        XCTAssertEqual(TargetLanguages.profile(for: LanguageCode("ar-EG"))?.code, .arabic)
    }
}

final class PlanningTests: XCTestCase {
    func testUnitTextAndPassThroughDetection() {
        let cue = SubtitleCue(id: "1", index: 0, start: 0, end: 1, text: "  <u>Look</u>  —\r\n <i>every</i> light ")
        XCTAssertEqual(TranslationText.unitText(for: cue), "Look —\n<i>every</i> light")
        XCTAssertFalse(TranslationText.needsTranslation(""))
        XCTAssertFalse(TranslationText.needsTranslation("♪ ♪"))
        XCTAssertFalse(TranslationText.needsTranslation("<i>...</i>"))
        XCTAssertTrue(TranslationText.needsTranslation("Hi"))
    }

    func testChunksAndContext() {
        var texts = (1...10).map { "Line \($0)." }
        texts[2] = "   " // cue 3 is empty
        let plan = TranslationPlan(document: makeDocument(texts), chunkSize: 4, contextSize: 2)
        XCTAssertEqual(plan.translatableItems.count, 9)
        XCTAssertEqual(plan.plannedChunkCount, 3)
        let chunks = plan.remainingChunks(completed: [:])
        XCTAssertEqual(chunks.map { $0.map(\.id) }, [["1", "2", "4", "5"], ["6", "7", "8", "9"], ["10"]])

        let completed = ["1": "سطر 1", "2": "سطر 2", "4": "سطر 4", "5": "سطر 5"]
        XCTAssertEqual(plan.remainingChunks(completed: completed).first?.map(\.id), ["6", "7", "8", "9"])
        let request = plan.request(for: chunks[1], completed: completed, glossary: Glossary(), source: .english,
                                   target: TargetLanguages.arabic, includeContext: true)
        XCTAssertEqual(request.units.map(\.id), ["6", "7", "8", "9"])
        XCTAssertEqual(request.precedingContext.map(\.id), ["4", "5"])
        XCTAssertEqual(request.precedingContext.map(\.translation), ["سطر 4", "سطر 5"])
        XCTAssertEqual(request.followingContext.map(\.id), ["10"])
        XCTAssertNil(request.followingContext.first?.translation)

        let noContext = plan.request(for: chunks[1], completed: completed, glossary: Glossary(), source: .english,
                                     target: TargetLanguages.arabic, includeContext: false)
        XCTAssertTrue(noContext.precedingContext.isEmpty && noContext.followingContext.isEmpty)
    }

    func testDuplicateCueIDsStayUnique() {
        var doc = makeDocument(["A b.", "C d.", "E f."])
        doc.cues[2].id = "1"
        let plan = TranslationPlan(document: doc, chunkSize: 10, contextSize: 0)
        XCTAssertEqual(Set(plan.items.map(\.id)).count, 3)
    }

    func testGlossaryMergeDedupeCapAndRelevance() {
        var g = Glossary(capacity: 3)
        g.merge([GlossaryEntry(source: "Mara", target: "مارا"), GlossaryEntry(source: "mara", target: "مارة"),
                 GlossaryEntry(source: "Idris", target: "إدريس"), GlossaryEntry(source: " ", target: "x"),
                 GlossaryEntry(source: "OK", target: "ok")])
        XCTAssertEqual(g.asEntries, [GlossaryEntry(source: "Mara", target: "مارا"), GlossaryEntry(source: "Idris", target: "إدريس")])
        XCTAssertEqual(g.entries.first?.hits, 2)
        g.merge([GlossaryEntry(source: "Night City", target: "مدينة الليل"), GlossaryEntry(source: "Hale", target: "هيل")])
        XCTAssertEqual(g.count, 3, "capped")
        XCTAssertTrue(g.asEntries.contains(GlossaryEntry(source: "Mara", target: "مارا")), "most used entry survives")
        XCTAssertEqual(g.relevant(to: "Then let's watch it together, MARA.").map(\.target), ["مارا"])
    }

    func testValidation() {
        let units = [TranslationUnit(id: "1", text: "Mara, are you awake?"), TranslationUnit(id: "2", text: "Trust me."),
                     TranslationUnit(id: "3", text: "Is it safe?"), TranslationUnit(id: "4", text: "Then let's go up.")]
        let response = TranslationChunkResponse(translations: ["1": "مارا, هل أنتِ مستيقظة?", "2": "  ", "3": "Is it safe?", "9": "زائد"])
        let v = ChunkValidator.validate(response, units: units, target: TargetLanguages.arabic)
        XCTAssertEqual(v.accepted, ["1": "مارا، هل أنتِ مستيقظة؟"])
        XCTAssertEqual(v.missing, ["2", "3", "4"], "empty, untranslated echo and absent ids are missing")
        XCTAssertEqual(v.unexpected, ["9"])
    }
}
