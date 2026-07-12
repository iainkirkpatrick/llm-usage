# Portable CLI Architecture Plan

## Goal

Make Codex usage available locally to Pi on Linux/Raspberry Pi without making a Mac the usage oracle, while preserving the existing macOS menu bar app and its `llm-usage-bar` launcher contract.

Target flow:

```text
Pi extension → local llm-usage CLI → local Codex app-server → Codex/OpenAI usage
```

## Verified feasibility (13 July 2026)

Target host: `smart-tv-pi`

- Debian Linux on `aarch64`: confirmed.
- Pi auth at `~/.pi/agent/auth.json`: present.
- Node: v26.3.0, confirmed and successfully runs the bundled helper (which targets Node 20).
- Codex: `@openai/codex@0.144.1` Linux ARM64 installed successfully.
- `codex app-server`: available and successfully serves the required RPCs on Linux ARM64.
- Swift: 6.3.3 installed through Swiftly using its Ubuntu 22.04 platform profile.
- `llm-usage`: builds successfully in release mode on the Pi.
- Authenticated local fetching using `~/.pi/agent/auth.json`: verified; source reports `Pi auth`.
- Installed layout: `~/bin/llm-usage` plus adjacent `LLMUsageBar_LLMUsageCore.resources` works outside the build directory.
- Pi extension config now points directly to the local CLI; the former SSH proxy configuration has been retired.

Important: Pi auth is not itself a usage API. The current fetcher launches a local `codex app-server`, then supplies Pi-managed ChatGPT tokens to it. A compatible local Codex binary is a hard dependency.

## Architecture

```text
LLMUsageCore (portable, initially Codex-only)
  ├─ Codex RPC/process client and usage fetcher
  ├─ Codex reset credit models and operations
  ├─ Pi auth helper resource and auth discovery
  ├─ shared Codex models
  └─ portable formatting needed by the CLI

llm-usage (portable CLI)
  ├─ llm-usage codex [--json]
  ├─ llm-usage diagnose
  └─ stable JSON and exit-code contract

LLM Usage.app (macOS)
  ├─ imports LLMUsageCore directly
  ├─ menu bar UI and app state
  ├─ notifications and automatic-reset policy
  ├─ OpenCode and Pi session providers initially remain here
  └─ preserves argument dispatch for compatibility
```

Products should ultimately be:

```text
.library(name: "LLMUsageCore", targets: ["LLMUsageCore"])
.executable(name: "llm-usage", targets: ["LLMUsageCLI"])
.executable(name: "LLMUsageBar", targets: ["LLMUsageBar"])
```

## Boundaries and constraints

### Portable core

The first portable core is deliberately Codex-only. It must not import or link:

- AppKit
- UserNotifications
- JavaScriptCore
- Security or other Apple-only frameworks

`UserNotifications` authorization and automatic-redemption policy belong in the macOS app and should be injected or checked before calling the core operation.

OpenCode remains macOS-only initially because its fetcher currently imports JavaScriptCore. Pi session support can be moved later after Codex is working end-to-end.

### Resources

The Pi auth helper is loaded with `Bundle.module`. A standalone executable copied into `~/bin` is insufficient: the generated Swift resource bundle must accompany it, or the helper must later be embedded by another deliberate mechanism.

Linux release archives must contain:

- `llm-usage`
- its Swift resource bundle containing `codex-pi-helper.bundle.mjs`
- an install script or documented layout that preserves resource lookup
- checksum and runtime prerequisites

App SVGs and the application icon remain app resources; do not move them into the portable core bundle.

### Compatibility contracts

Preserve the existing JSON keys and semantics:

```json
{
  "codex": {
    "session": { "remainingPercent": 42, "resetAt": "..." },
    "weekly": { "remainingPercent": 70, "resetAt": "..." },
    "resetCredits": { "availableCount": 3 },
    "source": "Pi auth",
    "updatedAt": "..."
  }
}
```

Contract tests must cover key names, omitted optional fields, ISO-8601 dates, stdout/stderr, and exit codes.

The `llm-usage-bar` launcher only opens the macOS app. All command-line usage belongs to the standalone `llm-usage` executable. Keep existing `~/.llm-usage-bar` paths and `LLM_BAR_*` environment variables during migration.

## Staged implementation

### Stage 0 — Target-host feasibility (completed)

Completed on `smart-tv-pi`:

1. Installed a Swift 6 toolchain.
2. Executed the bundled auth helper against the real Pi auth file without logging token material.
3. Verified local Codex app-server RPCs used by the fetcher:
   - initialization
   - `account/login/start`
   - `account/rateLimits/read`
   - reset-credit response decoding
4. Confirmed Node 26 helper compatibility and Linux ARM64 Codex availability.
5. Confirmed authenticated local fetching, allowing the local refactor to proceed.

### Stage 1 — Lock contracts and extract a minimal core (implemented)

1. Add tests for Codex JSON serialization and window classification.
2. Create `LLMUsageCore` with explicit public API.
3. Move only Codex models, RPC/process code, auth helper, logging if portable, and required formatting.
4. Move notification authorization and auto-redemption policy into the app.
5. Keep OpenCode, cookie import, Pi session aggregation, AppKit, launch-at-login, and app resources in macOS targets.
6. Keep macOS behavior unchanged.

### Stage 2 — Add the CLI and simplify the app (implemented)

1. Add the `llm-usage` executable product.
2. Implement `codex [--json]` and a Codex-focused, capability-aware `diagnose` command.
3. Remove command dispatch from the app executable; `llm-usage-bar` only launches the app.
4. Update development commands to name products explicitly because bare `swift run` becomes ambiguous.
5. Update macOS packaging for changed resource bundle names and include the new CLI deliberately.

### Stage 3 — Linux hardening

1. Add Linux build/test CI for `swift build --product llm-usage`.
2. Add bounded helper and RPC timeouts, cancellation, and child-process termination.
3. Ensure diagnostics report resolved executables/auth source without token material.
4. Build and test on the actual ARM64 Pi, not only x86_64 Linux.

### Stage 4 — Platform packaging

1. Produce architecture-specific archives; do not copy macOS binaries to Linux.
2. Include executable, resource bundle, install instructions/script, prerequisites, and checksum.
3. Use reproducible helper generation (`npm ci`) in release CI.
4. Preserve current macOS app packaging and launcher behavior.

### Stage 5 — Pi migration (implemented; hardening remains)

1. Local authenticated fetches work under the Pi user's environment.
2. JSON compatibility and installed resource discovery are verified; refresh-token and timeout behavior still need hardening/canary coverage.
3. The Pi extension command uses `/home/iainkirkpatrick/bin/llm-usage`.
4. The former SSH proxy and saved fallback configuration have been removed.

### Stage 6 — Additional providers and status

After Codex is stable:

- port Pi session parsing if useful
- replace or isolate OpenCode's JavaScriptCore parser before claiming Linux support
- investigate fast-mode/status as a separate feature with a defined data source
- consider provider-wide status commands and schemas

## Release gates

Do not switch the Pi integration until all of these pass:

- macOS app builds, launches, and displays the same data
- `llm-usage-bar` launches only the app and does not provide CLI commands
- `llm-usage codex --json` matches the documented schema
- Linux ARM64 build succeeds on `smart-tv-pi`
- local authenticated usage fetching succeeds on `smart-tv-pi`
- helper resources are found from the installed layout
- auth refresh and process timeout behavior are tested

## Non-goals for the first migration

- redesigning all provider schemas
- porting OpenCode immediately
- adding a daemon or central service before local feasibility is known
- changing menu bar UX
- renaming persisted config/log paths
- implementing fast mode before its data source is understood
