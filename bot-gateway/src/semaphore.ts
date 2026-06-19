/**
 * A minimal async counting semaphore — a GLOBAL concurrency gate for agent invokes.
 *
 * Per-session serialization (serialize-session.ts) serializes turns on the SAME
 * runtimeSessionId, but it does NOT bound DISTINCT sessions: a burst of N different
 * users @-mentioning the bot in a busy group would otherwise fire N concurrent
 * AgentCore invokes at once (cost spike, AgentCore throttling, N live heartbeat
 * timers / writers). This caps the number of invokes running CONCURRENTLY across
 * all sessions; excess callers await a slot. The card is still sent eagerly BEFORE
 * acquiring (so a waiting user sees "排队中"/思考 feedback, not silence).
 *
 * Pure + tiny (no dependency). FIFO fairness: waiters resolve in arrival order.
 */
export class Semaphore {
  private available: number;
  private readonly waiters: Array<() => void> = [];

  constructor(max: number) {
    this.available = Math.max(1, Math.floor(max));
  }

  /** Acquire a slot, awaiting one if none are free. */
  async acquire(): Promise<void> {
    if (this.available > 0) {
      this.available -= 1;
      return;
    }
    await new Promise<void>((resolve) => this.waiters.push(resolve));
  }

  /** Release a slot, handing it directly to the next FIFO waiter if any. */
  release(): void {
    const next = this.waiters.shift();
    if (next) {
      next(); // hand the slot straight to the waiter (count stays "spent")
    } else {
      this.available += 1;
    }
  }

  /** Run `fn` while holding a slot; always releases, even on throw. */
  async run<T>(fn: () => Promise<T>): Promise<T> {
    await this.acquire();
    try {
      return await fn();
    } finally {
      this.release();
    }
  }

  /** For diagnostics/tests: free slots and queued waiter count. */
  get stats(): { available: number; waiting: number } {
    return { available: this.available, waiting: this.waiters.length };
  }
}
