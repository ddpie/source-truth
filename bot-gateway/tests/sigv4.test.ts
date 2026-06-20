/**
 * Unit tests for SigV4 signing of AgentCore InvokeAgentRuntime requests.
 *
 * buildInvokeRequest is pure (path/headers/body shape). signInvoke produces a
 * real SigV4 Authorization header given static credentials — verified by
 * asserting the header shape (no network). Real invoke is integration-only.
 */

import { buildInvokeRequest, signInvoke, MIN_SESSION_ID_LEN, classifyInvokeOutcome, isTurnCapError } from "../src/sigv4";

const RUNTIME_ARN =
  "arn:aws:bedrock-agentcore:ap-northeast-1:557690613480:runtime/source_truth_agent-3nxWGkGA86";

// AgentCore requires runtimeSessionId >= 33 chars; a real randomUUID (36) is the
// production value, so tests use a valid-length id (UUID-shaped literal).
const SESSION_ID = "53adfc99-0324-48fc-8bbd-ebcbcce22bb2";

describe("buildInvokeRequest", () => {
  it("builds the correct invocations path with url-encoded ARN", () => {
    const req = buildInvokeRequest({
      runtimeArn: RUNTIME_ARN,
      region: "ap-northeast-1",
      sessionId: SESSION_ID,
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
      sessionId: SESSION_ID,
      prompt: "x",
    });
    expect(req.headers["X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"]).toBe(SESSION_ID);
    expect(req.headers["Content-Type"]).toContain("application/json");
  });

  it("puts the prompt in the JSON body", () => {
    const req = buildInvokeRequest({
      runtimeArn: RUNTIME_ARN,
      region: "ap-northeast-1",
      sessionId: SESSION_ID,
      prompt: "消除判定逻辑在哪",
    });
    expect(JSON.parse(req.body)).toEqual({ prompt: "消除判定逻辑在哪" });
  });

  it("forwards traceId in the body when provided (so the agent stamps its logs)", () => {
    const req = buildInvokeRequest({
      runtimeArn: RUNTIME_ARN,
      region: "ap-northeast-1",
      sessionId: SESSION_ID,
      prompt: "x",
      traceId: "st-deadbeef",
    });
    expect(JSON.parse(req.body)).toEqual({ prompt: "x", traceId: "st-deadbeef" });
  });

  it("omits traceId from the body when not provided (wire shape unchanged)", () => {
    const req = buildInvokeRequest({
      runtimeArn: RUNTIME_ARN,
      region: "ap-northeast-1",
      sessionId: SESSION_ID,
      prompt: "x",
    });
    expect(Object.keys(JSON.parse(req.body))).toEqual(["prompt"]);
  });

  it("forwards repos in the body when provided (multi-repo 阶段1 project repo set)", () => {
    const req = buildInvokeRequest({
      runtimeArn: RUNTIME_ARN,
      region: "ap-northeast-1",
      sessionId: SESSION_ID,
      prompt: "x",
      traceId: "st-1",
      repos: ["code-5x", "code-5x-svc"],
    });
    expect(JSON.parse(req.body)).toEqual({ prompt: "x", traceId: "st-1", repos: ["code-5x", "code-5x-svc"] });
  });

  it("omits repos when unset or empty (single-repo deploy: wire shape unchanged)", () => {
    const bare = buildInvokeRequest({ runtimeArn: RUNTIME_ARN, region: "ap-northeast-1", sessionId: SESSION_ID, prompt: "x" });
    expect(Object.keys(JSON.parse(bare.body))).toEqual(["prompt"]);
    const empty = buildInvokeRequest({ runtimeArn: RUNTIME_ARN, region: "ap-northeast-1", sessionId: SESSION_ID, prompt: "x", repos: [] });
    expect(Object.keys(JSON.parse(empty.body))).toEqual(["prompt"]);  // empty array → omitted
  });

  it("rejects a runtimeSessionId shorter than the AgentCore minimum", () => {
    expect(MIN_SESSION_ID_LEN).toBeGreaterThanOrEqual(33);
    expect(() =>
      buildInvokeRequest({
        runtimeArn: RUNTIME_ARN,
        region: "ap-northeast-1",
        sessionId: "too-short", // < 33 chars → AgentCore would 400
        prompt: "x",
      }),
    ).toThrow(/runtimeSessionId/);
    // A real UUID (36 chars) is accepted.
    expect(SESSION_ID.length).toBeGreaterThanOrEqual(MIN_SESSION_ID_LEN);
  });
});

