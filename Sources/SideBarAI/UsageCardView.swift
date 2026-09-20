import Foundation
import SwiftUI

@MainActor
struct UsageCardView: View {
    let record: ProviderRecord
    @Environment(\.sideBarLiquidGlassEnabled) private var usesLiquidGlass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(12)
        .background(
            usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.elevated,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .sideBarGlassEffect(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            if !usesLiquidGlass {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(SideBarTheme.border, lineWidth: 0.8)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(record.provider.accentColor.opacity(0.18))
                ProviderIcon(
                    provider: record.provider,
                    size: 17,
                    tint: record.provider.accentColor
                )
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.provider.displayName)
                    .font(SideBarTheme.headline)
                    .foregroundStyle(SideBarTheme.primaryText)

                if let accountLabel {
                    Text(accountLabel)
                        .font(SideBarTheme.caption)
                        .foregroundStyle(SideBarTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let planLabel = record.planStatusLabel {
                    Text("Plan: \(planLabel)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(record.provider.accentColor)
                        .lineLimit(1)
                }

                if let label = record.state.snapshot?.savedResetLabel {
                    Text(label)
                        .font(SideBarTheme.caption)
                        .foregroundStyle(record.provider.accentColor)
                }

                Text(sourceLabel)
                    .font(SideBarTheme.caption)
                    .foregroundStyle(SideBarTheme.secondaryText)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if record.isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(SideBarTheme.success)
                }
                stateBadge
            }
        }
    }

    private var accountLabel: String? {
        record.displayAccountLabel
    }

    @ViewBuilder
    private var content: some View {
        switch record.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(SideBarTheme.secondaryText)
                Text("Reading provider usage…")
                    .font(SideBarTheme.body)
                    .foregroundStyle(SideBarTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .authenticated(stateAccountLabel):
            StatusMessage(
                icon: "checkmark.circle",
                title: "Connected",
                detail: accountLabel ?? stateAccountLabel ?? "Credentials found; waiting for usage data."
            )

        case let .unavailable(message):
            StatusMessage(
                icon: "exclamationmark.triangle",
                title: "Unavailable",
                detail: message
            )

        case let .usage(snapshot):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(snapshot.windows) { window in
                    UsageWindowRow(window: window, accent: record.provider.accentColor)
                }
                if !snapshot.modelUsage.isEmpty {
                    ModelUsageSummaryView(
                        modelUsage: snapshot.modelUsage,
                        accent: record.provider.accentColor
                    )
                }

                Text(updatedLabel(snapshot.updatedAt))
                    .font(SideBarTheme.caption)
                    .foregroundStyle(SideBarTheme.mutedText)
            }
        }
    }

    private var sourceLabel: String {
        switch record.state {
        case let .usage(snapshot):
            snapshot.sourceLabel
        default:
            record.provider.sourceDescription
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch record.state {
        case .loading:
            Text("CHECKING")
                .foregroundStyle(SideBarTheme.secondaryText)
        case .authenticated:
            Text("CONNECTED")
                .foregroundStyle(SideBarTheme.success)
        case .unavailable:
            Text("SETUP")
                .foregroundStyle(Color.orange)
        case .usage:
            Text("USAGE")
                .foregroundStyle(SideBarTheme.success)
        }
    }

    private func updatedLabel(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        guard seconds.isFinite else {
            return seconds.sign == .minus ? "Updated just now" : "Updated a long time ago"
        }
        if seconds < 60 {
            return "Updated just now"
        }
        guard let minutes = UsageNumberFormatter.truncatedInteger(seconds / 60) else {
            return "Updated a long time ago"
        }
        return minutes == 1 ? "Updated 1 min ago" : "Updated \(minutes) min ago"
    }
}

@MainActor
private struct UsageWindowRow: View {
    let window: UsageWindow
    let accent: Color

