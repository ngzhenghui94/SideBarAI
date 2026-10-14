# SideBarAI

SideBarAI is a native macOS menu-bar utility with an edge-attached, expandable sidebar for monitoring AI provider usage and quotas. It is built with Swift 6 and Swift Package Manager and requires macOS 14 or newer.

## Features

- Usage windows, percentages, reset times, and account or plan labels.
- Local OMP model token totals (including cached input) for the last 30 days, with Codex and Claude cost estimates calculated from published OpenAI and Anthropic rates—not saved dollar amounts or subscription bills.
- Manual refresh or scheduled refresh every 1, 5, 15, or 30 minutes, or hourly.
- Menu-bar controls for showing or hiding the sidebar, compact or expanded views, and attachment to the left, right, top, or bottom screen edge.
- Provider enable/disable and visibility controls.
- Optional consolidation of multiple discovered Codex accounts into one weighted quota.
- Codex accounts discovered from your existing OMP logins on each refresh; no separate login manager or credential copies.
- Configurable startup state, optional Liquid Glass styling, launch at login, and quota alerts.

## Supported providers

Sign in to the provider CLIs first. SideBarAI reads authenticated usage from the local CLI sessions you already use.

| Provider | Authentication and requirements |
| --- | --- |
| Claude Code | Claude Code OAuth. Run `claude` and complete sign-in. Extra logins made with `CLAUDE_CONFIG_DIR=~/.claude-<name> claude` appear as separate cards after relaunch. |
| ChatGPT / Codex | Existing OMP logins. Open `omp`, use `/login` for Codex, then refresh SideBarAI. |
| Antigravity CLI | Run `agy` and complete sign-in. Usage reporting requires `agy` 1.1.11 or newer. |

## Install from source

### Requirements

- macOS 14 or newer.
- Swift 6 and Swift Package Manager.
- Signed-in provider CLIs for the providers you want to monitor.
- `rtk` on your `PATH`. The checked-in build scripts use it to run and condense SwiftPM output.

### Build and install

From a terminal:

```sh
git clone https://github.com/ngzhenghui94/SideBarAI.git
cd SideBarAI
bash scripts/build-install.sh
```

This builds a release, creates `SideBarAI.app`, and installs it to `/Applications`. The destination directory must already exist and be writable.

To install without administrator access:

```sh
mkdir -p "$HOME/Applications"
bash scripts/build-install.sh --install-dir "$HOME/Applications"
```

Useful options:

```sh
bash scripts/build-install.sh --configuration debug --install-dir "$HOME/Applications"
bash scripts/build-install.sh --dry-run
```

Launch the installed app with:

```sh
open /Applications/SideBarAI.app
# or
open "$HOME/Applications/SideBarAI.app"
```

## Codex accounts through OMP

Sign in once in OMP. SideBarAI discovers accounts and usage through `omp usage --json`; it does not read or modify Codex credential files. There is no separate `sidebarai` login CLI.

1. Open `omp` and use `/login` to add your Codex accounts.
2. Refresh SideBarAI, or wait for its scheduled refresh.

OMP owns authentication and account selection. Account changes appear on refresh without restarting SideBarAI. Failed discovery keeps known accounts with an explicit unavailable state rather than treating the failure as logout. Accounts without quota data remain visible as unavailable.

OMP must be installed and discoverable by the app. The app uses its existing executable search paths, including common user-local and Homebrew locations. OMP does not report which login is active, so SideBarAI does not guess or mark an account active. Subscription renewal dates are no longer read from Codex tokens.

The former custom CLI has been removed. Previously saved files under `~/.codex/accounts` are left untouched but are no longer used by SideBarAI. Accounts saved only there must also be signed in through OMP to appear.

## First launch

1. Sign in to the provider CLIs you want to monitor.
2. Open SideBarAI and open Settings from the menu bar.
3. Enable the providers, choose refresh and sidebar options, and optionally authorize Claude Keychain access.
4. Show the sidebar from the menu bar and refresh usage.

## Development

Run tests and a release build from the repository root:

```sh
DYLD_FRAMEWORK_PATH="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64" swift test
swift build -c release
```

The test suite is in `Tests/SideBarAITests`; OMP account tests use synthetic reports rather than real credentials.

To create an app bundle without installing it:

```sh
bash scripts/package-app.sh release
```

Release packaging is the normal build: it builds SwiftPM, verifies the manual-only updater policy, assigns the next numeric version/build, Developer ID signs nested code and the app with team `F57QJC4XU3` while preserving entitlements and bundle ID `com.icelemontees.SideBarAI`, submits using the existing Keychain profile `notary`, staples and validates the ticket, assesses Gatekeeper, and publishes a new release to the existing `ngzhenghui94/SideBarAI` destination. It verifies uploaded and public download checksums before pushing the signed feed and cask to `ngzhenghui94/homebrew-tap` main from the project-private `dist/update-tap` clone, fetching/rebasing its own commit before a normal push. Existing releases are never overwritten. `--dry-run` on build-install suppresses installation only; release publication still occurs.

