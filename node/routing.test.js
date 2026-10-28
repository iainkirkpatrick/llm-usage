import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fetchAllManagedUsage } from "./core.js";

const a = "11111111-1111-4111-8111-111111111111";
const b = "22222222-2222-4222-8222-222222222222";
const c = "33333333-3333-4333-8333-333333333333";
function pi(accountId) {
  return { "openai-codex": { type: "oauth", access: "fixture-access", refresh: "fixture-refresh", accountId, expires: Date.now() + 3600_000 } };
}
function fixture({ profiles, handoff = null, primary = profiles[0].id, piAccount, switchOnNative = null }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "llm-usage-routing-"));
  const authPath = path.join(root, "pi-auth.json");
  const configPath = path.join(root, "config.json");
  const calls = path.join(root, "calls.jsonl");
  const script = path.join(root, "codex.mjs");
  const executable = path.join(root, "codex");
  fs.writeFileSync(configPath, JSON.stringify({ codexManagedAccounts: profiles, codexPrimaryAccountID: primary, codexPiHandoffAccountID: handoff }));
  if (piAccount) fs.writeFileSync(authPath, JSON.stringify(pi(piAccount)));
  fs.writeFileSync(script, `import readline from 'node:readline'; import fs from 'node:fs';
const home=process.env.CODEX_HOME || null;
fs.appendFileSync(${JSON.stringify(calls)}, JSON.stringify({home})+'\\n');
readline.createInterface({input:process.stdin}).on('line',line=>{
 const m=JSON.parse(line); if(m.id==null)return;
 if(m.method==='account/read' && home === ${JSON.stringify(switchOnNative ? path.join(root, "codex-accounts", switchOnNative) : null)}) {
   fs.writeFileSync(${JSON.stringify(authPath)}, ${JSON.stringify(JSON.stringify(pi("account-b")))});
 }
 let result={};
 if(m.method==='account/read') result={account:{email:'fixture@example.test'}};
 if(m.method==='account/rateLimits/read') result={rateLimits:{primary:{usedPercent:12,windowDurationMins:300}}};
 process.stdout.write(JSON.stringify({id:m.id,result})+'\\n');
});`);
  fs.writeFileSync(executable, `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(script)}\n`, { mode: 0o700 });
  const old = { executable: process.env.LLM_BAR_CODEX_PATH, home: process.env.CODEX_HOME };
  process.env.LLM_BAR_CODEX_PATH = executable;
  delete process.env.CODEX_HOME;
  return {
    root, authPath, configPath,
    native(id, account) {
      const home = path.join(root, "codex-accounts", id);
      fs.mkdirSync(home, { recursive: true });
      const file = path.join(home, "auth.json");
      fs.writeFileSync(file, JSON.stringify({ OPENAI_API_KEY: null, tokens: { access_token: "fixture", refresh_token: "fixture", account_id: account } }));
      return file;
    },
    calls() { return fs.existsSync(calls) ? fs.readFileSync(calls, "utf8").trim().split("\n").map(JSON.parse) : []; },
    fetch() { return fetchAllManagedUsage({ configPath, authPath, timeoutMs: 2000 }); },
    close() {
      if (old.executable === undefined) delete process.env.LLM_BAR_CODEX_PATH; else process.env.LLM_BAR_CODEX_PATH = old.executable;
      if (old.home === undefined) delete process.env.CODEX_HOME; else process.env.CODEX_HOME = old.home;
      fs.rmSync(root, { recursive: true, force: true });
    }
  };
}

test("external switch uses Pi despite duplicate native credential; config and native bytes are untouched", async () => {
  const f = fixture({ profiles: [{ id: a, accountID: "account-a" }, { id: b, accountID: "account-b" }], handoff: a, piAccount: "account-b" });
  try {
    const file = f.native(b, "account-b");
    const nativeBefore = fs.readFileSync(file);
    const configBefore = fs.readFileSync(f.configPath);
    const result = await f.fetch();
    assert.equal(result.codex, null);
    assert.match(result.codexAccounts[0].error, /changed outside/);
    assert.equal(result.codexAccounts[1].usage.source, "Pi auth");
    assert.deepEqual(f.calls(), [{ home: null }]);
    assert.deepEqual(fs.readFileSync(file), nativeBefore);
    assert.deepEqual(fs.readFileSync(f.configPath), configBefore);
  } finally { f.close(); }
});

test("legacy native identity is resolved before choosing Pi or native auth", async () => {
  const f = fixture({ profiles: [{ id: b }], piAccount: "account-b" });
  try {
    f.native(b, "account-b");
    const result = await f.fetch();
    assert.equal(result.codex.source, "Pi auth");
    assert.deepEqual(f.calls(), [{ home: null }]);
  } finally { f.close(); }
});

test("Pi is reobserved after an earlier awaited native query", async () => {
  const f = fixture({ profiles: [{ id: a, accountID: "account-a" }, { id: b, accountID: "account-b" }], piAccount: "account-c", switchOnNative: a });
  try {
    f.native(a, "account-a"); f.native(b, "account-b");
    const result = await f.fetch();
    assert.equal(result.codexAccounts[0].usage.source, "Managed Codex");
    assert.equal(result.codexAccounts[1].usage.source, "Pi auth");
    assert.deepEqual(f.calls(), [{ home: path.join(f.root, "codex-accounts", a) }, { home: null }]);
  } finally { f.close(); }
});

test("malformed or conflicting Pi auth never launches possibly duplicated native homes", async () => {
  const f = fixture({ profiles: [{ id: a, accountID: "account-a" }, { id: b, accountID: "account-b" }] });
  try {
    f.native(a, "account-a"); f.native(b, "account-b");
    fs.writeFileSync(f.authPath, "{not-json");
    const malformed = await f.fetch();
    assert.ok(malformed.codexAccounts.every(x => !x.usage && /could not be verified/.test(x.error)));
    const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "account-a" } })).toString("base64url");
    const conflicting = pi("account-b"); conflicting["openai-codex"].access = `head.${payload}.signature`;
    fs.writeFileSync(f.authPath, JSON.stringify(conflicting));
    assert.ok((await f.fetch()).codexAccounts.every(x => !x.usage));
    assert.deepEqual(f.calls(), []);
  } finally { f.close(); }
});

test("missing or unknown Pi leaves independent native profiles usable", async () => {
  const f = fixture({ profiles: [{ id: a, accountID: "account-a" }, { id: b, accountID: "account-b" }], handoff: a, primary: b });
  try {
    f.native(b, "account-b");
    assert.equal((await f.fetch()).codex.source, "Managed Codex");
    fs.writeFileSync(f.authPath, JSON.stringify(pi("account-unknown")));
    assert.equal((await f.fetch()).codex.source, "Managed Codex");
  } finally { f.close(); }
});

test("ambiguous identities and native identity substitution are refused before launching", async () => {
  const f = fixture({ profiles: [{ id: a, accountID: "account-b" }, { id: b }, { id: c, accountID: "account-c" }], piAccount: "account-b" });
  try {
    f.native(a, "account-b"); f.native(b, "account-b"); f.native(c, "different-account");
    const result = await f.fetch();
    assert.match(result.codexAccounts[0].error, /multiple/);
    assert.match(result.codexAccounts[1].error, /multiple/);
    assert.match(result.codexAccounts[2].error, /different ChatGPT account/);
    assert.deepEqual(f.calls(), []);
  } finally { f.close(); }
});
