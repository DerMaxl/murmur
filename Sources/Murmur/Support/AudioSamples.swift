@preconcurrency import AVFoundation

/// Reads an audio file into mono Float samples plus its sample rate and channel
/// count. Our recordings are already 16 kHz mono, so this is a cheap, exact read.
enum AudioSamples {
    /// Read just the format (no sample data) - cheap, for deciding the code path
    /// before loading a potentially large file.
    static func format(_ url: URL) throws -> (sampleRate: Int, channels: Int) {
        let file = try AVAudioFile(forReading: url)
        return (Int(file.processingFormat.sampleRate), Int(file.processingFormat.channelCount))
    }

    /// Decode any audio file and write a 16 kHz mono Float32 copy to a temp WAV,
    /// returning its URL (caller deletes it). Imported files are arbitrary formats,
    /// but both segment-level ASR and diarization need 16 kHz mono, so we normalise
    /// once and feed the copy to both. Uses AVAudioConverter for sample-rate /
    /// channel conversion, streaming in chunks so memory stays bounded.
    static func write16kMonoCopy(of url: URL) throws -> URL {
        let inFile = try AVAudioFile(forReading: url)
        let inFormat = inFile.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000,
                                            channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let outFile = try AVAudioFile(forWriting: tempURL, settings: outFormat.settings)

        let inCapacity: AVAudioFrameCount = 1 << 16
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCapacity) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inCapacity) * ratio) + 1024

        // The converter pulls input via this (@Sendable) block. We hold the per-call
        // feed flags in a reference type rather than captured vars. `@unchecked
        // Sendable` is safe here: the converter invokes the block synchronously on the
        // calling thread, so `state` is never touched concurrently.
        final class FeedState: @unchecked Sendable { var fedThisCall = false; var ended = false }
        let state = FeedState()

        while !state.ended {
            state.fedThisCall = false
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let status = converter.convert(to: outBuffer, error: nil) { _, inStatus in
                if state.ended || state.fedThisCall {
                    inStatus.pointee = state.ended ? .endOfStream : .noDataNow
                    return nil
                }
                do {
                    inBuffer.frameLength = 0
                    try inFile.read(into: inBuffer)
                } catch {
                    state.ended = true
                    inStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    state.ended = true
                    inStatus.pointee = .endOfStream
                    return nil
                }
                state.fedThisCall = true
                inStatus.pointee = .haveData
                return inBuffer
            }
            if outBuffer.frameLength > 0 { try outFile.write(from: outBuffer) }
            // A mid-stream converter error would leave a truncated copy; throw so the
            // caller falls back to the original file rather than transcribing a fragment.
            if status == .error { throw CocoaError(.fileReadCorruptFile) }
            if status == .endOfStream { break }
        }
        return tempURL
    }

    static func read(_ url: URL) throws -> (samples: [Float], sampleRate: Int, channels: Int) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat   // Float32, deinterleaved, file's rate
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return ([], Int(format.sampleRate), Int(format.channelCount))
        }
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        var samples: [Float] = []
        if let channel = buffer.floatChannelData, count > 0 {
            samples = Array(UnsafeBufferPointer(start: channel[0], count: count))
        }
        return (samples, Int(format.sampleRate), Int(format.channelCount))
    }
}
