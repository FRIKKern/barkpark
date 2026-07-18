/**
 * The inbound webhook transport (charter D39) — ONE generic, fail-closed seam
 * for every webhook channel.
 *
 * `node:http` + the global `Request`/`Response` only. No express, no fastify: the
 * Chat SDK's adapters already speak WHATWG `Request -> Response`
 * (`Adapter.handleWebhook(request, options)`), so a framework would add a
 * dependency, a second router and a second body parser to translate a shape we
 * already have.
 *
 * THE REQUEST ORDER IS THE SECURITY MODEL:
 *
 *   parse the route (no body read)
 *     -> installs.lookupInstall(provider, installKey)   // fail-closed, D29
 *        -> null                    => opaque 404
 *     -> mounts.handlerFor(INSTALL ROW)                 // D39 keystone
 *        -> undefined               => the SAME opaque 404 (never an oracle)
 *     -> buffer the body ONCE
 *     -> rebuild a WHATWG Request from those exact bytes
 *     -> that install's OWN chat.webhooks[provider](request, { waitUntil })
 *
 * `handlerFor` takes the ROW, so a handler cannot be reached without having
 * passed the tenant lookup: cross-tenant routing is unrepresentable, not merely
 * untaken (see `mounts.ts`).
 *
 * Six rules that each cost a verifier real time:
 *
 * 1. Drive `chat.webhooks[provider]`, NEVER `adapter.handleWebhook` — an
 *    uninitialized adapter (Teams) answers 500 `{"error":"No handler registered"}`;
 *    `chat.webhooks` auto-initializes.
 * 2. `waitUntil` is MANDATORY. Without it the HTTP response blocks on the whole
 *    turn, Slack's 3s ack budget expires, Slack retries, and the turn runs TWICE
 *    (which also breaks D12 post-once). In a persistent process "background" is
 *    simply "don't await" — plus a `.catch` so a rejected turn is logged, not an
 *    unhandled rejection.
 * 3. `allowedMethods = ["GET", "POST"]`. Meta/WhatsApp's webhook VERIFICATION
 *    handshake is a GET (`hub.mode`/`hub.challenge`), so POST-only breaks
 *    WhatsApp onboarding outright. A generic allowlist, never a provider branch.
 * 4. The body is SINGLE-READ. We buffer the raw bytes ourselves and hand the
 *    adapter a Request built from that buffer, so the adapter's read is the first
 *    one. Pre-reading a Request the adapter also reads makes it throw "Body is
 *    unusable", which the Slack adapter catches and reports as a misleading HTTP
 *    401 "Invalid signature".
 * 5. On body-cap overflow NEVER `req.destroy()` — it tears down the socket, so
 *    the 413 never reaches the provider (they see a socket error and retry). We
 *    reject an over-cap DECLARED content-length before reading a byte, and for a
 *    chunked body we stop ACCUMULATING at the cap while still draining.
 * 6. `publicBaseUrl` — behind Caddy the socket speaks plain http, but adapters
 *    that validate audience/URL (Teams' Bot Framework JWT) need the PUBLIC https
 *    URL in the reconstructed Request.
 *
 * The path prefix is owned by the bridge, not by the proxy: Caddy's `handle` does
 * NOT strip it, so the router matches the FULL `/connectors/...` path
 * (`CONNECTORS_PATH_PREFIX`). Getting that wrong is a silent 404 on every webhook.
 */
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";

import type { ConnectorRegistry } from "../connector/registry.js";
import type { ConnectorInstall, InstallsLookup } from "../connector/types.js";
import {
  handleLinearOAuthCallback,
  type LinearOAuthCallbackDeps,
} from "../oauth/linear-oauth.js";
import {
  handleSlackOAuthCallback,
  type SlackOAuthCallbackDeps,
} from "../oauth/slack-oauth.js";
import {
  handleConnectRequest,
  type ConnectAction,
  type ConnectDeps,
} from "./connect.js";
import type { WebhookHandler, WebhookMountIndex } from "./mounts.js";

/** GET is not optional: it is WhatsApp's verification handshake (rule 3). */
export const ALLOWED_METHODS = ["GET", "POST"] as const;

/**
 * The single opaque failure. Unknown provider, unknown install key, an install
 * that exists but is not mounted, a half-row with no credential, a dot-segment
 * target — every one of them answers with THESE EXACT BYTES. Distinguishing them
 * would turn the endpoint into an install-enumeration oracle.
 */
const NOT_FOUND_BODY = '{"error":"not_found"}';
const TOO_LARGE_BODY = '{"error":"payload_too_large"}';
const BAD_REQUEST_BODY = '{"error":"bad_request"}';
const METHOD_NOT_ALLOWED_BODY = '{"error":"method_not_allowed"}';
const INTERNAL_ERROR_BODY = '{"error":"internal_error"}';
/** Liveness only. Says nothing about tenants, installs, or versions. */
const HEALTH_BODY = '{"status":"ok"}';

