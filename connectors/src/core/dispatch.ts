import type { ChatClient } from "../chat-client/types.js";
import type { ConnectorRegistry } from "../connector/registry.js";
import type { InboundEvent, TenantContext } from "../connector/types.js";
import type { ThreadSessionMap } from "../state/thread-session-map.js";
import {
  runTurn,
  type RunTurnResultHook,
  type TurnResult,
} from "../turn/turn-loop.js";

/**
 * THE CORE LOOP (charter D30). This is the spine of the whole epic:
 *
 *   inbound event
 *     -> connector.resolveTenant   (which workspace? fail closed)
 *     -> map.resolveOrMint          (which Session? mint once, resume after)
 *     -> runTurn                    (send + consume SSE, accumulate)
 *     -> reply                      (thread.post — exactly ONCE)
 *
 * Nothing in here names a channel. Adding Slack/Discord/Teams/WhatsApp in P3
 * is a registry entry — this file does not change. That invariant IS the
 * acceptance bar for P2.
 *
 * Every step fails closed. An unknown connector, an unresolvable tenant, or an
 * empty turn produces a typed outcome, never a message posted to the wrong
 * workspace and never an invented reply.
 */

export type DispatchStatus =
  | "posted" // a turn ran and its reply was posted exactly once
  | "dropped_unknown_connector" // event for a provider nobody registered
  | "dropped_no_tenant" // could not resolve a workspace — fail closed
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
  /** (provider, install_key) -> workspace. Fail-closed lookups. */
  installs: TenantContext;
  /** The thread -> Session map (the bridge's only per-conversation state). */
  map: ThreadSessionMap;
  /**
   * A ChatClient bound to THAT workspace's token. Per-tenant isolation is
   * enforced by the token itself, server-side — not by bridge bookkeeping.
   */
  chatClientFor(workspaceId: string): ChatClient | Promise<ChatClient>;
  /** Post the reply to the channel. Called at most ONCE per event (D12/D26). */
  reply(text: string): Promise<void>;
  /** Ack hook (D21) — fired on 202, NOT a channel post. */
  onAck?: () => void | Promise<void>;
  /** Seam for tests. Defaults to the real turn loop. */
  runTurnImpl?: RunTurnResultHook;
  timeoutMs?: number;
  signal?: AbortSignal;
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
  //    payload-team-id for Slack); the loop only cares that it fails closed.
  const workspaceId = await connector.resolveTenant(event, deps.installs);
  if (!workspaceId) return { status: "dropped_no_tenant" };

  const client = await deps.chatClientFor(workspaceId);

  // 2. Which Session? Mint on first contact, resume forever after. This is the
  //    ONLY per-conversation state the bridge holds (D6).
  const { sessionUuid, minted } = await deps.map.resolveOrMint(
    workspaceId,
    event.threadId,
    async () => (await client.createSession()).id,
  );

  // 3. Run the turn: send, consume the SSE stream, accumulate to one string.
  const run = deps.runTurnImpl ?? runTurn;
  const turn = await run(client, {
    sessionUuid,
    content: text,
    ...(deps.onAck ? { onAck: deps.onAck } : {}),
    ...(deps.timeoutMs !== undefined ? { timeoutMs: deps.timeoutMs } : {}),
    ...(deps.signal ? { signal: deps.signal } : {}),
  });

  // 4. Post ONCE. An empty reply is posted as nothing at all — Telegram
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
