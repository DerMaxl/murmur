import Foundation

/// Presentation helpers for `Recording`, used by the SwiftUI History view. Kept out
/// of the store type so the data model stays free of UI concerns.
extension Recording {
    /// SF Symbol that conveys what this recording is.
    var sourceSymbol: String {
        switch source {
        case .dictation: return "keyboard"
        case .meeting:   return "person.2.wave.2.fill"
        case .memo:      return "mic.fill"
        case .imported:  return "square.and.arrow.down"
        }
    }

    /// Human label for the source ("Dictation", "Meeting", …).
    var sourceLabel: String {
        switch source {
        case .dictation: return "Dictation"
        case .meeting:   return "Meeting"
        case .memo:      return "Recording"
        case .imported:  return "Import"
        }
    }

    /// Word count of the transcript (0 if none yet).
    var wordCount: Int {
        guard let t = transcript else { return 0 }
        return t.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    /// A one-line subtitle: the AI summary if present, else the start of the
    /// transcript, else a status hint.
    var previewLine: String {
        if let s = summary, !s.isEmpty { return s }
        if let t = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let firstLine = t.split(separator: "\n").first.map(String.init) ?? t
            return String(firstLine.prefix(120))
        }
        switch transcription {
        case .running: return "Transcribing…"
        case .failed:  return "Transcription failed"
        default:       return "No transcript yet"
        }
    }

    /// `mm:ss` (or `h:mm:ss`) duration, from the stored value or the file times.
    var durationText: String? {
        let seconds: Double?
        if let d = durationSeconds {
            seconds = d
        } else if let end = finishedAt {
            seconds = end.timeIntervalSince(startedAt)
        } else {
            seconds = nil
        }
        guard let s = seconds, s >= 1 else { return nil }
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    /// The day this recording belongs to, for grouped section headers.
    var dayStart: Date { Calendar.current.startOfDay(for: startedAt) }
}
