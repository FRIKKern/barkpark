# Ledger hygiene — wave 18 stale-row re-derivation recipes (2026-08-07)

Baseline: `origin/main` @ `6d80e83442cd37c907c4bd5a4f8f71aa7d309727` (fetched 2026-08-07 ~19:35Z).
Every row below was verified against origin/main FIRST. Verifier made NO bp mutations
(role fence: verifiers do not write the ledger); the corrections are handed to Decide
as ready-to-run commands.

---

## 1. `dr-followup-start-reported-callers` — DEAD (all 4 criteria satisfied by #10476)

    git grep -n 'Deploy\.start(' origin/main -- 'cloud/lib/**/*.ex'
    # 5 hits, ALL inside comments describing the historical form. Zero call sites.

    git grep -n 'Deploy\.start_reported(' origin/main -- 'cloud/lib/**/*.ex'
    # auto_deploy_worker.ex:264, template_freshness_worker.ex:296,
    # router.ex:11553, router.ex:13144  — all four converted.

    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | grep -n 'def start_reported\|^  def start('
    # 593: def start_reported(%Deployment{id: id}), do: starter().start(id)
    # no `Deploy.start/1` remains; the surviving `def start(deployment_id)` at
    # 2058/2105/2130 are @behaviour Sites.Deploy.Starter impls (Task/Sync/Noop starters).

    gh pr view 10476 --json number,title,state,mergedAt
    # MERGED 2026-08-07T19:00:23Z — "delete Deploy.start/1 so a refused driver
    # spawn cannot be reported as success"

CORRECTION: close as done (or cancelled-superseded), citing #10476.

---

## 2. `dr-bl-500-caption-lie` — criteria 1 AND 4 already built by #9730

    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | grep -n 'box_refusal'
    # 676, 693, 697 -> phase :start ; 929, 942 -> phase :poll
    # 1412: defp box_refusal(status, body, phase) when is_map(body)
    #        :start -> "the instance refused the deploy (HTTP #{status})"
    #        :poll  -> "the instance refused the build poll (HTTP #{status})"
    #        appends "[box request_id: #{rid}]" via request_id/1

    git log --oneline origin/main -S'box request_id' -- cloud/lib/barkpark_cloud/sites/deploy.ex
    # d9a6408ee  fix(cloud): a pool blip on one poll beat stops killing a finished build (#9730)

CORRECTION: c1 -> met:true (phase recorded, arity is /3 not /2 — the row's own arity is stale).
c4 -> met:true with the stated reason it is folded into `failure_reason` (:text) rather than a
column: no migration, no new column. c2/c3/c5 stay met:false — grep for a HEALTH-phase caption
finds nothing on main.

---

## 3. `dr-w13-s7-census-residue-and-per-site-blindness` — c5 duplicate, c8 phantom

c5 ("a DeployCensusSite pair is added to @pairs, proven able to lose") is the SAME work as
`dr-w16-s4-per-site-row-named-producer` criteria 2+3, which are strictly more specific
(`entry: {:site_row, 2}`, plus the before/after mutation run). One owner: dr-w16-s4.

    git show origin/main:cloud/test/barkpark_cloud/payload_key_set_census_test.exs | grep -n '@pairs\|DeployCensus'
    # @pairs at 471; only DeployCensus (486) and DeployCensusWindow (492). No site pair yet.
    git grep -n 'DeployCensusSite' origin/main -- 'internal/**/*.go'
    # client.go:1953 (type) and 2009 (Sites []DeployCensusSite `json:"sites"`) — the Go side EXISTS.

c8 ("a floor 18 below its population") is a PHANTOM — the 18-tag drift was retired when the
floor moved 197 -> 218 (wave 13) and again to 221 (#10442). MEASURED slack today is 1:

    git show origin/main:cloud/test/barkpark_cloud/payload_key_set_census_test.exs | grep -n '@emitted_floor\|@go_tag_floor'
    # 601: @emitted_floor 108
    # 602: @go_tag_floor 221

    # replicate Go.all_tags/1 exactly (split on comma, first field, reject "" and "-"):
    git show origin/main:internal/cloudclient/client.go \
      | grep -o 'json:"[^"]*"' | sed 's/json:"//;s/"$//' | cut -d, -f1 \
      | grep -v '^-$' | grep -v '^$' | sort -u | wc -l
    # 222      (client.go is the only non-_test.go file in internal/cloudclient)

CORRECTION: retire c5 (point at dr-w16-s4). Re-word c8 to the measured slack of ONE, or drop it.

---

## 4. `dr-w16-s6-team-scoped-census-returns-200` — c11 satisfiable NOW, c12 merged

    gh pr view 10472 --json state,mergedAt   # MERGED 2026-08-07T18:59:56Z

    TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
    curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOK" \
      https://api.barkpark.cloud/v1/operator/deploy-ledger/census        # 403 (proves non-operator)
    curl -s -H "Authorization: Bearer $TOK" \
      "https://api.barkpark.cloud/v1/deploy-ledger/census?from=2026-08-06T19:37:48Z&to=2026-08-07T19:37:48Z"
    # HTTP 200 at 2026-08-07T19:37:48Z
    # scope.team = "guerrilla", scope.registered_sites = 13, volume 2117, failed 29, live 579,
    # sites[] length 7

CORRECTION: stamp c11 met:true with the above; stamp c12 met:true citing #10472; close the row.
LEG-1 NOTE for Decide: leg 1's proposed acceptance ("a LIVE RUN returning 200 on a real
non-operator credential") is ALREADY this row's c11 — do not re-cut it as a new slice's
acceptance. Leg 1's real, unbuilt work is the Go caller at
`internal/cloudclient/client.go` (func FleetDeployCensus at :2154, the `c.do` at :2158 hitting
`/v1/operator/deploy-ledger/census`) and the string pin at
`internal/cli/cloud_deploy_census_cmd_test.go:167`:

    git show origin/main:internal/cloudclient/client.go | grep -n 'operator/deploy-ledger\|func (c \*Client) FleetDeployCensus'
    # 1972 (doc comment), 2146 (doc comment), 2154 (func), 2158 (c.do)
    git show origin/main:internal/cli/cloud_deploy_census_cmd_test.go | sed -n '167p'
    #  if *method != "GET" || *path != "/v1/operator/deploy-ledger/census" {
