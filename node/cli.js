#!/usr/bin/env node
import { fetchUsage, consumeCredit, resolveCodex } from "./core.js";
import { fileURLToPath } from "node:url";

export function parseArgs(args) {
  if (!args.length || ["help", "-h", "--help"].includes(args[0])) return { command: "help", json: false };
  if (args[0] === "diagnose") {
    if (args.length > 2 || (args[1] && args[1] !== "--json")) throw new Error(`Unknown argument: ${args[1]}`);
    return { command: "diagnose", json: args[1] === "--json" };
  }
  if (args[0] !== "codex") throw new Error(`Unknown command: ${args[0]}`);
  if (args[1] !== "reset") {
    if (args.length > 2 || (args[1] && args[1] !== "--json")) throw new Error(`Unknown argument: ${args[1]}`);
    return { command: "codex", json: args[1] === "--json" };
  }
  if (args[2] !== "consume") throw new Error(`Unknown argument: ${args[2] ?? "reset"}`);

  const values = { command: "consume", json: false };
  const seen = new Set();
  for (let i = 3; i < args.length; i++) {
    const key = args[i];
    if (seen.has(key)) throw new Error(`Duplicate argument: ${key}`);
    seen.add(key);
    if (key === "--json") { values.json = true; continue; }
    if (key !== "--credit-id" && key !== "--idempotency-key") throw new Error(`Unknown argument: ${key}`);
    const value = args[++i];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${key}`);
    if (key === "--credit-id") values.creditId = value; else values.idempotencyKey = value;
  }
  return values;
}

export function help() {
  return "Usage: llm-usage codex [--json]\n       llm-usage codex reset consume --credit-id ID --idempotency-key KEY --json\n       llm-usage diagnose\n       llm-usage help";
}

async function main(argv = process.argv.slice(2)) {
  const parsed = parseArgs(argv);
  if (parsed.command === "help") { console.log(help()); return; }
  if (parsed.command === "diagnose") {
    const usage = await fetchUsage();
    const result = { codex: { executable: resolveCodex() ?? null, piAuth: "available", source: usage.codex.source } };
    console.log(parsed.json ? JSON.stringify(result) : `Codex executable: ${result.codex.executable}\nPi auth: ${result.codex.piAuth}\nSource: ${result.codex.source}`); return;
  }
  if (parsed.command === "consume") {
    const result = await consumeCredit(parsed);
    console.log(parsed.json ? JSON.stringify({ outcome: result?.outcome ?? result }) : (result?.outcome ?? result)); return;
  }
  const result = await fetchUsage();
  console.log(parsed.json ? JSON.stringify(result) : JSON.stringify(result, null, 2));
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch(error => {
    const message = error instanceof Error ? error.message : String(error);
    // Do not allow an accidentally echoed bearer/JWT value into CLI output.
    console.error(message.replace(/Bearer\s+\S+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, "[redacted]"));
    process.exitCode = 1;
  });
}