/** 1 MiB. Slack/Teams/WhatsApp event bodies are kilobytes; this is slack in both senses. */
export const DEFAULT_MAX_BODY_BYTES = 1_048_576;

export const DEFAULT_PATH_PREFIX = "/connectors";

/**
 * THE TIME BOUND (charter D57). Node's stock defaults are not "forever", but they
 * are far too generous for a loopback seam: headersTimeout 60s, requestTimeout
 * 300s, and a `connectionsCheckingInterval` sweep every 30s.
 *
 * INVARIANT — `requestTimeout >= headersTimeout`, and it is enforced, not hoped
 * for. Once headers have arrived node evicts at `max(headersTimeout, requestTimeout)`,
 * so a "tighter" requestTimeout below headersTimeout is silently ignored: you would
 * set 5s, measure 20s, and conclude the setting does nothing.
 *
 * The sweep interval is the OTHER half, and it is the one a naive fix misses:
 * setting `headersTimeout` alone does not evict promptly, because eviction happens
 * on the sweep — a slow-loris was measured surviving 30 006 ms against a 20 s
 * headersTimeout. 5 s here bounds that overshoot.
 */
export const DEFAULT_HEADERS_TIMEOUT_MS = 20_000;
export const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;
export const DEFAULT_CONNECTIONS_CHECKING_INTERVAL_MS = 5_000;

export interface WebhookServerOptions {
  /** Where a provider id resolves to its Connector (and its `webhook` block). */
  registry: ConnectorRegistry;
  /** The fail-closed tenant lookup. The ONLY way to obtain an install row. */
  installs: InstallsLookup;
  /** The install-keyed mount index. `handlerFor` takes the row this lookup returned. */
  mounts: WebhookMountIndex;
  /**
   * The connect/disconnect routes (D50/D51). ABSENT ⇒ they are NOT MOUNTED and
   * every one of their paths is the same opaque 404 as any unknown route.
   *
   * Optional on purpose, and it is a deployment-safety property, not a style
   * choice: `CONNECTORS_CONNECT_SECRET` is written by the deploy, and a `required()`
   * here would mean the bridge REFUSES TO BOOT on any host that has not been
   * re-deployed yet — i.e. `/connectors` becomes the maintenance 503 for every
   * tenant, fleet-wide, because a feature nobody is using yet has no env var. An
   * unmounted route is a non-event; a dead bridge is an outage.
   */
  connect?: ConnectDeps;
  /**
   * The Add-to-Slack OAuth callback deps (D62). ABSENT ⇒ the callback route is
   * NOT MOUNTED and answers the same opaque 404 as any unknown path — the honest
   * state on an instance with no Slack app configured. Present only when the
   * bridge has Slack app credentials AND a connect secret (see `index.ts`).
   *
   * Unlike the connect routes this is PUBLIC (Slack redirects a browser to it) and
   * is NEVER loopback-gated: it authenticates by the signed connect ticket in
   * `state`, not by network topology.
   */
  slackOAuth?: SlackOAuthCallbackDeps;
  /**
   * The Connect-to-Linear OAuth callback deps (D77/D78) — the OUTBOUND (tool)
   * OAuth, the mirror of `slackOAuth` for a TOOL connector. ABSENT ⇒ the callback
   * route is NOT MOUNTED and answers the same opaque 404 as any unknown path — the
   * honest state on an instance with no Linear OAuth app configured. Present only
   * when the bridge has Linear app credentials AND a connect secret (see `index.ts`).
   *
   * Like `slackOAuth` this is PUBLIC (Linear redirects a browser to it) and is
   * NEVER loopback-gated: it authenticates by the signed connect ticket in `state`,
   * not by network topology.
   */
  linearOAuth?: LinearOAuthCallbackDeps;
  /** Node's `server.headersTimeout`, ms. Default 20 s. */
  headersTimeoutMs?: number;
  /** Node's `server.requestTimeout`, ms. Default 30 s. MUST be >= headersTimeout. */
  requestTimeoutMs?: number;
  /** Node's connection sweep, ms. Default 5 s — this is what makes eviction PROMPT. */
  connectionsCheckingIntervalMs?: number;
  /** Default `/connectors`. The bridge owns the FULL path — Caddy does not strip it. */
  pathPrefix?: string;
  /** Public https origin (behind a proxy). Falls back to x-forwarded-proto/host. */
  publicBaseUrl?: string;
  maxBodyBytes?: number;
  /**
   * Background the turn (rule 2). Defaults to fire-and-forget with a logging
   * `.catch` — correct for a persistent process, where "background" just means
   * "do not await".
   */
  waitUntil?: (task: Promise<unknown>) => void;
  /** Observability hook; never used to shape the response. */
  onError?: (error: unknown, context: WebhookErrorContext) => void;
}

export interface WebhookErrorContext {
  provider?: string;
  installKey?: string;
  workspaceId?: string;
  method?: string;
  target?: string;
}

