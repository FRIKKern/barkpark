/**
 * SOCKET/POLL SINGLE-OWNER LEASE (charter D93/D94/D95) — exactly ONE bridge
 * replica drives each Discord Gateway socket / Telegram getUpdates poll.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE PROBLEM (the honest remainder W8 named but did not solve, D83/D95)
 * ─────────────────────────────────────────────────────────────────────────────
 * W8's mount-reconcile made WEBHOOK connectors replica-safe: an inbound HTTP
 * request is stateless, so any replica can serve it and the mount index just has
 * to rediscover the row. SOCKET/POLL connectors are the opposite. Their transport
 * is a long-lived connection the bridge OPENS, and opening it twice is a bug the
 * provider punishes:
 *
 *   · Discord — a second Gateway websocket on the same bot means the bot is
 *     connected twice, and EVERY message is delivered to both replicas → the
 *     agent double-POSTs its reply. Silent: nothing errors.
 *   · Telegram — a second `getUpdates` long-poll on the same bot token is a hard
 *     `409 Conflict` from Telegram; the two pollers fight and updates are lost.
 *
 * A horizontally-scaled bridge (more than one replica) therefore MUST NOT let
 * every replica mount every socket/poll install. Exactly one replica has to own
 * each install's transport, the others stand by, and on the owner's death a
 * standby has to take over — without a human, without a restart.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE LEASE (D93) — one atomic claim/renew/steal statement, DB clock is truth
 * ─────────────────────────────────────────────────────────────────────────────
 * `chat_bridge.connector_install_leases` holds one row per socket/poll install.
 * Claiming, renewing, and stealing a lapsed lease are ONE statement:
 *
 *   INSERT … ON CONFLICT (provider, install_key) DO UPDATE
 *     SET owner_id = EXCLUDED.owner_id, expires_at = EXCLUDED.expires_at
 *     WHERE connector_install_leases.owner_id = EXCLUDED.owner_id   -- I still hold it → renew
 *        OR connector_install_leases.expires_at < now()            -- holder lapsed → steal
 *     RETURNING owner_id
 *
 * `RETURNING` yields ONE row when I acquired/renewed, ZERO rows when another
 * replica holds a LIVE lease — so `rows.length > 0` IS "I hold it". `expires_at`
 * and the `< now()` comparison both use the SERVER clock (`now()`), never a JS
 * `Date`: the whole point is many replicas agreeing on liveness, and they can
 * only agree on the database's clock, not their own skewed ones.
 *
 * NO LISTEN/NOTIFY (D83): rejected for the same two run-proven reasons as
 * mount-reconcile — a NOTIFY fired while no one is listening is lost forever (so a
 * poll backstop is mandatory regardless), and a dedicated `pg.Client` with no
 * `error` listener crashes the whole process on a connection drop. This coordinator
 * borrows the EXISTING pool (mandatory `pool.on('error')` lives in
 * `createBridgePool`) and converges from the table on every tick.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE COORDINATOR (D94) — mirrors mount-reconcile.ts verbatim
 * ─────────────────────────────────────────────────────────────────────────────
 * Side-effect-free construction, `start()`/`stop()`, an UNREF'd interval, an
 * `inFlight` overlap guard, per-install error containment, an injectable `onError`.
 * Each tick, for every socket/poll connector's install: claim the lease → on
 * ACQUIRE start the transport (`onAcquire` → `connector.listen`); while HELD the
 * claim renews it; on LOSE/LAPSE stop the transport (`onRelease` →
 * `connector.stopListening`) and stand by. The composition root wires `onAcquire`/
 * `onRelease` to the real bringUp/takeDown; a test wires them to recorders and
 * drives `reconcileOnce()` deterministically at `intervalMs: 0`.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * HONEST SCOPE (D95) — say exactly what this covers, and what it does not
 * ─────────────────────────────────────────────────────────────────────────────
 * COVERED: Discord (Gateway socket — silent double-POST) and Telegram
 * (getUpdates — 409 Conflict), the two socket/poll channels in the tree — every
 * channel connector carrying a `listen()`. Since D225 this set is INDEPENDENT
 * of mount-reconcile's `webhook !== undefined` set — the two OVERLAP on
 * dual-transport connectors (Discord: Gateway socket + interactions webhook),
 * whose webhook side mounts replica-safe on every replica while the socket side
 * is leased here.
 *
 * NOT COVERED, and named so no one mistakes silence for safety:
 *   · iMessage — the same socket-ish code shape, but a self-hosted ONE-Mac
 *     operator profile (D3/D44), never Cloud multi-tenant. If it is ever
 *     registered it rides this same lease path unchanged, but it is not built-for
 *     and not tested here.
 *   · Webhook-ONLY channels (Slack / Teams / WhatsApp) — already replica-safe
 *     via W8 mount-reconcile; with no `listen()` they never appear here. A
 *     `webhook` block alone no longer excludes a connector (D225) — only the
 *     absence of a leased transport does.
 *
 * And the D93 LAW: `connector_install_leases` is BRIDGE-INTERNAL — no Elixir ever
 * reads it (mirroring the D54 discipline), so it needs no `test_helper.exs`
 * transcription and the DDL drift gate ignores it.
 */
