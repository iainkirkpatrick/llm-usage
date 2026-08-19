# Node Codex CLI architecture

The Node bundle in `dist-node/llm-usage.mjs` is the Codex core for the macOS app and portable CLI. The standalone CLI preserves its existing Pi-auth compatibility flow and also supports an explicit native Codex home for managed accounts; the macOS app uses only managed homes.

## Runtime layout

- macOS app: `LLMUsageBar` invokes Node plus `Contents/Resources/llm-usage.mjs`.
- macOS command launcher: `Contents/MacOS/llm-usage` resolves Node and invokes the resource bundle.
- Linux: `install-linux-cli.sh` installs `llm-usage.mjs` and an executable launcher only.

## Authentication boundaries

`llm-usage codex --json` without `--codex-home` remains the existing Pi-managed `openai-codex` compatibility path. The Node core supplies Pi's OAuth tokens to a local Codex app-server and never changes the JSON contract when no managed home is selected.

Managed account fetches use:

```text
CODEX_HOME=<app-owned profile home> codex app-server
  → initialize
  → account/read { refreshToken: true }
  → account/rateLimits/read
```

No Pi token is injected into this path and the Node core does not duplicate token refresh or call undocumented HTTP endpoints. The installed Codex CLI owns native OAuth refreshes in the isolated `CODEX_HOME/auth.json`.

The macOS app creates homes below `~/.llm-usage-bar/codex-accounts/<UUID>`, rejects symlinked app-owned ancestors, stores only profile metadata in `config.json`, and enforces directory mode `0700` and auth-file mode `0600`. Login runs in a sibling staging `CODEX_HOME`; only a validated ChatGPT OAuth `auth.json` is atomically renamed into the live home after success. A cancellation or failed login never writes the live credential. Removal first quarantines and deletes the credential home, then commits metadata; a failed credential deletion restores the home and leaves metadata untouched, while a metadata-save failure leaves the profile retained and reports that credentials were already deleted.

## Commands and contract

```text
llm-usage codex [--json]
llm-usage codex --codex-home PATH [--json]
llm-usage codex --all-managed [--json]
llm-usage codex reset consume --credit-id ID --idempotency-key KEY [--codex-home PATH] --json
llm-usage diagnose
```

The default CLI JSON output remains `{ "codex": { "session", "weekly", "creditsRemaining", "resetCredits", "source", "updatedAt" } }`; managed responses add only optional `email` and `planType` profile metadata. `--all-managed --json` is managed-only and adds a `codexAccounts` array, retaining a selected `codex` object only when the configured (or first) managed primary is available. With no profiles it returns a clear managed-account prompt instead of querying CLI compatibility auth. Reset consumption is explicitly home-scoped when `--codex-home` is provided. `diagnose` only inspects local executable/config/Pi-auth availability, so a managed-only installation does not require Pi auth and is never reported as having it.

The macOS app owns account labels, menu presentation, primary-account selection, notifications, confirmation, and automatic-redemption policy. It displays and refreshes only managed homes, prompts for an account when none exist, and keeps primary selection fail-closed: an unavailable selected account is not replaced by another managed home. Pending reset idempotency state includes the account key so retries cannot cross account homes; refresh-required state is also account-scoped.

## Validation

```bash
npm test
npm run build
swift test
swift build -c release
```

Tests cover the CLI compatibility JSON keys, managed metadata/argument parsing, managed-only primary selection and empty-account response, managed-only diagnosis, unsafe auth rejection, ISO-8601 decoding, legacy config decoding, staged credential replacement, OAuth URL filtering, and managed-home permission/symlink hardening. `npm run build` regenerates the ignored `dist-node/llm-usage.mjs` bundle used by the app and launcher.
