import {
  verifyConnectTicket,
  verifyToolTicket,
  type ConnectTicket,
  type VerifyConnectTicketOptions,
} from "../connect/ticket.js";
import type { ConnectorRegistry } from "../connector/registry.js";
import type {
  Connector,
  ConnectorConnect,
  ConnectorInstall,
  InstallsLookup,
  InstallsWriter,
} from "../connector/types.js";

/**
 * THE CONNECT LOOP (charter D50/D51) — paste a token, the install is written,
 * sealed, and MOUNTED LIVE.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHAT THIS CLOSES
 * ─────────────────────────────────────────────────────────────────────────────
 * The mint endpoint existed. The seal existed. Nothing joined them: an operator
 * hand-wrote a row into `chat_bridge.connector_installs` and restarted a systemd
 * unit. "Click connect and your team is talking to your agent in two minutes" was
 * a claim about a wire nobody had run a current through. These three routes are
 * that wire:
 *
 *   POST {prefix}/connect/validate  {ticket, credential}
 *        -> 200 {install_key, display_name}   // NOTHING is written
 *        -> 422 {error:"invalid_credential", reason}
 *   POST {prefix}/connect           {ticket, credential, chat_token}
 *        -> 200 {ok, provider, install_key, workspace_id, mounted:true}
 *   POST {prefix}/disconnect        {ticket, install_key}
 *        -> 200 {ok, removed}
 *
 * VALIDATE (no write) -> CONNECT (one write) -> DISCONNECT (unmount + DELETE).
 * Validate-first is not politeness: a revoked token refused at PASTE time, in the
 * UI, with a reason, is a bad token that never becomes a crash-looping unit at the
 * next restart (D53).
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE SECURITY MODEL, IN THE ORDER IT RUNS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. LOOPBACK-ONLY BY CONSTRUCTION. `x-forwarded-for` / `x-forwarded-host` on the
 *    request => the SAME opaque 404 as an unknown route, EVEN WITH A VALID TICKET.
 *    Caddy always appends them, so the public `/connectors` path can never reach
 *    these routes — the exposure is closed by the shape of the request, not by a
 *    firewall rule someone has to remember. (Enforced in `webhook-server.ts`,
 *    before this module is called: the check must not depend on parsing a body.)
 * 2. THE TICKET IS THE AUTHORIZATION, and the PROVIDER COMES FROM IT. Never from
 *    the body — a body-supplied provider would let a ticket minted for Telegram
 *    install a Discord bot, under a chat token labelled for Telegram.
 * 3. THE SERVER RE-VALIDATES. `connect` never trusts a client-supplied
 *    `install_key`: it re-runs `connector.connect.validate(credential)` and uses
 *    the key THAT returns. Otherwise a caller with a valid ticket could seize an
 *    arbitrary install key — including another workspace's — and the upsert's
 *    `ON CONFLICT` would repoint that row's tenant.
 * 4. A CROSS-TENANT DISCONNECT IS UNREPRESENTABLE. The row is looked up, its
 *    `workspace_id` is compared to the TICKET's, and a mismatch is the opaque 404
 *    — byte-identical to an install that never existed, so the route cannot be
 *    used to enumerate other tenants' installs.
 * 5. NO WRITE SURVIVES A FAILED MOUNT. If `addInstall` throws (a token that
 *    validated against the provider's API but that the adapter refuses), the row is
 *    DELETED and the answer is 502 `mount_failed`. Leaving it would plant exactly
 *    the row that crash-loops the unit at the next boot.
 *
 * The bridge holds no Barkpark credential and mints nothing: the chat token is
 * minted by Studio, in-process, and arrives here already minted (D48). This module
 * seals it and stores it; it never logs it, never echoes it, and never sends it
 * anywhere but `connector_installs`.
 */

