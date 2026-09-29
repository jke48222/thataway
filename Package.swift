// swift-tools-version: 5.9
// Swift 5 language mode, matching WindowPet: AppKit + AX + ScreenCaptureKit
// under Swift 6 strict concurrency is a migration project of its own, and
// Phase 0 is a measurement harness. Revisit when the app target lands.
import PackageDescription

let package = Package(
    name: "Thataway",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure. No AppKit, no ApplicationServices, no ScreenCaptureKit.
        // Everything here is unit-testable headless — which is the point:
        // the coordinate-space trap and the latency budget are exactly the
        // things you want under test before hardware is involved.
        .target(name: "ThatawayCore", path: "Sources/ThatawayCore"),

        // The system-facing half: accessibility tree extraction, the warm
        // ScreenCaptureKit stream, the listen-only event tap.
        .target(
            name: "ThatawayKit",
            dependencies: ["ThatawayCore"],
            path: "Sources/ThatawayKit"
        ),

        // The app: menu-bar only, hotkey-summoned, points at real controls.
        .executableTarget(
            name: "ThatawayApp",
            dependencies: ["ThatawayKit", "ThatawayCore"],
            path: "Sources/ThatawayApp"
        ),

        // Phase 0 measurement CLI. Produces the three numbers.
        .executableTarget(
            name: "thataway-bench",
            dependencies: ["ThatawayKit", "ThatawayCore"],
            path: "Sources/ThatawayBench"
        ),

        .testTarget(
            name: "ThatawayCoreTests",
            dependencies: ["ThatawayCore"],
            path: "Tests/ThatawayCoreTests"
        ),

        // Kit's pure policies and its process/file plumbing: the hotkey state
        // machine, capture exclusion plan, cache freshness, exclusion file
        // reloads, lesson file limits and the sidecar protocol (against a
        // stand-in Python script). Nothing here needs a display or any TCC
        // permission.
        .testTarget(
            name: "ThatawayKitTests",
            dependencies: ["ThatawayKit", "ThatawayCore"],
            path: "Tests/ThatawayKitTests"
        ),

        // The bench CLI's argument handling, which the README's reproduce
        // command and CI depend on.
        .testTarget(
            name: "ThatawayBenchTests",
            dependencies: ["thataway-bench"],
            path: "Tests/ThatawayBenchTests"
        ),
    ]
)
