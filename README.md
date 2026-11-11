# LLM Usage Bar (Codex + Claude + OpenCode Go + Pi)

Small macOS menu bar app to track:

- **Codex** usage (session + weekly + credits + saved rate-limit resets)
- **Claude** multi-subscription usage (five-hour/weekly/model-specific allowances, reset times, and local Claude Code token totals)
- **OpenCode Go** usage (5h/weekly/monthly + model usage history for GLM-5, Kimi K2.5, MiniMax M2.5)
- **Pi** local session usage (today / last 7d / last 30d / last 90d, a selectable 90d/6m/1y/All token chart, and model/provider/project summaries)

## Build & Run

Development:

```bash
cd ~/Development/iainkirkpatrick/llm-usage
swift run LLMUsageBar
```

The Codex core is the bundled Node CLI. Rebuild it after changing Node sources:

```bash
npm ci
npm run build # refreshes the ignored dist-node/llm-usage.mjs bundle used by the app
```

Installed app (via dotfiles, using GitHub Releases):

```bash
cd ~/Development/iainkirkpatrick/dotfiles
./install-assistant-apps.sh
open "$HOME/Applications/LLM Usage.app"
```

The dotfiles installer builds from local source when `~/Development/iainkirkpatrick/llm-usage` exists and Swift is available; otherwise it downloads the latest public GitHub release.

## Command line

The installed launcher opens the menu bar app when run without arguments:

```bash
llm-usage-bar
```

Codex usage for agents and scripts is provided by the bundled Node CLI. The macOS app bridge and the installed launcher both run `llm-usage.mjs`:

```bash
./scripts/package-macos-app.sh
./dist/LLM\ Usage.app/Contents/MacOS/llm-usage codex --json
./dist/LLM\ Usage.app/Contents/MacOS/llm-usage claude --json
```

`claude --json` reports the caller's default login or exact `CLAUDE_CONFIG_DIR`; it never substitutes a tracked app account. It follows **Settings → Claude accounts → Usage source**. With **Claude Code**, the packaged helper asks the owner CLI for structured usage (`initialize` then `get_usage`, no model/user messages), checking reported email/organization before and after. This path does not read credentials from Keychain and preserves `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, including when inherited from Pi. OAuth API remains available explicitly and retains its existing credential/UUID checks.

The JSON keeps `claude.session`, `claude.weekly`, `remainingPercent`, `resetAt`, and `source`. For Claude Code, `updatedAt` is a compatibility alias of `capturedAt`; `freshnessVerified` and `identityVerifiedForTrackedAccount` are false. Capture time is not the original measurement time. The structured control API is experimental; incompatible responses fail closed rather than triggering login or falling back to another account/source. A private 60-second cache/backoff and cross-process lock coalesce requests, with reported identity rechecked even on cache hits. The total request budget is 25 seconds plus at most one second for process cleanup, below Pi's default 30-second timeout. This command requires the packaged macOS helper. Rebuild with `./scripts/package-macos-app.sh`, then run the dotfiles installer shown above (or use the launcher in `dist/LLM Usage.app` directly). The Linux installer remains Codex-only.

On Linux, install the Node bundle and launcher (no Swift runtime is required):

```bash
./scripts/install-linux-cli.sh
$HOME/bin/llm-usage codex --json
```

Requirements are Node 20 or newer and a compatible local Codex executable providing `app-server`. The standalone CLI keeps its existing Pi-managed Codex compatibility path; the macOS app normally uses accounts added under Managed Codex accounts, with an explicit Pi handoff available for the selected account. Override the destination with `LLM_USAGE_INSTALL_DIR`.

The Node CLI can verify local Codex prerequisites without starting an app-server or printing credentials:

```bash
llm-usage diagnose
```

`diagnose` reports the executable, whether a Pi OAuth credential is actually present, and the number of managed profiles. It works for managed-only installations; `Pi auth: unavailable` is expected when Pi is not installed. With no managed accounts, `llm-usage codex --json` keeps the existing Pi-managed `openai-codex` behavior. When the app has managed profiles, `llm-usage codex --all-managed --json` returns a backward-compatible selected `codex` object plus a `codexAccounts` array with per-account usage or errors. An explicit isolated home can be queried with:

