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

/** Streaming invoke: calls onChunk with each extracted text fragment as the SSE
 *  arrives, so the caller can update the card incrementally. Also extracts tool
 *  calls (agent reasoning steps) for the collapsible panel. */
export async function invokeRuntimeStreaming(
  p: InvokeParams,
  opts: SignOptions,
  onChunk: (textSoFar: string) => void,
): Promise<{ status: number; answer: string; reasoning: string }> {
  const signed = await signInvoke(buildInvokeRequest(p), opts);
  const res = await fetch(`https://${signed.hostname}${signed.path}`, {
    method: signed.method,
    headers: signed.headers,
    body: signed.body,
  });
  if (res.status !== 200 || !res.body) {
    return { status: res.status, answer: await res.text(), reasoning: "" };
  }
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  let answer = "";
  const toolSteps: string[] = [];
  const textRe = /"text":\s*"((?:[^"\\]|\\.)*)"/g;
  // Tool use: {"name": "Read", "input": {"file_path": "..."}}
  const toolRe = /"name":\s*"([^"]+)",\s*"input":\s*(\{[^}]*\})/g;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });

    // Extract text blocks (the agent's answer).
    let match: RegExpExecArray | null;
    while ((match = textRe.exec(buf)) !== null) {
      try {
        answer += JSON.parse(`"${match[1]}"`);
      } catch {
        answer += match[1];
      }
    }

    // Extract tool calls (reasoning steps — what the agent looked at).
    let toolMatch: RegExpExecArray | null;
    while ((toolMatch = toolRe.exec(buf)) !== null) {
      const name = toolMatch[1];
      try {
        const input = JSON.parse(toolMatch[2]);
        const desc = name === "Read" ? `读取 ${input.file_path ?? ""}`
          : name === "Glob" ? `搜索 ${input.pattern ?? ""}`
          : name === "Grep" ? `查找 ${input.pattern ?? ""}`
          : `${name}(${JSON.stringify(input).slice(0, 60)})`;
        if (!toolSteps.includes(desc)) toolSteps.push(desc);
      } catch {
        if (!toolSteps.includes(name)) toolSteps.push(name);
      }
    }

    // Keep only the unparsed tail (last incomplete line).
    const lastNl = buf.lastIndexOf("\n");
    if (lastNl >= 0) {
      buf = buf.slice(lastNl + 1);
      textRe.lastIndex = 0;
      toolRe.lastIndex = 0;
    }
    onChunk(answer);
  }

  const reasoning = toolSteps.length > 0
    ? "**取证步骤：**\n" + toolSteps.map((s) => `- ${s}`).join("\n")
    : "";
  return { status: res.status, answer, reasoning };
}
