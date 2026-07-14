import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it, vi } from "vitest";

import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall } from "../src/connector/types.js";
import { DISCORD_PROVIDER } from "../src/connectors/discord.js";
import {
  createIMessageConnector,
  isSelfHostedProfile,
  parseIMessageCredential,
  SpectrumCloudForbiddenError,
  IMESSAGE_PROVIDER,
  SELF_HOSTED_PROFILE,
} from "../src/connectors/imessage.js";
import { TELEGRAM_PROVIDER } from "../src/connectors/telegram.js";
import { registerBuiltinConnectors } from "../src/index.js";
import { createInMemoryInstallsLookup } from "../src/tenant/installs.js";

const localInstall: ConnectorInstall = {
  provider: IMESSAGE_PROVIDER,
  installKey: "mac-studio-office",
  workspaceId: "ws-operator",
  credentialRef: "local",
};

const grpcInstall: ConnectorInstall = {
  provider: IMESSAGE_PROVIDER,
  installKey: "mac-mini-closet",
  workspaceId: "ws-operator",
  credentialRef: JSON.stringify({
    mode: "self-host-grpc",
    address: "10.0.0.9:443",
    phone: "+15550001111",
    token: "relay-token-not-real",
  }),
};

/** Silent logger — the vendor's ConsoleLogger would spam the suite. */
const silentLogger = {
  child: () => silentLogger,
  debug: () => {},
  error: () => {},
  info: () => {},
  warn: () => {},
};

/** Public readonly fields on the vendor's iMessageAdapter. */
interface AdapterInternals {
  local: boolean;
  projectId?: string;
  projectSecret?: string;
  clients?: Array<{ address: string; phone: string; token: string }>;
}
const internals = (adapter: unknown): AdapterInternals =>
  adapter as unknown as AdapterInternals;

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("imessage — the PROFILE gate (fail closed for Cloud)", () => {
  it("is NOT registered under the default (Cloud) profile", () => {
    const registry = createConnectorRegistry();
    registerBuiltinConnectors(registry, {});

    // Apple has no server API: an iMessage bot is a Mac with an Apple ID. There is
    // no per-tenant credential to isolate, so Cloud must never be able to offer it.
    expect(registry.has(IMESSAGE_PROVIDER)).toBe(false);
    // The multi-tenant channels are always there.
    expect(registry.has(TELEGRAM_PROVIDER)).toBe(true);
    expect(registry.has(DISCORD_PROVIDER)).toBe(true);
  });

  it.each([
    ["unset", undefined],
    ["empty", ""],
    ["cloud", "cloud"],
    ["a near-miss typo", "selfhosted"],
    ["the wrong case", "Self-Hosted"],
  ])("is NOT registered when CONNECTORS_PROFILE is %s", (_label, profile) => {
    const registry = createConnectorRegistry();
    const env = profile === undefined ? {} : { CONNECTORS_PROFILE: profile };

    registerBuiltinConnectors(registry, { env });

    expect(registry.has(IMESSAGE_PROVIDER)).toBe(false);
    expect(registry.channels().map((c) => c.id)).not.toContain(IMESSAGE_PROVIDER);
  });

  it("IS registered when CONNECTORS_PROFILE=self-hosted", () => {
    const registry = createConnectorRegistry();
    registerBuiltinConnectors(registry, {
      env: { CONNECTORS_PROFILE: SELF_HOSTED_PROFILE },
    });

    expect(registry.has(IMESSAGE_PROVIDER)).toBe(true);
    expect(registry.get(IMESSAGE_PROVIDER)?.direction).toBe("channel");
    expect(registry.channels().map((c) => c.id)).toContain(IMESSAGE_PROVIDER);
  });

  it("isSelfHostedProfile fails closed on anything but the exact string", () => {
    expect(isSelfHostedProfile({})).toBe(false);
    expect(isSelfHostedProfile({ CONNECTORS_PROFILE: "" })).toBe(false);
    expect(isSelfHostedProfile({ CONNECTORS_PROFILE: "cloud" })).toBe(false);
    expect(isSelfHostedProfile({ CONNECTORS_PROFILE: "self-hosted " })).toBe(true); // trimmed
    expect(isSelfHostedProfile({ CONNECTORS_PROFILE: "self-hosted" })).toBe(true);
  });
});

