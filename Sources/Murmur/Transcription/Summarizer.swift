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
        guard text.count > 40 else { return nil }   // too short to be worth summarizing

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
            "You summarize a voice transcript in one concise sentence of at most 14 "
            + "words. Output only the summary, with no preamble or quotation marks."
        }
        do {
            let response = try await session.respond(to: "Transcript:\n\(capped)")
            let summary = response.content
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'"))
            return summary.isEmpty ? nil : summary
        } catch {
            Log.error("Summary generation failed: \(error.localizedDescription)")
            return nil
        }
    }
    #endif
}
