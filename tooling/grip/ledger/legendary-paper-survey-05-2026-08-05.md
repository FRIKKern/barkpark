<!-- doc-tier: cold | canonical-for: legendary-paper-survey-05-2026-08-05 | budget: 2400tok -->
# Legendary Paper survey 05 — Studio reader/visual lens

## Assignment

- CycleFleet assignment: `survey-05`
- Unit: `cloud-console-hardening-wave-29-2026-08-03::studio`
- Frozen published Paper revision: `18768b0a14c2eead927181c4a0e37c18`
- Lens: authenticated Studio hierarchy, density, clipping, blank space, obstruction, scrolling, and visual sense
- Observation time: 2026-08-05, guerrilla production

## Verdict

**PARTIAL.** The authenticated Paper reader is usable at wide, standard, and narrow widths: it has one local vertical scroller, wheel input over the Paper moves that scroller by the full requested 700px, the document itself never acquires global horizontal overflow, and wide tables expose their own `overflow-x:auto` surfaces. The 390×844 phone reader is not visually sound: the 288.7px Paper title occupies `x=83..371.7` while `Open standalone` occupies `x=157.1..294.8` and `Share` occupies `x=300.8..374`, producing measured overlaps of `137.7×20.8px` and `70.9×20.8px`. The Paper is also extremely long and spacer-heavy: 37 headings, 150 rendered empty paragraphs, and 50,064px of Paper height on desktop growing to 77,503px on phone.

Authentication was **not blocked**. An admin bearer minted a supported one-click login ticket (`POST /v1/auth/login-tickets` → 201); consuming it landed at authenticated scoped Studio with no login field. A direct token form POST without a browser CSRF token returned 403, but that was a rejected test method, not a Studio access gap.

## Exact browser sample

Playwright 1.59.1 / bundled Chromium, authenticated guerrilla Studio route:

`/w/default/p/default/d/production/studio/open/paper/cloud-console-hardening-wave-29-2026-08-03`

| Viewport | Paper / local scroller | Global overflow | Tables wider than their own client box | Wheel result | Visual result |
|---|---|---|---:|---|---|
| 1440×900 | Paper 720px; scroller 880×783, scrollHeight 50,064 | not_found: document 1440/1440 | 3, all `overflow-x:auto` | found: local `.bp-paper-body` 0→700 | found: clear three-column hierarchy; no measured header collision |
| 1024×768 | Paper 720px; scroller 723×651, scrollHeight 50,064 | not_found: document 1024/1024 | 3, all `overflow-x:auto` | found: local `.bp-paper-body` 0→700 | found: inspector collapses to rail; content remains readable |
| 640×900 | Paper/scroller 555px, scrollHeight 60,277 | not_found: document 640/640 | 5, all `overflow-x:auto` | found: local `.bp-paper-body` 0→700 | found: single reading column plus collapsed Structure/inspector rails; no measured top-header collision |
| 390×844 | Paper/scroller 349px, scrollHeight 77,503 | not_found: document 390/390 | 11, all `overflow-x:auto` | found: local `.bp-paper-body` 0→700 | **found defect:** Paper title collides with both header actions |

Viewport screenshots (ephemeral run evidence):

- `/private/tmp/legendary-paper-survey-05-normal-1440x900.png`
- `/private/tmp/legendary-paper-survey-05-standard-1024x768.png`
- `/private/tmp/legendary-paper-survey-05-narrow-640x900.png`
- `/private/tmp/legendary-paper-survey-05-phone-390x844.png`

Machine measurements:

- `/private/tmp/legendary-paper-survey-05-normal.json`
- `/private/tmp/legendary-paper-survey-05-standard.json`
- `/private/tmp/legendary-paper-survey-05-narrow.json`
- `/private/tmp/legendary-paper-survey-05-phone.json`

## Findings by requested concern