/** What the route needs to do its job. Every side effect is injected. */
export interface ConnectDeps {
  /** `CONNECTORS_CONNECT_SECRET`. Absent => the routes are NOT MOUNTED (D50). */
  secret: string;
  registry: ConnectorRegistry;
  /** Fail-closed reads. The disconnect tenant check rides this. */
  installs: InstallsLookup;
  /** `tenant/installs.ts#upsertInstall`, bound to the pool + cipher. */
  upsertInstall(install: ConnectorInstall): Promise<void>;
  /** `tenant/installs.ts#deleteInstall`, bound to the pool. */
  deleteInstall: InstallsWriter["deleteInstall"];
  /** `Bridge.addInstall` — live mount, no restart. MUST throw on failure. */
  mountInstall(install: ConnectorInstall): Promise<unknown>;
  /** `Bridge.removeInstall` — unroute now, before the row is deleted. */
  unmountInstall(provider: string, installKey: string): Promise<boolean>;
  /**
   * STAGE a pending-connect row for the OAuth flow (D63), sealing the raw chat
   * token under the ticket's nonce. Only providers that connect over OAuth
   * (Slack) use this — the paste flow ships both secrets in ONE `/connect` write
   * and never stages. Absent ⇒ `/connect/pending` answers the opaque 404.
   */
  stagePending?(input: {
    nonce: string;
    workspaceId: string;
    provider: string;
    chatToken: string;
  }): Promise<void>;
  /**
   * The bridge's OWN loopback base URL (e.g. `http://127.0.0.1:4020/connectors`),
   * baked into the `headersHelper` command the `tool-descriptors` route hands the
   * runner (charter D69/D71). The helper POSTs back to `{base}/tool-headers/:provider`
   * to fetch the sealed PAT at MCP-connect. Absent ⇒ the tool routes are the opaque
   * 404 (a bridge with no loopback base cannot mint a working helper).
   */
  toolHeadersBaseUrl?: string;
  now?: () => number;
}

/**
 * The routes, named by the thing they do.
 *
 * `tool-descriptors` / `tool-headers` are the OUTBOUND (tool) direction (D69/D71):
 * the first lists a workspace's tool connectors as MCP descriptors for the runner;
 * the second opens a sealed PAT at MCP-connect. Both are loopback-only, exactly
 * like the paste-connect family.
 */
export type ConnectAction =
  | "validate"
  | "connect"
  | "disconnect"
  | "pending"
  | "tool-descriptors"
  | "tool-headers";

/**
 * A rendered answer — or `null`, meaning "answer the caller's OWN opaque 404".
 *
 * The 404 bytes live in `webhook-server.ts` and are shared with the webhook demux
 * on purpose: an install-enumeration oracle is exactly a 404 that is subtly not the
 * other 404. This module never spells them itself.
 */
export type ConnectReply = { status: number; body: unknown } | null;

/** A refusal that says nothing about whether the workspace/install exists. */
const UNAUTHORIZED: ConnectReply = { status: 401, body: { error: "unauthorized" } };
const BAD_REQUEST: ConnectReply = { status: 400, body: { error: "bad_request" } };

function parseBody(raw: string): Record<string, unknown> | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return null;
  }
  return parsed as Record<string, unknown>;
}

function stringField(body: Record<string, unknown>, key: string): string | null {
  const value = body[key];
  if (typeof value !== "string" || value.trim() === "") return null;
  return value;
}

/**
 * Read the ticket WITHOUT knowing the provider yet.
 *
 * A chicken-and-egg the wire solves for us: the provider is INSIDE the ticket, but
 * `verifyConnectTicket` demands the provider to check `p` against. So we verify
 * twice — once with `p` echoed back to itself (the signature, TTL and shape are all
 * checked; only the provider-mismatch arm is a tautology), then AGAIN, for real,
 * against the provider we resolved from the registry. The second call is what a
 * reader should trust; the first exists only to learn which provider to look up.
 *
 * The alternative — trusting the body's provider — is the hole this design closes.
 */
function readTicket(raw: string, deps: ConnectDeps): ConnectTicket | null {
  const peek = decodeTicketProvider(raw);
  if (peek === null) return null;
  try {
    const options: VerifyConnectTicketOptions = { provider: peek };
    if (deps.now) options.now = deps.now;
    return verifyConnectTicket(raw, deps.secret, options);
  } catch {
    return null;
  }
}

/**
 * Peek at the UNVERIFIED `p` field. Safe ONLY because the very next thing that
 * happens is a full `verifyConnectTicket` against this exact value: if the peek
 * were tampered with, the signature check fails and nothing proceeds. Nothing is
 * trusted on the strength of the peek alone.
 */
