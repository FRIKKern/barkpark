# Re-derivation recipes — cch-wave-33 duplicate-thesis check (deploy-truth wave 2, verify)

Verifier assignment `cch-wave-33-duplicate-thesis`. Every claim below is re-derivable by the one
command beside it. Run from the repo root; `origin/main` reads, never the primary checkout.

## The Paper exists, is OPEN at VERIFYING, and is NOT in any charter on origin/main

```
bp paper view cch-wave-33-2026-08-06 | head -20
# → "CLOUD CONSOLE HARDENING — WAVE 33: THE EVIDENCE SURVIVES THE FAILURE"
#   "Status: SURVEYING" in the header block; the closing status latch at the
#   end of the verify plan reads "Status: VERIFYING."

git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -n 'Wave 33'
# → no output (ABSENT). The charter on origin/main stops at wave 32 / D372.
```

NOTE: `bp paper view` intermittently 500s (DBConnection pool starvation on guerrilla). Retry;
it succeeds on ~4 of 5 attempts.

## Wave 33 has shipped NOTHING

```
gh pr list --state all --limit 40 --search 'cch-w33' --json number,title,mergedAt   # → []
gh pr list --state all --limit 40 --search 'cch-w33 in:title' --json number,title   # → []
git ls-remote --heads origin | grep -i 'w33\|wave-33'
# → only refs/heads/docs/connectors-w33-wave-log (a DIFFERENT epic's wave 33)
gh pr list --state all --limit 30 --search 'sort:created-desc' --json number,title,mergedAt
# → newest cch merges are wave 32: #9655 #9656 #9657 #9658 #9659, charter #9620
```

## Wave 33 disclaims the deploy path by name (quote by line in the Paper)

```
bp paper view cch-wave-33-2026-08-06 > /tmp/w33.txt
sed -n '155,163p;255,268p;646,654p' /tmp/w33.txt
```

- ~:159 — "The upstream build-log defect belongs to the deploy-reliability epic — this wave does not touch deploy/."
- ~:267 — "Hard boundary: no slice in this wave edits deploy/ or the site-deploy path."
- ~:648 — "The deleted raw log in deploy/site-deploy-node.sh is filed as task-58001fc2464808e5 (open, UNCLAIMED) under the deploy-reliability epic — inside wave 33's hard boundary."
- ~:651 — "That epic's wave 2 has cut ZERO slices … so there is no active collision. The loaded gun is task-54326937e919e2cf, which explicitly names cloud/priv/static/app.js and a failure_class pill on the site-detail deploy row."

## The collision file set

```
git show origin/main:cloud/priv/static/app.js | grep -n 'deployDetailHtml\|deployConsoleHtml'
# 10738 / 10741 / 10763 (def) / 11624 / 11628 / 11637 (def) / 19619 (export)
```

Wave 33 s3 (re-aimed per its own Decide latch onto "the 2,889 mid-stage stops and the 9,542 empty
consoles") owns `deployConsoleHtml` + `deployDetailHtml` + `cloud/.../registry.ex`
(`cap_console/1` :1782-1789, `validate_console_line/1` :1770-1780, `cap_steps` :1796).
dr-w1-s6 (`task-54326937e919e2cf`) item (2) is a `failure_class` pill on the site-detail deploy
row — the same two render functions.

## build_log_url: on the deployment payload, but only ever written as an unopenable file:// URL

```
git grep -n 'build_log_url' origin/main -- internal/ cloud/
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '10374p'
#   build_log_url: d.build_log_url,          ← IS on deployment_json/1
git show origin/main:cloud/test/barkpark_cloud/web/router_builder_test.exs | sed -n '773p;782p'
#   build_log_url: "file:///var/lib/barkpark-builder/logs/#{did}.log"
#   assert String.starts_with?(d["build_log_url"], "file://")
git show origin/main:cloud/lib/barkpark_cloud/registry/deployment.ex | sed -n '15,17p'
#   "`build_log_url` is opaque to the control plane — the builder writes the log
#    somewhere accessible (e.g. blob storage) and stores the URL."
git show origin/main:cloud/test/barkpark_cloud/registry_deployment_freshness_test.exs | sed -n '88p'
#   refute Map.has_key?(entry, :build_log_url)   ← HONESTY LAW bars it from the SLIM FLEET MAP only
```

## The deploy-reliability charter's cross-epic fence is stale

```
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | sed -n '139,143p'
# D18 — "Respect cloud-console-hardening's live fences." Names cch WAVE 31 (s1/s8 router.ex,
# s7 registry.ex). Wave 32 has since merged and wave 33 is mid-flight; D18 needs re-pointing.
```

## The two overlapping "readers" rows

```
bp task get task-fb4fb869490b4213 -o json   # 23 children
bp task get task-54326937e919e2cf -o json           # Console + CLI readers
bp task get dr-w1-s6-cli-fleet-ledger-honest-status -o json   # CLI readers, 8 acceptance criteria
```

Both are open under the same parent and both own "print failure_class / the census in the CLI".
