import Foundation

enum Provider: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case claude
    case chatgpt
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .chatgpt:
            "ChatGPT / Codex"
        case .antigravity:
            "Antigravity"
        }
    }

    var shortName: String {
        switch self {
        case .claude:
            "Claude"
        case .chatgpt:
            "Codex"
        case .antigravity:
            "Antigravity"
        }
    }

    var systemImage: String {
        switch self {
        case .claude:
            "sparkles"
        case .chatgpt:
            "bubble.left.and.bubble.right.fill"
        case .antigravity:
            "circle.hexagongrid.fill"
        }
    }

    var colorHex: String {
        switch self {
        case .claude:
            "#D97757"
        case .chatgpt:
            "#10A37F"
        case .antigravity:
            "#4285F4"
        }
    }

    var sourceDescription: String {
        switch self {
        case .claude:
            "Claude Code OAuth"
        case .chatgpt:
            "Codex CLI OAuth"
        case .antigravity:
            "Antigravity CLI (agy)"
        }
    }
}

enum UsageUnit: String, Codable, Equatable, Hashable, Sendable {
    case percent
    case tokens
    case requests
    case currency

    var displayName: String {
        switch self {
        case .percent:
            "percent"
        case .tokens:
            "tokens"
        case .requests:
            "requests"
        case .currency:
            "cost"
        }
    }
}

struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let used: Double
    let limit: Double?
    let unit: UsageUnit
    let resetDate: Date?
    let providerReportedPercentage: Bool
    var periodSeconds: Double? = nil

    init(
        id: String,
        label: String,
        used: Double,
        limit: Double?,
        unit: UsageUnit,
        resetDate: Date?,
        providerReportedPercentage: Bool,
        periodSeconds: Double? = nil
    ) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = normalizedID.isEmpty ? "usage" : normalizedID
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = resolvedID
        self.label = normalizedLabel.isEmpty ? resolvedID : normalizedLabel
        self.used = used
        self.limit = limit.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        }
        self.unit = unit
        self.resetDate = resetDate
        self.providerReportedPercentage = providerReportedPercentage
        self.periodSeconds = periodSeconds.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        }
    }

    var percentUsed: Double? {
        guard let limit,
              limit.isFinite,
              limit > 0,
              used.isFinite,
              used >= 0 else {
            return nil
        }

        let percentage = (used / limit) * 100
        guard percentage.isFinite else { return nil }
        return min(max(percentage, 0), 100)
    }
}

enum UsageNumberFormatter {
    static func roundedIntegerString(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        if let integer = Int(exactly: rounded) {
            return String(integer)
        }
        return String(format: "%.0f", value)
    }

    static func truncatedInteger(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }

    static func compactTokenString(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else { return nil }

        let divisor: Double
        let suffix: String
        switch value {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1_000...:
            divisor = 1_000
            suffix = "K"
        default:
            return roundedIntegerString(value)
        }

        let scaled = value / divisor
        guard scaled.isFinite else { return nil }
        return String(format: "%.1f%@", scaled, suffix)
    }

    static func currencyString(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else { return nil }
        if value > 0, value < 0.01 {
            return String(format: "$%.4f", value)
        }
        return String(format: "$%.2f", value)
    }
}

struct ModelUsageSummary: Equatable, Identifiable, Sendable {
    let modelID: String
    let requestCount: Int
    let inputTokens: Double
    let outputTokens: Double
    let cacheReadTokens: Double
    let cacheWriteTokens: Double
    let totalTokens: Double
    let estimatedCost: Double?

    var id: String { modelID }

