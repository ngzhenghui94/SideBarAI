import AppKit
import SwiftUI
import Foundation
import Observation

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: UsageStore
    private let panelController: EdgePanelController
    private let settingsWindowController: SettingsWindowController
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let visibilityItem: NSMenuItem
    private let expansionItem: NSMenuItem
    private let attachItem: NSMenuItem
    private let attachmentMenu: NSMenu
    private var attachmentItems: [NSMenuItem]
    private let usageSummaryItem: NSMenuItem
    private let lastCheckedItem: NSMenuItem
    private var accountItems: [NSMenuItem]
    private let refreshItem: NSMenuItem

    init(
        panelController: EdgePanelController,
        store: UsageStore,
        settingsWindowController: SettingsWindowController
    ) {
        self.store = store
        self.panelController = panelController
        self.settingsWindowController = settingsWindowController
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.menu = NSMenu()
        self.visibilityItem = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
        self.expansionItem = NSMenuItem(title: "Expand", action: nil, keyEquivalent: "")
        self.attachItem = NSMenuItem(title: "Attach to Edge", action: nil, keyEquivalent: "")
        self.attachmentMenu = NSMenu()
        self.attachmentItems = []
        self.usageSummaryItem = NSMenuItem(title: "Usage overview", action: nil, keyEquivalent: "")
        self.lastCheckedItem = NSMenuItem(title: "Last checked —", action: nil, keyEquivalent: "")
        self.accountItems = []
        self.refreshItem = NSMenuItem(
            title: "Refresh Usage",
            action: #selector(refreshUsage(_:)),
            keyEquivalent: "r"
        )

        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        attachmentMenu.autoenablesItems = false

        usageSummaryItem.isEnabled = false
        lastCheckedItem.isEnabled = false

        for edge in SidebarEdge.allCases {
            let item = NSMenuItem(
                title: edge.displayName,
                action: #selector(attachToEdge(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = edge.rawValue
            attachmentMenu.addItem(item)
            attachmentItems.append(item)
        }
        attachItem.submenu = attachmentMenu

        visibilityItem.action = #selector(toggleVisibility(_:))
        visibilityItem.target = self
        expansionItem.action = #selector(toggleExpanded(_:))
        expansionItem.target = self
        refreshItem.target = self

        let settingsItem = NSMenuItem(
            title: "Open Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(visibilityItem)
        menu.addItem(expansionItem)
        menu.addItem(attachItem)
        menu.addItem(.separator())
        menu.addItem(usageSummaryItem)
        menu.addItem(lastCheckedItem)
        menu.addItem(.separator())
        menu.addItem(refreshItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "chart.bar.fill",
                accessibilityDescription: "SideBarAI"
            )
            button.imagePosition = .imageOnly
            button.toolTip = "SideBarAI"
        }

        updateMenuTitles()
        observeStoreChanges()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuTitles()
    }

    @objc
    private func toggleVisibility(_ sender: Any?) {
        panelController.toggleVisibility()
        updateMenuTitles()
    }

    @objc
    private func toggleExpanded(_ sender: Any?) {
        panelController.toggleExpanded()
        updateMenuTitles()
    }

    @objc
    private func attachToEdge(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let rawValue = item.representedObject as? String,
              let edge = SidebarEdge(rawValue: rawValue) else {
            return
        }
        panelController.attachToEdge(edge)
        updateMenuTitles()
    }

    @objc
    private func refreshUsage(_ sender: Any?) {
        store.refresh()
        updateMenuTitles()
    }

    @objc
    private func openSettings(_ sender: Any?) {
        settingsWindowController.show()
    }

    @objc
    private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    private func updateMenuTitles() {
        visibilityItem.title = panelController.isVisible ? "Hide" : "Show"
        expansionItem.title = panelController.isExpanded ? "Collapse" : "Expand"
        let edge = store.sidebarEdge
        attachItem.title = "Attach to " + edge.displayName
        attachItem.isEnabled = true
        for (item, availableEdge) in zip(attachmentItems, SidebarEdge.allCases) {
            item.state = edge == availableEdge ? .on : .off
        }
        usageSummaryItem.title = usageSummaryTitle
        lastCheckedItem.title = lastCheckedTitle
        refreshItem.title = store.isRefreshing ? "Checking Usage…" : "Refresh Usage"
        refreshItem.isEnabled = !store.isRefreshing
        updateStatusItem()
        rebuildAccountItems()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let records = store.presentationRecords
        let values = records.map { record in
            QuotaSummary.highestPercentage(in: [record]).map { "\($0)%" } ?? "—"
        }
        // Keep a standard icon-sized footprint regardless of the account count.
        button.title = ""
        button.imagePosition = .imageOnly
        let details = zip(records, values).map { record, value in
            "\(record.displayAccountLabel ?? record.provider.displayName): \(value) highest quota usage"
        }.joined(separator: "\n")
        button.toolTip = details.isEmpty ? "SideBarAI · Quota usage unavailable" : "SideBarAI\n" + details
        button.setAccessibilityLabel(button.toolTip)
    }

    private func observeStoreChanges() {
        let store = store
        withObservationTracking {
            _ = store.records
            _ = store.presentationRecords
            _ = store.hiddenProviders
            _ = store.sidebarEdge
            _ = store.isRefreshing
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateMenuTitles()
                self.observeStoreChanges()
            }
        }
    }

    private var menuRecords: [ProviderRecord] {
        store.presentationRecords
    }

    private func rebuildAccountItems() {
        for item in accountItems {
            menu.removeItem(item)
        }
        accountItems.removeAll(keepingCapacity: true)

        var insertionIndex = menu.index(of: lastCheckedItem)
        for record in menuRecords {
            let item = NSMenuItem(title: accountMenuTitle(for: record), action: nil, keyEquivalent: "")
            item.isEnabled = false
            if case let .usage(snapshot) = record.state, snapshot.hasModelUsage {
                item.toolTip = snapshot.modelUsageDetail
            } else {
                item.toolTip = record.state.errorMessage
            }
            menu.insertItem(item, at: insertionIndex)
            accountItems.append(item)
            insertionIndex += 1
        }
    }

    private func accountMenuTitle(for record: ProviderRecord) -> String {
        var identity = [record.provider.shortName]
        if let accountLabel = record.displayAccountLabel {
            identity.append(accountLabel)
        }
        if let planLabel = record.planStatusLabel {
            identity.append(planLabel)
        }
        if record.isActive {
            identity.append("Active")
        }
        return "\(identity.joined(separator: " · "))  \(usageDetail(for: record))"
    }

    private var usageSummaryTitle: String {
        let records = menuRecords
        guard !records.isEmpty else { return "No provider sessions found" }

        if store.isRefreshing || records.contains(where: { $0.state.isLoading }) {
            return "Checking \(accountCountDescription(records.count))…"
        }

        let reportingCount = records.count(where: { $0.state.snapshot != nil })
        if reportingCount == records.count {
            return "\(reportingCount) \(reportingCount == 1 ? "account" : "accounts") reporting usage"
        }
        if reportingCount > 0 {
            return "\(reportingCount) of \(records.count) accounts reporting usage"
        }

        let connectedCount = records.count(where: { record in
            if case .authenticated = record.state { return true }
            return false
        })
        if connectedCount > 0 {
            return "\(connectedCount) connected · waiting for usage"
        }
        return "No provider usage available"
    }

    private func accountCountDescription(_ count: Int) -> String {
        "\(count) \(count == 1 ? "account" : "accounts")"
    }

    private var lastCheckedTitle: String {
        guard !store.isRefreshing,
              let date = store.lastRefreshCompleted ?? store.lastRefreshAttempt else {
            return store.isRefreshing ? "Last checked: updating…" : "Last checked: —"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last checked: \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func usageDetail(for record: ProviderRecord) -> String {
        guard store.isProviderEnabled(record.provider) else { return "Disabled" }
        switch record.state {
        case .loading:
            return "Checking…"
        case .authenticated:
            return "Connected"
        case .unavailable:
            return "Needs setup"
        case let .usage(snapshot):
            let modelUsageDetail = snapshot.hasModelUsage ? snapshot.modelUsageDetail : nil
            guard let window = snapshot.windows.first else {
                return modelUsageDetail ?? "No usage data"
            }

            var detail = "\(window.label): \(usageValue(for: window))"
            if let resetDate = window.resetDate {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                detail += " · resets \(formatter.localizedString(for: resetDate, relativeTo: Date()))"
            }
            if let label = snapshot.savedResetLabel {
                detail += " · \(label)"
            }
            if let label = snapshot.subscriptionRenewalLabel() {
                detail += " · \(label)"
            }
            if let modelUsageDetail {
                detail += " · \(modelUsageDetail)"
            }
            return detail
        }
    }

    private func usageValue(for window: UsageWindow) -> String {
        if let percentage = window.percentUsed,
           let formatted = UsageNumberFormatter.roundedIntegerString(percentage) {
            return "\(formatted)% used"
        }

        guard window.used.isFinite else { return "Usage unavailable" }
        switch window.unit {
        case .tokens:
            guard let formatted = UsageNumberFormatter.roundedIntegerString(window.used) else {
                return "Usage unavailable"
            }
            return "\(formatted) tokens"
        case .requests:
            guard let formatted = UsageNumberFormatter.roundedIntegerString(window.used) else {
                return "Usage unavailable"
            }
            return "\(formatted) requests"
        case .currency:
            return String(format: "$%.2f", window.used)
        case .percent:
            return "Usage reported"
        }
    }
}
