import { afterEach, describe, expect, it, vi } from "vitest";

import { createConnectorRegistry } from "../src/connector/registry.js";
import type { Adapter } from "chat";
import type { ConnectorInstall } from "../src/connector/types.js";
import {
  createDiscordConnector,
  discordApplicationIdFromCredential,
  parseDiscordCredential,
  DISCORD_PROVIDER,
} from "../src/connectors/discord.js";
import {
  GatewayStartError,
  NODE_TIMEOUT_MAX,
  startSupervisedGateway,
  type GatewayAdapter,
} from "../src/connectors/gateway.js";
import { createInMemoryInstallsLookup } from "../src/tenant/installs.js";

/**
 * Fake credentials. Real Discord tokens are `<base64 app id>.<ts>.<hmac>`; the
 * shape does not matter here because nothing in this suite talks to Discord.
 */
const ALPHA_CREDENTIAL = JSON.stringify({
  applicationId: "111111111111111111",
  botToken: "alpha-bot-token-not-real",
  publicKey: "a".repeat(64),
});
const BETA_CREDENTIAL = JSON.stringify({
  applicationId: "222222222222222222",
  botToken: "beta-bot-token-not-real",
  publicKey: "b".repeat(64),
});

const alphaInstall: ConnectorInstall = {
  provider: DISCORD_PROVIDER,
  installKey: "111111111111111111",
  workspaceId: "ws-alpha",
  credentialRef: ALPHA_CREDENTIAL,
};
const betaInstall: ConnectorInstall = {
  provider: DISCORD_PROVIDER,
  installKey: "222222222222222222",
  workspaceId: "ws-beta",
  credentialRef: BETA_CREDENTIAL,
};

/** The vendor's `protected readonly` credential fields, as they exist at runtime. */
interface AdapterInternals {
  botToken: string;
  publicKey: string;
  applicationId: string;
}
const internals = (adapter: unknown): AdapterInternals =>
  adapter as unknown as AdapterInternals;

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("discord connector — registration shape (one registry entry, zero core change)", () => {
  it("declares direction=channel, auth=token, tenantResolution=credential-bound", () => {
    const connector = createDiscordConnector();

    expect(connector.id).toBe("discord");
    expect(connector.direction).toBe("channel");
    expect(connector.auth).toBe("token");
    // NOT payload-team-id. A Discord event carries a guild id, but a guild does
    // not own the bot — the APPLICATION does. Routing on guild_id would require a
    // shared app, i.e. ONE bot token serving every tenant (charter D41).
    expect(connector.tenantResolution).toBe("credential-bound");
  });

  it("registers as an ordinary channel connector — no special case anywhere", () => {
    const registry = createConnectorRegistry();
    registry.register(createDiscordConnector());

    expect(registry.list().map((c) => c.id)).toEqual([DISCORD_PROVIDER]);
    expect(registry.channels().map((c) => c.id)).toEqual([DISCORD_PROVIDER]);
    expect(() => registry.register(createDiscordConnector())).toThrow(
      /duplicate connector id/,
    );
  });

  it("exposes the listen/stopListening lifecycle the boot path calls blind", () => {
    const connector = createDiscordConnector();

    expect(typeof connector.listen).toBe("function");
    expect(typeof connector.stopListening).toBe("function");
  });
});

