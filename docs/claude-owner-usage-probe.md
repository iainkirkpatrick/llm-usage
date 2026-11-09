# Claude Code `/usage` source and owner probe

## Current status

The Claude Code owner-CLI source is integrated into app usage polling and is
selectable under **Settings → Claude accounts → Usage source**. Fresh app
configurations default to Claude Code; older configurations missing
`claudeUsageSource` remain on OAuth API until explicitly changed. This source is
separate from OAuth API: CLI readings are reported usage, not verified OAuth
account-UUID measurements, and Claude Code may display cached figures.

The explicit `--claude-owner-usage-probe` helper described below remains a
diagnostic/research entry point. The app uses the same bounded owner runner through
the coalescing `ClaudeCodeUsageFetcher`. The shared `llm-usage claude --json`
helper now uses a separate structured owner-control transport when Claude Code
is selected; the menu-bar transport remains the interactive `/usage` runner.

Version **0.2.4** was built, signed and installed locally on 8 November 2026, with
this user's explicit approval to select the Claude Code source. The existing app
and configuration were backed up under the private maintenance directory. The
installed app's first successful services capture at 05:39 UTC reported **100%
session / 81% weekly remaining**. Existing account UUIDs, verified-email fields,
labels, directories, other-provider settings and the five-minute interval were
preserved; only the source and separate CLI association pins changed. The next
scheduled refresh completed at 05:44 UTC with another successful services capture,
confirming automatic polling in the installed app; no probe children remained.

At that installation the configured main profile still needed user-completed
setup. The user subsequently completed the prompts and confirmed both menu-bar
accounts work. The shared CLI has also returned usage successfully for both the
default login and the explicitly selected main directory, with Pi's aggregate
traffic restriction preserved. No automatic login or prompt approval was added.
Historical validation before the 0.2.4 installation: 231 Swift tests and 30 Node
tests passed, plus static review.

### Shared CLI / Pi transport

`--claude-usage-identity` and `--claude-usage-cli` now follow the app's selected
source. The Claude Code identity fingerprint hashes source/version, the caller's
profile scope, and reported email/organization, not a credential. Default and
explicit `~/.claude` remain distinct; no tracked account is substituted.

The quota helper sends only correlated `initialize` and `get_usage` control
requests. Tools, hooks, MCP, Chrome, Remote Control, suggestions, persistence,
updater, telemetry, and error reporting are disabled. Auth/provider overrides are
sanitized, while inherited `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is preserved
for both status and usage. Identity is checked before/after capture. No model
message or prompt response is sent; Claude Code still owns its credentials.

The old JSON windows are retained. `capturedAt` and its legacy `updatedAt` alias
record capture time only; both verification flags remain false. Cache hits keep
that original timestamp and recheck reported identity. Profile/version/fingerprint
scoping, a private cross-process lock, 60-second cache/backoff, bounded protocol
frames/output, monotonic timeouts, and cancellation/process-tree cleanup protect
one-shot calls. Caller-local budget exhaustion is not cached as shared failure.
The Node budget is 25 seconds, including lock waits, with up to one additional
second for cleanup (Pi defaults to 30 seconds). The owner control API is
experimental: incompatible/interactive responses fail closed with sanitized
errors, without falling back to native Keychain reads or another account.

Version **0.2.5** was built, signed, and installed locally on 9 November 2026.
The installed `llm-usage claude --json` returned both profiles' windows and the
deployed Pi footer formatter accepted the payload. The existing configuration
was unchanged, and the prior app/config were backed up under
`~/.llm-usage-bar/maintenance/claude-cli-source-20261109-162323/`.
Validation: **257 Swift, 41 Node, and 13 Pi footer tests passed**. No Pi extension
change or reload is required; existing sessions use the replacement executable
on their next scheduled refresh.

## Why

Claude Code can reset its Keychain partition permissions when it rotates a token.
Delegating refresh to Claude and then rereading the credential from LLM Usage
still depends on the permission that was just lost. Instead, this experiment asks
Claude itself to run its local `/usage` command and captures its usage panel.

CodexBar uses this terminal-mediated approach as one of its usage sources:
https://github.com/steipete/CodexBar/blob/458afc6017c4b2f5f97615653ce2999de3551673/docs/claude.md#cli-pty-fallback

## Run explicitly

```bash
swift build
helper="$(swift build --show-bin-path)/LLMUsageBar"

