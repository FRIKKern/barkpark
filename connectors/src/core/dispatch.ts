import type { ChatClient } from "../chat-client/types.js";
import type { ConnectorRegistry } from "../connector/registry.js";
import type {
  AuthorizedInstall,
  ConnectorInstall,
  InboundEvent,
  InstallsLookup,
  TenantContext,
  WorkspaceId,
} from "../connector/types.js";
import type { ThreadSessionMap } from "../state/thread-session-map.js";
import {
  runTurn,
  type RunTurnResultHook,
  type TurnResult,
} from "../turn/turn-loop.js";

/**
 * THE CORE LOOP (charter D30/D35). This is the spine of the whole epic:
 *
 *   inbound event
 *     -> connector.resolveTenant   (which workspace? fail closed)
 *     -> the routed INSTALL row    (which credential? THE SAME ROW, fail closed)
 *     -> map.resolveOrMint          (which Session? mint once, resume after)
 *     -> runTurn                    (send + consume SSE, accumulate)
 *     -> reply                      (thread.post — exactly ONCE)
 *
 * Nothing in here names a channel. Adding Slack/Discord/Teams/WhatsApp in P3
 * is a registry entry — this file does not change. That invariant IS the
 * acceptance bar for P2.
 *
 * Every step fails closed. An unknown connector, an unresolvable tenant, an
 * install with no chat token, or an empty turn produces a typed outcome — never
 * a message posted to the wrong workspace, never an invented reply, and never a
 * request sent on a token that belongs to somebody else.
 *
 * ## The token comes from the row that routed the event
 *
 * P2 called `chatClientFor(workspaceId)` — and the only implementation IGNORED
 * its argument, handing every tenant the same operator token. Routing was
 * per-tenant; the credential was not. Now the loop mints a client from the
 * INSTALL: `chatClientForInstall(install)`. The token and the routing key are two
 * columns of one row, so "workspace A's traffic on workspace B's token" is not a
 * bug you can introduce here — it is a state you cannot construct.
 */

export type DispatchStatus =
  | "posted" // a turn ran and its reply was posted exactly once
  | "dropped_unknown_connector" // event for a provider nobody registered
  | "dropped_no_tenant" // could not resolve a workspace — fail closed
  | "dropped_no_install" // workspace resolved, but its install row is unusable
  | "dropped_no_chat_token" // install has no Barkpark chat token — fail closed
  | "dropped_empty_input" // inbound message had no text to send
  | "empty_reply"; // the turn produced no text; we post nothing rather than ""

export interface DispatchOutcome {
  status: DispatchStatus;
  workspaceId?: string;
  sessionUuid?: string;
  /** True when THIS event created the thread's Session. */
  minted?: boolean;
  /** The text posted (only when status === "posted"). */
  text?: string;
  turn?: TurnResult;
}

export interface DispatchDeps {
  registry: ConnectorRegistry;
  /** (provider, install_key) -> workspace + sealed secrets. Fail-closed lookups. */
  installs: TenantContext;
  /** The thread -> Session map (the bridge's only per-conversation state). */
  map: ThreadSessionMap;
  /**
   * A ChatClient bound to THIS INSTALL's own chat token — the one sealed in the
   * row that routed this event. Per-tenant isolation is enforced by the token
   * itself, server-side (a `chat` ApiToken carries its workspace_id), not by
   * bridge bookkeeping.
   *
   * Takes an {@link AuthorizedInstall}: the type has already proven the token is
   * present, so no implementation can be handed a tokenless install and quietly
   * substitute an operator one.
   */
  chatClientForInstall(
    install: AuthorizedInstall,
  ): ChatClient | Promise<ChatClient>;
  /** Post the reply to the channel. Called at most ONCE per event (D12/D26). */
  reply(text: string): Promise<void>;
  /** Ack hook (D21) — fired on 202, NOT a channel post. */
  onAck?: () => void | Promise<void>;
  /**
   * Persist the moment this inbound arrived, keyed on the RESOLVED workspace and
   * thread (D178). Generic like {@link onAck}: dispatch never names a channel —
   * the connector supplies the vendor timestamp via `inboundTimestampMs`, this
   * hook writes it wherever the channel's policy state lives (WhatsApp's durable
   * 24-hour window). Optional: connectors with no timestamp-driven policy leave it
   * unset and no write happens.
   */
  recordInbound?(
    workspaceId: string,
    threadId: string,
    atMs: number,
  ): void | Promise<void>;
  /** Seam for tests. Defaults to the real turn loop. */
  runTurnImpl?: RunTurnResultHook;
  timeoutMs?: number;
  signal?: AbortSignal;
}

