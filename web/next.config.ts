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
};

export default nextConfig;