function decodeTicketProvider(raw: string): string | null {
  const dot = raw.indexOf(".");
  if (dot <= 0) return null;
  try {
    const json = Buffer.from(raw.slice(0, dot), "base64url").toString("utf8");
    const parsed: unknown = JSON.parse(json);
    if (typeof parsed !== "object" || parsed === null) return null;
    const { p } = parsed as { p?: unknown };
    return typeof p === "string" && p.trim() !== "" ? p : null;
  } catch {
    return null;
  }
}

/**
 * Handle one connect-family request.
 *
 * `rawBody` is the bytes the transport already buffered under its size cap — this
 * module does no I/O of its own beyond the injected deps.
 */
export async function handleConnectRequest(
  action: ConnectAction,
  rawBody: string,
  deps: ConnectDeps,
  pathProvider?: string,
): Promise<ConnectReply> {
  const body = parseBody(rawBody);
  // A malformed body is a 400, never a 500 and never a stack trace.
  if (body === null) return BAD_REQUEST;

  const rawTicket = stringField(body, "ticket");
  if (rawTicket === null) return UNAUTHORIZED;

  // TOOL routes (D69/D71) verify a SESSION ticket bound to the reserved
  // tool-session provider — NOT the paste ticket read below. They select the
  // concrete provider from the route path (tool-headers) or list every one
  // (tool-descriptors); the workspace is proven by the ticket signature.
  if (action === "tool-descriptors") {
    return toolDescriptors(rawTicket, deps);
  }
  if (action === "tool-headers") {
    return toolHeaders(rawTicket, pathProvider, deps);
  }

  const ticket = readTicket(rawTicket, deps);
  if (ticket === null) return UNAUTHORIZED;

  // PENDING is handled BEFORE the `connector.connect` gate: it is the OAuth flow's
  // staging step (Slack has NO paste-mode `connect` member), and it needs nothing
  // from the connector — only a verified ticket and the raw chat token.
  if (action === "pending") return stagePending(body, ticket, deps);

  const connector = deps.registry.get(ticket.provider);
  // An unknown provider, or one that is catalog-visible but NOT connectable
  // (Slack = OAuth, Teams = admin consent, iMessage = self-hosted): the same
  // opaque 404 an unknown route gets. A 4xx that distinguished them would tell a
  // stranger which providers this bridge has registered.
  if (!connector?.connect) return null;

  switch (action) {
    case "validate":
      return validate(body, ticket, connector.connect);
    case "connect":
      return connect(body, ticket, connector, deps);
    case "disconnect":
      return disconnect(body, ticket, deps);
  }
}

/** Verify a tool-session ticket, or `null` — every failure is the same refusal. */
function readToolTicket(raw: string, deps: ConnectDeps): ConnectTicket | null {
  try {
    return verifyToolTicket(raw, deps.secret, deps.now ? { now: deps.now } : {});
  } catch {
    return null;
  }
}

/**
 * TOOL-DESCRIPTORS (D69/D71) — the OUTBOUND direction's list.
 *
 * The runner (Elixir) mints ONE session-length tool ticket and asks: "which MCP
 * servers may this workspace's agent connect to?" We answer with a NON-SECRET
 * descriptor per tool connector the workspace actually has an install of — provider,
 * transport, url, and a `headersHelper` command. The helper carries THIS same
 * ticket and points at our loopback `tool-headers` route, so the PAT is fetched at
 * MCP-connect and NEVER travels through Elixir or sits in the config file (D38).
 */
async function toolDescriptors(
  rawTicket: string,
  deps: ConnectDeps,
): Promise<ConnectReply> {
  const ticket = readToolTicket(rawTicket, deps);
  if (ticket === null) return UNAUTHORIZED;

  // Without a loopback base we cannot mint a working helper — so we mint none.
  // The runner sees an empty list and the agent simply has no tool servers.
  const base = deps.toolHeadersBaseUrl;
  if (base === undefined || base.trim() === "") {
    return { status: 200, body: { descriptors: [] } };
  }

  const descriptors: Array<{
    provider: string;
    type: string;
    url: string;
    headersHelper: string;
  }> = [];

  for (const connector of deps.registry.tools()) {
    const descriptor = connector.toolDescriptor;
    if (!descriptor) continue;
    // Only surface a tool the workspace has actually connected — an install proves
    // both the intent and that there is a sealed PAT for `tool-headers` to open.
    const install = await deps.installs.lookupByWorkspace(
      connector.id,
      ticket.workspaceId,
    );
    if (install === null) continue;

    descriptors.push({
      provider: connector.id,
      type: descriptor.type,
      url: descriptor.url,
      headersHelper: buildHeadersHelper(base, connector.id, rawTicket),
    });
  }

  return { status: 200, body: { descriptors } };
}