describe("discord connector — per-install credential isolation (D1)", () => {
  it("builds a REAL @chat-adapter/discord adapter from the install credential", () => {
    const adapter = createDiscordConnector().adapterFactory(alphaInstall);

    // The SDK Adapter contract — a genuine vendor adapter, not a stub.
    expect(adapter.name).toBe("discord");
    expect(typeof adapter.postMessage).toBe("function");
    expect(typeof adapter.encodeThreadId).toBe("function");
    expect(typeof (adapter as unknown as GatewayAdapter).startGatewayListener).toBe(
      "function",
    );
  });

  it("mounts TWO installs as two independent adapters with DIFFERENT bot tokens", () => {
    const connector = createDiscordConnector();

    const alpha = connector.adapterFactory(alphaInstall);
    const beta = connector.adapterFactory(betaInstall);

    expect(alpha).not.toBe(beta);
    // Each tenant's adapter is constructed from THAT tenant's credential and
    // nothing else — the whole of multi-tenant isolation, made structural.
    expect(internals(alpha).botToken).toBe("alpha-bot-token-not-real");
    expect(internals(beta).botToken).toBe("beta-bot-token-not-real");
    expect(internals(alpha).botToken).not.toBe(internals(beta).botToken);
    expect(internals(alpha).applicationId).toBe("111111111111111111");
    expect(internals(beta).applicationId).toBe("222222222222222222");
  });

  it("NEVER lets a process-wide DISCORD_BOT_TOKEN stand in for a tenant's own", () => {
    // The vendor's constructor does `config.botToken ?? process.env.DISCORD_BOT_TOKEN`.
    // In a multi-tenant bridge that fallback is a cross-tenant leak: one stray env
    // var would serve every workspace with an incomplete install row. Poison the
    // environment and prove the leak is unreachable.
    vi.stubEnv("DISCORD_BOT_TOKEN", "POISON-operator-wide-token");
    vi.stubEnv("DISCORD_APPLICATION_ID", "999999999999999999");
    vi.stubEnv("DISCORD_PUBLIC_KEY", "f".repeat(64));

    const connector = createDiscordConnector();
    const incomplete: ConnectorInstall = {
      ...alphaInstall,
      // A row that lost its token — exactly the case the env fallback would "rescue".
      credentialRef: JSON.stringify({
        applicationId: "111111111111111111",
        publicKey: "a".repeat(64),
      }),
    };

    expect(() => connector.adapterFactory(incomplete)).toThrow(
      /"botToken" is required/,
    );

    // And a COMPLETE install still uses its own token, never the poisoned env one.
    const adapter = connector.adapterFactory(alphaInstall);
    expect(internals(adapter).botToken).toBe("alpha-bot-token-not-real");
    expect(internals(adapter).botToken).not.toBe("POISON-operator-wide-token");
  });
});

describe("discord connector — credential parsing (fail closed)", () => {
  it("parses the full triple and derives the install key from the application id", () => {
    expect(parseDiscordCredential(ALPHA_CREDENTIAL)).toEqual({
      applicationId: "111111111111111111",
      botToken: "alpha-bot-token-not-real",
      publicKey: "a".repeat(64),
    });
    // The routing table's PRIMARY KEY is the non-secret half.
    expect(discordApplicationIdFromCredential(ALPHA_CREDENTIAL)).toBe(
      "111111111111111111",
    );
  });

  it("rejects a bare bot token — Discord needs all three values", () => {
    expect(() => parseDiscordCredential("alpha-bot-token-not-real")).toThrow(
      /expected JSON/,
    );
  });

  it.each(["applicationId", "botToken", "publicKey"])(
    "rejects a credential missing %s",
    (field) => {
      const partial = JSON.parse(ALPHA_CREDENTIAL) as Record<string, unknown>;
      delete partial[field];

      expect(() => parseDiscordCredential(JSON.stringify(partial))).toThrow(
        new RegExp(`"${field}" is required`),
      );
    },
  );

  it("rejects a blank field rather than passing whitespace to Discord", () => {
    expect(() =>
      parseDiscordCredential(
        JSON.stringify({ ...JSON.parse(ALPHA_CREDENTIAL), botToken: "   " }),
      ),
    ).toThrow(/"botToken" is required/);
  });
});

