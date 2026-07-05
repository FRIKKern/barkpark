# Epic wish — the Barkpark portrait task TUI

## AMENDMENT (2026-07-04) — the REAL upgrade: simple, beautiful, deep

**User's wish (2026-07-04, verbatim):** "We need to do a real upgrade to our task system — it
need to be a lot more simple and beautiful, also it should be able to open tasks and see the
task, and also be able to read paper related to it and see the tasks it contains, tasks within
tasks within tasks — learn from Doey — we have it on this computer — also you are using an even
stronger model than Doey did, so do smart decisions along the way that might matter — but
really — we need a large upgrade to our bp tasks tui."

The user attached a screenshot of **Doey's two-pane task UI** (left: sectioned task list with
2-line cards; right: a full DETAIL pane — title, status·team·priority·type meta line, hybrid
timestamps, status timeline `○ created → ● done`, Origin quote, Decisions log, Proof of
Completion with AI-verification prose and files-changed) as the exemplar. The read-only study
of Doey is already distilled at `.claude/workflows/doey-ui-lessons.md` (path:line citations
into /Volumes/SATECHI/github/doey) — strategists/architect MUST read it; go back to the Doey
source when a lesson needs more depth.

What this amendment means, concretely (waves 1–4 shipped the live board; this is the pivot):

