/**
 * CardKit streaming rate-limiter (POC#3 constraint).
 *
 * Feishu card update limits: max 10 updates/sec, 10-minute streaming window.
 * This module throttles outbound card updates so the gateway never exceeds the
 * platform rate limit — intermediate chunks are merged (last-write-wins) and
 * flushed once per interval.
 *
 * The real Feishu API call (PATCH card) is injected via the `send` callback.
 * This module is purely a timing/state machine — no network.
 */

/** 10 updates/sec → minimum 100ms between sends. */
export const RATE_LIMIT_INTERVAL_MS = 100;
/** Feishu streaming window: 10 minutes. */
export const STREAM_WINDOW_MS = 10 * 60 * 1000;

export class CardStream {
  private _send: (content: string) => void;
  private _closed = false;
  private _pending: string | null = null;
  private _timer: NodeJS.Timeout | null = null;
  private _lastSendAt = 0;

  constructor(send: (content: string) => void) {
    this._send = send;
  }

  get isClosed(): boolean {
    return this._closed;
  }

  /**
   * Queue a card content update. If within the rate-limit window, buffer it
   * (last-write-wins merge). Otherwise send immediately.
   */
  push(content: string): void {
    if (this._closed) return;

    const now = Date.now();
    const elapsed = now - this._lastSendAt;

    if (elapsed >= RATE_LIMIT_INTERVAL_MS) {
      this._flush(content);
    } else {
      // Buffer — only keep latest (merge strategy: last wins).
      this._pending = content;
      if (!this._timer) {
        const delay = RATE_LIMIT_INTERVAL_MS - elapsed;
        this._timer = setTimeout(() => {
          this._timer = null;
          if (this._pending !== null && !this._closed) {
            this._flush(this._pending);
            this._pending = null;
          }
        }, delay);
        if (typeof this._timer.unref === "function") this._timer.unref();
      }
    }
  }

  /**
   * Close the stream: flush any buffered content, then reject further pushes.
   * Must be called before processing interaction callbacks (Feishu constraint).
   */
  close(): void {
    if (this._closed) return;
    this._closed = true;
    if (this._timer) {
      clearTimeout(this._timer);
      this._timer = null;
    }
    if (this._pending !== null) {
      this._send(this._pending);
      this._pending = null;
    }
  }

  private _flush(content: string): void {
    this._lastSendAt = Date.now();
    this._pending = null;
    this._send(content);
  }
}
