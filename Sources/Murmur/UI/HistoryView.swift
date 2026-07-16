import SwiftUI

/// Browsable list of every recording, with a search box and a source-type filter on
/// the left and a read-only detail pane on the right.
struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var filter: SourceFilter = .all
    @State private var selectedID: UUID?
    @State private var confirmingBulkDelete = false

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all, dictation, meeting, imported
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .dictation: return "Dictation"
            case .meeting: return "Meetings"
            case .imported: return "Imports"
            }
        }
        func matches(_ r: Recording) -> Bool {
            switch self {
            case .all: return true
            case .dictation: return r.source == .dictation
            case .meeting: return r.source == .meeting
            case .imported: return r.source == .imported || r.source == .memo
            }
        }
    }

    private var filtered: [Recording] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // range(of:options:) matches case-insensitively without allocating; the old
        // lowercased() approach copied every transcript on each keystroke.
        func has(_ s: String?) -> Bool { s?.range(of: q, options: .caseInsensitive) != nil }
        return model.recordings.filter { rec in
            guard filter.matches(rec) else { return false }
            guard !q.isEmpty else { return true }
            return has(rec.displayName) || has(rec.transcript)
                || has(rec.summary) || has(rec.sourceApp)
        }
    }

    /// Filtered recordings grouped into day sections, newest day first.
    private var sections: [(day: Date, items: [Recording])] {
        let groups = Dictionary(grouping: filtered, by: \.dayStart)
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    var body: some View {
        // A fixed-width list beside a flexible detail, with no draggable divider. An
        // earlier nested HSplitView let the list be dragged wider than the window could
        // accommodate, which grew the window off the left edge of the screen. With the
        // list pinned, resizing the window only resizes the detail pane.
        HStack(spacing: 0) {
            listColumn
                .frame(width: 340)
            Divider()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcripts", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(8)

            Picker("", selection: $filter) {
                ForEach(SourceFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            // Bulk delete: acts on whatever the search + filter currently show, so you
            // can (say) pick "Dictation" and clear them all in one step instead of
            // deleting hundreds of rows one by one.
            if !filtered.isEmpty {
                HStack {
                    Text("\(filtered.count) shown")
                        .scaledFont(11).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { confirmingBulkDelete = true } label: {
                        Label("Delete Shown", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .scaledFont(11)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            Divider()

            if filtered.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                recordingsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog("Delete \(filtered.count) recording\(filtered.count == 1 ? "" : "s")?",
                            isPresented: $confirmingBulkDelete, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) { bulkDeleteShown() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves everything currently shown to Recently Deleted, where it can be restored for 30 days.")
        }
    }

    /// Empty list: nudge a brand-new user toward Settings to set up dictation (the app's
    /// main entry point, off by default), or just note an empty search/filter result.
    @ViewBuilder
    private var emptyState: some View {
        if model.recordings.isEmpty {
            ContentUnavailableView {
                Label("No recordings yet", systemImage: "waveform")
            } description: {
                Text(model.dictationEnabled
                     ? "Hold \(model.dictationTriggerDescription) anywhere to dictate, or record a meeting. You can change your shortcuts in Settings."
                     : "Turn on push-to-talk dictation and pick a shortcut in Settings, then hold it anywhere to start dictating.")
            } actions: {
                Button("Open Settings") { model.tab = .settings }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                   description: Text("Try a different search or filter."))
        }
    }

    /// Soft-delete every recording matching the current search + filter, in one batch.
    private func bulkDeleteShown() {
        let ids = filtered.map(\.id)
        if let sel = selectedID, ids.contains(sel) { selectedID = nil }
        model.delete(ids)
    }

    private var recordingsList: some View {
        List(selection: $selectedID) {
            ForEach(sections, id: \.day) { section in
                Section(Self.dayHeader(section.day)) {
                    ForEach(section.items) { rec in
                        row(for: rec)
                    }
                }
            }
        }
        .listStyle(.inset)
        // Drop the list's own (cool-toned) backdrop so it shows the panel surface, matching
        // the filter bar above it, the detail pane, and the Import/Settings panes.
        .scrollContentBackground(.hidden)
        // Open on the most recent recording rather than an empty detail pane (which
        // looks especially bare on a large or maximized window). Only when nothing is
        // already selected, so it never fights a selection the user made.
        .onAppear { if selectedID == nil { selectedID = filtered.first?.id } }
        // Delete the selected recording with the keyboard: the Delete key (the standard
        // list deletion), plus Command-Delete (Finder's "move to trash"). Soft delete,
        // so it's restorable from Recently Deleted.
        .onDeleteCommand(perform: deleteSelected)
        .onKeyPress(keys: [.delete]) { press in
            guard press.modifiers.contains(.command), selectedID != nil else { return .ignored }
            deleteSelected()
            return .handled
        }
    }

    private func row(for rec: Recording) -> some View {
        RecordingRow(rec: rec).tag(rec.id)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { deleteRow(rec.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            .contextMenu {
                if rec.transcript?.isEmpty == false {
                    Button("Copy Transcript") { model.copyTranscript(rec.id) }
                }
                // Re-transcribe (or transcribe) whenever the audio is still on disk;
                // not offered for text-only dictations, which keep no audio.
                if rec.transcription != .running, rec.hasTranscribableAudio {
                    Button(rec.transcription == .done ? "Re-transcribe" : "Transcribe") {
                        model.transcribe(rec.id)
                    }
                }
                Button("Reveal in Finder") { model.revealInFinder(rec.id) }
                Divider()
                Button("Delete", role: .destructive) { deleteRow(rec.id) }
            }
    }

    /// Delete whatever row is selected (used by the Delete / Command-Delete shortcuts).
    private func deleteSelected() {
        if let id = selectedID { deleteRow(id) }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selectedID, let rec = model.recordings.first(where: { $0.id == id }) {
            RecordingDetailView(rec: rec, model: model) { selectedID = nil }
        } else {
            ContentUnavailableView("Select a recording",
                                   systemImage: "doc.text.magnifyingglass",
                                   description: Text("Pick a recording to read its transcript."))
        }
    }

    /// Soft-delete a row, clearing the detail pane if it was the selected one.
    private func deleteRow(_ id: UUID) {
        if selectedID == id { selectedID = nil }
        model.delete(id)
    }

    // Cached: DateFormatter construction is milliseconds-expensive, and dayHeader
    // runs per section per render.
    private static let sameYearHeader: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()
    private static let otherYearHeader: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static func dayHeader(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = cal.isDate(day, equalTo: Date(), toGranularity: .year)
        return (sameYear ? sameYearHeader : otherYearHeader).string(from: day)
    }
}

/// One row in the history list: source icon, title, one-line preview, and a compact
/// metadata footer (time · duration · app · words).
private struct RecordingRow: View {
    let rec: Recording
    @Environment(\.fontScale) private var scale

    var body: some View {
        HStack(alignment: .top, spacing: 10 * scale) {
            Image(systemName: rec.sourceSymbol)
                .scaledFont(14)
                .foregroundStyle(Brand.wave)
                .frame(width: 22 * scale, height: 22 * scale)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(rec.displayName).scaledFont(13).lineLimit(1)
                Text(rec.previewLine)
                    .scaledFont(12).foregroundStyle(.secondary).lineLimit(2)
                // No source-type word here ("Dictation" / "Meeting" / "Import"): the
                // leading icon already conveys it, and dropping it keeps this footer to
                // one line in the narrow list instead of wrapping it letter by letter.
                HStack(spacing: 6 * scale) {
                    Text(rec.startedAt, format: .dateTime.hour().minute())
                    if let d = rec.durationText { metaDot; Text(d) }
                    if let app = rec.sourceApp {
                        metaDot
                        // For dictations the app is where the text was typed (arrow);
                        // for meetings it's whose audio was captured (speaker).
                        Image(systemName: rec.source == .dictation ? "arrow.right" : "speaker.wave.2.fill")
                        Text(app).lineLimit(1)
                    }
                    if rec.wordCount > 0 { metaDot; Text("\(rec.wordCount) words") }
                }
                .scaledFont(11).foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
            statusBadge
        }
        .padding(.vertical, 3)
    }

    private var metaDot: some View { Text("·").foregroundStyle(.quaternary) }

    @ViewBuilder
    private var statusBadge: some View {
        switch rec.transcription {
        case .running: ProgressView().controlSize(.small)
        case .failed:  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:       EmptyView()
        }
    }
}
