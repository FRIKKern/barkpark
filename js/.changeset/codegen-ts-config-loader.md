---
"@barkpark/codegen": minor
---

`barkpark.config.ts` — the format the `--config` help and `defineConfig`'s own example advertise — now actually loads: `.ts`/`.mts`/`.cts` configs go through jiti, so they work on the declared Node 20 engines floor (previously ERR_UNKNOWN_FILE_EXTENSION) and may carry non-erasable syntax such as enums (previously ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX even on Node 22's type-stripping). `--watch` freshness is preserved (jiti module/fs caches off). `.js`/`.mjs` configs load exactly as before.
