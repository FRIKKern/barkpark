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

/** 1 MiB. Slack/Teams/WhatsApp event bodies are kilobytes; this is slack in both senses. */
export const DEFAULT_MAX_BODY_BYTES = 1_048_576;

export const DEFAULT_PATH_PREFIX = "/connectors";

export interface WebhookServerOptions {
  /** Where a provider id resolves to its Connector (and its `webhook` block). */
  registry: ConnectorRegistry;
  /** The fail-closed tenant lookup. The ONLY way to obtain an install row. */
  installs: InstallsLookup;
  /** The install-keyed mount index. `handlerFor` takes the row this lookup returned. */
  mounts: WebhookMountIndex;
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
 * `{prefix}/webhooks/:provider[/:installKey]` — nothing else. No body has been
 * read at this point, and none will be for a route we do not serve.
 */
function parseRoute(rawTarget: string, pathPrefix: string): WebhookRoute | null {
  const segments = decodeSegments(rawTarget);
  if (segments === null) return null;

  const prefixSegments = normalisePathPrefix(pathPrefix)
    .split("/")
    .filter((s) => s !== "");

  for (const [index, expected] of prefixSegments.entries()) {
    if (segments[index] !== expected) return null;
  }

  const rest = segments.slice(prefixSegments.length);
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

      const route = parseRoute(req.url ?? "/", pathPrefix);
      if (route === null) {
        drain(req);
        notFound(res);
        return;
      }

      const connector = registry.get(route.provider);
      const spec = connector?.webhook;
      // No connector, or a connector with no inbound HTTP transport (Telegram
      // polling, Discord's gateway socket): not routable over HTTP. Same 404.
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

      let installKey: string | null = null;
      try {
        installKey =
          spec.extractInstallKey?.(
            read.body.toString("utf8"),
            requestHeaders(req),
          ) ?? null;
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

/** Build (but do not listen on) the webhook server. */
export function createWebhookServer(options: WebhookServerOptions): Server {
  return createServer(createWebhookRequestHandler(options));
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
