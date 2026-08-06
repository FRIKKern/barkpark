<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-14 | budget: 1400tok -->
# Restart Survey 14 — TUI80 live regression and frozen gates

Assignment `restart-survey-14` re-attested `cloud-console-hardening-wave-28-2026-08-03::tui80` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **unchanged baseline: containment passes; density, semantics, navigation, and provenance remain failed**.

## Direct answer

The canonical Round-1 command was replayed against the live server. It exited zero and was byte-for-byte identical to the sealed baseline: Paper revision `49c1534d9fb76d0d9adc7b97f25ec471`, 2,357 lines, 191,475 bytes, maximum width 80, zero overflow, SHA-256 `386de871838459e09144db4d96afeea339c69617fdceb6fa40048dcc435b48b3`. No regression or improvement was found on the frozen canonical surface.

## Frozen-gate ruling

- Containment remains a pass: 0/2,357 lines exceed 80 columns.
- Density remains a failure: one 237-block Paper occupies 2,357 lines.
- Exact-text proxies remain incomplete: headings 42/43, authored headers 35/57, list items 33/35, marked runs 62/67.
- All 18 tables render visible boxes, but none exposes a structural header carrier.
- All 13 callouts have visible bar/color treatment, but none exposes an explicit accessible tone label.
- Human output carries no Paper revision. Machine JSON separately carries the exact revision and all 237 blocks.
- Five Related recommendations appear, but the one-shot reader has no outline, bounded paging, reader-integrated history, or selectable task stops.
- Piping `q` into the command produces the identical output and exit status; stdin is not an interaction surface.

Canonical accounting, revision pins, text-losslessness proxies, table/mark/callout semantics, spacer migration, density, navigation, and contract provenance remain unchanged failures. Browser geometry, nested-list/headerless/alias gates, and real assistive-reader capabilities are not applicable or were not exercised on this cell.

## Reader boundary and contradiction

`bp paper view` is a one-shot headless renderer: it fetches canonical Paper source, emits width-bounded output, appends a fail-open Related section, and exits. Separate history returned 12 records, but history is not integrated into the human reader.

A real 80×24 PTY with automatic ANSI profile repeatedly produced 2,358 transcript lines, including one extra blank line inside table `w28e1007`. This is not promoted to a regression because the sealed profile-none capture remains byte-identical and the PTY adds terminal-query/autowrap behavior. A dedicated real-terminal cell-width capture is required to distinguish instrumentation from an ANSI/autowrap-only defect.

The exact-text misses are proof gaps rather than proof of deletion; wrapping, case, and styling explain several. Visual boxes do not establish semantic table headers, and colored bars do not establish accessible callout tone.

## Residual scope

Live navigation through the full `bp` task-board Paper frame, mouse/keyboard viewport ownership, widths 20/40/120, real assistive technology, and ANSI behavior in a full terminal emulator were not visited. The implementation boundary was statically inspected, but the interactive TUI was not captured end to end.

## Cycle payload

```json
{"assignment_id":"restart-survey-14","unit":"cloud-console-hardening-wave-28-2026-08-03::tui80","verdict":"unchanged_baseline","paper_revision":"49c1534d9fb76d0d9adc7b97f25ec471","canonical":{"exit_code":0,"bytes":191475,"lines":2357,"max_width":80,"overflow":0,"sha256":"386de871838459e09144db4d96afeea339c69617fdceb6fa40048dcc435b48b3","round1_byte_equal":true,"regressions":0,"improvements":0},"terminal_geometry":{"containment":"unchanged_pass","density":"unchanged_failure"},"proxies":{"headings":"42/43","headers":"35/57","list_items":"33/35","marked_runs":"62/67","table_boxes":"18/18","semantic_table_headers":"0/18","accessible_callout_tones":"0/13"},"human_revision_carrier":0,"related_recommendations":5,"outline":false,"bounded_paging":false,"integrated_history":false,"stdin_interactive":false,"pty_anomaly":"2358 lines under automatic ANSI; targeted proof required"}
```