/**
 * The install a connector's `resolveTenant` actually routed on.
 *
 * A connector knows how to find its install key — from the transport that
 * received the event (credential-bound) or from the payload (payload-team-id) —
 * and the core deliberately does not. So instead of asking the core to guess the
 * key (it cannot) or asking every connector to return one (a contract change that
 * every P3 channel would have to implement), we WITNESS the lookup: the core
 * hands the connector an `InstallsLookup` that records which key resolved to
 * which workspace, then reads back the key that produced the winning workspace.
 *
 * Consequences that matter:
 *   - the credential is fetched with the SAME (provider, install_key) the routing
 *     decision was made on. Not "an install of this provider in this workspace" —
 *     THE row. A workspace with two bots gets the right one.
 *   - a connector that resolves a tenant WITHOUT consulting the lookup (i.e. from
 *     thin air) witnesses nothing, so the event drops. Fail closed by default.
 *   - a connector that probes several keys is fine: we bind to the one whose
 *     workspace it actually returned, and refuse if that is ambiguous.
 *   - zero core-loop change when a channel is added. The witness is generic.
 */
interface Witness {
  lookup: InstallsLookup;
  /** The install key(s) that resolved to `workspaceId`, deduped. */
  keysFor(provider: string, workspaceId: WorkspaceId): string[];
}

function witnessInstalls(inner: InstallsLookup): Witness {
  const seen: Array<{
    provider: string;
    installKey: string;
    workspaceId: WorkspaceId;
  }> = [];

  const record = (
    provider: string,
    installKey: string | null | undefined,
    workspaceId: WorkspaceId | null,
  ) => {
    if (workspaceId === null || installKey === null || installKey === undefined) {
      return;
    }
    seen.push({ provider, installKey, workspaceId });
  };

  return {
    lookup: {
      async lookupInstall(provider, installKey) {
        const install = await inner.lookupInstall(provider, installKey);
        record(provider, installKey, install?.workspaceId ?? null);
        return install;
      },
      async resolveWorkspace(provider, installKey) {
        const workspaceId = await inner.resolveWorkspace(provider, installKey);
        record(provider, installKey, workspaceId);
        return workspaceId;
      },
      listInstalls(provider) {
        return inner.listInstalls(provider);
      },
      // Tool-connector reads (D69) never flow through inbound dispatch, but the
      // witnessing wrapper must satisfy the full lookup shape — delegate as-is.
      lookupByWorkspace(provider, workspaceId) {
        return inner.lookupByWorkspace(provider, workspaceId);
      },
    },

    keysFor(provider, workspaceId) {
      const keys = seen
        .filter((s) => s.provider === provider && s.workspaceId === workspaceId)
        .map((s) => s.installKey);
      return [...new Set(keys)];
    },
  };
}

