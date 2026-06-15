import AVFoundation
import AppKit

/// Records a meeting as **two clean tracks**: your microphone and the system / app
/// audio (the other participants), each streamed crash-safe to its own 16 kHz mono
/// CAF. Keeping them separate makes per-side transcription accurate and enables
/// speaker labelling later.
final class MeetingRecorder {
    private let mic = CrashSafeRecorder()
    private let system = SystemAudioRecorder()
    private(set) var isRecording = false

    /// Wall-clock instant each track began capturing (the two start a few ms apart).
    /// Read right after `start()` to align the tracks on a common timeline.
    private(set) var micStartedAt: Date?
    private(set) var systemStartedAt: Date?

    /// Live loudness (0...1) of **your microphone**, for the HUD - so you can see you're
    /// being picked up while you talk. The system track isn't metered; mixing both would
    /// let system silence mask your voice.
    var onLevel: (@Sendable (Float) -> Void)? {
        didSet { mic.onLevel = onLevel }
    }

    /// Choose how to capture your mic based on where sound is going right now. On the
    /// built-in speakers the mic hears the other participants, so cancel that echo and
    /// record whichever mic you've selected. On headphones (Bluetooth, USB, or the jack)
    /// there is no bleed, so skip echo cancellation - and don't record a Bluetooth
    /// headset's own mic, which would force it into the low-quality call profile and make
    /// all audio stutter; use the built-in mic and leave the headphones in high-quality
    /// output. Decided per recording, since the audio devices can change between meetings.
    private func configureMic() {
        // An explicit mic choice from settings always wins (it's a deliberate decision,
        // so we don't second-guess it with the headphone heuristic below). Echo
        // cancellation only when the output is the built-in speakers, where the mic can
        // pick up speaker bleed.
        if let chosen = CrashSafeRecorder.preferredInputDevice() {
            mic.inputDeviceID = chosen
            mic.enableVoiceProcessing = CrashSafeRecorder.outputUsesBuiltInSpeakers()
            return
        }
        if CrashSafeRecorder.outputUsesBuiltInSpeakers() {
            mic.enableVoiceProcessing = true
            mic.inputDeviceID = nil
        } else {
            mic.enableVoiceProcessing = false
            mic.inputDeviceID = CrashSafeRecorder.builtInInputDevice()
        }
    }

    /// Start both tracks. System audio is started first because it's the
    /// permission-gated one; if it fails, nothing is left running.
    func start(micURL: URL, systemURL: URL) throws {
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

    func stop() {
        guard isRecording else { return }
        mic.stop()
        system.stop()
        isRecording = false
    }
}
