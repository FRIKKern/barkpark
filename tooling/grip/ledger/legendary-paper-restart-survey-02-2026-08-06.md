<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-02 | budget: 1400tok -->
# Restart Survey 02 — CLI/API live regression and frozen gates

Assignment `restart-survey-02` re-attested `cloud-console-hardening-wave-28-2026-08-03::cli_api` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **unchanged baseline failures, no new regression, no improvement**.

## Direct answer

Fresh machine reads, source, and eight terminal renders are byte-identical to the frozen E03 baseline at revision `49c1534d9fb76d0d9adc7b97f25ec471`. Canonical accounting and terminal containment still pass. Revision carriers, text proxies, table/mark/callout semantics, spacer migration, density, navigation, and contract provenance still fail. Browser geometry and real-reader capabilities remain outside this CLI/API unit and receive no proxy pass.

## Fresh identity and render matrix

- Machine identity: 237/237 blocks and 237 unique ordered IDs.
- `bp doc get` and `bp paper view -o json`: byte-identical, 558,569 bytes.
- Current machine JSON and source: byte-identical to E03.
- Profiles `none` and `ansi256` at widths 20, 40, 80, and 120: all eight hashes exactly match E03.
- Improvement count: 0. New regressions: 0.

| Width | Lines | Maximum width | Overflow | Strict exact-string scores: headings / headers / lists / marks |
| ---: | ---: | ---: | ---: | --- |
| 20 | 13,111 | 20 | 0 | 41/43 · 33/57 · 16/35 · 49/67 |
| 40 | 5,224 | 40 | 0 | 42/43 · 35/57 · 28/35 · 59/67 |
| 80 | 2,357 | 80 | 0 | 42/43 · 35/57 · 33/35 · 62/67 |
| 120 | 1,547 | 120 | 0 | 42/43 · 35/57 · 31/35 · 66/67 |

The wrapping-sensitive scores prove unchanged output, not isolated word deletion. Containment succeeds while density remains unacceptable.

## Gate disposition

Canonical accounting and alias-conflict remain passes. Terminal geometry passes containment only. The following remain failures: human revision identity is 0/8; structural table-header carriers are 0/8 despite 18 tables and 57 authored headers; 67 authored marks lack a proven non-color semantic carrier; 13 callouts expose 0 tone-label carriers; all 103 exact-empty spacers remain; no outline, pager, or history navigation exists; and source JSON/plain negotiation still returns 406 while HTML negotiation returns JSON without an ETag.

Nested-list losslessness is blocked for this unit because its seven lists contain 35 flat items and zero nested nodes. Headerless intent is a non-applicable control because the unit has no headerless table. Browser geometry, authenticated Studio, assistive technology, and delivered-mail gates were not exercised.

## Navigation and history

The textual task token `task-3fbfff8c97b50c8f` resolves to the expected closed task with three criteria and parent `cloud-console-hardening-epic`, but `bp graph tasks <paper>` returns zero. The task exists; the structured Paper relationship carrier does not.

`bp doc history --limit 1` returns all 12 revisions rather than one and does not expose the current document revision. Typed missing-Paper behavior remains a narrow pass: exit 4 with structured `not_found` and request-ID data.

## Cycle payload

```json
{"assignment_id":"restart-survey-02","unit":"cloud-console-hardening-wave-28-2026-08-03::cli_api","revision":"49c1534d9fb76d0d9adc7b97f25ec471","verdict":"UNCHANGED_BASELINE_FAILURES_NO_NEW_REGRESSION","regressions":0,"improvements":0,"machine_blocks":"237/237","terminal_cells":"8/8","terminal_overflow_cells":"0/8","structured_header_carriers":"0/8","revision_carriers":"0/8","tone_label_carriers":"0/8","history_limit_requested":1,"history_records_returned":12,"structured_paper_task_links":0,"existing_task_tokens_resolved":"1/1","blocked_gates":["nested-list-losslessness","browser-geometry","real-reader-capabilities"]}
```