/**
 * Build the `headersHelper` command claude runs at MCP-connect (D69/D71).
 *
 * Its STDOUT must be a JSON object of string headers — which is EXACTLY the
 * `tool-headers` route's success body — so the whole helper is one `curl` that
 * POSTs the ticket to that loopback route and prints its response. The ticket is
 * base64url + a single `.` and the provider is a registry id (`[a-z0-9_-]`); both
 * are single-quote-safe, so the JSON body and URL interpolate without a shell
 * injection surface.
 */
function buildHeadersHelper(
  base: string,
  provider: string,
  ticket: string,
): string {
  const url = `${base.replace(/\/+$/, "")}/connect/tool-headers/${provider}`;
  const payload = JSON.stringify({ ticket });
  return `curl -sS -X POST -H 'content-type: application/json' -d '${payload}' ${url}`;
}

/**
 * TOOL-HEADERS (D69/D71) — open ONE workspace's sealed PAT at MCP-connect.
 *
 * The concrete provider comes from the ROUTE path (a non-secret selector), the
 * workspace from the TICKET signature. We open the PAT keyed on `(provider,
 * workspace)` — the seal's AAD binds `workspace_id`, so a row that belongs to a
 * different tenant cannot be opened here. The reply is a flat header object the
 * runner's `headersHelper` prints verbatim into claude's MCP transport.
 *
 * Every failure — bad ticket aside — is the SAME opaque 404 an unknown route gets:
 * unknown provider, a channel provider (no `toolDescriptor`), no install for this
 * workspace, or an install with no sealed credential. None of them reveal whether
 * any given install exists.
 */
async function toolHeaders(
  rawTicket: string,
  pathProvider: string | undefined,
  deps: ConnectDeps,
): Promise<ConnectReply> {
  const ticket = readToolTicket(rawTicket, deps);
  if (ticket === null) return UNAUTHORIZED;

  if (pathProvider === undefined || pathProvider.trim() === "") return null;

  const connector = deps.registry.get(pathProvider);
  // A tool connector, and only a tool connector. A channel provider named here is
  // the opaque 404 — the tool routes must not leak the channel registry either.
  if (!connector?.toolDescriptor) return null;

  const install = await deps.installs.lookupByWorkspace(
    pathProvider,
    ticket.workspaceId,
  );
  if (install === null) return null;

  const stored = install.credentialRef;
  if (stored === null || stored === undefined || stored.trim() === "") return null;

  // REFRESH BEFORE HANDING THE HEADER OUT (charter D90/D92). The connector — not
  // this shared route — owns the whole decision: `refreshCredential` parses its own
  // credential shape, checks its own skew window, and exchanges a fresh token if the
  // stored one is expiring. The route stays provider-agnostic; GitHub (no hook) and
  // a Linear bundle still comfortably inside its life both fall straight through.
  //
  // On success the re-sealed bundle is written back via `upsertInstall` (blind LWW,
  // NEVER a pinned CAS — a rotating refresh exchange is non-replayable, so a lost
  // pin would discard the fresh bundle and brick the install, D91) and the fresh
  // credential builds the Bearer. On FAILURE we serve the STORED credential and log
  // LOUDLY (serve-stale-loud, D90): a failed refresh must degrade to a maybe-stale
  // header, never to a hard connect failure. There is NO on-401 leg — the bridge
  // only prints headers, so it never observes the provider's 401.
  let credentialRef = stored;
  if (deps.upsertInstall && connector.refreshCredential) {
    const now = deps.now ? deps.now() : Date.now();
    try {
      const fresh = await connector.refreshCredential(install, { now });
      if (fresh !== null) {
        // Use the fresh credential for THIS connect regardless of the write-back
        // outcome — the token is already minted and valid.
        credentialRef = fresh;
        try {
          await deps.upsertInstall({
            provider: install.provider,
            installKey: install.installKey,
            workspaceId: install.workspaceId,
            // PLAINTEXT bundle in — upsertInstall does the ONE seal (AAD bpc2). NO
            // `chatToken` key: absent means PRESERVE, and D52's CASE keeps a tool
            // install's `chat_token_ref` NULL (same workspaceId, so nothing moves).
            credentialRef: fresh,
          });
        } catch (writeError) {
          console.error(
            `[tool-headers] refreshed ${install.provider} install=${install.installKey} ` +
              `workspace=${install.workspaceId} but FAILED to persist the re-sealed ` +
              `bundle — the fresh token is served this connect; the next refresh will ` +
              `retry against the previous refresh_token (Linear's ~30-min grace covers ` +
              `the common case):`,
            writeError,
          );
        }
      }
    } catch (refreshError) {
      console.error(
        `[tool-headers] credential refresh FAILED for ${install.provider} ` +
          `install=${install.installKey} workspace=${install.workspaceId} — serving ` +
          `the STORED credential (it may be stale and 401 at the provider until the ` +
          `next successful refresh; re-connect the install if this persists):`,
        refreshError,
      );
    }
  }

  // The runner's headersHelper prints THIS object straight into claude's MCP
  // config as the server's request headers. A flat { header: string } map is the
  // shape claude 2.1.209 requires.
  return {
    status: 200,
    body: { Authorization: `Bearer ${bearerFromCredentialRef(credentialRef)}` },
  };
}

