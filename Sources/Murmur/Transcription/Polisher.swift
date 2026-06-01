import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Cleans up a raw speech transcript using Apple's on-device language model
/// (Foundation Models, macOS 26+): removes stutters, false starts, and
/// self-corrections so the final text reads as the speaker intended, without
/// changing meaning, wording style, or language. Fully local.
///
/// Best-effort: returns nil when Apple Intelligence is unavailable or the text is
/// too short to be worth a round-trip, so callers fall back to the unpolished text.
enum Polisher {
    /// Polish only when the user has the setting on; always returns usable text (the
    /// original when off, or when the model declines / errors). One call site for the
    /// dictation and transcription pipelines to share.
    static func polishIfEnabled(_ text: String) async -> String {
        guard Settings.polishTranscripts else { return text }
        return await polish(text) ?? text
    }

    /// Polish `text`, or return nil to signal "use the original unchanged".
    static func polish(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return nil }   // too short to bother

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await clean(trimmed)
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func clean(_ text: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else {
            Log.info("AI cleanup skipped (Apple Intelligence unavailable)")
            return nil
        }
        let capped = text.count > 6000 ? String(text.prefix(6000)) : text

        let session = LanguageModelSession {
            "You clean up a raw speech-to-text transcript. Remove stutters, filler "
            + "words, false starts, and self-corrections: when the speaker restates or "
            + "changes a word mid-sentence, keep only their final intended version. Fix "
            + "obvious punctuation and capitalization. Do NOT add information, do NOT "
            + "summarize, do NOT translate, and do NOT change the meaning or the "
            + "speaker's wording and tone. Always reply in the SAME language as the "
            + "input. Output ONLY the cleaned text, with no preamble or quotation marks."
        }
        do {
            let response = try await session.respond(to: "Transcript:\n\(capped)")
            let cleaned = stripPreamble(response.content)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'"))
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            // Includes Apple's safety guardrail occasionally false-positiving (more
            // often on non-English). Caller falls back to the unpolished text.
            Log.error("AI cleanup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The model sometimes prefixes a chatty preamble line ("Sure, here is the cleaned
    /// transcript:") despite instructions. If the first line is short and ends with a
    /// colon, drop it and keep the body.
    private static func stripPreamble(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let nl = trimmed.firstIndex(of: "\n") else { return trimmed }
        let firstLine = trimmed[..<nl].trimmingCharacters(in: .whitespaces)
        guard firstLine.hasSuffix(":"), firstLine.count < 80 else { return trimmed }
        return String(trimmed[trimmed.index(after: nl)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
}
