import Foundation
import Testing
@testable import SideBarAI

@Suite(.serialized)
@MainActor
struct QuotaAlertsTests {
    @Test
    func quotaSummaryUsesHighestBoundedWindow() {
        let records = [
            record(provider: .claude, recordID: "claude", used: 42),
            record(provider: .chatgpt, recordID: "chatgpt", used: 83.4),
            ProviderRecord(
                provider: .antigravity,
                state: .usage(
                    UsageSnapshot(
                        windows: [
                            UsageWindow(
                                id: "tokens",
                                label: "Tokens",
                                used: 50_000,
                                limit: nil,
                                unit: .tokens,
                                resetDate: nil,
                                providerReportedPercentage: false
                            )
                        ],
                        updatedAt: Date(),
                        accountLabel: nil,
                        planLabel: nil,
                        sourceLabel: "fixture"
                    )
                )
            )
        ]

        #expect(QuotaSummary.highestPercentage(in: records) == 83)
    }

    @Test
    func quotaAlertsUseHighestNewThresholdAndPersistDeduplication() {
        let suiteName = "SideBarAITests.QuotaAlerts.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let resetDate = Date(timeIntervalSince1970: 1_800_000_000)
        let warningRecord = record(
            provider: .claude,
            recordID: "claude-account",
            used: 91,
            resetDate: resetDate
        )
        var evaluator = QuotaAlertEvaluator(defaults: defaults)

        let firstAlerts = evaluator.alerts(for: [warningRecord])
        #expect(firstAlerts.map(\.threshold) == [90])
        for alert in firstAlerts {
            evaluator.recordDeliverySuccess(alert)
        }

        var reloadedEvaluator = QuotaAlertEvaluator(defaults: defaults)
        #expect(reloadedEvaluator.alerts(for: [warningRecord]).isEmpty)
        let exhaustedRecord = record(
            provider: .claude,
            recordID: "claude-account",
            used: 100,
            resetDate: resetDate
        )
        let exhaustedAlerts = reloadedEvaluator.alerts(for: [exhaustedRecord])
        #expect(exhaustedAlerts.map(\.threshold) == [100])
    }

    @Test
    func defaultQuotaAlertsRequestPermissionAndDeliverCurrentWarning() async {
        let suiteName = "SideBarAITests.QuotaDelivery.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delivery = RecordingQuotaAlertDelivery(authorizationGranted: true)
        let adapter = QuotaStubAdapter(
            provider: .chatgpt,
            state: record(
                provider: .chatgpt,
                recordID: "chatgpt",
                used: 76,
                resetDate: Date(timeIntervalSince1970: 1_800_000_000)
            ).state
        )
        let store = UsageStore(
            adapters: [adapter],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60),
            quotaAlertDelivery: delivery
        )
        defer { store.shutdown() }
        await waitForRefresh(store)

        await settle()

        #expect(store.quotaAlertsEnabled)
        #expect(defaults.bool(forKey: "SideBarAI.quotaAlertsEnabled"))
        #expect(delivery.authorizationRequestCount == 1)
        #expect(delivery.alerts.map(\.threshold) == [75])

        store.refresh()
        await waitForRefresh(store)
        await settle()
        #expect(delivery.alerts.map(\.threshold) == [75])
    }

    @Test
    func deniedNotificationPermissionKeepsQuotaAlertsDisabled() async {
        let suiteName = "SideBarAITests.QuotaDenied.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delivery = RecordingQuotaAlertDelivery(authorizationGranted: false)
        let store = UsageStore(
            adapters: [],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60),
            quotaAlertDelivery: delivery
        )
        defer { store.shutdown() }
        await waitForRefresh(store)
        await settle()

        await store.setQuotaAlertsEnabled(true)

        #expect(!store.quotaAlertsEnabled)
        #expect(!defaults.bool(forKey: "SideBarAI.quotaAlertsEnabled"))
        #expect(store.quotaAlertsAuthorizationMessage?.contains("System Settings") == true)
    }

    private func record(
        provider: Provider,
        recordID: String,
        used: Double,
        resetDate: Date? = nil
    ) -> ProviderRecord {
        ProviderRecord(
            recordID: recordID,
            provider: provider,
            isActive: true,
            state: .usage(
                UsageSnapshot(
                    windows: [
                        UsageWindow(
                            id: "primary",
                            label: "Primary",
                            used: used,
                            limit: 100,
                            unit: .percent,
                            resetDate: resetDate,
                            providerReportedPercentage: true
                        )
                    ],
                    updatedAt: Date(),
                    accountLabel: nil,
                    planLabel: nil,
                    sourceLabel: "fixture"
                )
            )
        )
    }

    private func waitForRefresh(_ store: UsageStore) async {
        for _ in 0..<100 {
            if !store.isRefreshing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}

private struct QuotaStubAdapter: UsageProviderAdapter {
    let provider: Provider
    let state: ProviderState

    func fetch() async -> ProviderState {
        state
    }
}

@MainActor
private final class RecordingQuotaAlertDelivery: QuotaAlertDelivering {
    let authorizationGranted: Bool
    private(set) var authorizationRequestCount = 0
    private(set) var alerts: [QuotaAlert] = []

    init(authorizationGranted: Bool) {
        self.authorizationGranted = authorizationGranted
    }

    func requestAuthorization() async -> Bool {
        authorizationRequestCount += 1
        return authorizationGranted
    }

    func deliver(_ alert: QuotaAlert) async -> Bool {
        alerts.append(alert)
        return true
    }
}
