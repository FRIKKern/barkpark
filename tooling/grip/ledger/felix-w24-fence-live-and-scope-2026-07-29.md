# Re-derivation: Felix wave 24 — fence liveness, PR #6551 / #6057 scope, PDS ownership

Measured 2026-07-29 against live GitHub, the live Barkpark server, and `origin/main` @ `606fefd157112056e3560cb123c6c590139d6338`.

## PR #6551 — ALIVE but STALLED and UNOWNED

```sh
gh pr view 6551 --json state,isDraft,mergeable,mergeStateStatus,reviewDecision,updatedAt \
  -q '{s:.state,d:.isDraft,m:.mergeable,ms:.mergeStateStatus,r:.reviewDecision,u:.updatedAt}'
# -> {"d":false,"m":"MERGEABLE","ms":"UNSTABLE","r":"","s":"OPEN","u":"2026-07-28T15:12:51Z"}

gh pr view 6551 --json reviews,reviewRequests,author -q '{author:.author.login,nrev:(.reviews|length),reqs:[.reviewRequests[]?.login]}'
# -> {"author":"FRIKKern","nrev":0,"reqs":[]}

gh pr view 6551 --json statusCheckRollup -q '.statusCheckRollup[]|"\(.conclusion // .state) \(.name // .context)"' | sort
# -> FAILURE Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)
# -> FAILURE Doc budgets + anchors
# -> FAILURE Format (mix format --check-formatted, advisory) (27.0, 1.18.1)
# -> SUCCESS Elixir gate / Test (Elixir 1.18.1 / OTP 27.0)

git fetch origin -q
git rev-list --left-right --count origin/main...origin/loop-epic/bounded-import-spill-the-body-extract-to-3-r
# -> 27	7      (still 27 behind; NOT rebased)
```

Owning task claim is LAPSED (worker `null`, expired 2026-07-28T15:58Z):

```sh
bp task ls --all -o json | python3 -c "import json,sys;[print(t['doc_id'],t['lifecycle_status'],t['claim']) for t in json.load(sys.stdin)['docs'] if t.get('doc_id')=='pds-bl-bounded-import-unpack']"
```

## The +42 displacement SURVIVES (no rebase)

```sh
for r in origin/main 340204e5d 2053319d3; do git show $r:api/lib/barkpark/tenancy/workspace_bundle.ex | grep -n sobelow_skip; done
# origin/main    : 221 408 434 452 473 913
# merge-base     : 221 408 434 452 473 913   (workspace_bundle.ex unchanged on main since the base)
# PR head        : 221 450 476 494 515 955   (+42 uniform on all five; 221 unmoved)
```

## PR #6057 — CONFLICTING, and it is NOT a #6616 revert; it is a 31-row baseline DELETION

```sh
gh pr view 6057 --json state,mergeable,mergeStateStatus,updatedAt
# -> {"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN","updatedAt":"2026-07-28T12:37:54Z"}
# single commit f3eeab0ea, 2026-07-24 — predates #6616 (merged 2026-07-28T11:40Z)
# touches ONE file: api/.sobelow-skips (76+ / 54-)

git fetch origin chore/sobelow-baseline-reconcile-2026-07-24 -q
git show origin/main:api/.sobelow-skips | cut -d, -f3 | sort -u > /tmp/hm.txt
git show FETCH_HEAD:api/.sobelow-skips  | cut -d, -f3 | sort -u > /tmp/h2.txt
comm -23 /tmp/hm.txt /tmp/h2.txt | wc -l     # -> 31  main-only fingerprints LOST if 6057's file wins
git show 27352d8c1 --format="" -- api/.sobelow-skips | grep '^-' | grep -v '^---' | cut -d, -f3 | sort -u > /tmp/h1.txt
comm -12 /tmp/h1.txt /tmp/h2.txt             # -> CD9C35 only (1 of 19)
git show FETCH_HEAD:api/.sobelow-skips | grep -c blobstore   # -> 0  (does NOT green the blobstore 15)
```

## The comment-only cross-fence PRECEDENT EXISTS — commit c69cc0b1e (#6412), 2026-07-28

```sh
git show c69cc0b1e --stat --format="%s"
# fix(security): sobelow baseline stops swallowing its own inline waivers (#6412)
#  api/lib/barkpark/tenancy/workspace_bundle.ex | 20 +-
git show c69cc0b1e -- api/lib/barkpark/tenancy/workspace_bundle.ex | grep -E '^[+-]' | grep -v '^[+-][+-]'
# -> comment lines ONLY (qi/1 waiver reworded); commit message: "Comment only — no behaviour change."
git merge-base --is-ancestor c69cc0b1e 340204e5d && echo YES   # -> YES (already in #6551's base)
```

## D82 fence text (charter :913-921, origin/main)

```sh
git show origin/main:.claude/workflows/bp-felix-pristine-charter.md | sed -n '913,921p'
# "FENCE this thread: `api/lib/barkpark` (CMS core) + `api/test` ONLY
#  — strictly OFF `api/lib/barkpark_web/live/studio` (console-hardening), `tooling/grip/` (truth-grip),
#  `scripts/pds-*` + `tenancy/workspace_bundle` (PDS crown), `cloud/`, and the standing chat-tui /
#  structure fences."
```

## Branch protection IS live (the ledger row of 2026-07-28 is now stale)

```sh
gh api repos/FRIKKern/barkpark/branches/main/protection \
  -q '{contexts:.required_status_checks.contexts, strict:.required_status_checks.strict, enforce_admins:.enforce_admins.enabled}'
# -> {"contexts":["Elixir gate","PR references an active task"],"enforce_admins":true,"strict":false}
# Sobelow is NOT a required context.
```
