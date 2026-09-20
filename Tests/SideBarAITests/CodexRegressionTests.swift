import Foundation
import Testing
@testable import SideBarAI

@Suite(.serialized)
@MainActor
struct CodexRegressionTests {
    @Test
    func blankAndExpiredLegacyTokensAreNotUsable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = LocalCredentialReader(homeDirectoryURL: home)

        try write(
            #"{"tokens":{"access_token":"   "}}"#,
            relativePath: ".codex/auth.json",
            in: home
        )
        let blankAccount = CodexAccount.fallback(credentials: reader)
        #expect(!blankAccount.isActive)
        #expect(!CodexUsageAdapter(credentials: reader).hasUsableCredentials)

        let expiredToken = jwt(payload: #"{"exp":1}"#)
        try write(
            #"{"tokens":{"access_token":"\#(expiredToken)"}}"#,
            relativePath: ".codex/auth.json",
            in: home
        )
        let expiredAccount = CodexAccount.fallback(credentials: reader)
        #expect(!expiredAccount.isActive)
        #expect(!CodexUsageAdapter(credentials: reader).hasUsableCredentials)
    }

    @Test
    func legacyFallbackCarriesAccountIDAndEmailFromAuthMetadata() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = LocalCredentialReader(homeDirectoryURL: home)
        let idToken = jwt(
            payload: #"{"https://api.openai.com/auth":{"email":"legacy@example.com"}}"#
        )
        try write(
            #"{"tokens":{"access_token":"fixture-token","account_id":"acct-legacy","id_token":"\#(idToken)"}}"#,
            relativePath: ".codex/auth.json",
            in: home
        )

        let account = CodexAccount.fallback(credentials: reader)
        #expect(account.chatgptAccountID == "acct-legacy")
        #expect(account.email == "legacy@example.com")
        #expect(account.isActive)
    }

    @Test
    func inactiveAccountRejectsAuthForAnotherAccountID() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = LocalCredentialReader(homeDirectoryURL: home)
        try write(
            #"{"active_account_key":"active","accounts":[{"account_key":"active","chatgpt_account_id":"acct-active"},{"account_key":"inactive","chatgpt_account_id":"acct-inactive"}]}"#,
            relativePath: ".codex/accounts/registry.json",
            in: home
        )
        try write(
            #"{"tokens":{"access_token":"fixture-token","account_id":"acct-other"}}"#,
            relativePath: ".codex/accounts/inactive.auth.json",
            in: home
        )

        let inactive = try #require(
            CodexAccount.discover(credentials: reader).first(where: { $0.accountKey == "inactive" })
        )
        let adapter = CodexUsageAdapter(account: inactive, credentials: reader)
        #expect(!inactive.isActive)
        #expect(!adapter.hasUsableCredentials)

        try write(
            #"{"tokens":{"access_token":"fixture-token","account_id":"acct-inactive"}}"#,
            relativePath: ".codex/accounts/inactive.auth.json",
            in: home
        )
        #expect(CodexUsageAdapter(account: inactive, credentials: reader).hasUsableCredentials)
    }

    @Test
    func malformedPrimaryWindowDoesNotDiscardValidSecondaryWindow() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = LocalCredentialReader(homeDirectoryURL: home)
        try write(
            #"{"tokens":{"access_token":"fixture-token"}}"#,
            relativePath: ".codex/auth.json",
            in: home
        )
        CodexFixtureURLProtocol.body = Data(
            #"{"rate_limit":{"primary_window":{"used_percent":{"not":"a number"}},"secondary_window":{"used_percent":25,"reset_at":1893456000,"limit_window_seconds":18000}},"plan_type":"plus"}"#.utf8
        )
        defer { CodexFixtureURLProtocol.body = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexFixtureURLProtocol.self]
        let adapter = CodexUsageAdapter(
            http: UsageHTTPClient(session: URLSession(configuration: configuration)),
            credentials: reader
        )

        let state = await adapter.fetch()
        guard case let .usage(snapshot) = state else {
            Issue.record("Expected the valid secondary window to survive malformed primary data")
            return
        }
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.id == "secondary")
        #expect(snapshot.windows.first?.used == 25)
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SideBarAI-Codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ content: String, relativePath: String, in home: URL) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }

    private static func jwt(payload: String) -> String {
        let encodedPayload = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(encodedPayload).sig"
    }

    private func jwt(payload: String) -> String {
        Self.jwt(payload: payload)
    }
}

private final class CodexFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: Data?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let body = Self.body,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
