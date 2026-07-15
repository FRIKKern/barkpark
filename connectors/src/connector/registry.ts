/**
 * The connector registry (charter D30) — a plain map, deliberately boring.
 *
 * Adding a P3 channel is ONE call:
 *
 *     connectorRegistry.register(slackConnector);
 *
 * No edit to this file, and no edit to `tenant/resolve.ts`. The Chat SDK's own
 * `new Chat({ adapters: Record<string, Adapter> })` shape already delivers
 * "register an adapter, no core change"; this mirrors it one level up, at the
 * connector (adapter + auth + tenant-routing) granularity.
 */
import type { Connector } from "./types.js";

export interface ConnectorRegistry {
  /**
   * Register a connector under its `id`.
   * Throws on a duplicate id: a silently-shadowed connector would mean inbound events
   * routing through the wrong workspace's credentials — a tenant-isolation bug. Fail loud.
   */
  register(connector: Connector): void;
  /** The connector for a provider id, or `undefined` when nothing is registered. */
  get(id: string): Connector | undefined;
  /** True when a provider id is registered. */
  has(id: string): boolean;
  /** All registered connectors, in registration order. */
  list(): Connector[];
  /**
   * Only the inbound-capable connectors. The boot path mounts one Chat per
   * install of each of these; a `tool`-only connector (P4: GitHub, Linear) has no
   * inbound channel to listen on.
   */
  channels(): Connector[];
  /**
   * Only the OUTBOUND (tool) connectors — the mirror of {@link channels}. A
   * `tool` or `both` connector declares a `toolDescriptor`; the connect seam's
   * `tool-descriptors` route walks THIS list to tell the runner which MCP servers
   * the agent may connect to. A channel-only connector never appears here.
   */
  tools(): Connector[];
  /** Drop a single connector. Returns true when one was removed. */
  unregister(id: string): boolean;
  /** Drop every connector. Test-isolation helper — not used in production paths. */
  clear(): void;
}

/**
 * Build an isolated registry. Tests use a fresh one per case so they never leak
 * connectors into each other; production uses the `connectorRegistry` singleton below.
 */
export function createConnectorRegistry(): ConnectorRegistry {
  // Insertion-ordered by Map contract, so `list()` is stable.
  const connectors = new Map<string, Connector>();

  return {
    register(connector) {
      const id = connector.id;
      if (!id) {
        throw new Error(
          "connectorRegistry.register: connector.id must be a non-empty string",
        );
      }
      if (connectors.has(id)) {
        throw new Error(
          `connectorRegistry.register: duplicate connector id "${id}" — ` +
            "a shadowed connector would route inbound events through the wrong " +
            "workspace's credentials. Unregister the existing one first.",
        );
      }
      connectors.set(id, connector);
    },

    get(id) {
      return connectors.get(id);
    },

    has(id) {
      return connectors.has(id);
    },

    list() {
      return [...connectors.values()];
    },

    channels() {
      return [...connectors.values()].filter(
        (connector) =>
          connector.direction === "channel" || connector.direction === "both",
      );
    },

    tools() {
      return [...connectors.values()].filter(
        (connector) =>
          connector.direction === "tool" || connector.direction === "both",
      );
    },

    unregister(id) {
      return connectors.delete(id);
    },

    clear() {
      connectors.clear();
    },
  };
}

/**
 * The process-wide registry. P3 channels land here — one entry each, no core edit.
 */
export const connectorRegistry: ConnectorRegistry = createConnectorRegistry();
