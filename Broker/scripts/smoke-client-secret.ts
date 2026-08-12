import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const MAX_AUTHORIZED_REQUESTS = 11;

const ENDPOINT_ENV = "LUMI_SMOKE_ENDPOINT";
const DEVICE_TOKEN_ENV = "LUMI_SMOKE_DEVICE_TOKEN";
const DEVICE_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const UNAUTHORIZED_STATUS = 401;
const AUTHORIZED_STATUS = 200;
const RATE_LIMITED_STATUS = 429;
const JSON_CONTENT_TYPE = "application/json";
const NO_STORE_CACHE_CONTROL = "no-store";
const FIXED_FAILURE_MESSAGE = "Smoke failed.";
const FIXED_CONFIGURATION_MESSAGE = "Smoke configuration invalid.";

export type SmokeEnvironment = Readonly<Record<string, string | undefined>>;

export type SmokeFetch = (
  input: string,
  init?: RequestInit,
) => Promise<Response>;

export type SmokeWriter = (value: string) => void;

export type SmokeCheck = Readonly<{
  readonly scenario: "unauthorized" | "authorized" | "rate_limit";
  readonly statusOk: boolean;
  readonly categoryOk: boolean;
  readonly schemaOk: boolean;
}>;

export type SmokeReport = Readonly<{
  readonly ok: boolean;
  readonly checks: readonly SmokeCheck[];
}>;

export type SmokeOptions = Readonly<{
  readonly endpoint: string;
  readonly deviceToken: string;
  readonly fetch?: SmokeFetch;
  readonly now?: () => number;
}>;

export type SmokeCommandOptions = Readonly<{
  readonly fetch?: SmokeFetch;
  readonly now?: () => number;
  readonly writeStdout?: SmokeWriter;
  readonly writeStderr?: SmokeWriter;
}>;

export class SmokeConfigurationError extends Error {
  readonly code = "invalid_smoke_configuration" as const;

  constructor() {
    super(FIXED_CONFIGURATION_MESSAGE);
    this.name = "SmokeConfigurationError";
  }
}

type ResponseInspection = {
  readonly status: number;
  readonly contentTypeOk: boolean;
  readonly cacheControlOk: boolean;
  body: unknown;
};

type ErrorEnvelopeInspection = Readonly<{
  readonly categoryOk: boolean;
  readonly schemaOk: boolean;
}>;

function configurationError(): SmokeConfigurationError {
  return new SmokeConfigurationError();
}

function validateEndpoint(endpoint: string): string {
  if (typeof endpoint !== "string" || endpoint.trim().length === 0) {
    throw configurationError();
  }

  let parsed: URL;
  try {
    parsed = new URL(endpoint);
  } catch {
    throw configurationError();
  }

  if (
    parsed.protocol !== "https:" ||
    parsed.hostname.length === 0 ||
    parsed.username.length > 0 ||
    parsed.password.length > 0 ||
    parsed.search.length > 0 ||
    parsed.hash.length > 0
  ) {
    throw configurationError();
  }

  return parsed.href;
}

function validateDeviceToken(deviceToken: string): string {
  if (
    typeof deviceToken !== "string" ||
    !DEVICE_TOKEN_PATTERN.test(deviceToken)
  ) {
    throw configurationError();
  }

  const decoded = Buffer.from(deviceToken, "base64url");
  if (
    decoded.byteLength !== 32 ||
    decoded.toString("base64url") !== deviceToken
  ) {
    throw configurationError();
  }

  return deviceToken;
}

function headerMatches(
  response: Response,
  header: string,
  expected: string,
): boolean {
  return response.headers.get(header)?.trim().toLowerCase() === expected;
}

async function inspectResponse(response: Response): Promise<ResponseInspection> {
  let body: unknown;
  try {
    const text = await response.text();
    try {
      body = JSON.parse(text) as unknown;
    } catch {
      body = undefined;
    }
  } catch {
    body = undefined;
  }

  return {
    status: response.status,
    contentTypeOk: headerMatches(response, "content-type", JSON_CONTENT_TYPE),
    cacheControlOk: headerMatches(
      response,
      "cache-control",
      NO_STORE_CACHE_CONTROL,
    ),
    body,
  };
}

