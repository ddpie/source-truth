/**
 * Unit tests for session-map: (chatId, threadId?) → runtimeSessionId.
 *
 * Contract (architecture.md):
 *  - Same (chatId + threadId) always maps to the same sessionId.
 *  - Different chat/thread get different sessionIds.
 *  - Entries expire after TTL (memory bound).
 */

import { getSessionId, resetForTesting } from "../src/session-map";

afterEach(() => {
  resetForTesting();
});

describe("getSessionId", () => {
  it("returns a non-empty string for a new chat", () => {
    const id = getSessionId("chat_001");
    expect(id).toBeTruthy();
    expect(typeof id).toBe("string");
  });

  it("returns the same sessionId for the same chatId", () => {
    const a = getSessionId("chat_001");
    const b = getSessionId("chat_001");
    expect(a).toBe(b);
  });

  it("returns different sessionIds for different chatIds", () => {
    const a = getSessionId("chat_001");
    const b = getSessionId("chat_002");
    expect(a).not.toBe(b);
  });

  it("distinguishes same chat with different threadIds", () => {
    const a = getSessionId("chat_001", "thread_A");
    const b = getSessionId("chat_001", "thread_B");
    expect(a).not.toBe(b);
  });

  it("same chat + same thread returns same sessionId", () => {
    const a = getSessionId("chat_001", "thread_A");
    const b = getSessionId("chat_001", "thread_A");
    expect(a).toBe(b);
  });

  it("expires entries after the default TTL (15min, aligned to AgentCore idle)", () => {
    jest.useFakeTimers();
    const before = getSessionId("chat_ttl");
    // Default TTL is 900s (15min) = AgentCore's default idle timeout, unless
    // RUNTIME_IDLE_TIMEOUT_SECS overrides it (unset in this test env).
    jest.advanceTimersByTime(15 * 60 * 1000 + 1);
    const after = getSessionId("chat_ttl");
    expect(after).not.toBe(before); // new session after expiry
    jest.useRealTimers();
  });

  it("does NOT expire just before the default TTL", () => {
    jest.useFakeTimers();
    const before = getSessionId("chat_ttl2");
    jest.advanceTimersByTime(15 * 60 * 1000 - 1000); // 1s short of expiry
    const after = getSessionId("chat_ttl2");
    expect(after).toBe(before); // still warm
    jest.useRealTimers();
  });

  it("honors an explicit ttlMs override (caller-supplied)", () => {
    jest.useFakeTimers();
    const before = getSessionId("chat_ttl3", undefined, 60 * 1000); // 60s TTL
    jest.advanceTimersByTime(60 * 1000 + 1);
    const after = getSessionId("chat_ttl3", undefined, 60 * 1000);
    expect(after).not.toBe(before);
    jest.useRealTimers();
  });
});
