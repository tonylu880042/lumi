import assert from "node:assert/strict";
import test from "node:test";

import {
  BrokerConfigurationError,
  parseBrokerConfiguration,
} from "../src/configuration.ts";

const firstDigest = "a".repeat(64);
const secondDigest = "b".repeat(64);
const marker = "marker-that-must-not-escape";

function validEnvironment(): Record<string, string | undefined> {
  return {
    OPENAI_API_KEY: "  openai-placeholder  ",
    LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST: ` ${firstDigest},${secondDigest} `,
    LUMI_RATE_LIMIT_ID: "  lumi-preview-limit  ",
  };
}

function assertConfigurationError(action: () => unknown): void {
  assert.throws(action, (error: unknown) => {
    assert.ok(error instanceof BrokerConfigurationError);
    assert.equal(error.code, "configuration_unavailable");
    assert.equal(error.message, "Broker configuration unavailable");
    assert.equal(String(error).includes(marker), false);
    assert.equal(JSON.stringify(error).includes(marker), false);
    assert.equal(Object.prototype.hasOwnProperty.call(error, "input"), false);
    return true;
  });
}

test("configuration accepts trimmed values and preserves digest order", () => {
  const environment = validEnvironment();

  const configuration = parseBrokerConfiguration(environment);

  assert.deepEqual(configuration, {
    openAIKey: "openai-placeholder",
    deviceTokenDigests: [firstDigest, secondDigest],
    rateLimitId: "lumi-preview-limit",
  });
  assert.equal(Object.isFrozen(configuration.deviceTokenDigests), true);
  assert.equal(Object.isFrozen(configuration), true);
});

test("configuration does not retain the supplied environment object", () => {
  const environment = validEnvironment();
  const configuration = parseBrokerConfiguration(environment);

  environment.OPENAI_API_KEY = "changed-after-parse";
  environment.LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST = secondDigest;
  environment.LUMI_RATE_LIMIT_ID = "changed-after-parse";

  assert.equal(configuration.openAIKey, "openai-placeholder");
  assert.deepEqual(configuration.deviceTokenDigests, [firstDigest, secondDigest]);
  assert.equal(configuration.rateLimitId, "lumi-preview-limit");
});

test("configuration rejects missing or blank required values", () => {
  for (const key of [
    "OPENAI_API_KEY",
    "LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST",
    "LUMI_RATE_LIMIT_ID",
  ]) {
    const environment = validEnvironment();
    delete environment[key];
    assertConfigurationError(() => parseBrokerConfiguration(environment));

    environment[key] = "   ";
    assertConfigurationError(() => parseBrokerConfiguration(environment));
  }
});

test("configuration rejects empty allowlist entries", () => {
  for (const allowlist of [
    `,${firstDigest}`,
    `${firstDigest},`,
    `${firstDigest}, ,${secondDigest}`,
    "",
    "   ",
  ]) {
    const environment = validEnvironment();
    environment.LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST = allowlist;
    assertConfigurationError(() => parseBrokerConfiguration(environment));
  }
});

test("configuration rejects duplicate, uppercase, and malformed digests", () => {
  const invalidAllowlists = [
    `${firstDigest},${firstDigest}`,
    `${firstDigest.toUpperCase()}`,
    `${firstDigest.slice(0, 63)}`,
    `${firstDigest}g`,
    `-${firstDigest.slice(1)}`,
  ];

  for (const allowlist of invalidAllowlists) {
    const environment = validEnvironment();
    environment.LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST = allowlist;
    assertConfigurationError(() => parseBrokerConfiguration(environment));
  }
});

test("configuration errors never expose supplied markers", () => {
  const environment = {
    OPENAI_API_KEY: marker,
    LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST: marker,
    LUMI_RATE_LIMIT_ID: marker,
  };

  assertConfigurationError(() => parseBrokerConfiguration(environment));
});
