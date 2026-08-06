<!-- doc-tier: cold | canonical-for: legendary-paper-experiment-03-evidence | budget: 1800tok -->
# Experiment 03 — terminal navigation, identity, discovery, and provenance baseline

Verdict: `BASELINE_ESTABLISHED_CURRENT_TERMINAL_AND_CONTRACTS_FAIL_HARD_THRESHOLDS`. This is a frozen Round-1 measurement, not a candidate or format selection.

The exact four Paper pins reproduced across 32/32 terminal cells: four Papers × widths 20/40/80/120 × ANSI256 and NoColor projections. Machine document, history, schema, capabilities, source-negotiation, and typed missing-Paper controls added 17 deployed contract cells.

Width containment passes: no measured line exceeded its declared width. That narrow result does not establish usability. At width 20 the eight projections expand to 72,242 lines, including one 13,111-line cell. Aggregate line counts remain 28,662 at width 40, 13,278 at width 80, and 8,964 at width 120.

The terminal readers fail the frozen semantic and navigation contract:

- heading text survives 1,116/1,160 repeated render comparisons, not 100%;
- structural table-header, explicit tone-label, and pinned-revision carriers each pass 0/32 cells;
- authored list and mark semantics do not survive completely;
- help exposes width control but no outline, bounded pager, or Paper-history navigation;
- three task-like strings are plain text, not structured task relationships;
- `bp doc history --limit 1` forwards the limit for 0/4 Papers and returns 14, 10, 12, and 12 rows;
- history UUIDs and document `_rev` hashes are distinct identity domains but the reader does not explain that distinction.

The machine CLI missing-Paper control is a narrow pass: exit code 4 retains typed `not_found` and request-ID text. Deployed source discovery fails its media contract for all four Papers: `Accept: application/json` and `text/plain` return 406, while `text/html` returns 200 with an `application/json` body. No Paper source response carries an ETag. Capabilities itself returns 200 with an ETag, and Paper schema discovery returns 200.

Verification ran five times: twice by the typed experimenter, twice independently by the leader, and once after the typed result was finalized. Every run passed 253 checks with the same artifact-set SHA-256:

`d278f4d1255793d2456460e5575042be00b707e407c30c4ec81ea1f09d2a6fe1`

The stable manifest SHA-256 is `59eed0447713caeb86caf13e9b9c3af7a388b1fd155195421acc91d0499ed351`. Build time was 56.524017 seconds, declared probes 44.237593 seconds, and deployed contract probes 3.645173 seconds.

Durable artifacts live under `.omx/state/legendary-paper-reader-upgrade-experiments/E03`: assignment authority, exact source fixtures, controls, known-bad and adversarial corpora, raw machine/history/contract/error/terminal captures, render matrix, history/provenance report, hard thresholds, failure taxonomy, timing, hash manifest, typed result, and reproducible builder/verifier scripts. Reproduction is:

```text
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E03/scripts/build_baseline.py
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E03/scripts/verify.py
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E03/scripts/verify.py
```

The stop condition is met: terminal, navigation, identity, discovery, error, and provenance baselines are reproducible; current failures remain explicit; Studio and real-mail behavior are outside this assignment and are not proxy-passed; no candidate or product/Paper mutation occurred.
