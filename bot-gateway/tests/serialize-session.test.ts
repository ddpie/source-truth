/**
 * Tests for SessionSerializer — the guard that stops two invokes from running
 * concurrently on the same runtimeSessionId (which would corrupt the one warm
 * microVM's SDK conversation). The load-bearing invariant: for a given key, at
 * most ONE task body is in flight at a time; same-key tasks run sequentially.
 */

import { SessionSerializer } from "../src/serialize-session";

const tick = () => new Promise((r) => setTimeout(r, 5));

describe("SessionSerializer", () => {
  it("runs same-key tasks strictly sequentially (never overlapping)", async () => {
    const s = new SessionSerializer();
    let active = 0;
    let maxActive = 0;
    const order: number[] = [];
    const make = (n: number) => async () => {
      active++;
      maxActive = Math.max(maxActive, active);
      await tick();
      order.push(n);
      active--;
      return n;
    };

    const p1 = s.serialize("sess-A", make(1));
    const p2 = s.serialize("sess-A", make(2));
    const p3 = s.serialize("sess-A", make(3));

    await Promise.all([p1, p2, p3]);
    expect(maxActive).toBe(1); // the whole point: never two at once on one key
    expect(order).toEqual([1, 2, 3]); // FIFO chaining
  });

  it("runs DIFFERENT keys concurrently (no false serialization across sessions)", async () => {
    const s = new SessionSerializer();
    let active = 0;
    let maxActive = 0;
    const make = () => async () => {
      active++;
      maxActive = Math.max(maxActive, active);
      await tick();
      active--;
    };
    await Promise.all([s.serialize("A", make()), s.serialize("B", make()), s.serialize("C", make())]);
    expect(maxActive).toBeGreaterThan(1); // distinct sessions don't block each other
  });

  it("a rejected task does NOT block the next queued task on the same key", async () => {
    const s = new SessionSerializer();
    const ran: string[] = [];
    const bad = s.serialize("A", async () => {
      ran.push("bad");
      throw new Error("boom");
    });
    const good = s.serialize("A", async () => {
      ran.push("good");
      return "ok";
    });
    await expect(bad).rejects.toThrow("boom"); // caller still sees its own rejection
    await expect(good).resolves.toBe("ok"); // but the queue keeps moving
    expect(ran).toEqual(["bad", "good"]);
  });

  it("clears the key after the last chained task settles (no leak)", async () => {
    const s = new SessionSerializer();
    const p = s.serialize("A", async () => {
      await tick();
    });
    expect(s.isBusy("A")).toBe(true);
    await p;
    await tick();
    expect(s.isBusy("A")).toBe(false);
  });

  it("isBusy reflects an actively queued chain and frees once drained", async () => {
    const s = new SessionSerializer();
    const p1 = s.serialize("A", async () => { await tick(); });
    const p2 = s.serialize("A", async () => { await tick(); });
    expect(s.isBusy("A")).toBe(true);
    await Promise.all([p1, p2]);
    await tick();
    expect(s.isBusy("A")).toBe(false);
  });
});
