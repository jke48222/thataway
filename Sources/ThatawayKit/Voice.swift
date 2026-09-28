import AVFoundation
import ThatawayCore
import Speech

/// Push-to-talk speech in, spoken answers out. Entirely on-device.
///
/// The microphone runs only between `begin()` and `end()` — while the key is
/// physically held. No always-on listening, no wake word, no permanent
/// recording indicator, and nothing to leave the machine. For an app that
/// already needs permission to read your screen, an always-live microphone is
/// one ask too many.
///
/// `requiresOnDeviceRecognition` is set whenever the locale supports it, which
/// makes "zero bytes leave the machine" a property of the code rather than a
/// claim in a README. When the locale has no on-device model the recogniser
/// would fall back to Apple's servers, so this refuses instead and says why.
public final class Voice: NSObject {

    public enum Availability: Equatable {
        case ready(onDevice: Bool)
        case needsPermission(String)
        case unavailable(String)
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var delivered = false
    private var startedAtNs: UInt64 = 0
    /// Identifies the current hold. Every callback and timer captures the
    /// turn it belongs to and does nothing if a newer turn has begun, so a
    /// late result or a leftover timer from one hold can never deliver into
    /// the next.
    private var turn = 0
    private var ceilingWork: DispatchWorkItem?

    /// Live transcript while the key is held.
    public var onPartial: ((String) -> Void)?
    /// The finished utterance, with the milliseconds from key-release to final
    /// text — the STT term of the latency budget.
    public var onFinal: ((String, Double) -> Void)?
    public var onState: ((String) -> Void)?

    /// Refuse to send audio off-device. If the recogniser cannot work locally
    /// the feature is off, not silently remote.
    public var localOnly = true

    /// Longest the microphone may stay open for one hold. A key-up that never
    /// arrives must not leave the microphone live until the next press.
    ///
    /// This is the last-resort backstop, not the hold limit. The hold limit
    /// is `PushToTalk.maxHoldNs`, which the app enforces (and which the event
    /// tap's lost-key-up recovery backs up). A ceiling here shorter than that
    /// cut legitimate holds short: at 15 s it ended a 16 s description while
    /// the key was still down and acted on half a sentence. So it sits just
    /// past the push-to-talk limit and only fires if that one did not.
    public var maxListenSeconds: TimeInterval = Voice.listenCeiling(forMaxHoldNs: PushToTalk().maxHoldNs)

    /// The backstop for a hold limit of `maxHoldNs`: the limit plus a second.
    public static func listenCeiling(forMaxHoldNs maxHoldNs: UInt64) -> TimeInterval {
        Double(maxHoldNs) / 1e9 + 1
    }

    public private(set) var isListening = false

    public override init() {
        super.init()
    }

    // MARK: - Permissions

    public static var permissionSummary: String {
        func name(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
            switch s {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .restricted: return "restricted"
            case .notDetermined: return "not asked"
            @unknown default: return "unknown"
            }
        }
        func mic(_ s: AVAuthorizationStatus) -> String {
            switch s {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .restricted: return "restricted"
            case .notDetermined: return "not asked"
            @unknown default: return "unknown"
            }
        }
        return "speech \(name(SFSpeechRecognizer.authorizationStatus())), "
             + "mic \(mic(AVCaptureDevice.authorizationStatus(for: .audio)))"
    }

    public var availability: Availability {
        guard let recognizer else { return .unavailable("no recogniser for this locale") }
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            return .needsPermission("Speech Recognition")
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            return .needsPermission("Microphone")
        }
        guard recognizer.isAvailable else { return .unavailable("recogniser unavailable") }
        if localOnly && !recognizer.supportsOnDeviceRecognition {
            return .unavailable("no on-device model for this locale: "
                              + "voice is off rather than sending audio to a server")
        }
        return .ready(onDevice: recognizer.supportsOnDeviceRecognition)
    }

