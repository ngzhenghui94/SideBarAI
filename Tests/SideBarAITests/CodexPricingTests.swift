import Testing
@testable import SideBarAI

struct CodexPricingTests {
    @Test
    func gpt61SolIsPricedAtItsOwnCachedRate() throws {
        // 100k each of input, cached input and output stays under the 272k long-context line: $0.20 + $0.01 + $1.
        let cost = try #require(CodexModelPricing.estimate(
            modelID: "gpt-6.1-sol", input: 100_000, output: 100_000,
            cacheRead: 100_000, cacheWrite: 0, serviceTier: .standard
        ))
        #expect(abs(cost - 1.21) < 1e-9)
        #expect(CodexModelPricing.estimate(
            modelID: "gpt-6.1-sol", input: 1, output: 1, cacheRead: 0, cacheWrite: 0, serviceTier: .fast
        ) == nil)
    }
}
