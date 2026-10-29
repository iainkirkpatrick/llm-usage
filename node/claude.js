import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const CACHE_TTL_MS = 60_000;
const FAILURE_BACKOFF_MS = 60_000;
const LOCK_TIMEOUT_MS = 25_000;
const HELPER_TIMEOUT_MS = 22_000;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function configIdentity(env, fingerprint) {
  const home = env.HOME || os.homedir();
  const configured = env.CLAUDE_CONFIG_DIR;
  const directory = configured ? path.resolve(configured.replace(/^~/, home)) : path.join(home, ".claude");
  const mode = configured ? "explicit" : "default";
  const scope = crypto.createHash("sha256").update(`${process.getuid?.() ?? "user"}\0${mode}\0${directory}`).digest("hex");
  const key = crypto.createHash("sha256").update(`${scope}\0${fingerprint}`).digest("hex");
  return { scope, key };
}

function secureDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== (process.getuid?.() ?? stat.uid)) {
    throw new Error("Claude usage cache directory is not secure.");
  }
  fs.chmodSync(directory, 0o700);
}

function readCache(file) {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== (process.getuid?.() ?? stat.uid)) return null;
    fs.chmodSync(file, 0o600);
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch { return null; }
}

function writeCache(file, value) {
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  const fd = fs.openSync(temporary, "wx", 0o600);
  try { fs.writeFileSync(fd, JSON.stringify(value)); fs.fsyncSync(fd); }
  finally { fs.closeSync(fd); }
  fs.renameSync(temporary, file);
}

function validate(result) {
  const claude = result?.claude;
  if (!claude || typeof claude !== "object" || typeof claude.source !== "string" || typeof claude.updatedAt !== "string") {
    throw new Error("Claude usage helper returned an invalid response.");
  }
  for (const name of ["session", "weekly"]) {
    const value = claude[name];
    if (value == null) continue;
    if (!Number.isFinite(value.remainingPercent) || !Number.isFinite(value.usedPercent) ||
        value.remainingPercent < 0 || value.remainingPercent > 100 || value.usedPercent < 0 || value.usedPercent > 100 ||
        !(value.resetAt === null || typeof value.resetAt === "string")) {
      throw new Error("Claude usage helper returned an invalid response.");
    }
  }
  return result;
}

function helperPath(env) {
  if (env.LLM_USAGE_CLAUDE_HELPER) return env.LLM_USAGE_CLAUDE_HELPER;
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.resolve(here, "../MacOS/LLMUsageBar"),
    path.resolve(here, "../.build/release/LLMUsageBar"),
    path.resolve(here, "../.build/debug/LLMUsageBar")
  ];
  return candidates.find(file => { try { return fs.statSync(file).isFile() && (fs.statSync(file).mode & 0o111); } catch { return false; } }) ?? candidates[0];
}

function invokeHelper(executable, env, { identity = false, timeoutMs = HELPER_TIMEOUT_MS } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, [identity ? "--claude-usage-identity" : "--claude-usage-cli"], { env, stdio: ["ignore", "pipe", "pipe"], detached: true });
    let stdout = "", stderr = "", timedOut = false, settled = false;
    const signal = name => { try { process.kill(-child.pid, name); } catch { try { child.kill(name); } catch {} } };
    const timer = setTimeout(() => {
      timedOut = true;
      signal("SIGTERM");
      setTimeout(() => {
        signal("SIGKILL");
        finish(reject, new Error("Claude usage request timed out. Try again shortly."));
      }, 500).unref();
    }, timeoutMs);
    const finish = (fn, value) => { if (settled) return; settled = true; clearTimeout(timer); fn(value); };
    child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
    child.stdout.on("data", chunk => { stdout += chunk; if (stdout.length > 1_048_576) child.kill("SIGKILL"); });
    child.stderr.on("data", chunk => { stderr += chunk; if (stderr.length > 16_384) child.kill("SIGKILL"); });
    child.on("error", () => finish(reject, new Error("Claude usage helper is unavailable. Build the macOS app or set LLM_USAGE_CLAUDE_HELPER.")));
    child.on("close", code => {
      if (timedOut) return finish(reject, new Error("Claude usage request timed out. Try again shortly."));
      if (code !== 0) return finish(reject, new Error(stderr.trim() || "Claude usage request failed. Check Claude Code sign-in and try again."));
      try {
        const parsed = JSON.parse(stdout);
        if (identity) {
          if (typeof parsed?.fingerprint !== "string" || !/^[a-f0-9]{64}$/.test(parsed.fingerprint)) throw new Error();
          finish(resolve, parsed.fingerprint);
        } else finish(resolve, validate(parsed));
      } catch { finish(reject, new Error(identity ? "Claude credential identity is unavailable." : "Claude usage helper returned invalid JSON.")); }
    });
  });
}

