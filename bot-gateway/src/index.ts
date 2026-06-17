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

import { invokeRuntimeStreaming } from "./sigv4";
import { processEventLine } from "./index-core";
import { createCard, updateContent, closeStreaming, finalizeCard, appendButtons, buildSendCardContent } from "./cardkit-client";
import { removeReaction } from "./reaction";
import type { InvokeFn } from "./handle-event";

const REGION = process.env.AWS_REGION ?? "ap-northeast-1";
const RUNTIME_ARN = process.env.RUNTIME_ARN ?? "";
const EVENT_KEY = "im.message.receive_v1";

function log(obj: Record<string, unknown>): void {
  console.log(JSON.stringify({ ts: new Date().toISOString(), ...obj }));
}

// Message-level dedup: prevents double-processing on Feishu re-delivery after
// a gateway restart (event_id dedup map is in-memory and gets cleared).
const processedMessages = new Set<string>();

/** Streaming invoke: creates the card immediately (fast first render), then
 *  updates it as text arrives from the agent, and closes streaming at the end. */
async function streamingCardInvoke(
  sessionId: string,
  prompt: string,
  messageId: string,
  creds: { accessKeyId: string; secretAccessKey: string; sessionToken?: string },
): Promise<void> {
  // Guard: don't process the same message_id twice (covers re-delivery after restart).
  if (processedMessages.has(messageId)) return;
  processedMessages.add(messageId);

  // 1. Create streaming card + send it immediately (user sees card in <2s).
  //    Card starts with "正在分析…" + streaming_mode=true → Feishu shows "生成中" badge.
  const cardId = await createCard("source-truth");
  const sendChild = spawn(
    "lark-cli",
    ["im", "+messages-reply", "--as", "bot", "--message-id", messageId,
     "--msg-type", "interactive", "--content", buildSendCardContent(cardId)],
    { stdio: ["ignore", "ignore", "inherit"] },
  );
  await new Promise<void>((res, rej) => {
    sendChild.on("exit", (c) => (c === 0 ? res() : rej(new Error(`send card exited ${c}`))));
    sendChild.on("error", rej);
  });
  log({ event: "card_sent", message: messageId, card: cardId });

  // Remove the "processing" reaction now that the card is visible.
  removeReaction(messageId);

  // 2. Stream the agent's answer; update card content incrementally.
  let seq = 1;
  let lastUpdate = 0;
  const THROTTLE_MS = 300; // CardKit allows 10/s; ~3/s is safe and smooth.

  const { status, answer } = await invokeRuntimeStreaming(
    { runtimeArn: RUNTIME_ARN, region: REGION, sessionId, prompt },
    { region: REGION, credentials: creds },
    (textSoFar) => {
      const now = Date.now();
      if (now - lastUpdate >= THROTTLE_MS && textSoFar.length > 0) {
        lastUpdate = now;
        seq++;
        updateContent(cardId, textSoFar, seq).catch(() => {});
      }
    },
  );

  if (status !== 200) throw new Error(`invoke failed: HTTP ${status}`);

  // 3. Final update with the complete answer + close streaming.
  seq++;
  await updateContent(cardId, answer || "(无内容)", seq);
  seq++;
  await closeStreaming(cardId, seq);

  // 4. Finalize: header → green "回答完成" + reasoning collapsed + append buttons.
  seq++;
  try { await finalizeCard(cardId, answer || "(无内容)", "", seq); } catch { /* best-effort: PUT format might still fail on some edge cases */ }
  seq++;
  try { await appendButtons(cardId, seq); } catch { /* best-effort */ }
  log({ event: "card_closed", card: cardId, chars: answer.length });
}

async function main(): Promise<void> {
  if (!RUNTIME_ARN) throw new Error("RUNTIME_ARN env is required");
  const creds = await fromNodeProviderChain()();

  // The InvokeFn for handleMessageEvent: it returns the final answer (for
  // logging), but the real streaming card lifecycle is driven by
  // streamingCardInvoke called from the line handler.
  const invoke: InvokeFn = async (_sessionId, prompt) => {
    // The real streaming invoke is driven by streamingCardInvoke in the line
    // handler below. This returns the prompt so res.answer carries it through.
    return prompt;
  };

  log({ event: "gateway_start", region: REGION, eventKey: EVENT_KEY });

  // lark-cli event consume: read-only long connection, NDJSON on stdout.
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
        if (res?.handled && res.messageId && res.sessionId) {
          // Re-extract the prompt from the event (handle-event already parsed it).
          // res.answer here is just the dummy from invoke above.
          const prompt = res.answer ?? "";
          await streamingCardInvoke(res.sessionId, prompt, res.messageId, {
            accessKeyId: creds.accessKeyId,
            secretAccessKey: creds.secretAccessKey,
            sessionToken: creds.sessionToken,
          });
          log({ event: "replied", message: res.messageId, session: res.sessionId });
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
