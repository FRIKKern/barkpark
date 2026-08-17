# dr-w35 — fence negatives and floor collisions (re-derivation recipes)

Verifier `fence-negatives-and-floor-collisions`, wave 35, 2026-08-17. Every row is one
command that re-derives the fact from scratch. Nothing here is a summary of a summary.

## (a) #11534's complete file set — no CI config

    gh pr diff 11534 --name-only

Seven files: `cloud/lib/barkpark_cloud/deploy_ledger.ex`,
`cloud/test/barkpark_cloud/{deploy_ledger_test.exs,payload_key_set_census_test.exs,reader_less_instrument_census_test.exs}`,
`internal/cli/cloud_deploy_census_cmd{,_test}.go`, `internal/cloudclient/client.go`.
ZERO `.github/**`. The open PRs that DO hold CI config:

    gh pr list --state open --limit 200 --json number,mergeable,files \
      -q '.[]|select([.files[].path]|map(test("^\\.github/"))|any)|"\(.number) \(.mergeable)"'
    # 10722 CONFLICTING (deploy.yml) · 10155 MERGEABLE (cloud.yml, console-harness.yml) · 10085 CONFLICTING (console-harness.yml)

## (b) `@go_tag_floor` — main is 264, #11534's 268 is exactly 264 + 4

