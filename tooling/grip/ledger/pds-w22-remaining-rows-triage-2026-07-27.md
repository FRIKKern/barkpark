<!-- doc-tier: cold | canonical-for: pds-wave-22-remaining-rows-triage-rederivation | budget: 4000tok -->

# PDS wave 22 — remaining-rows triage re-derivation

Ledger-only slice `pds-w22-triage-remaining-rows`. Durable record of the counts, the method,
and the two corrections this slice made against its own brief. The dispositions themselves live
on the Barkpark ledger, not here.

## Counts, each at its own named instant

Method (charter PDS-D297), applied identically to both samples: the transitive `parent_id`
closure from `task-2ac1f95237c4a8e5` with the root excluded, INTERSECTED with an offset-walked
ready pool, UNION the `pds-w10-climb-in-the-post-deploy-window` subtree closure. Never an
id-prefix lens; never a subtraction from the other sample.

| Instant | ls docs | ready pool | descendants | closure∩ready | orphan∩ready | IN SCOPE |
|---|---|---|---|---|---|---|
| `2026-07-27T19:15:04Z` (before) | 3353 | 831 | 246 | 138 | 7 | **145** |
| `2026-07-27T21:31:05Z` (after) | — | — | — | 123 | 4 | **123** |

The before-count validates PDS-D297's 136 from an independent sample 56 minutes later:
145 minus the 9 rows this wave itself filed at ≥ `18:50` = **136 exactly**.

After the re-parent, `pds-w10-climb-in-the-post-deploy-window` is reached by the closure walk,
so the orphan term stops adding rows and the two lenses agree without a special case.

## Delta: 33 gone, 11 added, net −22

- **26 gone are this slice's**: 3 CLOSED, 23 PARKED.
- **7 gone are the partner slice's**: `pds-bl-harness-pgrep-wrong-process` and
  `pds-bl-templates-deploy-noop` closed by content on `58d1bd3a5` / `b2a92e3bc`, plus 5
  crown-blocked parks.
- **11 added**: 2 triage slices, 5 build slices, 4 defect rows filed during the wave.
- `EXPECTED-GONE-BUT-STILL-PRESENT: 0`. `UNEXPECTED-GONE: 7`, all attributed above.

This is **not** 33 defects fixed. 23 are parks carrying reactivation triggers, 3 are
dedup/refutation closes whose underlying defect survives on a named successor. The 55 rows left
OPEN are the honest residue.

## Two corrections made against the brief, by content

**The dead-path rows do not self-dispose.** `git ls-tree origin/main` confirms
`api/lib/barkpark/tag_registry.ex` is ABSENT (the live file is
`api/lib/barkpark/content/tag_registry.ex`). But in both citing rows that path appears only
inside an evidence object's `source` field — never as the defect's location. One row's defect is
still live on main (`scripts/pds-pull-proof.sh:2013` carries the falsified `tag` comment) and
was kept OPEN; the other was re-verified at the moved path (`register_attrs!/2` is a PRESENCE
test with no validity check) and PARKED as a chartered design question.

**The scratch-pointer fix commits are not on main.** The brief cited `09875840d` + `970c21527`;
`git merge-base --is-ancestor` returns non-zero for both. The reachable carrier is the merge
`c222a8739` (#4687). `git log --oneline --full-history -S'canonicalize_path' origin/main --
scripts/pds-scratch-target.sh` returns `c222a8739` plus `b5299fcb6` — the second-root-commit
graft PDS-D299 warns about, which default history-simplification would have hidden.

## The re-read caught a live defect (PDS-D298 earning its keep)

`bp task stage` reports success and lands `lifecycle_status: considering`, but
`content.engagement` — holder, note, object, ts — is silently dropped afterwards. The lifecycle
flip persists; the reason does not. Two rows were individually verified present and then went
empty with no intervening write (four reads 8 s apart, ruling out read lag).

Convergence required a re-read/rewrite loop, and the shape is the evidence:

```
round 0: 2   round 1: 6   round 2: 6   round 3: 9   round 4: 2   round 5: 0  → CONVERGED
(second pass, after 2 more evaporated)  round 0: 2   round 1: 0  → CONVERGED
```

A wave trusting its exit codes would have reported 24 parks and shipped ~20 with no reason at
all — exactly the Truth-Grip wave-10 outcome PDS-D298 exists to prevent, here reproduced live
rather than inferred. Filed as `pds-bl-stage-note-evaporates`; the partner independently filed
`pds-bl-park-note-evaporates` for the same defect, which the lead should collapse to one row.

## Also reproduced live

`pds-bl-large-task-write-500`: a single ~6 KB `bp doc patch` returned HTTP 500 `internal_error`
(`request_id GMY7xsB1DZQhcFQAIYTh`); the identical content split into three sub-5 KB patches
succeeded first try each. The same ceiling later refused a criterion stamp until its evidence
was trimmed.
