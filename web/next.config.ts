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

export default nextConfig;
