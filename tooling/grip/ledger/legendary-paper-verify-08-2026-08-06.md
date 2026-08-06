<!-- doc-tier: cold | canonical-for: legendary-paper-verify-08-evidence | budget: 1800tok -->
# Verify 08 — Studio responsive geometry and operability

Verdict: `refuted`. Studio is coherent at 1440×1000 and correctly keeps vertical and table scrolling local to the Paper. At 390×844 and 320×568, its invariant 585px topbar and unconstrained nowrap Paper header clip essential controls and collide with every title.

| Paper | 1440 height / local screens | 390 height / screens | 320 height / screens |
| --- | ---: | ---: | ---: |
| Cloud Console wave 29 | 50,064 / 56.70 | 77,503 / 112.16 | 88,764 / 213.89 |
| Cloud Console wave 28 | 66,509 / 75.32 | 94,413 / 136.63 | 107,064 / 257.99 |
| PDS wave 45 | 47,773 / 54.10 | 72,463 / 104.87 | 83,298 / 200.72 |
| PDS wave 44 | 38,042 / 43.08 | 62,236 / 90.07 | 76,192 / 183.60 |

- Local Paper geometry is 880×883px with a 720px Paper at desktop, 349×691px at 390, and 279×415px at 320.
- Wheel input over every Paper moves `.bp-paper-body` exactly `0→700` while `window.scrollY` remains zero. The widest table in every row accepts direct horizontal scrolling to its maximum.
- Desktop has zero title/action collisions and all measured controls are reachable. All twelve final captures have zero document-level horizontal overflow and bounded Paper widths.
- At 390, `.studio-bar` is 390 client / 585 scroll; at 320 it is 320 / 585. The shell clips the 195/265px excess instead of exposing a reachable horizontal lane.
- At 390, Settings is partly clipped and Network shares, theme, sign-out, and presence are fully offscreen. At 320, Style is partly clipped while Connectors, Settings, Network shares, theme, sign-out, and presence are fully offscreen.
- Project selection overlaps six tabs by 32×30px and Chat by 1.2×30px at both narrow widths.
- Every Paper title overlaps both document actions. Open-standalone overlap is 137.69×20.8px and Share is about 73.2×20.8px. Wave 28 and PDS 44 place both actions entirely beyond the viewport; Wave 29 and PDS 45 partly retain actions at 320.
- Intrinsic editor overflow at 390/320 is: wave 29 0/52px, wave 28 441/511px, PDS 45 0/64px, and PDS 44 408/478px. Page-width containment therefore hides controls rather than proving usable responsiveness.

The initial three-second Wave 28/390 capture reproduced an empty-canvas race: the 237-block footer appeared before headings/tables. Waiting for `.phx-connected` rendered 1 H1, 24 H2, 18 H3, and 18 tables at 94,413px, stable across two identical screenshot hashes. This corrects the older claim of permanent content loss but retains an initialization race for a later operational probe.

Deployed causes are exact: the full-viewport shell uses `overflow:hidden`; the topbar remains a three-column `1fr auto 1fr` grid with gaps and no phone override; title-side flex lacks `min-width:0`; the title is nowrap beside unconditional full-label actions. Table-local `overflow-x:auto` is working correctly.

All twelve captures returned HTTP 200. Geometry artifact `/private/tmp/verify08-studio-geometry.json` has SHA-256 `22bb977066271fd0c4b599977fd59c426c6892dd7bca978b1cca92d18dcef13c`; the Wave 28 connected replacement JSON is `4856097797cdf7dacd01bb91d600044feff5ae174502ec6d3716fed8af1f663b`. Chromium-only residuals are touch, zoom/text scaling, Safari/Firefox, keyboard-only traversal, and screen readers. No action was activated and no content mutation occurred.
