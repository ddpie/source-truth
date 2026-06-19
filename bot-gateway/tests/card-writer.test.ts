/**
 * Tests for CardWriter — the per-card serial write queue. The load-bearing
 * invariant: CardKit only ever receives strictly-increasing sequence numbers in
 * arrival order, so no write is stale-rejected (the race that dropped panel
 * appends / status writes / stop buttons). Writes are serialized FIFO and a
 * failed write never wedges the chain.
 */

import { CardWriter } from "../src/card-writer";

const tick = (ms = 5) => new Promise((r) => setTimeout(r, ms));

describe("CardWriter", () => {
  it("assigns strictly-increasing sequences in FIFO order", async () => {
    const w = new CardWriter();
    const seqs: number[] = [];
    await Promise.all([
      w.write(async (s) => { seqs.push(s); }),
      w.write(async (s) => { seqs.push(s); }),
      w.write(async (s) => { seqs.push(s); }),
    ]);
    expect(seqs).toEqual([1, 2, 3]);
  });

  it("serializes writes — the next never starts before the previous settles", async () => {
    const w = new CardWriter();
    let active = 0;
    let maxActive = 0;
    const order: number[] = [];
    const mk = (n: number) => () => w.write(async (s) => {
      active++; maxActive = Math.max(maxActive, active);
      await tick();
      order.push(s); active--;
      expect(s).toBe(n);
    });
    await Promise.all([mk(1)(), mk(2)(), mk(3)(), mk(4)()]);
    expect(maxActive).toBe(1);        // never two card writes at once
    expect(order).toEqual([1, 2, 3, 4]); // monotonic seq, in order
  });

  it("honors startSeq (the queued-card header already used seq 1)", async () => {
    const w = new CardWriter(1);
    const seqs: number[] = [];
    await w.write(async (s) => { seqs.push(s); });
    await w.write(async (s) => { seqs.push(s); });
    expect(seqs).toEqual([2, 3]); // first write is startSeq+1
  });

  it("a failed write does NOT wedge the chain and does NOT skip the next seq", async () => {
    const w = new CardWriter();
    const seqs: number[] = [];
    await w.write(async (s) => { seqs.push(s); throw new Error("boom"); }); // resolves (swallowed)
    await w.write(async (s) => { seqs.push(s); });
    expect(seqs).toEqual([1, 2]); // chain kept moving; seqs stayed monotonic
  });

  it("write() resolves even when fn rejects (best-effort, never throws to caller)", async () => {
    const w = new CardWriter();
    await expect(w.write(async () => { throw new Error("x"); })).resolves.toBeUndefined();
  });

  it("currentSeq reflects the high-water mark", async () => {
    const w = new CardWriter(5);
    await w.write(async () => {});
    await w.write(async () => {});
    expect(w.currentSeq).toBe(7);
  });
});

describe("CardWriter.coalesce (latest-wins lane)", () => {
  it("drops stale frames: a burst of coalesce calls runs only the LATEST", async () => {
    const w = new CardWriter();
    const seen: string[] = [];
    // First write occupies the chain; the next 5 all queue onto the same lane.
    const first = w.write(async () => { await tick(20); seen.push("blocker"); });
    for (const v of ["a", "b", "c", "d", "e"]) {
      w.coalesce("status", async () => { seen.push(v); });
    }
    await first;
    await tick(30);
    // The blocker ran, then ONLY the latest queued status frame ("e") ran — the
    // intermediate stale frames (a..d) were dropped, not executed.
    expect(seen).toEqual(["blocker", "e"]);
  });

  it("keeps sequences monotonic across coalesced + one-shot writes", async () => {
    const w = new CardWriter();
    const seqs: number[] = [];
    const blocker = w.write(async (s) => { await tick(20); seqs.push(s); });
    w.coalesce("status", async (s) => { seqs.push(s); });
    w.coalesce("status", async (s) => { seqs.push(s); }); // replaces the above
    await w.write(async (s) => { seqs.push(s); });
    await blocker;
    await tick(40);
    // blocker=1, the single surviving status frame=2, the one-shot=3 — strictly
    // increasing, no gaps from the dropped frame consuming a sequence.
    expect(seqs).toEqual([1, 2, 3]);
  });

  it("separate lanes don't coalesce into each other", async () => {
    const w = new CardWriter();
    const seen: string[] = [];
    const blocker = w.write(async () => { await tick(20); });
    w.coalesce("status", async () => { seen.push("status"); });
    w.coalesce("content", async () => { seen.push("content"); });
    await blocker;
    await tick(30);
    expect(seen.sort()).toEqual(["content", "status"]); // both lanes ran
  });

  it("re-queues a lane after its slot drained (a later tick runs again)", async () => {
    const w = new CardWriter();
    const seen: number[] = [];
    w.coalesce("status", async (s) => { seen.push(s); });
    await tick(15);
    w.coalesce("status", async (s) => { seen.push(s); });
    await tick(15);
    expect(seen).toEqual([1, 2]); // ran once per drained slot
  });

  it("dropLanes drops a PENDING frame so it never repaints (e.g. post-finalize)", async () => {
    const w = new CardWriter();
    const seen: string[] = [];
    const blocker = w.write(async () => { await tick(20); }); // occupy the chain
    w.coalesce("status", async () => { seen.push("stale"); }); // queued behind blocker
    w.dropLanes("status");                                      // drop before it runs
    await blocker;
    await tick(30);
    expect(seen).toEqual([]); // the dropped frame never executed
  });

  it("after dropLanes, a NEW coalesce on the same lane still works (slot marker cleared)", async () => {
    const w = new CardWriter();
    const seen: string[] = [];
    const blocker = w.write(async () => { await tick(20); });
    w.coalesce("status", async () => { seen.push("stale"); });
    w.dropLanes("status");
    w.coalesce("status", async () => { seen.push("fresh"); }); // must schedule a fresh slot
    await blocker;
    await tick(30);
    expect(seen).toEqual(["fresh"]); // stale dropped, fresh ran (laneQueued was cleared)
  });
});
