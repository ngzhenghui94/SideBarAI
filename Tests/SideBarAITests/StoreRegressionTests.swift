import Foundation
import Testing
@testable import SideBarAI

@Suite(.serialized)
@MainActor
struct StoreRegressionTests {
    @Test
    func refreshPublishesIndependentlyAndKeepsPreviousReadings() async {
        let (defaults, name) = makeDefaults("incremental")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
        let slow = ControlledRefreshAdapter(provider: .antigravity)
        let reading = snapshot(used: 25, resetDate: nil)
        let store = UsageStore(adapters: [
            RegressionAdapter(provider: .chatgpt, customRecordID: "fast", state: .usage(reading)),
            slow
        ], defaults: defaults, refreshInterval: .zero)
        defer { store.shutdown() }

        await waitUntil { store.record(for: .chatgpt)?.state == .usage(reading) }
        #expect(store.record(for: .chatgpt)?.state == .usage(reading))
        #expect(store.isRefreshing)
        #expect(store.lastRefreshCompleted == nil)
        await slow.complete(0, with: .usage(reading))
        await waitForRefresh(store)
        #expect(!store.isRefreshing)

        store.refresh()
        #expect(store.record(for: .chatgpt)?.state == .usage(reading))
        #expect(store.record(for: .antigravity)?.state == .usage(reading))
        await slow.complete(1, with: .unavailable(message: "Offline"))
        await waitForRefresh(store)
        #expect(store.record(for: .antigravity)?.state == .unavailable(message: "Offline"))
    }

    @Test
    func canceledRefreshCannotOverwriteNewerResults() async {
        let (defaults, name) = makeDefaults("canceledRefresh")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
        let adapter = ControlledRefreshAdapter(provider: .chatgpt)
        let store = UsageStore(adapters: [adapter], defaults: defaults, refreshInterval: .zero)
        defer { store.shutdown() }
        for _ in 0..<100 {
            if await adapter.callCount() == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await adapter.callCount() == 1)
        store.refresh()
        let reading = snapshot(used: 50, resetDate: nil)
        await adapter.complete(1, with: .usage(reading))
        await waitForRefresh(store)
        #expect(store.record(for: .chatgpt)?.state == .usage(reading))
        let completed = store.lastRefreshCompleted
        await adapter.complete(0, with: .unavailable(message: "Obsolete failure"))
        await settle()
        #expect(store.record(for: .chatgpt)?.state == .usage(reading))
        #expect(store.lastRefreshCompleted == completed)
        #expect(!store.isRefreshing)
    }

    @Test
    func duplicateAdapterIDsAreStableAndEveryRecordFinishes() async {
        let (defaults, defaultsName) = makeDefaults("DuplicateIDs")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")

        let adapters = [
            RegressionAdapter(
                provider: .chatgpt,
                customRecordID: "duplicate",
                state: .unavailable(message: "first")
            ),
            RegressionAdapter(
                provider: .chatgpt,
                customRecordID: "duplicate",
                state: .unavailable(message: "second")
            )
        ]
        let store = UsageStore(
            adapters: adapters,
            defaults: defaults,
            refreshInterval: .zero
        )
        defer { store.shutdown() }

        await waitForRefresh(store)

        #expect(store.records.map(\.recordID) == ["duplicate", "duplicate#2"])
        #expect(Set(store.records.map(\.recordID)).count == 2)
        #expect(store.records.allSatisfy { !$0.state.isLoading })
    }

    @Test
    func nonpositiveAutomaticRefreshIntervalsDoNotStartPolling() async {
        for interval in [Duration.zero, .seconds(-1)] {
            let (defaults, defaultsName) = makeDefaults("Interval")
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
            let counter = FetchCounter()
            let store = UsageStore(
                adapters: [CountingRegressionAdapter(counter: counter)],
                defaults: defaults,
                refreshInterval: interval
            )
            await waitForRefresh(store)
            let initialFetchCount = await counter.value()
            try? await Task.sleep(for: .milliseconds(80))
            #expect(await counter.value() == initialFetchCount)
            store.shutdown()
        }
    }

    @Test
    func disablingDuringAuthorizationCannotBeUndoneByLateGrant() async {
        let (defaults, defaultsName) = makeDefaults("AuthorizationRace")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let delivery = BlockingAuthorizationDelivery()
        let store = UsageStore(
            adapters: [],
            defaults: defaults,
            refreshInterval: .zero,
            quotaAlertDelivery: delivery
        )
        defer { store.shutdown() }

        await waitUntil { delivery.authorizationStarted }
        await store.setQuotaAlertsEnabled(false)
        delivery.resolveAuthorization(true)
        await settle()

        #expect(!store.quotaAlertsEnabled)
        #expect(!defaults.bool(forKey: "SideBarAI.quotaAlertsEnabled"))
        #expect(!store.isQuotaAlertAuthorizationPending)
    }