/**
 * Extract the Bearer value from a stored `credential_ref` (charter D89) — the ONE
 * generic, shape-blind discriminator that makes the dual-shape credential additive
 * forever.
 *
 * A trimmed value that starts with `{` AND parses as a JSON object with a non-empty
 * string `access_token` is an OAUTH BUNDLE — the Bearer is `.access_token`. ANYTHING
 * else — a bare paste PAT (GitHub), malformed JSON, a JSON array, a JSON object
 * without a usable `access_token` — passes through BYTE-FOR-BYTE as the bare bearer.
 *
 * This NEVER throws: a malformed-JSON legacy credential must not 500 the tool route.
 * And it is byte-for-byte on the fall-through path (the raw value, never the trimmed
 * one), so a GitHub PAT — pinned by `tool-descriptors.test.ts` — stays identical.
 */
function bearerFromCredentialRef(credentialRef: string): string {
  const trimmed = credentialRef.trim();
  if (trimmed.startsWith("{")) {
    try {
      const parsed: unknown = JSON.parse(trimmed);
      if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
        const accessToken = (parsed as { access_token?: unknown }).access_token;
        if (typeof accessToken === "string" && accessToken.trim() !== "") {
          return accessToken;
        }
      }
    } catch {
      // Malformed JSON: fall through and serve the raw string byte-for-byte.
    }
  }
  return credentialRef;
}

/**
 * STAGE — seal the raw chat token into a pending-connect row under the ticket's
 * nonce (D63), so the public OAuth callback can join it after Slack redirects.
 *
 * The provider comes from the TICKET, never the body, and the chat token rides
 * THIS loopback body once — never logged, never echoed, never a URL. If the bridge
 * was not built with a `stagePending` (no OAuth channel configured) the route is
 * the same opaque 404 as any unknown one.
 */
async function stagePending(
  body: Record<string, unknown>,
  ticket: ConnectTicket,
  deps: ConnectDeps,
): Promise<ConnectReply> {
  if (!deps.stagePending) return null;

  const chatToken = stringField(body, "chat_token");
  if (chatToken === null) return BAD_REQUEST;
  if (!ticket.nonce || ticket.nonce.trim() === "") return BAD_REQUEST;

  await deps.stagePending({
    nonce: ticket.nonce,
    workspaceId: ticket.workspaceId,
    provider: ticket.provider,
    chatToken,
  });

  return { status: 200, body: { ok: true, provider: ticket.provider } };
}

/** VALIDATE — the provider says yes or no, and NOTHING is written either way. */
async function validate(
  body: Record<string, unknown>,
  ticket: ConnectTicket,
  connect: ConnectorConnect,
): Promise<ConnectReply> {
  const credential = stringField(body, "credential");
  if (credential === null) return BAD_REQUEST;

  const verdict = await connect.validate(credential);
  if (!verdict.ok) {
    // 422, not 401: the ticket was fine, the CREDENTIAL was not — and the operator
    // needs to be told which, or "connect" becomes a coin flip. The reason comes
    // from the connector and is written for a human (see telegram.ts/discord.ts);
    // it never carries the credential back.
    return {
      status: 422,
      body: { error: "invalid_credential", reason: verdict.reason },
    };
  }

  return {
    status: 200,
    body: {
      ok: true,
      provider: ticket.provider,
      install_key: verdict.installKey,
      display_name: verdict.displayName,
    },
  };
}

