import { AuthStorage } from "@mariozechner/pi-coding-agent";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import os from "node:os";
import fs from "node:fs";

const PROVIDER = "openai-codex";
const TIMEOUT_MS = 20_000;

function jwtAccountId(token) {
  try {
    const part = token.split(".")[1];
    const json = Buffer.from(part.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString();
    const id = JSON.parse(json)["https://api.openai.com/auth"]?.chatgpt_account_id;
    return typeof id === "string" && id ? id : null;
  } catch { return null; }
}

export async function piTokens(authPath) {
  const storage = AuthStorage.create(authPath || undefined);
  const credential = storage.get(PROVIDER);
  if (!credential || credential.type !== "oauth") return null;
  const accessToken = await storage.getApiKey(PROVIDER);
  storage.reload();
  const refreshed = storage.get(PROVIDER);
  const accountId = refreshed?.type === "oauth" && refreshed.accountId || jwtAccountId(accessToken);
  if (!accessToken || !accountId) throw new Error("Pi Codex OAuth credential is incomplete.");
  return { accessToken, chatgptAccountId: accountId, chatgptPlanType: null };
}

export function classifyWindows(primary, secondary) {
  const candidates = [primary, secondary].filter(Boolean);
  let session = candidates.find(w => (w.windowDurationMins ?? Infinity) < 1440);
  let weekly = candidates.find(w => (w.windowDurationMins ?? 0) >= 1440);
  // Compatibility with app-server versions that omit windowDurationMins.
  if (!session && !weekly) {
    if (primary && secondary) [session, weekly] = [primary, secondary];
    else {
      const only = primary || secondary;
      if (only) {
        const horizon = only.resetsAt == null ? 0 : only.resetsAt * 1000 - Date.now();
        if (horizon > 86400000) weekly = only; else session = only;
      }
    }
  } else {
    const unknown = candidates.filter(w => w.windowDurationMins == null);
    if (!session) session = unknown[0];
    if (!weekly) weekly = unknown.find(w => w !== session);
  }
  return { session: session ?? null, weekly: weekly ?? null };
}

export function makeUsage(response, source = "Pi auth", updatedAt = new Date()) {
  const limits = response?.rateLimits ?? {};
  const windows = classifyWindows(limits.primary, limits.secondary);
  if (!windows.session && !windows.weekly) throw new Error("Codex returned no usage windows.");
  const window = w => {
    if (!w) return null;
    if (!Number.isFinite(w.usedPercent)) throw new Error("Codex returned an invalid usage percentage.");
    const resetAt = w.resetsAt == null ? null : Number(w.resetsAt);
    if (resetAt != null && !Number.isFinite(resetAt)) throw new Error("Codex returned an invalid reset timestamp.");
    return { usedPercent: w.usedPercent, remainingPercent: Math.max(0, 100 - w.usedPercent),
      resetAt: resetAt == null ? null : new Date(resetAt * 1000).toISOString() };
  };
  const summary = response.rateLimitResetCredits;
  const credits = summary && (summary.credits || []).map(c => ({
    id: c.id, resetType: c.resetType ?? null, status: c.status ?? null,
    grantedAt: c.grantedAt == null ? null : new Date(c.grantedAt * 1000).toISOString(),
    expiresAt: c.expiresAt == null ? null : new Date(c.expiresAt * 1000).toISOString(),
    title: c.title ?? null, description: c.description ?? null
  }));
  const balance = limits.credits?.balance == null ? null : Number(limits.credits.balance);
  if (balance != null && !Number.isFinite(balance)) throw new Error("Codex returned an invalid credit balance.");
  return { codex: {
    session: window(windows.session), weekly: window(windows.weekly),
    creditsRemaining: balance,
    resetCredits: summary ? { availableCount: Math.max(0, summary.availableCount ?? 0), credits: credits ?? [] } : null,
    source, updatedAt: updatedAt.toISOString()
  }};
}

function candidates() {
  const env = process.env;
  const home = os.homedir();
  const paths = [env.LLM_BAR_CODEX_PATH, `${home}/Applications/Assistants/codex/codex`, `${home}/bin/codex`];
  for (const dir of (env.PATH || "").split(":")) if (dir) paths.push(`${dir}/codex`);
  return [...new Set(paths.filter(Boolean).map(p => p.replace(/^~/, home)))];
}
export function resolveCodex() { return candidates().find(p => { try { return fs.statSync(p).isFile() && (fs.statSync(p).mode & 0o111); } catch { return false; } }); }

class RPC {
  constructor(path, tokens) {
    this.child = spawn(path, ["-s", "read-only", "-a", "untrusted", "app-server"], { stdio: ["pipe", "pipe", "pipe"] });
    this.lines = createInterface({ input: this.child.stdout });
    this.id = 0;
    this.tokens = tokens;
    this.pending = new Map();
    this.stderr = "";
    this.child.stderr.on("data", chunk => { this.stderr = (this.stderr + chunk).slice(-2000); });
    this.lines.on("line", line => this.onLine(line));
    this.child.on("error", error => this.failAll(new Error(`Could not start Codex app-server: ${error.message}`)));
    this.child.on("close", () => {
      const detail = this.stderr.trim().replace(/Bearer\s+\S+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, "[redacted]");
      this.failAll(new Error(detail ? `Codex app-server closed: ${detail}` : "Codex app-server closed unexpectedly."));
    });
  }
  failAll(error) {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
  onLine(line) {
    let msg; try { msg = JSON.parse(line); } catch { return; }
    if (msg.method && msg.id != null) { void this.serverRequest(msg); return; }
    const pending = this.pending.get(msg.id);
    if (!pending) return;
    this.pending.delete(msg.id);
    if (msg.error) pending.reject(new Error(msg.error.message || "Codex RPC request failed."));
    else pending.resolve(msg.result);
  }
  request(method, params = {}) {
    const id = ++this.id;
    const result = new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.child.stdin.write(JSON.stringify({ id, method, params }) + "\n", error => {
      if (!error) return;
      const pending = this.pending.get(id);
      this.pending.delete(id);
      pending?.reject(new Error(`Could not write Codex RPC request: ${error.message}`));
    });
    return result;
  }
  async serverRequest(msg) {
    if (msg.method !== "account/chatgptAuthTokens/refresh") {
      this.child.stdin.write(JSON.stringify({ id: msg.id, error: { code: -32601, message: "Unsupported request" } }) + "\n"); return;
    }
    try { this.child.stdin.write(JSON.stringify({ id: msg.id, result: await this.tokens() }) + "\n"); }
    catch { this.child.stdin.write(JSON.stringify({ id: msg.id, error: { code: -32603, message: "External authentication refresh failed" } }) + "\n"); }
  }
  close() { this.lines.close(); this.child.stdin.destroy(); if (!this.child.killed) { this.child.kill("SIGTERM"); setTimeout(() => this.child.kill("SIGKILL"), 250).unref(); } }
}

async function withTimeout(promise, ms = TIMEOUT_MS) {
  let timer; try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Codex request timed out.")), ms); })]); }
  finally { clearTimeout(timer); }
}
export async function fetchUsage({ authPath = process.env.LLM_BAR_PI_AUTH_PATH, timeoutMs = TIMEOUT_MS } = {}) {
  const path = resolveCodex(); if (!path) throw new Error(`Codex executable not found. Checked: ${candidates().join(", ")}`);
  const initial = await piTokens(authPath); if (!initial) throw new Error("Pi-managed openai-codex OAuth is not available.");
  const rpc = new RPC(path, async () => piTokens(authPath));
  try { return makeUsage(await withTimeout((async () => { await rpc.request("initialize", { clientInfo: { name: "llm-usage", version: "1.0.0" }, capabilities: { experimentalApi: true } }); rpc.child.stdin.write(JSON.stringify({ method: "initialized", params: {} }) + "\n"); await rpc.request("account/login/start", { type: "chatgptAuthTokens", ...initial, chatgptPlanType: null }); return rpc.request("account/rateLimits/read"); })(), timeoutMs)); }
  finally { rpc.close(); }
}
export async function consumeCredit({ creditId, idempotencyKey, authPath = process.env.LLM_BAR_PI_AUTH_PATH, timeoutMs = TIMEOUT_MS }) {
  if (!creditId || !idempotencyKey) throw new Error("--credit-id and --idempotency-key are required.");
  const path = resolveCodex(); if (!path) throw new Error("Codex executable not found.");
  const initial = await piTokens(authPath); if (!initial) throw new Error("Pi-managed openai-codex OAuth is not available.");
  const rpc = new RPC(path, async () => piTokens(authPath));
  try { return await withTimeout((async () => { await rpc.request("initialize", { clientInfo: { name: "llm-usage", version: "1.0.0" }, capabilities: { experimentalApi: true } }); rpc.child.stdin.write(JSON.stringify({ method: "initialized", params: {} }) + "\n"); await rpc.request("account/login/start", { type: "chatgptAuthTokens", ...initial, chatgptPlanType: null }); return rpc.request("account/rateLimitResetCredit/consume", { creditId, idempotencyKey }); })(), timeoutMs); }
  finally { rpc.close(); }
}
