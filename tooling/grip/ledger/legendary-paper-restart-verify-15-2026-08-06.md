<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-15 | budget: 2100tok -->
# Restart Verify 15 — TUI Paper discovery and open paths

Assignment `restart-verify-15` tested unique Paper opens through the direct `document_type_list` desk and through task relations, including `wave_paper`. Verdict: **refuted; direct opens 0/4 and relation opens 0/4**.

The source inventory is healthy: all four frozen Papers exist uniquely at the expected revisions. The live desk node is `{"id":"paper","title":"Papers","type":"document_type_list","type_name":"paper","child":null}`. TUI traversal reads only `found.Child`, stops when it is nil, and never establishes a selected document or revision. Exact 80×24 PTY frames for the installed and worktree binaries are byte-identical: Enter on Papers changes the prompt from content-type selection to document selection, but paints no Paper rows and opens no Paper frame.

An exhaustive census covered 5,269 tasks. It found 51 relations to the four frozen Papers, all exclusively in `wave_paper`: CCH28 10, CCH29 23, PDS44 11, and PDS45 7. Every target had zero `design_doc` and zero `papers[]` relations. The taskboard model and hydration paths read only `design_doc` and `papers[]`; consequently `wave_paper` never reaches `PaperRefs`, `DrivenTasks`, `FramePaper`, or `FetchPaper`.

| Path | Required | Observed |
|---|---:|---:|
| Unique source Papers | 4/4 | 4/4 |
| Direct desk opens | 4/4 | 0/4 |
| Task-relation opens | 4/4 | 0/4 |
| Matching task relations | — | 51 `wave_paper`; 0 legacy fields |

Targeted Go tests pass but encode only the incomplete legacy contract; none contains a `wave_paper` case. The live probe reported one paper reference among the first 1,000 tasks and skipped driven-task inversion because no `design_doc` relation was present. Search was not used. Stale multi-selection cannot be evaluated because neither Paper path materializes.

Evidence is preserved under `/private/tmp/bp-rv15.YnymxK`. Relation-manifest SHA-256 is `bd97ca10b6de58a52d2fa681d424f71eb1eb2ff9898333681e171b3755568ff0`; Paper-manifest SHA-256 is `d226f2b56c68fd803ab2d9449288cb47ee69fa60eb0bcd840a5afe56bedfbce2`; desk-manifest SHA-256 is `764525c7840367745b7fc217d3bd6f369568a70cae0255acf59b495cdf71e24d`. Installed binary SHA-256 is `7d501025836a0b3795a80b477069c3cc1634928dd4eaf9af56da8d3994909690`; worktree binary SHA-256 is `71e137ebf5f837cceb48bb435688f1d8a27b2d97a365eb52c18d5d1653604237`.

The evidence implies two isolated candidate repairs for Experiment: allow direct `NodeDocumentTypeList` navigation and hydrate/dedupe `wave_paper` alongside existing relation fields. No repository, Barkpark, Paper, Task, or production mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-verify-15","cycle_assignment_id":"ada32e7b-7251-4aa1-b603-dc708b0da8a3","verdict":"refuted","source_papers_unique":"4/4","direct_desk_opens":"0/4","task_relation_opens":"0/4","task_census":5269,"matching_relation_tasks":51,"relations":{"cch28":{"wave_paper":10,"design_doc":0,"papers":0},"cch29":{"wave_paper":23,"design_doc":0,"papers":0},"pds44":{"wave_paper":11,"design_doc":0,"papers":0},"pds45":{"wave_paper":7,"design_doc":0,"papers":0}},"search_used":false,"selected_paper_model":null,"mutations":0}
```
