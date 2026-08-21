import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { classifyWindows, diagnose, fetchAllManagedUsage, fetchUsage, makeUsage } from "./core.js";
import { parseArgs } from "./cli.js";

test("classifies duration windows and preserves primary/secondary fallback", () => {
  const primary = { usedPercent: 10, windowDurationMins: 300, resetsAt: 1 };
  const secondary = { usedPercent: 20, windowDurationMins: 10080, resetsAt: 2 };
  assert.deepEqual(classifyWindows(primary, secondary), { session: primary, weekly: secondary });
  assert.deepEqual(classifyWindows({ usedPercent: 1 }, { usedPercent: 2 }), { session: { usedPercent: 1 }, weekly: { usedPercent: 2 } });
});

test("usage JSON keeps compatibility keys and exposes credit details", () => {
  const output = makeUsage({ rateLimits: { primary: { usedPercent: 25, resetsAt: 100, windowDurationMins: 300 }, credits: { balance: "3" } }, rateLimitResetCredits: { availableCount: 1, credits: [{ id: "c1", status: "available", expiresAt: 200, title: "Trial", description: "desc" }] } }, "Pi auth", new Date(0));
  assert.deepEqual(Object.keys(output.codex).sort(), ["creditsRemaining", "resetCredits", "session", "source", "updatedAt", "weekly"]);
  assert.equal(output.codex.resetCredits.credits[0].id, "c1");
  assert.equal(output.codex.session.remainingPercent, 75);
});

test("managed usage adds only account metadata to the compatible JSON shape", () => {
  const output = makeUsage(
    { rateLimits: { primary: { usedPercent: 5, resetsAt: 100, windowDurationMins: 300 } } },
    "Managed Codex",
    new Date(0),
    { email: "managed@example.com", planType: "pro" }
  );
  assert.equal(output.codex.source, "Managed Codex");
  assert.equal(output.codex.email, "managed@example.com");
  assert.equal(output.codex.planType, "pro");
  assert.equal(output.codex.session.remainingPercent, 95);
});

