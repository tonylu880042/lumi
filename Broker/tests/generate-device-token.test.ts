import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  DEVICE_TOKEN_BYTE_LENGTH,
  DeviceTokenGenerationError,
  formatGeneratedDeviceToken,
  generateDeviceToken,
  runDeviceTokenCommand,
} from "../scripts/generate-device-token.ts";

const fixedBytes = Buffer.from(
  "00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f",
  "hex",
);

test("token generator produces a canonical token and matching digest", () => {
  let requestedLength: number | undefined;

  const generated = generateDeviceToken((size) => {
    requestedLength = size;
    return Buffer.from(fixedBytes);
  });

  assert.equal(requestedLength, DEVICE_TOKEN_BYTE_LENGTH);
  assert.equal(generated.token, fixedBytes.toString("base64url"));
  assert.equal(generated.token.length, 43);
  assert.match(generated.token, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(generated.digest.length, 64);
  assert.match(generated.digest, /^[0-9a-f]{64}$/);
  assert.equal(
    generated.digest,
    createHash("sha256").update(generated.token, "utf8").digest("hex"),
  );
  assert.notEqual(
    generated.digest,
    createHash("sha256").update(fixedBytes).digest("hex"),
  );
});

test("token generator rejects randomness that is not exactly 32 bytes", () => {
  for (const bytes of [Buffer.alloc(0), Buffer.alloc(31), Buffer.alloc(33)]) {
    assert.throws(
      () => generateDeviceToken(() => bytes),
      (error: unknown) => {
        assert.ok(error instanceof DeviceTokenGenerationError);
        assert.equal(error.code, "invalid_randomness");
        assert.equal(error.message, "Unable to generate device token");
        if (bytes.length > 0) {
          assert.equal(
            JSON.stringify(error).includes(bytes.toString("base64url")),
            false,
          );
        }
        assert.equal(Object.prototype.hasOwnProperty.call(error, "bytes"), false);
        return true;
      },
    );
  }
});

test("token generator replaces random-source failures with a fixed error", () => {
  const marker = "random-source-marker";

  assert.throws(
    () =>
      generateDeviceToken(() => {
        throw new Error(marker);
      }),
    (error: unknown) => {
      assert.ok(error instanceof DeviceTokenGenerationError);
      assert.equal(error.message, "Unable to generate device token");
      assert.equal(String(error).includes(marker), false);
      assert.equal(JSON.stringify(error).includes(marker), false);
      return true;
    },
  );
});

test("token generator output contains each credential exactly once", () => {
  const generated = {
    token: "A".repeat(43),
    digest: "b".repeat(64),
  } as const;

  const output = formatGeneratedDeviceToken(generated);

  assert.equal(
    output,
    `token=${generated.token}\nsha256=${generated.digest}\n`,
  );
  assert.equal(output.split(generated.token).length - 1, 1);
  assert.equal(output.split(generated.digest).length - 1, 1);
});

test("token generator operator runner emits both lines only after successful generation", () => {
  const stdout: string[] = [];
  const stderr: string[] = [];
  const exitCode = runDeviceTokenCommand(
    () => Buffer.from(fixedBytes),
    (value) => stdout.push(value),
    (value) => stderr.push(value),
  );
  const generated = generateDeviceToken(() => Buffer.from(fixedBytes));
  const output = stdout.join("");

  assert.equal(exitCode, 0);
  assert.deepEqual(stdout, [formatGeneratedDeviceToken(generated)]);
  assert.deepEqual(stderr, []);
  assert.equal(output, formatGeneratedDeviceToken(generated));
  assert.equal(output.split(generated.token).length - 1, 1);
  assert.equal(output.split(generated.digest).length - 1, 1);
});

test("token generator operator runner emits no partial credential when generation fails", () => {
  const marker = "operator-random-source-marker";
  const stdout: string[] = [];
  const stderr: string[] = [];

  const exitCode = runDeviceTokenCommand(
    () => {
      throw new Error(marker);
    },
    (value) => stdout.push(value),
    (value) => stderr.push(value),
  );

  assert.equal(exitCode, 1);
  assert.deepEqual(stdout, []);
  assert.deepEqual(stderr, ["Unable to generate device token.\n"]);
  assert.equal(stderr.join("").includes(marker), false);
});
