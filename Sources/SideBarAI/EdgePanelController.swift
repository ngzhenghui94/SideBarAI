import AppKit
import SwiftUI
import Foundation
import Observation

private final class PointerMonitorState: @unchecked Sendable {
    var localEventMonitor: Any?
    var globalEventMonitor: Any?
    var collapseTask: Task<Void, Never>?
}

enum SidebarFramePlacement {
    static func isAttached(
        _ frame: CGRect,
        to visibleFrame: CGRect,
        threshold: CGFloat,
        edge: SidebarEdge = .right
    ) -> Bool {
        edgeDistance(for: frame, to: visibleFrame, edge: edge) <= threshold
    }

    static func nearestEdge(
        for frame: CGRect,
        to visibleFrame: CGRect,
        threshold: CGFloat
    ) -> SidebarEdge? {
        guard let edge = SidebarEdge.allCases.min(by: { first, second in
            edgeDistance(for: frame, to: visibleFrame, edge: first)
                < edgeDistance(for: frame, to: visibleFrame, edge: second)
        }),
        isAttached(frame, to: visibleFrame, threshold: threshold, edge: edge) else {
            return nil
        }
        return edge
    }

    static func attachedFrame(
        _ frame: CGRect,
        size: CGSize,
        to visibleFrame: CGRect,
        edge: SidebarEdge,
        preservingPosition: CGFloat? = nil
    ) -> CGRect {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        let centeredX = visibleFrame.midX - size.width / 2
        let centeredY = visibleFrame.midY - size.height / 2

        var result = frame
        result.size = size
        switch edge {
        case .left:
            result.origin.x = visibleFrame.minX
            result.origin.y = min(
                max(preservingPosition ?? centeredY, visibleFrame.minY),
                maximumY
            )
        case .right:
            result.origin.x = maximumX
            result.origin.y = min(
                max(preservingPosition ?? centeredY, visibleFrame.minY),
                maximumY
            )
        case .top:
            result.origin.x = min(
                max(preservingPosition ?? centeredX, visibleFrame.minX),
                maximumX
            )
            result.origin.y = maximumY
        case .bottom:
            result.origin.x = min(
                max(preservingPosition ?? centeredX, visibleFrame.minX),
                maximumX
            )
            result.origin.y = visibleFrame.minY
        }
        return result
    }