# The unset/default login (not explicitly CLAUDE_CONFIG_DIR=~/.claude).
env -u CLAUDE_CONFIG_DIR "$helper" --claude-owner-usage-probe

# A specific existing Claude profile. Substitute its configured directory.
CLAUDE_CONFIG_DIR="/absolute/path/to/profile" "$helper" --claude-owner-usage-probe
```

The probe no longer forces `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, which can
break Claude's interactive usage page. It separately disables auto-updates,
telemetry, error reporting and official marketplace auto-install instead. The
usage capture also passes `--safe-mode` (tested with Claude Code 2.1.314), so
custom plugins, hooks, commands and other customizations do not run while the
aggregate restriction is absent. Managed policies still apply.

An inherited nonempty aggregate restriction is **not silently removed**, including
values `0` or `false`, which Claude treats as restrictions too. If you explicitly
want to permit this one diagnostic to make its usage/feature-configuration
requests, without changing saved settings or your shell, run:

```bash
env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC \
  "$helper" --claude-owner-usage-probe
```

Telemetry, error reporting and updates remain disabled by the probe. Otherwise
leave the restriction in place; the probe fails before launching Claude.

The diagnostic helper does not initialize AppKit, start a timer, change account
tracking, read credentials itself, call OAuth endpoints, copy tokens, initiate
sign-in, or send a model/chat request. It runs the installed Claude Code, which
**can refresh its own credentials or show its own Keychain prompts**. The
integrated app source also delegates CLI execution to Claude Code and does not
read app Keychain credentials or tokens on that path. It uses safe mode and
disables tools, hooks, MCP, Chrome, and Remote Control, with narrow telemetry,
updater, and error-reporting controls. Neither path answers login, OTP, or trust
prompts automatically.

The probe uses the existing private refresh workspace for the selected source,
with provider/auth/cloud overrides removed, updates disabled, and tools, hooks,
MCP configuration, browser integration and Remote Control startup disabled. It
never answers onboarding, trust or login prompts. If setup is required, complete
it yourself with that source's **Copy refresh setup command** in Settings, exit
Claude, and rerun the probe. Do not approve an unrelated workspace or sign out of
a working Claude session just to run this test.

Auth status is checked before and after the usage capture. Output is bounded,
commands are time-limited, and probe-owned process groups/descendants are cleaned
up on success, failure, timeout and cancellation, including SIGINT/SIGTERM sent
to the helper. SIGKILL cannot run cleanup. No raw terminal capture or auth
status JSON is persisted or logged. Successful output contains only selected
owner-reported identity fields and parsed usage. Errors are sanitized.

## Identity is deliberately unresolved

Claude Code 2.1.314's `auth status --json` returns an email and organisation UUID,
but **no account UUID**. That is not equivalent to the existing fetcher's
same-token, authenticated account-UUID + organisation-UUID check. A stable
pre/post observation also cannot prove the quota used that exact identity.

Successful diagnostic JSON therefore always includes:

```json
{"identityVerifiedForTrackedAccount": false, "freshnessVerified": false}
```

The experiment has a separate result type. It cannot populate a
`ClaudeQuotaSnapshot`, update saved account identity, relabel an account, route
the default login to another profile, or publish a tracked-account measurement.
Local metadata hints and email matches are not used to invent the missing UUID.
The output uses `capturedAt`, not `updatedAt`: capturing a CLI panel does not
prove the underlying measurement was just fetched.

## Parser limitations

The terminal renderer handles a bounded subset of VT cursor/erase operations,
streaming UTF-8, common wide characters, cursor visibility and redraw modes. It
is not a complete terminal emulator; complex grapheme clusters and unsupported
terminal operations can still cause a rejected capture.

The parser recognizes current session, all-model weekly and named weekly model
windows, percentages used/left, and reset descriptions. Missing windows remain
missing. Loading/error panels, conflicting percentages and CLI-seeded last-known
usage are rejected. Insight/tool-contribution percentages are not quotas. Reset
text is preserved, not converted into an invented timestamp. Extra-usage spend
is not implemented in this proof of concept.

## Initial live findings (6 November 2026)

Using the installed Claude Code 2.1.314:

- Default login: status reports the expected services email/organisation, but
  Claude's `/usage` panel reports **Failed to load usage data**.
