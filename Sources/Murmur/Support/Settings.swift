import Foundation

/// Where the app shows up: in the menu bar, in the Dock, or both. Default menu-bar
/// only (the app is driven mostly by its global hotkey).
enum AppVisibility: String, CaseIterable, Sendable {
    case menuBarOnly
    case dockOnly
    case dockAndMenuBar

    var displayName: String {
        switch self {
        case .menuBarOnly: return "Menu bar only"
        case .dockOnly: return "Dock only"
        case .dockAndMenuBar: return "Dock & menu bar"
        }
    }

    /// Whether the menu-bar status item should be shown.
    var showsMenuBar: Bool { self != .dockOnly }
    /// Whether the app keeps a Dock icon even when no window is open.
    var keepsDockIcon: Bool { self != .menuBarOnly }
}

/// How long to keep recordings before they're auto-moved to Recently Deleted. The
/// chosen period is measured from when each recording was made.
enum AutoDeletePeriod: String, CaseIterable, Sendable {
    case never
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear

    var displayName: String {
        switch self {
        case .never: return "Never"
        case .oneMonth: return "After 1 month"
        case .threeMonths: return "After 3 months"
        case .sixMonths: return "After 6 months"
        case .oneYear: return "After 1 year"
        }
    }

    /// Seconds after which a recording is considered old, or nil for "never".
    var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .oneMonth: return 30 * 86_400
        case .threeMonths: return 90 * 86_400
        case .sixMonths: return 180 * 86_400
        case .oneYear: return 365 * 86_400
        }
    }
}

/// Typed wrapper over UserDefaults for user-facing toggles. One place to define
/// defaults so the code and the settings UI agree.
enum Settings {
    /// Where the app appears (menu bar / Dock / both). Default Dock & menu bar, so a
    /// first-time user has a Dock icon to find and open the app.
    static var appVisibility: AppVisibility {
        get { AppVisibility(rawValue: UserDefaults.standard.string(forKey: "appVisibility") ?? "") ?? .dockAndMenuBar }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appVisibility") }
    }

    /// Automatically copy a transcript to the clipboard when it finishes. Excludes
    /// dictation (which already types at the cursor). Default on.
    static var autoCopyToClipboard: Bool {
        get { UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCopyToClipboard") }
    }

    /// Play short sounds when recording starts and when a transcription finishes.
    /// Default off.
    static var soundEffects: Bool {
        get { UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "soundEffects") }
    }

