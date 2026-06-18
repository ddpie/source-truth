/**
 * Tests for the in-process Feishu OpenAPI client (replaces spawn lark-cli on the
 * CardKit hot path). Covers: token caching (one fetch shared across calls),
 * non-zero Feishu code → throw, non-2xx → throw, and a 401 → token-refresh retry.
 * `fetch` is stubbed so no network is hit.
 */

// feishu-http reads APP_ID/SECRET at module load; set dummies BEFORE import so the
// credential guard passes (fetch is stubbed, so the values are never sent anywhere).
process.env.FEISHU_APP_ID = process.env.FEISHU_APP_ID || "cli_test";
process.env.FEISHU_APP_SECRET = process.env.FEISHU_APP_SECRET || "secret_test";

import { getTenantToken, invalidateToken, feishuApi } from "../src/feishu-http";

type FetchArgs = [input: string, init?: { method?: string; headers?: Record<string, string>; body?: string }];

const realFetch = global.fetch;
let calls: FetchArgs[] = [];

function stubFetch(handler: (url: string, init: FetchArgs[1]) => { status?: number; json: unknown }) {
  calls = [];
  global.fetch = (async (url: string, init?: FetchArgs[1]) => {
    calls.push([url, init]);
    const { status = 200, json } = handler(url, init);
    return { status, json: async () => json } as unknown as Response;
  }) as unknown as typeof fetch;
}

afterEach(() => {
  global.fetch = realFetch;
  invalidateToken();
});

const tokenResponse = (token = "t-abc", expire = 7200) => ({ code: 0, tenant_access_token: token, expire });

describe("getTenantToken", () => {
  it("fetches once and caches (second call hits no network)", async () => {
    stubFetch(() => ({ json: tokenResponse("t-1") }));
    expect(await getTenantToken()).toBe("t-1");
    expect(await getTenantToken()).toBe("t-1");
    const tokenCalls = calls.filter(([u]) => u.includes("tenant_access_token"));
    expect(tokenCalls.length).toBe(1); // cached
  });

  it("throws when Feishu returns a non-zero code", async () => {
    stubFetch(() => ({ json: { code: 10003, msg: "app disabled" } }));
    await expect(getTenantToken()).rejects.toThrow(/tenant_access_token failed/);
  });
});

describe("feishuApi", () => {
  it("sends the bearer token and parses a code:0 response", async () => {
    stubFetch((url) =>
      url.includes("tenant_access_token")
        ? { json: tokenResponse("t-xyz") }
        : { json: { code: 0, data: { card_id: "c1" } } },
    );
    const res = (await feishuApi("POST", "/open-apis/cardkit/v1/cards", { x: 1 })) as { data: { card_id: string } };
    expect(res.data.card_id).toBe("c1");
    const apiCall = calls.find(([u]) => u.includes("/cardkit/"));
    expect(apiCall?.[1]?.headers?.Authorization).toBe("Bearer t-xyz");
    expect(apiCall?.[1]?.method).toBe("POST");
  });

  it("throws on a non-zero Feishu code", async () => {
    stubFetch((url) =>
      url.includes("tenant_access_token") ? { json: tokenResponse() } : { json: { code: 11311, msg: "bad seq" } },
    );
    await expect(feishuApi("PUT", "/open-apis/cardkit/v1/cards/c", { s: 1 })).rejects.toThrow(/code 11311/);
  });

  it("throws on a non-2xx HTTP status", async () => {
    stubFetch((url) =>
      url.includes("tenant_access_token") ? { json: tokenResponse() } : { status: 500, json: { msg: "boom" } },
    );
    await expect(feishuApi("GET", "/open-apis/x")).rejects.toThrow(/HTTP 500/);
  });

  it("retries ONCE after a 401 (stale token), refreshing the token", async () => {
    let apiHits = 0;
    stubFetch((url) => {
      if (url.includes("tenant_access_token")) return { json: tokenResponse(`t-${Date.now()}`) };
      apiHits++;
      return apiHits === 1 ? { status: 401, json: { msg: "expired" } } : { json: { code: 0, data: "ok" } };
    });
    const res = (await feishuApi("POST", "/open-apis/x", {})) as { data: string };
    expect(res.data).toBe("ok");
    expect(apiHits).toBe(2); // first 401, retry succeeded
  });
});
