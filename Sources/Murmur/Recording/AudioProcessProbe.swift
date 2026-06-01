import AppKit
import CoreAudio

/// Finds which app is actually producing audio, via Core Audio's process objects
/// (macOS 14.4+) - so a meeting is labelled with the real source (e.g. "zoom.us")
/// rather than whatever window happens to be frontmost.
enum AudioProcessProbe {
    /// Apps currently outputting audio (excluding Murmur itself).
    static func audioProducingApps() -> [NSRunningApplication] {
        let mine = Bundle.main.bundleIdentifier
        var apps: [NSRunningApplication] = []
        for object in processObjectIDs() where isRunningOutput(object) {
            guard let bundleID = bundleID(object), bundleID != mine,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            else { continue }
            if !apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                apps.append(app)
            }
        }
        return apps
    }

    // MARK: Core Audio reads

    private static func processObjectIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var cf: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        let value = cf as String
        return value.isEmpty ? nil : value
    }
}