function hasOnlyKeys(
  record: Readonly<Record<string, unknown>>,
  keys: readonly string[],
): boolean {
  const actualKeys = Object.keys(record).sort();
  return (
    actualKeys.length === keys.length &&
    actualKeys.every((key, index) => key === [...keys].sort()[index])
  );
}

function inspectErrorEnvelope(
  response: ResponseInspection,
  expectedCode: "unauthorized" | "rate_limited",
): ErrorEnvelopeInspection {
  if (
    typeof response.body !== "object" ||
    response.body === null ||
    Array.isArray(response.body)
  ) {
    return { categoryOk: false, schemaOk: false };
  }

  const root = response.body as Record<string, unknown>;
  const error = root["error"];
  const hasValidError =
    typeof error === "object" &&
    error !== null &&
    !Array.isArray(error) &&
    hasOnlyKeys(error as Record<string, unknown>, ["code"]) &&
    (error as Record<string, unknown>)["code"] === expectedCode;

  return {
    categoryOk: hasValidError,
    schemaOk:
      response.contentTypeOk &&
      response.cacheControlOk &&
      hasOnlyKeys(root, ["error"]) &&
      hasValidError,
  };
}

function inspectSuccessEnvelope(
  response: ResponseInspection,
  now: number,
): boolean {
  if (
    typeof response.body !== "object" ||
    response.body === null ||
    Array.isArray(response.body)
  ) {
    return false;
  }

  const root = response.body as Record<string, unknown>;
  const value = root["value"];
  const expiresAt = root["expiresAt"];

  return (
    response.contentTypeOk &&
    response.cacheControlOk &&
    hasOnlyKeys(root, ["value", "expiresAt"]) &&
    typeof value === "string" &&
    value.trim().length > 0 &&
    typeof expiresAt === "number" &&
    Number.isFinite(expiresAt) &&
    expiresAt > now
  );
}

function check(
  scenario: SmokeCheck["scenario"],
  statusOk = false,
  categoryOk = false,
  schemaOk = false,
): SmokeCheck {
  return { scenario, statusOk, categoryOk, schemaOk };
}

function failedReport(
  unauthorized: SmokeCheck,
  authorized: SmokeCheck,
  rateLimit: SmokeCheck,
): SmokeReport {
  return {
    ok:
      unauthorized.statusOk &&
      unauthorized.categoryOk &&
      unauthorized.schemaOk &&
      authorized.statusOk &&
      authorized.categoryOk &&
      authorized.schemaOk &&
      rateLimit.statusOk &&
      rateLimit.categoryOk &&
      rateLimit.schemaOk,
    checks: [unauthorized, authorized, rateLimit],
  };
}

async function performRequest(
  endpoint: string,
  authorization: string | undefined,
  fetchImplementation: SmokeFetch,
): Promise<ResponseInspection | undefined> {
  const headers = new Headers({ Accept: JSON_CONTENT_TYPE });
  if (authorization !== undefined) {
    headers.set("Authorization", authorization);
  }

  try {
    const response = await fetchImplementation(endpoint, {
      method: "POST",
      headers,
    });
    return await inspectResponse(response);
  } catch {
    return undefined;
  }
}