/** A parsed webhook route. Nothing here has touched the body. */
interface WebhookRoute {
  provider: string;
  /** Present only for `keySource: "path"` routes. */
  installKeyFromPath: string | null;
}

function firstHeader(value: string | string[] | undefined): string | undefined {
  if (Array.isArray(value)) return value[0];
  return value;
}

/**
 * Split a raw request target into decoded path segments, or `null` when it is
 * not a plain origin-form path we are willing to route.
 *
 * Rejects dot segments AFTER percent-decoding (so `%2e%2e` is caught too), empty
 * segments (`//`, a trailing slash), and any segment that decodes to something
 * containing a separator or a NUL. Note that `fetch`/undici normalises dot
 * segments CLIENT-side — a traversal test written with `fetch` proves nothing, so
 * `test/webhook-server.test.ts` sends the literal bytes over a raw socket.
 */
function decodeSegments(rawTarget: string): string[] | null {
  const queryAt = rawTarget.indexOf("?");
  const pathname = queryAt === -1 ? rawTarget : rawTarget.slice(0, queryAt);

  // Origin-form only. An absolute-form target (`http://host/...`) or anything
  // else is not a route we serve.
  if (!pathname.startsWith("/")) return null;

  const segments: string[] = [];
  for (const raw of pathname.slice(1).split("/")) {
    let segment: string;
    try {
      segment = decodeURIComponent(raw);
    } catch {
      // A malformed escape (`%zz`) — refuse rather than guess.
      return null;
    }
    if (segment === "" || segment === "." || segment === "..") return null;
    if (segment.includes("/") || segment.includes("\\") || segment.includes("\0")) {
      return null;
    }
    segments.push(segment);
  }
  return segments;
}

/** Normalise `/connectors/`, `connectors` … to `/connectors`. Empty means root. */
export function normalisePathPrefix(prefix: string): string {
  const trimmed = prefix.trim().replace(/\/+$/, "");
  if (trimmed === "" || trimmed === "/") return "";
  return trimmed.startsWith("/") ? trimmed : `/${trimmed}`;
}

/**
 * Split the request target into the segments BELOW the bridge's path prefix, or
 * null when the target is malformed or not ours. Shared by the health route and
 * the webhook route so they agree, byte for byte, on what "under the prefix"
 * means (Caddy does NOT strip the prefix — the bridge owns the full path).
 */
function segmentsUnderPrefix(
  rawTarget: string,
  pathPrefix: string,
): string[] | null {
  const segments = decodeSegments(rawTarget);
  if (segments === null) return null;

  const prefixSegments = normalisePathPrefix(pathPrefix)
    .split("/")
    .filter((s) => s !== "");

  for (const [index, expected] of prefixSegments.entries()) {
    if (segments[index] !== expected) return null;
  }
  return segments.slice(prefixSegments.length);
}

/**
 * `GET {prefix}/health` — is the bridge process actually answering?
 *
 * Deliberately the ONLY unauthenticated, tenant-less surface, and it says
 * nothing a stranger could use: no install count, no provider list, no version.
 * It exists because the deploy needs a truthful liveness probe
 * (`deploy/instance-deploy.sh` curls it after `systemctl restart`, and the
 * ordering hazard in `docs/ops/connectors-deploy.md` turns on the answer): before
 * this route the probe could only ever log `000`, and "is the bridge up?" had no
 * answer short of reading journalctl.
 */
function isHealthRoute(rawTarget: string, pathPrefix: string): boolean {
  const rest = segmentsUnderPrefix(rawTarget, pathPrefix);
  return rest !== null && rest.length === 1 && rest[0] === "health";
}

/**
 * `{prefix}/connect`, `{prefix}/connect/validate`, `{prefix}/disconnect` — the
 * connect loop (D50/D51), or null when this is not one of them.
 *
 * Parsed HERE, inside the webhook server, because `decodeSegments` /
 * `segmentsUnderPrefix` / `normalisePathPrefix` are the security-hardened path
 * parsing this seam already owns (dot segments rejected AFTER percent-decoding,
 * empty segments refused, NUL and separator bytes refused). A connect router
 * mounted elsewhere would have to duplicate all of it, and the copy is where the
 * traversal bug would live.
 */
interface ConnectRoute {
  action: ConnectAction;
  /** The provider segment, present only on `tool-headers/:provider` (D69). */
  pathProvider?: string;
}

function parseConnectRoute(
  rawTarget: string,
  pathPrefix: string,
): ConnectRoute | null {
  const rest = segmentsUnderPrefix(rawTarget, pathPrefix);
  if (rest === null) return null;

  if (rest.length === 1 && rest[0] === "connect") return { action: "connect" };
  if (rest.length === 1 && rest[0] === "disconnect") {
    return { action: "disconnect" };
  }
  if (rest.length === 2 && rest[0] === "connect" && rest[1] === "validate") {
    return { action: "validate" };
  }
  if (rest.length === 2 && rest[0] === "connect" && rest[1] === "pending") {
    return { action: "pending" };
  }
  // The OUTBOUND (tool) direction (D69/D71): list a workspace's tool connectors,
  // and open ONE provider's sealed PAT at MCP-connect. Same loopback gate below.
  if (
    rest.length === 2 &&
    rest[0] === "connect" &&
    rest[1] === "tool-descriptors"
  ) {
    return { action: "tool-descriptors" };
  }
  if (
    rest.length === 3 &&
    rest[0] === "connect" &&
    rest[1] === "tool-headers" &&
    rest[2] !== undefined &&
    rest[2] !== ""
  ) {
    return { action: "tool-headers", pathProvider: rest[2] };
  }
  return null;
}