test("managed fetch uses native app-server auth in the supplied CODEX_HOME", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "llm-usage-node-test-"));
  const executable = path.join(root, "fake-codex.sh");
  const script = path.join(root, "fake-codex.mjs");
  const log = path.join(root, "rpc.log");
  const argsLog = path.join(root, "args.log");
  fs.writeFileSync(script, `import fs from "node:fs";
import readline from "node:readline";
const log = ${JSON.stringify(log)};
fs.writeFileSync(${JSON.stringify(argsLog)}, JSON.stringify(process.argv.slice(2)));
const home = process.env.CODEX_HOME;
const lines = readline.createInterface({ input: process.stdin });
lines.on("line", line => {
  const message = JSON.parse(line);
  if (message.id == null) return;
  fs.appendFileSync(log, JSON.stringify({ method: message.method, home }) + "\\n");
  let result = {};
  if (message.method === "initialize") result = {};
  else if (message.method === "account/read") result = { account: { type: "chatgpt", email: "managed@example.com", planType: "pro" }, requiresOpenaiAuth: false };
  else if (message.method === "account/rateLimits/read") result = { rateLimits: { primary: { usedPercent: 10, windowDurationMins: 300, resetsAt: 200 }, secondary: { usedPercent: 20, windowDurationMins: 10080, resetsAt: 300 } } };
  process.stdout.write(JSON.stringify({ id: message.id, result }) + "\\n");
});
`);
  fs.writeFileSync(executable, `#!/bin/sh
exec ${JSON.stringify(process.execPath)} ${JSON.stringify(script)} "$@"
`);
  fs.chmodSync(executable, 0o700);
  const previous = process.env.LLM_BAR_CODEX_PATH;
  process.env.LLM_BAR_CODEX_PATH = executable;
  try {
    const output = await fetchUsage({ codexHome: path.join(root, "managed-home"), timeoutMs: 2_000 });
    assert.equal(output.codex.source, "Managed Codex");
    assert.equal(output.codex.email, "managed@example.com");
    assert.equal(output.codex.session.remainingPercent, 90);
    assert.deepEqual(JSON.parse(fs.readFileSync(argsLog, "utf8")), ["-s", "read-only", "-a", "never", "app-server"]);
    const calls = fs.readFileSync(log, "utf8").trim().split("\n").map(line => JSON.parse(line));
    assert.deepEqual(calls.map(call => call.method), ["initialize", "account/read", "account/rateLimits/read"]);
    assert.ok(calls.every(call => call.home.endsWith("managed-home")));
  } finally {
    if (previous === undefined) delete process.env.LLM_BAR_CODEX_PATH;
    else process.env.LLM_BAR_CODEX_PATH = previous;
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("managed home rejects API-key auth instead of treating it as OAuth", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "llm-usage-node-auth-test-"));
  const home = path.join(root, "managed-home");
  fs.mkdirSync(home, { recursive: true });
  fs.writeFileSync(path.join(home, "auth.json"), JSON.stringify({ OPENAI_API_KEY: "sk-test" }));
  const previous = process.env.LLM_BAR_CODEX_PATH;
  process.env.LLM_BAR_CODEX_PATH = "/bin/sh";
  try {
    await assert.rejects(
      fetchUsage({ codexHome: home }),
      /ChatGPT OAuth credentials|API key/
    );
  } finally {
    if (previous === undefined) delete process.env.LLM_BAR_CODEX_PATH;
    else process.env.LLM_BAR_CODEX_PATH = previous;
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("diagnose reports unavailable Pi auth for a managed-only installation", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "llm-usage-node-diagnose-test-"));
  const configPath = path.join(root, "config.json");
  fs.writeFileSync(configPath, JSON.stringify({
    codexManagedAccounts: [{ id: "11111111-1111-4111-8111-111111111111", label: "Work" }]
  }));
  try {
    const result = diagnose({ configPath, authPath: path.join(root, "missing-pi-auth.json") });
    assert.equal(result.codex.managedAccounts, 1);
    assert.equal(result.codex.piAuth, "unavailable");
    assert.equal(result.codex.source, "Managed Codex");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("all-managed keeps the configured primary explicit and chooses the first managed profile when absent", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "llm-usage-node-primary-test-"));
  const executable = path.join(root, "fake-codex.sh");
  const script = path.join(root, "fake-codex.mjs");
  fs.writeFileSync(script, `import readline from "node:readline";
const lines = readline.createInterface({ input: process.stdin });
lines.on("line", line => {
  const message = JSON.parse(line);
  if (message.id == null) return;
  let result = {};
  if (message.method === "account/read") result = { account: { email: "managed@example.com", planType: "pro" } };
  if (message.method === "account/rateLimits/read") result = { rateLimits: { primary: { usedPercent: 10, windowDurationMins: 300, resetsAt: 200 } } };
  process.stdout.write(JSON.stringify({ id: message.id, result }) + "\\n");
});
`);
  fs.writeFileSync(executable, `#!/bin/sh
exec ${JSON.stringify(process.execPath)} ${JSON.stringify(script)}
`);
  fs.chmodSync(executable, 0o700);
  const first = "11111111-1111-4111-8111-111111111111";
  const second = "22222222-2222-4222-8222-222222222222";
  const configPath = path.join(root, "config.json");
  fs.writeFileSync(configPath, JSON.stringify({
    codexManagedAccounts: [{ id: first, label: "First" }, { id: second, label: "Second" }],
    codexPrimaryAccountID: second
  }));
  const previousExecutable = process.env.LLM_BAR_CODEX_PATH;
  const previousPiAuth = process.env.LLM_BAR_PI_AUTH_PATH;
  process.env.LLM_BAR_CODEX_PATH = executable;
  process.env.LLM_BAR_PI_AUTH_PATH = path.join(root, "missing-pi-auth.json");
  try {
    const selected = await fetchAllManagedUsage({ configPath, authPath: process.env.LLM_BAR_PI_AUTH_PATH, timeoutMs: 2_000 });
    assert.equal(selected.codex.source, "Managed Codex");
    assert.equal(selected.codexAccounts.find(account => account.id === second)?.usage?.source, "Managed Codex");

    fs.writeFileSync(configPath, JSON.stringify({
      codexManagedAccounts: [{ id: first, label: "First" }, { id: second, label: "Second" }],
      codexPrimaryAccountID: null
    }));
    const firstManagedSelected = await fetchAllManagedUsage({ configPath, timeoutMs: 2_000 });
    assert.equal(firstManagedSelected.codex.source, "Managed Codex");
    assert.equal(firstManagedSelected.codexAccounts.find(account => account.id === first)?.usage?.source, "Managed Codex");
  } finally {
    if (previousExecutable === undefined) delete process.env.LLM_BAR_CODEX_PATH;
    else process.env.LLM_BAR_CODEX_PATH = previousExecutable;
    if (previousPiAuth === undefined) delete process.env.LLM_BAR_PI_AUTH_PATH;
    else process.env.LLM_BAR_PI_AUTH_PATH = previousPiAuth;
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("parses managed Codex home without changing the compatibility command", () => {
  assert.deepEqual(parseArgs(["codex", "--json"]), { command: "codex", json: true });
  assert.deepEqual(parseArgs(["codex", "--all-managed", "--json"]), { command: "codex", allManaged: true, json: true });
  assert.deepEqual(parseArgs(["codex", "--codex-home", "/tmp/account", "--json"]), { command: "codex", codexHome: "/tmp/account", json: true });
  assert.deepEqual(parseArgs(["codex", "reset", "consume", "--credit-id", "c", "--idempotency-key", "k", "--json"]), { command: "consume", creditId: "c", idempotencyKey: "k", json: true });
  assert.deepEqual(parseArgs(["codex", "reset", "consume", "--credit-id", "c", "--idempotency-key", "k", "--codex-home", "/tmp/account", "--json"]), { command: "consume", creditId: "c", idempotencyKey: "k", codexHome: "/tmp/account", json: true });
});

test("all-managed returns a managed-account prompt without reading Pi auth when unconfigured", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "llm-usage-node-empty-managed-test-"));
  const configPath = path.join(root, "config.json");
  fs.writeFileSync(configPath, JSON.stringify({ codexManagedAccounts: [] }));
  try {
    const result = await fetchAllManagedUsage({ configPath, timeoutMs: 2_000 });
    assert.equal(result.codex, null);
    assert.deepEqual(result.codexAccounts, []);
    assert.match(result.error, /No managed Codex accounts configured/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