import type { ConnectorRegistry } from "../connector/registry.js";
import type { Connector, ConnectorInstall } from "../connector/types.js";
import type { BridgePool } from "../db/pool.js";

// ---------------------------------------------------------------------------
// THE LEASE STORE — the one atomic statement, and the release.
// ---------------------------------------------------------------------------

/** Fully-qualified so it works regardless of the pool's search_path pin. */
const LEASE_TABLE = "chat_bridge.connector_install_leases";

/**
 * Claim, renew, or STEAL a lapsed lease in ONE atomic statement (D93).
 *
 * `$4` is the TTL in milliseconds; `expires_at` is computed on the SERVER
 * (`now() + $4 * interval '1 millisecond'`) so every replica measures liveness on
 * the database's clock, never its own. `RETURNING owner_id` yields one row when I
 * now hold the lease, zero rows when another replica holds a live one.
 */
const CLAIM_LEASE = `
  INSERT INTO ${LEASE_TABLE} (provider, install_key, owner_id, expires_at, taken_at, renewed_at)
  VALUES ($1, $2, $3, now() + ($4::double precision * interval '1 millisecond'), now(), now())
  ON CONFLICT (provider, install_key) DO UPDATE
    SET owner_id   = EXCLUDED.owner_id,
        expires_at = EXCLUDED.expires_at,
        renewed_at = now()
    WHERE ${LEASE_TABLE}.owner_id = EXCLUDED.owner_id
       OR ${LEASE_TABLE}.expires_at < now()
  RETURNING owner_id
`;

/**
 * Release a lease — but ONLY if THIS owner still holds it. A stale caller (one
 * whose lease was already stolen) matches zero rows and does nothing, so a
 * release can never yank a live lease out from under the replica that legitimately
 * took it over. Idempotent: releasing a row that is already gone is a no-op.
 */
const RELEASE_LEASE = `
  DELETE FROM ${LEASE_TABLE}
   WHERE provider = $1
     AND install_key = $2
     AND owner_id = $3
`;

/** True when this owner now holds the lease (acquired, renewed, or stole a lapse). */
export async function claimLease(
  db: BridgePool,
  args: { provider: string; installKey: string; ownerId: string; ttlMs: number },
): Promise<boolean> {
  const { rows } = await db.query(CLAIM_LEASE, [
    args.provider,
    args.installKey,
    args.ownerId,
    args.ttlMs,
  ]);
  return rows.length > 0;
}

/** Drop this owner's lease. A no-op when another owner holds it or it is gone. */
export async function releaseLease(
  db: BridgePool,
  args: { provider: string; installKey: string; ownerId: string },
): Promise<void> {
  await db.query(RELEASE_LEASE, [args.provider, args.installKey, args.ownerId]);
}

/**
 * The lease operations the coordinator needs, closed over a pool + this replica's
 * identity + the TTL. Declared as an interface so a test can inject a store over
 * its own `createBridgePool()` (two replicas = two stores, one table).
 */
export interface LeaseStore {
  /** Claim/renew/steal. `true` ⇒ this replica now holds the lease. */
  claim(provider: string, installKey: string): Promise<boolean>;
  /** Release, but only if this replica still owns it (safe otherwise). */
  release(provider: string, installKey: string): Promise<void>;
}

/**
 * Build a {@link LeaseStore} over a bridge pool. `ownerId` is this PROCESS's
 * `crypto.randomUUID()` — minted once by the composition root (D93: container-safe,
 * a hostname collides across templated pods; a fresh UUID never does). `ttlMs`
 * MUST exceed the coordinator's tick interval so the holder renews before expiry.
 */
export function createBridgeLeaseStore(
  db: BridgePool,
  args: { ownerId: string; ttlMs: number },
): LeaseStore {
  return {
    claim: (provider, installKey) =>
      claimLease(db, {
        provider,
        installKey,
        ownerId: args.ownerId,
        ttlMs: args.ttlMs,
      }),
    release: (provider, installKey) =>
      releaseLease(db, { provider, installKey, ownerId: args.ownerId }),
  };
}

