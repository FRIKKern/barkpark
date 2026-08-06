<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-23 | budget: 1400tok -->
# Restart Survey 23 — CCH29 public live regression and frozen gates

Assignment `restart-survey-23` re-attested `cloud-console-hardening-wave-29-2026-08-03::public` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **unchanged failure with landmark and focus passes; real assistive technology remains blocked**.

## Direct answer

Five live HTTP fetches and two fresh Chrome navigations for revision `18768b0a14c2eead927181c4a0e37c18` all succeeded without stalls or 500s. Stable structure includes 252 unique block wrappers, main/article/H1, language `en`, 11 tables, 35 header cells, and four callouts. Raw hashes vary only through request-specific page material.

Fresh comparison reproduced both empty wrappers: `w29D015` and `w29D022` contain source text but zero reader text. Visible block parity is 250/252; paragraph-wrapped list preservation is 0/11 items and 0/406 words.

## Fresh geometry and interaction

At requested width 320, client width was 320 but the page expanded to 379 pixels: failure. At 390, document and client width remained 390: pass. Geometry is unchanged at 1/2. All 11 tables reflowed to 240 pixels at 320 and 310 at 390.

Actual CDP Tab events reached nine targets at each width; all 18/18 matched focus-visible. Main/article/H1/lang landmarks passed 2/2. These are browser interaction and DOM facts, not VoiceOver or NVDA proof.

## Frozen-gate ruling

Identity-only accounting passes at 252/252 wrappers. Revision remains failed because the reader exposes `0`, not `_rev`, and has no ETag. Text/list loss remains failed. All 11 tables are presentational with no scope/caption. Only three semantic mark elements survive versus 313 source mark records. Four callouts have zero accessible roles/tone labels. Source retains 139 empty spacers. Navigation lacks outline, pager, history, and structured task links. Geometry fails 1/2, while landmarks and focus pass. Real AT remains 0/2 blocked.

The prior transient width-320 500 was not reproduced in 7/7 current operations, but a short clean run does not erase historical risk. No mutations ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-23","unit":"cloud-console-hardening-wave-29-2026-08-03::public","revision":"18768b0a14c2eead927181c4a0e37c18","verdict":"unchanged_failure_with_landmark_and_focus_passes_real_at_blocked","live":{"http_success":"5/5","browser_success":"2/2","stalls":0,"transient_500_reproduced":false,"bytes":280162},"text":{"block_wrappers":"252/252","visible_blocks":"250/252","missing":["w29D015","w29D022"],"nested_items":"0/11","nested_words":"0/406"},"semantics":{"tables":11,"presentation_tables":11,"header_cells":35,"scoped_headers":0,"captions":0,"callouts":4,"labeled_callouts":0,"source_marks":313,"reader_semantic_marks":3},"geometry":{"320":{"client":320,"inner":379,"scroll":379,"pass":false},"390":{"client":390,"inner":390,"scroll":390,"pass":true},"score":"1/2"},"landmarks":"2/2","keyboard_focus":"18/18","reader_revision":"0","etag":null,"real_at":{"status":"blocked","cch29_cells":"0/2"}}
```