    private var progress: Double? {
        window.percentUsed.map { min(max($0, 0), 100) / 100 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(SideBarTheme.body)
                    .foregroundStyle(SideBarTheme.primaryText)

                Spacer(minLength: 4)

                Text(valueLabel)
                    .font(SideBarTheme.caption)
                    .foregroundStyle(accent)
                    .monospacedDigit()
            }

            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(SideBarTheme.usageTrack)
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [accent.opacity(0.72), accent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(window.label)
                .accessibilityValue(valueLabel)
            }

            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                Text(resetLabel)
            }
            .font(SideBarTheme.caption)
            .foregroundStyle(SideBarTheme.mutedText)
        }
    }

    private var valueLabel: String {
        if let percentage = window.percentUsed,
           let formatted = UsageNumberFormatter.roundedIntegerString(percentage) {
            return "\(formatted)% used"
        }

        switch window.unit {
        case .tokens:
            guard let formatted = UsageNumberFormatter.roundedIntegerString(window.used) else {
                return "Usage unavailable"
            }
            return "\(formatted) tokens"
        case .requests:
            guard let formatted = UsageNumberFormatter.roundedIntegerString(window.used) else {
                return "Usage unavailable"
            }
            return "\(formatted) requests"
        case .currency:
            guard window.used.isFinite else { return "Usage unavailable" }
            return String(format: "$%.2f", window.used)
        case .percent:
            return "Usage reported"
        }
    }

    private var resetLabel: String {
        guard let resetDate = window.resetDate else { return "No reset time reported" }
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
            return "Resets in \(hours / 24)d"
        }
        if hours > 0 {
            return "Resets in \(hours)h \(minutes % 60)m"
        }
        return minutes > 0 ? "Resets in \(minutes)m" : "Resets soon"
    }
}
@MainActor
private struct ModelUsageSummaryView: View {
    let modelUsage: [ModelUsageSummary]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
                .overlay(SideBarTheme.border)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model usage · \(OMPModelUsageSource.lookbackLabel)")
                        .font(SideBarTheme.caption.weight(.semibold))
                        .foregroundStyle(SideBarTheme.secondaryText)
                    Text(tokenSummary)
                        .font(SideBarTheme.caption)
                        .foregroundStyle(SideBarTheme.mutedText)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Estimated API cost")
                        .font(SideBarTheme.caption)
                        .foregroundStyle(SideBarTheme.mutedText)
                    Text(costSummary)
                        .font(SideBarTheme.caption.weight(.semibold))
                        .foregroundStyle(estimatedCost == nil ? SideBarTheme.mutedText : accent)
                        .monospacedDigit()
                }
            }

            ForEach(modelUsage) { usage in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(usage.modelID)
                            .font(SideBarTheme.caption.weight(.semibold))
                            .foregroundStyle(SideBarTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(requestLabel(usage.requestCount))
                            .font(SideBarTheme.caption)
                            .foregroundStyle(SideBarTheme.mutedText)
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(tokenLabel(usage.totalTokens))
                            .font(SideBarTheme.caption)
                            .foregroundStyle(SideBarTheme.secondaryText)
                            .monospacedDigit()
                        if let cost = usage.estimatedCost,
                           let formatted = UsageNumberFormatter.currencyString(cost) {
                            Text("≈ \(formatted)")
                                .font(SideBarTheme.caption)
                                .foregroundStyle(accent)
                                .monospacedDigit()
                        }
                    }
                }
            }

            if modelUsage.contains(where: { $0.estimatedCost == nil }) {
                Text("Some records have no pricing data.")
                    .font(SideBarTheme.caption)
                    .foregroundStyle(SideBarTheme.mutedText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var estimatedCost: Double? {
        guard modelUsage.allSatisfy({ $0.estimatedCost != nil }) else { return nil }
        let total = modelUsage.compactMap(\.estimatedCost).reduce(0, +)
        return total.isFinite && total >= 0 ? total : nil
    }

    private var tokenSummary: String {
        let total = modelUsage.reduce(0) { $0 + $1.totalTokens }
        guard total.isFinite,
              total >= 0,
              let formatted = UsageNumberFormatter.compactTokenString(total) else {
            return "Token total unavailable · \(modelUsage.count) models"
        }
        return "\(formatted) tokens · \(modelUsage.count) models"
    }

    private var costSummary: String {
        guard let estimatedCost,
              let formatted = UsageNumberFormatter.currencyString(estimatedCost) else {
            return "Unavailable"
        }
        return "≈ \(formatted)"
    }

    private func tokenLabel(_ value: Double) -> String {
        guard let formatted = UsageNumberFormatter.compactTokenString(value) else {
            return "Tokens unavailable"
        }
        return "\(formatted) tokens"
    }

    private func requestLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "request" : "requests")"
    }
}

@MainActor
private struct StatusMessage: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SideBarTheme.secondaryText)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SideBarTheme.body.weight(.semibold))
                    .foregroundStyle(SideBarTheme.primaryText)
                Text(detail)
                    .font(SideBarTheme.caption)
                    .foregroundStyle(SideBarTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
