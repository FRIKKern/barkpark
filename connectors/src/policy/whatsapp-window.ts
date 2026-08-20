/**
 * WhatsApp's 24-hour customer-service window — as a POLICY WE OWN (charter D43).
 *
 * Meta's rule: a business may send FREE-FORM messages to a user only within 24 hours of
 * that user's last inbound message. Outside it, the only thing the Cloud API accepts is
 * a pre-approved TEMPLATE. The adapter states plainly that it "does not auto-substitute
 * templates for outbound text posts" — so if we do nothing, the window is a RUNTIME
 * DISCOVERY: a send fails at Meta, in production, with a user waiting.
 *
 * So the decision is made HERE, before any API call, by a pure function over one
 * timestamp. No live number is needed to test it, and none was used.
 *
 * The three rules, in order of how much they matter:
 *
 *   1. **Never auto-substitute.** Outside the window a free-form send is REFUSED. The
 *      caller may pass an explicit approved template, and only then is a template sent.
 *      Silently turning someone's sentence into `appointment_reminder` is worse than a
 *      clean drop.
 *   2. **Unknown means closed.** No recorded inbound (a fresh process, a thread we have
 *      never seen) is `outside-24h-window`, not "probably fine". Fail closed.
 *   3. **The reply path is never affected.** A turn is a reply to an inbound message
 *      that arrived seconds ago, so it is always inside the window. This policy exists
 *      for BUSINESS-INITIATED sends (a proactive agent, a scheduled nudge) — which is
 *      exactly the path that would otherwise fail in production.
 */

/** Meta's window: 24 hours from the user's last inbound message. */
export const WHATSAPP_WINDOW_MS = 24 * 60 * 60 * 1000;

export type WhatsappWindowDecision =
  | {
      allowed: true;
      kind: "free-form";
      /** The inbound that opened the window. */
      lastInboundAt: number;
      /** When free-form sending stops being possible. */
      expiresAt: number;
      remainingMs: number;
    }
  | {
      allowed: false;
      kind: "outside-24h-window";
      /**
       * `no-inbound-recorded` — we have never seen this user speak in this thread (or
       * the bridge restarted and lost the in-memory record). Fail closed.
       * `window-expired` — they spoke, but more than `windowMs` ago.
       */
      reason: "no-inbound-recorded" | "window-expired";
      lastInboundAt: number | null;
      /** When it closed. Null when there was never an inbound to open it. */
      expiredAt: number | null;
    };

export interface WhatsappWindowInput {
  /** Epoch ms of the user's last inbound message in this thread; null when unknown. */
  lastInboundAt: number | null | undefined;
  /** Epoch ms "now" — injected, so the tests use fake timestamps and no clock. */
  now: number;
  /** Override the window (tests; Meta could change it). Defaults to 24h. */
  windowMs?: number;
}

/**
 * The whole policy, as one pure function.
 *
 * Boundary: the window is `elapsed < windowMs`. At EXACTLY 24h it is closed — Meta's
 * cutoff is inclusive of the boundary against us, and being one millisecond optimistic
 * buys a failed send.
 *
 * Clock skew: an inbound stamped in the future (a provider clock ahead of ours) is
 * treated as "just now" rather than as a negative age, so a skewed clock can never
 * silently *close* a window that is genuinely open. It can never *open* one either —
 * `lastInboundAt` only ever comes from a real inbound message we received.
 */
// @canonical capability:whatsapp-24h-window aka:whatsapp,24h,session-window,template,outside-24h-window doc:docs/ops/whatsapp-meta.md
export function decideWhatsappWindow(
  input: WhatsappWindowInput,
): WhatsappWindowDecision {
  const windowMs = input.windowMs ?? WHATSAPP_WINDOW_MS;
  const lastInboundAt = input.lastInboundAt;

  if (
    lastInboundAt === null ||
    lastInboundAt === undefined ||
    !Number.isFinite(lastInboundAt)
  ) {
    return {
      allowed: false,
      kind: "outside-24h-window",
      reason: "no-inbound-recorded",
      lastInboundAt: null,
      expiredAt: null,
    };
  }

  const elapsed = Math.max(0, input.now - lastInboundAt);
  if (elapsed >= windowMs) {
    return {
      allowed: false,
      kind: "outside-24h-window",
      reason: "window-expired",
      lastInboundAt,
      expiredAt: lastInboundAt + windowMs,
    };
  }

  return {
    allowed: true,
    kind: "free-form",
    lastInboundAt,
    expiresAt: lastInboundAt + windowMs,
    remainingMs: windowMs - elapsed,
  };
}

