/**
 * SigV4 signing for AgentCore InvokeAgentRuntime.
 *
 * The gateway calls the AgentCore data-plane endpoint:
 *   POST https://bedrock-agentcore.<region>.amazonaws.com
 *        /runtimes/<urlencoded runtimeArn>/invocations
 * carrying the runtimeSessionId header so the same question thread reuses one
 * warm microVM. Requests are SigV4-signed (service "bedrock-agentcore").
 *
 * buildInvokeRequest is pure; signInvoke adds the SigV4 headers; invokeRuntime
 * performs the real HTTPS call (used at runtime, not in unit tests).
 */

import { Sha256 } from "@aws-crypto/sha256-js";
import { SignatureV4 } from "@aws-sdk/signature-v4";
import { HttpRequest } from "@smithy/protocol-http";

import { newStreamState, applyEvent } from "./parse-stream";

const SERVICE = "bedrock-agentcore";
const SESSION_HEADER = "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id";

export interface InvokeRequest {
  method: "POST";
  hostname: string;
  path: string;
  headers: Record<string, string>;
  body: string;
}

export interface InvokeParams {
  runtimeArn: string;
  region: string;
  sessionId: string;
  prompt: string;
}

export interface AwsCredentials {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string;
}

/** Either a static credential object OR a provider that re-resolves on each
 *  call. Production passes the PROVIDER (from `fromNodeProviderChain()`): EC2
 *  instance-role (IMDS) credentials are temporary and expire after a few hours,
 *  so a snapshot resolved once at startup goes stale and every later invoke
 *  403s. SignatureV4 accepts a provider directly and re-resolves it (refreshing
 *  the underlying creds) on each sign. */
export type CredentialSource = AwsCredentials | (() => Promise<AwsCredentials>);

export interface SignOptions {
  region: string;
  credentials: CredentialSource;
}

// AgentCore rejects (HTTP 400) a runtimeSessionId shorter than this — verified
// live. randomUUID() (36 chars) satisfies it, but assert so a future change to
// the session-id scheme fails loudly here instead of 400-ing every invoke.
export const MIN_SESSION_ID_LEN = 33;

/** The settled result of a (streaming) invoke — what invokeRuntimeStreaming
 *  returns and what classifyInvokeOutcome judges. */
export interface InvokeOutcome {
  status: number;
  aborted: boolean;
  error: string | null;
}

/** Decide whether an invoke FAILED (so the caller renders an explicit failure
 *  card instead of a fake answer) or hung/threw. A user-pressed 停止 (`aborted`)
 *  is never a failure. Two failure shapes fold into one flag:
 *    - non-200 HTTP (403 from expired SigV4 creds, 4xx/5xx from AgentCore) —
 *      this previously THREW, leaving the already-sent streaming card stuck.
 *    - a top-level error event over an open 200 stream (backend unreachable,
 *      model throttled, run errored).
 *  Pure so the failure policy is unit-tested, not buried in the stream loop. */
export function classifyInvokeOutcome(r: InvokeOutcome): { failed: boolean; httpFailed: boolean } {
  const httpFailed = r.status !== 200 && !r.aborted;
  const failed = (r.error !== null || httpFailed) && !r.aborted;
  return { failed, httpFailed };
}

/** True when the error is the agentic-loop TURN CAP (partial progress), not a
 *  backend outage. Matches every shape the cap surfaces as: the SDK's result
 *  text "Maximum turns exceeded" (what detectEventError returns when `result` is
 *  set — see parse-stream.test.ts fixture), the "Reached maximum number of turns"
 *  errors[] phrasing, and the "error_max_turns" subtype fallback. Used so the
 *  caller shows a "narrow the question" message + the labeled partial answer
 *  instead of a red "backend down, retry" card. */
export function isTurnCapError(error: string | null): boolean {
  return !!error && /error_max_turns|maximum (number of turns|turns exceeded)/i.test(error);
}

