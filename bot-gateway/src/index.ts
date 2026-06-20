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

import { fromNodeProviderChain } from "@aws-sdk/credential-providers";

import { invokeRuntimeStreaming, classifyInvokeOutcome, isTurnCapError, type AwsCredentials } from "./sigv4";
import { decideFinalize, hardFailureMessage, shapeBody } from "./finalize-decision";
import { createCard, updateContent, closeStreaming, finalizeCard, appendFooter, appendClarify, buildSendCardContent, disableFollowUpButton, appendReasoningPanel, updateReasoningPanel, appendEvidencePanel, updateEvidencePanel, appendOneChart, MAX_CHARTS, appendStopButton, appendStatusLine, updateStatusLine, formatElapsed, type ActionButton } from "./cardkit-client";
import { extractCharts } from "./extract-charts";
import { rememberCard, rememberAnswer, lookupCard, collectChain } from "./card-registry";
import { composeFollowUpPrompt } from "./followup-context";
import { removeReaction } from "./reaction";
import { redactSensitive, redactSteps, redactDeep } from "./redact";
import { extractFollowUps, stripFollowUps } from "./extract-followups";
import { splitEvidence } from "./extract-evidence";
import { stripPreamble } from "./strip-preamble";
import { stripToolCallLeak, isToolCallLeakDominant } from "./strip-toolcall-leak";
import { normalizeBlocks } from "./normalize-blocks";
import { t, initI18n, currentLocale } from "./i18n";
import { extractClarification } from "./extract-clarify";
import { handleMessageEvent, type InvokeFn } from "./handle-event";
import { classifyWsError } from "./index-core";
import { sdkEventToImEvent } from "./sdk-event";
import { sendReply } from "./reply";
import { imReply, imSendToChat } from "./feishu-http";
import { getSessionId } from "./session-map";
import { SessionSerializer } from "./serialize-session";
import { Semaphore } from "./semaphore";
import { CardWriter } from "./card-writer";
import { hashUserId } from "./log";
import { isDuplicate, forget } from "./dedup";

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

// Per-field caps for the finalized card body. A Feishu interactive card has a
// total body-size limit; the finalize step rebuilds the WHOLE card in one PUT
// (conclusion + reasoning panel + evidence), so an over-long conclusion or a huge
// echoed config table in the evidence could push the PUT past the limit → CardKit
// 400s the request. That failure is SWALLOWED by the serial CardWriter (a dropped
// write must never wedge the queue), so the card would silently stay stuck
// mid-stream (header blue "正在分析…", no footer) — the exact frozen-card failure the
// design forbids. Clamp each field well under the limit BEFORE the PUT so finalize
// always fits and lands. The agent's max_turns + prompt normally keep answers short;
// this is the backstop for a pathological long answer / large evidence dump.
const MAX_CARD_BODY_CHARS = 9000;     // conclusion (prose; charts/tables are separate)
const MAX_CARD_EVIDENCE_CHARS = 9000; // 供研发复核 citations block
function clampForCard(text: string, max: number): string {
  if (text.length <= max) return text;
  // Cut on a line boundary when one is near the limit so we don't slice mid-markup,
  // and append a clear truncation marker (the dev-review panel still carries the
  // file:line citations, so a research can read the full source there).
  const head = text.slice(0, max);
  const nl = head.lastIndexOf("\n");
  const cut = nl > max - 400 ? head.slice(0, nl) : head;
  return `${cut}\n\n_（内容较长，已截断；完整依据见“供研发复核”或直接查阅源码）_`;
}

// Message-level dedup uses the shared TTL-bounded `isDuplicate` (dedup.ts) with
// a "msg:" prefix so it can't collide with event_id keys. This replaces an
// earlier unbounded Set that leaked memory in an always-on gateway.

// cardId → AbortController for the in-flight agent stream, so a 停止 button
// click (card.action.trigger) can abort that specific invoke.
const abortControllers = new Map<string, AbortController>();

// GRACEFUL SHUTDOWN (module scope so the SIGTERM/SIGINT handlers can be registered
// at the very TOP of main(), before the async startup awaits — a SIGTERM arriving
// DURING startup must still exit cleanly). Without graceful shutdown a SIGTERM
// (every deploy / supervisor bounce / docker stop) kills the process instantly and
// abandons every in-flight stream — its heartbeat stops and finalizeCard never
// runs, so the card is stuck on "正在分析…" FOREVER. Instead: abort all in-flight
// invokes (each hits its own abort path → finalizes its card to "已停止"), give the
// finalize writes a brief bounded window to land, then exit. wsRef is set once the
// WSClient exists; the stop is best-effort (not in the SDK's public types).
let wsRef: { stop?: () => void } | undefined;
let shuttingDown = false;
function gracefulShutdown(sig: string): void {
  if (shuttingDown) return;
  shuttingDown = true;
  log({ event: "shutdown_begin", signal: sig, inflight: abortControllers.size });
  try { wsRef?.stop?.(); } catch { /* no-op if absent — abort-all below is load-bearing */ }
  for (const ctrl of abortControllers.values()) {
    try { ctrl.abort(); } catch { /* each invoke finalizes its own card on abort */ }
  }
  // Bounded drain: give the abort-path finalize writes time to reach CardKit, then
  // exit regardless (never hang a deploy on a wedged finalize). 8s (was 3s): a single
  // finalize PUT that hits a Feishu 429 backs off up to ~250+500+1000ms + RTT, and
  // several concurrent in-flight cards contend for CardKit's 10/s cap, so 3s could
  // expire mid-finalize and exit(0) would truncate it → a frozen card, the exact
  // thing abort-all exists to avoid. 8s covers a finalize-with-retry while still
  // bounding the redeploy (cross-review).
  const deadline = Date.now() + 8000;
  const waitDrain = (): void => {
    if (abortControllers.size === 0 || Date.now() > deadline) {
      log({ event: "shutdown_done", drained: abortControllers.size === 0 });
      process.exit(0);
    }
    setTimeout(waitDrain, 150);
  };
  waitDrain();
}

// Serialize invokes per runtimeSessionId so two turns never run concurrently on
// the same warm microVM (which would corrupt its one SDK conversation). See
// serialize-session.ts for the why; it's a tested module so the critical
// concurrency logic doesn't live untested in this entry shell.
const sessionSerializer = new SessionSerializer();
// GLOBAL invoke concurrency gate. Per-session serialization bounds same-session
// turns but NOT distinct sessions — a burst of N different users in a busy group
// would otherwise fire N concurrent AgentCore invokes (cost/throttle/memory). Cap
// the number running at once across ALL sessions; excess waits for a slot (its card
// is already sent eagerly, so the user sees 排队中/思考, not silence). Operator-tunable
// via MAX_CONCURRENT_INVOKES; default 8 balances throughput vs. AgentCore pressure.
const _maxConc = Number(process.env.MAX_CONCURRENT_INVOKES);
const invokeGate = new Semaphore(Number.isFinite(_maxConc) && _maxConc > 0 ? _maxConc : 8);