export async function dispatchInbound(
  event: InboundEvent,
  deps: DispatchDeps,
): Promise<DispatchOutcome> {
  const connector = deps.registry.get(event.provider);
  if (!connector) return { status: "dropped_unknown_connector" };

  const text = event.text?.trim() ?? "";
  if (text === "") return { status: "dropped_empty_input" };

  // 1. Which tenant? The connector decides HOW (credential-bound for Telegram,
  //    payload-team-id for Slack); the loop only cares that it fails closed —
  //    and that it tells us, by using the lookup, WHICH row it decided on.
  const witness = witnessInstalls(deps.installs.installs);
  const witnessedCtx: TenantContext = {
    ...deps.installs,
    installs: witness.lookup,
  };

  const resolved = await connector.resolveTenant(event, witnessedCtx);
  // Normalise a blank/whitespace "tenant" from a sloppy connector to a hard miss,
  // the same way tenant/resolve.ts's core router does.
  const workspaceId =
    typeof resolved === "string" && resolved.trim() !== "" ? resolved : null;
  if (!workspaceId) return { status: "dropped_no_tenant" };

  // 1b. The window opened the moment the user spoke — so persist it HERE, keyed on
  //     the RESOLVED workspace, BEFORE the credential/session/turn steps. A turn
  //     that later drops (no_install / no_chat_token / empty_reply) or throws must
  //     not lose the fact that the human reached out. A null vendor timestamp falls
  //     back to Date.now() — never skip the write (a skip reads as window-CLOSED and
  //     defeats the store; now() is monotonically safe under the GREATEST upsert).
  //     Meta REDELIVERS a webhook it thinks failed, so the same inbound may record
  //     twice; the store's monotonic upsert makes that a no-op, never a regression.
  //     AWAITED in a try/catch that SWALLOWS (D188): a throwing store must never
  //     propagate into handle()'s failure-notice path and suppress the reply —
  //     persistence infrastructure never takes down the reply path. Awaited, not
  //     fire-and-forget, so the write is deterministically complete (not racing a
  //     test's drain) by the time dispatch resolves.
  try {
    await deps.recordInbound?.(
      workspaceId,
      event.threadId,
      connector.inboundTimestampMs?.(event.payload) ?? Date.now(),
    );
  } catch (err) {
    console.warn(
      `[bridge] recordInbound failed for ${event.provider} workspace=${workspaceId} ` +
        `thread=${event.threadId} — the window was not persisted, but the reply path ` +
        `is untouched (D188):`,
      err,
    );
  }

  // 2. Which credential? The install the connector ACTUALLY routed on — same
  //    (provider, install_key) row, so the token cannot drift from the routing.
  const install = await routedInstall(event.provider, workspaceId, witness, deps);
  if (!install) return { status: "dropped_no_install", workspaceId };

  // 3. This install's OWN Barkpark chat token, or nothing at all. There is no
  //    operator-token fallback: an install without a token is inert, and the
  //    event drops BEFORE a single HTTP call is made.
  if (!isAuthorized(install)) {
    console.warn(
      `[bridge] install ${install.provider}/${install.installKey} ` +
        `(workspace=${install.workspaceId}) has no chat token — dropping the turn. ` +
        "Provision a workspace-bound `chat` ApiToken into chat_bridge." +
        "connector_installs.chat_token_ref; the bridge will NOT fall back to an " +
        "operator token.",
    );
    return { status: "dropped_no_chat_token", workspaceId };
  }

  const client = await deps.chatClientForInstall(install);

  // 4. Which Session? Mint on first contact, resume forever after. This is the
  //    ONLY per-conversation state the bridge holds (D6).
  const { sessionUuid, minted } = await deps.map.resolveOrMint(
    workspaceId,
    event.threadId,
    async () => (await client.createSession()).id,
  );

  // 5. Run the turn: send, consume the SSE stream, accumulate to one string.
  const run = deps.runTurnImpl ?? runTurn;
  const turn = await run(client, {
    sessionUuid,
    content: text,
    ...(deps.onAck ? { onAck: deps.onAck } : {}),
    ...(deps.timeoutMs !== undefined ? { timeoutMs: deps.timeoutMs } : {}),
    ...(deps.signal ? { signal: deps.signal } : {}),
  });

  // 6. Post ONCE. An empty reply is posted as nothing at all — Telegram
  //    rejects empty messages, and a "" bubble is worse than silence.
  if (turn.text === "") {
    return { status: "empty_reply", workspaceId, sessionUuid, minted, turn };
  }

  await deps.reply(turn.text);

  return {
    status: "posted",
    workspaceId,
    sessionUuid,
    minted,
    text: turn.text,
    turn,
  };
}

/** A ConnectorInstall whose chat token is present. The only shape that may call out. */
function isAuthorized(install: ConnectorInstall): install is AuthorizedInstall {
  return typeof install.chatToken === "string" && install.chatToken.trim() !== "";
}

/**
 * Fetch the install the connector routed on — never "some install of this
 * provider in this workspace".
 *
 * The distinction is not academic: one workspace may run two bots of the same
 * provider (a staging bot and a live one), and picking the wrong row would mount
 * the wrong credential and send the turn on the wrong token. So the key comes
 * from the witness, and an ambiguous witness (a connector that resolved the same
 * workspace from two different keys) fails CLOSED rather than picking one.
 */
async function routedInstall(
  provider: string,
  workspaceId: WorkspaceId,
  witness: Witness,
  deps: DispatchDeps,
): Promise<ConnectorInstall | null> {
  const keys = witness.keysFor(provider, workspaceId);

  if (keys.length === 0) {
    console.warn(
      `[bridge] ${provider} resolved workspace=${workspaceId} without consulting ` +
        "the installs lookup — there is no row to take a credential from. Dropping. " +
        "A connector's resolveTenant must route through ctx.installs (see tenant/resolve.ts).",
    );
    return null;
  }
  if (keys.length > 1) {
    console.warn(
      `[bridge] ${provider} resolved workspace=${workspaceId} from ${keys.length} ` +
        "different install keys — ambiguous, so we cannot say which credential this " +
        "turn belongs to. Dropping rather than guessing.",
    );
    return null;
  }

  return deps.installs.installs.lookupInstall(provider, keys[0] as string);
}
