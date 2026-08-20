/**
 * The supervised Gateway runner — shared by the two SOCKET connectors (Discord,
 * iMessage). Not core: it lives beside the connectors it serves, so the core
 * loop (`core/dispatch.ts`, `tenant/resolve.ts`, `connector/registry.ts`,
 * `turn/`) stays provider-agnostic and untouched.
 *
 * Both `@chat-adapter/discord` and `chat-adapter-imessage` expose the SAME
 * `startGatewayListener(options, durationMs?, abortSignal?)` shape, and both
 * carry the same three traps. This module is where we handle them ONCE.
 *
 * TRAP 1 — the 500s that look like silence.
 *   The vendor answers a same-tick `500` and never listens when
 *   `options.waitUntil` is missing ("waitUntil not provided") or when the
 *   adapter has not been handed a Chat instance yet ("Chat instance not
 *   initialized" — i.e. `chat.initialize()` has not run). Both are a `Response`,
 *   not a throw. A caller that ignores the return value gets a bot that boots
 *   clean and never answers. We check `res.ok` and throw {@link GatewayStartError}.
 *
 * TRAP 2 — `durationMs` is a `setTimeout` delay, so MAX_SAFE_INTEGER is a BUG.
 *   The vendor's listener is `await new Promise(r => setTimeout(r, durationMs))`
 *   followed by `client.destroy()` in a `finally`. Node's `setTimeout` SILENTLY
 *   collapses any delay above 2^31-1 to **1 ms** (`TimeoutOverflowWarning`), so
 *   passing `Number.MAX_SAFE_INTEGER` destroys the Gateway connection about a
 *   millisecond after login — strictly worse than the 3-minute default it was
 *   meant to defeat. Measured:
 *
 *     $ node -e 'const t=Date.now();setTimeout(()=>console.log(Date.now()-t),Number.MAX_SAFE_INTEGER)'
 *     TimeoutOverflowWarning: 9007199254740991 does not fit into a 32-bit signed
 *     integer. Timeout duration was set to 1.
 *     3
 *
 *   So the cap is {@link NODE_TIMEOUT_MAX} (2^31-1 ms ≈ 24.8 days), and any
 *   larger value is rejected up front rather than silently truncated.
 *
 * TRAP 3 — a 24.8-day window still ENDS, and a rejected login ends in seconds.
 *   Barkpark's bridge is a persistent process (charter D32), so a listener that
 *   resolves once and stops is a bot that goes quiet forever, silently. This
 *   module therefore SUPERVISES: when the connection promise settles — window
 *   expiry, dropped socket, rejected token — it re-arms, with exponential
 *   backoff for connections that die fast (a bad token must not hot-loop) and no
 *   delay at all for a connection that lived a healthy while.
 *
 * `startSupervisedGateway` awaits only the FIRST arm (which the vendor returns
 * synchronously — measured at 28 ms), so it never stalls the sequential mount
 * loop in `startBridge`. The long-lived connection is handed to `waitUntil` and
 * watched in the background.
 */
import type { WebhookOptions } from "chat";

/**
 * Node's hard `setTimeout` ceiling: 2^31-1 ms (~24.8 days). A larger delay is
 * NOT clamped to the max — it is collapsed to 1 ms. See TRAP 2 above.
 */
export const NODE_TIMEOUT_MAX = 2_147_483_647;

/** The slice of a Chat SDK adapter that speaks the Gateway protocol. */
export interface GatewayAdapter {
  startGatewayListener(
    options: WebhookOptions,
    durationMs?: number,
    abortSignal?: AbortSignal,
  ): Promise<Response>;
}

/**
 * The Gateway refused to start. Thrown (not returned) so a misconfigured install
 * fails LOUDLY at boot instead of mounting a bot that never answers.
 */
