import "server-only";
import { Agent, fetch as keepAliveFetch } from "undici";
import { PUBLIC_API_URL, READ_TOKEN } from "./bp-env";
import { parseRetryAfterMs, retryDelayMs } from "./retry-after";

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
 *     EXTENDED by the upstream's own `Retry-After` when it sends one — the
 *     fixed ladder is a guess about a restart, and a server that sheds
 *     deliberately (`/v1/graph`'s concurrency cap) knows better than we do,
 *   - a ceiling on that header so it stays advice and not a hostage,
 *   - an `res.ok` guard BEFORE the body is ever consumed, and
 *   - defensive `text()` → `JSON.parse` (never bare `res.json()` on a body that
 *     might be empty/HTML — that is what throws the cryptic
 *     "Unexpected end of JSON input" the admin panel used to surface).
 *
 * On failure it throws a structured `BpUpstreamError` carrying the upstream HTTP
 * status (0 for network/timeout), a human message, and the envelope's
 * machine-readable `code` when the body carried one — callers translate that
 * into whatever envelope their contract owns.
 *
 * Token + base URL come from the server-only env vars (BARKPARK_TOKEN is
 * intentionally NOT `NEXT_PUBLIC_*` → never bundled to the browser). Names are
 * resolved in `./bp-env` (canonical first, legacy fallback).
 */

export const API_URL = PUBLIC_API_URL;
const TOKEN = READ_TOKEN;

/**
 * THE BUDGET BELOW IS A COMPILED DEFAULT ON PURPOSE.
 *
 * On a MANAGED build (the control plane's deploy runner) nothing sets
 * BARKPARK_FETCH_TIMEOUT_MS, and nothing can: the deploy request's env map is a
 * closed 7-key literal (`cloud/lib/barkpark_cloud/sites/deploy.ex` `env: %{…}`),
 * the template contract mirrors it (`cloud/lib/barkpark_cloud/templates.ex`
 * `@env_common ++ ~w(BARKPARK_DOC_TYPE)`), and the two shell allow-lists the box
 * enforces — `BUILD_ALLOW` (10 keys) and `site-deploy-node.sh`'s `RUNTIME_ALLOW`
 * (6 keys) in `deploy/lib/site-deploy-common.sh` — do not carry it either. The
 * env var is reachable only for a self-hosted deploy that sets it by hand
 * (docs/ops/vercel-dns-connect.md). So a cure for a managed build has to live in
 * these constants; an env var would be a cure nobody receives.
 *
 * THE OUTAGE FAMILY THIS SIZES FOR. The old ladder was 3 attempts with ~1s/~2s
 * of backoff — a ~3s wait, written for a `make deploy` BEAM bounce. The observed
 * DOC_ID_EMPTY failures are content-API unavailability lasting MINUTES (status 0
 * = this file's own AbortController timeout, plus upstream 503s), which a 3s
 * ladder cannot outlast. The ladder is widened to 6 attempts / ~30s of backoff,
 * and — because a build that hangs is worse than a build that fails — capped by
 * a hard TOTAL_BUDGET_MS wall clock so the worst case is bounded, not additive.
 *
 * A NOTE ON FRAMING, because this file is cited in the incident write-ups: the
 * deploy HEALTH gate is fail-CLOSED and CORRECT. It never took a serving site
 * down; the marker really was empty and the candidate build really did render
 * zero content. The failure class is misNAMED, not illusory — the cure belongs
 * here, in the fetch that gave up too early, not in the gate that caught it.
 */
/** Per-fetch timeout. Override per host via BARKPARK_FETCH_TIMEOUT_MS
 * (self-hosted only — see above: a managed build never receives it). */
const TIMEOUT_MS = Number(process.env.BARKPARK_FETCH_TIMEOUT_MS) || 15_000;
/** Retries cover a minutes-long upstream outage — total attempts = RETRIES + 1. */
const RETRIES = 5;
/** Backoff before retry N (1-indexed): ~1s, ~2s, ~4s, ~8s, ~15s — 30s in total. */
const BACKOFF_MS = [1_000, 2_000, 4_000, 8_000, 15_000];
/**
 * Hard wall-clock ceiling on ONE bpFetchJson call, backoff and attempts
 * together. Without it the widened ladder is 6 x TIMEOUT_MS + 30s ≈ 2 minutes of
 * additive worst case per call, and a page with several upstream reads
 * multiplies that into a build that looks hung. With it, a call that is going to
 * fail fails inside the budget: the loop refuses to START an attempt or SLEEP a
 * backoff it cannot finish before the wall. Self-hosted override:
 * BARKPARK_FETCH_TOTAL_BUDGET_MS.
 */
const TOTAL_BUDGET_MS =
  Number(process.env.BARKPARK_FETCH_TOTAL_BUDGET_MS) || 45_000;

/** The compiled budget, exported so a spec can assert the arithmetic (that the
 * ladder outlasts the observed outage AND stays bounded) without re-deriving
 * the numbers in a test where they could drift out of sync with these. */
export const RETRY_BUDGET = {
  TIMEOUT_MS,
  RETRIES,
  BACKOFF_MS,
  TOTAL_BUDGET_MS,
} as const;
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
 *
 * `code` carries the envelope's machine-readable code so a caller can branch on
 * the FAILURE rather than string-matching a human sentence; `retryAfterMs`
 * carries the upstream's own `Retry-After`, when it sent one, so the retry loop
 * can wait as long as the server said instead of guessing.
 */
export class BpUpstreamError extends Error {
  readonly status: number;
  readonly detail: string;
  readonly definitive: boolean;
  /** Machine-readable error code from the envelope's `{error:{code,message}}`
   * shape, when the upstream body carried one — undefined for infra blips
   * (bodyless/HTML 5xx) that never reached a structured envelope. Lets
   * callers branch on the specific failure instead of only the HTTP status. */
  readonly code?: string;
  /** Upstream `Retry-After`, in ms — `undefined` when the server sent none. */
  readonly retryAfterMs?: number;
  constructor(
    status: number,
    message: string,
    detail = "",
    definitive = false,
    code?: string,
    retryAfterMs?: number,
  ) {
    super(message);
    this.name = "BpUpstreamError";
    this.status = status;
    this.detail = detail;
    this.definitive = definitive;
    this.code = code;
    if (retryAfterMs !== undefined) this.retryAfterMs = retryAfterMs;
  }
}

/** Pull a human message + machine code out of an API
 * `{error: string | {message,code}}` body.
 *
 * The code is lifted BEFORE the message fallback below consumes it. Reading it
 * only as a fallback (the shape this file used to have) means an envelope
 * carrying BOTH a message and a code surfaces the message and DROPS the code,
 * leaving a caller nothing to branch on but the sentence. The fallback itself
 * is unchanged: with no human message the code is still the best display
 * string there is — it is just no longer the ONLY thing it can be. */
function errorEnvelope(body: string): { message: string; code?: string } | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || !("error" in parsed)) return null;
  const e = (parsed as { error: unknown }).error;
  if (typeof e === "string" && e.trim() !== "") return { message: e };
  if (e && typeof e === "object") {
    const o = e as { message?: unknown; code?: unknown };
    const code = typeof o.code === "string" && o.code.trim() !== "" ? o.code : undefined;
    if (typeof o.message === "string" && o.message.trim() !== "") {
      return { message: o.message, code };
    }
    if (code) return { message: code, code };
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
    // Read the server's own backoff instruction BEFORE classifying: a shed that
    // says "come back in 12s" is the only party that knows how long its
    // capacity is committed for (/v1/graph holds a slot for a whole derivation).
    const retryAfterMs = parseRetryAfterMs(res.headers.get("retry-after"));
    // A non-OK response carrying a parseable JSON {error:…} envelope is a
    // DELIBERATE upstream answer (reindex_failed, 401 unauthorized) — surface its
    // real message and mark it definitive so it is NOT retried. A bodyless/HTML
    // 5xx (LB 502, restart) has no envelope → stays a retryable transient.
    const enveloped = errorEnvelope(detail);
    if (enveloped) {
      throw new BpUpstreamError(
        res.status,
        enveloped.message,
        detail.slice(0, 200),
        true,
        enveloped.code,
        retryAfterMs,
      );
    }
    throw new BpUpstreamError(
      res.status,
      `upstream ${res.status}`,
      detail.slice(0, 200),
      false,
      undefined,
      retryAfterMs,
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
  const deadline = Date.now() + TOTAL_BUDGET_MS;
  let lastErr: unknown;
  for (let i = 0; i <= RETRIES; i++) {
    try {
      return await attempt(url, merged);
    } catch (err) {
      lastErr = err;
      if (i < RETRIES && isTransient(err)) {
        const scheduled = BACKOFF_MS[i] ?? BACKOFF_MS[BACKOFF_MS.length - 1];
        const advised =
          err instanceof BpUpstreamError ? err.retryAfterMs : undefined;
        const delay = retryDelayMs(scheduled, advised);
        // The wall, not the ladder, is what bounds this call. Sleeping a backoff
        // we cannot follow with an attempt just burns the budget in silence, so
        // give up NOW and surface the last real upstream error.
        if (Date.now() + delay >= deadline) throw err;
        await sleep(delay);
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
