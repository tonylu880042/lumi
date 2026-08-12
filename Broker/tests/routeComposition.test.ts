import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  createRealtimeClientSecretRoute,
  POST,
  type RouteDependencies,
} from "../api/realtime/client-secret.ts";

const validToken = Buffer.alloc(32, 0x42).toString("base64url");
const validDigest = digestToken(validToken);
const rateLimitId = "published-rule-id";
const openAIKey = "route-test-openai-key";
const clientSecret = "route-test-client-secret";
const nowSeconds = 1_780_000_000;
const marker = "route-composition-marker-must-not-escape";

function digestToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

function environment(
  overrides: Record<string, string | undefined> = {},
): Record<string, string | undefined> {
  return {
    OPENAI_API_KEY: openAIKey,
    LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST: validDigest,
    LUMI_RATE_LIMIT_ID: rateLimitId,
    ...overrides,
  };
}

function authorizedRequest(): Request {
  return new Request("https://broker.test/api/realtime/client-secret", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${validToken}`,
    },
  });
}

function requestWithMethod(method: string): Request {
  return new Request("https://broker.test/api/realtime/client-secret", {
    method,
  });
}

function createDependencies(
  overrides: Partial<RouteDependencies> = {},
): RouteDependencies {
  return {
    environment: environment(),
    checkRateLimit: async () => ({ rateLimited: false }),
    fetch: async () =>
      new Response(
        JSON.stringify({
          value: clientSecret,
          expires_at: nowSeconds + 600,
        }),
        { status: 200 },
      ),
    now: () => nowSeconds,
    ...overrides,
  };
}

async function assertErrorResponse(
  response: Response,
  status: number,
  code: string,
): Promise<string> {
  assert.equal(response.status, status);
  assert.equal(response.headers.get("content-type"), "application/json");
  assert.equal(response.headers.get("cache-control"), "no-store");
  const body = await response.text();
  assert.deepEqual(JSON.parse(body) as unknown, { error: { code } });
  return body;
}

test("route composition exports the named Vercel POST function", () => {
  assert.equal(typeof POST, "function");
});

test("route rejects non-POST before malformed configuration parsing", async () => {
  let rateLimitCalls = 0;
  let fetchCalls = 0;
  const route = createRealtimeClientSecretRoute(
    createDependencies({
      environment: environment({
        OPENAI_API_KEY: undefined,
        LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST: undefined,
        LUMI_RATE_LIMIT_ID: undefined,
      }),
      checkRateLimit: async () => {
        rateLimitCalls += 1;
        return { rateLimited: false };
      },
      fetch: async () => {
        fetchCalls += 1;
        return new Response("should not be returned", { status: 200 });
      },
    }),
  );

  const response = await route(requestWithMethod("GET"));

  await assertErrorResponse(response, 405, "method_not_allowed");
  assert.equal(rateLimitCalls, 0);
  assert.equal(fetchCalls, 0);
});

test("route composition fails closed on malformed configuration before WAF or OpenAI", async () => {
  let rateLimitCalls = 0;
  let fetchCalls = 0;
  const route = createRealtimeClientSecretRoute(
    createDependencies({
      environment: environment({ LUMI_RATE_LIMIT_ID: "" }),
      checkRateLimit: async () => {
        rateLimitCalls += 1;
        return { rateLimited: false };
      },
      fetch: async () => {
        fetchCalls += 1;
        return new Response(marker, { status: 200 });
      },
    }),
  );

  const response = await route(authorizedRequest());

  const body = await assertErrorResponse(response, 503, "service_unavailable");
  assert.equal(body.includes(marker), false);
  assert.equal(rateLimitCalls, 0);
  assert.equal(fetchCalls, 0);
});

test("route composition passes exact rule ID, request identity, and matched digest to WAF", async () => {
  let receivedRateLimitId: string | undefined;
  let receivedRequest: Request | undefined;
  let receivedRateLimitKey: string | undefined;
  let fetchCalls = 0;
  const incoming = authorizedRequest();
  const route = createRealtimeClientSecretRoute(
    createDependencies({
      checkRateLimit: async (receivedId, options) => {
        receivedRateLimitId = receivedId;
        receivedRequest = options.request;
        receivedRateLimitKey = options.rateLimitKey;
        return { rateLimited: false };
      },
      fetch: async () => {
        fetchCalls += 1;
        return new Response(
          JSON.stringify({ value: clientSecret, expires_at: nowSeconds + 600 }),
          { status: 200 },
        );
      },
    }),
  );

  const response = await route(incoming);

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    value: clientSecret,
    expiresAt: nowSeconds + 600,
  });
  assert.equal(receivedRateLimitId, rateLimitId);
  assert.equal(receivedRequest, incoming);
  assert.equal(receivedRateLimitKey, validDigest);
  assert.equal(fetchCalls, 1);
});

test("route composition returns 429 from the WAF result and never calls OpenAI", async () => {
  let fetchCalls = 0;
  const route = createRealtimeClientSecretRoute(
    createDependencies({
      checkRateLimit: async (receivedId, options) => {
        assert.equal(receivedId, rateLimitId);
        assert.equal(options.rateLimitKey, validDigest);
        return { rateLimited: true };
      },
      fetch: async () => {
        fetchCalls += 1;
        return new Response(marker, { status: 200 });
      },
    }),
  );

  const response = await route(authorizedRequest());

  await assertErrorResponse(response, 429, "rate_limited");
  assert.equal(fetchCalls, 0);
});

test("route composition maps a WAF exception to 503 without OpenAI", async () => {
  let fetchCalls = 0;
  const route = createRealtimeClientSecretRoute(
    createDependencies({
      checkRateLimit: async () => {
        throw new Error(marker);
      },
      fetch: async () => {
        fetchCalls += 1;
        return new Response(marker, { status: 200 });
      },
    }),
  );

  const response = await route(authorizedRequest());

  const body = await assertErrorResponse(response, 503, "service_unavailable");
  assert.equal(body.includes(marker), false);
  assert.equal(fetchCalls, 0);
});

test("route composition maps WAF error results to 503 without OpenAI", async () => {
  let fetchCalls = 0;
  for (const error of ["not-found", "blocked"] as const) {
    const route = createRealtimeClientSecretRoute(
      createDependencies({
        checkRateLimit: async () => ({ rateLimited: false, error }),
        fetch: async () => {
          fetchCalls += 1;
          return new Response(marker, { status: 200 });
        },
      }),
    );

    const response = await route(authorizedRequest());

    const body = await assertErrorResponse(response, 503, "service_unavailable");
    assert.equal(body.includes(marker), false);
  }

  assert.equal(fetchCalls, 0);
});

test("route composition maps unexpected composition exceptions to fixed 503", async () => {
  const route = createRealtimeClientSecretRoute(
    createDependencies({
      now: () => {
        throw new Error(marker);
      },
    }),
  );

  const response = await route(authorizedRequest());

  const body = await assertErrorResponse(response, 503, "service_unavailable");
  assert.equal(body.includes(marker), false);
});
