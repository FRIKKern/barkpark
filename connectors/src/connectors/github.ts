import type { Adapter } from "chat";

import type {
  ConnectValidation,
  Connector,
  ConnectorInstall,
  ToolDescriptor,
} from "../connector/types.js";

/**
 * GitHub — the FIRST tool connector (charter D69/D71), the epic's OTHER
 * direction.
 *
 * Every connector before this one was a CHANNEL: a human messages the agent
 * through Slack/Telegram/… and the bridge routes that inbound event. GitHub is a
 * TOOL: the agent ACTS on GitHub, by connecting to GitHub's MCP server
 * (`https://api.githubcopilot.com/mcp/`, Streamable HTTP) as a second MCP server
 * — right next to the loopback `bp mcp serve` server the runner already spawns.
 * The crux (D69, proven against real claude 2.1.209): a tool connector is just a
 * SECOND key in the runner's `mcpServers` config; nothing in the core loop
 * special-cases GitHub.
 *
 * WHY GITHUB, NOT LINEAR, FIRST
 * -----------------------------
 * GitHub ships a hosted, first-party MCP server at a fixed URL that authenticates
 * with a plain `Authorization: Bearer <PAT>` header — no OAuth dance, no per-repo
 * app install, no server to stand up. A fine-grained, read-only, single-repo PAT
 * is a two-minute create in the GitHub UI, which is exactly the "connect in two
 * minutes" bar the channel connectors set. Linear's MCP is OAuth-only, so it would
 * drag the whole D63 pending-connect OAuth machinery into the FIRST tool connector
 * and prove less about the abstraction. GitHub proves the seam with the least
 * incidental complexity; Linear lands as a SECOND registry entry once the seam is
 * real.
 *
 * WHY `credential-bound` / no channel transport
 * ---------------------------------------------
 * A tool connector is never inbound: no webhook, no poll loop, no `listen`. It
 * never appears in `registry.channels()`, so `startBridge` never mounts a Chat for
 * it. `adapterFactory` therefore THROWS — a tool connector has no Chat adapter, and
 * a caller reaching it is a bug, not a fallback. `tenantResolution` is a required
 * field on the shared `Connector` shape; `"credential-bound"` is the honest value
 * (the PAT is the tenant binding) even though `resolveTenant` is never called for a
 * connector with no inbound events.
 *
 * D38 — THE PAT NEVER TRANSITS ELIXIR
 * -----------------------------------
 * `validate` proves the pasted PAT and derives a stable, non-secret install key
 * (the GitHub account login) so DISCONNECT can revoke exactly that install later.
 * The PAT is then SEALED under the SAME per-workspace credential cipher every
 * channel uses (third secret kind, `provider="github"`, `chat_token_ref` NULL) —
 * NOT a second credential path. At runtime the agent's subprocess fetches
 * `{"Authorization":"Bearer <pat>"}` from the bridge's loopback `tool-headers`
 * route via claude's `headersHelper`; Elixir writes only that helper command + a
 * non-secret session ticket and never sees the plaintext.
 *
 * D24 TOOL-SCOPING WIDENING — NAMED, NOT BUILT
 * --------------------------------------------
 * This wave delivers the SEAM (attach a tool connector, one registry entry, zero
 * core-loop change) and proves the wire. It does NOT narrow what the agent may do
 * once connected. On the self-hosted/operator profile, the runner's subprocess
 * inherits FULL host trust (Bash/Read/Write/Edit) AND this PAT's scope in a single
 * turn — the only bound on the GitHub blast radius is the PAT itself. D24's 5-knob
 * Cloud tool-scoping (structural unreachability, `--disallowedTools`, connector-
 * scoped `bp mcp serve --tools <subset>`, grant-scoped token mint, unattended
 * auto-approval policy) is UNBUILT and remains backlog. The honest mitigation
 * today is the credential: mint a fine-grained, READ-ONLY, SINGLE-REPO PAT.
 *
 * THE ONE-INCH HUMAN GATE
 * -----------------------
 * Everything up to a LIVE GitHub call is built and unit-proven with an injected
 * `fetch` and a real loopback curl. The live call itself —
 * `https://api.githubcopilot.com/mcp/` answering a real PAT — needs a real token a
 * human must create. NO live tool call is fabricated anywhere: ZERO live installs
 * exist and that is the honest state.
 */

export const GITHUB_PROVIDER = "github";

/** GitHub's hosted first-party MCP server (Streamable HTTP). Fixed, non-secret. */
export const GITHUB_MCP_URL = "https://api.githubcopilot.com/mcp/";

/** GitHub's REST API. `GET /user` is the cheapest authenticated identity call. */
const GITHUB_API_BASE = "https://api.github.com";

/** The slice of GitHub's `GET /user` response the connect flow reads. */
interface GithubSelfUser {
  login?: string;
  id?: number;
  message?: string;
}