The ready app is `dist/SideBarAI.app`; immutable app/ZIP/signed appcast/notarization records are retained under `dist/releases/<version>/`. Never delete a failed release directory or draft blindly: inspect its recorded Apple submission and GitHub draft before retrying. Build locks prevent concurrent runs. The publisher requires existing Developer ID and app-specific Sparkle signing keys in Keychain, `gh` publication access, and the notary profile. It does not export secrets or grant permissions. Authored source is not included in the app ZIP or public tap. `debug` packaging is explicitly local/ad-hoc and does not publish.

Update-key access goes through `scripts/signing.swift`: it disables Keychain interaction before reading the existing key, checks it against the bundle's pinned public key, and passes it only through an anonymous stdin pipe to Sparkle. Missing, locked, approval-required, or mismatched keys fail closed; there is no retry, key generation, rotation, key file, or permission change. Signature verification uses public-only CryptoKit without Keychain access. This helper does not make Developer ID signing or the notarization profile noninteractive; do not resume those stages while their separate no-prompt prerequisite is unresolved.

### In-app updates

Choose **Check for Updates…** from the menu bar. Sparkle 2.10.0 requires both a signed appcast and Ed25519-signed archives, validates the signed app identity, and asks before installing/relaunching. Update checks, automatic downloads/installation, permission prompts, and system profiling are disabled, including persisted Sparkle preferences. The HTTPS feed is `https://raw.githubusercontent.com/ngzhenghui94/homebrew-tap/main/appcasts/sidebarai.xml`. Update signatures use the existing app-specific Keychain account `com.icelemontees.SideBarAI`; only its public verification key is in the bundle. Old versions without Sparkle need this notarized version installed once. Settings/usage login state remain owned by their existing stores; normal termination saves sidebar state and shuts down usage work.

Run the small release policy checks with `python3 scripts/release.py --selftest` and the packaged executable with `--update-selftest`; these checks do not install an update. GUI install/relaunch and provider behavior are checked separately.

## Privacy and credentials

SideBarAI monitors usage without managing credentials. Codex account discovery and usage are delegated to OMP; SideBarAI does not copy its tokens. Claude may optionally use macOS Keychain access after you authorize it in Settings. Background reads disable both LocalAuthentication interaction and legacy login-Keychain dialogs. If access needs approval, usage remains unavailable until you choose **Use Keychain**; refreshes do not request your password. Already-authorized credentials can still be picked up silently after Claude Code rotates them. The legacy interaction guard uses deprecated Security APIs because Claude Code stores its item in the login Keychain, not the Data Protection keychain.

If **Use Keychain** fails, Settings distinguishes a macOS Security error (with its numeric code) from a successful Keychain read containing an expired or invalid Claude login. For the latter, sign in again using `claude`, then retry **Use Keychain**. No credential contents are shown.

SideBarAI does not create, refresh, or display fake usage values. Provider and network availability can affect the usage shown in the sidebar.

### Model cost estimates

The bundled rate table in `CodexModelPricing.swift` was checked against [OpenAI’s Codex rate card](https://help.openai.com/en/articles/20001415-chatgpt-rate-card-enterprise-token-based-pricing) on **2026-09-25**. The app shows that date and source. The USD figures are Enterprise Codex rate-card estimates, not ChatGPT subscription charges; they are current-rate equivalents of recorded local usage, not historical charges, and the app does not download new prices automatically. OpenAI publishes GPT-5.6 Sol promotional rates through at least November 21, 2026.

Each account-linked `openai-codex` request is priced from separate input, output, and cached-input counts. Codex cache writes are not charged. The calculation applies recorded Fast-mode changes, the published model-specific multipliers, and long-context pricing above 272,000 prompt tokens where applicable; GPT-6 Astra uses the Codex long-context exception. Missing speed settings assume Standard. Regional surcharges, tool fees, subscription allowances, and contract discounts are not included.

Only exact supported model IDs are priced. Spark, unsupported tiers/models, or incomplete/inconsistent token breakdowns remain unpriced—even if OMP saved a nonzero dollar amount. A **priced subtotal** excludes unpriced models; it is never presented as a complete total. Missing account pins remain excluded rather than assigned to a guessed owner.

Claude estimates use the rate table in `ClaudeModelPricing.swift`, checked against [Anthropic’s API pricing](https://platform.claude.com/docs/en/about-claude/pricing) on **2026-09-25**. Each account-linked `anthropic` request is priced from separate input, output, cache-write, and cache-read counts (Opus 5.5 cache reads are 0.05× input). Cache writes assume the 5-minute TTL because OMP does not record the TTL. Fast mode, Batch, US-only inference, and tool fees are not included. These are API-equivalent figures; Claude Pro/Max subscriptions are not billed per token. Claude Code OAuth does not reveal an account identity, so OMP history is attached to the Claude card only when OMP has exactly one Anthropic account.

## Troubleshooting

- **Missing or stale usage:** Confirm the provider CLI is signed in, the provider is enabled and visible, then try a manual refresh.
- **No Antigravity usage:** Confirm `agy` is version 1.1.11 or newer and that sign-in is complete.
- **Missing model usage or cost:** Model summaries cover account-linked local OMP history only. Excluded unassigned records are disclosed separately. Unsupported models (including Spark) and unusable token/speed data show cost unavailable; supported complete records are recalculated even when their saved cost was zero or missing.
- **Installation fails:** Check that the destination directory exists and is writable, and that `rtk` is available on your `PATH`.
