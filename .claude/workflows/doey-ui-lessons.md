<!-- doc-tier: cold | canonical-for: doey-ui-lessons-for-bp-task-tui | budget: 9000tok -->
# Doey task-UI lessons → Barkpark portrait task TUI

> **Two parts.** Part 1 (below) = the pre-build brief that informed the epic — the task
> card/list/detail surface. Part 2 (bottom, 2026-07-04, post-wave-6) = the fuller mine of the
> nav shell, plan reader, and cross-cutting craft, with a retro-compare against what shipped and
> a ranked borrowable backlog. Read Part 2 first if you're picking the next slice.

Design brief extracted from the **Doey** TUI (Go + Bubble Tea/lipgloss, same stack Barkpark uses). READ-ONLY study — nothing in Doey was modified. All citations are `path:line` into `/Volumes/SATECHI/github/doey`.

Doey's task UI is a **two-pane** layout: a left list panel (`renderLeftPanel`, `tui/internal/model/tasks.go:1213`) and a right detail panel (`renderRightPanel`, `:1282`) with a full `ExpandedCard` (`tui/internal/taskcard/taskcard.go:480`). Barkpark's constraint is **one portrait column** with inline expansion — so the lesson isn't "copy the layout," it's "steal the compression tricks, collapse the two panes into one inline-expand."

---

## 1. TASK CARD anatomy — how Doey compresses rich state

The list card is a **fixed 2-line entry**, dense (`Height()=2`, `Spacing()=0` → `taskcard.go:57-60`):

```
 ◆ Scope correction: intent fallback is a router…      ← line 1: indent + health-icon + title
   #440 · W3.1 · (3/5) · feature · W3 · 12s            ← line 2: dim metadata, " · "-joined
```

**What's on the card** (`Render`, `taskcard.go:123`):
- **Line 1** = `indent + healthIcon + title`. Title truncated to `width-6` with a `…` (`:159`), never wraps. Child tasks get a `↳ ` indent and a deeper metadata indent (`:177-180`) — hierarchy is shown by indentation, not boxes.
- **Line 2** = `taskCardDescription` (`:245`): `#id · worker-names · N/M subtasks · type · team · age`, all `Muted`+`Faint`, joined with `·`. **Status is deliberately omitted from the text** — "Status is conveyed by the icon, so omitted from the description to save space" (`:243-244`). That single decision is why the line stays short.

**The icon carries the most state.** `taskHealthIcon` (`taskcard.go:203`) folds *both* status *and* liveness into one colored glyph:
- Status glyphs: `✓` done (success, faint), `○` cancelled, `✗` failed (danger), `◉` needs-confirmation (warn), `◈` awaiting-review, `◇` research, `◆` blocked (danger).
- For active tasks it becomes a **health diamond** colored by heartbeat: `◆` success/warn/muted for healthy/degraded/stale (`:228-237`). So one character tells you status *and* whether the worker is alive.

**Color = role, centralized.** `StatusAccentColor` (`styles/cards.go:38`) is the single status→color map (Success/Warning/Primary/Danger/Muted/Info). Everything else references it. This is exactly Barkpark's "same status-role vocabulary as the SPA/CLI" goal — one function, no forks.

**Selection** = left border + subtle background (`taskcard.go:184-197`), and the border flips to `Accent` when the task had activity in the last 30s — a live task you're looking at pulses a different edge color.

**Age is color-coded, not just printed.** `ActivityTimeBadge` (`styles/cards.go:975`): `<10s` green, `<60s` normal, `<120s` warn, older danger. Recency has a *temperature*.

**What makes it scannable:** one glyph per row does the heavy lifting; text is monochrome-dim so color only appears where it means something; fixed 2-line height means the eye scans a predictable grid.

## 2. LIST organization

