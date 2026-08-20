/**
 * health.ts — lightweight HTTP health-check server for bot-gateway.
 *
 * Binds to a SEPARATE port (default 18080) so liveness probes, systemd
 * WatchdogSec ExecStartPost, and external monitors can poll without touching
 * the Feishu long-connection path. Reports process uptime, WebSocket state,
 * last-event timestamp, and memory usage.
 */

import * as http from "node:http";

export type WsState = "disconnected" | "connecting" | "connected" | "reconnecting";

interface HealthState {
  wsState: WsState;
  lastEventTs: number; // epoch ms, 0 = no event yet
}

const state: HealthState = {
  wsState: "disconnected",
  lastEventTs: 0,
};

const startedAt = Date.now();

/** Call from the SDK's onReady callback. */
export function markConnected(): void { state.wsState = "connected"; }

/** Call from the SDK's onReconnecting callback. */
export function markReconnecting(): void { state.wsState = "reconnecting"; }

/** Call from the SDK's onReconnected callback. */
export function markReconnected(): void { state.wsState = "connected"; }

/** Call when the WSClient.start() is invoked (before connection established). */
export function markConnecting(): void { state.wsState = "connecting"; }

/** Call whenever an event (IM or card action) is received. */
export function markEventReceived(): void { state.lastEventTs = Date.now(); }

/** Start the health HTTP server. Returns the server instance. */
export function startHealthServer(port = 18080): http.Server {
  const server = http.createServer((_req, res) => {
    const mem = process.memoryUsage();
    const body = JSON.stringify({
      status: state.wsState === "connected" ? "healthy" : "degraded",
      uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
      wsState: state.wsState,
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
    const statusCode = state.wsState === "connected" ? 200 : 503;
    res.writeHead(statusCode, { "Content-Type": "application/json" });
    res.end(body);
  });

  // An http.Server with NO 'error' listener turns EADDRINUSE into an uncaught exception that
  // KILLS the gateway. That is a real topology, not a hypothetical: one index host runs one
  // bot-gateway per project (bot-gateway@<projectId>), so several gateways start on the same
  // box and a fixed shared port means every process after the first would die and then
  // crash-loop under Restart=always. Health reporting is an aid, never a serving dependency:
  // log and carry on without it.
  server.on("error", (err: NodeJS.ErrnoException) => {
    console.log(
      JSON.stringify({
        event: "health_server_unavailable",
        port,
        code: err.code ?? "unknown",
        detail: err.code === "EADDRINUSE" ? "port already bound (another gateway on this host?)" : String(err.message ?? err),
      }),
    );
  });

  server.listen(port, "127.0.0.1", () => {
    // intentionally no log here — caller logs if desired
  });
  server.unref(); // never keep the process alive for the health server alone

  return server;
}
