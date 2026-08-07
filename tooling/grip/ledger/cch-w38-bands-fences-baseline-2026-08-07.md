# cch-w38 — bands, fences and the baseline, re-derived after the queued PRs

Verify phase, wave 38. Every number below was produced by a command in this file,
against `origin/main` = `ef77af2748ceda54fdd6e078f71a6e6044b55439` and against a
SIMULATED merge tree (main + #9917 + #9919 + #9922) built without touching any
branch. The primary checkout is 504 commits behind main — never read a band from it.

## 0 — Build the simulated tree (no branch switch, no worktree)

```sh
cd /Volumes/SATECHI/github/barkpark
git fetch origin pull/9917/head pull/9919/head pull/9922/head
M=$(git rev-parse origin/main)
T1=$(git merge-tree --write-tree $M bbfddf03cb72d14c56564a2d0eedfbafda4b8fe8)   # 9917
C1=$(git commit-tree $T1 -p $M -p bbfddf03cb72d14c56564a2d0eedfbafda4b8fe8 -m sim1)
T2=$(git merge-tree --write-tree $C1 7d3ec6886f07604ad2e091e0446039666db307eb)  # 9919
C2=$(git commit-tree $T2 -p $C1 -p 7d3ec6886f07604ad2e091e0446039666db307eb -m sim2)
T3=$(git merge-tree --write-tree $C2 d5fcf226aa04c2be85f40a8ef414820c3579aa7e)  # 9922
C3=$(git commit-tree $T3 -p $C2 -p d5fcf226aa04c2be85f40a8ef414820c3579aa7e -m sim3)
echo $C3     # 292f0b071fadb4afa0f343640ebf6cedcddd85e8 on 2026-08-07
```

All three merge CLEAN (`merge-tree` exits 0 each time; no conflict stanza).
`app.js` 20959 -> 21067 (+108). `__app.test.mjs` 15528 -> 15698 (+170).
`app.css` 6583, untouched by all three.

## 1 — Compose proof (the three PRs do not break each other)

```sh
S=<scratch>; rm -rf $S/simtree && mkdir -p $S/simtree
git archive 292f0b071fadb4afa0f343640ebf6cedcddd85e8 cloud/priv/static | tar -x -C $S/simtree
cd $S/simtree/cloud/priv/static && node --test __app.test.mjs
```
sim: `# tests 919 / # pass 904 / # fail 15`.
main-only baseline, identical extraction: `# tests 914 / # pass 899 / # fail 15`.
The 15 are IDENTICAL by name in both and are environmental — every one of them
reads `cloud/lib/**` or a TUI golden, which a `cloud/priv/static`-only archive
does not carry. Net: +5 tests, ZERO new failures.

## 2 — cssom baseline: 1305, MEASURED not read

```sh
git show origin/main:cloud/priv/static/__preview__/cssom-heads.baseline | grep -vE '^#|^$'   # 1305
cd <maintree>/cloud/priv/static/__preview__ && node cssom-parity.mjs
#    authored rule heads   1305 (baseline 1305)
#    CSSOM style rules     1305 ... MISSES 0 ... PARITY PASS, rc=0
```

## 3 — S1 needs NO CSS (so the baseline holder question is moot)

```sh
git show origin/main:cloud/priv/static/app.css | grep -n 'inst-life-disabled\|inst-life-reason\|btn:disabled'
# 546:.btn:disabled { opacity: 0.55; cursor: not-allowed; }
# 1645:.inst-life-disabled { display: inline-flex; align-items: center; gap: 8px; }
# 1646:.inst-life-reason { font-size: 12px; color: var(--muted-text); }
# 5738:.cli-card .inst-life-disabled { padding: 8px 12px; border: 1px dashed var(--border); border-radius: var(--radius-sm); }
```
`lifecycleActionHtml`'s third arm (main app.js:1689-1692) ALREADY emits exactly
`<div class="inst-life-disabled"><button class="btn btn-sm" disabled title=…>` +
`<span class="inst-life-reason">`; `lifecycleActionRowHtml` already emits a
`model.loading` -> "Checking capabilities…" note (main:1712-1714). S1 consumes
both. GR25 (`bp-cloud-gui-remake-charter.md:40`) quarantines FOUR PILL families
only — `status-pill`, `dep-pill`, `tlv-badge`, `badge`/`fresh-badge`. None of
`.inst-life-*` or `.btn:disabled` is in that set. NO bump, NO carve-out for CSS.

## 4 — app.js bands, main -> sim (offset table, all derived)

| symbol | main | sim | offset |
|---|---|---|---|
| `var ERRORS` | 179 | 179 | 0 |
| `FORBIDDEN_ROLE_COPY` | 226 | 226 | 0 |
| `FORBIDDEN_REASON_COPY` | 233 | 233 | 0 |
| `lifecycleActionHtml` | 1675 | 1702 | +27 |
| `instanceDetailHtml` | 6381 | 6408 | +27 |
| `instanceLifecycle` | 6421 | 6448 | +27 |
| `runDecommission` | 6743 | 6770 | +27 |
| `retryInstance` | 6772 | 6799 | +27 |
| `removeInstance` | 6792 | 6819 | +27 |
| `updateInstance` | 6825 | 6852 | +27 |
| `rollbackInstance` | 6892 | 6919 | +27 |
| `attachDomain` | 6943 | 6970 | +27 |
| `patchAutoupdate` | 7636 | 7663 | +27 |
| `billingIsOwner` | 13318 | 13407 | +89 |
| `meState` | 13850 | 13939 | +89 |
| `__bpTestHook({` | 20302 | 20402 | +100 |
| export-object last row | 20956 | 21064 | +108 |

Queued-PR insertion points inside app.js (main coords): #9917 at 284 / 8321 /
8407 / 20304; #9919 at 243 only; #9922 at 8021 / 13938 / 20772. **None of them
touches 1521-1730 or 6381-7700** — S1's whole band is collision-free.

## 5 — The __bpTestHook insertion line

The role/me export cluster (main `canMintAnyAbility` :20766 … `meState` :20774)
is EXACTLY where #9922 lands (`@@ -20772,6 +20830,12 @@`, 6 lines below
`canMintAnyAbility`). Do not insert there.

