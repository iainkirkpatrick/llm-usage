import { AuthStorage } from "@mariozechner/pi-coding-agent";
import process from "node:process";

const PROVIDER_ID = "openai-codex";
const JWT_CLAIM_PATH = "https://api.openai.com/auth";

function decodeBase64Url(value) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4 || 4)) % 4);
  return Buffer.from(padded, "base64").toString("utf8");
}

function decodeJwtPayload(token) {
  const parts = token.split(".");
  if (parts.length < 2) return null;

  try {
    return JSON.parse(decodeBase64Url(parts[1]));
  } catch {
    return null;
  }
}

function extractAccountId(accessToken) {
  const payload = decodeJwtPayload(accessToken);
  const auth = payload?.[JWT_CLAIM_PATH];
  const accountId = auth?.chatgpt_account_id;
  return typeof accountId === "string" && accountId.length > 0 ? accountId : null;
}

async function readPiCodexTokens(authPath) {
  const authStorage = AuthStorage.create(authPath && authPath.length > 0 ? authPath : undefined);
  const credential = authStorage.get(PROVIDER_ID);
  if (!credential || credential.type !== "oauth") {
    return { status: "noAuth" };
  }

  const accessToken = await authStorage.getApiKey(PROVIDER_ID);
  if (!accessToken) {
    return { status: "noAuth" };
  }

  authStorage.reload();
  const refreshedCredential = authStorage.get(PROVIDER_ID);
  if (!refreshedCredential || refreshedCredential.type !== "oauth") {
    return { status: "noAuth" };
  }

  const chatgptAccountId =
    (typeof refreshedCredential.accountId === "string" && refreshedCredential.accountId.length > 0
      ? refreshedCredential.accountId
      : null) ?? extractAccountId(accessToken);

  if (!chatgptAccountId) {
    throw new Error("Pi Codex OAuth credential did not include a usable ChatGPT account id.");
  }

  return {
    status: "ok",
    accessToken,
    chatgptAccountId,
    chatgptPlanType: null,
  };
}

async function main() {
  const authPath = process.env.LLM_BAR_PI_AUTH_PATH?.trim();
  const result = await readPiCodexTokens(authPath);
  process.stdout.write(JSON.stringify(result));
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