```bash
llm-usage codex --codex-home "$HOME/.llm-usage-bar/codex-accounts/<profile-id>" --json
```

Reset consumption is account-bound and requires the expected ChatGPT account identity in the same app-server operation:

```bash
llm-usage codex reset consume --credit-id ID --idempotency-key KEY \
  --expected-account-id CHATGPT_ACCOUNT_ID --codex-home PATH --json
```

The command refuses an unbound reset request. The macOS app supplies the identity recorded for the selected managed profile; an active Pi handoff uses Pi's locked auth path and validates the identity again immediately before consumption. If the installed app-server does not return an account identity, reset consumption is disabled rather than guessed.

## Config

On first run, it creates:

`~/.llm-usage-bar/config.json`

Example:

```json
{
  "autoRedeemExpiringCodexResets" : false,
  "codexEnabled" : true,
  "claudeEnabled" : true,
  "defaultClaudeCode" : true,
  "claudeAutoRefreshEnabled" : true,
  "claudeAccounts" : [],
  "codexManagedAccounts" : [],
  "codexPrimaryAccountID" : null,
  "codexPiHandoffAccountID" : null,
  "openCodeCookieHeader" : null,
  "openCodeEnabled" : true,
  "openCodeWorkspaceID" : null,
  "piDeduplicateForkHistory" : true,
  "piEnabled" : true,
  "piSessionsDirectory" : null,
  "refreshIntervalSeconds" : 300
}
```

### Codex setup

Codex rate limits and saved reset credits are fetched from the Codex app-server. When credits are available, each account section lists its expiry and offers an explicit, Cancel-by-default confirmation before spending one. The Settings menu can opt in to automatically redeem the specific earliest-expiring saved reset during its final hour, but auto-redemption is scoped to the explicitly selected menu-bar account and fails closed if that account is not current. It sends local notifications at 24 hours, 6 hours, and after the redemption attempt.

Ownership and credential identity are rechecked before a reset attempt is recorded or dispatched. If a dispatched request has an uncertain result, **Retry pending saved reset…** reuses its original account, credit, and idempotency key—even if that credit is now redeemed, expired, or absent from the list. Other reset requests remain blocked until this retry confirms the outcome; a refresh alone never discards an uncertain attempt.

With no managed accounts, the app displays a prompt to add one and does not fetch Codex usage.

### Managed Codex accounts

Use **Settings → Managed Codex accounts → Add Codex account…** to add more than one Codex OAuth account. LLM Usage Bar creates an app-owned home for each profile under:

`~/.llm-usage-bar/codex-accounts/<profile-id>/`

The profile label and identity metadata are stored in `config.json`; credentials stay in that profile's `auth.json`. Homes are restricted to the owning user and `auth.json` is restricted to mode `0600`. Login runs the installed `codex login` in a temporary staging `CODEX_HOME`; only a validated ChatGPT OAuth `auth.json` is atomically installed after a successful login. Cancellation, validation failure, and CLI failure leave the previous live credentials untouched. If the CLI prints an OpenAI HTTPS OAuth URL instead of opening a browser, the app safely opens that URL without displaying bearer/JWT tokens. Usage then launches `codex app-server` with the same managed `CODEX_HOME`, calls native `account/read` and `account/rateLimits/read`, and keeps session/weekly limits independent for every account. Removing an account uses a recoverable home quarantine and commits metadata only when credential cleanup can be completed; failures are reported rather than hidden.

The menu shows only managed accounts as labelled Codex sections. The first managed account becomes primary; selecting an unavailable account fails closed rather than switching to another account. Managed accounts normally use their isolated native homes and never use the user's default Codex credentials.

### Use a managed Codex account in Pi