/**
 * `GET {prefix}/oauth/slack/callback` — the Add-to-Slack OAuth callback (D62).
 *
 * A FOURTH route class, distinct from the connect family: it is PUBLIC and
 * `GET`, authenticated by a signed connect ticket in `state` (crypto, not network
 * topology), never by loopback. It reuses the SAME hardened path parsing
 * (`segmentsUnderPrefix` — dot segments rejected after percent-decoding) so the
 * traversal defence is not duplicated.
 */
function isSlackOAuthCallbackRoute(rawTarget: string, pathPrefix: string): boolean {
  const rest = segmentsUnderPrefix(rawTarget, pathPrefix);
  return (
    rest !== null &&
    rest.length === 3 &&
    rest[0] === "oauth" &&
    rest[1] === "slack" &&
    rest[2] === "callback"
  );
}

/**
 * `GET {prefix}/oauth/linear/callback` — the Connect-to-Linear OAuth callback
 * (D77/D78), the OUTBOUND (tool) sibling of the Slack callback above.
 *
 * A FIFTH route class, identical in shape to the Slack one: PUBLIC and `GET`,
 * authenticated by a signed connect ticket in `state` (crypto, not network
 * topology), never loopback-gated. It reuses the SAME hardened path parsing
 * (`segmentsUnderPrefix` — dot segments rejected after percent-decoding) so the
 * traversal defence is not duplicated.
 */
function isLinearOAuthCallbackRoute(
  rawTarget: string,
  pathPrefix: string,
): boolean {
  const rest = segmentsUnderPrefix(rawTarget, pathPrefix);
  return (
    rest !== null &&
    rest.length === 3 &&
    rest[0] === "oauth" &&
    rest[1] === "linear" &&
    rest[2] === "callback"
  );
}

/**
 * LOOPBACK-ONLY BY CONSTRUCTION (D50).
 *
 * Caddy appends `x-forwarded-for` and `x-forwarded-host` to everything it proxies,
 * so their presence PROVES a request came through the public path route — and the
 * connect routes are not for the public. Refusing them is not defence-in-depth on
 * top of the bind address; it is the load-bearing control, because the same
 * `node:http` server also serves the webhook routes, which MUST be reachable from
 * the internet and which trust those very headers to build the adapter's URL.
 *
 * Note the asymmetry deliberately: a webhook WITH x-forwarded-* is normal traffic;
 * a connect WITH x-forwarded-* is an opaque 404, valid ticket or not.
 */
function isProxied(req: IncomingMessage): boolean {
  return (
    req.headers["x-forwarded-for"] !== undefined ||
    req.headers["x-forwarded-host"] !== undefined
  );
}

/**
 * `{prefix}/webhooks/:provider[/:installKey]` — nothing else. No body has been
 * read at this point, and none will be for a route we do not serve.
 */
function parseRoute(rawTarget: string, pathPrefix: string): WebhookRoute | null {
  const rest = segmentsUnderPrefix(rawTarget, pathPrefix);
  if (rest === null) return null;
  if (rest[0] !== "webhooks") return null;

  const provider = rest[1];
  if (provider === undefined) return null;

  if (rest.length === 2) return { provider, installKeyFromPath: null };
  if (rest.length === 3) {
    const installKeyFromPath = rest[2];
    if (installKeyFromPath === undefined) return null;
    return { provider, installKeyFromPath };
  }
  // Deeper than the route shape (including a traversal attempt) — 404.
  return null;
}

function send(
  res: ServerResponse,
  status: number,
  body: string,
  headers: Record<string, string> = {},
): void {
  if (res.writableEnded) return;
  res.statusCode = status;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.setHeader("content-length", Buffer.byteLength(body));
  for (const [key, value] of Object.entries(headers)) res.setHeader(key, value);
  res.end(body);
}

/** The one opaque failure. Byte-identical for every reason it can happen. */
function notFound(res: ServerResponse): void {
  send(res, 404, NOT_FOUND_BODY);
}

/** Escape the only thing that reaches the page from a string — the error text. */
function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * The OAuth callback answers a BROWSER, not a provider — so it renders a tiny HTML
 * page a human can read, never a JSON envelope. It never carries a token or a
 * stack trace: `installed` and the bridge's own one-line `error` are the whole of
 * it. The status is the callback's own (200 installed, 4xx refused, 409 owned).
 */
