# Wave 26 — the seal gauge's two holes, re-derived (2026-08-09)

Ground: `origin/main @ 0239dd4ee`, read from a **fresh detached worktree**, never the primary
checkout (which was **717 commits behind** when this was written — `git rev-list --count HEAD..origin/main`
= 717 — and whose copy of `seal-predicate.mjs` was 572 lines against main's 1437. Every number
below is worthless if taken from a stale tree; that is the first re-derivation step, not a footnote).

```bash
SP=$(mktemp -d)
git -C /Volumes/SATECHI/github/barkpark fetch origin -q
git -C /Volumes/SATECHI/github/barkpark worktree add --detach "$SP/w26main" origin/main
cd "$SP/w26main" && git rev-parse HEAD          # must print 0239dd4ee662dd30c4d8da0c6b9a149638224b1d
wc -l < cloud/priv/static/__preview__/seal-predicate.mjs   # 1437 on main
```

## 1. The honest wave-26 no-seal token

```bash
node cloud/priv/static/__preview__/seal-predicate.mjs \
  --epic task-fb4fb869490b4213 --successor am-bl-idle-p95-anomaly; echo "EXIT=$?"
```

```
SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=69 considering=0
  successor=am-bl-idle-p95-anomaly epic=task-fb4fb869490b4213 mode=live
  stubbed=0 waived=0 roster=147 repo=<worktree> head=0239dd4ee      [exit 1]
```

**D444's caveat sentence is mandatory on every citation:** `b=PASS` and `c=PASS` are scored off
**Cloud Console Hardening's** flat registers, not off deploy-reliability. `--epic` parameterizes
clause (a) ONLY; the run prints its own tell — all three gates come back
`parent=cloud-console-hardening-epic in-epic-roster=false` and pass anyway.

**Depth caveat, re-derived today:** the residue is **69 direct plus 332 one level below that
clause (a) structurally cannot see** (draft-subtracted: the `production` perspective returned
`_draft:true` = 0 and `drafts.`-prefixed ids = 0 across all 5,757 task documents, so 332 needs no
subtraction). Of those 332, **330** hang off `dr-backlog-never-started` (itself orphan #1, so its
existence is counted once while its 330 children are not) and **2** hang off gen-1 rows that are
already `done` — `task-1b20109435e5bd19` under `dr-w9-s5-the-beat-dates-its-own-producer` and
`task-973918c0fc635953` under `dr-w9-s3-deployments-table-carries-its-cause`. Those two are live,
published, non-draft rows the gauge is blind to **today, with no filing act required.**

Re-derive the depth number (the `in [...]` operator SILENTLY RETURNS EMPTY on this endpoint —
`filter=parent_id in ["task-fb4fb869490b4213"]` returns `count:0` where `==` returns 147 — so page
the whole type and walk the tree client-side; never trust an `in` filter here):

```bash
for off in 0 1000 2000 3000 4000 5000; do
  curl -sG https://guerrilla.barkpark.cloud/v1/data/query/production/task \
    --data-urlencode 'limit=1000' --data-urlencode "offset=$off" \
    -H 'Authorization: Bearer undefined' -o "page_$off.json"; done
# then: gen1 = docs where parent_id == task-fb4fb869490b4213 (147)
#       gen2 = docs whose parent_id is any gen1 _id            (332, all lifecycle_status=open)
```

## 2. HOLE A — SEAL by a filing act (mutation-proved, fixtures only)

`fetchRoster` (`cloud/priv/static/__preview__/seal-predicate.mjs:427-435`) is a single
`filter[parent_id]` query called exactly twice. Clause (a) is **exactly one level deep**.

Build a fixture that models ONE filing act — the 69 open direct children REPARENTED under an
already-`done` sibling, nothing finished — so `children` is the 78 done/cancelled rows:

```bash
node cloud/priv/static/__preview__/seal-predicate.mjs \
  --epic task-fb4fb869490b4213 --ledger <fixture>.json --repo .; echo "EXIT=$?"
```

```
roster: 78 children  {"cancelled":6,"done":72}
CLAUSE (a) forwarding — residue 0 (live 0, considering 0)
  UNNAMED RESIDUE (orphans) : 0
VERDICT: SEAL
  Sealed 78 children of task-fb4fb869490b4213: 72 evidence-closed, 0 forwarded by name
VERDICT-TOKEN: SEAL-PREDICATE SEAL a=PASS b=PASS c=PASS orphans=0 considering=0
  successor=am-bl-idle-p95-anomaly epic=task-fb4fb869490b4213 mode=fixture
  stubbed=0 waived=0 roster=78 repo=. head=NOT-READ                 [exit 0]
```

`stubbed=0 waived=0` — clause (b) ran the real committed guards; nothing was faked to reach the
green. The only honest marker on that line is `mode=fixture`, and a LIVE reparent would print the
identical numbers with `mode=live`. **The two already-hidden live rows above are the live half of
this proof: no fixture is needed to show the gauge is blind, only to show how far.**

## 3. HOLE B — `--ladder-only` accepts an epic that does not exist

```bash
node cloud/priv/static/__preview__/seal-predicate.mjs --epic totally-fake-epic-xyz --ladder-only
echo "EXIT=$?"   # 0
```

```
VERDICT-TOKEN: SEAL-PREDICATE LADDER-ONLY b-rungs=rung1:2,rung2:4,rung3:0 b-clean=6/6
  b-unavailable=0/6 a=NOT-READ c=NOT-READ epic=totally-fake-epic-xyz mode=live
  repo=<worktree> head=0239dd4ee                                    [exit 0]
```

**Half-refuted, and the surviving half is sharper than "it greens".** The path cannot be quoted as
a seal — it prints `a=NOT-READ c=NOT-READ` and five numbered paragraphs of WHAT THIS READING IS NOT.
What it does do is **attribute six Cloud Console Hardening defects to an epic label it never
resolved.** `KNOWN_DEFECTS` is epic-independent, so `--epic task-fb4fb869490b4213 --ladder-only`
prints `b-clean=6/6` for deploy-reliability out of another epic's register. The defect is the
LABEL, not the exit code.

**Not reproducible on a stale tree:** the primary checkout's 572-line copy has no `--ladder-only`
at all (`grep -c -- 'ladder-only'` = 0), silently ignores the unknown flag, and REFUSES at
`NO-SUCCESSOR` exit 1. A run of hole B that reports exit 1 was run against the wrong bytes.

## 4. Fence

No fix is written here. `cloud/priv/static/__preview__/*` is ceded to Cloud Console Hardening by
**D402**, and the owning row already exists: **`dr-w25-bl-seal-clause-a-is-one-level-deep`**
(open, priority 1, parent `dr-backlog-never-started`, GitHub issue 10979), whose acceptance
criterion 2 is exactly the mutation above and whose criterion 3 asks for this dispensation record.
Its brief quotes 57 + 319 = 376; today's re-derivation is **69 + 332 = 401**. Update the row, do
not re-file it. (The row is itself one of the 332 the gauge cannot see.)
