import SwiftUI

/// Read-only detail for a single recording: title, metadata, AI summary, the full
/// transcript (selectable), and actions to copy / reveal / delete.
struct RecordingDetailView: View {
    let rec: Recording
    @Bindable var model: AppModel
    var onDelete: () -> Void

    /// Briefly true right after a copy, to swap the copy icon to a confirmation check.
    @State private var didCopy = false
    /// Guards the check's auto-reset so a quick second copy doesn't clear it early.
    @State private var copyToken = 0
    @Environment(\.fontScale) private var scale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16 * scale) {
                header
                metadata
                if let s = rec.summary, !s.isEmpty { summaryCard(s) }
                Divider()
                transcriptBody
            }
            .padding(20 * scale)
            // Cap the reading column at a comfortable width and center it in the pane,
            // so a maximized window doesn't stretch the transcript edge to edge (long,
            // sparse lines). The inner maxWidth also bounds the text so it wraps instead
            // of overflowing. Mirrors how the Settings Form constrains its own width;
            // scales with the zoom level so the line length stays balanced when zoomed.
            .frame(maxWidth: 720 * scale, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10 * scale) {
            Image(systemName: rec.sourceSymbol)
                .scaledFont(20).foregroundStyle(Brand.wave)
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(rec.displayName).scaledFont(20, weight: .bold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(rec.startedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                    .scaledFont(12).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            actions
        }
    }

    /// Copy / Reveal / (Transcribe) / Delete. Lives in the view's own header, not the
    /// window toolbar: a `.toolbar` only appears on this tab, so it changed the title
    /// bar's height between tabs and shifted the traffic lights. Here it has a fixed home.
    private var actions: some View {
        HStack(spacing: 8 * scale) {
            // On copy, swap to a green check for ~1.5s so the click visibly registers
            // (the clipboard gives no feedback of its own).
            Button(action: copyTranscript) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .tint(didCopy ? .green : Brand.accent)
            .disabled(rec.transcript?.isEmpty ?? true)
            .help(didCopy ? "Copied" : "Copy transcript")
            .accessibilityLabel("Copy transcript")
            Button { model.revealInFinder(rec.id) } label: { Image(systemName: "folder") }
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
            // (Re-)transcribe: available whenever the audio is still on disk (so not
            // for text-only dictations). A running transcription shows a spinner in
            // its place. A finished one offers a redo - handy after switching the
            // speech model - labelled with the engine it will use.
            if rec.transcription == .running {
                ProgressView().controlSize(.small).padding(.horizontal, 4)
            } else if rec.hasTranscribableAudio {
                let isRedo = rec.transcription == .done
                Button { model.transcribe(rec.id) } label: { Image(systemName: "arrow.clockwise") }
                    .help(isRedo ? "Re-transcribe with \(model.currentEngineName)" : "Transcribe")
                    .accessibilityLabel(isRedo ? "Re-transcribe" : "Transcribe")
            }
            // Delete is immediate, no confirmation: it's a soft delete the user can
            // restore from Recently Deleted for 30 days.
            Button { model.delete(rec.id); onDelete() } label: { Image(systemName: "trash") }
                .tint(.red)
                .help("Delete")
                .accessibilityLabel("Delete")
        }
        // Bordered buttons show the standard pressed-in highlight on click, so every
        // action gives visible feedback. Consistent brand tint, green on a successful
        // copy, red for the destructive delete.
        .buttonStyle(.bordered)
        .tint(Brand.accent)
        .scaledFont(15)
    }

    /// Copy the transcript and flash a confirmation check on the button.
    private func copyTranscript() {
        model.copyTranscript(rec.id)
        withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
        copyToken += 1
        let token = copyToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copyToken == token { withAnimation { didCopy = false } }
        }
    }

    private var metadata: some View {
        HStack(spacing: 8 * scale) {
            chip(rec.sourceLabel, "tag")
            if let d = rec.durationText { chip(d, "clock") }
            if let app = rec.sourceApp {
                chip(app, rec.source == .dictation ? "arrow.right.square" : "speaker.wave.2")
            }
            if rec.wordCount > 0 { chip("\(rec.wordCount) words", "text.alignleft") }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .scaledFont(11).foregroundStyle(.secondary)
            .padding(.horizontal, 8 * scale).padding(.vertical, 4 * scale)
            .background(.quaternary, in: Capsule())
    }

    private func summaryCard(_ summary: String) -> some View {
        HStack(alignment: .top, spacing: 8 * scale) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text(summary).scaledFont(12)
            Spacer(minLength: 0)
        }
        .padding(12 * scale)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10 * scale))
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if let t = rec.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            // A re-transcribe of a finished recording keeps the old text on screen
            // until the new run lands (meetings don't stream partials), so flag that
            // it's re-running rather than leaving the stale text looking final.
            if rec.transcription == .running { retranscribingBanner }
            Text(t)
                .scaledFont(13)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if rec.transcription == .running {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Transcribing…").foregroundStyle(.secondary) }
        } else {
            Text("No transcript.").foregroundStyle(.secondary)
        }
    }

    private var retranscribingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Re-transcribing with \(model.currentEngineName)…").scaledFont(12).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4 * scale)
    }
}
