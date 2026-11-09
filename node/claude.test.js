import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import crypto from "node:crypto";
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
  fs.writeFileSync(helper, `#!/bin/sh\nif [ "$1" = "--claude-usage-identity" ]; then echo called >> '${identityLog}'; if [ "$TEST_ID_FAIL" = "1" ]; then echo identity failed >&2; exit 1; fi; if [ -n "$TEST_ID_DELAY" ]; then /bin/sleep "$TEST_ID_DELAY"; fi; printf '{"fingerprint":"%s"}' "\${TEST_ID:-0000000000000000000000000000000000000000000000000000000000000000}"; exit 0; fi\necho called >> '${quotaLog}'\nif [ -n "$TEST_ENV_LOG" ]; then printf '%s %s\\n' "$LLM_USAGE_CLAUDE_TIMEOUT_MS" "$LLM_USAGE_CLAUDE_FINGERPRINT" >> "$TEST_ENV_LOG"; fi\nif [ -n "$TEST_TREE_DELAY" ]; then sleep 30 & echo $! > "$TEST_SLEEP_PID"; wait; fi\nif [ -n "$TEST_QUOTA_ID" ] && [ "$LLM_USAGE_CLAUDE_FINGERPRINT" != "$TEST_QUOTA_ID" ]; then echo 'Claude Code login changed during refresh' >&2; exit 1; fi\nif [ "$TEST_DELAY" = "1" ]; then sleep 5; fi\nif [ -n "$TEST_QUOTA_DELAY" ]; then /bin/sleep "$TEST_QUOTA_DELAY"; fi\nprintf '%s' ${JSON.stringify(output)}\nexit ${status}\n`, { mode: 0o700 });
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

test("successful quota cache still checks the reported identity on every call", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root } };
    await fetchClaudeUsage(args);
    await fetchClaudeUsage(args);
    assert.equal((fs.readFileSync(f.identityLog, "utf8").match(/called/g) || []).length, 2);
    assert.equal((fs.readFileSync(f.quotaLog, "utf8").match(/called/g) || []).length, 1);
  } finally { f.cleanup(); }
});

test("invalid quota cache timestamps are ignored", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root } };
    await fetchClaudeUsage(args);
    const cacheFile = fs.readdirSync(f.cacheDirectory).find(name => name.endsWith(".json") && !name.endsWith(".identity.json"));
    const cache = JSON.parse(fs.readFileSync(path.join(f.cacheDirectory, cacheFile), "utf8"));
    cache.savedAt = Infinity;
    fs.writeFileSync(path.join(f.cacheDirectory, cacheFile), JSON.stringify(cache));
    await fetchClaudeUsage(args);
    assert.equal((fs.readFileSync(f.quotaLog, "utf8").match(/called/g) || []).length, 2);
  } finally { f.cleanup(); }
});

test("malformed cached quota results are refetched, never returned", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root } };
    await fetchClaudeUsage(args);
    const file = fs.readdirSync(f.cacheDirectory).find(name => name.endsWith(".json") && !name.endsWith(".identity.json"));
    const cache = JSON.parse(fs.readFileSync(path.join(f.cacheDirectory, file), "utf8"));
    cache.result = { claude: [] };
    fs.writeFileSync(path.join(f.cacheDirectory, file), JSON.stringify(cache));
    assert.deepEqual(await fetchClaudeUsage(args), payload);
    assert.equal(fs.readFileSync(f.quotaLog, "utf8").trim().split("\n").length, 2);
  } finally { f.cleanup(); }
});

test("damaged negative cache cannot impose unbounded backoff", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const env = { ...process.env, HOME: f.root };
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env };
    await fetchClaudeUsage(args);
    const scope = crypto.createHash("sha256").update(`claude-cli-v2\0${process.getuid?.() ?? "user"}\0default\0${path.join(f.root, ".claude")}`).digest("hex");
    const quotaKey = crypto.createHash("sha256").update(`${scope}\0${"0".repeat(64)}`).digest("hex");
    assert.ok(fs.existsSync(path.join(f.cacheDirectory, `${quotaKey}.json`)), "fixture must target the production scope");
    fs.writeFileSync(path.join(f.cacheDirectory, `${scope}.identity.json`), JSON.stringify({ savedAt: Date.now(), retryAt: Infinity, error: "broken" }));
    assert.deepEqual(await fetchClaudeUsage(args), payload);
    assert.equal(fs.readFileSync(f.identityLog, "utf8").trim().split("\n").length, 2);
  } finally { f.cleanup(); }
});

test("stale and legacy-scoped identity failures do not block requests", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    fs.mkdirSync(f.cacheDirectory, { recursive: true });
    const currentScope = crypto.createHash("sha256").update(`claude-cli-v2\0${process.getuid?.() ?? "user"}\0default\0${path.join(f.root, ".claude")}`).digest("hex");
    fs.writeFileSync(path.join(f.cacheDirectory, `${currentScope}.identity.json`), JSON.stringify({ savedAt: 0, retryAt: 60_000, error: "stale" }));
    const legacyScope = crypto.createHash("sha256").update(`${process.getuid?.() ?? "user"}\0default\0${path.join(f.root, ".claude")}`).digest("hex");
    fs.writeFileSync(path.join(f.cacheDirectory, `${legacyScope}.identity.json`), JSON.stringify({ savedAt: Date.now(), retryAt: Date.now() + 60_000, error: "legacy" }));
    assert.deepEqual(await fetchClaudeUsage({ executable: f.helper, cacheDirectory: f.cacheDirectory,
      env: { ...process.env, HOME: f.root } }), payload);
    assert.equal(fs.readFileSync(f.identityLog, "utf8").trim().split("\n").length, 1);
  } finally { f.cleanup(); }
});

