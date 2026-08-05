<!-- doc-tier: cold | canonical-for: legendary-paper-survey-47-evidence | budget: 1200tok -->
# Survey 47 — PDS wave 44 / public reader

Verdict: `partial`. Hierarchy and internally scrollable tables survive, but the Paper is extremely tall, lacks orientation/navigation, and develops 142 pixels of page-level overflow at 320 pixels.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; production dead render is HTTP 200 / 255,624 bytes with exact slug sentinel.
- Deterministic Chromium dead-render geometry: 1440×1000 yields a 720-pixel main / 640-pixel content region and 29,937-pixel document height; 390×844 yields 310-pixel content, 51,107-pixel height, and no page overflow; 320×568 yields 240-pixel content, 62,827-pixel height, and 462-pixel scroll width—142 pixels beyond the viewport.
- The article retains `56px 40px 96px` padding at every width. Horizontal padding consumes 20.5% of a 390-pixel viewport and 25% at 320 pixels.
- Typography remains desktop-sized on mobile. The H1 grows from 105.6 pixels tall on desktop to 246.3 at 390 and 281.5 at 320. All 32 Paper headings preserve their coherent hierarchy.
- All five tables use internal `overflow-x:auto`, avoiding table clipping. Every table needs horizontal scrolling at 390/320 pixels; the widest internal measures are 602 and 595 pixels. The largest 21-row table is 4,437 pixels tall on desktop and 4,853 on mobile.
- The Paper spans about 30 desktop screens, 61 screens at 390, and 111 screens at 320, with no navigation landmark, TOC, progress, footer, back-to-top, Related, driven tasks, backlinks, or history link.
- Fixed Email/TUI view buttons form a 75-pixel stack at every width. At 320×568 they occupy about 13.2% of viewport height and remain over the reading surface; focus-visible styling exists.
- Public DOM exposes `data-rev="0"`, not the pinned content revision. The Paper body contains no visible anchors; JavaScript-connected keyboard behavior remains partial.

Verify must isolate the 320-pixel overflow source, reduce mobile padding/type scale, add long-document orientation, collapse or auto-hide fixed controls, show table-scroll cues, expose content revision, and rerun connected LiveView geometry. No state mutation occurred.
