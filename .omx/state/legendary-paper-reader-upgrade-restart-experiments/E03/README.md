# Restart E03 — TUI, CLI, API, identity, discovery, errors, recovery

This is the immutable Round-1 baseline assignment `restart-experiment-03` (`6a716097-1b44-4775-8e8e-46b5d1a1a5b1`). It performs external reads only against saved server `guerrilla` using `docs/cli/fixtures/full-manifest.json` and writes only this artifact directory.

Boundaries are explicit: `raw/` stores decisive command/HTTP bodies, `envelopes/` stores normalized transport and document envelopes, `semantic/` stores canonical source blocks and core render projections, and `appendix/related/` stores the separately mutable Related projection.

```sh
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E03/scripts/build.py
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E03/scripts/replay.py
```

The verifier is pure and deterministic. A real interactive TUI session, a safe deployed 500, and a safe deployed timeout remain explicit blocked cells; static `bp paper view` output is not promoted to interactive-state proof.
