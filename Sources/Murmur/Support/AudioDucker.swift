import AppKit
import CoreAudio

/// Mutes the default output device while a dictation is in progress, then restores it.
///
/// This is the app-agnostic approach (the same one Wispr Flow uses): rather than try to
/// control each player, we turn the system output volume down to zero and put it back.
/// It works for anything that makes sound (Music, Spotify, a YouTube tab, a game), needs
/// no per-app Automation permission, and, because we save and restore an explicit volume
/// *value* instead of toggling a blind Play/Pause key, it can never "start" paused media:
/// muting something that's paused is silent, and so is restoring it.
///
/// We only duck when something is actually producing audio at the start, so dictating in
/// silence never touches the user's volume. The pre-duck volume is also persisted, so if
/// the app is killed mid-dictation we restore it on the next launch instead of leaving
/// the Mac stuck at zero.
final class AudioDucker: @unchecked Sendable {
    private static let restoreVolumeKey = "audioDuckRestoreVolume"
    private static let restoreUIDKey = "audioDuckRestoreDeviceUID"

    private var ducked = false
    /// The device we muted and the volume it had, so we restore that exact device even
    /// if the user switches output (e.g. plugs in AirPods) mid-dictation.
    private var duckedDevice: AudioObjectID?
    private var savedVolume: Float = 1

    /// Apps we must never mute around. Muting is system-wide, so if a browser (which
    /// could be hosting a Google Meet / Teams call) or a dedicated communication app is
    /// producing audio, we skip ducking entirely rather than risk silencing a live
    /// conversation. The cost is that background music keeps playing in those moments,
    /// which is the right trade.
    private static let protectedBundleIDs: Set<String> = [
        // Browsers (any of these could be hosting a call).
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "org.mozilla.firefox",
        "com.brave.Browser", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        // Dedicated communication apps.
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp", "com.apple.FaceTime",
        "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.skype.skype",
    ]

    /// If audio is playing, remember the current output volume and mute it.
    func duckIfPlaying() {
        guard Settings.pauseMusicWhileDictating, !ducked else { return }
        let producers = AudioProcessProbe.audioProducingApps()
        guard !producers.isEmpty else { return }
        // Don't mute if a call could be in progress (browser or comms app making sound).
        if producers.contains(where: { Self.protectedBundleIDs.contains($0.bundleIdentifier ?? "") }) {
            Log.info("Skipping mute while dictating: a browser/communication app is producing audio")
            return
        }
        guard let device = Self.defaultOutputDevice,
              let current = Self.volume(of: device) else { return }
        savedVolume = current
        duckedDevice = device
        // Persist (with the device UID) before changing, so a crash mid-dictation
        // self-heals at next launch, restoring the *same* device.
        UserDefaults.standard.set(current, forKey: Self.restoreVolumeKey)
        if let uid = Self.deviceUID(device) {
            UserDefaults.standard.set(uid, forKey: Self.restoreUIDKey)
        }
        Self.setVolume(0, on: device)
        ducked = true
    }

    /// Restore the volume on the exact device we muted (the moment recording stops).
    func restore() {
        guard ducked else { return }
        ducked = false
        if let device = duckedDevice { Self.setVolume(savedVolume, on: device) }
        duckedDevice = nil
        UserDefaults.standard.removeObject(forKey: Self.restoreVolumeKey)
        UserDefaults.standard.removeObject(forKey: Self.restoreUIDKey)
    }

    /// Called once at launch: if we were ducked when the app last died, the saved volume
    /// (and the device it belonged to) are still on disk. Put it back so the user isn't
    /// left muted, restoring the same device when it's still present.
    static func restoreAfterCrashIfNeeded() {
        guard let saved = UserDefaults.standard.object(forKey: restoreVolumeKey) as? Float else { return }
        let uid = UserDefaults.standard.string(forKey: restoreUIDKey)
        let device = uid.flatMap(self.device(forUID:)) ?? defaultOutputDevice
        if let device { setVolume(saved, on: device) }
        UserDefaults.standard.removeObject(forKey: restoreVolumeKey)
        UserDefaults.standard.removeObject(forKey: restoreUIDKey)
        Log.info("Restored output volume left muted by a previous session")
    }

    // MARK: Core Audio

    /// The "virtual main volume" selector ('vmvc'): the single slider the user controls,
    /// regardless of how many channels the device has. Accessed by raw value so we don't
    /// depend on the deprecated AudioHardwareService header.
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766d_7663)  // 'vmvc'

    private static var defaultOutputDevice: AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// The persistent UID string for a device, so we can find the same one again later.
    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        let value = uid as String
        return value.isEmpty ? nil : value
    }

    /// Resolve a device UID back to a live device id, or nil if it's no longer present.
    private static func device(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: virtualMainVolume,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func volume(of device: AudioObjectID) -> Float? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? Float(value) : nil
    }

    private static func setVolume(_ value: Float, on device: AudioObjectID) {
        var address = volumeAddress()
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return }
        var v = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &v)
    }
}
