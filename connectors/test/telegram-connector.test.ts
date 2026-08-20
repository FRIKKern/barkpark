import { describe, expect, it, vi } from "vitest";

import type { Adapter } from "chat";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall } from "../src/connector/types.js";
import {
  createTelegramConnector,
  startSupervisedPolling,
  telegramBotIdFromToken,
  type SupervisedPoller,
  TELEGRAM_PROVIDER,
} from "../src/connectors/telegram.js";
import { createInMemoryInstallsLookup } from "../src/tenant/installs.js";

const BOT_TOKEN = "123456789:AAHfake-not-a-real-botfather-token";
const BOT_ID = "123456789";

const install: ConnectorInstall = {
  provider: TELEGRAM_PROVIDER,
  installKey: BOT_ID,
  workspaceId: "ws-alpha",
  credentialRef: BOT_TOKEN,
};

describe("telegram connector — registration shape", () => {
  it("declares direction=channel, auth=token, tenantResolution=credential-bound", () => {
    const connector = createTelegramConnector();

    expect(connector.id).toBe("telegram");
    expect(connector.direction).toBe("channel");
    expect(connector.auth).toBe("token");
    // Telegram's payload carries NO team/org id, so the credential IS the
    // tenant binding (charter D29). A payload-team-id strategy here would be
    // unimplementable.
    expect(connector.tenantResolution).toBe("credential-bound");
  });

  it("registers into the registry as an ordinary channel connector", () => {
    const registry = createConnectorRegistry();
    registry.register(createTelegramConnector());

    expect(registry.list().map((c) => c.id)).toEqual([TELEGRAM_PROVIDER]);
    expect(registry.get(TELEGRAM_PROVIDER)?.direction).toBe("channel");
    // Only inbound connectors become `new Chat({ adapters })` entries.
    expect(registry.channels().map((c) => c.id)).toEqual([TELEGRAM_PROVIDER]);
  });

  it("refuses a duplicate registration instead of silently overwriting", () => {
    const registry = createConnectorRegistry();
    registry.register(createTelegramConnector());

    expect(() => registry.register(createTelegramConnector())).toThrow(
      /duplicate connector id/,
    );
  });

  it("builds a real @chat-adapter/telegram adapter from the install credential", () => {
    const connector = createTelegramConnector({ mode: "polling" });
    const adapter = connector.adapterFactory(install);

    // The SDK Adapter contract — this is a genuine adapter, not a stub.
    expect(typeof adapter.postMessage).toBe("function");
    expect(typeof adapter.encodeThreadId).toBe("function");
    expect(typeof (adapter as { startPolling?: unknown }).startPolling).toBe(
      "function",
    );
    expect((adapter as { isPolling?: boolean }).isPolling).toBe(false);
  });

  it("exposes a listen/stopListening lifecycle so the core never names the channel", () => {
    const connector = createTelegramConnector({ mode: "polling" });

    // The boot path calls connector.listen?.(adapter) — Telegram starts a poll
    // loop, P3's Slack (webhook) will leave these undefined.
    expect(typeof connector.listen).toBe("function");
    expect(typeof connector.stopListening).toBe("function");
  });

  it("derives the install key from the bot token's non-secret half", () => {
    // The routing table keys on the bot id, never on the raw secret.
    expect(telegramBotIdFromToken(BOT_TOKEN)).toBe(BOT_ID);
    expect(() => telegramBotIdFromToken(":no-bot-id")).toThrow(
      /invalid Telegram bot token/,
    );
  });

  it("rejects a token whose first segment is not the digits-only bot id", () => {
    // connectors-telegram-token-shape-guard: before this was tightened the
    // function only rejected an EMPTY first segment, so a paste error like
    // "not-a-token" derived a bogus install key and failed only at the first
    // poll. It now throws the same "invalid Telegram bot token" as the empty
    // case — one shape guard, caught at connect time.
    expect(() => telegramBotIdFromToken("not-a-token")).toThrow(
      /invalid Telegram bot token/,
    );
    expect(() => telegramBotIdFromToken("abc:secret")).toThrow(
      /invalid Telegram bot token/,
    );
    // The valid shape still parses to the digits-only bot id.
    expect(telegramBotIdFromToken("123456789:AAE-secret")).toBe("123456789");
  });
});

