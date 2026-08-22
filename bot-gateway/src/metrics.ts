/**
 * Unified telemetry exit — `emitMetric(event, fields)`. Every analytics event in the
 * gateway goes through here (never a scattered console.log), so the public fields,
 * PII discipline, and enum validation are enforced in ONE place.
 *
 * Design (telemetry-and-feedback plan §设计原则, all load-bearing):
 *  1. BEST-EFFORT, never blocks/breaks the answer hot path: a sink throw is swallowed
 *     (mirrors log.ts / agent_lib._perf). Emitting a metric must never fail a reply.
 *  2. PII desensitized: user/session ids only ever appear as hashUserId; question text
 *     and free-text NEVER enter an event — negative feedback is an ENUM reasonCode only.
 *  3. Enums are compile-time unions AND runtime-whitelisted: a caller that tries to put
 *     a free-text value into reason/reasonCode/kind fails to compile, and a value that
 *     slips through at runtime (e.g. an `any`-typed call site) is dropped to "unknown"/
 *     "invalid" rather than logged verbatim — so `value.text` can't leak via a metric.
 *  4. PHYSICAL key split (the stronger form of "traceId joins a trace, hashUserId joins a
 *     user"): USER-LEVEL events carry hashUserId and NO traceId; DIAGNOSTIC (per-Q&A)
 *     events carry traceId and NO hashUserId. Two keys never co-occur on one event, so a
 *     mis-configured (weak) salt can't be combined with traceId to re-identify a user.
 *
 * Backend = structured JSON logs → CloudWatch Logs Insights (zero new storage). The sink
 * is injectable so it can be swapped (or captured in tests) without touching call sites.
 */

import { saltIsWeak } from "./log";

// ── enum vocabularies (码不用自由文本) ──────────────────────────────────────
// A hard failure's cause. Covers the real observed failure modes so a CloudWatch
// `count by reason` answers "线上主要死在哪".
export type FailReason =
  | "cold_start_mcp_race"
  | "turn_capped"
  | "upstream_throttle"
  | "auth_denied"
  | "unknown";

// Why a user pressed 👎 (selected from buttons, never free text).
export type FeedbackReasonCode =
  | "inaccurate"
  | "no_evidence"
  | "off_topic"
  | "outdated"
  | "too_slow"
  | "hard_to_understand"
  | "too_shallow"
  | "other";

// A CardKit streaming-architecture health event (the user directly sees a bad card).
export type CardHealthKind =
  | "toolcall_leak_detected"
  | "finalize_failed"
  | "dedup_hit"
  | "zero_evidence_answer";

const FAIL_REASONS: ReadonlySet<string> = new Set<FailReason>([
  "cold_start_mcp_race", "turn_capped",
  "upstream_throttle", "auth_denied", "unknown",
]);

/** Classify a backend invoke error string into a FailReason for the failure-by-reason
 *  dashboard. A bare "unknown" for every non-200 hides distinct, actionable causes (an IAM
 *  403 vs a throttle vs a transient 5xx need different fixes). Pattern-match the error text;
 *  fall back to "unknown" when nothing recognizable. Pure + exported for unit testing. */
export function classifyFailure(error: string | undefined | null): FailReason {
  const e = (error || "").toLowerCase();
  if (!e) return "unknown";
  // IAM / authorization: "not authorized to perform", "403", "accessdenied", "forbidden".
  if (e.includes("not authorized") || e.includes("accessdenied") || e.includes("access denied")
      || e.includes("forbidden") || /\b403\b/.test(e)) return "auth_denied";
  // Throttling / rate limit / 429 / 503 backpressure.
  if (e.includes("throttl") || e.includes("rate exceeded") || e.includes("too many requests")
      || /\b429\b/.test(e) || e.includes("serviceunavailable") || /\b503\b/.test(e)) return "upstream_throttle";
  return "unknown";
}

// Source/config file extensions a citation path can end in (game repos: C#/Unity + configs).
// Used to count evidence citations — a cited <path>.<ext> is a real code reference whether or
// not it carries a :line. Anchored to these extensions so prose like "v1.2" or "etc." isn't
// miscounted as a file.
const _CITE_EXT = "cs|json|jsonc|cfg|ini|txt|xml|csv|tsv|py|ts|js|tsx|jsx|cpp|cc|h|hpp|java|go|rs|md|yaml|yml|sql|shader|asset|prefab|unity|gd|lua";
const _CITE_RE = new RegExp(String.raw`[\w./\\-]*[\w-]+\.(?:${_CITE_EXT})(?::\d+)?`, "gi");

