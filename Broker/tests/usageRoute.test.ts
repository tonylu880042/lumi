import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  createUsageRoute,
  POST,
  type RouteDependencies,
} from "../api/usage.ts";

const validToken = Buffer.alloc(32, 0x46).toString("base64url");
const validDigest = digestToken(validToken);
const openAIKey = "usage-route-test-openai-key";
const rateLimitId = "usage-route-rate-limit-id";

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

function validBody(): Record<string, unknown> {
  return {
    turn: 1,
    input_tokens: 1,
    output_tokens: 1,
    total_tokens: 2,
    cached_input_tokens: 0,
    input_text_tokens: 0,
    input_audio_tokens: 0,
    output_text_tokens: 0,
    output_audio_tokens: 0,
  };
}

function authorizedRequest(): Request {
  return new Request("https://broker.test/api/usage", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${validToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(validBody()),
  });
}

function requestWithMethod(method: string): Request {
  return new Request("https://broker.test/api/usage", { method });
}

function createDependencies(
  overrides: Partial<RouteDependencies> = {},
): RouteDependencies {
  return {
    environment: environment(),
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

test("route rejects non-POST before configuration parsing", async () => {
  const route = createUsageRoute(
    createDependencies({
      environment: environment({
        OPENAI_API_KEY: undefined,
        LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST: undefined,
        LUMI_RATE_LIMIT_ID: undefined,
      }),
    }),
  );

  const response = await route(requestWithMethod("GET"));

  await assertErrorResponse(response, 405, "method_not_allowed");
});

test("route composition fails closed on malformed configuration", async () => {
  const route = createUsageRoute(
    createDependencies({
      environment: environment({ LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST: "" }),
    }),
  );

  const response = await route(authorizedRequest());

  await assertErrorResponse(response, 503, "service_unavailable");
});

test("route composition returns 204 for an authorized, well-formed request", async () => {
  const route = createUsageRoute(createDependencies());

  const response = await route(authorizedRequest());

  assert.equal(response.status, 204);
});

test("route composition returns 401 for an unrecognized device token", async () => {
  const route = createUsageRoute(createDependencies());
  const request = new Request("https://broker.test/api/usage", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${Buffer.alloc(32, 0x47).toString("base64url")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(validBody()),
  });

  const response = await route(request);

  await assertErrorResponse(response, 401, "unauthorized");
});