test("independent successful requests coalesce quota work after checking identity", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root, TEST_DELAY: "1" } };
    const script = `import { fetchClaudeUsage } from ${JSON.stringify(new URL("./claude.js", import.meta.url).href)}; await fetchClaudeUsage(JSON.parse(process.argv[1]));`;
    await Promise.all(Array.from({ length: 3 }, () => execFileAsync(process.execPath,
      ["--input-type=module", "-e", script, JSON.stringify(args)], { timeout: 10_000 })));
    assert.equal(fs.readFileSync(f.identityLog, "utf8").trim().split("\n").length, 3);
    assert.equal(fs.readFileSync(f.quotaLog, "utf8").trim().split("\n").length, 1);
  } finally { f.cleanup(); }
});

test("quota child receives bounded remaining allowance and expected fingerprint", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const log = path.join(f.root, "env.log"), fingerprint = "a".repeat(64);
    await fetchClaudeUsage({ executable: f.helper, cacheDirectory: f.cacheDirectory,
      env: { ...process.env, HOME: f.root, TEST_ID: fingerprint, TEST_ENV_LOG: log }, helperTimeoutMs: 18_000 });
    const [allowance, observed] = fs.readFileSync(log, "utf8").trim().split(" ");
    assert.ok(Number(allowance) > 0 && Number(allowance) <= 18_000);
    assert.equal(observed, fingerprint);
  } finally { f.cleanup(); }
});

test("timeout terminates fixture helper and its sleep descendant", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const pidFile = path.join(f.root, "sleep.pid");
    await assert.rejects(fetchClaudeUsage({ executable: f.helper, cacheDirectory: f.cacheDirectory,
      env: { ...process.env, HOME: f.root, TEST_TREE_DELAY: "1", TEST_SLEEP_PID: pidFile }, helperTimeoutMs: 500 }), /timed out/);
    const pid = Number(fs.readFileSync(pidFile, "utf8"));
    await new Promise(resolve => setTimeout(resolve, 50));
    assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
  } finally { f.cleanup(); }
});

test("short-budget waiter cannot poison the successful owner's identity cache", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root } };
    const owner = fetchClaudeUsage({ ...args, env: { ...args.env, TEST_QUOTA_DELAY: "0.25" } });
    const startedBy = Date.now() + 3_000;
    while (!fs.existsSync(f.quotaLog) && Date.now() < startedBy) await new Promise(resolve => setTimeout(resolve, 5));
    assert.ok(fs.existsSync(f.quotaLog), "owner must start its quota request");
    await assert.rejects(fetchClaudeUsage({ ...args, totalTimeoutMs: 450,
      env: { ...args.env, TEST_ID_DELAY: "1" } }), /timed out/);
    assert.deepEqual(await owner, payload);
    assert.equal(fs.readdirSync(f.cacheDirectory).some(name => name.endsWith(".identity.json")), false);
    assert.deepEqual(await fetchClaudeUsage(args), payload);
    assert.equal(fs.readFileSync(f.quotaLog, "utf8").trim().split("\n").length, 1);
  } finally { f.cleanup(); }
});

test("caller-local quota timeout does not impose shared failure backoff", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const args = { executable: f.helper, cacheDirectory: f.cacheDirectory, env: { ...process.env, HOME: f.root } };
    await assert.rejects(fetchClaudeUsage({ ...args, totalTimeoutMs: 800,
      env: { ...args.env, TEST_QUOTA_DELAY: "2" } }), /timed out/);
    assert.deepEqual(await fetchClaudeUsage(args), payload);
    assert.equal(fs.readFileSync(f.quotaLog, "utf8").trim().split("\n").length, 2);
  } finally { f.cleanup(); }
});

test("timeout allows helper cancellation cleanup before hard escalation", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    const cleaned = path.join(f.root, "cleaned");
    fs.writeFileSync(f.helper, `#!/bin/sh\nif [ "$1" = "--claude-usage-identity" ]; then printf '{"fingerprint":"${"0".repeat(64)}"}'; exit 0; fi\ntrap '/bin/sleep 0.5; /usr/bin/touch "$TEST_CLEANED"; exit 1' TERM\n/bin/sleep 30 &\nwait\n`);
    await assert.rejects(fetchClaudeUsage({ executable: f.helper, cacheDirectory: f.cacheDirectory,
      env: { ...process.env, HOME: f.root, TEST_CLEANED: cleaned }, helperTimeoutMs: 750 }), /timed out/);
    assert.ok(fs.existsSync(cleaned), "helper must finish its descendant cleanup");
  } finally { f.cleanup(); }
});

test("lock wait uses the monotonic total deadline", async () => {
  const f = fixture(JSON.stringify(payload));
  try {
    fs.mkdirSync(f.cacheDirectory, { recursive: true });
    const scope = crypto.createHash("sha256").update(`claude-cli-v2\0${process.getuid?.() ?? "user"}\0default\0${path.join(f.root, ".claude")}`).digest("hex");
    const lock = path.join(f.cacheDirectory, `${scope}.lock`);
    fs.writeFileSync(lock, "99999999");
    const started = Date.now();
    await assert.rejects(fetchClaudeUsage({ executable: f.helper, cacheDirectory: f.cacheDirectory,
      env: { ...process.env, HOME: f.root }, now: () => 1, totalTimeoutMs: 80 }), /already running/);
    assert.ok(Date.now() - started < 500);
  } finally { f.cleanup(); }
});
