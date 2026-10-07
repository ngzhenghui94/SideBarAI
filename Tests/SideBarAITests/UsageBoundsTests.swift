import Darwin
import Foundation
import Testing
@testable import SideBarAI

@Suite(.serialized)
struct UsageBoundsTests {
    @Test
    func ompParserSalvagesMalformedLimitsAndScalesFractionalPercentages() throws {
        let data = Data(
            #"""
            {
              "reports": [{
                "provider": "openai-codex",
                "limits": [
                  {"id": "", "label": "No ID", "amount": {"used": 10, "limit": 100, "unit": "percent"}},
                  {"id": "broken", "amount": {"used": "not-a-number", "limit": 100, "unit": "percent"}},
                  {"id": "duplicate", "label": "First", "amount": {"used": 20, "limit": 100, "unit": "percent"}},
                  {"id": "duplicate", "label": "Second", "amount": {"used": 30, "limit": 100, "unit": "percent"}},
                  {"id": "fraction", "label": "Fraction", "amount": {"usedFraction": 0.25, "limit": 1, "unit": "percent"}}
                ],
                "metadata": {"email": "owner@example.com", "accountId": "account-123"}
              }]
            }
            """#.utf8
        )
        let account = CodexAccount(
            accountKey: "active",
            accountLabel: "owner@example.com",
            email: "owner@example.com",
            isActive: true,
            chatgptAccountID: "account-123"
        )

        guard let snapshot = try OMPUsageParser.parse(data).reports.first?.snapshot(for: account) else {
            Issue.record("Expected the valid OMP limits to produce a snapshot")
            return
        }

        #expect(snapshot.windows.count == 4)
        #expect(Set(snapshot.windows.map(\.id)).count == snapshot.windows.count)
        #expect(snapshot.windows.allSatisfy { !$0.id.isEmpty })
        let fraction = snapshot.windows.first { $0.label == "Fraction" }
        #expect(fraction?.used == 25)
        #expect(fraction?.limit == 100)
        #expect(fraction?.percentUsed == 25)
    }

    @Test
    func ompParserDropsNegativeUsageButKeepsValidLimits() throws {
        let data = Data(
            #"""
            {
              "reports": [{
                "provider": "openai-codex",
                "limits": [
                  {"id": "negative-used", "amount": {"used": -1, "limit": 100, "unit": "percent"}},
                  {"id": "negative-limit", "amount": {"used": 10, "limit": -100, "unit": "percent"}},
                  {"id": "valid", "amount": {"used": 10, "limit": 100, "unit": "percent"}}
                ],
                "metadata": {"email": "owner@example.com"}
              }]
            }
            """#.utf8
        )
        let account = CodexAccount(
            accountKey: "active",
            accountLabel: "owner@example.com",
            email: "owner@example.com",
            isActive: true
        )
        let snapshot = try OMPUsageParser.parse(data).reports.first?.snapshot(for: account)
        #expect(snapshot?.windows.count == 1)
        #expect(snapshot?.windows.first?.id == "valid")
        #expect(snapshot?.windows.first?.percentUsed == 10)
    }
    @Test
    func ompAccountIDConflictOverridesMatchingEmail() throws {
        let data = Data(
            #"""
            {
              "reports": [{
                "provider": "openai-codex",
                "limits": [{"id": "primary", "amount": {"used": 10, "limit": 100, "unit": "percent"}}],
                "metadata": {"email": "owner@example.com", "accountId": "other-account"}
              }]
            }
            """#.utf8
        )
        let account = CodexAccount(
            accountKey: "active",
            accountLabel: "owner@example.com",
            email: "owner@example.com",
            isActive: true,
            chatgptAccountID: "account-123"
        )

        let snapshot = try OMPUsageParser.parse(data).reports.first?.snapshot(for: account)
        #expect(snapshot == nil)
    }
    @Test
    func usageModelsNormalizeWindowIdentityAndRejectUnsafePercentages() {
        let duplicate = UsageWindow(
            id: "same",
            label: "Duplicate",
            used: 1,
            limit: 10,
            unit: .percent,
            resetDate: nil,
            providerReportedPercentage: true
        )
        let snapshot = UsageSnapshot(
            windows: [
                UsageWindow(
                    id: " ",
                    label: "Unnamed",
                    used: 1,
                    limit: 10,
                    unit: .percent,
                    resetDate: nil,
                    providerReportedPercentage: true
                ),
                duplicate,
                duplicate
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            accountLabel: nil,
            planLabel: nil,
            sourceLabel: "fixture",
            savedResetCount: -1
        )

        #expect(Set(snapshot.windows.map(\.id)).count == snapshot.windows.count)
        #expect(snapshot.windows.allSatisfy { !$0.id.isEmpty })
        #expect(snapshot.savedResetCount == nil)

        let unsafe = UsageWindow(
            id: "unsafe",
            label: "Unsafe",
            used: .greatestFiniteMagnitude,
            limit: .leastNonzeroMagnitude,
            unit: .tokens,
            resetDate: nil,
            providerReportedPercentage: false
        )
        #expect(unsafe.percentUsed == nil)
        #expect(UsageNumberFormatter.roundedIntegerString(.infinity) == nil)
        #expect(UsageNumberFormatter.roundedIntegerString(.greatestFiniteMagnitude) != nil)
    }
    @Test
    func modelUsageAttributesCredentialPinsAndAggregatesRecentModelCosts() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SideBarAI-model-usage-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let now = Date()
        let currentTimestamp = Int(now.timeIntervalSince1970 * 1_000)
        let staleTimestamp = Int(now.addingTimeInterval(-31 * 24 * 60 * 60).timeIntervalSince1970 * 1_000)
        let identity = OMPAccountIdentity(
            provider: "openai-codex",
            accountID: "account-123",
            email: "owner@example.com",
            organizationID: "org-123"
        )
        let otherIdentity = OMPAccountIdentity(
            provider: "openai-codex",
            accountID: "account-other",
            email: "other@example.com",
            organizationID: "org-123"
        )
        guard let credentialPinHash = identity.credentialPinHash,
              let otherCredentialPinHash = otherIdentity.credentialPinHash else {
            Issue.record("Expected credential pin hashes")
            return
        }

        let session = """
        {"type":"credential_pin","provider":"openai-codex","hash":"\(credentialPinHash)"}
        {"type":"message","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.5","timestamp":\(currentTimestamp),"usage":{"input":100,"output":20,"cacheRead":5,"cacheWrite":0,"totalTokens":125,"cost":{"input":0.1,"output":0.2,"cacheRead":0.01,"cacheWrite":0,"total":0.31}}}}
        {"type":"message","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.5","timestamp":\(currentTimestamp),"usage":{"input":50,"output":10,"cacheRead":0,"cacheWrite":0,"totalTokens":60,"cost":{"input":0.05,"output":0.1,"cacheRead":0.005,"cacheWrite":0,"total":0.155}}}}
        {"type":"message","message":{"role":"assistant","provider":"openai-codex","model":"stale-model","timestamp":\(staleTimestamp),"usage":{"input":999,"output":999,"totalTokens":1998,"cost":{"input":9,"output":9,"total":18}}}}
        """
        try Data(session.utf8).write(to: root.appendingPathComponent("current.jsonl"))

        let otherSession = """
        {"type":"credential_pin","provider":"openai-codex","hash":"\(otherCredentialPinHash)"}
        {"type":"message","message":{"role":"assistant","provider":"openai-codex","model":"other-model","timestamp":\(currentTimestamp),"usage":{"input":700,"output":80,"totalTokens":780,"cost":{"input":7,"output":8,"total":15}}}}
        """
        try Data(otherSession.utf8).write(to: root.appendingPathComponent("other.jsonl"))

        let source = OMPModelUsageSource(sessionsDirectory: root, cacheLifetime: 0)
        let report = await source.report(for: identity, now: now)
        let summaries = report.summaries
        #expect(report.unattributedRequestCount == 0)
        #expect(summaries.count == 1)
        guard let summary = summaries.first else {
            Issue.record("Expected one recent model summary")
            return
        }
        #expect(summary.modelID == "gpt-5.5")
        #expect(summary.requestCount == 2)
        #expect(summary.inputTokens == 150)
        #expect(summary.outputTokens == 30)
        #expect(summary.cacheReadTokens == 5)
        #expect(summary.totalTokens == 185)
        #expect(abs((summary.estimatedCost ?? -1) - 0.0016525) < 0.000000001)
        let ompData = """
        {"reports":[{"provider":"openai-codex","fetchedAt":\(currentTimestamp),"limits":[{"id":"primary","label":"Primary","amount":{"used":10,"limit":100,"unit":"percent"}}],"metadata":{"email":"owner@example.com","accountId":"account-123","orgId":"org-123"}}]}
        """
        let account = CodexAccount(
            accountKey: "active",
            accountLabel: "owner@example.com",
            email: "owner@example.com",
            isActive: true,
            chatgptAccountID: "account-123"
        )
        let usageSource = OMPUsageSource(
            runner: FixtureUsageCommandRunner(data: Data(ompData.utf8)),
            modelUsageSource: source,
            cacheLifetime: 0
        )
        guard let integratedSnapshot = await usageSource.snapshot(for: account) else {
            Issue.record("Expected OMP usage to include model summaries")
            return
        }
        #expect(integratedSnapshot.modelUsage == report.summaries)
        #expect(integratedSnapshot.unattributedModelRequestCount == report.unattributedRequestCount)
        #expect(abs((integratedSnapshot.estimatedCost ?? -1) - 0.0016525) < 0.000000001)
    }

    @Test
    func modelUsageKeepsRecentUnpinnedRequestsSeparateFromCredentialPins() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SideBarAI-model-attribution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = OMPAccountIdentity(provider: "openai-codex", accountID: "target")
        let otherIdentity = OMPAccountIdentity(provider: "openai-codex", accountID: "other")
        let unmatchedIdentity = OMPAccountIdentity(provider: "openai-codex", accountID: "unmatched")
        guard let identityHash = identity.credentialPinHash,
              let otherIdentityHash = otherIdentity.credentialPinHash else {
            Issue.record("Expected credential pin hashes")
            return
        }

        let records = [
            ompMessage(modelID: "before-pin", timestamp: now.addingTimeInterval(-1), usage: #"{"input":4}"#),
            """
            {"type":"credential_pin","provider":"openai-codex","hash":"\(identityHash)"}
            """,
            ompMessage(modelID: "matched", timestamp: now, usage: #"{"input":7}"#),
            ompMessage(modelID: "old", timestamp: now.addingTimeInterval(-31 * 24 * 60 * 60), usage: #"{"input":11}"#),
            ompMessage(modelID: "future", timestamp: now.addingTimeInterval(1), usage: #"{"input":13}"#),
            ompMessage(provider: "anthropic", modelID: "other-provider", timestamp: now, usage: #"{"input":17}"#)
        ].joined(separator: "\n")
        try Data(records.utf8).write(to: root.appendingPathComponent("target.jsonl"))

        let otherAccountRecord = [
            """
            {"type":"credential_pin","provider":"openai-codex","hash":"\(otherIdentityHash)"}
            """,
            ompMessage(modelID: "other-account", timestamp: now, usage: #"{"input":19}"#)
        ].joined(separator: "\n")
        try Data(otherAccountRecord.utf8).write(to: root.appendingPathComponent("other.jsonl"))

        let source = OMPModelUsageSource(sessionsDirectory: root, cacheLifetime: 0)
        let report = await source.report(for: identity, now: now)
        #expect(report.summaries.map(\.modelID) == ["matched"])
        #expect(report.summaries.first?.inputTokens == 7)
        #expect(report.unattributedRequestCount == 1)

        let unmatchedReport = await source.report(for: unmatchedIdentity, now: now)
        #expect(unmatchedReport.summaries.isEmpty)
        #expect(unmatchedReport.unattributedRequestCount == 1)
    }

    @Test
    func modelUsageRepricesSavedAmountsAndKeepsUnpriceableModelsOutOfSubtotal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SideBarAI-pricing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = OMPAccountIdentity(provider: "openai-codex", accountID: "pricing")
        let pin = try #require(identity.credentialPinHash)
        let records = [
            """
            {"type":"credential_pin","provider":"openai-codex","hash":"\(pin)"}
            """,
            ompMessage(modelID: "gpt-6-astra", timestamp: now, usage: #"{"input":1000,"output":100,"cacheRead":2000,"cacheWrite":50,"totalTokens":3150,"cost":{"total":0}}"#),
            ompMessage(modelID: "gpt-6-astra", timestamp: now, usage: #"{"input":1000,"output":100,"cacheRead":2000,"cacheWrite":50,"totalTokens":3150,"cost":{"total":999}}"#),
            ompMessage(modelID: "gpt-6-luna", timestamp: now, usage: #"{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0}"#),
            ompMessage(modelID: "gpt-5.3-codex-spark", timestamp: now, usage: #"{"input":100,"output":10,"cacheRead":0,"cacheWrite":0,"totalTokens":110,"cost":{"total":0.5}}"#),
            ompMessage(modelID: "gpt-5.6-sol", timestamp: now, usage: #"{"totalTokens":50,"cost":{"total":0.25}}"#),
            ompMessage(modelID: "gpt-5.6-luna", timestamp: now, usage: #"{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2}"#),
            ompMessage(modelID: "gpt-5.6-luna", timestamp: now, usage: #"{"input":9,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":0}"#)
        ].joined(separator: "\n")
        try Data(records.utf8).write(to: root.appendingPathComponent("session.jsonl"))
        let report = await OMPModelUsageSource(sessionsDirectory: root).report(for: identity, now: now)
        let astra = try #require(report.summaries.first { $0.modelID == "gpt-6-astra" })
        #expect(abs((astra.estimatedCost ?? -1) - 0.034) < 1e-12)
        #expect(astra.totalTokens == 6_300)
        #expect(astra.cacheReadTokens == 4_000)
        #expect(report.summaries.first { $0.modelID == "gpt-6-luna" }?.estimatedCost == 0)
        #expect(report.summaries.first { $0.modelID == "gpt-5.3-codex-spark" }?.estimatedCost == nil)
        #expect(report.summaries.first { $0.modelID == "gpt-5.6-sol" }?.estimatedCost == nil)
        #expect(report.summaries.first { $0.modelID == "gpt-5.6-luna" }?.estimatedCost == nil)
        let snapshot = UsageSnapshot(windows: [], updatedAt: now, accountLabel: nil, planLabel: nil, sourceLabel: "fixture")
            .withModelUsage(report)
        #expect(snapshot.estimatedCost == nil)
        #expect(abs((snapshot.pricedModelCost ?? -1) - 0.034) < 1e-12)
    }

    @Test
    func modelUsageAppliesServiceTierChangesWithinEachSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SideBarAI-tiers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = OMPAccountIdentity(provider: "openai-codex", accountID: "tiers")
        let pin = try #require(identity.credentialPinHash)
        let header = """
        {"type":"credential_pin","provider":"openai-codex","hash":"\(pin)"}
        """
        let usage = #"{"input":1000,"output":100,"cacheRead":2000,"cacheWrite":50,"totalTokens":3150,"cost":{"total":999}}"#
        let astra = ompMessage(modelID: "gpt-6-astra", timestamp: now, usage: usage)
        let records = [header, astra,
            #"{"type":"service_tier_change","serviceTier":{"openai":"priority"}}"#, astra,
            #"{"type":"service_tier_change","serviceTier":null}"#, astra,
            #"{"type":"service_tier_change","serviceTier":{"openai":"unrecognized"}}"#,
            ompMessage(modelID: "gpt-5.6-sol", timestamp: now, usage: usage),
            #"{"type":"service_tier_change","serviceTier":{"openai":"fast"}}"#, astra
        ].joined(separator: "\n")
        try Data(records.utf8).write(to: root.appendingPathComponent("first.jsonl"))
        try Data((header + "\n" + astra).utf8).write(to: root.appendingPathComponent("second.jsonl"))
        let report = await OMPModelUsageSource(sessionsDirectory: root).report(for: identity, now: now)
        let summary = try #require(report.summaries.first { $0.modelID == "gpt-6-astra" })
        #expect(summary.requestCount == 5)
        #expect(abs((summary.estimatedCost ?? -1) - 0.136) < 1e-12)
        #expect(report.summaries.first { $0.modelID == "gpt-5.6-sol" }?.estimatedCost == nil)
    }

    @Test
    func codexRatesSeparateCachedInputAndExcludeCacheWriteCharges() throws {
        let cost = try #require(CodexModelPricing.estimate(
            modelID: "gpt-6-astra", input: 1_000, output: 100,
            cacheRead: 2_000, cacheWrite: 5_000, serviceTier: .standard
        ))
        #expect(abs(cost - 0.017) < 1e-12)
    }

    @Test
    func codexLongContextIncludesCachedPromptAndExemptsAstra() throws {
        let boundary = try #require(CodexModelPricing.estimate(
            modelID: "gpt-5.6-sol", input: 1_000, output: 100,
            cacheRead: 271_000, cacheWrite: 0, serviceTier: .standard
        ))
        let long = try #require(CodexModelPricing.estimate(
            modelID: "gpt-5.6-sol", input: 1_000, output: 100,
            cacheRead: 271_001, cacheWrite: 0, serviceTier: .standard
        ))
        let astra = try #require(CodexModelPricing.estimate(
            modelID: "gpt-6-astra", input: 1_000, output: 100,
            cacheRead: 271_001, cacheWrite: 0, serviceTier: .standard
        ))
        #expect(abs(boundary - 0.1144) < 1e-12)
        #expect(abs(long - 0.2278008) < 1e-12)
        #expect(abs(astra - 0.286001) < 1e-12)
    }

    @Test
    func codexFastMultipliersFollowTheProductRatherThanAPIPrice() throws {
        let luna = try #require(CodexModelPricing.estimate(
            modelID: "gpt-5.6-luna", input: 1_000, output: 500,
            cacheRead: 200, cacheWrite: 0, serviceTier: .fast
        ))
        let older = try #require(CodexModelPricing.estimate(
            modelID: "gpt-5.4", input: 1_000, output: 500,
            cacheRead: 200, cacheWrite: 0, serviceTier: .fast
        ))
        #expect(abs(luna - 0.00201) < 1e-12)
        #expect(abs(older - 0.0201) < 1e-12)
    }

    @Test
    func codexPricingRejectsUnpublishedModelsTiersAndInvalidCounts() {
        #expect(CodexModelPricing.estimate(modelID: "gpt-5.3-codex-spark", input: 100, output: 10,
            cacheRead: 0, cacheWrite: 0, serviceTier: .standard) == nil)
        #expect(CodexModelPricing.estimate(modelID: "gpt-5.3-codex", input: 100, output: 10,
            cacheRead: 0, cacheWrite: 0, serviceTier: .fast) == nil)
        #expect(CodexModelPricing.estimate(modelID: "gpt-6-astra", input: -1, output: 10,
            cacheRead: 0, cacheWrite: 0, serviceTier: .standard) == nil)
        #expect(CodexModelPricing.estimate(modelID: "gpt-6-astra", input: 100, output: .infinity,
            cacheRead: 0, cacheWrite: 0, serviceTier: .standard) == nil)
    }

    @Test
    func claudeRatesPriceCacheSeparatelyAndRejectUnlistedModels() throws {
        // Opus 5.5 cache hits are 0.05x input, not the usual 0.1x.
        let opus = try #require(ClaudeModelPricing.estimate(
            modelID: "claude-opus-5-5", input: 1_000, output: 500, cacheRead: 10_000, cacheWrite: 2_000
        ))
        let datedHaiku = try #require(ClaudeModelPricing.estimate(
            modelID: "claude-haiku-4-5-20251001", input: 1_000, output: 100, cacheRead: 0, cacheWrite: 0
        ))
        #expect(abs(opus - 0.026) < 1e-12)
        #expect(abs(datedHaiku - 0.0015) < 1e-12)
        #expect(ClaudeModelPricing.estimate(modelID: "claude-sonnet-5-5", input: 100, output: 10,
            cacheRead: 0, cacheWrite: 0) == nil)
    }

    @Test
    func ompUsageSourceCarriesUnattributedRequestsWithoutMatchedModels() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SideBarAI-omp-unattributed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let timestamp = Int(now.timeIntervalSince1970 * 1_000)
        let event = ompMessage(modelID: "unassigned", timestamp: now, usage: #"{"input":21,"totalTokens":21}"#)
        try Data(event.utf8).write(to: root.appendingPathComponent("unassigned.jsonl"))

        let ompData = """
        {"reports":[{"provider":"openai-codex","fetchedAt":\(timestamp),"limits":[{"id":"primary","label":"Primary","amount":{"used":10,"limit":100,"unit":"percent"}}],"metadata":{"email":"owner@example.com","accountId":"account-123","orgId":"org-123"}}]}
        """
        let account = CodexAccount(
            accountKey: "active",
            accountLabel: "owner@example.com",
            email: "owner@example.com",
            isActive: true,
            chatgptAccountID: "account-123"
        )
        let source = OMPUsageSource(
            runner: FixtureUsageCommandRunner(data: Data(ompData.utf8)),
            modelUsageSource: OMPModelUsageSource(sessionsDirectory: root, cacheLifetime: 0),
            cacheLifetime: 0
        )

        guard let snapshot = await source.snapshot(for: account) else {
            Issue.record("Expected a snapshot from the fixture runner")
            return
        }
        #expect(snapshot.modelUsage.isEmpty)
        #expect(snapshot.unattributedModelRequestCount == 1)
        #expect(snapshot.hasModelUsage)
        #expect(snapshot.modelUsageDetail != nil)
        #expect(snapshot.estimatedCost == nil)
    }

    @Test
    func consolidatedCodexUsesMaximumUnattributedCountAndRetainsUnknownCost() {
        let makeRecord = { (id: String, unattributedCount: Int, summary: ModelUsageSummary) in
            ProviderRecord(
                recordID: id,
                provider: .chatgpt,
                state: .usage(UsageSnapshot(
                    windows: [UsageWindow(
                        id: "primary",
                        label: "Primary",
                        used: 10,
                        limit: 100,
                        unit: .percent,
                        resetDate: nil,
                        providerReportedPercentage: true
                    )],
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    accountLabel: id,
                    planLabel: "plus",
                    sourceLabel: "fixture",
                    modelUsage: [summary],
                    unattributedModelRequestCount: unattributedCount
                ))
            )
        }
        let priced = ModelUsageSummary(
            modelID: "gpt-5.5", requestCount: 1, inputTokens: 3, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 3, estimatedCost: 0.25
        )
        let unpriced = ModelUsageSummary(
            modelID: "gpt-5.5", requestCount: 1, inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 5, cacheWriteTokens: 0, totalTokens: 5, estimatedCost: nil
        )
        let records = [makeRecord("one", 3, priced), makeRecord("two", 7, unpriced)]

        guard case let .usage(snapshot) = ProviderRecord.consolidatedCodexPresentation(records).first?.state else {
            Issue.record("Expected consolidated usage")
            return
        }
        #expect(snapshot.unattributedModelRequestCount == 7)
        #expect(snapshot.modelUsage.count == 1)
        #expect(snapshot.modelUsage.first?.inputTokens == 3)
        #expect(snapshot.modelUsage.first?.cacheReadTokens == 5)
        #expect(snapshot.modelUsage.first?.estimatedCost == nil)
        #expect(snapshot.estimatedCost == nil)
    }


    @Test
    func consolidatedResetCountsDoNotOverflow() {
        let makeRecord = { (id: String) in
            ProviderRecord(
                recordID: id,
                provider: .chatgpt,
                state: .usage(UsageSnapshot(
                    windows: [UsageWindow(
                        id: "primary",
                        label: "Primary",
                        used: 10,
                        limit: 100,
                        unit: .percent,
                        resetDate: nil,
                        providerReportedPercentage: true
                    )],
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    accountLabel: id,
                    planLabel: "plus",
                    sourceLabel: "fixture",
                    savedResetCount: Int.max
                ))
            )
        }

        let records = [makeRecord("one"), makeRecord("two")]
        guard case let .usage(snapshot) = ProviderRecord.consolidatedCodexPresentation(records).first?.state else {
            Issue.record("Expected consolidated usage")
            return
        }
        #expect(snapshot.savedResetCount == nil)
    }

    @Test
    func aggregationKeepsFractionalAndHugeDurationsWithoutIntegerConversion() {
        let makeRecord = { (id: String, period: Double) in
            ProviderRecord(
                recordID: id,
                provider: .chatgpt,
                state: .usage(UsageSnapshot(
                    windows: [UsageWindow(
                        id: "primary",
                        label: "Primary",
                        used: 10,
                        limit: 100,
                        unit: .percent,
                        resetDate: nil,
                        providerReportedPercentage: true,
                        periodSeconds: period
                    )],
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    accountLabel: id,
                    planLabel: "plus",
                    sourceLabel: "fixture"
                ))
            )
        }

        let records = [
            makeRecord("one", .leastNonzeroMagnitude),
            makeRecord("two", .greatestFiniteMagnitude)
        ]
        guard case let .usage(snapshot) = ProviderRecord.consolidatedCodexPresentation(records).first?.state else {
            Issue.record("Expected consolidated usage")
            return
        }
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.contains { $0.periodSeconds == .leastNonzeroMagnitude })
        #expect(snapshot.windows.contains { $0.periodSeconds == .greatestFiniteMagnitude })
    }

    @Test
    func ompProcessTimeoutTerminatesAStuckCommand() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SideBarAI-stuck-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\nwhile :; do :; done\n".utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        do {
            _ = try await ProcessUsageCommandRunner(
                executableURL: scriptURL,
                timeout: 0.1
            ).run()
            Issue.record("Expected a stuck OMP command to time out")
        } catch let error as UsageCommandError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Expected timedOut, got \(error)")
        }
    }

    @Test
    func modelUsageCacheTracksFileChangesAndAccountReassignment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SideBarAI-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let first = OMPAccountIdentity(provider: "openai-codex", accountID: "first")
        let second = OMPAccountIdentity(provider: "openai-codex", accountID: "second")
        let firstHash = try #require(first.credentialPinHash)
        let secondHash = try #require(second.credentialPinHash)
        let base = Int(Date().timeIntervalSince1970)
        let now = Date(timeIntervalSince1970: TimeInterval(base))
        let header = "{\"type\":\"credential_pin\",\"provider\":\"openai-codex\",\"hash\":\"\(firstHash)\"}\n"
        func event(_ tokens: Int) -> String {
            "{\"type\":\"model_usage\",\"provider\":\"openai-codex\",\"model\":\"model\",\"timestamp\":\(base),\"usage\":{\"totalTokens\":\(tokens)}}\n"
        }
        try Data((header + event(10)).utf8).write(to: file)
        let source = OMPModelUsageSource(sessionsDirectory: root, cacheLifetime: 0)
        #expect(await source.report(for: first, now: now).summaries.first?.totalTokens == 10)

        let append = try FileHandle(forWritingTo: file)
        try append.seekToEnd()
        let nextEvent = Data(event(20).utf8)
        try append.write(contentsOf: nextEvent.prefix(30))
        #expect(await source.report(for: first, now: now).summaries.first?.totalTokens == 10)
        try append.write(contentsOf: nextEvent.dropFirst(30))
        try append.close()
        #expect(await source.report(for: first, now: now).summaries.first?.totalTokens == 30)

        // Same size and restored mtime must not hide a new account pin.
        var originalStat = stat()
        try #require(fstatat(AT_FDCWD, file.path, &originalStat, 0) == 0)
        var originalTimes = [originalStat.st_atimespec, originalStat.st_mtimespec]
        let replacement = header.replacingOccurrences(of: firstHash, with: secondHash) + event(10) + event(20)
        let rewrite = try FileHandle(forWritingTo: file)
        try rewrite.write(contentsOf: Data(replacement.utf8))
        try rewrite.close()
        try #require(utimensat(AT_FDCWD, file.path, &originalTimes, 0) == 0)
        #expect(await source.report(for: first, now: now).summaries.isEmpty)
        #expect(await source.report(for: second, now: now).summaries.first?.totalTokens == 30)

        try Data((header + event(5)).utf8).write(to: file, options: .atomic)
        #expect(await source.report(for: first, now: now).summaries.first?.totalTokens == 5)
        #expect(await source.report(for: second, now: now).summaries.isEmpty)
        try FileManager.default.removeItem(at: file)
        #expect(await source.report(for: first, now: now).summaries.isEmpty)
        try Data((header + event(15)).utf8).write(to: root.appendingPathComponent("new.jsonl"))
        #expect(await source.report(for: first, now: now).summaries.first?.totalTokens == 15)
    }

    @Test
    func cachedModelUsageStillAppliesRollingTimeBounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SideBarAI-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = OMPAccountIdentity(provider: "openai-codex", accountID: "window")
        let hash = try #require(identity.credentialPinHash)
        let base = Int(Date().timeIntervalSince1970)
        let data = """
        {"type":"credential_pin","provider":"openai-codex","hash":"\(hash)"}
        {"type":"model_usage","provider":"openai-codex","model":"model","timestamp":\(base),"usage":{"totalTokens":10}}
        {"type":"model_usage","provider":"openai-codex","model":"model","timestamp":\(base + 1),"usage":{"totalTokens":20}}
        """
        try Data(data.utf8).write(to: root.appendingPathComponent("session.jsonl"))
        let source = OMPModelUsageSource(sessionsDirectory: root, cacheLifetime: 3_600)
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        #expect(await source.report(for: identity, now: start).summaries.first?.totalTokens == 10)
        #expect(await source.report(for: identity, now: start.addingTimeInterval(1)).summaries.first?.totalTokens == 30)
        let cutoff = start.addingTimeInterval(OMPModelUsageSource.lookbackInterval)
        #expect(await source.report(for: identity, now: cutoff).summaries.first?.totalTokens == 30)
        #expect(await source.report(for: identity, now: cutoff.addingTimeInterval(0.5)).summaries.first?.totalTokens == 20)
        #expect(await source.report(for: identity, now: cutoff.addingTimeInterval(2)).summaries.isEmpty)
    }

    @Test
    func sharedDateParserHandlesConcurrentFormats() async {
        let cases: [(String, Double?)] = [
            ("2027-01-15T08:00:00.123Z", 1_800_000_000.123),
            ("2027-01-15T09:00:00+01:00", 1_800_000_000),
            (" 2027-01-15T08:00:00Z \n", 1_800_000_000),
            ("invalid", nil), ("", nil)
        ]
        let correct = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    for _ in 0..<20 {
                        for (input, expected) in cases {
                            let actual = UsageDateParser.iso8601(input)?.timeIntervalSince1970
                            if let expected {
                                guard let actual, abs(actual - expected) < 0.000001 else { return false }
                            } else if actual != nil { return false }
                        }
                    }
                    return true
                }
            }
            for await result in group where !result { return false }
            return true
        }
        #expect(correct)
    }

    @Test
    func backgroundCommandCannotLaunchAnotherExecutable() async throws {
        let shell = URL(fileURLWithPath: "/bin/bash")
        let command = """
        if /usr/bin/true; then printf launched; else printf blocked; fi
        if /usr/bin/security help >/dev/null 2>&1; then printf :keychain; fi
        """
        let unrestricted = try await ProcessUsageCommandRunner(
            arguments: ["-c", command], executableURL: shell
        ).run()
        #expect(String(decoding: unrestricted, as: UTF8.self) == "launched:keychain")

        let restricted = try await ProcessUsageCommandRunner(
            arguments: ["-c", command], executableURL: shell,
            isolatedWorkingDirectory: true, preventsApplicationLaunches: true
        ).run()
        #expect(String(decoding: restricted, as: UTF8.self) == "blocked:keychain")
    }

    @Test
    func processRunnerRejectsOutputBeyondOneMiB() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SideBarAI-output-limit-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n/bin/dd if=/dev/zero bs=1048577 count=1 2>/dev/null\n".utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        do {
            _ = try await ProcessUsageCommandRunner(
                executableURL: scriptURL,
                timeout: 1
            ).run()
            Issue.record("Expected output beyond the runner limit to fail")
        } catch let error as UsageCommandError {
            #expect(error == .outputTooLarge)
        } catch {
            Issue.record("Expected outputTooLarge, got \(error)")
        }
    }
}

private func ompMessage(
    provider: String = "openai-codex",
    modelID: String,
    timestamp: Date,
    usage: String
) -> String {
    let timestampMilliseconds = Int(timestamp.timeIntervalSince1970 * 1_000)
    return """
    {"type":"message","message":{"role":"assistant","provider":"\(provider)","model":"\(modelID)","timestamp":\(timestampMilliseconds),"usage":\(usage)}}
    """
}

private struct FixtureUsageCommandRunner: UsageCommandRunning {
    let data: Data

    func run() async throws -> Data {
        data
    }
}
