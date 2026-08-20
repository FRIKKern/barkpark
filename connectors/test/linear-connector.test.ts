/**
 * Linear — the SECOND tool connector (charter D77), proven in isolation.
 *
 * No database, no network: these are the connector's OWN declaration invariants.
 * The seam that wires it to the runner is proven in `test/linear-oauth.test.ts`
 * against a real Postgres (the tool-descriptors/tool-headers end-to-end), and the
 * OAuth install flow is proven there too.
 *
 * The whole point of this file is the DIFF against GitHub: GitHub reused paste
 * (`connect.mode === "paste"`); Linear has NO connect member at all (OAuth-only,
 * D77). Everything else — tool direction, http descriptor, throwing adapter,
 * fail-closed resolveTenant, tools()/channels() partition — is identical, which is
 * exactly what "a second tool connector is a second registry entry with ZERO
 * core-loop change" means.
 */
import { describe, expect, it } from "vitest";

import { createConnectorRegistry } from "../src/connector/registry.js";
import { createGithubConnector } from "../src/connectors/github.js";
import {
  createLinearConnector,
  LINEAR_MCP_URL,
  LINEAR_PROVIDER,
} from "../src/connectors/linear.js";

describe("Linear tool connector — declaration (D77)", () => {
  it("is a TOOL, carries an http MCP descriptor, and has NO connect member (OAuth-only)", () => {
    const linear = createLinearConnector();
    expect(linear.id).toBe(LINEAR_PROVIDER);
    expect(linear.direction).toBe("tool");
    expect(linear.auth).toBe("oauth");
    expect(linear.toolDescriptor).toEqual({ type: "http", url: LINEAR_MCP_URL });
    // The load-bearing DIFF from GitHub: Linear is OAuth-only, so it declares NO
    // paste-mode `connect` member. It is connectable exclusively via the OAuth
    // callback; the paste `/connect` routes answer the opaque 404 for it.
    expect(linear.connect).toBeUndefined();
    // A tool connector has NO inbound transport.
    expect(linear.webhook).toBeUndefined();
    expect(linear.listen).toBeUndefined();
  });

  it("the MCP url is Linear's hosted Streamable-HTTP server", () => {
    expect(LINEAR_MCP_URL).toBe("https://mcp.linear.app/mcp");
    expect(createLinearConnector().toolDescriptor?.url).toBe(LINEAR_MCP_URL);
  });

  it("a test may override the MCP url (for a local stub) without changing the shape", () => {
    const linear = createLinearConnector({ mcpUrl: "http://127.0.0.1:9/mcp" });
    expect(linear.toolDescriptor).toEqual({
      type: "http",
      url: "http://127.0.0.1:9/mcp",
    });
  });

  it("appears in registry.tools() and is EXCLUDED from registry.channels() — never mounted as a Chat", () => {
    const registry = createConnectorRegistry();
    registry.register(createLinearConnector());

    expect(registry.tools().map((c) => c.id)).toContain(LINEAR_PROVIDER);
    expect(registry.channels().map((c) => c.id)).not.toContain(LINEAR_PROVIDER);
  });

  it("registers ALONGSIDE GitHub — two tool connectors, one registry, no collision (the epic bar)", () => {
    const registry = createConnectorRegistry();
    registry.register(createGithubConnector());
    registry.register(createLinearConnector());

    // Both are tools; neither is a channel. This is the whole claim: a second tool
    // connector is a second registry entry with ZERO core-loop change.
    const toolIds = registry
      .tools()
      .map((c) => c.id)
      .sort();
    expect(toolIds).toEqual(["github", "linear"]);
    expect(registry.channels().map((c) => c.id)).not.toContain("github");
    expect(registry.channels().map((c) => c.id)).not.toContain("linear");
  });

  it("adapterFactory THROWS — a tool connector has no channel adapter (fail closed, not a fallback)", () => {
    const linear = createLinearConnector();
    expect(() =>
      linear.adapterFactory({
        provider: LINEAR_PROVIDER,
        installKey: "org_abc123",
        workspaceId: "11111111-1111-4111-8111-111111111111",
        credentialRef: "lin_oauth_token",
        chatToken: null,
      }),
    ).toThrow(/TOOL connector/);
  });

  it("resolveTenant is fail-closed null — no inbound event ever reaches a tool", async () => {
    const linear = createLinearConnector();
    await expect(
      linear.resolveTenant(
        { provider: LINEAR_PROVIDER, threadId: "t", text: "x" },
        { installs: {} as never },
      ),
    ).resolves.toBeNull();
  });
});
