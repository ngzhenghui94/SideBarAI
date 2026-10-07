import AppKit
import SwiftUI

@MainActor
struct SideBarRootView: View {
    let store: UsageStore
    let onOpenSettings: () -> Void
    let isDetached: Bool
    let attachment: SidebarEdge
    let onExpandedChange: (Bool) -> Void
    let onPeekChange: (String?, Bool) -> Void

    init(
        store: UsageStore,
        onOpenSettings: @escaping () -> Void,
        isDetached: Bool = false,
        attachment: SidebarEdge = .right,
        onExpandedChange: @escaping (Bool) -> Void,
        onPeekChange: @escaping (String?, Bool) -> Void = { _, _ in }
    ) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.isDetached = isDetached
        self.attachment = attachment
        self.onExpandedChange = onExpandedChange
        self.onPeekChange = onPeekChange
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 180 {
                CompactRailView(
                    store: store,
                    isDetached: isDetached,
                    attachment: attachment,
                    onExpandedChange: onExpandedChange,
                    onPeekChange: beginOrEndPeek
                )
            } else {
                ExpandedDashboardView(
                    store: store,
                    isDetached: isDetached,
                    attachment: attachment,
                    onOpenSettings: onOpenSettings,
                    onExpandedChange: onExpandedChange
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
        .environment(\.sideBarLiquidGlassEnabled, store.liquidGlassEnabled)
    }

    private func beginOrEndPeek(recordID: String?, hovering: Bool) {
        onPeekChange(recordID, hovering)
    }
}

private func preferredUsageWindow(
    in windows: [UsageWindow],
    id: String,
    labelFragment: String,
    periodRange: ClosedRange<Double>
) -> UsageWindow? {
    func matches(_ window: UsageWindow) -> Bool {
        let normalizedLabel = window.label
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
        if normalizedLabel.contains(labelFragment) { return true }
        guard let periodSeconds = window.periodSeconds else { return false }
        return periodRange.contains(periodSeconds)
    }

    return windows.first { $0.id == id && matches($0) }
        ?? windows.lazy.filter(matches).max { lhs, rhs in
            let left = lhs.percentUsed ?? -1
            let right = rhs.percentUsed ?? -1
            return left == right ? lhs.id > rhs.id : left < right
        }
}

private func fiveHourUsageWindow(in windows: [UsageWindow]) -> UsageWindow? {
    preferredUsageWindow(
        in: windows,
        id: "primary",
        labelFragment: "5 hour",
        periodRange: (4.0 * 60 * 60)...(6.0 * 60 * 60)
    )
}

private func sevenDayUsageWindow(in windows: [UsageWindow]) -> UsageWindow? {
    preferredUsageWindow(
        in: windows,
        id: "secondary",
        labelFragment: "7 day",
        periodRange: (6.0 * 24 * 60 * 60)...(8.0 * 24 * 60 * 60)
    )
}

@MainActor
private struct CompactRailView: View {
    let store: UsageStore
    let isDetached: Bool
    let attachment: SidebarEdge
    let onExpandedChange: (Bool) -> Void
    let onPeekChange: (String?, Bool) -> Void
    @Environment(\.sideBarLiquidGlassEnabled) private var usesLiquidGlass

    private var compactRecords: [ProviderRecord] {
        store.compactRecords
    }

    private var expandIconName: String {
        switch attachment {
        case .left:
            "chevron.right.2"
        case .right:
            "chevron.left.2"
        case .top:
            "chevron.down.2"
        case .bottom:
            "chevron.up.2"
        }
    }

    private var expandButtonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarDragHandle(attachment: attachment)
                .padding(.top, 2)
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(compactRecords) { record in
                        CompactProviderIndicator(
                            record: record,
                            onHoverChange: { hovering in
                                onPeekChange(record.id, hovering)
                            }
                        )
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 6)

