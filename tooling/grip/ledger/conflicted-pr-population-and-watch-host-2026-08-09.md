# Re-derivation recipe — conflicted-PR population + stale-verdict reporter host (dr wave 27, verifier)

Measured 2026-08-09 against `origin/main` = `da47f61aa39c0bd66afc658270ae1a92ecba2c9f`.

## 1. Does the host exist? YES.

    git show origin/main:.github/workflows/main-gate-watch.yml | head -5
    git show origin/main:scripts/main-gate-watch.sh | head -5
    git log origin/main --oneline -1 -- .github/workflows/main-gate-watch.yml
    # -> f5a29922c ci: main's tip carries a verdict or this screams (cch-w59-s3) (#11122)
    gh pr view 11122 --json mergedAt,files
    # -> merged 2026-08-09T05:49:31Z; 3 files incl. scripts/main-gate-watch.test.sh

The "ABSENT" surveyor read a checkout older than the 05:49:31Z merge.

## 2. Conflicted population (stable across 3 samples, 0 UNKNOWN)

    gh pr list --state open --limit 100 --json number,mergeable \
      --jq '[.[].mergeable]|group_by(.)|map({(.[0]):length})'
    # -> [{"CONFLICTING":22},{"MERGEABLE":18}]   (open total 40)

## 3. How many assert green — count all-of-present, NOT count-of-SUCCESS

The briefed jq counts SUCCESS entries and reports 10 at "green:4". Two of those
(#10722, #10720) render FIVE required-named check runs, one of which is a
FAILURE — the count-of-SUCCESS reaches 4 anyway. Correct form:

    gh pr list --state open --limit 100 --json number,mergeable,statusCheckRollup > /tmp/prs.json
    python3 - <<'EOF'
    import json
    REQ={"Elixir gate","PR references an active task","Cloud gate","Console gate"}
    rows=json.load(open('/tmp/prs.json'))
    for p in [x for x in rows if x['mergeable']=="CONFLICTING"]:
        req=[(c.get('name') or c.get('context'), c.get('conclusion') or c.get('state'))
             for c in (p.get('statusCheckRollup') or []) if (c.get('name') or c.get('context')) in REQ]
        ng=[r for r in req if r[1]!="SUCCESS"]
        print(p['number'], len(req), "GREEN" if req and not ng else ng or "NO-REQUIRED-CONTEXTS")
    EOF

Result: 22 conflicting / 10 all-present-green / **8 at exactly 4-of-4 green**
(10054, 10085, 10086, 10129, 10256, 10811, 11007, 11008); 6057 and 6086 are
1-of-1 green (three required contexts never rendered at all); 10766 renders
ZERO required contexts.

## 4. The green is stale, proved on one PR

    gh pr view 11008 --json headRefOid,statusCheckRollup
    # Elixir/Cloud/Console gate + PR task gate all SUCCESS, completedAt 2026-08-08T16:38-16:40Z
    # head 2a3e1241e; main has since moved to da47f61aa. Zero re-dispatch.
