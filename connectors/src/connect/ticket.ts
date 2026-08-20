import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

import type { WorkspaceId } from "../connector/types.js";

/**
 * THE CONNECT TICKET (charter D50) — the one thing that authorizes a connect.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHAT IT IS FOR
 * ─────────────────────────────────────────────────────────────────────────────
 * Studio (the BEAM) knows WHICH WORKSPACE an operator is acting for, and it has
 * re-gated that operator on `workspace_admin?` before it will act. The bridge
 * knows none of that: it is a separate Node process with no Barkpark credential
 * and no session. The ticket is how the one fact that matters — "the bearer is
 * authorized to install `<provider>` into workspace `<w>`" — crosses the process
 * boundary without the bridge having to become an auth server.
 *
 * An UNSIGNED workspace id would be an open tenant-assignment hole: anyone who can
 * reach the connect route could mount their bot inside someone else's workspace,
 * and from then on their messages open Sessions there. So the workspace rides an
 * HMAC the bridge itself can verify and only the secret-holder can mint.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE WIRE IS FIXED — DO NOT "IMPROVE" IT
 * ─────────────────────────────────────────────────────────────────────────────
 * An Elixir signer (`Barkpark`'s Studio catalog) mints these tickets and this
 * module verifies them. The two are written by different people in different
 * languages against a wire that exists only in the charter, so ANY drift — a space
 * after a colon, a reordered key, base64 instead of base64url — is a silent
 * cross-language HMAC mismatch that 401s every connect in production and passes
 * every test on both sides. That is what {@link GOLDEN_TICKET} is for: both sides
 * pin the SAME string, byte for byte, and a drift goes red in CI instead of in the
 * one place nobody is looking.
 *
 *   payload JSON, EXACT key order, no spaces:
 *     {"w":"<workspace uuid>","p":"<provider>","n":"<nonce>","t":<issued_at_ms>}
 *   ticket = base64url(json) "." base64url(HMAC-SHA256(secret, base64url(json)))
 *   no padding; TTL 600 000 ms; future skew tolerated up to 30 000 ms.
 *
 * The payload is READABLE on purpose — it is not a secret, it is a workspace id
 * the operator already knows — and the SIGNATURE is what makes it unforgeable. The
 * raw chat token NEVER rides in here: a ticket may traverse a URL bar and a proxy
 * log, so the token rides the POST body over LOOPBACK instead (D50).
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * RELATIONSHIP TO `oauth/slack-oauth.ts`
 * ─────────────────────────────────────────────────────────────────────────────
 * This is the generalisation of that module's `signOAuthState`/`verifyOAuthState`
 * (which had ZERO HTTP call sites — a primitive wired to nothing). It is NOT a
 * refactor of it: the OAuth `state` payload has no `p` field and its tests pin that
 * shape, so folding them together now would change a wire Slack is already using.
 * Deduping them is filed (`connectors-connect-ticket-unify-slack-state`); the honest
 * cost until then is one duplicated HMAC helper, which is cheaper than a broken
 * install flow.
 */

/** How long a minted ticket stays valid. Long enough to paste, no longer. */
export const CONNECT_TICKET_TTL_MS = 600_000;

/**
 * THE TOOL-SESSION TICKET (charter D69/D73) — the OTHER direction.
 *
 * A paste-mode connect ticket is short (600 s: long enough to paste, no longer)
 * and binds ONE provider. A TOOL ticket is different in both dimensions:
 *
 *   - It lives for a whole chat SESSION (8 h), because it is baked into the
 *     per-session `--mcp-config` file the runner's `claude` subprocess reads, and
 *     the subprocess runs its `headersHelper` — which carries this ticket — every
 *     time it (re)connects the GitHub MCP server, for as long as the session runs.
 *   - It binds the reserved provider {@link TOOL_TICKET_PROVIDER}, NOT a concrete
 *     tool provider, because ONE ticket authorizes BOTH the `tool-descriptors`
 *     list (all of a workspace's tool connectors) AND each `tool-headers` fetch
 *     (a specific provider named in the ROUTE path). The workspace is proven by the
 *     signature; the provider selector rides the path, never the ticket.
 *
 * This capability is meaningfully broader than a paste ticket (it opens sealed
 * PATs), so it is protected the same way the connect routes are: `tool-headers` is
 * loopback-only (an `x-forwarded-*` request is the opaque 404), and the config file
 * that holds it is written 0600 in a per-session temp dir. A leaked tool ticket is
 * useless off the box.
 */
