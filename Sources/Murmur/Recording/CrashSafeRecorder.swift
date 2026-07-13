@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

/// Records the microphone to disk **continuously**, so a crash or force-quit loses
/// at most the last buffer instead of the whole recording.
///
/// Pipeline: `AVAudioEngine` mic tap → `AVAudioConverter` to 16 kHz mono Float32 →
/// appended to an `AVAudioFile` (CAF). That format is exactly what the transcription
/// engine consumes, so recording and transcription share one pipeline. CAF is used
/// because it stays readable while still being written, its header doesn't depend
/// on a final size field the way canonical WAV does.
///
/// `@unchecked Sendable`: all recording state is guarded by `lock`, and the
/// configuration vars (`onLevel`, `inputDeviceID`) are set before `start()`. This lets
/// `startAsync`/`stopAsync` run the blocking setup on a background queue instead of the
/// main thread.
final class CrashSafeRecorder: @unchecked Sendable {

    /// Serial queue for the blocking start/stop, so audio setup never runs on (and
    /// freezes) the main thread when the audio system is slow or wedged.
    private let startQueue = DispatchQueue(label: "com.murmur.recorder.start", qos: .userInitiated)

    /// The format every recording is written in, and every engine consumes.
    static let transcriptionFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false)!

    enum RecorderError: Error { case engineFailed(String) }

    /// Recreated on each `start()` so the input node always binds to the *current*
    /// default input device (a long-lived engine keeps using whatever was default when
    /// it was created, which goes silent if the user later switches mics).
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var outputFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var isRecording = false
    /// Total frames written this capture, logged at `stop()`: 0 (or a tiny count) flags a
    /// recording that came through silent - e.g. the mic held by another app.
    private var framesWritten: AVAudioFramePosition = 0

    /// Live input loudness (0...1), emitted per buffer from the audio thread so the
    /// UI can show a meter. Set before `start()`.
    var onLevel: (@Sendable (Float) -> Void)?

    /// Fired (once per capture, from the audio thread) when buffers keep failing to
    /// reach disk - e.g. the disk filled up. Without this the level meter keeps
    /// bouncing on the in-memory buffers and the user records into the void.
    /// Set before `start()`.
    var onWriteFailure: (@Sendable () -> Void)?
    /// Consecutive failed writes before `onWriteFailure` fires (~2 s of mic audio):
    /// a lone transient failure shouldn't alarm, a sustained streak must.
    static let writeFailureThreshold = 25
    private var consecutiveWriteFailures = 0
    private var warnedWriteFailure = false

    /// Capture from this specific input device instead of the system default. Used for
    /// meetings on Bluetooth/USB headphones: recording the headset's own mic forces it
    /// into the low-quality call (HFP) profile, which makes all audio stutter, so we
    /// record the built-in mic instead. nil = the current default input. Set before
    /// `start()`.
    var inputDeviceID: AudioDeviceID?

    /// Begin writing mic audio to `url`. Returns once capture is running.
    func start(writingTo url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRecording else { return }
        framesWritten = 0
        consecutiveWriteFailures = 0
        warnedWriteFailure = false

        // Fresh engine so the input node binds to whatever the default input is *now*.
        engine = AVAudioEngine()
        let input = engine.inputNode
        // A freshly created AVAudioEngine already binds its input node to the *current*
        // default input device, so we only override when a specific device is requested
        // (e.g. forcing the built-in mic for a meeting on Bluetooth headphones).
        // Explicitly re-binding to the default via the audio unit is not just redundant:
        // with some device configurations - notably a Bluetooth output device active - it
        // stops the input tap from delivering any buffers, so the recording is silent.
        // Skip it on the common path, and even for an override skip it when it already
        // matches the default.
        if let override = inputDeviceID, override != Self.defaultInputDevice {
            Self.bindInputDevice(input, to: override)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw RecorderError.engineFailed("No microphone input available")
        }
        let boundDevice = inputDeviceID ?? Self.defaultInputDevice
        Log.info("Recording input: \(boundDevice.flatMap(Self.deviceName) ?? "default"), "
                 + "\(Int(inputFormat.sampleRate)) Hz \(inputFormat.channelCount) ch")

        let target = Self.transcriptionFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.engineFailed("Cannot convert mic format to 16 kHz mono")
        }
        self.converter = converter

        // CAF container with the 16 kHz mono Float32 settings.
        self.outputFile = try AVAudioFile(forWriting: url,
                                          settings: target.settings,
                                          commonFormat: .pcmFormatFloat32,
                                          interleaved: false)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        // Step log: a wedged CoreAudio call can hang here for a minute or more (seen
        // with a forced input rebind); this pins down which step the time went to.
        Log.info("Mic capture configured; starting audio engine")
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            outputFile = nil
            self.converter = nil
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        isRecording = true
        Log.info("Recording started → \(url.lastPathComponent)")
    }

    /// Stop capture and flush the file to disk.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil   // closing the AVAudioFile flushes/finalizes the CAF
        converter = nil
        isRecording = false
        Log.info("Recording stopped (\(framesWritten) frames)")
    }

    // MARK: Off-main start / stop

    /// Start capture on a background queue with a timeout, so a wedged CoreAudio call
    /// can't freeze the UI. Returns whether capture began in time; a start that unblocks
    /// after the timeout tears itself back down. Set `inputDeviceID` before calling.
    func startAsync(writingTo url: URL, timeout: TimeInterval = 4) async -> Bool {
        await startWithTimeout(on: startQueue, timeout: timeout, work: { [self] in
            do { try start(writingTo: url); return true }
            catch { Log.error("Recorder start failed: \(error.localizedDescription)"); return false }
        }, undo: { [self] in stop() })
    }

    /// Synchronous stop for app termination: serialized onto the start queue so it
    /// can't race an in-flight `startAsync`, and flushes the file before the process
    /// exits.
    func stopSync() {
        startQueue.sync { stop() }
    }

    /// Stop on the background queue (teardown also makes CoreAudio calls that can block),
    /// serialized after any in-flight `startAsync` on the same queue.
    func stopAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startQueue.async { [self] in
                stop()
                continuation.resume()
            }
        }
    }

    // MARK: Input device selection

    /// Point the engine's input node at `device` (or leave it on the node default when
    /// nil). Best-effort: on failure we fall back to whatever the node defaulted to.
    private static func bindInputDevice(_ node: AVAudioInputNode, to device: AudioDeviceID?) {
        guard var deviceID = device, let unit = node.audioUnit else { return }
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { Log.error("Could not set input device (status \(status))") }
    }

    static var defaultInputDevice: AudioDeviceID? { deviceID(for: kAudioHardwarePropertyDefaultInputDevice) }
    static var defaultOutputDevice: AudioDeviceID? { deviceID(for: kAudioHardwarePropertyDefaultOutputDevice) }

    private static func deviceID(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// The built-in microphone, if this Mac has one. Recording a Bluetooth headset's own
    /// mic forces it into the low-quality call (HFP) profile, which stutters all audio,
    /// so meetings capture this instead while on headphones (see `MeetingRecorder`).
    static func builtInInputDevice() -> AudioDeviceID? {
        allDevices().first { hasInputStreams($0) && transportType($0) == kAudioDeviceTransportTypeBuiltIn }
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &ids)
        return status == noErr ? ids : []
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// True when `device` connects over Bluetooth (classic or LE). Recording a
    /// Bluetooth headset's own mic forces it into the low-quality call (HFP)
    /// profile; other transports (built-in, USB, a wireless dongle) don't have
    /// that failure mode.
    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let transport = transportType(device)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// A device's human-readable name (for diagnostics).
    static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        let value = name as String
        return value.isEmpty ? nil : value
    }

    // MARK: Microphone picker

    /// One selectable input device for the settings mic picker. Identified by its
    /// stable `uid` (the ephemeral `AudioDeviceID` changes across reconnects/reboots).
    struct InputDevice: Identifiable, Sendable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// Every input-capable device currently present, for the mic picker.
    static func availableInputDevices() -> [InputDevice] {
        allDevices().compactMap { id in
            guard hasInputStreams(id), isSelectableMic(id), let uid = deviceUID(id) else { return nil }
            return InputDevice(id: id, uid: uid, name: deviceName(id) ?? "Unknown microphone")
        }
    }

    /// Excludes devices that have input streams but aren't real, user-pickable mics:
    /// system aggregate devices (e.g. "CADefaultDeviceAggregate", which CoreAudio spins
    /// up during a FaceTime call or when an app taps the default input) and any device
    /// its driver marks hidden. Without this they leak into the picker as mystery rows.
    private static func isSelectableMic(_ device: AudioDeviceID) -> Bool {
        transportType(device) != kAudioDeviceTransportTypeAggregate && !isHidden(device)
    }

    /// Whether the device's driver marks it hidden (not intended for user selection).
    private static func isHidden(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    /// A device's persistent UID (stable across reconnects/reboots), or nil.
    static func deviceUID(_ device: AudioDeviceID) -> String? {
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

    /// Resolve a saved device UID back to a live device id, or nil if it's no longer
    /// present (e.g. the mic was unplugged), so callers fall back to the default input.
    static func device(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }

    /// The input device the user picked in settings, if it's set and still present;
    /// nil means "follow the system default input".
    static func preferredInputDevice() -> AudioDeviceID? {
        Settings.preferredInputDeviceUID.flatMap(device(forUID:))
    }

    // MARK: Audio thread

    private func append(_ inBuffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let converter, let outputFile else { return }

        let target = Self.transcriptionFormat
        let ratio = target.sampleRate / inBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target,
                                               frameCapacity: capacity) else { return }

        // The converter calls this block synchronously inside convert(), so the
        // mutation is not actually concurrent; tell Swift 6 we accept that.
        nonisolated(unsafe) var consumed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuffer
        }

        if let convError {
            Log.error("Convert failed: \(convError.localizedDescription)")
            return
        }
        guard status != .error, outBuffer.frameLength > 0 else { return }

        do {
            try outputFile.write(from: outBuffer)
            framesWritten += AVAudioFramePosition(outBuffer.frameLength)
            consecutiveWriteFailures = 0
        } catch {
            if consecutiveWriteFailures == 0 {   // log the start of a streak, not every buffer
                Log.error("Write failed: \(error.localizedDescription)")
            }
            consecutiveWriteFailures += 1
            if !warnedWriteFailure, consecutiveWriteFailures >= Self.writeFailureThreshold {
                warnedWriteFailure = true
                onWriteFailure?()
            }
        }

        if let onLevel { onLevel(Self.loudness(outBuffer)) }
    }

    /// RMS loudness of a mono Float buffer, scaled to a usable 0...1 range for a
    /// visual meter (a little gain so normal speech fills most of the bar).
    static func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = (sum / Float(count)).squareRoot()
        return min(1, rms * 6)
    }
}
