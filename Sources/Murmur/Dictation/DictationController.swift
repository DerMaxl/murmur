import AVFoundation
import AppKit
import ApplicationServices

/// How the trigger key behaves. Exactly one is active at a time (selectable from the
/// menu now, a settings dropdown later).
enum DictationMode: String, CaseIterable, Sendable {
    case holdToTalk     // hold to record, release to stop
    case tapToggle      // tap to start, tap again to stop (always hands-free)
    case hybrid         // tap = hands-free toggle; hold = push-to-talk
    case holdWithLatch  // hold to talk; holding past a moment latches it hands-free

    var displayName: String {
        switch self {
        case .holdToTalk: return "Hold the key while you talk"
        case .tapToggle: return "Tap to start, tap again to stop"
        case .hybrid: return "Tap to start/stop, or hold to talk"
        case .holdWithLatch: return "Hold to talk, keep holding to lock it on"
        }
    }
}

/// Push-to-talk / hands-free dictation. The trigger-key gesture is interpreted
/// according to the selected `DictationMode`; the transcribed text is typed at the
/// cursor in the focused app.
///
/// Owns its own recorder (separate from voice-memo recording) writing to a temp
/// file that is transcribed and then discarded, so dictation never clutters the
/// recordings list.
@MainActor
final class DictationController {
    var triggerDescription: String { Settings.dictationShortcut.display }

    /// A key press shorter than this counts as a tap (toggle); longer is a hold.
    private let tapThreshold: TimeInterval = 0.4

    private enum Phase {
        case idle        // not recording
        case holding     // key down; undecided between hold and tap
        case handsFree   // recording continues after a tap, until the next tap
    }

    private let engine: TranscriptionEngine
    /// The current capture's recorder. A fresh instance is made per capture (see
    /// `startCapture`) so a slow, superseded, or timed-out start only ever tears down its
    /// own engine and file, never a newer recording's.
    private var recorder: CrashSafeRecorder?
    private let injector = TextInjector()
    private var hotkey: GlobalHotkey
    /// In hold-with-latch mode, holding longer than this latches the recording.
    private let latchThreshold: TimeInterval = 1.5

    private var tempURL: URL?
    private var phase: Phase = .idle
    private var pressedAt: Date?
    private var beganAt: Date?
    private var latched = false
    private var latchTask: Task<Void, Never>?
    /// Mutes/restores system output around a dictation (only restores what it muted).
    private let ducker = AudioDucker()

    private(set) var isEnabled = false
    var isDictating: Bool { phase != .idle }
    /// True from when a recording stops until its transcript is injected, so the HUD can
    /// stay up showing a "finishing" state (the transcription can take a moment, most of
    /// all on a cold model load).
    private(set) var isFinishing = false

    /// Return false to veto starting dictation (e.g. a voice memo is recording).
    var canStart: (@MainActor () -> Bool)?
    var onStateChange: (@MainActor () -> Void)?
    /// Live mic loudness (0...1) while dictating, for the meter HUD.
    var onLevel: (@MainActor (Float) -> Void)?
    /// Delivers the dictated text (how long it took, and the app it was typed into)
    /// once injected, so it can be saved to history. Not called for empty/no-speech
    /// dictations.
    var onTranscript: (@MainActor (String, TimeInterval, String?) -> Void)?
    /// A brief transient message for the HUD, e.g. when a recording couldn't start.
    var onNotice: (@MainActor (String) -> Void)?
    /// The capture succeeded but its transcription failed. Hands over the audio file
    /// (ownership transfers to the callee) so the speech can be preserved and retried
    /// instead of lost.
    var onTranscriptionFailed: (@MainActor (URL, TimeInterval, String?) -> Void)?

    init(engine: TranscriptionEngine) {
        self.engine = engine
        self.hotkey = GlobalHotkey(shortcut: Settings.dictationShortcut)
        wireHotkey()
    }

    private func wireHotkey() {
        hotkey.onPress = { [weak self] in self?.keyPressed() }
        hotkey.onRelease = { [weak self] in self?.keyReleased() }
        hotkey.onComboKey = { [weak self] in self?.comboKeyPressed() }
    }

    /// A key was pressed while the (bare-modifier) trigger is held, so it's being used
    /// as a modifier, e.g. Fn+Delete, not a push-to-talk hold. Cancel the dictation we
    /// just started and discard it, without transcribing or injecting anything.
    private func comboKeyPressed() {
        guard phase == .holding else { return }
        abortCapture()
    }

    // MARK: Return / Enter to end a dictation

