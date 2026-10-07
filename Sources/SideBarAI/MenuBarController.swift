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
        self.usageSummaryItem = NSMenuItem.sectionHeader(title: "Usage overview")
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
            item.image = Self.symbol(edge.menuSymbolName)
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
        refreshItem.image = Self.symbol("arrow.clockwise")

        let settingsItem = NSMenuItem(
            title: "Open Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = Self.symbol("gearshape")

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = Self.symbol("power")

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
            button.image = Self.statusGlyph
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
        visibilityItem.image = Self.symbol(panelController.isVisible ? "eye.slash" : "eye")
        expansionItem.title = panelController.isExpanded ? "Collapse" : "Expand"
        expansionItem.image = Self.symbol(
            panelController.isExpanded
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right"
        )
        let edge = store.sidebarEdge
        attachItem.title = "Attach to " + edge.displayName
        attachItem.image = Self.symbol(edge.menuSymbolName)
        attachItem.isEnabled = true
        for (item, availableEdge) in zip(attachmentItems, SidebarEdge.allCases) {
            item.state = edge == availableEdge ? .on : .off
        }
        usageSummaryItem.title = usageSummaryTitle
        lastCheckedItem.attributedTitle = NSAttributedString(
            string: lastCheckedTitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
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
            item.attributedTitle = accountAttributedTitle(for: record)
            item.image = Self.providerImage(for: record.provider)
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
        "\(accountIdentity(for: record).joined(separator: " · "))  \(usageDetailLines(for: record).joined(separator: " · "))"
    }

    /// Two-tone row: provider name and account on the first line, usage beneath.
    private func accountAttributedTitle(for record: ProviderRecord) -> NSAttributedString {
        let identity = accountIdentity(for: record)
        let title = NSMutableAttributedString(
            string: identity[0],
            attributes: [
                .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        if identity.count > 1 {
            title.append(NSAttributedString(
                string: "  " + identity.dropFirst().joined(separator: " · "),
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
        }
        for line in usageDetailLines(for: record) {
            title.append(NSAttributedString(
                string: "\n" + line,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
        }
        return title
    }

    private func accountIdentity(for record: ProviderRecord) -> [String] {
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
        return identity
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

    /// Usage summary split into short lines: quota window, plan dates, model costs.
    private func usageDetailLines(for record: ProviderRecord) -> [String] {
        guard store.isProviderEnabled(record.provider) else { return ["Disabled"] }
        switch record.state {
        case .loading:
            return ["Checking…"]
        case .authenticated:
            return ["Connected"]
        case .unavailable:
            return ["Needs setup"]
        case let .usage(snapshot):
            let modelUsageDetail = snapshot.hasModelUsage ? snapshot.modelUsageDetail : nil
            guard let window = snapshot.windows.first else {
                return [modelUsageDetail ?? "No usage data"]
            }

            var quota = "\(window.label): \(usageValue(for: window))"
            if let resetDate = window.resetDate {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                quota += " · resets \(formatter.localizedString(for: resetDate, relativeTo: Date()))"
            }
            let planDates = [snapshot.savedResetLabel, snapshot.subscriptionRenewalLabel()]
                .compactMap { $0 }
                .joined(separator: " · ")
            return [quota, planDates, modelUsageDetail ?? ""].filter { !$0.isEmpty }
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

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Provider brand mark tinted with its accent color for menu rows.
    private static func providerImage(for provider: Provider) -> NSImage? {
        let size = NSSize(width: 16, height: 16)
        let accent = NSColor(provider.accentColor)
        if let mark = ProviderIcon.templateImage(for: provider) {
            return NSImage(size: size, flipped: false) { rect in
                mark.draw(in: rect)
                accent.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [accent]))
        return symbol(provider.systemImage)?.withSymbolConfiguration(configuration)
    }

    /// Template glyph mirroring the app icon: a window with a meter sidebar docked to it.
    private static let statusGlyph: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            NSColor.black.set()

            let window = NSBezierPath(
                roundedRect: NSRect(x: 0.75, y: 2.75, width: 12, height: 10.5),
                xRadius: 2.5,
                yRadius: 2.5
            )
            window.lineWidth = 1.5
            window.stroke()

            let panelRect = NSRect(x: 10, y: 0.5, width: 7.5, height: 15)
            context.compositingOperation = .clear
            NSBezierPath(roundedRect: panelRect.insetBy(dx: -1.25, dy: -0.5), xRadius: 3.5, yRadius: 3.5).fill()
            context.compositingOperation = .sourceOver
            NSBezierPath(roundedRect: panelRect, xRadius: 2.5, yRadius: 2.5).fill()

            context.compositingOperation = .clear
            for (index, width) in [4.5, 3.25, 2.0].enumerated() {
                let meter = NSRect(x: 11.5, y: 11.25 - Double(index) * 3.75, width: width, height: 1.75)
                NSBezierPath(roundedRect: meter, xRadius: 0.875, yRadius: 0.875).fill()
            }
            context.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SideBarAI"
        return image
    }()
}

private extension SidebarEdge {
    var menuSymbolName: String {
        switch self {
        case .left:
            "rectangle.lefthalf.inset.filled"
        case .right:
            "rectangle.righthalf.inset.filled"
        case .top:
            "rectangle.tophalf.inset.filled"
        case .bottom:
            "rectangle.bottomhalf.inset.filled"
        }
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