    init(
        modelID: String,
        requestCount: Int,
        inputTokens: Double,
        outputTokens: Double,
        cacheReadTokens: Double,
        cacheWriteTokens: Double,
        totalTokens: Double? = nil,
        estimatedCost: Double? = nil
    ) {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = normalizedModelID.isEmpty ? "Unknown model" : normalizedModelID
        self.requestCount = max(0, requestCount)
        self.inputTokens = Self.nonNegativeFinite(inputTokens)
        self.outputTokens = Self.nonNegativeFinite(outputTokens)
        self.cacheReadTokens = Self.nonNegativeFinite(cacheReadTokens)
        self.cacheWriteTokens = Self.nonNegativeFinite(cacheWriteTokens)

        let calculatedTotal = self.inputTokens
            + self.outputTokens
            + self.cacheReadTokens
            + self.cacheWriteTokens
        let resolvedTotal = totalTokens.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        } ?? calculatedTotal
        self.totalTokens = resolvedTotal.isFinite && resolvedTotal >= 0 ? resolvedTotal : 0
        self.estimatedCost = estimatedCost.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }
    }

    private static func nonNegativeFinite(_ value: Double) -> Double {
        guard value.isFinite, value >= 0 else { return 0 }
        return value
    }
}

struct UsageSnapshot: Equatable, Sendable {
    let windows: [UsageWindow]
    let updatedAt: Date
    let accountLabel: String?
    let planLabel: String?
    /// Paid-through date reported by the provider; nil when unknown.
    let subscriptionRenewsAt: Date?
    let sourceLabel: String
    var savedResetCount: Int? = nil
    let modelUsage: [ModelUsageSummary]
    let unattributedModelRequestCount: Int
    let modelPricing: ModelPricingCatalog?

    init(
        windows: [UsageWindow],
        updatedAt: Date,
        accountLabel: String?,
        planLabel: String?,
        subscriptionRenewsAt: Date? = nil,
        sourceLabel: String,
        savedResetCount: Int? = nil,
        modelUsage: [ModelUsageSummary] = [],
        unattributedModelRequestCount: Int = 0,
        modelPricing: ModelPricingCatalog? = nil
    ) {
        self.windows = Self.normalizedWindows(windows)
        self.updatedAt = updatedAt
        self.accountLabel = accountLabel
        self.planLabel = planLabel
        self.subscriptionRenewsAt = subscriptionRenewsAt
        self.sourceLabel = sourceLabel
        self.savedResetCount = savedResetCount.flatMap { $0 >= 0 ? $0 : nil }
        self.modelUsage = modelUsage
        self.unattributedModelRequestCount = max(0, unattributedModelRequestCount)
        self.modelPricing = modelPricing
    }

    var savedResetLabel: String? {
        guard let savedResetCount, savedResetCount >= 0 else { return nil }
        return "\(savedResetCount) saved \(savedResetCount == 1 ? "reset" : "resets")"
    }

    /// Hidden once passed: the token claim is only refreshed at login, so a past date is stale.
    func subscriptionRenewalLabel(now: Date = Date()) -> String? {
        guard let subscriptionRenewsAt, subscriptionRenewsAt > now else { return nil }
        return "Renews \(subscriptionRenewsAt.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    var estimatedCost: Double? {
        guard !modelUsage.isEmpty,
              modelUsage.allSatisfy({ $0.estimatedCost != nil }) else {
            return nil
        }

        return pricedModelCost
    }

    var pricedModelCost: Double? {
        var total = 0.0
        var hasPrice = false
        for usage in modelUsage {
            guard let cost = usage.estimatedCost else { continue }
            total += cost
            hasPrice = true
        }
        return hasPrice && total.isFinite && total >= 0 ? total : nil
    }

    var totalModelTokens: Double? {
        guard !modelUsage.isEmpty else { return nil }
        let total = modelUsage.reduce(0) { $0 + $1.totalTokens }
        return total.isFinite && total >= 0 ? total : nil
    }

    var hasUnpricedModelUsage: Bool {
        modelUsage.contains { $0.estimatedCost == nil }
    }

    var hasModelUsage: Bool {
        !modelUsage.isEmpty || unattributedModelRequestCount > 0
    }

