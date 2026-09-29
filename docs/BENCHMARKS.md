# Results and how to reproduce them

Every number here names the file it came from. Two of the committed files are easy to misread, and
one field in them is not a measurement at all, so the caveats sit next to the numbers.
[ARCHITECTURE.md](ARCHITECTURE.md) explains the design these numbers shaped.

## Contents

- [Headline results](#headline-results)
- [Why 12 of 12 on a Chrome window is a narrow result](#why-12-of-12-on-a-chrome-window-is-a-narrow-result)
- [The `p50_ms` in `live-eval.json` is not a timing](#the-p50_ms-in-live-evaljson-is-not-a-timing)
- [Aimed crops: two runs that disagree](#aimed-crops-two-runs-that-disagree)
- [What is not measured](#what-is-not-measured)
- [Reproduce the results](#reproduce-the-results)

## Headline results

| Result | Value | Where it comes from |
| --- | --- | --- |
| Resolver latency | 0.067 ms p50, 0.081 ms p90 | `bench-data/axplan-chrome.json`, the same run as the accuracy below |
| Resolver accuracy | 12 of 12 targets on one Google Chrome window | Same file, `ax_hit_rate: 1` over 12 plans; CI reproduces it on every push |
| Warm-cache tree read | 0.34 to 0.36 ms p50 | PHASE-0, Phase 1 "The measured turn" |
| Cold against warm tree read | 6 to 10x (Logic Pro 220 ms against 21) | PHASE-0 Finding 1 |
| Batched attribute reads | 0.81 ms p50 against 2.54 (3.1x) | PHASE-0 Finding 2 |
| Warm capture | 7.9 ms p90 against 204 for `screencapture(1)` | PHASE-0 Finding 4 |
| Fastest usable vision call | 1,657 ms (Holo1.5-7B, 4-bit, crop3) | PHASE-0 Finding 6 |
| Live vision pipeline | 9,676 ms full frame against 1,337 ms aimed crop, both hits | PHASE-0, Phase 2 "The sidecar" |
| Swift tests | 233 passing, 0 failures: 132 Core, 83 Kit, 18 Bench | `swift test`, 2026-09-29 |
| Python tests | 17 passing: 13 sidecar, 4 bundling | `Tools/tests/`, 2026-09-29 |
| Source size | 17,204 Swift lines in 62 files | Sources 14,037, Tests 3,103, `Package.swift` 64 (`wc -l`, 2026-09-29) |

Timings move with the machine and its load. The source total includes the tests and the
Debug-only promo stage (2,771 lines), and the application and library code alone is 11,266 lines.

## Why 12 of 12 on a Chrome window is a narrow result

All twelve targets are in a single Google Chrome window, and seven of the twelve are buttons on the
bookmarks bar, seven of the same kind of control.

[`PHASE-0-FINDINGS.md`](../PHASE-0-FINDINGS.md) says so itself: Chrome's toolbar is a far easier
target than Logic Pro's dense interface, and the full-frame vision baseline scored 83% on Chrome
against 40% on Logic Pro. The tree reads labels rather than pixels, so dense layouts cost it less
than they cost vision, but 12 of 12 on a Chrome window is not a general result. A second app,
ideally a dense one, is the most useful next measurement.

## The `p50_ms` in `live-eval.json` is not a timing

`bench-data/live-eval.json` reports the same small `p50_ms` for both its `ax_only` and `hybrid`
rows. That value was not timed. [`Tools/live_eval.py`](../Tools/live_eval.py) writes it as a
literal at lines 128 and 147 and re-reads precomputed hit and score fields from the plan file
instead of running the resolver.

The real measurement is `bench-data/axplan-chrome.json`, written by `thataway-bench axplan`, which
records `resolve_p50_ms: 0.067166` and `resolve_p90_ms: 0.080708` from the same run as the 12 of
12. Cite that file.

## Aimed crops: two runs that disagree

An earlier README said that letting the tree aim the vision crop matched full-frame accuracy at
three times the speed. The first run supports that. The second run, later the same day, does not,
so both are here.

| Run | Condition | Accuracy | p50 | Speedup |
| --- | --- | ---: | ---: | ---: |
| `holo-axcrop.json` (Aug 21, 07:06) | full frame | 10 of 12 | 7,005 ms | |
| | AX-aimed crop | 10 of 12 | 2,359 ms | 2.97x, accuracy matched |
| `live-eval.json` (Aug 21, 11:54) | full frame | 11 of 12 (91.7%) | 7,317 ms | |
| | AX-aimed crop | 10 of 12 (83.3%) | 1,204 ms | 6.1x, one target lost |

The later run is faster and less accurate: the full frame beats the crop by one query in twelve.
With n = 12 one query is worth 8.3 percentage points, so the gap is small, but it points the wrong
way for a claim that the crop is free. What holds is narrower: on this one Chrome window, aimed
crops were 3 to 6 times faster, at a cost of zero or one target in twelve.

## What is not measured

- **Idle CPU and memory.** The harness exists (`--idlebench` in
  [`App.swift`](../Sources/ThatawayApp/App.swift): `getrusage` for CPU over a settled idle window,
  `task_info` for resident memory), but no result has been recorded, so there is no figure.
- **Startup time and battery use.**
- **End-to-end hybrid latency.** It was composed from a constant plus separately measured vision
  timings, never run and timed as one turn.
- **Accuracy outside Chrome.** See the section above.
- **The latency budget in CI.** `thataway-bench budget` exits non-zero on a violation, but it needs
  Accessibility and a live app, and a hosted runner has neither, so only a local run checks it.

## Reproduce the results

You need macOS 14 or newer on Apple silicon and Xcode. There are no third-party Swift
dependencies.

```bash
swift build -c release
swift test                                  # 233 tests, headless, no permissions needed
./.build/release/thataway-bench doctor      # environment and permission check
```

`doctor` exits 0 and prints four sections: environment, permissions (Accessibility and Screen
Recording, granted or denied), display layout, and the frontmost app. Run it first, because
everything except `swift test`, `doctor`, `axplan` and `exclusions` needs Accessibility or Screen
Recording.

The Python tests need a Python with Pillow:

```bash
python3 -m venv /tmp/thataway-venv
/tmp/thataway-venv/bin/python -m pip install pillow
/tmp/thataway-venv/bin/python -B Tools/tests/test_holo_server.py
/tmp/thataway-venv/bin/python -B Tools/tests/test_make_app.py
```

### The resolver result, with no permissions

`axplan` reads the committed Chrome snapshot, so it needs no permissions. Write the plan outside
the repository so the committed evidence file stays as it is, then compare:

```bash
./.build/release/thataway-bench axplan --data bench-data/google-chrome.json --targets 12 \
  --out /tmp/axplan-chrome.json
```

What reproduces is `ax_hit_rate: 1`, twelve exact hits over twelve plans, the same check CI runs.
`resolve_p50_ms` and `resolve_p90_ms` are timings and move with the machine and its load, so expect
the same order of magnitude as the committed 0.067 ms, not the same digits.

Three rows will not match the committed `bench-data/axplan-chrome.json`, because the personal
bookmark titles in the snapshot were replaced with placeholders after the run. Those three queries,
their scores and their aimed crops come out differently, and a fresh run reports 11 of 12 aimed
crops containing the target where the committed plan has 12. The vision harnesses read the
committed plans (`holo_axcrop.py` reads `axplan-chrome.json`, `live_eval.py` reads
`google-chrome-axplan.json` beside the snapshot), so do not point `--out` into `bench-data/`.

### The findings, with Accessibility granted

```bash
./.build/release/thataway-bench coldwarm --app "Logic Pro" --deadline 2000   # Finding 1
./.build/release/thataway-bench ax                                          # Finding 2
./.build/release/thataway-bench capture --scope window                       # Finding 4
./.build/release/thataway-bench budget                                       # non-zero exit on a violation
```

`thataway-bench` with no arguments or with `--help` prints its usage and exits 0, and `all` runs
only when named. The bench never walks an app on the exclusion list, and its captures leave those
apps' windows out, the same as the app.

### A whole turn without a human

```bash
./.build/release/ThatawayApp --selftest "the close button" --app "Google Chrome"
```

`--selftest` prints every coordinate the pointer would use instead of taking a screenshot.

### The vision half

The vision fallback needs a model that is not in this repository: a 4-bit MLX build of
H Company's Holo1.5-7B (Apache 2.0) at `~/models/holo1.5-7b-4bit`, 5.65 GB on disk, plus a
Python with `mlx_vlm` and Pillow. PHASE-0 Finding 6 started from the 16.6 GB BF16 build at
`mlx-community/holo1.5-7b-mlx` and quantized it. The accessibility path works without any of this,
but a fresh clone cannot run the vision half.
