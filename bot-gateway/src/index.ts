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

import { invokeRuntimeStreaming, classifyInvokeOutcome, isTurnCapError, type AwsCredentials } from "./sigv4";
import { createCard, updateContent, closeStreaming, finalizeCard, appendFooter, buildSendCardContent, disableFollowUpButton, updateStage, appendReasoningPanel, updateReasoningPanel, appendCharts, appendStopButton } from "./cardkit-client";
import { extractCharts } from "./extract-charts";
import { rememberCard, lookupCard } from "./card-registry";
import { removeReaction } from "./reaction";
import { redactSensitive, redactSteps, redactDeep } from "./redact";
import { extractFollowUps, stripFollowUps } from "./extract-followups";
import { handleMessageEvent, type InvokeFn } from "./handle-event";
import { sdkEventToImEvent } from "./sdk-event";
import { sendReply } from "./reply";
import { getSessionId } from "./session-map";
import { hashUserId } from "./log";
import { isDuplicate } from "./dedup";

const REGION = process.env.AWS_REGION ?? "ap-northeast-1";
const RUNTIME_ARN = process.env.RUNTIME_ARN ?? "";
const APP_ID = process.env.FEISHU_APP_ID ?? "";
const APP_SECRET = process.env.FEISHU_APP_SECRET ?? "";
// The bot's own open_id (optional). When set, group messages are answered only
// if THIS bot was @-mentioned (precise). When unset, the gate falls back to
// "any @-mention present" — still blocks the answer-everything behavior.
const BOT_OPEN_ID = process.env.FEISHU_BOT_OPEN_ID ?? "";

function log(obj: Record<string, unknown>): void {
  console.log(JSON.stringify({ ts: new Date().toISOString(), ...obj }));
}

// Message-level dedup uses the shared TTL-bounded `isDuplicate` (dedup.ts) with
// a "msg:" prefix so it can't collide with event_id keys. This replaces an
// earlier unbounded Set that leaked memory in an always-on gateway.

// cardId → AbortController for the in-flight agent stream, so a 停止 button
// click (card.action.trigger) can abort that specific invoke.
const abortControllers = new Map<string, AbortController>();

// Monotonic sequence for card-callback (button-disable) updates. Based on Unix
// seconds since a 2025 epoch (stays int32 for ~60y, and is far above the
// streaming seqs which top out in the low hundreds). A counter guarantees
// strict monotonicity even for multiple clicks within the SAME second (plain
// seconds would collide → CardKit rejects the 2nd update, button never greys).
let _lastCallbackSeq = 0;
function nextCallbackSeq(): number {
  const base = Math.floor(Date.now() / 1000) - 1_700_000_000;
  _lastCallbackSeq = base > _lastCallbackSeq ? base : _lastCallbackSeq + 1;
  return _lastCallbackSeq;
}

/** Streaming invoke: creates the card immediately (fast first render), then
 *  updates it as text arrives from the agent, and closes streaming at the end. */
