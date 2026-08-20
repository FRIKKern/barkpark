# pe-w5 live BEFORE pixels — re-derivation recipe (2026-08-17)

Captured the epic-criterion-2 BEFORE evidence on guerrilla live BEFORE the LAND merges
(#11854 hairline grid / #11814 fixtures / framed-finale authoring) destroy it. 8 full-page
PNGs under `tooling/paper-excellence/evidence/pe-w5-live-before/` (untracked; Decide commits).

## Theme selection on the live reader (NAMED)

The reader is a LiveView; the layout is `api/lib/barkpark_web/layouts/bulldocs.html.heex`.
A SYNCHRONOUS pre-paint `<script>` (lines 26-39) stamps `html[data-theme]`:

    document.documentElement.dataset.theme = localStorage.getItem("barkpark_theme") || osTheme();
    // osTheme() = matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"

- Persisted choice key: `barkpark_theme` (shared with Studio).
- On guerrilla the reader's `localStorage` is EMPTY (verified: `Object.keys(localStorage) == []`),
  so the stamp defaults to `prefers-color-scheme`.
- The generated `html[data-theme=...]` companion CSS blocks key off the stamp; the
  `@media (prefers-color-scheme:...)` blocks are the no-JS / first-paint fallback.

=> To force a theme in chrome-devtools: `emulate colorScheme:dark|light` then RELOAD (the
pre-paint reads the media feature at document load; emulate-then-reload flips the stamp).
Verified round-trip: emulate light+reload -> data-theme="light", bodyBg rgb(231,240,242);
emulate dark+reload -> data-theme="dark", bodyBg rgb(12,20,23). html also carries
`data-bp-theme="fjord"` (site palette, orthogonal to light/dark).

## Re-derive the captures

    # 1. confirm both papers 200
    curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/papers/eight-minute-erasure
    curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/papers/hobby-hardening-capstone

    # 2. chrome-devtools MCP, per {paper} x {1280,1920} x {light,dark}:
    #    new_page/navigate url -> resize_page {w}x{1000|1080}
    #    -> emulate colorScheme:{scheme} -> navigate reload
    #    -> evaluate: assert data-theme=={scheme} AND liveSocket.isConnected()==true (HYDRATED)
    #    -> take_screenshot fullPage:true filePath .../{paper}_{w}_{scheme}.png

    # 3. verify
    ls -la tooling/paper-excellence/evidence/pe-w5-live-before/ && \
      file tooling/paper-excellence/evidence/pe-w5-live-before/*.png

## What landed (all 8, every one confirmed phxConnected==true before shooting)

    eight-minute-erasure_1280_light.png      2560 x 22202
    eight-minute-erasure_1280_dark.png       2560 x 22202
    eight-minute-erasure_1920_light.png      3840 x 22812
    eight-minute-erasure_1920_dark.png       3840 x 22812
    hobby-hardening-capstone_1280_light.png  2560 x 65294
    hobby-hardening-capstone_1280_dark.png   2560 x 65294
    hobby-hardening-capstone_1920_light.png  3840 x 61342
    hobby-hardening-capstone_1920_dark.png   3840 x 61342

PNG pixel width is 2x the CSS width (devicePixelRatio 2 / retina). Full-page heights.

## BEFORE-state facts (what the after must beat)

At capture time on live HEAD (pre-LAND):
- `.bp-section--framed` count on eight-minute-erasure = 0 (framed finale NOT yet authored).
- `.bp-figure-grid` / hairline grid: `document.querySelector('.bp-figure-grid,[class*=grid]')`
  returned null on eight-minute-erasure (grid not present in served build).
- These two nulls are the crown-dark baseline the wish exists to light.
