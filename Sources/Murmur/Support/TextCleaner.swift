import Foundation

/// Removes spoken filler words (uh, um, äh, …) from a transcript, offline. Gated by
/// the `Settings.removeFillers` toggle. Conservative on purpose: only interjections
/// that aren't real words in German, English, or Dutch are stripped (e.g. "er" is
/// excluded because it means "he" in German).
enum TextCleaner {
    private static let fillers: Set<String> = [
        "uh", "uhh", "um", "umm", "uhm", "erm",
        "hmm", "hm", "mhm",
        "äh", "ähm", "ähem",
        "eh", "ehm",
    ]

    /// Apply filler removal if the user has it enabled, else return text unchanged.
    static func process(_ text: String) -> String {
        Settings.removeFillers ? removeFillers(text) : text
    }

    static func removeFillers(_ text: String) -> String {
        var result = text
        for filler in fillers {
            // Whole word, optionally followed by a comma, case-insensitive.
            let pattern = "\\b\(filler)\\b,?"
            result = result.replacingOccurrences(
                of: pattern, with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        // Tidy up the gaps the removals leave behind.
        result = result.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " +([,.!?])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: " +\n", with: "\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
