import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // No experimental flags — a plain `next build`, deployable as-is on Vercel
  // with this folder as the project root.
};

export default nextConfig;
