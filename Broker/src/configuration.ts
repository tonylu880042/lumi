const OPENAI_API_KEY_ENV = "OPENAI_API_KEY";
const DEVICE_TOKEN_ALLOWLIST_ENV = "LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST";
const RATE_LIMIT_ID_ENV = "LUMI_RATE_LIMIT_ID";
const LOWERCASE_SHA256_DIGEST = /^[0-9a-f]{64}$/;

export type BrokerEnvironment = Readonly<Record<string, string | undefined>>;

export type BrokerConfiguration = Readonly<{
  readonly openAIKey: string;
  readonly deviceTokenDigests: readonly string[];
  readonly rateLimitId: string;
}>;

export class BrokerConfigurationError extends Error {
  readonly code = "configuration_unavailable" as const;

  constructor() {
    super("Broker configuration unavailable");
    this.name = "BrokerConfigurationError";
  }
}

function requiredValue(value: string | undefined): string {
  if (typeof value !== "string") {
    throw new BrokerConfigurationError();
  }

  const trimmedValue = value.trim();
  if (trimmedValue.length === 0) {
    throw new BrokerConfigurationError();
  }

  return trimmedValue;
}

function parseDeviceTokenDigests(value: string | undefined): readonly string[] {
  const entries = requiredValue(value).split(",").map((entry) => entry.trim());
  const seen = new Set<string>();

  for (const entry of entries) {
    if (!LOWERCASE_SHA256_DIGEST.test(entry) || seen.has(entry)) {
      throw new BrokerConfigurationError();
    }

    seen.add(entry);
  }

  return Object.freeze(entries);
}

export function parseBrokerConfiguration(
  environment: BrokerEnvironment,
): BrokerConfiguration {
  const configuration = {
    openAIKey: requiredValue(environment[OPENAI_API_KEY_ENV]),
    deviceTokenDigests: parseDeviceTokenDigests(
      environment[DEVICE_TOKEN_ALLOWLIST_ENV],
    ),
    rateLimitId: requiredValue(environment[RATE_LIMIT_ID_ENV]),
  };

  return Object.freeze(configuration);
}
