<!-- doc-tier: cold | canonical-for: legendary-paper-survey-02-2026-08-05 | budget: 2200tok -->
# Survey 02 — cloud-console-hardening wave 29 public reader

Assignment: `survey-02`  
Unit: `cloud-console-hardening-wave-29-2026-08-03::public`  
Lens: visual reader at normal and narrow widths  
Verdict: **partial** — the normal-width reader is legible and page-contained, but the narrow reader persistently obscures content with its fixed view toggles; the Paper is also exceptionally long and every table requires horizontal interaction at 390px.

## Facts

- **found — revision identity:** `bp doc get paper cloud-console-hardening-wave-29-2026-08-03 --perspective published --json` returned `_rev=18768b0a14c2eead927181c4a0e37c18`, exactly the frozen revision, with 252 blocks.
- **found — normal-width containment:** Chromium at `1440x1000` rendered one centered `720px` paper surface, `34,823px` tall, with document `scrollWidth=clientWidth=1440`; no page-level horizontal overflow was found. Two of 11 tables had small internal overflow (`640→672px`, `640→661px`).
- **found — narrow page containment but table interaction burden:** Chromium at `390x844` rendered a `390px` surface, `60,684px` tall, with document `scrollWidth=clientWidth=390`. All 11 tables were internally scrollable (`clientWidth=310px`; `scrollWidth=318–672px`). This avoids page-wide clipping by design (`api/assets/paper-surface/paper-surface.css:245-249`), but the right-side columns are outside the initial viewport and require horizontal scrolling.
- **found — content obstruction at narrow width:** the fixed `Email view` rectangle (`x=249..370`, `y=749..782`) and `TUI view` rectangle (`x=265..370`, `y=791..824`) intersected Paper content at all five sampled scroll positions. Hit-testing found an H2 at the top sample, table cells at 25% and 75%, a list item at 50%, and the closing callout at the bottom. The fixed positioning is explicit at `api/lib/barkpark_web/layouts/bulldocs.html.heex:708-723`; there is no narrow-width relocation in that rule set.
- **found — extreme density/length:** the normal view is 34.8 viewport-heights and the narrow view is 71.9 viewport-heights. The document has 37 authored headings, 187 paragraphs, 13 lists, 11 tables, and 4 callouts. Five screenshots per viewport (top/25%/50%/75%/bottom) consistently show long prose, dense lists, or multi-column tables rather than short scanning summaries.
- **found — hierarchy is visually legible:** H1/H2/H3 size contrast is clear at both widths. The opening H1 occupies 141px at normal and 282px at narrow; subsequent section headings remain distinct. The reader deliberately fixes the surface to a 720px maximum with 40px horizontal padding (`api/lib/barkpark_web/layouts/bulldocs.html.heex:374-377`).
- **found — no large blank-space defect:** 139 empty paragraph blocks exist in the pinned document, but all sampled DOM measurements gave them `height=0`; no inter-block gap over 60px was found. They are source noise, not visible blank slabs on this reader.
- **partial — standalone visual sense:** the opening title, status, epic, predecessor, and charter identify the artifact. However, the first-screen status says `SURVEYING` while the same document later contains `DEBRIEF`, `Grade — A`, and shipped/reviewer sections. There is no contents/jump rail in the inspected reader, so a standalone visitor must traverse up to 60,684px to discover the final state. The visual presentation is coherent; the orientation state is stale and the narrative is not compact.
- **not_found — irreversible clipping:** tables expose `overflow-x:auto`, and the page itself does not widen. Content outside the initial narrow table viewport is recoverable by horizontal scrolling. The defect is discoverability and interaction cost, not proven data loss.
- **not_found — unsupported/blank renderer boxes in sampled views:** none appeared in the ten screenshots or 252-block DOM inventory.

## Coverage and evidence

Real browser: Playwright Chromium 147 / headless, live URL `https://guerrilla.barkpark.cloud/papers/cloud-console-hardening-wave-29-2026-08-03`.

Exact sample:

- 2 viewports: `1440x1000`, `390x844`.
- 5 scroll positions per viewport: top, 25%, 50%, 75%, bottom.
- 10 viewport screenshots.
- all 252 block rectangles checked for empty text and vertical gaps;
- all 37 authored headings measured;
- all 11 tables measured for client/scroll width;
- fixed toggle overlap hit-tested at all 5 narrow scroll positions.

Captures:

- `/private/tmp/survey-02-normal-{top,quarter,middle,threequarter,bottom}.png`
- `/private/tmp/survey-02-narrow-{top,quarter,middle,threequarter,bottom}.png`
- `/private/tmp/survey-02-paper.json`

Representative SHA-256:

- narrow top: `7365b6525d2b7dea3337060a2a6aae629700d6a60b323281c0c2c9fcc3e01c`
- narrow quarter: `0398a9a2edcbf77af038ebf44e9a487921a034e1a4f74550836af012751fedc9`
- narrow bottom: `c9318505f39b2d8854a2198426df5bdf0ecfb206cd05ee607c6602dab9aee383`
- normal top: `9705b0c201b8c3da20c490fc324624718eba9ea4fb86b970a0320f5faf93923f`
- normal middle: `26a8afce175dedf9d0e1769bd1d1c7120b5b86c6d3ae5fb63e56563a1240a89a`
- pinned JSON: `2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15`

## Checked inventory

| Target | Check | Result |
|---|---|---|
| `CLAUDE.md` | repository routing, Paper ownership, safety | found |
| `api/CLAUDE.md` | Bulldocs public-reader ownership | found |
| `.omx/context/legendary-paper-reader-upgrade-20260805T205600Z.md` | frozen revision, assignment, stop condition | found |
| Paper `cloud-console-hardening-wave-29-2026-08-03` rev `18768…37c18` | block inventory, opening/closing state, empty blocks | found |
| live `/papers/cloud-console-hardening-wave-29-2026-08-03` | hierarchy, density, clipping, blank space, standalone sense | partial |
| `api/lib/barkpark_web/layouts/bulldocs.html.heex:374-388` | reader measure and first-heading rhythm | found |
| `api/lib/barkpark_web/layouts/bulldocs.html.heex:700-729` | fixed Email/TUI toggle geometry | found |
| `api/assets/paper-surface/paper-surface.css:245-257` | table overflow containment | found |
| Barkpark task `task-a768c69e659add58` | assignment context only; no task mutation | partial (context file, not live task fetch) |
| Campaign Paper `legendary-paper-reader-upgrade-sweep-2026-08-03` | assignment context only; not part of target render | partial (context file, not rendered) |

## Inference and recommended proof

- **Inference:** the fixed mode toggles are a reader-wide mobile defect, not document-specific, because their geometry comes from the shared Bulldocs layout. Prove on at least one short Paper before assigning a global fix.
- **Inference:** the narrow table design is technically contained but visually expensive; requiring horizontal scrolling 11 times materially weakens scanability. A format experiment should compare responsive row/card projection against the present internal-scroll contract before changing shared rendering.
- **Inference:** compacting the Paper itself will improve both widths more than typography tuning alone because its 252 blocks and phase-by-phase append structure dominate total height.

## Unvisited ranges / risks

- Browser engines other than Chromium; dark mode; OS font substitutions; zoom/reflow; landscape; print; 320px and tablet widths.
- No manual touch gesture test of horizontal table scrolling; CSS/DOM proves scrollability, not gesture quality or discoverability.
- Only five visual scroll positions were screenshot-reviewed. DOM geometry covered all blocks/tables, but unsampled pixels may contain local visual defects.
- Alternate Email and TUI modes were not opened; they belong to separate frozen reader units.
- No production or Paper mutation was performed.
