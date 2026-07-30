# spd-w19 dispatch-time board recheck — re-derivation recipes (2026-07-30)

Read-only. Run from the shared checkout (`/Volumes/SATECHI/github/barkpark`), never a worktree.

## 1. Every round-2 / residue task's CURRENT claim + epoch

```bash
for t in spd-w18-empty-state-seam spd-w18-desk-chips-answer spd-w18-desk-click-latency \
         spd-w18-plus-creates-without-navigating spd-w18-bl-select-detects-dead-destination \
         spd-w18-bl-repair-button-endtoend spd-bl-focus-after-select spd-bl-plugin-link-aria-current \
         spd-w18-share-access-btn-names spd-b18-btn-focus-visible-desk-wide spd-w17-pending-honest \
         spd-bl-desk-chips-claim-tab-semantics-they-lack spd-bl-doc-checkbox-is-an-unfocusable-span; do
  echo "== $t"
  bp task get "$t" -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];c=d.get('claim') or {};print(d['id'],d.get('lifecycle_status'),d.get('assignee'),c.get('epoch'),c.get('worker'),c.get('expired_at'))"
done
```

Expected at dispatch: all 13 `open`, `assignee=None`, `claim=None` — i.e. free, no foreign holder.

## 2. Stale-open detector — shipped wave-18 work still at N-1/N

```bash
for t in spd-w18-fossil-named-state spd-w18-journey-harness spd-w18-save-announces \
         spd-w18-nil-icon-500 spd-w18-guard-rings-and-label; do
  bp task get "$t" -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];c=d.get('claim') or {};print('$t',d.get('lifecycle_status'),d.get('criteria_progress'),'ep',c.get('epoch'),'worker',c.get('worker'))"
done
git log origin/main --oneline -25 | grep -E '#789[6789]|#7900'
```

The only unmet criterion on each is verbatim `PR merged to main (LEAD closes this criterion).`
`#7896 #7897 #7898 #7900` are on `origin/main`; `#7899` is not.

## 3. #7795 landability, and #7899 reds vs. main's OWN reds (per-commit check-runs, never the rollup)

```bash
gh pr view 7795 --json state,mergeable,mergeStateStatus,headRefOid
for sha in $(gh pr view 7795 --json headRefOid -q .headRefOid) \
           $(gh pr view 7899 --json headRefOid -q .headRefOid) \
           $(gh api repos/:owner/:repo/commits/main -q .sha); do
  echo "== $sha"
  gh api "repos/:owner/:repo/commits/$sha/check-runs?per_page=100" -q '.check_runs[]|"\(.conclusion)\t\(.name)"' | sort
  gh api "repos/:owner/:repo/commits/$sha/status" -q '.statuses[]|"\(.state)\t\(.context)"'
done
```

`main` itself is red on `Doc budgets + anchors`, `Dependency CVE audit (blocking)`,
`Sobelow static analysis`, `Format`. Subtract main's set before reading any branch's set.

## 4. The standing doc-gates red (one line, reproducible without CI)

```bash
git show origin/main:api/lib/barkpark_web/live/studio/studio_live/components.ex | sed -n 1768p
bash scripts/studio-literal-check.sh   # from a clean origin/main tree
```

`studio-literal-check` reads the HTML entity `&#160;` as a hex colour literal.

## 5. Collision fence — who else touches the lane-2/lane-4 files

```bash
for n in $(gh pr list --state open --limit 100 --json number -q '.[].number'); do
  gh pr view "$n" --json number,files,headRefName \
    -q '.number as $n | .headRefName as $b | .files[] | select(.path|test("root.html.heex|studio_live/components.ex|studio_components")) | "\($n) \($b) \(.path)"'
done
git grep -n 'def studio_live_shell\|<\.studio_editor_shell' origin/main -- api/lib
```

`studio_live_shell/1` opens at `components.ex:1018`; the SOLE `<.studio_editor_shell`
call site is `components.ex:1418` (closing tag `:1442`). #7899's hunks at `:1060`/`:1109`
fall INSIDE `studio_live_shell/1` — same function as lane 2's fill site.

## 6. The checkout's own hazard (run before ANY commit from here)

```bash
git rev-list --left-right --count HEAD...origin/main
git log HEAD --not origin/main --oneline | head
```

Measured 2026-07-30: `48  42` — local `main` carries 48 foreign `PPCC2`/`omx(team)`
commits and is 42 behind. Committing ledger rows from `HEAD` drags all 48 into the PR.
Preserve, `reset --hard origin/main`, then branch.
