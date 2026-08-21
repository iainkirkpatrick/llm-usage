import { AuthStorage } from "@mariozechner/pi-coding-agent";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";

const PROVIDER = "openai-codex";
const TIMEOUT_MS = 20_000;

export function redactSensitive(text) {
  return String(text)
    .replace(/Bearer\s+\S+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, "[redacted]")
    .replace(/((?:access_token|refresh_token|id_token|token|code|password|secret)=)[^&\s]+/gi, "$1[redacted]");
}

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

function nativeAccountMetadata(accountResponse) {
  const account = accountResponse?.account;
  if (!account || typeof account !== "object") return { email: null, planType: null };
  const email = typeof account.email === "string" && account.email.trim() ? account.email.trim() : null;
  const planType = typeof account.planType === "string" && account.planType.trim() ? account.planType.trim() : null;
  return { email, planType };
}

export function makeUsage(response, source = "Pi auth", updatedAt = new Date(), identity = null) {
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

  const codex = {
    session: window(windows.session), weekly: window(windows.weekly),
    creditsRemaining: balance,
    resetCredits: summary ? { availableCount: Math.max(0, summary.availableCount ?? 0), credits: credits ?? [] } : null,
    source, updatedAt: updatedAt.toISOString()
  };
  // Keep the long-standing Pi-auth JSON keys unchanged when no identity is available. Managed
  // accounts add only profile metadata returned by account/read; no credential material is serialized.
  if (identity?.email) codex.email = identity.email;
  if (identity?.planType) codex.planType = identity.planType;
  return { codex };
}

function normalizeCodexHome(raw) {
  if (typeof raw !== "string" || !raw.trim()) throw new Error("A Codex home is required.");
  let value = raw.trim();
  if (value === "~") value = os.homedir();
  else if (value.startsWith("~/")) value = path.join(os.homedir(), value.slice(2));
  if (!path.isAbsolute(value)) throw new Error("Codex home must be an absolute path.");
  return path.resolve(value);
}

