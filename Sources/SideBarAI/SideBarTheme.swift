import AppKit
import SwiftUI

private struct SideBarLiquidGlassEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sideBarLiquidGlassEnabled: Bool {
        get { self[SideBarLiquidGlassEnabledKey.self] }
        set { self[SideBarLiquidGlassEnabledKey.self] = newValue }
    }
}

private struct SideBarGlassEffect<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.sideBarLiquidGlassEnabled) private var isEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.ultraThinMaterial, in: shape)
            }
        } else {
            content
        }
    }
}

extension View {
    func sideBarGlassEffect<S: Shape>(in shape: S) -> some View {
        modifier(SideBarGlassEffect(shape: shape))
    }
}

@MainActor
enum SideBarTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let elevated = Color.primary.opacity(0.075)
    static let border = Color.primary.opacity(0.11)
    static let primaryText = Color.primary.opacity(0.94)
    static let secondaryText = Color.primary.opacity(0.62)
    static let mutedText = Color.primary.opacity(0.46)
    static let glassSurface = Color.primary.opacity(0.06)
    static let usageTrack = Color.primary.opacity(0.13)
    static let usageTrackSubtle = Color.primary.opacity(0.08)
    static let success = Color(red: 0.25, green: 0.92, blue: 0.66)
    static let usageSevenDay = Color(red: 0.28, green: 0.58, blue: 1.0)
    static let warning = Color.orange
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)

    // Brand palette shared with the app icon.
    static let brand = Color(hex: "#7C6CFF")
    static let brandGradient = LinearGradient(
        colors: [Color(hex: "#3A3F6E"), Color(hex: "#14172E")],
        startPoint: .top,
        endPoint: .bottom
    )
    /// Faint indigo wash laid over opaque panels so they carry the brand tone in light and dark.
    static let panelTint = LinearGradient(
        colors: [brand.opacity(0.13), brand.opacity(0.02)],
        startPoint: .top,
        endPoint: .bottom
    )

    static func meterGradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.6), color], startPoint: .leading, endPoint: .trailing)
    }

    static func percentLabel(_ percentUsed: Double?) -> String? {
        percentUsed.map { "\(Int(min(max($0, 0), 100).rounded()))%" }
    }

    /// Escalates to warning/danger at the same 75%/90% marks that trigger quota alerts.
    static func usageColor(percentUsed: Double?, normal: Color) -> Color {
        guard let percentUsed else { return normal }
        if percentUsed >= 90 { return danger }
        if percentUsed >= 75 { return warning }
        return normal
    }

    static let title = Font.system(size: 16, weight: .semibold, design: .rounded)
    static let headline = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 12, weight: .regular, design: .rounded)
    static let caption = Font.system(size: 10, weight: .medium, design: .rounded)
    static let percentage = Font.system(size: 15, weight: .bold, design: .rounded)
}

extension Color {
    init(hex: String) {
        let normalized = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        guard normalized.count == 3 || normalized.count == 6 || normalized.count == 8,
              let value = UInt64(normalized, radix: 16) else {
            self = .gray
            return
        }

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64

        switch normalized.count {
        case 3:
            red = ((value >> 8) & 0xF) * 17
            green = ((value >> 4) & 0xF) * 17
            blue = (value & 0xF) * 17
            alpha = 255
        case 8:
            red = (value >> 24) & 0xFF
            green = (value >> 16) & 0xFF
            blue = (value >> 8) & 0xFF
            alpha = value & 0xFF
        default:
            red = (value >> 16) & 0xFF
            green = (value >> 8) & 0xFF
            blue = value & 0xFF
            alpha = 255
        }

        self.init(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

extension Provider {
    @MainActor
    var accentColor: Color {
        Color(hex: colorHex)
    }
}
