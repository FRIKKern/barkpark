# cch-w7 verify — KNOWN_DEFECTS freeze (executed, not read)

Tree: detached worktree at `origin/main` = `f38c01920985f6fc1581229dacb713345e4783a5`, clean.
(The primary checkout was **0 ahead / 13 behind** (`git rev-list --count HEAD..origin/main`) at
measurement time — every number below is
re-derived at `origin/main`, never at the primary checkout.)

## R1 — the four merge SHAs (charter standing law 1: merge SHA, never branch SHA)

```
for n in 5305 5308 5377 5378; do gh pr view $n --json number,title,state,mergeCommit,mergedAt; done
```
Expect all four `MERGED` with:

| vision divergence | PR | merge SHA | anchor introduced BY that commit |
|---|---|---|---|
| session came from `172.18.0.1` | #5305 | `8fd00b6afb1eca55d3c991f7921ed6ec2b7d77b4` | `router.ex` `defp trusted_peer?/1` |
| 40 requests are 5 | #5308 | `481d6f2319ecf630c10cd229df5006e692a51105` | `app.js` `var OVERVIEW_FLEET` (now `:4986`) |
| a bearer token is part of a URL | #5377 | `d157d098c78bc6604d00d84e22d038bdb176ef58` | `accounts.ex` SSE ticket mint/`consume_sse_ticket` |
| HEAD prober gets a session token | #5378 | `26acc7a91be0f0352efdb3e89b2017accb786367` | `router.ex` `refuse_head_on_side_effecting_gets` |

```
for s in 8fd00b6af 481d6f231 d157d098c 26acc7a91; do git merge-base --is-ancestor $s origin/main && echo "$s ANCESTOR"; done
git show 481d6f231 -- cloud/priv/static/app.js | grep -c "^+.*OVERVIEW_FLEET"    # expect >= 1
```
The `-r` review PRs squash the WHOLE branch: each PR title is a review-fix sentence, but the diff
carries the slice. Reading the title alone (e.g. #5308 "clear the Overview snapshot on sign-out")
under-reports what landed — check the diff, not the subject.

## R2 — the measurements that exist, per divergence

```
cd cloud && CC=clang mix test test/barkpark_cloud/web/router_test.exs                  # 164 tests, 0 failures
cd cloud && CC=clang mix test test/barkpark_cloud/web/router_sse_ticket_test.exs \
  test/barkpark_cloud/web/router_head_and_favicon_test.exs \
  test/barkpark_cloud/web/router_oauth_test.exs \
  test/barkpark_cloud/web/router_head_fence_census_test.exs \
  test/barkpark_cloud/web/router_sse_ticket_head_burn_test.exs                         # 50 tests, 0 failures
node --test cloud/priv/static/__app.test.mjs                                           # 714 tests, 0 failures
node --test --test-name-pattern="cost 12 requests" cloud/priv/static/__app.test.mjs    # 1 test, 0 failures
node design/emit-fence.test.mjs                                                        # exit 0
node cloud/priv/static/__preview__/cssom-parity.mjs                                    # PARITY PASS 1235/1235 MISSES 0
node cloud/priv/static/__preview__/seal-predicate.test.mjs                             # 11 tests, 0 failures
```
Peer-IP/SSE/HEAD are measured ONLY by ExUnit (`cloud.yml` job `test`). Refetch-storm and the
CSS-check divergence are measured by node (`console-harness.yml:59`, `doc-gates.yml:380`).
Rate-limiter bucket separation is measured by NOTHING: the only assertions are `router_test.exs`
`describe "front door: real client IP behind the Caddy loopback front"` (`:2212-2310`), which pin
`conn.remote_ip`, never a limiter key. `grep -rn peer_ip cloud/test` returns exactly one hit — a
COMMENT (`router_test.exs:2215`).

## R3 — `guard:` cannot express an ExUnit measurement (mutation-proven)

`seal-predicate.mjs:280` spawns `node <REPO>/<guard> --defect <id>` (timeout 300000). Point `guard`
at a shell script that exits 0 and the predicate reports a DEFECT:

```
cp -R cloud/priv/static/__preview__ $S/pv
# in the copy, replace KNOWN_DEFECTS with one entry: guard: 'guards/exunit.sh', commit '8fd00b6af'
printf '#!/bin/sh\nexit 0\n' > $S/repo/guards/exunit.sh && chmod +x $S/repo/guards/exunit.sh
node $S/pv/seal-predicate.mjs --ledger $S/repo/fixtures/seal-predicate/sealable.json --repo $S/repo
```
Expect exit 1 and `guard exited 1 — the defect is still measurable at origin/main`.

## R4 — a guard REFUSAL is laundered into a defect claim (already filed elsewhere)

```
node cloud/priv/static/__preview__/seal-predicate.mjs \
  --ledger cloud/priv/static/__preview__/fixtures/seal-predicate/sealable.json --repo . --guard-cmd 'exit 2'
```
Expect exit 1 and three × `guard exited 2 — the defect is still measurable at origin/main`, even
though `overflow-guard.mjs:66-68` documents exit 2 as "GUARD refused before measuring".
Prior art: `hg-overflow-guard-refusal-exits-1` (OPEN, priority 4, unclaimed, Honest-Gates epic) owns
exactly this; its criterion 2 is gated on "do not touch seal-predicate.mjs until the cloud-gui-remake
epic has taken its terminal verdict" — that verdict was taken 2026-07-21.

## R5 — test 4's emptiness sentinel goes vacuous on retarget

`seal-predicate.test.mjs:100` asserts `doesNotMatch(mutated, /GR108-tablet-topbar-overflow/)`.
Retarget the register to any non-GR108 entry and re-run the suite:

```
node $S/pv/seal-predicate.test.mjs    # 11 tests, 0 failures — including "defect 4"
```
The core assertion (an emptied register must refuse) still fires; the *sanity guard on the mutation*
becomes vacuously true. Derive the sentinel id from the register instead of hardcoding it.
