import Foundation

// Claude API list prices; a Claude Pro/Max subscription is not billed per token.
// OMP's recorded per-message cost uses its own catalog, so it is not reused here.
enum ClaudeModelPricing {
    static let verifiedOn = "2026-09-25"
    static let sourceURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    static let assumptions = "Current Claude API list rates, not historical charges. Cache writes assume the 5-minute TTL; Fast mode, Batch, US-only inference, and tool fees excluded."

    private struct Rates {
        let input: Double
        let cacheWrite: Double
        let cacheRead: Double
        let output: Double
    }

    static func estimate(
        modelID: String,
        input: Double,
        output: Double,
        cacheRead: Double,
        cacheWrite: Double
    ) -> Double? {
        guard input.isFinite, input >= 0,
              output.isFinite, output >= 0,
              cacheRead.isFinite, cacheRead >= 0,
              cacheWrite.isFinite, cacheWrite >= 0,
              let rates = rates(for: modelID) else { return nil }

        // OMP input excludes cache reads/writes, matching Anthropic's usage fields.
        // Claude 4.6+ bills the full context window at standard rates.
        let cost = (input * rates.input
            + cacheWrite * rates.cacheWrite
            + cacheRead * rates.cacheRead
            + output * rates.output) / 1_000_000
        return cost.isFinite && cost >= 0 ? cost : nil
    }

    private static func rates(for modelID: String) -> Rates? {
        switch baseModelID(modelID) {
        case "claude-fable-5-1", "claude-mythos-5-1":
            Rates(input: 10, cacheWrite: 12.5, cacheRead: 0.25, output: 50)
        case "claude-fable-5", "claude-mythos-5":
            Rates(input: 10, cacheWrite: 12.5, cacheRead: 1, output: 50)
        case "claude-opus-5-5":
            Rates(input: 4, cacheWrite: 5, cacheRead: 0.2, output: 20)
        case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5":
            Rates(input: 5, cacheWrite: 6.25, cacheRead: 0.5, output: 25)
        case "claude-opus-4-1", "claude-opus-4", "claude-opus-4-0":
            Rates(input: 15, cacheWrite: 18.75, cacheRead: 1.5, output: 75)
        case "claude-sonnet-5":
            Rates(input: 2, cacheWrite: 2.5, cacheRead: 0.2, output: 10)
        case "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4", "claude-sonnet-4-0":
            Rates(input: 3, cacheWrite: 3.75, cacheRead: 0.3, output: 15)
        case "claude-haiku-4-5":
            Rates(input: 1, cacheWrite: 1.25, cacheRead: 0.1, output: 5)
        case "claude-3-5-haiku":
            Rates(input: 0.8, cacheWrite: 1, cacheRead: 0.08, output: 4)
        default:
            // Unlisted models (e.g. announced but unpriced) stay unpriced, never borrowed.
            nil
        }
    }

    /// Drops a dated snapshot suffix such as `-20251001`; snapshots share their alias's price.
    private static func baseModelID(_ modelID: String) -> String {
        let id = modelID.lowercased()
        guard let dash = id.lastIndex(of: "-") else { return id }
        let suffix = id[id.index(after: dash)...]
        guard suffix.count == 8, suffix.allSatisfy(\.isASCIIDigit) else { return id }
        return String(id[..<dash])
    }
}

/// Which published rate card priced a snapshot's local model usage.
enum ModelPricingCatalog: Equatable, Sendable {
    case openAICodex
    case anthropic

    init?(ompProvider: String) {
        switch ompProvider.lowercased() {
        case "openai-codex": self = .openAICodex
        case "anthropic": self = .anthropic
        default: return nil
        }
    }

    var estimateLabel: String {
        switch self {
        case .openAICodex: "Codex estimate"
        case .anthropic: "Claude API estimate"
        }
    }

    var rateLinkTitle: String {
        switch self {
        case .openAICodex: "OpenAI rates · verified \(CodexModelPricing.verifiedOn)"
        case .anthropic: "Anthropic rates · verified \(ClaudeModelPricing.verifiedOn)"
        }
    }

    var sourceURL: URL {
        switch self {
        case .openAICodex: CodexModelPricing.sourceURL
        case .anthropic: ClaudeModelPricing.sourceURL
        }
    }

    var assumptions: String {
        switch self {
        case .openAICodex: CodexModelPricing.assumptions
        case .anthropic: ClaudeModelPricing.assumptions
        }
    }

    var compactAssumptions: String {
        switch self {
        case .openAICodex:
            "rates \(CodexModelPricing.verifiedOn); Standard if speed missing; no regional/tool fees"
        case .anthropic:
            "API rates \(ClaudeModelPricing.verifiedOn); 5m cache writes; no Fast/US-only/tool fees"
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
