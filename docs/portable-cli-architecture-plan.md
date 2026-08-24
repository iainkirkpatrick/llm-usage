# Node Codex CLI architecture

The Node bundle in `dist-node/llm-usage.mjs` is the Codex core for the macOS app and portable CLI. The standalone CLI preserves its existing Pi-auth compatibility flow and also supports an explicit native Codex home for managed accounts; the macOS app uses isolated managed homes unless the user explicitly hands the selected account off to Pi.

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

The macOS app creates homes below `~/.llm-usage-bar/codex-accounts/<UUID>`, rejects symlinked app-owned ancestors, stores only profile metadata and the optional Pi-handoff marker in `config.json`, and enforces directory mode `0700` and auth-file mode `0600`. Login runs in a sibling staging `CODEX_HOME`; only a validated ChatGPT OAuth `auth.json` is atomically renamed into the live home after success. A cancellation or failed login never writes the live credential. Removal first quarantines and deletes the credential home, then commits metadata; a failed credential deletion restores the home and leaves metadata untouched, while a metadata-save failure leaves the profile retained and reports that credentials were already deleted.

The menu can explicitly hand the selected managed account to Pi. The live OAuth entry is then stored under `openai-codex` in `~/.pi/agent/auth.json`, and the active managed home has no `auth.json`; this prevents two refresh loops from owning the same account. Pi-compatible mkdir locking with an inode-checked heartbeat, restrictive path checks, separate profile UUID/ChatGPT identity fields, exact credential/Pi snapshots and hashes, atomic writes, and a protected transaction journal provide fail-closed switching and startup recovery. Swift never removes an existing lock as stale; it fails busy when it cannot safely acquire the protocol, and a heartbeat-detected inode replacement aborts/rolls back the transaction instead of continuing. ConfigStore saves—including the handoff commit—use a kernel-owned `config.json.lock` from comparison through atomic replacement; its pathname is never removed for stale recovery. Switching away first converts Pi's latest tokens back to the matching native home, then activates the target. Existing Pi credentials for a different ChatGPT identity are never overwritten, and all unrelated provider entries are retained. While the handoff is active, the macOS app deliberately calls the Node CLI's Pi-auth path for usage and passes the expected ChatGPT identity for reset consumption; the Node operation validates that identity before its irreversible request. Once a committed or rolled-back invariant is proven, the journal is removed before nonessential backup cleanup; a failed cleanup can leave a protected orphan backup, but never a journal whose deleted backup makes recovery impossible.

## Commands and contract

```text
llm-usage codex [--json]
llm-usage codex --codex-home PATH [--json]
llm-usage codex --all-managed [--json]
llm-usage codex reset consume --credit-id ID --idempotency-key KEY --expected-account-id ID [--codex-home PATH] --json
llm-usage diagnose
```

The default CLI JSON output remains `{ "codex": { "session", "weekly", "creditsRemaining", "resetCredits", "source", "updatedAt" } }`; managed responses add only optional `email` and `planType` profile metadata. `--all-managed --json` adds a `codexAccounts` array, retaining a selected `codex` object only when the configured (or first) managed primary is available. If config records a Pi handoff, that active profile is fetched through the caller-supplied (or `LLM_BAR_PI_AUTH_PATH`) Pi auth path while inactive profiles remain native. With no profiles it returns a clear managed-account prompt instead of querying CLI compatibility auth. Reset consumption requires `--expected-account-id`; it is rejected when no expected ChatGPT identity is supplied, and the identity check runs in the same app-server operation as the irreversible consume request. If `account/read` does not return an identity, consumption is disabled for that app-server version. `diagnose` only inspects local executable/config/Pi-auth availability, so a managed-only installation does not require Pi auth and is never reported as having it.

The macOS app owns account labels, menu presentation, primary-account selection, Pi-handoff state, notifications, confirmation, and automatic-redemption policy. It displays and refreshes managed homes for inactive accounts and the Pi-auth path for the active handed-off account, prompts for an account when none exists, and keeps primary selection fail-closed: an unavailable selected account is not replaced by another managed home. Pending reset idempotency state includes the account key so retries cannot cross account homes; refresh-required state is also account-scoped.

## Validation

```bash
npm test
npm run build
swift test
swift build -c release
```

Tests cover the CLI compatibility JSON keys, managed metadata/argument parsing, managed-only primary selection and empty-account response, explicit Pi auth-path handling, account-bound reset consumption, managed-only diagnosis, unsafe auth rejection, ISO-8601 decoding, legacy config decoding, staged credential replacement, OAuth URL filtering, managed-home permission/symlink hardening, serialized competing ConfigStore writers, Pi lock ownership loss, and Pi handoff switching: latest-token persistence, one-live-copy invariants, unrelated Pi-provider preservation, identity mismatch rejection, partial cleanup ordering, and journal recovery faults across committed and rolled-back phases. `npm run build` regenerates the ignored `dist-node/llm-usage.mjs` bundle used by the app and launcher.