// Monotonic sequence for card-callback (button-disable) updates. Based on Unix
// seconds since a 2025 epoch (stays int32 for ~60y, and is orders of magnitude
// above any streaming seq reached in one card's lifetime — a 9-min run at the
// 200ms status cadence reaches only the low thousands). A counter guarantees
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
  // The CLEAN user question for display/registry (defaults to prompt). For a
  // follow-up, `prompt` carries the replayed prior-turn context but the card
  // preview + the question we remember must be the bare follow-up text, or a
  // follow-up-of-a-follow-up would replay the whole composed blob as the "question".
  question?: string,
  // The message_id this turn follows up / replies to, so the registry can chain
  // it to its parent and a later follow-up walks the whole history.
  parentMessageId?: string,
  // open_id of the asker, stored so a bare reply to this card is auto-answered
  // only when it comes from the same user (scopes the group reply bypass).
  askerOpenId?: string,
  // OPTIONAL deferred prompt composer. When provided, it is invoked at the START
  // of the serialized turn (i.e. AFTER any in-flight parent turn on this session
  // has finalized) to (re)build the prompt — so a reply to a STILL-STREAMING parent
  // replays the parent's NOW-settled answer instead of a chain missing the most
  // relevant (immediate) turn. Falls back to the eager `prompt` if it returns
  // empty. Pure-ish: it reads the card registry, no side effects.
  composePrompt?: () => string,
  // OPTIONAL upstream Feishu event_id. Only the IM path passes it (that path dedups
  // re-deliveries on event_id in handleMessageEvent); rolled back alongside the
  // `msg:` key if the FIRST card-send fails, so the re-delivery can retry. The
  // follow-up/callback path leaves it undefined (those are deliberate user clicks,
  // never event_id-deduped).
  eventId?: string,
): Promise<void> {
  // Dedup only IM messages (Feishu re-delivers them on restart). Follow-up
  // clicks (chatId target) are deliberate user actions — never dedup them, or a
  // second follow-up in the same chat would be silently dropped. Done BEFORE any
  // card/session work so a re-delivery creates no duplicate card.
  if ("messageId" in target && isDuplicate(`msg:${target.messageId}`)) return;

  // "排队中" shows when this turn won't start streaming immediately — either the
  // SAME session is mid-turn (serializer busy) OR the GLOBAL invoke gate is
  // saturated (all slots held by other sessions). Without the gate check, a turn
  // queued purely by global concurrency showed a frozen "正在分析" with no moving
  // timer (cross-review: the queued flag only covered same-session busy).
  const gateSaturated = invokeGate.stats.available === 0;
  const queued = sessionSerializer.isBusy(sessionId) || gateSaturated;
  if (queued) log({ event: "turn_queued", session: sessionId, reason: sessionSerializer.isBusy(sessionId) ? "session_busy" : "gate_saturated", gateWaiting: invokeGate.stats.waiting });

  // Create + send the card NOW, not when the serialized turn starts. Without this
  // a follow-up (or a 2nd message in the same chat) chained behind a 9-minute
  // stream would show NO card and couldn't be 停止'd until it finally began. The
  // abort handle is registered here too, so 停止 cancels even a still-queued turn.
  // If the SEND ITSELF fails (transient Feishu/token error), roll back BOTH dedup
  // marks so a Feishu re-delivery of this IM event can RETRY:
  //   - `msg:<messageId>` is burned just above (this function's own guard);
  //   - `eventId` (the upstream event_id) is burned EARLIER in handleMessageEvent,
  //     which is the gate the re-delivery actually hits FIRST. Rolling back only the
  //     `msg:` key was dead code: the re-delivery carries the SAME event_id, so it'd
  //     be dropped at handleMessageEvent's event_id gate and never reach here — the
  //     "first-send failure can retry" guarantee silently didn't hold (cross-review).
  //     `eventId` is threaded in for exactly this rollback. Re-throw so the caller logs.
  let card: Awaited<ReturnType<typeof sendStreamingCard>>;
  try {
    card = await sendStreamingCard(sessionId, target, queued, question ?? prompt, parentMessageId, askerOpenId);
  } catch (e) {
    if ("messageId" in target) forget(`msg:${target.messageId}`);
    if (eventId) forget(eventId);
    throw e;
  }

  return sessionSerializer.serialize(sessionId, () => {
    // Recompute the prompt HERE (turn start) if a composer was given: by now the
    // parent turn ahead of us in the serializer has finalized and stored its
    // answer, so collectChain sees the immediate parent turn (the freshness gap a
    // reply-to-a-still-streaming-parent otherwise had).
    const finalPrompt = composePrompt ? (composePrompt() || prompt) : prompt;
    // Hold a GLOBAL concurrency slot only around the heavy AgentCore invoke (the card
    // was already sent eagerly above, so a queued caller still shows 排队中/思考). This
    // caps distinct-session stampede without delaying the user-visible card.
    return invokeGate.run(() => runStreamingInvoke(card, sessionId, finalPrompt, credentials));
  }).finally(() => {
    // SOLE point of AbortController removal. The controller is registered at card-send
    // so 停止 works while the turn is still QUEUED and all through streaming +
    // finalize; this .finally runs only AFTER runStreamingInvoke fully resolves (i.e.
    // after closeStreaming/finalizeCard removed the 停止 button), so the button stays
    // live+functional for the entire card lifetime and is gone exactly when the entry
    // is removed — no dead-button window. Covers EVERY terminal path (resolve, throw,
    // queued-task dropped before its body ran), so no leak in the resident gateway.
    abortControllers.delete(card.cardId);
  });
}

/** Create + send the streaming card, register its abort handle, and (when the
 *  session is busy) show a 排队中 header + 停止 button. Returns the cardId +
 *  AbortController + the next free sequence number so the deferred streaming body
 *  reuses the same card (instead of creating a second one) and never collides
 *  with the seqs the queued-state updates already consumed. */
async function sendStreamingCard(
  sessionId: string,
  target: { messageId: string } | { chatId: string },
  queued: boolean,
  question: string,
  parentMessageId?: string,
  askerOpenId?: string,
): Promise<{ cardId: string; abort: AbortController; startSeq: number; isFollowUp: boolean; sentMessageId?: string; question: string; statusSeeded: boolean; stopButtonSeeded: boolean }> {
  const targetKey = "messageId" in target ? target.messageId : target.chatId;
  // REDACT the user's question before it touches any group-visible / persisted /
  // replayed surface. The question is user-typed and a 策划 could paste a secret
  // into it ("为什么 xoxb-… 调用失败"); without this it would leak three ways — the
  // group-visible ❓ echo, the card-registry store, and the follow-up replay prompt.
  // redactSensitive is the same net applied to agent output; apply it ONCE here so
  // the card echo, summary, registry, and (via the stored value) collectChain are
  // all safe. plain_text rendering only stops markdown injection, not secret leak.
  const safeQuestion = redactSensitive(question);
  // Follow-up cards carry a "↳ 追问" summary marker so the chat history shows
  // where they came from. Use the CLEAN question for the preview (prompt may be
  // the replayed-context blob for a follow-up).
  const isFollowUp = "chatId" in target;
  const summary = isFollowUp ? `${t("summary.followup.prefix")}${safeQuestion}` : safeQuestion;
  // Echo the question in the card body (esp. for follow-ups, so the card shows
  // WHAT was asked without scrolling). Pass it to createCard as the "question"
  // element; finalizeCard re-includes it so the full-PUT doesn't wipe it.
  const cardId = await createCard(summary, isFollowUp, safeQuestion);
  // Send the card in-process (HTTP), not via `spawn lark-cli` (~800ms): this is
  // on the first-render path, so the spawn cost delayed every answer's first
  // paint. Returns the sent message_id for the follow-up registry.
  const cardContent = buildSendCardContent(cardId);
  // Idempotency key for the send: cardId is unique per logical card (freshly created
  // just above) yet STABLE across a transport retry of THIS same send — so if
  // feishuApi re-sends after a 429/timeout that the backend already committed, Feishu
  // dedupes within its 1h window and we don't post a duplicate card (cross-review H1).
  const sendUuid = `card-${cardId}`;
  const sentMessageId = "messageId" in target
    ? await imReply(target.messageId, "interactive", cardContent, sendUuid)
    : await imSendToChat(target.chatId, "interactive", cardContent, sendUuid);
  // Record message_id → card_id so a follow-up click (which only carries
  // open_message_id) can find this card and disable the clicked button. Remember
  // the sessionId too, so a follow-up on THIS card resumes the same warm session
  // (preserves context even for threaded questions whose thread_id the callback
  // payload doesn't carry).
  // Store the question too, so a follow-up on this card can replay the prior
  // turn (question + answer, filled in at finalize) as stateless context.
  if (sentMessageId) {
    rememberCard(sentMessageId, cardId, sessionId, safeQuestion, parentMessageId, askerOpenId);
  } else {
    // Send accepted but no message_id in the response → the card can't be
    // registered, so a later follow-up/reply can't find it and silently loses
    // context. Log it (operator-visible) so "entry_missing" follow-ups are
    // diagnosable vs a normal eviction.
    log({ event: "card_sent_no_message_id", target: hashUserId(targetKey), card: cardId });
  }
  // sentMessageId is the BOT's OWN card message_id (the bot's public message in the
  // chat — not PII, unlike the asker's id which stays hashed). Logging it lets ops
  // correlate a card_id to the actual Feishu message for read-back/diagnosis.
  log({ event: "card_sent", target: hashUserId(targetKey), card: cardId, messageId: sentMessageId ?? null, hasMessageId: !!sentMessageId });

  // Remove the "processing" reaction now that the card is visible.
  if ("messageId" in target) removeReaction(target.messageId);

  // Register the abort handle NOW (not inside the deferred body), so 停止 can
  // cancel a turn that's still queued behind another invoke on this session.
  const abort = new AbortController();
  abortControllers.set(cardId, abort);

  let nextSeq = 1;
  // Append the 停止 button at CARD-SEND time so it exists for the ENTIRE life of
  // the card — including while the turn is still QUEUED behind another invoke, and
  // during the whole 思考 phase before the first tool call. Previously it was only
  // appended at the 思考→分析 flip (onChunk, liveSteps>0), so a queued turn and the
  // early thinking phase had a registered AbortController but NO button to trigger
  // it — the user couldn't stop, contradicting the design (and the past "停止没反应"
  // report). The heartbeat is element-level (updates only the `status` element),
  // so an appended button is never wiped until the finalize full-PUT. Track success
  // so the onChunk flip / runtime path don't double-append.
  let stopButtonSeeded = false;
  try {
    await appendStopButton(cardId, nextSeq);
    stopButtonSeeded = true;
    nextSeq += 1;
  } catch { /* seed failed → onChunk flip will append it (self-healing) */ }

  let statusSeeded = false;
  if (queued) {
    // Honest "排队中" indicator while the turn waits behind another invoke on this
    // session. Write it into the SAME `status` element the running heartbeat uses
    // (NOT a header full-PUT) so that when this turn dequeues, the heartbeat's
    // updateStatusLine OVERWRITES "排队中" in place → it cleanly becomes "正在分析".
    // (The old header full-PUT left the header stuck on "排队中" forever — the
    // heartbeat drives the status element, never the header — and also wiped the
    // question element.) Consumes seq 1; hand the body seq 2+.
    // Set statusSeeded ONLY if the seed append actually succeeded. If it failed,
    // leave it false so the body's heartbeat re-APPENDS the status element (self-
    // healing), instead of forever PUTting a nonexistent /elements/status (the
    // non-queued path relies on exactly this retry-as-append). startSeq advances
    // regardless to keep CardKit's monotonic-sequence contract.
    try {
      await appendStatusLine(cardId, t("card.status.queued"), nextSeq);
      statusSeeded = true;
      nextSeq += 1;
    } catch { /* seed failed → heartbeat will append on its first tick */ }
  }
  // startSeq = the last sequence CONSUMED by seeds above; the CardWriter's first
  // write is startSeq+1, contiguous with the seeds (no skipped seq).
  const startSeq = nextSeq - 1;
  // Return the REDACTED question so finalizeCard re-renders the safe echo (a raw
  // value here would re-leak a secret into the finalized full-PUT card).
  return { cardId, abort, startSeq, isFollowUp, sentMessageId, question: safeQuestion, statusSeeded, stopButtonSeeded };
}

