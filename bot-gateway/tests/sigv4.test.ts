/**
 * Unit tests for SigV4 signing of AgentCore InvokeAgentRuntime requests.
 *
 * buildInvokeRequest is pure (path/headers/body shape). signInvoke produces a
 * real SigV4 Authorization header given static credentials — verified by
 * asserting the header shape (no network). Real invoke is integration-only.
 */

import { buildInvokeRequest, signInvoke } from "../src/sigv4";

const RUNTIME_ARN =
  "arn:aws:bedrock-agentcore:ap-northeast-1:557690613480:runtime/source_truth_agent-3nxWGkGA86";

describe("buildInvokeRequest", () => {
  it("builds the correct invocations path with url-encoded ARN", () => {
    const req = buildInvokeRequest({
      runtimeArn: RUNTIME_ARN,
      region: "ap-northeast-1",
      sessionId: "sess-123",
      prompt: "where is match logic",
    });
    expect(req.path).toBe(
      `/runtimes/${encodeURIComponent(RUNTIME_ARN)}/invocations`,
    );
    expect(req.method).toBe("POST");
    expect(req.hostname).toBe("bedrock-agentcore.ap-northeast-1.amazonaws.com");
  });

  it("carries the runtimeSessionId header", () => {
    const req = buildInvokeRequest({
      runtimeArn: RUNTIME_ARN,
      region: "ap-northeast-1",
      sessionId: "sess-abc",
      prompt: "x",
    });
    expect(req.headers["X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"]).toBe("sess-abc");
    expect(req.headers["Content-Type"]).toContain("application/json");
  });

  it("puts the prompt in the JSON body", () => {
    const req = buildInvokeRequest({
      runtimeArn: RUNTIME_ARN,
      region: "ap-northeast-1",
      sessionId: "s",
      prompt: "消除判定逻辑在哪",
    });
    expect(JSON.parse(req.body)).toEqual({ prompt: "消除判定逻辑在哪" });
  });
});

describe("signInvoke", () => {
  it("produces a SigV4 Authorization header", async () => {
    const req = buildInvokeRequest({
      runtimeArn: RUNTIME_ARN,
      region: "ap-northeast-1",
      sessionId: "s",
      prompt: "x",
    });
    const signed = await signInvoke(req, {
      region: "ap-northeast-1",
      credentials: { accessKeyId: "AKIDEXAMPLE", secretAccessKey: "secret" },
    });
    const auth = signed.headers["Authorization"] ?? signed.headers["authorization"];
    expect(auth).toMatch(/^AWS4-HMAC-SHA256 /);
    expect(auth).toContain("ap-northeast-1/bedrock-agentcore/aws4_request");
    expect(signed.headers["X-Amz-Date"] ?? signed.headers["x-amz-date"]).toBeTruthy();
  });
});
