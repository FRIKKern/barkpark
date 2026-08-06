<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-07 | budget: 1900tok -->
# Restart Verify 07 — public phone/zoom usability

Assignment `restart-verify-07` tested public Paper containment, fixed-control obstruction, and table keyboard ownership at narrow widths under a declared 200% browser-layout reflow model. Verdict: **refuted, 0/8 strict cells**.

Playwright 1.59.1 drove Chromium with DPR2, non-mobile/no-touch: physical 390×844 became a 195×422 CSS viewport and physical 320×568 became 160×284. This tests layout reflow, not pinch zoom. All four frozen sources remained exact, and all public/source routes returned `200`.

Every cell overflowed horizontally with `documentElement` as scroll owner: CCH28 by 252/393px, CCH29 184/219px, PDS44 182/302px, and PDS45 322/357px at 390/320 respectively. Containment therefore passes 0/8.

Both fixed controls obstructed a real nonempty authored block at scroll fractions 0, .25, .5, and .75 in every cell. The bottom sample hit only blank trailing article space and was correctly excluded. The observed obstruction is 32/40 sampled positions and violates the zero-obstruction threshold in 8/8 cells.

Table behavior is substantially better but not sufficient. All 92 wide table instances use local `overflow-x:auto`, enter natural forward and reverse Tab order, scroll locally with ArrowRight, and exit with Tab. Strict horizontal ownership passes 90/92: two CCH28 tables at 390px reached their local edge before the fourth ArrowRight and then also panned the overflowing page.

| Paper | Overflow at 390 / 320 | Contained cells |
|---|---:|---:|
| CCH28 | 252 / 393px | 0/2 |
| CCH29 | 184 / 219px | 0/2 |
| PDS44 | 182 / 302px | 0/2 |
| PDS45 | 322 / 357px | 0/2 |

Article hashes were stable across both zoom cells per Paper; raw LiveView response hashes varied with request-scoped tokens. An early 750ms keyboard pass was discarded because the connected LiveView morph replaced focused tables; the final pass waited four seconds and used natural keyboard traversal.

Residuals are Chromium-only coverage, no pinch zoom, touch, Safari/Firefox, or real assistive technology. No screenshot was retained, but geometry, hit-testing, keyboard state, source pins, and stable article hashes provide the required direct evidence.

## Cycle payload

```json
{"assignment_id":"restart-verify-07","assignment_uuid":"afd3fbc9-fbca-46d5-8487-9b425f1b758a","verdict":"refuted","model":"200% layout reflow: 390x844->195x422 CSS; 320x568->160x284 CSS; DPR2","cells":"0/8","contained":"0/8","page_overflow_px":{"w28":[252,393],"w29":[184,219],"p44":[182,302],"p45":[322,357]},"rendered_block_obstruction":"32/40 positions; 8/8 cells fail zero-obstruction","tables":{"wide":92,"local_scrollable":92,"natural_tab_entry":92,"arrow_local_scroll":92,"tab_escape":92,"reverse_entry":92,"strict_page_x_stable":90},"public_routes":"8/8 HTTP 200","source_pins":"4/4 exact","mutations":0,"residual":["Chromium only","no pinch/touch/real AT","2 tables chain ArrowRight to page after local edge"]}
```
