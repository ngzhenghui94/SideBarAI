import Foundation
import LocalAuthentication
import Security

private final class UserDefaultsBox: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

private final class ClaudeCredentialCache: @unchecked Sendable {
    enum State {
        case notRead
        case unavailable
        case data(Data)
    }

    private let lock = NSLock()
    private var state: State = .notRead
    private var authorizationFailure: String?

    func failureMessage() -> String? { lock.withLock { authorizationFailure } }

    func setFailureMessage(_ message: String?) {
        lock.withLock { authorizationFailure = message }
    }
    private var rejectedAccessToken: String?

    func value() -> State {
        lock.withLock { state }
    }

    func reject(_ accessToken: String) {
        lock.withLock {
            rejectedAccessToken = accessToken
            state = .notRead
        }
    }

    func isRejected(_ accessToken: String) -> Bool {
        lock.withLock { rejectedAccessToken == accessToken }
    }

    func store(_ data: Data) {
        lock.withLock { state = .data(data) }
    }

    func storeUnavailable() {
        lock.withLock { state = .unavailable }
    }

    func clear() {
        lock.withLock { state = .notRead }
    }
}

struct ClaudeUsageAdapter: UsageProviderAdapter {
    private static let keychainAccessDefaultsKey = "SideBarAI.claudeKeychainAccessEnabled"

    let provider: Provider = .claude

    private let http: UsageHTTPClient
    private let credentials: LocalCredentialReader
    private let defaults: UserDefaultsBox
    private let keychainReader: @Sendable (Bool) throws -> Data?
    private let credentialCache: ClaudeCredentialCache
    private let ompUsageSource: OMPUsageSource?

    init(
        http: UsageHTTPClient = UsageHTTPClient(),
        credentials: LocalCredentialReader = LocalCredentialReader(),
        defaults: UserDefaults = .standard,
        keychainReader: @escaping @Sendable (Bool) throws -> Data? = ClaudeUsageAdapter.readKeychainData,
        ompUsageSource: OMPUsageSource? = nil
    ) {
        self.http = http
        self.credentials = credentials
        self.defaults = UserDefaultsBox(defaults)
        self.keychainReader = keychainReader
        self.credentialCache = ClaudeCredentialCache()
        self.ompUsageSource = ompUsageSource
    }

    var keychainAccessEnabled: Bool {
        defaults.value.bool(forKey: Self.keychainAccessDefaultsKey)
    }

    var keychainAccessAuthorizedForRun: Bool {
        guard case let .data(data) = credentialCache.value(),
              case let .success(oauth) = decodeKeychainCredentials(data) else {
            return false
        }
        return isUsableForAuthorization(oauth)
    }

    var isActive: Bool {
        guard case let .success(oauth) = loadOAuthCredentials(),
              nonEmpty(oauth.accessToken) != nil else {
            return false
        }

        if let expiresAt = oauth.expiresAt?.value {
            guard let expiryDate = UsageDateParser.epoch(expiresAt) else {
                return false
            }
            return expiryDate > Date().addingTimeInterval(30)
        }
        return true
    }

    func fetch() async -> ProviderState {
        let oauth: ClaudeOAuthCredentials
        switch loadOAuthCredentials() {
        case let .failure(issue):
            return .unavailable(message: ProviderFailureMessage.credential(issue, command: "claude"))
        case let .success(value):
            oauth = value
        }

        guard let accessToken = nonEmpty(oauth.accessToken) else {
            return .unavailable(message: ProviderFailureMessage.credential(
                .accessTokenMissing(path: "~/.claude/.credentials.json"),
                command: "claude"
            ))
        }

        if let expiresAt = oauth.expiresAt?.value {
            guard let expiryDate = UsageDateParser.epoch(expiresAt) else {
                credentialCache.clear()
                return .unavailable(message: ProviderFailureMessage.credential(
                    .jsonUnreadable(path: "~/.claude/.credentials.json"),
                    command: "claude"
                ))
            }
            if expiryDate <= Date().addingTimeInterval(30) {
                credentialCache.clear()
                return .unavailable(message: ProviderFailureMessage.tokenExpired(
                    provider: "Claude",
                    command: "claude"
                ))
            }
        }

        // Keychain keeps serving a revoked token until Claude Code rotates it; don't resend it.
        if credentialCache.isRejected(accessToken) {
            return .unavailable(message: ProviderFailureMessage.transport(
                .unauthorized,
                provider: "Claude",
                command: "claude"
            ))
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return .unavailable(message: "Claude usage endpoint is unavailable.")
        }

        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20"
        ]

