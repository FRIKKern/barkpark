/**
 * The webhook mount index (charter D39) — the design keystone of the inbound
 * HTTP seam.
 *
 * `handlerFor()` takes a `ConnectorInstall` **ROW**, never a pair of URL
 * strings. You cannot obtain a webhook handler without having first passed the
 * fail-closed `InstallsLookup` that produced that row (`tenant/installs.ts`), so
 * "workspace A's URL reaches workspace B's Chat" is not merely untaken — it is
 * UNREPRESENTABLE. A `handlerFor(provider, key)` signature would have made the
 * leak one typo away; this one makes it a type error.
 *
 * The index is keyed by the INSTALL, not by the provider. Keying by provider is
 * the naive design and it is a cross-tenant leak: two workspaces both install
 * Slack, the second mount overwrites the first, and one tenant's events land in
 * the other's Chat (with the other's credential). `test/webhook-server.test.ts`
 * pins this with a protective proof — re-key this map by `provider` and four
 * tests go red, headlined by A's URL reaching B.
 *
 * Mount/unmount is DYNAMIC on purpose: an install created by an OAuth callback
 * must be routable immediately (upsertInstall -> mount), and a disconnect must
 * stop routing immediately (unmount) — never "after the next restart".
 */
import type { Connector, ConnectorInstall } from "../connector/types.js";

/**
 * A webhook handler as the Chat SDK exposes it on `chat.webhooks[provider]`
 * (`chat/dist/messages-BSoJG691.d.ts:2526` — `(request, options) => Promise<Response>`).
 *
 * Declared structurally so this module never imports `Chat` itself: the index
 * only needs "something with a webhooks map", which keeps it testable without
 * constructing a real adapter.
 */
export type WebhookHandler = (
  request: Request,
  options?: WebhookHandlerOptions,
) => Promise<Response>;

export interface WebhookHandlerOptions {
  /**
   * Run the turn in the background so the HTTP response can return NOW.
   *
   * MANDATORY, not optional (`chat/dist/index.js:2606-2617` only backgrounds the
   * turn when it is supplied). Without it the response blocks on the WHOLE turn,
   * Slack's 3s ack budget expires, Slack RETRIES, and the turn runs TWICE — which
   * also breaks D12's post-once-per-turn.
   */
  waitUntil?: (task: Promise<unknown>) => void;
}

/**
 * The minimum shape of a `Chat` this index needs. A real
 * `Chat<Record<string, Adapter>>` satisfies it structurally (its `webhooks` is a
 * per-adapter-name map of exactly this handler type).
 */
export interface WebhookCapableChat {
  webhooks: Record<string, WebhookHandler | undefined>;
}

/**
 * One mounted install: the connector, the row it was mounted FROM, and the Chat
 * built from THAT row's credential. `index.ts`'s `MountedInstall` satisfies this
 * structurally — no import cycle, and no way to mount a Chat that was built from
 * a different tenant's secret than the row it is filed under.
 */
export interface WebhookMount {
  connector: Connector;
  install: ConnectorInstall;
  chat: WebhookCapableChat;
}

export interface WebhookMountIndex {
  /** Mount (or replace) one install's Chat. Idempotent per `(provider, installKey)`. */
  mount(entry: WebhookMount): void;
  /** Stop routing to an install. Returns true when one was actually removed. */
  unmount(provider: string, installKey: string): boolean;
  /**
   * THE KEYSTONE: a webhook handler for an install ROW that the fail-closed
   * lookup already vouched for. `undefined` when that install is not mounted, or
   * when the mounted row is not the same tenant's row — never a fallback to
   * "some Chat for this provider".
   */
  handlerFor(install: ConnectorInstall): WebhookHandler | undefined;
  /** The mount for a row, for callers that need the connector/Chat itself. */
  mountFor(install: ConnectorInstall): WebhookMount | undefined;
  /** Every mounted install, in mount order. */
  list(): WebhookMount[];
  size(): number;
  clear(): void;
}

/**
 * The composite key. JSON-encoded rather than joined on a separator, so there is
 * no delimiter to collide on: ("a", "b:c") and ("a:b", "c") stay distinct and no
 * install can forge another's slot by embedding the separator. Same construction
 * as `tenant/installs.ts` uses for its in-memory table — deliberately.
 */
function mountKey(provider: string, installKey: string): string {
  return JSON.stringify([provider, installKey]);
}

/** Build an isolated mount index. One per bridge; a fresh one per test. */
export function createWebhookMountIndex(): WebhookMountIndex {
  // Insertion-ordered by Map contract, so `list()` is stable.
  const mounts = new Map<string, WebhookMount>();

  const find = (install: ConnectorInstall): WebhookMount | undefined => {
    const entry = mounts.get(mountKey(install.provider, install.installKey));
    if (!entry) return undefined;
    // Defence in depth. The row we were handed came from the installs lookup;
    // the row we mounted came from the same table. If they disagree about the
    // tenant, something re-pointed an install underneath us — refuse rather than
    // hand a workspace someone else's Chat.
    if (entry.install.workspaceId !== install.workspaceId) return undefined;
    return entry;
  };

  return {
    mount(entry) {
      const { provider, installKey } = entry.install;
      if (!provider || !installKey) {
        throw new Error(
          "webhook mounts: an install must carry both provider and installKey — " +
            "an unkeyed mount could only ever be found by guessing, which is how " +
            "cross-tenant routing starts.",
        );
      }
      if (entry.connector.id !== provider) {
        throw new Error(
          `webhook mounts: connector "${entry.connector.id}" cannot serve install of ` +
            `provider "${provider}" — the Chat was built from the wrong connector.`,
        );
      }
      mounts.set(mountKey(provider, installKey), entry);
    },

    unmount(provider, installKey) {
      if (!provider || !installKey) return false;
      return mounts.delete(mountKey(provider, installKey));
    },

    mountFor(install) {
      return find(install);
    },

    handlerFor(install) {
      const entry = find(install);
      if (!entry) return undefined;
      // `chat.webhooks[provider]` — NEVER `adapter.handleWebhook`. An adapter
      // whose App was never initialized answers 500 {"error":"No handler
      // registered"} (Teams); `chat.webhooks` calls `ensureInitialized()` first
      // ("called automatically before handling webhooks", d.ts:2640).
      return entry.chat.webhooks[install.provider];
    },

    list() {
      return [...mounts.values()];
    },

    size() {
      return mounts.size;
    },

    clear() {
      mounts.clear();
    },
  };
}
