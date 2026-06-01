import AppKit

// Menu-bar app: no dock icon, no main window (LSUIElement in Info.plist).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
