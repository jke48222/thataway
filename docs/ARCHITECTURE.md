# How Thataway works

This is the engineering side of the [README](../README.md): the design, the measurements that
shaped it, the privacy gate, and how the code is tested. Numbers come from
[`PHASE-0-FINDINGS.md`](../PHASE-0-FINDINGS.md) and the committed files in `bench-data/`.
[BENCHMARKS.md](BENCHMARKS.md) has the results tables and the commands that reproduce them.

## Contents

- [The idea: the tree first, vision second](#the-idea-the-tree-first-vision-second)
- [One turn, start to finish](#one-turn-start-to-finish)
- [Measurements that set the design](#measurements-that-set-the-design)
- [The privacy gate](#the-privacy-gate)
- [Testing without a screen](#testing-without-a-screen)
- [Project layout](#project-layout)

## The idea: the tree first, vision second

Helping someone through unfamiliar software is mostly a coordinate problem. You know which
control you mean and you have no way to point at it. Screen sharing is often unavailable or too
much for one button. Written steps go stale when the app changes its layout. Screenshots with red
circles are made by hand, one per step.

The obvious move now is to hand the screen to a vision model and ask where the button is. On this
project's own tests that misses often: in PHASE-0, Holo1.5-7B found 4 of 10 targets on a full
Logic Pro window, and its fastest usable call took 1,657 ms (Finding 6). A pointer that lands on the wrong
control that often is worse than none, because the person following it cannot tell which answers
are wrong.

So Thataway inverts the order. Mac apps already publish a structured description of their own
interface, the accessibility tree: every button, field and menu item with its real screen
rectangle, its role, and usually a label. When the control is in the tree, its position is exact,
and once the tree is cached the resolver finds it in well under a millisecond. Vision is the
fallback for what the tree does not cover: canvases, custom-drawn controls, and apps that publish
nothing useful.

## One turn, start to finish

```
                      speculative, before you press anything
                 ┌──────────────────────────────────────────┐
                 │  AXCache: walk on app switch,            │
                 │  refresh on AXObserver events,           │
                 │  heartbeat to keep the tree warm         │
                 └────────────────────┬─────────────────────┘
                                      │  warm tree, already in hand
Option Space  ->  CommandBar  ->  AXResolver  ->  score >= 0.62 ?
"the Share button"  live shortlist    lexical rank        │
                    per keystroke                    yes  │  no
                                                          │   │
                                          point immediately   │
                                                              v
                                          AXResolver.cropHint: the tree aims
                                          a crop even though it could not answer
                                                              │
                                                              v
                                          Holo1.5-7B sidecar, started lazily
                                          on the first miss, never before
                                                              │
                                                              v
                                                Fusion: tree + vision -> one
                                                decision, plus a confidence
                                                the overlay draws
```

**The work happens before the hotkey.** [`AXCache.swift`](../Sources/ThatawayKit/AXCache.swift)
walks the frontmost app's tree when you switch apps, refreshes it when an `AXObserver` reports a
change (at most one walk per second, 250 ms while a lesson is watching), and runs a 3-second
heartbeat that pauses after 60 seconds without keyboard or mouse input. By the time you press
Option Space the tree is already in memory.

**The resolver is lexical, not learned.**
[`AXResolver.swift`](../Sources/ThatawayCore/AXResolver.swift) scores your words against the
labels in the tree. It is cheap enough that the command bar re-ranks on every keystroke and shows
the top three candidates as you type: 0.067 ms at p50 on a Chrome window.

**The model never starts on a confident hit.** If the top score clears 0.62, Thataway points right
away. The fastest usable vision call measured took 1,657 ms, so a second opinion on a confident
answer would add more than a second and a half to an answer the tree already has with exact bounds.

**When vision runs, the tree still aims it.** Even when the resolver cannot name the control, it
usually knows roughly where that kind of control lives, so `cropHint` picks a crop. Fewer pixels
mean fewer image tokens, and image tokens are what this model's latency is made of (Finding 6
measured about 1.7 ms per image token).

**Fusion decides how sure to sound.** [`Fusion.swift`](../Sources/ThatawayCore/Fusion.swift)
combines two kinds of answer. A tree candidate has exact bounds, a score and a role. A vision
candidate has a point, no bounds, and no confidence, because the model returns a click without a
probability. The rule: agreement between the two methods is the only route to a confident point.
Everything else is drawn as a question. [`Overlay.swift`](../Sources/ThatawayKit/Overlay.swift)
draws a solid ring for an exact tree answer and a dashed amber ring with a question mark for a
guess, and draws no pointer when nothing matched. Spoken answers carry the same hedge.

**The pointer is drawn, and it travels.** The overlay is a click-through panel. `PointerLayer`
draws a bezier arc from `NSEvent.mouseLocation` to the target, because a dot that appears somewhere
has to be found before it can be followed. Nothing in `Sources/` warps the cursor or posts mouse
events.

## Measurements that set the design

Three findings changed the design rather than confirming it.

### Finding 1: a cold accessibility tree is 6 to 10 times slower than a warm one

| App | Cold, first touch | Warm p50 | Ratio |
| --- | ---: | ---: | ---: |
| Logic Pro | 220 ms | 21 ms | 10.4x |
| Calendar | 193 ms | 18.5 ms | 10.4x |
| Messages | 170 ms | 27.5 ms | 6.2x |
| Google Chrome | 45 ms | 5.7 ms | 8.0x |

The first walk of an app's tree makes that app build it. Later walks ride a warm path. Finder's
37x is left out of the headline because its tree is five nodes, which makes the ratio arithmetic
rather than informative.

Warmth also decays within ten seconds. Left idle, Logic Pro drifts from 21 to 47 to 50 to 64 ms,
and Calendar goes from 18.5 ms back to 120 ms, cold again.

Thataway's usual moment is "you just switched apps and pressed the hotkey", which is the cold
path. Walking the tree on the hotkey would cost 45 to 220 ms. That is why `AXCache` exists, why an
`AXObserver` drives it, and why it keeps a heartbeat instead of only reacting to changes.

### Finding 2: batching attribute reads saves 3.1x

Eleven attributes per node read as eleven `AXUIElementCopyAttributeValue` calls, against one
`AXUIElementCopyMultipleAttributeValues` call:

| Strategy | p50 | p90 |
| --- | ---: | ---: |
| One call per attribute | 2.54 ms | 3.08 ms |
| Batched | 0.81 ms | 0.97 ms |

This is per-node attribute reading, not a whole walk. Each accessibility read is a synchronous
round trip into another app's run loop, so the saving is round trips, not CPU. Both paths stay in
[`AXTree.swift`](../Sources/ThatawayKit/AXTree.swift) as a selectable strategy, so the comparison
can be measured again.

### Finding 4: the capture path matters more than the capture API

| Path | p50 | p90 |
| --- | ---: | ---: |
| Warm ScreenCaptureKit stream, plus `CGImage` | 6.2 ms | 7.9 ms |
| `SCScreenshotManager` one shot | 34.4 ms | 35.9 ms |
| `screencapture(1)` command line tool | 193 ms | 204 ms |

The raw warm-grab row in the source data reads 0.00 ms, because the newest frame is already in
hand and reading a pointer is not a capture. The findings log rejects that row and uses the "plus
`CGImage`" row, quoted above.

A trap in the same finding: ScreenCaptureKit does not deliver frames on a timer. On a mostly still
screen, a display-scope stream delivered 108 complete frames and 96 idle ones, and an idle frame
carries no pixels. A design that waits for the next frame
after the hotkey can block on a still screen, which is what someone looking for a control is
usually looking at. [`WarmCapture.swift`](../Sources/ThatawayKit/WarmCapture.swift) keeps the
newest complete frame and uses it right away.

## The privacy gate

Excluded apps are not read and not captured, in that order.

The exclusion list first gated only the screenshot. Testing it against Messages produced a
candidate list with a real conversation in it, a contact's name and part of a message, with no
frame ever captured. The accessibility tree carries content, not only controls. That is Finding 16
in [`PHASE-0-FINDINGS.md`](../PHASE-0-FINDINGS.md).

The fix: [`AXCache.swift`](../Sources/ThatawayKit/AXCache.swift) checks the exclusion rules
before the first accessibility call, on the bundle identifier alone. An app excluded by bundle is
never touched through the accessibility API.

Title rules are checked against the window server's title from `CGWindowList`. macOS withholds
other apps' window titles without Screen Recording, and failing open on a missing title would make
every title rule useless. Only in that case does the cache read the focused window's `AXTitle` (at
most three attribute reads, no tree walk) from an app whose bundle is already allowed, and check it
before walking. A tree whose own window title matches a rule is discarded before it is cached.

An excluded app gets a stated refusal in the bar instead of a pointer, naming the rule the way the
exclusions file writes it: "Not looking at <app>: the app is on the exclusion list (bundle: <id>)."
or "Not looking at <app>: its window title is on the exclusion list (title: <pattern>)."

The vision frame holds only the target app's windows, so notification banners, widgets and other
apps never reach the model. Thataway's own bar and overlay are hidden from capture
(`sharingType = .none`). The frame goes to the local sidecar in memory over a pipe. Only if that
fails is it written as a temp file readable by you alone, deleted after the reply, and swept on the
next start if a crash left it behind
([`SidecarProcess.swift`](../Sources/ThatawayKit/SidecarProcess.swift)).

[`ExclusionStore.swift`](../Sources/ThatawayKit/ExclusionStore.swift) keeps the list at
`~/.config/thataway/exclusions.conf` as plain text. It writes the defaults on first run so you
can read what is excluded, and reloads when you save. It fails closed: a file with no rules means
the defaults, never "allow everything", and a file caught mid-save keeps the rules already loaded.
It re-arms its file watch after a delete or rename, because editors replace files instead of
writing in place.

The defaults are 26 bundle-ID prefixes and 16 title patterns, in
[`ExclusionList.swift`](../Sources/ThatawayCore/ExclusionList.swift). The README's
[Privacy section](../README.md#privacy-and-permissions) lists them.

The cost is on purpose: Thataway cannot help you inside your password manager.

## Testing without a screen

`ThatawayCore` imports only Foundation, CoreGraphics and Darwin: no AppKit, no
ApplicationServices, no ScreenCaptureKit. Its 132 tests ran in 0.014 s (XCTest's own summary,
2026-09-29) with no permissions, no windows and no hardware. The parts most likely to be quietly
wrong live there on purpose: multi-display coordinates, the latency budget, the resolver's scoring
and the fusion rules.

| Test file | Count | What it covers |
| --- | ---: | --- |
| `FusionTests` | 37 | Combining tree and vision candidates, the confidence rules, exclusion parsing |
| `LessonTests` | 23 | Steps, completion conditions, tree-diff detection |
| `WorkflowInferenceTests` | 18 | Click hit-testing and turning clicks into named steps |
| `LatencyTests` | 15 | Stage timing, percentiles, the budget as code |
| `AXResolverTests` | 13 | Query to element ranking, and crop aiming on a miss |
| `DisplaySpaceTests` | 11 | The multi-display coordinate trap, at the type level |
| `PushToTalkTests` | 11 | Hold versus tap on hardware timestamps, and turn ordering |

`ThatawayKit` has 83 tests for what runs without a display or a permission: the hotkey state
machine, the capture exclusion plan, cache freshness and event throttling, exclusion file reloads,
lesson file limits, the lesson runner's stall reporting and same-app check, and the config folder
move. They also drive the pointer's geometry, motion, contrast, badge and caption placement
headless, run the vision sidecar protocol against a stand-in Python script, and check that no
ordinary launch and no Release build can enter the Debug-only promo stage. Eighteen more
cover the bench CLI's command parsing, its `axplan` flags and its exit status.

Seventeen Python tests cover the sidecar (13, with `mlx_vlm` stubbed) and the app bundling script
(4, with `swift`, `security` and `codesign` stubbed).

The accessibility walk, capture, the overlay on a real display, voice and the app's turn logic
have no unit tests. That is the real coverage gap, and the `--selftest` harness and hand testing
are what check them today.

## Project layout

```
Sources/
├── ThatawayCore/        Foundation, CoreGraphics and Darwin only
│   ├── AXResolver.swift        Query to element ranking, and crop aiming on a miss
│   ├── Fusion.swift            Tree plus vision to one decision, with its confidence
│   ├── DisplaySpace.swift      The multi-display coordinate trap, at the type level
│   ├── AXNode.swift            Element model and label fusion
│   ├── ExclusionList.swift     What Thataway never looks at
│   ├── Lesson.swift            Steps, completion conditions, tree-diff detection
│   ├── WorkflowInference.swift Clicks to named steps
│   ├── PushToTalk.swift        Hold to speak, tap to type
│   ├── LatencyBudget.swift     The budget as code, checkable automatically
│   ├── LatencyTrace.swift      Stage timing, p50, p90, p99
│   └── Mono.swift              One monotonic clock for every stage
├── ThatawayKit/         System facing
│   ├── AXCache.swift           Speculative walks, AXObserver, heartbeat, privacy gate
│   ├── AXTree.swift            Tree extraction, batched attribute reads, limits
│   ├── ExclusionStore.swift    The hot-reloading exclusion file
│   ├── ConfigFolder.swift      The one-time settings folder move from the old name
│   ├── WarmCapture.swift       Warm ScreenCaptureKit stream and one-shot paths
│   ├── ScreenGrab.swift        Target-app capture with origin, scale and index
│   ├── GroundingService.swift  The vision sidecar, started lazily on the first miss
│   ├── SidecarProcess.swift    The sidecar's process, pipe and temp-file handling
│   ├── Overlay.swift           Click-through panel and the bezier-arc pointer
│   ├── HotKeyTap.swift         Event tap on its own thread, swallows only the hotkey
│   ├── Voice.swift             On-device push-to-talk speech, and speech out
│   ├── LessonRunner.swift      Multi-step lessons that advance on evidence
│   └── WorkflowRecorder.swift  Watch me: clicks to steps to JSON on disk
├── ThatawayApp/         Menu bar app, hotkey, command bar, the resolve and point turn
│   └── Promo/                  Debug-only stage that renders docs/media, compiled out of Release
└── ThatawayBench/       thataway-bench, 14 subcommands behind the findings

Tests/ThatawayCoreTests/   132 tests, headless
Tests/ThatawayKitTests/    83 tests, headless, no permissions
Tests/ThatawayBenchTests/  18 tests of the bench CLI's commands, flags and exit status
Tools/                     The Python vision sidecar and harnesses, make-app.sh, 17 Python tests
bench-data/                Committed benchmark output, the source of the figures here
PHASE-0-FINDINGS.md        The engineering log, 23 findings across phases 0 to 4
```

Source size on 2026-09-29 (`wc -l`): 17,204 Swift lines in 62 files. Sources are 14,037 lines in
38 files, tests 3,103 in 23, and `Package.swift` 64. The Debug-only promo stage is 2,771 of the
source lines, in 7 files.
