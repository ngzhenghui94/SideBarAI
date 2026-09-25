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

    private var expandButtonRadii: RectangleCornerRadii {
        switch attachment {
        case .left:
            .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 11, topTrailing: 11)
        case .right:
            .init(topLeading: 11, bottomLeading: 11, bottomTrailing: 0, topTrailing: 0)
        case .top:
            .init(topLeading: 0, bottomLeading: 11, bottomTrailing: 11, topTrailing: 0)
        case .bottom:
            .init(topLeading: 11, bottomLeading: 0, bottomTrailing: 0, topTrailing: 11)
        }
    }

    private var expandButtonShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: expandButtonRadii, style: .continuous)
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
            CompactRailShape(isDetached: isDetached, attachment: attachment)
                .fill(usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.canvas)
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
            return "..."
        }
        return "—"
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(SideBarTheme.usageTrack, lineWidth: 3)

                if let progress {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            fiveHourWindow == nil ? record.provider.accentColor : SideBarTheme.success,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.22), value: progress)
                }

                if sevenDayWindow != nil {
                    Circle()
                        .stroke(SideBarTheme.usageTrackSubtle, lineWidth: 2)
                        .frame(width: 29, height: 29)

                    if let secondaryProgress {
                        Circle()
                            .trim(from: 0, to: secondaryProgress)
                            .stroke(
                                SideBarTheme.usageSevenDay,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round)
                            )
                            .frame(width: 29, height: 29)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.22), value: secondaryProgress)
                    }
                }

                if record.state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(SideBarTheme.secondaryText)
                } else {
                    ProviderIcon(
                        provider: record.provider,
                        size: 16,
                        tint: SideBarTheme.primaryText
                    )
                }
            }
            .frame(width: 42, height: 42)
            .overlay(alignment: .topTrailing) {
                if record.isActive {
                    Circle()
                        .fill(SideBarTheme.success)
                        .frame(width: 6, height: 6)
                        .overlay {
                            Circle().stroke(SideBarTheme.canvas, lineWidth: 1.25)
                        }
                }
            }

            Text(valueLabel)
                .font(SideBarTheme.caption)
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
    private var modelUsageDetail: String? {
        guard let snapshot,
              snapshot.hasModelUsage else { return nil }
        return snapshot.modelUsageDetail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(record.provider.accentColor.opacity(0.18))
                    ProviderIcon(
                        provider: record.provider,
                        size: 19,
                        tint: record.provider.accentColor
                    )
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.provider.displayName)
                        .font(SideBarTheme.headline)
                        .foregroundStyle(SideBarTheme.primaryText)
                        .lineLimit(1)
                    Text(record.displayAccountLabel ?? record.provider.sourceDescription)
                        .font(SideBarTheme.caption)
                        .foregroundStyle(SideBarTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let planLabel = record.planStatusLabel {
                        Text("Plan: \(planLabel)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(record.provider.accentColor)
                    }
                    if let label = snapshot?.savedResetLabel {
                        Text(label)
                            .font(SideBarTheme.caption)
                            .foregroundStyle(record.provider.accentColor)
                    }
                    if let label = snapshot?.subscriptionRenewalLabel() {
                        Text(label)
                            .font(SideBarTheme.caption)
                            .foregroundStyle(SideBarTheme.secondaryText)
                    }
                }

                Spacer(minLength: 6)

                if record.isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(SideBarTheme.success)
                }
            }

            Text("Usage overview")
                .font(SideBarTheme.body.weight(.semibold))
                .foregroundStyle(SideBarTheme.primaryText)
                .padding(.top, 18)
                .padding(.bottom, 10)

            Group {
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
                    VStack(alignment: .leading, spacing: 8) {
                        PeekCombinedUsageView(
                            windows: quickPeekWindows,
                            accent: record.provider.accentColor
                        )
                        if let modelUsageDetail {
                            Text(modelUsageDetail)
                                .font(SideBarTheme.caption)
                                .foregroundStyle(SideBarTheme.secondaryText)
                                .lineLimit(2)
                                .help(modelUsageDetail)
                                .accessibilityLabel(modelUsageDetail)
                        }
                    }
            }
            }

            Spacer(minLength: 14)

            Button {
                onExpand()
            } label: {
                HStack(spacing: 7) {
                    Text("Open dashboard")
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .font(SideBarTheme.caption)
                .foregroundStyle(SideBarTheme.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    usesLiquidGlass ? SideBarTheme.glassSurface : SideBarTheme.elevated,
                    in: Capsule()
                )
                .sideBarGlassEffect(in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open full usage dashboard")
        }
        .padding(.leading, 18)
        .padding(.trailing, 18 + ChatBubbleShape.tailWidth)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if usesLiquidGlass {
                ChatBubbleShape()
                    .fill(SideBarTheme.glassSurface)
            } else {
                ZStack {
                    ChatBubbleShape()
                        .fill(SideBarTheme.canvas)
                    ChatBubbleShape()
                        .fill(.ultraThinMaterial)
                        .opacity(0.15)
                }
            }
        }
        .sideBarGlassEffect(in: ChatBubbleShape())
        .clipShape(ChatBubbleShape())
        .overlay {
            if !usesLiquidGlass {
                ChatBubbleShape()
                    .stroke(SideBarTheme.border, lineWidth: 0.8)
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: onHoverChange)
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
        HStack(alignment: .center, spacing: 10) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                PeekUsageGauge(window: window, accent: accent)
                    .frame(maxWidth: .infinity)

                if index < windows.count - 1 {
                    Rectangle()
                        .fill(SideBarTheme.border)
                        .frame(width: 1, height: 122)
                }
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

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(SideBarTheme.usageTrack, lineWidth: 6)

                if let percentage {
                    Circle()
                        .trim(from: 0, to: percentage / 100)
                        .stroke(
                            accent,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }

                VStack(spacing: 0) {
                    Text(valueLabel)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(SideBarTheme.primaryText)
                        .monospacedDigit()
                    Text("USED")
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(SideBarTheme.mutedText)
                }
            }
            .frame(width: 68, height: 68)

            VStack(spacing: 2) {
                Text(shortLabel)
                    .font(SideBarTheme.caption.weight(.semibold))
                    .foregroundStyle(SideBarTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(remainingLabel)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
            }

            if let resetDate = window.resetDate {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text(resetDate, style: .relative)
                        .monospacedDigit()
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(SideBarTheme.mutedText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var percentage: Double? {
        window.percentUsed.map { min(max($0, 0), 100) }
    }

    private var valueLabel: String {
        guard let percentage else { return window.unit.displayName.capitalized }
        return "\(Int(percentage.rounded()))%"
    }

    private var remainingLabel: String {
        guard let percentage else { return "Usage reported" }
        return "\(Int((100 - percentage).rounded()))% left"
    }

    private var shortLabel: String {
        window.label.replacingOccurrences(of: " window", with: "")
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
            HStack(alignment: .top, spacing: 12) {
                SidebarDragHandle(attachment: attachment)
                BrandMark(compact: false)

                Spacer(minLength: 6)

                StatusPill(records: store.presentationRecords, isRefreshing: store.isRefreshing)

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

            Text("Usage read from your installed AI CLI sessions.")
                .font(SideBarTheme.body)
                .foregroundStyle(SideBarTheme.secondaryText)
                .padding(.top, 16)
                .padding(.bottom, 18)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(store.presentationRecords) { record in
                        UsageCardView(record: record)
                    }
                }
                .padding(.bottom, 14)
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SideBarTheme.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Provider credentials stay on this Mac")
                        .font(SideBarTheme.caption)
                        .foregroundStyle(SideBarTheme.mutedText)
                    refreshStatus
                }

                Spacer(minLength: 8)

                Button("Refresh") {
                    store.refresh()
                }
                .font(SideBarTheme.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(SideBarTheme.secondaryText)
                .disabled(store.isRefreshing)
                .accessibilityLabel("Refresh provider usage")
                .accessibilityHint("Reads the latest usage from configured provider sessions")
            }
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
                    Rectangle().fill(.ultraThinMaterial).opacity(0.15)
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
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking providers…")
            }
        } else if let date = store.lastRefreshCompleted ?? store.lastRefreshAttempt {
            Text("Last checked \(date, style: .relative)")
        } else {
            Text("Last checked —")
        }
    }
}

@MainActor
private struct BrandMark: View {
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 0 : 8) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.98, green: 0.43, blue: 0.25), Color(red: 0.96, green: 0.18, blue: 0.53)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "sparkles")
                    .font(.system(size: compact ? 13 : 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: compact ? 34 : 32, height: compact ? 34 : 32)

            if !compact {
                Text("SideBarAI")
                    .font(SideBarTheme.title)
                    .foregroundStyle(SideBarTheme.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
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
            color = .orange
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
