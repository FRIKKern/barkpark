# W17 verifier — slice eligibility, shared floors, collision pairs (2026-08-07)

Re-derivation recipes. Every row was RUN, not read.

## Setup (the primary checkout is 608 commits behind origin/main)

```
git -C /Volumes/SATECHI/github/barkpark rev-list --count HEAD..origin/main        # 608
git -C /Volumes/SATECHI/github/barkpark worktree add --detach <SCRATCH>/w47v-disp origin/main
cp -R /Volumes/SATECHI/github/barkpark/cloud/deps  <SCRATCH>/w47v-disp/cloud/deps
cp -R /Volumes/SATECHI/github/barkpark/cloud/_build <SCRATCH>/w47v-disp/cloud/_build
```

`cloud/test/barkpark_cloud/payload_key_set_census_test.exs` DOES NOT EXIST in the
primary checkout; it exists on origin/main. The MUST-RUN command fails there for
that reason alone.

## TRUE floors (measured, not quoted)

```
cd <SCRATCH>/w47v-disp/cloud && CC=/usr/bin/clang MIX_ENV=test mix test test/barkpark_cloud/payload_key_set_census_test.exs
# 12 tests, 0 failures
grep -n '@emitted_floor\|@go_tag_floor\|@barkpark_family_keys' test/barkpark_cloud/payload_key_set_census_test.exs
# @emitted_floor 108 / @go_tag_floor 221 / @barkpark_family_keys 56 / _blind 42
```

Actual populations, measured by re-hosting the test file's own Extract/Go modules
(lines 1-413 copied to a scratch .exs, driven by `mix run --no-start`):

```
TOTAL_EMITTED_ACTUAL=108      # == @emitted_floor, no slack
GO_TAG_UNION_ACTUAL=221       # == @go_tag_floor,  no slack
DeployCensus tags (16): cancelled,classes,deferred,delivery,failed,failure_rate,
  in_flight,live,live_rate,min_sample,not_attempted,residual,sites,
  terminal_failure_rate,volume,window
```

Both floors are `>=` assertions only — no equality assertion anywhere. So a
key-adding slice that forgets the bump is GREEN; the collision is a textual
merge conflict plus silent floor decay, not a red.

```
grep -n '@emitted_floor\|@go_tag_floor' test/barkpark_cloud/payload_key_set_census_test.exs   # all >=
```

Reachability floors:

```
grep -n '@publics_floor\|@call_sites_floor' test/barkpark_cloud/deploy_ledger_reachability_test.exs
# @publics_floor 16 / @call_sites_floor 14
```

## PR #10401 reds main — proved, and the named fix proved to work

```
git fetch origin pull/10401/head:refs/remotes/pr/10401 -f
git merge-base --is-ancestor origin/main refs/remotes/pr/10401   # false: PR is 19 behind
git merge-tree --write-tree origin/main refs/remotes/pr/10401    # rc=1, CONFLICT in payload_key_set_census_test.exs
# materialise the AUTO-MERGED router from that same merge-tree oid:
git show 05bd6d69c181583109a4d4699b456a71bb9757f7:cloud/lib/barkpark_cloud/web/router.ex > cloud/lib/barkpark_cloud/web/router.ex
cd cloud && CC=/usr/bin/clang MIX_ENV=test mix test test/barkpark_cloud/deploy_ledger_reachability_test.exs
# 10 tests, 3 failures — "no longer unreachable ...: delivery/3, refusal_phase/1"
# fix, in the same tree:
python3 -c "p='test/barkpark_cloud/deploy_ledger_reachability_test.exs';s=open(p).read();s=s.replace('{:delivery, 3, :unreachable,','{:delivery, 3, :reachable,').replace('{:refusal_phase, 1, :unreachable,','{:refusal_phase, 1, :reachable,');open(p,'w').write(s)"
CC=/usr/bin/clang MIX_ENV=test mix test test/barkpark_cloud/deploy_ledger_reachability_test.exs   # 10 tests, 0 failures
git checkout -- lib/barkpark_cloud/web/router.ex test/barkpark_cloud/deploy_ledger_reachability_test.exs
```

## dr-w16-s6 has an UNNAMED shared file: the census caller-arity assertion

`deploy_ledger_reachability_test.exs:619` is `assert [%{arity: 2}] = callers[{:census, 3}].external`
— a strict single-element match. A team-scoped route calling `census/3` with an
opts list is a SECOND external call site at arity 3, so it reds.

```
# in cloud/lib/barkpark_cloud/web/router.ex, after line 3544 add:
#   _probe = fn f, t, ids -> DeployLedger.census(f, t, site_ids: ids) end
cd cloud && CC=/usr/bin/clang MIX_ENV=test mix test test/barkpark_cloud/deploy_ledger_reachability_test.exs
# 10 tests, 1 failure — match (=) failed, right: [%{arity: 2, line: 3544}, %{arity: 3, line: 3546}]
git checkout -- lib/barkpark_cloud/web/router.ex
```

## Which slice CODE is on origin/main (not which task is closed)

```
git log --oneline origin/main --grep="names every state"          # 5187d2b2b (#10442)  -> dr-w16-s2 CODE LANDED
git grep -n "instance/site-deploy" origin/main -- api/lib/barkpark_web/router.ex   # :1632 -> dr-w15-s1 CODE LANDED
git grep -n "DeployLedger.delivery\|DeployLedger.refusal_phase" origin/main -- cloud/lib   # EMPTY -> dr-w15-s3 NOT landed
git grep -n "DeployLedger.census(" origin/main -- cloud/lib      # ONE caller, router.ex:3544, arity 2
git grep -n "LivePerAttempt" origin/main                          # 1 comment + 1 field, ZERO readers
```

## The first-match trap in the Go census helper

`internal/cli/cloud_deploy_census_cmd_test.go:406` `censusLineContaining` returns
the FIRST line containing the needle despite a docstring saying "the single
rendered line". Tests at :178 and :207 needle `"of 2216 attempted"`. A live-rate
line printed ABOVE the failure line carrying the same denominator phrase silently
retargets both assertions.

```
sed -n '403,415p' internal/cli/cloud_deploy_census_cmd_test.go
CC=/usr/bin/clang go test ./internal/cli/... -run 'DeployCensus|Deployments'   # ok, baseline green
```

## Task lifecycle snapshot (bp, 2026-08-07)

```
for t in dr-w16-s2-census-names-every-state dr-w16-s4-per-site-row-named-producer \
         dr-w16-s5-live-per-attempt-co-equal-headline dr-w16-s6-team-scoped-census-returns-200 \
         dr-w16-s7-boundary-and-continuity-gauge dr-w15-s1-instance-answers-can-i-deploy \
         dr-w15-s3-emit-the-two-corpses dr-w15-s5-capability-reaches-bp-cloud-status \
         dr-w15-s6-live-per-attempt-headline dr-w13-s7-census-residue-and-per-site-blindness; do
  bp task get $t -o json; done
```

`bp task get dr-w15-s1` (the short slug) returns `not_found` — the real id is
`dr-w15-s1-instance-answers-can-i-deploy`. A truncated slug is indistinguishable
from a missing task.
