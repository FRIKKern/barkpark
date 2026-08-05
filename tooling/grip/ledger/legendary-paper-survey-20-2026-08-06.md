<!-- doc-tier: cold | canonical-for: legendary-paper-survey-20-evidence | budget: 1200tok -->
# Survey 20 — PDS wave 45 / Studio reader

Verdict: `partial`. Studio is coherent and independently scrollable at 1440 and 800 pixels, but its 390-pixel top bar overlaps and hides six controls beyond an overflow-clipped shell.

- Authority: revision `b992fd8aaa028b0dab30a8da76f077fd`; 227 blocks with 124 empty paragraphs.
- Document height is 47,837 pixels at 1440, 48,222 at 800, and 73,569 at 390. All 12 tables remain bounded horizontal-scroll regions.
- At 1440×900, panes are Structure 44, Papers 260, Editor 1,136, and inspector 300 pixels. Wheel input over the document changes only document scroll; the list and window remain fixed.
- At 800×900, Papers collapses to a 44-pixel strip, inspector to a 41-pixel disclosure strip, breadcrumbs preserve escape routes, and the paper retains a 629-pixel canvas. Focus autoscroll reveals table controls.
- At 390×844, the editor is single-pane, the canvas is 311 pixels, tables stay contained, and document scrolling remains internal.
- The phone top bar is broken: a 390-pixel bar has 617 pixels of scroll width inside an overflow-hidden shell. Navigation overlaps the scope selector; Settings clips; Network shares, Theme, Sign out, presence user, and current-user presence are fully offscreen.
- The title also collides visually with Open standalone and Share. The bar retains a three-column grid, fixed tab rail, and non-shrinking right rail without a phone override.
- No page-level overflow or scroll coupling was found at desktop/narrow widths; default inspector behavior preserves reading width.

Clean focus traversal through clipped controls, inspector overlay behavior, keyboard table scrolling, block-level gap judgment, light theme, zoom, screen readers, touch targets, and explicit sidebar states remain unvisited. No state mutation occurred.