Base, derived without running the suite (the union the census's UNREAD arm takes,
non-test Go sources only, per the test's own `all_tags/…` doc):

    git ls-tree -r --name-only origin/main internal/cloudclient/ | grep -v _test.go > /tmp/f.txt
    for f in $(cat /tmp/f.txt); do git show origin/main:$f; done \
      | grep -oE 'json:"[a-zA-Z0-9_]+' | sed 's/json:"//' | sort -u > /tmp/maintags.txt
    wc -l < /tmp/maintags.txt        # => 264, matching @go_tag_floor 264 on main

Per-PR delta against that union (`_test.go` excluded because the census excludes it):

    gh pr diff <N> | awk '/^diff --git/{f=($0 ~ /internal\/cloudclient\/[a-z_]*\.go/ && $0 !~ /_test\.go/)} f && /^\+/' \
      | grep -oE 'json:"[a-zA-Z0-9_]+' | sed 's/json:"//' | sort -u | comm -23 - /tmp/maintags.txt

    #11534 +4  covering_bound never_covered_sites never_covered_sites_total never_covered_sites_truncated  -> 268
    #10811 +2  coalesced_attempts since                                                                   -> 270 after #11534
    #10086 +1  details                                                                                    -> 269 after #11534
    #10129 +5  absorption box_caused deploy_rate rate sites_deploying                                     -> 273 after #11534

Name-for-name identical to charter D571's independent run-proof for #10811 and #10129.
#10086's +1 is NOT in D571 (D571 covers two PRs); charter `:8035` covers all three.
#11534's own hazard note names #10811 and #10129 and OMITS #10086.

## (b2) `@emitted_floor` 149 is NOT collision-exposed

The floor is a SUM over `@pairs`, whose Elixir entries are `barkpark_json/4`,
`site_deployment_json/3`, `DeployLedger.{census/3,rate/2,site_row/2}`,
`PlatformDelivery.to_json/1` (+ `deploy_census_json/2` as an `also`). No open PR edits any
of those bodies:

    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex \
      | grep -nE '^  (def|defp) (census|rate|site_row|site_rows|coverage_cohorts)\('
    # 1127 census/3 · 1504 coverage_cohorts/2 · 1671,1683 rate/2 · 1742 site_rows · 1754 site_row

    for n in 10400 10129; do gh pr diff $n \
      | awk '/^diff --git/{f=($0 ~ /deploy_ledger\.ex/)} f' | grep -nE 'census|site_row|def rate'; done
    # #10400: no hits at all. #10129: five hits, ALL inside added COMMENT prose.

    for n in 10154 9956 6028; do gh pr diff $n \
      | awk '/^diff --git.*cloud\/lib\/barkpark_cloud\/web\/router\.ex/{f=1;next} /^diff --git/{f=0} f' \
      | grep -E '^[+-]'; done
    # #10154 and #9956: comment-only. #6028: swaps require_team_admin for
    #   require_user_or_pat + require_ability at the credentials route — no serializer.

CAVEAT: 144 -> 149 was NOT independently re-derived here (it needs the suite). Only the
go-tag half is proven at today's tip.

## (c) #10766 IS a genuine fifth stranded CCH charter, and it is unmergeable as numbered

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -cE 'D6(1[7-9]|2[0-8]) '                         # => 9 (citations, not rows)
    for d in 617 618 ... 628; do git show origin/main:<cch charter> \
      | grep -cE "^\| D$d \||^- \*\*D$d —|^\*\*D$d —|^### D$d —"; done
    # DEFINED on main: D617 only — and it is a DIFFERENT decision (the foreign
    #   anon-metering two-subject carve-out, charter :274 / :999).
    # D618-D628: not defined anywhere on main. Ceiling on main is D827.

Main's charter already rules on this PR: `:1560` — "#10766 must still move its D617 row,
which collides with the anon-metering fence on main." Wave 35 may not close it: PR-body
slug derivation puts it in the CCH fence.

Open CCH charter PRs today (five): #10054 (w40), #10256 (w45), #10404 (w48), #10523 (w50),
#10766 (w54).

## (c2) Epic ownership by PR-body slug — the "6 CCH" census at charter :10291 is STALE

    for n in <every open PR>; do gh pr view $n --json body -q .body \
      | grep -oE '\b(cch|dr)-w[0-9]+[a-z0-9-]*' | head -1; done

CCH-owned opens today: 10054, 10085, 10086, 10154, 10006, 9956, 10155 (cch-w42) plus the
four unslugged CCH charters 10256/10404/10523/10766 = ELEVEN. #10944 carries a **DR** slug
(`dr-w24-bl-gyldendal-live-cross-tenant-escalation`) yet is CCH wave 68's S3 re-land —
cross-epic, and wave 35 must not act on it.

## (c3) #10173 is FULLY SUPERSEDED — closable with no salvage

    for d in 105 106 142 161 162 163 164 165 166 167 168 169 170 171; do \
      git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md \
      | grep -cE "^- \*\*D$d —|^\*\*D$d —|^### D$d —"; done
    # D105,D142,D161-D171 all = 1 (defined on main). D106 = 0, and #10173 only CITES it.

This refutes charter `:10303`'s grouping of #10173 with the three that need salvage
(#10407, #10496, #10522). Also: the charter's stranded set is SIX (`:5609`: #10522 #10496
#10612 #10407 #10173 #10133), SEVEN with #11539 — the wish names five.

## (d) CCH wave 68's slice fences are disjoint from wave 35's file set

    bp doc get paper cloud-console-hardening-wave-68-2026-08-17 -o json

Round 1: S1 `router_sites_test.exs` + `deploy.ex`; S2 `app.js` + `__app.test.mjs`;
S3 `registry.ex` + `registry_custom_host_test.exs`. Round 2: S4/S5 on `app.js`.
The only repo paths the whole paper names are `cloud/lib/barkpark_cloud/registry.ex` and
`cloud/mix.exs`. It touches NO `internal/cloudclient`, NO `deploy_ledger.ex`, NO census
test, and a DIFFERENT charter file. No collision — but both epics write
`tooling/grip/ledger/**`, so filenames must stay epic-prefixed.

## Merge order this implies

1. `#11534` (the only MERGEABLE floor-mover) — its 268 is correct at today's tip.
2. The union charter-reconcile PR. Because `#11539` is currently MERGEABLE and edits the
   SAME charter file, merging the union first makes `#11539` CONFLICTING: either the union
   carries the wave-34 entry and `#11539` closes superseded, or `#11539` merges FIRST.
3. `#10811` / `#10086` / `#10129` never merge without a 999 re-measure. `#10086` is
   foreign (CCH) — coordinate, never close.
