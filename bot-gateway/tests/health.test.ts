import http from "node:http";
import {
  startHealthServer,
  deriveHealthPort,
  DEFAULT_HEALTH_PORT,
  markConnected,
  markConnecting,
  markReconnecting,
  markReconnected,
  markDisconnected,
  markDraining,
  markEventReceived,
  getHealthState,
  __resetHealthState,
} from "../src/health";

/**
 * The health endpoint is an AID, never a serving dependency. Two regressions these tests exist
 * to hold down, both of which shipped once:
 *   1. listen() with no 'error' listener → EADDRINUSE becomes an uncaught exception. One index
 *      host runs one gateway per project, so every gateway after the first died and crash-looped.
 *   2. An out-of-range/non-integer port makes listen() throw SYNCHRONOUSLY (ERR_SOCKET_BAD_PORT),
 *      bypassing the 'error' listener entirely — the same crash through an unguarded path.
 */
describe("health server", () => {
  const servers: http.Server[] = [];
  const logs: Record<string, unknown>[] = [];
  const logger = (e: Record<string, unknown>) => { logs.push(e); };

  beforeEach(() => {
    __resetHealthState();
    logs.length = 0;
  });

  afterEach(async () => {
    await Promise.all(
      servers.splice(0).map(
        (s) => new Promise<void>((r) => (s.listening ? s.close(() => r()) : r())),
      ),
    );
  });

  /** Start on an ephemeral port and return the real bound port — no TOCTOU bind/close/rebind. */
  async function startOnEphemeral(): Promise<{ server: http.Server; port: number }> {
    const server = startHealthServer(0, { logger });
    servers.push(server);
    await new Promise<void>((resolve, reject) => {
      server.once("listening", () => resolve());
      server.once("error", reject);
    });
    const addr = server.address();
    if (!addr || typeof addr !== "object") throw new Error("no bound address");
    return { server, port: addr.port };
  }

  function req(port: number, path: string, method = "GET"): Promise<{ status: number; body: string }> {
    return new Promise((resolve, reject) => {
      // agent: false — do not let the global agent pool keep a socket alive past the assertion,
      // which shows up later as a jest "did not exit" warning in unrelated suites.
      const r = http.request({ host: "127.0.0.1", port, path, method, agent: false }, (res) => {
        let buf = "";
        res.on("data", (c) => (buf += c));
        res.on("end", () => resolve({ status: res.statusCode ?? 0, body: buf }));
      });
      r.on("error", reject);
      r.end();
    });
  }

  // ---- port derivation (pure) ------------------------------------------------------------
  describe("deriveHealthPort", () => {
    it("derives bridge port + 10000", () => {
      expect(deriveHealthPort("http://127.0.0.1:8080/mcp")).toEqual({ port: 18080, source: "derived" });
      expect(deriveHealthPort("http://idx.internal:8099/mcp")).toEqual({ port: 18099, source: "derived" });
    });

    it("parses IPv6 and userinfo authorities structurally, not by regex", () => {
      // The old /:(\d+)\b/ regex yielded 1 here (matching inside "[::1]") and 1234 for userinfo.
      expect(deriveHealthPort("http://[::1]:8080/mcp").port).toBe(18080);
      expect(deriveHealthPort("http://user:1234@idx.internal:8080/mcp").port).toBe(18080);
    });

    it("falls back to the default when there is no port, no endpoint, or an unparseable one", () => {
      expect(deriveHealthPort("https://idx.internal/mcp")).toEqual({ port: DEFAULT_HEALTH_PORT, source: "default" });
      expect(deriveHealthPort(null)).toEqual({ port: DEFAULT_HEALTH_PORT, source: "default" });
      expect(deriveHealthPort(undefined)).toEqual({ port: DEFAULT_HEALTH_PORT, source: "default" });
      expect(deriveHealthPort("not a url")).toEqual({ port: DEFAULT_HEALTH_PORT, source: "default" });
    });

    it("never derives a port above 65535", () => {
      // A bridge port this high is rejected by validateProjectsConfig, but the derivation must
      // not produce an out-of-range value even if one reaches it — that throw is synchronous.
      const { port } = deriveHealthPort("http://h:60000/mcp");
      expect(port).toBe(DEFAULT_HEALTH_PORT);
      expect(port).toBeLessThanOrEqual(65535);
    });

    it("lets HEALTH_PORT override, including 0 for an ephemeral port", () => {
      expect(deriveHealthPort("http://h:8080/mcp", "19999")).toEqual({ port: 19999, source: "env" });
      expect(deriveHealthPort("http://h:8080/mcp", "0")).toEqual({ port: 0, source: "env" });
    });

    it("reports an invalid HEALTH_PORT and falls back instead of crashing", () => {
      for (const bad of ["8080x", "99999", "-1", "1.5", "80"]) {
        const r = deriveHealthPort("http://h:8080/mcp", bad);
        expect(r.invalidEnv).toBe(bad);
        expect(r.port).toBe(18080); // derived fallback, not the bad value
      }
    });

    it("treats blank/whitespace HEALTH_PORT as unset", () => {
      expect(deriveHealthPort("http://h:8080/mcp", "").source).toBe("derived");
      expect(deriveHealthPort("http://h:8080/mcp", "   ").source).toBe("derived");
    });
  });

  // ---- routes and verdicts --------------------------------------------------------------
  it("/health is 200 and reports state; liveness never flips on WS state", async () => {
    const { port } = await startOnEphemeral();
    markConnected();
    markEventReceived();

    const ok = await req(port, "/health");
    expect(ok.status).toBe(200);
    const parsed = JSON.parse(ok.body);
    expect(parsed.status).toBe("healthy");
    expect(parsed.wsState).toBe("connected");
    expect(typeof parsed.uptimeSeconds).toBe("number");
    expect(typeof parsed.memoryMB.rss).toBe("number");
    expect(typeof parsed.lastEventAgoSeconds).toBe("number");

    // A reconnect blip must NOT make liveness fail — that would restart a self-healing gateway.
    markReconnecting();
    const during = await req(port, "/health");
    expect(during.status).toBe(200);
    expect(JSON.parse(during.body).status).toBe("degraded");
  });

  it("/ready is 503 until connected and 503 again while draining", async () => {
    const { port } = await startOnEphemeral();

    // startup: not connected yet
    expect((await req(port, "/ready")).status).toBe(503);

    markConnected();
    expect((await req(port, "/ready")).status).toBe(200);

    markDraining();
    const draining = await req(port, "/ready");
    expect(draining.status).toBe(503);
    expect(JSON.parse(draining.body).status).toBe("draining");
  });

  it("tracks every WS transition, including disconnected", () => {
    markConnecting();
    expect(getHealthState().wsState).toBe("connecting");
    markConnected();
    expect(getHealthState().wsState).toBe("connected");
    markReconnecting();
    expect(getHealthState().wsState).toBe("reconnecting");
    markReconnected();
    expect(getHealthState().wsState).toBe("connected");
    // Reachable only because markDisconnected exists — without it /ready reports a dark
    // gateway as connected for as long as the process lives.
    markDisconnected();
    expect(getHealthState().wsState).toBe("disconnected");
  });

  it("reports lastEventTs as null before any event", async () => {
    const { port } = await startOnEphemeral();
    const parsed = JSON.parse((await req(port, "/health")).body);
    expect(parsed.lastEventTs).toBeNull();
    expect(parsed.lastEventAgoSeconds).toBeNull();
  });

  it("404s unknown paths and 405s non-GET so a misconfigured probe fails loudly", async () => {
    const { port } = await startOnEphemeral();
    expect((await req(port, "/healthcheck")).status).toBe(404);
    expect((await req(port, "/")).status).toBe(404);
    expect((await req(port, "/health", "POST")).status).toBe(405);
    expect((await req(port, "/health", "DELETE")).status).toBe(405);
  });

  it("ignores a query string on /health", async () => {
    const { port } = await startOnEphemeral();
    expect((await req(port, "/health?probe=1")).status).toBe(200);
  });

  it("sets no-store so a probe cannot serve a stale verdict", async () => {
    const { port } = await startOnEphemeral();
    const headers = await new Promise<http.IncomingHttpHeaders>((resolve, reject) => {
      const r = http.get({ host: "127.0.0.1", port, path: "/health" }, (res) => {
        res.resume();
        resolve(res.headers);
      });
      r.on("error", reject);
    });
    expect(headers["cache-control"]).toBe("no-store");
  });

  it("never exposes project identity or topology in the body", async () => {
    const { port } = await startOnEphemeral();
    const parsed = JSON.parse((await req(port, "/health")).body);
    for (const forbidden of ["projectId", "repos", "endpoint", "runtimeArn", "appId", "token"]) {
      expect(parsed[forbidden]).toBeUndefined();
    }
  });

  // ---- failure modes -------------------------------------------------------------------
  it("does NOT crash the process when the port is already bound, and REPORTS it", async () => {
    const squatter = http.createServer();
    servers.push(squatter);
    await new Promise<void>((r) => squatter.listen(0, "127.0.0.1", () => r()));
    const addr = squatter.address();
    if (!addr || typeof addr !== "object") throw new Error("no squatter address");

    const uncaught = jest.fn();
    process.on("uncaughtException", uncaught);
    try {
      const second = startHealthServer(addr.port, { logger });
      servers.push(second);
      // Await the deterministic signal rather than sleeping a fixed interval.
      await new Promise<void>((resolve) => {
        const done = () => resolve();
        second.once("error", done);
        setTimeout(done, 2000); // failure guard only
      });
      expect(uncaught).not.toHaveBeenCalled();
      expect(second.listening).toBe(false);
      // Fail-soft AND silent would leave operators blind — assert the report exists.
      const reported = logs.find((l) => l.event === "health_server_unavailable");
      expect(reported).toBeDefined();
      expect(reported?.code).toBe("EADDRINUSE");
      expect(reported?.port).toBe(addr.port);
    } finally {
      process.off("uncaughtException", uncaught);
    }
  });

  it("does NOT crash on an out-of-range or non-integer port (listen throws synchronously)", () => {
    // ERR_SOCKET_BAD_PORT is thrown, not emitted, so the 'error' listener never sees it.
    for (const bad of [70000, -1, NaN, 1.5]) {
      logs.length = 0;
      expect(() => {
        const s = startHealthServer(bad, { logger });
        servers.push(s);
      }).not.toThrow();
      const reported = logs.find((l) => l.event === "health_server_unavailable");
      expect(reported).toBeDefined();
    }
  });

  it("logs health_server_started with the REAL bound port, not the requested one", async () => {
    const { port } = await startOnEphemeral();
    const started = logs.find((l) => l.event === "health_server_started");
    expect(started).toBeDefined();
    expect(started?.port).toBe(port); // requested 0, bound something real
    expect(started?.port).not.toBe(0);
  });
});
