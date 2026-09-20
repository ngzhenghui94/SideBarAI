import Foundation

enum CredentialReadIssue: Error, Equatable, Sendable {
    case fileNotFound(path: String)
    case jsonUnreadable(path: String)
    case accessTokenMissing(path: String)
    case keychainAuthorizationRequired
    case keychainUnavailable
}

enum ProviderFailureMessage {
    static func credential(_ issue: CredentialReadIssue, command: String) -> String {
        switch issue {
        case let .fileNotFound(path):
            "Credential file not found: \(path). Run `\(command)` to sign in."
        case let .jsonUnreadable(path):
            "Credential JSON unreadable: \(path). Run `\(command)` to repair it."
        case let .accessTokenMissing(path):
            "Credential JSON has no usable access token: \(path). Run `\(command)` to sign in again."
        case .keychainAuthorizationRequired:
            "Claude Keychain authorization is required. Open SideBarAI Settings and choose Use Keychain."
        case .keychainUnavailable:
            "Claude Code Keychain credential unavailable. Run `claude` to sign in, then choose Use Keychain in SideBarAI Settings."
        }
    }

    static func tokenExpired(provider: String, command: String) -> String {
        "\(provider) token expired. Run `\(command)` to sign in again."
    }

    static func transport(_ error: UsageTransportError, provider: String, command: String) -> String {
        switch error {
        case .unauthorized:
            "\(provider) returned HTTP 401. Run `\(command)` to refresh credentials."
        case .forbidden:
            "\(provider) returned HTTP 403. This account is not allowed to read usage."
        case .invalidPayload:
            "\(provider) usage payload changed. Try Refresh and update SideBarAI if it persists."
        case .network:
            "\(provider) usage request failed. Check your network connection and try Refresh."
        case .invalidResponse:
            "\(provider) returned an invalid response. Try Refresh."
        case let .httpStatus(status):
            "\(provider) returned HTTP \(status). Try Refresh."
        }
    }
}

enum JWTTokenInspector {
    static func expiryDate(for token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var encodedPayload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encodedPayload.count % 4
        if remainder > 0 {
            encodedPayload += String(repeating: "=", count: 4 - remainder)
        }

        guard let payloadData = Data(base64Encoded: encodedPayload),
              let object = try? JSONSerialization.jsonObject(with: payloadData),
              let claims = object as? [String: Any],
              let expiry = claims["exp"] as? NSNumber,
              expiry.doubleValue.isFinite else {
            return nil
        }

        return Date(timeIntervalSince1970: expiry.doubleValue)
    }
}
