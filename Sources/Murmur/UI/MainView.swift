import SwiftUI

/// The window's root: a fixed sidebar that switches between History, Import, Recently
/// Deleted, and Settings. Kept deliberately small - the app is driven mostly by the
/// global hotkey; this window is for browsing past recordings and changing settings
/// without hunting through the menu bar.
struct MainView: View {
    @Bindable var model: AppModel

    /// Below this window width the sidebar is hidden. Sized so the transcript pane keeps
    /// roughly 420pt: with the sidebar (232) and the recordings list (340) both showing,
    /// the detail only clears that at about 1000pt of window.
    private static let sidebarBreakpoint: CGFloat = 1000

    /// Whether the window was last seen narrower than the breakpoint. Only *crossing* it
    /// moves the sidebar, so a manual Show/Hide (⌃⌘S) sticks instead of being reverted by
    /// the next stray resize, including the one that showing the sidebar itself causes.
    @State private var wasNarrow: Bool?

    var body: some View {
        // A NavigationSplitView whose sidebar column is pinned with a *single* fixed
        // width. The earlier hand-rolled HStack existed because the split view's divider
        // stayed draggable, so the sidebar could be widened until the window ran off the
        // left of the screen; that was with a min/ideal/max range, which SwiftUI treats as
        // resizable. A lone `navigationSplitViewColumnWidth(232)` makes the column fixed,
        // so there's nothing to drag. In exchange we get the native sidebar collapse, which
        // lets a narrow (half-screen) window reclaim the sidebar's 232pt for the content.
        //
        // The window title bar shows no text (hidden in MainWindowController): SwiftUI
        // forces a large, bold title whenever a tab's content is a List (History,
        // Recently Deleted) but an inline one for the Form/VStack tabs, and won't
        // reliably let us unify them. The sidebar already shows the selected section,
        // so hiding the redundant title makes every tab's title bar identical.
        // The sidebar costs 232pt, which a half-screen window can't spare (it leaves the
        // transcript pane around 270pt, too narrow to read), so it hides itself when the
        // window is narrow and comes back when there's room. View > Show/Hide Sidebar
        // (⌃⌘S) overrides it, which is the way back to the other sections while narrow.
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(232)
        } detail: {
            NavigationStack {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Hide the sidebar on a narrow (half-screen) window and bring it back when the
        // window grows. Reads the split view's own width, which is the window's content
        // width and doesn't change when the sidebar collapses, so this can't oscillate.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let narrow = width < Self.sidebarBreakpoint
            guard narrow != wasNarrow else { return }   // only act on a crossing
            wasNarrow = narrow
            model.sidebarVisibility = narrow ? .detailOnly : .all
        }
        // The minimum has to stay under half a Mac screen, or the window can't actually
        // tile to half: macOS clamps the tile up to the minimum instead (at 840 on a
        // 1470pt screen it came out 840 against a 735pt half, i.e. 1.14x half, which reads
        // as "a bit more than half"). Now that the sidebar hides itself below 1000pt, the
        // floor only has to fit the recordings list (340) plus a readable detail.
        .frame(minWidth: 700, minHeight: 520)
        .tint(Brand.accent)
        .environment(\.fontScale, model.fontScale)
    }

    private var sidebar: some View {
        List(selection: $model.tab) {
            Label("History", systemImage: "clock.arrow.circlepath")
                .tag(AppModel.Tab.history)
            Label("Import a file", systemImage: "square.and.arrow.down")
                .tag(AppModel.Tab.importFiles)
            // A trailing count instead of `.badge()`: the system badge rendered a hair
            // above the row's text baseline, so this centers it against the label instead.
            Label {
                HStack(spacing: 0) {
                    // Priority so the label keeps its full width (even bold, when selected)
                    // and never truncates to "Recently Delet…" to make room for the count.
                    Text("Recently Deleted").layoutPriority(1)
                    if model.deletedRecordings.count > 0 {
                        Spacer(minLength: 8)
                        // `.secondary` derives from the row's foreground, so it stays muted
                        // when unselected and legible (light) on the selected blue row.
                        Text(model.deletedRecordings.count, format: .number)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "trash")
            }
            .tag(AppModel.Tab.recentlyDeleted)
            Label("Settings", systemImage: "gearshape")
                .tag(AppModel.Tab.settings)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.tab {
        case .history:         HistoryView(model: model)
        case .importFiles:     ImportView(model: model)
        case .recentlyDeleted: RecentlyDeletedView(model: model)
        case .settings:        SettingsView(model: model)
        }
    }
}
