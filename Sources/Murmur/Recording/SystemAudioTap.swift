@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures all system / app audio via a Core Audio **process tap** (macOS 14.4+),
/// driver-free (no BlackHole/Loopback). Delivers buffers in the tap's native format
/// on a background queue; the caller converts to the transcription format.
///
/// Requires the audio-recording permission (the `NSAudioCaptureUsageDescription`
/// Info.plist key), which the system prompts for on first use.
final class SystemAudioTap {
    enum TapError: Error, CustomStringConvertible {
        case createTap(OSStatus)
        case readFormat(OSStatus)
        case makeFormat
        case readDefaultOutput(OSStatus)
        case createAggregate(OSStatus)
        case createIOProc(OSStatus)
        case start(OSStatus)

        var description: String {
            switch self {
            case .createTap(let s): return "Couldn't create the system-audio tap (\(s)). Grant audio recording access."
            case .readFormat(let s): return "Couldn't read the tap format (\(s))."
            case .makeFormat: return "Unsupported system-audio format."
            case .readDefaultOutput(let s): return "Couldn't read the default output device (\(s))."
            case .createAggregate(let s): return "Couldn't create the aggregate device (\(s))."
            case .createIOProc(let s): return "Couldn't start the audio I/O proc (\(s))."
            case .start(let s): return "Couldn't start the system-audio device (\(s))."
            }
        }
    }

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.murmur.systemtap", qos: .userInitiated)

    /// Begin capturing. `onBuffer` is invoked on a background queue with system audio.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted

        var tap: AudioObjectID = 0
        let createStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard createStatus == noErr else { throw TapError.createTap(createStatus) }
        tapID = tap

        // Once the tap exists, any later failure must tear everything down again,
        // otherwise the tap/aggregate device leak.
        do {
            var asbd = try Self.tapFormat(tap)
            guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw TapError.makeFormat }

            let outputUID = try Self.defaultOutputUID()
            let dict: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Murmur System Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var aggregate: AudioObjectID = 0
            let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate)
            guard aggStatus == noErr else { throw TapError.createAggregate(aggStatus) }
            aggregateID = aggregate

            let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                                    bufferListNoCopy: inInputData,
                                                    deallocator: nil) else { return }
                onBuffer(buffer)
            }
            let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue, ioBlock)
            guard ioStatus == noErr else { throw TapError.createIOProc(ioStatus) }
            let startStatus = AudioDeviceStart(aggregate, procID)
            guard startStatus == noErr else { throw TapError.start(startStatus) }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            if let procID {
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                self.procID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    deinit { stop() }

    // MARK: Core Audio property reads

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw TapError.readFormat(status) }
        return asbd
    }

    private static func defaultOutputUID() throws -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var deviceAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var device = AudioDeviceID(0)
        var status = AudioObjectGetPropertyData(system, &deviceAddr, 0, nil, &deviceSize, &device)
        guard status == noErr else { throw TapError.readDefaultOutput(status) }

        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString
        status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, $0)
        }
        guard status == noErr else { throw TapError.readDefaultOutput(status) }
        return uid as String
    }
}
