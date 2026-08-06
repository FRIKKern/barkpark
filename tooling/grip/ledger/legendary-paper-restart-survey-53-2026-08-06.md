<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-53 | budget: 1400tok -->
# Restart Survey 53 — PDS45 public live regression

Assignment `restart-survey-53` re-attested `pds-wave-45-2026-08-03::public` at exact revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **partial; completeness and outline pass, while narrow geometry, control overlap, semantics, and revision identity remain failed**.

Flat public HTML/source, dataset HTML, and scoped HTML/source were stable at 15/15 HTTP 200. Source was byte-identical at 91,515 bytes/SHA `e19503ef…1e8`; full LiveView HTML hashes varied only with ephemeral page tokens. DOM/source parity is exact: 227/227 unique ordered block IDs, 103 visible blocks plus 124 empty wrappers, headings `1/23/9` without jumps, and seven lists/44 items.

Desktop at 1440px has zero page overflow, though 4/12 tables scroll internally. At 390px the 310px article sits in a 517px document, causing 127px overflow; at 320px the 240px article still sits in a 517px document, causing 197px overflow. All 12 tables scroll internally at both phone widths. Fixed TUI/email controls overlap authored text at 3/5 sampled scroll positions; the prior 4/5 sample lacked exact fractions, so this remains failure rather than improvement.

Semantics are unchanged: 12/12 tables use `role=presentation`, 0/9 headers have scope, 9/9 callouts lack role/label/heading, and authored strong is absent. Main/article and `lang=en` are positive. Page title remains generic, `data-rev=0` is not content identity, and flat routes expose no validator/revision header. Safari, Firefox, touch, AT, zoom, print, dark mode, connected races, and pixel diffs remain unvisited. No mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-53","unit":"pds-wave-45-2026-08-03::public","verdict":"partial","paper_rev":"b992fd8aaa028b0dab30a8da76f077fd","routes":"15/15 200","blocks":"227/227 exact ordered IDs","geometry":{"desktop_overflow":0,"390_overflow":127,"320_overflow":197,"narrow_table_scroll":"12/12","control_overlap":"3/5 fresh; failure unchanged"},"semantics":{"presentation_tables":"12/12","scoped_headers":"0/9","semantic_callouts":"0/9","authored_strong":0},"identity":"flat unbound","mutations":0}
```