describe("imessage — registration shape", () => {
  it("declares direction=channel, tenantResolution=credential-bound", () => {
    const connector = createIMessageConnector({ logger: silentLogger });

    expect(connector.id).toBe("imessage");
    expect(connector.direction).toBe("channel");
    expect(connector.tenantResolution).toBe("credential-bound");
    // The Mac IS the binding. An iMessage payload has no org/team id — Apple has
    // no notion of one — so payload-team-id would be unimplementable.
    expect(typeof connector.listen).toBe("function");
    expect(typeof connector.stopListening).toBe("function");
  });

  it("pins the vendor to an EXACT version (this vendor broke its own transport once)", () => {
    const manifest = JSON.parse(
      readFileSync(new URL("../package.json", import.meta.url), "utf8"),
    ) as { dependencies: Record<string, string> };

    const pinned = manifest.dependencies["chat-adapter-imessage"];

    // No caret, no tilde, no range: a silent minor bump swapped HTTP/Socket.IO for
    // gRPC once already.
    expect(pinned).toMatch(/^\d+\.\d+\.\d+$/);
  });
});

describe("imessage — credentials (Spectrum Cloud is FORBIDDEN)", () => {
  it("accepts the bare 'local' relay — the bridge runs ON the Mac", () => {
    expect(parseIMessageCredential("local")).toEqual({ mode: "local" });
    expect(parseIMessageCredential("")).toEqual({ mode: "local" });
    expect(parseIMessageCredential('{"mode":"local"}')).toEqual({
      mode: "local",
    });
  });

  it("accepts an explicit self-hosted gRPC relay on your own Mac", () => {
    expect(parseIMessageCredential(grpcInstall.credentialRef)).toEqual({
      mode: "self-host-grpc",
      address: "10.0.0.9:443",
      phone: "+15550001111",
      token: "relay-token-not-real",
    });
  });

  it("REFUSES a Spectrum Cloud credential — it moves the Mac to a third party", () => {
    // The vendor's hosted mode does not remove the Mac; it hands a stranger
    // (photon.codes) real Apple credentials. Charter D3 deliberately avoids that
    // trust decision, so the code refuses rather than leaving it a doc footnote.
    expect(() =>
      parseIMessageCredential(
        JSON.stringify({ projectId: "proj_123", projectSecret: "sekrit" }),
      ),
    ).toThrow(SpectrumCloudForbiddenError);

    expect(() =>
      parseIMessageCredential(
        JSON.stringify({ projectId: "proj_123", projectSecret: "sekrit" }),
      ),
    ).toThrow(/photon\.codes/);
  });

  it("REFUSES a cloud credential smuggled in behind mode:local", () => {
    expect(() =>
      parseIMessageCredential(
        JSON.stringify({ mode: "local", projectId: "proj_123" }),
      ),
    ).toThrow(SpectrumCloudForbiddenError);
  });

  it("rejects an incomplete gRPC relay rather than half-configuring it", () => {
    expect(() =>
      parseIMessageCredential(
        JSON.stringify({ mode: "self-host-grpc", address: "10.0.0.9:443" }),
      ),
    ).toThrow(/"phone" is required/);

    expect(() => parseIMessageCredential('{"mode":"spectrum-cloud"}')).toThrow(
      /mode must be "local" or "self-host-grpc"/,
    );
  });
});

/**
 * Local mode drives the Messages database on the relay Mac, so the vendor's
 * constructor hard-refuses to build on any other platform. That refusal is the
 * product truth (D: iMessage is a self-hosted macOS profile, never Cloud), and
 * CI is Linux — so the local-mode leg asserts what is TRUE on the platform it
 * runs on. It is never skipped: on Linux, reaching the macOS guard is itself
 * proof we asked the constructor for `local: true` and handed it no cloud
 * config, which is the whole claim of this describe block.
 */
