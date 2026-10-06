import {
  digestDeviceToken,
  findMatchingDigest,
  parseAuthorizationHeader,
} from "./clientSecretHandler.ts";

const AUTHORIZATION_HEADER = "authorization";
const UNAUTHORIZED_STATUS = 401;
const METHOD_NOT_ALLOWED_STATUS = 405;
const BAD_REQUEST_STATUS = 400;
const NO_CONTENT_STATUS = 204;

// Integer-only Realtime usage counters plus a round/turn number. No
// transcript, audio, identifier, or other free-form value is ever accepted
// here — this exists solely for the one-off greeting-cost measurement.
const USAGE_FIELDS = [
  "turn",
  "input_tokens",
  "output_tokens",
  "total_tokens",
  "cached_input_tokens",
  "input_text_tokens",
  "input_audio_tokens",
  "output_text_tokens",
  "output_audio_tokens",
] as const;

export type UsageHandlerDependencies = Readonly<{
  deviceTokenDigests: readonly string[];
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

function noContentResponse(): Response {
  return new Response(null, { status: NO_CONTENT_STATUS });
}

function isFiniteNonNegativeInteger(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isFinite(value) &&
    Number.isInteger(value) &&
    value >= 0
  );
}

function parseUsagePayload(
  payload: unknown,
): Record<string, number> | undefined {
  if (
    typeof payload !== "object" ||
    payload === null ||
    Array.isArray(payload)
  ) {
    return undefined;
  }

  const record = payload as Record<string, unknown>;
  if (Object.keys(record).length !== USAGE_FIELDS.length) {
    return undefined;
  }

  const parsed: Record<string, number> = {};
  for (const field of USAGE_FIELDS) {
    const value = record[field];
    if (!isFiniteNonNegativeInteger(value)) {
      return undefined;
    }
    parsed[field] = value;
  }

  return parsed;
}

export function createUsageHandler(
  dependencies: UsageHandlerDependencies,
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

    let payload: unknown;
    try {
      payload = await request.json();
    } catch {
      return jsonResponse(BAD_REQUEST_STATUS, "invalid_body");
    }

    const usage = parseUsagePayload(payload);
    if (usage === undefined) {
      return jsonResponse(BAD_REQUEST_STATUS, "invalid_body");
    }

    // The only side effect: one structured log line for later analysis.
    // No database, no KV, no queue — this is a one-off measurement.
    console.log(
      JSON.stringify({
        event: "realtime_usage",
        device: matchedDigest,
        ...usage,
      }),
    );

    return noContentResponse();
  };
}
