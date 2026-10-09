import Foundation

actor OMPUsageSource {
    private let runner: any UsageCommandRunning
    private let modelUsageSource: OMPModelUsageSource
    private let cacheLifetime: TimeInterval
    private var cachedDocument: OMPUsageDocument?
    private var cachedAt: Date?
    private var inFlight: Task<OMPUsageDocument, Error>?

    init(
        runner: any UsageCommandRunning = ProcessUsageCommandRunner(),
        modelUsageSource: OMPModelUsageSource = OMPModelUsageSource(),
        cacheLifetime: TimeInterval = 2
    ) {
        self.runner = runner
        self.modelUsageSource = modelUsageSource
        self.cacheLifetime = cacheLifetime
    }

    func reports() async throws -> [OMPUsageReport] {
        try await document().reports
    }

    func codexAccounts() async throws -> [CodexAccount] {
        try await document().codexAccounts()
    }

    private func document() async throws -> OMPUsageDocument {
        if let cachedDocument, let cachedAt,
           Date().timeIntervalSince(cachedAt) < cacheLifetime {
            return cachedDocument
        }
        if let inFlight { return try await inFlight.value }
        let runner = runner
        let task = Task<OMPUsageDocument, Error> {
            let data = try await runner.run()
            return try OMPUsageParser.parse(data)
        }
        inFlight = task
        do {
            let document = try await task.value
            inFlight = nil
            cachedDocument = document
            cachedAt = Date()
            return document
        } catch {
            inFlight = nil
            // A failed command never overwrites the last successful discovery.
            throw error
        }
    }

    func snapshot(for account: CodexAccount) async -> UsageSnapshot? {
        try? await usage(for: account)
    }

    func usage(for account: CodexAccount) async throws -> UsageSnapshot? {
        let reports = try await reports()
        guard let report = reports.lazy.filter({ $0.matches(account) }).max(by: {
            ($0.fetchedAt?.value ?? 0) < ($1.fetchedAt?.value ?? 0)
        }), let snapshot = report.snapshot(for: account) else { return nil }
        guard let identity = report.accountIdentity else { return snapshot }
        let modelUsage = await modelUsageSource.report(for: identity)
        return snapshot.withModelUsage(modelUsage)
    }

    /// Claude Code OAuth exposes no account identity, so local OMP history is attached
    /// only when OMP has exactly one Anthropic account; otherwise ownership is ambiguous.
    func anthropicModelUsage() async -> OMPModelUsageReport? {
        guard let reports = try? await reports() else { return nil }
        let anthropic = reports.filter { $0.provider.caseInsensitiveCompare("anthropic") == .orderedSame }
        guard anthropic.count == 1, let identity = anthropic[0].accountIdentity else { return nil }
        return await modelUsageSource.report(for: identity)
    }
}

struct OMPUsageDocument: Decodable, Sendable {
    let reports: [OMPUsageReport]
    let accountsWithoutUsage: [OMPUnreportedAccount]

    private enum CodingKeys: String, CodingKey {
        case reports, accountsWithoutUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Losing an invalid account row would look like a logout to the live store.
        // Limits within a valid report remain independently salvageable.
        reports = try container.decode([OMPUsageReport].self, forKey: .reports)
        accountsWithoutUsage = try container.decodeIfPresent([OMPUnreportedAccount].self, forKey: .accountsWithoutUsage) ?? []
    }

    func codexAccounts() throws -> [CodexAccount] {
        var accounts: [CodexAccount] = []
        var seen = Set<String>()
        func append(_ metadata: OMPUsageMetadata?) throws {
            guard let metadata, let account = CodexAccount.from(metadata: metadata) else {
                throw UsageCommandError.invalidOutput
            }
            if seen.insert(account.recordID).inserted { accounts.append(account) }
        }
        for report in reports.sorted(by: { ($0.fetchedAt?.value ?? 0) > ($1.fetchedAt?.value ?? 0) })
            where report.provider.caseInsensitiveCompare("openai-codex") == .orderedSame {
            try append(report.metadata)
        }
        for account in accountsWithoutUsage
            where account.provider.caseInsensitiveCompare("openai-codex") == .orderedSame {
            try append(account.metadata)
        }
        return accounts.sorted { $0.recordID < $1.recordID }
    }
}

