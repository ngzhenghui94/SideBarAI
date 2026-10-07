import SwiftUI

/// Miniature of the app icon: an indigo tile carrying three provider-colored meters.
@MainActor
struct AppGlyph: View {
    let size: CGFloat

    private static let meters: [(Color, CGFloat)] = [
        (Color(hex: "#D97757"), 0.78),
        (Color(hex: "#10A37F"), 0.52),
        (Color(hex: "#4A7DFF"), 0.30)
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            shape.fill(SideBarTheme.brandGradient)
            VStack(alignment: .leading, spacing: size * 0.09) {
                ForEach(Array(Self.meters.enumerated()), id: \.offset) { _, meter in
                    Capsule()
                        .fill(meter.0)
                        .frame(width: size * 0.58 * meter.1, height: size * 0.1)
                }
            }
            .frame(width: size * 0.58, alignment: .leading)
        }
        .frame(width: size, height: size)
        .overlay { shape.stroke(.white.opacity(0.14), lineWidth: 0.75) }
        .accessibilityHidden(true)
    }
}

/// Provider mark on a softly tinted rounded tile.
@MainActor
struct ProviderTile: View {
    let provider: Provider
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ProviderIcon(provider: provider, size: size * 0.52, tint: provider.accentColor)
            .frame(width: size, height: size)
            .background(provider.accentColor.opacity(0.15), in: shape)
            .overlay { shape.stroke(provider.accentColor.opacity(0.28), lineWidth: 0.75) }
            .accessibilityHidden(true)
    }
}

/// Small capsule label for plan, activity and connection state.
@MainActor
struct Chip: View {
    let text: String
    let color: Color
    var showsDot = false

    var body: some View {
        HStack(spacing: 4) {
            if showsDot {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .tracking(0.4)
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Horizontal gradient meter matching the app icon's usage bars.
@MainActor
struct UsageMeterBar: View {
    let progress: Double
    let color: Color
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(SideBarTheme.usageTrack)
                if clamped > 0 {
                    Capsule(style: .continuous)
                        .fill(SideBarTheme.meterGradient(color))
                        .frame(width: max(height, geometry.size.width * clamped))
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.25), value: progress)
    }
}

extension UsageWindow {
    /// Compact countdown such as "Resets in 4h 15m".
    var resetCountdownLabel: String {
        guard let resetDate else { return "No reset time reported" }
        let seconds = resetDate.timeIntervalSinceNow
        guard seconds.isFinite else {
            return seconds > 0 ? "Resets in a long time" : "Reset available"
        }
        if seconds <= 0 { return "Reset available" }

        guard let minutes = UsageNumberFormatter.truncatedInteger(seconds / 60) else {
            return "Resets in a long time"
        }
        let hours = minutes / 60
        if hours >= 24 {
            return "Resets in \(hours / 24)d \(hours % 24)h"
        }
        if hours > 0 {
            return "Resets in \(hours)h \(minutes % 60)m"
        }
        return minutes > 0 ? "Resets in \(minutes)m" : "Resets soon"
    }

    /// Wall-clock reset time; includes the weekday when it is more than a day away.
    var resetClockLabel: String? {
        guard let resetDate, resetDate.timeIntervalSinceNow > 0 else { return nil }
        if resetDate.timeIntervalSinceNow >= 24 * 60 * 60 {
            return resetDate.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return resetDate.formatted(.dateTime.hour().minute())
    }
}