export class GatewayStartError extends Error {
  constructor(
    readonly provider: string,
    readonly status: number,
    readonly detail: string,
  ) {
    super(
      `${provider}: gateway listener refused to start (HTTP ${status}): ${detail}`,
    );
    this.name = "GatewayStartError";
  }
}

export interface GatewayTuning {
  /**
   * How long ONE gateway window runs. Defaults to {@link NODE_TIMEOUT_MAX}.
   * Values above that ceiling throw — they would silently become 1 ms.
   */
  durationMs?: number;
  /** First re-arm delay after a connection that died fast. Default 1s. */
  minBackoffMs?: number;
  /** Backoff ceiling. Default 60s. */
  maxBackoffMs?: number;
  /** A connection that survived at least this long resets the backoff. Default 30s. */
  healthyAfterMs?: number;
  log?: (message: string, error?: unknown) => void;
  /** Injectable for tests — resolves early when the signal aborts. */
  sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
  now?: () => number;
}

export interface GatewaySupervisorOptions extends GatewayTuning {
  provider: string;
  adapter: GatewayAdapter;
}

export interface GatewaySession {
  /** Resolves when the supervisor loop has fully stopped. */
  readonly done: Promise<void>;
  /** How many times the gateway has been armed (1 = the boot arm). Test/ops signal. */
  readonly arms: () => number;
  /** Abort the gateway and wait for the supervisor to wind down. */
  stop(): Promise<void>;
}

/** A sleep that gives up the moment the signal aborts, so shutdown is prompt. */
function abortableSleep(ms: number, signal: AbortSignal): Promise<void> {
  if (ms <= 0 || signal.aborted) return Promise.resolve();

  return new Promise<void>((resolve) => {
    const finish = (): void => {
      clearTimeout(timer);
      signal.removeEventListener("abort", finish);
      resolve();
    };
    const timer = setTimeout(finish, ms);
    signal.addEventListener("abort", finish, { once: true });
  });
}

function defaultLog(message: string, error?: unknown): void {
  if (error === undefined) console.log(message);
  else console.error(message, error);
}

/**
 * Start a Gateway listener and keep it alive for the life of the process.
 *
 * Resolves as soon as the FIRST arm is accepted — it deliberately does NOT await
 * the connection, so the caller's mount loop keeps moving. Throws
 * {@link GatewayStartError} if that first arm is refused, so a bad credential or
 * an uninitialised Chat surfaces at boot rather than as silence.
 */
