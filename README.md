# LLM Usage Bar (Codex + OpenCode Go + Pi)

Small macOS menu bar app to track:

- **Codex** usage (session + weekly + credits + saved rate-limit resets)
- **OpenCode Go** usage (5h/weekly/monthly + model usage history for GLM-5, Kimi K2.5, MiniMax M2.5)
- **Pi** local session usage (today / last 7d / last 30d + model/provider/project summaries)

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
```

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

Node must be discoverable from common paths, your login shell, or `LLM_BAR_NODE_PATH`.

Runtime refresh logs are written to `~/.llm-usage-bar/app.log`.

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

- Pi totals are based on assistant message `usage.cost.total` values saved in session JSONL files.
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
