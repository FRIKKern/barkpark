# task-758ef042eb60c65e — the twin door and the empty CI net (2026-08-17)

Verifier lane `astro-twin-and-ci-coverage`, API read-path security sweep wave.
Re-derivation recipes only. No repo change, no bp mutation.

| # | Claim | Re-derive |
|---|---|---|
| 1 | `templates/search-starter/next.config.mjs:105` bakes `BARKPARK_TOKEN` into `NEXT_PUBLIC_BARKPARK_WS_TOKEN` with NO verification — no `verifyPublicReadToken`, no `/v1/capabilities` call, no `auth_tier` read | `git show origin/main:templates/search-starter/next.config.mjs \| grep -n 'NEXT_PUBLIC_BARKPARK_WS_TOKEN\|verifyPublic\|capabilities\|auth_tier'` → only line 52 (comment) and line 105 (the bake) |
| 2 | The guard exists ONLY in the Astro edition | `grep -rn 'verifyPublicReadToken' --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.omx .` → 2 hits, both `templates/astro-search-starter/astro.config.mjs` (:62 def, :110 call). Zero test files. |
| 3 | No workflow path filter names `astro.config.mjs` or `next.config.mjs` | `grep -rn 'astro.config.mjs\|verifyPublicReadToken' .github/workflows/` → no hits |
| 4 | A PR touching only `templates/astro-search-starter/astro.config.mjs` fires only `doc-gates` + `go-tests` (both `templates/**`); `astro-search-finder-test` is scoped to `templates/astro-search-starter/src/**` | `grep -n 'paths' -A6 .github/workflows/astro-search-finder-test.yml` ; `for f in .github/workflows/*.yml; do grep -l '"templates/\*\*"' $f; done` |
| 5 | `astro-finder-drift` DOES fire on `templates/search-starter/**` but its MAPPINGS cover only finder.tsx + 13 lib modules + globals.css — never a config file | `bash scripts/check-astro-finder-drift.sh` (green) ; `grep -n 'MAPPINGS' -A20 scripts/check-astro-finder-drift.sh` |
| 6 | `search-starter-smoke` fires on `templates/search-starter/**` but asserts nothing about the token: it runs a fixture self-test and `node --test 'lib/**/*.test.ts'` | `grep -n 'name:\|run:' .github/workflows/search-starter-smoke.yml` |
| 7 | The Go template gate reads JSON manifests only, and does not even include the two search-starter manifests | `grep -n 'func TestRealManifests' -A10 internal/template/template_test.go` |
| 8 | Both editions are LIVE in the public catalog; neither is deprecated | `grep -n 'slug:' cloud/lib/barkpark_cloud/templates.ex` ; `cat internal/provisioner/catalog/templates/search-starter/barkpark.template.json` |
| 9 | Blast radius is live: 3 Next-edition sites deployed on guerrilla (`search`, `search-capstone`, `search-ember`) plus `astro-search` | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'ls /opt/barkpark/sites/'` |
| 10 | The `search` site's build token IS inlined into a BROWSER-served static chunk | `ssh … 'grep -rlF "<tok>" /opt/barkpark/sites/search/releases/353e841270a5efce/.next/static'` → `chunks/0ig9x7fy2u.mg.js` |
| 11 | That live baked token is genuinely public-read (so the unguarded bake is not currently exploited on this site) | `curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer <tok>' http://localhost:4000/v1/data/search/production?q=a` → 403 ; same on `/v1/data/export/production` → 403 |
| 12 | RULING — `auth_tier "read"` is satisfied by a plain `read` permission, not just `public-read`, so the Astro guard admits a full-read token | `grep -n '@read_perms' api/lib/barkpark/tenancy/auth.ex` → `~w(read admin public-read)` ; `grep -n 'def tier_for_token' -A12 api/lib/barkpark/plugins/capabilities.ex` |

Token value deliberately elided as `<tok>`; re-read it from the release bundle when re-deriving.
