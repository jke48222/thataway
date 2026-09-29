import XCTest
@testable import ThatawayKit
import ThatawayCore

final class LessonStoreTests: XCTestCase {

    func testSymlinksAndOversizedFilesAreSkipped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lessons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LessonStore(directory: dir)
        let lesson = Lesson(title: "Real one", steps: [
            Step(instruction: "Click Save", target: "the Save button", completion: .manual),
        ])
        let saved = try store.save(lesson)

        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("zero.json"),
            withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        let big = dir.appendingPathComponent("big.json")
        FileManager.default.createFile(atPath: big.path, contents: Data(count: 2_000_000))

        let listed = store.list()
        XCTAssertEqual(listed.map(\.title), ["Real one"])
        XCTAssertNil(store.load(dir.appendingPathComponent("zero.json")))
        XCTAssertNil(store.load(big))
        XCTAssertEqual(store.load(saved)?.title, "Real one")
    }
}
