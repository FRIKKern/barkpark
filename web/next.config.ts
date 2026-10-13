import type { NextConfig } from "next";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

// Pin the Turbopack workspace root explicitly. When a sibling pnpm-workspace.yaml
// lives at the monorepo root (so `@barkpark/core` resolves through the workspace),
// Turbopack must be told the workspace root is the parent — otherwise it refuses
// to resolve `next` from web/node_modules because that symlink crosses out of the
// web/ project directory. When web/ is built standalone (legacy Vercel-style),
// fall back to pinning the project directory itself (the historical behaviour:
// avoids a wrong inference from a stray repo-root package-lock.json).
const projectRoot = dirname(fileURLToPath(import.meta.url));
const monorepoRoot = resolve(projectRoot, "..");
const turbopackRoot = existsSync(resolve(monorepoRoot, "pnpm-workspace.yaml"))
  ? monorepoRoot
  : projectRoot;

/**
 * The browser socket token guard (task-0cf611238d4ad597 JQ5, owner ruling #36).
 *
 * `NEXT_PUBLIC_BARKPARK_WS_TOKEN` is inlined into the client bundle, so it
 * reaches every visitor. Only a `public-read` token is safe there: it is pinned
 * to published, public types. An admin, write or plain read token (a plain
 * read token reads drafts) must never be baked. The demo sets this variable by
 * hand, so the build asks the API what the token is before baking it:
 * `GET /v1/capabilities?token=1` answers `auth_tier` and `token.public_read`.
 *
 * The token is baked only when the API answers `auth_tier: "read"` with
 * `token.public_read: true`. Every other answer, including an unreachable API
 * or a server too old to answer `token.public_read`, drops the token and
 * prints why. The demo then keeps live search on the same-origin HTTP path.
 * Unlike the search starters, this never fails the build: `web/` is a demo
 * deployed by hand, and losing the WebSocket upgrade is the safe outcome.
 *
 * Exported for `__tests__/ws-token-guard.test.ts`.
 */
export async function verifyPublicReadWsToken(
  raw: string | undefined,
  origin: string | undefined,
  fetchImpl: typeof fetch = globalThis.fetch,
): Promise<{ token: string; note: string }> {
  const token = (raw ?? "").trim();
  if (!token) return { token: "", note: "" };
  if (!origin) return { token: "", note: "no API URL to verify it against" };

  let body: { auth_tier?: unknown; token?: { public_read?: unknown } } | null;
  try {
    const res = await fetchImpl(
      origin.replace(/\/+$/, "") + "/v1/capabilities?token=1",
      {
        headers: { authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(15_000),
      },
    );
    if (!res.ok) return { token: "", note: `capabilities returned ${res.status}` };
    body = await res.json();
  } catch (e) {
    const name = e instanceof Error ? e.name : "error";
    return { token: "", note: `capabilities unreachable (${name})` };
  }

  const tier = body?.auth_tier;
  const publicRead = body?.token?.public_read;
  if (tier === "read" && publicRead === true) return { token, note: "" };
  if (tier === "read" && publicRead === false) {
    return {
      token: "",
      note: "it is a private read token, which reads drafts and private types",
    };
  }
  if (tier === "read") {
    return {
      token: "",
      note: "the API did not say whether it is public-read (update the Barkpark instance)",
    };
  }
  if (tier === "none" || tier == null) {
    return { token: "", note: `it does not authenticate (auth_tier "${String(tier ?? "absent")}")` };
  }
  return { token: "", note: `it is a "${String(tier)}" token` };
}

const nextConfig: NextConfig = {
  turbopack: {
    root: turbopackRoot,
  },
  // The unified detail route is `/d/[type]/[slug]`. Old per-type reader links
  // (`/posts/:slug`, `/papers/:slug`) 308-redirect into it. `:slug` requires a
  // segment, so the bare `/papers` LIST page is unaffected (it doesn't match).
  async redirects() {
    return [
      { source: "/posts/:slug", destination: "/d/post/:slug", permanent: true },
      {
        source: "/papers/:slug",
        destination: "/d/paper/:slug",
        permanent: true,
      },
    ];
  },
};

// Async config: verify the browser socket token before Next inlines it.
export default async function config(): Promise<NextConfig> {
  const origin =
    process.env.NEXT_PUBLIC_BARKPARK_API_URL ?? process.env.NEXT_PUBLIC_API_URL;
  const { token, note } = await verifyPublicReadWsToken(
    process.env.NEXT_PUBLIC_BARKPARK_WS_TOKEN,
    origin,
  );
  if (note) {
    console.warn(
      `[barkpark] NEXT_PUBLIC_BARKPARK_WS_TOKEN was not baked: ${note}. ` +
        `Live search stays on the same-origin HTTP path. Only a public-read token ` +
        `may reach the browser: POST <api>/v1/tokens ` +
        `{"label":"web live search","permissions":["public-read"]}`,
    );
  }
  // Both: `env` is what Next inlines, and process.env is what anything else
  // in this build reads.
  process.env.NEXT_PUBLIC_BARKPARK_WS_TOKEN = token;
  return {
    ...nextConfig,
    env: { ...nextConfig.env, NEXT_PUBLIC_BARKPARK_WS_TOKEN: token },
  };
}