    /// Asks for both permissions up front rather than mid-utterance. Being
    /// interrupted by a dialog while holding a key to speak loses the turn.
    public func requestPermissions(_ done: @escaping (Availability) -> Void) {
        // Asking without the usage strings is not a prompt: TCC kills the
        // process. An unbundled `swift build` binary has no Info.plist, so it
        // reports the current state instead of asking.
        guard Self.canAskForPermission else {
            DispatchQueue.main.async { [weak self] in
                done(self?.availability ?? .unavailable("gone"))
            }
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { done(self?.availability ?? .unavailable("gone")) }
            }
        }
    }

    /// Whether this process can show the Speech and Microphone prompts at
    /// all: only a bundle whose Info.plist carries both usage strings can.
    public static var canAskForPermission: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["NSMicrophoneUsageDescription"] != nil
            && info["NSSpeechRecognitionUsageDescription"] != nil
    }

    /// True while either permission has never been asked for. Only then can
    /// asking show a dialog; once denied, the user has to go to System
    /// Settings, and asking again does nothing.
    public static var permissionsUndetermined: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
            || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    /// Asks only if a dialog can actually appear, then reports the result.
    /// Safe to call on every launch and every summon.
    public func requestPermissionsIfNeeded(_ done: @escaping (Availability) -> Void) {
        guard Self.permissionsUndetermined else {
            done(availability)
            return
        }
        requestPermissions(done)
    }

    // MARK: - Listening

    public func begin() {
        guard !isListening else { return }
        guard case .ready = availability else {
            if Self.permissionsUndetermined && Self.canAskForPermission {
                // First use: ask now, so the dialogs appear and the app shows
                // up in the Privacy panes. This hold is lost; the next works.
                onState?("asking for microphone and speech permission…")
                requestPermissions { [weak self] a in
                    guard let self else { return }
                    if case .ready = a {
                        self.onState?("voice ready: hold ⌥Space and speak")
                    } else {
                        self.onState?(self.describe(a))
                    }
                }
            } else {
                onState?(describe(availability))
            }
            return
        }
        guard let recognizer else { return }

        // A new hold. Anything still running from the previous one is
        // abandoned, not merely replaced: its final result must not arrive
        // inside this turn.
        turn += 1
        let myTurn = turn
        task?.cancel()
        task = nil
        request = nil
        ceilingWork?.cancel()
        transcript = ""
        delivered = false
        startedAtNs = 0

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            onState?("no usable microphone input")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onState?("could not start the microphone: \(error.localizedDescription)")
            return
        }

        isListening = true
        onState?("listening")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.turn == myTurn else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.onPartial?(self.transcript)
                    if result.isFinal { self.deliver(turn: myTurn) }
                }
                if error != nil && !self.engine.isRunning { self.deliver(turn: myTurn) }
            }
        }

        // Hard ceiling on the hold, in case the key-up is never seen.
        let ceiling = DispatchWorkItem { [weak self] in
            guard let self, self.turn == myTurn, self.isListening else { return }
            self.onState?("stopped listening after \(Int(self.maxListenSeconds)) s")
            self.end()
        }
        ceilingWork = ceiling
        DispatchQueue.main.asyncAfter(deadline: .now() + maxListenSeconds, execute: ceiling)
    }

    /// Key released. Stop capturing immediately — the microphone must not
    /// outlive the hold by even a moment — then wait briefly for the
    /// recogniser to finalise what it already heard.
    public func end() {
        guard isListening else { return }
        isListening = false
        startedAtNs = Mono.nowNs()
        ceilingWork?.cancel()
        ceilingWork = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()

        // Finalisation is usually tens of milliseconds, but a recogniser that
        // never calls back would otherwise lose the turn silently. The timer
        // belongs to this turn only.
        let myTurn = turn
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.deliver(turn: myTurn)
        }
    }

    public func cancel() {
        turn += 1
        isListening = false
        delivered = true
        ceilingWork?.cancel()
        ceilingWork = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        task?.cancel()
        task = nil
        request = nil
    }

    private func deliver(turn deliveringTurn: Int) {
        guard deliveringTurn == turn, !delivered else { return }
        delivered = true
        task = nil
        request = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let ms = startedAtNs == 0 ? 0 : Mono.msSince(startedAtNs)
        guard !text.isEmpty else {
            onState?("didn't catch that")
            return
        }
        onFinal?(text, ms)
    }

    // MARK: - Speaking

    /// `AVSpeechSynthesizer`, on-device and free. Cloud voices sound better,
    /// but a coach whose answers require a network round trip is a coach that
    /// stops working on a plane — and every byte spoken here is a description
    /// of the user's own screen.
    public func speak(_ text: String) {
        guard !text.isEmpty else { return }
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
        utterance.postUtteranceDelay = 0
        if let voice = AVSpeechSynthesisVoice(identifier: AVSpeechSynthesisVoiceIdentifierAlex)
            ?? AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    public func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func describe(_ a: Availability) -> String {
        switch a {
        case .ready: return "ready"
        case .needsPermission(let what): return "\(what) permission needed"
        case .unavailable(let why): return why
        }
    }
}

