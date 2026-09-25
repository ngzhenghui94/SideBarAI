import Foundation

// OMP's openai-codex provider uses ChatGPT authentication, not API-key billing.
// Rates and product-specific exceptions verified against this OpenAI rate card.
enum CodexModelPricing {
    static let verifiedOn = "2026-09-25"
    static let sourceURL = URL(string: "https://help.openai.com/en/articles/20001415-chatgpt-rate-card-enterprise-token-based-pricing")!
    static let assumptions = "Current Codex rates, not historical charges. Recorded Fast mode is applied; missing speed assumes Standard. Regional and tool fees excluded."

    private struct Rates {
        let input: Double
        let cachedInput: Double
        let output: Double
        let longContext: Bool
        let fastMultiplier: Double?
    }

    static func estimate(
        modelID: String,
        input: Double,
        output: Double,
        cacheRead: Double,
        cacheWrite: Double,
        serviceTier: CodexServiceTier
    ) -> Double? {
        guard input.isFinite, input >= 0,
              output.isFinite, output >= 0,
              cacheRead.isFinite, cacheRead >= 0,
              cacheWrite.isFinite, cacheWrite >= 0,
              let rates = rates(for: modelID) else { return nil }

        let multiplier: Double
        switch serviceTier {
        case .standard:
            multiplier = 1
        case .fast:
            guard let fastMultiplier = rates.fastMultiplier else { return nil }
            multiplier = fastMultiplier
        case .unsupported:
            return nil
        }

        // OMP input excludes cache reads/writes; context size includes all prompt tokens.
        let promptTokens = input + cacheRead + cacheWrite
        guard promptTokens.isFinite else { return nil }
        let isLongContext = rates.longContext && promptTokens > 272_000
        let inputMultiplier = isLongContext ? 2.0 : 1.0
        let outputMultiplier = isLongContext ? 1.5 : 1.0
        // Codex does not charge cache writes. Astra has no Codex long-context surcharge.
        let cost = ((input * rates.input + cacheRead * rates.cachedInput) * inputMultiplier
            + output * rates.output * outputMultiplier) * multiplier / 1_000_000
        return cost.isFinite && cost >= 0 ? cost : nil
    }

    private static func rates(for modelID: String) -> Rates? {
        switch modelID {
        case "gpt-6-astra":
            Rates(input: 10, cachedInput: 1, output: 50, longContext: false, fastMultiplier: 2.5)
        case "gpt-6-sol":
            Rates(input: 2, cachedInput: 0.2, output: 10, longContext: true, fastMultiplier: 2.5)
        case "gpt-6-luna":
            Rates(input: 0.1, cachedInput: 0.01, output: 0.5, longContext: true, fastMultiplier: 2.5)
        case "gpt-5.6-sol":
            Rates(input: 4, cachedInput: 0.4, output: 20, longContext: true, fastMultiplier: 2.5)
        case "gpt-5.6-terra":
            Rates(input: 2, cachedInput: 0.2, output: 12, longContext: true, fastMultiplier: 2.5)
        case "gpt-5.6-luna":
            Rates(input: 0.2, cachedInput: 0.02, output: 1.2, longContext: true, fastMultiplier: 2.5)
        case "gpt-5.5":
            Rates(input: 5, cachedInput: 0.5, output: 30, longContext: true, fastMultiplier: 2.5)
        case "gpt-5.4":
            Rates(input: 2.5, cachedInput: 0.25, output: 15, longContext: true, fastMultiplier: 2)
        case "gpt-5.4-mini":
            Rates(input: 0.75, cachedInput: 0.075, output: 4.5, longContext: false, fastMultiplier: nil)
        case "gpt-5.3-codex", "gpt-5.2":
            Rates(input: 1.75, cachedInput: 0.175, output: 14, longContext: false, fastMultiplier: nil)
        default:
            // In particular, Spark has no final published rate; never borrow Codex's rate.
            nil
        }
    }
}

enum CodexServiceTier: Sendable {
    case standard
    case fast
    case unsupported
}
