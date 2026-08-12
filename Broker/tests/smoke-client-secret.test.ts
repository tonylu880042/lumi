import assert from "node:assert/strict";
import test from "node:test";

import {
  MAX_AUTHORIZED_REQUESTS,
  runSmoke,
  runSmokeCommand,
} from "../scripts/smoke-client-secret.ts";

const endpoint = "https://preview-broker.example.test/api/realtime/client-secret";
const deviceToken = Buffer.alloc(32, 0x42).toString("base64url");
const clientSecretMarker = "client-secret-marker-must-not-escape";
const upstreamMarker = "upstream-marker-must-not-escape";
const endpointMarker = "endpoint-marker-must-not-escape";
const nowSeconds = 1_780_000_000;

type FetchCall = Readonly<{
  readonly input: string;
  readonly init: RequestInit | undefined;
}>;

function jsonResponse(payload: unknown, status: number): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

function successResponse(): Response {
  return jsonResponse(
    { value: clientSecretMarker, expiresAt: nowSeconds + 600 },
    200,
  );
}

function unauthorizedResponse(): Response {
  return jsonResponse({ error: { code: "unauthorized" } }, 401);
}

function rateLimitedResponse(): Response {
  return jsonResponse({ error: { code: "rate_limited" } }, 429);
}

function createFetch(
  calls: FetchCall[],
  responses: readonly Response[],
): typeof fetch {
  let responseIndex = 0;

  return async (input, init) => {
    calls.push({ input: String(input), init });
    const response = responses[Math.min(responseIndex, responses.length - 1)];
    responseIndex += 1;
    if (response === undefined) {
      throw new Error("missing fake response");
    }
    return response;
  };
}

test("smoke validates unauthorized, authorized, and bounded rate-limit scenarios", async () => {
  const calls: FetchCall[] = [];
  const responses = [
    unauthorizedResponse(),
    ...Array.from({ length: MAX_AUTHORIZED_REQUESTS - 1 }, () => successResponse()),
    rateLimitedResponse(),
  ];

  const report = await runSmoke({
    endpoint,
    deviceToken,
    fetch: createFetch(calls, responses),
    now: () => nowSeconds,
  });

  assert.deepEqual(report, {
    ok: true,
    checks: [
      {
        scenario: "unauthorized",
        statusOk: true,
        categoryOk: true,
        schemaOk: true,
      },
      {
        scenario: "authorized",
        statusOk: true,
        categoryOk: true,
        schemaOk: true,
      },
      {
        scenario: "rate_limit",
        statusOk: true,
        categoryOk: true,
        schemaOk: true,
      },
    ],
  });

  assert.equal(calls.length, MAX_AUTHORIZED_REQUESTS + 1);
  assert.equal(calls[0]?.init?.body, undefined);
  assert.equal(calls[0]?.init?.headers instanceof Headers, true);
  assert.equal(new Headers(calls[0]?.init?.headers).get("authorization"), null);
  for (const call of calls.slice(1)) {
    assert.equal(call.input, endpoint);
    assert.equal(call.init?.method, "POST");
    assert.equal(call.init?.body, undefined);
    assert.equal(
      new Headers(call.init?.headers).get("authorization"),
      `Bearer ${deviceToken}`,
    );
    assert.equal(
      new Headers(call.init?.headers).get("accept"),
      "application/json",
    );
  }

  for (const response of responses) {
    assert.equal(response.bodyUsed, true);
  }
});

test("smoke stops as soon as the rate-limit response arrives", async () => {
  const calls: FetchCall[] = [];
  const responses = [
    unauthorizedResponse(),
    successResponse(),
    successResponse(),
    rateLimitedResponse(),
    successResponse(),
  ];

  const report = await runSmoke({
    endpoint,
    deviceToken,
    fetch: createFetch(calls, responses),
    now: () => nowSeconds,
  });

  assert.equal(report.ok, true);
  assert.equal(calls.length, 4);
  assert.equal(responses[3]?.bodyUsed, true);
  assert.equal(responses[4]?.bodyUsed, false);
});

