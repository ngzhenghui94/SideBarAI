import Foundation
import ServiceManagement

enum RefreshSchedule: String, CaseIterable, Codable, Identifiable, Sendable {
    case manual
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes
    case hourly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual:
            "Manual"
        case .oneMinute:
            "Every 1 minute"
        case .fiveMinutes:
            "Every 5 minutes"
        case .fifteenMinutes:
            "Every 15 minutes"
        case .thirtyMinutes:
            "Every 30 minutes"
        case .hourly:
            "Every hour"
        }
    }

    var interval: Duration? {
        switch self {
        case .manual:
            nil
        case .oneMinute:
            .seconds(60)
        case .fiveMinutes:
            .seconds(5 * 60)
        case .fifteenMinutes:
            .seconds(15 * 60)
        case .thirtyMinutes:
            .seconds(30 * 60)
        case .hourly:
            .seconds(60 * 60)
        }
    }
}

enum SidebarStartupMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case remember
    case hidden
    case compact
    case expanded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .remember:
            "Remember last state"
        case .hidden:
            "Hidden"
        case .compact:
            "Compact"
        case .expanded:
            "Expanded"
        }
    }
}

enum SidebarEdge: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case left
    case right
    case top
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left:
            "Left Edge"
        case .right:
            "Right Edge"
        case .top:
            "Top Edge"
        case .bottom:
            "Bottom Edge"
        }
    }

    var edgeName: String {
        switch self {
        case .left:
            "left"
        case .right:
            "right"
        case .top:
            "top"
        case .bottom:
            "bottom"
        }
    }
}

struct SidebarPresentationState: Equatable, Sendable {
    let isVisible: Bool
    let isExpanded: Bool
}

@MainActor
protocol LaunchAtLoginManaging: AnyObject {
    var isSupported: Bool { get }
    var isEnabled: Bool { get }
    var requiresApproval: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
final class UnavailableLaunchAtLoginManager: LaunchAtLoginManaging {
    let isSupported = false
    let isEnabled = false
    let requiresApproval = false

    func setEnabled(_ enabled: Bool) throws {}
}

@MainActor
enum DefaultLaunchAtLoginManager {
    static func make() -> any LaunchAtLoginManaging {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil else {
            return UnavailableLaunchAtLoginManager()
        }
        return ServiceManagementLaunchAtLoginManager(service: .mainApp)
    }
}

@MainActor
final class ServiceManagementLaunchAtLoginManager: LaunchAtLoginManaging {
    private let service: SMAppService

    init(service: SMAppService) {
        self.service = service
    }

    var isSupported: Bool { true }
    var isEnabled: Bool { service.status == .enabled }
    var requiresApproval: Bool { service.status == .requiresApproval }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
