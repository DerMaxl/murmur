import AppKit
import Sparkle

/// Thin wrapper over Sparkle's standard updater. Automatic background checks and silent
/// installation are configured in Info.plist (`SUEnableAutomaticChecks` /
/// `SUAutomaticallyUpdate` / `SUFeedURL` / `SUPublicEDKey`); this also exposes a manual
/// "Check for Updates" action and the controller a menu item can target directly.
///
/// As an `SPUUpdaterDelegate` it suppresses the "Install and Relaunch" confirmation: a
/// downloaded update installs and relaunches silently. The one exception is while a
/// dictation or meeting is in progress, when relaunching would cut the recording, so the
/// install is held and applied via `installPendingUpdateIfIdle()` once recording stops.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!

    /// Whether a recording is in progress (wired by the app delegate). When true we hold
    /// the update instead of relaunching out from under an active dictation/meeting.
    var isRecording: (@MainActor () -> Bool)?

    /// A downloaded update's immediate-install action, stashed while recording.
    private var pendingInstall: (() -> Void)?

    override init() {
        super.init()
        // startingUpdater: true kicks off the scheduled background checks immediately.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: nil)
    }

    /// Build a menu item wired to Sparkle's manual check (with its own validation).
    func makeMenuItem(title: String = "Check for Updates…") -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                              keyEquivalent: "")
        item.target = controller
        return item
    }

    /// Whether downloaded updates install automatically (our delegate then applies them
    /// silently when idle). Backed by Sparkle's own persisted preference; its initial
    /// value comes from `SUAutomaticallyUpdate` in Info.plist (on by default).
    var automaticUpdatesEnabled: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            // Keep the daily check on regardless, so turning auto-install off still
            // surfaces an available update (Sparkle then prompts to install it).
            controller.updater.automaticallyChecksForUpdates = true
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// A user-initiated update check with the standard Sparkle UI (including the
    /// "You're up to date" confirmation when there's nothing new).
    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// Install a held update now if one is waiting and no recording is in progress.
    /// Called on app-state changes (e.g. a meeting/dictation just finished).
    func installPendingUpdateIfIdle() {
        guard isRecording?() != true, let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }

    // MARK: SPUUpdaterDelegate

    /// Sparkle has a downloaded update ready to install on quit. Returning true and
    /// calling the handler installs + relaunches immediately with no confirmation: we do
    /// that right away when idle, or stash it until the current recording finishes.
    nonisolated func updater(_ updater: SPUUpdater,
                             willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        // Sparkle calls this on the main thread and we only ever touch the handler on the
        // main actor, so adopting it across the isolation hop is safe.
        nonisolated(unsafe) let handler = immediateInstallHandler
        MainActor.assumeIsolated {
            if self.isRecording?() == true {
                self.pendingInstall = handler
            } else {
                handler()
            }
        }
        return true
    }
}
