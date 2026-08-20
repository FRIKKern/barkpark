import { ConsoleLogger, type Adapter } from "chat";
import { iMessageAdapter } from "chat-adapter-imessage";

import type {
  Connector,
  ConnectorInstall,
  InboundEvent,
  TenantContext,
} from "../connector/types.js";
import { credentialBoundResolver } from "../tenant/resolve.js";
import {
  startSupervisedGateway,
  type GatewaySession,
  type GatewayTuning,
} from "./gateway.js";

/**
 * iMessage — a self-hosted OPERATOR PROFILE, not a product (charter D3/D44).
 *
 * Apple ships no server API for iMessage. Every "iMessage bot" on earth is a Mac
 * sitting somewhere with Messages.app signed into an Apple ID, being automated.
 * That is a real thing an operator can run for THEMSELVES; it is not a thing
 * Barkpark Cloud can offer a tenant. So this connector is deliberately
 * unavailable unless the process declares `CONNECTORS_PROFILE=self-hosted` — see
 * {@link isSelfHostedProfile}, which `registerBuiltinConnectors` consults, and
 * which FAILS CLOSED (an unset profile is not self-hosted). A Cloud deployment
 * cannot accidentally offer iMessage; there is no configuration mistake that
 * turns it on.
 *
 * ONE WORKSPACE PER MAC. The Mac's Apple ID is the identity — there is no
 * per-tenant credential to isolate, which is precisely why this does not fit
 * multi-tenant Cloud. `tenantResolution` is `credential-bound` (the install row
 * binds this Mac to one workspace), and honesty about the model matters more
 * than the label: the isolation boundary here is the MACHINE, not the token.
 *
 * SPECTRUM CLOUD IS FORBIDDEN. The vendor offers a hosted "Spectrum Cloud" mode
 * (`projectId` + `projectSecret` → photon.codes). It looks like the easy Cloud
 * win and it is NOT one: it does not remove the Mac, it moves it to a third party
 * who then holds real Apple credentials. Barkpark has not made that trust
 * decision (charter D3 deliberately avoids it), so {@link parseIMessageCredential}
 * REJECTS a cloud credential, and this file never calls the vendor's
 * `createiMessageAdapter` factory — that factory reads
 * `process.env.IMESSAGE_PROJECT_ID` / `IMESSAGE_PROJECT_SECRET`
 * (`node_modules/chat-adapter-imessage/dist/index.js:985-1005`), so a stray
 * environment variable could silently route a tenant's messages through
 * photon.codes. We construct `iMessageAdapter` DIRECTLY, which reads no
 * environment at all. Full picture: `docs/ops/imessage-self-host.md`.
 *
 * PIN THE VERSION. This vendor already broke its own transport once (HTTP /
 * Socket.IO → gRPC). `package.json` pins `chat-adapter-imessage` to an exact
 * version — never a caret.
 */

export const IMESSAGE_PROVIDER = "imessage";

/** The only profile in which iMessage may be mounted. */
export const SELF_HOSTED_PROFILE = "self-hosted";

/**
 * Is this process a self-hosted operator install?
 *
 * FAIL-CLOSED: anything other than the exact string `self-hosted` — unset, empty,
 * "cloud", a typo — is NOT self-hosted. Cloud is the default, and Cloud does not
 * get iMessage.
 */
export function isSelfHostedProfile(env: NodeJS.ProcessEnv = process.env): boolean {
  return env["CONNECTORS_PROFILE"]?.trim() === SELF_HOSTED_PROFILE;
}

/**
 * One operator's iMessage relay, as stored in `connector_installs.credential_ref`.
 *
 * - `local` — the bridge process runs ON the Mac and drives Messages.app directly.
 * - `self-host-grpc` — the bridge runs elsewhere and talks to an
 *   `@photon-ai/advanced-imessage` gRPC server on YOUR Mac.
 *
 * Both keep the Mac, and the Apple ID, under the operator's own control. There is
 * deliberately no third variant.
 */
export type IMessageCredential =
  | { mode: "local" }
  | {
      mode: "self-host-grpc";
      /** gRPC `host:port` of your own relay Mac. */
      address: string;
      /** The number/handle this relay sends as. `"shared"` for a single-number Mac. */
      phone: string;
      /** Auth token for YOUR relay server. */
      token: string;
    };

/** Thrown when an install tries to route iMessage through the vendor's hosted SaaS. */
export class SpectrumCloudForbiddenError extends Error {
  constructor() {
    super(
      "iMessage: Spectrum Cloud (projectId/projectSecret) is FORBIDDEN. It does not remove " +
        "the Mac — it moves it to a third party (photon.codes) that then holds real Apple " +
        "credentials. Barkpark has not made that trust decision (charter D3). Run your own " +
        "Mac: see docs/ops/imessage-self-host.md.",
    );
    this.name = "SpectrumCloudForbiddenError";
  }
}

