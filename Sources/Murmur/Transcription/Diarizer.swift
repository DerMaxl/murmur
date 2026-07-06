import Foundation
import FluidAudio

/// One speaker's turn on the timeline (who spoke when), from diarization.
struct SpeakerSegment: Sendable {
    let speakerId: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Speaker diarization via FluidAudio (Pyannote-based, runs on the Neural Engine).
/// Used on a meeting's system track to split the remote side into Speaker 1 / 2 / …
///
/// An `actor` so the (non-Sendable) `DiarizerManager` is accessed serially.
actor Diarizer {
    private var manager: DiarizerManager?
    private var idleUnloadTask: Task<Void, Never>?
    /// In-flight load + concurrent-use count, mirroring `ParakeetEngine`: concurrent
    /// callers (a meeting and an import) join one load, and the idle timer only arms
    /// once the last diarization finishes.
    private var loadTask: Task<Void, Error>?
    private var activeUses = 0

    private func prepare() async throws {
        idleUnloadTask?.cancel()   // in use: don't unload mid-diarization
        guard manager == nil else { return }
        let task = loadTask ?? Task {
            Log.info("Loading speaker-diarization models (first run downloads them)...")
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            self.manager = manager
            Log.info("Diarization models ready")
        }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    /// Free the Pyannote models after a while without a diarization (same policy as
    /// `ParakeetEngine`); the next use reloads from the CoreML cache.
    private func scheduleIdleUnload() {
        guard activeUses == 0 else { return }
        idleUnloadTask?.cancel()
        guard manager != nil else { return }
        idleUnloadTask = Task {
            try? await Task.sleep(for: .seconds(10 * 60))
            guard !Task.isCancelled, Settings.unloadModelsWhenIdle else { return }
            manager = nil
            Log.info("Diarization models unloaded after idle")
        }
    }

    /// Diarize a 16 kHz mono file. Best-effort: returns `[]` for very short audio or
    /// on any error, so the caller falls back to an un-labelled transcript.
    func diarize(fileAt url: URL) async -> [SpeakerSegment] {
        activeUses += 1
        defer { activeUses -= 1; scheduleIdleUnload() }
        do {
            try await prepare()
            guard let manager else { return [] }
            let (samples, sampleRate, _) = try AudioSamples.read(url)
            guard sampleRate == 16_000, samples.count > 16_000 else { return [] }  // need >~1s
            let result = try manager.performCompleteDiarization(samples)
            return result.segments.map {
                SpeakerSegment(speakerId: $0.speakerId,
                               start: TimeInterval($0.startTimeSeconds),
                               end: TimeInterval($0.endTimeSeconds))
            }
        } catch {
            Log.error("Diarization failed: \(error.localizedDescription)")
            return []
        }
    }
}
