import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    private static let hiddenProvidersDefaultsKey = "SideBarAI.hiddenProviders"
    private static let disabledProvidersDefaultsKey = "SideBarAI.disabledProviders"
    private static let refreshScheduleDefaultsKey = "SideBarAI.refreshSchedule"
    private static let sidebarStartupModeDefaultsKey = "SideBarAI.sidebarStartupMode"
    private static let sidebarEdgeDefaultsKey = "SideBarAI.sidebarEdge"
    private static let liquidGlassEnabledDefaultsKey = "SideBarAI.liquidGlassEnabled"
    private static let rememberedSidebarVisibleDefaultsKey = "SideBarAI.rememberedSidebarVisible"
    private static let rememberedSidebarExpandedDefaultsKey = "SideBarAI.rememberedSidebarExpanded"
    private static let consolidateCodexUsageDefaultsKey = "SideBarAI.consolidateCodexUsage"
    private static let quotaAlertsEnabledDefaultsKey = "SideBarAI.quotaAlertsEnabled"
    static let automaticRefreshInterval: Duration = .seconds(5 * 60)

    private(set) var records: [ProviderRecord]
    private(set) var hiddenProviders: Set<Provider>
    private(set) var disabledProviders: Set<Provider>
    private(set) var refreshSchedule: RefreshSchedule
    private(set) var sidebarStartupMode: SidebarStartupMode
    private(set) var sidebarEdge: SidebarEdge
    private(set) var liquidGlassEnabled: Bool
    private(set) var rememberedSidebarVisible: Bool
    private(set) var rememberedSidebarExpanded: Bool
    private(set) var consolidateCodexUsage: Bool
    private(set) var launchAtLoginSupported: Bool
    private(set) var launchAtLoginEnabled: Bool
    private(set) var launchAtLoginMessage: String?
    private(set) var isRefreshing: Bool
    private(set) var lastRefreshAttempt: Date?
    private(set) var lastRefreshCompleted: Date?
    private(set) var claudeKeychainAccessEnabled: Bool
    private(set) var claudeKeychainAuthorizedForRun: Bool
    private(set) var keychainAuthorizationMessage: String?
    private(set) var quotaAlertsEnabled: Bool
    private(set) var isQuotaAlertAuthorizationPending: Bool
    private(set) var quotaAlertsAuthorizationMessage: String?

    @ObservationIgnored
    private let adapters: [any UsageProviderAdapter]

    @ObservationIgnored
    private let adapterRecordIDs: [String]

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private let quotaAlertDelivery: any QuotaAlertDelivering

    @ObservationIgnored
    private let launchAtLoginManager: any LaunchAtLoginManaging

    @ObservationIgnored
    private var quotaAlertEvaluator: QuotaAlertEvaluator

    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var automaticRefreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var quotaAlertAuthorizationTask: Task<Void, Never>?

    @ObservationIgnored
    private var quotaAlertDeliveryTask: Task<Void, Never>?

    private var refreshGeneration = 0
    private var quotaAlertAuthorizationGeneration = 0
    private var quotaAlertDeliveryGeneration = 0
    private var isShuttingDown = false

    init(
        adapters: [any UsageProviderAdapter] = DefaultUsageAdapters.make(),
        defaults: UserDefaults = .standard,
        refreshInterval: Duration? = nil,
        quotaAlertDelivery: any QuotaAlertDelivering = UnavailableQuotaAlertDelivery(),
        launchAtLoginManager: any LaunchAtLoginManaging = UnavailableLaunchAtLoginManager()
    ) {
        self.adapters = adapters
        self.adapterRecordIDs = Self.uniqueRecordIDs(for: adapters)
        self.defaults = defaults
        self.quotaAlertDelivery = quotaAlertDelivery
        self.launchAtLoginManager = launchAtLoginManager
        self.quotaAlertEvaluator = QuotaAlertEvaluator(defaults: defaults)
        self.hiddenProviders = Self.loadProviders(
            from: defaults,
            key: Self.hiddenProvidersDefaultsKey
        )
        let disabledProviders = Self.loadProviders(
            from: defaults,
            key: Self.disabledProvidersDefaultsKey
        )
        self.disabledProviders = disabledProviders
        self.refreshSchedule = Self.loadRefreshSchedule(from: defaults)
        self.sidebarStartupMode = Self.loadSidebarStartupMode(from: defaults)
        self.sidebarEdge = Self.loadSidebarEdge(from: defaults)
        self.liquidGlassEnabled = Self.loadBool(
            from: defaults,
            key: Self.liquidGlassEnabledDefaultsKey,
            defaultValue: false
        )
        self.rememberedSidebarVisible = Self.loadBool(
            from: defaults,
            key: Self.rememberedSidebarVisibleDefaultsKey,
            defaultValue: true
        )
        self.rememberedSidebarExpanded = Self.loadBool(
            from: defaults,
            key: Self.rememberedSidebarExpandedDefaultsKey,
            defaultValue: false
        )
        self.consolidateCodexUsage = Self.loadBool(
            from: defaults,
            key: Self.consolidateCodexUsageDefaultsKey,
            defaultValue: false
        )
        self.launchAtLoginSupported = launchAtLoginManager.isSupported
        self.launchAtLoginEnabled = launchAtLoginManager.isEnabled
        self.launchAtLoginMessage = nil
        let claudeAdapter = adapters.compactMap { $0 as? ClaudeUsageAdapter }.first
        self.claudeKeychainAccessEnabled = claudeAdapter?.keychainAccessEnabled ?? false
        self.claudeKeychainAuthorizedForRun = claudeAdapter?.keychainAccessAuthorizedForRun ?? false
        let adapterRecordIDs = self.adapterRecordIDs
        self.records = adapters.enumerated().map { index, adapter in
            Self.makeRecord(
                from: adapter,
                recordID: adapterRecordIDs[index],
                enabled: !disabledProviders.contains(adapter.provider)
            )
        }
        self.isRefreshing = false
        self.lastRefreshAttempt = nil
        self.lastRefreshCompleted = nil
        self.keychainAuthorizationMessage = nil
        self.quotaAlertsEnabled = defaults.bool(forKey: Self.quotaAlertsEnabledDefaultsKey)
        self.isQuotaAlertAuthorizationPending = false
        self.quotaAlertsAuthorizationMessage = nil
        refresh()
        if let interval = refreshInterval ?? refreshSchedule.interval {
            startAutomaticRefresh(every: interval)
        }
        if defaults.object(forKey: Self.quotaAlertsEnabledDefaultsKey) == nil {
            quotaAlertAuthorizationTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                await self.setQuotaAlertsEnabled(true)
            }
        }
    }

    func record(for provider: Provider) -> ProviderRecord? {
        let providerRecords = records(for: provider)
        return providerRecords.first(where: \.isActive) ?? providerRecords.first
    }

    func records(for provider: Provider) -> [ProviderRecord] {
        ProviderRecord.presentationOrder(records.filter { $0.provider == provider })
    }

    var orderedRecords: [ProviderRecord] {
        ProviderRecord.presentationOrder(records)
    }

    var visibleRecords: [ProviderRecord] {
        ProviderRecord.presentationOrder(records.filter { !hiddenProviders.contains($0.provider) })
    }

    var presentationRecords: [ProviderRecord] {
        guard consolidateCodexUsage else { return visibleRecords }
        return ProviderRecord.consolidatedCodexPresentation(visibleRecords)
    }

    var compactRecords: [ProviderRecord] {
        ProviderRecord.compactRailOrder(presentationRecords)
    }

    func isProviderVisible(_ provider: Provider) -> Bool {
        !hiddenProviders.contains(provider)
    }

    func setProviderVisible(_ isVisible: Bool, for provider: Provider) {
        if isVisible {
            hiddenProviders.remove(provider)
        } else {
            hiddenProviders.insert(provider)
        }

        defaults.set(
            hiddenProviders.map { $0.rawValue }.sorted(),
            forKey: Self.hiddenProvidersDefaultsKey
        )
    }

    func isProviderEnabled(_ provider: Provider) -> Bool {
        !disabledProviders.contains(provider)
    }

    func setProviderEnabled(_ isEnabled: Bool, for provider: Provider) {
        if isEnabled {
            disabledProviders.remove(provider)
        } else {
            disabledProviders.insert(provider)
        }
        defaults.set(
            disabledProviders.map(\.rawValue).sorted(),
            forKey: Self.disabledProvidersDefaultsKey
        )
        refresh()
    }

    func setRefreshSchedule(_ schedule: RefreshSchedule) {
        guard refreshSchedule != schedule else { return }
        refreshSchedule = schedule
        defaults.set(schedule.rawValue, forKey: Self.refreshScheduleDefaultsKey)
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        if let interval = schedule.interval {
            startAutomaticRefresh(every: interval)
        }
    }

    func setSidebarStartupMode(_ mode: SidebarStartupMode) {
        sidebarStartupMode = mode
        defaults.set(mode.rawValue, forKey: Self.sidebarStartupModeDefaultsKey)
    }

    func setSidebarEdge(_ edge: SidebarEdge) {
        guard sidebarEdge != edge else { return }
        sidebarEdge = edge
        defaults.set(edge.rawValue, forKey: Self.sidebarEdgeDefaultsKey)
    }

    func setLiquidGlassEnabled(_ enabled: Bool) {
        guard liquidGlassEnabled != enabled else { return }
        liquidGlassEnabled = enabled
        defaults.set(enabled, forKey: Self.liquidGlassEnabledDefaultsKey)
    }

    func setConsolidateCodexUsage(_ enabled: Bool) {
        guard consolidateCodexUsage != enabled else { return }
        consolidateCodexUsage = enabled
        defaults.set(enabled, forKey: Self.consolidateCodexUsageDefaultsKey)
    }

    var startupSidebarState: SidebarPresentationState {
        switch sidebarStartupMode {
        case .remember:
            SidebarPresentationState(
                isVisible: rememberedSidebarVisible,
                isExpanded: rememberedSidebarVisible && rememberedSidebarExpanded
            )
        case .hidden:
            SidebarPresentationState(isVisible: false, isExpanded: false)
        case .compact:
            SidebarPresentationState(isVisible: true, isExpanded: false)
        case .expanded:
            SidebarPresentationState(isVisible: true, isExpanded: true)
        }
    }

    func rememberSidebarState(isVisible: Bool, isExpanded: Bool) {
        rememberedSidebarVisible = isVisible
        rememberedSidebarExpanded = isVisible && isExpanded
        defaults.set(isVisible, forKey: Self.rememberedSidebarVisibleDefaultsKey)
        defaults.set(
            rememberedSidebarExpanded,
            forKey: Self.rememberedSidebarExpandedDefaultsKey
        )
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginSupported = launchAtLoginManager.isSupported
        launchAtLoginEnabled = launchAtLoginManager.isEnabled
        if !launchAtLoginSupported {
            launchAtLoginMessage = "Available when SideBarAI is installed as a macOS app."
        } else if launchAtLoginManager.requiresApproval {
            launchAtLoginMessage = "Approval is required in System Settings → Login Items."
        } else {
            launchAtLoginMessage = nil
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard launchAtLoginManager.isSupported else {
            refreshLaunchAtLoginStatus()
            return
        }

        do {
            try launchAtLoginManager.setEnabled(enabled)
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginMessage = "Could not update Login Items: \(error.localizedDescription)"
        }
    }

    func authorizeClaudeKeychain() {
        guard let adapter = adapters.compactMap({ $0 as? ClaudeUsageAdapter }).first else {
            keychainAuthorizationMessage = "Claude Keychain adapter is unavailable."
            return
        }

        if adapter.authorizeKeychainAccess() {
            claudeKeychainAccessEnabled = true
            claudeKeychainAuthorizedForRun = true
            keychainAuthorizationMessage = "Enabled for this run. SideBarAI will reuse this credential without accessing Keychain during refreshes."
            refresh()
        } else {
            claudeKeychainAuthorizedForRun = false
            keychainAuthorizationMessage = "Claude Keychain access was not authorized. Allow access and try again."
        }
    }

    func disableClaudeKeychainAccess() {
        guard let adapter = adapters.compactMap({ $0 as? ClaudeUsageAdapter }).first else {
            keychainAuthorizationMessage = "Claude Keychain adapter is unavailable."
            return
        }

        adapter.disableKeychainAccess()
        claudeKeychainAccessEnabled = false
        claudeKeychainAuthorizedForRun = false
        keychainAuthorizationMessage = "Disabled. SideBarAI will not read the Claude Keychain item."
        refresh()
    }

    func setQuotaAlertsEnabled(_ enabled: Bool) async {
        guard !isShuttingDown else { return }

        if !enabled {
            quotaAlertAuthorizationGeneration &+= 1
            quotaAlertAuthorizationTask?.cancel()
            quotaAlertAuthorizationTask = nil
            quotaAlertDeliveryGeneration &+= 1
            quotaAlertDeliveryTask?.cancel()
            quotaAlertDeliveryTask = nil
            quotaAlertEvaluator.cancelPendingDeliveries()
            isQuotaAlertAuthorizationPending = false
            quotaAlertsEnabled = false
            quotaAlertsAuthorizationMessage = nil
            defaults.set(false, forKey: Self.quotaAlertsEnabledDefaultsKey)
            return
        }

        guard !isQuotaAlertAuthorizationPending else { return }
        quotaAlertAuthorizationGeneration &+= 1
        let authorizationGeneration = quotaAlertAuthorizationGeneration
        isQuotaAlertAuthorizationPending = true
        quotaAlertsAuthorizationMessage = nil
        let granted = await quotaAlertDelivery.requestAuthorization()

        guard !Task.isCancelled,
              !isShuttingDown,
              authorizationGeneration == quotaAlertAuthorizationGeneration else {
            if authorizationGeneration == quotaAlertAuthorizationGeneration {
                isQuotaAlertAuthorizationPending = false
            }
            return
        }

        isQuotaAlertAuthorizationPending = false
        quotaAlertsEnabled = granted
        defaults.set(granted, forKey: Self.quotaAlertsEnabledDefaultsKey)

        if granted {
            quotaAlertsAuthorizationMessage = "Quota alerts enabled."
            deliverQuotaAlertsIfNeeded()
        } else {
            quotaAlertsAuthorizationMessage = "Notifications are not allowed. Enable them in System Settings."
        }
    }

    func refresh() {
        guard !isShuttingDown else { return }
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration

        isRefreshing = true
        lastRefreshAttempt = Date()
        for (index, adapter) in adapters.enumerated() {
            var record = Self.makeRecord(
                from: adapter,
                recordID: adapterRecordIDs[index],
                enabled: isProviderEnabled(adapter.provider)
            )
            if record.isEnabled, records[index].isEnabled,
               case .usage = records[index].state {
                record.state = records[index].state
            }
            records[index] = record
        }

        let enabledAdapters = adapters.enumerated().compactMap { index, adapter -> AdapterEntry? in
            guard isProviderEnabled(adapter.provider) else { return nil }
            return AdapterEntry(
                adapter: adapter,
                recordID: adapterRecordIDs[index]
            )
        }
        guard !enabledAdapters.isEmpty else {
            isRefreshing = false
            lastRefreshCompleted = Date()
            return
        }

        refreshTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: AdapterResult.self) { group in
                for entry in enabledAdapters {
                    group.addTask {
                        AdapterResult(
                            recordID: entry.recordID,
                            state: await entry.adapter.fetch()
                        )
                    }
                }

                for await result in group {
                    guard !Task.isCancelled,
                          let self,
                          !self.isShuttingDown,
                          self.refreshGeneration == generation else {
                        group.cancelAll()
                        return
                    }
                    guard let index = self.records.firstIndex(where: { $0.recordID == result.recordID }) else {
                        continue
                    }
                    self.records[index].state = result.state
                    self.synchronizeClaudeKeychainAuthorization()
                }
            }

            guard !Task.isCancelled,
                  let self,
                  !self.isShuttingDown,
                  self.refreshGeneration == generation else {
                return
            }

            self.isRefreshing = false
            self.lastRefreshCompleted = Date()
            self.deliverQuotaAlertsIfNeeded()
        }
    }

    private func synchronizeClaudeKeychainAuthorization() {
        guard let adapter = adapters.compactMap({ $0 as? ClaudeUsageAdapter }).first else { return }

        let authorizedForRun = adapter.keychainAccessAuthorizedForRun
        guard authorizedForRun != claudeKeychainAuthorizedForRun else { return }

        claudeKeychainAuthorizedForRun = authorizedForRun
        if !authorizedForRun, claudeKeychainAccessEnabled {
            keychainAuthorizationMessage = "Claude Keychain authorization is no longer valid. Choose Use Keychain to authorize this run again."
        }
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        quotaAlertAuthorizationGeneration &+= 1
        quotaAlertAuthorizationTask?.cancel()
        quotaAlertAuthorizationTask = nil
        quotaAlertDeliveryGeneration &+= 1
        quotaAlertDeliveryTask?.cancel()
        quotaAlertDeliveryTask = nil
        quotaAlertEvaluator.cancelPendingDeliveries()
        isQuotaAlertAuthorizationPending = false
        isRefreshing = false
    }

    private func startAutomaticRefresh(every interval: Duration) {
        guard interval > .zero, !isShuttingDown else { return }
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }

                guard let self, !Task.isCancelled, !self.isShuttingDown else {
                    return
                }

                if !self.isRefreshing {
                    self.refresh()
                }
            }
        }
    }

    private static func loadProviders(
        from defaults: UserDefaults,
        key: String
    ) -> Set<Provider> {
        var rawValues = defaults.stringArray(forKey: key) ?? []
        if rawValues.contains("gemini") {
            rawValues = Array(Set(rawValues.map { $0 == "gemini" ? "antigravity" : $0 })).sorted()
            defaults.set(rawValues, forKey: key)
        }
        return Set(rawValues.compactMap { Provider(rawValue: $0) })
    }

    private static func loadRefreshSchedule(from defaults: UserDefaults) -> RefreshSchedule {
        guard let rawValue = defaults.string(forKey: refreshScheduleDefaultsKey),
              let schedule = RefreshSchedule(rawValue: rawValue) else {
            return .fiveMinutes
        }
        return schedule
    }

    private static func loadSidebarStartupMode(
        from defaults: UserDefaults
    ) -> SidebarStartupMode {
        guard let rawValue = defaults.string(forKey: sidebarStartupModeDefaultsKey),
              let mode = SidebarStartupMode(rawValue: rawValue) else {
            return .remember
        }
        return mode
    }

    private static func loadSidebarEdge(from defaults: UserDefaults) -> SidebarEdge {
        guard let rawValue = defaults.string(forKey: sidebarEdgeDefaultsKey),
              let edge = SidebarEdge(rawValue: rawValue) else {
            return .right
        }
        return edge
    }

    private static func loadBool(
        from defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static func uniqueRecordIDs(
        for adapters: [any UsageProviderAdapter]
    ) -> [String] {
        var usedIDs: Set<String> = []
        var nextSuffixByBase: [String: Int] = [:]

        return adapters.map { adapter in
            let base = adapter.recordID.isEmpty ? adapter.provider.rawValue : adapter.recordID
            if usedIDs.insert(base).inserted {
                nextSuffixByBase[base] = 2
                return base
            }

            var suffix = nextSuffixByBase[base, default: 2]
            var candidate = "\(base)#\(suffix)"
            while usedIDs.contains(candidate) {
                suffix += 1
                candidate = "\(base)#\(suffix)"
            }
            nextSuffixByBase[base] = suffix + 1
            usedIDs.insert(candidate)
            return candidate
        }
    }

    private static func makeRecord(
        from adapter: any UsageProviderAdapter,
        recordID: String,
        enabled: Bool
    ) -> ProviderRecord {
        ProviderRecord(
            recordID: recordID,
            provider: adapter.provider,
            accountLabel: adapter.accountLabel,
            planLabel: adapter.planLabel,
            isActive: adapter.isActive,
            isEnabled: enabled,
            hasUsableCredentials: enabled && adapter.hasUsableCredentials,
            state: enabled ? .loading : .unavailable(message: "Disabled in Settings.")
        )
    }

    private func deliverQuotaAlertsIfNeeded() {
        guard quotaAlertsEnabled, !isShuttingDown else { return }
        let alerts = quotaAlertEvaluator.alerts(for: records)
        guard !alerts.isEmpty else { return }
        let delivery = quotaAlertDelivery
        let generation = quotaAlertDeliveryGeneration

        quotaAlertDeliveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for alert in alerts {
                guard !Task.isCancelled,
                      !self.isShuttingDown,
                      self.quotaAlertsEnabled,
                      self.quotaAlertDeliveryGeneration == generation else {
                    return
                }

                let delivered = await delivery.deliver(alert)
                guard !Task.isCancelled,
                      !self.isShuttingDown,
                      self.quotaAlertsEnabled,
                      self.quotaAlertDeliveryGeneration == generation else {
                    return
                }

                if delivered {
                    self.quotaAlertEvaluator.recordDeliverySuccess(alert)
                } else {
                    self.quotaAlertEvaluator.recordDeliveryFailure(alert)
                }
            }
        }
    }

    private struct AdapterEntry: Sendable {
        let adapter: any UsageProviderAdapter
        let recordID: String
    }

    private struct AdapterResult: Sendable {
        let recordID: String
        let state: ProviderState
    }
}
