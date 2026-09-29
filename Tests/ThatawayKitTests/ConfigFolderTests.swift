import XCTest
@testable import ThatawayKit

final class ConfigFolderTests: XCTestCase {

    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("thataway-config-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    private func write(_ text: String, to relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testTheOldFolderMovesIntoPlaceWithItsRules() throws {
        try write("bundle: com.example.bank\n", to: ".config/screencoach/exclusions.conf")
        try write("{}", to: ".config/screencoach/lessons/intro.json")

        let folder = ConfigFolder.resolve(home: home)

        XCTAssertEqual(folder.lastPathComponent, "thataway")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("exclusions.conf"), encoding: .utf8),
                       "bundle: com.example.bank\n")
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("lessons/intro.json").path))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".config/screencoach").path))
    }

    func testAnExistingNewFolderIsNeverReplaced() throws {
        try write("bundle: com.example.new\n", to: ".config/thataway/exclusions.conf")
        try write("bundle: com.example.old\n", to: ".config/screencoach/exclusions.conf")

        let folder = ConfigFolder.resolve(home: home)

        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("exclusions.conf"), encoding: .utf8),
                       "bundle: com.example.new\n")
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".config/screencoach/exclusions.conf").path))
    }

    func testAFreshInstallCreatesNothing() {
        let folder = ConfigFolder.resolve(home: home)

        XCTAssertEqual(folder.path, home.appendingPathComponent(".config/thataway").path)
        XCTAssertFalse(fm.fileExists(atPath: folder.path))
    }

    func testAFileWithTheOldNameIsLeftAlone() throws {
        try write("not a folder", to: ".config/screencoach")

        let folder = ConfigFolder.resolve(home: home)

        XCTAssertFalse(fm.fileExists(atPath: folder.path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".config/screencoach").path))
    }
}
