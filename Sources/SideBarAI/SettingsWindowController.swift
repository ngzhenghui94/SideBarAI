import AppKit
import SwiftUI
import Foundation

enum SettingsWindowPlacement {
    static func centeredFrame(for frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let centered = CGRect(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2,
            width: frame.width,
            height: frame.height
        )
        return SidebarFramePlacement.clamped(centered, to: visibleFrame)
    }

    static func restoredFrame(
        for frame: CGRect,
        in visibleFrames: [CGRect]
    ) -> CGRect? {
        guard let targetFrame = SidebarFramePlacement.nearestVisibleFrame(
            to: frame,
            among: visibleFrames
        ) else {
            return nil
        }

        if visibleFrames.contains(where: { $0.intersects(frame) }) {
            return SidebarFramePlacement.clamped(frame, to: targetFrame)
        }
        return centeredFrame(for: frame, in: targetFrame)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var hasCenteredWindow = false

    init(store: UsageStore) {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "SideBarAI Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.contentMinSize = NSSize(width: 460, height: 520)
        window.contentViewController = NSHostingController(
            rootView: SettingsView(store: store) { [weak self] in
                self?.closeSettings()
            }
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else {
            return
        }

        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        if !hasCenteredWindow {
            if let visibleFrame = NSScreen.main?.visibleFrame ?? visibleFrames.first {
                let frame = SettingsWindowPlacement.centeredFrame(
                    for: window.frame,
                    in: visibleFrame
                )
                window.setFrame(frame, display: false)
            } else {
                window.center()
            }
            hasCenteredWindow = true
        } else if let frame = SettingsWindowPlacement.restoredFrame(
            for: window.frame,
            in: visibleFrames
        ) {
            window.setFrame(frame, display: false)
        }

        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func closeSettings() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
    }
}
