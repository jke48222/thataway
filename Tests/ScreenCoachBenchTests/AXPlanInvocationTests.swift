import XCTest
@testable import screencoach_bench

/// `screencoach-bench axplan` flag handling. The README's reproduce command
/// and CI both depend on these defaults, and a flag with no value used to
/// crash with an index out of range.
final class AXPlanInvocationTests: XCTestCase {

    private func parse(_ args: [String], targets: Int? = nil,
                       directories: Set<String> = []) -> Result<AXPlan.Invocation, AXPlan.InvocationError> {
        AXPlan.parseInvocation(["axplan"] + args, targets: targets,
                               isDirectory: { directories.contains($0) })
    }

    func testNoFlagsReproducesTheCitedChromePlan() {
        XCTAssertEqual(try parse([]).get(),
                       AXPlan.Invocation(dataPath: "bench-data/google-chrome.json",
                                         outPath: "bench-data/axplan-chrome.json", count: 12))
    }

    func testTheREADMECommandIsTakenLiterally() {
        let r = parse(["--data", "bench-data/google-chrome.json",
                       "--out", "bench-data/axplan-chrome.json"], targets: 12)
        XCTAssertEqual(try r.get(),
                       AXPlan.Invocation(dataPath: "bench-data/google-chrome.json",
                                         outPath: "bench-data/axplan-chrome.json", count: 12))
    }

    func testAnotherSnapshotGetsItsOwnPlanBesideIt() {
        XCTAssertEqual(try parse(["--data", "x/y.json"]).get().outPath, "x/y-axplan.json")
    }

    func testADirectoryOutGetsTheDerivedName() {
        let existing = parse(["--data", "x/y.json", "--out", "/scratch"],
                             directories: ["/scratch"])
        XCTAssertEqual(try existing.get().outPath, "/scratch/y-axplan.json")
        let slash = parse(["--out", "/new/dir/"])
        XCTAssertEqual(try slash.get().outPath, "/new/dir/axplan-chrome.json")
    }

    func testAFlagWithNoValueIsAnErrorNotACrash() {
        XCTAssertEqual(parse(["--data"]), .failure(.missingValue("--data")))
        XCTAssertEqual(parse(["--out"]), .failure(.missingValue("--out")))
        XCTAssertEqual(parse(["--data", "--out", "x"]), .failure(.missingValue("--data")))
    }

    func testFewerThanOneTargetIsRejected() {
        XCTAssertEqual(parse([], targets: 0), .failure(.badTargets(0)))
    }
}