    static func clamped(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        var result = frame
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - result.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - result.height)
        result.origin.x = min(max(result.origin.x, visibleFrame.minX), maximumX)
        result.origin.y = min(max(result.origin.y, visibleFrame.minY), maximumY)
        return result
    }
    static func nearestVisibleFrame(
        to frame: CGRect,
        among visibleFrames: [CGRect]
    ) -> CGRect? {
        visibleFrames
            .filter { !$0.isEmpty }
            .min { distanceSquared(from: frame, to: $0) < distanceSquared(from: frame, to: $1) }
    }

    static func alongEdgePosition(for frame: CGRect, edge: SidebarEdge) -> CGFloat {
        switch edge {
        case .left, .right:
            frame.origin.y
        case .top, .bottom:
            frame.origin.x
        }
    }

    static func peekOrigin(
        for frame: CGRect,
        peekSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat
    ) -> CGFloat {
        horizontalPeekOrigin(
            for: frame,
            peekSize: peekSize,
            visibleFrame: visibleFrame,
            gap: gap,
            preferLeft: true
        )
    }

    static func peekFrame(
        for frame: CGRect,
        peekSize: CGSize,
        visibleFrame: CGRect,
        edge: SidebarEdge?,
        gap: CGFloat
    ) -> CGRect {
        var result = CGRect(origin: .zero, size: peekSize)
        let minimumX = visibleFrame.minX
        let maximumX = max(minimumX, visibleFrame.maxX - peekSize.width)
        let minimumY = visibleFrame.minY
        let maximumY = max(minimumY, visibleFrame.maxY - peekSize.height)

        switch edge {
        case .left:
            result.origin.x = horizontalPeekOrigin(
                for: frame,
                peekSize: peekSize,
                visibleFrame: visibleFrame,
                gap: gap,
                preferLeft: false
            )
            result.origin.y = min(max(frame.midY - peekSize.height / 2, minimumY), maximumY)
        case .right, nil:
            result.origin.x = peekOrigin(
                for: frame,
                peekSize: peekSize,
                visibleFrame: visibleFrame,
                gap: gap
            )
            result.origin.y = min(max(frame.midY - peekSize.height / 2, minimumY), maximumY)
        case .top:
            result.origin.x = min(max(frame.midX - peekSize.width / 2, minimumX), maximumX)
            result.origin.y = verticalPeekOrigin(
                for: frame,
                peekSize: peekSize,
                visibleFrame: visibleFrame,
                gap: gap,
                preferBelow: true
            )
        case .bottom:
            result.origin.x = min(max(frame.midX - peekSize.width / 2, minimumX), maximumX)
            result.origin.y = verticalPeekOrigin(
                for: frame,
                peekSize: peekSize,
                visibleFrame: visibleFrame,
                gap: gap,
                preferBelow: false
            )
        }
        return result
    }

    private static func edgeDistance(
        for frame: CGRect,
        to visibleFrame: CGRect,
        edge: SidebarEdge
    ) -> CGFloat {
        switch edge {
        case .left:
            abs(frame.minX - visibleFrame.minX)
        case .right:
            abs(visibleFrame.maxX - frame.maxX)
        case .top:
            abs(visibleFrame.maxY - frame.maxY)
        case .bottom:
            abs(frame.minY - visibleFrame.minY)
        }
    }

    private static func distanceSquared(from frame: CGRect, to visibleFrame: CGRect) -> CGFloat {
        let horizontalDistance: CGFloat
        if frame.maxX < visibleFrame.minX {
            horizontalDistance = visibleFrame.minX - frame.maxX
        } else if visibleFrame.maxX < frame.minX {
            horizontalDistance = frame.minX - visibleFrame.maxX
        } else {
            horizontalDistance = 0
        }

        let verticalDistance: CGFloat
        if frame.maxY < visibleFrame.minY {
            verticalDistance = visibleFrame.minY - frame.maxY
        } else if visibleFrame.maxY < frame.minY {
            verticalDistance = frame.minY - visibleFrame.maxY
        } else {
            verticalDistance = 0
        }

        return horizontalDistance * horizontalDistance + verticalDistance * verticalDistance
    }

    private static func horizontalPeekOrigin(
        for frame: CGRect,
        peekSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat,
        preferLeft: Bool
    ) -> CGFloat {
        let leftOrigin = frame.minX - gap - peekSize.width
        let rightOrigin = frame.maxX + gap
        let minimumX = visibleFrame.minX
        let maximumX = max(minimumX, visibleFrame.maxX - peekSize.width)
        let leftFits = leftOrigin >= minimumX
        let rightFits = rightOrigin <= maximumX
        let origin: CGFloat

        if preferLeft {
            origin = leftFits || !rightFits ? leftOrigin : rightOrigin
        } else {
            origin = rightFits || !leftFits ? rightOrigin : leftOrigin
        }
        return min(max(origin, minimumX), maximumX)
    }

    private static func verticalPeekOrigin(

        for frame: CGRect,
        peekSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat,
        preferBelow: Bool
    ) -> CGFloat {
        let belowOrigin = frame.minY - gap - peekSize.height
        let aboveOrigin = frame.maxY + gap
        let minimumY = visibleFrame.minY
        let maximumY = max(minimumY, visibleFrame.maxY - peekSize.height)
        let belowFits = belowOrigin >= minimumY
        let aboveFits = aboveOrigin <= maximumY
        let origin: CGFloat

        if preferBelow {
            origin = belowFits || !aboveFits ? belowOrigin : aboveOrigin
        } else {
            origin = aboveFits || !belowFits ? aboveOrigin : belowOrigin
        }
        return min(max(origin, minimumY), maximumY)
    }
}

