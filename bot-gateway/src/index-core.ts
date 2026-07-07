/**
 * Connection-error policy for the long-connection subscriber (src/index.ts).
 */

/** What the WSClient onError handler should do with a connection error. PURE +
 *  unit-tested so the transient/terminal/shutdown decision (which governs whether a
 *  long-running gateway survives a blip, restarts on bad creds, or cleanly stands
 *  down on redeploy) isn't untested inline logic in the entry shell. */
export type WsErrorAction = "ignore" | "retry" | "exit";

/** Classify a WSClient error into an action.
 *  - shuttingDown  → "ignore": we closed the socket on purpose (SIGTERM); the drain
 *    owns the exit, so connection-teardown noise must NOT race exit(1) ahead of it.
 *  - exceed_conn_limit (1000040350) → "retry": a stale peer still holds the slot;
 *    exiting would race a supervised restart into the SAME limit (crash-loop). Back
 *    off + re-start in-process instead.
 *  - everything else → "exit": treat as terminal (bad/revoked creds etc.) and let the
 *    supervisor restart with fresh state rather than run dark. */
export function classifyWsError(err: unknown, shuttingDown: boolean): WsErrorAction {
  if (shuttingDown) return "ignore";
  const msg = String(err);
  if (msg.includes("1000040350") || msg.includes("exceed_conn_limit")) return "retry";
  return "exit";
}