struct OMPUnreportedAccount: Decodable, Sendable {
    let provider: String
    let metadata: OMPUsageMetadata

    private enum CodingKeys: String, CodingKey { case provider }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        metadata = try OMPUsageMetadata(from: decoder)
    }
}

struct OMPUsageReport: Decodable, Sendable {
    let provider: String
    let fetchedAt: FlexibleDouble?
    let limits: [OMPUsageLimit]
    let metadata: OMPUsageMetadata?
    let resetCredits: OMPResetCredits?

    private enum CodingKeys: String, CodingKey {
        case provider
        case fetchedAt
        case limits
        case metadata
        case resetCredits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        fetchedAt = try? container.decode(FlexibleDouble.self, forKey: .fetchedAt)
        limits = (try? container
            .decodeIfPresent(LossyDecodableArray<OMPUsageLimit>.self, forKey: .limits))?
            .values ?? []
        metadata = try container.decodeIfPresent(OMPUsageMetadata.self, forKey: .metadata)
        resetCredits = try? container.decode(OMPResetCredits.self, forKey: .resetCredits)
    }
    var accountIdentity: OMPAccountIdentity? {
        guard let metadata else { return nil }
        return OMPAccountIdentity(
            provider: provider,
            accountID: metadata.accountId,
            email: metadata.email,
            organizationID: metadata.organizationID,
            projectID: metadata.projectID
        )
    }

    func snapshot(for account: CodexAccount) -> UsageSnapshot? {
        guard provider.caseInsensitiveCompare("openai-codex") == .orderedSame,
              matches(account) else {
            return nil
        }

        var usedWindowIDs = Set<String>()
        let windows = limits.enumerated().compactMap { index, limit -> UsageWindow? in
            guard let window = limit.usageWindow(index: index) else { return nil }
            let uniqueID = uniqueWindowID(window.id, usedIDs: &usedWindowIDs)
            guard uniqueID != window.id else { return window }
            return UsageWindow(
                id: uniqueID,
                label: window.label,
                used: window.used,
                limit: window.limit,
                unit: window.unit,
                resetDate: window.resetDate,
                providerReportedPercentage: window.providerReportedPercentage,
                periodSeconds: window.periodSeconds
            )
        }
        guard !windows.isEmpty else { return nil }

        return UsageSnapshot(
            windows: windows,
            updatedAt: fetchedAt
                .flatMap { UsageDateParser.epoch($0.value) }
                ?? Date(),
            accountLabel: account.accountLabel ?? account.email,
            planLabel: metadata?.planType ?? account.planLabel,
            sourceLabel: "OMP usage --json",
            savedResetCount: resetCredits?.availableCount
        )
    }

    func matches(_ account: CodexAccount) -> Bool {
        guard provider.caseInsensitiveCompare("openai-codex") == .orderedSame,
              let metadata else { return false }
        let identity = OMPAccountIdentity(
            provider: "openai-codex",
            accountID: metadata.accountId,
            email: metadata.email?.lowercased(),
            organizationID: metadata.organizationID,
            projectID: metadata.projectID
        )
        // No email/account-ID fallback: both the user and workspace must agree.
        return (identity.accountID != nil || identity.email != nil) && identity == account.identity
    }

    private func uniqueWindowID(_ id: String, usedIDs: inout Set<String>) -> String {
        guard !usedIDs.contains(id) else {
            var suffix = 2
            var candidate = "\(id)-\(suffix)"
            while usedIDs.contains(candidate) {
                suffix += 1
                candidate = "\(id)-\(suffix)"
            }
            usedIDs.insert(candidate)
            return candidate
        }
        usedIDs.insert(id)
        return id
    }
}

struct OMPResetCredits: Decodable, Sendable {
    let availableCount: Int?

    private enum CodingKeys: String, CodingKey {
        case availableCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let rawValue = try? container.decode(FlexibleDouble.self, forKey: .availableCount),
              rawValue.value.isFinite,
              rawValue.value >= 0,
              rawValue.value.rounded(.towardZero) == rawValue.value,
              let count = Int(exactly: rawValue.value) else {
            availableCount = nil
            return
        }
        availableCount = count
    }
}

struct OMPUsageLimit: Decodable, Sendable {
    let id: String?
    let label: String?
    let scope: OMPUsageScope?
    let window: OMPUsageWindow?
    let amount: OMPUsageAmount?
    let status: String?

