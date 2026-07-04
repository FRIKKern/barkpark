# Barkpark task design language — GUI & TUI parity + authoring ideals

**Status:** design spec, awaiting build sign-off · **Date:** 2026-07-04 · **Companion artifacts:**
the published design proposals (shared vocabulary + detailed components; GUI/TUI parity). This is the
durable in-repo copy the build works from.

**One line:** every task looks and *means* the same thing on every surface — browser (paper / Studio /
web) and terminal (`bp tasks`) — because one manifest feeds both, and the tasks themselves are held to
a quality bar Barkpark enforces.

---

## 0. THE CRITERION — it must feel alive; you always feel progress

**This is the acceptance test for the whole initiative** (user, verbatim: *"Criteria is to make it feel
alive — making us always feel progress."*). Every feature below earns its place only if it serves this.
Open the task view and *something is moving*; you watch momentum, never a dead wall of text. The
concrete mechanisms that deliver it — each specced further down:

1. **Live pulse** — active work fades (GUI) / spins (TUI); the pane breathes, reads as working even at
   rest. (§2)
2. **Progress at every scale** — criteria `2/3` → phase rollup `5/11` → an overall % header. The needle
   is visible wherever you look.
3. **Movement surfaced** — flash-on-change per row + a one-line activity ticker of what just moved
   (`✓ tokens.json completed · ◐ inject snapshot 1→2`). Nothing changes silently.
4. **Completion is felt** — the done blink-×3 + a "done today" tally that climbs. Every finish lands.
5. **Always a next step** — ready-to-claim pinned; you can always make progress in one keypress
   (claim-forward, from the TUI charter).
6. **Things grow, not jump** — bars fill and counts tick up with smooth transitions (CSS `transition`
   on width / animated count); in the TUI, the heartbeat repaints the changed cells. Change you can
   *watch happen*.

A **momentum header** (aggregate: `◐ N in flight · ▶ N ready · ✓ N done today · NN%` + an animated
overall bar) sits atop the board on both surfaces — the always-on progress read. Motion is never
decoration here: it is the signal that the system, and your work, is moving.

---

## 1. The shared status vocabulary

Six lifecycle states. Each is ONE manifest row → `state → { role, glyph, active_frames, color }`.
Reconciles with `internal/semrole` (which already owns the role token vocabulary).

**EXACT SAME ICONS, both surfaces (user directive 2026-07-04, verbatim: "Make it use the same icons as
TUI precisely — exactly same icons").** The TUI is the constraint (a terminal can only paint Unicode),
so the shared set *is* the Unicode glyph set — the GUI prints the **identical character**, NOT a
lookalike SVG. No SVG icon system, no per-surface translation, nothing to drift.

**Checklist metaphor + brightness ladder (user directive 2026-07-04):** a task is a checklist item —
`ready` is the **unchecked** circle waiting to be ticked (**full white / foreground**), `done` is the
check. `open` is the **same `○` at 50% white opacity** (faint = backlog, not ready). So the neutral
"todo" spectrum is monochrome white (open dim → ready bright), and **color is reserved for the states
that carry meaning**: blue (working), amber (blocked), teal/green (done). This is the TUI's own
"color = state, never decoration" discipline. Lifecycle reads `○(50%) → ○(100%) → spinner → ✓`, with
`!` and `✕` offshoots. (Supersedes the earlier "green for ready" — green now signifies completion, not
readiness; ready is white.)

| state | meaning | glyph (GUI & TUI, identical) | codepoint | color |
|---|---|---|---|---|
| `open` | filed, backlog, not workable | `○` | U+25CB | **white @ 50% opacity** (foreground, adaptive) |
| `ready` | unchecked, deps met — claim it | `○` | U+25CB | **white / full foreground** (adaptive) |
| `in_progress` | claimed, worked now | Braille spinner `⠋…⠏` (**cycles, TUI-identical**) | U+280B… | blue `#2563eb` / `#60a5fa` |
| `blocked` | needs something / requirement unmet | `!` | U+0021 | amber `#d97706` / `#fbbf24` |
| `done` | complete | `✓` (**blinks ×3 on complete**) | U+2713 | teal `#0d9488` / `#2dd4bf` |
| `cancelled` | abandoned / superseded | `✕` | U+2715 | neutral-dim `#a1a1aa` / `#71717a` |

open & ready share the glyph `○` and codepoint — opacity (50% vs 100% of the foreground) is the only
difference, a brightness cue that reads as "backlog vs ready." "white / foreground" = adaptive: near-
white on dark, near-black on light (an unchecked checkbox is the text color).

The active state animates the **same way** in both: the GUI cycles the same 10 Braille frames as the
terminal (~12 fps) — same glyph, same motion. (This supersedes the earlier "GUI fades / TUI spins"
split — unified to one icon + one motion per the directive.) ASCII/no-Braille-font fallback still maps
these to `[>] [~] [x] [v]` (§3).

**Principles (from the `bp tasks` TUI bar, kept):**
- **Color = state, never decoration.** Labels stay dim monochrome; only status/priority-severity/
  blocker carry hue. One `RoleFor` map is the single source.
- **Telling icons.** A checkmark reads "done" with no legend; play = go, half-circle = in motion,
  slash = no-entry.
- **Neutral = white** (open 50%, ready 100%); **color only for meaning** — blue working, amber blocked,
  teal done. (Reverses the earlier "green for ready"; green/teal now = completion.) *Open decision:
  done = teal vs a classic green check — with ready no longer green, a green check is now unambiguous.*
- **Done recedes** (dim title) once complete; **honest truncation** (`… and N more`, `showing N of M`)
  everywhere.

## 2. Motion = state (two moments, nothing else moves)

| moment | GUI | TUI | rule |
|---|---|---|---|
| **being worked** (steady) | in_progress icon opacity **fades 100%↔40%**, ~1.8s ease-in-out | Braille spinner `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` cycles ~80ms/frame | continuous while the state holds |
| **just completed** (one-shot) | check **blinks + pops ×3** (~1s), then settles | `✓` flashes bright→dim ×3, then steady | fires ONCE on the done-transition; never on first paint or cache-primed render |

- CSS-only in the GUI (works in a static saved paper, zero runtime). Terminal frame-cycle rides the
  existing bubbletea heartbeat — which ticks **only while a live task exists**, so an idle board is
  byte-stable and goldens stay green (charter D-heartbeat).
- **Reduced motion / `NO_MOTION`:** GUI honors `prefers-reduced-motion`; TUI freezes the spinner on a
  steady frame (`⠿`) and skips the done-flash. Color + glyph still tell the whole story.

## 3. Layout — same structure, native rendering

Both surfaces render the SAME policy (`BuildBoard`-style organization), each in its idiom:

- **Phases** — grouped bands with a rollup `done/total`: card-band header (GUI) / dashed-rule header
  `── Paper Components ──── W5 · 5/11` (TUI).
- **Tasks within tasks** — arbitrary-depth nesting by indentation + `↳` guide, both surfaces.
- **Blockers on the row** — `⊘ <cause>` shown inline (GUI badge / TUI amber token), so a blocked task
  says *what* blocks it without opening it.
- **Rich row** (a paper is read, not glanced → density is a feature): icon · title · priority · criteria
  progress · blocker badge · assignee. Done rows recede.
- **NOW band** — active/claimed work pinned; claim-forward.

### TUI-specific rules
- **Portrait** 60–100 cols; titles ellipsize; one dim meta column right-aligns; below ~52 cols meta
  drops, glyph+title survive.
- **Color:** 24-bit ANSI (same hex) → 256-color → `NO_COLOR` (glyph alone carries state).
- **ASCII escape hatch:** a config flag swaps Braille/geometric glyphs for `( ) ready · [~] wip ·
  [!] blocked · [v] done · [x] cancelled` on fonts that can't render them (no tofu).
- **Detail view** (enter descends): title · `glyph lifecycle · P? · kind · worker` meta · hybrid
  timestamps `2h ago (Jul 04, 15:12)` · derived status timeline · description via mdlite→pdrender ·
  criteria checklist with per-item evidence · deps-in-words · claim block + lease · children + paper
  rails. Conditional — a thin task stays thin. Nav is a stack (esc ascends), breadcrumb, cycle guard.

## 4. THE GOAL — plans are living documents (all artifact components in PortableDoc)

**Directive (user, 2026-07-04):** *"we need to be able to utilize this in the way we are showing plans,
being able to see work on the plans realtime being updated … we have to be able to create everything
with portable docs."* So the goal is: **every component in the design artifact renders as a PortableDoc
block, and a plan (paper) embeds live task views that update in realtime as the work moves.**

### Components — all snapshot-driven pure `_raw` emitters in `Render.Components`

| block type | what | status |
|---|---|---|
| `tasks` / `task-list` | phased, nested, blocker-aware list + momentum header | ✅ built + tested |
| `task-detail` | conditional "open a task and SEE it" card (§15) | ✅ built + tested |
| `task-board` | kanban by lifecycle bucket | ✅ built + tested |
| `roadmap` | phase/task bars, status-coloured, today-marker (author `left`/`width` %, no `due_at`) | ✅ built + tested |
| `status-legend` | the glyph/colour vocabulary key (§2 of the artifact) | ▫ next |
| — momentum | header (in `tasks`) | ✅ built |

Pattern (proven): `compose_block(%{"type"=>…}) → %{"kind"=>"_raw","html"=>Components.foo_html(b)}`;
`Walk` passes `_raw` through; CSS appended to the single-source `paper-surface.css` →
`Stylesheet.css/0` (`@external_resource`) → all 3 view sinks. Snapshot contract = `snapshot: [rows]`
(same as the `sheet` embed) so it works offline / plugin-off. Every author string `escape_html`'d;
`~s|...|` sigils to dodge the paren trap; the in_progress spinner is **pure CSS** (`@keyframes`
animating `::before content` — no JS, so it lives in a saved static paper).

### Live plans — the realtime piece (the point of it all)

1. **Resolver** — `Papers.resolve_tasks_in_blocks`, mirroring `resolve_embeds_in_blocks` (papers.ex:766):
   a `tasks`/`task-board`/`roadmap`/`task-detail` block carries a `query`
   (`{parent_id, labels, status}`) instead of a static snapshot → collect targets → query the task
   substrate → inject the resolved `snapshot` into render opts (+ write-through on save). Makes the plan
   read **live** bp tasks (trees, blockers, criteria, claims). *(needs a running app to verify)*
2. **Realtime refresh** — task mutations already emit `mutation_events`
   (`task.{claimed,closed,mutated,relabeled,lease_expired}`, api/CLAUDE.md). BulldocsLive/Studio
   subscribes and re-resolves the embedded task blocks on those events → the plan updates itself while
   you watch (the "feel alive / always feel progress" criterion, now on a real plan).
3. **Studio EDIT authoring** — insert-menu + node-views + a query builder (pick epic / labels / status)
   so plans are authored, not hand-JSON'd.

### Also in scope
- **TUI catch-up** — bring `bp tasks` to the detailed/active direction (see
  `bp-task-tui-detailed-direction-note.md`).
- **Go pdrender + web `portable-doc.tsx` parity** — the same block types in the terminal + web renderers.
- **Retire** any thin earlier `tasks`/`gantt` variants into this one coherent family.

## 5. Filled well, by design — the authoring quality bar

> The interface is only as good as the tasks in it. Barkpark makes a **well-formed task the path of
> least resistance** — it guides authoring, scores completeness, and lets the render reward fill.

### The ideal task (rubric)
| field | the ideal — what "well-filled" means |
|---|---|
| **title** | verb-first, one specific outcome, ≤72 chars. "resolve_tasks_in_blocks → live snapshot", never "task stuff". |
| **description** | the why + approach + out-of-scope, markdown. A first-time reader understands in ~20s. |
| **acceptance_criteria** | 2–6 concrete, checkable items = definition of done; evidence attaches to each as it lands. |
| **priority** | P1–P4 chosen on purpose, not defaulted. |
| **placement** | under a parent/phase — part of the tree, not a loose orphan (unless it truly is). |
| **dependencies** | blockers declared, so `ready` actually means ready and the graph is honest. |
| **paper** | linked `design_doc` when a plan drives it — task and plan stay connected. |

### How Barkpark ensures it (four layers)
1. **Guided editor (author-time).** Studio task editor with structured fields whose *placeholders ask
   the right question* ("How will you know this is done?"), quick templates, and live preview in these
   components. The good shape is the default shape.
2. **Quality gate on save (`before_save`).** The sheets-gate pattern: empty title can't publish; a
   substantive task with zero criteria warns; malformed criteria rejected → 409 `halted`. Soft nudges,
   hard stops only on essentials. NEVER block trivially — fresh-install/authoring must stay smooth.
3. **Completeness score.** Every task carries a quality read (title · description · criteria ·
   placement · priority · deps · paper → N/7). Surfaced as a subtle badge, via `bp task lint <id>`, and
   the board can flag under-filled work. This is the single-task complement of Cody's repo-wide grade.
4. **Render rewards fill.** The components make a rich task *beautiful* (timeline, criteria-with-
   evidence, rails) and a thin one *visibly thin* with a named gap ("no acceptance criteria — how will
   you know it's done?"). The honesty is the incentive — no scolding, a payoff for doing it right.

**Peak-UX intent:** authoring a great task should *feel* good and *look* great immediately, so quality
is pulled by aesthetics, not pushed by validation. The gate is the floor; the render is the ceiling.

## 6. How the two stay identical (no drift)

Same source, two emitters, one gate — the [[unified-aesthetic-epic]] model extended to task symbols +
motion:

- **source:** the §1 manifest (`tokens.json` + `internal/semrole`).
- **GUI emitter:** prints the **same Unicode glyph** (not SVG) in a `.gi` span + `--st-*` CSS + the
  Braille frame-cycle (JS/CSS) + done-celebrate keyframe (`paper-surface.css`, `portable-doc.tsx`). Font
  stack must include a Braille-capable mono; ASCII fallback per §3.
- **TUI emitter:** glyph + ANSI color + spinner frame-cycle (`taskboard/theme.go`, `components.go`).
- **CI drift gate:** `design/check` fails the build if a glyph, color, or frame set diverges between
  surfaces.

## 7. Open decisions for sign-off
1. **done color** — teal (distinct from ready-green) vs the classic green check. *Recommend teal.*
2. **gate strictness** — which fields are hard-stops (recommend: title only) vs warn (criteria,
   placement, priority).
3. **TUI detailed/active pass** — scheduled as a later wave (see
   `bp-task-tui-detailed-direction-note.md`); paper components lead and prove the vocabulary first.

## Cross-reference
- TUI vocabulary source: `internal/taskboard/` (theme.go · components.go · detail_render.go · board.go).
- TUI reminder (detailed direction, deferred): `.claude/workflows/bp-task-tui-detailed-direction-note.md`.
- Epic home: `.claude/workflows/bp-aesthetic-unification-{epic-charter,wish}.md`; bp tree
  `aesthetic-unification-epic` (label `proj:aesthetic-unification`). See [[unified-aesthetic-epic]].
