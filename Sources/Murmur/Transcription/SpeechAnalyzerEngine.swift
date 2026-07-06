import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech engine (macOS 26+): the SpeechAnalyzer / SpeechTranscriber
/// API. The model ships with (and is managed by) macOS itself, so this engine adds
/// zero download, zero disk, and no resident model memory in Murmur's process.
///
/// Trade-off vs Parakeet: it transcribes in one fixed locale (the first of the user's
/// preferred languages it supports) - there is no automatic language detection across
/// utterances.
@available(macOS 26.0, *)
actor SpeechAnalyzerEngine: TranscriptionEngine {
    enum EngineError: LocalizedError {
        case noSupportedLocale

        var errorDescription: String? {
            switch self {
            case .noSupportedLocale:
                return "Apple's speech engine supports none of your preferred languages."
            }
        }
    }

    /// Resolved once: the first preferred language SpeechTranscriber supports.
    private var resolvedLocale: Locale?

    private func locale() async throws -> Locale {
        if let resolvedLocale { return resolvedLocale }
        let supported = await SpeechTranscriber.supportedLocales
        let preferred = Locale.preferredLanguages.map(Locale.init(identifier:)) + [Locale.current]
        // Exact BCP-47 match first (en-US), then same-language match (any English).
        let match = preferred.compactMap { candidate in
            supported.first { $0.identifier(.bcp47) == candidate.identifier(.bcp47) }
        }.first ?? preferred.compactMap { candidate in
            supported.first { $0.language.languageCode == candidate.language.languageCode }
        }.first
        guard let match else { throw EngineError.noSupportedLocale }
        resolvedLocale = match
        Log.info("Apple speech engine locale: \(match.identifier)")
        return match
    }

    /// Make sure the locale's speech assets are installed (macOS downloads and caches
    /// them system-wide; a no-op when already present).
    private func ensureAssets(for transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.info("Downloading Apple speech assets...")
            try await request.downloadAndInstall()
        }
    }

    @discardableResult
    func prewarm() async -> Bool {
        do {
            let transcriber = SpeechTranscriber(locale: try await locale(),
                                                preset: .transcription)
            try await ensureAssets(for: transcriber)
            return true
        } catch {
            Log.error("Apple speech prewarm failed: \(error.localizedDescription)")
            return false
        }
    }

    func transcribe(fileAt url: URL,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> Transcript {
        let transcriber = SpeechTranscriber(locale: try await locale(),
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        try await ensureAssets(for: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)

        // Collect finalized results while the analyzer walks the file below.
        let collector = Task {
            var pieces: [Transcript.Segment] = []
            var cumulative = ""
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let range = Self.timeRange(of: result.text)
                pieces.append(Transcript.Segment(start: range?.start ?? 0,
                                                 end: range?.end ?? 0,
                                                 text: text))
                cumulative += cumulative.isEmpty ? text : " " + text
                onPartial?(cumulative)   // progressive autosave hook
            }
            return Transcript(text: cumulative, segments: pieces)
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// Live-preview tick: analyze the capture recorded so far and return its text.
    /// Unlike Parakeet there is no VAD here to finalize chunks incrementally, so each
    /// tick re-analyzes the whole file - fine for this engine (the OS model runs well
    /// above realtime and dictations are short), and the preview loop self-paces so
    /// ticks never pile up. The final pass re-analyzes the complete file as usual.
    func livePartial(fileAt url: URL) async -> String? {
        do {
            let text = try await transcribe(fileAt: url, onPartial: nil).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil   // best-effort: a failed tick just shows nothing new
        }
    }

    /// The audio time span a result covers, from its `.audioTimeRange` run attributes.
    private static func timeRange(of text: AttributedString) -> (start: TimeInterval, end: TimeInterval)? {
        var start: TimeInterval?
        var end: TimeInterval?
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            if start == nil { start = range.start.seconds }
            end = range.end.seconds
        }
        guard let start, let end else { return nil }
        return (start, end)
    }
}
