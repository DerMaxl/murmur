@preconcurrency import AVFoundation

/// Records system / app audio to disk continuously (crash-safe, same as the mic
/// recorder), downsampling the tap's native stereo to 16 kHz mono Float32 CAF so it
/// feeds the transcription engine directly.
///
/// `@unchecked Sendable`: all shared state is guarded by `lock`, and `onLevel` is set
/// before `start()`. This lets the tap's `@Sendable` callback capture `self`.
final class SystemAudioRecorder: @unchecked Sendable {
    private let tap = SystemAudioTap()
    private let lock = NSLock()
    private var outputFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var isRecording = false

    /// Live loudness (0...1) per buffer, for the meter HUD. Set before `start()`.
    var onLevel: (@Sendable (Float) -> Void)?

    func start(writingTo url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRecording else { return }

        let target = CrashSafeRecorder.transcriptionFormat
        outputFile = try AVAudioFile(forWriting: url,
                                     settings: target.settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)
        do {
            try tap.start { [weak self] buffer in self?.append(buffer) }
        } catch {
            outputFile = nil
            throw error
        }
        isRecording = true
        Log.info("System-audio capture started → \(url.lastPathComponent)")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return }
        tap.stop()
        outputFile = nil
        converter = nil
        isRecording = false
        Log.info("System-audio capture stopped")
    }

    // MARK: Audio thread

    private func append(_ inBuffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let outputFile else { return }

        let target = CrashSafeRecorder.transcriptionFormat
        if converter == nil {
            // The tap format (e.g. 48 kHz stereo) is known once buffers arrive;
            // build the stereo→mono / 48k→16k converter from it.
            converter = AVAudioConverter(from: inBuffer.format, to: target)
        }
        guard let converter else { return }

        let ratio = target.sampleRate / inBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target,
                                               frameCapacity: capacity) else { return }

        nonisolated(unsafe) var consumed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if convError != nil { return }
        guard status != .error, outBuffer.frameLength > 0 else { return }

        do {
            try outputFile.write(from: outBuffer)
        } catch {
            Log.error("System-audio write failed: \(error.localizedDescription)")
        }

        if let onLevel { onLevel(CrashSafeRecorder.loudness(outBuffer)) }
    }
}
