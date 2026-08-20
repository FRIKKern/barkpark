# Task briefs drift from their descriptions by construction — measured 2026-08-20

Evidence for `task-039938a48b952aeb`. Data: `brief-purpose-drift-2026-08-20.json`.

## The generator, with a file:line

`ensureTaskPortableBrief`, `internal/cli/tasks_create_cmd.go`. It returns early
when a valid `brief` already exists and is reached only on the create paths, so
`brief.blocks[purpose-copy]` is a SNAPSHOT of `description` taken once at create
with **no update path anywhere**. A later `--set description=…`, `doc patch` or
raw mutate changes the description and never touches the brief.

The corruption is therefore invisible from the field everyone reads: the
description looks right while the brief a builder actually opens says something
else.

## Numbers

Of 6,866 published task docs, 4,408 carry a `purpose-copy` block:

| | count |
|---|---|
| EXACT (after normalisation) | 2,934 |
| CONTAINED (truncation / appended note) | 745 |
| **DIVERGENT** | **714** |
| empty purpose | 15 |

Divergent by shape:

| shape | total | open |
|---|---|---|
| purpose is literally `probe` / `placeholder` / `short` | 24 | 20 |
| auto-stub `"Complete the work described by …"` | 122 | 76 |
| real prose on both sides | 568 | **107** |

Of the 107 open rows, 70 are wholesale (similarity < 0.30) and **20 carry
gating/dependency language on one side only** — the actionable head, listed in
the JSON as `gating_language_on_one_side_only`.

## A SECOND drift surface, not previously counted

The same function also composes `brief.blocks[criteria-list]` from
`acceptance_criteria` at create time, with the same early return and the same
absence of an update path. Measured the same way: of 1,759 docs carrying both,
1,615 match, **94 disagree on COUNT** and **50 on TEXT**.

`dr-w13-s6-publish-clock-first-caller` is the sharpest row on the board and
fails BOTH ways at once: its brief lists **9** criteria where the task has
**15**, and its brief says `AFTER dr-w13-s3 … MERGES. Round 2` while its
description says `ROUND 1 — dependency-free, builds NOW. Its dependency
dr-w13-s3 MERGED as #10301`. A builder reading that brief waits for a merged
dependency and then works to two-thirds of the criteria.

**A remedy that re-derives only the purpose leaves this half open.**

## Direction, established by content and not only by the mechanism

Briefs carry the ORIGINAL framing while descriptions carry the later state:

* `hgw2-s4-format-ceiling-reland` — brief `AFTER hgw2-s1-elixir-skip-shim MERGES`; description `DEFERRED BY WAVE 4 WITH ITS REASONS RECORDED (charter D69)`.
* `task-2c6e0fff8a8a63c9` — brief `FILED BY THE WAVE 41 BUILDER`; description `DISCHARGED BY pds-w42-liveview-authorization-column`.

## Two warnings for whoever re-runs this

Both are mistakes this sweep made before it produced a usable number.

1. **Normalise markdown, or every formatted description reads as a divergence.**
   `ensureTaskPortableBrief` strips exactly `**`, `__` and backticks when
   composing the brief, so a description carrying them will differ forever, by
   design. A first cut without this reported 108 suspects out of 300 — all
   false. (This sweep's normaliser is slightly MORE aggressive than the Go
   source: it also strips single `*`/`_` and markdown links. That can only
   move rows from DIVERGENT to EXACT, so the 714 is a floor, not a ceiling.)

2. **Match `id == "purpose-copy"` with NO fallback.** 2,458 docs carry no such
   block. A "first paragraph with content" fallback picks up a stray paragraph
   from a differently-shaped brief — one held a lone `\x01` byte — and
   manufactured 794 suspects. The tell was the shape classifier reporting zero
   EMPTY rows while empty rows printed: an instrument that can disagree with
   itself is one you can catch.