            Button {
                onExpandedChange(true)
            } label: {
                Image(systemName: expandIconName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SideBarTheme.primaryText)
                    .frame(width: 32, height: 30)
                    .background(
                        usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.elevated,
                        in: expandButtonShape
                    )
                    .sideBarGlassEffect(in: expandButtonShape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand SideBarAI")
            .accessibilityHint("Shows the full AI usage dashboard")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                CompactRailShape(isDetached: isDetached, attachment: attachment)
                    .fill(usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.canvas)
                if !usesLiquidGlass {
                    CompactRailShape(isDetached: isDetached, attachment: attachment)
                        .fill(SideBarTheme.panelTint)
                }
            }
            .allowsHitTesting(false)
        }
        .sideBarGlassEffect(in: CompactRailShape(isDetached: isDetached, attachment: attachment))
        .clipShape(CompactRailShape(isDetached: isDetached, attachment: attachment))
        .overlay {
            if !usesLiquidGlass {
                CompactRailShape(isDetached: isDetached, attachment: attachment)
                    .stroke(SideBarTheme.border.opacity(0.22), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct CompactRailShape: Shape {
    let isDetached: Bool
    let attachment: SidebarEdge
    private let cornerRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        let radii: RectangleCornerRadii

        if isDetached {
            radii = .init(
                topLeading: radius,
                bottomLeading: radius,
                bottomTrailing: radius,
                topTrailing: radius
            )
        } else {
            switch attachment {
            case .left:
                radii = .init(
                    topLeading: 0,
                    bottomLeading: 0,
                    bottomTrailing: radius,
                    topTrailing: radius
                )
            case .right:
                radii = .init(
                    topLeading: radius,
                    bottomLeading: radius,
                    bottomTrailing: 0,
                    topTrailing: 0
                )
            case .top:
                radii = .init(
                    topLeading: 0,
                    bottomLeading: radius,
                    bottomTrailing: radius,
                    topTrailing: 0
                )
            case .bottom:
                radii = .init(
                    topLeading: radius,
                    bottomLeading: 0,
                    bottomTrailing: 0,
                    topTrailing: radius
                )
            }
        }

        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: rect)
    }
}

@MainActor
private struct SidebarNativeDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            (window?.delegate as? EdgePanelController)?.dragPanel(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

@MainActor
private struct SidebarDragHandle: View {
    let attachment: SidebarEdge
    @Environment(\.sideBarLiquidGlassEnabled) private var usesLiquidGlass

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SideBarTheme.mutedText)
            .frame(width: 28, height: 20)
            .background(
                usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.elevated,
                in: Capsule()
            )
            .sideBarGlassEffect(in: Capsule())
            .contentShape(Rectangle())
            .overlay { SidebarNativeDragHandle() }
            .help("Drag SideBarAI away from the current " + attachment.edgeName + " edge to detach it; drag it toward any edge to reattach")
            .accessibilityLabel("SideBarAI drag handle")
            .accessibilityHint("Drag away from the current " + attachment.edgeName + " edge to detach, or toward any screen edge to reattach")
    }
}

@MainActor
private struct CompactProviderIndicator: View {
    let record: ProviderRecord
    let onHoverChange: (Bool) -> Void

    private var usageSnapshot: UsageSnapshot? {
        guard case let .usage(snapshot) = record.state else { return nil }
        return snapshot
    }

    private var fiveHourWindow: UsageWindow? {
        guard let usageSnapshot else { return nil }
        return fiveHourUsageWindow(in: usageSnapshot.windows)
    }

    private var sevenDayWindow: UsageWindow? {
        guard let usageSnapshot,
              let window = sevenDayUsageWindow(in: usageSnapshot.windows),
              window.id != primaryWindow?.id else { return nil }
        return window
    }

    private var primaryWindow: UsageWindow? {
        fiveHourWindow ?? usageSnapshot?.windows.first
    }

    private var progress: CGFloat? {
        guard let percentage = primaryWindow?.percentUsed else { return nil }
        return CGFloat(percentage / 100)
    }

    private var secondaryProgress: CGFloat? {
        guard let percentage = sevenDayWindow?.percentUsed else { return nil }
        return CGFloat(percentage / 100)
    }

    private var valueLabel: String {
        if let percentage = primaryWindow?.percentUsed {
            return "\(Int(percentage.rounded()))%"
        }
        if record.state.isLoading {
            return "…"
        }
        return "—"
    }

