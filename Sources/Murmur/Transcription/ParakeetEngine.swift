import Foundation
import FluidAudio

/// Default speech engine: NVIDIA Parakeet TDT v3 on the Apple Neural Engine via
/// FluidAudio. One multilingual model covers German, English, and Dutch (plus 22
/// other European languages) with automatic language detection.
///
/// Long recordings are split into ASR-ready speech segments with Silero VAD
/// (silence-trimmed, capped at ~14 s) and transcribed one segment at a time. That
/// bounds memory regardless of length, avoids transcribing silence, and lets the
/// caller autosave the transcript as each segment finalizes.
///
/// An `actor` so the (non-Sendable) FluidAudio managers are accessed serially and
/// the type satisfies `TranscriptionEngine: Sendable`.
actor ParakeetEngine: TranscriptionEngine {
    private var asr: AsrManager?
    private var vad: VadManager?

    /// Speech-segmentation tuning. We raise the silence gap that ends a chunk from the
    /// 0.75s default to 1.5s, so a normal thinking pause doesn't split the utterance.
    /// Each split tends to pick up a sentence-final period from the model, so fewer
    /// splits means fewer stray periods on pauses. The 14s max-chunk cap is unchanged,
    /// so memory stays bounded regardless of how long you talk.
    private static let segmentation = VadSegmentationConfig(minSilenceDuration: 1.5)

    enum EngineError: Error { case notPrepared }

    /// Fired on load (true) / idle unload (false), so the app can keep its
    /// "model ready" state honest across unloads.
    private var onReadinessChange: (@Sendable (Bool) -> Void)?

    func setReadinessHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        onReadinessChange = handler
    }

    // MARK: Idle unload

    /// The loaded models keep several hundred MB resident. When the user opts in
    /// (`Settings.unloadModelsWhenIdle`, default on), free them after this long
    /// without a transcription; the next use reloads from the compiled CoreML cache
    /// (seconds, not the tens-of-seconds first-run path).
    private static let idleUnloadDelay: Duration = .seconds(10 * 60)
    private var idleUnloadTask: Task<Void, Never>?

    /// (Re)arm the idle-unload timer. Called after every use; each call supersedes
    /// the previous timer, so the delay always counts from the last transcription.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        guard asr != nil || vad != nil else { return }
        idleUnloadTask = Task {
            try? await Task.sleep(for: Self.idleUnloadDelay)
            // Re-check the setting at fire time so turning it off cancels the
            // behavior without needing to observe the change.
            guard !Task.isCancelled, Settings.unloadModelsWhenIdle else { return }
            unloadModels()
        }
    }

    private func unloadModels() {
        guard asr != nil || vad != nil else { return }
        asr = nil
        vad = nil
        Log.info("Speech models unloaded after idle")
        onReadinessChange?(false)
    }

    /// Download (first run only) and load the ASR + VAD Core ML models. Idempotent.
    private func prepare() async throws {
        // In use: an unload timer from a previous transcription must not fire mid-run.
        idleUnloadTask?.cancel()
        let wasLoaded = asr != nil && vad != nil
        if asr == nil {
            Log.info("Loading Parakeet v3 models (first run downloads them)...")
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
        }
        if vad == nil {
            Log.info("Loading Silero VAD model...")
            vad = try await VadManager(config: .default)
        }
        if !wasLoaded {
            Log.info("Speech models ready")
            onReadinessChange?(true)
        }
    }

    /// Load the ASR + VAD models now (in the background), so the first dictation or
    /// meeting transcription doesn't pay the cold-load cost on the critical path. This
    /// matters most right after a reboot or a macOS update, when CoreML recompiles the
    /// models for the Neural Engine, which can take tens of seconds.
    @discardableResult
    func prewarm() async -> Bool {
        do { try await prepare(); scheduleIdleUnload(); return true }
        catch {
            Log.error("Speech model prewarm failed: \(error.localizedDescription)")
            return false
        }
    }

    func transcribe(fileAt url: URL,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> Transcript {
        try await prepare()
        // Count idle from when this transcription finishes, however it exits.
        defer { scheduleIdleUnload() }
        guard let asr, let vad else { throw EngineError.notPrepared }

        // Recordings are 16 kHz mono (the recorder's format), which VAD and ASR
        // consume directly. For anything else (e.g. an imported MP3), fall back to
        // FluidAudio's whole-file path, which resamples internally - and check the
        // format first so we don't load a large file into memory just to fall back.
        let (sampleRate, channels) = try AudioSamples.format(url)
        guard sampleRate == 16_000, channels == 1 else {
            var state = try TdtDecoderState()
            let r = try await asr.transcribe(url, decoderState: &state, language: nil)
            onPartial?(r.text)
            return Transcript(text: r.text, segments: [])
        }

        let (samples, _, _) = try AudioSamples.read(url)
        guard !samples.isEmpty else { return Transcript(text: "", segments: []) }

        let segments = try await vad.segmentSpeech(samples, config: Self.segmentation)
        if segments.isEmpty {
            return Transcript(text: "", segments: [])
        }

        var pieces: [Transcript.Segment] = []
        var cumulative = ""
        for seg in segments {
            let start = max(0, seg.startSample(sampleRate: 16_000))
            let end = min(samples.count, seg.endSample(sampleRate: 16_000))
            guard end > start else { continue }

            var state = try TdtDecoderState()
            let chunk = Array(samples[start..<end])
            let result = try await asr.transcribe(chunk, decoderState: &state, language: nil)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            pieces.append(Transcript.Segment(start: seg.startTime, end: seg.endTime, text: text))
            cumulative += cumulative.isEmpty ? text : " " + text
            onPartial?(cumulative)   // progressive autosave hook
        }

        return Transcript(text: cumulative, segments: pieces)
    }

    /// Live-preview pass over the trailing `window` seconds of a growing recording.
    /// The CAF stays readable mid-write (the same property crash recovery relies on),
    /// so we re-read the file, transcribe just the tail, and let the caller show it.
    /// Bounding the work to the tail keeps each tick's cost constant no matter how
    /// long the dictation runs; the accurate full pass still happens at the end.
    func previewTail(fileAt url: URL, window: TimeInterval) async -> String? {
        do {
            try await prepare()
            defer { scheduleIdleUnload() }
            guard let asr, let vad else { return nil }

            let (samples, sampleRate, _) = try AudioSamples.read(url)
            guard sampleRate == 16_000, !samples.isEmpty else { return nil }
            let tailLength = Int(window * 16_000)
            let tail = samples.count > tailLength ? Array(samples.suffix(tailLength)) : samples

            let segments = try await vad.segmentSpeech(tail, config: Self.segmentation)
            guard !segments.isEmpty else { return nil }

            var pieces: [String] = []
            for seg in segments {
                let start = max(0, seg.startSample(sampleRate: 16_000))
                let end = min(tail.count, seg.endSample(sampleRate: 16_000))
                guard end > start else { continue }
                var state = try TdtDecoderState()
                let result = try await asr.transcribe(Array(tail[start..<end]),
                                                      decoderState: &state, language: nil)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { pieces.append(text) }
            }
            return pieces.isEmpty ? nil : pieces.joined(separator: " ")
        } catch {
            return nil   // best-effort: a failed preview tick just shows nothing new
        }
    }
}
