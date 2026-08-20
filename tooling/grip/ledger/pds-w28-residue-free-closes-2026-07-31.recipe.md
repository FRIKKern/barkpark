# pds-w28-residue-free-closes — re-derivation recipe (2026-07-31)

Verifier lane `residue-free-closes`, PDS wave 28. Every row below is a
predicate: it exits 0 while the stated fact holds and nonzero when it stops.
No stored values except where a value is quoted as REFUTED.

## R1 — PR #8412 is MERGED, not OPEN (digest premise REFUTED)

    gh pr view 8412 --json state -q .state            # => MERGED
    git merge-base --is-ancestor \
      $(gh pr view 8412 --json mergeCommit -q .mergeCommit.oid) origin/main

Level: L2 (gh api + git ancestry against origin/main).

## R2 — render_brief DOES carry disposition at origin/main (digest premise REFUTED)

    git show origin/main:api/lib/barkpark_web/controllers/tasks_controller/params.ex \
      | grep -q 'put_brief_disposition(content)'

Anchored on the TOKEN, not the line number. `render_doc(%Document{}, :brief)`
pipes through `put_brief_disposition/2`; `render_brief/2` delegates to it.
Level: L2.

## R3 — the wave-27 certification record is ABSENT (HOLDS)

    ! git ls-tree --name-only origin/main tooling/grip/ledger/ | grep -qi certif

Twelve `w27`-named siblings are present; no certification record among them.
`pds-w27-certify-the-round` is 0/9, lifecycle open, no disposition.
Level: L2 for the tree half, L1 for the task half (`bp task get`).

## R4 — docs/api-v1.md headroom is 116 B, NOT 2 or 3 (REFUTED, and the
##      naive re-run of the gate reproduces the STALE number)

    d=$(mktemp -d) && git archive origin/main | tar -x -C "$d" \
      && (cd "$d" && bash scripts/check-doc-budgets.sh | grep api-v1)
    # => ok:   docs/api-v1.md 13884B <= 14000B

Running `bash scripts/check-doc-budgets.sh` in the primary checkout prints
`13997B` — that is the LOCAL checkout (behind origin/main), not main.
Commit 662697194 "Keep API error guide within budget" (2026-07-31 03:34:50
+0200, ancestor of origin/main) removed 113 B. Both
`pds-bl-dedup-unavailable-error-code`'s disposition_reason ("13,998 bytes …
2 bytes of headroom, re-measured today") and
`pds-w25-backlog-api-v1-relocation`'s description ("13,998 B … 2 bytes") are
stale by that commit. The PARK still HOLDS in substance: the dedup row needs
390 B of doc lines and 116 B < 390 B.

Level: L2. This is the wave's live specimen of a measurement-citing reason
that was true when written and is false today.

## R5 — queue.ex has NO publication predicate (HOLDS)

    test 0 -eq "$(git show origin/main:api/lib/barkpark/tasks/queue.ex \
      | sed -n '/^    base =/,/executable_query/p' | grep -c 'd.status')"

The base candidate filter is exactly: `d.type == "task"`,
`content->>'kind' == "task"`, `content->>'lifecycle_status' IN
@ready_lifecycle_statuses`, `QueueGate.executable_query()`. No `d.status`,
no `drafts.` exclusion anywhere in the module.

## R6 — the drafts count in that row's evidence has DRIFTED 28 -> 30

    bp task ready --all -o json | grep -v '^bp:' \
      | python3 -c "import json,sys;r=json.load(sys.stdin)['docs'];\
print(len(r), sum(1 for x in r if x['doc_id'].startswith('drafts.')))"
    # => 1320 30   (2026-07-31)

Six of six sampled drafts rows have no published twin (`bp task get <bare-id>`
resolves to the `drafts.` row itself).

## R7 — today's census figures, from a clean origin/main tree

    d=$(mktemp -d) && git archive origin/main | tar -x -C "$d" \
      && (cd "$d" && bash scripts/pds-ledger-census.sh --json \
          --anchor-from-paper pds-wave-27-2026-07-31)
    # RC=0  live=190  live_adjudicated=172  reasons 213/213 distinct
    # live_bare=[]  residue=18

Residue is 18 today, not the 19 the digest carried.
