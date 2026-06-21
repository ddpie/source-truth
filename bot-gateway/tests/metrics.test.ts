import { emitMetric, setMetricSink, classifyFailure } from "../src/metrics";

// Capture emitted records via the injectable sink.
let records: Array<Record<string, unknown>>;
beforeEach(() => {
  records = [];
  setMetricSink((r) => records.push(r));
});

describe("emitMetric — public fields + shape", () => {
  it("stamps event, metric:true, and an ISO ts on every event", () => {
    emitMetric("answer_completed", { latencyMs: 1200 }, { traceId: "st-abc", nowMs: 0 });
    expect(records).toHaveLength(1);
    const r = records[0];
    expect(r.event).toBe("answer_completed");
    expect(r.metric).toBe(true);
    expect(r.ts).toBe("1970-01-01T00:00:00.000Z");
    expect(r.latencyMs).toBe(1200);
  });

  it("includes sessionId/projectId when provided", () => {
    emitMetric("answer_completed", {}, { traceId: "st-1", sessionId: "sess-9", projectId: "proj-A" });
    expect(records[0].sessionId).toBe("sess-9");
    expect(records[0].projectId).toBe("proj-A");
  });
});

describe("emitMetric — physical key split (PII discipline §4)", () => {
  it("USER-LEVEL events carry hashUserId and NEVER traceId", () => {
    emitMetric("question_received", { chatType: "group" },
      { hashUserId: "u_deadbeef", traceId: "st-should-not-appear" });
    const r = records[0];
    expect(r.hashUserId).toBe("u_deadbeef");
    expect(r.traceId).toBeUndefined();           // traceId dropped on a user-level event
  });

  it("DIAGNOSTIC events carry traceId and NEVER hashUserId", () => {
    emitMetric("answer_completed", { latencyMs: 50 },
      { traceId: "st-xyz", hashUserId: "u_should-not-appear" });
    const r = records[0];
    expect(r.traceId).toBe("st-xyz");
    expect(r.hashUserId).toBeUndefined();        // hashUserId dropped on a diagnostic event
  });

  it("feedback_voted (user-level) keeps hashUserId, drops traceId", () => {
    emitMetric("feedback_voted", { vote: "up" }, { hashUserId: "u_1", traceId: "st-1" });
    expect(records[0].hashUserId).toBe("u_1");
    expect(records[0].traceId).toBeUndefined();
  });

  it("gateway_heartbeat is a no-id system event (metric:true, no traceId/hashUserId)", () => {
    // The liveness heartbeat is emitted on a timer with no context — it must still produce a
    // clean metric:true line (that's what the GatewayHeartbeat filter + liveness alarm read).
    emitMetric("gateway_heartbeat", {});
    expect(records[0].event).toBe("gateway_heartbeat");
    expect(records[0].metric).toBe(true);
    expect(records[0].traceId).toBeUndefined();
    expect(records[0].hashUserId).toBeUndefined();
  });
});