    /// Auto-move recordings older than this into Recently Deleted. Default 1 year.
    static var autoDeleteAfter: AutoDeletePeriod {
        get { AutoDeletePeriod(rawValue: UserDefaults.standard.string(forKey: "autoDeleteAfter") ?? "") ?? .oneYear }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "autoDeleteAfter") }
    }

    /// Strip filler words (uh, um, äh, …) from transcripts. Default on.
    static var removeFillers: Bool {
        get { UserDefaults.standard.object(forKey: "removeFillers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "removeFillers") }
    }

    /// Run an on-device AI pass that cleans stutters / false starts / self-corrections
    /// into a tidy message (Apple Foundation Models). Adds ~1-2 s before dictated text
    /// appears, so it's opt-in. Default off.
    static var polishTranscripts: Bool {
        get { UserDefaults.standard.object(forKey: "polishTranscripts") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "polishTranscripts") }
    }

    /// Mute the system output while a dictation is in progress, and restore the volume
    /// afterwards (app-agnostic; only kicks in if audio is actually playing). Default on.
    static var pauseMusicWhileDictating: Bool {
        get { UserDefaults.standard.object(forKey: "pauseMusicWhileDictating") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pauseMusicWhileDictating") }
    }

    /// Label meeting speakers (Speaker 1 / 2 / …) via diarization. Default on.
    static var labelSpeakers: Bool {
        get { UserDefaults.standard.object(forKey: "labelSpeakers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "labelSpeakers") }
    }

    /// Also diarize the *mic* track, so when two people share this Mac's microphone
    /// they're separated ("You" for the main voice, "Local"/"Local 2"/… for the rest)
    /// instead of both being "You". Off by default and only meaningful when
    /// `labelSpeakers` is on: it costs a second diarization pass per meeting, so the
    /// common single-speaker case shouldn't pay for it. See PLAN.md.
    static var labelOwnSideSpeakers: Bool {
        get { UserDefaults.standard.object(forKey: "labelOwnSideSpeakers") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "labelOwnSideSpeakers") }
    }

    /// Which speech-to-text engine transcribes audio. The Apple engine (macOS 26+)
    /// is built into the OS - zero download and no model memory in Murmur - but
    /// transcribes in one fixed language; Parakeet is multilingual with automatic
    /// language detection. Fresh installs on macOS 26+ start on the Apple engine
    /// (see `applyFirstRunDefaultsIfNeeded`); the stored-value fallback stays
    /// Parakeet so existing installs and macOS 15 are unaffected.
    static var transcriptionEngine: EngineChoice {
        get { EngineChoice(rawValue: UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "") ?? .parakeet }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "transcriptionEngine") }
    }

    /// Show a live text preview in the HUD while dictating: the trailing seconds of
    /// audio are re-transcribed on a short cadence so you can see the words landing.
    /// Costs extra Neural Engine work for the duration of a dictation, so it's
    /// opt-in. Default off.
    static var liveDictationPreview: Bool {
        get { UserDefaults.standard.object(forKey: "liveDictationPreview") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "liveDictationPreview") }
    }

    /// Free the speech/diarization models after ~10 minutes without a transcription
    /// (they keep several hundred MB resident). The next use reloads them from the
    /// compiled CoreML cache, which takes a few seconds. Default on.
    static var unloadModelsWhenIdle: Bool {
        get { UserDefaults.standard.object(forKey: "unloadModelsWhenIdle") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "unloadModelsWhenIdle") }
    }

    /// The push-to-talk dictation trigger. Default: hold Fn. Migrates the old
    /// `dictationTrigger` string ("fn"/"rightOption") on first read.
    static var dictationShortcut: Shortcut {
        get { decodeShortcut("dictationShortcut") ?? migratedDictationDefault }
        set { encodeShortcut(newValue, "dictationShortcut") }
    }

    /// The meeting record toggle. Default: ⌥⌘E.
    static var meetingShortcut: Shortcut {
        get { decodeShortcut("meetingShortcut") ?? .optCmdE }
        set { encodeShortcut(newValue, "meetingShortcut") }
    }

    /// One-time default migrations, oldest first: Hyper+R (doesn't survive Hyperkey's
    /// event remapping) → ⌘E, then ⌘E ("Use Selection for Find" in many apps, which
    /// the tap would swallow) → ⌥⌘E. Each leaves any other deliberate choice untouched.
    static func migrateDefaultsIfNeeded() {
        let cmdEKey = "didMigrateMeetingToCmdE"
        if !UserDefaults.standard.bool(forKey: cmdEKey) {
            UserDefaults.standard.set(true, forKey: cmdEKey)
            if decodeShortcut("meetingShortcut") == .hyperR {
                meetingShortcut = .cmdE
            }
        }
        let optCmdEKey = "didMigrateMeetingToOptCmdE"
        if !UserDefaults.standard.bool(forKey: optCmdEKey) {
            UserDefaults.standard.set(true, forKey: optCmdEKey)
            if decodeShortcut("meetingShortcut") == nil || decodeShortcut("meetingShortcut") == .cmdE {
                meetingShortcut = .optCmdE
            }
        }
    }

    /// The microphone to record from (its stable Core Audio UID), for dictation and
    /// meetings. nil / empty = follow the system default input. Stored by UID rather
    /// than the ephemeral device id so the choice survives reconnects and reboots.
    static var preferredInputDeviceUID: String? {
        get {
            let value = UserDefaults.standard.string(forKey: "preferredInputDeviceUID")
            return (value?.isEmpty == false) ? value : nil
        }
        set { UserDefaults.standard.set(newValue, forKey: "preferredInputDeviceUID") }
    }

    /// How the trigger gesture is interpreted. Default hybrid: a tap starts/stops
    /// hands-free, or hold to push-to-talk - the most flexible of the four modes.
    static var dictationMode: DictationMode {
        get { DictationMode(rawValue: UserDefaults.standard.string(forKey: "dictationMode") ?? "") ?? .hybrid }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dictationMode") }
    }

    /// One-time first-run defaults that need an action rather than just a stored value:
    /// enable Launch at Login (Murmur is hotkey-driven, so it's only useful while
    /// running), and on macOS 26+ start on the built-in Apple speech engine so the
    /// first dictation works immediately with nothing to download - Parakeet (better,
    /// multilingual) is one Settings switch away. Gated by a flag so existing installs
    /// (which predate the picker and expect Parakeet) and later user choices are
    /// never overridden.
    static func applyFirstRunDefaultsIfNeeded() {
        let key = "didApplyDefaultLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        LoginItem.setEnabled(true)
        if #available(macOS 26.0, *) {
            transcriptionEngine = .appleSpeech
        }
    }

    // MARK: Shortcut persistence

    private static var migratedDictationDefault: Shortcut {
        switch UserDefaults.standard.string(forKey: "dictationTrigger") {
        case "rightOption": return Shortcut(keyCode: nil, modifiers: .maskAlternate)
        default: return .fnHold
        }
    }

    private static func decodeShortcut(_ key: String) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    private static func encodeShortcut(_ shortcut: Shortcut, _ key: String) {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
