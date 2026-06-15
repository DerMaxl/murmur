import Foundation

/// On-disk size accounting for the Settings screen: how much space recordings take
/// (split into audio vs. transcripts) and how big the downloaded speech model is.
enum StorageInfo {
    struct Sizes {
        var audio: Int64 = 0     // active .caf audio tracks
        var text: Int64 = 0      // active transcript.md + the shared index.yaml
        var trash: Int64 = 0     // everything still on disk for Recently Deleted items
        var recordings: Int64 { audio + text }   // active only (excludes trash)
        var model: Int64 = 0     // the FluidAudio / Parakeet model cache
    }

    /// Where FluidAudio caches the downloaded model. Lives under the *real* app
    /// support dir (not affected by MURMUR_HOME), so compute it directly.
    static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }

    /// Walk the recordings folder and the model cache and total their bytes. Trashed
    /// recordings stay on disk until purged, so their folders are attributed to `trash`
    /// (not the active audio/text totals), keeping "Saved recordings" in step with the
    /// active count shown beside it. `trashedFolders` is the set of Recently Deleted
    /// recording folder names. One filesystem walk, same cost as before.
    static func measure(trashedFolders: Set<String>) -> Sizes {
        var sizes = Sizes()
        let fm = FileManager.default
        let rootPath = Paths.recordings.path
        if let en = fm.enumerator(at: Paths.recordings,
                                  includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in en {
                guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      v.isRegularFile == true else { continue }
                let bytes = Int64(v.fileSize ?? 0)
                if trashedFolders.contains(topFolder(of: url, under: rootPath)) {
                    sizes.trash += bytes
                } else if url.pathExtension.lowercased() == "caf" {
                    sizes.audio += bytes
                } else {
                    sizes.text += bytes
                }
            }
        }
        sizes.model = directorySize(modelDirectory)
        return sizes
    }

    /// The recording-folder name a file sits in (the first path component under
    /// `Recordings/`), or "" for files directly in the root such as `index.yaml`.
    private static func topFolder(of url: URL, under rootPath: String) -> String {
        let prefix = rootPath + "/"
        guard url.path.hasPrefix(prefix) else { return "" }
        let rest = url.path.dropFirst(prefix.count)
        return rest.firstIndex(of: "/").map { String(rest[..<$0]) } ?? ""
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