    func usageWindow(index _: Int) -> UsageWindow? {
        // Status describes quota state; it does not invalidate the reported window.
        guard let amount,
              let unitValue = amount.unit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let unit = UsageUnit(rawValue: unitValue) else {
            return nil
        }

        let rawLimit = amount.limit?.value
        if let rawLimit,
           !rawLimit.isFinite || rawLimit <= 0 {
            return nil
        }

        var used: Double
        let limit: Double?
        let usedIsFraction: Bool
        if unit == .percent {
            if let fraction = amount.usedFraction?.value,
               fraction.isFinite,
               (0...1).contains(fraction) {
                used = fraction * 100
                usedIsFraction = true
            } else if let value = amount.used?.value,
                      value.isFinite,
                      value >= 0 {
                used = value
                usedIsFraction = false
            } else {
                return nil
            }

            if rawLimit == 1 {
                limit = 100
                if !usedIsFraction, used <= 1 {
                    used *= 100
                }
            } else {
                limit = rawLimit
            }
        } else {
            guard let value = amount.used?.value,
                  value.isFinite,
                  value >= 0 else {
                return nil
            }
            used = value
            usedIsFraction = false
            limit = rawLimit
        }
        guard used.isFinite,
              used >= 0,
              limit?.isFinite ?? true else {
            return nil
        }

        let periodSeconds: Double?
        if let value = window?.durationMs?.value,
           value.isFinite,
           value > 0 {
            let seconds = value / 1_000
            periodSeconds = seconds.isFinite && seconds > 0 ? seconds : nil
        } else {
            periodSeconds = nil
        }
        let resetDate: Date?
        if let value = window?.resetsAt?.value {
            resetDate = UsageDateParser.epoch(value)
        } else {
            resetDate = nil
        }
        let baseID = normalized(id)
            ?? normalized(window?.id)
            ?? normalized(scope?.windowId)
            ?? normalized(label)
            ?? normalized(window?.label)
            ?? "usage"
        let displayLabel = normalized(label)
            ?? normalized(window?.label)
            ?? baseID

        return UsageWindow(
            id: baseID,
            label: displayLabel,
            used: used,
            limit: limit,
            unit: unit,
            resetDate: resetDate,
            providerReportedPercentage: unit == .percent,
            periodSeconds: periodSeconds
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct OMPUsageScope: Decodable, Sendable {
    let provider: String?
    let accountId: String?
    let tier: String?
    let modelId: String?
    let windowId: String?
}

struct OMPUsageWindow: Decodable, Sendable {
    let id: String?
    let label: String?
    let durationMs: FlexibleDouble?
    let resetsAt: FlexibleDouble?
}

struct OMPUsageAmount: Decodable, Sendable {
    let used: FlexibleDouble?
    let limit: FlexibleDouble?
    let usedFraction: FlexibleDouble?
    let unit: String?
}

struct OMPUsageMetadata: Decodable, Sendable {
    let planType: String?
    let allowed: Bool?
    let limitReached: Bool?
    let email: String?
    let accountId: String?
    let organizationID: String?
    let organizationName: String?
    let projectID: String?

    private enum CodingKeys: String, CodingKey {
        case planType, allowed, limitReached, email, accountId
        case organizationID = "orgId"
        case organizationName = "orgName"
        case projectID = "projectId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try? container.decode(String.self, forKey: .planType)
        allowed = try? container.decode(Bool.self, forKey: .allowed)
        limitReached = try? container.decode(Bool.self, forKey: .limitReached)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        organizationID = try container.decodeIfPresent(String.self, forKey: .organizationID)
        organizationName = try? container.decode(String.self, forKey: .organizationName)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
    }
}

enum OMPUsageParser {
    static func parse(_ data: Data) throws -> OMPUsageDocument {
        do {
            return try JSONDecoder().decode(OMPUsageDocument.self, from: data)
        } catch {
            throw UsageCommandError.invalidOutput
        }
    }
}

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct LossyDecodableArray<Value: Decodable>: Decodable {
    let values: [Value]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Value] = []
        while !container.isAtEnd {
            let element = try container.decode(LossyDecodable<Value>.self)
            if let value = element.value {
                values.append(value)
            }
        }
        self.values = values
    }
}