// ---------------------------------------------------------------------------
// THE COORDINATOR — mirrors mount-reconcile.ts.
// ---------------------------------------------------------------------------

/** The narrow slice of the installs lookup the coordinator reads. */
export interface LeaseInstallsListing {
  listInstalls(provider: string): Promise<ConnectorInstall[]>;
}

export interface InstallLeaseDeps {
  registry: Pick<ConnectorRegistry, "channels">;
  installs: LeaseInstallsListing;
  lease: LeaseStore;
  /**
   * Start the inbound transport for an install this replica has just ACQUIRED the
   * lease on — the real `connector.listen(adapter)` (the composition root ensures
   * the Chat is mounted first). It THROWS on a bad credential, and the coordinator
   * catches it per-install AND releases the just-claimed lease, so a poisoned row
   * cannot both stall the tick and squat a lease no one is serving.
   */
  onAcquire(install: ConnectorInstall): Promise<void>;
  /**
   * Stop the inbound transport for an install this replica has LOST or whose row
   * has DISAPPEARED — the real `connector.stopListening(adapter)`. The coordinator
   * releases the lease separately (a no-op when it was already stolen).
   */
  onRelease(install: ConnectorInstall): Promise<void>;
}

export interface InstallLeaseOptions {
  /** Tick period. `<= 0` disables the timer entirely (drive `reconcileOnce()`). */
  intervalMs: number;
  /** Where per-install failures are reported. Defaults to a loud `console.error`. */
  onError?: (context: string, error: unknown) => void;
}

/** What one pass changed — returned so a test can assert convergence. */
export interface LeaseSummary {
  /** Installs whose transport this replica STARTED this pass (fresh takeover). */
  acquired: number;
  /** Installs whose transport this replica STOPPED this pass (lost/lapsed/gone). */
  released: number;
  /** Installs this replica holds and is already serving (renewed, no-op). */
  renewed: number;
  /** Installs another replica holds — this one stands by. */
  standby: number;
  /** Per-install claim/acquire/release failures, contained not fatal. */
  failures: number;
}

export interface InstallLease {
  /** Run ONE convergence pass. Idempotent — the holder just renews. */
  reconcileOnce(): Promise<LeaseSummary>;
  /** Arm the periodic timer (no-op when `intervalMs <= 0` or already started). */
  start(): void;
  /** Disarm the timer. Safe to call when not started. */
  stop(): void;
  /** The installs this replica currently OWNS + serves (for tests/introspection). */
  serving(): { provider: string; installKey: string }[];
}

const defaultOnError = (context: string, error: unknown): void => {
  console.error(`[bridge] install lease: ${context}`, error);
};

/** JSON, not a delimiter join, so no `(provider, installKey)` pair can forge another. */
const keyOf = (provider: string, installKey: string): string =>
  JSON.stringify([provider, installKey]);

/**
 * Build the socket/poll ownership coordinator over a lease store and the installs
 * table. Nothing runs until {@link InstallLease.start} (or an explicit
 * {@link InstallLease.reconcileOnce}) — construction is side-effect free.
 */
