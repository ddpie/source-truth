/**
 * health.ts — lightweight HTTP health server for bot-gateway.
 *
 * Binds a SEPARATE loopback port so probes and monitors can poll without touching the Feishu
 * long-connection path. Two routes, deliberately split:
 *
 *   GET /health  LIVENESS  — 200 for as long as the process is answering, whatever the WS is
 *                            doing. A liveness probe wired to a restart action must NOT fire
 *                            during a normal 2-second SDK reconnect: that would abort every
 *                            in-flight card and turn self-healing into a restart loop. The
 *                            WS state is still reported in the body for humans and dashboards.
 *   GET /ready   READINESS — 200 only when the WS is connected and the process is not draining.
 *                            This is the one to gate traffic/rollout on. It is 503 during
 *                            startup (before onReady) and during shutdown.
 *
 * BIND ADDRESS IS DELIBERATELY FIXED to 127.0.0.1 and must stay that way: the body carries
 * activity metadata, and the port number itself encodes the bridge port (see deriveHealthPort),
 * which is a topology hint. Do NOT make the bind address configurable.
 *
 * DO NOT ADD projectId, repos, endpoint, chat/user ids or tokens to the response body. The
 * obvious next request is "which project is this?" — that answer belongs in logs, not on an
 * unauthenticated port.
 *
 * KNOWN LIMIT (deliberate): `lastEventTs` tracks BUSINESS traffic only (IM + card actions). An
 * idle night is indistinguishable from a wedged half-open socket on that field alone, so the
 * verdict does NOT flip on business-traffic silence — doing so would restart a perfectly healthy
 * gateway every quiet night. Detecting a wedge needs a signal the SDK emits unconditionally;
 * until one is wired up, `lastEventAgoSeconds` is exposed for humans but is not a verdict input.
 */

import * as http from "node:http";

export type WsState = "disconnected" | "connecting" | "connected" | "reconnecting";

/** Single declaration site for the fallback port (see deriveHealthPort). */
export const DEFAULT_HEALTH_PORT = 18080;

/** Lowest port we will bind. Below 1024 needs privileges this process must not have. */
const MIN_PORT = 1024;
const MAX_PORT = 65535;

interface HealthState {
  wsState: WsState;
  lastEventTs: number; // epoch ms, 0 = no event yet
  draining: boolean;
}

const state: HealthState = {
  wsState: "disconnected",
  lastEventTs: 0,
  draining: false,
};

/** Call from the SDK's onReady callback. */
export function markConnected(): void { state.wsState = "connected"; }

/** Call from the SDK's onReconnecting callback. */
export function markReconnecting(): void { state.wsState = "reconnecting"; }

/** Call from the SDK's onReconnected callback. */
export function markReconnected(): void { state.wsState = "connected"; }

/** Call before WSClient.start() (initial connect AND every retry). */
export function markConnecting(): void { state.wsState = "connecting"; }

/**
 * Call when the socket is known to be down and no reconnect is in flight — the SDK's own
 * retry-exhausted / retry-failed paths. Without this the union member "disconnected" is
 * unreachable after startup and /ready keeps reporting a dead gateway as connected.
 */
export function markDisconnected(): void { state.wsState = "disconnected"; }

/** Call whenever an event (IM or card action) is received. */
export function markEventReceived(): void { state.lastEventTs = Date.now(); }

/** Call from graceful shutdown: /ready goes 503 while in-flight work drains. */
export function markDraining(): void { state.draining = true; }

/** Test seam: reset module state so cases are not order-coupled. */
export function __resetHealthState(): void {
  state.wsState = "disconnected";
  state.lastEventTs = 0;
  state.draining = false;
}

/** Current state, for assertions and for callers that want the verdict without an HTTP hop. */
export function getHealthState(): Readonly<HealthState> {
  return { ...state };
}

/**
 * Resolve the health port.
 *
 * Default is derived from this project's bridge port (8080 → 18080) because one index host runs
 * one bot-gateway PER PROJECT: a single hard-coded port would leave every gateway but the first
 * without a health endpoint. `envPort` (HEALTH_PORT) overrides.
 *
 * Pure and exported so the derivation is testable — it previously lived in an inline IIFE inside
 * main(), which is why a regex that mis-parses IPv6 authorities shipped unnoticed.
 *
 * Parsing is STRUCTURAL (URL), not regex: `/:(\d+)\b/` matched the wrong number on shapes the
 * route validator permits — `http://[::1]:8080/mcp` yielded 1, `http://u:1234@h/mcp` yielded
 * 1234, `http://h/mcp:9` yielded 9.
 */
export function deriveHealthPort(
  endpoint: string | null | undefined,
  envPort?: string | null,
): { port: number; source: "env" | "derived" | "default"; invalidEnv?: string } {
  const raw = envPort?.trim();
  if (raw) {
    // Explicit request wins — including "0", which legitimately means "any free port".
    const n = Number(raw);
    if (Number.isInteger(n) && (n === 0 || (n >= MIN_PORT && n <= MAX_PORT))) {
      return { port: n, source: "env" };
    }
    // Fall through to the derived port rather than crashing on a typo'd env var.
    return { ...deriveFromEndpoint(endpoint), invalidEnv: raw };
  }
  return deriveFromEndpoint(endpoint);
}