export async function fetchClaudeUsage({ env = process.env, cacheDirectory = path.join(env.HOME || os.homedir(), ".llm-usage-bar", "claude-cli-cache"), executable = helperPath(env), now = Date.now, helperTimeoutMs = HELPER_TIMEOUT_MS } = {}) {
  const { scope } = configIdentity(env, "");
  secureDirectory(cacheDirectory);
  const lockFile = path.join(cacheDirectory, `${scope}.lock`);
  const failureFile = path.join(cacheDirectory, `${scope}.identity.json`);
  let lock;
  // The owner may run both identity and quota helpers sequentially.
  const coordinationTimeoutMs = Math.max(LOCK_TIMEOUT_MS, 2 * (helperTimeoutMs + 500) + 1_000);
  const deadline = now() + coordinationTimeoutMs;
  while (!lock) {
    try {
      lock = fs.openSync(lockFile, "wx", 0o600);
      fs.writeFileSync(lock, String(process.pid));
      fs.fsyncSync(lock);
    } catch (error) {
      if (error.code !== "EEXIST") throw new Error("Could not coordinate Claude usage refresh safely.");
      const failure = readCache(failureFile);
      if (failure?.error && now() < failure.retryAt) throw new Error(failure.error);
      try {
        const info = fs.statSync(lockFile);
        if (now() - info.mtimeMs > coordinationTimeoutMs * 3) {
          const pid = Number(fs.readFileSync(lockFile, "utf8"));
          let alive = true;
          try { process.kill(pid, 0); } catch (e) { if (e.code === "ESRCH") alive = false; }
          if (!alive) fs.unlinkSync(lockFile);
        }
      } catch { /* another process owns or is replacing the lock */ }
      if (now() >= deadline) throw new Error("Claude usage refresh is already running. Try again shortly.");
      await sleep(100);
    }
  }
  try {
    const failure = readCache(failureFile);
    if (failure?.error && now() < failure.retryAt) throw new Error(failure.error);
    let fingerprint;
    try {
      fingerprint = await invokeHelper(executable, { ...env }, { identity: true, timeoutMs: helperTimeoutMs });
      try { fs.unlinkSync(failureFile); } catch {}
    } catch (error) {
      const message = String(error?.message || "Claude credential identity is unavailable.").replace(/Bearer\s+\S+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, "[redacted]").slice(0, 500);
      writeCache(failureFile, { savedAt: now(), retryAt: now() + FAILURE_BACKOFF_MS, error: message });
      throw new Error(message);
    }
    const { key } = configIdentity(env, fingerprint);
    const cacheFile = path.join(cacheDirectory, `${key}.json`);
    const current = readCache(cacheFile);
    if (current?.result && now() - current.savedAt < CACHE_TTL_MS) return validate(current.result);
    if (current?.error && now() < current.retryAt) throw new Error(current.error);
    try {
      const result = await invokeHelper(executable, { ...env, LLM_USAGE_CLAUDE_FINGERPRINT: fingerprint }, { timeoutMs: helperTimeoutMs });
      writeCache(cacheFile, { savedAt: now(), result });
      return result;
    } catch (error) {
      const message = String(error?.message || "Claude usage request failed.").replace(/Bearer\s+\S+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, "[redacted]").slice(0, 500);
      writeCache(cacheFile, { savedAt: now(), retryAt: now() + FAILURE_BACKOFF_MS, error: message });
      throw new Error(message);
    }
  } finally {
    try { fs.closeSync(lock); } catch {}
    try { fs.unlinkSync(lockFile); } catch {}
  }
}
