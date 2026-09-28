import CoreGraphics
import Darwin
import XCTest
@testable import ScreenCoachKit
import ScreenCoachCore

/// The vision sidecar's privacy and robustness rules, driven against a
/// stand-in written in plain Python (no MLX, no model, no display).
final class SidecarHardeningTests: XCTestCase {

    private var dir: URL!
    private var scratch: URL!
    private var services: [GroundingService] = []

    private static let sidecar = #"""
import base64, os, struct, sys, time, json
mode = os.path.basename(sys.argv[1])
def emit(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
hello = {"ready": True, "model": "fake", "load_s": 0.01}
if mode == "inline":
    hello["inline_image"] = True
emit(hello)
while True:
    line = sys.stdin.readline()
    if not line:
        break
    req = json.loads(line)
    if req.get("op") == "quit":
        break
    rid = req.get("id")
    if mode == "inline":
        if "image" in req:
            emit({"id": rid, "error": "a path was sent to an inline sidecar"}); continue
        head = base64.b64decode(req["image_png_b64"])[:24]
    else:
        if mode == "slowpath":
            time.sleep(1.5)
        with open(req["image"], "rb") as f:
            head = f.read(24)
    w, h = struct.unpack(">II", head[16:24])
    if mode == "wild":
        emit({"id": rid, "x": -500.0, "y": 10000.0}); continue
    if mode == "env":
        emit({"id": rid, "x": 1.0 if "PYTHONPATH" in os.environ else 0.0, "y": 0.0}); continue
    emit({"id": rid, "x": float(w) / 2, "y": float(h) / 2})
"""#

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString)")
        scratch = dir.appendingPathComponent("frames")
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
                                 modelPath: model.path, scratchDirectory: scratch)
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

    private func ground(_ s: GroundingService) -> GroundingService.Result? {
        s.ground(image: image(width: 400, height: 300), query: "the Save button",
                 cropPixels: nil, screenIndex: 0, displayScale: 1,
                 displayOrigin: .zero)
    }

    private func framesOnDisk() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? [])
            .filter { $0.hasPrefix("frame-") }
    }

    // MARK: - No frame on disk

    func testAnInlineSidecarGetsTheFrameOverThePipeAndNoFileIsWritten() throws {
        let s = service(mode: "inline")
        XCTAssertTrue(s.startIfNeeded(), "\(s.state)")
        let r = try XCTUnwrap(ground(s), s.lastFailure ?? "nil")
        XCTAssertEqual(r.point.cg.x, 200, accuracy: 0.01)
        XCTAssertEqual(r.point.cg.y, 150, accuracy: 0.01)
        XCTAssertEqual(framesOnDisk(), [])
        XCTAssertNil(s.lastFailure)
    }

    func testFramesLeftByACrashAreSweptAtStartAndRecentOnesAreKept() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let old = scratch.appendingPathComponent("frame-OLD.png")
        let recent = scratch.appendingPathComponent("frame-RECENT.png")
        FileManager.default.createFile(atPath: old.path, contents: Data([1]))
        FileManager.default.createFile(atPath: recent.path, contents: Data([1]))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)

        _ = service(mode: "echo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path),
                       "a frame from an earlier run must not survive the next start")
        // A recent one may belong to another instance's call in progress.
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testAPurgedScratchFolderIsRecreatedBeforeTheNextFrame() throws {
        let s = service(mode: "echo")
        XCTAssertTrue(s.startIfNeeded())
        try FileManager.default.removeItem(at: scratch)
        XCTAssertNotNil(ground(s), s.lastFailure ?? "nil")
        XCTAssertEqual(framesOnDisk(), [], "the path fallback deletes its frame")
    }

    func testTheFallbackFrameFileIsPrivateToTheUser() throws {
        let s = service(mode: "echo")
        guard case .success(let url) = s.writeFrame(Data([0x89, 0x50])) else {
            return XCTFail("write failed")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testShutdownLetsAGroundingCallInProgressDeleteItsFrame() {
        let s = service(mode: "slowpath")
        XCTAssertTrue(s.startIfNeeded())
        let done = expectation(description: "ground returned")
        DispatchQueue.global().async {
            _ = self.ground(s)
            done.fulfill()
        }
        // Wait until the frame is on disk, then quit mid-request.
        let deadline = Date().addingTimeInterval(2)
        while framesOnDisk().isEmpty && Date() < deadline { usleep(10_000) }
        XCTAssertFalse(framesOnDisk().isEmpty, "the stand-in never saw a frame")
        s.shutdown(grace: 3)
        XCTAssertEqual(framesOnDisk(), [], "shutdown returned with a frame still on disk")
        wait(for: [done], timeout: 5)
    }

    // MARK: - Answers

    func testAnAnswerOutsideTheFrameIsDiscarded() {
        let s = service(mode: "wild")
        XCTAssertTrue(s.startIfNeeded())
        XCTAssertNil(ground(s))
        XCTAssertNotNil(s.lastFailure)
        XCTAssertTrue(GroundingService.pointIsInside(x: 0, y: 300, width: 400, height: 300))
        XCTAssertFalse(GroundingService.pointIsInside(x: -1, y: 5, width: 400, height: 300))
        XCTAssertFalse(GroundingService.pointIsInside(x: 5, y: 301, width: 400, height: 300))
        XCTAssertFalse(GroundingService.pointIsInside(x: .nan, y: 5, width: 400, height: 300))
        XCTAssertFalse(GroundingService.pointIsInside(x: .infinity, y: 5, width: 400, height: 300))
    }

    // MARK: - The coach's grants and environment stay with the coach

    func testTheSidecarDoesNotSeeTheCoachsPythonPath() throws {
        setenv("PYTHONPATH", "/tmp/not-for-the-sidecar", 1)
        defer { unsetenv("PYTHONPATH") }
        let s = service(mode: "env")
        XCTAssertTrue(s.startIfNeeded(), "\(s.state)")
        let r = try XCTUnwrap(ground(s), s.lastFailure ?? "nil")
        XCTAssertEqual(r.point.cg.x, 0, "PYTHONPATH reached the sidecar")
    }

    func testAHelperIsSpawnedResponsibleForItselfWithOnlyItsOwnDescriptors() throws {
        // A descriptor this process holds open without close-on-exec, the kind
        // a leak would hand to the helper. The helper reports whether it can
        // see that exact number.
        let marker = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThan(marker, 2)
        defer { close(marker) }
        let p = try SidecarProcess.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "if [ -e /dev/fd/\(marker) ]; then echo LEAKED; else echo CLEAN; fi; env; sleep 2"],
            environment: SidecarProcess.minimalEnvironment(
                from: ["HOME": "/Users/x", "PYTHONPATH": "/evil", "DYLD_INSERT_LIBRARIES": "/evil"]))
        defer { p.terminate(grace: 0.2); p.closeAll() }

        if let responsible = SidecarProcess.responsiblePID(for: p.pid) {
            XCTAssertEqual(responsible, p.pid,
                           "the helper would act with the coach's TCC grants")
        }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var pfd = pollfd(fd: p.stdoutFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 100) > 0 else {
                if String(decoding: out, as: UTF8.self).contains("HOME=") { break }
                continue
            }
            let n = read(p.stdoutFD, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("HOME=/Users/x"), text)
        XCTAssertFalse(text.contains("PYTHONPATH"), text)
        XCTAssertFalse(text.contains("DYLD_"), text)
        XCTAssertEqual(text.split(separator: "\n").first.map(String.init), "CLEAN",
                       "a descriptor leaked into the helper: \(text)")
    }

    func testAnInterpreterInAFolderEveryoneCanWriteIsRefused() throws {
        XCTAssertTrue(GroundingService.isTrustworthyExecutable("/usr/bin/python3"))
        XCTAssertFalse(GroundingService.isTrustworthyExecutable("relative/python3"))

        let shared = dir.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let py = shared.appendingPathComponent("python3")
        FileManager.default.createFile(atPath: py.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        XCTAssertTrue(GroundingService.isTrustworthyExecutable(py.path))
        chmod(shared.path, 0o777)
        XCTAssertFalse(GroundingService.isTrustworthyExecutable(py.path))

        // A symlink whose target is in such a folder is refused too.
        chmod(shared.path, 0o755)
        let link = dir.appendingPathComponent("link-python3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: py)
        XCTAssertTrue(GroundingService.isTrustworthyExecutable(link.path))
        chmod(shared.path, 0o777)
        XCTAssertFalse(GroundingService.isTrustworthyExecutable(link.path))
        chmod(shared.path, 0o755)
    }
}
