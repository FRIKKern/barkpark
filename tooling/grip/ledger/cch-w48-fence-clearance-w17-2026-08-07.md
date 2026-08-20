# CCH wave-48 fence clearance for deploy-reliability wave 17 — re-derivation recipes

Taken 2026-08-07, `origin/main` = `9af98373d` (which IS the merge of CCH `cch-w48-s7` #10450).
CCH w48 charter authority = branch `origin/epic-charter/cloud-console-hardening-w48-20260807T162842Z`
(PR #10404, OPEN). It does NOT exist on `origin/main` — main's CCH charter tops out at **D534**.

## R1 — fetch the charter branch and read its new rows

    git fetch origin 'refs/heads/epic-charter/*:refs/remotes/origin/epic-charter/*'
    git show origin/epic-charter/cloud-console-hardening-w48-20260807T162842Z:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -n 'cch-w48' -A 6

## R2 — prove w48 added NO new Surface-fence widening (rc/count is the proof)

    git diff origin/main origin/epic-charter/cloud-console-hardening-w48-20260807T162842Z \
      -- .claude/workflows/bp-cloud-console-hardening-charter.md | grep -c '^+\*\*Wave-48'
    # → 0

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -n '^\*\*In fence'
    git show origin/epic-charter/cloud-console-hardening-w48-20260807T162842Z:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -n '^\*\*In fence'
    # both → 125:**In fence:** `cloud/`, `api/lib/barkpark_web/live/`.   (BYTE-IDENTICAL)

## R3 — prove `attention_order.json` is absent from the w48 charter

    git show origin/epic-charter/cloud-console-hardening-w48-20260807T162842Z:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -c 'attention_order'
    # → 0
    # counter-authority (DR side, on main): charter D57 claims the fixture as DR's
    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n 'D57 — `cloud/priv/static/__fixtures__/attention_order.json` IS OURS'

## R4 — prove all six w48 build slices MERGED (the region fences are SPENT)

    for n in 10445 10446 10447 10448 10449 10450; do \
      gh pr view $n --json state,mergedAt,files \
        -q '"\(.state) \(.mergedAt) \([.files[].path]|join(","))"'; done
    # all six MERGED 2026-08-07T17:44Z

## R5 — the census region on main, and who claims it

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'deploy-ledger/census\|DeployLedger\.census\|defp operator_fleet_json'
    # 3536: get "/v1/operator/deploy-ledger/census" do
    # 3537:   conn = Auth.require_platform_operator(conn, [])
    # 3544:   json(conn, 200, DeployLedger.census(from, to))
    # 9348: defp operator_fleet_json(bp) do

    for n in 10401 10129 10154 10019 9956; do echo "### $n"; gh pr diff $n | \
      awk '/^diff --git .*cloud\/lib\/barkpark_cloud\/web\/router.ex/{f=1;next} /^diff --git /{f=0} f&&/^@@/{print}'; done
    # only #10401 lands inside 3513-3551 / 9348+ ; #10129 is at 1891 / 8755 / 8828

## R6 — #10401's conflict is DR-internal, not a CCH collision

    gh pr view 10401 --json mergeable,mergeStateStatus   # CONFLICTING DIRTY
    B=$(git merge-base origin/main origin/loop-epic/two-built-readers-stop-being-unreachable-2)
    git merge-tree $B origin/main origin/loop-epic/two-built-readers-stop-being-unreachable-2 | grep -c '<<<<<<<'   # 3
    git log --oneline -1 $B   # 0d817eb05 (#10354) — behind wave 16's own #10440/#10442/#10443

## R7 — the only LIVE CCH claim left after w48

    bp task get cch-w46-s7-member-actor-rendered-state-authority-sweep
    # unclaimed; files: __preview__/smoke.mjs, breakpoint-sweep.mjs(+.test.mjs),
    # __app.test.mjs, NEW __member_authority_sweep.mjs, .github/workflows/console-harness.yml
    # NB: `bp task get cch-w46-s7` → not_found (the bare cch-wNN-sM form is not an id)

## R8 — open-PR file claims across the cloud family

    for n in $(gh pr list --state open --limit 60 --json number -q '.[].number'); do \
      f=$(gh pr view $n --json files -q '.files[].path' | grep -E 'cloud/priv/static|console-harness|web/auth\.ex|attention_order' | tr '\n' ' '); \
      [ -n "$f" ] && echo "$n: $f"; done
    # 10155 console-harness.yml | 10129 attention_order (both) | 10085 __binding_census.*
    # 10006 app.js,__app.test.mjs,__preview__/mock.js | 9956 web/auth.ex | 6028 app.js,__app.test.mjs
