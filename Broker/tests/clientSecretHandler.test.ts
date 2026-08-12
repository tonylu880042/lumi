import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  createClientSecretHandler,
  findMatchingDigest,
} from "../src/clientSecretHandler.ts";

const validToken = Buffer.alloc(32, 0x42).toString("base64url");
const secondToken = Buffer.alloc(32, 0x43).toString("base64url");
const validDigest = digestToken(validToken);
const secondDigest = digestToken(secondToken);
const marker = "handler-marker-must-not-escape";
const inputMarker = "client-input-marker-must-not-be-forwarded";
const upstreamMarker = "upstream-marker-must-not-escape";
const testOpenAIKey = "test-openai-key";
const testClientSecret = "client-secret-test-value";
const nowSeconds = 1_780_000_000;

function digestToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

function request(
  authorization?: string,
  init: RequestInit = {},
): Request {
  const headers = new Headers(init.headers);
  if (authorization !== undefined) {
    headers.set("authorization", authorization);
  }

  return new Request("https://broker.test/api/realtime/client-secret", {
    method: "POST",
    ...init,
    headers,
  });
}

function jsonResponse(response: Response): Promise<Record<string, unknown>> {
  return response.json() as Promise<Record<string, unknown>>;
}

function assertNoStoreJson(response: Response): void {
  assert.equal(response.headers.get("content-type"), "application/json");
  assert.equal(response.headers.get("cache-control"), "no-store");
}

async function assertErrorResponse(
  response: Response,
  status: number,
  code: string,
): Promise<string> {
  assert.equal(response.status, status);
  assertNoStoreJson(response);
  const body = await response.text();
  assert.deepEqual(JSON.parse(body) as unknown, {
    error: { code },
  });
  return body;
}

type HandlerOptions = Readonly<{
  checkRateLimit?: (rateLimitKey: string) => boolean | Promise<boolean>;
  fetch?: (input: string, init?: RequestInit) => Promise<Response>;
  now?: () => number;
  openAIKey?: string;
}>;

function createHandler(
  digests: readonly string[] = [validDigest],
  options: HandlerOptions = {},
): (request: Request) => Promise<Response> {
  return createClientSecretHandler({
    deviceTokenDigests: digests,
    checkRateLimit: options.checkRateLimit ?? (() => false),
    fetch:
      options.fetch ??
      (async () =>
        new Response(
          JSON.stringify({
            value: testClientSecret,
            expires_at: nowSeconds + 600,
          }),
          { status: 200 },
        )),
    now: options.now ?? (() => nowSeconds),
    openAIKey: options.openAIKey ?? testOpenAIKey,
  });
}

test("method gate returns exact 405 and never calls downstream dependencies", async () => {
  let rateLimitCalls = 0;
  let fetchCalls = 0;
  const handler = createHandler([validDigest], {
    checkRateLimit: () => {
      rateLimitCalls += 1;
      return false;
    },
    fetch: async () => {
      fetchCalls += 1;
      return new Response("should not be returned");
    },
  });

  for (const method of ["GET", "PUT", "DELETE"]) {
    await assertErrorResponse(
      await handler(request(`Bearer ${validToken}`, { method })),
      405,
      "method_not_allowed",
    );
  }

  assert.equal(rateLimitCalls, 0);
  assert.equal(fetchCalls, 0);
});

test("authorization rejects missing and wrong-scheme headers", async () => {
  let rateLimitCalls = 0;
  let fetchCalls = 0;
  const handler = createHandler([validDigest], {
    checkRateLimit: () => {
      rateLimitCalls += 1;
      return false;
    },
    fetch: async () => {
      fetchCalls += 1;
      return new Response("should not be returned");
    },
  });

  await assertErrorResponse(
    await handler(request()),
    401,
    "unauthorized",
  );
  await assertErrorResponse(
    await handler(request(`Basic ${validToken}`)),
    401,
    "unauthorized",
  );

  assert.equal(rateLimitCalls, 0);
  assert.equal(fetchCalls, 0);
});

test("authorization rejects repeated and malformed Bearer values", async () => {
  let rateLimitCalls = 0;
  let fetchCalls = 0;
  const handler = createHandler([validDigest], {
    checkRateLimit: () => {
      rateLimitCalls += 1;
      return false;
    },
    fetch: async () => {
      fetchCalls += 1;
      return new Response("should not be returned");
    },
  });

  const repeatedHeaders = new Headers();
  repeatedHeaders.append("authorization", `Bearer ${validToken}`);
  repeatedHeaders.append("authorization", `Bearer ${validToken}`);
  await assertErrorResponse(
    await handler(request(undefined, { headers: repeatedHeaders })),
    401,
    "unauthorized",
  );

  for (const value of [
    `Bearer ${validToken.slice(0, 42)}`,
    `Bearer ${validToken} trailing`,
    `Bearer  ${validToken}`,
    `bearer ${validToken}`,
  ]) {
    await assertErrorResponse(
      await handler(request(value)),
      401,
      "unauthorized",
    );
  }

  assert.equal(rateLimitCalls, 0);
  assert.equal(fetchCalls, 0);
});