    var modelUsageDetail: String? {
        guard hasModelUsage else { return nil }
        var parts = ["Local OMP · \(OMPModelUsageSource.lookbackLabel)"]
        if let tokens = totalModelTokens,
           let formatted = UsageNumberFormatter.compactTokenString(tokens) {
            parts.append("\(formatted) tokens incl. cache · \(modelUsage.count) models")
        } else {
            parts.append("No account-linked records")
        }
        if let cost = pricedModelCost, let formatted = UsageNumberFormatter.currencyString(cost) {
            let label = hasUnpricedModelUsage ? "priced subtotal" : (modelPricing?.estimateLabel ?? "estimate")
            parts.append("\(label) ≈ \(formatted), not billed")
        } else {
            parts.append("cost unavailable")
        }
        if let modelPricing {
            parts.append(modelPricing.compactAssumptions)
        }
        if unattributedModelRequestCount > 0 {
            parts.append("\(unattributedModelRequestCount) unassigned provider records excluded")
        }
        return parts.joined(separator: " · ")
    }

    func withModelUsage(_ report: OMPModelUsageReport) -> UsageSnapshot {
        UsageSnapshot(
            windows: windows,
            updatedAt: updatedAt,
            accountLabel: accountLabel,
            planLabel: planLabel,
            subscriptionRenewsAt: subscriptionRenewsAt,
            sourceLabel: sourceLabel,
            savedResetCount: savedResetCount,
            modelUsage: report.summaries,
            unattributedModelRequestCount: report.unattributedRequestCount,
            modelPricing: report.pricing
        )
    }

    private static func normalizedWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        var usedIDs = Set<String>()
        return windows.map { window in
            let baseID = window.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedID = baseID.isEmpty ? "usage" : baseID
            var uniqueID = normalizedID
            if !usedIDs.insert(uniqueID).inserted {
                var suffix = 2
                repeat {
                    uniqueID = "\(normalizedID)-\(suffix)"
                    suffix += 1
                } while !usedIDs.insert(uniqueID).inserted
            }
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
    }
}


enum ProviderState: Equatable, Sendable {
    case loading
    case authenticated(accountLabel: String?)
    case unavailable(message: String)
    case usage(UsageSnapshot)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var snapshot: UsageSnapshot? {
        if case let .usage(snapshot) = self { return snapshot }
        return nil
    }

    var errorMessage: String? {
        if case let .unavailable(message) = self { return message }
        return nil
    }
}
enum ProviderSyncStatus: Equatable, Sendable {
    case checking
    case synced
    case partial
    case setup

    var label: String {
        switch self {
        case .checking:
            "CHECKING"
        case .synced:
            "SYNCED"
        case .partial:
            "PARTIAL"
        case .setup:
            "SETUP"
        }
    }
}
struct ProviderRecord: Equatable, Identifiable, Sendable {
    let recordID: String
    let provider: Provider
    let accountLabel: String?
    let planLabel: String?
    let isActive: Bool
    let isEnabled: Bool
    let hasUsableCredentials: Bool
    var state: ProviderState

    var id: String { recordID }

    init(
        recordID: String,
        provider: Provider,
        accountLabel: String? = nil,
        planLabel: String? = nil,
        isActive: Bool = false,
        isEnabled: Bool = true,
        hasUsableCredentials: Bool = false,
        state: ProviderState
    ) {
        self.recordID = recordID
        self.provider = provider
        self.accountLabel = accountLabel
        self.planLabel = planLabel
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.hasUsableCredentials = hasUsableCredentials
        self.state = state
    }

    init(provider: Provider, state: ProviderState) {
        self.init(
            recordID: provider.rawValue,
            provider: provider,
            accountLabel: nil,
            isActive: false,
            state: state
        )
    }

