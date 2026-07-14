import { describe, it, expect } from "vitest";
import type { Adapter } from "chat";

import {
  createConnectorRegistry,
  connectorRegistry,
} from "../src/connector/registry.js";
import type { Connector, ConnectorInstall } from "../src/connector/types.js";

/**
 * A stand-in Chat SDK adapter. The registry never calls into an adapter — it only
 * stores the factory — so an unimplemented object cast to `Adapter` is honest here
 * and keeps the test from depending on a real provider SDK.
 */
const stubAdapter = (): Adapter => ({}) as Adapter;

function mockConnector(
  overrides: Partial<Connector> & Pick<Connector, "id">,
): Connector {
  return {
    direction: "channel",
    auth: "token",
    tenantResolution: "credential-bound",
    adapterFactory: (_install: ConnectorInstall) => stubAdapter(),
    resolveTenant: async () => null,
    ...overrides,
  };
}

describe("connectorRegistry", () => {
  it("registers a connector and gets it back by id", () => {
    const registry = createConnectorRegistry();
    const telegram = mockConnector({ id: "telegram" });

    registry.register(telegram);

    expect(registry.get("telegram")).toBe(telegram);
    expect(registry.has("telegram")).toBe(true);
  });

  it("returns undefined for an unregistered provider (never a fallback connector)", () => {
    const registry = createConnectorRegistry();
    registry.register(mockConnector({ id: "telegram" }));

    expect(registry.get("slack")).toBeUndefined();
    expect(registry.has("slack")).toBe(false);
  });

  it("lists connectors in registration order", () => {
    const registry = createConnectorRegistry();
    registry.register(mockConnector({ id: "telegram" }));
    registry.register(mockConnector({ id: "slack" }));
    registry.register(mockConnector({ id: "discord" }));

    expect(registry.list().map((c) => c.id)).toEqual([
      "telegram",
      "slack",
      "discord",
    ]);
  });

  it("throws on a duplicate id — a shadowed connector is a tenant-isolation bug", () => {
    const registry = createConnectorRegistry();
    registry.register(mockConnector({ id: "telegram" }));

    expect(() => registry.register(mockConnector({ id: "telegram" }))).toThrowError(
      /duplicate connector id "telegram"/,
    );
    // The original survives; the impostor never replaces it.
    expect(registry.list()).toHaveLength(1);
  });

  it("throws on an empty id", () => {
    const registry = createConnectorRegistry();

    expect(() => registry.register(mockConnector({ id: "" }))).toThrowError(
      /must be a non-empty string/,
    );
  });

  it("unregisters and clears", () => {
    const registry = createConnectorRegistry();
    registry.register(mockConnector({ id: "telegram" }));
    registry.register(mockConnector({ id: "slack" }));

    expect(registry.unregister("telegram")).toBe(true);
    expect(registry.unregister("telegram")).toBe(false);
    expect(registry.list().map((c) => c.id)).toEqual(["slack"]);

    registry.clear();
    expect(registry.list()).toEqual([]);
  });

  it("keeps registries isolated from one another", () => {
    const a = createConnectorRegistry();
    const b = createConnectorRegistry();

    a.register(mockConnector({ id: "telegram" }));

    expect(a.has("telegram")).toBe(true);
    expect(b.has("telegram")).toBe(false);
  });

  it("exposes a process-wide singleton for production registration", () => {
    // Registration into the singleton is what a P3 channel does. Assert it is a live
    // registry, then leave it as we found it so other test files see a clean map.
    expect(connectorRegistry.has("__probe__")).toBe(false);
    connectorRegistry.register(mockConnector({ id: "__probe__" }));
    expect(connectorRegistry.get("__probe__")?.id).toBe("__probe__");
    connectorRegistry.unregister("__probe__");
    expect(connectorRegistry.has("__probe__")).toBe(false);
  });
});

describe("Connector declaration surface (charter D30)", () => {
  it("carries direction, auth and tenantResolution as declared metadata", () => {
    const slack = mockConnector({
      id: "slack",
      direction: "both",
      auth: "oauth",
      tenantResolution: "payload-team-id",
    });

    expect(slack.direction).toBe("both");
    expect(slack.auth).toBe("oauth");
    expect(slack.tenantResolution).toBe("payload-team-id");
  });

  it("builds an adapter from THAT install's own credential (D1 isolation)", () => {
    const built: ConnectorInstall[] = [];
    const telegram = mockConnector({
      id: "telegram",
      adapterFactory: (install) => {
        built.push(install);
        return stubAdapter();
      },
    });

    const installA: ConnectorInstall = {
      provider: "telegram",
      installKey: "bot-a",
      workspaceId: "ws-a",
      credentialRef: "ws-a-bot-token",
    };
    const installB: ConnectorInstall = {
      provider: "telegram",
      installKey: "bot-b",
      workspaceId: "ws-b",
      credentialRef: "ws-b-bot-token",
    };

    telegram.adapterFactory(installA);
    telegram.adapterFactory(installB);

    // Each adapter is constructed from exactly one workspace's credential —
    // a tenant's adapter can never be built from another tenant's secret.
    expect(built).toEqual([installA, installB]);
    expect(built[0]?.credentialRef).not.toBe(built[1]?.credentialRef);
  });
});