1. **A LOT more simple and beautiful.** Waves 3–4 accreted density (chips, clusters, twins,
   heartbeat verbs, flashes). The user is telling us the pane got busy. Subtract before adding:
   fewer glyph vocabularies, more whitespace/rhythm, calmer color (color = state only —
   Doey's discipline: one glyph carries status, text stays monochrome-dim). Every existing
   feature must re-justify its pixels; folding/removing is a first-class outcome.
2. **Open a task and SEE it.** A real full detail view, Doey-DETAIL-grade: title, meta line,
   hybrid timestamps (`2h ago (Jul 04, 15:12)`), status timeline, full description/origin
   rendered as markdown, decisions/activity, acceptance-criteria checklist, claim/worker
   history. Not the current few-line inline expand — a place where you can actually READ the
   task.
3. **Follow the task to its Paper.** Tasks link to Barkpark Papers (design docs). From a
   task's detail, open the related paper and READ it in the TUI — `internal/pdrender` already
   renders PortableDoc for the terminal; reuse it, never fork a second renderer. Verify how
   task↔paper linkage is expressed today (references? labels? body links?); if the link isn't
   queryable, a small API/SDK addition is in scope for this epic.
4. **Tasks within tasks within tasks.** Arbitrary-depth drill-down: a paper shows the tasks it
   drives; a task shows its children; children have children. Navigation is a stack —
   enter descends (task → detail → paper → its tasks → …), esc/backspace ascends, and you
   always know where you are (breadcrumb). The board is level 0 of the same stack, not a
   separate app.
5. **Layout: learn from Doey, adapt to the terminal we're in.** Doey is two-pane
   (list + detail). The portrait constraint from 2026-07-03 still matters (narrow tmux
   split), but the exemplar screenshot is wide. Smart decision expected here: adaptive —
   wide terminal = master-detail two-pane; narrow portrait = full-frame push navigation on
   the same stack. One codebase of pure renderers, two compositions. Simplicity wins ties.
6. **Smart decisions along the way.** The user explicitly grants latitude: where Doey's
   choice and the current board's choice conflict, pick the better one and log it in the
   charter's Decisions — don't preserve wave 1–4 behavior out of inertia.

---

**Original wish (2026-07-03, verbatim spirit):** "Create the best portrait task interactive TUI for Barkpark tasks. It should be connected with your relevant repo. It should be very incredible — we see it's organized well in epics, currently active, latest updated on top. We want ONE simple view — not many toggles — but that view should be fantastic and work very automatically, helping the user understand what's going on. This is a very important goal — loop until perfection."

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

---

## AMENDMENT 2 (2026-07-04) — COMPACT, GROUPED, CLAIM-FORWARD (live-queue feedback)

**User, verbatim, seeing the real guerrilla board:** "I never see anything claimed, and I see all
these tasks stacked like this? looks so incredibly bad — I wanted them stacked — and I want to see
what is being worked on — not a lot of irrelevant tasks — unless I expand to see more, I want to
see the relevant active list, but not all the items." + "We want it to be a lot more compact and
grouped — it is important that Barkpark is making it very important that we claim tasks — and
handle it fully — so we can see active ongoing work."

**Ground truth of the live queue (measured 2026-07-04, `/v1/tasks?limit=1000`, 204 docs):**
`open 66 · done 136 · blocked 1 · in_progress 0`; **119 claims all EXPIRED** (workers dropped the
lease without closing); 4 epics dominate the opens — aesthetic-unification (35 children), dwb (30),
sheets-parity (22), lvw (13). So today's board renders every epic FULLY EXPANDED → a ~130-row flat
wall, and the NOW band is empty ("nothing claimed right now") because nothing is genuinely
in_progress. This is the exact opposite of the wish.

**The two decisions this amendment demands (implement + retune the opinion — this is legal now,
the board is live and the user is the authority):**

1. **COMPACT + GROUPED BY DEFAULT.** The board's default is a SHORT, scannable list of GROUP
   HEADERS (epics + clusters), each collapsed to one line with its progress + a claimable hint —
   NOT a dump of every open child. Expand (enter/l on a header) reveals the children. This INVERTS
   today's "expanded unless Dormant" default: epics/clusters now FOLD by default, and auto-EXPAND
   only when they hold active work (an in_progress/claimed child) — the group you're actually
   working shows its rows, everything else stays a quiet header. Orphans fold behind a count too
   (open orphans, not just done). "Unless I expand, I see the relevant active list, not all items."

2. **CLAIM-FORWARD — active work is the hero, claiming is the point.** The pane's whole opinion
   pushes claim → work → close. NOW (active claimed/in_progress work) stays pinned at top. When
   NOTHING is claimed (today's reality), the band must NOT dead-end at "nothing claimed" — it
   surfaces a compact **READY TO CLAIM** head: the top N ready tasks across all epics (priority
   then freshness), each one keypress `c` to claim, so the user always has an obvious way to start
   active work and immediately SEE it move into NOW. Barkpark should make claiming feel important
   and make the claim lifecycle legible (claimed → in_progress → closed), not bury it.

Everything else (Amendment 1's simple/beautiful/deep, the calm subtraction) still holds. This is a
policy/opinion retune on the LIVE queue — the slice the roadmap always reserved for "run against
guerrilla, retune ordering/folding." Loop until the pane, on the REAL corpus, reads compact,
grouped, and claim-forward — not a flat wall.

---

## AMENDMENT 3 (2026-07-04) — the DETAILED direction: `bp tasks` matches the design-language mockup

**User showed the current calm board (before) beside the target mockup (after) and said: make it look
like the mockup.** The target is the Barkpark task design language, fully specced in
`.claude/workflows/bp-task-design-language-spec.md` (the SOURCE OF TRUTH — read it whole) and already
built + tested on the paper/GUI side (the `task-list` PortableDoc component). This is the TUI catch-up
the spec §4/§7 scheduled. It deliberately reverses part of the wave-5 subtraction: structure and
MEANINGFUL color return (spec's "color = state, never decoration" — hue on lifecycle, priority
severity, and blockers; labels stay dim monochrome).

**The target frame, read from the mockup (portrait, ~60 cols):**

1. **Header** — `barkpark · tasks` left; `⇄ guerrilla ● live` right (drop the branch chrome).
2. **Momentum header** (spec §0) — `⠿ 1 in flight · ○ 4 ready · ✓ 14 done` with `NN%` right-aligned,
   and a **progress bar** row under it. Icons + color (done teal). The always-on progress read.
3. **NOW · N claimed** — the in-flight row with the spinner glyph, colored priority, criteria `2/3`,
   and the assignee (`me`) in accent.
4. **Phase bands, not epic/cluster rules** — section headers are a NAME + **dotted leader** + a rollup:
   `Token spine ·········· W1 · 1/4`, `Studio ····· W2 · 0/3`, `Web · TUI · pdrender ···· W3–4 · 0/4`,
   `Paper components ···· W5 · 14/24`, `Enforce & cut over ··· W6 · 0/2`. Grouping is by phase
   (`phase:*` / the W-code), with a `done/total` criteria rollup per phase.
5. **Rich row** (spec §3) — `glyph  ID · title              PRIORITY  criteria`. The lifecycle glyph
   (open `○`@50% / ready `○` white / in_progress spinner blue / blocked `!` amber / done `✓` teal),
   the id·title, a **color-severity priority** (P0/P1 red, P2 amber, P3/P4 dim), and the criteria
   fraction `0/4`. Done rows recede (dim, teal check). Assignee when claimed.
6. **Nested subtasks** — arbitrary depth by indent + `↳` guide, each a full rich row
   (`↳ ✓ collect query targets from blocks`, `↳ ○ inject snapshot into render opts   P3 0/2`).
7. **Blocker badge on the row** — `! resolver` in amber on a blocked task, so it says WHAT blocks it
   without opening.
8. **Folded done** — `+ 2 more done — folded` teal; honest truncation everywhere.
9. **Footer** — `j/k move · enter open · c claim · x close · N open · N done`.

**Vocabulary is EXACT and shared** (spec §1, §6): the TUI glyph/color set IS the manifest both surfaces
use — do not invent a TUI-only variant; reconcile with `internal/semrole` and the paper component's
values so the CI drift gate stays green. Motion (spec §2): the in_progress braille spinner cycles on
the existing heartbeat (idle board stays byte-stable); done flashes ×3 on the done-transition only.
NO_COLOR / ASCII / reduced-motion fallbacks per spec §3. The calm subtraction's GOOD parts stay: dim
monochrome labels, done recedes, honest truncation, one-view-no-toggle-farm. Loop until `bp tasks` on
the real corpus reads like the mockup.

---

## AMENDMENT 4 (2026-07-05) — ONE activity-focused list (kill READY TO CLAIM; recency + focus windows)

User, verbatim: "I dont really want to see 'Ready to claim' on top - i just want 1 list, with the stuff
that been recently worked on - like just how it is now - but the epic / goals etc is based on recently
worked on etc - we dont for example want to see stuff like long list finished stuff blocking the view -
what i want to see is the big picture, and what is being worked on - i dont want too much dead space
without me expanding - but right now it might just be bad task hygiene - so we need to make our system
excellent at ensuring best practices - it is important to be able to see what is being worked on, the
context around it - so for example see 3 siblings, 3 children, maybe 1,2 parents - but if this is within
proximity of another task that is active or going to be worked on then it should be giving more
perspective - so we dont make many lists, but try to cover more that is relevant in one eye catch."

Observed failure (screenshot): the auth epic rendered ~25 recent-done ✓ rows as a wall (they were <24h
old so the "terminal >24h folds" rule let them all through) — finished work FLOODING the view. And the
READY TO CLAIM head makes a second list that duplicates rows from the sections below.

The retune:
1. ONE LIST. Kill the READY TO CLAIM band. The board is a single spine of sections; claim-forward
   stays via the cursor + `c` (and NOW pins live claims as today).
2. RECENCY RANKS. Sections (epics/clusters) order by last-activity (most recent claim/close/mutation/
   update among descendants — events + updated_at), most-recent first. The big picture reads top-down
   as "what this system is working on now → lately → dormant".
3. DONE RECEDES, ALWAYS. Done rows never flood: at most ~1-2 freshest done rows in an ACTIVE section
   as a completion cue; everything else folds to "+N done" regardless of age. The done-blink/ticker
   still celebrates the moment.
4. FOCUS WINDOWS, not head-of-first-5. Within an active section show the ACTIVE work + its context:
   ~3 ready siblings, ~3 children, 1-2 parents of the active/claimed tasks; when two active tasks are
   near each other (shared parent/section), MERGE their windows into one wider neighborhood — more
   perspective in one eye-catch, never two lists for one story. Sections with no activity collapse to
   header+rollup (the big-picture line); expand (l/enter) still reveals all.
5. HYGIENE IS SYSTEMIC. The flood was partly bad task hygiene; the §5/§6 quality tasks (save-gate,
   completeness score, bp task lint, guided editor) are the enforcement arm — the board must ALSO be
   robust to bad hygiene (mass closes, stale claims) by policy, not by hoping data is clean.