    /// While a dictation is in progress, Return or the numeric-keypad Enter ends it
    /// (handy for the hands-free modes, where there's no key to release). These taps
    /// consume the keystroke so it doesn't also type a newline into the focused app,
    /// and are armed only for the duration of a dictation, so normal typing is
    /// unaffected the rest of the time. Return = 36, keypad Enter = 76.
    private var stopKeys: [GlobalHotkey] = []

    private func armStopKeys() {
        guard stopKeys.isEmpty else { return }
        for keyCode in [Int64(36), Int64(76)] {
            let key = GlobalHotkey(shortcut: Shortcut(keyCode: keyCode, modifiers: []))
            key.onPress = { [weak self] in self?.endByStopKey() }
            _ = key.start()
            stopKeys.append(key)
        }
    }

    private func disarmStopKeys() {
        stopKeys.forEach { $0.stop() }
        stopKeys.removeAll()
    }

    /// Called from a stop-key tap callback. Defer the actual finish to the next run-loop
    /// turn so we're not tearing down the very event tap whose callback we're inside.
    private func endByStopKey() {
        guard phase != .idle else { return }
        Task { @MainActor [weak self] in self?.finishCapture() }
    }

    /// Switch the trigger shortcut, rebuilding the event tap so it takes effect now.
    /// Re-arms the tap if dictation is currently enabled.
    func setShortcut(_ shortcut: Shortcut) {
        guard shortcut != Settings.dictationShortcut else { return }
        Settings.dictationShortcut = shortcut
        let wasRunning = isEnabled
        hotkey.stop()
        hotkey = GlobalHotkey(shortcut: shortcut)
        wireHotkey()
        if wasRunning { _ = hotkey.start() }
        onStateChange?()
        Log.info("Dictation shortcut changed to \(shortcut.display)")
    }

    private static let enabledDefaultsKey = "dictationEnabled"

    func toggle() {
        if isEnabled { disable() } else { enable() }
    }

