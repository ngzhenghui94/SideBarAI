import Foundation
import Testing
@testable import SideBarAI

@Suite(.serialized)
@MainActor
struct AdapterRegressionTests {
    @Test
    func claudeKeepsValidWindowsWhenOneWindowIsMalformed() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            #"{"claudeAiOauth":{"accessToken":"fixture-token"}}"#,
            to: home.appendingPathComponent(".claude/.credentials.json")
        )

        let session = fixtureSession([
            "/api/oauth/usage": #"{"five_hour":{"utilization":"not-a-number"},"seven_day":{"utilization":37,"resets_at":"2030-01-07T00:00:00Z"},"seven_day_sonnet":"malformed","seven_day_opus":{"utilization":19,"resets_at":"2030-01-08T00:00:00Z"}}"#
        ])
        let adapter = ClaudeUsageAdapter(
            http: UsageHTTPClient(session: session),
            credentials: LocalCredentialReader(homeDirectoryURL: home)
        )

        guard case let .usage(snapshot) = await adapter.fetch() else {
            Issue.record("Expected Claude usage after dropping malformed windows")
            return
        }
        #expect(snapshot.windows.map(\.id) == ["seven-day", "seven-day-opus"])
        #expect(snapshot.windows.compactMap(\.percentUsed) == [37.0, 19.0])
    }

    @Test
    func antigravityParsesGroupedRemainingQuotaAndDropsUnknownBuckets() async throws {
        let payload = #"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.8,"reset_time":"2030-01-02T00:00:00Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":1},{"id":"unknown","window":"5h"},{"id":"disabled","window":"5h","remaining_fraction":0,"disabled":true},{"id":"invalid","window":"5h","remaining_fraction":true}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-5h","window":"5h","remaining_fraction":0.25}]}]}}}"#
        let adapter = AntigravityUsageAdapter(
            versionRunner: AntigravityFixtureRunner(text: "1.1.11"),
            usageRunner: AntigravityFixtureRunner(text: payload)
        )
        guard case let .usage(snapshot) = await adapter.fetch() else {
            Issue.record("Expected Antigravity quota groups")
            return
        }
        #expect(snapshot.windows.map(\.id) == ["3p-5h", "gemini-5h", "gemini-weekly"])
        #expect(snapshot.windows[0].percentUsed == 75)
        #expect(snapshot.windows[1].percentUsed == 0)
        #expect(abs((snapshot.windows[2].percentUsed ?? -1) - 20) < 0.001)
        #expect(snapshot.windows[0].periodSeconds == 18_000)
        #expect(snapshot.windows[2].periodSeconds == 604_800)
        #expect(snapshot.windows[2].resetDate == UsageDateParser.iso8601("2030-01-02T00:00:00Z"))
    }

    @Test(arguments: ["1.1.10", "unknown"])
    func antigravityNeverSendsUsageToUnsupportedCLI(version: String) async {
        let adapter = AntigravityUsageAdapter(
            versionRunner: AntigravityFixtureRunner(text: version),
            usageRunner: AntigravityForbiddenRunner()
        )
        guard case .unavailable = await adapter.fetch() else {
            Issue.record("An unsupported CLI must not run a potential model prompt")
            return
        }
    }

    @Test
    func antigravityRejectsUnsuccessfulOrUnknownQuotaReports() async {
        let valid = #"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"name":"Gemini","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.5}]}]}}}"#
        let reports = [
            valid.replacingOccurrences(of: "SUCCESS", with: "ERROR"),
            valid.replacingOccurrences(of: #""name":"usage""#, with: #""name":"models""#),
            valid.replacingOccurrences(of: #""num_turns":0"#, with: #""num_turns":1"#),
            valid.replacingOccurrences(of: #","remaining_fraction":0.5"#, with: ""),
            valid.replacingOccurrences(of: "0.5", with: "1.5"),
            valid.replacingOccurrences(of: #""remaining_fraction":0.5"#, with: #""remaining_fraction":0.5,"disabled":true"#)
        ]
        for report in reports {
            let adapter = AntigravityUsageAdapter(
                versionRunner: AntigravityFixtureRunner(text: "1.2.2"),
                usageRunner: AntigravityFixtureRunner(text: report)
            )
            guard case .unavailable = await adapter.fetch() else {
                Issue.record("Unknown quotas must not appear as zero usage")
                continue
            }
        }
    }

    @Test
    func antigravityPreservesLegacyProviderVisibilityAndEnablement() throws {
        let suite = "SideBarAITests.Migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["gemini"], forKey: "SideBarAI.hiddenProviders")
        defaults.set(["gemini", "claude"], forKey: "SideBarAI.disabledProviders")
        let store = UsageStore(adapters: [], defaults: defaults, refreshInterval: .zero)
        defer { store.shutdown() }
        #expect(!store.isProviderVisible(.antigravity))
        #expect(!store.isProviderEnabled(.antigravity))
        #expect(!store.isProviderEnabled(.claude))
        #expect(store.isProviderEnabled(.chatgpt))
    }

    @Test
    func claudeRejectsInvalidCachedKeychainCredentialsBeforeAuthorization() throws {
        let payloads = [
            Data("not-json".utf8),
            Data(#"{"claudeAiOauth":{"accessToken":"   "}}"#.utf8),
            Data(#"{"claudeAiOauth":{"accessToken":"fixture-token","expiresAt":1}}"#.utf8),
            Data(#"{"claudeAiOauth":{"accessToken":"fixture-token","expiresAt":1e17}}"#.utf8)
        ]

        for payload in payloads {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let suiteName = "SideBarAITests.AdapterRegression.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                Issue.record("Expected test defaults suite")
                return
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let reader = RecordingKeychainReader(data: payload)
            let adapter = ClaudeUsageAdapter(
                credentials: LocalCredentialReader(homeDirectoryURL: home),
                defaults: defaults,
                keychainReader: { allowInteraction in
                    reader.calls.append(allowInteraction)
                    return reader.data
                }
            )

            #expect(!adapter.authorizeKeychainAccess())
            #expect(!adapter.keychainAccessEnabled)
            #expect(!adapter.keychainAccessAuthorizedForRun)
            #expect(reader.calls == [true])
        }
    }

    @Test
    func transportRejectsNonFiniteNumbersAndUnsafeEpochs() throws {
        var rejected = false
        do {
            _ = try JSONDecoder().decode(FlexibleDouble.self, from: Data(#""NaN""#.utf8))
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(UsageDateParser.epoch(.infinity) == nil)
        #expect(UsageDateParser.epoch(1e18) == nil)
        #expect(abs((UsageDateParser.epoch(4_102_444_800_000)?.timeIntervalSince1970 ?? -1) - 4_102_444_800) < 0.001)
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SideBarAI-AdapterRegression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url)
    }

    private func fixtureSession(_ fixtures: [String: String]) -> URLSession {
        AdapterFixtureURLProtocol.fixtures = fixtures.mapValues { Data($0.utf8) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdapterFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct AntigravityFixtureRunner: UsageCommandRunning {
    let text: String
    func run() async throws -> Data { Data(text.utf8) }
}

private struct AntigravityForbiddenRunner: UsageCommandRunning {
    func run() async throws -> Data {
        Issue.record("Unsupported agy must not execute /usage")
        throw UsageCommandError.invalidOutput
    }
}

private final class RecordingKeychainReader: @unchecked Sendable {
    let data: Data?
    var calls: [Bool] = []

    init(data: Data?) {
        self.data = data
    }
}

private final class AdapterFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixtures: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let data = Self.fixtures[url.path],
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