- **Sort:** `sortEntries` (`tasks.go:419`) = **most-recently-active first**, using `taskActivityTime` = `heartbeat.LastActivity > Updated > Created` (`:406`). Freshest movement floats up — exactly Barkpark's "latest-updated first." Tiebreak by ID descending.
- **Hierarchy:** after sorting, `groupChildrenUnderParents` (`tasks.go:443`) reorders so children sit *directly under their parent* (orphaned children whose parent isn't loaded append at the end). This is Barkpark's epic-spine in miniature.
- **Sections:** `TaskSection` (`taskcard.go:73`) buckets into `IN PROGRESS / NEEDS REVIEW / DONE / CLOSED / OTHER`. Headers are rendered *inline at group boundaries* by the delegate itself (`:129-146`) — a dim bold faint label with 2 blank lines of breathing room before it (`SectionGapLines=2`). No separate header widget.
- **There is also a hidden `statusPriority`** (`tasks.go:387`: active=0, blocked=1, review=2, draft=3, done=4) — a status-band ordering that the *current* sort doesn't fully use (recency wins). Worth noting as the "NOW band" primitive Barkpark wants: band-by-status-priority, then recency *within* band.
- **Summary line** above the list (`taskSummary`, `tasks.go:2087`): `"12 total, 3 active, 9 done, 2 workers active"` — active in green, done dim, workers in warning. A one-line census.
- **Scale handling:** relies on Bubble Tea `list`'s built-in pagination (`l.SetSize`, `tasks.go:1266`). No density modes, no folding of done tasks. **This is a weakness** (see AVOID).

## 3. INSPECTION — the detail / expanded card

Doey opens detail in the **right pane** (Barkpark will do this **inline**). `ExpandedCard.Render` (`taskcard.go:480`) is a long vertical stack of *conditional* sections — each renders only if it has content, so a thin task stays thin:

- Header: bold title (+ `▸` focus glyph), then a **compact meta line** `◆ status · team · P1 · type` (`:501-519`), then `Created`/`Updated` as **hybrid timestamps** `"2h ago (Jan 02, 15:04)"` (`formatTimestampHybrid`, `:470`).
- **Status timeline** (`renderStatusTimeline`, `:2533`): parses the activity log for `→ status` transitions and draws `○ created (Mar 31) → ● active → ● done`, wrapping vertically if too wide (`:2611`). A horizontal life-story of the task.
- **Markdown** description+notes+decisions rendered once through glamour, **cached** by (body,width) to avoid re-render per frame (`renderMarkdown`, `:1361`).
- **Unified timeline** (`buildTimeline`/`renderUnifiedTimeline`, `:925`/`:1042`): merges logs, events, messages, updates, Q&A, reports, recovery into one chronological stream, **noise-filtered** (`isNoisyLogEntry`/`isNoisyEvent`, `:796`/`:859` — drops tool-telemetry, raw field dumps, auto-complete dupes), capped at 100, with a blank line between entries of different kinds for visual grouping. Title shows `Timeline (37 of 210)` so truncation is honest.
- **Proof of Completion** (`renderProofSection`, `:1915`): success-criteria checklist (`✓`/`✗`/`○` pass/fail/needs-human with evidence), verification badges, commits, files-changed, and **auto-generated human-verify steps** by file extension (`.go`→`go test`, etc., `:2180`).
- **Sub-sections are individually expand/collapse** with `[+]/[-]` toggles and cursor focus (reports `:633`, attachments `:1509`, subtasks `:723`) — clickable via bubblezone marks.

**What the operator can DO from inspection** is the same act-verb set that works on the list (see §4).

## 4. Genuinely clever — worth stealing

- **Icon-as-primary-signal** (one glyph = status + health) — the single biggest scannability win.
- **Status omitted from text because the icon says it** — ruthless de-duplication of information.
- **Hybrid timestamps** `relative (absolute)` — glanceable *and* precise, no toggle.
- **Noise filters as first-class code** (`noisyFieldPrefixes`, `noisyEventTypes`, `IsBodyLineNoise`) — the timeline is curated, not a raw dump. This is the difference between "log viewer" and "instrument."
- **Honest truncation everywhere:** `Timeline (37 of 210)`, `… and 12 more`, `Files changed: N` — never silently drops without saying so.
- **Markdown render cache** keyed on (body,width) — the refresh-discipline trick that keeps a live-polling TUI from re-rendering glamour every frame.
- **Keyboard grammar** (`updateList`, `tasks.go:811`): single-letter verbs, **context-sensitive** — `a`=accept, `m`=move-status, `d`=dispatch/deny, `s`=cycle/skip, `x`=cancel, `p`=open plan, `n`=new. Same key does the contextually-right thing per status (e.g. `d` = "deny" on a review task, "dispatch" otherwise). Discoverable via a `?` help overlay (`:2042`).
- **Empty state** is a centered icon + title + hint (`EmptyStateIcon/Title/Hint`, `tasks.go:1226`), not a blank void.
- **Soft-fail data loading** (`task_footer.go:44`): file-authoritative with DB fallback, every step degrades to a partial render rather than an error — Barkpark's "offline server renders honest degraded state" maps directly.
- **Compact one-line footer** (`RenderTaskFooter`, `task_footer.go:214`): `task #440 · title · status · 3/5 done · phase X · ·12s`, drops any empty segment, truncates title with a 30-cell reserve so meta never gets shoved off-screen.

## 5. ANTI-lessons (what fights the portrait / one-view constraint)

- **Two-pane split** doesn't fit a narrow portrait column. Barkpark must collapse detail into **inline expand-in-place** (the wish already says this). Doey's `ExpandedCard` content model transfers; its side-by-side placement does not.
- **No folding of done/closed tasks.** Done tasks stay fully in the list forever, relying only on section order and pagination. In a leave-open-all-day portrait pane this is noise. Barkpark's wave-2 orphan-folding + the amendment's "stale bucket / done folds" directly fix a real Doey gap.
- **`ExpandedCard.Render` is a ~1300-line god-method** with a dozen `render*Section` helpers and lazy sidecar/result file loads inline. Powerful, but a maintenance smell. Barkpark should keep the *conditional-section* pattern but split section renderers cleanly.
- **Fixed 2-line card can't grow** to show chips/relatedness without a rethink of `Height()`. Barkpark's chip row is a *third* line (or an inline-wrapped tail) — plan the delegate height for it from the start.
- **Deep expand-state maps** (`ExpandedReports`, `ExpandedAttachments`, `ExpandedSubtasks`, `TimelineFilter`) add a lot of interaction surface. The wish says "no toggle farm" — port the *inline expand* idea but resist Doey's proliferation of per-subsection toggles.

---

## Mapping onto the Barkpark wave-3 AMENDMENT

### Chips (amendment #1 — "a lot more categorized, tags that show relation, consistent per-tag color")

**STEAL:** the centralized color-role function pattern (`StatusAccentColor`) — one map, referenced everywhere, never forked. Chips must ride the same discipline.

**ADAPT — and mind the gap:** Doey *has* a `Tags []string` field ("cross-cutting concerns", `runtime/types.go:187`) and a `Category` field, **but**:
- Tags are rendered **only in the detail pane**, as a `Tags: #a #b` meta line (`tasks.go:1384-1390`), **uniformly `Muted`** (`TagBadge`, `styles/status.go:133`) — no per-tag color, and **not on the list card at all.**
- Only `Category` gets a color, via `CategoryColor` (`styles/status.go`), which is a **hardcoded switch over a fixed enum** (bug/feature/refactor/docs/infrastructure → Danger/Primary/Accent/Success/Warning). Arbitrary tags get no color.

→ **Barkpark's amendment wants more than Doey ships.** For "same tag = same color everywhere" across an *open* `proj:*/area:*` taxonomy, you need a **deterministic hash-of-tag → palette-slot** function (Doey has no equivalent — its coloring is a closed enum). Build that as the chip-color primitive, seed it from the status-role palette so chips harmonize with status colors, and **put chips on the card line** (Doey's biggest miss). Reserve card height for a chip row up front (AVOID lesson above).

