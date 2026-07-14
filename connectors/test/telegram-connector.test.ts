import { describe, expect, it } from "vitest";

import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall } from "../src/connector/types.js";
import {
  createTelegramConnector,
  telegramBotIdFromToken,
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
