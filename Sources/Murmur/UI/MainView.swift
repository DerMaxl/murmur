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

    /// Under this window width the sidebar stays a rail whatever the preference says:
    /// labels (232) plus the recordings list (340) only leave the transcript a readable
    /// ~420pt from about here up.
    private static let labelsBreakpoint: CGFloat = 1000

    /// Corner radius and gap of the floating panels.
    private static let panelRadius: CGFloat = 10
    private static let panelGap: CGFloat = 8

    var body: some View {
        // Two rounded panels floating on the window's background, rather than columns
        // butted together. A NavigationSplitView can't do this: it draws its columns
        // adjacent with a divider between them and paints their materials itself, so
        // there is nowhere for a gap to go. It also isn't buying anything here any more,
        // the rail is a fixed width (so, as with the original hand-rolled layout, there's
        // no divider to drag off screen) and the label toggle is our own state rather than
        // its column collapsing. The gap between the panels replaces the divider outright.
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
        HStack(spacing: Self.panelGap) {
            panel {
                sidebar
                    .frame(width: model.sidebarShowsLabels
                           ? Self.expandedWidth : Self.railWidth)
            }
            panel {
                NavigationStack {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(Self.panelGap)
        // The page the panels sit on. Deliberately darker than the panels themselves, so
        // they read as floating rather than as regions of one flat surface. The window's
        // background is set to match (MainWindowController), so the title-bar strip above
        // is the same colour and the whole thing looks like one page.
        .background(Color(nsColor: .underPageBackgroundColor))
        // Track whether there's room for labels. Resizing down to half the screen has to
        // drop the sidebar back to the rail on its own, or the labels keep their 232pt and
        // it comes out of the transcript, which just slides out of view.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let narrow = width < Self.labelsBreakpoint
            if model.sidebarIsNarrow != narrow { model.sidebarIsNarrow = narrow }
        }
        // The minimum has to stay under half a Mac screen, or the window can't actually
        // tile to half: macOS clamps the tile up to the minimum instead (at 840 on a
        // 1470pt screen it came out 840 against a 735pt half, i.e. 1.14x half, which reads
        // as "a bit more than half").
        .frame(minWidth: 700, minHeight: 520)
        .tint(Brand.accent)
        .environment(\.fontScale, model.fontScale)
    }

    /// Wraps content as one of the window's floating panels: its own surface, rounded,
    /// and clipped so a List inside can't square the corners back off.
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous))
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
        // Drop the list's own backdrop so the panel's surface shows through instead.
        .scrollContentBackground(.hidden)
    }

    /// One section row: just the icon while collapsed to the rail, icon + label (and the
    /// Recently Deleted count) once expanded. The rail keeps the name in a tooltip, since
    /// there's no room to print it.
    @ViewBuilder
    private func item(_ tab: AppModel.Tab, _ title: String,
                      _ symbol: String, count: Int = 0) -> some View {
        if model.sidebarShowsLabels {
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
