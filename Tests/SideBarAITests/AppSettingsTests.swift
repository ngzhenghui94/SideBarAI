import Foundation
import Testing
@testable import SideBarAI

@Suite(.serialized)
@MainActor
struct AppSettingsTests {
    @Test
    func refreshScheduleAndDisabledProvidersPersist() async {
        let suiteName = "SideBarAITests.RefreshSettings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let counter = ProviderFetchCounter()
        let adapters: [any UsageProviderAdapter] = [
            SettingsCountingAdapter(provider: .claude, counter: counter),
            SettingsCountingAdapter(provider: .antigravity, counter: counter)
        ]
        let store = UsageStore(
            adapters: adapters,
            defaults: defaults,
            refreshInterval: .seconds(60 * 60)
        )
        await waitForRefresh(store)

        let antigravityFetchesBeforeDisable = await counter.value(for: .antigravity)
        store.setRefreshSchedule(.manual)
        store.setProviderEnabled(false, for: .antigravity)
        await waitForRefresh(store)

        #expect(store.refreshSchedule == .manual)
        #expect(!store.isProviderEnabled(.antigravity))
        #expect(await counter.value(for: .antigravity) == antigravityFetchesBeforeDisable)
        #expect(store.records(for: .antigravity).allSatisfy { record in
            record.state.errorMessage == "Disabled in Settings."
        })
        store.shutdown()

        let reloadedStore = UsageStore(
            adapters: adapters,
            defaults: defaults,
            refreshInterval: .seconds(60 * 60)
        )
        defer { reloadedStore.shutdown() }
        await waitForRefresh(reloadedStore)

        #expect(reloadedStore.refreshSchedule == .manual)
        #expect(!reloadedStore.isProviderEnabled(.antigravity))
    }

    @Test
    func startupModesAndRememberedStatePersist() {
        let suiteName = "SideBarAITests.StartupState.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UsageStore(
            adapters: [],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60)
        )

        #expect(
            store.startupSidebarState
                == SidebarPresentationState(isVisible: true, isExpanded: false)
        )

        store.rememberSidebarState(isVisible: true, isExpanded: true)
        #expect(
            store.startupSidebarState
                == SidebarPresentationState(isVisible: true, isExpanded: true)
        )

        store.setSidebarStartupMode(.hidden)
        #expect(
            store.startupSidebarState
                == SidebarPresentationState(isVisible: false, isExpanded: false)
        )

        store.setSidebarStartupMode(.expanded)
        store.shutdown()

        let reloadedStore = UsageStore(
            adapters: [],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60)
        )
        defer { reloadedStore.shutdown() }

        #expect(reloadedStore.sidebarStartupMode == .expanded)
        #expect(
            reloadedStore.startupSidebarState
                == SidebarPresentationState(isVisible: true, isExpanded: true)
        )
    }

    @Test
    func sidebarAttachmentSupportsEveryScreenEdge() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        let size = CGSize(width: 80, height: 200)
        let edgeFrames: [(SidebarEdge, CGRect)] = [
            (.left, CGRect(x: 100, y: 240, width: 80, height: 200)),
            (.right, CGRect(x: 1_020, y: 240, width: 80, height: 200)),
            (.top, CGRect(x: 560, y: 550, width: 80, height: 200)),
            (.bottom, CGRect(x: 560, y: 50, width: 80, height: 200))
        ]

        for (edge, frame) in edgeFrames {
            #expect(
                SidebarFramePlacement.isAttached(
                    frame,
                    to: visibleFrame,
                    threshold: 0,
                    edge: edge
                )
            )
            #expect(
                SidebarFramePlacement.nearestEdge(
                    for: frame,
                    to: visibleFrame,
                    threshold: 0
                ) == edge
            )
            #expect(
                SidebarFramePlacement.attachedFrame(
                    CGRect(x: 400, y: 300, width: 20, height: 20),
                    size: size,
                    to: visibleFrame,
                    edge: edge,
                    preservingPosition: edge == .left || edge == .right ? 240 : 560
                ) == frame
            )
        }

        let detached = CGRect(x: 500, y: 300, width: 80, height: 200)
        #expect(
            SidebarFramePlacement.nearestEdge(
                for: detached,
                to: visibleFrame,
                threshold: 72
            ) == nil
        )
    }

    @Test
    func sidebarEdgePreferencePersists() {
        let suiteName = "SideBarAITests.SidebarEdge.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UsageStore(
            adapters: [],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60)
        )
        #expect(store.sidebarEdge == .right)
        store.setSidebarEdge(.bottom)
        #expect(store.sidebarEdge == .bottom)
        store.shutdown()

        let reloadedStore = UsageStore(
            adapters: [],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60)
        )
        defer { reloadedStore.shutdown() }
        #expect(reloadedStore.sidebarEdge == .bottom)
    }

    @Test
    func liquidGlassThemePreferencePersists() {
        let suiteName = "SideBarAITests.LiquidGlass.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UsageStore(
            adapters: [],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60)
        )
        #expect(!store.liquidGlassEnabled)
        store.setLiquidGlassEnabled(true)
        #expect(store.liquidGlassEnabled)
        store.shutdown()

        let reloadedStore = UsageStore(
            adapters: [],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60)
        )
        defer { reloadedStore.shutdown() }
        #expect(reloadedStore.liquidGlassEnabled)
    }

    @Test
    func attachedPeekAppearsInsideTheScreenForEveryEdge() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        let panelSize = CGSize(width: 80, height: 200)
        let peekSize = CGSize(width: 300, height: 300)

        for edge in SidebarEdge.allCases {
            let panelFrame = SidebarFramePlacement.attachedFrame(
                CGRect(x: 400, y: 300, width: 20, height: 20),
                size: panelSize,
                to: visibleFrame,
                edge: edge,
                preservingPosition: edge == .left || edge == .right ? 240 : 560
            )
            let peekFrame = SidebarFramePlacement.peekFrame(
                for: panelFrame,
                peekSize: peekSize,
                visibleFrame: visibleFrame,
                edge: edge,
                gap: 10
            )

            #expect(visibleFrame.contains(peekFrame))
            switch edge {
            case .left:
                #expect(peekFrame.minX >= panelFrame.maxX + 10)
            case .right:
                #expect(peekFrame.maxX <= panelFrame.minX - 10)
            case .top:
                #expect(peekFrame.maxY <= panelFrame.minY - 10)
            case .bottom:
                #expect(peekFrame.minY >= panelFrame.maxY + 10)
            }
        }
    }

    @Test
    func sidebarAttachmentUsesRightEdgeThreshold() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        let nearEdge = CGRect(x: 980, y: 200, width: 80, height: 200)
        let detached = CGRect(x: 900, y: 200, width: 80, height: 200)

        #expect(
            SidebarFramePlacement.isAttached(
                nearEdge,
                to: visibleFrame,
                threshold: 72
            )
        )
        #expect(
            !SidebarFramePlacement.isAttached(
                detached,
                to: visibleFrame,
                threshold: 72
            )
        )
    }

    @Test
    func detachedSidebarFrameStaysInsideVisibleFrame() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        let frame = CGRect(x: 40, y: 600, width: 120, height: 200)

        let result = SidebarFramePlacement.clamped(frame, to: visibleFrame)

        #expect(result.origin.x == 100)
        #expect(result.origin.y == 550)
    }

    @Test
    func detachedPeekChoosesAvailableSide() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let peekSize = CGSize(width: 300, height: 300)
        let nearLeft = CGRect(x: 20, y: 250, width: 64, height: 100)
        let nearRight = CGRect(x: 916, y: 250, width: 64, height: 100)

        #expect(
            SidebarFramePlacement.peekOrigin(
                for: nearLeft,
                peekSize: peekSize,
                visibleFrame: visibleFrame,
                gap: 10
            ) == 94
        )
        #expect(
            SidebarFramePlacement.peekOrigin(
                for: nearRight,
                peekSize: peekSize,
                visibleFrame: visibleFrame,
                gap: 10
            ) == 606
        )
    }

    @Test
    func launchAtLoginUsesInjectedServiceState() {
        let suiteName = "SideBarAITests.LaunchAtLogin.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Expected test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = RecordingLaunchAtLoginManager()
        let store = UsageStore(
            adapters: [],
            defaults: defaults,
            refreshInterval: .seconds(60 * 60),
            launchAtLoginManager: manager
        )
        defer { store.shutdown() }

        #expect(store.launchAtLoginSupported)
        #expect(!store.launchAtLoginEnabled)

        store.setLaunchAtLoginEnabled(true)

        #expect(manager.requestedValues == [true])
        #expect(store.launchAtLoginEnabled)
        #expect(store.launchAtLoginMessage == nil)
    }

    private func waitForRefresh(_ store: UsageStore) async {
        for _ in 0..<100 {
            if !store.isRefreshing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor ProviderFetchCounter {
    private var values: [Provider: Int] = [:]

    func increment(_ provider: Provider) {
        values[provider, default: 0] += 1
    }

    func value(for provider: Provider) -> Int {
        values[provider, default: 0]
    }
}

private struct SettingsCountingAdapter: UsageProviderAdapter {
    let provider: Provider
    let counter: ProviderFetchCounter

    func fetch() async -> ProviderState {
        await counter.increment(provider)
        return .unavailable(message: "Fixture unavailable")
    }
}

@MainActor
private final class RecordingLaunchAtLoginManager: LaunchAtLoginManaging {
    let isSupported = true
    var isEnabled = false
    var requiresApproval = false
    private(set) var requestedValues: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        requestedValues.append(enabled)
        isEnabled = enabled
    }
}