struct PanelLifecycleState: Equatable {
    private(set) var isDragging = false
    private(set) var isShutdown = false

    mutating func beginDragging() {
        guard !isShutdown else { return }
        isDragging = true
    }

    mutating func finishDragging() {
        isDragging = false
    }

    mutating func resetForHide() {
        isDragging = false
    }

    mutating func shutdown() {
        isDragging = false
        isShutdown = true
    }
}

@MainActor
final class EdgePanelController: NSObject, NSWindowDelegate {
    private enum Metrics {
        static let collapsedWidth: CGFloat = 64
        static let peekWidth: CGFloat = 300
        static let expandedWidth: CGFloat = 368
        static let peekGap: CGFloat = 10
        static let attachmentThreshold: CGFloat = 72
        // Rail padding (20), handle (22), scroll padding (12), gap (6), button (30).
        static let compactBaseHeight: CGFloat = 90
        static let compactProviderHeight: CGFloat = 62
        static let compactProviderSpacing: CGFloat = 8
        static let minimumCompactHeight: CGFloat = 140
        static let peekHeight: CGFloat = 384
        static let expandedHeight: CGFloat = 640
    }

    private let store: UsageStore
    private let panel: EdgePanel
    private let peekPanel: EdgePanel
    private let onOpenSettings: () -> Void
    private var hostingView: NSHostingView<SideBarRootView>? = nil
    private var lifecycleState = PanelLifecycleState()
    private(set) var isExpanded = false
    private(set) var isPeeking = false
    private(set) var isDetached = false
    private(set) var attachment: SidebarEdge
    private var peekedRecordID: String?
    private var isPositioningPanel = false
    private var hasPositionedPanel = false

    private var isDraggingPanel: Bool {
        lifecycleState.isDragging
    }

    private var isShuttingDown: Bool {
        lifecycleState.isShutdown
    }

    private nonisolated let pointerMonitorState = PointerMonitorState()

    init(store: UsageStore, onOpenSettings: @escaping () -> Void) {
        let initialFrame = NSRect(
            x: 0,
            y: 0,
            width: Metrics.collapsedWidth,
            height: Metrics.minimumCompactHeight
        )
        let panel = EdgePanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let peekPanel = EdgePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Metrics.peekWidth,
                height: Metrics.peekHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.store = store
        self.panel = panel
        self.peekPanel = peekPanel
        self.onOpenSettings = onOpenSettings
        self.attachment = store.sidebarEdge
        super.init()

        configure(panel)
        configure(peekPanel)
        panel.delegate = self
        panel.isMovableByWindowBackground = true

        let contentView = NSView(frame: NSRect(origin: .zero, size: initialFrame.size))
        contentView.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(rootView: makeRootView())
        self.hostingView = hostingView
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        panel.contentView = contentView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        installPointerMonitors()
        observeStoreChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let localEventMonitor = pointerMonitorState.localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let globalEventMonitor = pointerMonitorState.globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        pointerMonitorState.collapseTask?.cancel()
    }

