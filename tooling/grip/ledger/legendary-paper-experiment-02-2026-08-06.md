<!-- doc-tier: cold | canonical-for: legendary-paper-experiment-02-evidence | budget: 1800tok -->
# Experiment 02 — browser geometry, accessibility, and identity baseline

Verdict: `BASELINE_FAIL_WITH_BLOCKED_SURFACES`. This is a read-only Round-1 baseline, not a repair candidate or a proxy pass for unavailable readers.

The exact four Paper pins and frozen inventory digest reproduced. Canonical source and machine CLI identity pass 8/8 pin checks, 4/4 canonical block hashes agree, and all four sources retain unique nonblank block identifiers. Across the current human-facing readers, five threshold groups pass, eight fail, and four remain explicitly blocked.

The passing baseline checks are exact source/CLI pins (8/8), source-to-CLI semantic hashes (4/4), unique block identity (4/4 Papers), public landmarks (8/8 width cells), and keyboard-visible focus targets exercised through real Chrome DevTools Protocol Tab events (8/8). These results prove only their named dimensions.

Hard failures remain:

- public visible-text parity is 813/815 blocks; Cloud Console 29 blocks `w29D015` and `w29D022` are missing;
- all four Papers fail the zero-spacer threshold, with 381 exact-empty paragraphs;
- public narrow geometry passes 2/8 cells at 320/390 pixels, while the HTTP email preview passes 0/8;
- data-table semantics pass 0/46, callout labels pass 0/30, and authored mark semantics pass 0/388;
- public and email reader revision identity passes 0/16 cells.

Authenticated Studio is blocked for 8/8 cells, actual assistive technology is blocked for 8/8 cells, delivered Gmail/Outlook/Apple Mail evidence is blocked for 24/24 cells, and the six frozen adversarial fixtures remain blocked from reader ingestion because this assignment cannot mutate production or create a candidate. Browser accessibility trees are retained as observations but are not counted as real assistive-technology proof. The email route is an HTTP preview, not delivered mail.

The capture retained three transient HTTP 500 cells from pre-final geometry attempts. An immediate final repeat was clean. Both facts remain in the evidence so intermittent service behavior is neither erased nor misreported as deterministic reader failure.

Verification ran four times: twice by the typed experimenter and twice independently by the leader. Every final replay passed 11/11 checks across 37 evidence files with the same verification SHA-256:

`31a069a93a62035bcb4790696846013f21233793a9061a56fde7da44cb714528`

Capture took 61.291442 seconds. Durable artifacts live under `.omx/state/legendary-paper-reader-upgrade-experiments/E02`: frozen fixtures and manifest, raw source/public/email/CLI captures, browser observations, text-parity and geometry results, threshold scorecard, surface matrix, failure taxonomy, gaps, transient-500 observations, typed Cycle payload, timing, idempotence proof, and reproducible capture/report/verifier scripts. Reproduction is:

```text
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E02/scripts/capture.py
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E02/scripts/build_report.py
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E02/scripts/verify.py
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E02/scripts/verify.py
```

The stop condition is met: current browser geometry, accessibility observations, semantic parity, immutable identity, capability gaps, transient failures, and reproducible denominators are frozen without building a candidate or mutating a Paper, task, Campaign Paper, Cycle result, or product source.
