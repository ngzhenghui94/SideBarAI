import SwiftUI

@MainActor
struct SettingsView: View {
    private let store: UsageStore
    private let onClose: () -> Void

    init(store: UsageStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SideBarAI")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("General and provider settings")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    store.refresh()
                } label: {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
                .help("Refresh provider usage")
                .accessibilityLabel(store.isRefreshing ? "Checking provider usage" : "Refresh provider usage")
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("SideBarAI reads authenticated usage from the local CLI sessions you already use. It never creates, refreshes, or displays fake usage values.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    applicationControlsRow
                    quotaAlertsRow

                    Text("Power controls stop provider polling. Eye controls choose what appears in the dashboard.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVStack(spacing: 10) {
                        ForEach(store.orderedRecords) { record in
                            providerRow(record)
                        }

                        claudeKeychainAuthorizationRow
                    }
                }
                .padding(.top, 15)
            }

            Divider()
                .padding(.top, 18)
                .padding(.bottom, 12)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Credentials remain managed by each provider CLI.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                    refreshStatus
                }
                Spacer()
                Button("Done") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 460, minHeight: 560)
        .onAppear {
            store.refreshLaunchAtLoginStatus()
        }
    }

    private var liquidGlassDescription: String {
        if #available(macOS 26.0, *) {
            "Use macOS Liquid Glass surfaces throughout the sidebar."
        } else {
            "Use the closest translucent material available on this macOS version."
        }
    }

    private var applicationControlsRow: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Refresh usage")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text("Manual refresh remains available from the menu bar.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 10)

                Picker(
                    "Refresh usage",
                    selection: Binding(
                        get: { store.refreshSchedule },
                        set: { store.setRefreshSchedule($0) }
                    )
                ) {
                    ForEach(RefreshSchedule.allCases) { schedule in
                        Text(schedule.displayName).tag(schedule)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Consolidate Codex usage")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text("Combine all Codex accounts into one quota using sum of reported usage divided by sum of reported capacity. Accounts missing a window are excluded from that window's calculation.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Toggle(
                    "Consolidate Codex usage",
                    isOn: Binding(
                        get: { store.consolidateCodexUsage },
                        set: { store.setConsolidateCodexUsage($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Consolidate Codex usage")
                .help("Show all Codex accounts as one weighted usage quota")
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sidebar edge")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text("Choose where the sidebar attaches. Drag the handle toward any edge to reattach after detaching.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Picker(
                    "Sidebar edge",
                    selection: Binding(
                        get: { store.sidebarEdge },
                        set: { store.setSidebarEdge($0) }
                    )
                ) {
                    ForEach(SidebarEdge.allCases) { edge in
                        Text(edge.displayName).tag(edge)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Liquid Glass")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(liquidGlassDescription)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Toggle(
                    "Liquid Glass theme",
                    isOn: Binding(
                        get: { store.liquidGlassEnabled },
                        set: { store.setLiquidGlassEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Liquid Glass theme")
                .help("Use Liquid Glass surfaces throughout the sidebar")
            }

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Startup sidebar")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text("Choose the panel state used after launch.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 10)

                Picker(
                    "Startup sidebar",
                    selection: Binding(
                        get: { store.sidebarStartupMode },
                        set: { store.setSidebarStartupMode($0) }
                    )
                ) {
                    ForEach(SidebarStartupMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Launch at login")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(store.launchAtLoginMessage ?? "Start SideBarAI when you sign in.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(
                            store.launchAtLoginSupported ? Color.secondary : Color.orange
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { store.launchAtLoginEnabled },
                        set: { store.setLaunchAtLoginEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!store.launchAtLoginSupported)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
    }

    private var quotaAlertsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quota threshold alerts")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Notify when any usage window reaches 75%, 90%, or 100%.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.isQuotaAlertAuthorizationPending {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Requesting notification access…")
                    }
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                } else if let message = store.quotaAlertsAuthorizationMessage {
                    Text(message)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(store.quotaAlertsEnabled ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            Toggle(
                "Quota threshold alerts",
                isOn: Binding(
                    get: { store.quotaAlertsEnabled },
                    set: { enabled in
                        Task { @MainActor in
                            await store.setQuotaAlertsEnabled(enabled)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(store.isQuotaAlertAuthorizationPending)
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var refreshStatus: some View {
        if store.isRefreshing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking providers…")
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)
        } else if let date = store.lastRefreshCompleted ?? store.lastRefreshAttempt {
            Text("Last checked \(date, style: .relative)")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
        } else {
            Text("Last checked —")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func providerRow(_ record: ProviderRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(record.provider.accentColor.opacity(0.16))
                ProviderIcon(
                    provider: record.provider,
                    size: 17,
                    tint: record.provider.accentColor
                )
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(record.provider.displayName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))

                    if record.isActive && store.isProviderEnabled(record.provider) {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.4)
                            .foregroundStyle(.green)
                    }

                    Spacer()
                    Text(
                        store.isProviderEnabled(record.provider)
                            ? statusTitle(record.state)
                            : "DISABLED"
                    )
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        store.isProviderEnabled(record.provider)
                            ? statusColor(record.state)
                            : Color.secondary
                    )

                    Button {
                        store.setProviderEnabled(
                            !store.isProviderEnabled(record.provider),
                            for: record.provider
                        )
                    } label: {
                        Image(
                            systemName: store.isProviderEnabled(record.provider)
                                ? "power.circle.fill"
                                : "power.circle"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            store.isProviderEnabled(record.provider) ? Color.green : Color.secondary
                        )
                        .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help(
                        store.isProviderEnabled(record.provider)
                            ? "Disable \(record.provider.displayName) polling"
                            : "Enable \(record.provider.displayName) polling"
                    )
                    .accessibilityLabel(
                        store.isProviderEnabled(record.provider)
                            ? "Disable \(record.provider.displayName) polling"
                            : "Enable \(record.provider.displayName) polling"
                    )

                    Button {
                        store.setProviderVisible(
                            !store.isProviderVisible(record.provider),
                            for: record.provider
                        )
                    } label: {
                        Image(systemName: store.isProviderVisible(record.provider) ? "eye" : "eye.slash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help(
                        store.isProviderVisible(record.provider)
                            ? "Hide \(record.provider.displayName) from the dashboard"
                            : "Show \(record.provider.displayName) in the dashboard"
                    )
                    .accessibilityLabel(
                        store.isProviderVisible(record.provider)
                            ? "Hide \(record.provider.displayName) from dashboard"
                            : "Show \(record.provider.displayName) in dashboard"
                    )
                }

                if let accountLabel = record.displayAccountLabel {
                    Text(accountLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let planLabel = record.planStatusLabel {
                    Text("Plan: \(planLabel)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(record.provider.accentColor)
                }

                Text(record.provider.sourceDescription)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(credentialLocation(for: record.provider))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)

                stateDetail(record.state)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
        .accessibilityElement(children: .combine)
    }

    private var claudeKeychainAuthorizationRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Provider.claude.accentColor.opacity(0.16))
                ProviderIcon(
                    provider: .claude,
                    size: 17,
                    tint: Provider.claude.accentColor
                )
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Keychain")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))

                Text(claudeKeychainStatusMessage)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Group {
                if store.claudeKeychainAuthorizedForRun {
                    Button("Stop Using") {
                        store.disableClaudeKeychainAccess()
                    }
                    .accessibilityLabel("Stop using Claude Keychain access")
                } else {
                    Button("Use Keychain") {
                        store.authorizeClaudeKeychain()
                    }
                    .accessibilityLabel("Authorize Claude Keychain access")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
        .accessibilityElement(children: .contain)
    }

    private var claudeKeychainStatusMessage: String {
        if let message = store.keychainAuthorizationMessage {
            return message
        }
        if store.claudeKeychainAuthorizedForRun {
            return "Enabled for this run. Automatic refreshes reuse the credential and never access Keychain interactively."
        }
        if store.claudeKeychainAccessEnabled {
            return "Previously enabled. Choose Use Keychain to authorize this run; automatic refreshes never access Keychain."
        }
        return "Off. SideBarAI will not access the Claude Keychain item unless you choose Use Keychain."
    }

    @ViewBuilder
    private func stateDetail(_ state: ProviderState) -> some View {
        switch state {
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Reading current usage…")
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)
        case let .authenticated(accountLabel):
            Text(accountLabel ?? "Credentials found; usage has not been returned yet.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
        case let .unavailable(message):
            Text(message)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case let .usage(snapshot):
            VStack(alignment: .leading, spacing: 3) {
                Text(updatedLabel(snapshot.updatedAt))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                if snapshot.hasModelUsage,
                   let detail = snapshot.modelUsageDetail {
                    Text(detail)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(detail)
                        .accessibilityLabel(detail)
                }
            }
        }
    }

    private func statusTitle(_ state: ProviderState) -> String {
        switch state {
        case .loading:
            "CHECKING"
        case .authenticated:
            "CONNECTED"
        case .unavailable:
            "UNAVAILABLE"
        case .usage:
            "USAGE READY"
        }
    }

    private func statusColor(_ state: ProviderState) -> Color {
        switch state {
        case .loading:
            .orange
        case .authenticated, .usage:
            .green
        case .unavailable:
            .secondary
        }
    }

    private func credentialLocation(for provider: Provider) -> String {
        switch provider {
        case .claude:
            "~/.claude/.credentials.json or macOS Keychain"
        case .chatgpt:
            "~/.codex/accounts/registry.json and account credential files"
        case .antigravity:
            "Antigravity CLI (agy) manages credentials in macOS Keychain"
        }
    }

    private func updatedLabel(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "Updated just now" }
        let minutes = Int(seconds / 60)
        return minutes == 1 ? "Updated 1 minute ago" : "Updated \(minutes) minutes ago"
    }
}
