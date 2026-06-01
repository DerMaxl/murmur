import Foundation

/// On-disk size accounting for the Settings screen: how much space recordings take
/// (split into audio vs. transcripts) and how big the downloaded speech model is.
enum StorageInfo {
    struct Sizes {
        var audio: Int64 = 0     // .caf audio tracks
        var text: Int64 = 0      // transcript.md, index.yaml, journal-adjacent text
        var recordings: Int64 { audio + text }
        var model: Int64 = 0     // the FluidAudio / Parakeet model cache
    }

    /// Where FluidAudio caches the downloaded model. Lives under the *real* app
    /// support dir (not affected by MURMUR_HOME), so compute it directly.
    static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }

    /// Walk the recordings folder and the model cache and total their bytes.
    static func measure() -> Sizes {
        var sizes = Sizes()
        let fm = FileManager.default
        if let en = fm.enumerator(at: Paths.recordings,
                                  includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in en {
                guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      v.isRegularFile == true else { continue }
                let bytes = Int64(v.fileSize ?? 0)
                if url.pathExtension.lowercased() == "caf" { sizes.audio += bytes }
                else { sizes.text += bytes }
            }
        }
        sizes.model = directorySize(modelDirectory)
        return sizes
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            if let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    /// Human-readable size, e.g. "124 MB". Returns "0 bytes" for zero.
    static func format(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 bytes" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
