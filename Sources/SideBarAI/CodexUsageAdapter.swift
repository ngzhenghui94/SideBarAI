import CryptoKit
import Foundation

/// Identity only: OMP owns credentials, login selection, and usage requests.
struct CodexAccount: Equatable, Identifiable, Sendable {
    let accountKey: String
    let accountLabel: String?
    let email: String?
    let isActive: Bool
    let chatgptAccountID: String?
    let planLabel: String?
    let organizationID: String?
    let projectID: String?

    var id: String { recordID }
    var recordID: String { "chatgpt:\(accountKey)" }

    init(
        accountKey: String,
        accountLabel: String? = nil,
        email: String? = nil,
        isActive: Bool = false,
        chatgptAccountID: String? = nil,
        planLabel: String? = nil,
        organizationID: String? = nil,
        projectID: String? = nil
    ) {
        self.accountKey = accountKey
        self.accountLabel = accountLabel
        self.email = email
        self.isActive = isActive
        self.chatgptAccountID = chatgptAccountID
        self.planLabel = planLabel
        self.organizationID = organizationID
        self.projectID = projectID
    }

    var identity: OMPAccountIdentity {
        OMPAccountIdentity(
            provider: "openai-codex",
            accountID: chatgptAccountID,
            email: email?.lowercased(),
            organizationID: organizationID,
            projectID: projectID
        )
    }

    static func from(metadata: OMPUsageMetadata) -> CodexAccount? {
        let identity = OMPAccountIdentity(
            provider: "openai-codex",
            accountID: metadata.accountId,
            email: metadata.email?.lowercased(),
            organizationID: metadata.organizationID,
            projectID: metadata.projectID
        )
        // A workspace ID alone cannot distinguish its different members.
        guard identity.accountID != nil || identity.email != nil else { return nil }
        // Length prefixes keep identity components unambiguous, including unusual strings.
        let components = [identity.provider, identity.accountID ?? "", identity.email ?? "",
                          identity.organizationID ?? "", identity.projectID ?? ""]
        let key = components.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(key.utf8))
        let accountKey = "omp-" + digest.map { String(format: "%02x", Int($0)) }.joined()
        let baseLabel = identity.email ?? identity.accountID
        let workspace = metadata.organizationName ?? identity.organizationID
        let label = [baseLabel, workspace, identity.projectID].compactMap { $0 }.joined(separator: " · ")
        return CodexAccount(
            accountKey: accountKey,
            accountLabel: label,
            email: identity.email,
            // `omp usage --json` has no active-login field. Never infer one.
            chatgptAccountID: identity.accountID,
            planLabel: metadata.planType,
            organizationID: identity.organizationID,
            projectID: identity.projectID
        )
    }
}

struct CodexUsageAdapter: UsageProviderAdapter {
    let provider: Provider = .chatgpt
    let account: CodexAccount
    let ompUsageSource: OMPUsageSource

    var recordID: String { account.recordID }
    var accountLabel: String? { account.accountLabel }
    var isActive: Bool { account.isActive }
    // Discovery proves OMP knows this identity; OMP reports authentication failures.
    var hasUsableCredentials: Bool { true }
    var planLabel: String? { account.planLabel }

    func fetch() async -> ProviderState {
        do {
            // Keep command failures distinct from a successful command with no quota data.
            guard let snapshot = try await ompUsageSource.usage(for: account) else {
                return .unavailable(message: "OMP has no usable Codex usage for this account. Open `omp`, use /login to check the account, then refresh.")
            }
            return .usage(snapshot)
        } catch is CancellationError {
            return .loading
        } catch {
            return .unavailable(message: Self.failureMessage(for: error))
        }
    }

    static func failureMessage(for error: any Error) -> String {
        switch error {
        case UsageCommandError.executableNotFound:
            "Install OMP, open `omp`, and use /login to add Codex accounts, then refresh."
        case UsageCommandError.timedOut:
            "OMP Codex usage check timed out. Check your connection and try Refresh."
        case UsageCommandError.invalidOutput:
            "OMP returned unreadable or ambiguous account usage. Try Refresh and update OMP if it persists."
        case UsageCommandError.outputTooLarge:
            "OMP usage output exceeded the supported size. Update OMP and try Refresh."
        case let UsageCommandError.commandFailed(status):
            "OMP usage failed (exit \(status)). Open `omp` and check your logins and connection, then refresh."
        default:
            // Never expose raw CLI errors: they may contain account details.
            "OMP Codex usage could not be read. Open `omp` and check your logins, then refresh."
        }
    }
}
