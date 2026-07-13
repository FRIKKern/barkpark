import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    // The state-layer proofs run against a REAL, ephemeral Postgres that the
    // suite creates and drops — never Barkpark's own database, and never an
    // in-memory fake (which cannot prove schema isolation; see
    // test/thread-session-map.test.ts). The transport runs against a byte-exact
    // SSE mock, never a live BEAM.
    globals: false,
  },
});