    func shutdown() {
        lifecycleState.shutdown()
        cancelPendingCollapse()
        removePointerMonitors()
        NotificationCenter.default.removeObserver(self)
        peekPanel.orderOut(nil)
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func show() {
        guard !isShuttingDown else { return }
        dismissPeek()
        reposition()
        panel.orderFrontRegardless()
    }

    func hide() {
        lifecycleState.resetForHide()
        cancelPendingCollapse()
        dismissPeek()
        panel.orderOut(nil)
    }

    func toggleVisibility() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    func attachToEdge(_ edge: SidebarEdge = .right) {
        let wasVisible = panel.isVisible
        cancelPendingCollapse()
        dismissPeek()
        lifecycleState.finishDragging()
        store.setSidebarEdge(edge)
        setAttachment(edge)
        setDetached(false)
        reposition()
        if wasVisible {
            panel.orderFrontRegardless()
        }
    }

    func setExpanded(_ expanded: Bool) {
        if expanded {
            dismissPeek()
        }

        guard isExpanded != expanded else {
            reposition()
            return
        }

        isExpanded = expanded
        if !expanded {
            cancelPendingCollapse()
        }
        reposition()
    }

    func setPeeking(recordID: String?, hovering: Bool) {
        guard !isExpanded else { return }

        if hovering, let recordID {
            cancelPendingCollapse()
            peekedRecordID = recordID
            isPeeking = true
            updatePeekPanelContent()
            return
        }

        guard recordID == nil || recordID == peekedRecordID else { return }
        scheduleCollapse()
    }

    private func makeRootView() -> SideBarRootView {
        SideBarRootView(
            store: store,
            onOpenSettings: onOpenSettings,
            isDetached: isDetached,
            attachment: attachment,
            onExpandedChange: { [weak self] expanded in
                Task { @MainActor [weak self] in
                    self?.setExpanded(expanded)
                }
            },
            onPeekChange: { [weak self] recordID, hovering in
                Task { @MainActor [weak self] in
                    self?.setPeeking(recordID: recordID, hovering: hovering)
                }
            }
        )
    }

    private func setAttachment(_ edge: SidebarEdge) {
        guard attachment != edge else { return }
        attachment = edge
        hostingView?.rootView = makeRootView()
    }

    private func setDetached(_ detached: Bool) {
        guard isDetached != detached else { return }
        isDetached = detached
        hostingView?.rootView = makeRootView()
    }

    func dragPanel(with event: NSEvent) {
        guard !isShuttingDown else { return }
        beginPanelDrag()
        defer { finishPanelDrag() }
        let initialOrigin = panel.frame.origin
        let initialPointer = panel.convertPoint(toScreen: event.locationInWindow)
        while let nextEvent = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            let pointer = NSEvent.mouseLocation
            var frame = panel.frame
            frame.origin = NSPoint(
                x: initialOrigin.x + pointer.x - initialPointer.x,
                y: initialOrigin.y + pointer.y - initialPointer.y
            )
            setPanelFrame(frame)
            if nextEvent.type == .leftMouseUp { break }
        }
    }

    private func beginPanelDrag() {
        guard !isDraggingPanel, !isShuttingDown else { return }
        lifecycleState.beginDragging()
        cancelPendingCollapse()
        dismissPeek()
    }

    private func finishPanelDrag() {
        guard isDraggingPanel else { return }
        lifecycleState.finishDragging()

        guard let screen = screen(containing: panel.frame) ?? screen(nearestTo: panel.frame) else {
            setDetached(true)
            return
        }

        let visibleFrame = screen.visibleFrame
        guard let edge = SidebarFramePlacement.nearestEdge(
            for: panel.frame,
            to: visibleFrame,
            threshold: Metrics.attachmentThreshold
        ) else {
            setDetached(true)
            setPanelFrame(SidebarFramePlacement.clamped(panel.frame, to: visibleFrame))
            return
        }

        store.setSidebarEdge(edge)
        setAttachment(edge)
        setDetached(false)
        attachPanel(
            to: visibleFrame,
            edge: edge,
            preservingPosition: SidebarFramePlacement.alongEdgePosition(
                for: panel.frame,
                edge: edge
            )
        )
    }

    private func attachPanel(
        to visibleFrame: NSRect,
        edge: SidebarEdge,
        preservingPosition: CGFloat? = nil
    ) {
        let panelFrame = SidebarFramePlacement.attachedFrame(
            panel.frame,
            size: size(for: visibleFrame.size),
            to: visibleFrame,
            edge: edge,
            preservingPosition: preservingPosition
        )
        setPanelFrame(panelFrame)
    }

    private func setPanelFrame(_ frame: NSRect) {
        isPositioningPanel = true
        defer { isPositioningPanel = false }
        panel.setFrame(frame, display: true)
        hasPositionedPanel = true
    }