function deriveFromEndpoint(
  endpoint: string | null | undefined,
): { port: number; source: "derived" | "default" } {
  if (endpoint) {
    try {
      const parsed = new URL(endpoint);
      const bridgePort = Number(parsed.port);
      const derived = 10000 + bridgePort;
      if (Number.isInteger(bridgePort) && bridgePort > 0 && derived <= MAX_PORT) {
        return { port: derived, source: "derived" };
      }
    } catch {
      // not a parseable URL — fall back
    }
  }
  return { port: DEFAULT_HEALTH_PORT, source: "default" };
}

export interface HealthServerOptions {
  /** Injected so health.ts stays dependency-free and the log shape matches the gateway's. */
  logger?: (entry: Record<string, unknown>) => void;
}

function defaultLogger(entry: Record<string, unknown>): void {
  // Same shape as src/log.ts (ts first) so CloudWatch metric filters keyed on it also match here.
  console.log(JSON.stringify({ ts: new Date().toISOString(), ...entry }));
}

function buildBody(): string {
  const mem = process.memoryUsage();
  return JSON.stringify({
    status: state.draining
      ? "draining"
      : state.wsState === "connected"
        ? "healthy"
        : "degraded",
    // process.uptime() is real process uptime; a module-load timestamp drifts by however long
    // the import graph (30+ modules plus the Lark SDK) took to evaluate.
    uptimeSeconds: Math.floor(process.uptime()),
    wsState: state.wsState,
    draining: state.draining,
    lastEventTs: state.lastEventTs || null,
    lastEventAgoSeconds: state.lastEventTs
      ? Math.floor((Date.now() - state.lastEventTs) / 1000)
      : null,
    memoryMB: {
      rss: Math.round(mem.rss / 1048576),
      heapUsed: Math.round(mem.heapUsed / 1048576),
      heapTotal: Math.round(mem.heapTotal / 1048576),
    },
  });
}

/**
 * Start the health server. NEVER throws and never takes the gateway down: a bad port or an
 * already-bound port degrades to "no health endpoint" plus a log line.
 *
 * Returns the server. `server.listening` tells the caller whether the bind actually succeeded —
 * do not log success without checking it.
 */
export function startHealthServer(
  port: number = DEFAULT_HEALTH_PORT,
  opts: HealthServerOptions = {},
): http.Server {
  const log = opts.logger ?? defaultLogger;

  const server = http.createServer((req, res) => {
    const headers = {
      "Content-Type": "application/json",
      // A cached health verdict is worse than no verdict.
      "Cache-Control": "no-store",
      Connection: "close",
    };

    if (req.method !== "GET") {
      res.writeHead(405, headers);
      res.end(JSON.stringify({ error: "method_not_allowed" }));
      return;
    }

    const path = (req.url ?? "/").split("?")[0];

    if (path === "/health" || path === "/healthz") {
      // LIVENESS: alive is alive. Never 503 here — see the header comment.
      res.writeHead(200, headers);
      res.end(buildBody());
      return;
    }

    if (path === "/ready") {
      const ready = state.wsState === "connected" && !state.draining;
      res.writeHead(ready ? 200 : 503, headers);
      res.end(buildBody());
      return;
    }

    // Explicit 404 so a probe misconfigured at /healthcheck fails loudly instead of
    // passing forever against a catch-all.
    res.writeHead(404, headers);
    res.end(JSON.stringify({ error: "not_found", routes: ["/health", "/ready"] }));
  });

  // Without an 'error' listener EADDRINUSE becomes an uncaught exception that KILLS the gateway.
  // One index host runs one bot-gateway per project, so several gateways start on the same box;
  // a shared port would take down every process after the first, then crash-loop it under
  // Restart=always.
  server.on("error", (err: NodeJS.ErrnoException) => {
    log({
      event: "health_server_unavailable",
      port,
      code: err.code ?? "unknown",
      detail:
        err.code === "EADDRINUSE"
          ? "port already bound (another gateway on this host?)"
          : String(err.message ?? err).slice(0, 300),
    });
  });

  // listen() validates the port SYNCHRONOUSLY: an out-of-range or non-integer value throws
  // ERR_SOCKET_BAD_PORT instead of emitting 'error', so the listener above does not see it and
  // the throw escapes main() into process.exit(1) — a crash-loop through the very path the
  // 'error' handler exists to prevent. Guard the call itself.
  try {
    server.listen(port, "127.0.0.1", () => {
      const addr = server.address();
      const bound = addr && typeof addr === "object" ? addr.port : port;
      log({ event: "health_server_started", port: bound });
    });
  } catch (err) {
    const e = err as NodeJS.ErrnoException;
    log({
      event: "health_server_unavailable",
      port,
      code: e.code ?? "invalid_port",
      detail: String(e.message ?? e).slice(0, 300),
    });
  }

  server.unref(); // never keep the process alive for the health server alone

  return server;
}
