/**
 * bot-gateway entrypoint — long-connection Feishu subscriber.
 *
 * Runs a single Feishu SDK WSClient long-connection that receives both IM
 * message events (im.message.receive_v1) and card action callbacks
 * (card.action.trigger), dispatching each through handleMessageEvent → the
 * agent (SigV4 invoke of the Tokyo AgentCore runtime) → a streaming CardKit
 * reply. Card follow-up buttons feed back through card.action.trigger.
 *
 * Must be the ONLY long-connection consumer for this app: Feishu long-connection
 * is cluster mode and delivers each event to one random client, so a stray
 * lark-cli event-bus daemon would steal events.
 *
 * Thin shell: logic lives in handle-event / sdk-event / sigv4 (unit-tested).
 *
 * Env:
 *   RUNTIME_ARN         AgentCore runtime ARN (Tokyo)
 *   AWS_REGION          default ap-northeast-1
 *   FEISHU_APP_ID       app id (for the SDK long-connection)
 *   FEISHU_APP_SECRET   app secret
 */

import { spawn } from "node:child_process";

import { fromNodeProviderChain } from "@aws-sdk/credential-providers";

import { invokeRuntimeStreaming } from "./sigv4";
import { createCard, updateContent, closeStreaming, finalizeCard, appendFooter, buildSendCardContent, disableFollowUpButton, updateStage } from "./cardkit-client";
import { rememberCard, lookupCard } from "./card-registry";
import { removeReaction } from "./reaction";
import { redactSensitive } from "./redact";
import { extractFollowUps } from "./extract-followups";
import { handleMessageEvent, type InvokeFn } from "./handle-event";
import { sdkEventToImEvent } from "./sdk-event";
import { getSessionId } from "./session-map";