### Relatedness (amendment #1b — "make them relate", derive clusters)

**STEAL:** `groupChildrenUnderParents` (`tasks.go:443`) is the mechanical model for cluster grouping — compute groups, then re-emit entries contiguously with a header at each boundary (`taskcard.go:129`). Swap "parent_id" for "shared-label cluster key" and the same reorder+inline-header machinery renders clusters.

**ADAPT:** Doey has **no** derived relatedness — grouping is purely explicit `parent_id`. Barkpark's "derive clusters by shared labels then title/topic similarity" is net-new; there's nothing to copy, but the *rendering* seam (contiguous entries + boundary header, no new mode) is proven. Suggested tags ("dim `+proj:sheets?` chip, one keypress to apply") map onto Doey's context-sensitive act-verb pattern (`updateList`, `:811`) — a chip is just another zone-marked, keypress-actionable element.

### Staleness (amendment #2 — "never outdated")

**STEAL directly:** `ActivityTimeBadge` (`styles/cards.go:975`) already color-codes age by temperature (green→warn→danger) — this *is* the AgeBadge the amendment references. And `taskActivityTime` (`tasks.go:406`) is the honest recency source (heartbeat > updated > created).

**ADAPT:** extend the temperature past `120s` into **days** for the "open-but-untouched >N days" flag the amendment wants (Doey's badge tops out at minutes because it's tuned for live worker heartbeats, not week-old backlog). Add a `stale` bucket to the section vocabulary (`TaskSection`, `taskcard.go:73`) or a sort-down, mirroring how Doey buckets `DONE`/`CLOSED`. The `statusPriority` band model (`tasks.go:387`) is the place to inject a stale band.