/** Streaming invoke body: streams the agent's answer onto the pre-created card
 *  and finalizes it. Runs inside the per-session serializer, so at most one body
 *  per runtimeSessionId is live at a time. */
async function runStreamingInvoke(
  card: { cardId: string; abort: AbortController; startSeq: number; isFollowUp: boolean; sentMessageId?: string; question: string; statusSeeded: boolean; stopButtonSeeded: boolean },
  sessionId: string,
  prompt: string,
  // A credential PROVIDER, not a snapshot: SignatureV4 re-resolves it on every
  // sign, so EC2 instance-role (IMDS) temporary creds get refreshed instead of
  // going stale and 403-ing every invoke after a few hours of uptime.
  credentials: () => Promise<AwsCredentials>,
): Promise<void> {
  const { cardId, abort, isFollowUp, sentMessageId, question } = card;

  // 2. Stream the agent's answer; update card content incrementally.
  //    9-minute safety timeout: close streaming gracefully before Feishu's
  //    10-minute hard window kills the stream (avoids broken card state).
  //    seq starts above any sequence the queued-state card already used.
  // ALL card writes go through one serial queue (CardWriter): it assigns the
  // sequence at SEND time and awaits each write before the next, so CardKit always
  // sees strictly-increasing sequences in arrival order. This kills the whole
  // class of "two fire-and-forget writes race → the lower-seq one is stale-
  // rejected and dropped" bugs (status wiping the stop button, double stop button,
  // and the 分析过程 panel never appearing — the last one caught in live self-test).
  // onError surfaces a SWALLOWED card-write failure (the chain stays alive best-
  // effort, but a dropped write — esp. a failed finalize after token/throttle
  // retries — must be diagnosable, not silent). Coalesced status/content drops are
  // benign (next frame carries the full value), so they're logged at low signal.
  const writer = new CardWriter(card.startSeq, (label, err) =>
    log({ event: "card_write_dropped", card: cardId, op: label, error: redactSensitive(String(err)).slice(0, 200) }));
  let lastUpdate = 0;
  let lastPanelUpdate = 0;
  let timedOut = false;
  let stage: "thinking" | "analyzing" = "thinking";
  let stepsShown = 0; // how many reasoning steps are currently rendered in the panel
  let panelAppended = false;
  // Live "供研发复核" (dev-review) panel: appended once when evidence first streams,
  // updated in place as more citations arrive. evidenceShown holds the last-RENDERED
  // content so we only push when it actually CHANGED — a content compare, NOT a length
  // compare: stripToolCallLeak is non-monotonic (a streaming <invoke> block strips to
  // less once it closes), so a length gate `len > shownLen` could go false-and-stick
  // when the text shrinks, freezing the panel on stale content (caught in cross-review).
  let evidenceAppended = false;
  let evidenceShown = "";
  // The stop button is normally seeded at card-send time (so it's clickable while
  // queued + during thinking); this tracks that so the 思考→分析 flip only appends
  // it as a self-heal when the seed failed (never a 2nd button).
  let stopButtonSeeded = card.stopButtonSeeded;
  // ~8/s nominal per timer-driven lane (content + panel). NOTE: the nominal per-lane
  // rates do NOT by themselves bound the CardKit-facing rate — content(~8/s) +
  // panel(~8/s) + status(nominal ~5/s at the 200ms tick, throttled to a ~1/s floor
  // mid-stream) can nominally sum >10/s. What actually keeps us under
  // CardKit's 10/s per-card cap is the CardWriter single FIFO chain (card-writer.ts):
  // each write awaits the prior HTTP call and coalesce() collapses each lane to 1
  // pending, so the real outbound rate = 1/(Feishu RTT ~50-150ms). In practice that
  // stays at/under the cap; if Feishu ever speeds up materially, add an explicit
  // min-inter-write gate in CardWriter rather than relying on RTT.
  const THROTTLE_MS = 125;
  // Derive the safety timeout from the external Feishu hard limit so the "must
  // stay below the hard window" invariant is self-documenting (not a magic 9 vs a
  // prose "Feishu closes at 10" comment that can drift if either value changes).
  const FEISHU_STREAM_HARD_LIMIT_MS = 10 * 60 * 1000; // Feishu force-closes a streaming card at 10 min
  const STREAM_TIMEOUT_MS = FEISHU_STREAM_HARD_LIMIT_MS - 60 * 1000; // 1-min margin to finalize gracefully
  const deadline = Date.now() + STREAM_TIMEOUT_MS;
  // The deadline must ACTIVELY abort the invoke, not just set a flag. A flag-only
  // timeout (the old onChunk `if (Date.now() > deadline)` check) only fires when a
  // chunk arrives — a run that streams nothing but never sends the terminal result
  // would keep the fetch/socket open until Feishu's 10-min hard close, leaking the
  // connection and delaying finalize past the 1-min margin (caught in cross-review).
  // So arm a real timer: set timedOut FIRST (so the result is classified as a
  // timeout, not a user 停止), then abort() to cancel the socket. Cleared in finally
  // on every normal exit. unref() so it can't keep the process alive on its own.
  const timeoutTimer = setTimeout(() => {
    timedOut = true;
    abort.abort();
  }, STREAM_TIMEOUT_MS);
  timeoutTimer.unref?.();

  // ── 始终生效的"正在分析"动效 (Claude-Code/Codex 风格: spinner + 秒数 + 阶段词) ──
  // The animation/timer is a DEDICATED body element (element_id="status") updated
  // ELEMENT-LEVEL, NOT the header. The old header-based heartbeat used a full-card
  // PUT, which wipes appended elements (停止 button, 分析过程 panel), so it had to
  // self-disable the moment the analyzing phase appended them — leaving the timer
  // frozen for most of the run (the user's complaint). An element-level update
  // touches only the status line, so the spinner + elapsed-seconds advance in
  // EVERY phase (thinking, analyzing, streaming) without disturbing anything else.
  // The SECONDS counter is the honest signal (monotonic = not frozen); the spinner
  // is decoration; the watchdog says so honestly when no SSE event arrived lately.
  // Typewriter-ellipsis animation (community-standard "AI is typing…" style:
  // restrained + informational, not a flashy spinner). The dots cycle . → .. → …
  // and the live seconds counter carries the honest "still working" signal, so it
  // reads as professional/calm and never looks frozen at the low write cadence.
  const ELLIPSIS = ["·", "··", "···"];
  // MONOTONIC base for the elapsed display + spinner: Date.now() is wall-clock, so an
  // NTP/VM clock step backward mid-stream would make elapsed go negative → the timer
  // visibly JUMPS back to 0s then climbs again (a dim#1「计时晃」violation).
  // performance.now() is monotonic — elapsed only ever increases. (Date.now() stays
  // for throttle deltas + the deadline, where a one-tick skew is harmless.)
  const monoStart = performance.now();
  // If the queued path already created the status element, the heartbeat must
  // UPDATE it in place (so "排队中" → "正在分析" on the same element), not append a
  // second one.
  let statusAppended = card.statusSeeded;
  let heartbeat: ReturnType<typeof setInterval> | undefined;
  const stopHeartbeat = () => { if (heartbeat) { clearInterval(heartbeat); heartbeat = undefined; } };
  // Refresh cadence: the dominant cost is the THINKING/ANALYZING phase (live data:
  // ~68s before the conclusion even starts), and during it NO conclusion content
  // streams — so the status line is the ONLY motion and can safely run fast. We
  // write every STATUS_WRITE_MS=200ms (~5 spinner frames/s, feels smooth, well
  // under CardKit's 10/s). Once the conclusion typewriter IS streaming, the answer
  // text is the motion, so we yield to it (the `< STREAMING_YIELD_MS` skip below)
  // and the combined status+content rate stays under the cap.
  const STATUS_WRITE_MS = 200;
  const STREAMING_YIELD_MS = 200;
  // Max time the elapsed timer may go un-refreshed during active streaming before
  // we force a status write so the counter/ellipsis never visibly freeze (~1/s).
  const STATUS_FLOOR_MS = 1000;
  let lastStatusWrite = 0;
  heartbeat = setInterval(() => {
    if (timedOut || Date.now() > deadline) { stopHeartbeat(); return; }
    const now = Date.now();
    // Throttle the cadence. Coalescing (writer.coalesce) already drops stale
    // frames so a backlog can't build, but we still don't need to enqueue more
    // than ~5 frames/s.
    if (now - lastStatusWrite < STATUS_WRITE_MS) return;
    // Stay under CardKit's per-card 10/s: when the conclusion typewriter is
    // actively streaming (a content update within the last STREAMING_YIELD_MS),
    // the answer text IS the visible motion — yield the status write this tick so
    // status+content don't both fire on every 200ms heartbeat tick. BUT enforce a max-staleness
    // floor: if the timer hasn't been refreshed for STATUS_FLOOR_MS (~1s), write it
    // anyway even mid-stream — otherwise the elapsed counter visibly FREEZES for the
    // entire (tens-of-seconds) conclusion-streaming phase, since content keeps
    // refreshing lastUpdate so the yield would never release. The forced write is
    // quantized to the 200ms heartbeat tick + the 1s floor, so the displayed seconds
    // advance in ~1.0–1.2s steps (may occasionally skip a digit) — it never freezes,
    // which is the requirement. The CardWriter serial+coalesce chain is what bounds
    // the actual CardKit write rate (see THROTTLE_MS note above), not this cadence.
    if (now - lastUpdate < STREAMING_YIELD_MS && now - lastStatusWrite < STATUS_FLOOR_MS) return;
    // Cycle the ellipsis · → ·· → ··· each write. Put it AFTER the seconds so the
    // seconds stay in a FIXED position (the dots changing width before the number
    // made the number jitter left/right). seconds is the live "still working" signal.
    // Derive BOTH the spinner phase and the elapsed seconds from the SAME monotonic
    // elapsed value. The spinner was `frame++` at schedule-time, so a coalesce-DROPPED
    // tick (RTT > cadence) advanced the counter without rendering → the visible dots
    // skipped a phase (·→···). Time-derived: a dropped frame just means the next
    // rendered dot reflects true elapsed time, no desync (dim#1「不晃」).
    const elapsedMs = performance.now() - monoStart;
    const dots = ELLIPSIS[Math.floor(elapsedMs / STATUS_WRITE_MS) % ELLIPSIS.length];
    const elapsed = formatElapsed(elapsedMs);  // s / Mm Ss / Hh Mm
    const phaseWord = stage === "thinking" ? "正在思考" : "正在分析";
    const text = `${phaseWord} ${elapsed}${dots}`;
    lastStatusWrite = now;
    // Latest-wins lane: if a status frame is still queued, this one REPLACES it
    // (stale frames dropped) instead of piling up behind a slow lark-cli spawn —
    // so the timer always shows the CURRENT elapsed time, never a frame queued
    // seconds ago (the "卡在 11s" complaint). Decide append-vs-update at execution
    // time on the live flag so a failed append retries as an append.
    writer.coalesce("status", async (seq) => {
      if (!statusAppended) {
        await appendStatusLine(cardId, text, seq);
        statusAppended = true; // only on success → a throw leaves it false
      } else {
        await updateStatusLine(cardId, text, seq);
      }
    });
  }, STATUS_WRITE_MS);

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
      // The timeoutTimer (armed above) is what enforces the deadline — it sets
      // timedOut + aborts the socket. Here we just stop processing further chunks
      // once that's happened (the abort may have a few in-flight chunks behind it).
      if (timedOut) return;
      // Stage 2 (思考→分析): on the first tool call, flip the stage word. The 停止
      // button is normally already seeded at card-send time (so it exists while
      // queued + during the whole thinking phase). Only append it HERE as a
      // SELF-HEAL if the send-time seed failed — otherwise we'd render a 2nd button.
      if (stage === "thinking" && liveSteps.length > 0) {
        stage = "analyzing";
        if (!stopButtonSeeded) {
          void writer.write(async (seq) => { await appendStopButton(cardId, seq); stopButtonSeeded = true; });
        }
        return;
      }
      // Live reasoning panel: append once, then update in place as steps grow —
      // separate element from the streamed conclusion, so it doesn't fight the
      // typewriter. Only push when a NEW step appeared (not every text chunk).
      // NOTE: this block does NOT early-return — it falls through to the conclusion
      // update below so that a chunk carrying BOTH a new step AND new answer text
      // pushes both on the same tick (the panel and content are independent element
      // lanes). Returning here used to defer the typewriter whenever a step
      // arrived, contributing to the "stall then dump" feel.
      if (liveSteps.length > stepsShown) {
        // Throttle panel pushes (they share CardKit's 10/s entity cap). If we
        // pushed a panel update recently, SKIP just the panel this tick (steps keep
        // accumulating in liveSteps; the next tick renders them all) — but still
        // fall through to the content update below.
        const nowPanel = Date.now();
        if (nowPanel - lastPanelUpdate >= THROTTLE_MS) {
          // Redact steps before they hit the group-visible panel (same safety net
          // as the conclusion text) — a secret/path in a narration step leaks too.
          // redactSteps also DROPS steps that are pure tool-call markup, so safeSteps
          // can be SHORTER than liveSteps (or empty). The live panel must NEVER shrink
          // or vanish mid-stream (the "进展默认展开区突然消失" report): only push when
          // the CLEAN step count actually grew, and never render an empty panel over a
          // non-empty one. Track progress by the CLEAN count, not the raw count.
          const safeSteps = redactSteps(liveSteps);
          if (safeSteps.length <= stepsShown) {
            // Nothing new survived stripping this tick → keep the panel as-is.
          } else {
          lastPanelUpdate = nowPanel; // throttle stamp (schedule-time is fine)
          // Decide append-vs-update at EXECUTION time (inside the serial callback),
          // NOT at schedule time. The CardWriter chain is FIFO, so by the time this
          // callback runs, any earlier panel write has already settled and set
          // panelAppended. CRITICAL: advance stepsShown only AFTER the write actually
          // LANDS (inside the callback), not at schedule time — else a FAILED append
          // would leave panelAppended=false but stepsShown already raised, so the
          // retry gate (safeSteps.length > stepsShown) could stay shut while the
          // clean-step count plateaus → the panel never appears at all (caught in
          // re-review). Capturing `target` and committing it post-await makes a
          // failed append fully self-heal on the next tick.
          const target = safeSteps.length;
          void writer.write(async (seq) => {
            if (!panelAppended) {
              await appendReasoningPanel(cardId, safeSteps, seq);
              panelAppended = true; // only on success → a throw leaves it false
            } else {
              await updateReasoningPanel(cardId, safeSteps, seq);
            }
            stepsShown = target; // only after the write landed (throw → not advanced → retry)
          });
          }
        }
      }
      // Conclusion area: stream the answer text as it arrives. While the agent
      // is still narrating between tool calls, the newest text is provisional;
      // once it's the genuine final block (no more tools follow) the typewriter
      // lands on it. Placeholder until any real text exists so it never flashes
      // empty.
      const now = Date.now();
      if (now - lastUpdate < THROTTLE_MS) return;
      lastUpdate = now;
      // Strip the evidence (供研发复核) section and the 你可能还想问 follow-up trailer
      // from the LIVE conclusion so the typewriter shows ONLY clean business prose.
      // Both helpers are marker-keyed and pure: they no-op when the marker hasn't
      // streamed yet (so the partial answer shows normally), and once the agent
      // emits the `供研发复核` heading the raw file:line block stops appearing inline.
      // Without this, the reader watches the raw evidence block + 💡 trailer type
      // out and then finalize abruptly re-lays-them-out (the "noise then snap"). The
      // evidence still appears — folded — at finalize via the unchanged splitEvidence
      // path. Charts are deliberately NOT stripped live (extractCharts on an
      // unclosed fence is fragile; the chart fence streams briefly then renders at
      // finalize, same as before).
      let display = "正在分析…";
      let liveEvidence = "";
      if (textSoFar.length > 0) {
        // Split evidence FIRST, then strip follow-ups from the BODY only. The reverse
        // order (stripFollowUps then splitEvidence) silently LOSES the evidence block
        // when the model emits the 你可能还想问 trailer BEFORE 供研发复核 — stripFollowUps'
        // greedy `…[\s\S]*$` would eat the evidence too (cross-review HIGH). Splitting
        // evidence off first confines each extractor to its own partition.
        const split = splitEvidence(textSoFar);
        const body = stripFollowUps(split.body);
        // Strip the followup trailer from evidence too (it often follows 供研发复核 in
        // the model output) so the live dev-review panel never shows it — mirrors the
        // finalize path; the real buttons render separately.
        liveEvidence = stripFollowUps(split.evidence);
        // Drop a planning preamble ("现在我整理答案…" + ---) that leaked into the
        // conclusion block so the typewriter shows 结论先行 from the first line. Marker-
        // keyed + conservative: no-op until the preamble's `---` has streamed.
        // normalizeBlocks (additive newlines only) also repairs jammed ###/---/>
        // live so the typewriter doesn't briefly show literal markers mid-paragraph.
        // stripToolCallLeak: on the MCP-init-race failure (cold microVM whose MCP
        // tools didn't register), the model emits raw <invoke> tool-call XML as text;
        // strip it LIVE so the user never watches that markup type out (finalize also
        // strips + may show a clean failure message, but the live stream must not leak).
        // ORDER: redact LAST (outermost). Stripping a tag can re-join the two halves of
        // a secret that a `<parameter …>` split, so redaction must run AFTER strip or a
        // leaked tail survives this live frame (finalize already orders it strip→redact;
        // the live path had it inverted — cross-review P1).
        display = redactSensitive(stripToolCallLeak(normalizeBlocks(stripPreamble(body.length > 0 ? body : textSoFar))));
        if (!display.trim()) display = "正在分析…";
        // Clamp the LIVE update too: a runaway-long stream could 400 the per-frame PUT
        // (coalesced → silently dropped → typewriter appears to freeze) before finalize
        // even runs. Same cap as the finalized body. (finalize re-clamps independently.)
        display = clampForCard(display, MAX_CARD_BODY_CHARS);
      }
      // Latest-wins lane: each content update carries the FULL text so far, so a
      // queued-but-not-yet-sent frame is stale and is replaced — the typewriter
      // shows the newest text without a backlog stalling behind a slow spawn.
      writer.coalesce("content", (seq) => updateContent(cardId, display, seq));
      // LIVE 供研发复核 panel: once the evidence section starts streaming, render it
      // (folded) so the dev can watch citations form, instead of only at finalize.
      // Redact + strip-leak the same as the body. Push when the CLEAN evidence CHANGED
      // (content compare — see evidenceShown: a length gate sticks shut when strip-leak
      // shrinks the text). Use a COALESCE lane ("evidence") rather than one-shot write():
      // coalescing keeps only the latest pending frame (always the newest content) and
      // drops stale intermediates, so two ticks reading the same pre-commit evidenceShown
      // can't land a shorter frame after a longer one (the content-regression window the
      // one-shot path had). Append-vs-update is decided at run-time inside the serial
      // callback: evidenceAppended flips only on a successful append and evidenceShown
      // commits only after the write lands, so a failed append self-heals on the next
      // tick. finalizeCard re-renders the same element_id="evidence" (no re-layout).
      const safeEvidence = liveEvidence.trim()
        ? stripToolCallLeak(redactSensitive(liveEvidence)).trim()
        : "";
      if (safeEvidence && safeEvidence !== evidenceShown) {
        const target = safeEvidence;
        writer.coalesce("evidence", async (seq) => {
          if (!evidenceAppended) {
            await appendEvidencePanel(cardId, target, seq);
            evidenceAppended = true;
          } else {
            await updateEvidencePanel(cardId, target, seq);
          }
          evidenceShown = target;
        });
      }
    },
    abort.signal,
    );
  } finally {
    stopHeartbeat(); // ALWAYS clear the animation timer — no leak in the always-on process
    // Drop any queued-but-unsent status/content frame so it can't repaint the
    // live timer or stale "正在分析" text ONTO the card AFTER finalize runs (and
    // so the finalize writes aren't stuck behind a backlog — the "停止 no response
    // / card frozen" symptom). finalize uses one-shot write() which lands next.
    writer.dropLanes("status", "content", "evidence");
    clearTimeout(timeoutTimer); // stop the deadline timer on every exit path
    // NB: do NOT delete the abortControllers entry HERE. This finally runs BEFORE the
    // finalize writes below (closeStreaming / finalizeCard's full-PUT that removes the
    // 停止 button). Deleting now would leave a clickable-but-dead button for the whole
    // finalize window (a 停止 click → found:false → no feedback = the "停止没反应"
    // symptom), and would also make gracefulShutdown's drain (waits for
    // abortControllers.size===0) fire BEFORE the "已停止" finalize write flushed.
    // The outer streamingCardInvoke .finally deletes the entry AFTER finalize fully
    // resolves — that's the correct, single point of removal. (cross-review)
  }
  // FINALIZE ORCHESTRATION — guarded. Everything below composes the terminal card
  // (classify outcome → extract charts/evidence → strip/normalize → close streaming →
  // finalizeCard → footer). It runs AFTER the heartbeat was stopped in the finally
  // above, so ANY unexpected throw here (a helper choking on pathological agent
  // output, a missing i18n key, or a re-thrown failed updateContent/closeStreaming
  // write) would otherwise strand the card forever in "正在分析…": timer frozen,
  // streaming_mode still true, 停止 button clickable-but-dead — the exact "card
  // frozen" failure the design forbids. The catch guarantees a clean, self-consistent
  // terminal state instead. (cross-review HIGH)
  try {
  // A timeout aborts the controller too (to cancel the socket), so sigv4 reports
  // aborted=true. Distinguish it from a USER 停止: if we set timedOut, treat it as a
  // timeout (its own message), NOT as an abort — else a 9-min timeout would render
  // "已停止" instead of the timeout/narrow-it guidance.
  const { status, answer, steps, aborted: rawAborted, error, timing } = result;
  const aborted = rawAborted && !timedOut;
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
  // Include the (redacted, truncated) backend error body so a 429/400/403/503 are
  // distinguishable to operators — not just an opaque status code. The user-facing
  // card stays generic; only the log carries the reason.
  if (httpFailed) log({ event: "invoke_http_error", card: cardId, status, detail: error ? redactSensitive(error).slice(0, 300) : undefined });

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
  // Gate turn-cap detection to the in-stream (HTTP-200) path. The turn cap is an
  // agent-loop concept surfaced INSIDE the 200 stream (detectEventError); a non-200
  // HTTP failure now carries the raw response body in `error` (sigv4 captures it for
  // the accessDenied hint + logging), and a body that happened to contain "maximum
  // turns" would otherwise mis-route an HTTP outage into the partial-answer branch
  // and render the raw error envelope as an "answer". So never treat an HTTP failure
  // as a turn cap.
  // The terminal classification + chart/footer/remember gating is now a PURE,
  // unit-tested decision (finalize-decision.ts) so a regression in this composition
  // (e.g. dropping follow-ups on a turn cap, or storing a hard-failure body) is
  // caught by tests rather than only in production.
  const decision = decideFinalize({
    failed, httpFailed, turnCappedRaw: isTurnCapError(error), aborted, timedOut, accessDenied,
  });
  // Consume ALL of the decision's gating fields (not just hardFailed) so the
  // unit-tested keep*/remember gates actually drive production — a regression in
  // them is then caught by finalize-decision.test.ts, not only in the field.
  const { turnCapped, hardFailed, keepCharts, keepFooter, remember } = decision;

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
    bodyNoEvidence = hardFailureMessage(accessDenied);
  } else {
    const ex = extractCharts(answer);
    charts = ex.charts;
    // Split evidence FIRST, then strip follow-ups from the body only — see the live
    // path above: the reverse order loses the evidence block when 你可能还想问 precedes
    // 供研发复核 (stripFollowUps' greedy tail-eat). Confine each extractor to its partition.
    const split = splitEvidence(ex.text);
    const body = stripFollowUps(split.body);
    // Strip the "💡 你可能还想问" trailer from the EVIDENCE partition too. The model
    // commonly emits it AFTER 供研发复核 (供研发复核 … --- 💡 你可能还想问 …), so it lands
    // in split.evidence and gets folded INTO the dev-review panel — redundant noise,
    // since the real follow-up BUTTONS render separately below (user-reported). Strip
    // it from both partitions; the buttons still come from extractFollowUps(answer).
    const ev = stripFollowUps(split.evidence);
    evidence = ev;
    // Drop a planning preamble ("现在我整理答案…" + ---) that the model wrote into
    // the conclusion block, so the finalized body leads with the answer (结论先行).
    // Then shape the VISIBLE body: append the incompleteness note AFTER evidence is
    // split off, so the note isn't hidden inside the collapsed panel.
    bodyNoEvidence = shapeBody(stripPreamble(body), { turnCapped, aborted, timedOut });
  }
  // LEAKED TOOL-CALL MARKUP: sometimes the model emits its tool-call XML
  // (<function_calls>/<invoke>) as plain TEXT instead of actually invoking the tools,
  // and that text lands in the conclusion (the user sees raw markup). The exact cause
  // varies (tools unavailable that turn, a formatting slip, a truncated stream) and is
  // NOT something we can assert from here — so the user-facing message stays
  // cause-AGNOSTIC: it only says the answer couldn't be completed + suggests a retry,
  // without claiming a specific reason. If the body is DOMINATED by such markup the
  // turn produced no real answer → show the clean failure message; otherwise just strip
  // the stray block(s). Skip on hard failure (already a fixed message). The operator
  // log carries the signal for real root-causing.
  let leakFailed = false;
  if (!hardFailed) {
    // Assess dominance over BOTH body AND evidence: a leak can land after the
    // 供研发复核 heading (→ evidence partition), so checking the body alone would
    // miss an evidence-only leak. If dominant, the whole turn produced no real
    // answer → clean failure message + suppress charts/evidence.
    if (isToolCallLeakDominant(bodyNoEvidence + "\n" + evidence)) {
      log({ event: "toolcall_leak_dominant", card: cardId, chars: bodyNoEvidence.length });
      bodyNoEvidence = t("msg.fail.toolcallLeak");
      charts = []; evidence = ""; leakFailed = true;
    } else {
      // Strip stray markup from BOTH partitions so neither the body nor the folded
      // 供研发复核 panel shows raw tool-call XML.
      bodyNoEvidence = stripToolCallLeak(bodyNoEvidence);
      evidence = stripToolCallLeak(evidence);
    }
  }
  // Clarification: when the agent判定 the question is ambiguous it emits a
  // "🔀 需要你确认 + options" block INSTEAD of an answer. Detect it on the raw answer
  // (before redaction — the options are business questions, no secrets). If present,
  // the card shows the disambiguation prompt + one-tap option buttons (rendered in
  // the footer section below) and suppresses charts/evidence/follow-ups (there's no
  // answer yet). Only on a clean run — a hard failure / abort / turn-cap is not a
  // clarification. The buttons reuse the follow_up callback so a click re-asks the
  // chosen clarified question WITH context replay.
  const clarifyRaw = (!hardFailed && !aborted && !turnCapped) ? extractClarification(answer) : null;
  // Redact the question + every option before they reach the group-visible card —
  // same secret/path safety net as the conclusion / follow-ups / reasoning panel.
  // The options are agent-authored business questions (low risk), but the agent is
  // steered by repo content, so scrub defensively (defense in depth).
  const clarify = clarifyRaw
    ? { question: redactSensitive(clarifyRaw.question), options: clarifyRaw.options.map(redactSensitive) }
    : null;
  if (clarify) {
    // The body becomes just the disambiguation prompt; the options are buttons.
    bodyNoEvidence = clarify.question;
    evidence = "";
    charts = [];
  }
  // normalizeBlocks repairs block markers (### / --- / >) the model jammed mid-prose
  // without a preceding blank line — lark_md only renders them at line start, else
  // the reader sees literal "###"/"---" inside a paragraph. Runs AFTER stripPreamble
  // (which keys off inline `---`) and after redaction (additive newlines only, so it
  // can't move a secret across the redaction boundary). Clarify body is a single
  // prompt line — no blocks — so it's a harmless no-op there.
  // Clamp BEFORE normalize/redact-free PUT so an over-long conclusion or a huge echoed
  // config table can't push the single finalize PUT past Feishu's card-size limit (a
  // 400 there is swallowed by CardWriter → card stuck mid-stream). See MAX_CARD_* above.
  const finalText = normalizeBlocks(clampForCard(redactSensitive(bodyNoEvidence), MAX_CARD_BODY_CHARS));
  const finalEvidence = normalizeBlocks(clampForCard(redactSensitive(evidence), MAX_CARD_EVIDENCE_CHARS));
  // NOTE: do not trust `messages-mget` read-back to verify heading rendering — it
  // collapses the blank line around block markers in its re-serialization (verified:
  // we SEND "…：\n\n### X" but mget returns "…：### X"). The real card renders the
  // heading correctly; the mget "jam" is a read-back artifact. normalizeBlocks is
  // covered by unit tests.
  // Finalize writes go through the SAME serial writer, so they're ordered AFTER
  // every streaming write drained (FIFO) and carry strictly-higher sequences —
  // no stale rejection. Each is independently guarded inside writer.write (a
  // failed write is swallowed, never wedges the chain), and we await each so the
  // card always ends up finalized (header green, streaming off, stop button gone)
  // even if one mid-step write failed.
  await writer.write((seq) => updateContent(cardId, finalText, seq)
    .catch((e) => { log({ event: "finalize_content_error", card: cardId, error: String(e) }); throw e; }));
  await writer.write((seq) => closeStreaming(cardId, seq)
    .catch((e) => { log({ event: "close_streaming_error", card: cardId, error: String(e) }); throw e; }));

  // 4. Finalize: header → green "回答完成" (or 已停止 / 查询失败) + reasoning panel
  //    collapsed. The full-card PUT rebuilds the body (conclusion + panel), which
  //    also drops the now-irrelevant 停止 button AND the live status line.
  // Reasoning-panel fallback: the panel renders the agent's PRE-TOOL narration
  // (`steps` = text blocks before the conclusion). Some models (esp. on follow-ups,
  // and Sonnet) call tools FIRST and write only the final answer, so `steps` is
  // empty and the panel would vanish — even though the agent DID do retrieval work.
  // A prompt rule alone doesn't reliably force narration across models. So when
  // there are no narration steps but tools WERE used, synthesize ONE honest,
  // business-language step (no tool names → no leak) so the 分析过程 panel is always
  // present whenever real evidence-gathering happened. Skipped on hard failure (no
  // trustworthy work) and when zero tools ran (nothing to show).
  // redactSteps strips leaked tool-call markup + secrets and DROPS pure-markup
  // steps, so apply it FIRST and base the "panel empty → synthesize a step"
  // fallback on the CLEANED count. Otherwise N pure-markup narration steps would
  // pass the length check, then get dropped at render time → an empty panel even
  // though tools ran (the exact MCP-init-race shape).
  let panelSteps = redactSteps(steps);
  if (panelSteps.length === 0 && !hardFailed && !clarify && (timing.toolCalls ?? 0) > 0) {
    panelSteps = [t("card.reasoning.synthesized")];
  }
  // A clarification is a question back to the user, not an answer — don't show a
  // "已检索…据此得出结论" panel (no conclusion was reached).
  if (clarify) panelSteps = [];
  // Show total elapsed in the finalized header ("回答完成 · 用时 67s"). Monotonic base
  // (same as the live timer) so the final 用时 can't be skewed by a clock step.
  const elapsedLabel = formatElapsed(performance.now() - monoStart);
  // panelSteps is already cleaned (redactSteps above); finalizeCard re-redacts which
  // is idempotent (no markup/secret left to strip).
  await writer.write((seq) => finalizeCard(cardId, finalText, redactSteps(panelSteps), seq, isFollowUp, aborted, hardFailed, finalEvidence, question, elapsedLabel, turnCapped, !!clarify, timedOut));
  // Store the (redacted) answer in the registry BEFORE rendering the follow-up
  // buttons. rememberAnswer is pure in-memory (no card I/O), and the follow-up
  // suggestion buttons are written just below — if a user clicks one in the window
  // between the footer-append and the answer-store, collectChain would read an
  // answer-less parent and drop the immediate turn from context (caught in
  // re-review). Storing first closes that race. Skipped on hard failure (no
  // trustworthy answer) and on a clarification (prompt-back-to-user, not an answer).
  if (sentMessageId && remember && !clarify) rememberAnswer(sentMessageId, finalText);
  // 5. Data charts + follow-ups: skip on HARD failure (no trustworthy conclusion).
  //    A turn-capped partial keeps its charts/follow-ups (labeled incomplete).
  if (keepCharts && charts.length > 0) {
    // Charts are pulled from the UNredacted answer (extractCharts ran on it),
    // so scrub every string leaf of each spec before it hits the group-visible
    // card — same secret/path safety net as the conclusion and reasoning panel.
    // Cap the count (MAX_CHARTS) — a pathological many-chart answer would blow the
    // card-size limit / write budget; the prose table is the fallback.
    const safeCharts = charts.slice(0, MAX_CHARTS).map((c) => redactDeep(c));
    if (charts.length > MAX_CHARTS) log({ event: "chart_capped", total: charts.length, kept: MAX_CHARTS });
    // Append EACH chart as its own element so one malformed VChart spec can't make
    // CardKit reject the whole batch (atomic append) and wipe every chart. A
    // failing append is logged and skipped; the others still render.
    safeCharts.forEach((c, i) => {
      void writer.write((seq) => appendOneChart(cardId, c, i, seq)
        .catch((e) => log({ event: "chart_error", index: i, error: String(e) })));
    });
  }
  // Outcome ACTION buttons (recovery affordances, shown above follow-up suggestions):
  //  - retry : the turn yielded NO usable answer (hard failure / dominant tool-call
  //            leak / aborted-with-no-body). Re-ask the ORIGINAL question fresh — a
  //            cold-VM MCP-init failure usually clears on a now-warm retry.
  //  - narrow: the turn was step-capped (partial). Re-ask focused on one point so it
  //            can finish within the cap.
  // `question` here is the redacted user question (safe to echo + re-ask).
  const actions: ActionButton[] = [];
  const noAnswer = hardFailed || leakFailed || (aborted && bodyNoEvidence.trim().length <= 12);
  if (noAnswer && !clarify) {
    actions.push({ kind: "retry", text: question, label: t("card.action.retry") });
  } else if (turnCapped && !clarify) {
    actions.push({ kind: "narrow", text: t("card.action.narrow.prompt", { question }), label: t("card.action.narrow") });
  }
  if (clarify) {
    // Disambiguation: render the option buttons (the prompt is already in the body).
    // No follow-ups — the user picks an option to continue. Reuses the follow_up
    // callback so a click re-asks the chosen clarified question with context replay.
    log({ event: "clarify_shown", card: cardId, options: clarify.options.length });
    await writer.write((seq) => appendClarify(cardId, seq, clarify.question, clarify.options));
  } else if (keepFooter) {
    // Extract follow-ups from the RAW answer (still carries the "💡 你可能还想问"
    // trailer that stripFollowUps removed from the rendered body).
    const followUps = extractFollowUps(redactSensitive(answer));
    await writer.write((seq) => appendFooter(cardId, seq, followUps, actions));
  } else if (actions.length > 0) {
    // hardFailed/leakFailed → keepFooter is false, but the retry button is exactly
    // what the user needs here. Append a footer carrying ONLY the action button(s).
    await writer.write((seq) => appendFooter(cardId, seq, [], actions));
  }
  // Redact `error` before logging: on a non-200 path it now carries the raw backend
  // response body (sigv4), which could echo a token/header/connection-string.
  log({ event: "card_closed", card: cardId, chars: answer.length, charts: charts.length, timedOut, failed, turnCapped, error: error ? redactSensitive(error) : undefined });
  } catch (finalizeErr) {
    // The finalize composition threw unexpectedly. The card is still mid-stream
    // (header blue "正在分析…", live timer, dead 停止 button). Best-effort force it to
    // a clean, self-consistent terminal state so it never hangs: drop any queued
    // status/content frames, then a single one-shot finalizeCard (full-PUT) that
    // rebuilds the body as a generic service error, closes streaming, and removes
    // the 停止 button + live status line. Each step is independently swallowed —
    // we must not throw out of the emergency path. closeStreaming is attempted too
    // in case finalizeCard's PUT itself fails (so streaming_mode is cleared either way).
    log({ event: "finalize_error", card: cardId, error: redactSensitive(String(finalizeErr)).slice(0, 300) });
    try { writer.dropLanes("status", "content", "evidence"); } catch { /* best-effort */ }
    await writer.write((seq) =>
      finalizeCard(cardId, t("msg.serviceError"), [], seq, isFollowUp, false, true, "", question, "", false, false),
    ).catch(() => {});
    await writer.write((seq) => closeStreaming(cardId, seq)).catch(() => {});
  }
}

