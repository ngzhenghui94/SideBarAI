# SideBarAI

SideBarAI is a native macOS menu-bar utility with an edge-attached, expandable sidebar for monitoring AI provider usage and quotas. It is built with Swift 6 and Swift Package Manager and requires macOS 14 or newer.

## Features

- Usage windows, percentages, reset times, and account or plan labels, plus Codex subscription renewal dates read from the ChatGPT login token (hidden once passed, since the token only refreshes at login).
- Local OMP model token totals (including cached input) for the last 30 days, with Codex and Claude cost estimates calculated from published OpenAI and Anthropic rates—not saved dollar amounts or subscription bills.
- Manual refresh or scheduled refresh every 1, 5, 15, or 30 minutes, or hourly.
- Menu-bar controls for showing or hiding the sidebar, compact or expanded views, and attachment to the left, right, top, or bottom screen edge.
- Provider enable/disable and visibility controls.
- Optional consolidation of multiple discovered Codex accounts into one weighted quota.
- Configurable startup state, optional Liquid Glass styling, launch at login, and quota alerts.

## Supported providers

Sign in to the provider CLIs first. SideBarAI reads authenticated usage from the local CLI sessions you already use.

| Provider | Authentication and requirements |
| --- | --- |
| Claude Code | Claude Code OAuth. Run `claude` and complete sign-in. |
| ChatGPT / Codex | Codex CLI OAuth. Sign in with `codex login`. Multiple discovered Codex accounts are supported. |
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

## First launch

1. Sign in to the provider CLIs you want to monitor.
2. Open SideBarAI and open Settings from the menu bar.
3. Enable the providers, choose refresh and sidebar options, and optionally authorize Claude Keychain access.
4. Show the sidebar from the menu bar and refresh usage.

## Development

Run tests and a release build from the repository root:

```sh
swift test
swift build -c release
```

The test suite is in `Tests/SideBarAITests`.

To create an app bundle without installing it:

```sh
bash scripts/package-app.sh release
```

The packaging script accepts `bash scripts/package-app.sh [debug|release] [destination]`.

## Privacy and credentials

SideBarAI is a local usage monitor. Credentials remain managed by each provider CLI. Claude may optionally use macOS Keychain access after you authorize it in Settings.

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
