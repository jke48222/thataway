import Foundation

/// Hold to speak, tap to type — decided on the hardware timestamps of the
/// key events, never on when the main thread got round to looking.
///
/// The main thread can be busy for a couple of hundred milliseconds at the
/// exact moment a hold starts (a cold tree read after switching apps), and
/// the key-up handler queues behind it. Timing the hold with a wall clock
/// read on main therefore measured scheduling, not the user's finger, and
/// threw real holds away as taps. The event tap stamps both edges on one
/// monotonic axis, so the classification lives here, on those two numbers.
///
/// Pure: Foundation only, no clocks, no side effects. The caller performs
/// whatever `Action` comes back.
public struct PushToTalk: Equatable {

    public enum Action: Equatable {
        /// A new hold began: open the microphone now, before anything else.
        case startListening
        /// A key-down arrived while a hold was already open and too long
        /// after the last one to be auto-repeat: the previous key-up was
        /// lost. Close the stale capture and start a fresh one.
        case restartListening
        /// Released quickly with nothing heard: it was a tap, so drop the
        /// audio and leave the bar open for typing.
        case cancelToTyping
        /// Released after a real hold (or a short one that already produced
        /// words): stop the microphone and deliver what was said.
        case finishUtterance
        /// Nothing to do: auto-repeat, or a key-up with no hold open.
        case ignore
    }

    /// Below this a release counts as a tap. 300 ms is comfortably longer
    /// than a deliberate tap and shorter than any spoken word.
    public var tapThresholdNs: UInt64 = 300_000_000
    /// Key-downs closer together than this while a hold is open are
    /// auto-repeat. The slowest system initial-repeat delay is about 2 s.
    public var repeatWindowNs: UInt64 = 2_500_000_000
    /// The microphone never outlives the hold, and a hold whose key-up is
    /// lost must not become an open microphone. This is the backstop.
    public var maxHoldNs: UInt64 = 30_000_000_000

    public private(set) var downAtNs: UInt64?
    private var lastDownSeenNs: UInt64 = 0

    public init() {}

    public var isHolding: Bool { downAtNs != nil }

    public mutating func keyDown(atNs t: UInt64) -> Action {
        if downAtNs != nil {
            if t <= lastDownSeenNs || t - lastDownSeenNs <= repeatWindowNs {
                lastDownSeenNs = max(lastDownSeenNs, t)
                return .ignore
            }
            downAtNs = t
            lastDownSeenNs = t
            return .restartListening
        }
        downAtNs = t
        lastDownSeenNs = t
        return .startListening
    }

    public mutating func keyUp(atNs t: UInt64, heardText: Bool) -> Action {
        guard let down = downAtNs else { return .ignore }
        downAtNs = nil
        let held = t > down ? t - down : 0
        if held < tapThresholdNs && !heardText { return .cancelToTyping }
        return .finishUtterance
    }

    /// Call when the backstop timer fires. Ends a hold that has outlived
    /// `maxHoldNs`; ignores one that has already been released or restarted.
    public mutating func expire(atNs t: UInt64) -> Action {
        guard let down = downAtNs, t > down, t - down >= maxHoldNs else { return .ignore }
        downAtNs = nil
        return .finishUtterance
    }

    /// The turn ended some other way (Escape, Return, focus loss).
    public mutating func reset() {
        downAtNs = nil
    }
}

/// A monotonically increasing turn number, readable from any queue.
///
/// Every user-visible turn (summon, submit, cancel, lesson start or stop)
/// advances it. Work that outlives its turn — a vision call can take ten
/// seconds, far longer on first model load — captures the number when it
/// starts and checks it before touching the screen, so a late answer can
/// never overwrite a newer one.
public final class TurnClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    public init() {}

    public var current: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    @discardableResult
    public func advance() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }

    public func isCurrent(_ turn: UInt64) -> Bool { current == turn }
}
