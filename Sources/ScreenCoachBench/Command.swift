/// Which subcommand a `screencoach-bench` invocation asks for.
///
/// Most subcommands read other apps' accessibility trees or capture the live
/// display, so nothing runs unless it was named. Asking for help (or giving
/// no arguments) prints the usage and exits 0; an unknown word, or options
/// with no command in front of them, prints the usage and exits 2. `all` is
/// reachable only by typing it.
enum BenchCommand: String, CaseIterable, Equatable {
    case doctor, ax, coldwarm, apps, dump, capture, hotkey, snap, staleness
    case windows, axplan, budget, exclusions, all

    enum Parsed: Equatable {
        case run(BenchCommand)
        case help
        /// Print the message and the usage to stderr, exit non-zero.
        case usageError(String)
    }

    static let helpFlags: Set<String> = ["--help", "-h"]

    /// `args` excludes the executable path.
    ///
    /// A help flag anywhere wins, so `screencoach-bench ax --help` explains
    /// itself instead of walking the frontmost app's tree. The bare word
    /// `help` counts only as the command, so `--app help` still means an app.
    static func parse(_ args: [String]) -> Parsed {
        guard let first = args.first, first != "help" else { return .help }
        if args.contains(where: helpFlags.contains) { return .help }
        if first.hasPrefix("-") {
            return .usageError("No command given before \(first).")
        }
        guard let command = BenchCommand(rawValue: first) else {
            return .usageError("Unknown command \"\(first)\".")
        }
        return .run(command)
    }

    static let usage = """
    screencoach-bench — Phase 0 latency harness

    USAGE
      screencoach-bench <command> [options]
      screencoach-bench --help

    COMMANDS
      doctor    Permissions and environment
      ax        AX tree extraction timing (batched vs per-attribute)
      coldwarm  First-touch vs steady-state AX cost, and how fast
                warmth decays — decides speculative extraction
      apps      Survey every running app: groundability + extraction cost
                (apps on the exclusion list are skipped, not walked)
      dump      Print the frontmost window's AX tree with bounds
      capture   Compare screencapture(1), SCScreenshotManager, warm SCStream
      hotkey    Interactive: real key press → frame in hand
      snap      Save the frontmost window as PNG + its AX tree as JSON,
                for the vision-grounding benchmark to work against
      staleness Compare the newest warm-stream frame with a fresh capture
      windows   List the windows ScreenCaptureKit will hand over
      axplan    Resolver hit rate + AX-aimed crop plans, from a snapshot
                (offline: reads only the --data JSON)
      budget    Measure every stage against LatencyBudget; non-zero exit
                on violation, so it can gate CI. --vision includes the
                model (slow, and loads 5.6 GB)
      exclusions  Watch the privacy list reload live
      all       doctor + ax + apps + capture (reads the accessibility
                tree and captures the screen; only runs when named)

    Every command except doctor, axplan and exclusions reads the
    accessibility tree or captures the live display, and needs the matching
    TCC permission.

    OPTIONS
      --trials N     Trials per measurement (default 30)
      --app NAME     Target a named running app instead of the frontmost
      --delay SEC    Countdown before measuring, to go focus something
      --scope S      capture scope: display | window   (default window)
      --max-nodes N  AX node cap (default 2500)
      --deadline MS  AX walk deadline (default 250)
      --targets N    Targets to measure in axplan (default 12)
      --data PATH    Snapshot JSON for axplan
                     (default bench-data/google-chrome.json)
      --out PATH     Output path; for axplan a file or a directory
                     (default axplan-chrome.json, or <snapshot>-axplan.json
                     for a given --data, in the temporary directory)
      --verbose      Per-trial detail
      -h, --help     Print this and exit
    """
}