    func windowWillMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel,
              !isPositioningPanel,
              !isShuttingDown else { return }
        beginPanelDrag()
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel,
              !isPositioningPanel,
              !isShuttingDown else { return }
        if !isDraggingPanel {
            beginPanelDrag()
        }
        cancelPendingCollapse()
    }
    private func configure(_ panel: EdgePanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
    }

    private func updatePeekPanelContent() {
        guard let peekedRecordID,
              let record = store.presentationRecords.first(where: { $0.id == peekedRecordID }) else {
            dismissPeek()
            return
        }

        let contentFrame = NSRect(origin: .zero, size: peekPanel.frame.size)
        let contentView = NSView(frame: peekPanel.contentView?.bounds ?? contentFrame)
        contentView.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(
            rootView: PeekUsageView(
                record: record,
                onExpand: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.setExpanded(true)
                    }
                },
                onHoverChange: { [weak self] hovering in
                    Task { @MainActor [weak self] in
                        self?.handlePeekHover(hovering)
                    }
                }
            )
                .environment(\.sideBarLiquidGlassEnabled, store.liquidGlassEnabled)
        )
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        peekPanel.contentView = contentView

        reposition()
        peekPanel.orderFrontRegardless()
    }

    private func dismissPeek() {
        cancelPendingCollapse()
        isPeeking = false
        peekedRecordID = nil
        peekPanel.orderOut(nil)
    }

    private func handlePeekHover(_ hovering: Bool) {
        guard isPeeking else { return }
        if hovering {
            cancelPendingCollapse()
        } else {
            scheduleCollapse()
        }
    }

    private func installPointerMonitors() {
        let eventMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown]

        pointerMonitorState.localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            let isMouseUp = event.type == .leftMouseUp
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else { return }
                if isMouseUp {
                    self.finishPanelDrag()
                } else {
                    self.handlePointerActivity()
                }
            }
            return event
        }

        pointerMonitorState.globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            let isMouseUp = event.type == .leftMouseUp
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else { return }
                if isMouseUp {
                    self.finishPanelDrag()
                } else {
                    self.handlePointerActivity()
                }
            }
        }
    }

    private func handlePointerActivity() {
        guard !isDraggingPanel else { return }
        if isExpanded {
            let hitFrame = panel.frame.insetBy(dx: -8, dy: -8)
            if hitFrame.contains(NSEvent.mouseLocation) {
                cancelPendingCollapse()
            } else if pointerMonitorState.collapseTask == nil {
                scheduleCollapse()
            }
            return
        }

        guard isPeeking else {
            cancelPendingCollapse()
            return
        }

        let hitFrame = NSUnionRect(panel.frame, peekPanel.frame).insetBy(dx: -8, dy: -8)
        if hitFrame.contains(NSEvent.mouseLocation) {
            cancelPendingCollapse()
        } else if pointerMonitorState.collapseTask == nil {
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        guard !isDraggingPanel, !isShuttingDown else { return }
        pointerMonitorState.collapseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }

            guard !Task.isCancelled, let self else {
                return
            }
            guard self.isExpanded || self.isPeeking else {
                self.pointerMonitorState.collapseTask = nil
                return
            }

            let hitFrame: NSRect
            if self.isExpanded {
                hitFrame = self.panel.frame.insetBy(dx: -8, dy: -8)
            } else {
                hitFrame = NSUnionRect(self.panel.frame, self.peekPanel.frame).insetBy(dx: -8, dy: -8)
            }
            guard !hitFrame.contains(NSEvent.mouseLocation) else {
                self.pointerMonitorState.collapseTask = nil
                return
            }

            if self.isExpanded {
                self.setExpanded(false)
            } else {
                self.dismissPeek()
            }
            self.pointerMonitorState.collapseTask = nil
        }
    }

    private func cancelPendingCollapse() {
        pointerMonitorState.collapseTask?.cancel()
        pointerMonitorState.collapseTask = nil
    }

    private func removePointerMonitors() {
        if let localEventMonitor = pointerMonitorState.localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            pointerMonitorState.localEventMonitor = nil
        }
        if let globalEventMonitor = pointerMonitorState.globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            pointerMonitorState.globalEventMonitor = nil
        }
    }

    @objc
    private func screenParametersDidChange(_ notification: Notification) {
        guard !isShuttingDown else { return }
        reposition()
    }

    private func reposition() {
        guard !isDraggingPanel, !isShuttingDown, let screen = currentScreen else {
            return
        }

        let visibleFrame = screen.visibleFrame
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return
        }

        let panelSize = size(for: visibleFrame.size)
        var frame = panel.frame
        let previousCenter = NSPoint(x: frame.midX, y: frame.midY)
        if isDetached {
            frame.size = panelSize
            frame.origin.x = previousCenter.x - panelSize.width / 2
            frame.origin.y = previousCenter.y - panelSize.height / 2
            frame = SidebarFramePlacement.clamped(frame, to: visibleFrame)
        } else {
            frame = SidebarFramePlacement.attachedFrame(
                frame,
                size: panelSize,
                to: visibleFrame,
                edge: attachment,
                preservingPosition: hasPositionedPanel
                    ? SidebarFramePlacement.alongEdgePosition(for: frame, edge: attachment)
                    : nil
            )
        }
        setPanelFrame(frame)

        let peekSize = CGSize(
            width: min(Metrics.peekWidth, visibleFrame.width),
            height: min(Metrics.peekHeight, visibleFrame.height)
        )
        let peekFrame = SidebarFramePlacement.peekFrame(
            for: frame,
            peekSize: peekSize,
            visibleFrame: visibleFrame,
            edge: isDetached ? nil : attachment,
            gap: Metrics.peekGap
        )
        peekPanel.setFrame(peekFrame, display: true)
    }

    private var currentScreen: NSScreen? {
        screen(containing: panel.frame)
            ?? screen(nearestTo: panel.frame)
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) {
            return screen
        }

        return NSScreen.screens
            .filter { $0.visibleFrame.intersects(frame) }
            .max { first, second in
                let firstIntersection = first.visibleFrame.intersection(frame)
                let secondIntersection = second.visibleFrame.intersection(frame)
                return firstIntersection.width * firstIntersection.height
                    < secondIntersection.width * secondIntersection.height
            }
    }

    private func screen(nearestTo frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard let nearestFrame = SidebarFramePlacement.nearestVisibleFrame(
            to: frame,
            among: screens.map(\.visibleFrame)
        ) else {
            return nil
        }
        return screens.first(where: { $0.visibleFrame == nearestFrame })
    }

    private func observeStoreChanges() {
        guard !isShuttingDown else { return }
        let store = store
        withObservationTracking {
            _ = store.presentationRecords
            _ = store.sidebarEdge
            _ = store.liquidGlassEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else { return }
                if self.attachment != self.store.sidebarEdge {
                    self.attachToEdge(self.store.sidebarEdge)
                } else if self.isPeeking {
                    self.updatePeekPanelContent()
                } else {
                    self.reposition()
                }
                self.observeStoreChanges()
            }
        }
    }

    private var compactHeight: CGFloat {
        let accountCount = store.compactRecords.count
        let spacingCount = max(accountCount - 1, 0)
        let contentHeight = Metrics.compactBaseHeight
            + CGFloat(accountCount) * Metrics.compactProviderHeight
            + CGFloat(spacingCount) * Metrics.compactProviderSpacing
        return max(Metrics.minimumCompactHeight, contentHeight)
    }

    private func size(for visibleSize: CGSize) -> CGSize {
        let requestedWidth: CGFloat
        let requestedHeight: CGFloat

        if isExpanded {
            requestedWidth = Metrics.expandedWidth
            requestedHeight = Metrics.expandedHeight
        } else {
            requestedWidth = Metrics.collapsedWidth
            requestedHeight = compactHeight
        }

        return CGSize(
            width: min(requestedWidth, visibleSize.width),
            height: min(requestedHeight, visibleSize.height)
        )
    }
}

@MainActor
private final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
