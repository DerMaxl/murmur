import Foundation

/// Which speech-to-text engine transcribes audio.
enum EngineChoice: String, CaseIterable, Sendable {
    case parakeet
    case appleSpeech

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet TDT v3"
        case .appleSpeech: return "Apple (built into macOS)"
        }
    }

    /// Approximate one-time model download for this engine, or nil when nothing is
    /// fetched (Apple's engine ships with macOS). Shown in the engine picker so people
    /// know what a first-run Parakeet download costs before selecting it.
    var approxDownloadSize: String? {
        switch self {
        case .parakeet: return "~500 MB"
        case .appleSpeech: return nil
        }
    }

    /// Picker label: the name plus the download size when there is one.
    var pickerLabel: String {
        approxDownloadSize.map { "\(displayName) · \($0) download" } ?? displayName
    }
}

/// Routes every call to the engine currently selected in Settings, so switching
/// engines takes effect immediately - no replumbing, no relaunch. The app owns one
/// of these; both real engines load their models lazily, so the unselected one
/// costs nothing.
final class SwitchableEngine: TranscriptionEngine {
    private let parakeet = ParakeetEngine()
    /// nil before macOS 26 (the SpeechAnalyzer API doesn't exist there).
    private let apple: TranscriptionEngine?

    /// Whether the Apple engine exists on this macOS, for the settings picker.
    var appleEngineAvailable: Bool { apple != nil }

    init() {
        if #available(macOS 26.0, *) {
            apple = SpeechAnalyzerEngine()
        } else {
            apple = nil
        }
    }

    private var current: TranscriptionEngine {
        if Settings.transcriptionEngine == .appleSpeech, let apple { return apple }
        return parakeet
    }

    func transcribe(fileAt url: URL,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> Transcript {
        let engine = current
        // Switching engines mid-dictation must not strand Parakeet's live-preview
        // session for this file (only Parakeet's own transcribe consumes it).
        if !(engine is ParakeetEngine) { await parakeet.liveDiscard(fileAt: url) }
        return try await engine.transcribe(fileAt: url, onPartial: onPartial)
    }

    @discardableResult
    func prewarm() async -> Bool {
        await current.prewarm()
    }

    func setPreparationHandler(_ handler: @escaping @Sendable (ModelPreparation) -> Void) {
        // Only Parakeet loads/downloads models in-process; the Apple engine's model
        // is managed by the OS and is effectively always ready.
        parakeet.setPreparationHandler { prep in
            // A background Parakeet download/unload must not drive the HUD while the
            // (always-ready) Apple engine is the one selected.
            if !prep.isReady, Settings.transcriptionEngine == .appleSpeech { return }
            handler(prep)
        }
    }

    func livePartial(fileAt url: URL) async -> String? {
        await current.livePartial(fileAt: url)
    }

    var reusesLiveWork: Bool { current.reusesLiveWork }

    func liveDiscard(fileAt url: URL) async {
        // Both engines, not `current`: the selection may have changed since the
        // session was created.
        await parakeet.liveDiscard(fileAt: url)
        await apple?.liveDiscard(fileAt: url)
    }
}
