import XCTest
@testable import ScreenCoachKit
import ScreenCoachCore

final class ExclusionStoreTests: XCTestCase {

    private var dir: URL!
    private var url: URL!
    private let queue = DispatchQueue(label: "exclusion-store-tests")

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("excl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("exclusions.conf")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func eventually(_ timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    func testSeedsDefaultsOnlyWhenTheFileIsMissing() throws {
        let store = ExclusionStore(url: url, queue: queue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.check(bundleID: "com.1password.7", windowTitle: nil).excluded)

        try "bundle: com.mine.only\n".write(to: url, atomically: true, encoding: .utf8)
        let second = ExclusionStore(url: url, queue: queue)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bundle: com.mine.only\n")
        XCTAssertTrue(second.check(bundleID: "com.mine.only", windowTitle: nil).excluded)
    }

    /// Every save after the first used to be missed: the old watch's cancel
    /// handler closed the new watch's descriptor.
    func testEveryAtomicSaveIsReloaded() throws {
        let store = ExclusionStore(url: url, queue: queue)
        for i in 0..<5 {
            let bundle = "com.atomic.bank\(i)"
            try "bundle: \(bundle)\n".write(to: url, atomically: true, encoding: .utf8)
            XCTAssertTrue(eventually { store.check(bundleID: bundle, windowTitle: nil).excluded },
                          "save \(i + 1) was not picked up")
        }
    }

    func testRenameAwayThenCreateNeverWritesDefaultsOverTheUsersFile() throws {
        let store = ExclusionStore(url: url, queue: queue)
        let backup = dir.appendingPathComponent("exclusions.conf~")
        for i in 0..<5 {
            let bundle = "com.vim.bank\(i)"
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: url, to: backup)
            Thread.sleep(forTimeInterval: 0.003)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            Thread.sleep(forTimeInterval: 0.003)
            try "bundle: \(bundle)\n".write(to: url, atomically: false, encoding: .utf8)
            XCTAssertTrue(eventually { store.check(bundleID: bundle, windowTitle: nil).excluded },
                          "vim-style save \(i + 1) was not picked up")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bundle: \(bundle)\n",
                           "the watcher overwrote the user's file")
        }
    }

    func testANonUTF8ByteDoesNotDropTheUsersRules() throws {
        var data = Data("# Caf".utf8)
        data.append(0xE9)
        data.append(contentsOf: Data("\nbundle: com.mybank.app\ntitle: payroll\n".utf8))
        try data.write(to: url)
        let store = ExclusionStore(url: url, queue: queue)
        XCTAssertTrue(store.check(bundleID: "com.mybank.app", windowTitle: nil).excluded)
        XCTAssertTrue(store.check(bundleID: nil, windowTitle: "Payroll - Gusto").excluded)
        XCTAssertEqual(try Data(contentsOf: url), data, "the user's file was replaced")
    }

    /// A CRLF file (Windows editor, or copied from another machine) must
    /// load every rule. It used to parse as one line, and nothing matched.
    func testACRLFFileLoadsEveryRule() throws {
        try "# mine\r\nbundle: com.chase\r\ntitle: my bank\r\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let store = ExclusionStore(url: url, queue: queue)
        XCTAssertTrue(store.check(bundleID: "com.chase.app", windowTitle: nil).excluded)
        XCTAssertTrue(store.check(bundleID: nil, windowTitle: "My Bank - login").excluded)
    }

    func testAnUnreadableFileKeepsThePreviousRules() throws {
        try "bundle: com.keep.me\n".write(to: url, atomically: true, encoding: .utf8)
        let store = ExclusionStore(url: url, queue: queue)
        XCTAssertTrue(store.check(bundleID: "com.keep.me", windowTitle: nil).excluded)
        chmod(url.path, 0o000)
        defer { chmod(url.path, 0o644) }
        store.reload()
        XCTAssertTrue(store.check(bundleID: "com.keep.me", windowTitle: nil).excluded)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.statusLine.contains("previous rules kept"))
    }
}
