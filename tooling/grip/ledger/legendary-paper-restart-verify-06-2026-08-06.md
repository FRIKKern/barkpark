<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-06 | budget: 1800tok -->
# Restart Verify 06 — public/email structural semantics

Assignment `restart-verify-06` mapped frozen source tables, marks, and callouts to fresh public/email DOM semantics. Verdict: **refuted**.

All four source pins match exactly and both surfaces returned `200` for all Papers. Live denominators confirm 815 blocks, 46 tables, 113 authored header cells, 11 headerless tables, 388 mark records (147 strong and 241 code), and 30 callouts.

Both readers render all 46 tables with `role="presentation"`; none is data-semantic. All 113 header texts survive in `<th>` elements, but 0/113 provide `scope`, `headers`, or associated IDs. All 387 nonempty marked texts survive, while the 388th record is an authored empty strong run with no visible proposition; neither reader emits a semantic `<strong>` or `<code>` carrier for any of the 388 records. PDS45's eight map-form strong marks become visual `font-weight:bold` spans only.

All 30 callout bodies map by source text, but both readers emit 0/30 semantic roles and 0/30 accessible names. Source tone vocabulary is 14 absent, 6 `info`, 1 `note`, 4 `warn`, and 5 `warning`; output collapses this to 25 info/blue and five warning/amber, visually misclassifying `note` and `warn` as well.

| Carrier | Source | Public semantic | Email semantic |
|---|---:|---:|---:|
| Data tables | 46 | 0/46 | 0/46 |
| Associated headers | 113 | 0/113 | 0/113 |
| Strong/code marks | 388 | 0/388 | 0/388 |
| Callout roles | 30 | 0/30 | 0/30 |
| Callout names | 30 | 0/30 | 0/30 |

The implementation explicitly emits presentation-table roles and roleless callout divs. The inline renderer recognizes some map-form marks but legacy string marks fall through; existing tests lock visual presentation behavior rather than accessible semantics. Public block IDs allow direct localization; email localization used exact pinned source keys, canonical ordinals, and full callout-text matching.

No VoiceOver/NVDA or real mail-client session ran. Those are required after repair but cannot rescue the current claim because the prerequisite DOM semantics are absent.

## Cycle payload

```json
{"assignment_id":"restart-verify-06","cycle_assignment_id":"90720300-39dc-4025-8ceb-cd726a5ec9e8","verdict":"refuted","source":{"papers":4,"blocks":815,"tables":46,"headers":113,"headerless_tables":11,"marks":388,"mark_types":{"strong":147,"code":241},"callouts":30},"public":{"http_200":"4/4","presentation_tables":"46/46","associated_headers":"0/113","nonempty_mark_text_survival":"387/387","semantic_marks":"0/388","semantic_callout_roles":"0/30","accessible_callout_names":"0/30"},"email":{"http_200":"4/4","presentation_tables":"46/46","associated_headers":"0/113","nonempty_mark_text_survival":"387/387","semantic_marks":"0/388","semantic_callout_roles":"0/30","accessible_callout_names":"0/30"},"tone_mapping":{"source":{"none":14,"info":6,"note":1,"warn":4,"warning":5},"output":{"info":25,"warning":5}},"mutations":0}
```