    /// Re-enable on launch if it was on last time AND Accessibility is still granted.
    /// Never prompts here, so launch is silent; the user re-enables manually if the
    /// grant was revoked.
    func restoreIfPreviouslyEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey),
              Self.accessibilityTrusted(prompt: false) else { return }
        if hotkey.start() {
            isEnabled = true
            onStateChange?()
            Log.info("Dictation restored from last session")
        }
    }

    /// Turn dictation on. Requires Accessibility permission; prompts if missing.
    @discardableResult
    func enable() -> Bool {
        guard !isEnabled else { return true }
        guard Self.accessibilityTrusted(prompt: true), hotkey.start() else {
            presentAccessibilityNeeded()
            // Notify so a UI toggle that flipped us on snaps back to off (we're not on).
            onStateChange?()
            return false
        }
        isEnabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
        onStateChange?()
        Log.info("Dictation enabled (hold \(triggerDescription))")
        return true
    }

    func disable() {
        guard isEnabled else { return }
        if isDictating { finishCapture() }
        hotkey.stop()
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
        onStateChange?()
        Log.info("Dictation disabled")
    }

    // MARK: Gesture handling (per DictationMode)

    private func keyPressed() {
        guard isEnabled else { return }
        switch Settings.dictationMode {
        case .holdToTalk:
            if phase == .idle { startCapture(into: .holding) }
        case .tapToggle:
            if phase == .idle { startCapture(into: .handsFree) } else { finishCapture() }
        case .hybrid:
            if phase == .handsFree { finishCapture() }
            else if phase == .idle { startCapture(into: .holding) }
        case .holdWithLatch:
            if phase == .handsFree { finishCapture() }
            else if phase == .idle { startCapture(into: .holding); scheduleLatch() }
        }
    }

    private func keyReleased() {
        guard isEnabled, phase == .holding else { return }
        switch Settings.dictationMode {
        case .holdToTalk:
            finishCapture()
        case .tapToggle:
            break   // toggled on press; releases are ignored
        case .hybrid:
            let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
            if held < tapThreshold { enterHandsFree() } else { finishCapture() }
        case .holdWithLatch:
            cancelLatch()
            if latched { enterHandsFree() } else { finishCapture() }
        }
    }

    /// Switch an in-progress hold over to hands-free: the key is released, so the combo
    /// cancel no longer applies and Return/Enter become the way to stop.
    private func enterHandsFree() {
        phase = .handsFree
        armStopKeys()
        onStateChange?()
    }

    private func scheduleLatch() {
        cancelLatch()
        let threshold = latchThreshold
        // A Task created here inherits the @MainActor context, so touching `latched`
        // is concurrency-safe (unlike a DispatchQueue.main work item under Swift 6).
        latchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(threshold))
            guard !Task.isCancelled, let self, self.phase == .holding else { return }
            self.latched = true
        }
    }

    private func cancelLatch() {
        latchTask?.cancel()
        latchTask = nil
    }

    // MARK: Capture

    /// Identifies the current capture attempt, so an engine start that finishes late (or
    /// after the gesture already ended) can tell it was superseded.
    private var captureID = 0
    /// True while the audio engine is still starting on a background thread.
    private var startInFlight = false
    /// What to do once the engine finishes starting, if the gesture ended first.
    private enum EndRequest { case finish(duration: TimeInterval, targetApp: String?), abort }
    private var endRequest: EndRequest?

    private func startCapture(into newPhase: Phase) {
        if let canStart, !canStart() { return }   // e.g. a meeting is recording
        guard ensureMicrophoneAccess() else { return }   // prompt on first use; bail if denied
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-dictation-\(UUID().uuidString).caf")

        // A fresh recorder per capture: its start/stop only ever touch its own engine and
        // file, so a slow, superseded, or timed-out start can never tear down a newer
        // recording (the Task below owns this instance for its whole lifetime).
        let recorder = CrashSafeRecorder()
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        recorder.onWriteFailure = { [weak self] in
            Task { @MainActor in self?.onNotice?("Recording isn't being saved — check disk space") }
        }
        // Record from the user's chosen mic (settings), or the system default when unset.
        recorder.inputDeviceID = CrashSafeRecorder.preferredInputDevice()
        self.recorder = recorder

        // Set the UI state up front so the HUD appears instantly; the recording is only
        // "confirmed" once the engine actually starts (in the Task below).
        captureID &+= 1
        let id = captureID
        startInFlight = true
        endRequest = nil
        isFinishing = false
        phase = newPhase
        let now = Date()   // one instant: recording start (beganAt) and key-down (pressedAt)
        beganAt = now
        pressedAt = now
        latched = false
        tempURL = url
        ducker.duckIfPlaying()
        // Return/Enter end a hands-free dictation. During a pure hold we don't arm them:
        // you stop by releasing the key, and any key press cancels (see comboKeyPressed).
        if newPhase == .handsFree { armStopKeys() }
        onStateChange?()

        // Start the engine off the main thread so a wedged CoreAudio call can't freeze the
        // UI; a timeout turns an indefinite stall into a clean "couldn't start" instead.
        Task { [weak self] in
            let started = await recorder.startAsync(writingTo: url)
            guard let self, self.captureID == id else {
                // No controller, or a newer capture superseded this one: tear down our own
                // recorder (a separate instance) and don't leak the temp file.
                if started { await recorder.stopAsync() }
                try? FileManager.default.removeItem(at: url)
                return
            }
            self.startInFlight = false
            guard started else { self.startFailed(url: url); return }
            // The gesture may have ended while the engine was still starting.
            switch self.endRequest {
            case .finish(let duration, let targetApp):
                self.endRequest = nil
                await recorder.stopAsync()
                self.transcribeAndInject(url: url, duration: duration, targetApp: targetApp)
            case .abort:
                self.endRequest = nil
                await recorder.stopAsync()
                try? FileManager.default.removeItem(at: url)
            case .none:
                Sounds.recordingStarted()   // recording is live
            }
        }
    }

    /// Reset the per-capture state back to idle. Callers handle `isFinishing` themselves
    /// (a finish keeps the HUD up; an abort or a failed start clears it). Callers that still
    /// need the recorder must copy `self.recorder` into a local *before* calling this.
    private func resetCaptureState() {
        phase = .idle
        tempURL = nil
        beganAt = nil
        pressedAt = nil
        latched = false
        recorder = nil   // release the stopped recorder (and its engine) between captures
    }

    /// Stop and discard an in-progress dictation: no transcription, no injection. Used
    /// when the hold trigger turns out to be part of a key combo (e.g. Fn+Delete).
    private func abortCapture() {
        cancelLatch()
        disarmStopKeys()
        guard phase != .idle, let url = tempURL else { resetCaptureState(); return }
        ducker.restore()
        let recorder = self.recorder
        resetCaptureState()
        isFinishing = false
        if startInFlight {
            endRequest = .abort   // the start Task tears it down once the engine comes up
        } else {
            Task { await recorder?.stopAsync(); try? FileManager.default.removeItem(at: url) }
        }
        onStateChange?()
        Log.info("Dictation cancelled (trigger used as a modifier)")
    }

    private func finishCapture() {
        cancelLatch()
        disarmStopKeys()
        guard phase != .idle, let url = tempURL else { resetCaptureState(); return }
        ducker.restore()   // unmute the moment the gesture ends
        Sounds.recordingStopped()
        let duration = beganAt.map { Date().timeIntervalSince($0) } ?? 0
        // The frontmost app right now is the one that'll receive the text (our accessory
        // app never takes focus); record it for the history view.
        let targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let recorder = self.recorder
        resetCaptureState()
        isFinishing = true   // keep the HUD up in a "finishing" state until text lands
        onStateChange?()
        if startInFlight {
            // Engine still starting: hand the stop + transcription to the start Task.
            endRequest = .finish(duration: duration, targetApp: targetApp)
        } else {
            Task { [weak self] in
                await recorder?.stopAsync()   // flush the file before transcribing
                self?.transcribeAndInject(url: url, duration: duration, targetApp: targetApp)
            }
        }
    }

    /// Synchronous cleanup for app termination: restore any ducked audio and release
    /// the microphone before the process exits. Without this, quitting mid-dictation
    /// leaves the system output muted until the next launch (the ducked volume is
    /// persisted, but only restored at startup). The dictation itself is abandoned -
    /// quitting mid-hold is an explicit user choice - so the temp file is removed.
    func stopAtTerminate() {
        guard phase != .idle else { return }
        cancelLatch()
        disarmStopKeys()
        ducker.restore()
        let recorder = self.recorder
        let url = tempURL
        resetCaptureState()
        isFinishing = false
        recorder?.stopSync()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Roll back the optimistic state when the engine couldn't start (a wedged or slow
    /// audio system) and show a brief notice instead of freezing.
    private func startFailed(url: URL) {
        cancelLatch()
        disarmStopKeys()
        endRequest = nil
        ducker.restore()
        try? FileManager.default.removeItem(at: url)
        resetCaptureState()
        isFinishing = false
        onStateChange?()
        onNotice?("Couldn't start recording")
        Log.error("Dictation couldn't start (audio system busy)")
    }

    /// Transcribe the captured audio, inject it at the cursor, and hand off the text to be
    /// saved. Runs the model off the main actor; clears the finishing state when done.
    private func transcribeAndInject(url: URL, duration: TimeInterval, targetApp: String?) {
        Task { [engine, weak self] in
            do {
                let transcript = try await engine.transcribe(fileAt: url, onPartial: nil)
                let cleaned = TextCleaner.process(transcript.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    // Optional on-device AI polish (stutters / false starts). Adds latency,
                    // so it's gated by a setting; falls back to the cleaned text.
                    let text = await Polisher.polishIfEnabled(cleaned)
                    await MainActor.run {
                        self?.injector.inject(text)
                        self?.onTranscript?(text, duration, targetApp)
                    }
                }
                // Success (or genuine silence): dictations are text-only, discard the audio.
                try? FileManager.default.removeItem(at: url)
            } catch {
                // The speech is on disk and retryable - hand it over rather than delete
                // it (losing a dictation to a transient engine failure breaks the app's
                // "your recording is always saved" rule).
                Log.error("Dictation transcription failed: \(error.localizedDescription)")
                await MainActor.run {
                    if let self, let handler = self.onTranscriptionFailed {
                        handler(url, duration, targetApp)
                    } else {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            await MainActor.run {
                self?.isFinishing = false
                self?.onStateChange?()
            }
        }
    }

    // MARK: Permission

    /// Microphone gate for dictation, mirroring meeting capture. Returns true when we
    /// can record now; otherwise it triggers the system prompt (first use) or points the
    /// user to Settings (previously denied) and returns false, so we never "record"
    /// silence the user thinks was captured. On a first-use prompt the recording is
    /// skipped; the next press, after granting, works.
    private func ensureMicrophoneAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return false
        default:
            presentMicrophoneDenied()
            return false
        }
    }

    private func presentMicrophoneDenied() {
        let alert = NSAlert()
        alert.messageText = "Microphone access needed"
        alert.informativeText = "To dictate, enable Murmur under System Settings → "
            + "Privacy & Security → Microphone, then try again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func accessibilityTrusted(prompt: Bool) -> Bool {
        // Value of the kAXTrustedCheckOptionPrompt constant. Referenced by literal to
        // avoid touching the imported global var (not concurrency-safe under Swift 6).
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    private func presentAccessibilityNeeded() {
        let alert = NSAlert()
        alert.messageText = "Accessibility access needed"
        alert.informativeText = "To type dictated text into other apps, enable Murmur "
            + "under System Settings → Privacy & Security → Accessibility, then turn "
            + "dictation on again. You may need to relaunch Murmur after granting it."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
