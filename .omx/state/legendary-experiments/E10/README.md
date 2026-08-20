# E10 canonical Legendary convergence

E10 evaluates the strongest Round-3 survivor without weakening the frozen E03 hard gates. Round 3 did not produce a winner: E04 and E06 are rejected, while E05 is only the strongest non-rejected candidate on the E09 evidence-truth axis and still fails or is blocked on E08 content, structure, accessibility, width, and real-surface gates.

This directory is an isolated, read-only convergence packet. It does not mutate product code, production data, the wave Paper, or authoritative Tasks.

Replay and verify the packet:

```sh
python3 .omx/state/legendary-experiments/E10/scripts/build.py
python3 .omx/state/legendary-experiments/E10/scripts/verify.py
```

The exact builder gate fails closed because no winner exists:

```sh
python3 .omx/state/legendary-experiments/E10/scripts/builder_gate.py
# exit 42; E10 BUILDER GATE BLOCKED
```

Verification can assert that the refusal is the expected result:

```sh
python3 .omx/state/legendary-experiments/E10/scripts/builder_gate.py --expect-blocked
# exit 0; E10 EXPECTED BLOCK CONFIRMED
```

`result.json` is the machine-readable verdict. `next-complete-three.json` specifies the three atomic rework assignments required before convergence may be reconsidered. Assignment ids remain leader-owned; this worker does not invent authoritative Task ids or a winner.
