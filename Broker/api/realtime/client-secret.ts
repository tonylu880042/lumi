import { checkRateLimit as vercelCheckRateLimit } from "@vercel/firewall";

import {
  parseBrokerConfiguration,
  type BrokerEnvironment,
} from "../../src/configuration.ts";
import {
  createClientSecretHandler,
  type ClientSecretHandlerDependencies,
} from "../../src/clientSecretHandler.ts";

type RateLimitOptions = Readonly<{
  request: Request;
  rateLimitKey: string;
}>;

type RateLimitResult = Readonly<{
  rateLimited: boolean;
  error?: "not-found" | "blocked";
}>;

type RateLimitCheck = (
  rateLimitId: string,
  options: RateLimitOptions,
) => Promise<RateLimitResult>;

export type RouteDependencies = Readonly<{
  environment: BrokerEnvironment;
  checkRateLimit: RateLimitCheck;
  fetch: ClientSecretHandlerDependencies["fetch"];
  now: () => number;
}>;

function serviceUnavailableResponse(): Response {
  return new Response(
    JSON.stringify({ error: { code: "service_unavailable" } }),
    {
      status: 503,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      },
    },
  );
}

function methodNotAllowedResponse(): Response {
  return new Response(
    JSON.stringify({ error: { code: "method_not_allowed" } }),
    {
      status: 405,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      },
    },
  );
}

export function createRealtimeClientSecretRoute(
  dependencies: RouteDependencies,
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return methodNotAllowedResponse();
    }

    try {
      const configuration = parseBrokerConfiguration(dependencies.environment);
      const handler = createClientSecretHandler({
        deviceTokenDigests: configuration.deviceTokenDigests,
        openAIKey: configuration.openAIKey,
        fetch: dependencies.fetch,
        now: dependencies.now,
        checkRateLimit: async (matchedDigest) => {
          const result = await dependencies.checkRateLimit(
            configuration.rateLimitId,
            {
              request,
              rateLimitKey: matchedDigest,
            },
          );

          if (result.error !== undefined) {
            throw new Error("rate_limit_unavailable");
          }

          return result.rateLimited;
        },
      });

      return await handler(request);
    } catch {
      return serviceUnavailableResponse();
    }
  };
}

export async function POST(request: Request): Promise<Response> {
  return createRealtimeClientSecretRoute({
    environment: process.env,
    checkRateLimit: (rateLimitId, options) =>
      vercelCheckRateLimit(rateLimitId, options),
    fetch: (input, init) => globalThis.fetch(input, init),
    now: () => Date.now() / 1000,
  })(request);
}
