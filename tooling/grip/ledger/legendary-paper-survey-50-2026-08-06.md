<!-- doc-tier: cold | canonical-for: legendary-paper-survey-50-evidence | budget: 1200tok -->
# Survey 50 — PDS wave 44 / Studio reader

Verdict: `partial`. Live Studio renders the complete Paper without page-level horizontal overflow at desktop, 390px, and 320px, but drops all 12 source table headers, becomes extremely tall on mobile, and clips important controls.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; 99 blocks and exact slug sentinel reached a connected LiveView.
- Live matrix: 1440×900 produces a 720×38,042 Paper surface, 640px content, 48.6 internal screens, and 3/5 horizontally scrolling tables. At 390×844 it is 349×62,236, 317px content, 90.1 screens, 5/5 scrolling tables. At 320×568 it is 279×76,192, 247px content, 183.6 screens, 5/5 scrolling tables.
- Every viewport retained 1 H1, 24 H2, seven H3, 133 rendered paragraph elements, and five tables. Paper `scrollWidth == clientWidth`; body owns vertical scrolling; no fixed/sticky Paper navigation or content links exist.
- Confirmed parity defect: Studio rendered zero `<th>` cells and 54 rows although source carries 12 headers across three tables. `run-convert.js` reads only `block.head`; the Paper stores legacy `header`. The public reader previously rendered all 12 headers and 57 rows. This is schema compatibility loss, not CSS.
- Responsive gutters shrink from 40px to 16px, but phone mode removes both list panes while shell/editor overflow is clipped. At 390px and 320px, toolbar controls beginning at x=420 are unreachable; document Share begins at x=724. Network shares, theme, sign-out, presence/profile, and Share are wholly offscreen.
- Studio defaults to an always-editable canvas rather than a dedicated read-only reader. Open standalone exists in source, but its mobile reachability was not captured. Footer word/block/save status is tens of thousands of pixels below entry.
- Exact revision identity was established from pinned source data; the live editable DOM exposed the slug sentinel but no immutable revision marker.

Evidence includes `/private/tmp/s50-live-direct.ndjson`, the pinned source artifact, live three-viewport browser measurements, and inspection of `run-convert.js`, `table-node.js`, `blocks.ex`, Studio components/editor, and root layout CSS. Verify must prove dual `header`/`head` conversion and safe round trip, accessible mobile overflow actions, prominent standalone escape or compact mode, and long-document outline/progress behavior. No state mutation occurred.