/**
 * CONNECT — validate again (server-side), write ONE row with BOTH secrets, mount
 * it LIVE.
 *
 * The two secrets land in a SINGLE `upsertInstall`, which is what makes the D52
 * conditional-preserve unnecessary here and load-bearing everywhere else: this
 * caller always supplies both, so it never relies on preservation — while the
 * Slack OAuth callback, which supplies only one, now relies on it completely.
 */
async function connect(
  body: Record<string, unknown>,
  ticket: ConnectTicket,
  connector: Connector,
  deps: ConnectDeps,
): Promise<ConnectReply> {
  const connectSpec = connector.connect;
  // Reached only through the `connector.connect` gate in handleConnectRequest.
  if (!connectSpec) return null;

  // A TOOL connector (GitHub, D69) seals ONLY its provider credential — the PAT.
  // It has no chat token (its `chat_token_ref` stays NULL) and no Chat to mount
  // (`registry.channels()` excludes it), so the flow BRANCHES ON DIRECTION, never
  // on the provider id. A channel connector still needs both secrets and a live
  // mount, exactly as before.
  const isTool = connector.direction === "tool";

  const credential = stringField(body, "credential");
  const chatToken = stringField(body, "chat_token");
  // Both a channel's chat token and a tool's absence of one are required shapes:
  // a channel with no chat_token is a 400; a tool that supplied one is ignored
  // (it has nowhere to go — `chat_token_ref` is NULL for a tool install).
  if (credential === null) return BAD_REQUEST;
  if (!isTool && chatToken === null) return BAD_REQUEST;

  // NEVER trust `body.install_key`. The key is whatever the PROVIDER says this
  // credential is — anything else lets a valid ticket seize another workspace's
  // row, because the upsert's ON CONFLICT would then repoint its workspace_id.
  const verdict = await connectSpec.validate(credential);
  if (!verdict.ok) {
    return {
      status: 422,
      body: { error: "invalid_credential", reason: verdict.reason },
    };
  }

  // AND NEVER OVERWRITE ANOTHER TENANT'S ROW. `UPSERT_INSTALL` sets
  // `workspace_id = EXCLUDED.workspace_id` unconditionally, so without this check a
  // connect against an install key that already belongs to workspace A would REPOINT
  // A's row to B — A's adapter is taken down by `addInstall`, A's sealed chat token
  // is replaced, and A's install simply disappears. Nothing about that is a leak (the
  // AAD sees to it that no secret of A's ever opens for B) but it is a silent
  // cross-tenant DESTRUCTION, and the operator on the other end deserves to be told
  // what happened rather than to succeed at it.
  //
  // `resolveWorkspace`, deliberately, not `lookupInstall`: it reads `workspace_id`
  // ALONE, so a row whose seals no longer open (a botched key rotation) still guards
  // its tenant instead of silently becoming free real estate.
  //
  // This is NOT an enumeration oracle: reaching this line already required a valid
  // ticket (Studio + workspace-admin) AND a credential the PROVIDER just
  // authenticated as owning this exact install key. Someone holding the bot's live
  // credential learning "this bot is connected to another workspace" learns nothing
  // they could not learn from the bot — and it is the only message that lets them
  // act (disconnect it there first).
  const owner = await deps.installs.resolveWorkspace(
    ticket.provider,
    verdict.installKey,
  );
  if (owner !== null && owner !== ticket.workspaceId) {
    return {
      status: 409,
      body: {
        error: "install_owned_elsewhere",
        reason:
          "that bot is already connected to a different Barkpark workspace. " +
          "Disconnect it there first — moving it from here would silently take the " +
          "other workspace's install down.",
      },
    };
  }

  const install: ConnectorInstall = {
    provider: ticket.provider,
    installKey: verdict.installKey,
    workspaceId: ticket.workspaceId,
    credentialRef: credential,
    // A tool install has no chat token — `chat_token_ref` stays NULL. A channel
    // install carries the workspace-bound token its /v1/chat traffic travels on.
    ...(isTool ? {} : { chatToken }),
  };

  await deps.upsertInstall(install);

  // A TOOL install is never mounted as a Chat (D69): it has no inbound transport,
  // and the agent reaches its service through the MCP `tool-descriptors` seam, not
  // through this bridge. The write IS the connect — there is nothing to bring up.
  if (isTool) {
    return {
      status: 200,
      body: {
        ok: true,
        provider: install.provider,
        install_key: install.installKey,
        workspace_id: install.workspaceId,
        display_name: verdict.displayName,
        mounted: false,
      },
    };
  }

  try {
    // Live, with no restart. The very next message from the channel routes.
    await deps.mountInstall(install);
  } catch (error) {
    // The credential satisfied the provider's API but the adapter refused it.
    // Leaving the row would plant precisely the install that crash-loops the unit
    // at the next boot (D53) — and would tell the operator "connected" about a bot
    // that will never answer. Roll the write back and say so.
    //
    // NAMED COST, because it is not free: when this was a RE-connect, the delete
    // takes the PREVIOUS install with it. That is not a choice we get to make here
    // — `upsertInstall` has already overwritten the old credential and
    // `addInstall` has already taken the old Chat down, so by this line the prior
    // install no longer exists to restore. The operator re-pastes. Restoring it
    // instead would mean reading the row back before writing (a lost-update race)
    // or keeping a plaintext copy of the old secret in memory; a re-paste is
    // cheaper than either, and the 502 says exactly what happened.
    console.error(
      `[connect] mount FAILED for ${install.provider} install=${install.installKey} ` +
        `workspace=${install.workspaceId} — deleting the row just written:`,
      error,
    );
    try {
      await deps.deleteInstall(install.provider, install.installKey);
    } catch (cleanupError) {
      // Now it IS a row that boots badly. Say so loudly — this is the one state
      // this route cannot fix by itself.
      console.error(
        `[connect] could NOT delete the row after a failed mount — ` +
          `${install.provider}/${install.installKey} is written but unmounted:`,
        cleanupError,
      );
    }
    return {
      status: 502,
      body: {
        error: "mount_failed",
        reason:
          "the credential was accepted by the provider but the adapter refused to " +
          "mount it. Nothing was installed.",
      },
    };
  }

  return {
    status: 200,
    body: {
      ok: true,
      provider: install.provider,
      install_key: install.installKey,
      workspace_id: install.workspaceId,
      display_name: verdict.displayName,
      mounted: true,
    },
  };
}