describe("telegram connector — tenant resolution (credential-bound, fail closed)", () => {
  const lookup = createInMemoryInstallsLookup([install]);
  const installs = { installs: lookup };
  const connector = createTelegramConnector();

  const event = (
    overrides: Partial<Parameters<typeof connector.resolveTenant>[0]> = {},
  ) => ({
    provider: TELEGRAM_PROVIDER,
    threadId: "telegram:555",
    text: "hi",
    installKey: BOT_ID,
    ...overrides,
  });

  it("resolves the workspace that owns the bot", async () => {
    await expect(connector.resolveTenant(event(), installs)).resolves.toBe(
      "ws-alpha",
    );
  });

  it("returns null for a bot nobody installed — never a default workspace", async () => {
    await expect(
      connector.resolveTenant(event({ installKey: "999999999" }), installs),
    ).resolves.toBeNull();
  });

  it("returns null when the transport could not say which bot received it", async () => {
    const anonymous = event();
    delete (anonymous as { installKey?: string }).installKey;

    await expect(connector.resolveTenant(anonymous, installs)).resolves.toBeNull();
  });
});

/**
 * A faithful stand-in for the vendor's public polling surface, reproducing the
 * two behaviours the watchdog exists to survive (verified against
 * `node_modules/@chat-adapter/telegram/dist/index.js`):
 *
 *   - startPolling() sets `pollingActive = true` (isPolling true), OR
 *   - startPolling() THROWS synchronously (a `resetWebhook` failure) leaving
 *     `pollingActive = false` — the mount throw that used to brick the install.
 *   - the poll loop can SETTLE on its own, flipping `pollingActive` false with
 *     no error and no event — the silent settle, exposed only via `isPolling`.
 *
 * Only the public `isPolling`/`startPolling`/`stopPolling` surface is modelled:
 * the watchdog must never touch the private `pollingTask`/`pollingActive`.
 */
function fakePoller(
  options: {
    /** Outcome per successive startPolling() call; missing entries default "ok". */
    arms?: Array<"ok" | Error>;
  } = {},
) {
  const outcomes = options.arms ?? [];
  let polling = false;
  let index = 0;
  /** One entry per startPolling() invocation — the arm counter's ground truth. */
  const startCalls: number[] = [];

  const adapter: SupervisedPoller = {
    get isPolling() {
      return polling;
    },
    async startPolling() {
      const outcome = outcomes[index++] ?? "ok";
      startCalls.push(index);
      if (outcome instanceof Error) {
        // The vendor sets pollingActive = false and rethrows on resetWebhook
        // failure (index.js:1047-1051). Mirror that exactly.
        polling = false;
        throw outcome;
      }
      polling = true;
    },
    async stopPolling() {
      polling = false;
    },
  };

  return {
    adapter,
    startCalls,
    /** Simulate the vendor loop ending on its own — the silent settle. */
    settle() {
      polling = false;
    },
  };
}

describe("telegram poll watchdog — a persistent process outlives one poll loop", () => {
  it("re-arms a poll loop that settled silently, so the bot never goes quiet forever", async () => {
    // The vendor's pollingLoop self-heals per iteration, but if it EVER returns,
    // `.finally(() => pollingActive = false)` flips isPolling false with no error.
    // Nothing re-arms it — the bot goes silent. The health-check catches this.
    const poller = fakePoller();

    const session = await startSupervisedPolling({
      provider: TELEGRAM_PROVIDER,
      adapter: poller.adapter,
      minBackoffMs: 1,
      maxBackoffMs: 1,
      healthyAfterMs: 0, // any window counts as healthy -> immediate re-arm
      healthCheckIntervalMs: 1,
      log: () => {},
    });

    expect(session.arms()).toBe(1);
    expect(poller.adapter.isPolling).toBe(true);

    poller.settle(); // isPolling silently reads false

    await vi.waitFor(() => expect(session.arms()).toBe(2));
    expect(poller.adapter.isPolling).toBe(true);

    await session.stop();
  });

  it("does not re-arm after stop() — no zombie re-arm once the operator takes the bot down", async () => {
    // stopListening disarms the watchdog BEFORE stopping the vendor loop. The
    // deliberate isPolling=false that follows must NOT be mistaken for a settle.
    const poller = fakePoller();

    const session = await startSupervisedPolling({
      provider: TELEGRAM_PROVIDER,
      adapter: poller.adapter,
      minBackoffMs: 1,
      healthyAfterMs: 0,
      healthCheckIntervalMs: 1,
      log: () => {},
    });

    expect(session.arms()).toBe(1);

    await session.stop();
    const armsAtStop = session.arms();

    poller.settle();
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(session.arms()).toBe(armsAtStop);
  });

  it("retries a synchronously-throwing initial arm until it finally polls", async () => {
    // resetWebhook failed at mount three times (a transient Telegram 5xx) then
    // succeeded. Before this watchdog the FIRST throw permanently failed the
    // install with zero retry — the exact regression D84 exists to kill.
    const poller = fakePoller({
      arms: [
        new Error("deleteWebhook failed: 502"),
        new Error("deleteWebhook failed: 502"),
        new Error("deleteWebhook failed: 502"),
      ],
    });

    const session = await startSupervisedPolling({
      provider: TELEGRAM_PROVIDER,
      adapter: poller.adapter,
      minBackoffMs: 1,
      maxBackoffMs: 4,
      healthyAfterMs: 30_000,
      healthCheckIntervalMs: 1,
      log: () => {},
    });

    // The first arm (awaited) threw — the bot is NOT polling yet, but the
    // install is not bricked: the watchdog keeps trying in the background.
    expect(session.arms()).toBe(1);
    expect(poller.adapter.isPolling).toBe(false);

    await vi.waitFor(() => expect(poller.adapter.isPolling).toBe(true));
    expect(session.arms()).toBe(4); // 3 throws + the success

    await session.stop();
  });

  it("backs off exponentially instead of hot-looping when the arm keeps failing", async () => {
    const sleeps: number[] = [];
    const poller = fakePoller({
      arms: [
        new Error("deleteWebhook failed"),
        new Error("deleteWebhook failed"),
        new Error("deleteWebhook failed"),
        new Error("deleteWebhook failed"),
      ],
    });

    const session = await startSupervisedPolling({
      provider: TELEGRAM_PROVIDER,
      adapter: poller.adapter,
      minBackoffMs: 10,
      maxBackoffMs: 80,
      healthyAfterMs: 30_000,
      healthCheckIntervalMs: 5_000,
      log: () => {},
      // Record the schedule; yield to a macrotask so the loop never starves
      // vi.waitFor and the abort in stop() is always observed.
      sleep: async (ms) => {
        sleeps.push(ms);
        await new Promise((resolve) => setTimeout(resolve, 0));
      },
    });

    await vi.waitFor(() => expect(sleeps.length).toBeGreaterThanOrEqual(3));
    await session.stop();

    // The re-arm backoffs (health-check intervals and the zero-delay first arm
    // filtered out) are exponential and capped — never a tight spin.
    const backoffs = sleeps.filter((ms) => ms !== 5_000 && ms !== 0);
    expect(backoffs.slice(0, 3)).toEqual([10, 20, 40]);
    expect(Math.max(...backoffs)).toBeLessThanOrEqual(80);
  });
});

