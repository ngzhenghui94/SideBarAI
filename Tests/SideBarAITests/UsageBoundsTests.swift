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
        let summaries = await source.summaries(for: identity, now: now)

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
        #expect(abs((summary.estimatedCost ?? -1) - 0.465) < 0.000001)
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
        #expect(integratedSnapshot.modelUsage == summaries)
        #expect(abs((integratedSnapshot.estimatedCost ?? -1) - 0.465) < 0.000001)
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
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let header = "{\"type\":\"credential_pin\",\"provider\":\"openai-codex\",\"hash\":\"\(firstHash)\"}\n"
        func event(_ tokens: Int) -> String {
            "{\"type\":\"model_usage\",\"provider\":\"openai-codex\",\"model\":\"model\",\"timestamp\":1800000000,\"usage\":{\"totalTokens\":\(tokens)}}\n"
        }
        try Data((header + event(10)).utf8).write(to: file)
        let source = OMPModelUsageSource(sessionsDirectory: root, cacheLifetime: 0)
        #expect(await source.summaries(for: first, now: now).first?.totalTokens == 10)

        let append = try FileHandle(forWritingTo: file)
        try append.seekToEnd()
        let nextEvent = Data(event(20).utf8)
        try append.write(contentsOf: nextEvent.prefix(30))
        #expect(await source.summaries(for: first, now: now).first?.totalTokens == 10)
        try append.write(contentsOf: nextEvent.dropFirst(30))
        try append.close()
        #expect(await source.summaries(for: first, now: now).first?.totalTokens == 30)

        // Same size and restored mtime must not hide a new account pin.
        var originalStat = stat()
        try #require(fstatat(AT_FDCWD, file.path, &originalStat, 0) == 0)
        var originalTimes = [originalStat.st_atimespec, originalStat.st_mtimespec]
        let replacement = header.replacingOccurrences(of: firstHash, with: secondHash) + event(10) + event(20)
        let rewrite = try FileHandle(forWritingTo: file)
        try rewrite.write(contentsOf: Data(replacement.utf8))
        try rewrite.close()
        try #require(utimensat(AT_FDCWD, file.path, &originalTimes, 0) == 0)
        #expect(await source.summaries(for: first, now: now).isEmpty)
        #expect(await source.summaries(for: second, now: now).first?.totalTokens == 30)

        try Data((header + event(5)).utf8).write(to: file, options: .atomic)
        #expect(await source.summaries(for: first, now: now).first?.totalTokens == 5)
        #expect(await source.summaries(for: second, now: now).isEmpty)
        try FileManager.default.removeItem(at: file)
        #expect(await source.summaries(for: first, now: now).isEmpty)
        try Data((header + event(15)).utf8).write(to: root.appendingPathComponent("new.jsonl"))
        #expect(await source.summaries(for: first, now: now).first?.totalTokens == 15)
    }

    @Test
    func cachedModelUsageStillAppliesRollingTimeBounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SideBarAI-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = OMPAccountIdentity(provider: "openai-codex", accountID: "window")
        let hash = try #require(identity.credentialPinHash)
        let data = """
        {"type":"credential_pin","provider":"openai-codex","hash":"\(hash)"}
        {"type":"model_usage","provider":"openai-codex","model":"model","timestamp":1800000000,"usage":{"totalTokens":10}}
        {"type":"model_usage","provider":"openai-codex","model":"model","timestamp":1800000001,"usage":{"totalTokens":20}}
        """
        try Data(data.utf8).write(to: root.appendingPathComponent("session.jsonl"))
        let source = OMPModelUsageSource(sessionsDirectory: root, cacheLifetime: 3_600)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(await source.summaries(for: identity, now: start).first?.totalTokens == 10)
        #expect(await source.summaries(for: identity, now: start.addingTimeInterval(1)).first?.totalTokens == 30)
        let cutoff = start.addingTimeInterval(OMPModelUsageSource.lookbackInterval)
        #expect(await source.summaries(for: identity, now: cutoff).first?.totalTokens == 30)
        #expect(await source.summaries(for: identity, now: cutoff.addingTimeInterval(0.5)).first?.totalTokens == 20)
        #expect(await source.summaries(for: identity, now: cutoff.addingTimeInterval(2)).isEmpty)
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

private struct FixtureUsageCommandRunner: UsageCommandRunning {
    let data: Data

    func run() async throws -> Data {
        data
    }
}