/**
 * Last-inbound-at per `(workspace_id, thread_id)`.
 *
 * Keyed by the SAME composite the `thread_session_map` uses — never by `thread_id`
 * alone. Two workspaces' threads can collide on a provider thread id; a single-column
 * key would let one tenant's inbound open another tenant's send window.
 */
export interface WhatsappWindowStore {
  getLastInboundAt(workspaceId: string, threadId: string): Promise<number | null>;
  recordInbound(workspaceId: string, threadId: string, atMs: number): Promise<void>;
}

/**
 * In-memory store. Deliberately the ONLY implementation this slice ships.
 *
 * On restart every window reads as `no-inbound-recorded` — i.e. CLOSED. That is the
 * safe direction (a refused proactive send, never a rejected one), and it is why an
 * in-memory store is honest rather than a stub: the reply path never consults it, so
 * nothing user-visible degrades.
 *
 * Durable last-inbound now ships: {@link createPgWhatsappWindowStore} (a
 * `chat_bridge.whatsapp_window` row) survives a restart and implements this exact
 * interface. That store is STORE-ONLY (charter D169) — feeding it from the webhook seam
 * is the still-open `connectors-whatsapp-window-wiring`, so this in-memory store remains
 * the wired default until then.
 */
export function createInMemoryWhatsappWindowStore(): WhatsappWindowStore {
  // JSON-encoded pair, so no separator character can be smuggled across the composite.
  const key = (workspaceId: string, threadId: string): string =>
    JSON.stringify([workspaceId, threadId]);
  const table = new Map<string, number>();

  return {
    async getLastInboundAt(workspaceId, threadId) {
      return table.get(key(workspaceId, threadId)) ?? null;
    },
    async recordInbound(workspaceId, threadId, atMs) {
      const existing = table.get(key(workspaceId, threadId));
      // Monotonic: an out-of-order webhook must never move the window BACKWARDS.
      if (existing !== undefined && existing >= atMs) return;
      table.set(key(workspaceId, threadId), atMs);
    },
  };
}

/** A pre-approved template, as the adapter's `sendTemplate` takes it. */
export interface WhatsappTemplateRef {
  name: string;
  language: string;
  components?: unknown[];
}

export interface WhatsappSendRequest {
  workspaceId: string;
  threadId: string;
  /** The free-form text we WANT to send. */
  text: string;
  /**
   * An explicitly-chosen approved template to fall back to when the window is closed.
   * OMITTING IT IS THE DEFAULT: no template, no send. The caller opts in, always.
   */
  template?: WhatsappTemplateRef;
}

export interface WhatsappSendDeps {
  store: WhatsappWindowStore;
  /** Epoch ms. Injected for tests. */
  now?: () => number;
  windowMs?: number;
  /** Free-form send — only ever called INSIDE the window. */
  postText(threadId: string, text: string): Promise<void>;
  /** Template send — only ever called with an explicitly-supplied template. */
  sendTemplate?(threadId: string, template: WhatsappTemplateRef): Promise<void>;
}

export type WhatsappSendOutcome =
  | { status: "posted"; decision: WhatsappWindowDecision }
  | { status: "template_sent"; decision: WhatsappWindowDecision }
  | {
      status: "dropped_outside_24h_window";
      reason: "no-inbound-recorded" | "window-expired";
      decision: WhatsappWindowDecision;
    };

/**
 * Send `text` if the window is open; otherwise refuse it — and send an approved template
 * ONLY if the caller explicitly supplied one.
 *
 * This is the function every outbound WhatsApp path goes through. It cannot be talked
 * into substituting a template on its own, and it cannot be talked into a free-form send
 * outside the window: both are structurally impossible, not merely discouraged.
 */
export async function sendWhatsappWithinWindow(
  deps: WhatsappSendDeps,
  request: WhatsappSendRequest,
): Promise<WhatsappSendOutcome> {
  const now = (deps.now ?? Date.now)();
  const lastInboundAt = await deps.store.getLastInboundAt(
    request.workspaceId,
    request.threadId,
  );

  const decision = decideWhatsappWindow({
    lastInboundAt,
    now,
    ...(deps.windowMs !== undefined ? { windowMs: deps.windowMs } : {}),
  });

  if (decision.allowed) {
    await deps.postText(request.threadId, request.text);
    return { status: "posted", decision };
  }

  if (request.template && deps.sendTemplate) {
    await deps.sendTemplate(request.threadId, request.template);
    return { status: "template_sent", decision };
  }

  // The typed drop. The caller sees exactly why, and nothing was sent.
  return {
    status: "dropped_outside_24h_window",
    reason: decision.reason,
    decision,
  };
}
