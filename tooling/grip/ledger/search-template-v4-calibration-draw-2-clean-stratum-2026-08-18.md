<!-- doc-tier: cold | canonical-for: search-template-audit-v4-calibration-draw-2 | budget: 1500tok -->
# Search-Template Done-Set Audit — V4 calibration draw #2 (clean strata) re-derivation recipes

Wave: search-template-wave-2026-08-18-audit. Assignment V4: does any CLEAN-stratum done
row (loop-lead w1-8, codex-wave5, 4 true engine-builder) fail to be structurally pinned
by real bytes on origin/main under a mutate-check? Verdict: **NO. 10/10 pinned, 0 vacuous,
false-done = 0 in this draw.** Anchor: origin/main e21bf40 (fetched 2026-08-18 09:45).

## Denominator (re-derive)
    bp task get search-template-epic-goal -o json | python3 -c "import json,sys;from collections import Counter;print(Counter(x['lifecycle_status'] for x in json.load(sys.stdin)['children']))"
    # -> done:72 open:38 considering:6 cancelled:1  (child_count 117 = total, NOT done)

## Stratum classify (closed_by regime)
    bp task get <doc_id> -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];c=d.get('claim') or {};print(c.get('closed_by'),c.get('worker'),d.get('criteria_progress'))"
    # loop-lead => LEAD-CLOSED; codex-task-quality-wave5 => codex; epic-builder-* => engine-builder

## Mutate-checks (guard = anti-pattern must be absent from CODE lines; comment-only OK)

### stw6-engine-file-contract [2] — no secret on child argv (GUARD, strongest)
    for f in deploy/site-deploy.sh deploy/site-deploy-node.sh deploy/lib/site-deploy-common.sh; do
      git show origin/main:$f | grep -nE 'env -i|BARKPARK_TOKEN=' | grep -vE '^[0-9]+:[[:space:]]*#'
    done
    # -> EMPTY for all three: every 'env -i'/'BARKPARK_TOKEN=' hit is a COMMENT. Guard holds.

### stw1-app-extraction [1] — no vendored portable-doc (GUARD)
    git show origin/main:templates/search-starter/components/document-detail.tsx | grep -nE 'import.*@barkpark/react|components/portable-doc'
    # -> line10 import { PortableDoc } from "@barkpark/react"; only 'web/components/portable-doc' hit is comment line6

### stw6-deployrunner-reattach [0] — EnvironmentFile never --setenv (GUARD)
    git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | grep -n 'setenv'
    # -> only lines 62 (@moduledoc) + 1353 (comment). Real argv (1367 --unit=, 1369 --property=EnvironmentFile=) uses neither.

### stw1-graph-theme-parity [1]/[3] — byte-identical copies + doc-gates trigger
    diff <(git show origin/main:web/public/bp-graph.js) <(git show origin/main:api/priv/static/assets/bp-graph.js)  # exit 0, sha 7cf73ce
    git show origin/main:.github/workflows/doc-gates.yml | grep -n 'templates/\*\*'  # lines 140 (push) + 290 (pull_request)

### stw6-cp-restart-grace [0] — grace_left SEPARATE counter
    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | grep -nE 'defp poll|grace_left'
    # -> poll/4 (line893); {:error,_} when grace_left>0 -> poll(...,left,grace_left-1) keeps left UNCHANGED (line948-950); :running resets to poll_grace() (903)

### stw6-graph-flat-origin [0] — origin derived before flat /v1/graph (Next + Astro)
    git show origin/main:templates/search-starter/lib/graph.ts | grep -nE 'new URL.*origin|/v1/graph'    # 188 const origin=new URL(API_URL).origin; 189 `${origin}/v1/graph`
    git show origin/main:templates/astro-search-starter/src/lib/bp.ts | grep -nE 'new URL.*origin|/v1/graph'  # 89 `${new URL(env.apiUrl).origin}/v1/graph`

### stw4-backlog-site-preflight [0] / stw8-cli-site-settings [0] / stw4-cli-create-deploy-motion [0] — CLI verb dispatch + test
    git grep -nE 'case "preflight"|case "settings"' origin/main -- internal/cli/cloud_site_cmd.go   # :100 preflight, :102 settings
    git grep -nl 'TestRunCloudSiteCreateDeployMotion' origin/main -- internal/cli                    # cloud_site_cmd_test.go

## Coverage: 10 rows, all 3 clean strata (4 engine-builder incl. app-extraction; 4 codex; loop-lead graph-theme-parity + cli-site-settings + graph-flat-origin). Every guard mutate-checked. Zero vacuous.
