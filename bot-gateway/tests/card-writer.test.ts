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
