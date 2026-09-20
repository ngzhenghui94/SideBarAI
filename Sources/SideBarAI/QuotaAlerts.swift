import AppKit
import Foundation
import UserNotifications

struct QuotaAlert: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let threshold: Int
}

@MainActor
protocol QuotaAlertDelivering: AnyObject {
    func requestAuthorization() async -> Bool
    func deliver(_ alert: QuotaAlert) async -> Bool
}

@MainActor
final class UnavailableQuotaAlertDelivery: QuotaAlertDelivering {
    func requestAuthorization() async -> Bool {
        false
    }

    func deliver(_ alert: QuotaAlert) async -> Bool { false }
}

@MainActor
enum DefaultQuotaAlertDelivery {
    static func make() -> any QuotaAlertDelivering {
        guard Bundle.main.bundleIdentifier != nil else {
            return QuotaAlertToastDelivery()
        }
        return UserNotificationQuotaAlertDelivery(
            center: UNUserNotificationCenter.current()
        )
    }
}

@MainActor
final class UserNotificationQuotaAlertDelivery: NSObject, QuotaAlertDelivering, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func deliver(_ alert: QuotaAlert) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: alert.identifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
final class QuotaAlertToastDelivery: QuotaAlertDelivering {
    private let panel: NSPanel
    private let titleLabel: NSTextField
    private let bodyLabel: NSTextField
    private var dismissalTask: Task<Void, Never>?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = NSTextField(wrappingLabelWithString: "")
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 2
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(titleLabel)
        background.addSubview(bodyLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            bodyLabel.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -14)
        ])

        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        self.panel = panel
        self.titleLabel = titleLabel
        self.bodyLabel = bodyLabel
    }

    func requestAuthorization() async -> Bool {
        true
    }

    func deliver(_ alert: QuotaAlert) async -> Bool {
        dismissalTask?.cancel()
        titleLabel.stringValue = alert.title
        bodyLabel.stringValue = alert.body

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visibleFrame = screen.visibleFrame
            let origin = NSPoint(
                x: visibleFrame.maxX - panel.frame.width - 16,
                y: visibleFrame.maxY - panel.frame.height - 16
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()

        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            self?.panel.orderOut(nil)
        }
        return true
    }
}

enum QuotaSummary {
    static func highestPercentage(in records: [ProviderRecord]) -> Int? {
        records
            .compactMap(\.state.snapshot)
            .flatMap(\.windows)
            .compactMap(\.percentUsed)
            .filter(\.isFinite)
            .max()
            .map { Int($0.rounded()) }
    }
}

struct QuotaAlertEvaluator {
    static let thresholds = [75, 90, 100]

    private static let defaultsKey = "SideBarAI.quotaAlertState"
    private static let retentionInterval: TimeInterval = 45 * 24 * 60 * 60
    private static let maximumStoredCycles = 256

