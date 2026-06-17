/**
 * bot-gateway entrypoint — long-connection Feishu subscriber.
 *
 * Spawns `lark-cli event consume im.message.receive_v1` (a read-only long
 * connection; its websocket was verified reachable), reads the NDJSON event
 * stream line by line, and dispatches each line through processEventLine →
 * handleMessageEvent → the agent (SigV4 invoke of the Tokyo AgentCore runtime).
 *
 * Thin shell: all logic is in index-core / handle-event / sigv4 (unit-tested).
 * The CardKit reply back to Feishu is the remaining wire-up (src/cardkit.ts
 * builds the card; sending it uses the bot identity).
 *
 * Env:
 *   RUNTIME_ARN   AgentCore runtime ARN (Tokyo)
 *   AWS_REGION    default ap-northeast-1
 */

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

import { fromNodeProviderChain } from "@aws-sdk/credential-providers";

import { invokeRuntime } from "./sigv4";
import { processEventLine } from "./index-core";
import { sendReply } from "./reply";
import type { InvokeFn } from "./handle-event";

/** Extract the assistant's answer text from the runtime's SSE response body. */
function extractAnswer(body: string): string {
  const texts: string[] = [];
  for (const m of body.matchAll(/"text":\s*"((?:[^"\\]|\\.)*)"/g)) {
    try {
      texts.push(JSON.parse(`"${m[1]}"`));
    } catch {
      texts.push(m[1]);
    }
  }
  return texts.join("").trim() || "(无内容)";
}

const REGION = process.env.AWS_REGION ?? "ap-northeast-1";
const RUNTIME_ARN = process.env.RUNTIME_ARN ?? "";
const EVENT_KEY = "im.message.receive_v1";

function log(obj: Record<string, unknown>): void {
  console.log(JSON.stringify({ ts: new Date().toISOString(), ...obj }));
}

/** Build an InvokeFn that signs + calls the Tokyo runtime with the caller's
 *  AWS credentials (resolved once from the provider chain). */
async function makeInvoke(): Promise<InvokeFn> {
  const creds = await fromNodeProviderChain()();
  return async (sessionId, prompt) => {
    const { status, body } = await invokeRuntime(
      { runtimeArn: RUNTIME_ARN, region: REGION, sessionId, prompt },
      {
        region: REGION,
        credentials: {
          accessKeyId: creds.accessKeyId,
          secretAccessKey: creds.secretAccessKey,
          sessionToken: creds.sessionToken,
        },
      },
    );
    if (status !== 200) throw new Error(`invoke failed: HTTP ${status}`);
    return extractAnswer(body);
  };
}

async function main(): Promise<void> {
  if (!RUNTIME_ARN) throw new Error("RUNTIME_ARN env is required");
  const invoke = await makeInvoke();

  log({ event: "gateway_start", region: REGION, eventKey: EVENT_KEY });

  // lark-cli event consume: read-only long connection, NDJSON on stdout.
  // Keep stdin as a pipe (not "ignore"): consume treats stdin EOF as an exit
  // signal, so an ignored/closed stdin shuts it down immediately. We hold the
  // pipe open and stop via SIGTERM on process exit instead.
  const child = spawn("lark-cli", ["event", "consume", EVENT_KEY, "--as", "bot"], {
    stdio: ["pipe", "pipe", "inherit"],
  });
  const stopChild = () => {
    if (!child.killed) child.kill("SIGTERM");
  };
  process.on("SIGINT", stopChild);
  process.on("SIGTERM", stopChild);

  const rl = createInterface({ input: child.stdout });
  rl.on("line", (line) => {
    void processEventLine(line, { invoke })
      .then(async (res) => {
        if (res?.handled && res.messageId && res.answer) {
          log({ event: "answered", session: res.sessionId, chars: res.answer.length });
          await sendReply({ messageId: res.messageId, answer: res.answer });
          log({ event: "replied", message: res.messageId });
        }
      })
      .catch((err) => log({ event: "handle_error", error: String(err) }));
  });

  child.on("exit", (code) => {
    log({ event: "consume_exit", code });
    process.exit(code ?? 0);
  });
}

if (require.main === module) {
  main().catch((err) => {
    log({ event: "fatal", error: String(err) });
    process.exit(1);
  });
}
