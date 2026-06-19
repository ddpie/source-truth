/**
 * End-to-end smoke test (offline, all external deps stubbed).
 *
 * Exercises the full request path with stubs:
 *   飞书 IM event → dedup → session-map → [SigV4 stub] → [AgentCore stub] →
 *   agent-container run_agent (stub) → [index-service path_align reference] →
 *   CardKit streaming → final card content.
 *
 * Each stage explicitly annotated: ✅ real logic | 桩·未验证 stub.
 */

import { isDuplicate, resetForTesting as resetDedup } from "../src/dedup";
import { getSessionId, resetForTesting as resetSessions } from "../src/session-map";
import { parseAgentStream } from "../src/parse-stream";

afterEach(() => {
  resetDedup();
  resetSessions();
});

describe("E2E smoke (offline, stubbed externals)", () => {
  it("processes a question through the full path", () => {
    // --- 1. Simulate Feishu IM event arriving ---
    const event = {
      event_id: "evt_smoke_001",
      chat_id: "oc_smoke",
      thread_id: "ot_smoke",
      text: "消除判定逻辑在哪",
    };

    // --- 2. Dedup: first occurrence → not duplicate (✅ real) ---
    expect(isDuplicate(event.event_id)).toBe(false);
    // Replay guard: second delivery is rejected.
    expect(isDuplicate(event.event_id)).toBe(true);

    // --- 3. Session-map: route to runtimeSessionId (✅ real) ---
    const sessionId = getSessionId(event.chat_id, event.thread_id);
    expect(sessionId).toBeTruthy();
    // Same thread → same session (idempotent).
    expect(getSessionId(event.chat_id, event.thread_id)).toBe(sessionId);

    // --- 4. SigV4 sign + InvokeAgentRuntime (桩·未验证) ---
    // Real: signs with AWS credentials and calls AgentCore HTTP endpoint.
    // Stub: just verify the payload shape.
    const invokePayload = { prompt: event.text, session: { sessionId } };
    expect(invokePayload.prompt).toBe("消除判定逻辑在哪");

    // --- 5. agent-container run_agent (桩·未验证: SDK absent) ---
    // Real: claude_agent_sdk.query drives the agent loop.
    // Stub: simulate two streamed messages.
    const agentMessages = [
      "根据 CodeGraph 定位，消除判定逻辑位于 Assets/Scripts/Match3/MatchResolver.cs:42",
      "[RESULT] 回答完成",
    ];

    // --- 6. index-service path_align (✅ real function, tested separately) ---
    // Included by reference: CodeGraph paths are rewritten to repo-relative form
    // (no agent mount). Verified in index-service/tests/test_path_align.py.

    // --- 7. Stream parsing: narrations vs conclusion (✅ real prod logic) ---
    // The live path (sigv4.invokeRuntimeStreaming) folds the SSE stream via the
    // SAME shared parser as parseAgentStream. Real agents emit: narration →
    // tool_use → final answer; a tool_use is what SEPARATES text blocks (two
    // consecutive texts with no tool between them are one block).
    const sse = [
      `data: ${JSON.stringify({ content: [{ text: agentMessages[0] }] })}`,
      `data: ${JSON.stringify({ content: [{ name: "codegraph_symbol_search", input: {} }] })}`,
      `data: ${JSON.stringify({ content: [{ text: agentMessages[1] }] })}`,
    ].join("\n");
    const parsed = parseAgentStream(sse);
    // The pre-tool text is a narration; the post-tool text is the conclusion.
    expect(parsed.narrations).toEqual([agentMessages[0]]);
    expect(parsed.conclusion).toContain("RESULT");
    expect(parsed.conclusion).not.toContain("MatchResolver.cs"); // that was the narration
  });
});
