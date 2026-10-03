---
'create-barkpark-app': patch
---

Scaffolded starters' `codegen` script now runs `barkpark generate --config barkpark.config.ts`, and the shared `barkpark.config.ts` default-exports the codegen config (`apiUrl`, `dataset`, `output: 'lib/barkpark.types.ts'`, and `token` from `BARKPARK_TOKEN`). Before this, the script was a bare `barkpark generate`, which reads no config file, so the step the scaffolder prints under "Next steps" failed on every new app with `Missing dataset: pass --dataset or set it in barkpark.config.`
