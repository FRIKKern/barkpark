# ssw9 · autodeploy-source-guard — re-derivation recipes

Verifier lane [autodeploy-source-guard], wave 9 (site-spawner). Every row below
re-derives one load-bearing fact from scratch. Run from the repo root unless a
row says otherwise.

| # | Claim | Command |
|---|---|---|
| 1 | Both unbidden enqueue paths exist and are green today | `cd cloud && CC=clang mix test test/barkpark_cloud/sites/auto_deploy_worker_test.exs test/barkpark_cloud/sites/template_freshness_worker_test.exs` |
| 2 | `Deploy.enqueue/5` is the SINGLE shared seam — exactly 3 prod callers | `git grep -n "Deploy.enqueue(" -- cloud/lib` |
| 3 | The box payload carries NO artifact/source field | `sed -n '437,466p' cloud/lib/barkpark_cloud/sites/deploy.ex` |
| 4 | Template always resolves — nil `Site.template` falls back to framework | `sed -n '492,501p' cloud/lib/barkpark_cloud/sites/deploy.ex` |
| 5 | The box builds `$SITE_SRC` (`$ROOT/src`) and stages `dist/` — no artifact arm | `grep -n "SITE_SRC" deploy/site-deploy.sh` |
| 6 | `SKIP_BUILD=1` only re-gates an already-staged release dir | `sed -n '1113,1126p' deploy/site-deploy.sh` |
| 7 | HEALTH asserts baked markers by value → a template rebuild passes honestly | `sed -n '226,240p;282,296p' deploy/site-deploy.sh` |
| 8 | `@triggers` is already THREE, not two | `git grep -n '@triggers' cloud/lib/barkpark_cloud/registry/deployment.ex` |
| 9 | `template-auto` reaches NO surface — 0 hits in Go CLI and dashboard | `git grep -n "template-auto" -- internal/ cloud/priv/static` |
| 10 | Go CLI narrates every unmapped trigger as " — manual" (active lie) | `sed -n '514,524p' internal/cli/cloud_site_cmd.go` |
| 11 | JS label degrades unmapped triggers to a lowercased passthrough | `sed -n '10017,10024p' cloud/priv/static/app.js` |
| 12 | No test pins the trigger enumeration — adding a 4th reds nothing | copy `cloud/priv/static` aside, add `case "prebuilt":` to `deployTriggerLabel`, `node __app.test.mjs` (only the 2 repo-relative ENOENT copies fail) |
| 13 | Stage vocabulary is a closed whitelist that SILENTLY drops unknowns | `sed -n '64p;948,952p;1042,1046p' cloud/lib/barkpark_cloud/sites/deploy.ex` |
| 14 | No `build_source`/prebuilt column on Site | `grep -n "field :" cloud/lib/barkpark_cloud/registry/site.ex` |
| 15 | Charter D7 is the decision the headline reverses | `grep -n "D7 — Same-box BUILD" .claude/workflows/bp-cloud-site-spawner-charter.md` |
