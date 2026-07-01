---
'@barkpark/codegen': patch
---

`barkpark generate --watch` now tells you when it has nothing to watch instead of silently discarding the flag. `--watch` only re-runs on config-file changes, so a flag-/env-driven run (no `--config`) or a `--from`/`--schema` run has no file to observe. In both cases the one-shot output is still written, and a one-line stderr notice explains that `--watch` had no effect. The existing config-file watcher path is unchanged.
