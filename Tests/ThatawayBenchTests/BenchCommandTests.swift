import XCTest
@testable import thataway_bench

/// `thataway-bench`'s subcommand choice. Asking for help must never fall
/// through to a command that walks other apps' trees or captures the screen.
final class BenchCommandTests: XCTestCase {

    func testNoArgumentsPrintsHelp() {
        XCTAssertEqual(BenchCommand.parse([]), .help)
    }

    func testEveryHelpSpellingPrintsHelp() {
        for args in [["--help"], ["-h"], ["help"], ["ax", "--help"],
                     ["apps", "-h"], ["all", "--help"], ["--verbose", "--help"]] {
            XCTAssertEqual(BenchCommand.parse(args), .help, "\(args)")
        }
    }

    func testFlagsWithoutACommandAreAUsageErrorNotAll() {
        for args in [["--verbose"], ["--trials", "5"], ["--app", "Safari"]] {
            guard case .usageError = BenchCommand.parse(args) else {
                return XCTFail("\(args) should be a usage error")
            }
        }
    }

    func testAnUnknownWordIsAUsageError() {
        XCTAssertEqual(BenchCommand.parse(["axe"]), .usageError("Unknown command \"axe\"."))
        XCTAssertEqual(BenchCommand.parse(["ALL"]), .usageError("Unknown command \"ALL\"."))
    }

    func testAllRunsOnlyWhenNamed() {
        XCTAssertEqual(BenchCommand.parse(["all"]), .run(.all))
        XCTAssertEqual(BenchCommand.parse(["all", "--trials", "3"]), .run(.all))
    }

    func testHelpAsAnOptionValueIsNotAHelpRequest() {
        XCTAssertEqual(BenchCommand.parse(["dump", "--app", "help"]), .run(.dump))
    }

    func testTheREADMEReproduceCommandStillParses() {
        XCTAssertEqual(BenchCommand.parse(["axplan", "--data", "bench-data/google-chrome.json",
                                           "--targets", "12", "--out", "/tmp/x"]),
                       .run(.axplan))
    }

    func testEveryCommandIsListedInTheUsage() {
        XCTAssertEqual(BenchCommand.allCases.count, 14)
        for c in BenchCommand.allCases {
            XCTAssertEqual(BenchCommand.parse([c.rawValue]), .run(c))
            XCTAssertTrue(BenchCommand.usage.contains("\n  \(c.rawValue) "),
                          "\(c.rawValue) missing from usage")
        }
    }
}
