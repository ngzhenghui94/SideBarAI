import Foundation

enum DefaultUsageAdapters {
    static func makeCodex(
        ompUsageSource: OMPUsageSource
    ) async throws -> [any UsageProviderAdapter] {
        try await ompUsageSource.codexAccounts().map {
            CodexUsageAdapter(account: $0, ompUsageSource: ompUsageSource)
        }
    }

    static func makeNonCodex(
        credentials: LocalCredentialReader = LocalCredentialReader(),
        http: UsageHTTPClient,
        ompUsageSource: OMPUsageSource
    ) -> [any UsageProviderAdapter] {
        let claude = ClaudeUsageAdapter.discoverConfigDirectories(homeDirectoryURL: credentials.homeDirectoryURL).map {
            ClaudeUsageAdapter(
                http: http,
                credentials: credentials,
                configDirectory: $0,
                // OMP's Anthropic model usage is not per login; attach it once to avoid double counting.
                ompUsageSource: $0 == ClaudeUsageAdapter.defaultConfigDirectory ? ompUsageSource : nil
            )
        }
        return claude + [AntigravityUsageAdapter()]
    }
}