describe("discord connector — tenant resolution (credential-bound, fail closed)", () => {
  const installs = {
    installs: createInMemoryInstallsLookup([alphaInstall, betaInstall]),
  };
  const connector = createDiscordConnector();

  const event = (installKey?: string) => ({
    provider: DISCORD_PROVIDER,
    threadId: "discord:chan:1",
    text: "hi",
    ...(installKey === undefined ? {} : { installKey }),
  });

  it("routes each bot to the workspace that installed it", async () => {
    await expect(
      connector.resolveTenant(event("111111111111111111"), installs),
    ).resolves.toBe("ws-alpha");
    await expect(
      connector.resolveTenant(event("222222222222222222"), installs),
    ).resolves.toBe("ws-beta");
  });

  it("returns null for an app nobody installed — never a default workspace", async () => {
    await expect(
      connector.resolveTenant(event("333333333333333333"), installs),
    ).resolves.toBeNull();
  });

  it("returns null when the transport could not say which app received it", async () => {
    await expect(connector.resolveTenant(event(), installs)).resolves.toBeNull();
  });
});

/**
 * A faithful stand-in for the vendor's `startGatewayListener`, reproducing the
 * three behaviours that matter (verified against
 * `node_modules/@chat-adapter/discord/dist/index.js:2151-2179`):
 *
 *   - no `waitUntil`      -> same-tick 500 "waitUntil not provided", nothing listens
 *   - chat not initialised -> same-tick 500 "Chat instance not initialized"
 *   - otherwise            -> hand the connection promise to waitUntil, return 200
 */
function fakeGateway(
  options: {
    initialized?: boolean;
    /**
     * One factory per window, called at ARM time (never eagerly — a pre-created
     * rejected promise would be an unhandled rejection before the supervisor
     * ever sees it). Default: a promise that never settles, i.e. a healthy,
     * long-lived socket.
     */
    windows?: Array<() => Promise<unknown>>;
  } = {},
) {
  const calls: Array<{
    hasWaitUntil: boolean;
    durationMs: number | undefined;
    signal: AbortSignal | undefined;
  }> = [];
  const windows = options.windows ?? [];
  let index = 0;

  const adapter: GatewayAdapter = {
    async startGatewayListener(webhookOptions, durationMs, abortSignal) {
      calls.push({
        hasWaitUntil: typeof webhookOptions.waitUntil === "function",
        durationMs,
        signal: abortSignal,
      });

      if (options.initialized === false) {
        return new Response("Chat instance not initialized", { status: 500 });
      }
      if (!webhookOptions.waitUntil) {
        return new Response("waitUntil not provided", { status: 500 });
      }

      const next = windows[index++];
      // The default window NEVER settles and IGNORES the abort signal — the
      // pessimistic case, which is exactly what shutdown must survive.
      webhookOptions.waitUntil(next ? next() : new Promise<void>(() => {}));

      return new Response(JSON.stringify({ status: "listening" }), {
        status: 200,
      });
    },
  };

  return { adapter, calls };
}

