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
  | "coldstart_retry_exhausted"
  | "turn_capped"
  | "aborted"
  | "upstream_throttle"
  | "encoding_error"
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
  | "heartbeat_stall"
  | "dedup_hit"
  | "idempotent_resend";

const FAIL_REASONS: ReadonlySet<string> = new Set<FailReason>([
  "cold_start_mcp_race", "coldstart_retry_exhausted", "turn_capped", "aborted",
  "upstream_throttle", "encoding_error", "unknown",
]);
const FEEDBACK_REASON_CODES: ReadonlySet<string> = new Set<FeedbackReasonCode>([
  "inaccurate", "no_evidence", "off_topic", "outdated",
  "too_slow", "hard_to_understand", "too_shallow", "other",
]);
const CARD_HEALTH_KINDS: ReadonlySet<string> = new Set<CardHealthKind>([
  "toolcall_leak_detected", "finalize_failed", "heartbeat_stall", "dedup_hit", "idempotent_resend",
]);

// Runtime whitelist per enum field-name. A value not in the set is replaced (not logged
// verbatim) so a stray `value.text` at an `any`-typed call site can't leak as a metric.
const ENUM_WHITELIST: Record<string, { set: ReadonlySet<string>; fallback: string }> = {
  reason: { set: FAIL_REASONS, fallback: "unknown" },
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
  | "clarify_shown" | "card_health";

const USER_LEVEL_EVENTS: ReadonlySet<string> = new Set<UserLevelEvent>([
  "question_received", "feedback_voted", "feedback_reason",
]);

/** The injectable sink. Default writes one structured JSON line (same shape as the
 *  gateway's log()), which CloudWatch Logs Insights filters on `metric:true`. */
export type MetricSink = (record: Record<string, unknown>) => void;
let sink: MetricSink = (record) => {
  // eslint-disable-next-line no-console
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