const ON_MAC = process.platform === "darwin";

describe("imessage — adapter construction reads NO environment", () => {
  it("builds a REAL local iMessageAdapter from the install credential", () => {
    const connector = createIMessageConnector({ logger: silentLogger });

    if (!ON_MAC) {
      expect(() => connector.adapterFactory(localInstall)).toThrow(
        /requires macOS/,
      );
      return;
    }

    const adapter = connector.adapterFactory(localInstall);

    expect(adapter.name).toBe("imessage");
    expect(typeof adapter.postMessage).toBe("function");
    expect(typeof adapter.encodeThreadId).toBe("function");
    expect(internals(adapter).local).toBe(true);
  });

  it("builds a self-hosted gRPC adapter pointed at YOUR Mac", () => {
    const connector = createIMessageConnector({ logger: silentLogger });
    const adapter = connector.adapterFactory(grpcInstall);

    expect(internals(adapter).local).toBe(false);
    expect(internals(adapter).clients).toEqual([
      {
        address: "10.0.0.9:443",
        phone: "+15550001111",
        token: "relay-token-not-real",
      },
    ]);
    expect(internals(adapter).projectId).toBeUndefined();
  });

  it("a poisoned IMESSAGE_PROJECT_* environment can NOT route a tenant to Spectrum Cloud", () => {
    // The vendor's createiMessageAdapter() factory does
    // `config?.projectId ?? process.env.IMESSAGE_PROJECT_ID` — so a stray env var
    // in the deployment would silently push messages through photon.codes. We
    // never call that factory; we construct the class directly, which reads
    // nothing from the environment. Poison the env and prove it.
    //
    // Proven on the gRPC install: self-host-grpc is the ONLY mode that carries a
    // remote endpoint at all, so it is the only mode a stray projectId could
    // actually divert. (Local mode has no network path to divert, and its
    // constructor is macOS-only — see ON_MAC above.)
    vi.stubEnv("IMESSAGE_PROJECT_ID", "POISON_PROJECT");
    vi.stubEnv("IMESSAGE_PROJECT_SECRET", "POISON_SECRET");
    vi.stubEnv("IMESSAGE_SERVER_URL", "https://api.photon.codes");
    vi.stubEnv("IMESSAGE_API_KEY", "POISON_KEY");

    const connector = createIMessageConnector({ logger: silentLogger });
    const adapter = connector.adapterFactory(grpcInstall);

    expect(internals(adapter).local).toBe(false);
    expect(internals(adapter).projectId).toBeUndefined();
    expect(internals(adapter).projectSecret).toBeUndefined();
    // Still pointed at YOUR Mac, not at photon.codes.
    expect(internals(adapter).clients).toEqual([
      {
        address: "10.0.0.9:443",
        phone: "+15550001111",
        token: "relay-token-not-real",
      },
    ]);

    if (ON_MAC) {
      const local = connector.adapterFactory(localInstall);
      expect(internals(local).local).toBe(true);
      expect(internals(local).projectId).toBeUndefined();
      expect(internals(local).projectSecret).toBeUndefined();
    }
  });
});

describe("imessage — tenant resolution (credential-bound, fail closed)", () => {
  const installs = {
    installs: createInMemoryInstallsLookup([localInstall, grpcInstall]),
  };
  const connector = createIMessageConnector({ logger: silentLogger });

  const event = (installKey?: string) => ({
    provider: IMESSAGE_PROVIDER,
    threadId: "imessage;-;+15550001111",
    text: "hi",
    ...(installKey === undefined ? {} : { installKey }),
  });

  it("routes a relay Mac to the ONE workspace that owns it", async () => {
    await expect(
      connector.resolveTenant(event("mac-studio-office"), installs),
    ).resolves.toBe("ws-operator");
  });

  it("returns null for an unknown Mac and for a nameless transport", async () => {
    await expect(
      connector.resolveTenant(event("some-other-mac"), installs),
    ).resolves.toBeNull();
    await expect(connector.resolveTenant(event(), installs)).resolves.toBeNull();
  });
});
