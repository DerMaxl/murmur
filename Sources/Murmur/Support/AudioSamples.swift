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