test("authorization rejects noncanonical 43-character base64url values", async () => {
  const noncanonicalToken = `${validToken.slice(0, -1)}B`;
  assert.equal(noncanonicalToken.length, 43);
  assert.match(noncanonicalToken, /^[A-Za-z0-9_-]{43}$/);

  let rateLimitCalls = 0;
  let fetchCalls = 0;
  const handler = createHandler([validDigest], {
    checkRateLimit: () => {
      rateLimitCalls += 1;
      return false;
    },
    fetch: async () => {
      fetchCalls += 1;
      return new Response("should not be returned");
    },
  });

  await assertErrorResponse(
    await handler(request(`Bearer ${noncanonicalToken}`)),
    401,
    "unauthorized",
  );
  assert.equal(rateLimitCalls, 0);
  assert.equal(fetchCalls, 0);
});

test("unknown and removed tokens return indistinguishable 401 responses", async () => {
  const unknownHandler = createHandler([validDigest]);
  const removedHandler = createHandler([]);

  const unknownResponse = await unknownHandler(request(`Bearer ${secondToken}`));
  const removedResponse = await removedHandler(request(`Bearer ${validToken}`));

  await assertErrorResponse(unknownResponse, 401, "unauthorized");
  await assertErrorResponse(removedResponse, 401, "unauthorized");
  assert.equal(unknownResponse.status, removedResponse.status);
  assert.equal(
    unknownResponse.headers.get("content-type"),
    removedResponse.headers.get("content-type"),
  );
  assert.equal(
    unknownResponse.headers.get("cache-control"),
    removedResponse.headers.get("cache-control"),
  );
});

test("unauthorized responses never expose token, digest, or marker values", async () => {
  const handler = createHandler([validDigest]);
  const response = await handler(request(`Bearer ${secondToken}`));
  const body = await response.text();

  assert.equal(body.includes(validToken), false);
  assert.equal(body.includes(validDigest), false);
  assert.equal(body.includes(marker), false);
});

test("rate limit uses the matched digest key and short-circuits OpenAI", async () => {
  let rateLimitKey: string | undefined;
  let fetchCalls = 0;
  const handler = createHandler([validDigest], {
    checkRateLimit: (key) => {
      rateLimitKey = key;
      return true;
    },
    fetch: async () => {
      fetchCalls += 1;
      return new Response("should not be returned", { status: 200 });
    },
  });

  const response = await handler(request(`Bearer ${validToken}`));

  await assertErrorResponse(response, 429, "rate_limited");
  assert.equal(rateLimitKey, validDigest);
  assert.equal(fetchCalls, 0);
});

test("rate limit failures fail closed as 503 without calling OpenAI", async () => {
  let fetchCalls = 0;
  const handler = createHandler([validDigest], {
    checkRateLimit: () => {
      throw new Error(upstreamMarker);
    },
    fetch: async () => {
      fetchCalls += 1;
      return new Response("should not be returned", { status: 200 });
    },
  });

  const response = await handler(request(`Bearer ${validToken}`));

  const body = await assertErrorResponse(response, 503, "service_unavailable");
  assert.equal(body.includes(upstreamMarker), false);
  assert.equal(body.includes(marker), false);
  assert.equal(fetchCalls, 0);
});

test("OpenAI request uses the fixed client-secret contract and maps success", async () => {
  const incoming = request(`Bearer ${validToken}`, { body: inputMarker });
  let capturedInput: string | undefined;
  let capturedInit: RequestInit | undefined;
  const handler = createHandler([validDigest], {
    fetch: async (input, init) => {
      capturedInput = input;
      capturedInit = init;
      return new Response(
        JSON.stringify({
          value: testClientSecret,
          expires_at: nowSeconds + 600,
        }),
        { status: 200 },
      );
    },
  });

  const response = await handler(incoming);

  assert.equal(response.status, 200);
  assertNoStoreJson(response);
  assert.deepEqual(await jsonResponse(response), {
    value: testClientSecret,
    expiresAt: nowSeconds + 600,
  });
  assert.equal(capturedInput, "https://api.openai.com/v1/realtime/client_secrets");
  assert.notEqual(capturedInit, undefined);
  assert.equal(capturedInit?.method, "POST");
  assert.equal(capturedInit?.signal, incoming.signal);

  const capturedHeaders = new Headers(capturedInit?.headers);
  assert.deepEqual(
    [...capturedHeaders.keys()].sort(),
    ["authorization", "content-type", "openai-safety-identifier"],
  );
  assert.equal(
    capturedHeaders.get("authorization"),
    `Bearer ${testOpenAIKey}`,
  );
  assert.equal(capturedHeaders.get("content-type"), "application/json");
  assert.equal(
    capturedHeaders.get("openai-safety-identifier"),
    validDigest,
  );

  assert.equal(typeof capturedInit?.body, "string");
  const body = JSON.parse(capturedInit?.body as string) as unknown;
  assert.deepEqual(body, {
    session: {
      type: "realtime",
      model: "gpt-realtime-2.1-mini",
      audio: { output: { voice: "marin" } },
    },
  });
  assert.equal((capturedInit?.body as string).includes(inputMarker), false);
});