    @Test
    func failedDeliveryIsRetriedAndOnlySuccessPersistsDeduplication() async {
        let (defaults, defaultsName) = makeDefaults("DeliveryRetry")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: "SideBarAI.quotaAlertsEnabled")
        let delivery = SequencedAlertDelivery(results: [false, true])
        let adapter = RegressionAdapter(
            provider: .claude,
            customRecordID: "claude",
            state: .usage(snapshot(used: 76, resetDate: Date(timeIntervalSince1970: 1_800_000_000)))
        )
        let store = UsageStore(
            adapters: [adapter],
            defaults: defaults,
            refreshInterval: .zero,
            quotaAlertDelivery: delivery
        )
        defer { store.shutdown() }

        await waitForDeliveryCount(delivery, count: 1)
        #expect(delivery.results == [true])
        #expect(defaults.data(forKey: "SideBarAI.quotaAlertState") == nil)

        store.refresh()
        await waitForRefresh(store)
        await waitForDeliveryCount(delivery, count: 2)

        #expect(delivery.alerts.map(\.threshold) == [75, 75])
        #expect(defaults.data(forKey: "SideBarAI.quotaAlertState") != nil)
        var evaluator = QuotaAlertEvaluator(defaults: defaults)
        #expect(evaluator.alerts(for: store.records).isEmpty)
    }

    @Test
    func disablingCancelsPendingDeliveryAndAllowsRetryAfterReenable() async {
        let (defaults, defaultsName) = makeDefaults("DeliveryCancel")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: "SideBarAI.quotaAlertsEnabled")
        let delivery = BlockingAlertDelivery()
        let adapter = RegressionAdapter(
            provider: .antigravity,
            customRecordID: "antigravity",
            state: .usage(snapshot(used: 76, resetDate: Date(timeIntervalSince1970: 1_800_000_000)))
        )
        let store = UsageStore(
            adapters: [adapter],
            defaults: defaults,
            refreshInterval: .zero,
            quotaAlertDelivery: delivery
        )
        defer { store.shutdown() }

        await waitForDeliveryCount(delivery, count: 1)
        await store.setQuotaAlertsEnabled(false)
        delivery.resolvePending(true)
        await settle()

        #expect(!store.quotaAlertsEnabled)
        #expect(defaults.data(forKey: "SideBarAI.quotaAlertState") == nil)

        await store.setQuotaAlertsEnabled(true)
        await waitForDeliveryCount(delivery, count: 2)
        await settle()
        #expect(delivery.alerts.map(\.threshold) == [75, 75])
        #expect(defaults.data(forKey: "SideBarAI.quotaAlertState") != nil)
    }

    @Test
    func activeCyclesSurviveRetentionAndCapacityPruning() {
        let (defaults, defaultsName) = makeDefaults("ActiveCycles")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let oldDate = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let records = (0..<257).map { index in
            ProviderRecord(
                recordID: "account-\(index)",
                provider: .chatgpt,
                state: .usage(snapshot(used: 76, resetDate: oldDate))
            )
        }
        var evaluator = QuotaAlertEvaluator(defaults: defaults)
        let initialAlerts = evaluator.alerts(for: records, now: oldDate)
        #expect(initialAlerts.count == records.count)
        for alert in initialAlerts {
            evaluator.recordDeliverySuccess(alert, now: oldDate)
        }

        var reloadedEvaluator = QuotaAlertEvaluator(defaults: defaults)
        #expect(reloadedEvaluator.alerts(for: records, now: now).isEmpty)
    }

    @Test
    func quotaCycleIdentityIncludesProviderAndSafeResetDates() {
        let (defaults, defaultsName) = makeDefaults("CycleIdentity")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let resetDate = Date(timeIntervalSince1970: 1_800_000_000)
        let sharedWindow = UsageWindow(
            id: "primary",
            label: "Primary",
            used: 76,
            limit: 100,
            unit: .percent,
            resetDate: resetDate,
            providerReportedPercentage: true
        )
        let records = [
            ProviderRecord(
                recordID: "shared",
                provider: .claude,
                state: .usage(UsageSnapshot(
                    windows: [sharedWindow],
                    updatedAt: resetDate,
                    accountLabel: nil,
                    planLabel: nil,
                    sourceLabel: "fixture"
                ))
            ),
            ProviderRecord(
                recordID: "shared",
                provider: .antigravity,
                state: .usage(UsageSnapshot(
                    windows: [sharedWindow],
                    updatedAt: resetDate,
                    accountLabel: nil,
                    planLabel: nil,
                    sourceLabel: "fixture"
                ))
            )
        ]
        var evaluator = QuotaAlertEvaluator(defaults: defaults)
        let alerts = evaluator.alerts(for: records, now: resetDate)
        #expect(alerts.count == 2)
        #expect(Set(alerts.map(\.identifier)).count == 2)

        let invalidReset = Date(timeIntervalSince1970: .infinity)
        let invalidRecord = ProviderRecord(
            recordID: "invalid-reset",
            provider: .claude,
            state: .usage(snapshot(used: 76, resetDate: invalidReset))
        )
        #expect(!evaluator.alerts(for: [invalidRecord], now: resetDate).isEmpty)
    }

    private func snapshot(used: Double, resetDate: Date?) -> UsageSnapshot {
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
            updatedAt: resetDate ?? Date(timeIntervalSince1970: 1_800_000_000),
            accountLabel: nil,
            planLabel: nil,
            sourceLabel: "fixture"
        )
    }

    private func makeDefaults(_ label: String) -> (UserDefaults, String) {
        let name = "SideBarAITests.StoreRegression.\(label).\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func waitForRefresh(_ store: UsageStore) async {
        for _ in 0..<100 {
            if !store.isRefreshing { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
    }

    private func waitForDeliveryCount(_ delivery: AlertDeliveryProbe, count: Int) async {
        await waitUntil { delivery.deliveryCount >= count }
    }

    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}

private actor ControlledRefreshAdapter: UsageProviderAdapter {
    nonisolated let provider: Provider
    private var nextCall = 0
    private var pending: [Int: CheckedContinuation<ProviderState, Never>] = [:]
    private var completed: [Int: ProviderState] = [:]

    init(provider: Provider) { self.provider = provider }

    func callCount() -> Int { nextCall }

    func fetch() async -> ProviderState {
        let call = nextCall
        nextCall += 1
        if let state = completed.removeValue(forKey: call) { return state }
        return await withCheckedContinuation { pending[call] = $0 }
    }

    func complete(_ call: Int, with state: ProviderState) {
        if let continuation = pending.removeValue(forKey: call) {
            continuation.resume(returning: state)
        } else {
            completed[call] = state
        }
    }
}

private struct RegressionAdapter: UsageProviderAdapter {
    let provider: Provider
    let customRecordID: String
    let state: ProviderState

    var recordID: String { customRecordID }

    func fetch() async -> ProviderState {
        state
    }
}

private actor FetchCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private struct CountingRegressionAdapter: UsageProviderAdapter {
    let provider: Provider = .chatgpt
    let counter: FetchCounter

    func fetch() async -> ProviderState {
        await counter.increment()
        return .unavailable(message: "fixture")
    }
}

@MainActor
private protocol AlertDeliveryProbe: AnyObject {
    var deliveryCount: Int { get }
}

@MainActor
private final class BlockingAuthorizationDelivery: QuotaAlertDelivering {
    private(set) var authorizationStarted = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestAuthorization() async -> Bool {
        authorizationStarted = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolveAuthorization(_ granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }

    func deliver(_ alert: QuotaAlert) async -> Bool {
        true
    }
}

@MainActor
private final class SequencedAlertDelivery: QuotaAlertDelivering, AlertDeliveryProbe {
    private(set) var results: [Bool]
    private(set) var alerts: [QuotaAlert] = []

    var deliveryCount: Int { alerts.count }

    init(results: [Bool]) {
        self.results = results
    }

    func requestAuthorization() async -> Bool {
        true
    }

    func deliver(_ alert: QuotaAlert) async -> Bool {
        alerts.append(alert)
        return results.isEmpty ? true : results.removeFirst()
    }
}

@MainActor
private final class BlockingAlertDelivery: QuotaAlertDelivering, AlertDeliveryProbe {
    private(set) var alerts: [QuotaAlert] = []
    private var continuation: CheckedContinuation<Bool, Never>?

    var deliveryCount: Int { alerts.count }

    func requestAuthorization() async -> Bool {
        true
    }

    func deliver(_ alert: QuotaAlert) async -> Bool {
        alerts.append(alert)
        guard alerts.count == 1 else { return true }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolvePending(_ delivered: Bool) {
        continuation?.resume(returning: delivered)
        continuation = nil
    }
}