    var displayAccountLabel: String? {
        if let accountLabel = Self.nonEmpty(accountLabel) {
            return accountLabel
        }

        switch state {
        case let .authenticated(accountLabel):
            return Self.nonEmpty(accountLabel)
        case let .usage(snapshot):
            return Self.nonEmpty(snapshot.accountLabel)
        default:
            return nil
        }
    }

    var displayPlanLabel: String? {
        if case let .usage(snapshot) = state,
           let planLabel = AccountPlanLabel.displayName(for: snapshot.planLabel) {
            return planLabel
        }
        return AccountPlanLabel.displayName(for: planLabel)
    }

    var planStatusLabel: String? {
        displayPlanLabel ?? (provider == .chatgpt ? "Plan unavailable" : nil)
    }

    var requiresSetup: Bool {
        guard isEnabled else { return true }
        switch state {
        case .authenticated, .usage:
            return false
        case .loading, .unavailable:
            return !hasUsableCredentials
        }
    }

    var showsInCompactRail: Bool {
        if provider == .chatgpt || isActive { return true }
        switch state {
        case .authenticated, .usage:
            return true
        case .loading, .unavailable:
            return !requiresSetup
        }
    }

    static func compactRailOrder(_ records: [ProviderRecord]) -> [ProviderRecord] {
        presentationOrder(records.filter { $0.showsInCompactRail })
    }

    static func consolidatedCodexPresentation(_ records: [ProviderRecord]) -> [ProviderRecord] {
        let codexRecords = records.filter { $0.provider == .chatgpt }
        guard let consolidated = CodexUsageAggregation.record(from: codexRecords) else {
            return presentationOrder(records)
        }

        let otherRecords = records.filter { $0.provider != .chatgpt }
        return presentationOrder(otherRecords + [consolidated])
    }

    static func presentationOrder(_ records: [ProviderRecord]) -> [ProviderRecord] {
        let orderByProvider: ([ProviderRecord]) -> [ProviderRecord] = { records in
            Provider.allCases.flatMap { provider in
                records
                    .filter { $0.provider == provider }
                    .sorted { lhs, rhs in
                        if lhs.isActive != rhs.isActive { return lhs.isActive }
                        return (lhs.displayAccountLabel ?? lhs.id)
                            .localizedCaseInsensitiveCompare(rhs.displayAccountLabel ?? rhs.id) == .orderedAscending
                    }
            }
        }

        let configuredRecords = records.filter { !$0.requiresSetup }
        let setupRecords = records.filter(\.requiresSetup)
        return orderByProvider(configuredRecords) + orderByProvider(setupRecords)
    }

