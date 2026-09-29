// Debug builds only, like the stage it gates: a Release build carries neither
// the parser nor the stage, so it has no promo code path at all.
#if DEBUG

import Foundation

/// How the app was asked to start: as the menu bar app, or (Debug builds
/// only) as the promo stage that renders `docs/media` for
/// `scripts/make_media.sh`.
///
/// Pure, so "a normal launch never enters the stage" is a unit test and not a
/// promise. The stage itself lives in `Sources/ThatawayApp/Promo/`, wrapped in
/// `#if DEBUG`, and `ThatawayApp.main()` asks this parser before it creates
/// the app delegate, the tree cache, the hotkey tap, the status item, the
/// overlay, voice, or anything that could show a permission prompt.
public enum PromoLaunch: Equatable, Sendable {
    /// No promo flag: start the app as usual.
    case normal
    /// `--promo-stills <dir>`: render the stills, icon and social preview.
    case stills(directory: String)
    /// `--promo <dir> --promo-scene <name>`: play one scene for the recorder.
    case scene(name: String, directory: String)
    /// A promo flag was given but the rest does not parse. The caller exits
    /// with the message rather than falling through to the real app.
    case invalid(String)

    public static let stillsFlag = "--promo-stills"
    public static let stageFlag = "--promo"
    public static let sceneFlag = "--promo-scene"

    /// Whether this module was compiled for Debug. A Release build passes
    /// false and so can never leave `.normal`.
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Decide from the process arguments (`CommandLine.arguments`, program
    /// name first). Flags match exactly; anything else is left to the app.
    public static func parse(_ arguments: [String], debugBuild: Bool) -> PromoLaunch {
        guard debugBuild else { return .normal }
        let args = Array(arguments.dropFirst())
        let flags = [stillsFlag, stageFlag, sceneFlag]
        guard args.contains(where: { flags.contains($0) }) else { return .normal }

        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]
            return v.isEmpty || v.hasPrefix("-") ? nil : v
        }

        if args.contains(stillsFlag) {
            guard !args.contains(stageFlag), !args.contains(sceneFlag) else {
                return .invalid("\(stillsFlag) cannot be combined with \(stageFlag) or \(sceneFlag)")
            }
            guard let dir = value(after: stillsFlag) else {
                return .invalid("\(stillsFlag) needs an output directory")
            }
            return .stills(directory: dir)
        }
        guard let dir = value(after: stageFlag) else {
            return .invalid("\(stageFlag) needs a handshake directory")
        }
        guard let name = value(after: sceneFlag) else {
            return .invalid("\(stageFlag) needs \(sceneFlag) <name>")
        }
        return .scene(name: name, directory: dir)
    }
}

#endif
