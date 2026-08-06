# E04 — revision-fenced write-time migration candidate

This isolated experiment reads the four committed E01 revision-pinned source fixtures. It never calls a server or writes outside E04.

The migration changes only an unambiguous table with `header` and no `head`: it moves the authored value to `head`. Equal aliases collapse to `head`; conflicting aliases, malformed aliases, and missing revision pins are quarantined without mutation. Headerless tables and exact-empty spacers are retained as author-intent boundaries.

`scripts/replay.py` builds two isolated copies, proves byte-identical output, proves a second migration is a no-op, performs exact byte rollback from raw preimages, verifies all denominators, creates five adapter receipts, records blocked real-reader cells without proxy passes, scans saved artifacts for credential-shaped data, and creates a deterministic evidence archive.

Run from the repository worktree root:

```sh
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E04/scripts/replay.py
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E04/scripts/verify.py
```

Adapter receipts are candidate-harness evidence, not claims that deployed public, authenticated Studio, delivered email, or interactive TUI readers passed. Those real-reader cells remain `BLOCKED` where no real session/client exists.
