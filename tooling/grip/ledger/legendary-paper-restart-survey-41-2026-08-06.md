<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-41 | budget: 1400tok -->
# Restart Survey 41 — PDS44 Studio live regression and frozen gates

Assignment `restart-survey-41` re-attested `pds-wave-44-2026-08-03::studio` at exact revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **partial unchanged failure with mobile geometry regression**. A fresh authenticated connected LiveView still renders all 99 blocks, but both phone layouts grew narrower and longer, all 12 table headers remain lost, and primary actions remain unreachable.

Frozen geometry denominator is three viewports:

- 1440×900: surface/content `720/640`; height 38,090px versus 38,042 baseline — unchanged.
- 390×844: surface/content `343/311` versus `349/317`; height 63,236px versus 62,236 — regression.
- 320×568: surface/content `273/241` versus `279/247`; height 77,903px versus 76,192 — regression.

Page-level containment passes `3/3`, but tables internally overflow `3/5` desktop and `5/5` on both phones. The Paper requires roughly 48.6, 91.5, and 187.5 internal screens respectively. Open standalone begins at x=580 and Share at x=724, making action reach `0/2` phone widths—unchanged failure.

All source type totals survive: 32 headings, 48 paragraphs, five tables, ten lists, four callouts, 99/99 blocks. Semantic preservation does not: source has 12 table headers; Studio renders `0/12`, and `0/5` tables contain TH. Current conversion reads only `block.head` while this Paper uses compatible legacy `header`.

Anonymous exact route redirects to login and missing workspace returns typed 404. Missing-Paper and draft initial authenticated requests return the shell; terminal post-LiveView states were not observed. Fresh keyboard/AX behavior, table-edge escape, inspector focus return, and real assistive technology remain unvisited. No test-suite pass or mutation is claimed.

## Cycle payload

```json
{"assignment_id":"restart-survey-41","unit":"pds-wave-44-2026-08-03::studio","verdict":"partial unchanged failure with mobile regression","paper":{"rev":"8bbd5d874a1b697f1e4e437c473f8e52","blocks":"99/99"},"geometry":{"denominator":3,"unchanged":1,"improved":0,"regressed":2,"desktop_height":38090,"390_height":63236,"320_height":77903,"page_containment":"3/3"},"content":{"type_totals":"5/5","source_headers":12,"studio_headers":"0/12","tables_with_th":"0/5"},"responsive_actions":{"reachable":"0/2 phone widths"},"errors":{"proven":"2/4","terminal_live_errors":"unvisited"},"keyboard_ax":"unvisited_live","mutations":0}
```
