import type { NextConfig } from "next";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

// This app's lockfile is web/pnpm-lock.yaml. Pin the Turbopack workspace root to
// this directory so it doesn't infer the monorepo root from a sibling lockfile
// (e.g. the repo-root package-lock.json), which emits a build-time warning.
const projectRoot = dirname(fileURLToPath(import.meta.url));

const nextConfig: NextConfig = {
  turbopack: {
    root: projectRoot,
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