Settings → Managed Codex accounts → **Use this account in Pi…** performs an explicit credential handoff. The selected account is written as Pi's `openai-codex` OAuth entry in `~/.pi/agent/auth.json`; its managed `auth.json` is removed while active, so there is only one independently-refreshing live credential. Other managed accounts remain in their isolated native homes. The active account's usage and reset actions fetch through Pi auth, not its managed home.

Before switching, exit running Pi sessions. Resume or restart them after the confirmation so they reload the selected account. When switching to another managed account, LLM Usage Bar first saves the latest Pi access/refresh tokens back to the matching inactive managed home, then atomically activates the target. An existing Pi `openai-codex` credential for a different ChatGPT account is rejected rather than overwritten; unrelated provider entries are preserved. **Stop using this account in Pi…** moves the latest tokens back and removes the Pi entry.

Handoff state and account identity metadata are recorded in `config.json`; credential files are restricted to the owning user (`0700` directories, `0600` files), protected by Pi's mkdir-lock protocol with an inode-checked heartbeat, validated for account identity, and written atomically. ConfigStore saves—including handoff commits—share a kernel-owned `config.json.lock` across the complete comparison and replacement; lock paths are never deleted as stale. An existing Pi lock is treated as busy, and any inode replacement aborts the transaction rather than being silently ignored. Exact credential and Pi snapshots are journaled for recovery; a changed Pi/config document, missing or corrupt rollback snapshot, or unsafe symlink causes the operation to fail closed and, once a journal exists, leaves it for recovery. After a committed or rolled-back invariant is proven, the journal is removed before best-effort deletion of nonessential backups, so a partial cleanup can leave only a protected orphan backup—not a journal referring to deleted recovery data.

### External Pi login changes

Usage tracking follows Pi's **verified current ChatGPT identity**, not just the last recorded handoff. If you manually change Pi's login, the matching known account is read from Pi; its duplicate native credential is not refreshed. An unknown, ambiguous, or unreadable identity is never guessed or attributed to a different account. The explicitly selected menu-bar account is not automatically changed.

If the menu reports a stale handoff:

1. Choose **Clear stale Pi handoff…** in the Codex section. This clears only the stale association; it does not copy, replace, or delete credentials.
2. The displaced account may need **Settings → Managed Codex accounts → Sign in again…**, because its only live credential had been in Pi before the external login replaced it.
3. To resume managed switching, choose **Manage this active Pi account…** for the account Pi actually uses. Exit Pi sessions before a credential handoff, as above.
4. Select **Use for menu-bar glyph** if you want a different account displayed in the menu bar.

Saved-reset spending is disabled while handoff ownership is inconsistent, and an observed-but-not-managed Pi account cannot spend resets through a stale native home. Disabled reset menus explain the actual condition: manage the active Pi account, clear a stale handoff, wait for an operation, resolve a pending request, or refresh unavailable usage. Refresh advice is not shown in place of missing credential ownership. Inactive accounts with independent working credentials remain readable.

### Claude setup and multiple subscriptions

Use **Settings → Claude accounts**:

- **Track default Claude Code login…** registers your existing default login without replacing it. macOS may ask for read-only Keychain access.
- **Track existing Claude profile…** registers another directory already used with `CLAUDE_CONFIG_DIR`. Select the configuration directory itself, not its `projects` subdirectory.
- **Add Claude account…** creates an isolated directory under `~/.llm-usage-bar/claude-accounts/<profile-id>/` and runs the installed `claude auth login --claudeai` for that directory. Sign in to the desired subscription in the browser. This does not switch your normal/default Claude Code login.

Each tracked profile shows available five-hour, weekly, and model-specific usage windows and reset times. The OAuth API source additionally shows extra-usage spend/cap when available. Under **Settings → Claude accounts → Usage source**, choose **Claude Code (recommended)** or **OAuth API**. A fresh configuration defaults to Claude Code; a pre-existing configuration without `claudeUsageSource` remains on OAuth API until the user explicitly selects a source. Missing windows remain unavailable, and one profile's failure does not hide the others.

