---
'@barkpark/nextjs': patch
---

**Test gate:** the `client` vitest project could pass with zero tests. Measured: renaming both `tests/*.client.test.tsx` files out of the include glob left `vitest run` GREEN at 16 files / 160 tests — the 22 client assertions vanished with no warning, and `pnpm test` (the CI gate in `js-tests.yml`) went green anyway.

Two causes, both fixed. `vitest.client.config.ts` set `passWithNoTests: true`, and `test:client` passed `--passWithNoTests` on the CLI. Separately, vitest's projects mode only errors when NO project has test files, so an empty project is invisible behind a populated sibling — `test` therefore now runs `vitest run --project=server && vitest run --project=client` as two commands, each of which reds on its own emptiness.

Re-measured after the fix: emptying either project exits 1 with `No test files found`; the unmutated suite is 18 files / 182 tests. No test was changed.
