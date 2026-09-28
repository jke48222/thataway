import XCTest
@testable import thataway_bench

/// `thataway-bench axplan` flag handling. The README's reproduce command
/// and CI both depend on these defaults, and a flag with no value used to
/// crash with an index out of range.
final class AXPlanInvocationTests: XCTestCase {

    private func parse(_ args: [String], targets: Int? = nil,
                       directories: Set<String> = []) -> Result<AXPlan.Invocation, AXPlan.InvocationError> {
        AXPlan.parseInvocation(["axplan"] + args, targets: targets,
                               isDirectory: { directories.contains($0) },
                               temporaryDirectory: "/tmpdir")
    }

    func testNoFlagsReproducesTheCitedChromePlanOutsideTheRepository() {
        XCTAssertEqual(try parse([]).get(),
                       AXPlan.Invocation(dataPath: "bench-data/google-chrome.json",
                                         outPath: "/tmpdir/axplan-chrome.json", count: 12))
    }

    func testTheREADMECommandIsTakenLiterally() {
        let r = parse(["--data", "bench-data/google-chrome.json",
                       "--out", "/tmp/axplan-chrome.json"], targets: 12)
        XCTAssertEqual(try r.get(),
                       AXPlan.Invocation(dataPath: "bench-data/google-chrome.json",
                                         outPath: "/tmp/axplan-chrome.json", count: 12))
    }

    func testAnotherSnapshotGetsItsOwnPlanInTheTemporaryDirectory() {
        XCTAssertEqual(try parse(["--data", "x/y.json"]).get().outPath, "/tmpdir/y-axplan.json")
    }

    func testNoRunWithoutOutWritesIntoTheCommittedEvidence() throws {
        for args in [[], ["--data", "bench-data/google-chrome.json"]] {
            XCTAssertFalse(try parse(args).get().outPath.hasPrefix("bench-data/"), "\(args)")
        }
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

/// `AXPlan.run`'s exit status. CI's reproduce step relies on a failed load or
/// a failed write returning 1 rather than printing "Wrote" and exiting 0.
/// Headless: it reads only the committed Chrome snapshot.
final class AXPlanRunStatusTests: XCTestCase {

    private static let chromeSnapshot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ThatawayBenchTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("bench-data/google-chrome.json").path

    private var written: [String] = []

    override func tearDown() {
        for path in written { try? FileManager.default.removeItem(atPath: path) }
        written.removeAll()
        super.tearDown()
    }

    private func scratch(_ name: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    func testASnapshotThatDoesNotExistExitsOne() {
        let out = scratch("axplan-\(UUID()).json")
        written.append(out)
        XCTAssertEqual(AXPlan.run(dataPath: scratch("missing-\(UUID()).json"),
                                  outPath: out, count: 12), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    }

    func testAnUnwritableOutPathExitsOneAndWritesNothing() {
        let out = scratch("no-such-dir-\(UUID())/x.json")
        XCTAssertEqual(AXPlan.run(dataPath: Self.chromeSnapshot, outPath: out, count: 12), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    }

    func testTheChromeSnapshotAnswersAllTwelveAndExitsZero() throws {
        let out = scratch("axplan-\(UUID()).json")
        written.append(out)
        XCTAssertEqual(AXPlan.run(dataPath: Self.chromeSnapshot, outPath: out, count: 12), 0)
        let data = try Data(contentsOf: URL(fileURLWithPath: out))
        let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(plan["ax_hit_rate"] as? Double, 1.0)
        XCTAssertEqual((plan["plans"] as? [[String: Any]])?.count, 12)
    }
}
