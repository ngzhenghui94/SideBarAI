import Foundation
import Testing
@testable import SideBarAI

@Suite(.serialized)
@MainActor
struct UsageStoreTests {
    @Test
    func providerPercentIsDerivedOnlyFromAnExplicitLimit() {
        let measured = UsageWindow(
            id: "primary",
            label: "Primary",
            used: 25,
            limit: 100,
            unit: .percent,
            resetDate: nil,
            providerReportedPercentage: true
        )
        let unbounded = UsageWindow(
            id: "tokens",
            label: "Tokens",
            used: 25_000,
            limit: nil,
            unit: .tokens,
            resetDate: nil,
            providerReportedPercentage: false
        )

        #expect(measured.percentUsed == 25)
        #expect(unbounded.percentUsed == nil)
    }

    @Test
    func storeAppliesAuthenticatedAdapterSnapshots() async {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = UsageSnapshot(
            windows: [
                UsageWindow(
                    id: "weekly",
                    label: "Weekly",
                    used: 41,
                    limit: 100,
                    unit: .percent,
                    resetDate: updatedAt.addingTimeInterval(3_600),
                    providerReportedPercentage: true
                )
            ],
            updatedAt: updatedAt,
            accountLabel: "test-account",
            planLabel: "test-plan",
            sourceLabel: "fixture"
        )
        let adapters = Provider.allCases.map {
            StubAdapter(provider: $0, state: .usage(snapshot))
        }
        let store = UsageStore(adapters: adapters)

        await settle()

        #expect(store.records.count == Provider.allCases.count)
        #expect(store.record(for: .claude)?.state == .usage(snapshot))
        #expect(store.record(for: .chatgpt)?.state == .usage(snapshot))
        #expect(store.record(for: .antigravity)?.state == .usage(snapshot))
    }

    @Test
    func missingCredentialsRemainUnavailableInsteadOfBecomingZero() async {
        let adapters = Provider.allCases.map {
            StubAdapter(provider: $0, state: .unavailable(message: "No credentials"))
        }
        let store = UsageStore(adapters: adapters)

        await settle()

        for record in store.records {
            guard case let .unavailable(message) = record.state else {
                Issue.record("Expected \(record.provider) to remain unavailable")
                continue
            }
            #expect(message == "No credentials")
        }
    }

    @Test
    func manualRefreshPublishesProgressAndCompletion() async {
        let adapters = Provider.allCases.map {
            StubAdapter(provider: $0, state: .unavailable(message: "No credentials"))
        }
        let store = UsageStore(adapters: adapters)

        await settle()
        #expect(!store.isRefreshing)
        #expect(store.lastRefreshAttempt != nil)
        #expect(store.lastRefreshCompleted != nil)

        store.refresh()
        #expect(store.isRefreshing)

        await settle()
        #expect(!store.isRefreshing)
        #expect(store.lastRefreshCompleted != nil)
    }

    @Test
    func automaticRefreshRunsAtConfiguredInterval() async {
        #expect(UsageStore.automaticRefreshInterval == .seconds(5 * 60))

        let counter = FetchCounter()
        let adapters = Provider.allCases.map {
            CountingAdapter(
                provider: $0,
                counter: counter,
                state: .unavailable(message: "No credentials")
            )
        }
        let store = UsageStore(
            adapters: adapters,
            refreshInterval: .milliseconds(50)
        )
        defer { store.shutdown() }

        let expectedFetches = Provider.allCases.count * 2
        for _ in 0..<100 {
            if await counter.value() >= expectedFetches {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let fetchCount = await counter.value()
        #expect(fetchCount >= expectedFetches)
    }

    @Test
    func hiddenProvidersAreFilteredAndPersisted() async {
        let suiteName = "SideBarAITests.HiddenProviders.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let adapters = Provider.allCases.map {
            StubAdapter(provider: $0, state: .unavailable(message: "No credentials"))
        }
        let store = UsageStore(adapters: adapters, defaults: defaults)
        await settle()

        store.setProviderVisible(false, for: .antigravity)

        #expect(!store.isProviderVisible(.antigravity))
        #expect(store.visibleRecords.count == Provider.allCases.count - 1)
        #expect(!store.visibleRecords.contains(where: { $0.provider == .antigravity }))

        let reloadedStore = UsageStore(adapters: adapters, defaults: defaults)
        #expect(!reloadedStore.isProviderVisible(.antigravity))
        #expect(reloadedStore.visibleRecords.allSatisfy { $0.provider != .antigravity })

        reloadedStore.setProviderVisible(true, for: .antigravity)
        #expect(reloadedStore.isProviderVisible(.antigravity))
        #expect(reloadedStore.visibleRecords.count == Provider.allCases.count)

        store.shutdown()
        reloadedStore.shutdown()
    }

    @Test
    func providerAdaptersWithoutUsableCredentialsAreInactive() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = LocalCredentialReader(homeDirectoryURL: home)
        let suiteName = "SideBarAITests.ProviderActivity.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let claude = ClaudeUsageAdapter(
            credentials: reader,
            defaults: defaults,
            keychainReader: { _ in nil }
        )
        let antigravity = AntigravityUsageAdapter()
        let codex = CodexUsageAdapter(credentials: reader)

        #expect(!claude.isActive)
        #expect(!antigravity.isActive)
        #expect(!codex.isActive)

