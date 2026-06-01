import SwiftUI

/// The window's root: a sidebar that switches between History and Settings. Kept
/// deliberately small - the app is driven mostly by the global hotkey; this window
/// is for browsing past recordings and changing settings without hunting through the
/// menu bar.
struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        // Keep the sidebar permanently expanded. We don't bind `columnVisibility` (which
        // let the divider collapse it, then snapped back jitterily); instead the sidebar
        // has a fixed min/max width so dragging the divider just stops at the bounds.
        NavigationSplitView {
            List(selection: $model.tab) {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(AppModel.Tab.history)
                Label("Import a file", systemImage: "square.and.arrow.down")
                    .tag(AppModel.Tab.importFiles)
                Label {
                    Text("Recently Deleted")
                } icon: {
                    Image(systemName: "trash")
                }
                .badge(model.deletedRecordings.count)
                .tag(AppModel.Tab.recentlyDeleted)
                Label("Settings", systemImage: "gearshape")
                    .tag(AppModel.Tab.settings)
            }
            // A real minimum width so the divider clamps instead of collapsing the
            // sidebar to nothing.
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch model.tab {
            case .history:         HistoryView(model: model)
            case .importFiles:     ImportView(model: model)
            case .recentlyDeleted: RecentlyDeletedView(model: model)
            case .settings:        SettingsView(model: model)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 840, minHeight: 520)
        .navigationTitle("Murmur")
        .tint(Brand.accent)
        .environment(\.fontScale, model.fontScale)
    }
}