function sendOAuthPage(
  res: ServerResponse,
  status: number,
  installed: boolean,
  error: string | undefined,
  providerLabel: string,
): void {
  if (res.writableEnded) return;
  const heading = installed
    ? `Connected to ${providerLabel}`
    : `Could not connect ${providerLabel}`;
  const detail = installed
    ? `Your ${providerLabel} account is now connected to Barkpark. You can close this tab and return to Studio.`
    : escapeHtml(
        error ??
          "The connect could not be completed. Return to Studio and try again.",
      );
  const body =
    `<!doctype html><html lang="en"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width, initial-scale=1">` +
    `<title>${escapeHtml(heading)}</title></head>` +
    `<body style="font-family: system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; padding: 0 1.5rem;">` +
    `<h1>${escapeHtml(heading)}</h1><p>${detail}</p></body></html>`;
  res.statusCode = status;
  res.setHeader("content-type", "text/html; charset=utf-8");
  res.setHeader("content-length", Buffer.byteLength(body));
  res.end(body);
}

type BodyRead =
  { ok: true; body: Buffer } | { ok: false; reason: "too_large" | "malformed" };

/**
 * Drain without accumulating. NEVER `req.destroy()` (rule 5): destroying the
 * socket means our 413 never reaches the provider — they see a transport error
 * (`UND_ERR_SOCKET`) and retry, which is the opposite of backpressure.
 */
function drain(req: IncomingMessage): void {
  req.resume();
}

function readBody(req: IncomingMessage, maxBytes: number): Promise<BodyRead> {
  return new Promise<BodyRead>((resolve) => {
    const declared = firstHeader(req.headers["content-length"]);
    if (declared !== undefined) {
      const length = Number(declared);
      if (!Number.isInteger(length) || length < 0) {
        drain(req);
        resolve({ ok: false, reason: "malformed" });
        return;
      }
      if (length > maxBytes) {
        // Rejected BEFORE a single byte is read.
        drain(req);
        resolve({ ok: false, reason: "too_large" });
        return;
      }
    }

    const chunks: Buffer[] = [];
    let total = 0;
    let overflowed = false;

    req.on("data", (chunk: Buffer) => {
      total += chunk.length;
      if (total > maxBytes) {
        // Chunked and over the cap: stop ACCUMULATING, keep draining.
        overflowed = true;
        chunks.length = 0;
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      resolve(
        overflowed
          ? { ok: false, reason: "too_large" }
          : { ok: true, body: Buffer.concat(chunks) },
      );
    });
    req.on("error", () => {
      resolve({ ok: false, reason: "malformed" });
    });
  });
}

/** The URL the ADAPTER sees. Public https origin behind a proxy (rule 6). */
function requestUrl(req: IncomingMessage, publicBaseUrl?: string): string {
  const target = req.url ?? "/";
  if (publicBaseUrl) {
    // Concatenated, not `new URL(target, base)`: a base with a path would have
    // its path dropped, and URL would re-normalise the target we deliberately
    // validated ourselves.
    return `${publicBaseUrl.replace(/\/+$/, "")}${target}`;
  }
  const proto = firstHeader(req.headers["x-forwarded-proto"]) ?? "http";
  const host =
    firstHeader(req.headers["x-forwarded-host"]) ??
    firstHeader(req.headers.host) ??
    "localhost";
  return `${proto}://${host}${target}`;
}

/** Hop-by-hop headers: meaningless to an adapter, and rejected by `Request`. */
const SKIPPED_HEADERS = new Set([
  "connection",
  "keep-alive",
  "transfer-encoding",
  "upgrade",
  "host",
]);

function requestHeaders(req: IncomingMessage): Headers {
  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    if (value === undefined) continue;
    if (SKIPPED_HEADERS.has(name.toLowerCase())) continue;
    if (Array.isArray(value)) {
      for (const item of value) headers.append(name, item);
    } else {
      headers.set(name, value);
    }
  }
  return headers;
}

/**
 * Rebuild the provider's request from the exact bytes we buffered. The body is
 * handed over UNPARSED and UNTOUCHED — Slack HMACs the raw bytes, so a
 * re-serialised JSON round-trip (whitespace! unicode escapes!) would fail
 * signature verification for reasons impossible to debug from the 401.
 */
function buildRequest(
  req: IncomingMessage,
  body: Buffer | undefined,
  publicBaseUrl?: string,
): Request {
  const method = (req.method ?? "GET").toUpperCase();
  const hasBody = method !== "GET" && method !== "HEAD" && body !== undefined;
  return new Request(requestUrl(req, publicBaseUrl), {
    method,
    headers: requestHeaders(req),
    // `new Uint8Array(...)` — a Node Buffer is a Uint8Array view, but pass the
    // exact window (byteOffset/byteLength), never the whole pooled ArrayBuffer.
    body: hasBody
      ? new Uint8Array(body.buffer, body.byteOffset, body.byteLength)
      : undefined,
  });
}