async function main(): Promise<void> {
  // Register shutdown handlers FIRST — before any await — so a SIGTERM during the
  // async startup window (SDK import, i18n load, credential setup) still exits cleanly.
  process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
  process.on("SIGINT", () => gracefulShutdown("SIGINT"));
  if (!RUNTIME_ARN) throw new Error("RUNTIME_ARN env is required");
  // Load card copy (config/i18n.json) at startup so a missing/broken bundle fails
  // loudly here, not mid-answer. LOCALE env selects the locale (default zh).
  initI18n();
  log({ event: "i18n_loaded", locale: currentLocale() });
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
    const question = res.answer ?? ""; // InvokeFn passes the clean question through as `answer`
    // If this IM message REPLIED to a prior bot card (Feishu 回复/引用), replay that
    // card's whole conversation chain as context — so a TYPED follow-up continues
    // the thread just like the follow-up button does. parentId → registry chain.
    let prompt = question;
    let parentId: string | undefined;
    let sessionId = res.sessionId;
    if (res.parentId) {
      const parentEntry = lookupCard(res.parentId);
      if (parentEntry) {
        // The reply targets a KNOWN bot card. Record the parent link REGARDLESS of
        // whether its answer has finalized yet — if we only set parentId when the
        // chain is currently non-empty, a reply to a still-streaming parent would
        // be permanently orphaned from the conversation even after the parent
        // settles. collectChain heals the chain once the parent's answer lands.
        parentId = res.parentId;
        // Reuse the parent card's warm session (mirrors the follow-up button path),
        // not a freshly-derived one — a threaded reply whose thread_id differs from
        // the parent's would otherwise pin a different, cold microVM.
        sessionId = parentEntry.sessionId ?? res.sessionId;
        const chain = collectChain(res.parentId);
        if (chain.length > 0) {
          prompt = composeFollowUpPrompt(question, chain);
          log({ event: "reply_context_replayed", turns: chain.length });
        } else {
          // Parent not finalized yet (reply to a still-streaming card). The eager
          // prompt is bare; the composePrompt below will recompute at turn start —
          // by then the parent has finalized (it runs FIRST on this shared session).
          log({ event: "reply_context_pending", reason: "parent_not_yet_finalized" });
        }
      } else {
        log({ event: "reply_context_missing", reason: "parent_not_in_registry" });
      }
    }
    // Defer prompt composition to turn-start so a reply to a still-streaming parent
    // replays the parent's NOW-settled answer (the parent runs first on this shared
    // session). Re-collects the chain at invoke time; falls back to the eager prompt.
    const composePrompt = parentId
      ? () => {
          const chain = collectChain(parentId!);
          if (chain.length === 0) return prompt; // still nothing — keep eager (bare)
          log({ event: "reply_context_replayed_deferred", turns: chain.length });
          return composeFollowUpPrompt(question, chain);
        }
      : undefined;
    try {
      await streamingCardInvoke(sessionId, prompt, { messageId: res.messageId }, credentials, question, parentId, res.senderId, composePrompt, res.eventId);
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
      // REDACT the echoed prompt: this error branch bypasses sendStreamingCard's
      // redaction (the card never rendered), so a secret pasted into the question
      // would otherwise leak verbatim into the group here. redactSensitive is
      // idempotent, so re-redacting the already-safe chain part of a follow-up
      // blob is harmless while it covers the raw new-question segment.
      await sendReply({ messageId: res.messageId, answer: `${t("msg.serviceError")}\n\n${redactSensitive(prompt)}` })
        .catch((e) => log({ event: "fallback_error", error: String(e) }));
    }
    log({ event: "replied", message: hashUserId(res.messageId), session: sessionId });
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
        void handleMessageEvent(event, { invoke }, {
          botOpenId: BOT_OPEN_ID || undefined,
          // A reply BY THE ASKER to one of our remembered bot cards counts as an
          // implicit mention so group reply-follow-ups don't require an extra @
          // (scoped to the asker: one card can't let every member trigger invokes).
          isAskerReply: (pid, senderId) => {
            const e = lookupCard(pid);
            // Fail CLOSED: only the known asker bypasses the @-gate. If the card's
            // asker is unknown (askerOpenId empty — e.g. an event/callback that
            // didn't carry the sender open_id), a bare reply must still @-mention,
            // so one card can't let any member drive invokes via the empty branch.
            return !!e && !!e.askerOpenId && !!senderId && e.askerOpenId === senderId;
          },
        })
          .then((res) => {
            // A reply to a card we no longer know (gateway restart / >500 eviction)
            // is dropped at the mention gate; log it so the silent stop is
            // diagnosable rather than indistinguishable from a plain non-mention.
            if (res && !res.handled && res.reason === "reply_to_unknown_card") {
              log({ event: "reply_to_unknown_card", chat: hashUserId(event.chat_id) });
            }
            return replyWithCard(res);
          })
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
          action?: { value?: { action?: string; text?: string; eid?: string; card_id?: string; fresh?: boolean } };
          context?: { open_chat_id?: string; open_message_id?: string };
          operator?: { open_id?: string; tenant_key?: string };
        };
        const value = d?.action?.value;
        const chatId = d?.context?.open_chat_id ?? "";
        const messageId = d?.context?.open_message_id ?? "";
        const operatorOpenId = d?.operator?.open_id;
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
        if (value?.action === "stop") {
          // 停止: abort the in-flight agent stream for this card. The invoke then
          // finalizes with whatever was generated, header → ⏹ 已停止. Resolve the
          // cardId from the button's own value.card_id, falling back to the
          // registry by messageId (mirrors follow_up) so a payload whose value
          // dropped card_id still stops the right card instead of silently no-op'ing
          // with no trace ("点了停止没反应" + no log) (cross-review).
          const stopEntry = lookupCard(messageId);
          const stopCardId = value.card_id || stopEntry?.cardId;
          // ASKER-SCOPING (operator decision 2026-06-19): only the user who ASKED the
          // card may stop its stream — aborting someone else's in-flight answer is a
          // low-friction DoS, so gate it like the reply path. FAIL CLOSED: refuse if
          // the card's asker is unknown (can't verify) or the operator isn't the
          // asker. (Follow-up buttons stay group-open by the same decision — clicking
          // one only spends a fresh invoke, it doesn't disrupt an in-flight stream.)
          const stopAsker = stopEntry?.askerOpenId;
          const stopAllowed = !!stopAsker && !!operatorOpenId && operatorOpenId === stopAsker;
          if (!stopCardId) {
            log({ event: "stop_unresolved", message: messageId ? hashUserId(messageId) : "" });
          } else if (!stopAllowed) {
            // Not the asker (or asker unknown) → ignore. Logged (hashed) so abuse /
            // an unexpected-empty-asker is diagnosable, not silent.
            log({ event: "stop_denied", card: stopCardId, reason: stopAsker ? "not_asker" : "asker_unknown" });
          } else {
            const ctrl = abortControllers.get(stopCardId);
            log({ event: "stop_clicked", card: stopCardId, found: !!ctrl });
            if (ctrl) ctrl.abort();
          }
        } else if (value?.action === "follow_up" && typeof value.text === "string" && value.text && chatId) {
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
          // A "重新试一次" (retry) button sets value.fresh: the prior turn FAILED
          // (no usable answer), so there's no useful context to carry — and
          // replaying the failure message as context would poison the retry. Re-ask
          // the question FRESH (no chain). Otherwise replay the WHOLE prior chain
          // (this card + ancestors) so multi-turn follow-ups build full history.
          const fresh = value.fresh === true;
          // Eager prompt for the immediate-fire case; the deferred composer below
          // recomputes at turn-start. A "重新试一次" (retry) button sets value.fresh:
          // the prior turn FAILED (no usable answer), so carry NO context (replaying
          // the failure message would poison the retry) — re-ask the question fresh.
          const chain = fresh ? [] : collectChain(messageId);
          const prompt = fresh ? value.text : composeFollowUpPrompt(value.text, chain);
          if (fresh) {
            log({ event: "retry_clicked", chatId: hashUserId(chatId) });
          } else if (chain.length === 0) {
            log({ event: "followup_context_missing", chatId: hashUserId(chatId), reason: entry ? "no_answer_stored" : "entry_missing" });
          } else {
            log({ event: "followup_context_replayed", chatId: hashUserId(chatId), turns: chain.length });
          }
          // DEFER context composition to turn-start (mirror the reply path): a button
          // clicked while the PARENT is still streaming — or in the sub-second window
          // before the parent's answer is stored — would otherwise freeze an
          // answer-less chain at click time and lose the immediate parent turn. The
          // composer re-collects the chain at invoke time, by when the parent (same
          // session, runs first) has finalized + stored its answer. Skipped for a
          // fresh retry (no context wanted).
          const composeBtn = fresh
            ? undefined
            : () => {
                const c = collectChain(messageId);
                if (c.length === 0) return prompt; // still nothing — keep eager (bare)
                log({ event: "followup_context_replayed_deferred", turns: c.length });
                return composeFollowUpPrompt(value.text!, c);
              };
          // The new follow-up card's PARENT is the card being followed up, so a
          // follow-up-of-this-follow-up keeps walking the chain.
          void streamingCardInvoke(sessionId, prompt, { chatId }, credentials, value.text, messageId, operatorOpenId, composeBtn)
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
        } else {
          // A callback we recognized the envelope of but could NOT act on — e.g. a
          // follow_up whose context.open_chat_id was absent (chatId empty), or an
          // unknown action. The dedup key was already burned above; roll it back so a
          // Feishu re-delivery with the missing field populated can retry instead of
          // being dropped as a duplicate forever (mirrors the reply path's forget;
          // cross-review). Log so the skip is diagnosable rather than silent.
          forget(`cb:${cbId}`);
          log({ event: "callback_unactionable", action: value?.action ?? "", hasText: !!value?.text, hasChat: !!chatId });
        }
      } catch (e) {
        // Best-effort (the SDK callback must not throw), but DON'T swallow silently:
        // a throw in the synchronous setup before ctrl.abort()/streamingCardInvoke
        // (malformed payload, helper throw) would otherwise leave a 停止 click with
        // no abort + no trace, or a follow-up with no card + no error. Log it.
        log({ event: "callback_handler_error", error: String(e) });
      }
      return {};
    },
  });
  // Wire lifecycle callbacks for observability AND fail-loud recovery. Transient
  // drops (network blip / Feishu restart / token expiry surfacing as a socket
  // close) auto-reconnect inside the SDK (infinite retries). But a TERMINAL error
  // — non-retryable bad/revoked/expired credentials — makes the SDK stop trying
  // and (without onError) NO exception propagates: the process stays up but the
  // gateway, the ONLY event consumer, goes permanently DARK with zero signal. So
  // onError logs loudly and exits(1) so the supervisor (the run_in_background /
  // systemd launcher) restarts with a clean attempt rather than running blind.
  const ws = new lark.WSClient({
    appId: APP_ID,
    appSecret: APP_SECRET,
    loggerLevel: lark.LoggerLevel.warn,
    onReady: () => log({ event: "sdk_wsclient_connected" }), // the REAL "receiving events" signal
    onReconnecting: () => log({ event: "sdk_wsclient_reconnecting" }),
    onReconnected: () => log({ event: "sdk_wsclient_reconnected" }),
    onError: (err: unknown) => {
      const msg = String(err);
      // The transient/terminal/shutdown decision is a PURE, unit-tested helper
      // (classifyWsError) so this critical "does the gateway survive a blip / restart
      // on bad creds / stand down cleanly on redeploy" logic isn't untested inline.
      switch (classifyWsError(err, shuttingDown)) {
        case "ignore":
          // We closed the socket on purpose (SIGTERM → wsRef.stop()); the drain owns
          // the exit. Without this, the teardown error would race exit(1) ahead of
          // gracefulShutdown → in-flight cards never finalize + a redeploy looks like
          // a crash (failure exit code).
          log({ event: "ws_error_during_shutdown", error: msg });
          return;
        case "retry": {
          // exceed_conn_limit (1000040350): a stale peer still holds the app's WS
          // slot. Exiting would race a supervised restart into the SAME limit → tight
          // crash-loop, dark throughout. Back off + re-start in-process instead.
          const backoffMs = 3000 + Math.floor(Math.random() * 4000);
          log({ event: "ws_conn_limit_retry", error: msg, backoffMs });
          setTimeout(() => { try { ws.start({ eventDispatcher: dispatcher }); } catch (e) { log({ event: "ws_retry_failed", error: String(e) }); } }, backoffMs);
          return;
        }
        case "exit":
          log({ event: "ws_terminal_error", error: msg });
          // Terminal (bad/revoked creds etc.) — don't run dark. Exit so the
          // supervisor restarts with fresh state.
          process.exit(1);
      }
    },
  });
  wsRef = ws as unknown as { stop?: () => void }; // let gracefulShutdown best-effort stop intake
  ws.start({ eventDispatcher: dispatcher });
  // NOTE: start() resolves before the connection is established; this marks only
  // "start() invoked". The real "connected + receiving events" signal is the
  // sdk_wsclient_connected log from onReady above.
  log({ event: "sdk_wsclient_started" });

  // (SIGTERM/SIGINT handlers were registered at the top of main(); gracefulShutdown
  // is module-scoped and uses wsRef set below.)
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