**Claude Code source** runs the isolated owner CLI's `/usage` command, with auth status checked before and after. It runs in safe mode with tools, hooks, MCP, Chrome, and Remote Control disabled; telemetry, updater, and error reporting are narrowly disabled. LLM Usage does not read app Keychain credentials or tokens, refresh credentials, or answer OTP, login, or trust prompts on this path. Claude Code itself may refresh credentials or show macOS prompts. The setting **Automatically refresh Claude Code usage…** (`claudeAutoRefreshEnabled`) controls background CLI checks: when false, no background CLI runs; an explicit manual refresh forces a run past cache/backoff. `/usage` may return cached figures, so CLI capture time is not proof of measurement freshness.

CLI readings use the separate `codeUsage` result and are not treated as verified OAuth UUID measurements. Claude Code reports email and organization; LLM Usage pins these as `codeEmail` and `codeOrganizationID` without changing the existing verified `accountID` or `email` fields. The default login is used only when both its reported organization and an expected email uniquely match a tracked profile. Missing email associations can be bootstrapped from that configured profile’s historical `.claude.json` only when its complete UUID pair matches the saved identity; organization alone is insufficient. Unknown or ambiguous identities are never adopted, and a failure to read the default login does not block independent configured profiles. Menus identify **Default login** or **Configured profile** and show the actual reported email. A source switch clears incompatible results and discards stale in-flight results. Results are shared/coalesced with a 60-second cache/backoff per source; a newly observed default identity forces a capture rather than trusting an old cached login; manual force refreshes join an already-running request. Transient errors retain an in-memory last-known result only for the same origin, with a warning and original capture time; identity change or logout clears it. Shutdown cleans up probe processes.

**OAuth API source** retains the existing OAuth credential reader, internal usage/profile API features, and authenticated account/organization UUID checks. Its fallback to the default login is still gated on an exact UUID match to one uniquely tracked subscription. LLM Usage does not copy tokens to another credential store or refresh OAuth tokens itself. The standalone `llm-usage claude --json` helper is unchanged: it remains a read-only OAuth API query of the default login or `CLAUDE_CONFIG_DIR`, independent of the app's selected usage source. Local session totals are unchanged and continue to come only from each configured profile's `projects/**/*.jsonl` history.

For one-time CLI setup, **Copy refresh setup command** targets the actual selected origin (default login or configured profile) and runs `/usage` in safe mode with the narrow safety flags; complete any prompts yourself. **Sign in…** continues to target the configured profile. The normal **Copy Claude Code launch command** remains available, for example:

```bash
CLAUDE_CONFIG_DIR="$HOME/.llm-usage-bar/claude-accounts/<profile-id>" claude
```

Shell API-key, OAuth-token, or cloud-provider overrides can take precedence over a profile when you run Claude Code yourself. LLM Usage's explicit sign-in subprocess removes those inherited overrides.

Token totals are read locally from each profile's `projects/**/*.jsonl`, including subagent logs, with streamed/copied request-message identities deduplicated. The menu shows today/7d/30d totals, with input/output/cache-read/cache-write details. These are **recorded local-profile tokens**, not an account-wide total across devices or Claude web/desktop, and history from a directory used with past logins cannot be reliably attributed to one subscription. Profiles without a `projects` directory show “No local sessions yet”; unreadable existing history is reported separately from quota errors. No token count is inferred from an allowance percentage, and API-price estimates are not presented as subscription bills.

Removing a Claude account from tracking deletes only its tracking metadata, never its directory, sessions, or credentials. Claude account switching is not implemented by this feature.

Node must be discoverable from common paths, your login shell, or `LLM_BAR_NODE_PATH`.

Runtime refresh logs are written to `~/.llm-usage-bar/app.log`.

### Claude Code usage source

The Claude Code `/usage` source is now integrated into menu-bar polling as an explicitly selectable source; it is not the OAuth API transport and does not claim OAuth UUID verification or guaranteed measurement freshness. The CLI owner probe and its research history, including unresolved diagnostic identity/freshness flags, are documented in [the probe notes](docs/claude-owner-usage-probe.md).

