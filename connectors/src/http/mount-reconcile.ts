/**
 * PERIODIC MOUNT RECONCILE (charter D83) — the webhook mount index rediscovers
 * installs written by ANOTHER process.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE PROBLEM
 * ─────────────────────────────────────────────────────────────────────────────
 * `WebhookMountIndex` is an in-memory, per-process `Map` (`http/mounts.ts`). It is
 * populated once at boot (the `startBridge` mount loop) and thereafter ONLY by the
 * `addInstall`/`removeInstall` callbacks that a connect/OAuth request runs — and
 * those run in the process that HANDLED the request. A horizontally-scaled bridge
 * therefore has a split brain: replica A handles the OAuth callback, writes the
 * `connector_installs` row, mounts it in ITS OWN index — and replica B, which
 * never saw the request, has a stale index and answers the same opaque 404 as an
 * unknown route for that tenant's webhook until it is restarted.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHY A POLL, NOT LISTEN/NOTIFY (D83 — decided with run-proofs, not asserted)
 * ─────────────────────────────────────────────────────────────────────────────
 * `pg` LISTEN/NOTIFY was evaluated and REJECTED on two independent grounds:
 *
 *   1. NON-DURABLE. A `NOTIFY` delivered while no session is `LISTEN`ing is lost
 *      forever — there is no backlog. A replica that reconnects (pool churn, a
 *      Postgres failover, a deploy) misses every notification sent during the gap
 *      and is silently stale again. Only a poll re-reads the table as the SOURCE
 *      OF TRUTH on every tick, so it is self-healing across any disconnect.
 *
 *   2. A PROCESS-CRASH LANDMINE. LISTEN needs a DEDICATED long-lived `pg.Client`
 *      (a pooled client cannot hold a subscription — the pool reuses it), and a
 *      `pg.Client` whose connection drops with NO `'error'` listener attached
 *      emits an `'error'` event on an EventEmitter with no handler, which Node
 *      turns into an UNCAUGHT EXCEPTION and the whole bridge exits 1. So the
 *      "efficient" design adds a second failure mode that takes the process down —
 *      the exact opposite of what this hardening is for.
 *
 * A periodic DB reconcile has neither problem: it borrows the EXISTING pool (no
 * dedicated client, no error-listener hazard), and it converges from the table
 * itself on every tick regardless of what happened between ticks.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * SCOPE — WEBHOOK MOUNTS ONLY (honest, and narrow on purpose)
 * ─────────────────────────────────────────────────────────────────────────────
 * This reconciles the WEBHOOK mount index only: connectors whose transport IS the
 * inbound HTTP request (Slack/Teams/WhatsApp), which the index actually holds. It
 * deliberately does NOT reconcile poll/socket channels (Telegram getUpdates,
 * Discord gateway): a second replica that mounted those from a rediscovered row
 * would START A SECOND POLL LOOP / a second gateway socket against the same bot —
 * a Discord double-post, a Telegram 409-Conflict. That replica-safety hazard is a
 * SEPARATE problem tracked by `connectors-replica-socket-poll-safety`; converging
 * it through this loop would silently create the very bug it is filed to prevent.
 * So the reconcile enumerates ONLY connectors that declare a `webhook`.
 *
 * Convergence runs through the SAME `addInstall`/`removeInstall` (bringUp/takeDown)
 * paths a connect request uses — no second mounting codepath to drift.
 */
import type { ConnectorRegistry } from "../connector/registry.js";
import type { Connector, ConnectorInstall } from "../connector/types.js";
import type { WebhookMountIndex } from "./mounts.js";

/**
 * The narrow slice of `InstallsLookup` the reconcile reads — just the per-provider
 * list. Declared structurally so a test injects a lookup over one real Postgres
 * without dragging the whole interface in.
 */
export interface InstallsListing {
  listInstalls(provider: string): Promise<ConnectorInstall[]>;
}

/** The slice of the mount index the reconcile observes (never mutates directly). */
export interface MountObserver {
  list(): { connector: Connector; install: ConnectorInstall }[];
  /** Undefined ⇒ this exact tenant row is NOT mounted here (stale). */
  mountFor(install: ConnectorInstall): unknown;
}

export interface MountReconcileDeps {
  registry: Pick<ConnectorRegistry, "channels">;
  installs: InstallsListing;
  mounts: MountObserver;
  /**
   * Mount a rediscovered install — the EXACT `Bridge.addInstall` (bringUp) a
   * connect request runs, so there is no second mounting path to keep in step. It
   * THROWS on a bad credential (runtime mount semantics), and the reconcile
   * catches it per-install so one poisoned row cannot stall the whole tick.
   */
  addInstall(install: ConnectorInstall): Promise<unknown>;
  /** Unmount an install whose row has disappeared — `Bridge.removeInstall`/takeDown. */
  removeInstall(provider: string, installKey: string): Promise<boolean>;
}

