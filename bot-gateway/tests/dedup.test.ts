/**
 * Unit tests for event_id deduplication (飞书 event replay protection).
 *
 * Feishu may re-deliver the same event (same event_id) multiple times.
 * The dedup module must:
 *  - Accept the first occurrence of an event_id (returns false = not duplicate).
 *  - Reject subsequent occurrences within the TTL window (returns true = duplicate).
 *  - Auto-expire entries after TTL so memory doesn't grow unbounded.
 */

import { isDuplicate, forget, resetForTesting } from "../src/dedup";

afterEach(() => {
  resetForTesting();
});

describe("isDuplicate", () => {
  it("returns false for a new event_id", () => {
    expect(isDuplicate("evt_001")).toBe(false);
  });

  it("returns true for a repeated event_id", () => {
    isDuplicate("evt_002");
    expect(isDuplicate("evt_002")).toBe(true);
  });

  it("forget() rolls back a mark so the same id can be processed again (failed-send retry)", () => {
    expect(isDuplicate("evt_fail")).toBe(false); // first delivery
    forget("evt_fail");                          // send failed → roll back
    expect(isDuplicate("evt_fail")).toBe(false); // re-delivery is NOT dropped → retries
    expect(isDuplicate("evt_fail")).toBe(true);  // and the retry's mark sticks
  });

  it("forget() on an unknown id is a no-op", () => {
    expect(() => forget("never_seen")).not.toThrow();
  });

  it("tracks multiple distinct event_ids independently", () => {
    isDuplicate("evt_a");
    isDuplicate("evt_b");
    expect(isDuplicate("evt_a")).toBe(true);
    expect(isDuplicate("evt_b")).toBe(true);
    expect(isDuplicate("evt_c")).toBe(false);
  });

  it("does NOT expire before the default TTL (must outlive a ~9-min invoke)", () => {
    // The window must exceed the longest in-flight invoke (~9 min) so a guard can't
    // lapse mid-flight and let a re-delivery double-answer. At 10 min it's still live.
    jest.useFakeTimers();
    isDuplicate("evt_live");
    jest.advanceTimersByTime(10 * 60 * 1000);
    expect(isDuplicate("evt_live")).toBe(true); // still within the 15-min window
    jest.useRealTimers();
  });

  it("expires entries after the default TTL (15 minutes)", () => {
    jest.useFakeTimers();
    isDuplicate("evt_ttl");
    expect(isDuplicate("evt_ttl")).toBe(true);

    // Advance past the default TTL (15 minutes — see DEFAULT_TTL_MS rationale).
    jest.advanceTimersByTime(15 * 60 * 1000 + 1);

    expect(isDuplicate("evt_ttl")).toBe(false); // expired, treated as new
    jest.useRealTimers();
  });

  it("honors a custom SHORT ttlMs (callback composite-key path): redelivery swallowed, later re-tap allowed", () => {
    // The card-action callback uses a 90s TTL for the COMPOSITE fallback key (no real
    // event_id), so a seconds-apart Feishu redelivery is still deduped, but a deliberate
    // re-tap minutes later is NOT silently swallowed (cross-review P1).
    jest.useFakeTimers();
    const SHORT = 90_000;
    expect(isDuplicate("cb:composite", SHORT)).toBe(false);  // first tap
    jest.advanceTimersByTime(3_000);
    expect(isDuplicate("cb:composite", SHORT)).toBe(true);   // redelivery seconds later → swallowed
    jest.advanceTimersByTime(90_000);                        // 90s+ later (deliberate re-tap)
    expect(isDuplicate("cb:composite", SHORT)).toBe(false);  // re-tap is allowed, not dropped
    jest.useRealTimers();
  });
});
