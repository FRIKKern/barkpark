import "server-only";
import { Agent, fetch as keepAliveFetch } from "undici";
import { PUBLIC_API_URL, READ_TOKEN } from "./bp-env";

/**
 * Persistent connection pool to the Barkpark API. Without it, every upstream
 * call (every search) pays a fresh TLS handshake — the dominant latency on the
 * Vercel→Hetzner hop (~150–190ms of pure overhead). We use undici's OWN fetch +
 * Agent rather than the global fetch because Node's built-in fetch keeps its
 * undici dispatcher internal/unreachable, so a global keep-alive setting won't
 * stick. Idle sockets stay warm across a typing burst within a serverless
 * instance; undici transparently re-establishes if the server closed one.
 */
const bpDispatcher = new Agent({
  keepAliveTimeout: 30_000,
  keepAliveMaxTimeout: 600_000,
  connections: 64,
});

/**
 * The one place server-side routes/libs talk to the Barkpark API over a raw
 * `fetch`. Centralises the resilience that every upstream call needs:
 *
 *   - an `AbortController` timeout (a hung API never pins a serverless slot),
 *   - a short retry-with-backoff over the API-restart window (a `make deploy`
 *     bounces the BEAM for ~30s, during which the LB/socket layer may accept the
 *     connection but Phoenix answers an empty body or an Nginx 502 HTML page),
 *   - an `res.ok` guard BEFORE the body is ever consumed, and
 *   - defensive `text()` → `JSON.parse` (never bare `res.json()` on a body that
 *     might be empty/HTML — that is what throws the cryptic
 *     "Unexpected end of JSON input" the admin panel used to surface).
 *
 * On failure it throws a structured `BpUpstreamError` carrying the upstream HTTP
 * status (0 for network/timeout) and a human message — callers translate that
 * into whatever envelope their contract owns.
 *
 * Token + base URL come from the server-only env vars (BARKPARK_TOKEN is
 * intentionally NOT `NEXT_PUBLIC_*` → never bundled to the browser). Names are
 * resolved in `./bp-env` (canonical first, legacy fallback).
 */

export const API_URL = PUBLIC_API_URL;
const TOKEN = READ_TOKEN;

/** Per-fetch timeout. Override per host via BARKPARK_FETCH_TIMEOUT_MS. */
const TIMEOUT_MS = Number(process.env.BARKPARK_FETCH_TIMEOUT_MS) || 15_000;
/** Retries cover the API-restart window — total attempts = RETRIES + 1. */
const RETRIES = 2;
/** Backoff before retry N (1-indexed): ~1s, ~2s. */
const BACKOFF_MS = [1_000, 2_000];
/** Upstream statuses that mean "API is bouncing, try again", not "real error". */
const TRANSIENT_STATUS = new Set([502, 503, 504]);

/** Bearer header from the server-only token, or `{}` when unset (anonymous). */
export function authHeaders(): HeadersInit {
  return TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {};
}

/**
 * Structured upstream failure — `status` is 0 for network/timeout errors.
 * `definitive` marks a deliberate upstream answer (a parseable `{error:…}` body,
 * e.g. reindex_failed or a 401) as opposed to an infra blip (bodyless/HTML 5xx,
 * restart, timeout): definitive errors are NOT retried and carry their real
 * message instead of the generic "restarting" one.
 */
export class BpUpstreamError extends Error {
  readonly status: number;
  readonly detail: string;
  readonly definitive: boolean;
  constructor(status: number, message: string, detail = "", definitive = false) {
    super(message);
    this.name = "BpUpstreamError";
    this.status = status;
    this.detail = detail;
    this.definitive = definitive;
  }
}

/** Pull a human message out of an API `{error: string | {message,code}}` body. */
function errorEnvelopeMessage(body: string): string | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || !("error" in parsed)) return null;
  const e = (parsed as { error: unknown }).error;
  if (typeof e === "string" && e.trim() !== "") return e;
  if (e && typeof e === "object") {
    const o = e as { message?: unknown; code?: unknown };
    if (typeof o.message === "string" && o.message.trim() !== "") return o.message;
    if (typeof o.code === "string" && o.code.trim() !== "") return o.code;
  }
  return null;
}

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

