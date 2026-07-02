---
'create-barkpark-app': patch
---

Fix the broken next-step commands printed on first run. The codegen hint printed `<pm> run barkpark codegen`, which fails with `Missing script: barkpark` — the templates define the script as `codegen` (`barkpark generate`), so it now prints `<pm> codegen`. The `--hosted-demo` branch printed `npx barkpark demo eject`, a command the `barkpark` bin does not have; it now tells you to re-run `create-barkpark-app` without `--hosted-demo` for local data.
