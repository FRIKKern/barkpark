<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-29 | budget: 2100tok -->
# Restart Verify 29 — authority and evidence coherence

Assignment `restart-verify-29` compared the live restart Cycle, campaign Paper, epic Task, frozen inventory, Survey evidence, replacement ancestry, Verify plan, and Legendary validator. Verdict: **proven at the observed Verify-stage boundary**, not full Cycle completion.

| Measure | Observed |
|---|---:|
| Inventory cross-product | 20 = 4 Papers × 5 readers |
| Survey planned / started / completed / failed | 60 / 61 / 60 / 1 |
| Survey missing / invalid / unresolved | 0 / 0 / 0 |
| Verify planned / started / completed / in flight | 30 / 30 / 27 / 3 |
| Frozen Paper identities current | 4/4 |
| Survey evidence IDs/paths/blobs | 60/60/60 |
| Verify plan unique IDs | 30 |
| Paper/live Cycle ledger compare | exact |
| Paper/live fleet compare | exact |
| Validator | PASS, exit 0 |

Live authority remained wave revision `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`, inventory digest `227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc`, and plan digest `9997fc50db5f1b83f1f53e33bd45dd111b2b06402b07a78b0673d2048f299e45`. Cycle, campaign-Paper cross-product, and Survey-plan inventory sets all contained the same twenty units with zero set differences.

Canonical Cycle-ledger SHA-256 was `72f52571b71e1a0d4ff89312bb75e1c98a2b35599f921f1beba96be9ab365b0c` in both live and embedded forms. Canonical fleet SHA-256 was `e2733d820448920262bdde3257d9d24ff06ba8e5686fa671279501034cd5cac3` in both. All sixty Survey `repo://` links resolved at their declared evidence revisions, with unique logical IDs, paths, and blobs.

The Verify plan was frozen at `a55051a3c89fcd26676207d7317381851c61a854`, SHA-256 `d4a22aacf361fe9835dedacafefe8e0902ba139525b280d77ca68a0fd1799b11`, and differed from HEAD by zero bytes. The validator exposes no `verify` phase; its documented Verify-boundary phase is `digest`, which passed with exit zero.

Survey has one historical failed predecessor and one replacement: `restart-survey-21` followed by terminal `restart-survey-21-r1`. Counts reconcile as 61 attempts, 60 completed leaves, one failed predecessor, and zero unresolved failures. Server invariants prove a linear replacement relation and preserved scope/phase/type/wave, but the public Cycle projection omits the literal `replaces_assignment_id` pointer; this portion is source-invariant evidence rather than a printable public edge.

Expected incompleteness remains explicit: `cycle_ledger.exact=false`, `fleet_complete=false`, Task acceptance 1/5, and Experiment/Build/Review pending. Historical original-wave digest ordering differs while the unit set is identical; the campaign Paper discloses this. The credential-rotation incident remains carried without reading or persisting credential material.

Evidence under `/private/tmp/restart-verify-29-*` includes Cycle capture SHA-256 `4da47812b6d7501ec9cf486cdbc7a19bf6db33175498d73b1a52b98308a120d3`, Paper capture `2e6bd0078d1b1970c14c5d6c5c1618a6ea3cd3f881e098ef9dc66e3f66b56cbe`, validator output `57a434a9cb383748170868e1c2dbf555a5a474945ebadb9c4a008ef97fe94a99`, evidence-resolution manifest `71f5f4d618264699fc1f684c2f6bfaf6a677be6682192a960e1dfcf9b34d2b58`, and compact result `58a6dacfa28e5cac9ef3fdb307f238922d7b0dabc3e9b4a272f391e5b57d0e52`. Mutations were zero.

## Cycle payload

```json
{"assignment_id":"restart-verify-29","assignment_uuid":"e6a8b638-42ef-459b-83d1-abfb6379c867","verdict":"proven_verify_stage_coherence","inventory":20,"survey":{"planned":60,"started":61,"completed":60,"failed":1,"missing":0,"invalid":0,"unresolved":0,"evidence_resolved":"60/60"},"verify":{"planned":30,"started":30,"completed":27,"in_flight":3,"invalid":0},"frozen_papers":"4/4","inventory_set_diffs":0,"paper_cycle_ledger_equal":true,"paper_fleet_equal":true,"replacement_leaf":"restart-survey-21-r1","validator":{"phase":"digest","exit":0,"result":"pass"},"mutations":0}
```
