import Foundation
import Testing
@testable import SideBarAI

struct CodexRegressionTests {
    @Test
    func discoverySeparatesUsersWorkspacesAndProjects() async throws {
        let rows = [
            report(email: "alice@example.com", accountID: "shared", organizationID: "org-one", projectID: "project-one", used: 10),
            report(email: "bob@example.com", accountID: "shared", organizationID: "org-one", projectID: "project-one", used: 20),
            report(email: "alice@example.com", accountID: "shared", organizationID: "org-two", projectID: "project-one", used: 30),
            report(email: "alice@example.com", accountID: "shared", organizationID: "org-one", projectID: "project-two", used: 40)
        ]
        let source = source(data: try document(rows))
        let accounts = try await source.codexAccounts()
        #expect(accounts.count == 4)
        #expect(Set(accounts.map(\.recordID)).count == 4)
        #expect(accounts.allSatisfy { !$0.isActive })
        for account in accounts {
            let snapshot = try #require(await source.snapshot(for: account))
            let expected: Double = account.email == "bob@example.com" ? 20
                : account.organizationID == "org-two" ? 30
                : account.projectID == "project-two" ? 40 : 10
            #expect(snapshot.windows.first?.used == expected)
            #expect(snapshot.accountLabel == account.accountLabel)
        }
    }

    @Test
    func identitySurvivesReorderingPlanAndDisplayNameChanges() async throws {
        let first = report(email: "Alice@Example.com", accountID: "account", organizationID: "org", plan: "plus", orgName: "Old name")
        let second = report(email: "bob@example.com", accountID: "other")
        let changed = report(email: " alice@example.com ", accountID: "account", organizationID: "org", plan: "pro", orgName: "New name")
        let before = try await source(data: document([first, second])).codexAccounts()
        let after = try await source(data: document([second, changed])).codexAccounts()
        #expect(before.map(\.recordID) == after.map(\.recordID))
        let aliceBefore = try #require(before.first { $0.email == "alice@example.com" })
        let aliceAfter = try #require(after.first { $0.email == "alice@example.com" })
        #expect(aliceBefore.accountKey == aliceAfter.accountKey)
        #expect(aliceBefore.accountLabel != aliceAfter.accountLabel)
        #expect(aliceAfter.planLabel == "pro")
    }