async function writeResponse(
  res: ServerResponse,
  response: Response,
): Promise<void> {
  if (res.writableEnded) return;
  const buffer = Buffer.from(await response.arrayBuffer());
  res.statusCode = response.status;
  response.headers.forEach((value, name) => {
    if (SKIPPED_HEADERS.has(name.toLowerCase())) return;
    res.setHeader(name, value);
  });
  res.setHeader("content-length", buffer.byteLength);
  res.end(buffer);
}

/** The default background runner for a persistent process: do not await, do log. */
function defaultWaitUntil(task: Promise<unknown>): void {
  void task.catch((error: unknown) => {
    console.error("[webhook] background turn failed:", error);
  });
}

/**
 * The request handler. Usable standalone (tests drive it through a real
 * `node:http` server on port 0) or mounted into an existing server.
 */
// @canonical capability:connector-webhook-demux aka:webhook,inbound,slack,teams,whatsapp,handleWebhook doc:.claude/workflows/bp-connectors-charter.md
export function createWebhookRequestHandler(
  options: WebhookServerOptions,
): (req: IncomingMessage, res: ServerResponse) => void {
  const {
    registry,
    installs,
    mounts,
    connect,
    slackOAuth,
    linearOAuth,
    publicBaseUrl,
    onError,
    waitUntil = defaultWaitUntil,
  } = options;
  const pathPrefix = normalisePathPrefix(options.pathPrefix ?? DEFAULT_PATH_PREFIX);
  const maxBodyBytes = options.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;

  const invoke = async (
    handler: WebhookHandler,
    install: ConnectorInstall,
    req: IncomingMessage,
    res: ServerResponse,
    body: Buffer | undefined,
  ): Promise<void> => {
    try {
      const request = buildRequest(req, body, publicBaseUrl);
      const response = await handler(request, { waitUntil });
      await writeResponse(res, response);
    } catch (error) {
      // The adapter blew up. Answer opaquely — the provider must never learn our
      // stack — log honestly, and stay up: one bad install cannot take the
      // process (and every other tenant) down with it.
      onError?.(error, {
        provider: install.provider,
        installKey: install.installKey,
        workspaceId: install.workspaceId,
        method: req.method,
        target: req.url,
      });
      console.error(
        `[webhook] handler failed for ${install.provider} install=${install.installKey}:`,
        error,
      );
      send(res, 500, INTERNAL_ERROR_BODY);
    }
  };

  return (req: IncomingMessage, res: ServerResponse): void => {
    void (async () => {
      const method = (req.method ?? "GET").toUpperCase();
      if (!(ALLOWED_METHODS as readonly string[]).includes(method)) {
        drain(req);
        send(res, 405, METHOD_NOT_ALLOWED_BODY, {
          allow: ALLOWED_METHODS.join(", "),
        });
        return;
      }

      // Liveness, before anything tenant-shaped. GET only — a POST to /health is
      // not a health check, it is someone probing.
      if (isHealthRoute(req.url ?? "/", pathPrefix)) {
        drain(req);
        if (method !== "GET") {
          send(res, 405, METHOD_NOT_ALLOWED_BODY, { allow: "GET" });
          return;
        }
        send(res, 200, HEALTH_BODY);
        return;
      }

      // The connect loop (D50/D51). Every refusal below is the SAME opaque 404 the
      // webhook demux gives, and it is reached BEFORE any body is read whenever
      // that is possible at all.
      const connectRoute = parseConnectRoute(req.url ?? "/", pathPrefix);
      if (connectRoute !== null) {
        // Not mounted (no CONNECTORS_CONNECT_SECRET), came through the proxy, or
        // arrived as a GET: indistinguishable from "there is no such route". A
        // stranger cannot even learn that a connect seam exists here. The tool
        // routes (D69) ride this SAME loopback gate — a `tool-headers` fetch is
        // never reachable from the public path.
        if (connect === undefined || isProxied(req) || method !== "POST") {
          drain(req);
          notFound(res);
          return;
        }

        const read = await readBody(req, maxBodyBytes);
        if (!read.ok) {
          send(
            res,
            read.reason === "too_large" ? 413 : 400,
            read.reason === "too_large" ? TOO_LARGE_BODY : BAD_REQUEST_BODY,
            { connection: "close" },
          );
          return;
        }

        const reply = await handleConnectRequest(
          connectRoute.action,
          read.body.toString("utf8"),
          connect,
          connectRoute.pathProvider,
        );
        // `null` => the handler declined (unknown/unconnectable provider, or a
        // cross-tenant disconnect). It never spells the 404 itself, so it cannot
        // drift from this one.
        if (reply === null) {
          notFound(res);
          return;
        }
        send(res, reply.status, JSON.stringify(reply.body));
        return;
      }

      // THE ADD-TO-SLACK OAUTH CALLBACK (D62) — a fourth route class, between the
      // connect family and the webhook demux. It is PUBLIC and GET (Slack
      // redirects a browser here through Caddy, so x-forwarded-* is ALWAYS present
      // — an isProxied gate would 404 it permanently), and it authenticates by the
      // signed connect ticket in `state`, never by loopback. A body is never read:
      // everything rides the query string.
      if (isSlackOAuthCallbackRoute(req.url ?? "/", pathPrefix)) {
        drain(req);
        // Not configured (no Slack app / no connect secret) ⇒ indistinguishable
        // from "there is no such route". A non-GET is the same: a browser redirect
        // is a GET, and anything else is a probe.
        if (slackOAuth === undefined || method !== "GET") {
          notFound(res);
          return;
        }

        const request = buildRequest(req, undefined, publicBaseUrl);
        const result = await handleSlackOAuthCallback(request, slackOAuth);
        sendOAuthPage(res, result.status, result.installed, result.error, "Slack");
        return;
      }

      // THE CONNECT-TO-LINEAR OAUTH CALLBACK (D77/D78) — the OUTBOUND (tool)
      // sibling of the Slack callback above, and identical in shape: PUBLIC and
      // GET (Linear redirects a browser here through Caddy, so x-forwarded-* is
      // ALWAYS present — an isProxied gate would 404 it permanently), authenticated
      // by the signed connect ticket in `state`, never by loopback. No body is read.
      if (isLinearOAuthCallbackRoute(req.url ?? "/", pathPrefix)) {
        drain(req);
        // Not configured (no Linear app / no connect secret) ⇒ indistinguishable
        // from "there is no such route". A non-GET is the same: a browser redirect
        // is a GET, and anything else is a probe.
        if (linearOAuth === undefined || method !== "GET") {
          notFound(res);
          return;
        }

        const request = buildRequest(req, undefined, publicBaseUrl);
        const result = await handleLinearOAuthCallback(request, linearOAuth);
        sendOAuthPage(res, result.status, result.installed, result.error, "Linear");
        return;
      }

      const route = parseRoute(req.url ?? "/", pathPrefix);
      if (route === null) {
        drain(req);
        notFound(res);
        return;
      }

      const connector = registry.get(route.provider);
      const spec = connector?.webhook;
      // No connector, or a connector with no inbound HTTP transport (Telegram in
      // polling mode): not routable over HTTP. Same 404. (Discord DOES carry a
      // webhook block since D228 — Gateway socket AND slash-command interactions.)
      if (!connector || !spec) {
        drain(req);
        notFound(res);
        return;
      }

      if (spec.keySource === "path") {
        // The install key is a path segment, so the tenant is known BEFORE the
        // body is read — an unroutable request never costs us a byte of body.
        if (route.installKeyFromPath === null) {
          drain(req);
          notFound(res);
          return;
        }

        const install = await installs.lookupInstall(
          route.provider,
          route.installKeyFromPath,
        );
        if (install === null) {
          drain(req);
          notFound(res);
          return;
        }

        const handler = mounts.handlerFor(install);
        if (handler === undefined) {
          drain(req);
          notFound(res);
          return;
        }

        const read = await readBody(req, maxBodyBytes);
        if (!read.ok) {
          send(
            res,
            read.reason === "too_large" ? 413 : 400,
            read.reason === "too_large" ? TOO_LARGE_BODY : BAD_REQUEST_BODY,
            { connection: "close" },
          );
          return;
        }

        await invoke(handler, install, req, res, read.body);
        return;
      }

      // keySource === "payload": the provider's request_url is APP-WIDE (Slack's
      // team_id, Teams' tenant id), so the tenant key lives in the body and the
      // body MUST be read before the lookup. It is read ONCE and handed to the
      // adapter as-is — this is the single read, not a peek.
      if (route.installKeyFromPath !== null) {
        // A payload-keyed connector has no per-install URL. An extra segment is
        // someone probing; it is not a route.
        drain(req);
        notFound(res);
        return;
      }

      const read = await readBody(req, maxBodyBytes);
      if (!read.ok) {
        send(
          res,
          read.reason === "too_large" ? 413 : 400,
          read.reason === "too_large" ? TOO_LARGE_BODY : BAD_REQUEST_BODY,
          { connection: "close" },
        );
        return;
      }

      const rawBody = read.body.toString("utf8");
      const headers = requestHeaders(req);

      let installKey: string | null = null;
      try {
        installKey = (await spec.extractInstallKey?.(rawBody, headers)) ?? null;
      } catch (error) {
        // A connector's extractor threw on a hostile body. Fail closed, loudly
        // in the log and opaquely on the wire.
        onError?.(error, {
          provider: route.provider,
          method: req.method,
          target: req.url,
        });
        notFound(res);
        return;
      }

      // No install key. Before the 404, give the connector its ONE chance to
      // answer a request that legitimately has no tenant: the provider's endpoint
      // VERIFICATION handshake (Slack's `url_verification`, which is sent before
      // any workspace has installed the app and carries no team id). Without this
      // hook Slack's Events request_url can never be verified and the app can
      // never be configured — a 404 here would make the seam unusable for the one
      // channel it was built for. The hook is tenant-less by contract: it sees no
      // install row and touches no credential.
      if (installKey === null) {
        let handshake: Response | null = null;
        try {
          handshake = (await spec.handleUnkeyed?.(rawBody, headers)) ?? null;
        } catch (error) {
          onError?.(error, {
            provider: route.provider,
            method: req.method,
            target: req.url,
          });
          notFound(res);
          return;
        }
        if (handshake !== null) {
          await writeResponse(res, handshake);
          return;
        }
        notFound(res);
        return;
      }

      const install = await installs.lookupInstall(route.provider, installKey);
      if (install === null) {
        notFound(res);
        return;
      }

      const handler = mounts.handlerFor(install);
      if (handler === undefined) {
        notFound(res);
        return;
      }

      await invoke(handler, install, req, res, read.body);
    })().catch((error: unknown) => {
      // The router itself failed (a database outage in lookupInstall, say). Never
      // leak it, never hang the provider's connection.
      onError?.(error, { method: req.method, target: req.url });
      console.error("[webhook] router failed:", error);
      send(res, 500, INTERNAL_ERROR_BODY);
    });
  };
}

