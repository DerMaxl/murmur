import SwiftUI

/// The window's root: a fixed sidebar that switches between History, Import, Recently
/// Deleted, and Settings. Kept deliberately small - the app is driven mostly by the
/// global hotkey; this window is for browsing past recordings and changing settings
/// without hunting through the menu bar.
struct MainView: View {
    @Bindable var model: AppModel

    /// Sidebar widths: a narrow icon-only rail by default, or wide enough for the labels
    /// when expanded (⌃⌘S). Both are single fixed values, see the column note below.
    private static let railWidth: CGFloat = 56
    private static let expandedWidth: CGFloat = 232

    var body: some View {
        // A NavigationSplitView whose sidebar column is pinned with a *single* fixed
        // width. The earlier hand-rolled HStack existed because the split view's divider
        // stayed draggable, so the sidebar could be widened until the window ran off the
        // left of the screen; that was with a min/ideal/max range, which SwiftUI treats as
        // resizable. A lone `navigationSplitViewColumnWidth(_:)` makes the column fixed,
        // so there's nothing to drag.
        //
        // The sidebar defaults to an icon-only rail. At ~56pt instead of 232 even a
        // half-screen window can spare it, so the sections stay reachable at every size
        // rather than the sidebar having to hide itself (and stranding you in one pane).
        //
        // The window title bar shows no text (hidden in MainWindowController): SwiftUI
        // forces a large, bold title whenever a tab's content is a List (History,
        // Recently Deleted) but an inline one for the Form/VStack tabs, and won't
        // reliably let us unify them. The sidebar already shows the selected section,
        // so hiding the redundant title makes every tab's title bar identical.
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    model.sidebarExpanded ? Self.expandedWidth : Self.railWidth)
        } detail: {
            NavigationStack {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // The minimum has to stay under half a Mac screen, or the window can't actually
        // tile to half: macOS clamps the tile up to the minimum instead (at 840 on a
        // 1470pt screen it came out 840 against a 735pt half, i.e. 1.14x half, which reads
        // as "a bit more than half").
        .frame(minWidth: 700, minHeight: 520)
        .tint(Brand.accent)
        .environment(\.fontScale, model.fontScale)
    }

    private var sidebar: some View {
        List(selection: $model.tab) {
            item(.history, "History", "clock.arrow.circlepath")
            item(.importFiles, "Import a file", "square.and.arrow.down")
            item(.recentlyDeleted, "Recently Deleted", "trash",
                 count: model.deletedRecordings.count)
            item(.settings, "Settings", "gearshape")
        }
        .listStyle(.sidebar)
    }

    /// One section row: just the icon while collapsed to the rail, icon + label (and the
    /// Recently Deleted count) once expanded. The rail keeps the name in a tooltip, since
    /// there's no room to print it.
    @ViewBuilder
    private func item(_ tab: AppModel.Tab, _ title: String,
                      _ symbol: String, count: Int = 0) -> some View {
        if model.sidebarExpanded {
            Label {
                HStack(spacing: 0) {
                    // Priority so the label keeps its full width (even bold, when selected)
                    // and never truncates to "Recently Delet…" to make room for the count.
                    Text(title).layoutPriority(1)
                    if count > 0 {
                        Spacer(minLength: 8)
                        // `.secondary` derives from the row's foreground, so it stays muted
                        // when unselected and legible (light) on the selected blue row.
                        Text(count, format: .number)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: symbol)
            }
            .tag(tab)
        } else {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, alignment: .center)
                .help(count > 0 ? "\(title) (\(count.formatted()))" : title)
                .accessibilityLabel(title)
                .tag(tab)
        }
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
