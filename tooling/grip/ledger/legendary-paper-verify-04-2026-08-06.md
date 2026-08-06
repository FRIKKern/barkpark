<!-- doc-tier: cold | canonical-for: legendary-paper-verify-04-evidence | budget: 1600tok -->
# Verify 04 — public-reader responsive geometry

Verdict: `refuted`. Fresh Chromium geometry proves desktop containment, but six of eight narrow Paper cases widen the page, every narrow case places fixed reader controls over authored content, and 45 of 46 tables require internal horizontal scrolling at both 390px and 320px.

| Paper | 390px page overflow | 320px page overflow | narrow control overlap | narrow tables scrolling |
| --- | ---: | ---: | ---: | ---: |
| Cloud Console wave 29 | 0 | 59px | 4/5 sampled positions | 11/11 |
| PDS wave 45 | 127px | 197px | 4/5 | 12/12 |
| Cloud Console wave 28 | 57px | 233px | 4/5 | 17/18 |
| PDS wave 44 | 0 | 142px | 4/5 | 5/5 |

- All four 1440×1000 cases are page-contained and unobstructed. Their full heights range from 29.94 to 50.48 screens.
- Narrow full heights range from 60.55 to 91.30 screens at 390×844 and 110.61 to 154.46 screens at 320×568.
- Exact leaf probes identify unbreakable paths, 40-character hashes, symbols, and slash tokens under `overflow-wrap: normal; word-break: normal` as root page-overflow sources.
- `.bp-table` correctly contains table overflow with `display: block; max-width: 100%; overflow-x: auto`; tables were not root page-overflow contributors. The remaining defect is a severe, undisclosed interaction burden.
- Fixed Email/TUI controls cover 27.5–32.5% of the 310px reading column at 390px and 35.5–42.0% of the 240px column at 320px. DOM intersections occur at four of five sampled scroll positions for every narrow Paper.
- Retaining 40px side padding at phone widths reduces usable measure. Padding reduction alone cannot solve the observed 300–513px tokens; general prose-token wrapping and mobile control relocation or reserved space are both required.

The proof covered all 815 authored block wrappers, 46 tables, two fixed controls per case, four Papers, three viewports, and five scroll positions. The sealed artifact manifest contains 12 geometry censuses and 30 screenshots at `/Volumes/SATECHI/dev-caches/tmp/verify04-public-final-0hys95ui/manifest.json`, SHA-256 `50ba5ea911ad8bf2f99ed27a5e0e4b92559b0ee643a71c6b361c12397cbdb63d`.

Residual risk: the browser proof used Chromium 147; Safari/Firefox measurement and native hyphenation may differ. Touch discoverability and actual swipe behavior remain for an interaction proof. No repository, task, or Paper mutation occurred.
