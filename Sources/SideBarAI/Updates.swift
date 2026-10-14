import AppKit
import Sparkle

@MainActor
final class AppUpdates: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    static let shared = AppUpdates()
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        // Override persisted preferences: every network check requires a menu click.
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
        controller.updater.sendsSystemProfile = false
        controller.startUpdater()
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { controller?.updater.canCheckForUpdates == true }
    @objc private func checkForUpdates(_ sender: Any?) { controller?.checkForUpdates(sender) }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    static func requireManualCheck(_ check: SPUUpdateCheck) throws {
        guard check == .updates else {
            throw NSError(domain: "SideBarAI.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Choose Check for Updates… from the menu to check for updates."])
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try Self.requireManualCheck(updateCheck)
    }

    static func selftest() throws {
        try requireManualCheck(.updates)
        for check: SPUUpdateCheck in [.updatesInBackground, .updateInformation] {
            do { try requireManualCheck(check); preconditionFailure("Unsolicited update check accepted") }
            catch { }
        }
        print("updater selftest ok: manual checks accepted; unsolicited checks rejected")
    }
}
