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
npm run build
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

Requirements are Node 20 or newer, a compatible local Codex executable providing `app-server`, and Pi-managed Codex authentication. Override the destination with `LLM_USAGE_INSTALL_DIR`.

The Node CLI can verify local Codex prerequisites:

```bash
llm-usage diagnose
```

Codex usage requires Pi-managed `openai-codex` authentication. The local Codex executable provides the app-server transport but its own login is not used.

## Config

On first run, it creates:

`~/.llm-usage-bar/config.json`

Example:

```json
{
  "codexEnabled" : true,
  "autoRedeemExpiringCodexResets" : false,
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

Codex rate limits and saved reset credits are fetched from the Codex app-server. When credits are available, the menu lists their expiry and offers an explicit, Cancel-by-default confirmation before spending one. The Settings menu can opt in to automatically redeem the specific earliest-expiring saved reset during its final hour; it sends local notifications at 24 hours, 6 hours, and after the redemption attempt.

If Pi has an `openai-codex` OAuth login in `~/.pi/agent/auth.json`, the bundled Node CLI supplies that auth to the local Codex app-server. Node must be discoverable from common paths, your login shell, or `LLM_BAR_NODE_PATH`.

The menu shows the active source as **Pi auth**.

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

You can also run with env vars:

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
- If OpenCode changes those endpoints, this app will need updates.
