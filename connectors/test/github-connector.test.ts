/**
 * GitHub — the FIRST tool connector (charter D69/D71), proven in isolation.
 *
 * No database, no network: `fetch` is injected, so paste-mode `validate()` runs
 * for real without a live PAT and without GitHub on the other end. These are the
 * connector's OWN invariants — the seam that wires it to the runner is proven in
 * `test/tool-descriptors.test.ts` against a real Postgres.
 */
import { describe, expect, it } from "vitest";

import { createConnectorRegistry } from "../src/connector/registry.js";
import {
  createGithubConnector,
  GITHUB_MCP_URL,
  GITHUB_PROVIDER,
} from "../src/connectors/github.js";

/** A `fetch` that records its calls and answers a canned response. */
function recordingFetch(answer: (url: string, init?: RequestInit) => Response): {
  fetch: typeof fetch;
  calls: Array<{ url: string; init?: RequestInit }>;
} {
  const calls: Array<{ url: string; init?: RequestInit }> = [];
  const impl = (async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const url = typeof input === "string" ? input : String(input);
    calls.push(init ? { url, init } : { url });
    return answer(url, init);
  }) as unknown as typeof fetch;
  return { fetch: impl, calls };
}

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

describe("GitHub tool connector — declaration (D69/D71)", () => {
  it("is a TOOL, carries an http MCP descriptor, and declares paste-mode connect", () => {
    const github = createGithubConnector();
    expect(github.id).toBe(GITHUB_PROVIDER);
    expect(github.direction).toBe("tool");
    expect(github.toolDescriptor).toEqual({ type: "http", url: GITHUB_MCP_URL });
    expect(github.connect?.mode).toBe("paste");
    // A tool connector has NO inbound transport.
    expect(github.webhook).toBeUndefined();
    expect(github.listen).toBeUndefined();
  });

  it("appears in registry.tools() and is EXCLUDED from registry.channels() — never mounted as a Chat", () => {
    const registry = createConnectorRegistry();
    registry.register(createGithubConnector());

    expect(registry.tools().map((c) => c.id)).toContain(GITHUB_PROVIDER);
    expect(registry.channels().map((c) => c.id)).not.toContain(GITHUB_PROVIDER);
  });

  it("adapterFactory THROWS — a tool connector has no channel adapter (fail closed, not a fallback)", () => {
    const github = createGithubConnector();
    expect(() =>
      github.adapterFactory({
        provider: GITHUB_PROVIDER,
        installKey: "octocat",
        workspaceId: "11111111-1111-4111-8111-111111111111",
        credentialRef: "ghp_x",
        chatToken: null,
      }),
    ).toThrow(/TOOL connector/);
  });

  it("resolveTenant is fail-closed null — no inbound event ever reaches a tool", async () => {
    const github = createGithubConnector();
    await expect(
      github.resolveTenant(
        { provider: GITHUB_PROVIDER, threadId: "t", text: "x" },
        { installs: {} as never },
      ),
    ).resolves.toBeNull();
  });
});

describe("GitHub paste-mode validate — GET /user, no network (D51/D69)", () => {
  it("accepts a live PAT: install key is the account LOGIN, display name is @login", async () => {
    const { fetch: doFetch, calls } = recordingFetch(() =>
      json({ login: "octocat", id: 583231 }),
    );
    const github = createGithubConnector({ fetch: doFetch });

    const verdict = await github.connect?.validate("ghp_a-good-token");

    expect(verdict).toEqual({
      ok: true,
      installKey: "octocat",
      displayName: "@octocat",
    });
    // It asked GitHub's /user, once, with a Bearer header — and NOT the numeric id.
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe("https://api.github.com/user");
    expect(
      (calls[0]?.init?.headers as Record<string, string>)["authorization"],
    ).toBe("Bearer ghp_a-good-token");
  });

  it("REFUSES a revoked PAT at PASTE TIME with GitHub's own message — not at first tool use", async () => {
    const { fetch: doFetch } = recordingFetch(() =>
      json({ message: "Bad credentials" }, 401),
    );
    const github = createGithubConnector({ fetch: doFetch });

    expect(await github.connect?.validate("ghp_revoked")).toEqual({
      ok: false,
      reason: "Bad credentials",
    });
  });

  it("refuses an empty paste WITHOUT spending a round trip", async () => {
    const { fetch: doFetch, calls } = recordingFetch(() => json({}));
    const github = createGithubConnector({ fetch: doFetch });

    const verdict = await github.connect?.validate("   ");
    expect(verdict?.ok).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("distinguishes 'GitHub is unreachable' from 'your token is bad'", async () => {
    const { fetch: doFetch } = recordingFetch(() => {
      throw new Error("ENOTFOUND");
    });
    const github = createGithubConnector({ fetch: doFetch });

    const verdict = await github.connect?.validate("ghp_good");
    expect(verdict).toMatchObject({ ok: false });
    expect((verdict as { reason: string }).reason).toContain("could not reach");
  });

  it("REFUSES a token GitHub blesses but that returns no login — an unidentifiable install is not installable", async () => {
    const { fetch: doFetch } = recordingFetch(() => json({ id: 42 }));
    const github = createGithubConnector({ fetch: doFetch });

    const verdict = await github.connect?.validate("ghp_no_login");
    expect(verdict?.ok).toBe(false);
    expect((verdict as { reason: string }).reason).toContain("no account login");
  });
});
