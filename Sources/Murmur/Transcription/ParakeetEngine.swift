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

    /// The ASR rejects buffers shorter than ~300 ms ("Invalid audio data"), but VAD
    /// can emit shorter speech blips - especially at the consumption boundaries the
    /// live session introduces (seen in the wild: a dictation's final pass failed on
    /// a tiny leftover segment). Pad short chunks with trailing silence rather than
    /// letting one blip fail the whole transcription.
    private static let minAsrSamples = Int(0.35 * 16_000)   // margin over the 300 ms floor

    private static func padToMinimum(_ chunk: [Float]) -> [Float] {
        guard chunk.count < minAsrSamples else { return chunk }
        return chunk + [Float](repeating: 0, count: minAsrSamples - chunk.count)
    }

    /// Fired as the model is prepared (download %, load, ready) and on idle unload, so
    /// the app can tell the user what the wait is and keep "model ready" honest.
    private var onPreparation: (@Sendable (ModelPreparation) -> Void)?

    func setPreparationHandler(_ handler: @escaping @Sendable (ModelPreparation) -> Void) {
        onPreparation = handler
    }

    // MARK: Idle unload

    /// The loaded models keep several hundred MB resident. When the user opts in
    /// (`Settings.unloadModelsWhenIdle`, default on), free them after this long
    /// without a transcription; the next use reloads from the compiled CoreML cache
    /// (seconds, not the tens-of-seconds first-run path).
    private static let idleUnloadDelay: Duration = .seconds(10 * 60)
    private var idleUnloadTask: Task<Void, Never>?

    /// Transcriptions currently inside the engine. The idle timer only arms when
    /// this drops to zero, so one meeting track finishing can't schedule an unload
    /// out from under the other track that's still transcribing.
    private var activeUses = 0

    /// (Re)arm the idle-unload timer. Called after every use; each call supersedes
    /// the previous timer, so the delay always counts from the last transcription.
    private func scheduleIdleUnload() {
        guard activeUses == 0 else { return }   // a sibling transcription is still running
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
        onPreparation?(.unloaded)
    }

    /// In-flight model load, so concurrent callers join one load instead of each
    /// running their own (a meeting transcribes two tracks at once - without this,
    /// both would download/compile the models and double the peak memory, on every
    /// first use after an idle unload).
    private var loadTask: Task<Void, Error>?

    /// Download (first run only) and load the ASR + VAD Core ML models. Idempotent
    /// and de-duplicated across concurrent callers.
    private func prepare() async throws {
        // In use: an unload timer from a previous transcription must not fire mid-run.
        idleUnloadTask?.cancel()
        guard asr == nil || vad == nil else { return }
        // Captured into a local so the (@Sendable) download progress block, called on
        // an arbitrary queue, doesn't touch actor-isolated state directly.
        let notify = onPreparation
        let task = loadTask ?? Task {
            notify?(.loading)
            if asr == nil {
                Log.info("Loading Parakeet v3 models (first run downloads them)...")
                // Report the first-run download so the user sees "Downloading model X%"
                // instead of a stuck "Loading model" during a large one-time fetch.
                let progress: DownloadUtils.ProgressHandler = { p in
                    switch p.phase {
                    case .downloading: notify?(.downloading(fraction: p.fractionCompleted))
                    // Listing the remote files and compiling after download are both
                    // quick pre/post steps; show them as the plain loading state.
                    case .listing, .compiling: notify?(.loading)
                    }
                }
                let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: progress)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                asr = manager
            }
            if vad == nil {
                Log.info("Loading Silero VAD model...")
                vad = try await VadManager(config: .default)
            }
            Log.info("Speech models ready")
            notify?(.ready)
        }
        loadTask = task
        defer { loadTask = nil }
        do {
            try await task.value
        } catch {
            // A partial failure can leave one model resident (ASR loaded, the VAD
            // download failed offline): make sure an unload timer still covers it.
            scheduleIdleUnload()
            throw error
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
        // Consume any live-preview session up front (even if prepare() throws below,
        // it must not linger for a URL that's about to be deleted or moved).
        let liveState = liveSessions.removeValue(forKey: url)
        try await prepare()
        // Count idle from when the engine's last in-flight transcription finishes.
        activeUses += 1
        defer { activeUses -= 1; scheduleIdleUnload() }
        guard let asr, let vad else { throw EngineError.notPrepared }

        // The preview already transcribed the finalized part of this dictation while
        // it was being recorded; finish only the remainder instead of starting over.
        if let liveState {
            return try await finishLiveSession(liveState, url: url, asr: asr, vad: vad,
                                               onPartial: onPartial)
        }

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
            let chunk = Self.padToMinimum(Array(samples[start..<end]))
            let result = try await asr.transcribe(chunk, decoderState: &state, language: nil)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            pieces.append(Transcript.Segment(start: seg.startTime, end: seg.endTime, text: text))
            cumulative += cumulative.isEmpty ? text : " " + text
            onPartial?(cumulative)   // progressive autosave hook
        }

        return Transcript(text: cumulative, segments: pieces)
    }

    // MARK: Live preview (incremental session over a growing file)

    /// Per-file live-transcription state: everything before `base` has been VAD-
    /// segmented, transcribed once, and folded into `text`/`segments` (absolute
    /// times). Each preview tick only re-transcribes the still-open tail, and the
    /// final `transcribe(fileAt:)` consumes this so the dictation isn't transcribed
    /// twice.
    private struct LiveState {
        var base = 0                                // absolute sample index of the unconsumed suffix
        var text = ""                               // finalized transcript so far
        var segments: [Transcript.Segment] = []     // finalized, absolute times
    }
    private var liveSessions: [URL: LiveState] = [:]

    /// A trailing VAD segment is treated as still-open (re-transcribed next tick
    /// instead of finalized) when it ends within this margin of the file's current
    /// end - it was cut off by the read, not closed by a real silence gap.
    private static let liveOpenTailMargin = Int(1.5 * 16_000)

    /// One preview tick: read the file (a CAF stays readable mid-write - the same
    /// property crash recovery relies on), finalize any speech segments that ended,
    /// and return finalized text plus a rough take on the open tail. Work per tick is
    /// bounded: closed segments are transcribed exactly once, and the open tail is
    /// capped by VAD's ~14 s max-chunk length no matter how long you talk.
    func livePartial(fileAt url: URL) async -> String? {
        do {
            try await prepare()
            activeUses += 1
            defer { activeUses -= 1; scheduleIdleUnload() }
            guard let asr, let vad else { return nil }

            var state = liveSessions[url] ?? LiveState()
            let (samples, sampleRate, _) = try AudioSamples.read(url)
            guard sampleRate == 16_000, samples.count > state.base else {
                return state.text.isEmpty ? nil : state.text
            }
            let suffix = Array(samples[state.base...])
            let segments = try await vad.segmentSpeech(suffix, config: Self.segmentation)

            var volatileText = ""
            var consumed = 0   // suffix-relative end of the last finalized segment
            for (index, seg) in segments.enumerated() {
                let start = max(0, seg.startSample(sampleRate: 16_000))
                let end = min(suffix.count, seg.endSample(sampleRate: 16_000))
                guard end > start else { continue }
                var decoder = try TdtDecoderState()
                let result = try await asr.transcribe(Self.padToMinimum(Array(suffix[start..<end])),
                                                      decoderState: &decoder, language: nil)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let isOpenTail = index == segments.count - 1
                    && end > suffix.count - Self.liveOpenTailMargin
                if isOpenTail {
                    volatileText = text
                } else {
                    if !text.isEmpty {
                        state.segments.append(Transcript.Segment(
                            start: Double(state.base + start) / 16_000,
                            end: Double(state.base + end) / 16_000,
                            text: text))
                        state.text += state.text.isEmpty ? text : " " + text
                    }
                    consumed = end
                }
            }
            state.base += consumed
            // A cancelled tick (the dictation ended mid-read) must not resurrect the
            // session that finish/discard is about to consume or drop.
            guard !Task.isCancelled else { return nil }
            liveSessions[url] = state

            let combined = [state.text, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
            return combined.isEmpty ? nil : combined
        } catch {
            return nil   // best-effort: a failed preview tick just shows nothing new
        }
    }

    func liveDiscard(fileAt url: URL) {
        liveSessions.removeValue(forKey: url)
    }

    /// Live sessions are consumed by `transcribe(fileAt:)`, so background ticking
    /// during a dictation is work moved earlier, not extra work.
    nonisolated var reusesLiveWork: Bool { true }

    /// Finish a live session: transcribe only what the preview ticks hadn't
    /// finalized yet and stitch it onto the cached result.
    private func finishLiveSession(_ state: LiveState, url: URL,
                                   asr: AsrManager, vad: VadManager,
                                   onPartial: (@Sendable (String) -> Void)?) async throws -> Transcript {
        var text = state.text
        var pieces = state.segments
        let (samples, sampleRate, _) = try AudioSamples.read(url)
        if sampleRate == 16_000, samples.count > state.base {
            let suffix = Array(samples[state.base...])
            let segments = try await vad.segmentSpeech(suffix, config: Self.segmentation)
            for seg in segments {
                let start = max(0, seg.startSample(sampleRate: 16_000))
                let end = min(suffix.count, seg.endSample(sampleRate: 16_000))
                guard end > start else { continue }
                var decoder = try TdtDecoderState()
                let result = try await asr.transcribe(Self.padToMinimum(Array(suffix[start..<end])),
                                                      decoderState: &decoder, language: nil)
                let chunk = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !chunk.isEmpty else { continue }
                pieces.append(Transcript.Segment(start: Double(state.base + start) / 16_000,
                                                 end: Double(state.base + end) / 16_000,
                                                 text: chunk))
                text += text.isEmpty ? chunk : " " + chunk
                onPartial?(text)
            }
        }
        return Transcript(text: text, segments: pieces)
    }
}
