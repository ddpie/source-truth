/**
 * Per-key task serializer.
 *
 * One warm AgentCore microVM == one persistent Claude Agent SDK conversation,
 * pinned by its runtimeSessionId. Two invokes carrying the SAME runtimeSessionId
 * must NOT run concurrently — they'd append to one conversation's message/tool
 * history simultaneously and corrupt it (and bleed the two streamed answers
 * together). This happens for real: a follow-up button click, or a second
 * question in the same p2p chat, fires while the first answer is still streaming
 * for minutes.
 *
 * `serialize(key, task)` runs `task` immediately if the key is idle, otherwise
 * CHAINS it after the in-flight task for that key settles — so same-key work
 * runs strictly sequentially (which also matches intent: a follow-up is meant to
 * build on the prior turn). The internal map entry is cleared only when the LAST
 * chained task for a key settles, so it never leaks in the always-on process.
 */

export class SessionSerializer {
  private readonly inFlight = new Map<string, Promise<unknown>>();

  /** True if a task is currently queued/running for this key. */
  isBusy(key: string): boolean {
    return this.inFlight.has(key);
  }

  /**
   * Run `task` serialized on `key`. Returns a promise for THIS task's result.
   * A prior task's rejection never blocks the queued one (we chain off a
   * swallowed copy), but each returned promise still reflects its own outcome.
   */
  serialize<T>(key: string, task: () => Promise<T>): Promise<T> {
    const prior = this.inFlight.get(key);
    const run = (prior ? prior.catch(() => undefined) : Promise.resolve()).then(task);
    this.inFlight.set(key, run);
    // Clear the slot when THIS run settles, but only if it's still the tail of
    // the chain (a later queued task may have replaced it).
    void run
      .catch(() => undefined)
      .finally(() => {
        if (this.inFlight.get(key) === run) this.inFlight.delete(key);
      });
    return run;
  }
}