describe("emitMetric — enum whitelist (no free-text / PII leak)", () => {
  it("keeps a valid reason enum", () => {
    emitMetric("answer_failed", { reason: "cold_start_mcp_race" }, { traceId: "st-1" });
    expect(records[0].reason).toBe("cold_start_mcp_race");
  });

  it("replaces a NON-enum reason with the safe fallback (a leaked question can't pass through)", () => {
    // Simulate an any-typed call site trying to stuff the user's question into reason.
    emitMetric("answer_failed", { reason: "用户问的原始问题文本泄漏" } as never, { traceId: "st-1" });
    expect(records[0].reason).toBe("unknown");    // dropped to fallback, NOT logged verbatim
    expect(JSON.stringify(records[0])).not.toContain("用户问的原始问题文本");
  });

  it("replaces a bad reasonCode with 'other' and a bad kind with 'invalid'", () => {
    emitMetric("feedback_reason", { reasonCode: "free text here" } as never, { hashUserId: "u_1" });
    expect(records[0].reasonCode).toBe("other");
    emitMetric("card_health", { kind: "something arbitrary" } as never, { traceId: "st-1" });
    expect(records[0 + 1].kind).toBe("invalid");
  });

  it("keeps valid feedback reasonCode + card_health kind", () => {
    emitMetric("feedback_reason", { reasonCode: "no_evidence" }, { hashUserId: "u_1" });
    expect(records[0].reasonCode).toBe("no_evidence");
    emitMetric("card_health", { kind: "toolcall_leak_detected" }, { traceId: "st-1" });
    expect(records[1].kind).toBe("toolcall_leak_detected");
  });

  it("accepts the new non-technical-audience reason codes (too_slow / hard_to_understand / too_shallow)", () => {
    for (const code of ["too_slow", "hard_to_understand", "too_shallow"]) {
      records = [];
      emitMetric("feedback_reason", { reasonCode: code }, { hashUserId: "u_1" });
      expect(records[0].reasonCode).toBe(code);   // whitelisted, not dropped to "other"
    }
  });

  it("accepts all wired card_health kinds (leak/finalize/dedup); dedup_hit is keyless infra", () => {
    emitMetric("card_health", { kind: "finalize_failed" }, { traceId: "st-2" });
    expect(records[0].kind).toBe("finalize_failed");
    expect(records[0].traceId).toBe("st-2");
    records = [];
    // dedup_hit is emitted with NO ctx (pure infra counter — no invoke, no user).
    emitMetric("card_health", { kind: "dedup_hit" });
    expect(records[0].kind).toBe("dedup_hit");
    expect(records[0].hashUserId).toBeUndefined();
    expect(records[0].traceId).toBeUndefined();
    expect(records[0].metric).toBe(true);
  });
});

describe("emitMetric — best-effort (never breaks the hot path §1)", () => {
  it("does NOT throw when the sink throws", () => {
    setMetricSink(() => { throw new Error("sink down (e.g. CloudWatch agent dead)"); });
    expect(() => emitMetric("answer_completed", { latencyMs: 1 }, { traceId: "st-1" })).not.toThrow();
  });

  it("does NOT throw on a circular-reference field (JSON.stringify would throw in the sink)", () => {
    const circular: Record<string, unknown> = {};
    circular.self = circular;
    // default sink does JSON.stringify; ensure the wrapping try/catch swallows it
    setMetricSink((r) => { JSON.stringify(r); });
    expect(() => emitMetric("answer_completed", { bad: circular }, { traceId: "st-1" })).not.toThrow();
  });
});

describe("classifyFailure — backend error → FailReason (failure-by-reason dashboard)", () => {
  it("maps IAM/authorization errors to auth_denied", () => {
    expect(classifyFailure('HTTP 403: User ... is not authorized to perform: bedrock-agentcore:InvokeAgentRuntime')).toBe("auth_denied");
    expect(classifyFailure("AccessDeniedException")).toBe("auth_denied");
    expect(classifyFailure("403 Forbidden")).toBe("auth_denied");
  });
  it("maps throttle / rate-limit / 429 / 503 to upstream_throttle", () => {
    expect(classifyFailure("ThrottlingException: Rate exceeded")).toBe("upstream_throttle");
    expect(classifyFailure("HTTP 429: too many requests")).toBe("upstream_throttle");
    expect(classifyFailure("ServiceUnavailable (503)")).toBe("upstream_throttle");
  });
  it("falls back to unknown for empty/unrecognized errors", () => {
    expect(classifyFailure("")).toBe("unknown");
    expect(classifyFailure(undefined)).toBe("unknown");
    expect(classifyFailure(null)).toBe("unknown");
    expect(classifyFailure("some weird internal error xyz")).toBe("unknown");
  });
  it("does not misclassify a 403 substring inside an unrelated number", () => {
    // \b403\b must not match e.g. "14039" — guards against false auth_denied.
    expect(classifyFailure("latency was 14039ms")).toBe("unknown");
  });
});
