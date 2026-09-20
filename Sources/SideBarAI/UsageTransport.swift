import Foundation

enum UsageTransportError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case unauthorized
    case forbidden
    case httpStatus(Int)
    case network
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The provider returned an invalid response."
        case .unauthorized:
            "The saved provider credentials were rejected. Sign in again with the provider CLI."
        case .forbidden:
            "The saved account is not allowed to read usage for this provider."
        case let .httpStatus(status):
            "The provider returned HTTP status \(status)."
        case .network:
            "The provider could not be reached. Check your network connection."
        case .invalidPayload:
            "The provider returned an unexpected usage response."
        }
    }
}

struct UsageHTTPClient: Sendable {
    let session: URLSession
    let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.session = session
        self.timeout = timeout
    }

    func getJSON<Response: Decodable>(
        _ url: URL,
        headers: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        apply(headers, to: &request)
        return try await send(request, as: Response.self)
    }

    func postJSON<Body: Encodable, Response: Decodable>(
        _ url: URL,
        body: Body,
        headers: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        apply(headers, to: &request)

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw UsageTransportError.invalidPayload
        }

        return try await send(request, as: Response.self)
    }

    private func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    private func send<Response: Decodable>(
        _ request: URLRequest,
        as type: Response.Type
    ) async throws -> Response {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw UsageTransportError.network
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageTransportError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401:
            throw UsageTransportError.unauthorized
        case 403:
            throw UsageTransportError.forbidden
        default:
            throw UsageTransportError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw UsageTransportError.invalidPayload
        }
    }
}

struct LocalCredentialReader: Sendable {
    let homeDirectoryURL: URL

    init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
    }

    func data(relativePath: String) -> Data? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            return nil
        }

        let fileURL = homeDirectoryURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        let homePath = homeDirectoryURL.path.hasSuffix("/")
            ? homeDirectoryURL.path
            : homeDirectoryURL.path + "/"
        guard fileURL.path.hasPrefix(homePath) else {
            return nil
        }

        return FileManager.default.contents(atPath: fileURL.path)
    }

    func decode<Value: Decodable>(_ type: Value.Type, relativePath: String) -> Value? {
        guard let data = data(relativePath: relativePath) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum UsageDateParser {
    private static let millisecondsThreshold: TimeInterval = 100_000_000_000
    private static let minimumEpochSeconds = Date.distantPast.timeIntervalSince1970
    private static let maximumEpochSeconds = Date.distantFuture.timeIntervalSince1970
    private static let iso8601Parser = ISO8601Parser()

    static func iso8601(_ rawValue: String?) -> Date? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return iso8601Parser.date(from: trimmed).flatMap(bounded)
    }

    static func epoch(_ rawValue: Double?) -> Date? {
        guard let rawValue,
              rawValue.isFinite else {
            return nil
        }

        let seconds = abs(rawValue) > millisecondsThreshold
            ? rawValue / 1_000
            : rawValue
        guard seconds.isFinite,
              seconds >= minimumEpochSeconds,
              seconds <= maximumEpochSeconds else {
            return nil
        }

        return bounded(Date(timeIntervalSince1970: seconds))
    }

    // Foundation formatters build expensive parsing state. Share fixed-format
    // instances, but serialize access because provider requests run concurrently.
    private final class ISO8601Parser: @unchecked Sendable {
        private let lock = NSLock()
        private let fractional = ISO8601DateFormatter()
        private let wholeSeconds = ISO8601DateFormatter()

        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            wholeSeconds.formatOptions = [.withInternetDateTime]
        }

        func date(from value: String) -> Date? {
            lock.withLock {
                fractional.date(from: value) ?? wholeSeconds.date(from: value)
            }
        }
    }

    private static func bounded(_ date: Date) -> Date? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite,
              seconds >= minimumEpochSeconds,
              seconds <= maximumEpochSeconds else {
            return nil
        }
        return date
    }
}

struct FlexibleDouble: Decodable, Sendable {
    private static let maximumMagnitude = 1e18

    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            guard Self.isSafe(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a finite number within the supported range"
                )
            }
            self.value = value
            return
        }
        if let value = try? container.decode(String.self),
           let parsed = Double(value),
           Self.isSafe(parsed) {
            self.value = parsed
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a number")
    }

    private static func isSafe(_ value: Double) -> Bool {
        value.isFinite && abs(value) <= maximumMagnitude
    }
}
