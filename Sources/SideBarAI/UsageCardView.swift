import Foundation
import SwiftUI

@MainActor
struct UsageCardView: View {
    let record: ProviderRecord
    @Environment(\.sideBarLiquidGlassEnabled) private var usesLiquidGlass

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(14)
        .background {
            ZStack {
                cardShape.fill(usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.elevated)
                cardShape.fill(
                    LinearGradient(
                        colors: [record.provider.accentColor.opacity(0.10), .clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
            }
        }
        .sideBarGlassEffect(in: cardShape)
        .overlay {
            if !usesLiquidGlass {
                cardShape.stroke(SideBarTheme.border, lineWidth: 0.8)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ProviderTile(provider: record.provider, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.provider.displayName)
                        .font(SideBarTheme.headline)
                        .foregroundStyle(SideBarTheme.primaryText)
                    Text(accountLabel ?? sourceLabel)
                        .font(SideBarTheme.caption)
                        .foregroundStyle(SideBarTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if let peak = SideBarTheme.percentLabel(peakPercent) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(peak)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(SideBarTheme.usageColor(percentUsed: peakPercent, normal: SideBarTheme.primaryText))
                            .monospacedDigit()
                        Text("PEAK USED")
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(SideBarTheme.mutedText)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Peak quota usage \(peak)")
                }
            }

            HStack(spacing: 5) {
                if record.isActive {
                    Chip(text: "ACTIVE", color: SideBarTheme.success, showsDot: true)
                }
                if let planLabel = record.planStatusLabel {
                    Chip(text: planLabel.uppercased(), color: record.provider.accentColor)
                }
                stateChip
            }
        }
    }

    private var peakPercent: Double? {
        QuotaSummary.highestPercentage(in: [record]).map(Double.init)
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
            VStack(alignment: .leading, spacing: 12) {
                ForEach(snapshot.windows) { window in
                    UsageWindowRow(window: window, accent: record.provider.accentColor)
                }
                ForEach([snapshot.savedResetLabel, snapshot.subscriptionRenewalLabel()].compactMap { $0 }, id: \.self) { label in
                    Label(label, systemImage: "calendar")
                        .font(SideBarTheme.caption)
                        .foregroundStyle(SideBarTheme.secondaryText)
                }
                if snapshot.hasModelUsage {
                    ModelUsageSummaryView(
                        snapshot: snapshot,
                        accent: record.provider.accentColor
                    )
                }

                Text("\(snapshot.sourceLabel) · \(updatedLabel(snapshot.updatedAt))")
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
    private var stateChip: some View {
        switch record.state {
        case .loading:
            Chip(text: "CHECKING", color: SideBarTheme.secondaryText)
        case .authenticated:
            Chip(text: "CONNECTED", color: SideBarTheme.success)
        case .unavailable:
            Chip(text: "SETUP", color: SideBarTheme.warning)
        case .usage:
            EmptyView()
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

    private var levelColor: Color {
        SideBarTheme.usageColor(percentUsed: window.percentUsed, normal: accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(SideBarTheme.body.weight(.medium))
                    .foregroundStyle(SideBarTheme.primaryText)

                Spacer(minLength: 4)

                Text(valueLabel)
                    .font(SideBarTheme.caption.weight(.semibold))
                    .foregroundStyle(levelColor)
                    .monospacedDigit()
            }

            if let progress {
                UsageMeterBar(progress: progress, color: levelColor)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(window.label)
                    .accessibilityValue(valueLabel)
            }

            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .semibold))
                Text(resetLabel)
                Spacer(minLength: 4)
                if let progress {
                    Text("\(Int(((1 - progress) * 100).rounded()))% left")
                        .monospacedDigit()
                }
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
        window.resetCountdownLabel
    }
}
@MainActor
private struct ModelUsageSummaryView: View {
    let snapshot: UsageSnapshot
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().overlay(SideBarTheme.border)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local OMP usage · \(OMPModelUsageSource.lookbackLabel)")
                        .font(SideBarTheme.caption.weight(.semibold))
                        .foregroundStyle(SideBarTheme.secondaryText)
                    Text(tokenSummary)
                        .font(SideBarTheme.caption)
                        .foregroundStyle(SideBarTheme.mutedText)
                }
                Spacer(minLength: 4)
                if !snapshot.modelUsage.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(snapshot.hasUnpricedModelUsage ? "Priced subtotal" : (snapshot.modelPricing?.estimateLabel ?? "Estimate"))
                            .font(SideBarTheme.caption)
                            .foregroundStyle(SideBarTheme.mutedText)
                        Text(costSummary)
                            .font(SideBarTheme.caption.weight(.semibold))
                            .foregroundStyle(snapshot.pricedModelCost == nil ? SideBarTheme.mutedText : accent)
                            .monospacedDigit()
                    }
                }
            }

            ForEach(snapshot.modelUsage) { usage in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(usage.modelID)
                            .font(SideBarTheme.caption.weight(.semibold))
                            .foregroundStyle(SideBarTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(usage.requestCount) \(usage.requestCount == 1 ? "request" : "requests")")
                            .font(SideBarTheme.caption)
                            .foregroundStyle(SideBarTheme.mutedText)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(UsageNumberFormatter.compactTokenString(usage.totalTokens).map { "\($0) tokens" } ?? "Tokens unavailable")
                            .font(SideBarTheme.caption)
                            .foregroundStyle(SideBarTheme.secondaryText)
                            .monospacedDigit()
                        if let cost = usage.estimatedCost,
                           let formatted = UsageNumberFormatter.currencyString(cost) {
                            Text("≈ \(formatted)")
                                .font(SideBarTheme.caption)
                                .foregroundStyle(accent)
                                .monospacedDigit()
                        } else {
                            Text("Cost unavailable")
                                .font(SideBarTheme.caption)
                                .foregroundStyle(SideBarTheme.mutedText)
                        }
                    }
                }
            }

            if snapshot.hasUnpricedModelUsage {
                Text("Subtotal excludes models without published rates or usable token/speed data.")
                    .font(SideBarTheme.caption)
                    .foregroundStyle(SideBarTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snapshot.unattributedModelRequestCount > 0 {
                Text("\(snapshot.unattributedModelRequestCount) provider-wide records excluded; account ownership is unknown.")
                    .font(SideBarTheme.caption)
                    .foregroundStyle(SideBarTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let pricing = snapshot.modelPricing {
                Link(pricing.rateLinkTitle, destination: pricing.sourceURL)
                    .font(SideBarTheme.caption)
                Text(pricing.assumptions + " Partial local OMP history, not your subscription bill.")
                    .font(SideBarTheme.caption)
                    .foregroundStyle(SideBarTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var tokenSummary: String {
        guard let total = snapshot.totalModelTokens,
              let formatted = UsageNumberFormatter.compactTokenString(total) else {
            return "No account-linked model totals available."
        }
        let count = snapshot.modelUsage.count
        return "\(formatted) tokens incl. cached input · \(count) \(count == 1 ? "model" : "models")"
    }

    private var costSummary: String {
        guard let cost = snapshot.pricedModelCost,
              let formatted = UsageNumberFormatter.currencyString(cost) else { return "Unavailable" }
        return "≈ \(formatted)"
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