describe("signInvoke", () => {
  it("produces a SigV4 Authorization header", async () => {
    const req = buildInvokeRequest({
      runtimeArn: RUNTIME_ARN,
      region: "ap-northeast-1",
      sessionId: SESSION_ID,
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

  // Regression: the gateway must sign with a credential PROVIDER, re-resolved on
  // every request, not a snapshot resolved once at startup. A static snapshot of
  // EC2 instance-role (IMDS) credentials expires after a few hours, after which
  // every AgentCore invoke 403s while the process keeps running (observed: a
  // gateway up ~11h started 403-ing; a freshly restarted one worked). Passing the
  // auto-refreshing provider lets SignatureV4 pull fresh creds per sign.
  it("accepts a credential provider and re-resolves it per sign (no stale snapshot)", async () => {
    let calls = 0;
    const provider = async () => {
      calls++;
      return { accessKeyId: `AKID${calls}EXAMPLE`, secretAccessKey: "secret" };
    };
    const req = buildInvokeRequest({
      runtimeArn: RUNTIME_ARN,
      region: "ap-northeast-1",
      sessionId: SESSION_ID,
      prompt: "x",
    });
    const a = await signInvoke(req, { region: "ap-northeast-1", credentials: provider });
    const b = await signInvoke(req, { region: "ap-northeast-1", credentials: provider });
    // Provider invoked once per sign — not cached from a single startup resolve.
    expect(calls).toBe(2);
    // Distinct creds → distinct signatures, proving each sign re-resolved.
    const authA = a.headers["Authorization"] ?? a.headers["authorization"];
    const authB = b.headers["Authorization"] ?? b.headers["authorization"];
    expect(authA).not.toEqual(authB);
  });
});

describe("classifyInvokeOutcome", () => {
  const ok = { status: 200, answer: "the answer", steps: [], aborted: false, error: null };

  it("treats a clean 200 with no error as success (not failed)", () => {
    expect(classifyInvokeOutcome(ok).failed).toBe(false);
  });

  // The regression: a non-200 (403 from expired SigV4 creds, or any 4xx/5xx)
  // must be classified as FAILED so the caller finalizes the card, NOT thrown
  // (which left the streaming card stuck forever).
  it("classifies a 403 as failed (expired-credentials shape)", () => {
    const r = { status: 403, answer: "Forbidden", steps: [], aborted: false, error: null };
    expect(classifyInvokeOutcome(r).failed).toBe(true);
  });

  it("classifies any non-200 HTTP as failed", () => {
    for (const status of [400, 401, 429, 500, 503]) {
      expect(classifyInvokeOutcome({ ...ok, status }).failed).toBe(true);
    }
  });

  it("classifies a stream-level error (over a 200) as failed", () => {
    const r = { status: 200, answer: "", steps: [], aborted: false, error: "index-service unreachable" };
    expect(classifyInvokeOutcome(r).failed).toBe(true);
  });

  // A user-pressed 停止 is NOT a failure — abort wins over both a non-200 and a
  // stream error, so the card finalizes as "已停止", not "查询失败".
  it("never marks an aborted invoke as failed, even on non-200 or error", () => {
    expect(classifyInvokeOutcome({ status: 403, answer: "", steps: [], aborted: true, error: null }).failed).toBe(false);
    expect(classifyInvokeOutcome({ status: 200, answer: "", steps: [], aborted: true, error: "x" }).failed).toBe(false);
  });
});

describe("isTurnCapError", () => {
  it("matches every shape the turn cap surfaces as", () => {
    // The SDK result text the gateway actually sees (parse-stream fixture):
    expect(isTurnCapError("Maximum turns exceeded")).toBe(true);
    // The errors[] phrasing + the subtype fallback:
    expect(isTurnCapError("Reached maximum number of turns (20)")).toBe(true);
    expect(isTurnCapError("result error (error_max_turns)")).toBe(true);
  });

  it("does NOT match genuine backend outages / denials / null", () => {
    expect(isTurnCapError("ConnectionError: connection refused")).toBe(false);
    expect(isTurnCapError("AccessDeniedException: ...")).toBe(false);
    expect(isTurnCapError(null)).toBe(false);
  });
});