### Twin markers / duplicates (amendment #3 — "when tasks do the same, cover it")

**STEAL the data model:** Doey already has `MergedInto string` ("task ID this was merged into — audit trail", `runtime/types.go:188`), rendered in detail as `Merged into #NNN` (`tasks.go:1391`). That's the persistence shape for a resolved duplicate.

**ADAPT:** Doey has **no near-duplicate *detection* or surfacing** — `MergedInto` is only shown *after* a human merges. Barkpark's `⧉` twin marker (surface high title/label overlap within a cluster, no auto-merge) is net-new. Render it as a card-line glyph next to the health icon — exactly how Doey layers `Blockers != "" → ◆ danger` into the icon (`taskcard.go:205`). One glyph, one meaning, operator decides (`o` opens both).

---

## Top-5, distilled

1. **One glyph = status + liveness + risk.** Doey's `taskHealthIcon` folds status, heartbeat health, and blocked-ness into a single colored diamond, and *omits status from the text* because the icon says it. Copy this; it's the core of scannability.
2. **Color only where it means something.** Text is monochrome-dim; a centralized `StatusAccentColor` map is the *only* source of semantic color. Chips/stale/twins must all route through one palette function — never fork it.
3. **Doey has tags but under-renders them** (detail-only, uniformly muted, closed-enum coloring). Barkpark's amendment must go further: **card-line chips + deterministic hash-to-color** for an open taxonomy — a primitive Doey lacks.
4. **Recency temperature + honest truncation are the "instrument" feel:** age color-coded (`ActivityTimeBadge`), noise-filtered timelines, `Timeline (37 of 210)` / `… and N more`. Never silently drop. Extend the temperature into days for staleness.
5. **Reuse the grouping seam, not the layout.** `groupChildrenUnderParents` + inline boundary headers is the mechanism for epics *and* derived clusters. But **collapse Doey's two panes into inline expand**, add **done/stale folding** (Doey's real gap), and **budget card height for a chip line** before you start.

---

# Part 2 — the fuller mine (2026-07-04, post-wave-6)

Part 1 above studied ONE Doey surface (the task card/list/detail) to inform the epic. It was a
pre-build brief. Part 2 mines the surfaces Part 1 skipped — the **navigation shell**, the **plan
reader**, and **cross-cutting craft** — and retro-compares them against what Barkpark actually
shipped (waves 5–6: calm board + detail + paper reader + `[]Frame` drill-down shell). All three
were read-only studies of `/Volumes/SATECHI/github/doey` with `path:line` citations; the headline
is that **Barkpark's shell and reader came out structurally AHEAD of both Doey shells**, so the
borrowables are a short list of small robustness/ergonomics items, not a redesign.

Doey has **two** shells that teach opposite lessons: `root.go` (a flat 9-tab deck — mostly
anti-lessons for a portrait pane) and `planview`/`doey-masterplan-tui` (a single-surface
focus-ring + overlay + live-reload cockpit — where the real robustness ideas live).

## Where Barkpark is already AHEAD (do not regress)

