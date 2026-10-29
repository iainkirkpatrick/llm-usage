import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
const execFileAsync = promisify(execFile);
import { fetchClaudeUsage } from "./claude.js";
import { parseArgs, help } from "./cli.js";

const payload = { claude: { session: { remainingPercent: 75, usedPercent: 25, resetAt: null }, weekly: null, source: "Claude Code default", updatedAt: "2025-01-01T00:00:00Z" } };
function fixture(output, status = 0) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "llm-claude-cli-"));
  const helper = path.join(root, "helper");
  const identityLog = path.join(root, "identity.log");
  const quotaLog = path.join(root, "quota.log");
  fs.writeFileSync(helper, `#!/bin/sh\nif [ "$1" = "--claude-usage-identity" ]; then echo called >> '${identityLog}'; if [ "$TEST_ID_FAIL" = "1" ]; then echo identity failed >&2; exit 1; fi; printf '{"fingerprint":"%s"}' "\${TEST_ID:-0000000000000000000000000000000000000000000000000000000000000000}"; exit 0; fi\necho called >> '${quotaLog}'\nif [ -n "$TEST_QUOTA_ID" ] && [ "$LLM_USAGE_CLAUDE_FINGERPRINT" != "$TEST_QUOTA_ID" ]; then echo 'Claude Code login changed during refresh' >&2; exit 1; fi\nif [ "$TEST_DELAY" = "1" ]; then sleep 5; fi\nprintf '%s' ${JSON.stringify(output)}\nexit ${status}\n`, { mode: 0o700 });
  return { root, helper, identityLog, quotaLog, cacheDirectory: path.join(root, "cache"), cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
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

test("identity failures are backed off before repeated helper invocation", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root, TEST_ID_FAIL: "1" } };
    await assert.rejects(fetchClaudeUsage(args), /identity failed/);
    await assert.rejects(fetchClaudeUsage(args), /identity failed/);
    assert.equal((fs.readFileSync(f.identityLog, "utf8").match(/called/g) || []).length, 1);
  } finally { f.cleanup(); }
});

test("concurrent callers share identity failure across lock contenders", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root, TEST_ID_FAIL: "1" } };
    const results = await Promise.allSettled(Array.from({ length: 8 }, () => fetchClaudeUsage(args)));
    assert.equal(results.filter(result => result.status === "rejected").length, 8);
    assert.equal((fs.readFileSync(f.identityLog, "utf8").match(/called/g) || []).length, 1);
  } finally { f.cleanup(); }
});

test("independent processes coordinate identity failure before touching Keychain", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root, TEST_ID_FAIL: "1" } };
    const script = `import { fetchClaudeUsage } from ${JSON.stringify(new URL("./claude.js", import.meta.url).href)};
      try { await fetchClaudeUsage(JSON.parse(process.argv[1])); process.exit(2); }
      catch (error) { if (!error.message.includes('identity failed')) throw error; }`;
    await Promise.all(Array.from({ length: 8 }, () => execFileAsync(process.execPath,
      ["--input-type=module", "-e", script, JSON.stringify(args)], { timeout: 10_000 })));
    assert.equal(fs.readFileSync(f.identityLog, "utf8").trim().split("\n").length, 1);
    assert.equal(fs.existsSync(f.quotaLog), false);
    assert.equal(fs.readdirSync(f.cacheDirectory).some(name => name.endsWith(".lock")), false);
  } finally { f.cleanup(); }
});

test("quota failures are backed off while credential identity is still checked", async () => {
  const f = fixture("not-json");
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root } };
    await assert.rejects(fetchClaudeUsage(args), /invalid JSON/);
    await assert.rejects(fetchClaudeUsage(args), /invalid JSON/);
    assert.equal(fs.readFileSync(f.identityLog, "utf8").trim().split("\n").length, 2);
    assert.equal(fs.readFileSync(f.quotaLog, "utf8").trim().split("\n").length, 1);
  } finally { f.cleanup(); }
});

test("identity failure backoff expires and can recover", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    let clock = Date.now();
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root, TEST_ID_FAIL: "1" }, now: () => clock };
    await assert.rejects(fetchClaudeUsage(args), /identity failed/);
    args.env.TEST_ID_FAIL = "0";
    await assert.rejects(fetchClaudeUsage(args), /identity failed/);
    clock += 60_001;
    assert.deepEqual(await fetchClaudeUsage(args), payload);
    assert.equal(fs.readFileSync(f.identityLog, "utf8").trim().split("\n").length, 2);
  } finally { f.cleanup(); }
});

test("quota helper is bound to the fingerprint observed before the cache lookup", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory,
      env: { ...process.env, HOME: f.root, TEST_ID: "1".repeat(64), TEST_QUOTA_ID: "2".repeat(64) } };
    await assert.rejects(fetchClaudeUsage(args), /login changed/);
    assert.equal(fs.readdirSync(f.cacheDirectory).some(name => {
      return name.endsWith(".json") && JSON.parse(fs.readFileSync(path.join(f.cacheDirectory, name))).result;
    }), false);
    args.env.TEST_ID = "2".repeat(64);
    assert.deepEqual(await fetchClaudeUsage(args), payload);
  } finally { f.cleanup(); }
});

test("successful quota cache still checks identity on every call", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root } };
    await fetchClaudeUsage(args);
    await fetchClaudeUsage(args);
    assert.equal((fs.readFileSync(f.identityLog, "utf8").match(/called/g) || []).length, 2);
  } finally { f.cleanup(); }
});