        do {
            let response: ClaudeUsageResponse = try await http.getJSON(url, headers: headers)
            let windows = [
                makeWindow(response.fiveHour, id: "five-hour", label: "5-hour session"),
                makeWindow(response.sevenDay, id: "seven-day", label: "7-day window"),
                makeWindow(response.sevenDaySonnet, id: "seven-day-sonnet", label: "7-day Sonnet"),
                makeWindow(response.sevenDayOpus, id: "seven-day-opus", label: "7-day Opus")
            ].compactMap { $0 }

            guard !windows.isEmpty else {
                return .unavailable(message: ProviderFailureMessage.transport(
                    .invalidPayload,
                    provider: "Claude",
                    command: "claude"
                ))
            }

            let snapshot = UsageSnapshot(
                windows: windows,
                updatedAt: Date(),
                accountLabel: "Claude Code",
                planLabel: nil,
                sourceLabel: "Claude Code OAuth"
            )
            guard let modelUsage = await ompUsageSource?.anthropicModelUsage() else {
                return .usage(snapshot)
            }
            return .usage(snapshot.withModelUsage(modelUsage))
        } catch is CancellationError {
            return .loading
        } catch let error as UsageTransportError {
            if error == .unauthorized {
                credentialCache.reject(accessToken)
            }
            return .unavailable(message: ProviderFailureMessage.transport(
                error,
                provider: "Claude",
                command: "claude"
            ))
        } catch {
            return .unavailable(message: ProviderFailureMessage.transport(
                .invalidPayload,
                provider: "Claude",
                command: "claude"
            ))
        }
    }

    private func loadOAuthCredentials() -> Result<ClaudeOAuthCredentials, CredentialReadIssue> {
        let path = "~/.claude/.credentials.json"
        var readableFileWithoutOAuth = false

        if let data = credentials.data(relativePath: ".claude/.credentials.json") {
            guard let envelope = try? JSONDecoder().decode(ClaudeCredentialEnvelope.self, from: data) else {
                return .failure(.jsonUnreadable(path: path))
            }
            if let oauth = envelope.oauth {
                return .success(oauth)
            }
            readableFileWithoutOAuth = true
        }

        if !keychainAccessEnabled {
            return .failure(readableFileWithoutOAuth
                ? .accessTokenMissing(path: path)
                : .keychainAuthorizationRequired)
        }

        let cached = credentialCache.value()
        if case let .data(data) = cached,
           case let .success(oauth) = decodeKeychainCredentials(data),
           isUsableForAuthorization(oauth) {
            return .success(oauth)
        }

        // Claude Code rotates the token in Keychain; pick it up silently (never prompts).
        if let data = keychainData(allowInteraction: false),
           case let .success(oauth) = decodeKeychainCredentials(data),
           isUsableForAuthorization(oauth) {
            credentialCache.store(data)
            return .success(oauth)
        }

        switch cached {
        case let .data(data):
            return decodeKeychainCredentials(data)
        case .unavailable:
            return .failure(.keychainUnavailable)
        case .notRead:
            return .failure(.keychainAuthorizationRequired)
        }
    }

    private func decodeKeychainCredentials(
        _ data: Data
    ) -> Result<ClaudeOAuthCredentials, CredentialReadIssue> {
        guard let envelope = try? JSONDecoder().decode(ClaudeCredentialEnvelope.self, from: data) else {
            return .failure(.jsonUnreadable(path: "Claude Code Keychain item"))
        }
        guard let oauth = envelope.oauth,
              nonEmpty(oauth.accessToken) != nil else {
            return .failure(.accessTokenMissing(path: "Claude Code Keychain item"))
        }
        return .success(oauth)
    }

    var keychainAuthorizationFailure: String? { credentialCache.failureMessage() }

    private func keychainData(allowInteraction: Bool) -> Data? {
        do {
            return try keychainReader(allowInteraction)
        } catch {
            if allowInteraction {
                let code = (error as NSError).code
                let detail = SecCopyErrorMessageString(OSStatus(clamping: code), nil) as String? ?? "Unknown Security error"
                credentialCache.setFailureMessage("macOS Keychain error \(code): \(detail)")
            }
            return nil
        }
    }

    private static let keychainInteractionLock = NSLock()

    private static func readKeychainData(allowInteraction: Bool) throws -> Data? {
        // Login-Keychain ACL prompts are not controlled by LAContext. Serialize
        // all reads while temporarily changing its process-wide interaction flag.
        keychainInteractionLock.lock()
        defer { keychainInteractionLock.unlock() }
        var previousInteraction: DarwinBoolean = false
        if !allowInteraction {
            guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                return nil
            }
        }
        defer {
            if !allowInteraction {
                _ = SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue)
            }
        }
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            // Claude Code rewrites the item via /usr/bin/security on every token refresh,
            // which drops our "Always Allow" ACL entry. `security` created the item, so it
            // stays trusted and can read it without prompting.
            if !allowInteraction, let data = readKeychainDataViaSecurityCLI() {
                return data
            }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return result as? Data
    }

    private static func readKeychainDataViaSecurityCLI() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    @MainActor
    internal func authorizeKeychainAccess() -> Bool {
        credentialCache.clear()
        credentialCache.setFailureMessage(nil)
        guard let data = keychainData(allowInteraction: true) else {
            credentialCache.storeUnavailable()
            return false
        }

        let oauth: ClaudeOAuthCredentials
        switch decodeKeychainCredentials(data) {
        case let .success(value):
            oauth = value
        case let .failure(issue):
            credentialCache.setFailureMessage(ProviderFailureMessage.credential(issue, command: "claude"))
            credentialCache.storeUnavailable()
            return false
        }
        guard isUsableForAuthorization(oauth) else {
            credentialCache.setFailureMessage("Keychain access succeeded, but the Claude login has expired or is invalid. Run claude and sign in again, then choose Use Keychain.")
            credentialCache.storeUnavailable()
            return false
        }

        credentialCache.store(data)
        defaults.value.set(true, forKey: Self.keychainAccessDefaultsKey)
        return true
    }

    internal func disableKeychainAccess() {
        credentialCache.clear()
        defaults.value.set(false, forKey: Self.keychainAccessDefaultsKey)
    }

    private func makeWindow(
        _ window: ClaudeRateWindow?,
        id: String,
        label: String
    ) -> UsageWindow? {
        guard let window,
              let utilization = window.utilization?.value,
              utilization.isFinite else {
            return nil
        }

        return UsageWindow(
            id: id,
            label: label,
            used: min(max(utilization, 0), 100),
            limit: 100,
            unit: .percent,
            resetDate: UsageDateParser.iso8601(window.resetsAt),
            providerReportedPercentage: true
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isUsableForAuthorization(_ oauth: ClaudeOAuthCredentials) -> Bool {
        guard nonEmpty(oauth.accessToken) != nil else { return false }
        guard let expiresAt = oauth.expiresAt?.value else { return true }
        guard let expiryDate = UsageDateParser.epoch(expiresAt) else { return false }
        return expiryDate > Date().addingTimeInterval(30)
    }
}

private struct ClaudeCredentialEnvelope: Decodable, Sendable {
    let claudeAiOauth: ClaudeOAuthCredentials?
    let accessToken: String?
    let expiresAt: FlexibleDouble?

    var oauth: ClaudeOAuthCredentials? {
        if let claudeAiOauth,
           let accessToken = claudeAiOauth.accessToken,
           !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return claudeAiOauth
        }
        if let accessToken {
            return ClaudeOAuthCredentials(accessToken: accessToken, expiresAt: expiresAt)
        }
        return claudeAiOauth
    }

    private enum CodingKeys: String, CodingKey {
        case claudeAiOauth
        case accessToken
        case expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeAiOauth = try? container.decode(ClaudeOAuthCredentials.self, forKey: .claudeAiOauth)
        accessToken = try? container.decode(String.self, forKey: .accessToken)
        expiresAt = try? container.decode(FlexibleDouble.self, forKey: .expiresAt)
    }
}

private struct ClaudeOAuthCredentials: Decodable, Sendable {
    let accessToken: String?
    let expiresAt: FlexibleDouble?

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case expiresAt
    }

    init(accessToken: String?, expiresAt: FlexibleDouble?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

private struct ClaudeUsageResponse: Decodable, Sendable {
    let fiveHour: ClaudeRateWindow?
    let sevenDay: ClaudeRateWindow?
    let sevenDaySonnet: ClaudeRateWindow?
    let sevenDayOpus: ClaudeRateWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try? container.decode(ClaudeRateWindow.self, forKey: .fiveHour)
        sevenDay = try? container.decode(ClaudeRateWindow.self, forKey: .sevenDay)
        sevenDaySonnet = try? container.decode(ClaudeRateWindow.self, forKey: .sevenDaySonnet)
        sevenDayOpus = try? container.decode(ClaudeRateWindow.self, forKey: .sevenDayOpus)
    }
}

private struct ClaudeRateWindow: Decodable, Sendable {
    let utilization: FlexibleDouble?
    let resetsAt: String?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try? container.decode(FlexibleDouble.self, forKey: .utilization)
        resetsAt = try? container.decode(String.self, forKey: .resetsAt)
    }
}