| Concern | Result | Evidence |
|---|---|---|
| Pinned authority | found | `bp doc get paper ... --perspective published --fields title,slug` returned `_rev=18768b0a14c2eead927181c4a0e37c18`, title `Cloud Console Hardening — wave 29 strategy`. |
| Authenticated access | found | Login-ticket mint 201; consume redirected to `/w/default/p/default/d/production/studio`; target route then rendered `Studio`, no login input. |
| Hierarchy | partial | Wide shows Structure, Paper header, reading surface, and Document inspector distinctly. Narrow/phone drill the surrounding panes away. Phone corrupts the Paper header hierarchy through title/action overlap. |
| Density | partial | 37 visible `h1/h2/h3`; content height 50,064px desktop, 60,277px narrow, 77,503px phone. This is complete content, but exceptionally costly to scan. |
| Blank space | found defect | 150 visible empty `<p>` elements exist inside the Paper at every viewport. The phone capture shows a conspicuous blank interval before `The wish`; these are part of the current baseline’s safe empty-paragraph-spacer class, not missing network content. |
| Vertical clipping | not_found | The document viewport remains exactly its viewport size; content resides in the single `.editor-body.editor-panel-main.bp-paper-body` scroller. |
| Horizontal clipping | not_found globally / partial locally | No document-level horizontal overflow. 3/3/5/11 tables exceed their own client width at 1440/1024/640/390, but each computes `overflow-x:auto`; table content therefore requires local horizontal scrolling rather than silently widening the page. Actual end-of-table horizontal scroll was not exercised. |
| Interaction obstruction | found defect on phone | The measured Paper title/action rectangles overlap. No visible fixed/sticky overlay was found at any sampled viewport. Buttons were not clicked because this survey was read-only and `Share` may open stateful UI. |
| Scroll behavior | found | Hovering the Paper center and issuing `mouse.wheel(0,700)` moved only `.bp-paper-body` by 700px at all four viewports; global document remained fixed. |

## Repository anchors checked

| File / durable object | What was checked | Result |
|---|---|---|
| `CLAUDE.md` | repo safety, routing, task/Paper operating contract | found |
| `.omx/context/legendary-paper-reader-upgrade-20260805T205600Z.md` | immutable wave, task `task-a768c69e659add58`, Paper/revision, survey stop rules | found |
| `docs/cards/studio.md:4-20` | scoped Studio route, width buckets, protected content, inspector behavior | found |
| Paper `cloud-console-hardening-wave-29-2026-08-03`, rev `18768b0a14c2eead927181c4a0e37c18` | current published identity and actual authenticated Studio rendering | found |
| `api/lib/barkpark_web/live/studio/studio_live/components.ex:159-210` | Paper header actions; `Open standalone` and `Share` markup | found |
| `api/lib/barkpark_web/live/studio/studio_live/components.ex:231-241` | local `.bp-paper-body` scroll wrapper and Paper surface | found |
| `api/lib/barkpark_web/components/studio_components/editor.ex:63-82` | header uses two flex children; title side has no `min-width:0`, actions side has `flex:1` | found; plausible collision seam, not a proved root cause |
| `api/lib/barkpark_web/layouts/root.html.heex:1234-1246` | pane title ellipsis/action CSS | partial: generic title supports ellipsis, but the rendered header’s left inline flex wrapper is separate from `.pane-header-titlewrap` |
| `api/lib/barkpark_web/layouts/root.html.heex:1257-1337` | width-bucket/content-floor intent | found |
| `api/lib/barkpark_web/layouts/root.html.heex:3878-3891` | Paper responsive gutters and body surface | found |

## Facts versus inference

Facts are the revision response, ticket/auth responses, DOM rectangles, computed overflow values, element counts, screenshots, and scroll deltas above. The likely cause of the phone collision is the header’s unconstrained left inline flex container competing with a flex-growing actions container; that is **inference**, because this survey did not run a CSS deletion or mutation experiment. The claim that 150 empty paragraphs materially worsen scan cost is also a visual/product inference, though their existence and rendered height are measured facts.

## Risks requiring targeted proof

1. Prove the smallest CSS repair for the phone header with a positive-control visual test; do not simply hide all actions or the full title.
2. Exercise horizontal scrolling on representative widest tables at 390px and verify keyboard/touch discoverability; computed `overflow-x:auto` proves a scroll surface, not discoverability.
3. Determine which of the 150 empty paragraphs are intentional spacers versus source noise before removing any; this survey did not mutate or adjudicate individual spacers.
4. Recheck 320px and zoomed/text-scaled states. The collision already exists at 390px, so smaller or enlarged-text states are high risk.

## Unvisited / explicit coverage edge

- No 320px, 480px, landscape-phone, browser zoom, forced text scaling, dark theme, or reduced-motion samples.
- No keyboard traversal, screen reader, touch gesture, or table end-to-end horizontal-scroll proof.
- No clicks on `Open standalone`, `Share`, inspector, or edit controls.
- No draft perspective and no Paper revisions other than the frozen published revision.
- No second browser engine; Chromium only.
- No CSS mutation experiment; root-cause statement remains inference.

## Reproduction command shape

The run used Playwright resolved from `/Volumes/SATECHI/github/barkpark/js/package.json`, minted a one-click ticket with the configured guerrilla bearer, consumed it in the same browser context, set each viewport explicitly with `page.setViewportSize`, opened the scoped Paper route, measured the DOM, wheeled 700px over the Paper center, and captured the viewport. Secrets were never printed or written to this ledger.