    static func syncStatus(
        for records: [ProviderRecord],
        isRefreshing: Bool
    ) -> ProviderSyncStatus {
        if isRefreshing || records.contains(where: { $0.state.isLoading }) {
            return .checking
        }
        guard !records.isEmpty else { return .setup }
        if records.allSatisfy({ $0.state.snapshot != nil }) {
            return .synced
        }
        if records.contains(where: { $0.state.snapshot != nil }) {
            return .partial
        }
        return .setup
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum CodexUsageAggregation {
    private struct UsageEntry {
        let snapshot: UsageSnapshot
    }

    private struct WindowKey: Hashable {
        let id: String
        let unit: UsageUnit
        let periodSeconds: Double?
        let fallbackLabel: String?
    }

    static func record(from records: [ProviderRecord]) -> ProviderRecord? {
        guard !records.isEmpty else { return nil }

        let entries = records.compactMap { record -> UsageEntry? in
            guard case let .usage(snapshot) = record.state else { return nil }
            return UsageEntry(snapshot: snapshot)
        }

        let state: ProviderState
        let windows = aggregateWindows(from: entries, totalAccounts: records.count)
        if !windows.isEmpty {
            let updatedAt = entries.map(\.snapshot.updatedAt).max() ?? Date()
            let resetCounts = entries.compactMap(\.snapshot.savedResetCount)
            state = .usage(UsageSnapshot(
                windows: windows,
                updatedAt: updatedAt,
                accountLabel: "All Codex accounts · \(records.count)",
                planLabel: consolidatedPlanLabel(records: records),
                sourceLabel: "Codex CLI OAuth · \(records.count) accounts consolidated",
                savedResetCount: summedResetCount(resetCounts, expectedCount: records.count),
                modelUsage: aggregateModelUsage(from: entries),
                // Each account reports the same provider-wide unassigned history.
                unattributedModelRequestCount: entries.reduce(0) { max($0, $1.snapshot.unattributedModelRequestCount) },
                modelPricing: entries.lazy.compactMap(\.snapshot.modelPricing).first
            ))
        } else if records.contains(where: { $0.state.isLoading }) {
            state = .loading
        } else if records.contains(where: {
            if case .authenticated = $0.state { return true }
            return false
        }) {
            state = .authenticated(accountLabel: "Waiting for all \(records.count) Codex accounts to report usage.")
        } else {
            state = .unavailable(message: "No Codex account returned a usable usage window. Review individual accounts in Settings.")
        }

        return ProviderRecord(
            recordID: "chatgpt:consolidated",
            provider: .chatgpt,
            accountLabel: "All Codex accounts · \(records.count)",
            planLabel: consolidatedPlanLabel(records: records),
            state: state
        )
    }

    private static func aggregateWindows(
        from entries: [UsageEntry],
        totalAccounts: Int
    ) -> [UsageWindow] {
        var grouped: [WindowKey: [UsageWindow]] = [:]
        var order: [WindowKey] = []

        for entry in entries {
            for window in entry.snapshot.windows {
                guard let limit = window.limit,
                      limit.isFinite,
                      limit > 0,
                      window.used.isFinite,
                      window.used >= 0 else {
                    continue
                }

                let periodSeconds = window.periodSeconds.flatMap { rawValue -> Double? in
                    guard rawValue.isFinite, rawValue > 0 else { return nil }
                    return rawValue
                }
                let fallbackLabel = periodSeconds == nil
                    ? normalizedWindowLabel(window.label)
                    : nil
                let key = WindowKey(
                    id: window.id,
                    unit: window.unit,
                    periodSeconds: periodSeconds,
                    fallbackLabel: fallbackLabel
                )
                if grouped[key] == nil {
                    order.append(key)
                }
                grouped[key, default: []].append(window)
            }
        }

        return order.compactMap { key -> UsageWindow? in
            guard let windows = grouped[key],
                  !windows.isEmpty else { return nil }

            let totalUsed = windows.reduce(0) { $0 + $1.used }
            let totalLimit = windows.compactMap(\.limit).reduce(0, +)
            guard totalUsed.isFinite,
                  totalLimit.isFinite,
                  totalLimit > 0 else {
                return nil
            }

            let label = windows.count == totalAccounts
                ? windows[0].label
                : "\(windows[0].label) · \(windows.count)/\(totalAccounts) accounts"

            return UsageWindow(
                id: key.id,
                label: label,
                used: totalUsed,
                limit: totalLimit,
                unit: key.unit,
                resetDate: commonResetDate(windows),
                providerReportedPercentage: windows.allSatisfy(\.providerReportedPercentage),
                periodSeconds: key.periodSeconds
            )
        }
    }
    private static func aggregateModelUsage(from entries: [UsageEntry]) -> [ModelUsageSummary] {
        var grouped: [String: [ModelUsageSummary]] = [:]
        var order: [String] = []

        for entry in entries {
            for summary in entry.snapshot.modelUsage {
                if grouped[summary.modelID] == nil {
                    order.append(summary.modelID)
                }
                grouped[summary.modelID, default: []].append(summary)
            }
        }

        return order.compactMap { modelID in
            guard let summaries = grouped[modelID], !summaries.isEmpty else { return nil }

            var requestCount = 0
            var inputTokens = 0.0
            var outputTokens = 0.0
            var cacheReadTokens = 0.0
            var cacheWriteTokens = 0.0
            var totalTokens = 0.0
            var estimatedCost = 0.0
            var hasCompleteCost = true

            for summary in summaries {
                let (nextRequestCount, requestOverflow) = requestCount.addingReportingOverflow(summary.requestCount)
                guard !requestOverflow else { return nil }
                requestCount = nextRequestCount
                inputTokens += summary.inputTokens
                outputTokens += summary.outputTokens
                cacheReadTokens += summary.cacheReadTokens
                cacheWriteTokens += summary.cacheWriteTokens
                totalTokens += summary.totalTokens
                if let cost = summary.estimatedCost {
                    estimatedCost += cost
                } else {
                    hasCompleteCost = false
                }
            }

            guard inputTokens.isFinite,
                  outputTokens.isFinite,
                  cacheReadTokens.isFinite,
                  cacheWriteTokens.isFinite,
                  totalTokens.isFinite,
                  inputTokens >= 0,
                  outputTokens >= 0,
                  cacheReadTokens >= 0,
                  cacheWriteTokens >= 0,
                  totalTokens >= 0 else {
                return nil
            }
            if hasCompleteCost {
                guard estimatedCost.isFinite, estimatedCost >= 0 else { return nil }
            }

            return ModelUsageSummary(
                modelID: modelID,
                requestCount: requestCount,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                totalTokens: totalTokens,
                estimatedCost: hasCompleteCost ? estimatedCost : nil
            )
        }
    }

    private static func normalizedWindowLabel(_ label: String) -> String {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? "usage" : normalized
    }

    private static func commonResetDate(_ windows: [UsageWindow]) -> Date? {
        let dates = windows.compactMap(\.resetDate)
        guard dates.count == windows.count,
              let first = dates.first,
              dates.dropFirst().allSatisfy({ abs($0.timeIntervalSince(first)) < 1 }) else {
            return nil
        }
        return first
    }

    private static func consolidatedPlanLabel(records: [ProviderRecord]) -> String? {
        let values = records.compactMap { record -> String? in
            if case let .usage(snapshot) = record.state,
               let snapshotPlan = nonEmpty(snapshot.planLabel) {
                return snapshotPlan
            }
            return nonEmpty(record.planLabel)
        }
        guard values.count == records.count,
              let first = values.first else {
            return nil
        }

        let normalized = Set(values.map {
            $0.lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
        })
        return normalized.count == 1 ? first : "multiple_plans"
    }

    private static func summedResetCount(_ counts: [Int], expectedCount: Int) -> Int? {
        guard counts.count == expectedCount,
              counts.allSatisfy({ $0 >= 0 }) else {
            return nil
        }

        var total = 0
        for count in counts {
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AccountPlanLabel {
    static func displayName(for rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "free", "chatgpt_free", "chatgptfree":
            return "Free"
        case "go", "chatgpt_go", "chatgptgo":
            return "Go"
        case "plus", "chatgpt_plus", "chatgptplus":
            return "Plus"
        case "pro", "chatgpt_pro", "chatgptpro":
            return "Pro"
        case "team", "chatgpt_team":
            return "Team"
        case "business", "chatgpt_business":
            return "Business"
        case "enterprise", "chatgpt_enterprise":
            return "Enterprise"
        case "edu", "education", "chatgpt_edu":
            return "Edu"
        default:
            return trimmed
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }
}

protocol UsageProviderAdapter: Sendable {
    var provider: Provider { get }
    var recordID: String { get }
    var accountLabel: String? { get }
    var isActive: Bool { get }
    var hasUsableCredentials: Bool { get }
    var planLabel: String? { get }
    func fetch() async -> ProviderState
}

extension UsageProviderAdapter {
    var recordID: String { provider.rawValue }
    var accountLabel: String? { nil }
    var isActive: Bool { false }
    var hasUsableCredentials: Bool { isActive }
    var planLabel: String? { nil }
}
