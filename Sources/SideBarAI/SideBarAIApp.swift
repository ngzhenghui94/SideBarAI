import AppKit
import Foundation

@main
@MainActor
enum SideBarAIApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = SideBarAIAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class SideBarAIAppDelegate: NSObject, NSApplicationDelegate {
    let store: UsageStore
    let settingsWindowController: SettingsWindowController
    let panelController: EdgePanelController
    let menuBarController: MenuBarController

    override init() {
        let store = UsageStore(
            quotaAlertDelivery: DefaultQuotaAlertDelivery.make(),
            launchAtLoginManager: DefaultLaunchAtLoginManager.make()
        )
        let settingsWindowController = SettingsWindowController(store: store)
        let panelController = EdgePanelController(
            store: store,
            onOpenSettings: { settingsWindowController.show() }
        )

        self.store = store
        self.settingsWindowController = settingsWindowController
        self.panelController = panelController
        self.menuBarController = MenuBarController(
            panelController: panelController,
            store: store,
            settingsWindowController: settingsWindowController
        )

        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let startupState = store.startupSidebarState
        panelController.setExpanded(startupState.isExpanded)
        if startupState.isVisible {
            panelController.show()
        } else {
            panelController.hide()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.rememberSidebarState(
            isVisible: panelController.isVisible,
            isExpanded: panelController.isExpanded
        )
        store.shutdown()
        panelController.shutdown()
        panelController.hide()
    }
}
