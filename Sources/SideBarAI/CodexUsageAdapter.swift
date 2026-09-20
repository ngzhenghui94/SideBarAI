import Foundation

private func codexAuthFilename(for accountKey: String) -> String {
    var encoded = Data(accountKey.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    while encoded.last == "=" {
        encoded.removeLast()
    }
    return encoded
}
private func codexNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func codexAuthHasUsableAccessToken(_ auth: CodexAuthFile?) -> Bool {
    guard let accessToken = codexNonEmpty(auth?.tokens?.accessToken) else {
        return false
    }
    guard let expiryDate = JWTTokenInspector.expiryDate(for: accessToken) else {
        return true
    }
    return expiryDate > Date()
}

private func codexLegacyAccountID(from auth: CodexAuthFile?) -> String? {
    if let accountID = codexNonEmpty(auth?.accountID)
        ?? codexNonEmpty(auth?.tokens?.accountID) {
        return accountID
    }
    return CodexTokenMetadata.from(auth: auth).accountID
}

private func codexLegacyEmail(from auth: CodexAuthFile?) -> String? {
    if let email = codexNonEmpty(auth?.email)
        ?? codexNonEmpty(auth?.tokens?.email) {
        return email
    }
    return CodexTokenMetadata.from(auth: auth).email
}

private struct CodexTokenMetadata: Sendable {
    let accountID: String?
    let email: String?

    static func from(auth: CodexAuthFile?) -> CodexTokenMetadata {
        let tokens = [auth?.tokens?.idToken, auth?.tokens?.accessToken].compactMap { $0 }
        var accountID: String?
        var email: String?
        for token in tokens {
            let metadata = from(token: token)
            accountID = accountID ?? metadata.accountID
            email = email ?? metadata.email
            if accountID != nil, email != nil {
                break
            }
        }
        return CodexTokenMetadata(accountID: accountID, email: email)
    }

    private static func from(token: String) -> CodexTokenMetadata {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else {
            return CodexTokenMetadata(accountID: nil, email: nil)
        }

        var encodedPayload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encodedPayload.count % 4
        if remainder > 0 {
            encodedPayload += String(repeating: "=", count: 4 - remainder)
        }

        guard let payloadData = Data(base64Encoded: encodedPayload),
              let object = try? JSONSerialization.jsonObject(with: payloadData),
              let claims = object as? [String: Any] else {
            return CodexTokenMetadata(accountID: nil, email: nil)
        }

        var objects = [claims]
        for key in ["https://api.openai.com/auth", "https://api.openai.com/profile", "auth", "profile"] {
            if let nested = claims[key] as? [String: Any] {
                objects.append(nested)
            }
        }

        let accountID = firstString(
            in: objects,
            keys: ["chatgpt_account_id", "account_id", "accountId"]
        )
        let email = firstString(
            in: objects,
            keys: ["email", "user_email"]
        )
        return CodexTokenMetadata(accountID: accountID, email: email)
    }

    private static func firstString(in objects: [[String: Any]], keys: [String]) -> String? {
        for object in objects {
            for key in keys {
                if let value = object[key] as? String,
                   let value = codexNonEmpty(value) {
                    return value
                }
            }
        }
        return nil
    }
}

struct CodexAccount: Equatable, Identifiable, Sendable {
    let accountKey: String
    let authFilePath: String
    let accountLabel: String?
    let email: String?
    let isActive: Bool
    let chatgptAccountID: String?
    let planLabel: String?

    var id: String { recordID }
    var recordID: String { "chatgpt:\(accountKey)" }

    // These aliases keep the account model useful to callers that distinguish
    // a relative credential path from the registry key or display label.
    var authFileRelativePath: String { authFilePath }
    var authPath: String { authFilePath }
    var label: String? { accountLabel }
    var displayLabel: String? { accountLabel }
    var chatGPTAccountID: String? { chatgptAccountID }
    var plan: String? { planLabel }

    init(
        accountKey: String,
        authFilePath: String? = nil,
        accountLabel: String? = nil,
        email: String? = nil,
        isActive: Bool = false,
        chatgptAccountID: String? = nil,
        planLabel: String? = nil
    ) {
        self.accountKey = accountKey
        self.authFilePath = authFilePath ?? ".codex/accounts/\(accountKey).auth.json"
        self.accountLabel = accountLabel
        self.email = email
        self.isActive = isActive
        self.chatgptAccountID = chatgptAccountID
        self.planLabel = planLabel
    }

    static func fallback(credentials: LocalCredentialReader = LocalCredentialReader()) -> CodexAccount {
        let auth: CodexAuthFile? = credentials.decode(
            CodexAuthFile.self,
            relativePath: ".codex/auth.json"
        )
        return CodexAccount(
            accountKey: "active",
            authFilePath: ".codex/auth.json",
            email: codexLegacyEmail(from: auth),
            isActive: codexAuthHasUsableAccessToken(auth),
            chatgptAccountID: codexLegacyAccountID(from: auth)
        )
    }

    static func discover(
        credentials: LocalCredentialReader = LocalCredentialReader()
    ) -> [CodexAccount] {
        guard let registry: CodexRegistry = credentials.decode(
            CodexRegistry.self,
            relativePath: ".codex/accounts/registry.json"
        ) else {
            return [fallback(credentials: credentials)]
        }

        let activeKey = normalized(registry.activeAccountKey)
        var seenKeys = Set<String>()
        let accounts = registry.accounts.compactMap { entry -> CodexAccount? in
            guard let accountKey = normalized(entry.accountKey),
                  seenKeys.insert(accountKey).inserted else {
                return nil
            }

            let authFilePath = matchingAuthFilePath(
                accountKey: accountKey,
                credentials: credentials
            ) ?? ".codex/accounts/\(accountKey).auth.json"
            return CodexAccount(
                accountKey: accountKey,
                authFilePath: authFilePath,
                accountLabel: displayLabel(for: entry),
                email: normalized(entry.email),
                isActive: accountKey == activeKey,
                chatgptAccountID: normalized(entry.chatgptAccountID),
                planLabel: normalized(entry.planLabel)
            )
        }

        return accounts.isEmpty ? [fallback(credentials: credentials)] : accounts
    }

    static func discover(homeDirectoryURL: URL) -> [CodexAccount] {
        discover(credentials: LocalCredentialReader(homeDirectoryURL: homeDirectoryURL))
    }


    private static func matchingAuthFilePath(
        accountKey: String,
        credentials: LocalCredentialReader
    ) -> String? {
        var paths = [".codex/accounts/\(accountKey).auth.json"]
        let encodedKey = codexAuthFilename(for: accountKey)
        paths.append(".codex/accounts/\(encodedKey).auth.json")

        for path in paths {
            guard credentials.data(relativePath: path) != nil else {
                continue
            }
            return path
        }
        return nil
    }

    private static func displayLabel(for entry: CodexRegistryAccount) -> String? {
        normalized(entry.alias)
            ?? normalized(entry.email)
            ?? normalized(entry.accountName)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum CodexCredentialLoadResult {
    case fileNotFound
    case jsonUnreadable
    case loaded(CodexAuthFile)
}
struct CodexUsageAdapter: UsageProviderAdapter {
    let provider: Provider = .chatgpt
    let account: CodexAccount

    private let http: UsageHTTPClient
    private let credentials: LocalCredentialReader
    private let ompUsageSource: OMPUsageSource?

    var recordID: String { account.recordID }
    var accountLabel: String? { resolvedAccount.accountLabel }
    var isActive: Bool { resolvedAccount.isActive }
    var hasUsableCredentials: Bool {
        guard case let .loaded(auth) = loadAuth(for: resolvedAccount) else {
            return false
        }
        return codexAuthHasUsableAccessToken(auth)
    }
    var planLabel: String? { resolvedAccount.planLabel }

    private var resolvedAccount: CodexAccount {
        CodexAccount.discover(credentials: credentials)
            .first(where: { $0.accountKey == account.accountKey })
            ?? account
    }

    init(
        account: CodexAccount,
        http: UsageHTTPClient = UsageHTTPClient(),
        credentials: LocalCredentialReader = LocalCredentialReader(),
        ompUsageSource: OMPUsageSource? = nil
    ) {
        self.account = account
        self.http = http
        self.credentials = credentials
        self.ompUsageSource = ompUsageSource
    }

    // Keep the original injectable initializer as the legacy auth.json fixture
    // path used by existing callers and tests.
    init(
        http: UsageHTTPClient = UsageHTTPClient(),
        credentials: LocalCredentialReader = LocalCredentialReader(),
        ompUsageSource: OMPUsageSource? = nil
    ) {
        self.init(
            account: .fallback(credentials: credentials),
            http: http,
            credentials: credentials,
            ompUsageSource: ompUsageSource
        )
    }

    func fetch() async -> ProviderState {
        let account = resolvedAccount
        let auth: CodexAuthFile
        switch loadAuth(for: account) {
        case .fileNotFound:
            return await fallbackOrOriginal(
                .unavailable(message: ProviderFailureMessage.credential(
                    .fileNotFound(path: account.authFilePath),
                    command: "codex login"
                )),
                for: account
            )
        case .jsonUnreadable:
            return await fallbackOrOriginal(
                .unavailable(message: ProviderFailureMessage.credential(
                    .jsonUnreadable(path: account.authFilePath),
                    command: "codex login"
                )),
                for: account
            )
        case let .loaded(value):
            auth = value
        }

        guard let accessToken = nonEmpty(auth.tokens?.accessToken) else {
            return await fallbackOrOriginal(
                .unavailable(message: ProviderFailureMessage.credential(
                    .accessTokenMissing(path: account.authFilePath),
                    command: "codex login"
                )),
                for: account
            )
        }
        if let expiryDate = JWTTokenInspector.expiryDate(for: accessToken), expiryDate <= Date() {
            return await fallbackOrOriginal(
                .unavailable(message: ProviderFailureMessage.tokenExpired(
                    provider: "Codex",
                    command: "codex login"
                )),
                for: account
            )
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return await fallbackOrOriginal(
                .unavailable(message: "Codex usage endpoint is unavailable."),
                for: account
            )
        }

        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "User-Agent": "codex-cli"
        ]
        // The registry is authoritative for the account ID when it has one;
        // the token value remains the fallback for legacy auth.json files.
        if let accountID = nonEmpty(account.chatgptAccountID) ?? codexLegacyAccountID(from: auth) {
            headers["ChatGPT-Account-Id"] = accountID
        }

        do {
            let response: CodexUsageResponse = try await http.getJSON(url, headers: headers)
            let windows = [
                makeWindow(response.rateLimit?.primaryWindow, id: "primary"),
                makeWindow(response.rateLimit?.secondaryWindow, id: "secondary")
            ].compactMap { $0 }

            guard !windows.isEmpty else {
                return await fallbackOrOriginal(
                    .unavailable(message: ProviderFailureMessage.transport(
                        .invalidPayload,
                        provider: "Codex",
                        command: "codex login"
                    )),
                    for: account
                )
            }

            let accountID = nonEmpty(account.chatgptAccountID) ?? codexLegacyAccountID(from: auth)
            let ompSnapshot = await ompUsageSnapshot(for: account)
            let snapshot = UsageSnapshot(
                windows: windows,
                updatedAt: Date(),
                accountLabel: account.accountLabel ?? account.email ?? accountID.map { "Account \($0)" },
                planLabel: nonEmpty(response.planType) ?? account.planLabel,
                sourceLabel: "Codex CLI OAuth",
                savedResetCount: ompSnapshot?.savedResetCount,
                modelUsage: ompSnapshot?.modelUsage ?? []
            )
            return .usage(snapshot)
        } catch is CancellationError {
            return .loading
        } catch let error as UsageTransportError {
            return await fallbackOrOriginal(
                .unavailable(message: ProviderFailureMessage.transport(
                    error,
                    provider: "Codex",
                    command: "codex login"
                )),
                for: account
            )
        } catch {
            return await fallbackOrOriginal(
                .unavailable(message: ProviderFailureMessage.transport(
                    .invalidPayload,
                    provider: "Codex",
                    command: "codex login"
                )),
                for: account
            )
        }
    }

    private func fallbackOrOriginal(_ state: ProviderState, for account: CodexAccount) async -> ProviderState {
        guard let snapshot = await ompUsageSnapshot(for: account) else {
            return state
        }
        return .usage(snapshot)
    }

    private func ompUsageSnapshot(for account: CodexAccount) async -> UsageSnapshot? {
        guard let ompUsageSource else { return nil }
        return await ompUsageSource.snapshot(for: account)
    }

    private func loadAuth(for account: CodexAccount) -> CodexCredentialLoadResult {
        var paths = [account.authFilePath]
        if account.isActive {
            paths.insert(".codex/auth.json", at: 0)
        }
        let directPath = ".codex/accounts/\(account.accountKey).auth.json"
        let encodedPath = ".codex/accounts/\(codexAuthFilename(for: account.accountKey)).auth.json"
        paths.append(directPath)
        paths.append(encodedPath)

        var sawUnreadable = false
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            guard let data = credentials.data(relativePath: path) else {
                continue
            }
            guard let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else {
                sawUnreadable = true
                continue
            }
            guard authBelongsToAccount(auth, account: account) else {
                continue
            }
            return .loaded(auth)
        }
        return sawUnreadable ? .jsonUnreadable : .fileNotFound
    }

    private func authBelongsToAccount(_ auth: CodexAuthFile, account: CodexAccount) -> Bool {
        guard let expectedAccountID = nonEmpty(account.chatgptAccountID),
              let actualAccountID = codexLegacyAccountID(from: auth) else {
            return true
        }
        return expectedAccountID == actualAccountID
    }

    private func makeWindow(_ window: CodexRateWindow?, id: String) -> UsageWindow? {
        guard let window,
              let usedPercent = window.usedPercent?.value,
              usedPercent.isFinite else {
            return nil
        }

        let label: String
        if let seconds = window.limitWindowSeconds?.value, seconds >= 500_000 {
            label = "7-day window"
        } else if let seconds = window.limitWindowSeconds?.value, seconds >= 10_000 {
            label = "5-hour window"
        } else {
            label = id == "primary" ? "Primary window" : "Secondary window"
        }

        return UsageWindow(
            id: id,
            label: label,
            used: min(max(usedPercent, 0), 100),
            limit: 100,
            unit: .percent,
            resetDate: UsageDateParser.epoch(window.resetAt?.value),
            providerReportedPercentage: true,
            periodSeconds: window.limitWindowSeconds?.value
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CodexRegistry: Decodable, Sendable {
    let activeAccountKey: String?
    let accounts: [CodexRegistryAccount]

    private enum CodingKeys: String, CodingKey {
        case activeAccountKey = "active_account_key"
        case accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeAccountKey = try? container.decode(String.self, forKey: .activeAccountKey)

        if let entries = try? container.decode([CodexRegistryAccount].self, forKey: .accounts) {
            accounts = entries
            return
        }

        if let entries = try? container.decode([String: CodexRegistryAccount].self, forKey: .accounts) {
            accounts = entries
                .map { key, entry in
                    var entry = entry
                    if entry.accountKey == nil {
                        entry.accountKey = key
                    }
                    return entry
                }
                .sorted { ($0.accountKey ?? "") < ($1.accountKey ?? "") }
            return
        }

        accounts = []
    }
}

private struct CodexRegistryAccount: Decodable, Sendable {
    var accountKey: String?
    let alias: String?
    let email: String?
    let accountName: String?
    let chatgptAccountID: String?
    let planLabel: String?

    private enum CodingKeys: String, CodingKey {
        case accountKey = "account_key"
        case alias
        case email
        case accountName = "account_name"
        case name
        case chatgptAccountID = "chatgpt_account_id"
        case plan
        case planType = "plan_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountKey = try? container.decode(String.self, forKey: .accountKey)
        alias = try? container.decode(String.self, forKey: .alias)
        email = try? container.decode(String.self, forKey: .email)
        accountName = (try? container.decode(String.self, forKey: .accountName))
            ?? (try? container.decode(String.self, forKey: .name))
        chatgptAccountID = try? container.decode(String.self, forKey: .chatgptAccountID)
        planLabel = (try? container.decode(String.self, forKey: .plan))
            ?? (try? container.decode(String.self, forKey: .planType))
    }
}

private struct CodexAuthFile: Decodable, Sendable {
    let tokens: CodexTokens?
    let accountID: String?
    let email: String?

    private enum CodingKeys: String, CodingKey {
        case tokens
        case accountID = "account_id"
        case email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try? container.decode(CodexTokens.self, forKey: .tokens)
        accountID = try? container.decode(String.self, forKey: .accountID)
        email = try? container.decode(String.self, forKey: .email)
    }
}

private struct CodexTokens: Decodable, Sendable {
    let accessToken: String?
    let accountID: String?
    let idToken: String?
    let email: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountID = "account_id"
        case idToken = "id_token"
        case email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try? container.decode(String.self, forKey: .accessToken)
        accountID = try? container.decode(String.self, forKey: .accountID)
        idToken = try? container.decode(String.self, forKey: .idToken)
        email = try? container.decode(String.self, forKey: .email)
    }
}

private struct CodexUsageResponse: Decodable, Sendable {
    let planType: String?
    let rateLimit: CodexRateLimit?

    private enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

private struct CodexRateLimit: Decodable, Sendable {
    let primaryWindow: CodexRateWindow?
    let secondaryWindow: CodexRateWindow?

    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryWindow = try? container.decodeIfPresent(CodexRateWindow.self, forKey: .primaryWindow)
        secondaryWindow = try? container.decodeIfPresent(CodexRateWindow.self, forKey: .secondaryWindow)
    }
}

private struct CodexRateWindow: Decodable, Sendable {
    let usedPercent: FlexibleDouble?
    let resetAt: FlexibleDouble?
    let limitWindowSeconds: FlexibleDouble?

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }
}
