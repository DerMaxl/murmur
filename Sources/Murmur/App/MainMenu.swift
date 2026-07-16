import AppKit

/// The app's menu bar. Murmur is normally a menu-bar (accessory) app with no menu bar,
/// but it switches to a regular activation policy while the window is open - and that's
/// when this menu shows. Kept minimal: an app menu, an Edit menu (so text fields get
/// Copy/Paste/Select-All/Undo), and a View menu for ⌘+/⌘-/⌘0 window zoom.
///
/// Using real menu items is the reliable way to handle ⌘-key shortcuts (a stray event
/// monitor can miss them or leak to other apps); the system routes the key equivalents
/// here only while Murmur is active.
@MainActor
enum MainMenu {
    /// Build the menu. App/zoom items are sent to `target` (the app delegate); window
    /// items go to the first responder (the key window).
    static func make(zoomTarget target: AnyObject) -> NSMenu {
        let main = NSMenu()
        for submenu in [appMenu(target: target), editMenu(), viewMenu(target: target), windowMenu()] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }

    private static func appMenu(target: AnyObject) -> NSMenu {
        let m = NSMenu(title: "Murmur")
        m.addItem(withTitle: "About Murmur",
                  action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        let settings = m.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        settings.target = target
        m.addItem(.separator())
        m.addItem(withTitle: "Hide Murmur", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return m
    }

    private static func windowMenu() -> NSMenu {
        // Standard window commands routed to the key window via the responder chain.
        let m = NSMenu(title: "Window")
        m.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        m.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "Edit")
        m.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = m.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(.separator())
        m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return m
    }

    private static func viewMenu(target: AnyObject) -> NSMenu {
        let m = NSMenu(title: "View")
        // ⌘= (no Shift needed) for zoom in, matching common muscle memory.
        let zoomIn = m.addItem(withTitle: "Zoom In", action: #selector(AppDelegate.zoomIn), keyEquivalent: "=")
        let zoomOut = m.addItem(withTitle: "Zoom Out", action: #selector(AppDelegate.zoomOut), keyEquivalent: "-")
        let actual = m.addItem(withTitle: "Actual Size", action: #selector(AppDelegate.zoomActual), keyEquivalent: "0")
        m.addItem(.separator())
        // ⌃⌘S, the standard macOS Show/Hide Sidebar shortcut. The sidebar hides itself on
        // a narrow (half-screen) window to give the transcript room, so this is the way
        // back to the other sections there. The title flips in validateMenuItem.
        let sidebar = m.addItem(withTitle: "Hide Sidebar",
                                action: #selector(AppDelegate.toggleSidebar), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.control, .command]
        for item in [zoomIn, zoomOut, actual, sidebar] { item.target = target }
        return m
    }
}