/**
 * PASTE-MODE VALIDATION (D51/D69) — `GET /user` with `Authorization: Bearer <pat>`.
 *
 * The PAT is the whole credential, so "is this token good?" is one authenticated
 * round trip. GitHub answers 401 `{"message":"Bad credentials"}` for a revoked or
 * mistyped token — the failure we surface AT PASTE TIME (a bad PAT never becomes a
 * silently-broken tool connector at first use), never a throw: a bad paste is a
 * typed refusal the route turns into a 422.
 *
 * The install key is the account LOGIN — stable, non-secret, and unique per
 * account, so DISCONNECT can name exactly this install, and the sealed PAT's PK
 * never holds a raw secret. `login` (not the numeric `id`) is used because it is
 * what an operator recognises in the catalog; both are provider-authenticated
 * (they come from GitHub's answer to THIS token), so neither is caller-choosable.
 */
async function validateGithubPat(
  pat: string,
  doFetch: typeof fetch,
  apiBase: string,
): Promise<ConnectValidation> {
  const trimmed = pat.trim();
  // Cheap shape gate before spending a round trip: a GitHub PAT is a non-trivial
  // opaque string. An empty or whitespace paste is refused without asking GitHub.
  if (trimmed === "") {
    return {
      ok: false,
      reason:
        "paste a GitHub personal access token — a fine-grained, read-only, " +
        "single-repo token is enough (github.com/settings/personal-access-tokens).",
    };
  }

  let response: Response;
  try {
    response = await doFetch(`${apiBase}/user`, {
      method: "GET",
      headers: {
        authorization: `Bearer ${trimmed}`,
        accept: "application/vnd.github+json",
        "x-github-api-version": "2022-11-28",
        "user-agent": "barkpark-connectors",
      },
    });
  } catch (error) {
    // GitHub unreachable is NOT "your token is bad" — say which, or the operator
    // re-pastes a perfectly good token five times.
    return {
      ok: false,
      reason: `could not reach GitHub to check the token: ${
        error instanceof Error ? error.message : String(error)
      }`,
    };
  }

  let payload: GithubSelfUser;
  try {
    payload = (await response.json()) as GithubSelfUser;
  } catch {
    return {
      ok: false,
      reason: `GitHub answered HTTP ${response.status} with a body that is not JSON`,
    };
  }

  if (!response.ok) {
    return {
      ok: false,
      reason:
        payload.message ?? `GitHub rejected the token (HTTP ${response.status})`,
    };
  }

  const login = payload.login;
  if (typeof login !== "string" || login.trim() === "") {
    return {
      ok: false,
      reason:
        "GitHub accepted the token but returned no account login, so it cannot be " +
        "labelled. Refusing to install an unidentifiable credential.",
    };
  }

  return {
    ok: true,
    installKey: login,
    displayName: `@${login}`,
  };
}

export interface GithubConnectorOptions {
  /** Injected for `connect.validate` — tests NEVER hit the network. */
  fetch?: typeof fetch;
  /** Override the REST origin (tests point it at a local recorder). */
  apiBase?: string;
  /** Override the MCP server URL (tests point it at a local stub). */
  mcpUrl?: string;
}

export function createGithubConnector(
  options: GithubConnectorOptions = {},
): Connector {
  // Bound at construction, not read from the global at call time: a test that
  // injects a fetch must be certain no code path can reach the real network.
  const doFetch = options.fetch ?? fetch;
  const apiBase = (options.apiBase ?? GITHUB_API_BASE).replace(/\/+$/, "");
  const mcpUrl = options.mcpUrl ?? GITHUB_MCP_URL;

  const toolDescriptor: ToolDescriptor = { type: "http", url: mcpUrl };

  return {
    id: GITHUB_PROVIDER,
    // The OTHER direction: the agent ACTS on GitHub, so this is a TOOL, not a
    // channel. It is excluded from `registry.channels()` and never mounted as a
    // Chat; it appears in `registry.tools()` and drives the MCP config instead.
    direction: "tool",
    auth: "token",
    // The PAT is the tenant binding — but a tool connector has no inbound events,
    // so `resolveTenant` below is never consulted. The field is required by the
    // shared shape; this is its honest value.
    tenantResolution: "credential-bound",

    toolDescriptor,

    /**
     * Two-minute onboarding (D51/D69): the operator pastes a GitHub PAT and that
     * is the entire credential. No OAuth app, no per-repo install.
     */
    connect: {
      mode: "paste",
      credentialLabel: "GitHub personal access token (fine-grained, read-only)",
      helpUrl: "https://github.com/settings/personal-access-tokens",
      validate: (credential: string) =>
        validateGithubPat(credential, doFetch, apiBase),
    },

    /**
     * A tool connector has NO Chat adapter — it is never mounted as a channel.
     * Throwing here is the honest fail-closed answer: `startBridge` iterates
     * `registry.channels()`, which excludes this connector, so nothing legitimate
     * ever calls this. A caller that does has confused a tool for a channel.
     */
    adapterFactory(install: ConnectorInstall): Adapter {
      throw new Error(
        `github is a TOOL connector (D69) — it has no channel adapter and is never ` +
          `mounted as a Chat. install="${install.installKey}" workspace=` +
          `"${install.workspaceId}". The agent reaches GitHub through its MCP server ` +
          `(${mcpUrl}), not through an inbound adapter.`,
      );
    },

    /** No inbound events ever reach a tool connector. Fail closed. */
    async resolveTenant(): Promise<string | null> {
      return null;
    },
  };
}
