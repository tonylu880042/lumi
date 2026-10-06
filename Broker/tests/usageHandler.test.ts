import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import { createUsageHandler } from "../src/usageHandler.ts";

const validToken = Buffer.alloc(32, 0x44).toString("base64url");
const secondToken = Buffer.alloc(32, 0x45).toString("base64url");
const validDigest = digestToken(validToken);
const marker = "usage-handler-marker-must-not-escape";

function digestToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

function validBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    turn: 3,
    input_tokens: 45,
    output_tokens: 78,
    total_tokens: 123,
    cached_input_tokens: 5,
    input_text_tokens: 10,
    input_audio_tokens: 35,
    output_text_tokens: 20,
    output_audio_tokens: 58,
    ...overrides,
  };
}

function request(
  authorization?: string,
  init: RequestInit = {},
): Request {
  const headers = new Headers(init.headers);
  if (authorization !== undefined) {
    headers.set("authorization", authorization);
  }
  if (!headers.has("content-type") && init.body !== undefined) {
    headers.set("content-type", "application/json");
  }

  return new Request("https://broker.test/api/usage", {
    method: "POST",
    ...init,
    headers,
  });
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

function createHandler(
  digests: readonly string[] = [validDigest],
): (request: Request) => Promise<Response> {
  return createUsageHandler({ deviceTokenDigests: digests });
}

test("method gate returns exact 405 for non-POST requests", async () => {
  const handler = createHandler();

  for (const method of ["GET", "PUT", "DELETE"]) {
    await assertErrorResponse(
      await handler(request(`Bearer ${validToken}`, { method })),
      405,
      "method_not_allowed",
    );
  }
});

test("authorization rejects missing, wrong-scheme, and unknown tokens", async () => {
  const handler = createHandler();

  await assertErrorResponse(
    await handler(
      request(undefined, { body: JSON.stringify(validBody()) }),
    ),
    401,
    "unauthorized",
  );
  await assertErrorResponse(
    await handler(
      request(`Basic ${validToken}`, { body: JSON.stringify(validBody()) }),
    ),
    401,
    "unauthorized",
  );
  await assertErrorResponse(
    await handler(
      request(`Bearer ${secondToken}`, { body: JSON.stringify(validBody()) }),
    ),
    401,
    "unauthorized",
  );
});

test("valid request returns exactly 204 with no body", async () => {
  const handler = createHandler();
  const response = await handler(
    request(`Bearer ${validToken}`, { body: JSON.stringify(validBody()) }),
  );

  assert.equal(response.status, 204);
  assert.equal(await response.text(), "");
});

test("malformed JSON body maps to 400 without leaking the parse error", async () => {
  const handler = createHandler();
  const response = await handler(
    request(`Bearer ${validToken}`, { body: marker }),
  );

  const body = await assertErrorResponse(response, 400, "invalid_body");
  assert.equal(body.includes(marker), false);
});

test("rejects malformed usage payloads", async () => {
  const handler = createHandler();
  const malformedBodies: unknown[] = [
    validBody({ turn: -1 }),
    validBody({ input_tokens: 1.5 }),
    validBody({ output_tokens: "12" }),
    validBody({ total_tokens: Number.POSITIVE_INFINITY }),
    validBody({ cached_input_tokens: null }),
    validBody({ extra_field: 1 }),
    (() => {
      const { turn, ...rest } = validBody();
      return rest;
    })(),
    [],
    "not an object",
    null,
  ];

  for (const payload of malformedBodies) {
    const response = await handler(
      request(`Bearer ${validToken}`, { body: JSON.stringify(payload) }),
    );
    await assertErrorResponse(response, 400, "invalid_body");
  }
});

test("logs exactly one structured line with the matched digest and fields", async () => {
  const handler = createHandler();
  const originalLog = console.log;
  const logged: string[] = [];
  console.log = (line: string) => {
    logged.push(line);
  };

  try {
    const response = await handler(
      request(`Bearer ${validToken}`, { body: JSON.stringify(validBody()) }),
    );
    assert.equal(response.status, 204);
  } finally {
    console.log = originalLog;
  }

  assert.equal(logged.length, 1);
  const parsed = JSON.parse(logged.at(0) ?? "") as Record<string, unknown>;
  assert.equal(parsed.event, "realtime_usage");
  assert.equal(parsed.device, validDigest);
  assert.equal(parsed.turn, 3);
  assert.equal(parsed.input_tokens, 45);
  assert.equal(parsed.output_audio_tokens, 58);
});
