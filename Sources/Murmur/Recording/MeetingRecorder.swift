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

    init() {
        // Echo cancellation on the mic so it doesn't also re-record the other
        // participants coming out of the speakers. (Headphones still give the cleanest
        // result, but this removes most of the bleed.)
        mic.enableVoiceProcessing = true
    }

    /// Live loudness (0...1) of **your microphone**, for the HUD - so you can see you're
    /// being picked up while you talk. The system track isn't metered; mixing both would
    /// let system silence mask your voice.
    var onLevel: (@Sendable (Float) -> Void)? {
        didSet { mic.onLevel = onLevel }
    }

    /// Start both tracks. System audio is started first because it's the
    /// permission-gated one; if it fails, nothing is left running.
    func start(micURL: URL, systemURL: URL) throws {
        guard !isRecording else { return }
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
