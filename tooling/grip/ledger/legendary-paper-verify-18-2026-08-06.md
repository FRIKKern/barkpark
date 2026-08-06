<!-- doc-tier: cold | canonical-for: legendary-paper-verify-18-evidence | budget: 1800tok -->
# Verify 18 — CLI navigation, history rendering, and revision terminology

Verdict: `proven`, with terminology nuance. `paper view` has no native long-document navigation and cannot render document-history revisions. The generic name `revision-id` is overloaded across commands, but current help explicitly identifies the Paper flag as an immutable Wave revision, so literal help conflation is refuted.

| Paper | Width-80 lines / bytes | Current document `_rev` | History count / newest UUID |
| --- | ---: | --- | --- |
| Cloud Console wave 29 | 1,440 / 126,556 | `18768b0a…` | 14 / `eed97c1b…` |
| Cloud Console wave 28 | 2,357 / 191,456 | `49c1534d…` | 12 / `7c1135de…` |
| PDS wave 45 | 1,537 / 136,500 | `b992fd8a…` | 10 / `4afe0099…` |
| PDS wave 44 | 1,305 / 111,922 | `8bbd5d87…` | 12 / `344fe5ee…` |

- `--pager`, `--outline`, `--search`, and `--section` are rejected as unknown Paper flags. Setting `PAGER=/usr/bin/false` still emits every line; no pager integration exists.
- Full Paper and Studio URLs with fragments discard the fragment and render the entire stream with the same hash. A bare slug plus fragment is treated as an invalid literal slug. Fragments never select a section.
- `doc history` returns newest-first snapshot UUIDs. `doc revision <history UUID>` succeeds for all four with 252/237/227/99 blocks, but snapshot content has neither `_rev` nor `rev`.
- Neither a history UUID nor current document `_rev` can directly select `paper view`; both activate release-pin validation and require the complete six-part tuple.

Three distinct identities must remain explicit:

1. Current document `_rev`: 32-hex mutable-store revision.
2. Document-history UUID: consumed by `doc revision <rev_id>`.
3. `paper view --revision-id`: Wave revision inside epic, wave, gate, candidate, and role release pins; wire name `wave_revision`.

Current help correctly says `immutable Wave revision (wire: wave_revision)`, while `doc revision` says `Revision id (from doc history)`. The defect is overloaded adjacent naming plus the absence of history-to-render flow, not an incorrect definition.

Focused CLI and API-client release-pin tests pass. No pager, outline, search, section extraction, fragment jump, or document-history rendering seam exists. A full live six-pin release read was not possible without an assignment-supplied tuple, but code and tests prove its separate contract. Deployed reads were intermittently 500/timeout; successful retries establish semantics, not reliability. No files or Barkpark data were mutated at clean commit `36422119ca11`.
