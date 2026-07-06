import AVFoundation
import AppKit

/// Records a meeting as **two clean tracks**: your microphone and the system / app
/// audio (the other participants), each streamed crash-safe to its own 16 kHz mono
/// CAF. Keeping them separate makes per-side transcription accurate and enables
/// speaker labelling later.
///
/// `@unchecked Sendable`: the mutable audio state (`isRecording`, `micStartedAt`,
/// `mic`/`system`) is only ever touched from `startQueue` — `start`/`stop` are private and
/// reached only through `startAsync`/`stopAsync`/`stopSync`, all of which hop onto that
/// serial queue. `micStartedAt`/`systemStartedAt` are read on the main actor only after
/// `startAsync` has resumed, which establishes the necessary ordering.
final class MeetingRecorder: @unchecked Sendable {
    private let mic = CrashSafeRecorder()
    private let system = SystemAudioRecorder()
    private(set) var isRecording = false

    /// Serial queue for the blocking start/stop (the system-audio tap, aggregate device,
    /// and audio engine all make CoreAudio calls that can wedge), so setup never freezes
    /// the main thread.
    private let startQueue = DispatchQueue(label: "com.murmur.meeting.start", qos: .userInitiated)

    /// Wall-clock instant each track began capturing (the two start a few ms apart).
    /// Read right after `start()` to align the tracks on a common timeline.
    private(set) var micStartedAt: Date?
    private(set) var systemStartedAt: Date?

    /// True when the system-audio track recorded only silence - almost always because the
    /// System Audio Recording permission is missing (the tap yields silence rather than
    /// failing), so the other side of the meeting isn't captured. Meaningful after `stop()`.
    var systemAudioWasSilent: Bool { !system.didCaptureAudio }

    /// Live loudness (0...1) of **your microphone**, for the HUD - so you can see you're
    /// being picked up while you talk. The system track isn't metered; mixing both would
    /// let system silence mask your voice.
    var onLevel: (@Sendable (Float) -> Void)? {
        didSet { mic.onLevel = onLevel }
    }

    /// Fired when a track's audio stops reaching disk (e.g. the disk filled up), so
    /// the UI can warn instead of recording into the void. At most once per track
    /// per capture, so a full disk can surface it for the mic and the system track.
    var onWriteFailure: (@Sendable () -> Void)? {
        didSet {
            mic.onWriteFailure = onWriteFailure
            system.onWriteFailure = onWriteFailure
        }
    }

    /// Choose which mic to capture. Only a **Bluetooth** input needs avoiding:
    /// recording a Bluetooth headset's own mic forces it into the low-quality call
    /// (HFP) profile, which makes all audio stutter, so we record the built-in mic
    /// instead. Every other input - built-in, USB, or a wireless-dongle headset (e.g.
    /// an Arctis) - records fine as-is, and leaving the engine on its default input
    /// avoids rebinding the input device: the old output-based heuristic forced the
    /// built-in mic whenever headphones were the *output*, and on a USB headset that
    /// rebind wedged CoreAudio for ~90 s, so the meeting timed out and failed to
    /// start. Decided per recording, since devices change between meetings.
    ///
    /// Echo cancellation (voice processing) is intentionally NOT used: it ducks system
    /// output while recording, which makes a live call (e.g. Google Meet) hard to hear,
    /// and it conflicts with the system-audio tap that runs on the same output device. The
    /// other side is already captured cleanly on the separate system-audio track, so faint
    /// speaker bleed into the mic doesn't matter.
    private func configureMic() {
        // An explicit mic choice from settings always wins (a deliberate decision, so we
        // don't second-guess it with the Bluetooth heuristic below).
        if let chosen = CrashSafeRecorder.preferredInputDevice() {
            mic.inputDeviceID = chosen
            return
        }
        if let input = CrashSafeRecorder.defaultInputDevice, CrashSafeRecorder.isBluetooth(input) {
            mic.inputDeviceID = CrashSafeRecorder.builtInInputDevice()
        } else {
            mic.inputDeviceID = nil   // default input, no rebind
        }
    }

    /// Start both tracks. System audio is started first because it's the
    /// permission-gated one; if it fails, nothing is left running. Runs on `startQueue`
    /// (via `startAsync`), never directly on the main thread.
    private func start(micURL: URL, systemURL: URL) throws {
        guard !isRecording else { return }
        configureMic()
        try system.start(writingTo: systemURL)
        systemStartedAt = Date()
        do {
            try mic.start(writingTo: micURL)
            micStartedAt = Date()
        } catch {
            system.stop()
            throw error
        }
        isRecording = true
    }

    /// Runs on `startQueue` (via `stopAsync`/`stopSync`), never directly on the main thread.
    private func stop() {
        guard isRecording else { return }
        mic.stop()
        system.stop()
        isRecording = false
    }

    /// Start both tracks on a background queue with a timeout, so a wedged CoreAudio call
    /// can't freeze the UI. Returns whether recording began in time; a start that unblocks
    /// after the timeout tears itself back down. Read `micStartedAt`/`systemStartedAt`
    /// after this returns true. The timeout is generous because the first meeting can
    /// surface the system-audio permission prompt inside this start.
    func startAsync(micURL: URL, systemURL: URL, timeout: TimeInterval = 12) async -> Bool {
        await startWithTimeout(on: startQueue, timeout: timeout, work: { [self] in
            do { try start(micURL: micURL, systemURL: systemURL); return true }
            catch { Log.error("Meeting start failed: \(error.localizedDescription)"); return false }
        }, undo: { [self] in stop() })
    }

    /// Stop both tracks on the background queue (teardown makes blocking CoreAudio calls),
    /// serialized after any in-flight `startAsync`.
    func stopAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startQueue.async { [self] in
                stop()
                continuation.resume()
            }
        }
    }

    /// Synchronous stop for app termination. Runs `stop()` on `startQueue` so it serializes
    /// after any in-flight `startAsync` instead of racing it on the main thread, flushing
    /// both tracks to disk before the process exits.
    func stopSync() {
        startQueue.sync { stop() }
    }
}