/** Build the (unsigned) InvokeAgentRuntime request. Pure. */
export function buildInvokeRequest(p: InvokeParams): InvokeRequest {
  if (!p.sessionId || p.sessionId.length < MIN_SESSION_ID_LEN) {
    throw new Error(
      `runtimeSessionId must be >= ${MIN_SESSION_ID_LEN} chars (AgentCore constraint); got ${p.sessionId?.length ?? 0}`,
    );
  }
  const hostname = `${SERVICE}.${p.region}.amazonaws.com`;
  const path = `/runtimes/${encodeURIComponent(p.runtimeArn)}/invocations`;
  const body = JSON.stringify({ prompt: p.prompt });
  return {
    method: "POST",
    hostname,
    path,
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      Host: hostname,
      [SESSION_HEADER]: p.sessionId,
    },
    body,
  };
}

/** Sign the request with SigV4; returns a request whose headers include
 *  Authorization + X-Amz-Date (+ X-Amz-Security-Token if a session token). */
export async function signInvoke(
  req: InvokeRequest,
  opts: SignOptions,
): Promise<InvokeRequest> {
  const signer = new SignatureV4({
    service: SERVICE,
    region: opts.region,
    credentials: opts.credentials,
    sha256: Sha256,
  });
  const httpReq = new HttpRequest({
    method: req.method,
    protocol: "https:",
    hostname: req.hostname,
    path: req.path,
    headers: req.headers,
    body: req.body,
  });
  const signed = await signer.sign(httpReq);
  return { ...req, headers: signed.headers as Record<string, string> };
}

/** Perform the real signed HTTPS call to AgentCore. Returns the raw response
 *  body (text/event-stream). Used at runtime; integration-tested, not unit. */
export async function invokeRuntime(
  p: InvokeParams,
  opts: SignOptions,
): Promise<{ status: number; body: string }> {
  const signed = await signInvoke(buildInvokeRequest(p), opts);
  const res = await fetch(`https://${signed.hostname}${signed.path}`, {
    method: signed.method,
    headers: signed.headers,
    body: signed.body,
  });
  return { status: res.status, body: await res.text() };
}

/** Streaming invoke. Parses the SSE stream into the agent's prose blocks and
 *  classifies them: every text block except the last is a NARRATION (the human
 *  "what I'm doing now" line → shown live in the 分析过程 panel), the last text
 *  block is the CONCLUSION (the answer). Tool-use/result/thinking blocks are not
 *  surfaced. onChunk(conclusionSoFar, narrations) fires as the stream arrives.
 *
 *  Streaming nuance: we can't know which text block is "last" until the stream
 *  ends, so mid-stream the newest text block is treated as the (provisional)
 *  conclusion; if another tool_use follows it, it retroactively becomes a
 *  narration and a fresh conclusion block starts. */
/** Per-invoke latency breakdown for perf analysis (all ms, -1 = never reached). */
export interface InvokeTiming {
  signMs: number;       // SigV4 sign + build
  ttfbMs: number;       // request sent → response headers (first byte)
  ttftMs: number;       // request sent → first non-empty text block on screen
  ttfcMs: number;       // request sent → first token of the FINAL conclusion block
                        // (the "how long until the answer starts" metric — the
                        // gap ttfcMs→streamEnd is the conclusion's own stream time;
                        // a huge ttfcMs with a tiny conclusion gap is the
                        // "thinks forever, dumps at end" signature issue #3 fixes)
  lastTokenMs: number;  // request sent → last text token (trailing time after =
                        // streamMs+ttfbMs - lastTokenMs is dead time at the end)
  streamMs: number;     // first byte → stream end (the long pole: model+tools)
  totalMs: number;      // whole invokeRuntimeStreaming call
  events: number;       // SSE data events parsed
}

