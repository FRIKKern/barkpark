# Reminder — bring the `bp tasks` TUI toward the DETAILED direction (paper-led)

**Date:** 2026-07-04 · **Status:** deferred note, not scheduled work · **Owner topic:** task-tui epic

## What the user asked

Looking at the paper task-component design brief, the user chose the **richer** row (priority chip +
criteria progress bar + status + criteria fraction) over the TUI's subtracted "one glyph + one dim
token" row — and said, verbatim:

> "We want to see phases, tasks within tasks — blockers etc … We want to improve the TUI in that
> direction as well, just create a small paper as reminder for later — and lets continue building in
> this more detailed direction."

The attached image was the brief's **"WHAT WE SHIP NOW"** row (dot · `P1` chip · progress bar · `2/3`
· `DONE`) — i.e. the row I had critiqued as a subtraction violation. The user wants that density.

## The reconciliation (why this doesn't just revert wave 5)

The wave-5 **subtraction pivot** (charter D14, D22) was correct **for a glanceable, leave-open-all-day
portrait pane** — one glyph carries status, text stays monochrome-dim, chips/meters/deps move to the
detail frame. That philosophy still holds for the *board* surface.

But a **paper is a document, not a live pane** — it's read, not glanced. Density is a feature there:
phases, arbitrary-depth task nesting, blocker edges, priority, progress, assignee can all coexist
because the reader has arrived to *read*, not to keep half an eye on it all day. So the paper task
components lead in the detailed direction; the TUI is a **future retune**, not a same-wave change.

## What "detailed direction" means for the TUI (later)

When this is picked up (a future wave, after the paper components land and prove the vocabulary):

1. **Phases as first-class grouping** — beyond epics: a `phase:*` swimlane band with rollup, so a
   plan's structure (W0…W6) reads at a glance, not just parent trees.
2. **Tasks within tasks within tasks** — the board today flattens to root-epic + one child level
   (`rootOf`). The detailed direction wants a real expandable tree to arbitrary depth *in the board*,
   not only via descent into detail frames.
3. **Blockers as visible edges** — surface `blocked by N` / `blocks N` on the row itself (not only in
   detail), with the dependency relationship legible ("⊘ blocked by: <task title>").
4. **A richer row option** — a density mode where the row carries dot + title + priority + criteria
   progress + blocker badge + assignee (the paper `task-list` row, adapted to cells). Likely a
   per-surface choice, NOT a global toggle-farm: the board stays calm, a `plan`/`roadmap` view is
   the dense one.
5. **A roadmap/gantt view in the TUI** — phases + tasks + dependency arrows, mirroring the paper
   `roadmap` component (author-supplied dates, since the domain has no `due_at`).

## Guardrails (don't lose the good subtraction)

- **Color still means state, never decoration** — the one non-negotiable. Priority chips, blocker
  badges, progress fills all route through the `RoleFor` palette; labels stay dim monochrome.
- **Done still recedes** (dim, not green).
- **Honest truncation** (`… and N more`, `showing N of M`) everywhere.
- The calm board is NOT deleted — the dense view is an *additional* surface (`bp tasks plan`?), so the
  glanceable pane the 2026-07-03 wish demanded still exists.

## Cross-reference

- Paper components lead: `.claude/workflows/bp-aesthetic-unification-{epic-charter,wish}.md`,
  `internal/taskboard/` (the vocabulary source), the design brief artifact.
- This is a candidate wave for `bp-task-tui-epic-charter.md` — promote to a real task/paper there when
  scheduled. Keep it deferred until the paper components ship and the detailed vocabulary is proven.
