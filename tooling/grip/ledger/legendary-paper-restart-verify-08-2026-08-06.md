<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-08 | budget: 1900tok -->
# Restart Verify 08 — email narrow-layout containment

Assignment `restart-verify-08` tested whether HTTP email preview honors real 320/390 layout widths and contains wide tables locally. Verdict: **refuted**.

All four current source pins reproduce their frozen revisions/counts. Chrome 150 mobile emulation exercised eight width/Paper cells using exact previously captured HTTP-preview bodies served unchanged from a disposable local origin; all eight response hashes matched. The preview contains no viewport metadata in 0/8 cells. Requested 320/390 layouts therefore became effective 980–1,277 CSS-pixel layouts with scale factors 0.2506–0.3980. Exact requested layout passed 0/8 and page containment relative to the requested width passed 0/8.

Across 92 table instances (46 unique tables at two widths), 0/92 fit the requested width and 0/92 had an ancestor providing explicit local overflow containment. Tables ranged from 600 to 1,086.97 pixels wide and began at x=190. Even against the inflated effective DOM width, CCH28 overflowed 65–66 pixels and PDS45 297 pixels in four cells.

| Paper | 320 effective / overflow | 390 effective / overflow | Tables contained |
|---|---:|---:|---:|
| CCH28 | 1046 / 726px | 1045 / 655px | 0/36 |
| CCH29 | 980 / 660px | 980 / 590px | 0/22 |
| PDS44 | 980 / 660px | 980 / 590px | 0/10 |
| PDS45 | 1277 / 957px | 1277 / 887px | 0/24 |

The absent `<meta name="viewport">` makes mobile Chromium create a desktop fallback layout viewport, then shrink the entire page into the device screen. That is shrink-to-fit, not responsive 320/390 layout or local table scrolling. Geometry evidence SHA-256 is `43ec34ae04cf2a198d28db529142130f3cf85980ee280e828f9dc5b782816845`.

Current live flat/dataset/scoped preview routes independently returned 404 in 12/12 probes, so contemporaneous body recapture was unavailable. The exact preserved preview bytes still decisively refute the format geometry, while the 404s separately refute current route availability. This assignment makes no MIME, delivery, or real-client claim.

## Cycle payload

```json
{"assignment_id":"restart-verify-08","cycle_uuid":"3edf6b14-50e3-49ac-a288-902410191ed0","verdict":"refuted","papers":"4/4 rev+count exact","browser":"Chrome 150.0.7871.189 mobile emulation","cells":"8/8 exercised","viewport_meta":"0/8","exact_requested_layout":"0/8","zero_page_overflow_requested":"0/8","tables_requested_fit_or_local":"0/92","explicit_local_containment":"0/92","live_routes":"0/12 200; 12/12 404","body_hashes":"4/4 exact","geometry_sha256":"43ec34ae04cf2a198d28db529142130f3cf85980ee280e828f9dc5b782816845","mutations":0,"delivered_mime_clients":"not_inferred","residual_risk":["live preview 404 prevents contemporaneous HTML recapture","no Gmail/Outlook/Apple Mail claim"]}
```