- **A real navigation STACK with a cycle guard + per-frame saved cursor** (`program.go:928-940`).
  Neither Doey shell can express hierarchical descent — `root.go` is lateral tabs, `masterplan`
  is one surface with focus rings. Barkpark's task→paper→its-tasks→child descent is net-new.
- **Frame-kind dispatch** (one discriminant, `topFrame().Kind`) vs Doey's 9-arm `focusIndex`
  switch *duplicated in five methods* (`root.go`) — a rename touches all five.
- **Pure `View`/`Compose`** (byte-stable goldens) vs Doey's `SetSize`-inside-`View()` paint-time
  mutation (`root.go:536-562`).
- **Heartbeat aliveness BUDGET** (`program.go:342-381`): ticks only while `Alive()`, dead-still at
  rest → at-rest goldens stable by construction. Doey ticks unconditionally every 1–2s forever.
- **Hysteresis deadband** on the wide/narrow boundary (`compose.go:22-25`) — a tmux drag never
  flaps. Doey's `ClassifyWidth` has hard thresholds.
- **Cache-primed first paint + out-of-order-fetch guard + forward-only per-row merge**
  (`program.go:246-256`, `live.go`) — never a blank frame, never a reverting row.
- **ONE render engine shared with the product** (`pdrender` = the same stack Studio uses):
  task prose, papers, and web Studio render identically. Doey's TUI uses **glamour**, a *different*
  renderer from its product surface — so its TUI and product can drift. Structural win.
- **Structured, bidirectional, draft-agnostic linkage** (`DrivenTasks`/`PaperRefs`/`ChildrenOf`
  on `design_doc`/`papers[]`/`parent_id`). Doey scrapes `- [ ]` checkbox text + `<!-- task_id=N -->`
  HTML comments out of prose (`plans.go:701-719`) — fragile. Never scrape prose for structure.
- **LRU-capped render cache** (`paperCacheMax=32`) vs Doey's single-slot cache (re-renders on
  every back-and-forth). **Honest truncation caps** ("… and N more") vs Doey's uncapped lists.

## Where Doey is AHEAD — the actual borrowables (ranked backlog)

1. **BUG — orphan fold-key eviction.** `UIState.CollapsedEpics` is written (`program.go:730/737/763`)
   and **never pruned** (grep: zero delete sites — verified). In the leave-open-all-day pane it's
   built for, the map accumulates dead keys as epics close / clusters churn. Fix = Doey's
   `evictOrphanExpansions` (`masterplan main.go:128-144`): after each `applySnapshot`, drop every
   key not in the live set. ~10 lines. **Smallest, clearest — do first.**
2. **Scroll-position `NN%` on long docs.** Doey renders `viewport.ScrollPercent()` → "73%"
   right-aligned (`plans.go:910`, `tasks.go:1975`). Barkpark's `readingFooter` shows `↑/↓ more`
   booleans but no *how-far* sense (`compose.go:182,217`); `windowFrame` already has `top`/`len`/
   `avail`. Few lines. Closes the one clean long-paper-reading gap.
3. **Collapsible paper sections / heading-fold.** Doey's planview folds Goal/Context/Deliverables
   to one-line summaries below a width breakpoint and offers a full-section overlay on enter
   (`sections.go:120-167`). Barkpark renders the whole paper body flat — a 500-line design doc is a
   wall of scroll. Fold `pdrender` blocks under a heading stop → a navigable outline. **Biggest
   effort, biggest "read a long paper" payoff.**
4. **Reading-content immutability during refetch.** Barkpark's pushed frames read live out of
   `m.details`/`m.tasks` on *every paint* (`program.go:1006-1027`); a refetch mid-read can shift
   the body under your eyes. Doey snapshots overlay content at open so live reloads can't disturb
   it (`masterplan main.go:1164-1167`). Freeze a `FrameTask`'s body (or stops) at push, or
   consciously decide live-update-while-reading is wanted + guard it.
5. **Self-write echo suppression.** Doey marks a just-saved path for 200ms so its own mutation's
   reflection doesn't jump the cursor (`live.go:148-185`). Barkpark fires an optimistic refetch
   after claim/close; if the acted row changes band the cursor follows — worth the primitive if
   testing shows a jump.
