# stale-verdict-watch — population + per-PR epic ownership (wave 30 verifier)

Re-derivation recipes. Every number below was produced by running these, never read from a doc.
Taken 2026-08-09 ~14:1xZ against `origin/main` 839453b70614be46ce84f25cfef0155f9fcbf78c.

## 1. Run the watch from origin/main, never the primary checkout

```
T=$(mktemp -d); mkdir -p $T/scripts $T/.github
git show origin/main:scripts/stale-verdict-watch.sh > $T/scripts/stale-verdict-watch.sh
git show origin/main:.github/required-checks.json > $T/.github/required-checks.json
(cd $T && bash scripts/stale-verdict-watch.sh --repo FRIKKern/barkpark); echo RC=$?
```

Observed: `RC=1`; `35 open · 25 CONFLICTING · 10 MERGEABLE · 0 UNKNOWN`;
`RED — 23 CONFLICTING pull request(s) assert a green required verdict main has moved past.`

## 2. Per-PR epic ownership (derived from each PR's own body slice-slug, not guessed)

```
for n in 6028 6057 6086 10054 10085 10086 10129 10173 10256 10400 10404 10407 \
         10496 10522 10523 10720 10722 10811 10944 11007 11008 11169 11174; do
  echo "=== #$n"
  gh pr view $n --json headRefName -q .headRefName
  gh pr view $n --json body -q .body | grep -oE 'dr-w[0-9]+-[a-z0-9-]+|cch-[a-z0-9-]+' | sort -u | head -3
done
```

Split (23 = 14 + 6 + 3):

- deploy-reliability (this epic, 14): 10129 10173 10400 10407 10496 10522 10720 10722 10811 10944 11007 11008 11169 11174
- cloud-console-hardening (FENCED — closing any is a fence violation, 6): 10054 10085 10086 10256 10404 10523
- neither epic (3): 6028 (bp-mcp onramp) 6057 (sobelow baseline) 6086 (epic-cycle memory)

Residual after draining the epic's own four (11007 11008 11169 11174): **19** — 10 ours, 6 cch, 3 foreign.
Residual after draining ALL 14 deploy-reliability rows: **9**, none of them ours. The GREEN is unreachable
by any act inside this epic's fence.

## 3. The arm-5 comment on main is now FALSE

```
git show origin/main:.github/workflows/stale-verdict-watch.yml | sed -n '125,130p'   # "The ONLY push run ... 31311358759"
gh run list --workflow stale-verdict-watch.yml --limit 200 \
  --json event,conclusion -q '[.[]|[.event,.conclusion]|join(" ")]|group_by(.)|map({k:.[0],n:length})|.[]|"\(.k)\t\(.n)"'
gh run view 31316075524 --json headSha,event,conclusion,createdAt
gh run view 31316075524 --log | grep -E 'POPULATION|open ·|^.*ok — no CONFLICTING'
```

Observed: `push success 2`, not 1. The second is **31316075524**, head `718461e8b`, push, SUCCESS,
2026-08-09T13:32:37Z — `42 open · 0 CONFLICTING · 0 MERGEABLE · 42 UNKNOWN` and
`ok — no CONFLICTING pull request is asserting a green required verdict that main has moved past.`
It concluded 93 seconds before #11256 (`899aa34c0`, merged 13:34:10Z) landed the BLIND arm, so it is a
SECOND blind green, not one the fix covers. `.github/workflows/stale-verdict-watch.yml:54` and `:125-127`,
and charter `D502` (`.claude/workflows/bp-deploy-reliability-charter.md:9670`, "**1 success**"), all now
misstate the census. One-line corrections; the arm itself is correct and needs no change.

## 4. Charter cross-checks

```
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md > /tmp/c.md
sed -n '9729,9733p' /tmp/c.md   # "draining the epic's own four leaves 19 rows, eleven belonging to other epics' charters"
sed -n '5607,5611p' /tmp/c.md   # D302-D336 stranded on #10522 #10496 #10612 #10407 #10173 #10133
```

`19` reproduces exactly. `eleven belonging to other epics' charters` does NOT: only **9** of the 19 are
foreign, and only **4** of those are other-epic *charter* PRs (10054 10256 10404 10523). Ten of the 19 are
this epic's own — four of them its own stranded wave charters (10173 w11, 10407 w16, 10496 w18, 10522 w19),
which carry D256-D336 that `origin/main` does not (`grep -c 'D256\|D322' /tmp/c.md` finds only prose
*about* the stranding). Closing those four deletes unrecorded charter history: salvage before close.