/**
 * DISCONNECT — unmount, then DELETE the row.
 *
 * In that order, and it matters: unrouting first means an in-flight webhook cannot
 * reach a Chat whose credential is about to vanish. Deleting the ROW (rather than
 * nulling its secrets) is what makes the disconnect survive a restart — before this
 * wave `removeInstall` was in-memory only, so the next boot re-read the row and
 * mounted the "disconnected" bot straight back.
 *
 * Revoking the chat token itself is STUDIO's half of the promise (`Auth.revoke_token`,
 * keyed by the `connector:<provider>:<install_key>` label it minted). The bridge
 * holds no Barkpark credential and could not revoke anything if it wanted to.
 */
async function disconnect(
  body: Record<string, unknown>,
  ticket: ConnectTicket,
  deps: ConnectDeps,
): Promise<ConnectReply> {
  const installKey = stringField(body, "install_key");
  if (installKey === null) return BAD_REQUEST;

  const install = await deps.installs.lookupInstall(ticket.provider, installKey);

  // No such install — OR an install belonging to somebody else. ONE answer, and it
  // is the same one an unknown route gets: a cross-tenant disconnect must be
  // unrepresentable, not merely untaken, and a distinguishable refusal would turn
  // this route into an install-enumeration oracle for every other tenant.
  //
  // `lookupInstall` returns null for a row whose seals do not open, too, and that
  // is a row nobody can disconnect through this route. It is also a row nothing can
  // MOUNT (`toInstall` drops it), so it is inert rather than dangerous; cleaning it
  // up is an operator action against the table.
  if (install === null || install.workspaceId !== ticket.workspaceId) return null;

  await deps.unmountInstall(ticket.provider, installKey);
  const removed = await deps.deleteInstall(ticket.provider, installKey);

  return {
    status: 200,
    body: {
      ok: true,
      provider: ticket.provider,
      install_key: installKey,
      removed,
    },
  };
}
