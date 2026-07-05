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
        try await current.transcribe(fileAt: url, onPartial: onPartial)
    }

    @discardableResult
    func prewarm() async -> Bool {
        await current.prewarm()
    }

    func setReadinessHandler(_ handler: @escaping @Sendable (Bool) -> Void) async {
        // Only Parakeet loads/unloads models in-process; the Apple engine's model
        // is managed by the OS and is effectively always ready.
        await parakeet.setReadinessHandler(handler)
    }

    func previewTail(fileAt url: URL, window: TimeInterval) async -> String? {
        await current.previewTail(fileAt: url, window: window)
    }
}
