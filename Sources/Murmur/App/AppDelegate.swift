import AppKit

/// App lifecycle and status-item UI: the menu-bar item and its menu, the main
/// window, the recording HUD, and the menu-bar/Dock visibility modes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = AppCoordinator()
    private lazy var model = AppModel(coordinator: coordinator)
    private lazy var windowController = MainWindowController(model: model)
    private var statusItem: NSStatusItem!
    private let hud = RecordingHUD()
    private let updater = AppUpdater()
    private enum HUDState { case hidden, starting, recording, processing }
    private var hudState: HUDState = .hidden
    /// Whether the status menu is currently open; we only rebuild its recording rows
    /// while it's visible (state changes fire often during transcription).
    private var menuIsOpen = false

    private lazy var meetingItem = NSMenuItem(title: "Record meeting",
                                              action: #selector(toggleMeeting),
                                              keyEquivalent: "")
    private lazy var dictationItem = NSMenuItem(title: "Push-to-talk dictation",
                                                action: #selector(toggleDictation),
                                                keyEquivalent: "")
    private lazy var modeItem = NSMenuItem(title: "Dictation mode",
                                           action: nil, keyEquivalent: "")
    private lazy var fillerItem = NSMenuItem(title: "Remove filler words (uh, um)",
                                             action: #selector(toggleFiller),
                                             keyEquivalent: "")
    private lazy var speakerItem = NSMenuItem(title: "Label speakers in meetings & imports",
                                              action: #selector(toggleSpeakers),
                                              keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the app icon explicitly so the Dock / Mission Control / app switcher show
        // it when the window is open (a SwiftPM bundle doesn't always pick it up from
        // Info.plist alone).
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        AudioDucker.restoreAfterCrashIfNeeded()   // unmute if a crash left us ducked
        Settings.migrateDefaultsIfNeeded()   // move old meeting defaults (Hyper+R, ⌘E) → ⌘⌥E
        Settings.applyFirstRunDefaultsIfNeeded()   // enable Launch at Login once, on first run
        NSApp.mainMenu = MainMenu.make(zoomTarget: self)   // shown while the window is open
        setupMenuBar()
        coordinator.onStateChange = { [weak self] in
            self?.refreshUI()
            self?.model.sync()
            self?.updater.installPendingUpdateIfIdle()   // apply a held update once idle
        }
        coordinator.onAudioLevel = { [weak self] level in self?.hud.push(level: level) }
        coordinator.onNotice = { [weak self] message in self?.hud.showNotice(message) }
        coordinator.onDictationPreview = { [weak self] text in self?.hud.push(preview: text) }
        // Let the updater defer installing while a recording is in progress. This must
        // also cover a dictation that is *finishing* (recorded, still transcribing -
        // releasing the key fires onStateChange with isDictating already false, which
        // is exactly when a held update would otherwise install and relaunch, killing
        // the in-flight transcription) and a meeting that is starting or tearing down.
        updater.isRecording = { [weak self] in
            guard let self else { return false }
            return self.coordinator.isDictating
                || self.coordinator.isFinishingDictation
                || self.coordinator.isMeetingActive
        }
        // Wire the Settings "Software updates" controls to the Sparkle updater. Set the
        // initial toggle value before assigning applyAutoUpdate, so seeding it doesn't
        // write straight back to Sparkle.
        model.checkForUpdatesAction = { [weak self] in self?.updater.checkForUpdates() }
        model.autoUpdate = updater.automaticUpdatesEnabled
        model.applyAutoUpdate = { [weak self] on in self?.updater.automaticUpdatesEnabled = on }
        // After the menu and callbacks exist, so recovery/retry also refresh the UI.
        coordinator.recoverOrphansAtLaunch()
        coordinator.restoreDictation()   // re-arm if it was on last session
        coordinator.armMeetingHotkey()   // meeting hotkey, if Accessibility is granted
        applyVisibility()
        refreshUI()
    }

    /// Show the window again when the Dock icon is clicked with no window open (the
    /// only way back in when running Dock-only).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController.show() }
        return true
    }

    /// Apply the menu-bar / Dock visibility preference. The window controller owns the
    /// policy during open/close transitions; this covers launch and live setting changes.
    /// Called from `refreshUI` (which fires often during transcription), so each property
    /// is only set when it actually changes.
    private func applyVisibility() {
        let visibility = Settings.appVisibility
        if statusItem?.isVisible != visibility.showsMenuBar {
            statusItem?.isVisible = visibility.showsMenuBar
        }
        // Menu-bar only keeps the Dock icon just while a window is open.
        let policy: NSApplication.ActivationPolicy =
            visibility.keepsDockIcon || windowController.isWindowVisible ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    /// Files opened with Murmur (drag onto the app, "Open With", or `open -a`) are
    /// imported and transcribed, same as dropping them on the Import view.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { coordinator.importFile(url) }
    }

    /// Refresh everything that reflects state: icons, titles, and the recordings list
    /// (so a finished transcript updates the menu live, whether or not it's open).
    private func refreshUI() {
        meetingItem.title = coordinator.isMeetingRecording
            ? "Stop meeting"
            : "Record meeting  (\(coordinator.meetingShortcut.display))"
        dictationItem.title = coordinator.dictationEnabled
            ? "Push-to-talk dictation  (hold \(coordinator.dictationTrigger))"
            : "Enable push-to-talk dictation"
        dictationItem.state = coordinator.dictationEnabled ? .on : .off
        fillerItem.state = coordinator.fillerRemovalEnabled ? .on : .off
        speakerItem.state = coordinator.speakerLabelsEnabled ? .on : .off
        for item in modeItem.submenu?.items ?? [] {
            item.state = (item.representedObject as? String) == coordinator.dictationMode.rawValue ? .on : .off
        }
        updateStatusIcon()
        updateHUD()
        applyVisibility()   // reflect a live change to the menu-bar/Dock preference
        // Only rebuild the recording rows while the menu is actually open - onStateChange
        // fires many times a second during transcription.
        if menuIsOpen, let menu = statusItem?.menu {
            rebuildRecentItems(in: menu)
        }
    }

    /// Show the meter HUD while recording or dictating; hide it otherwise. Only acts
    /// on transitions so the elapsed timer isn't reset by unrelated UI refreshes.
    private func updateHUD() {
        let recording = coordinator.isDictating || coordinator.isMeetingRecording
        // A meeting's audio capture takes a few seconds to spin up; show feedback at once.
        let starting = coordinator.isMeetingStarting && !recording
        // After a dictation, keep the HUD up while the transcript is being produced.
        let processing = coordinator.isFinishingDictation && !recording
        let desired: HUDState = recording ? .recording
            : starting ? .starting
            : processing ? .processing
            : .hidden
        if desired != hudState {
            hudState = desired
            switch desired {
            case .starting:   hud.showProcessing("Starting")
            case .recording:  hud.show()
            case .processing: hud.showProcessing(processingMessage)
            case .hidden:     hud.hide()
            }
        } else if desired == .processing {
            // Stay in processing but keep the message current, so a download
            // percentage (or the flip to "Transcribing" once ready) shows live.
            hud.updateProcessing(processingMessage)
        }
    }

    /// The HUD's processing-state text: a model download/load status while the engine
    /// isn't ready, otherwise "Transcribing".
    private var processingMessage: String {
        coordinator.modelPreparingMessage ?? "Transcribing"
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self   // repopulate the recordings list each time it opens

        let historyItem = NSMenuItem(title: "Open Murmur…",
                                     action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        meetingItem.target = self
        menu.addItem(meetingItem)

        dictationItem.target = self
        menu.addItem(dictationItem)

        let modeMenu = NSMenu()
        for mode in DictationMode.allCases {
            let item = NSMenuItem(title: mode.displayName,
                                  action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        fillerItem.target = self
        menu.addItem(fillerItem)
        speakerItem.target = self
        menu.addItem(speakerItem)
        menu.addItem(.separator())

        recentHeader.isEnabled = false
        menu.addItem(recentHeader)
        // Recording rows (and a Finder link) get inserted between the header and
        // this anchor.
        menu.addItem(recentAnchor)

        menu.addItem(updater.makeMenuItem())
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Murmur",
                                  action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // Markers that bound the dynamically-rebuilt list of recent recordings.
    private let recentHeader = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
    private let recentAnchor = NSMenuItem.separator()

    /// Rebuild the recording rows shown between the "Recent" header and the anchor.
    private func rebuildRecentItems(in menu: NSMenu) {
        let headerIdx = menu.index(of: recentHeader)
        let anchorIdx = menu.index(of: recentAnchor)
        guard headerIdx >= 0, anchorIdx > headerIdx else { return }

        // Remove old rows.
        for i in stride(from: anchorIdx - 1, to: headerIdx, by: -1) {
            menu.removeItem(at: i)
        }

        let all = coordinator.store.recordings
        if all.isEmpty {
            let empty = NSMenuItem(title: "  No recordings yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.insertItem(empty, at: headerIdx + 1)
            return
        }

        let shown = 4
        let recent = all.suffix(shown).reversed()
        var offset = 0
        for rec in recent {
            let item = NSMenuItem(title: "  \(statusGlyph(rec))  \(rec.displayName)",
                                  action: nil, keyEquivalent: "")
            item.submenu = rowSubmenu(for: rec)
            menu.insertItem(item, at: headerIdx + 1 + offset)
            offset += 1
        }
        // Single Finder entry: reaches everything when there are more than we show,
        // and is the way to open the folder when there are few.
        let folderTitle = all.count > shown ? "  Show all \(all.count) in Finder…" : "  Open in Finder…"
        let folder = NSMenuItem(title: folderTitle, action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.insertItem(folder, at: headerIdx + 1 + offset)
    }

    private func statusGlyph(_ rec: Recording) -> String {
        switch rec.transcription {
        case .none:    return rec.status == .recovered ? "✓ (recovered)" : "•"
        case .running: return "⏳"
        case .done:    return "✓"
        case .failed:  return "⚠︎"
        }
    }

    private func rowSubmenu(for rec: Recording) -> NSMenu {
        let sub = NSMenu()
        if rec.transcription == .done, let t = rec.transcript, !t.isEmpty {
            let previewText = rec.summary ?? String(t.prefix(60))
            let preview = NSMenuItem(title: previewText, action: nil, keyEquivalent: "")
            preview.isEnabled = false
            sub.addItem(preview)
            sub.addItem(.separator())
            sub.addItem(action("Copy transcript", #selector(copyTranscriptItem), rec.id))
            // Re-transcribe a finished recording (e.g. after switching the speech
            // model), as long as its audio is still on disk.
            if rec.hasTranscribableAudio {
                sub.addItem(action("Re-transcribe", #selector(transcribeItem), rec.id))
            }
        } else if rec.transcription == .running {
            let running = NSMenuItem(title: "Transcribing…", action: nil, keyEquivalent: "")
            running.isEnabled = false
            sub.addItem(running)
        } else {
            sub.addItem(action("Transcribe", #selector(transcribeItem), rec.id))
        }
        sub.addItem(.separator())
        sub.addItem(action("Reveal in Finder", #selector(revealItem), rec.id))
        sub.addItem(action("Delete", #selector(deleteItem), rec.id))
        return sub
    }

    private func action(_ title: String, _ selector: Selector, _ id: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    /// The Murmur wave-M as a menu-bar template glyph (tints white/black to match the
    /// menu bar). Falls back to a mic SF Symbol if the bundled image is missing.
    private lazy var menuBarIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            let height: CGFloat = 15
            img.size = NSSize(width: height * (img.size.width / img.size.height), height: height)
            img.isTemplate = true
            return img
        }
        let fallback = NSImage(systemSymbolName: "mic", accessibilityDescription: "Murmur")!
        fallback.isTemplate = true
        return fallback
    }()

    private func updateStatusIcon() {
        // Same wave-M glyph in every state; tint red while recording / dictating.
        // Assign only on change: this runs on every state change (per transcribed
        // segment during a transcription), and reassigning forces a redraw.
        let active = coordinator.isDictating || coordinator.isMeetingRecording
        let tint: NSColor? = active ? .systemRed : nil
        if statusItem.button?.image !== menuBarIcon { statusItem.button?.image = menuBarIcon }
        if statusItem.button?.contentTintColor != tint { statusItem.button?.contentTintColor = tint }
    }

    @objc private func toggleMeeting() {
        coordinator.toggleMeeting()
    }

    @objc private func toggleDictation() {
        coordinator.toggleDictation()
        // Enabling dictation grants Accessibility, which the meeting chord also needs.
        coordinator.armMeetingHotkey()
    }

    @objc private func toggleFiller() {
        coordinator.toggleFillerRemoval()
    }

    @objc private func toggleSpeakers() {
        coordinator.toggleSpeakerLabels()
    }

    @objc private func selectMode(_ sender: Any?) {
        if let raw = (sender as? NSMenuItem)?.representedObject as? String,
           let mode = DictationMode(rawValue: raw) {
            coordinator.setDictationMode(mode)
        }
    }

    @objc private func openHistory() { windowController.show(tab: .history) }
    // Internal so the app menu's ⌘, item can target it.
    @objc func openSettings() { windowController.show(tab: .settings) }

    // Window zoom (View menu ⌘+/⌘-/⌘0). Internal so the menu's selectors can reach them.
    @objc func zoomIn() { model.zoomIn() }
    @objc func zoomOut() { model.zoomOut() }
    @objc func zoomActual() { model.resetZoom() }

    @objc private func openFolder() {
        coordinator.openRecordingsFolder()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Runs on every quit path (status-menu Quit, the main menu's ⌘Q, log-out, …).
    /// Stop an in-progress meeting so the journal records a clean finish instead of
    /// an orphan to crash-recover (its transcription re-runs on the next launch), and
    /// clean up an in-progress dictation so the system volume isn't left muted.
    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stopMeetingAtTerminate()
        coordinator.stopDictationAtTerminate()
    }

    // MARK: Per-recording actions (id carried in representedObject)

    private func id(from sender: Any?) -> UUID? {
        (sender as? NSMenuItem)?.representedObject as? UUID
    }

    @objc private func copyTranscriptItem(_ sender: Any?) {
        if let id = id(from: sender) { coordinator.copyTranscript(id) }
    }

    @objc private func transcribeItem(_ sender: Any?) {
        if let id = id(from: sender) { coordinator.transcribe(id) }
    }

    @objc private func revealItem(_ sender: Any?) {
        if let id = id(from: sender) { coordinator.revealInFinder(id) }
    }

    @objc private func deleteItem(_ sender: Any?) {
        guard let id = id(from: sender) else { return }
        // Soft delete → Recently Deleted (restorable). onStateChange refreshes UI.
        coordinator.softDelete(id)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refreshUI()
        // Self-heal: if Accessibility was granted *after* launch, the meeting chord
        // never armed. Re-arm here (idempotent) so it starts working without a relaunch.
        coordinator.armMeetingHotkey()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }
}