    private var levelColor: Color {
        SideBarTheme.usageColor(
            percentUsed: primaryWindow?.percentUsed,
            normal: record.provider.accentColor
        )
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    /// A provider tile that fills from the bottom with the primary window's usage,
    /// with a thin 7-day meter along its base.
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                tileShape.fill(SideBarTheme.usageTrackSubtle)

                if let progress {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [levelColor.opacity(0.55), levelColor.opacity(0.2)],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(height: geometry.size.height * min(max(progress, 0), 1))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .animation(.easeOut(duration: 0.25), value: progress)
                }

                Group {
                    if record.state.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(SideBarTheme.secondaryText)
                    } else {
                        ProviderIcon(
                            provider: record.provider,
                            size: 17,
                            tint: progress == nil ? record.provider.accentColor : SideBarTheme.primaryText
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let secondaryProgress {
                    UsageMeterBar(
                        progress: secondaryProgress,
                        color: SideBarTheme.usageColor(
                            percentUsed: sevenDayWindow?.percentUsed,
                            normal: SideBarTheme.usageSevenDay
                        ),
                        height: 3
                    )
                    .padding(.horizontal, 7)
                    .padding(.bottom, 5)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(tileShape)
            .overlay {
                tileShape.stroke(
                    (progress == nil ? record.provider.accentColor : levelColor).opacity(0.35),
                    lineWidth: 0.8
                )
            }
            .overlay(alignment: .topTrailing) {
                if record.isActive {
                    Circle()
                        .fill(SideBarTheme.success)
                        .frame(width: 7, height: 7)
                        .overlay {
                            Circle().stroke(SideBarTheme.canvas, lineWidth: 1.5)
                        }
                        .offset(x: 2, y: -2)
                }
            }

            Text(valueLabel)
                .font(SideBarTheme.caption.weight(.semibold))
                .foregroundStyle(SideBarTheme.primaryText)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityLabel: String {
        var parts = [record.provider.displayName]
        if let accountLabel = record.displayAccountLabel { parts.append(accountLabel) }
        if let planLabel = record.planStatusLabel { parts.append(planLabel) }
        if record.isActive { parts.append("active account") }
        parts.append("usage")
        return parts.joined(separator: ", ")
    }

    private var accessibilityValue: String {
        var usageValues: [String] = []

        if let percentage = fiveHourWindow?.percentUsed {
            usageValues.append("5-hour: " + String(Int(percentage.rounded())) + " percent used")
        } else if let percentage = primaryWindow?.percentUsed {
            usageValues.append(String(Int(percentage.rounded())) + " percent used")
        }

        if let percentage = sevenDayWindow?.percentUsed {
            usageValues.append("7-day: " + String(Int(percentage.rounded())) + " percent used")
        }

        if !usageValues.isEmpty {
            let activeSuffix = record.isActive ? " Active account." : ""
            return usageValues.joined(separator: ". ") + "." + activeSuffix
        }

        if record.state.isLoading {
            return record.isActive ? "Active account. Checking" : "Checking"
        }
        let activeSuffix = record.isActive ? " Active account." : ""
        if let message = record.state.errorMessage {
            return "Unavailable." + activeSuffix + " " + message
        }
        return record.isActive ? "Unavailable. Active account." : "Unavailable"
    }
}

@MainActor
struct PeekUsageView: View {
    let record: ProviderRecord
    let onExpand: () -> Void
    let onHoverChange: (Bool) -> Void
    @Environment(\.sideBarLiquidGlassEnabled) private var usesLiquidGlass
    private var snapshot: UsageSnapshot? {
        if case let .usage(snapshot) = record.state { return snapshot }
        return nil
    }

    private var quickPeekWindows: [UsageWindow] {
        guard let snapshot else { return [] }

        let fiveHour = fiveHourUsageWindow(in: snapshot.windows)
        let sevenDay = sevenDayUsageWindow(in: snapshot.windows)

        var selected = [fiveHour, sevenDay].compactMap { $0 }
        let selectedIDs = Set(selected.map(\.id))
        selected.append(contentsOf: snapshot.windows.filter { !selectedIDs.contains($0.id) })
        return Array(selected.prefix(2))
    }

    private var peakPercent: Double? {
        QuotaSummary.highestPercentage(in: [record]).map(Double.init)
    }

    private var planDateLabels: [String] {
        [snapshot?.savedResetLabel, snapshot?.subscriptionRenewalLabel()].compactMap { $0 }
    }

    private var panelShape: some Shape { ChatBubbleShape() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch record.state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking usage…")
                }
                .font(SideBarTheme.body)
                .foregroundStyle(SideBarTheme.secondaryText)

            case let .authenticated(accountLabel):
                PeekStateMessage(
                    title: "Connected",
                    detail: accountLabel ?? "Waiting for usage data."
                )

            case let .unavailable(message):
                PeekStateMessage(title: "Unavailable", detail: message)

            case .usage:
                if !quickPeekWindows.isEmpty {
                    PeekCombinedUsageView(
                        windows: quickPeekWindows,
                        accent: record.provider.accentColor
                    )
                }
            }

            if !planDateLabels.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(planDateLabels, id: \.self) { label in
                        Label(label, systemImage: "calendar")
                    }
                }
                .font(SideBarTheme.caption)
                .foregroundStyle(SideBarTheme.secondaryText)
            }

            if let snapshot, snapshot.hasModelUsage {
                PeekModelCostRow(snapshot: snapshot, accent: record.provider.accentColor)
            }

            Button {
                onExpand()
            } label: {
                HStack(spacing: 7) {
                    Text("Open dashboard")
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .font(SideBarTheme.caption.weight(.semibold))
                .foregroundStyle(SideBarTheme.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.brand.opacity(0.18),
                    in: Capsule()
                )
                .sideBarGlassEffect(in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel("Open full usage dashboard")
        }
        .padding(.leading, 16)
        .padding(.trailing, 16 + ChatBubbleShape.tailWidth)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            if usesLiquidGlass {
                panelShape.fill(SideBarTheme.glassSurface)
            } else {
                ZStack {
                    panelShape.fill(SideBarTheme.canvas)
                    panelShape.fill(SideBarTheme.panelTint)
                }
            }
        }
        .sideBarGlassEffect(in: panelShape)
        .clipShape(panelShape)
        .overlay {
            if !usesLiquidGlass {
                panelShape.stroke(SideBarTheme.border, lineWidth: 0.8)
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: onHoverChange)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProviderTile(provider: record.provider, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.provider.displayName)
                        .font(SideBarTheme.headline)
                        .foregroundStyle(SideBarTheme.primaryText)
                        .lineLimit(1)
                    Text(record.displayAccountLabel ?? record.provider.sourceDescription)
                        .font(SideBarTheme.caption)
                        .foregroundStyle(SideBarTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 6)

                if let peak = SideBarTheme.percentLabel(peakPercent) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(peak)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(SideBarTheme.usageColor(percentUsed: peakPercent, normal: SideBarTheme.primaryText))
                            .monospacedDigit()
                        Text("PEAK")
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(SideBarTheme.mutedText)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Peak quota usage \(peak)")
                }
            }

            if record.isActive || record.planStatusLabel != nil {
                HStack(spacing: 5) {
                    if record.isActive {
                        Chip(text: "ACTIVE", color: SideBarTheme.success, showsDot: true)
                    }
                    if let planLabel = record.planStatusLabel {
                        Chip(text: planLabel.uppercased(), color: record.provider.accentColor)
                    }
                }
            }
        }
    }
}

/// One-line local model usage summary: estimated cost, token volume and lookback.
@MainActor
private struct PeekModelCostRow: View {
    let snapshot: UsageSnapshot
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(tokenLine)
                    .foregroundStyle(SideBarTheme.secondaryText)
                Text("Local OMP · \(OMPModelUsageSource.lookbackLabel)")
                    .foregroundStyle(SideBarTheme.mutedText)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            Text(costLabel)
                .font(SideBarTheme.body.weight(.semibold))
                .foregroundStyle(snapshot.pricedModelCost == nil ? SideBarTheme.mutedText : accent)
                .monospacedDigit()
        }
        .font(SideBarTheme.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SideBarTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(snapshot.modelUsageDetail ?? "")
        .accessibilityElement(children: .combine)
    }

