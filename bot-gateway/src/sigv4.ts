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

export interface SignOptions {
  region: string;
  credentials: {
    accessKeyId: string;
    secretAccessKey: string;
    sessionToken?: string;
  };
}

/** Build the (unsigned) InvokeAgentRuntime request. Pure. */
export function buildInvokeRequest(p: InvokeParams): InvokeRequest {
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
export async function invokeRuntimeStreaming(
  p: InvokeParams,
  opts: SignOptions,
  onChunk: (conclusionSoFar: string, narrations: string[]) => void,
  signal?: AbortSignal,
): Promise<{ status: number; answer: string; steps: string[]; aborted: boolean }> {
  const signed = await signInvoke(buildInvokeRequest(p), opts);
  let res: Response;
  try {
    res = await fetch(`https://${signed.hostname}${signed.path}`, {
      method: signed.method,
      headers: signed.headers,
      body: signed.body,
      signal,
    });
  } catch (e) {
    if (signal?.aborted) return { status: 200, answer: "", steps: [], aborted: true };
    throw e;
  }
  if (res.status !== 200 || !res.body) {
    return { status: res.status, answer: await res.text(), steps: [], aborted: false };
  }
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";

  // texts[] = prose blocks in order; sawToolAfterLastText marks that a tool_use
  // arrived after the latest text, so the next text starts a new block.
  const texts: string[] = [];
  let sawToolAfterLastText = true; // first text starts a fresh block

  const processEvent = (jsonStr: string): void => {
    let evt: { content?: Array<Record<string, unknown>> };
    try { evt = JSON.parse(jsonStr); } catch { return; }
    const item = evt.content?.[0];
    if (!item) return;
    if (typeof item.text === "string") {
      if (sawToolAfterLastText) {
        texts.push(item.text);
        sawToolAfterLastText = false;
      } else {
        // Same logical block continued (rare): append to the current one.
        texts[texts.length - 1] = item.text;
      }
    } else if (typeof item.name === "string" && "input" in item) {
      // tool_use: the preceding text block is now a finished narration.
      sawToolAfterLastText = true;
    }
    // thinking / tool_result: ignored.
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
  return { status: res.status, answer, steps, aborted };
}