export async function runSmoke(options: SmokeOptions): Promise<SmokeReport> {
  const endpoint = validateEndpoint(options.endpoint);
  const deviceToken = validateDeviceToken(options.deviceToken);
  const fetchImplementation = options.fetch ?? globalThis.fetch.bind(globalThis);
  const now = options.now ?? (() => Math.floor(Date.now() / 1000));

  const unauthorizedResponse = await performRequest(
    endpoint,
    undefined,
    fetchImplementation,
  );
  if (unauthorizedResponse === undefined) {
    return failedReport(
      check("unauthorized"),
      check("authorized"),
      check("rate_limit"),
    );
  }

  const unauthorizedEnvelope = inspectErrorEnvelope(
    unauthorizedResponse,
    "unauthorized",
  );
  unauthorizedResponse.body = undefined;
  const unauthorizedCheck = check(
    "unauthorized",
    unauthorizedResponse.status === UNAUTHORIZED_STATUS,
    unauthorizedEnvelope.categoryOk,
    unauthorizedEnvelope.schemaOk,
  );
  if (
    !unauthorizedCheck.statusOk ||
    !unauthorizedCheck.categoryOk ||
    !unauthorizedCheck.schemaOk
  ) {
    return failedReport(
      unauthorizedCheck,
      check("authorized"),
      check("rate_limit"),
    );
  }

  const authorization = `Bearer ${deviceToken}`;
  let authorizedRequestCount = 0;
  const firstAuthorizedResponse = await performRequest(
    endpoint,
    authorization,
    fetchImplementation,
  );
  authorizedRequestCount += 1;
  if (firstAuthorizedResponse === undefined) {
    return failedReport(
      unauthorizedCheck,
      check("authorized"),
      check("rate_limit"),
    );
  }

  const authorizedSchemaOk = inspectSuccessEnvelope(
    firstAuthorizedResponse,
    now(),
  );
  firstAuthorizedResponse.body = undefined;
  const authorizedCheck = check(
    "authorized",
    firstAuthorizedResponse.status === AUTHORIZED_STATUS,
    firstAuthorizedResponse.status === AUTHORIZED_STATUS && authorizedSchemaOk,
    authorizedSchemaOk,
  );
  if (
    !authorizedCheck.statusOk ||
    !authorizedCheck.categoryOk ||
    !authorizedCheck.schemaOk
  ) {
    return failedReport(
      unauthorizedCheck,
      authorizedCheck,
      check("rate_limit"),
    );
  }

  while (authorizedRequestCount < MAX_AUTHORIZED_REQUESTS) {
    const response = await performRequest(
      endpoint,
      authorization,
      fetchImplementation,
    );
    authorizedRequestCount += 1;

    if (response === undefined) {
      return failedReport(
        unauthorizedCheck,
        authorizedCheck,
        check("rate_limit"),
      );
    }

    if (response.status === RATE_LIMITED_STATUS) {
      const envelope = inspectErrorEnvelope(response, "rate_limited");
      response.body = undefined;
      const rateLimitCheck = check(
        "rate_limit",
        true,
        envelope.categoryOk,
        envelope.schemaOk,
      );
      return failedReport(unauthorizedCheck, authorizedCheck, rateLimitCheck);
    }

    if (
      response.status !== AUTHORIZED_STATUS ||
      !inspectSuccessEnvelope(response, now())
    ) {
      response.body = undefined;
      return failedReport(
        unauthorizedCheck,
        authorizedCheck,
        check("rate_limit"),
      );
    }

    response.body = undefined;
  }

  return failedReport(
    unauthorizedCheck,
    authorizedCheck,
    check("rate_limit"),
  );
}

function environmentValue(
  environment: SmokeEnvironment,
  key: string,
): string | undefined {
  const value = environment[key];
  return typeof value === "string" && value.trim().length > 0
    ? value.trim()
    : undefined;
}

export async function runSmokeCommand(
  environment: SmokeEnvironment = process.env,
  options: SmokeCommandOptions = {},
): Promise<number> {
  const writeStdout = options.writeStdout ?? ((value: string) => process.stdout.write(value));
  const writeStderr = options.writeStderr ?? ((value: string) => process.stderr.write(value));

  const endpoint = environmentValue(environment, ENDPOINT_ENV);
  const deviceToken = environmentValue(environment, DEVICE_TOKEN_ENV);
  if (endpoint === undefined || deviceToken === undefined) {
    writeStderr(`${FIXED_CONFIGURATION_MESSAGE}\n`);
    return 1;
  }

  try {
    const report = await runSmoke({
      endpoint,
      deviceToken,
      ...(options.fetch === undefined ? {} : { fetch: options.fetch }),
      ...(options.now === undefined ? {} : { now: options.now }),
    });
    writeStdout(`${JSON.stringify(report)}\n`);
    return report.ok ? 0 : 1;
  } catch {
    writeStderr(`${FIXED_FAILURE_MESSAGE}\n`);
    return 1;
  }
}

function invokedAsScript(): boolean {
  const entryPoint = process.argv[1];
  return (
    entryPoint !== undefined &&
    pathToFileURL(resolve(entryPoint)).href === import.meta.url
  );
}

if (invokedAsScript()) {
  process.exitCode = await runSmokeCommand();
}
