import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// A configurable global hotkey driven by a `Shortcut`. Reports press/release so it
/// can drive both push-to-talk (hold) and toggle (tap) behaviours:
///
/// - **Chord** shortcut (modifiers + key): registered as a Carbon hotkey
///   (`RegisterEventHotKey`). The system matches and consumes it with **zero
///   per-keystroke cost** in this process (an active CGEvent tap would round-trip
///   every keystroke system-wide through Murmur all day) and it needs no
///   Accessibility permission. Press fires `onPress`, the key-up `onRelease`.
/// - **Bare-modifier** shortcut (e.g. Fn): a `listenOnly` CGEvent tap on
///   `flagsChanged` - Carbon can't observe a held modifier. We never consume it (the
///   modifier may be used elsewhere); `onPress` fires when the exact modifier set
///   becomes held, `onRelease` when it's let go. This path needs Accessibility.
@MainActor
final class GlobalHotkey {
    private nonisolated let shortcut: Shortcut

    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?
    /// Bare-modifier triggers only: fired when another key is pressed while the modifier
    /// is held, i.e. the modifier is being used in a key combo (e.g. Fn+Delete) rather
    /// than as a push-to-talk hold. The key is never consumed, so the combo still works.
    var onComboKey: (@MainActor () -> Void)?

    /// Whether arming this hotkey requires the Accessibility permission. Chords go
    /// through Carbon and need nothing; only the bare-modifier tap needs the grant.
    var needsAccessibility: Bool { shortcut.keyCode == nil }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyID: UInt32 = 0
    private var isDown = false

    var isRunning: Bool { eventTap != nil || hotKeyRef != nil }

    init(shortcut: Shortcut) { self.shortcut = shortcut }

    func start() -> Bool {
        guard !isRunning else { return true }
        if shortcut.keyCode != nil { return startCarbon() }
        return startTap()
    }

    func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
            Self.registered.removeValue(forKey: hotKeyID)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)   // fully tear down the tap, not just disable it
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isDown = false
    }

    // MARK: Chords (Carbon)

    /// Registered hotkeys by id, so the shared Carbon handler can route an event
    /// back to its instance.
    private static var registered: [UInt32: GlobalHotkey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    /// 'MURM' - tags our hotkeys in the EventHotKeyID.
    private static let signature: OSType = 0x4D55_524D

    private func startCarbon() -> Bool {
        guard let keyCode = shortcut.keyCode else { return false }
        Self.installCarbonHandlerIfNeeded()
        let id = Self.nextID
        Self.nextID &+= 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode),
                                         Self.carbonModifiers(shortcut.flags),
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.error("Failed to register hotkey \(shortcut.display) (status \(status))")
            return false
        }
        hotKeyRef = ref
        hotKeyID = id
        Self.registered[id] = self
        Log.info("Hotkey armed (\(shortcut.display))")
        return true
    }

    /// Carbon has no Fn modifier bit; chords already ignore Fn (F-keys and arrows set
    /// it spuriously), so the mapping covers everything a chord can use.
    private nonisolated static func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.maskCommand) { mods |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { mods |= UInt32(optionKey) }
        if flags.contains(.maskControl) { mods |= UInt32(controlKey) }
        if flags.contains(.maskShift) { mods |= UInt32(shiftKey) }
        return mods
    }

    /// One process-wide handler for all our hotkeys; runs on the main event loop.
    private static func installCarbonHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            guard let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let kind = GetEventKind(event)
            // The dispatcher target delivers on the main thread.
            MainActor.assumeIsolated {
                guard id.signature == GlobalHotkey.signature,
                      let hotkey = GlobalHotkey.registered[id.id] else { return }
                if kind == UInt32(kEventHotKeyPressed) {
                    if !hotkey.isDown { hotkey.isDown = true; hotkey.onPress?() }
                } else if kind == UInt32(kEventHotKeyReleased) {
                    if hotkey.isDown { hotkey.isDown = false; hotkey.onRelease?() }
                }
            }
            return noErr
        }, 2, &types, nil, nil)
        handlerInstalled = true
    }

    // MARK: Bare modifiers (event tap)

    private func startTap() -> Bool {
        // Watch flagsChanged for the hold, and keyDown so we can tell when the
        // modifier is being used in a combo (e.g. Fn+Delete) and cancel.
        let mask: CGEventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let hk = Unmanaged<GlobalHotkey>.fromOpaque(refcon).takeUnretainedValue()
            hk.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)   // listen-only: never consume
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            // Append at the TAIL so we observe events *after* other taps have run -
            // crucially, after key remappers like Hyperkey rewrite CapsLock→⌘⌥⌃⇧.
            // A head-insert tap would see the raw keystroke before that rewrite, so a
            // Hyper-based shortcut would never match.
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("Failed to create hotkey tap (Accessibility permission?)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        Log.info("Hotkey armed (\(shortcut.display))")
        return true
    }

    /// Runs on the main run loop (where the tap was added), so we're on the main actor.
    private nonisolated func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated {
                // The tap was disabled (slow callback or system load) and any release
                // that happened meanwhile was dropped. Clear our held-state AND, if we
                // were mid-hold, synthesize the release so the consumer (push-to-talk
                // dictation) ends instead of getting stuck "down" with the HUD up.
                let wasDown = isDown
                isDown = false
                if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                if wasDown { onRelease?() }
            }
            return
        }

        if type == .keyDown {
            // A key pressed while the bare modifier is held: it's being used as a
            // modifier (e.g. Fn+Delete), not a push-to-talk hold. It isn't consumed
            // (the combo must still work); just notify so dictation can cancel.
            MainActor.assumeIsolated { if isDown { onComboKey?() } }
            return
        }
        guard type == .flagsChanged else { return }
        let down = bareModifierHeld(event.flags)
        MainActor.assumeIsolated {
            if down, !isDown { isDown = true; onPress?() }
            else if !down, isDown { isDown = false; onRelease?() }
        }
    }

    /// A bare-modifier trigger (e.g. hold Fn) counts as held when its required
    /// modifier(s) are *all* present, allowing extra modifiers on top. Using a subset
    /// test (not exact equality) means pressing another modifier mid-hold doesn't flip
    /// the trigger off and back on, and lets it start even if a modifier was already held.
    private nonisolated func bareModifierHeld(_ flags: CGEventFlags) -> Bool {
        let required = shortcut.flags.intersection(Shortcut.relevantMask)
        guard !required.isEmpty else { return false }
        return flags.intersection(required) == required
    }
}
