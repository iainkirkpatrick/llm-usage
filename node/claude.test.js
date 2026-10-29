import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fetchClaudeUsage } from "./claude.js";
import { parseArgs, help } from "./cli.js";

const payload = { claude: { session: { remainingPercent: 75, usedPercent: 25, resetAt: null }, weekly: null, source: "Claude Code default", updatedAt: "2025-01-01T00:00:00Z" } };
function fixture(output, status = 0) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "llm-claude-cli-"));
  const helper = path.join(root, "helper");
  fs.writeFileSync(helper, `#!/bin/sh\nif [ "$1" = "--claude-usage-identity" ]; then printf '{"fingerprint":"%s"}' "\${TEST_ID:-0000000000000000000000000000000000000000000000000000000000000000}"; exit 0; fi\nif [ "$TEST_DELAY" = "1" ]; then sleep 5; fi\nprintf '%s' ${JSON.stringify(output)}\nexit ${status}\n`, { mode: 0o700 });
  return { root, helper, cacheDirectory: path.join(root, "cache"), cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

test("Claude command routing only accepts JSON and help documents it", () => {
  assert.deepEqual(parseArgs(["claude", "--json"]), { command: "claude", json: true });
  assert.throws(() => parseArgs(["claude", "--codex-home", "/tmp"]), /Unknown argument/);
  assert.match(help(), /llm-usage claude --json/);
});

test("Claude helper output is validated and cached with private permissions", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root }, now: () => Date.now() };
    assert.deepEqual(await fetchClaudeUsage(args), payload);
    assert.deepEqual(await fetchClaudeUsage(args), payload);
    assert.equal(fs.readdirSync(f.cacheDirectory).filter(name => name.endsWith(".json")).length, 1);
    assert.equal(fs.statSync(f.cacheDirectory).mode & 0o777, 0o700);
    assert.equal(fs.statSync(path.join(f.cacheDirectory, fs.readdirSync(f.cacheDirectory).find(name => name.endsWith(".json")))).mode & 0o777, 0o600);
  } finally { f.cleanup(); }
});

test("credential fingerprint changes and default versus explicit config use separate caches", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const base = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root }, now: () => Date.now() };
    await fetchClaudeUsage({ ...base, env: { ...base.env, TEST_ID: "1".repeat(64) } });
    await fetchClaudeUsage({ ...base, env: { ...base.env, TEST_ID: "2".repeat(64) } });
    await fetchClaudeUsage({ ...base, env: { ...base.env, TEST_ID: "2".repeat(64), CLAUDE_CONFIG_DIR: path.join(f.root, ".claude") } });
    assert.equal(fs.readdirSync(f.cacheDirectory).filter(name => name.endsWith(".json")).length, 3);
  } finally { f.cleanup(); }
});

test("helper deadline rejects and releases its cache lock", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    await assert.rejects(fetchClaudeUsage({ executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root, TEST_DELAY: "1" }, helperTimeoutMs: 50 }), /timed out/);
    assert.equal(fs.readdirSync(f.cacheDirectory).some(name => name.endsWith(".lock")), false);
  } finally { f.cleanup(); }
});

test("invalid helper output is rejected and failure is backed off without another invocation", async () => {
  const f = fixture("not-json");
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root }, now: () => Date.now() };
    await assert.rejects(fetchClaudeUsage(args), /invalid JSON/);
    await assert.rejects(fetchClaudeUsage(args), /invalid JSON/);
  } finally { f.cleanup(); }
});
