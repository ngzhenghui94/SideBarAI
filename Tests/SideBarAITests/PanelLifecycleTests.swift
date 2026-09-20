import Foundation
import Testing
@testable import SideBarAI

@Suite(.serialized)
struct PanelLifecycleTests {
    @Test
    func offscreenDragUsesNearestDisplayBeforeClamping() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_200, y: 0, width: 1_000, height: 800)
        ]
        let draggedFrame = CGRect(x: -900, y: 220, width: 80, height: 160)

        let nearest = SidebarFramePlacement.nearestVisibleFrame(
            to: draggedFrame,
            among: displays
        )
        #expect(nearest == displays[0])

        let recoveredFrame = SidebarFramePlacement.clamped(
            draggedFrame,
            to: nearest ?? .zero
        )
        #expect(recoveredFrame == CGRect(x: 0, y: 220, width: 80, height: 160))
    }

    @Test
    func attachedPanelPreservesAlongEdgePositionAcrossDisplayChanges() {
        let panelSize = CGSize(width: 80, height: 180)
        let horizontalDisplay = CGRect(x: 0, y: 100, width: 1_000, height: 700)
        let movedHorizontalDisplay = CGRect(x: 1_200, y: 0, width: 1_000, height: 900)
        let rightEdgeFrame = SidebarFramePlacement.attachedFrame(
            CGRect(x: 300, y: 310, width: 20, height: 20),
            size: panelSize,
            to: horizontalDisplay,
            edge: .right,
            preservingPosition: 310
        )
        let movedRightEdgeFrame = SidebarFramePlacement.attachedFrame(
            rightEdgeFrame,
            size: panelSize,
            to: movedHorizontalDisplay,
            edge: .right,
            preservingPosition: SidebarFramePlacement.alongEdgePosition(
                for: rightEdgeFrame,
                edge: .right
            )
        )
        #expect(movedRightEdgeFrame.origin.y == 310)

        let verticalDisplay = CGRect(x: 100, y: 0, width: 1_000, height: 800)
        let movedVerticalDisplay = CGRect(x: 0, y: 1_000, width: 1_200, height: 800)
        let topEdgeFrame = SidebarFramePlacement.attachedFrame(
            CGRect(x: 420, y: 300, width: 20, height: 20),
            size: panelSize,
            to: verticalDisplay,
            edge: .top,
            preservingPosition: 420
        )
        let movedTopEdgeFrame = SidebarFramePlacement.attachedFrame(
            topEdgeFrame,
            size: panelSize,
            to: movedVerticalDisplay,
            edge: .top,
            preservingPosition: SidebarFramePlacement.alongEdgePosition(
                for: topEdgeFrame,
                edge: .top
            )
        )
        #expect(movedTopEdgeFrame.origin.x == 420)
    }

    @Test
    func hideAndShutdownResetInterruptedDragState() {
        var state = PanelLifecycleState()
        state.beginDragging()
        #expect(state.isDragging)

        state.resetForHide()
        #expect(!state.isDragging)

        state.beginDragging()
        state.shutdown()
        #expect(!state.isDragging)
        #expect(state.isShutdown)

        state.beginDragging()
        #expect(!state.isDragging)
    }

    @Test
    func settingsWindowRecentersWhenItsDisplayDisappears() {
        let remainingDisplay = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        let removedDisplayFrame = CGRect(x: 2_200, y: 100, width: 460, height: 400)

        let restored = SettingsWindowPlacement.restoredFrame(
            for: removedDisplayFrame,
            in: [remainingDisplay]
        )
        #expect(
            restored == CGRect(
                x: 370,
                y: 250,
                width: 460,
                height: 400
            )
        )

        let partiallyOffscreen = CGRect(x: -80, y: 120, width: 460, height: 400)
        let clamped = SettingsWindowPlacement.restoredFrame(
            for: partiallyOffscreen,
            in: [remainingDisplay]
        )
        #expect(clamped?.origin == CGPoint(x: 0, y: 120))
    }
}
