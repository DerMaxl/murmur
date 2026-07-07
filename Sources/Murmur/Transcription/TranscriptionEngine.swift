import Foundation

/// The single seam for speech-to-text. Swapping models (Parakeet → whisper.cpp →
/// Apple SpeechAnalyzer) means implementing this protocol and pointing the app at
/// the new type, no other code changes.
///
/// All engines consume 16 kHz mono Float32 PCM (see
/// `CrashSafeRecorder.transcriptionFormat`), so the recorder's output feeds any
/// engine directly.
protocol TranscriptionEngine: Sendable {
    /// Transcribe a finished audio file on disk. Implementations load their model
    /// lazily on first use.
    ///
    /// - Parameter onPartial: called with the cumulative transcript each time a
    ///   chunk finalizes, so callers can autosave progress. Engines that can't
    ///   stream simply call it once at the end (or not at all).
    func transcribe(fileAt url: URL,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> Transcript

    /// Load the model ahead of first use so the first real transcription isn't stuck on
    /// a slow cold load. Best-effort and idempotent; default is a no-op for engines that
    /// don't need it. Returns whether the model is actually ready, so callers can retry
    /// later (e.g. a first-run download failed because the Mac was offline).
    @discardableResult
    func prewarm() async -> Bool

    /// Register a callback fired when the engine's readiness changes: `true` when the
    /// model finishes loading, `false` when the engine frees its models after idling
    /// (see `Settings.unloadModelsWhenIdle`). Drives the HUD's "Loading model" vs
    /// "Transcribing" message. Default: never fires (engines that are always ready).
    func setReadinessHandler(_ handler: @escaping @Sendable (Bool) -> Void) async

    /// One live-preview tick over a file that is *still being written*: returns the
    /// cumulative transcript so far (finalized speech plus a rough take on the still-
    /// open tail). Engines keep per-file session state so already-finished speech is
    /// transcribed only once - and a later `transcribe(fileAt:)` on the same URL
    /// consumes that state instead of re-transcribing from scratch. Returns nil on
    /// any problem or for engines that can't do it - callers just show no preview.
    func livePartial(fileAt url: URL) async -> String?

    /// Drop any live-preview session for `url` without transcribing (the dictation
    /// was cancelled). Default no-op.
    func liveDiscard(fileAt url: URL) async

    /// Whether `livePartial` work is cached and consumed by the final
    /// `transcribe(fileAt:)`. When true, ticking in the background is worthwhile
    /// even with no preview UI (long dictations finish near-instantly); when false
    /// (default), background ticks would be pure extra compute.
    var reusesLiveWork: Bool { get }
}

extension TranscriptionEngine {
    func prewarm() async -> Bool { true }
    func setReadinessHandler(_ handler: @escaping @Sendable (Bool) -> Void) async {}
    func livePartial(fileAt url: URL) async -> String? { nil }
    func liveDiscard(fileAt url: URL) async {}
    var reusesLiveWork: Bool { false }
}

/// Result of a transcription. Segments carry per-utterance timing (for SRT export
/// and, later, meeting/diarization views); `text` is the convenience concatenation.
struct Transcript: Sendable {
    struct Segment: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    let text: String
    let segments: [Segment]
}