/** Count DISTINCT source-file citations in an answer's evidence section. Replaces a stricter
 *  regex that required <path>:<line> and so scored 0 for the very common form where the agent
 *  cites `Assets/Scripts/Foo.cs` + a method name but no line number (a real, evidence-backed
 *  answer was undercounted as 0 → the 证据覆盖率 dashboard understated quality). Matches a path
 *  ending in a known source/config extension, with or without :line, and DEDUPES by path (a
 *  file cited 3× counts once). Pure + exported for unit testing. */
export function countEvidenceCitations(evidence: string | undefined | null): number {
  if (!evidence) return 0;
  const paths = new Set<string>();
  for (const m of evidence.matchAll(_CITE_RE)) {
    paths.add(m[0].replace(/:\d+$/, "").toLowerCase());  // strip :line, dedupe case-insensitively
  }
  return paths.size;
}
const FEEDBACK_REASON_CODES: ReadonlySet<string> = new Set<FeedbackReasonCode>([
  "inaccurate", "no_evidence", "off_topic", "outdated",
  "too_slow", "hard_to_understand", "too_shallow", "other",
]);
const CARD_HEALTH_KINDS: ReadonlySet<string> = new Set<CardHealthKind>([
  "toolcall_leak_detected", "finalize_failed", "dedup_hit", "zero_evidence_answer",
]);

// Drop reasons for `event_dropped`. These share the `reason` FIELD NAME with the invoke-failure
// vocabulary above but are a completely different set, and the whitelist is keyed by field name —
// so before this set existed, every drop reason fell through to the `unknown` fallback. Two
// separately-verified rounds collided here: the enum whitelist (added to stop a stray `value.text`
// leaking as a metric dimension) silently coerced the drop vocabulary (added to make silent event
// loss observable), and the result was worse than either problem.
//
// Two alarms were broken by that coercion, in opposite directions:
//   * EventDroppedUnparseable matches `$.reason = "unparseable_event"` — a value that never
//     appeared in a metric line, so the alarm built for "100% of messages are being dropped"
//     could not fire at all.
//   * EventDroppedGate excludes unparseable and duplicate drops; `"unknown"` satisfies both
//     inequalities, so it matched EVERY drop — including the post-deploy Feishu redelivery burst
//     its own purpose field says it must not alarm on.
// Keep this in sync with ImEvent.reason in handle-event.ts plus the gateway's own drop reasons.
export type DropReason =
  | "unparseable_event"
  | "duplicate"
  | "unsupported_type"
  | "empty"
  | "not_mentioned"
  | "not_a_user"
  | "self_message"
  | "reply_to_unknown_card";

const DROP_REASONS: ReadonlySet<string> = new Set<DropReason>([
  "unparseable_event", "duplicate", "unsupported_type", "empty",
  "not_mentioned", "not_a_user", "self_message", "reply_to_unknown_card",
]);

// Runtime whitelist per enum field-name. A value not in the set is replaced (not logged
// verbatim) so a stray `value.text` at an `any`-typed call site can't leak as a metric.
const ENUM_WHITELIST: Record<string, { set: ReadonlySet<string>; fallback: string }> = {
  // Union of both vocabularies: the field name is shared, so gating on either set alone
  // silently rewrites the other one's values.
  reason: { set: new Set<string>([...FAIL_REASONS, ...DROP_REASONS]), fallback: "unknown" },
  reasonCode: { set: FEEDBACK_REASON_CODES, fallback: "other" },
  kind: { set: CARD_HEALTH_KINDS, fallback: "invalid" },
};

