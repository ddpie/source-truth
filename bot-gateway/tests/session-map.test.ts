/**
 * Unit tests for session-map: (chatId, threadId?) → runtimeSessionId.
 *
 * Contract (architecture.md):
 *  - Same (chatId + threadId) always maps to the same sessionId.
 *  - Different chat/thread get different sessionIds.
 *  - Entries expire after TTL (memory bound).
 */

import { getSessionId, getSessionState, resetForTesting, setBusyProbe } from "../src/session-map";

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

describe("warm-session pool (best-effort borrow)", () => {
  it("a new chat borrows an IDLE warm session instead of cold-starting", () => {
    // All sessions idle.
    setBusyProbe(() => false);
    const a = getSessionState("chat_A");
    expect(a.cold).toBe(true); // first ever → real cold mint
    const b = getSessionState("chat_B");
    expect(b.sessionId).toBe(a.sessionId); // borrowed chat_A's warm session
    expect(b.cold).toBe(false); // borrowed ⇒ NOT a cold start
  });

  it("does NOT borrow a BUSY session — mints a fresh one instead", () => {
    const a = getSessionId("chat_A"); // default probe = busy
    const b = getSessionId("chat_B");
    expect(b).not.toBe(a); // a is busy, can't borrow → fresh mint
  });

  it("borrows the MOST-recently-used idle session", () => {
    // Grow two DISTINCT sessions by holding everything busy during minting.
    setBusyProbe(() => true);
    const s1 = getSessionId("chat_1");
    const s2 = getSessionId("chat_2");
    expect(s2).not.toBe(s1); // two distinct warm sessions, s2 minted last (MRU)
    // Now everything idle: a new key should borrow the MRU idle one (s2).
    setBusyProbe(() => false);
    const borrowed = getSessionId("chat_3");
    expect(borrowed).toBe(s2);
  });

  it("caps distinct sessions at MAX_CONCURRENT_INVOKES (default 8) when all busy", () => {
    // Every session busy → never borrow → mint until cap, then share OLDEST.
    setBusyProbe(() => true);
    const ids = new Set<string>();
    for (let i = 0; i < 12; i++) ids.add(getSessionId(`chat_${i}`));
    expect(ids.size).toBe(8); // hard cap; turns 9–12 shared an existing session
  });

  it("when full AND all busy, an overflow turn shares the OLDEST session", () => {
    setBusyProbe(() => true);
    const first = getSessionId("chat_0"); // oldest (minted first)
    for (let i = 1; i < 8; i++) getSessionId(`chat_${i}`); // fill to cap (8 distinct)
    const overflow = getSessionId("chat_overflow"); // pool full, all busy → share
    expect(overflow).toBe(first); // oldest, not MRU → frees up soonest
  });

  it("reused key stays sticky and warm (cold=false on 2nd hit)", () => {
    setBusyProbe(() => false);
    const first = getSessionState("chat_sticky");
    const second = getSessionState("chat_sticky");
    expect(second.sessionId).toBe(first.sessionId);
    expect(second.cold).toBe(false);
  });
});