const REGION = process.env.AWS_REGION ?? "ap-northeast-1";
const RUNTIME_ARN = process.env.RUNTIME_ARN ?? "";
const APP_ID = process.env.FEISHU_APP_ID ?? "";
const APP_SECRET = process.env.FEISHU_APP_SECRET ?? "";

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
  // Dedup only IM messages (Feishu re-delivers them on restart). Follow-up
  // clicks (chatId target) are deliberate user actions — never dedup them,
  // or a second follow-up in the same chat would be silently dropped.
  if ("messageId" in target) {
    if (processedMessages.has(target.messageId)) return;
    processedMessages.add(target.messageId);
  }

  // 1. Create streaming card + send it immediately. Follow-up cards carry a
  //    "↳ 追问" summary marker so the chat history shows where they came from.
  const isFollowUp = "chatId" in target;
  const summary = isFollowUp ? `↳ 追问：${prompt}` : prompt;
  const cardId = await createCard(summary, isFollowUp);
  const sendArgs = "messageId" in target
    ? ["im", "+messages-reply", "--as", "bot", "--message-id", target.messageId,
       "--msg-type", "interactive", "--content", buildSendCardContent(cardId)]
    : ["im", "+messages-send", "--as", "bot", "--chat-id", target.chatId,
       "--msg-type", "interactive", "--content", buildSendCardContent(cardId)];
  const sendChild = spawn("lark-cli", sendArgs, { stdio: ["ignore", "pipe", "inherit"] });
  let sendOut = "";
  sendChild.stdout.on("data", (d) => (sendOut += d));
  await new Promise<void>((res, rej) => {
    sendChild.on("exit", (c) => (c === 0 ? res() : rej(new Error(`send card exited ${c}`))));
    sendChild.on("error", rej);
  });
  // Record message_id → card_id so a follow-up click (which only carries
  // open_message_id) can find this card and disable the clicked button.
  try {
    const sentMessageId = (JSON.parse(sendOut) as { data?: { message_id?: string } })?.data?.message_id;
    if (sentMessageId) rememberCard(sentMessageId, cardId);
  } catch { /* best-effort: button-disable is a visual nicety */ }
  log({ event: "card_sent", target: targetKey, card: cardId });

  // Remove the "processing" reaction now that the card is visible.
  if ("messageId" in target) removeReaction(target.messageId);

  // 2. Stream the agent's answer; update card content incrementally.
  //    9-minute safety timeout: close streaming gracefully before Feishu's
  //    10-minute hard window kills the stream (avoids broken card state).
  let seq = 1;
  let lastUpdate = 0;
  let timedOut = false;
  let stage: "thinking" | "analyzing" = "thinking";
  let lastDisplay = "正在分析…";
  const THROTTLE_MS = 100; // CardKit allows 10/s; push to max for smoothest typewriter.
  const STREAM_TIMEOUT_MS = 9 * 60 * 1000; // 9 min (Feishu closes at 10)
  const deadline = Date.now() + STREAM_TIMEOUT_MS;

  const { status, answer, reasoning } = await invokeRuntimeStreaming(
    { runtimeArn: RUNTIME_ARN, region: REGION, sessionId, prompt },
    { region: REGION, credentials: creds },
    (textSoFar, latestTool) => {
      if (timedOut) return;
      if (Date.now() > deadline) { timedOut = true; return; }
      // Stage 2 (思考→分析): on the first tool call, flip the header to an
      // orange "正在分析…" via a one-time full PUT (carries current text so the
      // streaming body isn't wiped). Only once — repeated full PUTs would
      // stutter the typewriter.
      if (stage === "thinking" && latestTool) {
        stage = "analyzing";
        seq++;
        updateStage(cardId, "🔍 正在分析…", "orange", lastDisplay, seq).catch(() => {});
        return;
      }
      const now = Date.now();
      if (now - lastUpdate < THROTTLE_MS) return;
      lastUpdate = now;
      const display = textSoFar.length > 0
        ? redactSensitive(textSoFar)
        : latestTool
          ? `*正在分析：${latestTool}*`
          : "正在分析…";
      lastDisplay = display;
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
  try { await finalizeCard(cardId, finalText, reasoning, seq, isFollowUp); } catch { /* best-effort */ }
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

  log({ event: "gateway_start", region: REGION });

  // After handleMessageEvent decides to answer, drive the streaming card.
  const replyWithCard = async (res: Awaited<ReturnType<typeof handleMessageEvent>>) => {
    if (!res?.handled || !res.messageId || !res.sessionId) return;
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
  };

  // Single Feishu SDK WSClient long-connection: IM events + card action
  // callbacks. (Must be the ONLY consumer for this app — Feishu long-connection
  // is cluster mode and delivers each event to just one random client, so a
  // stray lark-cli event-bus daemon would steal events. Verified live.)
  if (!APP_ID || !APP_SECRET) throw new Error("FEISHU_APP_ID and FEISHU_APP_SECRET required");
  const lark = await import("@larksuiteoapi/node-sdk");
  const dispatcher = new lark.EventDispatcher({}).register({
    "im.message.receive_v1": (data: unknown) => {
      const event = sdkEventToImEvent(data);
      if (event) {
        void handleMessageEvent(event, { invoke })
          .then(replyWithCard)
          .catch((err) => log({ event: "handle_error", error: String(err) }));
      }
      return {};
    },
    "card.action.trigger": (data: unknown) => {
      try {
        const d = data as {
          action?: { value?: { action?: string; text?: string; eid?: string } };
          context?: { open_chat_id?: string; open_message_id?: string };
        };
        const value = d?.action?.value;
        const chatId = d?.context?.open_chat_id ?? "";
        const messageId = d?.context?.open_message_id ?? "";
        if (value?.action === "follow_up" && value.text && chatId) {
          log({ event: "follow_up_clicked", chatId, question: value.text });
          const sessionId = getSessionId(chatId);
          void streamingCardInvoke(sessionId, value.text, { chatId }, {
            accessKeyId: creds.accessKeyId,
            secretAccessKey: creds.secretAccessKey,
            sessionToken: creds.sessionToken,
          }).catch((e) => log({ event: "follow_up_error", error: String(e) }));
          // Mark the clicked button: disable it + ✓ on the original card, so the
          // user sees which one they picked (best-effort, async).
          const cardId = lookupCard(messageId);
          if (cardId && value.eid) {
            // sequence must be int32 (≤2147483647) AND > the card's streaming
            // seqs (which top out in the low hundreds). Unix seconds since a
            // 2025 epoch fits int32 for ~60y and is monotonic across clicks.
            const seq = Math.floor(Date.now() / 1000) - 1_700_000_000;
            void disableFollowUpButton(cardId, value.eid, value.text, seq)
              .catch((e) => log({ event: "disable_button_error", error: String(e) }));
          }
          // No toast — the in-place button disable (✓ + greyed) is feedback enough.
        }
      } catch { /* best-effort */ }
      return {};
    },
  });
  const ws = new lark.WSClient({ appId: APP_ID, appSecret: APP_SECRET, loggerLevel: lark.LoggerLevel.warn });
  ws.start({ eventDispatcher: dispatcher });
  log({ event: "sdk_wsclient_started" });
}

if (require.main === module) {
  main().catch((err) => {
    log({ event: "fatal", error: String(err) });
    process.exit(1);
  });
}
