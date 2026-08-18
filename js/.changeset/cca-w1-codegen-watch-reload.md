---
'@barkpark/codegen': patch
---

`barkpark generate --watch` now regenerates from the EDITED config instead of the one loaded on the first run. `loadConfig` imported the config file by its bare `file://` URL, and the ESM module registry is keyed by URL — so every change the chokidar watcher saw re-imported the same URL and got the cached module back. Proven end to end against the built CLI: a config edited in place from `{ dataset: 'alpha', output: 'A.types.ts' }` to `{ dataset: 'beta', output: 'B.types.ts' }` made the watcher refetch `/v1/schemas/alpha` and print `Re-wrote …/A.types.ts`; `B.types.ts` was never created. That is a false success, not a no-op — the CLI reports a regeneration that used the stale dataset.

The import URL now carries a monotonic cache-bust query (`?t=<n>`), deliberately not a file mtime: a filesystem with 1-second timestamp granularity would key two same-second saves identically and reintroduce the bug on a subset of machines. Each reload costs one small, permanently-registered ESM module — noted at the code. The one-shot paths (`generate` without `--watch`, and `--from`, which the CI drift gate rides) import exactly once and are unaffected.
