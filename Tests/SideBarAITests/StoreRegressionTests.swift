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

    @Test
    func codexMembershipAndMetadataRefreshOnTheSameStore() async {
        let (defaults, name) = makeDefaults("CodexMembership")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
        let firstReading = snapshot(used: 25, resetDate: nil)
        let secondReading = snapshot(used: 60, resetDate: nil)
        let claude = ControlledRefreshAdapter(provider: .claude)
        let discovery = MutableCodexDiscovery(adapters: [
            codexFixture("one", label: "Work", state: .usage(firstReading)),
            codexFixture("two", label: "Personal", state: .usage(secondReading))
        ])
        let store = UsageStore(
            adapters: [claude], defaults: defaults, refreshInterval: .zero,
            codexAdaptersFactory: { discovery.adapters }
        )
        defer { store.shutdown() }
        await claude.complete(0, with: .usage(firstReading))
        await waitForRefresh(store)
        #expect(store.records.map(\.recordID) == ["chatgpt:one", "chatgpt:two", "claude"])
        #expect(store.records.first(where: { $0.recordID == "chatgpt:one" })?.accountLabel == "Work")
        #expect(store.records(for: .chatgpt).allSatisfy { !$0.isActive })

        // Identity survives reordering and renaming; OMP need not report an active login.
        discovery.adapters = [
            codexFixture("two", label: "Renamed", state: .usage(secondReading)),
            codexFixture("three", label: "New", state: .usage(firstReading)),
            codexFixture("one", label: "Work", state: .usage(firstReading))
        ]
        store.refresh()
        await waitUntil { store.records.map(\.recordID) == ["chatgpt:two", "chatgpt:three", "chatgpt:one", "claude"] }
        #expect(store.records[0].state == .usage(secondReading))
        #expect(store.records[2].state == .usage(firstReading))
        #expect(store.records[3].state == .usage(firstReading))
        #expect(store.records.first(where: { $0.recordID == "chatgpt:two" })?.accountLabel == "Renamed")
        await claude.complete(1, with: .usage(secondReading))
        await waitForRefresh(store)
        #expect(store.record(for: .claude)?.state == .usage(secondReading))

        discovery.adapters = [codexFixture("three", label: "New", state: .usage(firstReading))]
        store.refresh()
        await claude.complete(2, with: .usage(firstReading))
        await waitForRefresh(store)
        #expect(store.records.map(\.recordID) == ["chatgpt:three", "claude"])
        #expect(await claude.callCount() == 3)
        #expect(!store.isRefreshing)

        discovery.adapters = []
        store.refresh()
        await claude.complete(3, with: .usage(firstReading))
        await waitForRefresh(store)
        #expect(store.records.map(\.recordID) == ["chatgpt", "claude"])
        #expect(store.record(for: .chatgpt)?.requiresSetup == true)
        #expect(store.record(for: .chatgpt)?.state.errorMessage?.contains("OMP") == true)
    }

    @Test
    func scheduledRefreshRediscoversCodexMembership() async {
        let (defaults, name) = makeDefaults("ScheduledCodexMembership")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
        let discovery = MutableCodexDiscovery(adapters: [
            codexFixture("one", label: "Original", state: .unavailable(message: "fixture"))
        ])
        let store = UsageStore(
            adapters: [], defaults: defaults, refreshInterval: .milliseconds(20),
            codexAdaptersFactory: { discovery.adapters }
        )
        defer { store.shutdown() }
        await waitForRefresh(store)
        discovery.adapters = [codexFixture("two", label: "Replacement", state: .unavailable(message: "fixture"))]
        for _ in 0..<100 {
            if store.records.map(\.recordID) == ["chatgpt:two"] { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.records.map(\.recordID) == ["chatgpt:two"])
        #expect(store.record(for: .chatgpt)?.accountLabel == "Replacement")
        #expect(store.record(for: .chatgpt)?.isActive == false)
    }


    @Test
    func rediscoveryDiscardsDelayedResultsFromRemovedAndReplacedAdapters() async {
        let (defaults, name) = makeDefaults("CodexMembershipCancellation")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
        let removed = ControlledRefreshAdapter(provider: .chatgpt, recordID: "removed")
        let replaced = ControlledRefreshAdapter(provider: .chatgpt, recordID: "retained")
        let discovery = MutableCodexDiscovery(adapters: [removed, replaced])
        let store = UsageStore(
            adapters: [], defaults: defaults, refreshInterval: .zero,
            codexAdaptersFactory: { discovery.adapters }
        )
        defer { store.shutdown() }
        for _ in 0..<100 {
            if await removed.callCount() == 1, await replaced.callCount() == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await removed.callCount() == 1)
        #expect(await replaced.callCount() == 1)
        let reading = snapshot(used: 35, resetDate: nil)
        discovery.adapters = [RegressionAdapter(provider: .chatgpt, customRecordID: "retained", state: .usage(reading))]
        store.refresh()
        await waitForRefresh(store)
        #expect(store.records.map(\.recordID) == ["retained"])
        #expect(store.records.first?.state == .usage(reading))
        let completed = store.lastRefreshCompleted
        await removed.complete(0, with: .unavailable(message: "Removed account result"))
        await replaced.complete(0, with: .unavailable(message: "Obsolete retained account result"))
        await settle()
        #expect(store.records.map(\.recordID) == ["retained"])
        #expect(store.records.first?.state == .usage(reading))
        #expect(store.lastRefreshCompleted == completed)
        #expect(!store.isRefreshing)
    }

    @Test
    func injectedAdaptersRemainFixedWithoutDiscoveryFactory() async {
        let (defaults, name) = makeDefaults("FixedAdapters")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
        let store = UsageStore(
            adapters: [RegressionAdapter(provider: .chatgpt, customRecordID: "injected", state: .unavailable(message: "fixture"))],
            defaults: defaults, refreshInterval: .zero
        )
        defer { store.shutdown() }
        await waitForRefresh(store)
        store.refresh()
        await waitForRefresh(store)
        #expect(store.records.map(\.recordID) == ["injected"])
        #expect(store.records.first?.state == .unavailable(message: "fixture"))
    }

    @Test
    func codexRediscoveryKeepsClaudeKeychainAuthorizationCache() async {
        let (defaults, name) = makeDefaults("CodexClaudeAuthorization")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
        // Disable Claude fetching so this test never contacts its usage endpoint.
        defaults.set([Provider.claude.rawValue], forKey: "SideBarAI.disabledProviders")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let claude = ClaudeUsageAdapter(
            credentials: LocalCredentialReader(homeDirectoryURL: home), defaults: defaults,
            keychainReader: { _ in Data(#"{"claudeAiOauth":{"accessToken":"fixture-only"}}"#.utf8) }
        )
        let discovery = MutableCodexDiscovery(adapters: [
            RegressionAdapter(provider: .chatgpt, customRecordID: "one", state: .unavailable(message: "fixture"))
        ])
        let store = UsageStore(
            adapters: [claude], defaults: defaults, refreshInterval: .zero,
            codexAdaptersFactory: { discovery.adapters }
        )
        defer { store.shutdown() }
        await waitForRefresh(store)
        store.authorizeClaudeKeychain()
        await waitForRefresh(store)
        #expect(store.claudeKeychainAuthorizedForRun)
        #expect(claude.keychainAccessAuthorizedForRun)
        discovery.adapters = [
            RegressionAdapter(provider: .chatgpt, customRecordID: "two", state: .unavailable(message: "fixture"))
        ]
        store.refresh()
        await waitForRefresh(store)
        #expect(store.claudeKeychainAuthorizedForRun)
        #expect(store.records.map(\.recordID) == ["two", "claude"])
        store.disableClaudeKeychainAccess()
        #expect(!claude.keychainAccessAuthorizedForRun)
        #expect(!store.claudeKeychainAuthorizedForRun)
        await waitForRefresh(store)
    }

    @Test
    func discoveryFailureRetainsAccountsAndRecoversWithoutBlockingOtherProviders() async {
        let (defaults, name) = makeDefaults("DiscoveryFailure")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
        let discovery = ControlledCodexDiscovery()
        let reading = snapshot(used: 35, resetDate: nil)
        let store = UsageStore(
            adapters: [RegressionAdapter(provider: .claude, customRecordID: "claude", state: .usage(reading))],
            defaults: defaults, refreshInterval: .zero,
            codexAdaptersFactory: { try await discovery.discover() }
        )
        defer { store.shutdown() }
        await waitUntil { discovery.callCount == 1 && store.record(for: .claude)?.state == .usage(reading) }
        #expect(store.record(for: .claude)?.state == .usage(reading))
        #expect(store.isRefreshing)
        discovery.complete(0, with: .success([codexFixture("one", label: "Known", state: .usage(reading))]))
        await waitForRefresh(store)

        store.refresh()
        await waitUntil { discovery.callCount == 2 }
        #expect(store.record(for: .chatgpt)?.state == .usage(reading))
        discovery.complete(1, with: .failure(UsageCommandError.timedOut))
        await waitForRefresh(store)
        #expect(store.records.map(\.recordID) == ["chatgpt:one", "claude"])
        #expect(store.record(for: .chatgpt)?.accountLabel == "Known")
        #expect(store.record(for: .chatgpt)?.state.errorMessage?.contains("timed out") == true)
        #expect(store.record(for: .chatgpt)?.requiresSetup == false)
        #expect(store.record(for: .claude)?.state == .usage(reading))

        store.refresh()
        await waitUntil { discovery.callCount == 3 }
        discovery.complete(2, with: .success([codexFixture("one", label: "Renamed", state: .usage(reading))]))
        await waitForRefresh(store)
        #expect(store.record(for: .chatgpt)?.accountLabel == "Renamed")
        #expect(store.record(for: .chatgpt)?.state == .usage(reading))
    }

    @Test
    func discoveryFailureWithoutAccountsIsNotSuccessfulEmptySetup() async {
        let (defaults, name) = makeDefaults("DiscoveryEmptyFailure")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
        let discovery = ControlledCodexDiscovery()
        let store = UsageStore(adapters: [], defaults: defaults, refreshInterval: .zero,
                               codexAdaptersFactory: { try await discovery.discover() })
        defer { store.shutdown() }
        await waitUntil { discovery.callCount == 1 }
        discovery.complete(0, with: .failure(UsageCommandError.timedOut))
        await waitForRefresh(store)
        #expect(store.record(for: .chatgpt)?.requiresSetup == false)
        #expect(store.record(for: .chatgpt)?.state.errorMessage?.contains("timed out") == true)
        store.refresh()
        await waitUntil { discovery.callCount == 2 }
        discovery.complete(1, with: .success([]))
        await waitForRefresh(store)
        #expect(store.records.map(\.recordID) == ["chatgpt"])
        #expect(store.record(for: .chatgpt)?.requiresSetup == true)
    }

    @Test
    func staleDiscoverySuccessOrFailureCannotResurrectRemovedAccounts() async {
        for staleFails in [false, true] {
            let (defaults, name) = makeDefaults("StaleDiscovery")
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
            let discovery = ControlledCodexDiscovery()
            let store = UsageStore(adapters: [], defaults: defaults, refreshInterval: .zero,
                                   codexAdaptersFactory: { try await discovery.discover() })
            defer { store.shutdown() }
            await waitUntil { discovery.callCount == 1 }
            store.refresh()
            await waitUntil { discovery.callCount == 2 }
            discovery.complete(1, with: .success([]))
            await waitForRefresh(store)
            let records = store.records
            let completed = store.lastRefreshCompleted
            if staleFails {
                discovery.complete(0, with: .failure(UsageCommandError.timedOut))
            } else {
                discovery.complete(0, with: .success([
                    codexFixture("removed", label: "Obsolete", state: .unavailable(message: "obsolete"))
                ]))
            }
            await settle()
            #expect(store.records == records)
            #expect(store.lastRefreshCompleted == completed)
            #expect(!store.isRefreshing)
        }
    }

    @Test
    func canceledGenerationDoesNotStartDiscovery() async {
        let (defaults, name) = makeDefaults("DiscoveryBeforeAwait")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
        let discovery = ControlledCodexDiscovery()
        let store = UsageStore(adapters: [], defaults: defaults, refreshInterval: .zero,
                               codexAdaptersFactory: { try await discovery.discover() })
        defer { store.shutdown() }
        // All calls occur on MainActor without yielding; only the final task may discover.
        store.refresh()
        store.refresh()
        await waitUntil { discovery.callCount == 1 }
        discovery.complete(0, with: .success([]))
        await waitForRefresh(store)
        #expect(discovery.callCount == 1)
    }

    @Test
    func shutdownDiscardsPendingDiscoveryMembership() async {
        let (defaults, name) = makeDefaults("DiscoveryShutdown")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SideBarAI.quotaAlertsEnabled")
        let discovery = ControlledCodexDiscovery()
        let store = UsageStore(adapters: [], defaults: defaults, refreshInterval: .zero,
                               codexAdaptersFactory: { try await discovery.discover() })
        await waitUntil { discovery.callCount == 1 }
        store.shutdown()
        let records = store.records
        discovery.complete(0, with: .success([
            codexFixture("late", label: "Late", state: .unavailable(message: "obsolete"))
        ]))
        await settle()
        #expect(store.records == records)
        #expect(store.lastRefreshCompleted == nil)
        #expect(!store.isRefreshing)
    }


    private func codexFixture(_ key: String, label: String, state: ProviderState) -> DiscoveredCodexFixtureAdapter {
        DiscoveredCodexFixtureAdapter(
            account: CodexAccount(accountKey: key, accountLabel: label), state: state
        )
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

@MainActor
private final class MutableCodexDiscovery {
    var adapters: [any UsageProviderAdapter]

    init(adapters: [any UsageProviderAdapter]) { self.adapters = adapters }
}

private struct DiscoveredCodexFixtureAdapter: UsageProviderAdapter {
    let account: CodexAccount
    let state: ProviderState

    var provider: Provider { .chatgpt }
    var recordID: String { account.recordID }
    var accountLabel: String? { account.accountLabel }
    var isActive: Bool { account.isActive }
    var hasUsableCredentials: Bool { true }
    var planLabel: String? { account.planLabel }

    func fetch() async -> ProviderState { state }
}

private actor ControlledRefreshAdapter: UsageProviderAdapter {
    nonisolated let provider: Provider
    nonisolated let recordID: String
    private var nextCall = 0
    private var pending: [Int: CheckedContinuation<ProviderState, Never>] = [:]
    private var completed: [Int: ProviderState] = [:]

    init(provider: Provider, recordID: String? = nil) {
        self.provider = provider
        self.recordID = recordID ?? provider.rawValue
    }

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


@MainActor
private final class ControlledCodexDiscovery {
    private var continuations: [Int: CheckedContinuation<[any UsageProviderAdapter], any Error>] = [:]
    private(set) var callCount = 0

    func discover() async throws -> [any UsageProviderAdapter] {
        let index = callCount
        callCount += 1
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }

    func complete(_ index: Int, with result: Result<[any UsageProviderAdapter], any Error>) {
        continuations.removeValue(forKey: index)?.resume(with: result)
    }
}

