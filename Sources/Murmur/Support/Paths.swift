import Foundation

/// Well-known on-disk locations. Everything lives under
/// ~/Library/Application Support/Murmur so recordings and the journal survive
/// crashes and relaunches.
///
/// Set the `MURMUR_HOME` environment variable to redirect everything elsewhere
/// (used for safe testing against throwaway data).
enum Paths {
    static let appSupport: URL = {
        let base: URL
        if let home = ProcessInfo.processInfo.environment["MURMUR_HOME"], !home.isEmpty {
            base = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
                .appendingPathComponent("Murmur", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Where recordings live: one folder per recording (audio + transcript.md).
    static let recordings: URL = {
        let dir = appSupport.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }()

    /// The crash-recovery journal (internal app state).
    static let journal = appSupport.appendingPathComponent("journal.json")

    /// Human- and agent-facing manifest of all recordings (a YAML list).
    static let index = recordings.appendingPathComponent("index.yaml")
}
