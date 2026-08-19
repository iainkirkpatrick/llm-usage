#!/usr/bin/env node
import { fetchUsage, fetchAllManagedUsage, consumeCredit, diagnose as diagnoseCodex, redactSensitive } from "./core.js";
import { fileURLToPath } from "node:url";

function parseCodexHomeOption(args, index, values) {
  const value = args[++index];
  if (!value || value.startsWith("--")) throw new Error(`Missing value for ${args[index - 1]}`);
  values.codexHome = value;
  return index;
}

function parseUsageOptions(args, start = 1) {
  const values = { command: "codex", json: false };
  for (let i = start; i < args.length; i++) {
    const key = args[i];
    if (key === "--json") { values.json = true; continue; }
    if (key === "--all-managed") {
      if (values.codexHome) throw new Error("--all-managed cannot be combined with --codex-home");
      values.allManaged = true;
      continue;
    }
    if (key === "--codex-home") {
      if (values.allManaged) throw new Error("--all-managed cannot be combined with --codex-home");
      i = parseCodexHomeOption(args, i, values); continue;
    }
    throw new Error(`Unknown argument: ${key}`);
  }
  return values;
}

export function parseArgs(args) {
  if (!args.length || ["help", "-h", "--help"].includes(args[0])) return { command: "help", json: false };
  if (args[0] === "diagnose") {
    if (args.length > 2 || (args[1] && args[1] !== "--json")) throw new Error(`Unknown argument: ${args[1]}`);
    return { command: "diagnose", json: args[1] === "--json" };
  }
  if (args[0] !== "codex") throw new Error(`Unknown command: ${args[0]}`);
  if (args[1] !== "reset") return parseUsageOptions(args, 1);
  if (args[2] !== "consume") throw new Error(`Unknown argument: ${args[2] ?? "reset"}`);

  const values = { command: "consume", json: false };
  const seen = new Set();
  for (let i = 3; i < args.length; i++) {
    const key = args[i];
    if (seen.has(key)) throw new Error(`Duplicate argument: ${key}`);
    seen.add(key);
    if (key === "--json") { values.json = true; continue; }
    if (key === "--codex-home") { i = parseCodexHomeOption(args, i, values); continue; }
    if (key !== "--credit-id" && key !== "--idempotency-key") throw new Error(`Unknown argument: ${key}`);
    const value = args[++i];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${key}`);
    if (key === "--credit-id") values.creditId = value; else values.idempotencyKey = value;
  }
  return values;
}

export function help() {
  return "Usage: llm-usage codex [--json] [--codex-home PATH | --all-managed]\n       llm-usage codex reset consume --credit-id ID --idempotency-key KEY [--codex-home PATH] --json\n       llm-usage diagnose [--json]\n       llm-usage help";
}

async function main(argv = process.argv.slice(2)) {
  const parsed = parseArgs(argv);
  if (parsed.command === "help") { console.log(help()); return; }
  if (parsed.command === "diagnose") {
    const result = diagnoseCodex();
    const source = result.codex.source ?? "not queried";
    console.log(parsed.json ? JSON.stringify(result) : `Codex executable: ${result.codex.executable}\nPi auth: ${result.codex.piAuth}\nManaged accounts: ${result.codex.managedAccounts}\nSource: ${source}`); return;
  }
  if (parsed.command === "consume") {
    const result = await consumeCredit(parsed);
    console.log(parsed.json ? JSON.stringify({ outcome: result?.outcome ?? result }) : (result?.outcome ?? result)); return;
  }
  const result = parsed.allManaged ? await fetchAllManagedUsage(parsed) : await fetchUsage(parsed);
  console.log(parsed.json ? JSON.stringify(result) : JSON.stringify(result, null, 2));
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch(error => {
    const message = error instanceof Error ? error.message : String(error);
    // Do not allow an accidentally echoed bearer/JWT value into CLI output.
    console.error(redactSensitive(message));
    process.exitCode = 1;
  });
}
