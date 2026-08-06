# Experiment 02 — Round 1 baseline

This isolated artifact freezes the current reader baseline for the exact four assigned Paper revisions. It performs read-only source/public/email/CLI capture, real headless-Chrome 320/390 geometry, keyboard focus traversal, browser accessibility-tree capture, semantic scoring, and deterministic verification.

Run:

```sh
python3 scripts/capture.py
python3 scripts/build_report.py
python3 scripts/verify.py
python3 scripts/verify.py
```

The HTTP `/email` route is explicitly an HTML preview, not a delivered mail-client artifact. Authenticated Studio, real assistive technology, real Gmail/Outlook/Apple Mail, and adversarial reader ingestion remain `BLOCKED`; none is proxy-passed. This assignment creates no repair candidate and mutates no Paper, Task, Cycle ledger, or product source.
