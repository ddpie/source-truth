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
import { splitEvidence } from "./extract-evidence";
import { handleMessageEvent, type InvokeFn } from "./handle-event";
import { sdkEventToImEvent } from "./sdk-event";
import { sendReply } from "./reply";
import { getSessionId } from "./session-map";
import { SessionSerializer } from "./serialize-session";
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

// Serialize invokes per runtimeSessionId so two turns never run concurrently on
// the same warm microVM (which would corrupt its one SDK conversation). See
// serialize-session.ts for the why; it's a tested module so the critical
// concurrency logic doesn't live untested in this entry shell.
const sessionSerializer = new SessionSerializer();

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

/** Public entry: dedup, create+send the card EAGERLY (so a queued request shows
 *  feedback and is abortable immediately), then serialize the actual streaming
 *  per runtimeSessionId so two turns never run concurrently on the same warm
 *  microVM (which would corrupt its one SDK conversation). A busy session CHAINS
 *  the new turn after the in-flight one; while it waits, its card shows 排队中 and
 *  its 停止 button can already cancel it. */
async function streamingCardInvoke(
  sessionId: string,
  prompt: string,
  target: { messageId: string } | { chatId: string },
  credentials: () => Promise<AwsCredentials>,
): Promise<void> {
  // Dedup only IM messages (Feishu re-delivers them on restart). Follow-up
  // clicks (chatId target) are deliberate user actions — never dedup them, or a
  // second follow-up in the same chat would be silently dropped. Done BEFORE any
  // card/session work so a re-delivery creates no duplicate card.
  if ("messageId" in target && isDuplicate(`msg:${target.messageId}`)) return;

  const queued = sessionSerializer.isBusy(sessionId);
  if (queued) log({ event: "session_busy_queued", session: sessionId });

  // Create + send the card NOW, not when the serialized turn starts. Without this
  // a follow-up (or a 2nd message in the same chat) chained behind a 9-minute
  // stream would show NO card and couldn't be 停止'd until it finally began. The
  // abort handle is registered here too, so 停止 cancels even a still-queued turn.
  const card = await sendStreamingCard(sessionId, prompt, target, queued);

  return sessionSerializer.serialize(sessionId, () =>
    runStreamingInvoke(card, sessionId, prompt, credentials),
  );
}

/** Create + send the streaming card, register its abort handle, and (when the
 *  session is busy) show a 排队中 header + 停止 button. Returns the cardId +
 *  AbortController + the next free sequence number so the deferred streaming body
 *  reuses the same card (instead of creating a second one) and never collides
 *  with the seqs the queued-state updates already consumed. */
async function sendStreamingCard(
  sessionId: string,
  prompt: string,
  target: { messageId: string } | { chatId: string },
  queued: boolean,
): Promise<{ cardId: string; abort: AbortController; startSeq: number; isFollowUp: boolean }> {
  const targetKey = "messageId" in target ? target.messageId : target.chatId;
  // Follow-up cards carry a "↳ 追问" summary marker so the chat history shows
  // where they came from.
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
    // Remember the sessionId too, so a follow-up click on THIS card resumes the
    // exact same warm session (preserves conversation context even for threaded
    // questions, whose thread_id the callback payload doesn't carry).
    if (sentMessageId) rememberCard(sentMessageId, cardId, sessionId);
  } catch { /* best-effort: button-disable is a visual nicety */ }
  log({ event: "card_sent", target: hashUserId(targetKey), card: cardId });

  // Remove the "processing" reaction now that the card is visible.
  if ("messageId" in target) removeReaction(target.messageId);

  // Register the abort handle NOW (not inside the deferred body), so 停止 can
  // cancel a turn that's still queued behind another invoke on this session.
  const abort = new AbortController();
  abortControllers.set(cardId, abort);

  let startSeq = 1;
  if (queued) {
    // Honest header while the turn waits behind another invoke on this session.
    // ONLY the header (a full-card PUT of the conclusion area) — deliberately NO
    // appended 停止 button here: the streaming path's whole invariant is "no
    // appended elements exist during the thinking phase, so the heartbeat's
    // full-card PUTs are safe to wipe-and-replace the body". A queued button
    // would be an appended element that the first thinking-phase heartbeat PUT
    // wipes anyway (and could race the analyzing-flip append into a DUPLICATE
    // button). So we keep the card consistent with every normal card: the 停止
    // button appears at the analyzing flip. The abort handle is already
    // registered, and the in-flight card's own 停止 lets the user end the
    // blocking turn early. This consumes seq 1; hand the body seq 2+.
    await updateStage(cardId, "⏳ 排队中（正在等待上一个问题分析完成）", "orange", "排队中…", 1).catch(() => {});
    startSeq = 2;
  }
  return { cardId, abort, startSeq, isFollowUp };
}

/** Streaming invoke body: streams the agent's answer onto the pre-created card
 *  and finalizes it. Runs inside the per-session serializer, so at most one body
 *  per runtimeSessionId is live at a time. */