export const TOOL_TICKET_PROVIDER = "tool-session";

/** A tool ticket lives for a chat session (8 h), not a paste window. */
export const TOOL_TICKET_TTL_MS = 28_800_000;

/**
 * How far into the FUTURE a ticket may be dated before we refuse it.
 *
 * Not zero (the BEAM and the bridge share a host, but not a monotonic clock, and
 * an NTP step of a few hundred ms would otherwise 401 a legitimate connect) and
 * not the TTL (a wide future window is just a longer TTL wearing a disguise).
 */
export const CONNECT_TICKET_MAX_SKEW_MS = 30_000;

/**
 * THE GOLDEN VECTOR (D50). Pinned on BOTH sides of the wire.
 *
 * secret `golden-connect-secret`, workspace `1111…5555`, provider `telegram`,
 * nonce `0123456789abcdef`, issued at 1752480000000.
 */
export const GOLDEN_TICKET_SECRET = "golden-connect-secret";
export const GOLDEN_TICKET_INPUT = {
  workspaceId: "11111111-2222-3333-4444-555555555555",
  provider: "telegram",
  nonce: "0123456789abcdef",
  issuedAt: 1752480000000,
} as const;
export const GOLDEN_TICKET =
  "eyJ3IjoiMTExMTExMTEtMjIyMi0zMzMzLTQ0NDQtNTU1NTU1NTU1NTU1IiwicCI6InRlbGVncmFtIiwibiI6IjAxMjM0NTY3ODlhYmNkZWYiLCJ0IjoxNzUyNDgwMDAwMDAwfQ.lKEgXtxTstQoQlBxCdvvPhY23Cq0reI9BHzzPzpdxO0";

/** The verified contents of a ticket. Everything the connect routes are allowed to trust. */
export interface ConnectTicket {
  /** The workspace this connect is authorized for. */
  workspaceId: WorkspaceId;
  /** The provider it is authorized for. The routes take the provider from HERE. */
  provider: string;
  nonce: string;
  issuedAt: number;
}

export class ConnectTicketError extends Error {
  constructor(message: string) {
    super(`connect ticket: ${message}`);
    this.name = "ConnectTicketError";
  }
}

function base64url(input: Buffer): string {
  return input.toString("base64url");
}

function hmac(secret: string, body: string): Buffer {
  return createHmac("sha256", secret).update(body).digest();
}

export interface SignConnectTicketOptions {
  now?: () => number;
  nonce?: string;
}

/**
 * Mint a ticket. The bridge itself has no reason to call this in production (the
 * BEAM mints; the bridge verifies) — it exists so the wire has ONE executable
 * definition, so the golden vector can be regenerated, and so an operator smoke
 * script can drive the routes without Studio.
 */
export function signConnectTicket(
  workspaceId: WorkspaceId,
  provider: string,
  secret: string,
  options: SignConnectTicketOptions = {},
): string {
  if (!secret || secret.trim() === "") {
    throw new ConnectTicketError(
      "a secret is required — an unsigned ticket lets anyone install a bot into " +
        "another tenant's workspace",
    );
  }
  if (!workspaceId || workspaceId.trim() === "") {
    throw new ConnectTicketError("workspaceId is required");
  }
  if (!provider || provider.trim() === "") {
    throw new ConnectTicketError("provider is required");
  }

  // The key order IS the wire (see the module note). Written as a literal, in
  // order, because `JSON.stringify` preserves insertion order for string keys.
  const payload = JSON.stringify({
    w: workspaceId,
    p: provider,
    n: options.nonce ?? base64url(randomBytes(12)),
    t: (options.now ?? Date.now)(),
  });
  const body = base64url(Buffer.from(payload, "utf8"));
  return `${body}.${base64url(hmac(secret, body))}`;
}

export interface VerifyConnectTicketOptions {
  /**
   * The provider the caller is ABOUT TO ACT ON. The ticket's `p` must equal it.
   *
   * This is the whole reason `p` is on the wire: without it, a ticket minted for
   * "connect Telegram" would authorize "connect Discord" — and Studio's mint gate
   * is per-provider (it labels the chat token `connector:<provider>:<key>`). The
   * route NEVER takes the provider from the request body; it takes it from the
   * ticket and passes it here, so a body cannot re-aim an authorization.
   */
  provider: string;
  now?: () => number;
  maxAgeMs?: number;
  maxSkewMs?: number;
}

