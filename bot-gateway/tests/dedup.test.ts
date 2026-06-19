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

  it("expires entries after TTL", () => {
    jest.useFakeTimers();
    isDuplicate("evt_ttl");
    expect(isDuplicate("evt_ttl")).toBe(true);

    // Advance past default TTL (5 minutes)
    jest.advanceTimersByTime(5 * 60 * 1000 + 1);

    expect(isDuplicate("evt_ttl")).toBe(false); // expired, treated as new
    jest.useRealTimers();
  });
});
