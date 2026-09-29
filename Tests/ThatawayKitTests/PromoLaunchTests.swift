// The parser and the stage exist in Debug builds only.
#if DEBUG

import XCTest
@testable import ThatawayKit

/// The promo stage (`Sources/ThatawayApp/Promo/`) draws fictional windows and
/// a scripted pointer for the README and site. It must never be what a person
/// gets when they open the app, so these tests pin both halves of the rule:
/// the parser only leaves `.normal` for an explicit flag in a Debug build,
/// and the stage's source is compiled out of Release and hooked in before
/// the app delegate exists.
final class PromoLaunchTests: XCTestCase {

    private let exe = "/Applications/Thataway.app/Contents/MacOS/ThatawayApp"

    func testNoFlagIsANormalLaunch() {
        for debug in [true, false] {
            XCTAssertEqual(PromoLaunch.parse([exe], debugBuild: debug), .normal)
            XCTAssertEqual(PromoLaunch.parse([], debugBuild: debug), .normal)
        }
    }

    func testOtherLaunchArgumentsAreANormalLaunch() {
        let launches: [[String]] = [
            [exe, "-psn_0_12345"],
            [exe, "-NSDocumentRevisionsDebugMode", "YES"],
            [exe, "--selftest", "the close button", "--app", "Finder"],
            [exe, "--lessontest"],
            [exe, "--idlebench", "60", "--force-active"],
            // Near misses must not count as the flag.
            [exe, "--promotion"], [exe, "promo"], [exe, "--promo-stillsx", "/tmp/x"],
            [exe, "--PROMO", "/tmp/x"], [exe, "-promo", "/tmp/x"],
        ]
        for args in launches {
            XCTAssertEqual(PromoLaunch.parse(args, debugBuild: true), .normal, "\(args)")
            XCTAssertEqual(PromoLaunch.parse(args, debugBuild: false), .normal, "\(args)")
        }
    }

    func testReleaseBuildNeverEntersTheStage() {
        let flagged: [[String]] = [
            [exe, "--promo-stills", "/tmp/stills"],
            [exe, "--promo", "/tmp/work", "--promo-scene", "hero"],
            [exe, "--promo"], [exe, "--promo-scene", "hero"],
        ]
        for args in flagged {
            XCTAssertEqual(PromoLaunch.parse(args, debugBuild: false), .normal, "\(args)")
        }
    }

    func testDebugBuildWithExplicitFlags() {
        XCTAssertEqual(PromoLaunch.parse([exe, "--promo-stills", "/tmp/stills"], debugBuild: true),
                       .stills(directory: "/tmp/stills"))
        XCTAssertEqual(
            PromoLaunch.parse([exe, "--promo", "/tmp/work", "--promo-scene", "hero"], debugBuild: true),
            .scene(name: "hero", directory: "/tmp/work"))
        XCTAssertEqual(
            PromoLaunch.parse([exe, "--promo-scene", "lesson", "--promo", "/tmp/w"], debugBuild: true),
            .scene(name: "lesson", directory: "/tmp/w"))
    }

    /// A malformed promo launch is reported, never quietly run as the app.
    func testMalformedFlagsAreInvalidNotNormal() {
        let malformed: [[String]] = [
            [exe, "--promo-stills"],
            [exe, "--promo-stills", "--promo", "/tmp/w"],
            [exe, "--promo", "/tmp/w"],
            [exe, "--promo", "--promo-scene", "hero"],
            [exe, "--promo-scene", "hero"],
            [exe, "--promo", "/tmp/w", "--promo-scene"],
        ]
        for args in malformed {
            guard case .invalid = PromoLaunch.parse(args, debugBuild: true) else {
                return XCTFail("expected .invalid for \(args)")
            }
        }
    }

    func testIsDebugBuildMatchesThisConfiguration() {
        XCTAssertTrue(PromoLaunch.isDebugBuild)
    }

    // MARK: - Source invariants

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ThatawayKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    /// Every promo file is wrapped in `#if DEBUG` from its first statement
    /// to its last line, so a Release build contains none of it.
    func testStageSourceIsDebugOnly() throws {
        let dir = packageRoot.appendingPathComponent("Sources/ThatawayApp/Promo")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no promo sources found at \(dir.path)")
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let code = lines.filter { !$0.isEmpty && !$0.hasPrefix("//") }
            XCTAssertEqual(code.first, "#if DEBUG", "\(file.lastPathComponent) must open with #if DEBUG")
            XCTAssertEqual(code.last, "#endif", "\(file.lastPathComponent) must close with #endif")
        }
    }

    /// The hook sits in `main()`, inside `#if DEBUG`, before the delegate
    /// (and with it the cache, overlay, command bar, exclusion store and
    /// voice) is constructed.
    func testAppHookRunsBeforeTheDelegateAndOnlyInDebug() throws {
        let app = try String(contentsOf: packageRoot.appendingPathComponent("Sources/ThatawayApp/App.swift"),
                             encoding: .utf8)
        guard let main = app.range(of: "static func main()"),
              let delegate = app.range(of: "let delegate = ThatawayApp()", range: main.upperBound..<app.endIndex)
        else { return XCTFail("could not find main() and the delegate in App.swift") }
        let prologue = String(app[main.upperBound..<delegate.lowerBound])
        guard let open = prologue.range(of: "#if DEBUG"),
              let hook = prologue.range(of: "PromoStage.runIfRequested("),
              let close = prologue.range(of: "#endif")
        else { return XCTFail("the promo hook must sit in main(), inside #if DEBUG, before the delegate") }
        XCTAssertLessThan(open.lowerBound, hook.lowerBound)
        XCTAssertLessThan(hook.lowerBound, close.lowerBound)
        // The only other mention of the stage in the app is that hook.
        XCTAssertEqual(app.components(separatedBy: "PromoStage").count - 1, 1)
    }
}

#endif
