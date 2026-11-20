import XCTest
import Foundation
@testable import LibraryKit
import SubtitleKit

// OWNER: sync agent.
final class TimingStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("timing.json") }
    private let video = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let otherVideo = UUID(uuidString: "0E984725-C51C-4BF4-9960-E1C80E27ABA0")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimingStoreTests-\(UUID().uuidString)", isDirectory: true)
        // The store must create its parent directory itself, so do not create it here.
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func key(_ group: String = "emb:mkv:3", video: UUID? = nil) -> String {
        TimingStore.key(videoID: video ?? self.video, timingGroupID: group)
    }

    func testKeyFormat() {
        XCTAssertEqual(TimingStore.key(videoID: video, timingGroupID: "ext:abc"), "\(video.uuidString)|ext:abc")
    }

    func testDefaultsToIdentityAndNothingToUndo() {
        let store = TimingStore(fileURL: fileURL)
        XCTAssertEqual(store.timing(forKey: key()), .identity)
        XCTAssertFalse(store.canUndo(forKey: key()))
        XCTAssertNil(store.undo(forKey: key()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "reading must not create a file")
    }

    func testPersistsAcrossInstances() throws {
        do {
            let store = TimingStore(fileURL: fileURL)
            store.setTiming(SubtitleTiming(offset: 2.5), forKey: key())
            store.setTiming(SubtitleTiming(offset: -1.25, scale: 1.001), forKey: key("ext:1234"))
            XCTAssertNil(store.lastError)
        }
        // Simulated app restart: a brand-new instance reading the same file.
        let reopened = TimingStore(fileURL: fileURL)
        XCTAssertEqual(reopened.timing(forKey: key()), SubtitleTiming(offset: 2.5))
        XCTAssertEqual(reopened.timing(forKey: key("ext:1234")), SubtitleTiming(offset: -1.25, scale: 1.001))
        XCTAssertTrue(reopened.canUndo(forKey: key()))
        XCTAssertEqual(reopened.undo(forKey: key()), .identity)
        XCTAssertFalse(reopened.recoveredFromCorruptFile)

        let afterUndo = TimingStore(fileURL: fileURL)
        XCTAssertEqual(afterUndo.timing(forKey: key()), .identity, "undo is persisted too")
        XCTAssertFalse(afterUndo.canUndo(forKey: key()))
    }

    func testFileFormatIsVersionedJSON() throws {
        let store = TimingStore(fileURL: fileURL)
        store.setTiming(SubtitleTiming(offset: 1.3), forKey: key())
        store.setTiming(SubtitleTiming(offset: 1.4), forKey: key())
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, TimingStore.formatVersion)
        let entries = object?["entries"] as? [String: Any]
        let entry = entries?[key()] as? [String: Any]
        let timing = entry?["timing"] as? [String: Any]
        XCTAssertEqual(timing?["offset"] as? Double, 1.4)
        XCTAssertEqual(timing?["scale"] as? Double, 1)
        let undo = entry?["undo"] as? [[String: Any]]
        XCTAssertEqual(undo?.compactMap { $0["offset"] as? Double }, [0, 1.3])
    }

    func testUndoRestoresInReverseOrderExactly() {
        let store = TimingStore(fileURL: fileURL)
        let values: [SubtitleTiming] = [
            SubtitleTiming(offset: 0.1),
            SubtitleTiming(offset: 2.5),
            SubtitleTiming(offset: -75.5),
            SubtitleTiming(offset: 3.217, scale: 1.0010015),
        ]
        for value in values { store.setTiming(value, forKey: key()) }
        XCTAssertEqual(store.timing(forKey: key()), values[3])
        XCTAssertEqual(store.undoDepth(forKey: key()), 4)
        XCTAssertEqual(store.undo(forKey: key()), values[2])
        XCTAssertEqual(store.timing(forKey: key()), values[2])
        XCTAssertEqual(store.undo(forKey: key()), values[1])
        XCTAssertEqual(store.undo(forKey: key()), values[0])
        XCTAssertEqual(store.undo(forKey: key()), .identity)
        XCTAssertNil(store.undo(forKey: key()))
        XCTAssertFalse(store.canUndo(forKey: key()))
    }

    func testUnchangedValueDoesNotPushUndo() {
        let store = TimingStore(fileURL: fileURL)
        store.setTiming(SubtitleTiming(offset: 1), forKey: key())
        store.setTiming(SubtitleTiming(offset: 1), forKey: key())
        store.setTiming(SubtitleTiming(offset: 1.0001), forKey: key()) // below the 0.5 ms resolution
        XCTAssertEqual(store.undoDepth(forKey: key()), 1)
        store.setTiming(.identity, forKey: key("other"))
        XCTAssertFalse(store.canUndo(forKey: key("other")), "setting identity on a fresh key changes nothing")
    }

    func testNonUndoableSetKeepsHistory() {
        let store = TimingStore(fileURL: fileURL)
        store.setTiming(SubtitleTiming(offset: 1), forKey: key())
        store.setTiming(SubtitleTiming(offset: 1.5), forKey: key(), undoable: false)
        store.setTiming(SubtitleTiming(offset: 1.6), forKey: key(), undoable: false)
        XCTAssertEqual(store.undoDepth(forKey: key()), 1)
        XCTAssertEqual(store.undo(forKey: key()), .identity)
    }

    func testUndoStackIsCappedAtFifty() {
        let store = TimingStore(fileURL: fileURL)
        for i in 1...60 { store.setTiming(SubtitleTiming(offset: Double(i)), forKey: key()) }
        XCTAssertEqual(store.undoDepth(forKey: key()), TimingStore.undoLimit)
        XCTAssertEqual(TimingStore.undoLimit, 50)
        var restored: [Double] = []
        while let previous = store.undo(forKey: key()) { restored.append(previous.offset) }
        // The 50 most recent previous values survive: 59, 58, ... 10. The oldest (0...9) are gone.
        XCTAssertEqual(restored, (10...59).reversed().map(Double.init))
        XCTAssertEqual(store.timing(forKey: key()).offset, 10)

        // The cap also holds for what is read back from disk.
        for i in 1...55 { store.setTiming(SubtitleTiming(offset: Double(100 + i)), forKey: key()) }
        XCTAssertEqual(TimingStore(fileURL: fileURL).undoDepth(forKey: key()), 50)
    }

    func testResetIsUndoable() {
        let store = TimingStore(fileURL: fileURL)
        let tuned = SubtitleTiming(offset: -2.345, scale: 0.999)
        store.setTiming(tuned, forKey: key())
        store.reset(forKey: key())
        XCTAssertEqual(store.timing(forKey: key()), .identity)
        XCTAssertTrue(store.canUndo(forKey: key()))
        XCTAssertEqual(TimingStore(fileURL: fileURL).timing(forKey: key()), .identity)
        XCTAssertEqual(store.undo(forKey: key()), tuned)
        XCTAssertEqual(store.timing(forKey: key()), tuned)
        XCTAssertEqual(TimingStore(fileURL: fileURL).timing(forKey: key()), tuned)
    }

    func testResetOfIdentityIsNoOp() {
        let store = TimingStore(fileURL: fileURL)
        store.reset(forKey: key())
        XCTAssertFalse(store.canUndo(forKey: key()))
    }

    func testRemoveAllForVideoKeepsOtherVideos() {
        let store = TimingStore(fileURL: fileURL)
        store.setTiming(SubtitleTiming(offset: 1), forKey: key("emb:mkv:3"))
        store.setTiming(SubtitleTiming(offset: 2), forKey: key("ext:A"))
        store.setTiming(SubtitleTiming(offset: 3), forKey: key("emb:mkv:3", video: otherVideo))
        store.removeAll(videoID: video)
        XCTAssertEqual(store.timing(forKey: key("emb:mkv:3")), .identity)
        XCTAssertEqual(store.timing(forKey: key("ext:A")), .identity)
        XCTAssertFalse(store.canUndo(forKey: key("ext:A")), "history goes too")
        XCTAssertEqual(store.timing(forKey: key("emb:mkv:3", video: otherVideo)).offset, 3)

        let reopened = TimingStore(fileURL: fileURL)
        XCTAssertEqual(reopened.allKeys, [key("emb:mkv:3", video: otherVideo)])
    }

    func testTenthIncrementsRoundTripExactly() {
        let store = TimingStore(fileURL: fileURL)
        // What the player does for a +0.1 s tap followed by a −0.1 s tap.
        store.setTiming(store.timing(forKey: key()).shifted(by: 0.1), forKey: key())
        XCTAssertEqual(store.timing(forKey: key()).offset, 0.1)
        store.setTiming(store.timing(forKey: key()).shifted(by: -0.1), forKey: key())
        XCTAssertEqual(store.timing(forKey: key()).offset, 0.0)
        XCTAssertEqual(store.timing(forKey: key()).offset.sign, .plus, "no negative zero (would display as −0.000)")

        // Thirty taps up and thirty down end exactly where they started, also after a reload.
        for _ in 0..<30 { store.setTiming(store.timing(forKey: key()).shifted(by: 0.1), forKey: key()) }
        XCTAssertEqual(store.timing(forKey: key()).offset, 3.0)
        XCTAssertEqual(TimingStore(fileURL: fileURL).timing(forKey: key()).offset, 3.0)
        for _ in 0..<30 { store.setTiming(store.timing(forKey: key()).shifted(by: -0.1), forKey: key()) }
        XCTAssertEqual(store.timing(forKey: key()).offset, 0.0)

        // Values written and read back are bit-identical.
        let odd = SubtitleTiming(offset: 1.3, scale: 1.0010015015015015)
        store.setTiming(odd, forKey: key("odd"))
        XCTAssertEqual(TimingStore(fileURL: fileURL).timing(forKey: key("odd")), odd)
    }

    func testNegativeZeroIsNormalised() {
        let store = TimingStore(fileURL: fileURL)
        store.setTiming(SubtitleTiming(offset: 1), forKey: key())
        store.setTiming(SubtitleTiming(offset: -0.0), forKey: key())
        XCTAssertEqual(store.timing(forKey: key()).offset.sign, .plus)
        XCTAssertEqual(TimingStore(fileURL: fileURL).timing(forKey: key()).offset.sign, .plus)
    }

    func testCorruptFileStartsEmptyAndKeepsBackup() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{ \"version\": 1, \"entries\": { broken".utf8)
        try garbage.write(to: fileURL)

        let store = TimingStore(fileURL: fileURL)
        XCTAssertTrue(store.recoveredFromCorruptFile)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.allKeys, [])
        XCTAssertEqual(try Data(contentsOf: store.corruptBackupURL), garbage, "the unreadable file is preserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        // The store keeps working and writes a fresh, valid file.
        store.setTiming(SubtitleTiming(offset: 0.5), forKey: key())
        let reopened = TimingStore(fileURL: fileURL)
        XCTAssertFalse(reopened.recoveredFromCorruptFile)
        XCTAssertEqual(reopened.timing(forKey: key()).offset, 0.5)
    }

    func testWrongShapeJSONIsTreatedAsCorrupt() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("[1, 2, 3]".utf8).write(to: fileURL)
        let store = TimingStore(fileURL: fileURL)
        XCTAssertTrue(store.recoveredFromCorruptFile)
        XCTAssertEqual(store.timing(forKey: key()), .identity)
    }

    func testEmptyFileIsTolerated() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: fileURL)
        let store = TimingStore(fileURL: fileURL)
        XCTAssertFalse(store.recoveredFromCorruptFile)
        XCTAssertEqual(store.allKeys, [])
        store.setTiming(SubtitleTiming(offset: 1), forKey: key())
        XCTAssertEqual(TimingStore(fileURL: fileURL).timing(forKey: key()).offset, 1)
    }

    func testInvalidValuesAreRejected() {
        let store = TimingStore(fileURL: fileURL)
        store.setTiming(SubtitleTiming(offset: .nan), forKey: key())
        store.setTiming(SubtitleTiming(offset: .infinity), forKey: key())
        store.setTiming(SubtitleTiming(offset: 1, scale: 0), forKey: key())
        store.setTiming(SubtitleTiming(offset: 1, scale: -1), forKey: key())
        XCTAssertEqual(store.timing(forKey: key()), .identity)
        XCTAssertFalse(store.canUndo(forKey: key()))
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testUndoAfterPushingSameValueTwiceAcrossKeysIsIndependent() {
        let store = TimingStore(fileURL: fileURL)
        store.setTiming(SubtitleTiming(offset: 1), forKey: key("a"))
        store.setTiming(SubtitleTiming(offset: 9), forKey: key("b"))
        store.setTiming(SubtitleTiming(offset: 2), forKey: key("a"))
        XCTAssertEqual(store.undo(forKey: key("b")), .identity)
        XCTAssertEqual(store.timing(forKey: key("a")).offset, 2)
        XCTAssertEqual(store.undo(forKey: key("a"))?.offset, 1)
    }
}
