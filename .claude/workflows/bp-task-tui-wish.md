# Epic wish — the Barkpark portrait task TUI

**User's wish (2026-07-03, verbatim spirit):** "Create the best portrait task interactive TUI for Barkpark tasks. It should be connected with your relevant repo. It should be very incredible — we see it's organized well in epics, currently active, latest updated on top. We want ONE simple view — not many toggles — but that view should be fantastic and work very automatically, helping the user understand what's going on. This is a very important goal — loop until perfection."

## The shape

A **tall, narrow, always-glanceable** live pane — the user runs it in a portrait tmux/terminal split beside their editor (reference screenshot: a ~half-width, full-height column). Think `lazygit`-grade polish applied to the task queue: one view you leave open all day that tells you, without touching it, *what is going on*.

## Non-negotiables (from the wish)

1. **ONE view.** No tab bar, no mode maze, no settings screen. The single view is the product. Interactivity = navigate, expand/collapse, act on a task — not reconfigure.
2. **Very automatic.** Live-updating (poll or SSE against the configured server), self-organizing, zero setup. Open it and it's already right.
3. **Organized by epics** — tasks group under their goal/parent (`parent_id` trees, `proj:*`/`phase:*` labels). Epics are the spine of the layout.
4. **Currently active surfaces to the top** — claimed/in-progress work (claim.worker set, unexpired) is the "NOW" band, always visible.
5. **Latest-updated first** — within groups, recency ordering (updated_at). The freshest movement is where the eye lands.
6. **Repo-aware.** Running inside a git repo, it connects to that repo's configured Barkpark (`~/.config/barkpark/` context, same resolution as `bp`) and can correlate: task ↔ recent commits/PRs mentioning it, ledger activity. The TUI knows *which* Barkpark and which work matters here.
7. **Helps understanding, not just listing:** claim state + worker + age at a glance; acceptance-criteria progress (met/total); dependency/blocked indicators; child counts on goals; event/activity hints (recently closed flashes into view briefly). Color = semantic status (same status-role vocabulary as the cloud SPA / CLI tables — ok/info/warn/danger).

## Existing substrate (build WITH it, verify against the tree)

- Go TUI + `bp` CLI are ONE binary (repo root + `internal/cli/`), manifest-driven from `GET /v1/capabilities`. The TUI card: `docs/cards/tui.md`; task system: `docs/setup/TASK-SYSTEM.md`.
- Task API: `/v1/tasks` (ready/claim/close/prime, docs carry children + child_count, claim epochs, acceptance_criteria, labels, priority, parent_id). `bp task prime` is the one-call rehydration primitive — likely the TUI's ideal poll endpoint (counts + in-progress + ready head + recent events in one call). Verify payload coverage; if the TUI needs a richer single call (e.g. full epic trees + recent events), a small server-side addition is in scope.
- CLI status-role coloring work exists/planned (cloud epic decision 12, `table.go` seam) — share the vocabulary, don't fork it.
- Bubble Tea/lipgloss (or whatever the existing TUI uses — verify) is the rendering substrate; match the existing TUI's stack, don't introduce a second framework.

## The bar

- Kinsta/Vercel-grade visual polish in a terminal: intentional typography/spacing, truncation that never garbles, smooth resize, dark-terminal-first contrast, graceful narrow widths (portrait = ~60–100 cols wide, 100+ rows tall — the layout is designed FOR that, not adapted to it).
- Instant: no visible loading jank; optimistic updates on actions; offline/unreachable server renders an honest degraded state, never a crash.
- Keyboard: arrows/jk navigate, enter expands a task (detail inline, not a new screen), a small set of act verbs (claim/close/open-in-studio) discoverable via a one-line footer hint. No toggle farm.
- Tested: pure layout/grouping/sort logic unit-tested; golden renders for the view at 2–3 widths; the same discipline as the rest of the repo (no vacuous green).

## Scale directive

Very important goal. Loop wave after wave until perfection — strategists think BOLDLY about what "the best portrait task TUI ever" means (they run on Fable, per user direction, and should be used heavily); the architect owns a dedicated charter at `.claude/workflows/bp-task-tui-epic-charter.md`; builders/perfecters iterate until the direction agent judges it at the bar.