describe("telegram connector — listen()/stopListening() drive the watchdog", () => {
  it("listen() arms the watchdog; stopListening() disarms it AND stops the vendor loop", async () => {
    const poller = fakePoller();
    const connector = createTelegramConnector({
      mode: "polling",
      polling: {
        minBackoffMs: 1,
        healthyAfterMs: 0,
        healthCheckIntervalMs: 1,
        log: () => {},
      },
    });

    await connector.listen?.(poller.adapter as unknown as Adapter);
    expect(poller.adapter.isPolling).toBe(true);
    expect(poller.startCalls.length).toBe(1);

    await connector.stopListening?.(poller.adapter as unknown as Adapter);
    expect(poller.adapter.isPolling).toBe(false);

    // Disarmed: a post-takedown settle must NOT re-arm (no zombie watchdog).
    const armsAfterStop = poller.startCalls.length;
    poller.settle();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(poller.startCalls.length).toBe(armsAfterStop);
  });

  it("is idempotent — a second listen() never opens a second watchdog for one bot", async () => {
    const poller = fakePoller();
    const connector = createTelegramConnector({
      mode: "polling",
      polling: { healthCheckIntervalMs: 10_000, log: () => {} },
    });

    await connector.listen?.(poller.adapter as unknown as Adapter);
    await connector.listen?.(poller.adapter as unknown as Adapter);

    expect(poller.startCalls.length).toBe(1);

    await connector.stopListening?.(poller.adapter as unknown as Adapter);
  });

  // STANDBY TAKEOVER (charter D93/D94): the install-lease coordinator stops the
  // poll on a replica that loses the lease and starts it on the one that steals it.
  // A replica that loses then RE-acquires (holder came back, or a flap) must re-arm
  // a FRESH watchdog — stopListening() must leave the connector re-listenable, not
  // wedged with a stale session. This is the connector-level property the lease
  // relies on for takeover.
  it("re-arms after stopListening — a lease regained opens a FRESH poll (takeover)", async () => {
    const poller = fakePoller();
    const connector = createTelegramConnector({
      mode: "polling",
      polling: { healthCheckIntervalMs: 10_000, log: () => {} },
    });

    await connector.listen?.(poller.adapter as unknown as Adapter);
    expect(poller.startCalls.length).toBe(1);

    // Lost the lease → the coordinator stops the transport.
    await connector.stopListening?.(poller.adapter as unknown as Adapter);
    expect(poller.adapter.isPolling).toBe(false);

    // Re-acquired the lease → listen() again must arm a NEW watchdog (not a no-op
    // left over from the stale sessions map).
    await connector.listen?.(poller.adapter as unknown as Adapter);
    expect(poller.startCalls.length).toBe(2);
    expect(poller.adapter.isPolling).toBe(true);

    await connector.stopListening?.(poller.adapter as unknown as Adapter);
  });
});