SAFE POINT: immediately after `offloadSupportActionHtml: offloadSupportActionHtml,`
— **main:20956, post-merge sim:21064**, i.e. the last row of the export object,
before its `});`. Clearance: 176 lines from #9922's nearest insertion, 656 from
#9917's. It is the furthest-from-contention point in the whole object.

## 6 — __app.test.mjs EOF is ALREADY CLAIMED

`gh pr diff 9922 | grep '@@'` on `__app.test.mjs` ends with `@@ -15526,3 +15553,54 @@`
and main's file is 15528 lines: 15526+3-1 = 15528 = EOF. **#9922 owns EOF on main.**
Post-merge EOF = sim:15698. #9917 inserts at 15350 (+84); #9919 edits 15369-15499.
Ruling this implies: S1 and S2 must both be cut on the POST-#9922 tree; S1 takes
the (new) EOF, S2 inserts inside the `cch-w35-s4` band at sim 15465-15650.
`friendly` is already exported (sim:20510), so **S2 needs no new export at all** —
which settles the export-object tail for S1 alone.

## 7 — S2 collides with #9919 in auth.ex, in the @docs, not the halts

```sh
git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | grep -n 'no_team\|scope: "'
# main 414 / 441  json_halt(conn, 422, %{error: "no_team"})     <- S2's targets
# main 484        forbidden(conn, reason: "no_team", scope: "team")  <- the GOOD shape
# sim  422 / 453 / 496                                            (same three, shifted)
```
#9919's hunks are `@@ -395,12 @@`, `@@ -417,17 @@`, `@@ -444,7 @@` — they do NOT
contain 414 or 441, but they REWRITE both `@doc` blocks, and both rewritten docs
contain the sentence "422 `no_team` if the user has no team at all", which is
precisely the contract S2 changes. **S2 must be cut on top of #9919 or it
conflicts in prose.**

Blast radius, re-derived: the two gates have TEN route callers —
`POST /v1/onboarding` (1510), `GET /v1/audit` (1939), `DELETE /v1/barkparks/:id`
(1978), `self-update` (2991), `rollback` (3128), `autoupdate` (3252), `domain`
(3548), `billing/checkout|portal|cancel` (5113/5154/5189). Five of those are
S1's rail. No test asserts the string `no_team` on any of them: the 7 test files
that mention `no_team` pin INLINE router 422s (`POST /v1/tokens`,
`router_pat_test.exs:98`; the SSE-ticket suites; `router_test.exs:1858`) or the
403 shape (`router_ability_matrix_test.exs:480`). Gate-scoped S2 = 2 lines +
2 @docs. Router-scoped S2 = 34 router sites + 5 live test assertions.

## 8 — The cross-epic tripwire is CONTENT-shaped, not line-shaped

The brief's claim ("the census pins ABSOLUTE app.js line numbers … five pinned
rows sit below deployRow") is REFUTED by the census's own header, verbatim:
"Line numbers are NEVER written down here — they rot on any sibling shift …
every line number this census prints is DERIVED at run time from the live file."
`keyOf = (r) => \`${r.fn}|${r.verb} ${r.route}\``. The `line:` field is display
only. Arm (2f) is likewise "Content-matched, not line-pinned": it COUNTS regex
matches of `Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team)`
in router.ex and requires exactly 6.

The REAL tripwire, and it is live: `cloud/lib/**` is in `CONSOLE_PATHS`
(`scripts/console-path-escape-check.sh:153`), and #9920 says so itself — "so a
router edit reaches it". #9888 and #9889 (deploy-reliability, queued NOW) both
edit `cloud/lib/barkpark_cloud/web/router.ex`; neither adds the idiom today
(`grep -cE '^\+.*Accounts\.team_admin\?'` = 0 on both), so nothing reds yet.
And `task-54326937e919e2cf` (deploy-reliability, OPEN, P2) is chartered to
"show failure_class as a pill on the site-detail deploy row" — an app.js edit in
the band holding six census PIN rows (`loadSite` :10801, `openSiteEnvModal`
:11078, `runPromote` :11437, `runSiteRollback` :11649, `createAndDeploy` :12059,
`runDeploy` :12223). Because the key is the ENCLOSING FUNCTION NAME, extracting
a deploy-row renderer reds the required, blocking Console gate as ADD+REMOVE on
a stranger's PR from another epic.

## 9 — Two citation phantoms

`git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -c D416` = 0
(`grep -c D421` = 0 too; the ledger tops at D414). Both return 2 on #9857.
#9920's shipped comment cites "charter D383/D409/D421" — D421 does not exist on
main. If #9857 lands after #9920 the citation is dangling in between.

## 10 — One more open PR touches the console

#6028 (OPEN, `mergeStateStatus: DIRTY`, last pushed 2026-07-31) edits app.js
(hunks 4557/5436/5470/5586/12089/18312 on its own stale base) and
`__app.test.mjs` at 3574 — NOT at EOF. It is 22k+ commits behind and cannot
merge without a rebase, so it is a latent, not an active, collision.