test("smoke requires the camelCase broker success schema", async () => {
  const calls: FetchCall[] = [];
  const responses = [
    unauthorizedResponse(),
    jsonResponse(
      { value: clientSecretMarker, expires_at: nowSeconds + 600 },
      200,
    ),
    rateLimitedResponse(),
  ];

  const report = await runSmoke({
    endpoint,
    deviceToken,
    fetch: createFetch(calls, responses),
    now: () => nowSeconds,
  });

  assert.equal(report.ok, false);
  assert.equal(report.checks[1]?.statusOk, true);
  assert.equal(report.checks[1]?.categoryOk, false);
  assert.equal(report.checks[1]?.schemaOk, false);
  assert.equal(calls.length, 2);
  assert.equal(responses[1]?.bodyUsed, true);
  assert.equal(responses[2]?.bodyUsed, false);
});

test("smoke command emits only static boolean output", async () => {
  const stdout: string[] = [];
  const stderr: string[] = [];

  const exitCode = await runSmokeCommand(
    {
      LUMI_SMOKE_ENDPOINT: endpoint,
      LUMI_SMOKE_DEVICE_TOKEN: deviceToken,
    },
    {
      fetch: createFetch(
        [],
        [
          unauthorizedResponse(),
          ...Array.from({ length: MAX_AUTHORIZED_REQUESTS - 1 }, () => successResponse()),
          rateLimitedResponse(),
        ],
      ),
      now: () => nowSeconds,
      writeStdout: (value) => stdout.push(value),
      writeStderr: (value) => stderr.push(value),
    },
  );

  assert.equal(exitCode, 0);
  assert.deepEqual(stderr, []);
  assert.equal(stdout.length, 1);
  const output = stdout[0] ?? "";
  const expectedOutput =
    '{"ok":true,"checks":[{"scenario":"unauthorized","statusOk":true,"categoryOk":true,"schemaOk":true},{"scenario":"authorized","statusOk":true,"categoryOk":true,"schemaOk":true},{"scenario":"rate_limit","statusOk":true,"categoryOk":true,"schemaOk":true}]}\n';
  assert.equal(output, expectedOutput);
  const parsed = JSON.parse(output) as unknown;
  assert.deepEqual(parsed, {
    ok: true,
    checks: [
      { scenario: "unauthorized", statusOk: true, categoryOk: true, schemaOk: true },
      { scenario: "authorized", statusOk: true, categoryOk: true, schemaOk: true },
      { scenario: "rate_limit", statusOk: true, categoryOk: true, schemaOk: true },
    ],
  });
  for (const marker of [
    endpoint,
    deviceToken,
    clientSecretMarker,
    upstreamMarker,
    "401",
    "429",
    "200",
    "rate_limited",
  ]) {
    assert.equal(output.includes(marker), false);
  }
  assert.equal(output.includes('"scenario":"unauthorized"'), true);
  assert.equal(output.includes('"scenario":"authorized"'), true);
  assert.equal(output.includes('"scenario":"rate_limit"'), true);
  assert.equal(output.includes('"statusOk":true'), true);
  assert.equal(output.includes('"categoryOk":true'), true);
  assert.equal(output.includes('"schemaOk":true'), true);
});

