import {
  parseBrokerConfiguration,
  type BrokerEnvironment,
} from "../src/configuration.ts";
import { createUsageHandler } from "../src/usageHandler.ts";

export type RouteDependencies = Readonly<{
  environment: BrokerEnvironment;
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

// One-off Realtime cost-telemetry milestone: no rate limiting here (unlike
// the client-secret route). Adding the WAF plumbing would roughly double
// this route's size for an endpoint that only appends one log line and is
// already fire-and-forget from every caller. See the milestone report for
// the explicit trade-off.
export function createUsageRoute(
  dependencies: RouteDependencies,
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return methodNotAllowedResponse();
    }

    try {
      const configuration = parseBrokerConfiguration(dependencies.environment);
      const handler = createUsageHandler({
        deviceTokenDigests: configuration.deviceTokenDigests,
      });
      return await handler(request);
    } catch {
      return serviceUnavailableResponse();
    }
  };
}

export async function POST(request: Request): Promise<Response> {
  return createUsageRoute({ environment: process.env })(request);
}
