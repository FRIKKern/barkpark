# PDS wave 25 — free-close sweep over the 34 bare-live rows

Re-derivation recipes. Every row below is a command that reproduces the fact
from scratch. No claim here rests on a commit message alone; every CLOSED
verdict is verified BY CONTENT against `origin/main`.

## 0. Re-derive the 34 bare-live rows (independent of the census script)

```bash
S=https://guerrilla.barkpark.cloud; T=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
for o in 0 1000 2000 3000; do curl -s -H "Authorization: Bearer $T" "$S/v1/data/query/production/task?limit=1000&offset=$o" -o page_$o.json; done
```

Then walk `parent_id` transitively from `task-2ac1f95237c4a8e5`. NOTE THE FIELD
NAMES — the status field is `lifecycle_status`, NOT `status`, and every ledger
field (`disposition`, `disposition_reason`, `disposition_owner`,
`reopen_trigger`, `parent_id`) is FLAT at the document top level, not nested
under `content`. A reader that looks for `status` gets `None` on every row and
computes live == closure == 291.

Measured 2026-07-30T19:3xZ: closure 291 · statuses
`{open:132, done:101, considering:31, cancelled:26, blocked:1}` · live 164 ·
bare-live (no `disposition`) **34**.

## 1. The Retires: trailer convention is ONE COMMIT, repo-wide

```bash
git log origin/main --pretty=format:'%b' | grep -icE '^retires:'   # -> 1
```

The single trailer is `6f4ca7904`, and it names FOUR rows:

```bash
git show --no-patch --format='%b' 6f4ca7904 | tail -6
```

There is no wider trailer corpus to mine. D343's "lower bound" is bounded here.

## 2. Content verification per CLOSED verdict

```bash
# pds-bl-crown-launch-armed-without-liveness
git grep -c assert_child_up origin/main -- scripts/pds-crown-launch.sh      # 11

# pds-bl-scratch-teardown-strands-the-survivor + pds-bl-scratch-pointer-concurrency
git grep -c 'registry_' origin/main -- scripts/pds-scratch-target.sh        # 13
git grep -n 'registry_add\|registry_remove\|resolve_home' origin/main -- scripts/pds-scratch-target.sh
git ls-tree origin/main --name-only scripts/ | grep scratch_test            # test file exists

# pds-bl-floor-env-silent-revert  (named BY SLUG in the fix's own comment)
git show origin/main:scripts/pds-crown-launch.sh | sed -n '430,470p'

# pds-bl-tagregistry-guard-no-rung  (the ask was a RULING, and it landed)
git grep -n 'PDS-D187' origin/main -- .claude/workflows/bp-pds-charter.md   # :1499

# pds-w23-cold-owner-verb-honesty
git grep -n 'Accept' origin/main -- internal/apiclient/export.go            # :58 x-ndjson, application/json

# pds-w23-success-claim-registry
git ls-tree origin/main --name-only internal/cli/ | grep success_claim

# pds-w10-instrumented-climb
git ls-tree origin/main --name-only scripts/ | grep window-sentinel
```

## 3. Content verification per STILL-OPEN verdict (the fix is NOT in the tree)

```bash
# place-directory install.sh EXISTS (never deleted) and lines 29/33 are still transport echoes
git ls-tree -r origin/main --name-only | grep place-directory/install.sh
git show origin/main:templates/place-directory/install.sh | sed -n '27,34p'
git log --all --diff-filter=D --name-only --format='' -- '*install.sh'      # EMPTY

# import DDL deadlock is a DIFFERENT path from the webhook-audit 40P01 mitigation
git grep -n 'audit_dispatch_async' origin/main -- api/config/test.exs       # the audit mitigation
git grep -rn 'lock_timeout' origin/main -- api/lib/barkpark/tenancy/        # EMPTY
git show origin/main:api/lib/barkpark/tenancy/workspace_bundle.ex | sed -n '451,475p'

# dedup_unavailable is still `halted`/409 ON THE WIRE
git show origin/main:api/lib/barkpark/content/errors.ex | sed -n '443,445p'

# cmd_arm still has no scratch.env assertion
git grep -c 'scratch.env' origin/main -- scripts/pds-crown-launch.sh        # 0

# go-literal-check EPIPE still there
git show origin/main:scripts/go-literal-check.sh | sed -n '75p'

# E3 bare-slug still an unconditional literal
git grep -n 'E3_BARE_SLUG_FALLBACK' origin/main -- scripts/pds-pull-proof.sh # :957 def, :1131 unconditional

# plugin commands still carry no writes bit
git show origin/main:api/lib/barkpark/plugins/capabilities.ex | sed -n '438,444p'

# deploy -o json still emits an envelope ONLY on --dry-run (and the help text says otherwise)
git show origin/main:internal/cli/cloud_deploy_cmd.go | grep -n 'renderJSON'  # one hit, inside deployDryRun
git show origin/main:internal/cli/cloud_deploy_cmd.go | sed -n '707p'

# instance-deploy still nukes the rollback root before building
git grep -n 'rm -rf "_build_\$TARGET"' origin/main -- deploy/instance-deploy.sh  # :706

# `barkpark reload` still has no forced exit
git grep -c 'force' origin/main -- bin/barkpark

# up-seed re-mints after a revoke, and the mint hard-matches {:ok, _}
git show origin/main:api/lib/barkpark/seeds/clean.ex | sed -n '124,133p'

# no repair migration for the amended-in-place trigger
git grep -rln 'barkpark_bind_document_revision' origin/main -- api/priv/repo/migrations

# scripts/pds-* still has ZERO CI coverage
git grep -rln 'pds-' origin/main -- .github/workflows/                      # EMPTY (rc=1)

# D101/D116 anchors are still the stale ones
git show origin/main:.claude/workflows/bp-pds-charter.md | sed -n '774p;924,926p'
```

## 4. The two rows that are NOT bare but ARE now wrong

`pds-bl-scratch-pointer-concurrency` and `pds-bl-scratch-pointer-explicit-default`
both carry `disposition: "open"` with a reason citing
`scripts/pds-scratch-target.sh:124` / the single global pointer as the LIVE
defect. `6f4ca7904` retired both. Their reasons are now false.

```bash
curl -s -H "Authorization: Bearer $T" \
  "$S/v1/data/query/production/task?limit=1&filter%5B_id%5D=pds-bl-scratch-pointer-concurrency" | python3 -m json.tool
```