export async function startSupervisedGateway(
  options: GatewaySupervisorOptions,
): Promise<GatewaySession> {
  const {
    provider,
    adapter,
    durationMs = NODE_TIMEOUT_MAX,
    minBackoffMs = 1_000,
    maxBackoffMs = 60_000,
    healthyAfterMs = 30_000,
    log = defaultLog,
    sleep = abortableSleep,
    now = Date.now,
  } = options;

  // Fail LOUD rather than let Node collapse the window to 1 ms (TRAP 2).
  if (!Number.isFinite(durationMs) || durationMs <= 0) {
    throw new RangeError(
      `${provider}: gateway durationMs must be a positive number, got ${durationMs}`,
    );
  }
  if (durationMs > NODE_TIMEOUT_MAX) {
    throw new RangeError(
      `${provider}: gateway durationMs ${durationMs} exceeds Node's setTimeout ceiling ` +
        `(${NODE_TIMEOUT_MAX}). Node would silently collapse it to 1ms and the adapter ` +
        "would destroy the connection immediately. Use NODE_TIMEOUT_MAX; the supervisor re-arms.",
    );
  }

  const controller = new AbortController();
  const signal = controller.signal;
  let armCount = 0;

  /** How one gateway window ended. Never a rejection — see `arm()`. */
  interface WindowResult {
    error?: unknown;
  }

  /**
   * The connection promise, BOXED.
   *
   * `arm` is async and must hand back a long-lived promise. Returning it bare
   * would be a `Promise<Promise<…>>`, which does not exist at runtime: `await`
   * assimilates recursively, so `await arm()` would block until the SOCKET
   * closed — turning the whole point of this module (resolve promptly, supervise
   * in the background) into a mount loop that hangs forever on the first
   * connector. The box is what keeps the two promises distinct.
   */
  interface ArmedGateway {
    connection: Promise<WindowResult>;
  }

  /** Arm the gateway once. Returns a promise that settles when the window ends. */
  const arm = async (): Promise<ArmedGateway> => {
    // The vendor hands the connection promise to waitUntil and returns
    // synchronously. We KEEP the promise (rather than dropping it, as a
    // serverless host would) — it is the only signal that the socket ended.
    //
    // The handlers are attached in the SAME tick the vendor hands it over, so a
    // connection that rejects (a revoked token) can never surface as an
    // unhandled rejection and take the whole bridge down.
    let connection: Promise<WindowResult> | null = null;

    const webhookOptions: WebhookOptions = {
      waitUntil: (promise: Promise<unknown>): void => {
        connection = Promise.resolve(promise).then(
          () => ({}),
          (error: unknown) => ({ error }),
        );
      },
    };

    const response = await adapter.startGatewayListener(
      webhookOptions,
      durationMs,
      signal,
    );
    armCount += 1;

    if (!response.ok) {
      const detail = await response.text().catch(() => `HTTP ${response.status}`);
      throw new GatewayStartError(
        provider,
        response.status,
        detail.trim() || `HTTP ${response.status}`,
      );
    }

    // A 200 that never handed us a promise means nothing is actually listening —
    // treat it as a start failure, not as a healthy mount.
    if (connection === null) {
      throw new GatewayStartError(
        provider,
        response.status,
        "gateway reported success but never handed over a connection promise",
      );
    }

    return { connection };
  };

  // The FIRST arm is awaited: a refusal must break the boot, loudly. Only the
  // ARM is awaited — never the connection inside the box.
  let { connection } = await arm();

  // Shutdown must NOT depend on the adapter honouring the abort signal. If a
  // vendor's connection promise never settles (a wedged socket, a listener that
  // ignores the signal), racing the abort here is what keeps `stop()` prompt
  // instead of hanging the whole process on SIGTERM.
  const ABORTED = Symbol("gateway-aborted");
  const abortRace = new Promise<typeof ABORTED>((resolve) => {
    if (signal.aborted) resolve(ABORTED);
    else signal.addEventListener("abort", () => resolve(ABORTED), { once: true });
  });

  const loop = (async (): Promise<void> => {
    let consecutiveFailures = 0;

    for (;;) {
      const startedAt = now();

      const result = await Promise.race([connection, abortRace]);
      if (signal.aborted) return;

      if (result !== ABORTED && result.error !== undefined) {
        log(`[${provider}] gateway connection ended with an error`, result.error);
      }

      const lasted = now() - startedAt;
      consecutiveFailures = lasted >= healthyAfterMs ? 0 : consecutiveFailures + 1;

      const delay =
        consecutiveFailures === 0
          ? 0
          : Math.min(maxBackoffMs, minBackoffMs * 2 ** (consecutiveFailures - 1));

      log(
        `[${provider}] gateway window ended after ${lasted}ms — re-arming in ${delay}ms`,
      );

      await sleep(delay, signal);
      if (signal.aborted) return;

      try {
        ({ connection } = await arm());
      } catch (error) {
        // A re-arm that is refused (revoked token, Discord outage) must not hot-loop.
        // Fall through with an already-settled window: the next pass measures a
        // ~0ms window, bumps the failure count, and backs off further.
        log(`[${provider}] gateway re-arm failed`, error);
        connection = Promise.resolve({ error });
      }
    }
  })();

  return {
    done: loop,
    arms: () => armCount,
    async stop(): Promise<void> {
      controller.abort();
      await loop;
    },
  };
}
