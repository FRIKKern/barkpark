<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-08 | budget: 1400tok -->
# Restart Survey 08 — public live regression and frozen gates

Assignment `restart-survey-08` re-attested `cloud-console-hardening-wave-28-2026-08-03::public` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **unchanged mixed control and failure; no new deterministic regression and no improvement**.

## Direct answer

After removing per-request CSRF, LiveView session, element-ID, and CSP-nonce values, current public HTML is byte-identical to E02 at normalized SHA-256 `9954f254ab621c7a519be1f776b16772c91011eb43a72a104c23e4e522b131ac`. Block accounting, wording, landmarks, and keyboard-visible table focus remain stable passes. Phone geometry, table/mark/callout semantics, navigation, spacer cleanup, and immutable revision provenance remain failures. Browser AX observations are not real assistive-technology proof.

## Fresh sample

- Published revision `49c1534d9fb76d0d9adc7b97f25ec471`.
- One raw public HTML capture, one source projection, and two Chrome cells at 320 and 390 CSS px.
- Source/public: 237 blocks/wrappers; 43 headings; 18 tables/57 authored header cells/466 data cells; seven lists/35 items; zero nested nodes; 13 callouts; 67 marks; 103 exact-empty spacers.
- Two browser AX trees, 18 Tab events, zero real-AT runs.

| Requested width | Client | Inner | Scroll | Result |
| ---: | ---: | ---: | ---: | --- |
| 320 | 320 | 553 | 553 | overflow |
| 390 | 390 | 448 | 448 | overflow |

Both cells exactly reproduce E02 geometry. This unit remains 0/2; the frozen aggregate was public 2/8.

## Gate disposition

Unchanged passes: canonical accounting at 237/237 unique, ordered wrappers; text losslessness at 237/237 block checks and 134/134 nonempty authored-token sequences.

Unchanged failures: the reader exposes `data-rev="0"` rather than the pinned revision; all 18 tables use `role=presentation`, with 0 scoped headers and 0 captions; 67 authored marks lack one-to-one semantic preservation; all 13 callouts lack role or accessible tone; 103 spacer wrappers remain; both phone cells overflow; no outline, bounded paging, history, nav region, or structured task link exists; HTTP provenance has no ETag and reader revision is zero.

Nested-list losslessness, headerless intent, alias conflict, and terminal geometry are non-applicable/control gates. Real-reader capability is blocked at 0/2 real-AT cells.

Stable positives in both cells include one main, article, and H1; language `en`; 43 AX headings; seven lists/35 items; and nine focus-visible keyboard targets, all scrollable tables. Stable deficiencies include 18 presentational tables, only 55/57 AX column headers and 17/18 AX tables, unlabeled generic callouts, no authored code semantics, and a task token present twice only as text. Browser heuristics and focus visibility do not satisfy the semantic or real-AT contracts.

Totals: zero regressions, zero improvements, eight unchanged failures, two unchanged passes, one blocked gate, and four N/A/control gates.

## Facts, inference, and residual scope

Facts are normalized byte equality, exact source/DOM/text counts, two geometry cells, AX snapshots, and actual Tab events. These support the inference that deployed behavior is unchanged. VoiceOver, NVDA, Studio, email, CLI/TUI, other Papers, Tasks, and Cycle state were outside this assignment.

## Cycle payload

```json
{"assignment_id":"restart-survey-08","unit":"cloud-console-hardening-wave-28-2026-08-03::public","revision":"49c1534d9fb76d0d9adc7b97f25ec471","verdict":"UNCHANGED_PUBLIC_READER_MIXED_CONTROL_AND_FAILURE","normalized_html_sha256":"9954f254ab621c7a519be1f776b16772c91011eb43a72a104c23e4e522b131ac","normalized_baseline_equal":true,"browser_cells":2,"geometry_pass":"0/2","block_wrappers":"237/237","block_text_pass":"237/237","nonempty_text_pass":"134/134","semantic_tables":"0/18","scoped_headers":"0/57","semantic_marks_proven":"0/67","semantic_callouts":"0/13","revision_carriers":"0/2","structured_task_links":0,"focus_visible_cells":"2/2","real_at_cells":"0/2","classifications":{"regression":0,"improvement":0,"unchanged_failure":8,"unchanged_pass":2,"blocked":1,"not_applicable_or_control":4}}
```
