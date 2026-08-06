<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-50 | budget: 1400tok -->
# Restart Survey 50 — PDS45 email live regression and frozen gates

Assignment `restart-survey-50` re-attested `pds-wave-45-2026-08-03::email` at exact revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **partial regression with live route instability**. Content/structure is unchanged; overflow and semantics remain failed; 320px adds new proof of the existing narrow-layout defect.

Initial flat/dataset/scoped sampling passed `9/9` HTTP 200 with identical 119,290-byte/SHA `3e29bd38…a900` HTML. Structure remains 103 substantive renders from 227 blocks after 124 empty paragraphs suppress: H1/H2/H3 `1/23/9`, 42 paragraphs, seven lists/44 items, 12 tables/119 rows/398 cells.

Geometry:

- 1440px: document width 1,507px, overflow 67px; 4/12 tables exceed 600px; widest 1,086.97px.
- 390px: content 318px, document 1,123px, overflow 733px; all tables exceed content, 9/12 cross viewport; widest initially 32.6% visible.
- 320px: content 248px, document 1,123px, overflow 803px; all 12 cross viewport; widest initially 26.1% visible.

Semantics remain failed: 12/12 presentation tables; 9/9 headers lack scope; 9/9 callouts lack role; zero semantic strong, anchors, landmarks/note roles; missing HTML language.

Later in this lens, the same live paths returned stable plain 404 while CLI still found the Paper. This does not erase earlier 9/9 proof or other concurrent successful active-origin reads; it records route/host/server-state instability requiring a pinned-process rerun. No ETag exists. No mail was sent and no real-client result is claimed.

## Cycle payload

```json
{"assignment_id":"restart-survey-50","unit":"pds-wave-45-2026-08-03::email","verdict":"partial regression with live route instability","paper":{"rev":"b992fd8aaa028b0dab30a8da76f077fd","blocks":227},"preview":{"initial":"9/9 200","bytes":119290,"sha256":"3e29bd380466e0db716ec4bc67a197a38206a757ebf7f5157f98da70fd39a900","later":"404 instability"},"geometry":{"desktop_overflow_px":67,"390_overflow_px":733,"320_overflow_px":803,"phone_tables_crossing":"9/12 at 390; 12/12 at 320"},"semantics":{"presentation_tables":"12/12","scoped_headers":"0/9","semantic_callouts":"0/9","strong":0,"lang":false,"landmarks":0},"delivery":{"sent":0,"clients":"unvisited"},"mutations":0}
```
