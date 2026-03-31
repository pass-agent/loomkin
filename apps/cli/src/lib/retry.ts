import { ApiError } from "./api.js";

export interface RetryOptions {
  maxAttempts?: number;
  baseDelayMs?: number;
  maxDelayMs?: number;
  onRetry?: (attempt: number, error: Error) => void;
}

function isRetryable(err: unknown): boolean {
  if (err instanceof TypeError && err.message.toLowerCase().includes("fetch")) {
    return true;
  }
  if (err instanceof ApiError) {
    // Rate limit and server-side transient errors
    return err.status === 429 || err.status === 502 || err.status === 503 || err.status === 504;
  }
  return false;
}

function getRetryAfterMs(err: unknown): number | null {
  // ApiError does not expose headers, so we rely on default backoff for 429.
  // If the server returns a Retry-After header it would need to be surfaced
  // separately — for now return null and let backoff handle it.
  return null;
}

async function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function withRetry<T>(
  fn: () => Promise<T>,
  options: RetryOptions = {},
): Promise<T> {
  const maxAttempts = options.maxAttempts ?? 3;
  const baseDelayMs = options.baseDelayMs ?? 500;
  const maxDelayMs = options.maxDelayMs ?? 10_000;
  const onRetry = options.onRetry;

  let lastError: Error = new Error("Unknown error");

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err instanceof Error ? err : new Error(String(err));

      if (!isRetryable(err) || attempt === maxAttempts) {
        throw lastError;
      }

      const retryAfterMs = getRetryAfterMs(err);
      const exponentialMs = baseDelayMs * Math.pow(2, attempt - 1);
      // Add up to 25% jitter to avoid thundering herd
      const jitter = Math.random() * exponentialMs * 0.25;
      const waitMs = Math.min(retryAfterMs ?? exponentialMs + jitter, maxDelayMs);

      onRetry?.(attempt, lastError);
      await delay(waitMs);
    }
  }

  throw lastError;
}