describe("discord connector — the gateway listener (the three vendor traps)", () => {
  it("listen() RESOLVES promptly and does NOT await the socket (mount loop keeps moving)", async () => {
    // The window never settles — a listener that awaited it would hang the
    // sequential mount loop in startBridge and no later install would ever mount.
    const { adapter, calls } = fakeGateway();
    const connector = createDiscordConnector();

    const started = Date.now();
    await connector.listen?.(adapter as unknown as Adapter);
    const elapsed = Date.now() - started;

    expect(elapsed).toBeLessThan(500);
    expect(calls).toHaveLength(1);

    await connector.stopListening?.(adapter as unknown as Adapter);
  });

  it("passes waitUntil — the omission that returns a silent 500 is unreachable", async () => {
    const { adapter, calls } = fakeGateway();
    const connector = createDiscordConnector();

    await connector.listen?.(adapter as unknown as Adapter);

    expect(calls[0]?.hasWaitUntil).toBe(true);

    await connector.stopListening?.(adapter as unknown as Adapter);
  });

  it("passes a durationMs at Node's timer ceiling — NOT MAX_SAFE_INTEGER", async () => {
    const { adapter, calls } = fakeGateway();
    const connector = createDiscordConnector();

    await connector.listen?.(adapter as unknown as Adapter);

    // The vendor does `setTimeout(resolve, durationMs)` and then `client.destroy()`.
    // Node collapses any delay above 2^31-1 to ONE MILLISECOND, so MAX_SAFE_INTEGER
    // would destroy the gateway instantly — silently, and worse than the 3-minute
    // default it was meant to defeat.
    expect(calls[0]?.durationMs).toBe(NODE_TIMEOUT_MAX);
    expect(calls[0]?.durationMs).toBeLessThanOrEqual(2_147_483_647);
    expect(calls[0]?.durationMs).not.toBe(Number.MAX_SAFE_INTEGER);
    // And the default is NOT the vendor's 3-minute window (fatal in a persistent process).
    expect(calls[0]?.durationMs).toBeGreaterThan(180_000);

    await connector.stopListening?.(adapter as unknown as Adapter);
  });

  it("the MAX_SAFE_INTEGER trap is real — Node collapses the timer to 1ms", async () => {
    // The tripwire behind the assertion above: keep the proof next to the rule so
    // nobody "simplifies" durationMs back to Number.MAX_SAFE_INTEGER.
    const firedAt = await new Promise<number>((resolve) => {
      const started = Date.now();
      setTimeout(() => resolve(Date.now() - started), Number.MAX_SAFE_INTEGER);
    });

    expect(firedAt).toBeLessThan(1_000); // ~1ms, not ~285,000 years
  });

  it("refuses a durationMs above Node's ceiling instead of silently truncating it", async () => {
    const { adapter } = fakeGateway();

    await expect(
      startSupervisedGateway({
        provider: "discord",
        adapter,
        durationMs: Number.MAX_SAFE_INTEGER,
      }),
    ).rejects.toThrow(/exceeds Node's setTimeout ceiling/);
  });

  it("THROWS on a refused gateway — a 500 must not look like 'nothing happened'", async () => {
    const { adapter } = fakeGateway({ initialized: false });
    const connector = createDiscordConnector();

    await expect(connector.listen?.(adapter as unknown as Adapter)).rejects.toThrow(
      GatewayStartError,
    );
    await expect(connector.listen?.(adapter as unknown as Adapter)).rejects.toThrow(
      /Chat instance not initialized/,
    );
  });

  it("THROWS against the REAL vendor adapter when chat.initialize() has not run", async () => {
    // No fake: the genuine @chat-adapter/discord code path, no network. This is the
    // ordering bug startBridge would hit if it called listen() before initialize().
    const connector = createDiscordConnector();
    const adapter = connector.adapterFactory(alphaInstall);

    await expect(connector.listen?.(adapter)).rejects.toThrow(
      /gateway listener refused to start \(HTTP 500\): Chat instance not initialized/,
    );
  });

  it("stopListening aborts the gateway's AbortSignal", async () => {
    const { adapter, calls } = fakeGateway();
    const connector = createDiscordConnector();

    await connector.listen?.(adapter as unknown as Adapter);
    const signal = calls[0]?.signal;

    expect(signal?.aborted).toBe(false);

    await connector.stopListening?.(adapter as unknown as Adapter);

    expect(signal?.aborted).toBe(true);
  });

  it("is idempotent — a second listen() never opens a second socket for one bot", async () => {
    const { adapter, calls } = fakeGateway();
    const connector = createDiscordConnector();

    await connector.listen?.(adapter as unknown as Adapter);
    await connector.listen?.(adapter as unknown as Adapter);

    expect(calls).toHaveLength(1);

    await connector.stopListening?.(adapter as unknown as Adapter);
  });

  // STANDBY TAKEOVER (charter D93/D94): the install-lease coordinator stops the
  // Gateway socket on a replica that loses the lease and starts it on the one that
  // steals it. A replica that loses then RE-acquires must open a FRESH socket —
  // stopListening() must clear the session so the connector is re-listenable. This
  // is the connector-level property the lease relies on for takeover.
  it("re-arms after stopListening — a lease regained opens a FRESH socket (takeover)", async () => {
    const { adapter, calls } = fakeGateway();
    const connector = createDiscordConnector();

    await connector.listen?.(adapter as unknown as Adapter);
    expect(calls).toHaveLength(1);

    // Lost the lease → the coordinator stops the transport.
    await connector.stopListening?.(adapter as unknown as Adapter);

    // Re-acquired the lease → listen() again must open a NEW socket, not silently
    // no-op on a stale session left behind by the previous listen().
    await connector.listen?.(adapter as unknown as Adapter);
    expect(calls).toHaveLength(2);
    expect(calls[1]?.signal?.aborted).toBe(false);

    await connector.stopListening?.(adapter as unknown as Adapter);
  });
});

describe("gateway supervisor — a persistent process outlives one window", () => {
  it("re-arms when the gateway window ends, so the bot does not go silent forever", async () => {
    // Window 1 ends (the vendor's timer fires and destroys the client). In a
    // persistent process that is a bot that stops answering, with no error.
    let closeFirstWindow!: () => void;
    const first = new Promise<void>((resolve) => {
      closeFirstWindow = resolve;
    });
    const { adapter, calls } = fakeGateway({ windows: [() => first] });

    const session = await startSupervisedGateway({
      provider: "discord",
      adapter,
      minBackoffMs: 1,
      maxBackoffMs: 1,
      healthyAfterMs: 0, // treat the window as healthy -> immediate re-arm
      log: () => {},
    });

    expect(session.arms()).toBe(1);

    closeFirstWindow();
    await vi.waitFor(() => expect(session.arms()).toBe(2));

    expect(calls).toHaveLength(2);
    expect(calls[1]?.hasWaitUntil).toBe(true);

    await session.stop();
  });

  it("backs off instead of hot-looping when the connection keeps dying fast", async () => {
    const sleeps: number[] = [];
    // Every window rejects immediately — a revoked bot token, for instance. A
    // rejecting connection must be absorbed, never surface as an unhandled
    // rejection that kills the bridge process.
    const dying = Array.from(
      { length: 4 },
      () => () =>
        Promise.reject(new Error("gateway closed: authentication failed")),
    );

    const { adapter } = fakeGateway({ windows: dying });

    const session = await startSupervisedGateway({
      provider: "discord",
      adapter,
      minBackoffMs: 10,
      maxBackoffMs: 80,
      healthyAfterMs: 30_000,
      log: () => {},
      sleep: async (ms) => {
        sleeps.push(ms);
      },
    });

    await vi.waitFor(() => expect(sleeps.length).toBeGreaterThanOrEqual(3));
    await session.stop();

    // Exponential, and capped — never a tight spin against Discord's API.
    expect(sleeps.slice(0, 3)).toEqual([10, 20, 40]);
    expect(Math.max(...sleeps)).toBeLessThanOrEqual(80);
  });

  it("stops re-arming once aborted", async () => {
    const { adapter } = fakeGateway({ windows: [() => Promise.resolve()] });

    const session = await startSupervisedGateway({
      provider: "discord",
      adapter,
      minBackoffMs: 1,
      healthyAfterMs: 0,
      log: () => {},
    });

    await session.stop();
    const armsAtStop = session.arms();

    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(session.arms()).toBe(armsAtStop);
  });

  it("stop() returns even when the adapter IGNORES the abort signal (no hung SIGTERM)", async () => {
    // The default fake window never settles and never watches the signal. If the
    // supervisor simply awaited the connection, stop() would hang forever and
    // SIGTERM would never drain the bridge. Found by this test, fixed by racing
    // the abort.
    const { adapter } = fakeGateway();

    const session = await startSupervisedGateway({
      provider: "discord",
      adapter,
      log: () => {},
    });

    await expect(
      Promise.race([
        session.stop().then(() => "stopped"),
        new Promise((resolve) => setTimeout(() => resolve("HUNG"), 1_000)),
      ]),
    ).resolves.toBe("stopped");
  });
});