    private var tokenLine: String {
        guard let tokens = snapshot.totalModelTokens,
              let formatted = UsageNumberFormatter.compactTokenString(tokens) else {
            return "No account-linked records"
        }
        let count = snapshot.modelUsage.count
        return "\(formatted) tokens · \(count) \(count == 1 ? "model" : "models")"
    }

    private var costLabel: String {
        guard let cost = snapshot.pricedModelCost,
              let formatted = UsageNumberFormatter.currencyString(cost) else { return "—" }
        return "≈ \(formatted)"
    }
}


private struct ChatBubbleShape: Shape {
    static let tailWidth: CGFloat = 10

    let cornerRadius: CGFloat = 24
    let tailHeight: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let bodyRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(0, rect.width - Self.tailWidth),
            height: rect.height
        )
        let radius = min(cornerRadius, min(bodyRect.width, bodyRect.height) / 2)
        let tailCenter = bodyRect.midY
        var path = Path()

        path.move(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY))
        path.addArc(
            center: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY + radius),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: tailCenter - tailHeight / 2))
        path.addLine(to: CGPoint(x: rect.maxX, y: tailCenter))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: tailCenter + tailHeight / 2))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
        path.addArc(
            center: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
        path.addArc(
            center: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
        path.addArc(
            center: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY + radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

@MainActor
private struct PeekCombinedUsageView: View {
    let windows: [UsageWindow]
    let accent: Color
    @Environment(\.sideBarLiquidGlassEnabled) private var usesLiquidGlass
    var body: some View {
        Group {
            if windows.count == 1, let window = windows.first {
                HStack(spacing: 16) {
                    PeekUsageGauge(window: window, accent: accent, showsDetails: false)
                    PeekUsageDetails(window: window, accent: accent, alignment: .leading)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        PeekUsageGauge(window: window, accent: accent, showsDetails: true)
                            .frame(maxWidth: .infinity)

                        if index < windows.count - 1 {
                            Rectangle()
                                .fill(SideBarTheme.border)
                                .frame(width: 1)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
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
    }
}

@MainActor
private struct PeekUsageGauge: View {
    let window: UsageWindow
    let accent: Color
    let showsDetails: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(SideBarTheme.usageTrack, lineWidth: 7)

                if let percentage, percentage > 0 {
                    Circle()
                        .trim(from: 0, to: percentage / 100)
                        .stroke(
                            AngularGradient(
                                colors: [levelColor.opacity(0.55), levelColor],
                                center: .center,
                                startAngle: .degrees(0),
                                endAngle: .degrees(360 * percentage / 100)
                            ),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }

                VStack(spacing: 0) {
                    Text(valueLabel)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(SideBarTheme.primaryText)
                        .monospacedDigit()
                    Text("USED")
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(SideBarTheme.mutedText)
                }
            }
            .frame(width: 72, height: 72)

            if showsDetails {
                PeekUsageDetails(window: window, accent: accent, alignment: .center)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var percentage: Double? {
        window.percentUsed.map { min(max($0, 0), 100) }
    }

    private var levelColor: Color {
        SideBarTheme.usageColor(percentUsed: percentage, normal: accent)
    }

    private var valueLabel: String {
        SideBarTheme.percentLabel(percentage) ?? window.unit.displayName.capitalized
    }
}

/// Window name, remaining share and reset timing shown beside or under a gauge.
@MainActor
private struct PeekUsageDetails: View {
    let window: UsageWindow
    let accent: Color
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(window.label.replacingOccurrences(of: " window", with: ""))
                .font(SideBarTheme.caption.weight(.semibold))
                .foregroundStyle(SideBarTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(remainingLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(SideBarTheme.usageColor(percentUsed: window.percentUsed, normal: accent))
                .monospacedDigit()

            if window.resetDate != nil {
                Text(window.resetCountdownLabel)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(SideBarTheme.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let clock = window.resetClockLabel {
                    Text(clock)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(SideBarTheme.mutedText)
                        .lineLimit(1)
                }
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    private var remainingLabel: String {
        guard let percentage = window.percentUsed else { return "Usage reported" }
        return "\(Int((100 - min(max(percentage, 0), 100)).rounded()))% left"
    }
}

@MainActor
private struct PeekStateMessage: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(SideBarTheme.body.weight(.semibold))
                .foregroundStyle(SideBarTheme.primaryText)
            Text(detail)
                .font(SideBarTheme.caption)
                .foregroundStyle(SideBarTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
private struct ExpandedDashboardView: View {
    let store: UsageStore
    let isDetached: Bool
    let attachment: SidebarEdge
    let onOpenSettings: () -> Void
    let onExpandedChange: (Bool) -> Void
    @Environment(\.sideBarLiquidGlassEnabled) private var usesLiquidGlass
    private var panelShape: UnevenRoundedRectangle {
        let radius: CGFloat = 26
        let radii: RectangleCornerRadii

        if isDetached {
            radii = .init(
                topLeading: radius,
                bottomLeading: radius,
                bottomTrailing: radius,
                topTrailing: radius
            )
        } else {
            switch attachment {
            case .left:
                radii = .init(
                    topLeading: 0,
                    bottomLeading: 0,
                    bottomTrailing: radius,
                    topTrailing: radius
                )
            case .right:
                radii = .init(
                    topLeading: radius,
                    bottomLeading: radius,
                    bottomTrailing: 0,
                    topTrailing: 0
                )
            case .top:
                radii = .init(
                    topLeading: 0,
                    bottomLeading: radius,
                    bottomTrailing: radius,
                    topTrailing: 0
                )
            case .bottom:
                radii = .init(
                    topLeading: radius,
                    bottomLeading: 0,
                    bottomTrailing: 0,
                    topTrailing: radius
                )
            }
        }

        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
    }

    private var collapseIconName: String {
        switch attachment {
        case .left:
            "chevron.left.2"
        case .right:
            "chevron.right.2"
        case .top:
            "chevron.up.2"
        case .bottom:
            "chevron.down.2"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                SidebarDragHandle(attachment: attachment)
                BrandMark()

                Spacer(minLength: 6)

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SideBarTheme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.elevated,
                            in: Circle()
                        )
                        .sideBarGlassEffect(in: Circle())
                }
                .buttonStyle(.plain)
                .help("Open Settings")
                .accessibilityLabel("Open SideBarAI Settings")

                Button {
                    onExpandedChange(false)
                } label: {
                    Image(systemName: collapseIconName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SideBarTheme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.elevated,
                            in: Circle()
                        )
                        .sideBarGlassEffect(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse SideBarAI")
                .accessibilityHint("Returns to the compact edge rail")
            }

            HStack(spacing: 8) {
                StatusPill(records: store.presentationRecords, isRefreshing: store.isRefreshing)
                Spacer(minLength: 6)
                refreshStatus
                    .font(SideBarTheme.caption)
                    .foregroundStyle(SideBarTheme.mutedText)
                    .lineLimit(1)
                Button {
                    store.refresh()
                } label: {
                    Group {
                        if store.isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(SideBarTheme.secondaryText)
                        }
                    }
                        .frame(width: 26, height: 26)
                        .background(
                            usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.elevated,
                            in: Circle()
                        )
                        .sideBarGlassEffect(in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .help("Refresh usage")
                .accessibilityLabel("Refresh provider usage")
                .accessibilityHint("Reads the latest usage from configured provider sessions")
            }
            .padding(.top, 16)
            .padding(.bottom, 14)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(store.presentationRecords) { record in
                        UsageCardView(record: record)
                    }
                }
                .padding(.bottom, 14)
            }

            Label("Read from your local CLI sessions · credentials stay on this Mac", systemImage: "lock.fill")
                .font(SideBarTheme.caption)
                .foregroundStyle(SideBarTheme.mutedText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(SideBarTheme.border)
                        .frame(height: 1)
                }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if usesLiquidGlass {
                panelShape.fill(SideBarTheme.glassSurface)
            } else {
                ZStack {
                    panelShape.fill(SideBarTheme.canvas)
                    panelShape.fill(SideBarTheme.panelTint)
                }
            }
        }
        .sideBarGlassEffect(in: panelShape)
        .clipShape(panelShape)
        .overlay {
            if !usesLiquidGlass {
                panelShape
                    .stroke(SideBarTheme.border, lineWidth: 0.8)
            }
        }
    }

    @ViewBuilder
    private var refreshStatus: some View {
        if store.isRefreshing {
            Text("Checking providers…")
        } else if let date = store.lastRefreshCompleted ?? store.lastRefreshAttempt {
            Text("Last checked \(date, style: .relative)")
        } else {
            Text("Last checked —")
        }
    }
}

@MainActor
private struct BrandMark: View {
    var body: some View {
        HStack(spacing: 9) {
            AppGlyph(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("SideBarAI")
                    .font(SideBarTheme.title)
                    .foregroundStyle(SideBarTheme.primaryText)
                Text("AI usage at a glance")
                    .font(SideBarTheme.caption)
                    .foregroundStyle(SideBarTheme.mutedText)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SideBarAI")
    }
}

@MainActor
private struct StatusPill: View {
    let records: [ProviderRecord]
    let isRefreshing: Bool
    @Environment(\.sideBarLiquidGlassEnabled) private var usesLiquidGlass
    private var status: (label: String, color: Color) {
        let syncStatus = ProviderRecord.syncStatus(
            for: records,
            isRefreshing: isRefreshing
        )
        let color: Color
        switch syncStatus {
        case .synced:
            color = SideBarTheme.success
        case .checking, .partial, .setup:
            color = SideBarTheme.warning
        }
        return (syncStatus.label, color)
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
                .shadow(color: status.color.opacity(0.8), radius: 4)
            Text(status.label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.7)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(SideBarTheme.secondaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.elevated,
            in: Capsule()
        )
        .sideBarGlassEffect(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage status: \(status.label.lowercased())")
    }
}