    private let defaults: UserDefaults
    private var state: PersistedState
    private var pendingDeliveries: [String: PendingDelivery] = [:]
    private var activeCycleIDs: Set<String> = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            self.state = state
        } else {
            self.state = PersistedState()
        }
    }

    mutating func alerts(
        for records: [ProviderRecord],
        now: Date = Date()
    ) -> [QuotaAlert] {
        let previousState = state
        var alerts: [QuotaAlert] = []
        var activeCycleIDs: Set<String> = []

        for record in records {
            guard case let .usage(snapshot) = record.state else { continue }

            for window in snapshot.windows {
                guard let percentUsed = window.percentUsed,
                      percentUsed.isFinite else {
                    continue
                }

                let cycleID = Self.cycleID(
                    provider: record.provider,
                    recordID: record.recordID,
                    window: window
                )
                let crossedThresholds = Self.thresholds.filter {
                    percentUsed >= Double($0)
                }
                if !crossedThresholds.isEmpty {
                    activeCycleIDs.insert(cycleID)
                }

                var cycle = state.cycles[cycleID] ?? StoredCycle()
                let previousThresholds = cycle.thresholds
                cycle.thresholds = cycle.thresholds.filter {
                    percentUsed >= Double($0)
                }

                if let threshold = crossedThresholds.last(where: {
                    !cycle.thresholds.contains($0)
                }) {
                    let alert = Self.makeAlert(
                        cycleID: cycleID,
                        record: record,
                        window: window,
                        percentUsed: percentUsed,
                        threshold: threshold
                    )
                    if pendingDeliveries[alert.identifier] == nil {
                        pendingDeliveries[alert.identifier] = PendingDelivery(
                            cycleID: cycleID,
                            thresholds: Set(crossedThresholds)
                        )
                        alerts.append(alert)
                    }
                }

                if cycle.thresholds.isEmpty {
                    state.cycles.removeValue(forKey: cycleID)
                } else {
                    if cycle.thresholds != previousThresholds {
                        cycle.updatedAt = now
                    }
                    state.cycles[cycleID] = cycle
                }
            }
        }

        self.activeCycleIDs = activeCycleIDs
        pruneState(relativeTo: now, preserving: activeCycleIDs)
        if state != previousState {
            persistState()
        }
        return alerts
    }

    mutating func recordDeliverySuccess(
        _ alert: QuotaAlert,
        now: Date = Date()
    ) {
        guard let pending = pendingDeliveries.removeValue(forKey: alert.identifier) else {
            return
        }

        var cycle = state.cycles[pending.cycleID] ?? StoredCycle()
        cycle.thresholds.formUnion(pending.thresholds)
        cycle.updatedAt = now
        state.cycles[pending.cycleID] = cycle
        pruneState(relativeTo: now, preserving: activeCycleIDs)
        persistState()
    }

    mutating func recordDeliveryFailure(_ alert: QuotaAlert) {
        pendingDeliveries.removeValue(forKey: alert.identifier)
    }

    mutating func cancelPendingDeliveries() {
        pendingDeliveries.removeAll()
    }

    private mutating func pruneState(
        relativeTo now: Date,
        preserving activeCycleIDs: Set<String>
    ) {
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        state.cycles = state.cycles.filter {
            activeCycleIDs.contains($0.key) || $0.value.updatedAt >= cutoff
        }

        guard state.cycles.count > Self.maximumStoredCycles else { return }

        let activeCycles = state.cycles.filter { activeCycleIDs.contains($0.key) }
        let inactiveCycles = state.cycles
            .filter { !activeCycleIDs.contains($0.key) }
            .sorted { lhs, rhs in
                if lhs.value.updatedAt != rhs.value.updatedAt {
                    return lhs.value.updatedAt > rhs.value.updatedAt
                }
                return lhs.key < rhs.key
            }
        let availableSlots = max(0, Self.maximumStoredCycles - activeCycles.count)
        let cyclesToKeep = Array(activeCycles) + Array(inactiveCycles.prefix(availableSlots))
        state.cycles = Dictionary(
            uniqueKeysWithValues: cyclesToKeep.map { ($0.key, $0.value) }
        )
    }

    private func persistState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func cycleID(
        provider: Provider,
        recordID: String,
        window: UsageWindow
    ) -> String {
        let periodComponent = window.periodSeconds.map { String($0) } ?? "none"
        let resetComponent: String
        if let resetDate = window.resetDate,
           let seconds = Int64(exactly: resetDate.timeIntervalSince1970.rounded()) {
            resetComponent = String(seconds)
        } else if window.resetDate == nil {
            resetComponent = "none"
        } else {
            resetComponent = "invalid"
        }
        let rawValue = [
            provider.rawValue,
            recordID,
            window.id,
            window.unit.rawValue,
            periodComponent,
            resetComponent
        ].joined(separator: "\u{1F}")
        return Data(rawValue.utf8).base64EncodedString()
    }

    private static func makeAlert(
        cycleID: String,
        record: ProviderRecord,
        window: UsageWindow,
        percentUsed: Double,
        threshold: Int
    ) -> QuotaAlert {
        let roundedPercentage = Int(percentUsed.rounded())
        return QuotaAlert(
            identifier: "SideBarAI.quota.\(cycleID).\(threshold)",
            title: "\(record.provider.displayName) quota warning",
            body: "\(window.label) usage reached \(roundedPercentage)%.",
            threshold: threshold
        )
    }

    private struct PendingDelivery {
        let cycleID: String
        let thresholds: Set<Int>
    }

    private struct PersistedState: Codable, Equatable {
        var cycles: [String: StoredCycle] = [:]
    }

    private struct StoredCycle: Codable, Equatable {
        var thresholds: Set<Int> = []
        var updatedAt: Date = .distantPast
    }
}