async function runStreamingInvoke(
  card: { cardId: string; abort: AbortController; startSeq: number; isFollowUp: boolean },
  sessionId: string,
  prompt: string,
  // A credential PROVIDER, not a snapshot: SignatureV4 re-resolves it on every
  // sign, so EC2 instance-role (IMDS) temporary creds get refreshed instead of
  // going stale and 403-ing every invoke after a few hours of uptime.
  credentials: () => Promise<AwsCredentials>,
): Promise<void> {
  const { cardId, abort, isFollowUp } = card;

  // 2. Stream the agent's answer; update card content incrementally.
  //    9-minute safety timeout: close streaming gracefully before Feishu's
  //    10-minute hard window kills the stream (avoids broken card state).
  //    seq starts above any sequence the queued-state card already used.
  let seq = card.startSeq;
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
    // The header animation uses updateStage = a FULL-card PUT, which replaces the
    // whole body and would WIPE any separately-appended elements (the 停止 button
    // and the live 分析过程 panel). So the heartbeat may ONLY drive the header
    // while NO such elements exist yet — i.e. the early "thinking" phase, before
    // the first tool call flips stage→analyzing and appends them. Once we're in
    // analyzing, the typewriter + live panel ARE the animation; the heartbeat
    // must NOT full-PUT (it would delete the stop button mid-run → user can't
    // abort, and flicker the panel). It self-stops driving but keeps the watchdog
    // off the critical path by simply returning here.
    if (stage !== "thinking") return;
    // Even in the thinking phase the conclusion CAN stream (the agent narrates
    // before its first tool call). When it does, the content typewriter is
    // already PUTting at up to 10/s; adding the heartbeat's ~1.25/s on top would
    // exceed CardKit's 10/s cap and silently drop frames. The typewriter IS the
    // animation while text flows, so skip this header tick if content updated
    // within the last beat — keeps the combined rate at/under the cap.
    if (Date.now() - lastUpdate < 800) return;
    const sinceEvent = Date.now() - lastEventAt;
    const elapsed = Math.floor((Date.now() - startedAt) / 1000);
    const spin = SPINNER[spinFrame++ % SPINNER.length];
    // Watchdog: >15s with no new event → say so honestly, don't fake progress.
    const label = sinceEvent > 15000
      ? `${spin} 仍在思考（较久）${elapsed}s`
      : `${spin} 正在分析 ${elapsed}s`;
    seq++;
    // body still the placeholder "正在分析…" in thinking phase → nothing to wipe.
    updateStage(cardId, label, "orange", lastDisplay, seq).catch(() => {});
  }, 800);

  // The abort handle was created + registered in abortControllers at card-send
  // time (so 停止 can cancel even a still-queued turn); reused here as-is. If the
  // user already pressed 停止 while this turn was queued, abort.signal is already
  // aborted and invokeRuntimeStreaming returns immediately with aborted=true.

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
      // Stage 2 (思考→分析): on the first tool call, set the orange header ONCE
      // (this is the LAST full-card PUT — nothing appended yet to wipe), then add
      // the 停止 button. After this flip the heartbeat stops full-PUTting (it
      // gates on stage==="thinking"), so the button + live panel appended here and
      // below survive; the typewriter + live panel are the animation from now on.
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

  // 3. Final update + close streaming. Order matters so the "供研发复核" evidence
  //    folds correctly AND any incompleteness disclaimer stays VISIBLE (not swept
  //    into the folded panel):
  //    raw answer → extractCharts → stripFollowUps → splitEvidence → THEN append
  //    the aborted/turn-capped disclaimer to the (evidence-free) body.
  let bodyNoEvidence: string;
  let evidence = "";
  let charts: ReturnType<typeof extractCharts>["charts"] = [];
  if (hardFailed) {
    // Hard failure: a fixed message, no real answer/charts/evidence to surface.
    bodyNoEvidence = accessDenied
      ? "⚠️ 模型访问未开通：请在 AWS Bedrock 控制台为该模型开通 Model access（global.* 跨区域推理需在相关区域分别开通），开通后即可正常回答。"
      : "⚠️ 查询失败（后端不可用或取证中断），请稍后重试；若持续失败请转研发。";
  } else {
    const ex = extractCharts(answer);
    charts = ex.charts;
    const { body, evidence: ev } = splitEvidence(stripFollowUps(ex.text));
    evidence = ev;
    // Shape the VISIBLE body: append the incompleteness note AFTER evidence is
    // split off, so the note isn't hidden inside the collapsed panel.
    if (turnCapped) {
      bodyNoEvidence = body
        ? body + "\n\n*（分析步骤较多，未在限定步数内完成；以上为已得到的部分结论，建议把问题缩小后再问，例如只问某一个符号 / 某一处影响）*"
        : "⚠️ 这个问题分析步骤较多，未在限定步数内得出结论。请把问题缩小（如只问某一个符号 / 某一处影响）后重试。";
    } else if (aborted) {
      bodyNoEvidence = body ? body + "\n\n*（已停止，以上为已生成内容）*" : "⏹ 已停止。";
    } else if (timedOut && !body) {
      bodyNoEvidence = "⏱ 分析超时，请缩小问题范围后重试。";
    } else {
      bodyNoEvidence = body || "(无内容)";
    }
  }
  const finalText = redactSensitive(bodyNoEvidence);
  const finalEvidence = redactSensitive(evidence);
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
  try { await finalizeCard(cardId, finalText, redactSteps(steps), seq, isFollowUp, aborted, hardFailed, finalEvidence); } catch { /* best-effort */ }
  // 5. Data charts + follow-ups: skip on HARD failure (no trustworthy conclusion).
  //    A turn-capped partial keeps its charts/follow-ups (labeled incomplete).
  if (!hardFailed && charts.length > 0) {
    // Charts are pulled from the UNredacted answer (extractCharts ran on it),
    // so scrub every string leaf of each spec before it hits the group-visible
    // card — same secret/path safety net as the conclusion and reasoning panel.
    const safeCharts = charts.map((c) => redactDeep(c));
    seq++;
    try { await appendCharts(cardId, safeCharts, seq); } catch (e) { log({ event: "chart_error", error: String(e) }); }
  }
  if (!hardFailed) {
    seq++;
    // Extract follow-ups from the RAW answer (still carries the "💡 你可能还想问"
    // trailer that stripFollowUps removed from the rendered body).
    const followUps = extractFollowUps(redactSensitive(answer));
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
          header?: { event_id?: string };
          event_id?: string;
          token?: string;
          action?: { value?: { action?: string; text?: string; eid?: string; card_id?: string } };
          context?: { open_chat_id?: string; open_message_id?: string };
        };
        const value = d?.action?.value;
        const chatId = d?.context?.open_chat_id ?? "";
        const messageId = d?.context?.open_message_id ?? "";
        // Dedup re-delivered callbacks. The IM path dedups on event_id; the
        // callback path had NO idempotency key, so a Feishu re-delivery of a
        // follow_up callback would queue a SECOND invoke on the same session —
        // and the per-session serializer runs both sequentially → a guaranteed
        // DOUBLE answer (cost + a confusing 2nd card). Prefer the callback's own
        // event_id/token (true idempotency key, location varies by SDK payload
        // shape); fall back to a composite (clicked button + source card + chat)
        // that a genuine re-delivery repeats identically while distinct clicks
        // differ. "cb:" prefix keeps this keyspace disjoint from the "msg:" one.
        const cbId = d?.header?.event_id ?? d?.event_id ?? d?.token
          ?? `${value?.action ?? ""}:${value?.eid ?? ""}:${value?.card_id ?? ""}:${messageId}:${chatId}`;
        if (isDuplicate(`cb:${cbId}`)) {
          log({ event: "callback_duplicate", action: value?.action ?? "" });
          return {};
        }
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
          // Resume the EXACT session the original card was answered under, so a
          // threaded question's follow-up keeps its warm context (the callback
          // payload has no thread_id, so re-deriving via getSessionId(chatId)
          // would mint a different, cold session). Fall back to the chat-level
          // session if the card isn't in the registry (evicted / pre-restart).
          const entry = lookupCard(messageId);
          const sessionId = entry?.sessionId ?? getSessionId(chatId);
          // Observability for the cold-session fallback: when the original card's
          // session is gone (registry evicted past the 500-cap, or wiped by a
          // gateway restart), we re-derive via getSessionId(chatId) — which, for a
          // question originally asked in a THREAD, mints a fresh/cold session that
          // silently lacks the prior turn's context. That's exactly the
          // silently-wrong-answer mode the project forbids, so emit a signal an
          // operator can alarm on rather than hiding it behind `??`.
          if (!entry?.sessionId) {
            log({ event: "followup_session_fallback", chatId: hashUserId(chatId), reason: entry ? "no_session_on_entry" : "entry_missing" });
          }
          void streamingCardInvoke(sessionId, value.text, { chatId }, credentials)
            .catch((e) => log({ event: "follow_up_error", error: String(e) }));
          // Mark the clicked button: disable it + ✓ on the original card, so the
          // user sees which one they picked (best-effort, async).
          const cardId = entry?.cardId;
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
  // Last-resort backstop for the always-on gateway: an unhandled promise
  // rejection or a stray async throw (e.g. an EventEmitter 'error' with no
  // listener that slipped past our per-call guards) would otherwise terminate
  // the process and take down EVERY in-flight session until a human restarts it.
  // We LOG and KEEP RUNNING — a single dropped event is vastly preferable to the
  // bot going dark. (Individual invokes still finalize their own cards via their
  // own try/catch; this only catches what those miss.)
  process.on("unhandledRejection", (reason) => {
    log({ event: "unhandled_rejection", error: String(reason) });
  });
  process.on("uncaughtException", (err) => {
    log({ event: "uncaught_exception", error: String(err && err.stack ? err.stack : err) });
  });
  main().catch((err) => {
    log({ event: "fatal", error: String(err) });
    process.exit(1);
  });
}
