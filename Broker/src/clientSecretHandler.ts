import { createHash, timingSafeEqual } from "node:crypto";

const AUTHORIZATION_HEADER = "authorization";
const CANONICAL_DEVICE_TOKEN = /^[A-Za-z0-9_-]{43}$/;
const AUTHORIZATION_VALUE = /^Bearer ([A-Za-z0-9_-]{43})$/;
const UNAUTHORIZED_STATUS = 401;
const METHOD_NOT_ALLOWED_STATUS = 405;
const RATE_LIMITED_STATUS = 429;
const UPSTREAM_FAILURE_STATUS = 502;
const SERVICE_UNAVAILABLE_STATUS = 503;
const OPENAI_CLIENT_SECRETS_URL =
  "https://api.openai.com/v1/realtime/client_secrets";
const OPENAI_REQUEST_BODY = JSON.stringify({
  session: {
    type: "realtime",
    model: "gpt-realtime-2.1-mini",
    audio: { output: { voice: "marin" } },
  },
});

type DigestComparator = (
  presentedDigest: string,
  configuredDigest: string,
) => boolean;

export type ClientSecretHandlerDependencies = Readonly<{
  deviceTokenDigests: readonly string[];
  checkRateLimit: (rateLimitKey: string) => boolean | Promise<boolean>;
  fetch: (input: string, init?: RequestInit) => Promise<Response>;
  now: () => number;
  openAIKey: string;
}>;

function jsonResponse(status: number, code: string): Response {
  return new Response(JSON.stringify({ error: { code } }), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

function clientSecretResponse(value: string, expiresAt: number): Response {
  return new Response(JSON.stringify({ value, expiresAt }), {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

function parseClientSecretPayload(
  payload: unknown,
  now: number,
): { value: string; expiresAt: number } | undefined {
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
    return undefined;
  }

  const record = payload as Record<string, unknown>;
  const value = record["value"];
  const expiresAt = record["expires_at"];

  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    typeof expiresAt !== "number" ||
    !Number.isFinite(expiresAt) ||
    expiresAt <= now
  ) {
    return undefined;
  }

  return { value, expiresAt };
}

function canonicalDeviceToken(value: string | null): string | undefined {
  if (value === null || !CANONICAL_DEVICE_TOKEN.test(value)) {
    return undefined;
  }

  const decoded = Buffer.from(value, "base64url");
  if (decoded.length !== 32 || decoded.toString("base64url") !== value) {
    return undefined;
  }

  return value;
}

function parseAuthorizationHeader(value: string | null): string | undefined {
  if (value === null || !AUTHORIZATION_VALUE.test(value)) {
    return undefined;
  }

  return canonicalDeviceToken(value.slice("Bearer ".length));
}

function digestDeviceToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

function timingSafeDigestMatch(
  presentedDigest: string,
  configuredDigest: string,
): boolean {
  const presentedBytes = Buffer.from(presentedDigest, "utf8");
  const configuredBytes = Buffer.from(configuredDigest, "utf8");

  if (presentedBytes.byteLength !== configuredBytes.byteLength) {
    return false;
  }

  return timingSafeEqual(presentedBytes, configuredBytes);
}

/** @internal Testing-only comparator seam; the handler always uses its fixed comparator. */
export function findMatchingDigest(
  presentedDigest: string,
  configuredDigests: readonly string[],
  compare: DigestComparator = timingSafeDigestMatch,
): string | undefined {
  let matchedDigest: string | undefined;

  for (const configuredDigest of configuredDigests) {
    const isMatch = compare(presentedDigest, configuredDigest);
    if (isMatch && matchedDigest === undefined) {
      matchedDigest = configuredDigest;
    }
  }

  return matchedDigest;
}

export function createClientSecretHandler(
  dependencies: ClientSecretHandlerDependencies,
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return jsonResponse(METHOD_NOT_ALLOWED_STATUS, "method_not_allowed");
    }

    const token = parseAuthorizationHeader(
      request.headers.get(AUTHORIZATION_HEADER),
    );
    if (token === undefined) {
      return jsonResponse(UNAUTHORIZED_STATUS, "unauthorized");
    }

    const presentedDigest = digestDeviceToken(token);
    const matchedDigest = findMatchingDigest(
      presentedDigest,
      dependencies.deviceTokenDigests,
    );
    if (matchedDigest === undefined) {
      return jsonResponse(UNAUTHORIZED_STATUS, "unauthorized");
    }

    let rateLimited: boolean;
    try {
      rateLimited = await dependencies.checkRateLimit(matchedDigest);
    } catch {
      return jsonResponse(SERVICE_UNAVAILABLE_STATUS, "service_unavailable");
    }

    if (rateLimited) {
      return jsonResponse(RATE_LIMITED_STATUS, "rate_limited");
    }

    let upstreamResponse: Response;
    try {
      upstreamResponse = await dependencies.fetch(OPENAI_CLIENT_SECRETS_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${dependencies.openAIKey}`,
          "Content-Type": "application/json",
          "OpenAI-Safety-Identifier": matchedDigest,
        },
        body: OPENAI_REQUEST_BODY,
        signal: request.signal,
      });
    } catch {
      return jsonResponse(UPSTREAM_FAILURE_STATUS, "upstream_failure");
    }

    if (!upstreamResponse.ok) {
      return jsonResponse(UPSTREAM_FAILURE_STATUS, "upstream_failure");
    }

    let payload: unknown;
    try {
      payload = await upstreamResponse.json();
    } catch {
      return jsonResponse(UPSTREAM_FAILURE_STATUS, "upstream_failure");
    }

    const clientSecret = parseClientSecretPayload(payload, dependencies.now());
    if (clientSecret === undefined) {
      return jsonResponse(UPSTREAM_FAILURE_STATUS, "upstream_failure");
    }

    return clientSecretResponse(clientSecret.value, clientSecret.expiresAt);
  };
}
