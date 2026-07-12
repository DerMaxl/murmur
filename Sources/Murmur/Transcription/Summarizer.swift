import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Generates a one-line summary of a transcript using Apple's on-device language
/// model (the Foundation Models framework, macOS 26+). Fully local, nothing leaves
/// the Mac. Returns nil when Apple Intelligence isn't available (older OS, not
/// enabled, unsupported device), so callers degrade gracefully to "no summary".
enum Summarizer {
    static func summarize(_ transcript: String) async -> String? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // A short transcript IS its own summary: a 14-word cap can't compress a
        // couple of dozen words, so the model just reads them back (observed with a
        // 12-word meeting). Only summarize when there is something to compress.
        guard text.split(whereSeparator: \.isWhitespace).count >= 25 else { return nil }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await generate(text)
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func generate(_ text: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else {
            Log.info("On-device summary skipped (Apple Intelligence unavailable)")
            return nil
        }
        // The on-device model has a bounded context window; cap very long
        // transcripts so a long memo still gets a summary instead of erroring out.
        let capped = text.count > 6000 ? String(text.prefix(6000)) : text

        let session = LanguageModelSession {
            """
            You write a one-line summary of a voice transcript (a dictation, meeting, \
            or memo). Rules:
            - Exactly one sentence, at most 14 words, in the same language as the \
            transcript.
            - Describe what it is about - the topic, decisions, or requests - in your \
            own words, like an email subject line.
            - Never quote the transcript or repeat its sentences back.
            - Never refer to "the user" or "the speaker"; describe the content itself.
            - Output only that one sentence: no label, no preamble, no explanation \
            line after it, no quotation marks.
            """
        }
        do {
            let response = try await session.respond(to: "Transcript:\n\(capped)")
            // The model sometimes returns a headline plus an explainer line despite
            // the one-sentence rule (seen: "Job acceptance request - User seeks help
            // drafting..."); keep only the first non-empty line, stripped of stray
            // bullet/dash/quote decoration.
            let summary = response.content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-\u{2013}\u{2014}•\"'")) }
                .first { !$0.isEmpty } ?? ""
            guard !summary.isEmpty else { return nil }
            // The model sometimes ignores the rules and reads the transcript back
            // (with or without a stray label in front). A bad summary is worse than
            // none: the transcript's own first line already shows in the UI.
            guard !isEcho(summary, of: text) else {
                Log.info("Summary discarded (echoed the transcript)")
                return nil
            }
            return summary
        } catch {
            Log.error("Summary generation failed: \(error.localizedDescription)")
            return nil
        }
    }
    #endif

    /// True when the "summary" is essentially the transcript read back rather than a
    /// compression of it. Compares a normalized trailing chunk, so a stray label
    /// prefix ("Summary: ...") can't disguise an echo.
    private static func isEcho(_ summary: String, of transcript: String) -> Bool {
        let normalizedSummary = normalize(summary)
        guard normalizedSummary.count >= 12 else { return false }
        return normalize(transcript).contains(String(normalizedSummary.suffix(24)))
    }

    /// Case-, punctuation-, and whitespace-insensitive form for echo comparison.
    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
