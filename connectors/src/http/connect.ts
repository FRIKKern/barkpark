import {
  verifyConnectTicket,
  type ConnectTicket,
  type VerifyConnectTicketOptions,
} from "../connect/ticket.js";
import type { ConnectorRegistry } from "../connector/registry.js";
import type {
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
  now?: () => number;
}

/** The three routes, named by the thing they do. */
export type ConnectAction = "validate" | "connect" | "disconnect";

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
): Promise<ConnectReply> {
  const body = parseBody(rawBody);
  // A malformed body is a 400, never a 500 and never a stack trace.
  if (body === null) return BAD_REQUEST;

  const rawTicket = stringField(body, "ticket");
  if (rawTicket === null) return UNAUTHORIZED;

  const ticket = readTicket(rawTicket, deps);
  if (ticket === null) return UNAUTHORIZED;

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
      return connect(body, ticket, connector.connect, deps);
    case "disconnect":
      return disconnect(body, ticket, deps);
  }
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
  connectSpec: ConnectorConnect,
  deps: ConnectDeps,
): Promise<ConnectReply> {
  const credential = stringField(body, "credential");
  const chatToken = stringField(body, "chat_token");
  if (credential === null || chatToken === null) return BAD_REQUEST;

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
    chatToken,
  };

  await deps.upsertInstall(install);

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