/** Merge the auth header into caller-supplied headers (caller wins on clash). */
function withAuth(init?: RequestInit): RequestInit {
  return {
    cache: "no-store",
    ...init,
    headers: { ...authHeaders(), ...(init?.headers ?? {}) },
  };
}

/** One attempt: timeout-guarded fetch + `res.ok` guard + defensive JSON parse. */
async function attempt(url: string, init: RequestInit): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  let res: Awaited<ReturnType<typeof keepAliveFetch>>;
  try {
    // undici fetch + the shared keep-alive Agent → reuse the TLS connection.
    res = await keepAliveFetch(url, {
      method: init.method,
      headers: init.headers as Record<string, string> | undefined,
      body: init.body as string | undefined,
      signal: controller.signal,
      dispatcher: bpDispatcher,
    });
  } catch (e) {
    // Network error or AbortController timeout — both surface as status 0.
    const msg = (e as Error)?.name === "AbortError" ? "request timed out" : (e as Error).message;
    throw new BpUpstreamError(0, msg);
  } finally {
    clearTimeout(timer);
  }

  if (!res.ok) {
    const detail = await res.text().catch(() => "(unreadable body)");
    // A non-OK response carrying a parseable JSON {error:…} envelope is a
    // DELIBERATE upstream answer (reindex_failed, 401 unauthorized) — surface its
    // real message and mark it definitive so it is NOT retried. A bodyless/HTML
    // 5xx (LB 502, restart) has no envelope → stays a retryable transient.
    const enveloped = errorEnvelopeMessage(detail);
    if (enveloped) {
      throw new BpUpstreamError(res.status, enveloped, detail.slice(0, 200), true);
    }
    throw new BpUpstreamError(
      res.status,
      `upstream ${res.status}`,
      detail.slice(0, 200),
    );
  }

  // Read as text first, then parse — an empty/HTML body must not throw a bare
  // SyntaxError; it becomes a structured non-JSON error instead.
  const text = await res.text();
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new BpUpstreamError(
      502,
      "upstream returned non-JSON",
      text.slice(0, 200),
    );
  }
}

/** True when an error is worth one more attempt (network/timeout or 5xx-ish).
 * A definitive error (the upstream answered with a real {error:…}) is never
 * retried — retrying a business failure just wastes the restart-window budget. */
export function isTransient(err: unknown): boolean {
  if (!(err instanceof BpUpstreamError)) return false;
  if (err.definitive) return false;
  return err.status === 0 || TRANSIENT_STATUS.has(err.status);
}

/**
 * Resilient JSON fetch against the Barkpark API. Bakes in auth + no-store,
 * retries transient failures across the restart window, and throws a
 * `BpUpstreamError` (never a raw JSON-parse SyntaxError) on hard failure.
 */
export async function bpFetchJson(
  url: string,
  init?: RequestInit,
): Promise<unknown> {
  const merged = withAuth(init);
  let lastErr: unknown;
  for (let i = 0; i <= RETRIES; i++) {
    try {
      return await attempt(url, merged);
    } catch (err) {
      lastErr = err;
      if (i < RETRIES && isTransient(err)) {
        await sleep(BACKOFF_MS[i] ?? 2_000);
        continue;
      }
      throw err;
    }
  }
  throw lastErr;
}

/** Friendly message for the API-restart case, else the structured message. */
export function humanUpstreamMessage(err: unknown): string {
  if (err instanceof BpUpstreamError) {
    // A definitive upstream error already carries its real, specific message.
    if (err.definitive) return err.message;
    if (err.status === 0 || TRANSIENT_STATUS.has(err.status)) {
      return "search API is restarting, try again in a moment";
    }
    return err.message;
  }
  return err instanceof Error ? err.message : String(err);
}