6. **Rail rows show TITLE, not bare slug.** Papers rail renders `▸ <slug>` (`detail_render.go:643`);
   Doey shows a 120-char abstract per research row (`live.go:403`). Show the paper title (cheap
   snapshot lookup) — big scannability win.
7. **Named layout-gate predicates.** Doey's breakpoints are named testable functions
   (`ClassifyWidth`, `ResearchIndexLayout(mode)`); Barkpark's are inline constants in `Compose`.
   Lift "show band X at width W" into named predicates as the pane grows conditional bands.

## Cross-cutting CRAFT worth stealing (the "reads well vs renders" polish)

- **Graded-grey token TIER, all colors adaptive light/dark.** Doey has THREE dims — `Subtle`
  (timestamps/meta), `Muted` (secondary), `Separator` (rules) — and every color is
  `AdaptiveColor{Light,Dark}` (`theme.go:22-23,108-120`). This tiering is *what makes*
  "monochrome-dim, color only where it means something" actually legible. If Barkpark has a single
  "dim," this is the highest-value token upgrade + it earns the pane a light-terminal.
- **Zero-jitter focus: `HiddenBorder` (inactive) same footprint as `RoundedBorder` (active); focus
  = border-COLOR shift, not a highlight block** (`borders.go:7-22`, `tasks.go:1285`). The single
  biggest "reads well vs twitches" win for an all-day pane — selection never shifts layout a pixel.
- **Progressive FADE for done/stale instead of hiding** (`CardStyleForHealth`/`CompletedCardStyle`,
  `cards.go:797-849`): finished work gets Muted+Faint + a Separator border and optically recedes
  while staying visible — the calm alternative to folding. Complements Barkpark's stale/done buckets.
- **Empty state names the ONE next action with the keybind bolded inside the sentence** — "Press
  **n** to create your first task" (`cards.go:280-285`). **Two-tier help**: persistent one-line
  short strip → full overlay on `?` (`footer.go:71-86`). **Context-sensitive verbs inline** — show
  only the acts legal for the selected task's status (`tasks.go:1982-2013`).
- **Transient 2s action toast that evaporates** (set `statusMsg`, batch `tea.Tick(2s)` clear —
  `tasks.go:26-31`) — feedback flashes then vanishes, no banner residue.
- **Faint `│` block-quote column** for descriptions/criteria instead of a bordered box
  (`cards.go:314-335`) — one dim column, not furniture.
- **Doey ran its OWN subtraction** — `ThickSeparator`/`ThinSeparator` return `""` (`listframe.go:38`),
  `StatusBadge` comment says "no background, no solid blocks" (`status.go:46`), header is
  explicitly "no spinner" (`header.go:32`). Barkpark's calm pass is in good company; follow Doey's
  *restraint*, not its leftover fill-badge/pill/banner functions (those are the anti-lessons).

## Confirmed ANTI-lessons (Doey craft that fights the one-calm-view constraint)

The horizontal **tab bar** (eats 2 vertical rows of the scarce axis; our one-line breadcrumb is the
portrait analogue), **9-panel focus-cycling + number-key jumps** (no portrait analogue — we have a
board + a descent stack), **keeping all sub-views alive+sized at once** (we lazily render frames
from the in-hand index — correct), **`SetSize` inside `View()`**, background-filled **pill badges /
phase banners / card grids / chat bubbles**, the **VT terminal emulator** (`emulator.go`, 634 lines,
zero relevance), and **`[+]/[-]` toggle proliferation**. Barkpark already avoids all of these — the
subtraction pass was the right call.

## Bottom line

The wish's depth (open a task, read its paper, descend into its tasks) is shipped and, on the
things that matter structurally, ahead of the Doey exemplar. What remains from Doey is a **ranked
backlog of small items** (above): one real bug (#1 orphan-key eviction), two long-doc reading
ergonomics (#2 scroll-%, #3 section fold), two live-refresh robustness guards (#4/#5), a rail
scannability tweak (#6), and a **craft/polish pass** (graded-grey tiers + zero-jitter focus +
progressive fade + inline-keybind empty/help). None re-open the navigation spine — it's done.
