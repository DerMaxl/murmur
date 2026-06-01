import AppKit
import CoreGraphics

/// Inserts text at the current cursor in whatever app is focused, by putting the
/// text on the pasteboard and synthesizing Cmd-V. This is the most reliable method
/// for arbitrary-length text across apps. The previous clipboard contents (of every
/// type, not just plain text) are restored shortly after, so dictation doesn't clobber
/// what the user had copied, be it an image, files, or rich text.
///
/// Posting key events to other apps requires Accessibility permission.
@MainActor
final class TextInjector {
    func inject(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postCommandV()

        // Restore the user's clipboard after the paste has been delivered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.restore(saved, to: pasteboard)
        }
    }

    /// Copy every item on the pasteboard (all representations) so we can put it back
    /// exactly. `NSPasteboardItem`s belong to the live pasteboard, so we duplicate the
    /// data into detached items.
    private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        // Nothing was on the clipboard before: leave it empty rather than write junk.
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    private func postCommandV() {
        let vKey: CGKeyCode = 0x09   // kVK_ANSI_V
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
