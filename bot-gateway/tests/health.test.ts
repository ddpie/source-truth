import http from "node:http";
import { startHealthServer, markConnected, markEventReceived } from "../src/health";

/**
 * The health endpoint is an AID, never a serving dependency.
 *
 * The regression that matters here: one index host runs one bot-gateway PER PROJECT
 * (bot-gateway@<projectId>), so several gateways start on the same box. The first version of
 * health.ts called server.listen() with no 'error' listener, which turns EADDRINUSE into an
 * uncaught exception — every gateway after the first would die and then crash-loop under
 * systemd Restart=always. Binding must fail soft.
 */
describe("health server", () => {
  const servers: http.Server[] = [];

  afterEach(async () => {
    await Promise.all(
      servers.splice(0).map((s) => new Promise<void>((r) => s.close(() => r()))),
    );
  });

  function freePort(): Promise<number> {
    return new Promise((resolve) => {
      const probe = http.createServer();
      probe.listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as { port: number };
        probe.close(() => resolve(port));
      });
    });
  }

  it("serves status, ws state and memory as JSON", async () => {
    const port = await freePort();
    servers.push(startHealthServer(port));
    markConnected();
    markEventReceived();

    const body = await new Promise<string>((resolve, reject) => {
      const req = http.get({ host: "127.0.0.1", port, path: "/health" }, (res) => {
        let buf = "";
        res.on("data", (c) => (buf += c));
        res.on("end", () => resolve(buf));
      });
      req.on("error", reject);
    });

    const parsed = JSON.parse(body);
    expect(parsed.wsState).toBe("connected");
    expect(parsed.status).toBe("healthy");
    expect(typeof parsed.uptimeSeconds).toBe("number");
    expect(typeof parsed.memoryMB.rss).toBe("number");
  });

  it("does NOT crash the process when the port is already bound", async () => {
    const port = await freePort();

    // Occupy the port first, the way a sibling project's gateway would.
    const squatter = http.createServer();
    servers.push(squatter);
    await new Promise<void>((r) => squatter.listen(port, "127.0.0.1", () => r()));

    const uncaught = jest.fn();
    process.on("uncaughtException", uncaught);
    try {
      // Must return normally and must not throw asynchronously.
      const second = startHealthServer(port);
      servers.push(second);
      await new Promise((r) => setTimeout(r, 120));
      expect(uncaught).not.toHaveBeenCalled();
    } finally {
      process.off("uncaughtException", uncaught);
    }
  });
});