// ── event taxonomy ──────────────────────────────────────────────────────────
// USER-LEVEL: aggregated by hashUserId (DAU/retention). NO traceId (key-split, §4).
export type UserLevelEvent = "question_received" | "feedback_voted" | "feedback_reason";
// DIAGNOSTIC: per-Q&A, joined by traceId to the agent's perf logs. NO hashUserId (§4).
// answer_aborted is SEPARATE from answer_failed on purpose: a user pressing 停止 is a
// deliberate user choice, NOT a system failure — folding it into answer_failed would
// inflate the failure rate and mask real outages. Keeping it distinct lets CloudWatch's
// "failure distribution" reflect only genuine faults, while abort rate is its own signal.
export type DiagnosticEvent =
  | "answer_first_token" | "answer_completed" | "answer_failed" | "answer_aborted"
  | "clarify_shown" | "card_health"
  // SYSTEM heartbeat — emitted on a fixed timer regardless of traffic (NOT per-Q&A, no
  // traceId/hashUserId). Its whole purpose is to be a metric that is NONZERO in normal
  // operation even during idle periods, so the log-pipeline-liveness alarm can tell
  // "alive but idle" (heartbeat still arriving) from "pipeline dead" (heartbeat stops).
  // A traffic-driven metric (question_received) can't make that distinction — an idle
  // night and a dead agent both look like no data. See monitoring plan 阶段3 liveness.
  | "gateway_heartbeat"
  // OUTCOME of a finished turn. outcome=text_fallback means the card path failed and the
  // answer degraded to plain text — the signature of a missing CardKit permission, which
  // emits no answer_failed (the fallback send succeeded) and so had no alarm at all.
  | "turn_finished"
  // An inbound event we did NOT answer, with the reason. Covers the two silent-loss modes:
  // an unparseable SDK envelope (100% message loss) and a wrong bot open_id (all group
  // traffic dropped at the mention gate) — both leave /ready at 200 and the heartbeat green.
  | "event_dropped"
  // RUNTIME COLD START — emitted once per invoke that landed on a freshly-minted session
  // (no warm microVM behind it), carrying spinupMs = time-to-first-token (which on a cold
  // invoke folds in AgentCore microVM spin-up + routing). Lets CloudWatch chart cold-start
  // FREQUENCY (count) and DURATION (spinupMs p50/p95) separately from warm latency.
  | "runtime_cold_start";

const USER_LEVEL_EVENTS: ReadonlySet<string> = new Set<UserLevelEvent>([
  "question_received", "feedback_voted", "feedback_reason",
]);

/** The injectable sink. Default writes one structured JSON line (same shape as the
 *  gateway's log()), which CloudWatch Logs Insights filters on `metric:true`. */
export type MetricSink = (record: Record<string, unknown>) => void;
let sink: MetricSink = (record) => {
  console.log(JSON.stringify(record));
};

/** Override the sink (tests capture; prod could swap to a different backend). */
export function setMetricSink(s: MetricSink): void { sink = s; }

export interface MetricContext {
  // USER-LEVEL events pass hashUserId (already hashed — emitMetric does NOT hash, the
  // caller passes the hashUserId output so a raw open_id can never reach here).
  hashUserId?: string;
  sessionId?: string;
  // DIAGNOSTIC events pass traceId (per-invoke).
  traceId?: string;
  projectId?: string;
  // Allow nowMs injection for deterministic tests; defaults to Date.now().
  nowMs?: number;
}

/**
 * Emit one telemetry event. `event` decides the key-split: a user-level event keeps
 * hashUserId + drops traceId; a diagnostic event keeps traceId + drops hashUserId.
 * Enum fields (reason/reasonCode/kind) are runtime-whitelisted. NEVER throws.
 */
export function emitMetric(
  event: UserLevelEvent | DiagnosticEvent,
  fields: Record<string, unknown> = {},
  ctx: MetricContext = {},
): void {
  try {
    const isUserLevel = USER_LEVEL_EVENTS.has(event);
    // Whitelist enum fields; drop a non-conforming value to its safe fallback so free
    // text can't leak verbatim through a metric.
    const safeFields: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(fields)) {
      const rule = ENUM_WHITELIST[k];
      if (rule) {
        safeFields[k] = typeof v === "string" && rule.set.has(v) ? v : rule.fallback;
      } else {
        safeFields[k] = v;
      }
    }
    const record: Record<string, unknown> = {
      event,
      metric: true,
      ts: new Date(ctx.nowMs ?? Date.now()).toISOString(),
      ...safeFields,
    };
    if (ctx.sessionId) record.sessionId = ctx.sessionId;
    if (ctx.projectId) record.projectId = ctx.projectId;
    // KEY SPLIT (§4): user-level → hashUserId, no traceId; diagnostic → traceId, no hashUserId.
    if (isUserLevel) {
      if (ctx.hashUserId) record.hashUserId = ctx.hashUserId;
      // Stamp salt weakness so CloudWatch can flag un-trustworthy de-identification.
      if (saltIsWeak()) record.saltWeak = true;
    } else {
      if (ctx.traceId) record.traceId = ctx.traceId;
    }
    sink(record);
  } catch {
    // best-effort: a telemetry failure must never break the answer path (§1).
  }
}
