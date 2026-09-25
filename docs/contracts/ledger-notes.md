<!-- doc-tier: agent | canonical-for: ledger-note-content | budget: 1000tok -->

# What a note on a task row may say

A note (`disposition_reason`, a close reason, a description addendum) records
**what happened and why**. It never restates the row's `lifecycle_status`,
`criteria_progress`, claim or assignee. Those four are read live from the row; a
note that copies them is a cache nobody invalidates, and it goes false the moment
someone works the row.

## Move and adoption notes

A move note names the **source parent, the destination, the date, the charter
clause, and the reason**. The source matters because the ledger may not keep it:
the S-4c rows checked carry no `task.reparented {from, to}` event, and the old
`parent_id` survives only in revision history (`bp doc history`, `bp doc revision`).

If rows were chosen by their state, cite the rule that chose them, not what it saw.

**Written:** *"Adopted by dr-backlog-never-started for ROSTER HEADROOM (charter
S-4c). This row is never-started (open, zero criteria met, no claim, no assignee, no
evidence), so moving it loses no work … Disposition stays OPEN."* By 2026-09-07
`dr-bl-graph-show-draft-leak` was 4/5 met with its fix merged, and the note still
invited a dispatcher to rebuild it.

**Write instead:**

> Moved 2026-08-08 from `task-fb4fb869490b4213` to `dr-backlog-never-started` under
> charter S-4c (D434): the epic's direct roster was 450 of the seal predicate's
> `ROSTER_PAGE_LIMIT` 500. Only `parent_id` changed; nothing was cancelled. Read
> the row for its progress, claim and assignee.

The adoption is still traceable to its clause and its reason, and it gains the
source parent the original omitted. The roster count describes the epic at the
time of the move, not this row, so it cannot go stale.

## Screening an epic's children

`bp task get <epic> -o json` lists every direct child under `.children` with
`doc_id`, `execution_class`, `inserted_at`, `lifecycle_status`, `title`,
`updated_at`, and `criteria_progress` when the row has criteria. That answers
status and progress with no per-row fetch. It has **no `claim` or `assignee`**.

`bp task ls --parent <epic> --all -o json` returns the same children as flat rows
with `claim`, `assignee`, `criteria_progress`, `lifecycle_status` and `content`
(including `disposition_reason`): all four fields and the note in one paged read.
Do not intersect with `bp task ready` instead. It caps at 1000 rows and lists only
ready rows, so it is a window, not the population.

A claim record survives close and release. A row is held only when `claim.worker`
is set and `claim.closed_at` and `claim.released_at` are both null.

## Sweeping for stale notes

Corrections keep the displaced text verbatim, so a keyword match also finds rows
that were already fixed. Exclude notes containing `CORRECTED BY`, `DISPLACED TEXT,
VERBATIM` or `SUPERSEDED`, and print the IDs, never only a count:

```bash
bp task ls --parent <epic> --all -o json | jq -r '.docs[]
  | (.content.disposition_reason // "") as $n
  | select($n | test("never-started|zero criteria met|no claim|no assignee"))
  | select($n | test("CORRECTED BY|DISPLACED TEXT, VERBATIM|SUPERSEDED") | not)
  | "\(.doc_id)\t\(.lifecycle_status)\t\(.criteria_progress.met // 0)/\(.criteria_progress.total // 0)"'
```

Control: `dr-bl-graph-show-draft-leak` carries a corrected note. It must be absent
from this output and present when the exclusion line is removed.