/**
 * Verify a ticket, or THROW. There is no soft failure: every caller answers the
 * same opaque 404/401 and installs nothing.
 *
 * Fails closed on: missing, malformed, bad signature (including a signature minted
 * under a different secret), expired, future-dated beyond the skew, no workspace,
 * no provider, and a provider that is not the one being acted on.
 */
export function verifyConnectTicket(
  raw: string | null | undefined,
  secret: string,
  options: VerifyConnectTicketOptions,
): ConnectTicket {
  if (!secret || secret.trim() === "") {
    // Belt and braces: the routes are not mounted at all without a secret, so
    // reaching this would mean a caller passed "" — which HMAC would happily
    // accept as a key and thereby verify anything an attacker signs with "".
    throw new ConnectTicketError("no secret configured — refusing to verify");
  }
  if (typeof raw !== "string" || raw.trim() === "") {
    throw new ConnectTicketError("missing");
  }

  const dot = raw.indexOf(".");
  if (dot <= 0 || dot === raw.length - 1) {
    throw new ConnectTicketError("malformed");
  }
  // Exactly one separator. A second dot means someone is feeding us a JWT (or a
  // truncated one), and guessing which half is the signature is how a verifier
  // ends up verifying the wrong bytes.
  if (raw.indexOf(".", dot + 1) !== -1) {
    throw new ConnectTicketError("malformed");
  }

  const body = raw.slice(0, dot);
  const signature = Buffer.from(raw.slice(dot + 1), "base64url");
  const expected = hmac(secret, body);

  // Length-check FIRST: `timingSafeEqual` THROWS on a length mismatch, and the
  // attacker controls the length of the signature they send.
  if (
    signature.length !== expected.length ||
    !timingSafeEqual(signature, expected)
  ) {
    throw new ConnectTicketError(
      "bad signature — not minted by this bridge's peer",
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
  } catch {
    throw new ConnectTicketError("malformed payload");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new ConnectTicketError("malformed payload");
  }

  const { w, p, n, t } = parsed as {
    w?: unknown;
    p?: unknown;
    n?: unknown;
    t?: unknown;
  };
  if (typeof w !== "string" || w.trim() === "") {
    throw new ConnectTicketError("no workspace bound");
  }
  if (typeof p !== "string" || p.trim() === "") {
    throw new ConnectTicketError("no provider bound");
  }
  if (typeof t !== "number" || !Number.isFinite(t)) {
    throw new ConnectTicketError("no issued-at");
  }

  // A valid signature over the WRONG provider is still a refusal: the signature
  // proves the ticket was minted, not that it was minted for THIS action.
  if (p !== options.provider) {
    throw new ConnectTicketError(
      `provider mismatch — minted for "${p}", used for "${options.provider}"`,
    );
  }

  const now = (options.now ?? Date.now)();
  const maxAgeMs = options.maxAgeMs ?? CONNECT_TICKET_TTL_MS;
  const maxSkewMs = options.maxSkewMs ?? CONNECT_TICKET_MAX_SKEW_MS;

  if (now - t > maxAgeMs) throw new ConnectTicketError("expired");
  // Future-dated beyond the tolerated skew: a clock that far ahead is either
  // broken or hostile, and a hostile one would be minting itself a longer TTL.
  if (t - now > maxSkewMs) throw new ConnectTicketError("future-dated");

  return {
    workspaceId: w,
    provider: p,
    nonce: typeof n === "string" ? n : "",
    issuedAt: t,
  };
}

/**
 * Verify a TOOL-SESSION ticket (D69/D73), or THROW.
 *
 * A thin, deliberate specialisation of {@link verifyConnectTicket}: it demands the
 * ticket bind the reserved {@link TOOL_TICKET_PROVIDER} (so a short paste ticket
 * for a concrete provider can never be replayed against the tool routes) and it
 * allows the 8 h {@link TOOL_TICKET_TTL_MS} rather than the 600 s paste window. The
 * concrete tool provider is chosen by the ROUTE path, never the ticket — this
 * verify only proves "the bearer is authorized to act as tools for workspace <w>".
 */
export function verifyToolTicket(
  raw: string | null | undefined,
  secret: string,
  options: { now?: () => number; maxAgeMs?: number } = {},
): ConnectTicket {
  return verifyConnectTicket(raw, secret, {
    provider: TOOL_TICKET_PROVIDER,
    ...(options.now ? { now: options.now } : {}),
    maxAgeMs: options.maxAgeMs ?? TOOL_TICKET_TTL_MS,
  });
}
