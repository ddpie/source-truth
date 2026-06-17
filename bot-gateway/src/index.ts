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
import { createCard, updateContent, closeStreaming, finalizeCard, appendFooter, buildSendCardContent } from "./cardkit-client";
import { removeReaction } from "./reaction";
import { redactSensitive } from "./redact";
import { extractFollowUps } from "./extract-followups";
// Card callback via SDK WSClient deferred (connection issue to root-cause).
// import { startCardCallbackListener } from "./card-callback";
import { getSessionId as _getSessionId } from "./session-map";
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
  target: { messageId: string } | { chatId: string },
  creds: { accessKeyId: string; secretAccessKey: string; sessionToken?: string },
): Promise<void> {
  const targetKey = "messageId" in target ? target.messageId : target.chatId;
  if (processedMessages.has(targetKey)) return;
  processedMessages.add(targetKey);

  // 1. Create streaming card + send it immediately.
  const cardId = await createCard(prompt);
  const sendArgs = "messageId" in target
    ? ["im", "+messages-reply", "--as", "bot", "--message-id", target.messageId,
       "--msg-type", "interactive", "--content", buildSendCardContent(cardId)]
    : ["im", "+messages-send", "--as", "bot", "--chat-id", target.chatId,
       "--msg-type", "interactive", "--content", buildSendCardContent(cardId)];
  const sendChild = spawn("lark-cli", sendArgs, { stdio: ["ignore", "ignore", "inherit"] });
  await new Promise<void>((res, rej) => {
    sendChild.on("exit", (c) => (c === 0 ? res() : rej(new Error(`send card exited ${c}`))));
    sendChild.on("error", rej);
  });
  log({ event: "card_sent", target: targetKey, card: cardId });

  // Remove the "processing" reaction now that the card is visible.
  if ("messageId" in target) removeReaction(target.messageId);

  // 2. Stream the agent's answer; update card content incrementally.
  //    9-minute safety timeout: close streaming gracefully before Feishu's
  //    10-minute hard window kills the stream (avoids broken card state).
  let seq = 1;
  let lastUpdate = 0;
  let timedOut = false;
  const THROTTLE_MS = 100; // CardKit allows 10/s; push to max for smoothest typewriter.
  const STREAM_TIMEOUT_MS = 9 * 60 * 1000; // 9 min (Feishu closes at 10)
  const deadline = Date.now() + STREAM_TIMEOUT_MS;

  const { status, answer, reasoning } = await invokeRuntimeStreaming(
    { runtimeArn: RUNTIME_ARN, region: REGION, sessionId, prompt },
    { region: REGION, credentials: creds },
    (textSoFar, latestTool) => {
      if (timedOut) return;
      if (Date.now() > deadline) { timedOut = true; return; }
      const now = Date.now();
      if (now - lastUpdate < THROTTLE_MS) return;
      lastUpdate = now;
      const display = textSoFar.length > 0
        ? redactSensitive(textSoFar)
        : latestTool
          ? `*正在取证：${latestTool}*`
          : "正在分析…";
      seq++;
      updateContent(cardId, display, seq).catch(() => {});
    },
  );

  if (status !== 200) throw new Error(`invoke failed: HTTP ${status}`);

  // 3. Final update + close streaming.
  const finalText = timedOut && !answer
    ? "⏱ 分析超时，请缩小问题范围后重试。"
    : redactSensitive(answer || "(无内容)");
  seq++;
  await updateContent(cardId, finalText, seq);
  seq++;
  await closeStreaming(cardId, seq);

  // 4. Finalize: header → green "回答完成" + reasoning collapsed + footer.
  seq++;
  try { await finalizeCard(cardId, finalText, reasoning, seq); } catch { /* best-effort */ }
  seq++;
  const followUps = extractFollowUps(finalText);
  try { await appendFooter(cardId, seq, followUps); } catch { /* best-effort */ }
  log({ event: "card_closed", card: cardId, chars: answer.length, timedOut });
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

  // Event source: prefer Feishu SDK WSClient (handles IM events + card callbacks
  // in one connection). Falls back to lark-cli event consume if no credentials.
  // const APP_ID = process.env.FEISHU_APP_ID ?? "";
  // const APP_SECRET = process.env.FEISHU_APP_SECRET ?? "";

  const handleEvent = (line: string) => {
    void processEventLine(line, { invoke })
      .then(async (res) => {
        if (res?.handled && res.messageId && res.sessionId) {
          const prompt = res.answer ?? "";
          try {
            await streamingCardInvoke(res.sessionId, prompt, { messageId: res.messageId }, {
              accessKeyId: creds.accessKeyId,
              secretAccessKey: creds.secretAccessKey,
              sessionToken: creds.sessionToken,
            });
          } catch (cardErr) {
            log({ event: "card_fallback", error: String(cardErr) });
            const { sendReply } = await import("./reply.js");
            await sendReply({ messageId: res.messageId, answer: `⚠️ 卡片渲染失败，纯文本回复：\n\n${prompt}` }).catch(() => {});
          }
          log({ event: "replied", message: res.messageId, session: res.sessionId });
        }
      })
      .catch((err) => log({ event: "handle_error", error: String(err) }));
  };

  // Use lark-cli event consume (reliable, proven). Card action callbacks via
  // SDK WSClient didn't connect reliably — deferred until root-caused.
  const child = spawn("lark-cli", ["event", "consume", EVENT_KEY, "--as", "bot"], {
    stdio: ["pipe", "pipe", "inherit"],
  });
  const stopChild = () => { if (!child.killed) child.kill("SIGTERM"); };
  process.on("SIGINT", stopChild);
  process.on("SIGTERM", stopChild);
  const rl = createInterface({ input: child.stdout });
  rl.on("line", handleEvent);
  child.on("exit", (code) => { log({ event: "consume_exit", code }); process.exit(code ?? 0); });
}

if (require.main === module) {
  main().catch((err) => {
    log({ event: "fatal", error: String(err) });
    process.exit(1);
  });
}
