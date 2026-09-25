import CryptoKit
import Darwin
import Foundation

struct OMPAccountIdentity: Equatable, Sendable {
    let provider: String
    let accountID: String?
    let email: String?
    let organizationID: String?
    let projectID: String?

    init(
        provider: String,
        accountID: String? = nil,
        email: String? = nil,
        organizationID: String? = nil,
        projectID: String? = nil
    ) {
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountID = Self.normalized(accountID)
        self.email = Self.normalized(email)
        self.organizationID = Self.normalized(organizationID)
        self.projectID = Self.normalized(projectID)
    }

    var credentialPinHash: String? {
        guard accountID != nil || email != nil else { return nil }

        let value = [
            provider,
            accountID ?? "",
            email ?? "",
            organizationID ?? "",
            projectID ?? ""
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct OMPModelUsageReport: Sendable {
    let summaries: [ModelUsageSummary]
    let unattributedRequestCount: Int
    let pricing: ModelPricingCatalog?
}

actor OMPModelUsageSource {
    static let lookbackInterval: TimeInterval = 30 * 24 * 60 * 60
    static let lookbackLabel = "last 30 days"

    private let sessionsDirectory: URL
    private let cacheLifetime: TimeInterval
    private var cachedSessions: [URL: CachedSession] = [:]
    private var sessionOrder: [URL] = []
    private var cachedAt: Date?

    init(
        sessionsDirectory: URL? = nil,
        cacheLifetime: TimeInterval = 2
    ) {
        let directory = sessionsDirectory ?? Self.defaultSessionsDirectory()
        self.sessionsDirectory = directory.standardizedFileURL
        self.cacheLifetime = cacheLifetime.isFinite && cacheLifetime > 0 ? cacheLifetime : 0
    }

    func report(
        for identity: OMPAccountIdentity,
        now: Date = Date()
    ) -> OMPModelUsageReport {
        let credentialPinHash = identity.credentialPinHash
        let provider = identity.provider.lowercased()

        refreshEvents()
        let cutoff = now.addingTimeInterval(-Self.lookbackInterval)
        var grouped: [String: ModelUsageAccumulator] = [:]
        var order: [String] = []
        var unattributedRequestCount = 0
        for fileURL in sessionOrder {
            guard let session = cachedSessions[fileURL] else { continue }
            for event in session.events where event.provider == provider
                && event.timestamp >= cutoff && event.timestamp <= now {
                guard let eventPin = event.credentialPinHash else {
                    unattributedRequestCount += 1
                    continue
                }
                guard eventPin == credentialPinHash else { continue }
                if grouped[event.modelID] == nil {
                    grouped[event.modelID] = ModelUsageAccumulator()
                    order.append(event.modelID)
                }
                grouped[event.modelID]?.add(event)
            }
        }
        return OMPModelUsageReport(
            summaries: order.compactMap { grouped[$0]?.summary(modelID: $0) },
            unattributedRequestCount: unattributedRequestCount,
            pricing: ModelPricingCatalog(ompProvider: provider)
        )
    }

    private static func defaultSessionsDirectory() -> URL {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let agentDirectory: URL
        if let configured = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            agentDirectory = URL(fileURLWithPath: configured)
        } else {
            agentDirectory = homeDirectory.appendingPathComponent(".omp/agent", isDirectory: true)
        }
        return agentDirectory
            .standardizedFileURL
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private func refreshEvents() {
        if let cachedAt, Date().timeIntervalSince(cachedAt) < cacheLifetime { return }
        var sessions: [URL: CachedSession] = [:]
        var order: [URL] = []
        defer {
            cachedSessions = sessions
            sessionOrder = order
            cachedAt = Date()
        }
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory, includingPropertiesForKeys: nil, options: []
        ) else { return }

        let decoder = JSONDecoder()
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  let stamp = SessionFileStamp(fileURL) else { continue }
            if let cached = cachedSessions[fileURL], cached.stamp == stamp {
                sessions[fileURL] = cached
            } else {
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                // A concurrent writer must not make a partial read reusable.
                let stableStamp = SessionFileStamp(fileURL) == stamp ? stamp : nil
                sessions[fileURL] = CachedSession(
                    stamp: stableStamp, events: Self.parseEvents(data, decoder: decoder)
                )
            }
            order.append(fileURL)
        }
        // Replacing the cache also removes deleted or unreadable session files.
    }

    private static func parseEvents(_ data: Data, decoder: JSONDecoder) -> [OMPPinnedModelUsageEvent] {
        var events: [OMPPinnedModelUsageEvent] = []
        var pinsByProvider: [String: String] = [:]
        var serviceTier: CodexServiceTier = .standard
        for line in data.split(whereSeparator: { $0 == 0x0A }) {
            guard let entry = try? decoder.decode(OMPSessionEntry.self, from: line) else { continue }
            if entry.type == "credential_pin" {
                guard let provider = normalized(entry.provider),
                      let hash = normalized(entry.hash) else { continue }
                pinsByProvider[provider.lowercased()] = hash.lowercased()
                continue
            }
            if entry.type == "service_tier_change" {
                serviceTier = entry.serviceTier ?? .unsupported
                continue
            }
            if entry.type == "model_usage",
               let event = makeEvent(
                   provider: entry.provider, modelID: entry.model, usage: entry.usage,
                   timestamp: entry.timestamp?.date, serviceTier: serviceTier, pinsByProvider: pinsByProvider
               ) {
                events.append(event)
                continue
            }
            guard entry.type == "message", let message = entry.message,
                  message.role == "assistant" else { continue }
            if let event = makeEvent(
                provider: message.provider, modelID: message.model, usage: message.usage,
                timestamp: message.timestamp?.date ?? entry.timestamp?.date,
                serviceTier: serviceTier, pinsByProvider: pinsByProvider
            ) {
                events.append(event)
            }
        }
        return events
    }

    private static func makeEvent(
        provider: String?,
        modelID: String?,
        usage: OMPTokenUsagePayload?,
        timestamp: Date?,
        serviceTier: CodexServiceTier,
        pinsByProvider: [String: String]
    ) -> OMPPinnedModelUsageEvent? {
        guard let provider = normalized(provider),
              let modelID = normalized(modelID),
              let usage,
              let timestamp else {
            return nil
        }

        return OMPPinnedModelUsageEvent(
            provider: provider.lowercased(),
            credentialPinHash: pinsByProvider[provider.lowercased()],
            modelID: modelID,
            timestamp: timestamp,
            usage: usage,
            serviceTier: serviceTier
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CachedSession {
    let stamp: SessionFileStamp?
    let events: [OMPPinnedModelUsageEvent]
}

// Size and modification time alone miss same-size rewrites and replacements.
private struct SessionFileStamp: Equatable {
    private let device: dev_t
    private let inode: ino_t
    private let size: off_t
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    init?(_ url: URL) {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return fstatat(AT_FDCWD, path, &info, 0)
        }
        guard result == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

private struct OMPPinnedModelUsageEvent: Sendable {
    let provider: String
    let credentialPinHash: String?
    let modelID: String
    let timestamp: Date
    let usage: OMPTokenUsagePayload
    let serviceTier: CodexServiceTier
}

private struct ModelUsageAccumulator: Sendable {
    private var requestCount = 0
    private var inputTokens = 0.0
    private var outputTokens = 0.0
    private var cacheReadTokens = 0.0
    private var cacheWriteTokens = 0.0
    private var totalTokens = 0.0
    private var estimatedCost = 0.0
    private var hasCompleteCost = true
    private var isValid = true

    mutating func add(_ event: OMPPinnedModelUsageEvent) {
        let usage = event.usage
        let (nextRequestCount, requestOverflow) = requestCount.addingReportingOverflow(1)
        guard !requestOverflow else {
            isValid = false
            return
        }

        let nextInputTokens = inputTokens + usage.inputValue
        let nextOutputTokens = outputTokens + usage.outputValue
        let nextCacheReadTokens = cacheReadTokens + usage.cacheReadValue
        let nextCacheWriteTokens = cacheWriteTokens + usage.cacheWriteValue
        let nextTotalTokens = totalTokens + usage.totalValue
        guard nextInputTokens.isFinite, nextInputTokens >= 0,
              nextOutputTokens.isFinite, nextOutputTokens >= 0,
              nextCacheReadTokens.isFinite, nextCacheReadTokens >= 0,
              nextCacheWriteTokens.isFinite, nextCacheWriteTokens >= 0,
              nextTotalTokens.isFinite, nextTotalTokens >= 0 else {
            isValid = false
            return
        }

        requestCount = nextRequestCount
        inputTokens = nextInputTokens
        outputTokens = nextOutputTokens
        cacheReadTokens = nextCacheReadTokens
        cacheWriteTokens = nextCacheWriteTokens
        totalTokens = nextTotalTokens

        if let cost = usage.estimatedCost(provider: event.provider, modelID: event.modelID, serviceTier: event.serviceTier) {
            let nextEstimatedCost = estimatedCost + cost
            guard nextEstimatedCost.isFinite, nextEstimatedCost >= 0 else {
                isValid = false
                return
            }
            estimatedCost = nextEstimatedCost
        } else {
            hasCompleteCost = false
        }
    }

    func summary(modelID: String) -> ModelUsageSummary? {
        guard isValid,
              requestCount > 0 else {
            return nil
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

private struct OMPSessionEntry: Decodable, Sendable {
    let type: String?
    let timestamp: OMPHistoryDate?
    let provider: String?
    let model: String?
    let hash: String?
    let usage: OMPTokenUsagePayload?
    let message: OMPHistoryMessage?
    let serviceTier: CodexServiceTier?

    private enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case provider
        case model
        case hash
        case usage
        case message
        case serviceTier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decode(String.self, forKey: .type)
        if type == "model_usage" || type == "message" {
            timestamp = try? container.decode(OMPHistoryDate.self, forKey: .timestamp)
        } else {
            timestamp = nil
        }
        provider = try? container.decode(String.self, forKey: .provider)
        model = try? container.decode(String.self, forKey: .model)
        hash = try? container.decode(String.self, forKey: .hash)
        usage = try? container.decode(OMPTokenUsagePayload.self, forKey: .usage)
        message = try? container.decode(OMPHistoryMessage.self, forKey: .message)
        serviceTier = type == "service_tier_change"
            ? (try? container.decode(OMPServiceTierSelection.self, forKey: .serviceTier))?.value ?? .unsupported
            : nil
    }
}

private struct OMPHistoryMessage: Decodable, Sendable {
    let role: String?
    let provider: String?
    let model: String?
    let timestamp: OMPHistoryDate?
    let usage: OMPTokenUsagePayload?

    private enum CodingKeys: String, CodingKey {
        case role
        case provider
        case model
        case timestamp
        case usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try? container.decode(String.self, forKey: .role)
        provider = try? container.decode(String.self, forKey: .provider)
        model = try? container.decode(String.self, forKey: .model)
        timestamp = try? container.decode(OMPHistoryDate.self, forKey: .timestamp)
        usage = try? container.decode(OMPTokenUsagePayload.self, forKey: .usage)
    }
}

private struct OMPHistoryDate: Decodable, Sendable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            date = nil
        } else if let value = try? container.decode(FlexibleDouble.self) {
            date = UsageDateParser.epoch(value.value)
        } else if let value = try? container.decode(String.self) {
            date = UsageDateParser.iso8601(value)
        } else {
            date = nil
        }
    }
}

private struct OMPTokenUsagePayload: Decodable, Sendable {
    let input: FlexibleDouble?
    let output: FlexibleDouble?
    let cacheRead: FlexibleDouble?
    let cacheWrite: FlexibleDouble?
    let totalTokens: FlexibleDouble?

    private enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead
        case cacheWrite
        case totalTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try? container.decode(FlexibleDouble.self, forKey: .input)
        output = try? container.decode(FlexibleDouble.self, forKey: .output)
        cacheRead = try? container.decode(FlexibleDouble.self, forKey: .cacheRead)
        cacheWrite = try? container.decode(FlexibleDouble.self, forKey: .cacheWrite)
        totalTokens = try? container.decode(FlexibleDouble.self, forKey: .totalTokens)
    }

    var inputValue: Double { nonNegative(input?.value) }
    var outputValue: Double { nonNegative(output?.value) }
    var cacheReadValue: Double { nonNegative(cacheRead?.value) }
    var cacheWriteValue: Double { nonNegative(cacheWrite?.value) }

    var totalValue: Double {
        if let totalTokens, totalTokens.value.isFinite, totalTokens.value >= 0 {
            return totalTokens.value
        }
        return inputValue + outputValue + cacheReadValue + cacheWriteValue
    }

    func estimatedCost(provider: String, modelID: String, serviceTier: CodexServiceTier) -> Double? {
        // A total alone cannot distinguish expensive output from discounted cached input.
        guard let pricing = ModelPricingCatalog(ompProvider: provider),
              let input = input?.value, let output = output?.value,
              let cacheRead = cacheRead?.value, let cacheWrite = cacheWrite?.value else { return nil }
        let componentTotal = input + output + cacheRead + cacheWrite
        if let totalTokens, totalTokens.value != componentTotal { return nil }
        switch pricing {
        case .openAICodex:
            return CodexModelPricing.estimate(
                modelID: modelID, input: input, output: output,
                cacheRead: cacheRead, cacheWrite: cacheWrite, serviceTier: serviceTier
            )
        case .anthropic:
            // OMP's service tier records only OpenAI speed; Claude assumes standard speed.
            return ClaudeModelPricing.estimate(
                modelID: modelID, input: input, output: output,
                cacheRead: cacheRead, cacheWrite: cacheWrite
            )
        }
    }

    private func nonNegative(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return value
    }
}

private struct OMPServiceTierSelection: Decodable {
    let value: CodexServiceTier

    private enum CodingKeys: String, CodingKey { case openai }

    init(from decoder: Decoder) throws {
        if try decoder.singleValueContainer().decodeNil() {
            value = .standard
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .openai) {
        case nil, "default", "standard": value = .standard
        case "priority", "fast": value = .fast
        default: value = .unsupported
        }
    }
}
