import AppKit
import CoreGraphics
import ScreenCoachCore

/// Global hotkey via `CGEventTap`.
///
/// Chosen over Carbon's `RegisterEventHotKey` for one measurement-critical
/// reason: the tap hands over the original `CGEvent`, and
/// `CGEventGetTimestamp` on it is the moment the *hardware* event entered the
/// system, in raw mach units. Timing from there instead of from "when my
/// callback ran" means the reported hotkey→frame figure includes event
/// delivery — which is part of what the user feels, and is exactly the term a
/// naive harness hides from itself.
///
/// The tap consumes the binding and nothing else. The key-down, its
/// auto-repeats and the matching key-up are swallowed; every other event
/// passes through untouched. Letting Option-Space through would type a
/// non-breaking space (U+00A0) at the caret of whatever the user was editing
/// on every summon, and trigger whatever that app binds to the chord. The
/// tap runs on its own thread, and the system disables a tap whose callback
/// stalls, so a hung coach still cannot wedge the keyboard: the callback does
/// no work beyond matching the key.
///
/// Known limit: while any process has Secure Event Input on (a focused
/// password field, Terminal's Secure Keyboard Entry), no session tap sees
/// keystrokes, so the hotkey does nothing until it is turned off.
public final class HotKeyTap {

    public struct Binding: Equatable {
        public let keyCode: UInt16
        public let flags: CGEventFlags

        public init(keyCode: UInt16, flags: CGEventFlags) {
            self.keyCode = keyCode
            self.flags = flags
        }

        /// Option-Space, matching WindowPet's default summon.
        public static let optionSpace = Binding(keyCode: 49, flags: .maskAlternate)

        static let significant: CGEventFlags = [
            .maskCommand, .maskShift, .maskAlternate, .maskControl,
        ]

        func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
            keyCode == self.keyCode
                && flags.intersection(Self.significant) == self.flags.intersection(Self.significant)
        }
    }

    /// Fired with the hardware event's timestamp, already on the `Mono` axis.
    public var onHotKey: ((UInt64) -> Void)?

    /// Fired when the key is released. Push-to-talk is a *hold*, so the turn
    /// is bracketed by these two rather than triggered by one.
    public var onHotKeyUp: ((UInt64) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let binding: Binding
    private let ready = DispatchSemaphore(value: 0)

    public init(binding: Binding = .optionSpace) {
        self.binding = binding
        self.machine = Machine(binding: binding)
    }

    public enum TapError: Error, CustomStringConvertible {
        case tapCreationFailed
        public var description: String {
            "CGEvent.tapCreate failed — Accessibility permission is required for event taps"
        }
    }

    /// Runs the tap on a thread of its own rather than the main run loop.
    ///
    /// Two reasons, both real. The system disables any tap whose callback
    /// runs long, so a tap sharing a thread with UI work is a tap that
    /// eventually goes deaf. And it frees callers to be plain async code
    /// instead of having to keep a run loop spinning to stay listening.
    public func start() throws {
        var thrown: Error?
        let t = Thread { [weak self] in
            guard let self else { return }
            do {
                try self.install()
            } catch {
                thrown = error
                self.ready.signal()
                return
            }
            self.runLoop = CFRunLoopGetCurrent()
            self.ready.signal()
            CFRunLoopRun()
        }
        t.name = "coach.hotkey.tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        if let thrown { throw thrown }
    }

    private func install() throws {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            // Swallow the binding; pass everything else through untouched.
            guard me.handle(type: type, event: event) == .pass else { return nil }
            return Unmanaged.passUnretained(event)
        }

        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: refcon
        ) else { throw TapError.tapCreationFailed }

        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
        }
        source = nil
        tap = nil
        runLoop = nil
        thread = nil
    }

    enum Disposition: Equatable { case pass, consume }

    /// What a tap would do with one event. Separated from the tap so the
    /// state machine can be driven by tests without a keyboard.
    struct Machine {
        let binding: Binding
        private(set) var isDown = false

        init(binding: Binding) { self.binding = binding }

        enum Output: Equatable { case none, down, up, upThenDown }

        /// - Parameter keyIsPhysicallyDown: asked only when the tap was
        ///   disabled while the key was held, to recover a lost key-up.
        mutating func feed(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                           isAutorepeat: Bool,
                           keyIsPhysicallyDown: () -> Bool) -> (Disposition, Output) {
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // Events may have been missed while the tap was off. If the
                // key-up was one of them, end the hold now: a microphone left
                // running is the worst possible failure for this app.
                if isDown && !keyIsPhysicallyDown() {
                    isDown = false
                    return (.pass, .up)
                }
                return (.pass, .none)

            case .keyDown:
                if isDown && keyCode == binding.keyCode {
                    // Auto-repeat of the held chord: swallow it, or it types
                    // into whatever becomes key while the user is speaking.
                    if isAutorepeat { return (.consume, .none) }
                    // A fresh press while we still think the key is down
                    // means a key-up was lost. Close the old turn, open a new
                    // one.
                    if binding.matches(keyCode: keyCode, flags: flags) {
                        return (.consume, .upThenDown)
                    }
                    // A plain press of the same key: the chord was released
                    // while we were not looking. End the hold and let the
                    // keystroke through; it belongs to the user's app.
                    isDown = false
                    return (.pass, .up)
                }
                guard binding.matches(keyCode: keyCode, flags: flags) else { return (.pass, .none) }
                // Auto-repeat fires keyDown continuously while a key is held;
                // a push-to-talk turn must begin exactly once.
                if isAutorepeat { return (.consume, .none) }
                isDown = true
                return (.consume, .down)

            case .keyUp:
                // Match on the key code alone, deliberately. Releasing Option
                // before Space changes the modifier flags, so requiring the
                // full combination here would drop the release and leave the
                // microphone running.
                guard isDown, keyCode == binding.keyCode else { return (.pass, .none) }
                isDown = false
                return (.consume, .up)

            default:
                return (.pass, .none)
            }
        }
    }

    private var machine: Machine

    private func handle(type: CGEventType, event: CGEvent) -> Disposition {
        // The system disables a tap that ever runs long; re-arm rather than
        // going silently deaf.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        let isKey = type == .keyDown || type == .keyUp
        let code = isKey ? UInt16(event.getIntegerValueField(.keyboardEventKeycode)) : 0
        let repeatFlag = isKey && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let keyCode = binding.keyCode
        let (disposition, output) = machine.feed(
            type: type, keyCode: code, flags: isKey ? event.flags : [],
            isAutorepeat: repeatFlag,
            keyIsPhysicallyDown: {
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
            })
        let ts = isKey ? Mono.machToNs(event.timestamp) : Mono.nowNs()
        switch output {
        case .none: break
        case .down: onHotKey?(ts)
        case .up: onHotKeyUp?(ts)
        case .upThenDown:
            onHotKeyUp?(ts)
            onHotKey?(ts)
        }
        return disposition
    }

    deinit { stop() }
}
