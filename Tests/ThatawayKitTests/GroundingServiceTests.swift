import CoreGraphics
import XCTest
@testable import ThatawayKit
import ThatawayCore

/// Drives GroundingService against a stand-in sidecar written in plain
/// Python (no MLX), one behaviour per mode.
final class GroundingServiceTests: XCTestCase {

    private var dir: URL!
    private var services: [GroundingService] = []

    private static let sidecar = #"""
import os, struct, sys, time, json
mode = os.path.basename(sys.argv[1])
marker = sys.argv[1] + ".slow-done"
def emit(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
emit({"ready": True, "model": "fake", "load_s": 0.01})
if mode == "die":
    sys.exit(0)
if mode == "closein":
    os.close(0); time.sleep(5); sys.exit(0)
while True:
    line = sys.stdin.readline()
    if not line:
        break
    req = json.loads(line)
    rid = req.get("id")
    if mode == "slow" and not os.path.exists(marker):
        open(marker, "w").close()
        time.sleep(3)
        emit({"id": rid, "x": 1.0, "y": 1.0})
        continue
    if mode == "stale":
        emit({"id": rid - 100, "x": 1.0, "y": 1.0})
        print("a library warning, not JSON", flush=True)
    with open(req["image"], "rb") as f:
        head = f.read(24)
    w, h = struct.unpack(">II", head[16:24])
    emit({"id": rid, "x": float(w), "y": float(h), "ttft_ms": 1, "total_ms": 2, "tokens": 3})
"""#

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ground-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Self.sidecar.write(to: dir.appendingPathComponent("fake_server.py"),
                                atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        services.forEach { $0.shutdown() }
        services = []
        try? FileManager.default.removeItem(at: dir)
    }

    private func service(mode: String) -> GroundingService {
        let model = dir.appendingPathComponent(mode)
        try? FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let s = GroundingService(serverScript: dir.appendingPathComponent("fake_server.py"),
                                 modelPath: model.path)
        s.pythonPath = "/usr/bin/python3"
        s.interpreterProbe = { _ in true }
        s.relaunchBackoff = 0
        services.append(s)
        return s
    }

    private func image(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func ground(_ s: GroundingService, crop: CGRect? = nil) -> GroundingService.Result? {
        s.ground(image: image(width: 400, height: 300), query: "the Save button",
                 cropPixels: crop, screenIndex: 1, displayScale: 2,
                 displayOrigin: CGPoint(x: 1000, y: 0))
    }

    func testTheTimeoutIsEnforcedAndTheNextQueryStartsClean() {
        let s = service(mode: "slow")
        s.timeout = 1
        XCTAssertTrue(s.startIfNeeded())
        let started = Date()
        XCTAssertNil(ground(s), "a late answer must not be returned")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "the deadline was not enforced")
        if case .failed = s.state {} else { XCTFail("state should be failed, was \(s.state)") }

        XCTAssertTrue(s.startIfNeeded(), "the next miss should relaunch the sidecar")
        let r = ground(s)
        XCTAssertEqual(r?.point.cg.x ?? 0, 1000 + 400 / 2, accuracy: 0.01)
        XCTAssertEqual(r?.point.screenIndex, 1)
    }

    func testRepliesForOtherIDsAndNonJSONLinesAreDiscarded() {
        let s = service(mode: "stale")
        XCTAssertTrue(s.startIfNeeded())
        let r = ground(s)
        XCTAssertEqual(r?.point.cg.x ?? 0, 1000 + 400 / 2, accuracy: 0.01)
        XCTAssertEqual(r?.point.cg.y ?? 0, 300 / 2, accuracy: 0.01)
    }

    func testTheCropIsAppliedBeforeEncodingAndMappedBack() {
        let s = service(mode: "echo")
        XCTAssertTrue(s.startIfNeeded(), "\(s.state)")
        // The stand-in answers with the size of the image it was sent, so
        // the answer is the crop's far corner: (100 + 200, 50 + 100) px.
        let r = ground(s, crop: CGRect(x: 100, y: 50, width: 200, height: 100))
        XCTAssertEqual(r?.point.cg.x ?? 0, 1000 + 300.0 / 2, accuracy: 0.01)
        XCTAssertEqual(r?.point.cg.y ?? 0, 150.0 / 2, accuracy: 0.01)
    }

    func testASidecarThatDiedBetweenQueriesDoesNotKillTheApp() {
        let s = service(mode: "die")
        XCTAssertTrue(s.startIfNeeded())
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertNil(ground(s))
    }

    func testWritingToAClosedPipeFailsWithoutSIGPIPE() {
        let s = service(mode: "closein")
        XCTAssertTrue(s.startIfNeeded())
        Thread.sleep(forTimeInterval: 0.5)
        // Before the fix this write raised SIGPIPE and the process exited
        // with status 141; reaching the assertion is the test.
        XCTAssertNil(ground(s))
        if case .failed = s.state {} else { XCTFail("state should be failed, was \(s.state)") }
    }

    func testInterpreterCandidatesNeverUseEnvAndPreferExplicitSettings() {
        let list = GroundingService.candidateInterpreters(
            explicit: "/custom/python3", environment: ["THATAWAY_PYTHON": "/env/python3"],
            defaultsValue: "/defaults/python3", modelPath: "/Users/x/models/holo")
        XCTAssertEqual(Array(list.prefix(3)), ["/custom/python3", "/env/python3", "/defaults/python3"])
        XCTAssertTrue(list.contains("/Users/x/models/holo/.venv/bin/python3"))
        XCTAssertTrue(list.contains("/opt/homebrew/bin/python3"))
        XCTAssertEqual(list.last, "/usr/bin/python3")
        XCTAssertFalse(list.contains { $0.hasSuffix("/env") })
    }
}