test("upstream non-2xx responses map to 502 without provider leakage", async () => {
  const handler = createHandler([validDigest], {
    fetch: async () =>
      new Response(JSON.stringify({ error: upstreamMarker }), { status: 429 }),
  });

  const response = await handler(request(`Bearer ${validToken}`));

  const body = await assertErrorResponse(response, 502, "upstream_failure");
  assert.equal(body.includes(upstreamMarker), false);
  assert.equal(body.includes(testOpenAIKey), false);
});

test("upstream malformed success data maps to 502 without provider leakage", async () => {
  const malformedPayloads: unknown[] = [
    { value: "", expires_at: nowSeconds + 600 },
    { value: "   ", expires_at: nowSeconds + 600 },
    { value: upstreamMarker, expires_at: nowSeconds - 1 },
    { value: testClientSecret },
    { expires_at: nowSeconds + 600 },
    [],
    { value: testClientSecret, expires_at: null },
    { value: testClientSecret, expires_at: true },
    { value: testClientSecret, expires_at: "not-a-timestamp" },
  ];

  for (const payload of malformedPayloads) {
    const handler = createHandler([validDigest], {
      fetch: async () => new Response(JSON.stringify(payload), { status: 200 }),
    });
    const response = await handler(request(`Bearer ${validToken}`));

    const body = await assertErrorResponse(response, 502, "upstream_failure");
    assert.equal(body.includes(upstreamMarker), false);
    assert.equal(body.includes(testClientSecret), false);
  }
});

test("finite future fractional expiry is preserved exactly", async () => {
  const expiresAt = nowSeconds + 600.25;
  const handler = createHandler([validDigest], {
    fetch: async () =>
      new Response(
        JSON.stringify({ value: testClientSecret, expires_at: expiresAt }),
        { status: 200 },
      ),
  });

  const response = await handler(request(`Bearer ${validToken}`));

  assert.equal(response.status, 200);
  assertNoStoreJson(response);
  assert.deepEqual(await jsonResponse(response), {
    value: testClientSecret,
    expiresAt,
  });
});

test("malformed upstream JSON maps to 502 without body leakage", async () => {
  const handler = createHandler([validDigest], {
    fetch: async () => new Response(upstreamMarker, { status: 200 }),
  });

  const response = await handler(request(`Bearer ${validToken}`));

  const body = await assertErrorResponse(response, 502, "upstream_failure");
  assert.equal(body.includes(upstreamMarker), false);
});

test("upstream fetch failures map to 502 without provider leakage", async () => {
  const handler = createHandler([validDigest], {
    fetch: async () => {
      throw new Error(upstreamMarker);
    },
  });

  const response = await handler(request(`Bearer ${validToken}`));

  const body = await assertErrorResponse(response, 502, "upstream_failure");
  assert.equal(body.includes(upstreamMarker), false);
});

test("digest matcher compares every configured digest after a match", () => {
  const configuredDigests = ["a", "b", "c"];
  const comparisons: Array<[string, string]> = [];

  const matchedDigest = findMatchingDigest(
    "a",
    configuredDigests,
    (presentedDigest, configuredDigest) => {
      comparisons.push([presentedDigest, configuredDigest]);
      return presentedDigest === configuredDigest;
    },
  );

  assert.equal(matchedDigest, "a");
  assert.deepEqual(comparisons, [
    ["a", "a"],
    ["a", "b"],
    ["a", "c"],
  ]);
});

test("digest matcher returns the first match while still comparing every digest", () => {
  const configuredDigests = ["first", "target", "target"];
  let comparisonCount = 0;

  const matchedDigest = findMatchingDigest(
    "target",
    configuredDigests,
    (presentedDigest, configuredDigest) => {
      comparisonCount += 1;
      return presentedDigest === configuredDigest;
    },
  );

  assert.equal(matchedDigest, "target");
  assert.equal(comparisonCount, configuredDigests.length);
});