function requireString(record: Record<string, unknown>, field: string): string {
  const value = record[field];
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(
      `invalid iMessage credential: "${field}" is required for self-host-grpc mode ` +
        "and must be a non-empty string",
    );
  }
  return value.trim();
}

/**
 * Parse an install's `credential_ref` into an iMessage relay credential.
 *
 * Accepts the bare string `local` (the common case — the bridge runs on the Mac),
 * or a JSON object for an explicit gRPC relay. REJECTS anything carrying Spectrum
 * Cloud credentials, loudly.
 */
export function parseIMessageCredential(
  credentialRef: string | null | undefined,
): IMessageCredential {
  // NULL, absent and "" all mean "the Mac this process runs on" — the local relay
  // needs no stored secret. (NULL is a first-class column state since D42;
  // `undefined` since D52 made `credentialRef` optional on the write path.)
  const raw = credentialRef?.trim() ?? "";

  if (raw === "" || raw === "local") return { mode: "local" };

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(
      'invalid iMessage credential: expected "local", or JSON ' +
        '{"mode":"self-host-grpc","address":"host:port","phone":"…","token":"…"}',
    );
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(
      'invalid iMessage credential: expected "local" or a JSON object',
    );
  }

  const record = parsed as Record<string, unknown>;

  // Checked BEFORE the mode switch: a cloud credential must be refused however
  // it is dressed up, including a `{"mode":"local", "projectId": …}` mix.
  if (record["projectId"] !== undefined || record["projectSecret"] !== undefined) {
    throw new SpectrumCloudForbiddenError();
  }

  if (record["mode"] === "local") return { mode: "local" };

  if (record["mode"] !== "self-host-grpc") {
    throw new Error(
      `invalid iMessage credential: mode must be "local" or "self-host-grpc", got ` +
        `${JSON.stringify(record["mode"])}`,
    );
  }

  return {
    mode: "self-host-grpc",
    address: requireString(record, "address"),
    phone: requireString(record, "phone"),
    token: requireString(record, "token"),
  };
}

export interface IMessageConnectorOptions {
  /** Gateway supervisor tuning. Tests inject fake timers; production takes the defaults. */
  gateway?: GatewayTuning;
  /** Injectable for tests. Defaults to the SDK's ConsoleLogger. */
  logger?: ConstructorParameters<typeof iMessageAdapter>[0]["logger"];
}

export function createIMessageConnector(
  options: IMessageConnectorOptions = {},
): Connector {
  const resolver = credentialBoundResolver();
  const logger =
    options.logger ?? new ConsoleLogger("info").child(IMESSAGE_PROVIDER);

  const sessions = new Map<Adapter, GatewaySession>();

  return {
    id: IMESSAGE_PROVIDER,
    direction: "channel",
    auth: "token",
    // The relay Mac IS the binding. There is no tenant id anywhere in an iMessage
    // payload — Apple has no notion of an org — so a payload-team-id strategy
    // would be unimplementable, exactly as with Telegram.
    tenantResolution: "credential-bound",

    /**
     * Construct the adapter DIRECTLY, never via the vendor's `createiMessageAdapter`
     * factory: that factory env-falls-back to `IMESSAGE_PROJECT_ID` /
     * `IMESSAGE_PROJECT_SECRET`, so a stray environment variable could route a
     * tenant through Spectrum Cloud. The class constructor reads no environment.
     */
    adapterFactory(install: ConnectorInstall): Adapter {
      const credential = parseIMessageCredential(install.credentialRef);

      if (credential.mode === "local") {
        return new iMessageAdapter({ local: true, logger });
      }

      return new iMessageAdapter({
        local: false,
        logger,
        clients: [
          {
            address: credential.address,
            phone: credential.phone,
            token: credential.token,
          },
        ],
        phone: credential.phone,
      });
    },

    async resolveTenant(
      event: InboundEvent,
      ctx: TenantContext,
    ): Promise<string | null> {
      return resolver(event, ctx);
    },

    /**
     * Start the inbound message pump. Same `startGatewayListener` shape as Discord
     * — and the same three traps (a same-tick 500 that looks like silence, a
     * `durationMs` that is really a `setTimeout` delay, a window that ends). The
     * shared supervisor in `gateway.ts` handles all three.
     */
    async listen(adapter: Adapter): Promise<void> {
      if (sessions.has(adapter)) return;

      const session = await startSupervisedGateway({
        provider: IMESSAGE_PROVIDER,
        adapter: adapter as unknown as iMessageAdapter,
        ...options.gateway,
      });

      sessions.set(adapter, session);
    },

    async stopListening(adapter: Adapter): Promise<void> {
      const session = sessions.get(adapter);
      if (!session) return;

      sessions.delete(adapter);
      await session.stop();
    },
  };
}
