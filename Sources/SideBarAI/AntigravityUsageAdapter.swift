import Foundation
import CoreFoundation

struct AntigravityUsageAdapter: UsageProviderAdapter {
    let provider: Provider = .antigravity
    private let versionRunner: any UsageCommandRunning
    private let usageRunner: any UsageCommandRunning

    init(
        versionRunner: (any UsageCommandRunning)? = nil,
        usageRunner: (any UsageCommandRunning)? = nil
    ) {
        let executable = ProcessUsageCommandRunner.resolveExecutable(named: "agy")
        self.versionRunner = versionRunner ?? ProcessUsageCommandRunner(
            executableName: "agy", arguments: ["--version"],
            executableURL: executable, timeout: 5, isolatedWorkingDirectory: true,
            preventsApplicationLaunches: true
        )
        self.usageRunner = usageRunner ?? ProcessUsageCommandRunner(
            executableName: "agy",
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "60s"],
            executableURL: executable, timeout: 65, isolatedWorkingDirectory: true,
            preventsApplicationLaunches: true
        )
    }

    func fetch() async -> ProviderState {
        do {
            let version = try await versionRunner.run()
            // Older versions can interpret /usage as a model prompt. Fail closed.
            guard Self.supportsUsageReport(version) else {
                return .unavailable(message: "Update Antigravity CLI to agy 1.1.11 or newer, then refresh.")
            }
            let windows = try Self.parseUsageReport(await usageRunner.run())
            return .usage(UsageSnapshot(
                windows: windows, updatedAt: Date(), accountLabel: nil, planLabel: nil,
                sourceLabel: "Antigravity CLI (agy)"
            ))
        } catch is CancellationError {
            return .loading
        } catch UsageCommandError.executableNotFound {
            return .unavailable(message: "Install Antigravity CLI, run 'agy' to sign in, then refresh.")
        } catch UsageCommandError.timedOut {
            return .unavailable(message: "Antigravity quota check timed out. Sign in manually with 'agy', then refresh. Background checks cannot open sign-in windows.")
        } catch {
            // CLI diagnostics may contain account details; never surface raw output.
            return .unavailable(message: "Antigravity quotas unavailable. Sign in manually with 'agy' and check /usage, then refresh. Background checks cannot open sign-in windows.")
        }
    }

    private static func supportsUsageReport(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return false }
        return major > 1 || (major == 1 && (minor > 1 || (minor == 1 && patch >= 11)))
    }

    private static func parseUsageReport(_ data: Data) throws -> [UsageWindow] {
        guard let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              report["status"] as? String == "SUCCESS",
              let turns = number(report["num_turns"]), turns == 0,
              let command = report["command"] as? [String: Any],
              command["name"] as? String == "usage",
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]] else {
            throw UsageCommandError.invalidOutput
        }

        var windows: [UsageWindow] = []
        var seenIDs: Set<String> = []
        for group in groups {
            guard let name = nonEmpty(group["name"]),
                  let buckets = group["buckets"] as? [Any] else { continue }
            for value in buckets {
                guard let bucket = value as? [String: Any],
                      bucket["disabled"] == nil || bucket["disabled"] as? Bool == false,
                      let id = nonEmpty(bucket["id"]),
                      let remaining = number(bucket["remaining_fraction"]),
                      (0...1).contains(remaining) else { continue }
                let period: Double
                let label: String
                switch bucket["window"] as? String {
                case "5h":
                    period = 5 * 60 * 60
                    label = "5-hour"
                case "weekly":
                    period = 7 * 24 * 60 * 60
                    label = "7-day"
                default:
                    continue
                }
                // Ambiguous duplicate buckets must not silently overwrite one another.
                guard seenIDs.insert(id).inserted else { throw UsageCommandError.invalidOutput }
                windows.append(UsageWindow(
                    id: id, label: "\(name) · \(label)", used: (1 - remaining) * 100,
                    limit: 100, unit: .percent,
                    resetDate: UsageDateParser.iso8601(bucket["reset_time"] as? String),
                    providerReportedPercentage: true, periodSeconds: period
                ))
            }
        }
        guard !windows.isEmpty else { throw UsageCommandError.invalidOutput }
        return windows.sorted { $0.id < $1.id }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