export interface MountReconcileOptions {
  /** Tick period. `<= 0` disables the timer entirely (a boot with no reconcile). */
  intervalMs: number;
  /**
   * Where a per-install/per-provider failure is reported. Defaults to a loud
   * `console.error` — a reconcile that swallowed its errors would let a whole
   * replica silently rot. Injectable so a test can assert the loud path.
   */
  onError?: (context: string, error: unknown) => void;
}

/** What one pass actually changed — returned so a test can assert convergence. */
export interface ReconcileSummary {
  added: number;
  removed: number;
  failures: number;
}

export interface MountReconcile {
  /**
   * Run ONE convergence pass: for every webhook connector, mount the DB rows this
   * index is missing and unmount the mounts whose DB row is gone. Idempotent — a
   * second call with nothing changed is a no-op returning zeroes.
   */
  reconcileOnce(): Promise<ReconcileSummary>;
  /** Arm the periodic timer (no-op when `intervalMs <= 0` or already started). */
  start(): void;
  /** Disarm the timer. Safe to call when not started. */
  stop(): void;
}

const defaultOnError = (context: string, error: unknown): void => {
  console.error(`[bridge] mount reconcile: ${context}`, error);
};

/**
 * Build a reconcile over a mount index and the installs table.
 *
 * Nothing runs until {@link MountReconcile.start} (or an explicit
 * {@link MountReconcile.reconcileOnce}) — construction is side-effect free, so the
 * composition root wires it once and a test drives `reconcileOnce()` deterministically
 * without an interval.
 */
export function createMountReconcile(
  deps: MountReconcileDeps,
  options: MountReconcileOptions,
): MountReconcile {
  const onError = options.onError ?? defaultOnError;
  let timer: ReturnType<typeof setInterval> | undefined;
  // A slow DB tick must not overlap the next one — a second pass would double-mount
  // nothing (mountFor guards that) but would waste connections and interleave logs.
  let inFlight = false;

  const webhookConnectors = (): Connector[] =>
    deps.registry.channels().filter((connector) => connector.webhook !== undefined);

  const reconcileOnce = async (): Promise<ReconcileSummary> => {
    const summary: ReconcileSummary = { added: 0, removed: 0, failures: 0 };

    for (const connector of webhookConnectors()) {
      let dbInstalls: ConnectorInstall[];
      try {
        dbInstalls = await deps.installs.listInstalls(connector.id);
      } catch (error) {
        summary.failures++;
        onError(
          `listInstalls(${connector.id}) failed — skipping this provider`,
          error,
        );
        continue;
      }

      const dbKeys = new Set(dbInstalls.map((install) => install.installKey));

      // ADD / RE-POINT: a DB row this index is not serving for THIS tenant. A row
      // moved to another workspace also lands here (mountFor fails the workspace
      // check), and addInstall's takeDown-then-bringUp replaces the stale mount.
      for (const install of dbInstalls) {
        if (deps.mounts.mountFor(install)) continue;
        try {
          await deps.addInstall(install);
          summary.added++;
        } catch (error) {
          summary.failures++;
          onError(
            `addInstall ${connector.id} install=${install.installKey} ` +
              `workspace=${install.workspaceId} failed — the credential is most likely ` +
              "revoked; leaving it unmounted until the next tick",
            error,
          );
        }
      }

      // REMOVE: a mount whose DB row is gone (a disconnect on another replica).
      // Snapshot first — removeInstall mutates the index we are iterating.
      const mountedHere = deps.mounts
        .list()
        .filter((mount) => mount.connector.id === connector.id);
      for (const mount of mountedHere) {
        if (dbKeys.has(mount.install.installKey)) continue;
        try {
          if (await deps.removeInstall(connector.id, mount.install.installKey)) {
            summary.removed++;
          }
        } catch (error) {
          summary.failures++;
          onError(
            `removeInstall ${connector.id} install=${mount.install.installKey} failed`,
            error,
          );
        }
      }
    }

    if (summary.added || summary.removed) {
      console.log(
        `[bridge] mount reconcile: +${summary.added} -${summary.removed}` +
          (summary.failures ? ` (${summary.failures} failed)` : ""),
      );
    }
    return summary;
  };

  const runGuarded = async (): Promise<void> => {
    if (inFlight) return;
    inFlight = true;
    try {
      await reconcileOnce();
    } catch (error) {
      // reconcileOnce catches per-install; anything escaping is a bug, but the
      // interval MUST survive it — a reconcile that killed its own timer on one
      // bad tick would leave the replica permanently stale.
      onError("unexpected error in reconcile pass", error);
    } finally {
      inFlight = false;
    }
  };

  return {
    reconcileOnce,

    start() {
      if (timer || options.intervalMs <= 0) return;
      timer = setInterval(() => void runGuarded(), options.intervalMs);
      // Do not hold the event loop open on the reconcile alone — the bridge's
      // liveness is its webhook server and poll loops, not this housekeeping timer.
      timer.unref?.();
    },

    stop() {
      if (timer) {
        clearInterval(timer);
        timer = undefined;
      }
    },
  };
}