### Pi setup

Pi support reads local session files directly.

Defaults:

- sessions directory: `~/.pi/agent/sessions`
- fork dedupe: enabled

Menu settings:

- **Enable Pi**
- **Deduplicate Pi fork history**
- **Set Pi sessions directory…**
- **Clear Pi sessions directory**

Notes:

- The Pi menu keeps four summary cards for today, the last 7d, the last 30d, and the last 90d, followed by a compact range-selectable token bar chart. Its 90d/6m/1y/All selector is interactive while the menu stays open. Choose 90d or 6m for local-calendar daily buckets, 1y for contiguous local-calendar seven-day buckets, or All for weekly buckets through 104 buckets (roughly two years) and calendar-month buckets for older history (the first/last month can be a partial range so the chart starts at the earliest eligible local day and ends today). Fixed-range charts and All use zero-filled buckets, exclude rows newer than the refresh time, and saturate negative/overflowing token sums. Hover a bucket while the menu is open to highlight it and inspect its exact local date (daily) or inclusive date range (weekly/monthly) and locale-formatted token count, including zero-token buckets.
- Pi totals are based on assistant message usage and completed subagent summaries persisted in the parent session JSONL. Subagent summaries are the `toolResult` records for the `subagent` tool; each valid result contributes its saved model usage and is assigned to the tool-result/completion timestamp.
- Incomplete subagent runs or results without usable usage are omitted. Pi does not read `telemetry/events.jsonl`; the persisted parent-session summary is the canonical subagent source and avoids counting a completed run twice.
- A managed Codex account handed off to Pi is also the source used for the app's Codex usage refresh; it is not read from the inactive managed home.
- Fork dedupe avoids double-counting copied history in forked session files by ignoring entries older than the fork session header timestamp.
- If a model/provider had missing pricing metadata when a session was recorded, some rows may appear as zero-cost.

### OpenCode Go setup

You can provide auth in three ways:

1. **Menu → Settings → Import OpenCode cookie from Chromium** (recommended)
2. **Menu → Settings → Set OpenCode cookie…**
3. Set `openCodeCookieHeader` in `~/.llm-usage-bar/config.json`

Optional:

- `openCodeWorkspaceID`: force a specific `wrk_...` workspace id.

If `openCodeWorkspaceID` is not set, the app auto-detects the first workspace.

If no manual cookie is configured, the fetcher also attempts a Chromium/Chrome cookie auto-import at runtime.

## Environment overrides

You can also run with env vars. These values affect the current process only: unrelated UI and managed-account saves preserve the corresponding values already stored on disk, including managed-account metadata.

- `LLM_BAR_CODEX_PATH`
- `LLM_BAR_CLAUDE_PATH` (Claude Code executable for explicit sign-in)
- `LLM_BAR_NODE_PATH`
- `LLM_BAR_OPENCODE_COOKIE`
- `LLM_BAR_OPENCODE_WORKSPACE_ID`
- `LLM_BAR_PI_SESSIONS_DIR`
- `LLM_BAR_PI_DEDUPE_FORKS`
- `LLM_BAR_REFRESH_SECONDS`

Example:

```bash
LLM_BAR_CODEX_PATH="$HOME/Applications/Assistants/codex/codex" \
LLM_BAR_OPENCODE_COOKIE='auth=...' \
LLM_BAR_PI_SESSIONS_DIR="$HOME/.pi/agent/sessions" \
swift run LLMUsageBar
```

## Startup behavior

- App already runs as a background/accessory menubar app (no Dock icon).
- To auto-start on login, use **Settings → Start at login**.

## Notes

- OpenCode usage-history access currently relies on internal web server-function endpoints used by the OpenCode web UI.
- Managed Codex accounts use the installed Codex CLI and app-server; LLM Usage Bar does not shell out to CodexBar.

## Validation

```bash
swift test
node --test node/*.test.js
npm run build
```

Claude tests use fixture credentials, fake CLI processes, and injected HTTP responses; they never access real Keychain logins or make provider requests.
