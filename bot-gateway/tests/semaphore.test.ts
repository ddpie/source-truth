import { Semaphore } from "../src/semaphore";

describe("Semaphore", () => {
  it("allows up to `max` concurrent holders, queues the rest", async () => {
    const s = new Semaphore(2);
    await s.acquire();
    await s.acquire();
    expect(s.stats).toEqual({ available: 0, waiting: 0 });
    let third = false;
    const p = s.acquire().then(() => { third = true; });
    await Promise.resolve();
    expect(third).toBe(false);              // 3rd blocked
    expect(s.stats.waiting).toBe(1);
    s.release();                            // free one → hands to the waiter
    await p;
    expect(third).toBe(true);
  });

  it("run() releases on success AND on throw", async () => {
    const s = new Semaphore(1);
    await expect(s.run(async () => 42)).resolves.toBe(42);
    expect(s.stats.available).toBe(1);      // released after success
    await expect(s.run(async () => { throw new Error("boom"); })).rejects.toThrow("boom");
    expect(s.stats.available).toBe(1);      // released after throw (no leak)
  });

  it("bounds true concurrency under a burst (never exceeds max in flight)", async () => {
    const s = new Semaphore(3);
    let inFlight = 0, peak = 0;
    const task = () => s.run(async () => {
      inFlight++; peak = Math.max(peak, inFlight);
      await new Promise((r) => setTimeout(r, 5));
      inFlight--;
    });
    await Promise.all(Array.from({ length: 20 }, task));
    expect(peak).toBeLessThanOrEqual(3);    // never more than 3 concurrent
    expect(s.stats).toEqual({ available: 3, waiting: 0 }); // fully drained
  });

  it("is FIFO — waiters resolve in arrival order", async () => {
    const s = new Semaphore(1);
    await s.acquire();
    const order: number[] = [];
    const w1 = s.acquire().then(() => order.push(1));
    const w2 = s.acquire().then(() => order.push(2));
    s.release(); await w1;
    s.release(); await w2;
    expect(order).toEqual([1, 2]);
  });

  it("treats max<1 as 1 (never zero-permits deadlock)", async () => {
    const s = new Semaphore(0);
    await expect(s.run(async () => "ok")).resolves.toBe("ok");
  });
});
