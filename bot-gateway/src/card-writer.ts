/**
 * Per-card serial write queue.
 *
 * CardKit applies updates in strictly-increasing `sequence` order and REJECTS
 * any update whose sequence is <= the last one it applied. The gateway used to
 * assign the sequence synchronously (correct order) but SEND writes fire-and-
 * forget with a shared mutable counter — so two concurrent writes (the 200ms
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
  // Coalescing lanes: a "lane" is a single card element whose updates are
  // latest-wins (the status timer, the conclusion typewriter). Each carries the
  // FULL current value, so intermediate frames are stale and droppable. We keep
  // only the latest pending fn per lane + whether that lane already has a slot in
  // the FIFO chain. This bounds the queue to ~1 write per lane regardless of how
  // fast the heartbeat/typewriter ticks — so a slow lark-cli spawn can't let a
  // backlog of stale status frames pile up and make the timer crawl seconds
  // behind real time (the "卡在 11s" complaint). One-shot writes (append, stop
  // button, finalize) bypass coalescing via write().
  private latestByLane = new Map<string, (seq: number) => Promise<void>>();
  private laneQueued = new Set<string>();

  /** startSeq is the last sequence already consumed before this writer takes
   *  over (e.g. the queued-card "排队中" header used seq 1); the first write gets
   *  startSeq + 1. onError (optional) is invoked with any swallowed write/coalesce
   *  error so a dropped card op (esp. a failed FINALIZE after retries) is
   *  diagnosable — the chain still stays alive (best-effort), this only observes. */
  constructor(startSeq = 0, private readonly onError?: (label: string, err: unknown) => void) {
    this.seq = startSeq;
  }

  /**
   * Enqueue a one-shot card write (never coalesced/dropped — use for appends,
   * the stop button, and the finalize sequence). `fn` receives the sequence to
   * use and must perform exactly one CardKit call. Resolves when THIS write
   * completes (resolves even on failure — swallowed so one bad write can't stall
   * the chain).
   */
  write(fn: (seq: number) => Promise<void>): Promise<void> {
    const run = this.chain.then(async () => {
      const seq = ++this.seq;
      try {
        await fn(seq);
      } catch (e) {
        /* best-effort: a dropped card update must never wedge the queue */
        this.onError?.("write", e);
      }
    });
    this.chain = run.catch(() => undefined);
    return run;
  }

  /**
   * Enqueue a LATEST-WINS write for `lane`. If a write for this lane is already
   * pending (queued but not yet run), its fn is replaced by this one — the stale
   * frame is dropped — instead of appending another slot. The sequence is still
   * assigned at run time (monotonic, in FIFO order across all lanes), so CardKit
   * never sees an out-of-order sequence. Use for the status timer and conclusion
   * typewriter, where only the newest value matters.
   */
  coalesce(lane: string, fn: (seq: number) => Promise<void>): void {
    this.latestByLane.set(lane, fn); // latest wins
    if (this.laneQueued.has(lane)) return; // a slot is already scheduled for this lane
    this.laneQueued.add(lane);
    const run = this.chain.then(async () => {
      this.laneQueued.delete(lane);
      const latest = this.latestByLane.get(lane);
      this.latestByLane.delete(lane);
      if (!latest) return;
      const seq = ++this.seq;
      try {
        await latest(seq);
      } catch (e) {
        /* best-effort */
        this.onError?.(`coalesce:${lane}`, e);
      }
    });
    this.chain = run.catch(() => undefined);
  }

  /** Drop any pending (not-yet-run) coalesced frame for these lanes. Called
   *  before finalize so a queued status/content frame can't repaint stale "正在
   *  分析" text or the live timer ONTO the finalized card after it's done. A lane
   *  whose slot is mid-execution still completes (harmless — finalize's full PUT
   *  runs after it on the FIFO chain and overwrites). */
  dropLanes(...lanes: string[]): void {
    // Clear BOTH the pending frame AND the queued-slot marker. Dropping only
    // latestByLane (the old behavior) was safe ONLY because the sole caller clears
    // the heartbeat first, so no coalesce() could follow. But that left the
    // invariant dependent on caller timing: if a coalesce() ever lands after
    // dropLanes while laneQueued still held the lane, its slot would early-return
    // on the next enqueue... actually re-use the stale slot and repaint a finalized
    // card. Deleting laneQueued too makes "this lane is dropped" a LOCAL guarantee:
    // a later coalesce() schedules a fresh slot (harmless) rather than reviving a
    // stale one. A slot already mid-execution is unaffected (its latestByLane.get
    // already returned, and on a dropped lane returns undefined → no-op).
    for (const lane of lanes) {
      this.latestByLane.delete(lane);
      this.laneQueued.delete(lane);
    }
  }

  /** Current high-water sequence (for tests / diagnostics). */
  get currentSeq(): number {
    return this.seq;
  }
}
