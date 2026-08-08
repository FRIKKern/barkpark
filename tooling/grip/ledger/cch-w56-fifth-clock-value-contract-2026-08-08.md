# cch-w56 v5 — the fifth clock value, and its proof obligations

Verify-phase re-derivation recipes. Every row below was RUN at `origin/main`
`b97663730a7a98c39f05a607110bdad5981c81e4` on 2026-08-08. Re-run any line to
re-derive the claim; nothing here is transcribed prose.

| claim | rerun |
|---|---|
| the shipped taxonomy is pinned by EQUALITY at :655 and holds 4 kinds | `git show origin/main:cloud/test/barkpark_cloud/promise_actor_manifest_test.exs \| sed -n '640,660p'` |
| `resolve_clock(:synchronous)` is a constant and CANNOT LOSE | `git show origin/main:cloud/test/barkpark_cloud/promise_actor_manifest_test.exs \| sed -n '313,315p'` |
| `resolve_clock(:crontab_absent)` discharges on the crontab read ALONE — no search obligation | `git show origin/main:cloud/test/barkpark_cloud/promise_actor_manifest_test.exs \| sed -n '260,266p'` |
| `resolve_clock({:external_only, :stripe})` already RUNS (local negative), names no in-tree literal | `git show origin/main:cloud/test/barkpark_cloud/promise_actor_manifest_test.exs \| sed -n '285,312p'` |
| Caddy arms ACME in-tree and states NO interval anywhere | `git show origin/main:internal/caddyfile/caddyfile.go \| sed -n '405,425p'` ; `git grep -rn "renew" origin/main -- '*.go'` |
| shape-(b) actors state literal AND cadence in-tree | `git show origin/main:deploy/systemd/barkpark-image-bake.timer` ; `git grep -n "cron:" origin/main -- '.github/workflows/*.yml'` ; `git grep -n "DefaultInterval" origin/main -- internal/agent/agent.go` |
| the cadence-token discriminator separates (a) from (b) with zero judgment | `PAT='OnCalendar\|OnUnitActiveSec\|cron:\|time\.(Second\|Minute\|Hour\|Duration)'; for f in internal/caddyfile/caddyfile.go deploy/systemd/barkpark-image-bake.timer .github/workflows/renew-mail-cert.yml internal/agent/agent.go; do echo "$f $(git show origin/main:$f \| grep -Ec "$PAT")"; done` → 0 / 1 / 1 / 6 |
| a cross-tree read is CENSUSED and must be declared, or the ratchet exits 1 | `git show origin/main:scripts/cloud-path-escape-check.sh \| sed -n '300,340p'` |
| repo-root reads from a cloud test are precedented and green | `git show origin/main:cloud/test/barkpark_cloud/async_global_seam_guard_test.exs \| sed -n '31p'` |
| DIRECTORY declarations are unaffordable; EXACT FILES are ~free | `git rev-list --since=60.days origin/main -- cloud .github/workflows/cloud.yml scripts/cloud-path-escape-check.sh \| sort > /tmp/b2; for f in .github/workflows deploy internal/caddyfile/caddyfile.go deploy/systemd/barkpark-image-bake.timer; do git rev-list --since=60.days origin/main -- $f \| sort > /tmp/a2; echo "$f newly=$(comm -23 /tmp/a2 /tmp/b2 \| wc -l)"; done` → 145 / 76 / 8 / 1 |
| the census regex sees `Path.expand("../…")` and is BLIND to `Path.join([__DIR__, "..", …])` | `printf '%s\n' 'Path.join([__DIR__, "..", "..", "deploy", "x"])' 'Path.expand("../../deploy/x", __DIR__)' > /tmp/e.exs; grep -Eoh '"\.\./[^"]*"' /tmp/e.exs` → only the expand form |
| the lazy-guard family is real: a 7-day boundary stamped at write, enforced at read | `git grep -n "@invite_validity_days" origin/main -- cloud/lib/barkpark_cloud/accounts.ex` ; `git show origin/main:cloud/lib/barkpark_cloud/accounts.ex \| sed -n '1204,1216p'` |
| the shipped console has SEVEN live `setInterval` arms, not 17 | `git grep -n "setInterval" origin/main -- cloud/priv/static/app.js` (8 lines; :17306 is a comment) |
| no console copy promises a Stripe retry | `git grep -rniE "retry\|try again" origin/main -- cloud/priv/static/app.js` — every hit is a user-action prompt or a rate-limit countdown |
