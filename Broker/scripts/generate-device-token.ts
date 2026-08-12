import { createHash, randomBytes as secureRandomBytes } from "node:crypto";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const DEVICE_TOKEN_BYTE_LENGTH = 32;

export type RandomBytes = (size: number) => Uint8Array;

export type TextWriter = (value: string) => void;

export type GeneratedDeviceToken = Readonly<{
  readonly token: string;
  readonly digest: string;
}>;

export class DeviceTokenGenerationError extends Error {
  readonly code = "invalid_randomness" as const;

  constructor() {
    super("Unable to generate device token");
    this.name = "DeviceTokenGenerationError";
  }
}

function generationError(): DeviceTokenGenerationError {
  return new DeviceTokenGenerationError();
}

export function generateDeviceToken(
  randomBytes: RandomBytes = secureRandomBytes,
): GeneratedDeviceToken {
  let bytes: Uint8Array;

  // `randomBytes(32)` is Node's synchronous CSPRNG API.
  // Source: https://nodejs.org/api/crypto.html#cryptorandombytessize-callback
  try {
    bytes = randomBytes(DEVICE_TOKEN_BYTE_LENGTH);
  } catch {
    throw generationError();
  }

  if (
    !(bytes instanceof Uint8Array) ||
    bytes.byteLength !== DEVICE_TOKEN_BYTE_LENGTH
  ) {
    throw generationError();
  }

  try {
    const token =
      // Node's base64url encoding is RFC 4648 URL-safe and omits padding.
      // Source: https://nodejs.org/api/buffer.html#buffers-and-character-encodings
      Buffer.from(bytes).toString("base64url");
    const digest =
      // The broker hashes the UTF-8 token text, not the random bytes.
      // Source: https://nodejs.org/api/crypto.html#hashdigestencoding
      createHash("sha256").update(token, "utf8").digest("hex");

    return Object.freeze({ token, digest });
  } catch {
    throw generationError();
  }
}

export function formatGeneratedDeviceToken(
  generated: GeneratedDeviceToken,
): string {
  return `token=${generated.token}\nsha256=${generated.digest}\n`;
}

export function runDeviceTokenCommand(
  randomBytes: RandomBytes = secureRandomBytes,
  writeStdout: TextWriter = (value) => {
    process.stdout.write(value);
  },
  writeStderr: TextWriter = (value) => {
    process.stderr.write(value);
  },
): number {
  try {
    const generated = generateDeviceToken(randomBytes);
    // Build the complete payload before writing, so no credential is emitted
    // when generation or validation fails.
    writeStdout(formatGeneratedDeviceToken(generated));
    return 0;
  } catch {
    writeStderr("Unable to generate device token.\n");
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
  process.exitCode = runDeviceTokenCommand();
}
