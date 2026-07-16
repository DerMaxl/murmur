import SwiftUI

/// Recently Deleted: recordings that were deleted (manually or by the auto-delete
/// retention) but not yet purged. Each can be restored or removed permanently; they're
/// purged automatically 30 days after deletion.
struct RecentlyDeletedView: View {
    @Bindable var model: AppModel
    @Environment(\.fontScale) private var scale
    @State private var confirmingEmpty = false
    /// The recording whose per-item "delete permanently" is awaiting confirmation.
    @State private var pendingDelete: Recording?

    var body: some View {
        VStack(spacing: 0) {
            // A header row mirroring History's "N shown / Delete Shown" bar: the item count
            // on the left, the destructive Empty on the right, a divider beneath. That grounds
            // the button as part of a header rather than a lone control floating in an empty
            // strip. Kept in the content, not a `.toolbar`: a toolbar only appears on this tab,
            // which changed the title-bar height between tabs and shifted the traffic lights.
            // A fixed in-content spot avoids that. (The 30-day note lives in the list footer,
            // where it reads per-item; a count next to it up here implied a single batch purge.)
            if !model.deletedRecordings.isEmpty {
                HStack {
                    Text("\(model.deletedRecordings.count) item\(model.deletedRecordings.count == 1 ? "" : "s")")
                        .scaledFont(11).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { confirmingEmpty = true } label: {
                        Label("Empty", systemImage: "trash.slash")
                    }
                    .buttonStyle(.borderless)
                    .scaledFont(11)
                }
                .padding(.horizontal, 16 * scale)
                .padding(.vertical, 8 * scale)
                Divider()
            }

            if model.deletedRecordings.isEmpty {
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "trash",
                    description: Text("Deleted recordings appear here for 30 days, so you can restore them. Then they're removed for good."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(model.deletedRecordings) { rec in
                            row(rec)
                        }
                    } footer: {
                        Text("Items are removed permanently 30 days after deletion.")
                            .scaledFont(11).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
                // Drop the list's own backdrop so it sits on the panel surface like the
                // rest of the app, instead of a distinct (cooler-toned) inset background.
                .scrollContentBackground(.hidden)
            }
        }
        // Cap the content width and center it, so rows don't stretch edge-to-edge on a
        // wide or full-screen window (title far left, buttons far right, a void between).
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Permanently delete everything in Recently Deleted?",
                            isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Delete All Permanently", role: .destructive) { model.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(model.deletedRecordings.count) recording\(model.deletedRecordings.count == 1 ? "" : "s") and their files. This can't be undone.")
        }
        .confirmationDialog("Permanently delete this recording?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { rec in
            Button("Delete Permanently", role: .destructive) { model.deletePermanently(rec.id) }
            Button("Cancel", role: .cancel) {}
        } message: { rec in
            Text("“\(rec.displayName)” and its files will be removed. This can't be undone.")
        }
    }

    private func row(_ rec: Recording) -> some View {
        HStack(alignment: .top, spacing: 10 * scale) {
            Image(systemName: rec.sourceSymbol)
                .scaledFont(14).foregroundStyle(.secondary)
                .frame(width: 22 * scale, height: 22 * scale)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(rec.displayName).scaledFont(13).lineLimit(1)
                Text(rec.previewLine).scaledFont(12).foregroundStyle(.secondary).lineLimit(2)
                if let when = rec.deletedAt {
                    Text("Deleted \(when, format: .relative(presentation: .named))")
                        .scaledFont(11).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6 * scale) {
                Button("Restore") { model.restore(rec.id) }
                    .buttonStyle(.borderless)
                Button {
                    pendingDelete = rec
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete permanently")
            }
        }
        .padding(.vertical, 3)
    }
}
