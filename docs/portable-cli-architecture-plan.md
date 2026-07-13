# Node Codex CLI architecture

The Node bundle in `dist-node/llm-usage.mjs` is the sole Codex core for both macOS and Linux. It reads Pi-managed `openai-codex` OAuth credentials, launches the local Codex `app-server`, and preserves the external JSON contract for `codex --json`.

## Runtime layout

- macOS app: `LLMUsageBar` invokes Node plus `Contents/Resources/llm-usage.mjs`.
- macOS command launcher: `Contents/MacOS/llm-usage` resolves Node and invokes the resource bundle.
- Linux: `install-linux-cli.sh` installs `llm-usage.mjs` and an executable launcher only.

Node resolution honors `LLM_BAR_NODE_PATH`, `~/bin/node`, common Homebrew/system paths, `PATH`, and a zsh/bash login shell. The Swift bridge bounds execution time, terminates timed-out children, and drains bounded stdout/stderr concurrently.

The app owns UI policy and authorization. In particular, it checks notification/config authorization immediately before invoking `codex reset consume ... --json` for automatic redemption. The Node core performs only Codex fetching and consumption.

## Commands and contract

```text
llm-usage codex --json
llm-usage codex reset consume --credit-id ID --idempotency-key KEY --json
```

The JSON output remains `{ "codex": { "session", "weekly", "creditsRemaining", "resetCredits", "source", "updatedAt" } }`, with optional values omitted/null as before. Node tests cover argument parsing, window classification, and schema compatibility.

Build/package validation:

```bash
npm ci
npm test
npm run build
./scripts/package-macos-app.sh
./scripts/install-linux-cli.sh
```