test("smoke output and failures never expose endpoint, token, client-secret, or upstream markers", async () => {
  const calls: FetchCall[] = [];
  const stderr: string[] = [];
  const stdout: string[] = [];
  const response = new Response(JSON.stringify({ error: upstreamMarker }), {
    status: 502,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

  const exitCode = await runSmokeCommand(
    {
      LUMI_SMOKE_ENDPOINT: endpoint,
      LUMI_SMOKE_DEVICE_TOKEN: deviceToken,
    },
    {
      fetch: async (input, init) => {
        calls.push({ input: String(input), init });
        if (calls.length === 1) {
          return unauthorizedResponse();
        }
        if (calls.length === 2) {
          return response;
        }
        throw new Error(`${endpointMarker}:${deviceToken}:${clientSecretMarker}`);
      },
      now: () => nowSeconds,
      writeStdout: (value) => stdout.push(value),
      writeStderr: (value) => stderr.push(value),
    },
  );

  assert.equal(exitCode, 1);
  assert.equal(response.bodyUsed, true);
  const output = `${stdout.join("")}\n${stderr.join("")}`;
  assert.equal(output.includes(endpoint), false);
  assert.equal(output.includes(deviceToken), false);
  assert.equal(output.includes(clientSecretMarker), false);
  assert.equal(output.includes(upstreamMarker), false);
  assert.equal(output.includes("401"), false);
  assert.equal(output.includes("429"), false);
  assert.equal(output.includes("502"), false);
  assert.equal(output.includes("upstream_failure"), false);
  assert.equal(calls.length, 2);
});

test("smoke command reduces fetch diagnostics to a fixed failure", async () => {
  const stdout: string[] = [];
  const stderr: string[] = [];

  const exitCode = await runSmokeCommand(
    {
      LUMI_SMOKE_ENDPOINT: endpoint,
      LUMI_SMOKE_DEVICE_TOKEN: deviceToken,
    },
    {
      fetch: async () => {
        throw new Error(
          `${endpointMarker}:${deviceToken}:${clientSecretMarker}:${upstreamMarker}`,
        );
      },
      writeStdout: (value) => stdout.push(value),
      writeStderr: (value) => stderr.push(value),
    },
  );

  assert.equal(exitCode, 1);
  assert.equal(stderr.length, 0);
  assert.equal(stdout.length, 1);
  const diagnostics = `${stdout.join("")}\n${stderr.join("")}`;
  for (const marker of [
    endpoint,
    endpointMarker,
    deviceToken,
    clientSecretMarker,
    upstreamMarker,
  ]) {
    assert.equal(diagnostics.includes(marker), false);
  }
});

test("smoke validates endpoint and token before any fetch", async () => {
  let fetchCalls = 0;
  const fetch = async () => {
    fetchCalls += 1;
    return unauthorizedResponse();
  };

  for (const invalidEndpoint of [
    "http://broker.example.test/api/realtime/client-secret",
    "https://user:password@broker.example.test/api/realtime/client-secret",
    "https://broker.example.test/api/realtime/client-secret?marker=secret",
    "https://broker.example.test/api/realtime/client-secret#marker",
  ]) {
    await assert.rejects(
      () =>
        runSmoke({
          endpoint: invalidEndpoint,
          deviceToken,
          fetch,
          now: () => nowSeconds,
        }),
      (error: unknown) => {
        assert.equal(String(error).includes("marker"), false);
        assert.equal(String(error).includes(deviceToken), false);
        return true;
      },
    );
  }

  await assert.rejects(
    () =>
      runSmoke({
        endpoint,
        deviceToken: `${deviceToken.slice(0, -1)}!`,
        fetch,
        now: () => nowSeconds,
      }),
    (error: unknown) => {
      assert.equal(String(error).includes(deviceToken), false);
      return true;
    },
  );

  const noncanonicalTrailingBitsToken = `${deviceToken.slice(0, -1)}B`;
  assert.match(noncanonicalTrailingBitsToken, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(noncanonicalTrailingBitsToken, deviceToken);
  await assert.rejects(
    () =>
      runSmoke({
        endpoint,
        deviceToken: noncanonicalTrailingBitsToken,
        fetch,
        now: () => nowSeconds,
      }),
    (error: unknown) => {
      assert.equal(String(error).includes(noncanonicalTrailingBitsToken), false);
      return true;
    },
  );

  assert.equal(fetchCalls, 0);
});