- Configured main profile: status initially reports the expected main
  email/organisation, but interactive usage stops at a setup/login barrier.
- Configured services profile: Claude reports signed out; it is distinct from
  the default login. There is deliberately no silent fallback between them.

At that time no live quota was accepted, so those observations did not
demonstrate working quota fetching, correct live parser fidelity, or successful
rotation across an expiry. They remain historical findings; see the current
status above and the later follow-up below. They are not grounds to claim both
profiles are fixed.

Validation: 194 Swift tests passed, including 34 new parser/probe tests. Separate
fixture-only helper smoke checks confirmed SIGINT and SIGTERM cancel cleanly and
leave neither the fixture CLI nor its child running. Static review found no
remaining important POC safety issue. The existing trust-barrier fixture startup
timeout was increased from 0.3 to 2 seconds after it failed under full-suite load
but passed in isolation; its production behavior and assertions are unchanged.

## Follow-up findings (6 November 2026, evening)

The later default/services probe successfully returned CLI-reported quota: at
the 11:39 UTC capture it showed 98% session and 81% weekly remaining. This
historical capture is distinct from the latest pre-install probe summarized
above. The isolated main profile was not retried or changed in that follow-up.

Two implementation problems were addressed:

1. We were forcing the aggregate traffic-disable flag on every launch, and the
   shell also inherits it. This flag is a known contributor to interactive
   `/usage` failures. We now use narrow controls, preserve an inherited
   restriction, and require an explicit one-run unset for this experiment.
   Upstream reports:
   https://github.com/anthropics/claude-code/issues/8473#issuecomment-4694198700
   https://github.com/anthropics/claude-code/issues/71886
2. Claude emits Kitty keyboard-protocol and terminal-query sequences such as
   `CSI < u` during redraws. The renderer incorrectly treated them as display
   invalidation, discarding quota rows. These non-display operations now preserve
   the screen. The current insights heading (`What's contributing to your
   usage?`, without "limits") is also excluded from quota parsing.

The aggregate flag is not a universal usage prohibition: a separate structured
owner-side control test returned windows with it still set, and the interactive
CLI can display an earlier snapshot. This makes **freshness provenance a separate
unresolved issue**, not a reason to treat any visible quota as fresh.

### Structured alternative

The actually installed Claude Agent SDK 0.3.312 declarations expose:

```ts
usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({skipBehaviors: true})
```

Its native control request is `get_usage` with `skip_behaviors: true`. A bounded
one-shot control-protocol experiment against the installed Claude Code 2.1.314
successfully returned structured five-hour/weekly utilization and ISO reset
times. It sent only `initialize` and `get_usage` control requests, no user/model
messages; the returned session model cost was zero, and behavior scanning was
skipped. That experiment added neither an SDK dependency nor a shipped control
transport at the time; the shared CLI now implements the bounded protocol
directly, without an SDK dependency, as described above.

This avoids terminal parsing, but does **not** resolve the important gates:

- Initialization/`accountInfo()` reports email, organisation display name,
  subscription type and provider, not the authenticated account UUID pair.
  Separate `auth status` adds the organisation UUID, still not the account UUID.
- Recursively inspecting the usage response found no account/organisation UUID
  evidence. Local metadata cannot fill this gap authoritatively.
- The native implementation can return seeded cached windows after a request
  failure. The public response does not expose the source's original observation
  time or a reliable fresh-versus-seeded status. A non-null `rate_limits` object
  is therefore insufficient evidence of a fresh fetch.
- Anthropic explicitly marks this API experimental and unstable.

The SDK API itself is not a runtime dependency. The shared CLI's direct
structured control transport retains these experimental identity/freshness
limitations. The menu-bar source is separately labelled and uses separate
`codeEmail` and `codeOrganizationID` pins; neither transport overwrites the
existing verified OAuth subscription identity or pretends to be the same-token
source. Preserving the OAuth source's exact identity guarantee still requires
its authenticated account/organisation UUID checks.

Follow-up validation at the time: all 197 Swift tests passed, including 37
parser/probe tests. That historical count is not a current test total. The
integrated source publishes separately labelled CLI readings, while the
unverified identity/freshness diagnostic flags remain false; fixture tests do
not establish live freshness, successful rotation, or behavior for every profile.
