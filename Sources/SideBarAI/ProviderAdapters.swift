import Foundation

enum DefaultUsageAdapters {
    static func make(
        credentials: LocalCredentialReader = LocalCredentialReader()
    ) -> [any UsageProviderAdapter] {
        let client = UsageHTTPClient()
        let ompUsageSource = OMPUsageSource()
        let codexAdapters: [any UsageProviderAdapter] = CodexAccount
            .discover(credentials: credentials)
            .map { account in
                CodexUsageAdapter(
                    account: account,
                    http: client,
                    credentials: credentials,
                    ompUsageSource: ompUsageSource
                )
            }

        return codexAdapters + [
            ClaudeUsageAdapter(http: client, credentials: credentials, ompUsageSource: ompUsageSource),
            AntigravityUsageAdapter()
        ]
    }
}