    @Test
    func matchingNeverFallsBackAcrossConflictingOrMissingIdentityComponents() throws {
        let account = try #require(OMPUsageParser.parse(document([
            report(email: "alice@example.com", accountID: "shared", organizationID: "org", projectID: "project")
        ])).codexAccounts().first)
        let mismatches = [
            report(email: "bob@example.com", accountID: "shared", organizationID: "org", projectID: "project"),
            report(email: "alice@example.com", accountID: "other", organizationID: "org", projectID: "project"),
            report(email: "alice@example.com", accountID: "shared", organizationID: "other", projectID: "project"),
            report(email: "alice@example.com", accountID: "shared", organizationID: "org", projectID: "other"),
            report(email: "alice@example.com", accountID: "shared", projectID: "project"),
            report(email: "alice@example.com", organizationID: "org", projectID: "project")
        ]
        for row in mismatches {
            let parsed = try #require(OMPUsageParser.parse(document([row])).reports.first)
            #expect(!parsed.matches(account))
            #expect(parsed.snapshot(for: account) == nil)
        }
    }

    @Test
    func missingUsageAccountsRemainDiscoveredAndBecomeUnavailable() async throws {
        let data = try document([], unreported: [[
            "provider": "openai-codex", "type": "oauth", "email": "alice@example.com",
            "accountId": "account", "orgId": "org", "orgName": "Workspace"
        ]])
        let source = source(data: data)
        let adapters = try await DefaultUsageAdapters.makeCodex(ompUsageSource: source)
        let adapter = try #require(adapters.first)
        #expect(adapters.count == 1)
        #expect(!adapter.isActive)
        #expect(adapter.hasUsableCredentials)
        guard case let .unavailable(message) = await adapter.fetch() else {
            Issue.record("Missing quota should be unavailable, not fabricated usage")
            return
        }
        #expect(message.contains("no usable Codex usage"))
        #expect(message.contains("/login"))
    }

    @Test
    func duplicateIdentityUsesNewestReportWithoutCombiningQuotas() async throws {
        let older = report(email: "alice@example.com", accountID: "account", used: 10, fetchedAt: 1_700_000_000_000)
        let newer = report(email: "alice@example.com", accountID: "account", used: 20, fetchedAt: 1_700_000_100_000)
        let source = source(data: try document([older, newer]))
        let accounts = try await source.codexAccounts()
        let account = try #require(accounts.first)
        #expect(accounts.count == 1)
        let snapshot = try #require(await source.snapshot(for: account))
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.used == 20)
    }

    @Test
    func successfulEmptyAndOtherProvidersHaveNoCodexAccounts() async throws {
        let empty = try await source(data: document([])).codexAccounts()
        #expect(empty.isEmpty)
        let other = try await source(data: document([["provider": "anthropic", "limits": []]])).codexAccounts()
        #expect(other.isEmpty)
        let adapters = try await DefaultUsageAdapters.makeCodex(ompUsageSource: source(data: document([])))
        #expect(adapters.isEmpty)
    }

    @Test(arguments: [
        "not json", "{}", #"{"reports":null}"#,
        #"{"reports":[null]}"#,
        #"{"reports":[{"provider":"openai-codex","metadata":{"accountId":42}}]}"#,
        #"{"reports":[{"provider":"openai-codex","metadata":{"orgId":"workspace-only"}}]}"#,
        #"{"reports":[],"accountsWithoutUsage":[{"provider":"openai-codex","email":42}]}"#,
        #"{"reports":[],"accountsWithoutUsage":[{"provider":"openai-codex"}]}"#
    ])
    func malformedDiscoveryIsAnErrorNotAnEmptyLogout(json: String) async {
        do {
            _ = try await source(data: Data(json.utf8)).codexAccounts()
            Issue.record("Malformed identity output must not masquerade as an empty account pool")
        } catch {
            #expect(error as? UsageCommandError == .invalidOutput)
        }
    }

    @Test
    func failedCommandIsNotEmptyAndCanRecoverWithStableIdentity() async throws {
        let data = try document([report(email: "alice@example.com", accountID: "account")])
        let runner = CodexReportRunner(results: [.success(data), .failure(.commandFailed(7)), .success(data)])
        let source = source(runner: runner, cacheLifetime: 0)
        let before = try await source.codexAccounts()
        do {
            _ = try await source.codexAccounts()
            Issue.record("A failed command must throw, not remove known accounts")
        } catch {
            #expect(error as? UsageCommandError == .commandFailed(7))
        }
        let after = try await source.codexAccounts()
        #expect(before == after)
    }

    @Test
    func adapterPreservesSalvagedWindowsResetsAndSourceWithoutDirectAuth() async throws {
        var row = report(email: "alice@example.com", accountID: "account", plan: "pro")
        row["limits"] = [
            ["id": "broken", "amount": ["used": "invalid", "limit": 100, "unit": "percent"]],
            ["id": "weekly", "label": "Weekly", "window": ["durationMs": 604_800_000, "resetsAt": 1_700_001_000_000],
             "amount": ["usedFraction": 0.25, "limit": 1, "unit": "percent"], "status": "exhausted"]
        ]
        row["resetCredits"] = ["availableCount": 3]
        let runner = CodexReportRunner(results: [.success(try document([row]))])
        let source = source(runner: runner)
        let adapters = try await DefaultUsageAdapters.makeCodex(ompUsageSource: source)
        let adapter = try #require(adapters.first)
        guard case let .usage(snapshot) = await adapter.fetch() else {
            Issue.record("Expected quota directly from OMP")
            return
        }
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.used == 25)
        #expect(snapshot.windows.first?.limit == 100)
        #expect(snapshot.windows.first?.periodSeconds == 604_800)
        #expect(snapshot.windows.first?.resetDate == Date(timeIntervalSince1970: 1_700_001_000))
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snapshot.savedResetCount == 3)
        #expect(snapshot.planLabel == "pro")
        #expect(snapshot.sourceLabel == "OMP usage --json")
        #expect(await runner.callCount == 1)
    }

    @Test(arguments: [UsageCommandError.executableNotFound, .timedOut, .invalidOutput, .outputTooLarge, .commandFailed(9)])
    func adapterDisplaysMeaningfulCommandFailures(error: UsageCommandError) async {
        let source = source(runner: CodexReportRunner(results: [.failure(error)]))
        let adapter = CodexUsageAdapter(account: CodexAccount(accountKey: "fixture"), ompUsageSource: source)
        guard case let .unavailable(message) = await adapter.fetch() else {
            Issue.record("Expected a visible OMP failure")
            return
        }
        #expect(message == CodexUsageAdapter.failureMessage(for: error))
        #expect(message.contains("OMP"))
        #expect(!message.contains("auth.json"))
    }

    private func report(
        email: String? = nil,
        accountID: String? = nil,
        organizationID: String? = nil,
        projectID: String? = nil,
        used: Double = 10,
        fetchedAt: Double = 1_700_000_000_000,
        plan: String = "plus",
        orgName: String? = nil
    ) -> [String: Any] {
        var metadata: [String: Any] = ["planType": plan]
        metadata["email"] = email
        metadata["accountId"] = accountID
        metadata["orgId"] = organizationID
        metadata["projectId"] = projectID
        metadata["orgName"] = orgName
        return [
            "provider": "openai-codex", "fetchedAt": fetchedAt, "metadata": metadata,
            "limits": [["id": "primary", "amount": ["used": used, "limit": 100, "unit": "percent"]]]
        ]
    }

    private func document(_ reports: [[String: Any]], unreported: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["reports": reports, "accountsWithoutUsage": unreported])
    }

    private func source(data: Data) -> OMPUsageSource {
        source(runner: CodexReportRunner(results: [.success(data)]))
    }

    private func source(runner: any UsageCommandRunning, cacheLifetime: TimeInterval = 60) -> OMPUsageSource {
        // No test reads real OMP sessions or credentials.
        OMPUsageSource(
            runner: runner,
            modelUsageSource: OMPModelUsageSource(sessionsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            cacheLifetime: cacheLifetime
        )
    }
}

private actor CodexReportRunner: UsageCommandRunning {
    private var results: [Result<Data, UsageCommandError>]
    private(set) var callCount = 0

    init(results: [Result<Data, UsageCommandError>]) {
        self.results = results
    }

    func run() async throws -> Data {
        callCount += 1
        guard !results.isEmpty else { throw UsageCommandError.invalidOutput }
        let result = results.count > 1 ? results.removeFirst() : results[0]
        return try result.get()
    }
}
