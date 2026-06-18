/**
 * Per-card serial write queue.
 *
 * CardKit applies updates in strictly-increasing `sequence` order and REJECTS
 * any update whose sequence is <= the last one it applied. The gateway used to
 * assign the sequence synchronously (correct order) but SEND writes fire-and-
 * forget with a shared mutable counter — so two concurrent writes (the 400ms
 * status heartbeat vs an onChunk panel/content update) could arrive at CardKit
 * out of order: the higher-seq one lands first, and the lower-seq one is then
 * stale-rejected and silently dropped. That single race caused a recurring class
 * of bugs — the status line wiping the stop button, a duplicated stop button, and
 * (most recently, caught in live self-test) the 分析过程 panel never appearing
 * because its append lost the seq race to the status churn.
 *
 * CardWriter fixes the whole class at the root: every card write goes through one
 * FIFO chain that assigns the sequence at SEND time and awaits each write before
 * starting the next. CardKit therefore always receives monotonically increasing
 * sequences in arrival order → no stale rejection is ever possible. Writes stay
 * best-effort (a failed write is swallowed so it can't wedge the chain), and the
 * caller can still await its own write to know when it landed.
 */

export class CardWriter {
  private chain: Promise<void> = Promise.resolve();
  private seq: number;

  /** startSeq is the last sequence already consumed before this writer takes
   *  over (e.g. the queued-card "排队中" header used seq 1); the first write gets
   *  startSeq + 1. */
  constructor(startSeq = 0) {
    this.seq = startSeq;
  }

  /**
   * Enqueue a card write. `fn` receives the sequence number to use and must
   * perform exactly one CardKit call with it. Returns a promise that settles when
   * THIS write completes (resolves even if the write failed — failures are
   * swallowed so one bad write can't stall every later write).
   */
  write(fn: (seq: number) => Promise<void>): Promise<void> {
    const run = this.chain.then(async () => {
      const seq = ++this.seq;
      try {
        await fn(seq);
      } catch {
        /* best-effort: a dropped card update must never wedge the queue */
      }
    });
    // Keep the chain alive regardless of this write's outcome.
    this.chain = run.catch(() => undefined);
    return run;
  }

  /** Current high-water sequence (for tests / diagnostics). */
  get currentSeq(): number {
    return this.seq;
  }
}