export function createInstallLease(
  deps: InstallLeaseDeps,
  options: InstallLeaseOptions,
): InstallLease {
  const onError = options.onError ?? defaultOnError;
  let timer: ReturnType<typeof setInterval> | undefined;
  // A slow tick must not overlap the next — two passes could double-claim nothing
  // (the DB serialises the claim) but would race the serving map and interleave logs.
  let inFlight = false;

  // The installs THIS replica owns and is currently serving the transport for.
  // The complement of "the DB says another replica holds it". Keyed like the map.
  const served = new Map<string, ConnectorInstall>();

  // Every channel connector carrying a LEASED transport — a `listen()` that
  // opens a poll/socket needing single-replica ownership. INDEPENDENT of
  // mount-reconcile's `webhook !== undefined` set since D225 — the two overlap
  // on dual-transport connectors (Discord keeps its Gateway lease here while
  // its interactions webhook mounts on every replica). Tool connectors never
  // appear in `channels()`.
  //
  // LOCKSTEP (D226): this inlines `isLeaseManaged` from src/index.ts — it
  // CANNOT import it (index.ts imports this file; importing back is circular).
  // Any edit to the predicate there MUST be mirrored here in the same diff.
  const socketPollConnectors = (): Connector[] =>
    deps.registry
      .channels()
      .filter((connector) => typeof connector.listen === "function");

  const reconcileOnce = async (): Promise<LeaseSummary> => {
    const summary: LeaseSummary = {
      acquired: 0,
      released: 0,
      renewed: 0,
      standby: 0,
      failures: 0,
    };

    for (const connector of socketPollConnectors()) {
      let dbInstalls: ConnectorInstall[];
      try {
        dbInstalls = await deps.installs.listInstalls(connector.id);
      } catch (error) {
        summary.failures++;
        onError(
          `listInstalls(${connector.id}) failed — skipping this provider (leaving ` +
            "its leases untouched, exactly like mount-reconcile does on a DB blip)",
          error,
        );
        continue;
      }

      const dbKeys = new Set(dbInstalls.map((install) => install.installKey));

      // CLAIM / RENEW / STAND-DOWN, per DB install.
      for (const install of dbInstalls) {
        const key = keyOf(connector.id, install.installKey);

        let held: boolean;
        try {
          held = await deps.lease.claim(connector.id, install.installKey);
        } catch (error) {
          summary.failures++;
          onError(
            `claim ${connector.id} install=${install.installKey} failed — ` +
              "not touching its transport this tick",
            error,
          );
          continue;
        }

        if (held) {
          if (served.has(key)) {
            // Already ours: the claim just renewed the lease. Nothing to start.
            summary.renewed++;
            continue;
          }
          // FRESH TAKEOVER: we just acquired a lease we were not serving.
          try {
            await deps.onAcquire(install);
            served.set(key, install);
            summary.acquired++;
          } catch (error) {
            summary.failures++;
            onError(
              `onAcquire ${connector.id} install=${install.installKey} ` +
                `workspace=${install.workspaceId} failed — releasing the lease so a ` +
                "standby replica can try, rather than squatting a lease no one serves",
              error,
            );
            // Do NOT keep a lease for a transport we could not start.
            try {
              await deps.lease.release(connector.id, install.installKey);
            } catch (releaseError) {
              onError(
                `release-after-failed-acquire ${connector.id} install=${install.installKey}`,
                releaseError,
              );
            }
          }
        } else {
          summary.standby++;
          if (served.has(key)) {
            // We WERE serving this and lost the lease — another replica took over
            // (our renew lapsed). Stand down so exactly one replica serves it.
            await standDown(connector.id, install, key, summary);
          }
        }
      }

      // ROW-GONE: an install we serve whose row disappeared (a disconnect handled
      // on another replica). `claim` was never called for it — the DB no longer
      // lists it — so catch it here and stand down. Snapshot: standDown mutates.
      for (const [key, install] of [...served]) {
        if (install.provider !== connector.id) continue;
        if (dbKeys.has(install.installKey)) continue;
        await standDown(connector.id, install, key, summary);
      }
    }

    if (summary.acquired || summary.released) {
      console.log(
        `[bridge] install lease: +${summary.acquired} -${summary.released} ` +
          `(serving ${served.size}` +
          (summary.failures ? `, ${summary.failures} failed` : "") +
          ")",
      );
    }
    return summary;
  };

  /** Stop the transport, drop from the serving set, release the lease (best-effort). */
  const standDown = async (
    provider: string,
    install: ConnectorInstall,
    key: string,
    summary: LeaseSummary,
  ): Promise<void> => {
    try {
      await deps.onRelease(install);
    } catch (error) {
      summary.failures++;
      onError(
        `onRelease ${provider} install=${install.installKey} failed — the standby ` +
          "may still hold a live transport; investigate",
        error,
      );
    }
    served.delete(key);
    // Release is safe whether or not we still own the row: the DELETE is
    // owner-scoped, so a lease another replica already stole is left alone.
    try {
      await deps.lease.release(provider, install.installKey);
    } catch (error) {
      onError(`release ${provider} install=${install.installKey}`, error);
    }
    summary.released++;
  };

  const runGuarded = async (): Promise<void> => {
    if (inFlight) return;
    inFlight = true;
    try {
      await reconcileOnce();
    } catch (error) {
      // reconcileOnce contains per-install; anything escaping is a bug, but the
      // interval MUST survive it — a tick that killed its own timer would freeze
      // every lease at its current owner and never take over a lapse again.
      onError("unexpected error in lease pass", error);
    } finally {
      inFlight = false;
    }
  };

  return {
    reconcileOnce,

    start() {
      if (timer || options.intervalMs <= 0) return;
      timer = setInterval(() => void runGuarded(), options.intervalMs);
      // Housekeeping only: the bridge's liveness is its transports, not this timer.
      timer.unref?.();
    },

    stop() {
      if (timer) {
        clearInterval(timer);
        timer = undefined;
      }
    },

    serving() {
      return [...served.values()].map((install) => ({
        provider: install.provider,
        installKey: install.installKey,
      }));
    },
  };
}
