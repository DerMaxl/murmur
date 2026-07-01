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
    private var converterInputFormat: AVAudioFormat?
    private(set) var isRecording = false
    /// Whether any non-silent audio arrived during this capture. Stays false when the
    /// System Audio Recording permission is missing: the process tap then delivers pure
    /// digital silence instead of failing, so this is the only signal that the capture
    /// produced nothing. Written on the audio thread; read via `didCaptureAudio`.
    private var capturedAudio = false

    /// Lock-guarded snapshot of `capturedAudio`, safe to read from any thread. Meaningful
    /// after `stop()`.
    var didCaptureAudio: Bool { lock.lock(); defer { lock.unlock() }; return capturedAudio }

    func start(writingTo url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRecording else { return }
        capturedAudio = false

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
        converterInputFormat = nil
        isRecording = false
        Log.info("System-audio capture stopped")
    }

    // MARK: Audio thread

    private func append(_ inBuffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let outputFile else { return }

        let target = CrashSafeRecorder.transcriptionFormat
        if converter == nil || converterInputFormat != inBuffer.format {
            // The tap format (e.g. 48 kHz stereo) is known once buffers arrive; build
            // the stereo→mono / 48k→16k converter from it. Rebuild if the format ever
            // changes mid-recording (e.g. the default output device switches), so we
            // never feed mismatched buffers to a stale converter.
            converter = AVAudioConverter(from: inBuffer.format, to: target)
            converterInputFormat = inBuffer.format
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

        // Any real audio marks the track as captured; digital silence (e.g. a missing
        // System Audio Recording permission) stays exactly 0. The system track isn't
        // metered, so there's no live-level callback here (unlike the mic recorder).
        if CrashSafeRecorder.loudness(outBuffer) > 0 { capturedAudio = true }
    }
}
