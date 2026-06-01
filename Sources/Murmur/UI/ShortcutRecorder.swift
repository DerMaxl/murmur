import SwiftUI
import AppKit

/// A click-to-record shortcut field. Click it, then press a key combination (e.g.
/// ⌃⌥⌘⇧R) or hold a bare modifier (e.g. Fn); the captured `Shortcut` is written back
/// through the binding. Esc cancels recording.
struct ShortcutField: NSViewRepresentable {
    @Binding var shortcut: Shortcut

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.shortcut = shortcut
        v.onCapture = { captured in shortcut = captured }
        return v
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        if !view.isRecording { view.shortcut = shortcut }
    }
}

/// AppKit view that captures the next key chord (or bare-modifier hold) while focused.
final class RecorderView: NSView {
    var shortcut: Shortcut = .fnHold { didSet { needsDisplay = true } }
    var onCapture: ((Shortcut) -> Void)?
    private(set) var isRecording = false { didSet { needsDisplay = true } }
    private var sawModifiers: CGEventFlags = []

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 22) }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                     : NSColor.quaternaryLabelColor.withAlphaComponent(0.5)).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text = isRecording ? "Type a shortcut…" : shortcut.display
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2),
                                withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sawModifiers = []
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    // ⌘-based combos arrive here before menu items; route them to capture too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { isRecording = false; return }   // Esc cancels
        capture(Shortcut(keyCode: Int64(event.keyCode), modifiers: chordModifiers(event.modifierFlags)))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { super.flagsChanged(with: event); return }
        let mods = bareModifiers(event.modifierFlags)
        if mods.isEmpty {
            // Released everything without pressing a key → a bare-modifier hold trigger.
            if !sawModifiers.isEmpty { capture(Shortcut(keyCode: nil, modifiers: sawModifiers)) }
        } else {
            sawModifiers = mods
        }
    }

    private func capture(_ shortcut: Shortcut) {
        guard shortcut.isValid else { isRecording = false; return }
        self.shortcut = shortcut
        isRecording = false
        window?.makeFirstResponder(nil)
        onCapture?(shortcut)
    }

    /// For chords: command/option/control/shift only. Fn is excluded because F-keys
    /// and arrows set it spuriously.
    private func chordModifiers(_ f: NSEvent.ModifierFlags) -> CGEventFlags {
        var m: CGEventFlags = []
        if f.contains(.command) { m.insert(.maskCommand) }
        if f.contains(.option) { m.insert(.maskAlternate) }
        if f.contains(.control) { m.insert(.maskControl) }
        if f.contains(.shift) { m.insert(.maskShift) }
        return m
    }

    /// For bare-modifier triggers: includes Fn.
    private func bareModifiers(_ f: NSEvent.ModifierFlags) -> CGEventFlags {
        var m = chordModifiers(f)
        if f.contains(.function) { m.insert(.maskSecondaryFn) }
        return m
    }
}