async function streamingCardInvoke(
  sessionId: string,
  prompt: string,
  target: { messageId: string } | { chatId: string },
  // A credential PROVIDER, not a snapshot: SignatureV4 re-resolves it on every
  // sign, so EC2 instance-role (IMDS) temporary creds get refreshed instead of
  // going stale and 403-ing every invoke after a few hours of uptime.
  credentials: () => Promise<AwsCredentials>,
): Promise<void> {
  const targetKey = "messageId" in target ? target.messageId : target.chatId;
  // Dedup only IM messages (Feishu re-delivers them on restart). Follow-up
  // clicks (chatId target) are deliberate user actions — never dedup them,
  // or a second follow-up in the same chat would be silently dropped.
  if ("messageId" in target) {
    if (isDuplicate(`msg:${target.messageId}`)) return;
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
  log({ event: "card_sent", target: hashUserId(targetKey), card: cardId });

  // Remove the "processing" reaction now that the card is visible.
  if ("messageId" in target) removeReaction(target.messageId);

  // 2. Stream the agent's answer; update card content incrementally.
  //    9-minute safety timeout: close streaming gracefully before Feishu's
  //    10-minute hard window kills the stream (avoids broken card state).
  let seq = 1;
  let lastUpdate = 0;
  let lastPanelUpdate = 0;
  let timedOut = false;
  let stage: "thinking" | "analyzing" = "thinking";
  let lastDisplay = "正在分析…";
  let stepsShown = 0; // how many reasoning steps are currently rendered in the panel
  let panelAppended = false;
  const THROTTLE_MS = 100; // CardKit allows 10/s; push to max for smoothest typewriter.
  const STREAM_TIMEOUT_MS = 9 * 60 * 1000; // 9 min (Feishu closes at 10)
  const deadline = Date.now() + STREAM_TIMEOUT_MS;

  // ── "正在分析" 动效 (Claude-Code/Codex 风格: spinner 持续转 + 秒数 + 阶段词) ──
  // A heartbeat timer animates the header so the card feels alive while the agent
  // thinks. The SECONDS counter is the honest signal (monotonic = not frozen);
  // the spinner is decoration. A watchdog degrades the text when NO real SSE
  // event has arrived for a while, so we never imply progress that isn't there.
  // The timer ONLY drives the header during the THINKING phase and during
  // analyzing GAPS — once the conclusion is actively streaming, the typewriter IS
  // the animation and we don't fight it with full-card PUTs (which re-carry the
  // body and could race the streamed text). MUST be cleared on every exit path.
  const SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
  const startedAt = Date.now();
  let lastEventAt = Date.now();   // updated on every real onChunk (real progress)
  let spinFrame = 0;
  let heartbeat: ReturnType<typeof setInterval> | undefined;
  const stopHeartbeat = () => { if (heartbeat) { clearInterval(heartbeat); heartbeat = undefined; } };
  heartbeat = setInterval(() => {
    if (timedOut || Date.now() > deadline) { stopHeartbeat(); return; }
    // While the conclusion is streaming (analyzing + real text flowing recently),
    // the typewriter is the animation — skip the header spinner to avoid racing
    // the body's streamed text with a full-card PUT.
    const sinceEvent = Date.now() - lastEventAt;
    if (stage === "analyzing" && lastDisplay !== "正在分析…" && sinceEvent < 1500) return;
    const elapsed = Math.floor((Date.now() - startedAt) / 1000);
    const spin = SPINNER[spinFrame++ % SPINNER.length];
    // Watchdog: >15s with no new event → say so honestly, don't fake progress.
    const label = sinceEvent > 15000
      ? `${spin} 仍在思考（较久）${elapsed}s`
      : `${spin} 正在分析 ${elapsed}s`;
    seq++;
    updateStage(cardId, label, "orange", lastDisplay, seq).catch(() => {});
  }, 800);

  // Abort handle for the 停止 button (registered for the lifetime of the stream).
  const abort = new AbortController();
  abortControllers.set(cardId, abort);

  // try/finally so the abortControllers entry is removed on EVERY exit path —
  // resolve, abort, OR a thrown network/stream/signing error. Without the finally
  // a non-abort throw skips the delete and leaks one AbortController per failed
  // invoke for the lifetime of this always-on process.
  let result: Awaited<ReturnType<typeof invokeRuntimeStreaming>>;
  try {
    result = await invokeRuntimeStreaming(
    { runtimeArn: RUNTIME_ARN, region: REGION, sessionId, prompt },
    { region: REGION, credentials },
    (textSoFar, liveSteps) => {
      if (timedOut) return;
      if (Date.now() > deadline) { timedOut = true; return; }
      lastEventAt = Date.now(); // real SSE activity → resets the watchdog
      // Stage 2 (思考→分析): on the first tool call, add the 停止 button + seed the
      // live reasoning panel. The header spinner/text is driven by the heartbeat
      // timer (which reads `stage`), so we no longer push a static "正在分析…"
      // here — just flip the stage and add the stop button.
      if (stage === "thinking" && liveSteps.length > 0) {
        stage = "analyzing";
        seq++;
        updateStage(cardId, "🔍 正在分析…", "orange", lastDisplay, seq).catch(() => {});
        seq++;
        appendStopButton(cardId, seq).catch(() => {});
        return;
      }
      // Live reasoning panel: append once, then update in place as steps grow —
      // separate element from the streamed conclusion, so it doesn't fight the
      // typewriter. Only push when a NEW step appeared (not every text chunk).
      if (liveSteps.length > stepsShown) {
        // Throttle panel pushes too: they share CardKit's 10/s entity cap with
        // content/stage/button updates, so an agent emitting steps in a burst
        // could otherwise trip the limit. Skip this tick if we updated recently
        // (steps keep accumulating in liveSteps; the next tick renders them all).
        const nowPanel = Date.now();
        if (nowPanel - lastPanelUpdate < THROTTLE_MS) return;
        lastPanelUpdate = nowPanel;
        stepsShown = liveSteps.length;
        seq++;
        // Redact steps before they hit the group-visible panel (same safety net
        // as the conclusion text) — a secret/path in a narration step leaks too.
        const safeSteps = redactSteps(liveSteps);
        if (!panelAppended) {
          panelAppended = true;
          appendReasoningPanel(cardId, safeSteps, seq).catch(() => {});
        } else {
          updateReasoningPanel(cardId, safeSteps, seq).catch(() => {});
        }
        return;
      }
      // Conclusion area: stream the answer text as it arrives. While the agent
      // is still narrating between tool calls, the newest text is provisional;
      // once it's the genuine final block (no more tools follow) the typewriter
      // lands on it. Placeholder until any real text exists so it never flashes
      // empty.
      const now = Date.now();
      if (now - lastUpdate < THROTTLE_MS) return;
      lastUpdate = now;
      const display = textSoFar.length > 0 ? redactSensitive(textSoFar) : "正在分析…";
      lastDisplay = display;
      seq++;
      updateContent(cardId, display, seq).catch(() => {});
    },
    abort.signal,
    );
  } finally {
    stopHeartbeat(); // ALWAYS clear the animation timer — no leak in the always-on process
    abortControllers.delete(cardId);
  }
  const { status, answer, steps, aborted, error, timing } = result;
  // Structured perf line (grep '"perf":true' | jq): one row per invoke with the
  // latency breakdown — sign / time-to-first-byte / time-to-first-token / stream
  // duration (the long pole = model + tool turns) / total / SSE event count.
  log({ perf: true, event: "invoke_timing", card: cardId, ...timing });

  // A backend failure must NEVER masquerade as a completed answer — that is the
  // "silent wrong answer when the index is unavailable" mode the code-as-only-
  // truth design forbids (system.md: 出错就说出错). Two failure shapes:
  //   (a) non-200 HTTP — e.g. 403 when the SigV4 creds expired, 4xx/5xx from
  //       AgentCore. Earlier this THREW, which left the already-sent streaming
  //       card stuck forever in "正在分析…" (never closed); the IM path showed a
  //       misleading "卡片渲染失败" while the follow-up path showed nothing.
  //   (b) a top-level error event over an open 200 stream (CodeGraph/index-
  //       service unreachable, model throttled, run errored).
  // Both now fold into `failed` so the SAME path finalizes the card explicitly
  // (red header, no charts, no follow-ups) instead of throwing or hanging.
  const { failed, httpFailed } = classifyInvokeOutcome({ status, aborted, error });
  if (httpFailed) log({ event: "invoke_http_error", card: cardId, status });

  // A Bedrock model-access denial (common on a freshly-deployed account where
  // model access isn't enabled yet) is operator-actionable, not a transient —
  // surface a specific hint instead of the generic "稍后重试".
  const accessDenied = !!error && /accessdenied|don't have access|not authorized to invoke/i.test(error);
  // Hitting the agentic-loop turn cap is PARTIAL PROGRESS, not a backend outage:
  // re-asking the same broad question just re-hits the cap, so "retry" is wrong
  // advice — tell the user to NARROW the question (like the timeout branch), and
  // surface any partial conclusion (clearly labeled) instead of discarding it.
  // NOTE: detectEventError (parse-stream.ts) returns the ResultMessage's `result`
  // field FIRST when present — for a turn cap that is the SDK's "Maximum turns
  // exceeded" text, NOT the `error_max_turns` subtype token — so the regex must
  // match that human string too, or a turn cap is misclassified as a hard failure
  // (red card, partial discarded). The subtype-token forms remain as a fallback.
  const turnCapped = isTurnCapError(error);
  // "Hard failure" = a real outage/denial (discard partial, it's untrustworthy).
  // A turn-cap is handled on its own branch below, NOT as a hard failure.
  const hardFailed = failed && !turnCapped;

  // 3. Final update + close streaming. Pull any ```chart blocks out of the
  //    answer first so the conclusion text is clean (charts render separately).
  const rawFinal = hardFailed
    ? (accessDenied
        ? "⚠️ 模型访问未开通：请在 AWS Bedrock 控制台为该模型开通 Model access（global.* 跨区域推理需在相关区域分别开通），开通后即可正常回答。"
        : "⚠️ 查询失败（后端不可用或取证中断），请稍后重试；若持续失败请转研发。")
    : turnCapped
      ? (answer
          ? answer + "\n\n*（分析步骤较多，未在限定步数内完成；以上为已得到的部分结论，建议把问题缩小后再问，例如只问某一个符号 / 某一处影响）*"
          : "⚠️ 这个问题分析步骤较多，未在限定步数内得出结论。请把问题缩小（如只问某一个符号 / 某一处影响）后重试。")
    : aborted
      ? (answer ? answer + "\n\n*（已停止，以上为已生成内容）*" : "⏹ 已停止。")
      : timedOut && !answer
        ? "⏱ 分析超时，请缩小问题范围后重试。"
        : (answer || "(无内容)");
  // On HARD failure, suppress any partial chart/answer fragments — not trustworthy.
  // A turn-capped partial IS shown (labeled incomplete), so parse its charts too.
  const { text: textNoCharts, charts } = hardFailed ? { text: rawFinal, charts: [] } : extractCharts(rawFinal);
  // Strip the "💡 你可能还想问" trailer from the rendered body — those questions
  // become clickable footer buttons below, so leaving them in the prose shows
  // them twice (and clutters the card the prompt was rewritten to keep clean).
  // The full text (with trailer) is still used for extractFollowUps further down.
  const finalText = redactSensitive(hardFailed ? textNoCharts : stripFollowUps(textNoCharts));
  // Best-effort, independently guarded: if updateContent throws (transient
  // CardKit/lark-cli error, or a sequence rejection racing the last fire-and-
  // forget onChunk update), closeStreaming and finalizeCard MUST still run —
  // otherwise an aborted/finished card stays stuck in "正在分析…" with streaming
  // on and a dead 停止 button (finalizeCard's full PUT is what clears both).
  seq++;
  try { await updateContent(cardId, finalText, seq); } catch (e) { log({ event: "finalize_content_error", card: cardId, error: String(e) }); }
  seq++;
  try { await closeStreaming(cardId, seq); } catch (e) { log({ event: "close_streaming_error", card: cardId, error: String(e) }); }

  // 4. Finalize: header → green "回答完成" (or 已停止 / 查询失败) + reasoning panel
  //    collapsed. The full-card PUT rebuilds the body (conclusion + panel), which
  //    also drops the now-irrelevant 停止 button.
  seq++;
  try { await finalizeCard(cardId, finalText, redactSteps(steps), seq, isFollowUp, aborted, hardFailed); } catch { /* best-effort */ }
  // 5. Data charts + follow-ups: skip on HARD failure (no trustworthy conclusion).
  //    A turn-capped partial keeps its charts/follow-ups (labeled incomplete).
  if (!hardFailed && charts.length > 0) {
    // Charts are pulled from the UNredacted answer (extractCharts ran on rawFinal),
    // so scrub every string leaf of each spec before it hits the group-visible
    // card — same secret/path safety net as the conclusion and reasoning panel.
    const safeCharts = charts.map((c) => redactDeep(c));
    seq++;
    try { await appendCharts(cardId, safeCharts, seq); } catch (e) { log({ event: "chart_error", error: String(e) }); }
  }
  if (!hardFailed) {
    seq++;
    // Extract from the UNstripped text (finalText had the trailer removed above).
    const followUps = extractFollowUps(redactSensitive(textNoCharts));
    try { await appendFooter(cardId, seq, followUps); } catch { /* best-effort */ }
  }
  log({ event: "card_closed", card: cardId, chars: answer.length, charts: charts.length, timedOut, failed, turnCapped, error: error ?? undefined });
}

async function main(): Promise<void> {
  if (!RUNTIME_ARN) throw new Error("RUNTIME_ARN env is required");
  // Hold the credential PROVIDER, not a one-time resolved snapshot. EC2 instance-
  // role creds (IMDS) are temporary; resolving once at startup and reusing the
  // snapshot for the lifetime of this always-on process meant every invoke 403'd
  // once those creds expired (~hours in). The provider re-resolves (and refreshes)
  // per sign. fromNodeProviderChain() memoizes internally and only hits IMDS when
  // the cached creds are near expiry, so this is cheap to call per request.
  const credentials = fromNodeProviderChain();

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
      await streamingCardInvoke(res.sessionId, prompt, { messageId: res.messageId }, credentials);
    } catch (cardErr) {
      // streamingCardInvoke now finalizes the card itself on backend failure
      // (non-200 / stream error), so reaching here means something unexpected
      // broke (e.g. the initial card create/send). Fall back to plain text and
      // keep the message neutral — it is NOT necessarily a card-render issue.
      log({ event: "card_fallback", error: String(cardErr) });
      // If streamingCardInvoke threw BEFORE it removed the "processing" reaction
      // (e.g. the initial createCard / card-send failed at index.ts:97-109), that
      // emoji is still stuck on the user's message. Clear it here so a failed
      // answer doesn't leave the message looking perpetually "in progress".
      removeReaction(res.messageId);
      // Static import (top of file): a dynamic import("./reply.js") fails to
      // resolve under ts-node (the .js specifier hits Node's native ESM loader,
      // which can't find the .ts source) — that would make the FALLBACK itself
      // throw and the user get nothing. Log the fallback's own failure too.
      await sendReply({ messageId: res.messageId, answer: `⚠️ 暂时无法回答（服务异常），请稍后重试：\n\n${prompt}` })
        .catch((e) => log({ event: "fallback_error", error: String(e) }));
    }
    log({ event: "replied", message: hashUserId(res.messageId), session: res.sessionId });
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
        void handleMessageEvent(event, { invoke }, { botOpenId: BOT_OPEN_ID || undefined })
          .then(replyWithCard)
          .catch((err) => log({ event: "handle_error", error: String(err) }));
      }
      return {};
    },
    "card.action.trigger": (data: unknown) => {
      try {
        const d = data as {
          action?: { value?: { action?: string; text?: string; eid?: string; card_id?: string } };
          context?: { open_chat_id?: string; open_message_id?: string };
        };
        const value = d?.action?.value;
        const chatId = d?.context?.open_chat_id ?? "";
        const messageId = d?.context?.open_message_id ?? "";
        if (value?.action === "stop" && value.card_id) {
          // 停止: abort the in-flight agent stream for this card. The invoke
          // then finalizes with whatever was generated, header → ⏹ 已停止.
          const ctrl = abortControllers.get(value.card_id);
          log({ event: "stop_clicked", card: value.card_id, found: !!ctrl });
          if (ctrl) ctrl.abort();
        } else if (value?.action === "follow_up" && value.text && chatId) {
          // Hash the chat id; log only the question LENGTH, not the text, to
          // avoid "who asked what" profiling in logs (data minimization).
          log({ event: "follow_up_clicked", chatId: hashUserId(chatId), question_len: value.text.length });
          const sessionId = getSessionId(chatId);
          void streamingCardInvoke(sessionId, value.text, { chatId }, credentials)
            .catch((e) => log({ event: "follow_up_error", error: String(e) }));
          // Mark the clicked button: disable it + ✓ on the original card, so the
          // user sees which one they picked (best-effort, async).
          const cardId = lookupCard(messageId);
          if (cardId && value.eid) {
            // int32-safe, streaming-seq-beating, AND strictly monotonic even for
            // same-second rapid clicks (see nextCallbackSeq).
            const seq = nextCallbackSeq();
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
