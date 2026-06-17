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