function lstatIfPresent(filePath) {
  try { return fs.lstatSync(filePath); }
  catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function validateNativeAuthFile(authPath) {
  const stat = lstatIfPresent(authPath);
  if (!stat) throw new Error("Managed Codex auth.json is missing.");
  if (stat.isSymbolicLink()) throw new Error("Managed Codex auth.json must not be a symbolic link.");
  if (!stat.isFile()) throw new Error("Managed Codex auth.json must be a regular file.");
  if (stat.size > 1_000_000) throw new Error("Managed Codex auth.json is too large.");

  let auth;
  try { auth = JSON.parse(fs.readFileSync(authPath, "utf8")); }
  catch { throw new Error("Managed Codex auth.json is not valid JSON."); }
  if (!auth || typeof auth !== "object" || Array.isArray(auth)) {
    throw new Error("Managed Codex auth.json must contain a JSON object.");
  }
  if (auth.type !== undefined && !["oauth", "chatgpt", "chatgptOAuth"].includes(auth.type)) {
    throw new Error("Managed Codex auth.json contains an unsupported authentication type.");
  }
  if (auth.auth_mode !== undefined && !["chatgpt", "oauth"].includes(String(auth.auth_mode).toLowerCase())) {
    throw new Error("Managed Codex auth.json contains an unsupported authentication mode.");
  }
  // `codex login` is the ChatGPT OAuth flow. Do not accidentally treat a native API-key file,
  // Pi's provider map, or a value of an unexpected type as a managed account credential.
  if (auth.OPENAI_API_KEY !== undefined && auth.OPENAI_API_KEY !== null) {
    throw new Error("Managed Codex auth.json must contain ChatGPT OAuth credentials, not an API key.");
  }
  if (!auth.tokens || typeof auth.tokens !== "object" || Array.isArray(auth.tokens) ||
      !nonEmptyString(auth.tokens.access_token) || !nonEmptyString(auth.tokens.refresh_token)) {
    throw new Error("Managed Codex auth.json does not contain a supported ChatGPT OAuth credential.");
  }
  if (auth.tokens.account_id !== undefined && !nonEmptyString(auth.tokens.account_id)) {
    throw new Error("Managed Codex auth.json contains an invalid account id.");
  }
}

function secureManagedHome(codexHome) {
  const home = normalizeCodexHome(codexHome);
  if (home === path.parse(home).root) throw new Error("Managed Codex home must not be the filesystem root.");

  const homeStat = lstatIfPresent(home);
  if (homeStat) {
    if (homeStat.isSymbolicLink()) throw new Error("Managed Codex home must not be a symbolic link.");
    if (!homeStat.isDirectory()) throw new Error("Managed Codex home must be a directory.");
  } else {
    // Explicit CLI paths may have ordinary system symlink ancestors (for example /var on macOS).
    // Only the managed home itself and its auth file are trust boundaries here.
    fs.mkdirSync(home, { recursive: true, mode: 0o700 });
  }

  const securedHome = lstatIfPresent(home);
  if (!securedHome || securedHome.isSymbolicLink() || !securedHome.isDirectory()) {
    throw new Error("Managed Codex home is not a secure directory.");
  }
  // Permission failures are security failures. Never continue and hope that the app checked it.
  fs.chmodSync(home, 0o700);
  const mode = lstatIfPresent(home)?.mode ?? 0;
  if ((mode & 0o777) !== 0o700) throw new Error("Managed Codex home could not be secured to mode 0700.");

  const authPath = path.join(home, "auth.json");
  const authStat = lstatIfPresent(authPath);
  if (authStat) {
    if (authStat.isSymbolicLink()) throw new Error("Managed Codex auth.json must not be a symbolic link.");
    if (!authStat.isFile()) throw new Error("Managed Codex auth.json must be a regular file.");
    fs.chmodSync(authPath, 0o600);
    const securedAuth = lstatIfPresent(authPath);
    if (!securedAuth || securedAuth.isSymbolicLink() || !securedAuth.isFile() ||
        (securedAuth.mode & 0o777) !== 0o600) {
      throw new Error("Managed Codex auth.json could not be secured to mode 0600.");
    }
    validateNativeAuthFile(authPath);
  }
  return home;
}

function candidates() {
  const env = process.env;
  const home = os.homedir();
  const paths = [env.LLM_BAR_CODEX_PATH, `${home}/Applications/Assistants/codex/codex`, `${home}/bin/codex`, "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"];
  for (const dir of (env.PATH || "").split(":")) if (dir) paths.push(`${dir}/codex`);
  return [...new Set(paths.filter(Boolean).map(p => p.replace(/^~/, home)))];
}
export function resolveCodex() { return candidates().find(p => { try { return fs.statSync(p).isFile() && (fs.statSync(p).mode & 0o111); } catch { return false; } }); }

export function piOAuthAvailable(authPath = process.env.LLM_BAR_PI_AUTH_PATH) {
  try {
    const storage = AuthStorage.create(authPath || undefined);
    const credential = storage.get(PROVIDER);
    return Boolean(credential && credential.type === "oauth" &&
      nonEmptyString(credential.access) && nonEmptyString(credential.refresh));
  } catch { return false; }
}

export function diagnose({
  configPath = process.env.LLM_BAR_CONFIG_PATH || path.join(os.homedir(), ".llm-usage-bar", "config.json"),
  authPath = process.env.LLM_BAR_PI_AUTH_PATH
} = {}) {
  let profiles = [];
  let configReadable = true;
  try {
    const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
    profiles = Array.isArray(config?.codexManagedAccounts) ? config.codexManagedAccounts : [];
  } catch (error) {
    configReadable = error?.code === "ENOENT";
  }
  const piAuth = piOAuthAvailable(authPath);
  return {
    codex: {
      executable: resolveCodex() ?? null,
      piAuth: piAuth ? "available" : "unavailable",
      managedAccounts: profiles.length,
      configReadable,
      source: profiles.length > 0 ? "Managed Codex" : (piAuth ? "Pi auth" : null)
    }
  };
}

class RPC {
  constructor(pathToCodex, { tokens = null, codexHome = null } = {}) {
    const env = { ...process.env };
    if (codexHome) env.CODEX_HOME = codexHome;
    // Current Codex releases accept `on-request` or `never`; older releases used
    // `untrusted`. Usage requests are read-only and non-interactive, so never ask.
    this.child = spawn(pathToCodex, ["-s", "read-only", "-a", "never", "app-server"], { env, stdio: ["pipe", "pipe", "pipe"] });
    this.lines = createInterface({ input: this.child.stdout });
    this.id = 0;
    this.tokens = tokens;
    this.pending = new Map();
    this.stderr = "";
    this.child.stderr.on("data", chunk => { this.stderr = (this.stderr + chunk).slice(-2000); });
    this.lines.on("line", line => this.onLine(line));
    this.child.on("error", error => this.failAll(new Error(`Could not start Codex app-server: ${error.message}`)));
    this.child.on("close", () => {
      const detail = redactSensitive(this.stderr.trim());
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
    if (msg.method !== "account/chatgptAuthTokens/refresh" || !this.tokens) {
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

async function initialize(rpc) {
  await rpc.request("initialize", { clientInfo: { name: "llm-usage", version: "1.0.0" }, capabilities: { experimentalApi: true } });
  rpc.child.stdin.write(JSON.stringify({ method: "initialized", params: {} }) + "\n");
}

async function nativeAccount(rpc, timeoutMs) {
  let account;
  try {
    account = await withTimeout(rpc.request("account/read", { refreshToken: true }), timeoutMs);
  } catch (error) {
    // Older app-server versions accepted account/read without parameters. Retry only for an
    // invalid-params response; authentication and transport errors must remain terminal.
    if (!String(error?.message || error).toLowerCase().includes("invalid params")) throw error;
    account = await withTimeout(rpc.request("account/read"), timeoutMs);
  }
  if (!account?.account) throw new Error("Managed Codex account is not authenticated.");
  return account;
}

async function fetchNativeUsage({ pathToCodex, codexHome, timeoutMs }) {
  const home = secureManagedHome(codexHome);
  const rpc = new RPC(pathToCodex, { codexHome: home });
  try {
    await withTimeout(initialize(rpc), timeoutMs);
    const account = await nativeAccount(rpc, timeoutMs);
    const response = await withTimeout(rpc.request("account/rateLimits/read"), timeoutMs);
    return makeUsage(response, "Managed Codex", new Date(), nativeAccountMetadata(account));
  } finally {
    rpc.close();
    secureManagedHome(home);
  }
}

export async function fetchUsage({ authPath = process.env.LLM_BAR_PI_AUTH_PATH, codexHome = null, timeoutMs = TIMEOUT_MS } = {}) {
  const pathToCodex = resolveCodex();
  if (!pathToCodex) throw new Error(`Codex executable not found. Checked: ${candidates().join(", ")}`);
  if (codexHome != null) return fetchNativeUsage({ pathToCodex, codexHome, timeoutMs });

  const initial = await piTokens(authPath);
  if (!initial) throw new Error("Pi-managed openai-codex OAuth is not available.");
  const rpc = new RPC(pathToCodex, { tokens: async () => piTokens(authPath) });
  try {
    return makeUsage(await withTimeout((async () => {
      await initialize(rpc);
      await rpc.request("account/login/start", { type: "chatgptAuthTokens", ...initial, chatgptPlanType: null });
      return rpc.request("account/rateLimits/read");
    })(), timeoutMs));
  } finally { rpc.close(); }
}

export async function fetchAllManagedUsage({
  configPath = process.env.LLM_BAR_CONFIG_PATH || path.join(os.homedir(), ".llm-usage-bar", "config.json"),
  timeoutMs = TIMEOUT_MS
} = {}) {
  let config;
  try {
    config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") {
      return {
        codex: null,
        codexAccounts: [],
        error: "No managed Codex accounts configured. Add a managed Codex account before using --all-managed."
      };
    }
    throw new Error("Could not read the LLM Usage Bar managed-account configuration.");
  }

  const profiles = Array.isArray(config?.codexManagedAccounts) ? config.codexManagedAccounts : [];
  if (profiles.length === 0) {
    return {
      codex: null,
      codexAccounts: [],
      error: "No managed Codex accounts configured. Add a managed Codex account before using --all-managed."
    };
  }

  const configRoot = path.dirname(path.resolve(configPath));
  const homesRoot = path.join(configRoot, "codex-accounts");
  const accounts = [];
  for (const profile of profiles) {
    const id = typeof profile?.id === "string" ? profile.id : "";
    const label = typeof profile?.label === "string" && profile.label.trim() ? profile.label.trim() : "Managed Codex";
    const email = typeof profile?.email === "string" && profile.email.trim() ? profile.email.trim() : null;
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) {
      accounts.push({ id, label, email, usage: null, error: "Invalid managed account id." });
      continue;
    }
    try {
      const usage = await fetchUsage({ codexHome: path.join(homesRoot, id), timeoutMs });
      accounts.push({ id, label, email: usage.codex.email ?? email, usage: usage.codex, error: null });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      accounts.push({ id, label, email, usage: null, error: redactSensitive(message) });
    }
  }

  const configuredPrimaryID = typeof config?.codexPrimaryAccountID === "string" ? config.codexPrimaryAccountID : null;
  // A legacy config may have managed profiles but no primary metadata. Make the first profile the
  // explicit primary; if that profile is unavailable, fail closed rather than selecting another.
  const primaryID = configuredPrimaryID && profiles.some(profile => profile?.id === configuredPrimaryID)
    ? configuredPrimaryID
    : profiles[0]?.id;
  const selected = accounts.find(account => account.id === primaryID && account.usage);
  return { codex: selected?.usage ?? null, codexAccounts: accounts };
}

export async function consumeCredit({ creditId, idempotencyKey, codexHome = null, authPath = process.env.LLM_BAR_PI_AUTH_PATH, timeoutMs = TIMEOUT_MS }) {
  if (!creditId || !idempotencyKey) throw new Error("--credit-id and --idempotency-key are required.");
  const pathToCodex = resolveCodex(); if (!pathToCodex) throw new Error("Codex executable not found.");

  if (codexHome != null) {
    const home = secureManagedHome(codexHome);
    const rpc = new RPC(pathToCodex, { codexHome: home });
    try {
      await withTimeout(initialize(rpc), timeoutMs);
      await nativeAccount(rpc, timeoutMs);
      return await withTimeout(rpc.request("account/rateLimitResetCredit/consume", { creditId, idempotencyKey }), timeoutMs);
    } finally {
      rpc.close();
      secureManagedHome(home);
    }
  }

  const initial = await piTokens(authPath); if (!initial) throw new Error("Pi-managed openai-codex OAuth is not available.");
  const rpc = new RPC(pathToCodex, { tokens: async () => piTokens(authPath) });
  try {
    return await withTimeout((async () => {
      await initialize(rpc);
      await rpc.request("account/login/start", { type: "chatgptAuthTokens", ...initial, chatgptPlanType: null });
      return rpc.request("account/rateLimitResetCredit/consume", { creditId, idempotencyKey });
    })(), timeoutMs);
  } finally { rpc.close(); }
}

export function normalizeCodexHomeForCLI(value) { return normalizeCodexHome(value); }
