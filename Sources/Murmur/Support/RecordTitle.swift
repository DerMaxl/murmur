import Foundation

/// Derives a short, human-readable title from a transcript, fully offline. Used for
/// the menu, the Markdown frontmatter, and the INDEX manifest.
enum RecordTitle {
    static func make(from transcript: String?) -> String {
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return "Untitled recording" }

        // First sentence, capped at a handful of words.
        let firstSentence = text.split(whereSeparator: { ".!?\n".contains($0) })
            .first.map(String.init) ?? text
        let words = firstSentence.split(separator: " ").prefix(9)
        var title = words.joined(separator: " ")
        if title.count > 60 {
            title = String(title.prefix(60)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}
