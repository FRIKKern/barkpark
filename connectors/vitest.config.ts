import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    // The map + streaming glue are pure logic tested against pg-mem (an
    // in-process Postgres) and a faithful SSE mock — never Barkpark's real DB
    // and never a live BEAM. See test/thread-session-map.test.ts.
    globals: false,
  },
});
