// swift-tools-version: 5.9
// Swift 5 language mode, matching WindowPet: AppKit + AX + ScreenCaptureKit
// under Swift 6 strict concurrency is a migration project of its own, and
// Phase 0 is a measurement harness. Revisit when the app target lands.
import PackageDescription

let package = Package(
    name: "ScreenCoach",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure. No AppKit, no ApplicationServices, no ScreenCaptureKit.
        // Everything here is unit-testable headless — which is the point:
        // the coordinate-space trap and the latency budget are exactly the
        // things you want under test before hardware is involved.
        .target(name: "ScreenCoachCore", path: "Sources/ScreenCoachCore"),

        // The system-facing half: accessibility tree extraction, the warm
        // ScreenCaptureKit stream, the listen-only event tap.
        .target(
            name: "ScreenCoachKit",
            dependencies: ["ScreenCoachCore"],
            path: "Sources/ScreenCoachKit"
        ),

        // The app: menu-bar only, hotkey-summoned, points at real controls.
        .executableTarget(
            name: "ScreenCoachApp",
            dependencies: ["ScreenCoachKit", "ScreenCoachCore"],
            path: "Sources/ScreenCoachApp"
        ),

        // Phase 0 measurement CLI. Produces the three numbers.
        .executableTarget(
            name: "screencoach-bench",
            dependencies: ["ScreenCoachKit", "ScreenCoachCore"],
            path: "Sources/ScreenCoachBench"
        ),

        .testTarget(
            name: "ScreenCoachCoreTests",
            dependencies: ["ScreenCoachCore"],
            path: "Tests/ScreenCoachCoreTests"
        ),

        // Kit's pure policies and its process/file plumbing: the hotkey state
        // machine, capture exclusion plan, cache freshness, exclusion file
        // reloads, lesson file limits and the sidecar protocol (against a
        // stand-in Python script). Nothing here needs a display or any TCC
        // permission.
        .testTarget(
            name: "ScreenCoachKitTests",
            dependencies: ["ScreenCoachKit", "ScreenCoachCore"],
            path: "Tests/ScreenCoachKitTests"
        ),

        // The bench CLI's argument handling, which the README's reproduce
        // command and CI depend on.
        .testTarget(
            name: "ScreenCoachBenchTests",
            dependencies: ["screencoach-bench"],
            path: "Tests/ScreenCoachBenchTests"
        ),
    ]
)
