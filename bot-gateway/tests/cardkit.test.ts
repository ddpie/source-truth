/**
 * Unit tests for CardKit streaming rate-limiter (POC#3 core constraint).
 *
 * Constraints (from POC verification):
 *  - Max 10 card updates/sec; must throttle and merge intermediate chunks.
 *  - 10-minute streaming window; must handle expiry (renew or finalize).
 *  - Must close streaming before processing interaction callbacks.
 */

import {
  CardStream,
  RATE_LIMIT_INTERVAL_MS,
  STREAM_WINDOW_MS,
} from "../src/cardkit";

describe("CardStream rate-limiter", () => {
  beforeEach(() => jest.useFakeTimers());
  afterEach(() => jest.useRealTimers());

  it("immediately emits the first update", () => {
    const send = jest.fn();
    const cs = new CardStream(send);
    cs.push("hello");
    expect(send).toHaveBeenCalledTimes(1);
    expect(send).toHaveBeenCalledWith("hello");
  });

  it("throttles rapid updates to at most 1 per interval", () => {
    const send = jest.fn();
    const cs = new CardStream(send);
    cs.push("a");
    cs.push("b");
    cs.push("c");
    // Only first fires immediately; b and c are buffered.
    expect(send).toHaveBeenCalledTimes(1);
    jest.advanceTimersByTime(RATE_LIMIT_INTERVAL_MS);
    // After one interval, the LATEST buffered value fires (merge = last wins).
    expect(send).toHaveBeenCalledTimes(2);
    expect(send).toHaveBeenLastCalledWith("c");
  });

  it("emits all updates if spaced beyond the interval", () => {
    const send = jest.fn();
    const cs = new CardStream(send);
    cs.push("a");
    jest.advanceTimersByTime(RATE_LIMIT_INTERVAL_MS);
    cs.push("b");
    jest.advanceTimersByTime(RATE_LIMIT_INTERVAL_MS);
    cs.push("c");
    expect(send).toHaveBeenCalledTimes(3);
  });

  it("flushes remaining buffer on close", () => {
    const send = jest.fn();
    const cs = new CardStream(send);
    cs.push("a");
    cs.push("b");
    cs.close();
    // close flushes the pending buffer.
    expect(send).toHaveBeenCalledTimes(2);
    expect(send).toHaveBeenLastCalledWith("b");
  });

  it("close is idempotent", () => {
    const send = jest.fn();
    const cs = new CardStream(send);
    cs.push("x");
    cs.close();
    cs.close(); // no-op
    expect(send).toHaveBeenCalledTimes(1);
  });

  it("push after close is ignored", () => {
    const send = jest.fn();
    const cs = new CardStream(send);
    cs.push("x");
    cs.close();
    cs.push("y");
    expect(send).toHaveBeenCalledTimes(1);
  });

  it("exposes closed state for callback gating", () => {
    const cs = new CardStream(jest.fn());
    expect(cs.isClosed).toBe(false);
    cs.close();
    expect(cs.isClosed).toBe(true);
  });

  it("exports expected constants", () => {
    expect(RATE_LIMIT_INTERVAL_MS).toBe(100); // 10/sec = 100ms
    expect(STREAM_WINDOW_MS).toBe(10 * 60 * 1000);
  });
});