export interface WebhookServer {
  server: Server;
  /** The bound port — resolved, so a test can listen on 0 and still address it. */
  port: number;
  close(): Promise<void>;
}

/**
 * `connectionsCheckingInterval` is a REAL, documented runtime property of
 * `http.Server` — and `@types/node@22.20.1` does not declare it (it is missing from
 * the `Server` interface, though `createServer`'s options bag has it). Casting
 * through this local interface is the honest spelling: it says "the type is wrong,
 * the runtime is right", and it stays checked (a typo is still a compile error)
 * rather than an `any` that would swallow one.
 *
 * It is set on the SERVER, not passed to `createServer`, so that a server the
 * caller built elsewhere can be bounded too — and because the three timeouts then
 * live in one place a reader can see at once.
 */
interface ServerWithConnectionsChecking extends Server {
  connectionsCheckingInterval: number;
}

/**
 * Build (but do not listen on) the webhook server, TIME-BOUNDED (D57).
 *
 * The byte bound already shipped (1 MiB, drained, never a socket teardown). This
 * is the other half: without it a slow-loris — a connection that sends half a
 * header line and then nothing — holds a socket for 60 s on node's defaults, and
 * the eviction lands whenever the 30 s sweep next happens to run.
 */
export function createWebhookServer(options: WebhookServerOptions): Server {
  const headersTimeout = options.headersTimeoutMs ?? DEFAULT_HEADERS_TIMEOUT_MS;
  const requestTimeout = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
  const connectionsCheckingInterval =
    options.connectionsCheckingIntervalMs ??
    DEFAULT_CONNECTIONS_CHECKING_INTERVAL_MS;

  // THE INVARIANT (D57), enforced rather than commented: once headers have
  // arrived, node evicts at max(headersTimeout, requestTimeout). A requestTimeout
  // BELOW headersTimeout is therefore not "stricter" — it is inert, and the
  // operator who set it would measure the headers value and disbelieve their own
  // config. Refuse it at construction, where the mistake is cheap.
  if (requestTimeout < headersTimeout) {
    throw new Error(
      `webhook server: requestTimeout (${requestTimeout}ms) must be >= headersTimeout ` +
        `(${headersTimeout}ms) — node evicts at max(headersTimeout, requestTimeout) once ` +
        "headers have arrived, so a lower requestTimeout is silently ignored.",
    );
  }

  const server = createServer(createWebhookRequestHandler(options));

  server.headersTimeout = headersTimeout;
  server.requestTimeout = requestTimeout;
  // The sweep. WITHOUT this, headersTimeout alone does not evict promptly: the
  // check runs on this interval, so a 20 s bound with node's stock 30 s sweep was
  // measured letting a slow-loris live 30 006 ms.
  (server as ServerWithConnectionsChecking).connectionsCheckingInterval =
    connectionsCheckingInterval;

  return server;
}

export interface StartWebhookServerOptions extends WebhookServerOptions {
  /** 0 binds an ephemeral port — how the tests get a real socket cheaply. */
  port: number;
  host?: string;
}

/** Build AND listen. Resolves once the socket is actually accepting. */
export function startWebhookServer(
  options: StartWebhookServerOptions,
): Promise<WebhookServer> {
  const server = createWebhookServer(options);

  return new Promise<WebhookServer>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, options.host, () => {
      server.removeListener("error", reject);
      const address = server.address();
      const port =
        typeof address === "object" && address !== null
          ? address.port
          : options.port;
      resolve({
        server,
        port,
        close: () =>
          new Promise<void>((done, fail) => {
            // closeAllConnections: without it a keep-alive socket (every provider
            // uses one) holds the process open and `close()` never resolves.
            server.closeAllConnections();
            server.close((error) => (error ? fail(error) : done()));
          }),
      });
    });
  });
}
