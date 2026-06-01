import AppKit

/// Tiny, optional UI sound effects. Uses the built-in macOS system sounds so there's
/// nothing to bundle. All calls are gated by `Settings.soundEffects`, so callers can
/// fire them unconditionally.
enum Sounds {
    /// Played when a recording (dictation or meeting) starts.
    static func recordingStarted() { play("Tink") }

    /// Played when a recording stops (capture finished, transcription pending).
    static func recordingStopped() { play("Pop") }

    /// Played when a transcription finishes and text is available.
    static func transcriptionDone() { play("Glass") }

    private static func play(_ name: String) {
        guard Settings.soundEffects else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