export async function invokeRuntimeStreaming(
  p: InvokeParams,
  opts: SignOptions,
  onChunk: (conclusionSoFar: string, narrations: string[]) => void,
  signal?: AbortSignal,
): Promise<{ status: number; answer: string; steps: string[]; aborted: boolean; error: string | null; timing: InvokeTiming }> {
  const t0 = Date.now();
  const timing: InvokeTiming = { signMs: 0, ttfbMs: -1, ttftMs: -1, ttfcMs: -1, lastTokenMs: -1, streamMs: -1, totalMs: 0, events: 0 };
  const signed = await signInvoke(buildInvokeRequest(p), opts);
  timing.signMs = Date.now() - t0;
  const tReq = Date.now();
  let res: Response;
  try {
    res = await fetch(`https://${signed.hostname}${signed.path}`, {
      method: signed.method,
      headers: signed.headers,
      body: signed.body,
      signal,
    });
  } catch (e) {
    if (signal?.aborted) return { status: 200, answer: "", steps: [], aborted: true, error: null, timing: { ...timing, totalMs: Date.now() - t0 } };
    throw e;
  }
  timing.ttfbMs = Date.now() - tReq;
  if (res.status !== 200 || !res.body) {
    return { status: res.status, answer: await res.text(), steps: [], aborted: false, error: null, timing: { ...timing, totalMs: Date.now() - t0 } };
  }
  const tFirstByte = Date.now();
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";

  // Shared tool-gated accumulator (parse-stream.ts) — single source of truth so
  // the live incremental parse and the whole-string parseAgentStream can't diverge.
  const state = newStreamState();
  const texts = state.texts;
  let lastTextLen = 0;          // total text chars seen, to detect token growth
  let lastBlockCount = 0;       // number of text blocks, to detect a NEW conclusion block
  const processEvent = (jsonStr: string): void => {
    let evt: Record<string, unknown>;
    try { evt = JSON.parse(jsonStr); } catch { return; }
    timing.events++;
    applyEvent(state, evt);
    const totalLen = state.texts.reduce((n, t) => n + t.length, 0);
    // First moment real answer text exists → time-to-first-token (on screen).
    if (timing.ttftMs < 0 && totalLen > 0) timing.ttftMs = Date.now() - tReq;
    // Time-to-first-conclusion: the LAST text block is the (provisional)
    // conclusion. Each time a NEW text block opens, the prior provisional
    // conclusion was actually a narration; so re-arm ttfc to the first token of
    // the newest block. On stream end the last value sticks = the real conclusion.
    if (state.texts.length > lastBlockCount && totalLen > lastTextLen) {
      timing.ttfcMs = Date.now() - tReq;  // newest block's first token
      lastBlockCount = state.texts.length;
    }
    // Track the last moment any token arrived (trailing dead-time analysis).
    if (totalLen > lastTextLen) {
      timing.lastTokenMs = Date.now() - tReq;
      lastTextLen = totalLen;
    }
  };

  let aborted = false;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line.startsWith("data:")) {
          const jsonStr = line.slice(5).trim();
          if (jsonStr.startsWith("{")) processEvent(jsonStr);
        }
      }
      // Mid-stream: newest text block is the provisional conclusion, the rest
      // (before it) are narrations.
      const conclusionSoFar = texts.length > 0 ? texts[texts.length - 1] : "";
      onChunk(conclusionSoFar, texts.slice(0, -1));
    }
  } catch (e) {
    // User pressed 停止 → fetch/read aborted. Keep whatever we have so far.
    if (signal?.aborted) aborted = true;
    else throw e;
  }
  // Flush any trailing buffered line.
  if (buf.trim().startsWith("data:")) {
    const jsonStr = buf.trim().slice(5).trim();
    if (jsonStr.startsWith("{")) processEvent(jsonStr);
  }

  const answer = texts.length > 0 ? texts[texts.length - 1] : "";
  const steps = texts.slice(0, -1);
  timing.streamMs = Date.now() - tFirstByte;
  timing.totalMs = Date.now() - t0;
  return { status: res.status, answer, steps, aborted, error: state.error, timing };
}
