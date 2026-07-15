# E22 isolated real-reader gate

This directory is the complete, fail-closed E22 harness. It accepts exactly
three runtime secrets/targets (`E22_ISOLATED_BASE_URL`, `E22_DATABASE_URL`, and
`E22_ADMIN_TOKEN`), never serializes their values, and refuses ambiguous or
production-shaped targets. Without all three authorized non-production values,
`build_blocked.py` emits the canonical deterministic `BLOCKED/REWORK` evidence
set; it never fabricates a deployment or capture.

```sh
python3 scripts/preflight.py --ttl-minutes 120 --deny-production
python3 scripts/build_blocked.py
python3 scripts/verify.py --require-cells 108 --require-provenance --replays 2
```

With authorized isolated credentials, run `provision.py`, `capture.py`, then
`teardown.py`. `capture.py` deliberately requires real reader evidence and
rejects redirects/login pages, URL reflection, API/proxy substitutes, blanks,
duplicates, and provenance drift.
