import test from "node:test";
import assert from "node:assert/strict";
import { classifyWindows, makeUsage } from "./core.js";
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

test("parses consume arguments", () => {
  assert.deepEqual(parseArgs(["codex", "reset", "consume", "--credit-id", "c", "--idempotency-key", "k", "--json"]), { command: "consume", creditId: "c", idempotencyKey: "k", json: true });
});
