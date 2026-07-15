# E04 — canonical-native repair candidate

Isolated Round-2 candidate. It snapshots the frozen E03 selected fixtures, normalizes Papers to a conservative PortableDoc subset plus derived HTML, and emits class-specific Task fields. `transformation-manifest.json` records every accepted or quarantined unit and its hashes. It never calls Barkpark APIs or mutates product/source data.

Run: `./scripts/run.sh`. Expected verification output begins `E04 VERIFY PASS`. The full replay may rewrite deterministic artifacts only with identical bytes and must leave `git status` clean.

Timing policy: `verification.json` freezes the measured timing captured for the committed evidence. Later replay timings are emitted to stdout only, are excluded from deterministic artifact hashes, and never rewrite tracked evidence.

Authenticated Studio and real-client email are capability-blocked. Therefore this candidate cannot clear the frozen `surface_exercise`, accessibility, or width/email gates and cannot self-select as winner.
