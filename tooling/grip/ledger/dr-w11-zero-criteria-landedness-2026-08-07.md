# dr-w11 — zero-criteria children: landedness re-derivation recipe (2026-08-07)

Baseline: `origin/main` = `b4ef025cf6e2ccd13018c23afd1ae6b83a5843f3`.

## 1. Re-derive the zero-criteria set (17, not 15)

```
bp task get task-fb4fb869490b4213 -o json | python3 -c "import json,sys;ch=json.load(sys.stdin)['children'];print(len(ch));print([c['doc_id'] for c in ch if c.get('criteria_progress',{}).get('total',0)==0])"
```

## 2. Per-row landedness probes (each a single command against origin/main)

```
# tokens: mint-only lifecycle (task-1a9b89e4be002159)
git grep -n 'v1/tokens' origin/main -- api/lib/barkpark_web/router.ex

# console/CLI failure_class surfacing (task-54326937e919e2cf)
git show origin/main:cloud/priv/static/app.js | grep -c 'failure_class'      # 0 = console leg unpaid
git grep -n 'failure_class' origin/main -- internal/cli/cloud_site_cmd.go    # CLI leg paid
git grep -rn 'stripANSI' origin/main -- internal/                            # tests only = ANSI leg unpaid

# build-error extractor (task-58001fc2464808e5)
git show origin/main:deploy/lib/site-deploy-common.sh | sed -n '124,132p'
git grep -n 'BUILD_LOG_KEEP' origin/main -- deploy/site-deploy-node.sh

# runaway journalctl lifetime bound (task-e05c4e4cea2282e5)
git show origin/main:internal/agent/report.go | sed -n '371,385p'

# DBConnection/swap opaque error (task-cbde37238506ed7c)
git grep -n 'unknown error' origin/main -- api/lib/barkpark/content/errors.ex

# build-concurrency cap + box vitals (task-aa775c3d30287a4b)
git grep -n '@build_slot_capacity' origin/main -- api/lib/barkpark/sites/deploy_runner.ex
git grep -n 'SwapUsedPercent' origin/main -- internal/agent/report.go

# agent space route (task-ca88b8ea571b3470)
git grep -n 'v1/agent/space' origin/main -- cloud/lib/barkpark_cloud/web/router.ex
git grep -n '@types ~w' origin/main -- cloud/lib/barkpark_cloud/registry/agent_event.ex

# jarl 96% disk ranks HEALTHY (task-e15db1dc07507cf9)
git show origin/main:internal/cli/cloud_status_cmd.go | grep -n 'filling'
git grep -n 'SitesDir' origin/main -- internal/agent/report.go   # no containerd/builder root

# digest calls a sick fleet healthy (dr-w10-bl-digest-email-...)
git show origin/main:cloud/lib/barkpark_cloud/notifications/digest_email.ex | sed -n '49,60p'

# graph phantom ids (dr-bl-graph-phantom-id-exposure)
git show origin/main:api/lib/barkpark/content/graph.ex | sed -n '227,241p'

# ledger fixture re-derivation (task-a4b939801795cf94)
git show origin/main:cloud/test/barkpark_cloud/deploy_ledger_test.exs | grep -n '2026-08-0'
git grep -rn 'CONTENT_API' origin/main   # charter only, no code
```

## 3. The refusal seam (structural answer)

```
git show origin/main:api/lib/barkpark/content/authoring_wall.ex | sed -n '96,120p'   # @walled_types ~w(paper task); with-chain
git show origin/main:api/lib/barkpark/tasks/schema.ex | sed -n '321,338p'            # no validation required/min on acceptance_criteria
```

## 4. Consumers of doc.acceptance_criteria (the trap is consumed, not latent)

```
grep -rn 'acceptance_criteria' --include='*.sh' --include='*.py' --include='*.go' --include='*.ex' scripts/ tooling/ internal/
git show origin/main:internal/cli/cmux_hook.go | sed -n '270,294p'   # zero criteria -> (0,false), never provably done
git show origin/main:tooling/fleet/fleet-run.sh | sed -n '236,246p'  # ac[0] -> '' silently
```

## 5. Refuted direction claims

```
git grep -c 'Pressure' origin/main -- internal/cloudclient   # 4, NOT nothing (D158g false as written)
```