        try write(
            "{\"claudeAiOauth\":{\"accessToken\":\"expired-token\",\"expiresAt\":1}}",
            to: home.appendingPathComponent(".claude/.credentials.json")
        )
        let expiredClaude = ClaudeUsageAdapter(
            credentials: reader,
            defaults: defaults,
            keychainReader: { _ in nil }
        )
        #expect(!expiredClaude.isActive)
    }

    @Test
    func explicitClaudeKeychainAuthorizationEnablesLaterNoninteractiveFetch() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let suiteName = "SideBarAITests.ClaudeKeychainAuthorized.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainData = Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-token\"}}".utf8)
        let recorder = KeychainReaderRecorder(data: keychainData)
        let session = fixtureSession([
            "/api/oauth/usage": "{\"five_hour\":{\"utilization\":42,\"resets_at\":\"2030-01-01T00:00:00Z\"}}"
        ])
        let adapter = ClaudeUsageAdapter(
            http: UsageHTTPClient(session: session),
            credentials: LocalCredentialReader(homeDirectoryURL: home),
            defaults: defaults,
            keychainReader: { allowInteraction in
                recorder.values.append(allowInteraction)
                return recorder.data
            }
        )

        #expect(adapter.authorizeKeychainAccess())
        #expect(defaults.bool(forKey: "SideBarAI.claudeKeychainAccessEnabled"))
        let state = await adapter.fetch()

        guard case let .usage(snapshot) = state else {
            Issue.record("Expected Claude usage after explicit authorization, got \(state)")
            return
        }
        #expect(snapshot.windows.first?.percentUsed == 42)

        guard case .usage = await adapter.fetch() else {
            Issue.record("Expected cached Claude credentials on repeated fetch")
            return
        }
        #expect(recorder.values == [true])
    }

    @Test
    func persistedClaudeKeychainAccessReadsSilently() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let suiteName = "SideBarAITests.ClaudeKeychainCached.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "SideBarAI.claudeKeychainAccessEnabled")

        let keychainData = Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-token\"}}".utf8)
        let recorder = KeychainReaderRecorder(data: keychainData)
        let session = fixtureSession([
            "/api/oauth/usage": "{\"five_hour\":{\"utilization\":42,\"resets_at\":\"2030-01-01T00:00:00Z\"}}"
        ])
        let adapter = ClaudeUsageAdapter(
            http: UsageHTTPClient(session: session),
            credentials: LocalCredentialReader(homeDirectoryURL: home),
            defaults: defaults,
            keychainReader: { allowInteraction in
                recorder.values.append(allowInteraction)
                return recorder.data
            }
        )

        #expect(adapter.keychainAccessEnabled)
        #expect(!adapter.keychainAccessAuthorizedForRun)
        guard case .usage = await adapter.fetch() else {
            Issue.record("Expected silent Keychain read to recover Claude usage")
            return
        }
        #expect(adapter.keychainAccessAuthorizedForRun)
        #expect(recorder.values.allSatisfy { !$0 })
    }

    @Test
    func deniedSilentClaudeKeychainReadRequiresExplicitAuthorization() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let suiteName = "SideBarAITests.ClaudeKeychainDenied.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "SideBarAI.claudeKeychainAccessEnabled")

        let recorder = KeychainReaderRecorder(data: nil)
        let adapter = ClaudeUsageAdapter(
            credentials: LocalCredentialReader(homeDirectoryURL: home),
            defaults: defaults,
            keychainReader: { allowInteraction in
                recorder.values.append(allowInteraction)
                return recorder.data
            }
        )

        #expect(!adapter.isActive)
        guard case let .unavailable(message) = await adapter.fetch() else {
            Issue.record("Expected Claude Keychain access to require explicit authorization")
            return
        }
        #expect(message.contains("choose Use Keychain"))
        #expect(recorder.values.allSatisfy { !$0 })
    }

    @Test
    func disablingClaudeKeychainAccessPreventsFurtherReads() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let suiteName = "SideBarAITests.ClaudeKeychainDisabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainData = Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-token\"}}".utf8)
        let recorder = KeychainReaderRecorder(data: keychainData)
        let session = fixtureSession([
            "/api/oauth/usage": "{\"five_hour\":{\"utilization\":42,\"resets_at\":\"2030-01-01T00:00:00Z\"}}"
        ])
        let adapter = ClaudeUsageAdapter(
            http: UsageHTTPClient(session: session),
            credentials: LocalCredentialReader(homeDirectoryURL: home),
            defaults: defaults,
            keychainReader: { allowInteraction in
                recorder.values.append(allowInteraction)
                return recorder.data
            }
        )
        let store = UsageStore(
            adapters: [adapter],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60)
        )
        defer { store.shutdown() }
        await waitForRefresh(store)
        #expect(!store.claudeKeychainAuthorizedForRun)

        store.authorizeClaudeKeychain()
        await waitForRefresh(store)
        #expect(store.claudeKeychainAccessEnabled)
        #expect(store.claudeKeychainAuthorizedForRun)

        store.disableClaudeKeychainAccess()
        await waitForRefresh(store)
        guard case let .unavailable(message) = store.record(for: .claude)?.state else {
            Issue.record("Expected disabled Claude Keychain access to be unavailable")
            return
        }
        #expect(message.contains("Keychain authorization is required"))
        #expect(recorder.values == [true])
        #expect(!store.claudeKeychainAccessEnabled)
        #expect(!store.claudeKeychainAuthorizedForRun)
        #expect(!defaults.bool(forKey: "SideBarAI.claudeKeychainAccessEnabled"))
    }

    @Test
    func claudeKeychainRequiresExplicitOptIn() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let suiteName = "SideBarAITests.ClaudeKeychain.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let adapter = ClaudeUsageAdapter(
            credentials: LocalCredentialReader(homeDirectoryURL: home),
            defaults: defaults
        )
        guard case let .unavailable(message) = await adapter.fetch() else {
            Issue.record("Expected Claude without opt-in to be unavailable")
            return
        }
        #expect(message.contains("Keychain authorization is required"))
        #expect(message.contains("Use Keychain"))
    }

    @Test
    func failedExplicitClaudeKeychainAuthorizationNeverPromptsAgain() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let suiteName = "SideBarAITests.ClaudeKeychainUnavailable.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "SideBarAI.claudeKeychainAccessEnabled")

        let recorder = KeychainReaderRecorder(data: nil)
        let adapter = ClaudeUsageAdapter(
            credentials: LocalCredentialReader(homeDirectoryURL: home),
            defaults: defaults,
            keychainReader: { allowInteraction in
                recorder.values.append(allowInteraction)
                return recorder.data
            }
        )

        #expect(!adapter.authorizeKeychainAccess())
        #expect(!adapter.isActive)
        _ = await adapter.fetch()
        _ = await adapter.fetch()
        #expect(recorder.values.first == true)
        #expect(recorder.values.dropFirst().allSatisfy { !$0 })
    }

    @Test
    func expiredClaudeKeychainCredentialsDoNotAuthorizeExplicitAccess() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let suiteName = "SideBarAITests.ClaudeKeychainExpired.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainData = Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-token\",\"expiresAt\":1}}".utf8)
        let recorder = KeychainReaderRecorder(data: keychainData)
        let adapter = ClaudeUsageAdapter(
            http: UsageHTTPClient(session: fixtureSession([:])),
            credentials: LocalCredentialReader(homeDirectoryURL: home),
            defaults: defaults,
            keychainReader: { allowInteraction in
                recorder.values.append(allowInteraction)
                return recorder.data
            }
        )
        let store = UsageStore(
            adapters: [adapter],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60)
        )
        defer { store.shutdown() }
        await waitForRefresh(store)

        store.authorizeClaudeKeychain()
        await waitForRefresh(store)

        #expect(recorder.values == [true])
        #expect(!store.claudeKeychainAccessEnabled)
        #expect(!store.claudeKeychainAuthorizedForRun)
        guard case let .unavailable(message) = store.record(for: .claude)?.state else {
            Issue.record("Expected expired Claude Keychain credentials to be unavailable")
            return
        }
        #expect(message.contains("Keychain authorization is required"))
    }

    @Test
    func unauthorizedClaudeKeychainCredentialsReenableExplicitAuthorization() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let suiteName = "SideBarAITests.ClaudeKeychainUnauthorized.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainData = Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-token\"}}".utf8)
        let recorder = KeychainReaderRecorder(data: keychainData)
        let adapter = ClaudeUsageAdapter(
            http: UsageHTTPClient(session: fixtureSession(
                ["/api/oauth/usage": "{}"],
                statusCodes: ["/api/oauth/usage": 401]
            )),
            credentials: LocalCredentialReader(homeDirectoryURL: home),
            defaults: defaults,
            keychainReader: { allowInteraction in
                recorder.values.append(allowInteraction)
                return recorder.data
            }
        )
        let store = UsageStore(
            adapters: [adapter],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60)
        )
        defer { store.shutdown() }
        await waitForRefresh(store)

        store.authorizeClaudeKeychain()
        await waitForRefresh(store)

        #expect(recorder.values == [true])
        #expect(store.claudeKeychainAccessEnabled)
        #expect(!store.claudeKeychainAuthorizedForRun)
        #expect(store.keychainAuthorizationMessage?.contains("Choose Use Keychain") == true)
        guard case let .unavailable(message) = store.record(for: .claude)?.state else {
            Issue.record("Expected unauthorized Claude Keychain credentials to be unavailable")
            return
        }
        #expect(message.contains("HTTP 401"))
    }

    @Test
    func accountPresentationKeepsEveryRecordAndPutsActiveAccountFirst() {
        let records = [
            ProviderRecord(
                recordID: "claude",
                provider: .claude,
                accountLabel: "Claude Code",
                state: .authenticated(accountLabel: "Claude Code")
            ),
            ProviderRecord(
                recordID: "chatgpt:second",
                provider: .chatgpt,
                accountLabel: "second@example.com",
                state: .authenticated(accountLabel: "second@example.com")
            ),
            ProviderRecord(
                recordID: "chatgpt:active",
                provider: .chatgpt,
                accountLabel: "active@example.com",
                planLabel: "pro",
                isActive: true,
                state: .authenticated(accountLabel: "active@example.com")
            ),
            ProviderRecord(
                recordID: "chatgpt:first",
                provider: .chatgpt,
                accountLabel: "first@example.com",
                state: .authenticated(accountLabel: "first@example.com")
            )
        ]

        let ordered = ProviderRecord.presentationOrder(records)
        #expect(ordered.map(\.id) == [
            "claude",
            "chatgpt:active",
            "chatgpt:first",
            "chatgpt:second"
        ])
        #expect(Set(ordered.map(\.id)) == Set(records.map(\.id)))
        #expect(ordered.first(where: { $0.id == "chatgpt:active" })?.displayPlanLabel == "Pro")
    }
    @Test
    func providersRequiringSetupArePresentedAfterConfiguredProviders() {
        let records = [
            ProviderRecord(
                recordID: "claude",
                provider: .claude,
                state: .unavailable(message: "No credentials")
            ),
            ProviderRecord(
                recordID: "chatgpt",
                provider: .chatgpt,
                state: .usage(UsageSnapshot(
                    windows: [],
                    updatedAt: Date(),
                    accountLabel: "owner@example.com",
                    planLabel: "plus",
                    sourceLabel: "Codex"
                ))
            ),
            ProviderRecord(
                recordID: "antigravity",
                provider: .antigravity,
                state: .authenticated(accountLabel: "owner@example.com")
            )
        ]

        #expect(ProviderRecord.presentationOrder(records).map(\.id) == [
            "chatgpt",
            "antigravity",
            "claude"
        ])
    }
    @Test
    func compactRailPreservesCodexAccountsAndFiltersInactiveProviders() {
        let records = [
            ProviderRecord(
                recordID: "claude",
                provider: .claude,
                state: .unavailable(message: "No credentials")
            ),
            ProviderRecord(
                recordID: "chatgpt:unavailable",
                provider: .chatgpt,
                accountLabel: "unavailable@example.com",
                state: .unavailable(message: "Usage unavailable")
            ),
            ProviderRecord(
                recordID: "chatgpt:active",
                provider: .chatgpt,
                accountLabel: "active@example.com",
                isActive: true,
                state: .usage(UsageSnapshot(
                    windows: [],
                    updatedAt: Date(),
                    accountLabel: "active@example.com",
                    planLabel: "pro",
                    sourceLabel: "Codex"
                ))
            ),
            ProviderRecord(
                recordID: "antigravity",
                provider: .antigravity,
                state: .authenticated(accountLabel: "antigravity@example.com")
            )
        ]

        let compactRecords = ProviderRecord.compactRailOrder(records)
        #expect(compactRecords.map(\.id) == ["chatgpt:active", "antigravity", "chatgpt:unavailable"])
        #expect(!compactRecords.contains { $0.provider == .claude })
    }
    @Test
    func syncStatusRequiresCompleteVisibleUsage() {
        let snapshot = UsageSnapshot(
            windows: [],
            updatedAt: Date(),
            accountLabel: "owner@example.com",
            planLabel: "plus",
            sourceLabel: "Codex"
        )
        let usage = ProviderRecord(
            recordID: "chatgpt",
            provider: .chatgpt,
            state: .usage(snapshot)
        )
        let setup = ProviderRecord(
            recordID: "claude",
            provider: .claude,
            state: .unavailable(message: "No credentials")
        )
        let transientError = ProviderRecord(
            recordID: "antigravity:error",
            provider: .antigravity,
            hasUsableCredentials: true,
            state: .unavailable(message: "HTTP 503")
        )
        let disabled = ProviderRecord(
            recordID: "claude:disabled",
            provider: .claude,
            isEnabled: false,
            hasUsableCredentials: true,
            state: .unavailable(message: "Disabled in Settings.")
        )

        #expect(ProviderRecord.syncStatus(for: [usage, setup], isRefreshing: false) == .partial)
        #expect(ProviderRecord.syncStatus(for: [usage], isRefreshing: false) == .synced)
        #expect(ProviderRecord.syncStatus(for: [setup], isRefreshing: false) == .setup)
        #expect(ProviderRecord.syncStatus(for: [usage], isRefreshing: true) == .checking)
        #expect(!transientError.requiresSetup)
        #expect(disabled.requiresSetup)
        #expect(ProviderRecord.presentationOrder([setup, transientError]).map(\.id) == [
            "antigravity:error",
            "claude"
        ])
    }
    @Test
    func consolidatedCodexUsageUsesTotalReportedCapacity() {
        let resetDate = Date(timeIntervalSince1970: 1_800_000_000)
        let makeRecord = { (id: String, account: String, used: Double, plan: String) in
            ProviderRecord(
                recordID: id,
                provider: .chatgpt,
                accountLabel: account,
                planLabel: plan,
                state: .usage(UsageSnapshot(
                    windows: [UsageWindow(
                        id: "primary",
                        label: "5-hour window",
                        used: used,
                        limit: 100,
                        unit: .percent,
                        resetDate: resetDate,
                        providerReportedPercentage: true,
                        periodSeconds: 18_000
                    )],
                    updatedAt: resetDate,
                    accountLabel: account,
                    planLabel: plan,
                    sourceLabel: "Codex"
                ))
            )
        }
        let records = [
            makeRecord("chatgpt:one", "one@example.com", 20, "plus"),
            makeRecord("chatgpt:two", "two@example.com", 40, "plus"),
            makeRecord("chatgpt:three", "three@example.com", 80, "plus")
        ]

        let consolidated = ProviderRecord.consolidatedCodexPresentation(records)
        #expect(consolidated.count == 1)
        guard case let .usage(snapshot) = consolidated.first?.state,
              let window = snapshot.windows.first else {
            Issue.record("Expected consolidated Codex usage")
            return
        }

        #expect(snapshot.accountLabel == "All Codex accounts · 3")
        #expect(snapshot.planLabel == "plus")
        #expect(window.used == 140)
        #expect(window.limit == 300)
        #expect(abs((window.percentUsed ?? -1) - (140.0 / 300.0 * 100)) < 0.001)
        #expect(window.periodSeconds == 18_000)
        #expect(window.resetDate == resetDate)
    }

    @Test
    func consolidatedCodexUsageExcludesMissingWindowsFromDenominator() {
        let makeWindow = { (id: String, label: String, used: Double, limit: Double, period: Double?) in
            UsageWindow(
                id: id,
                label: label,
                used: used,
                limit: limit,
                unit: .percent,
                resetDate: nil,
                providerReportedPercentage: true,
                periodSeconds: period
            )
        }
        let makeRecord = { (id: String, windows: [UsageWindow]) in
            ProviderRecord(
                recordID: id,
                provider: .chatgpt,
                state: .usage(UsageSnapshot(
                    windows: windows,
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    accountLabel: id,
                    planLabel: "pro",
                    sourceLabel: "Codex"
                ))
            )
        }
        let records = [
            makeRecord("chatgpt:one", [
                makeWindow("primary", "5-hour window", 20, 100, 18_000),
                makeWindow("secondary", "7-day window", 50, 100, 604_800)
            ]),
            makeRecord("chatgpt:two", [makeWindow("primary", "5-hour window", 60, 100, 18_000)]),
            makeRecord("chatgpt:three", [makeWindow("primary", "5-hour window", 0, 100, 18_000)])
        ]

        let consolidated = ProviderRecord.consolidatedCodexPresentation(records)
        guard case let .usage(snapshot) = consolidated.first?.state,
              let primary = snapshot.windows.first(where: { $0.id == "primary" }),
              let secondary = snapshot.windows.first(where: { $0.id == "secondary" }) else {
            Issue.record("Expected reported Codex windows")
            return
        }

        #expect(abs((primary.percentUsed ?? -1) - (80.0 / 300.0 * 100)) < 0.001)
        #expect(primary.label == "5-hour window")
        #expect(secondary.percentUsed == 50)
        #expect(secondary.label == "7-day window · 1/3 accounts")
    }

    @Test
    func consolidatedCodexUsageSeparatesMixedWindowPeriods() {
        let makeRecord = { (id: String, used: Double, label: String, period: Double) in
            ProviderRecord(
                recordID: id,
                provider: .chatgpt,
                state: .usage(UsageSnapshot(
                    windows: [UsageWindow(
                        id: "primary",
                        label: label,
                        used: used,
                        limit: 100,
                        unit: .percent,
                        resetDate: nil,
                        providerReportedPercentage: true,
                        periodSeconds: period
                    )],
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    accountLabel: id,
                    planLabel: "plus",
                    sourceLabel: "Codex"
                ))
            )
        }
        let records = [
            makeRecord("chatgpt:one", 50, "5-hour window", 18_000),
            makeRecord("chatgpt:two", 25, "5-hour window", 18_000),
            makeRecord("chatgpt:three", 75, "7-day window", 604_800)
        ]

        let consolidated = ProviderRecord.consolidatedCodexPresentation(records)
        guard case let .usage(snapshot) = consolidated.first?.state else {
            Issue.record("Expected consolidated Codex usage with mixed periods")
            return
        }
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.first(where: { $0.periodSeconds == 18_000 })?.percentUsed == 37.5)
        #expect(snapshot.windows.first(where: { $0.periodSeconds == 604_800 })?.percentUsed == 75)
        #expect(snapshot.windows.first(where: { $0.periodSeconds == 604_800 })?.label == "7-day window · 1/3 accounts")
    }

    @Test
    func consolidatedCodexUsageFallsBackForInvalidWindowPeriods() {
        let makeRecord = { (id: String, used: Double, period: Double) in
            ProviderRecord(
                recordID: id,
                provider: .chatgpt,
                state: .usage(UsageSnapshot(
                    windows: [UsageWindow(
                        id: "primary",
                        label: "5-hour window",
                        used: used,
                        limit: 100,
                        unit: .percent,
                        resetDate: nil,
                        providerReportedPercentage: true,
                        periodSeconds: period
                    )],
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    accountLabel: id,
                    planLabel: "plus",
                    sourceLabel: "Codex"
                ))
            )
        }
        let records = [
            makeRecord("chatgpt:one", 40, .infinity),
            makeRecord("chatgpt:two", 60, -1)
        ]

        let consolidated = ProviderRecord.consolidatedCodexPresentation(records)
        guard case let .usage(snapshot) = consolidated.first?.state,
              let window = snapshot.windows.first else {
            Issue.record("Expected consolidated Codex usage with invalid periods")
            return
        }
        #expect(window.periodSeconds == nil)
        #expect(window.label == "5-hour window")
        #expect(window.percentUsed == 50)
    }

    @Test
    func consolidateCodexUsageSettingPersistsAndChangesPresentation() async {
        let suiteName = "SideBarAITests.ConsolidateCodex.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = UsageSnapshot(
            windows: [UsageWindow(
                id: "primary",
                label: "5-hour window",
                used: 25,
                limit: 100,
                unit: .percent,
                resetDate: nil,
                providerReportedPercentage: true,
                periodSeconds: 18_000
            )],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            accountLabel: nil,
            planLabel: "plus",
            sourceLabel: "Codex"
        )
        let adapters: [any UsageProviderAdapter] = [
            StubAdapter(provider: .chatgpt, recordID: "chatgpt:one", accountLabel: "one", isActive: true, planLabel: "plus", state: .usage(snapshot)),
            StubAdapter(provider: .chatgpt, recordID: "chatgpt:two", accountLabel: "two", planLabel: "plus", state: .usage(snapshot)),
            StubAdapter(provider: .chatgpt, recordID: "chatgpt:three", accountLabel: "three", planLabel: "plus", state: .usage(snapshot))
        ]
        let store = UsageStore(adapters: adapters, defaults: defaults, refreshInterval: nil)
        defer { store.shutdown() }
        await settle()

        #expect(!store.consolidateCodexUsage)
        #expect(store.records(for: .chatgpt).count == 3)
        #expect(store.presentationRecords.count == 3)

        store.setConsolidateCodexUsage(true)
        #expect(store.consolidateCodexUsage)
        #expect(store.records(for: .chatgpt).count == 3)
        #expect(store.presentationRecords.count == 1)
        #expect(store.presentationRecords.first?.id == "chatgpt:consolidated")
        #expect(defaults.bool(forKey: "SideBarAI.consolidateCodexUsage"))

        let reloadedStore = UsageStore(adapters: adapters, defaults: defaults, refreshInterval: nil)
        defer { reloadedStore.shutdown() }
        #expect(reloadedStore.consolidateCodexUsage)
        #expect(reloadedStore.presentationRecords.count == 1)
    }

    @Test
    func accountPlanLabelsNormalizeKnownCodexTiers() {
        #expect(AccountPlanLabel.displayName(for: "free") == "Free")
        #expect(AccountPlanLabel.displayName(for: "chatgpt_go") == "Go")
        #expect(AccountPlanLabel.displayName(for: "PLUS") == "Plus")
        #expect(AccountPlanLabel.displayName(for: "chatgpt-pro") == "Pro")
        #expect(AccountPlanLabel.displayName(for: "enterprise") == "Enterprise")
        #expect(AccountPlanLabel.displayName(for: "custom_tier") == "Custom Tier")
        #expect(AccountPlanLabel.displayName(for: "  ") == nil)

        let unavailableRecord = ProviderRecord(
            recordID: "chatgpt:plus",
            provider: .chatgpt,
            planLabel: "plus",
            state: .unavailable(message: "Usage unavailable")
        )
        #expect(unavailableRecord.displayPlanLabel == "Plus")

        let noPlanRecord = ProviderRecord(
            recordID: "chatgpt:unknown",
            provider: .chatgpt,
            state: .unavailable(message: "Usage unavailable")
        )
        #expect(noPlanRecord.planStatusLabel == "Plan unavailable")
    }

    @Test
    func codexCredentialFailuresExplainRecovery() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = LocalCredentialReader(homeDirectoryURL: home)
        let adapter = CodexUsageAdapter(credentials: reader)
        #expect(!adapter.isActive)

        guard case let .unavailable(missingMessage) = await adapter.fetch() else {
            Issue.record("Expected missing Codex credentials to be unavailable")
            return
        }
        #expect(missingMessage.contains("Credential file not found"))
        #expect(missingMessage.contains("codex login"))

        try write("not-json", to: home.appendingPathComponent(".codex/auth.json"))
        guard case let .unavailable(unreadableMessage) = await adapter.fetch() else {
            Issue.record("Expected malformed Codex credentials to be unavailable")
            return
        }
        #expect(unreadableMessage.contains("Credential JSON unreadable"))

        try write("{\"tokens\":{}}", to: home.appendingPathComponent(".codex/auth.json"))
        guard case let .unavailable(tokenMessage) = await adapter.fetch() else {
            Issue.record("Expected tokenless Codex credentials to be unavailable")
            return
        }
        #expect(tokenMessage.contains("no usable access token"))

        #expect(ProviderFailureMessage.transport(.unauthorized, provider: "Codex", command: "codex login").contains("HTTP 401"))
        #expect(ProviderFailureMessage.transport(.forbidden, provider: "Codex", command: "codex login").contains("HTTP 403"))
        #expect(ProviderFailureMessage.transport(.invalidPayload, provider: "Codex", command: "codex login").contains("payload changed"))
    }

    @Test
    func codexAuthRegistryProducesIndependentLiveRecords() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let firstKey = "account-one"
        let secondKey = "account-two"
        try write(
            "{\"schema_version\":3,\"active_account_key\":\"account-two\",\"accounts\":[{\"account_key\":\"account-one\",\"email\":\"one@example.com\",\"alias\":\"Work\",\"chatgpt_account_id\":\"chat-one\",\"plan\":\"plus\"},{\"account_key\":\"account-two\",\"email\":\"two@example.com\",\"alias\":\"\",\"chatgpt_account_id\":\"chat-two\",\"plan\":\"pro\"}]}",
            to: home.appendingPathComponent(".codex/accounts/registry.json")
        )
        try write(
            "{\"tokens\":{\"access_token\":\"token-one\",\"account_id\":\"chat-one\"}}",
            to: home.appendingPathComponent(".codex/accounts/\(codexAuthFilename(for: firstKey)).auth.json")
        )
        try write(
            "{\"tokens\":{\"access_token\":\"token-two\",\"account_id\":\"chat-two\"}}",
            to: home.appendingPathComponent(".codex/accounts/\(codexAuthFilename(for: secondKey)).auth.json")
        )

        let reader = LocalCredentialReader(homeDirectoryURL: home)
        let accounts = CodexAccount.discover(credentials: reader)
        #expect(accounts.count == 2)
        #expect(accounts.filter(\.isActive).count == 1)
        #expect(accounts.first(where: { $0.accountKey == firstKey })?.accountLabel == "Work")
        #expect(accounts.first(where: { $0.accountKey == secondKey })?.isActive == true)

        let factoryCodexAdapters = DefaultUsageAdapters.make(credentials: reader).filter { $0.provider == .chatgpt }
        #expect(factoryCodexAdapters.count == 2)
        #expect(factoryCodexAdapters.map(\.planLabel) == ["plus", "pro"])

        let session = fixtureSession([
            "/backend-api/wham/usage": "{\"plan_type\":\"pro\",\"rate_limit\":{\"primary_window\":{\"used_percent\":15,\"reset_at\":1735401600,\"limit_window_seconds\":18000}}}"
        ])
        let codexAdapters: [any UsageProviderAdapter] = accounts.map {
            CodexUsageAdapter(account: $0, http: UsageHTTPClient(session: session), credentials: reader)
        }
        let adapters: [any UsageProviderAdapter] = codexAdapters + [
            StubAdapter(provider: .claude, state: .unavailable(message: "No credentials")),
            StubAdapter(provider: .antigravity, state: .unavailable(message: "No credentials"))
        ]
        let store = UsageStore(adapters: adapters)

        await waitForRefresh(store)

        let codexRecords = store.records(for: .chatgpt)
        #expect(codexRecords.count == 2)
        #expect(codexRecords.filter(\.isActive).count == 1)
        #expect(codexRecords.allSatisfy { if case .usage = $0.state { true } else { false } })
        #expect(Set(FixtureURLProtocol.authorizationHeaders) == ["Bearer token-one", "Bearer token-two"])
        #expect(Set(FixtureURLProtocol.accountHeaders) == ["chat-one", "chat-two"])
    }

    @Test
    func activeCodexAccountUsesFreshLegacyLoginFile() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let accountKey = "active-account"

        try write(
            """
            {"schema_version":3,"active_account_key":"active-account","accounts":[{"account_key":"active-account","email":"active@example.com","chatgpt_account_id":"chat-active","plan":"plus"}]}
            """,
            to: home.appendingPathComponent(".codex/accounts/registry.json")
        )
        try write(
            """
            {"tokens":{"access_token":"stale-token","account_id":"chat-active"}}
            """,
            to: home.appendingPathComponent(".codex/accounts/\(codexAuthFilename(for: accountKey)).auth.json")
        )
        try write(
            """
            {"tokens":{"access_token":"fresh-token","account_id":"chat-active"}}
            """,
            to: home.appendingPathComponent(".codex/auth.json")
        )

        let reader = LocalCredentialReader(homeDirectoryURL: home)
        guard let account = CodexAccount.discover(credentials: reader).first else {
            Issue.record("Expected active Codex account")
            return
        }

        let session = fixtureSession([
            "/backend-api/wham/usage": """
            {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":15,"reset_at":1735401600,"limit_window_seconds":18000}}}
            """
        ])
        let adapter = CodexUsageAdapter(
            account: account,
            http: UsageHTTPClient(session: session),
            credentials: reader
        )

        guard case .usage = await adapter.fetch() else {
            Issue.record("Expected refreshed Codex credentials to authorize usage")
            return
        }
        #expect(FixtureURLProtocol.authorizationHeaders == ["Bearer fresh-token"])
        #expect(FixtureURLProtocol.accountHeaders == ["chat-active"])
    }

    @Test
    func ompUsageJSONMapsCodexReport() throws {
        let data = Data(
            #"""
            {"generatedAt":1788335268904,"reports":[{"provider":"openai-codex","fetchedAt":1788335266190,"limits":[{"id":"openai-codex:primary","label":"5 hours","window":{"durationMs":18000000,"resetsAt":1788339647000},"amount":{"used":74,"limit":100,"usedFraction":0.74,"unit":"percent"},"status":"ok"},{"id":"openai-codex:secondary","label":"7 days","window":{"durationMs":604800000,"resetsAt":1788747866000},"amount":{"used":18,"limit":100,"usedFraction":0.18,"unit":"percent"},"status":"ok"}],"metadata":{"planType":"plus","allowed":true,"email":"owner@example.com","accountId":"account-123"}}]}
            """#.utf8
        )
        let account = CodexAccount(
            accountKey: "active",
            accountLabel: "owner@example.com",
            email: "owner@example.com",
            isActive: true,
            chatgptAccountID: "account-123",
            planLabel: "plus"
        )

        guard let snapshot = try OMPUsageParser.parse(data).reports.first?.snapshot(for: account) else {
            Issue.record("Expected OMP Codex report to match account")
            return
        }
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.first?.label == "5 hours")
        #expect(snapshot.windows.first?.used == 74)
        #expect(snapshot.windows.first?.periodSeconds == 18_000)
        #expect(snapshot.windows[1].percentUsed == 18)
        #expect(snapshot.planLabel == "plus")
        #expect(snapshot.sourceLabel == "OMP usage --json")
    }

    @Test
    func ompUsageJSONKeepsWarningCodexWindow() throws {
        let data = Data(
            #"""
            {"reports":[{"provider":"openai-codex","limits":[{"id":"openai-codex:primary","label":"5 hours","window":{"durationMs":18000000,"resetsAt":1788339647000},"amount":{"used":94,"limit":100,"unit":"percent"},"status":"warning"}],"metadata":{"planType":"plus","email":"owner@example.com","accountId":"account-123"}}]}
            """#.utf8
        )
        let account = CodexAccount(
            accountKey: "active",
            accountLabel: "owner@example.com",
            email: "owner@example.com",
            isActive: true,
            chatgptAccountID: "account-123",
            planLabel: "plus"
        )

        guard let snapshot = try OMPUsageParser.parse(data).reports.first?.snapshot(for: account) else {
            Issue.record("Expected warning Codex usage report to match account")
            return
        }
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.label == "5 hours")
        #expect(snapshot.windows.first?.used == 94)
        #expect(snapshot.windows.first?.percentUsed == 94)
    }

    @Test
    func codexAdapterFallsBackToOMPUsageJSONAfterDirectFailure() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            #"""
            {"schema_version":3,"active_account_key":"active-account","accounts":[{"account_key":"active-account","email":"owner@example.com","chatgpt_account_id":"account-123","plan":"plus"}]}
            """#,
            to: home.appendingPathComponent(".codex/accounts/registry.json")
        )
        try write(
            #"""
            {"tokens":{"access_token":"direct-token","account_id":"account-123"}}
            """#,
            to: home.appendingPathComponent(".codex/auth.json")
        )

        let ompData = Data(
            #"""
            {"reports":[{"provider":"openai-codex","fetchedAt":1788335266190,"limits":[{"id":"openai-codex:primary","label":"5 hours","window":{"durationMs":18000000,"resetsAt":1788339647000},"amount":{"used":74,"limit":100,"unit":"percent"},"status":"ok"}],"metadata":{"planType":"plus","email":"owner@example.com","accountId":"account-123"}}]}
            """#.utf8
        )
        let source = OMPUsageSource(
            runner: StubUsageCommandRunner(data: ompData),
            modelUsageSource: OMPModelUsageSource(sessionsDirectory: home, cacheLifetime: 0),
            cacheLifetime: 60
        )
        let session = fixtureSession(
            ["/backend-api/wham/usage": "{}"],
            statusCodes: ["/backend-api/wham/usage": 401]
        )
        let reader = LocalCredentialReader(homeDirectoryURL: home)
        guard let account = CodexAccount.discover(credentials: reader).first else {
            Issue.record("Expected active Codex account")
            return
        }
        let adapter = CodexUsageAdapter(
            account: account,
            http: UsageHTTPClient(session: session),
            credentials: reader,
            ompUsageSource: source
        )

        guard case let .usage(snapshot) = await adapter.fetch() else {
            Issue.record("Expected OMP usage fallback after direct 401")
            return
        }
        #expect(snapshot.windows.first?.used == 74)
        #expect(snapshot.sourceLabel == "OMP usage --json")
        #expect(FixtureURLProtocol.authorizationHeaders == ["Bearer direct-token"])
    }

    @Test
    func codexAdapterMapsWhamUsageWindows() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Real ChatGPT ID tokens use a "+00:00" offset for the paid-through date.
        let claims = #"{"https://api.openai.com/auth":{"chatgpt_subscription_active_until":"2030-10-17T01:41:06+00:00"}}"#
        let idToken = "e30." + Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") + ".sig"
        try write(
            "{\"tokens\":{\"access_token\":\"fixture-token\",\"account_id\":\"account-123\",\"id_token\":\"\(idToken)\"}}",
            to: home.appendingPathComponent(".codex/auth.json")
        )

        let session = fixtureSession([
            "/backend-api/wham/usage": """
            {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":15,"reset_at":1735401600,"limit_window_seconds":18000},"secondary_window":{"used_percent":5,"reset_at":1735920000,"limit_window_seconds":604800}}}
            """
        ])
        let adapter = CodexUsageAdapter(
            http: UsageHTTPClient(session: session),
            credentials: LocalCredentialReader(homeDirectoryURL: home)
        )
        #expect(adapter.isActive)
        let state = await adapter.fetch()

        guard case let .usage(snapshot) = state else {
            Issue.record("Expected Codex usage snapshot, got \(state)")
            return
        }
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.first?.percentUsed == 15)
        #expect(snapshot.windows.first?.label == "5-hour window")
        #expect(snapshot.planLabel == "pro")
        #expect(AccountPlanLabel.displayName(for: snapshot.planLabel) == "Pro")
        let renewal = try #require(snapshot.subscriptionRenewsAt)
        #expect(renewal == Date(timeIntervalSince1970: 1_918_431_666))
        #expect(snapshot.subscriptionRenewalLabel(now: renewal.addingTimeInterval(-1)) != nil)
        // The claim only refreshes at login, so a passed date is stale and hidden.
        #expect(snapshot.subscriptionRenewalLabel(now: renewal) == nil)
    }

    @Test
    func claudeAdapterMapsOAuthUsageWindows() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            "{\"claudeAiOauth\":{\"accessToken\":\"fixture-token\"}}",
            to: home.appendingPathComponent(".claude/.credentials.json")
        )

        let session = fixtureSession([
            "/api/oauth/usage": """
            {"five_hour":{"utilization":73,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":7,"resets_at":"2030-01-07T00:00:00Z"}}
            """
        ])
        let adapter = ClaudeUsageAdapter(
            http: UsageHTTPClient(session: session),
            credentials: LocalCredentialReader(homeDirectoryURL: home)
        )
        #expect(adapter.isActive)
        let state = await adapter.fetch()

        guard case let .usage(snapshot) = state else {
            Issue.record("Expected Claude usage snapshot, got \(state)")
            return
        }
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.first?.percentUsed == 73)
        #expect(snapshot.windows.first?.label == "5-hour session")
    }

    @Test
    func claudeAdapterDoesNotResendRejectedToken() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let credentialsURL = home.appendingPathComponent(".claude/.credentials.json")
        try write("{\"claudeAiOauth\":{\"accessToken\":\"revoked-token\"}}", to: credentialsURL)

        let session = fixtureSession(
            ["/api/oauth/usage": "{}"],
            statusCodes: ["/api/oauth/usage": 401]
        )
        let adapter = ClaudeUsageAdapter(
            http: UsageHTTPClient(session: session),
            credentials: LocalCredentialReader(homeDirectoryURL: home)
        )
        _ = await adapter.fetch()
        guard case .unavailable = await adapter.fetch() else {
            Issue.record("Expected rejected Claude token to stay unavailable")
            return
        }
        #expect(FixtureURLProtocol.authorizationHeaders == ["Bearer revoked-token"])

        try write("{\"claudeAiOauth\":{\"accessToken\":\"rotated-token\"}}", to: credentialsURL)
        _ = await adapter.fetch()
        #expect(FixtureURLProtocol.authorizationHeaders == ["Bearer revoked-token", "Bearer rotated-token"])
    }


    @Test
    func ompUsageDoesNotMatchConflictingAccountIDsWithSameEmail() throws {
        let reportJSON = """
        {
          "provider": "openai-codex",
          "metadata": {
            "accountId": "account-A",
            "email": "user@example.com"
          },
          "limits": []
        }
        """
        let report = try JSONDecoder().decode(OMPUsageReport.self, from: Data(reportJSON.utf8))
        let conflictingAccount = CodexAccount(
            accountKey: "account-B",
            accountLabel: "user@example.com",
            email: "user@example.com",
            isActive: true,
            chatgptAccountID: "account-B"
        )
        #expect(report.snapshot(for: conflictingAccount) == nil)
    }

    @Test
    func usageTransportNormalizesCancelledURLErrorToCancellationError() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CancellingURLProtocol.self]
        let client = UsageHTTPClient(session: URLSession(configuration: config))

        struct DummyResponse: Decodable {}

        do {
            _ = try await client.getJSON(URL(string: "https://api.example.com/test")!, headers: [:]) as DummyResponse
            #expect(Bool(false), "Expected CancellationError to be thrown")
        } catch is CancellationError {
            #expect(Bool(true))
        } catch {
            #expect(Bool(false), "Expected CancellationError but caught: \\(error)")
        }
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

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SideBarAI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ content: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func codexAuthFilename(for accountKey: String) -> String {
        var encoded = Data(accountKey.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while encoded.last == "=" {
            encoded.removeLast()
        }
        return encoded
    }

    private func fixtureSession(
        _ fixtures: [String: String],
        statusCodes: [String: Int] = [:]
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        FixtureURLProtocol.fixtures = fixtures.mapValues { Data($0.utf8) }
        FixtureURLProtocol.statusCodes = statusCodes
        FixtureURLProtocol.authorizationHeaders = []
        FixtureURLProtocol.accountHeaders = []
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct StubAdapter: UsageProviderAdapter {
    let provider: Provider
    let customRecordID: String?
    let customAccountLabel: String?
    let customIsActive: Bool
    let customPlanLabel: String?
    let state: ProviderState

    var recordID: String { customRecordID ?? provider.rawValue }
    var accountLabel: String? { customAccountLabel }
    var isActive: Bool { customIsActive }
    var planLabel: String? { customPlanLabel }

    init(
        provider: Provider,
        recordID: String? = nil,
        accountLabel: String? = nil,
        isActive: Bool = false,
        planLabel: String? = nil,
        state: ProviderState
    ) {
        self.provider = provider
        self.customRecordID = recordID
        self.customAccountLabel = accountLabel
        self.customIsActive = isActive
        self.customPlanLabel = planLabel
        self.state = state
    }

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

private struct CountingAdapter: UsageProviderAdapter {
    let provider: Provider
    let counter: FetchCounter
    let state: ProviderState

    func fetch() async -> ProviderState {
        await counter.increment()
        return state
    }
}

private final class KeychainReaderRecorder: @unchecked Sendable {
    let data: Data?
    var values: [Bool] = []

    init(data: Data?) {
        self.data = data
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixtures: [String: Data] = [:]
    nonisolated(unsafe) static var authorizationHeaders: [String] = []
    nonisolated(unsafe) static var accountHeaders: [String] = []
    nonisolated(unsafe) static var statusCodes: [String: Int] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
            Self.authorizationHeaders.append(authorization)
        }
        if let account = request.value(forHTTPHeaderField: "ChatGPT-Account-Id") {
            Self.accountHeaders.append(account)
        }

        guard let url = request.url,
              let data = Self.fixtures[url.path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: Self.statusCodes[url.path] ?? 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CancellingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}

private struct StubUsageCommandRunner: UsageCommandRunning {
    let data: Data

    func run() async throws -> Data {
        data
    }
}
