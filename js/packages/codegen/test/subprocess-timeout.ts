// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/**
 * The timeout for a test that spawns the built CLI (`node dist/cli.mjs …`) as a
 * subprocess (task-666d3f475d516f3a). Vitest's 5000 ms default is too tight for
 * them: `cli-from.test.ts`'s first test took 5043 ms on main (js-tests run
 * 38098910455) and passed on a rerun. The subprocess is the point of these
 * tests (they run the binary the CI drift gate runs), so they keep it and get an
 * explicit budget instead of a raised suite default.
 *
 * Measured, 10-core host, `vitest run` of the whole package, 30 `yes` CPU
 * burners (3x cores), 20 runs: the slowest test (the first, which pays the cold
 * start) p50 1192 ms, p99 1475 ms; the others p99 ≤ 1132 ms. The CLI subprocess
 * alone, 50 runs: idle p99 331 ms, loaded p99 1101 ms. CI's smaller runners
 * reached 5043 ms. 30 s is about 6x that observed CI worst and 20x the loaded
 * local p99, and a hung CLI still fails inside 30 s.
 */
export const SUBPROCESS_TIMEOUT_MS = 30_000
