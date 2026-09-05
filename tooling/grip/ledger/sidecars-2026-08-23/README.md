<!-- doc-tier: cold | canonical-for: close-packet-sidecars-2026-08-23 | budget: 900tok -->
# Close-packet criterion sidecars — 2026-08-23

The close packets in the parent directory cite per-row criterion evidence as
`<row>__crit<N>.txt` "beside this file". Those files were never committed: before this
directory existed, **0 of 1289 files** under `tooling/grip/ledger/` matched
`__crit<N>.txt` or `MANIFEST`. Every packet's evidence chain ended at a path that no longer
resolved, so a close reason repointed at a packet inherited that dead end one indirection
further out. This directory is that evidence, restored.

**Source.** A protected session scratchpad from the 2026-08-23 triage sweep
(`ba5f66f9-9370-4639-ae79-5f38bb0e7fe1`), snapshotted 2026-09-02. Files are byte-unchanged:
copied, never edited, renamed or reformatted.

**What a `__crit<N>.txt` holds.** The EXACT stored bytes of that row's
`acceptance_criteria[N].criterion` at sweep time. Indices are ZERO-BASED. Every packet row
was `lifecycle_status=open` and 0-met, so every index in `0..total-1` has a file.

## Integrity

Two of the five manifests are machine-checkable sha256 lists. Both verify clean **against
the files in this directory**, not merely against the source snapshot:

| manifest | checked | mismatch | missing |
|---|---|---|---|
| `tgw-pdf-triage/packet/MANIFEST.txt` | 34 | 0 | 0 |
| `dr-triage-shard/packet/MANIFEST.tsv` | 1378 | 0 | 0 |

`ssw-triage`, `ae-spd-cchi` and `task-triage` carry MANIFESTs that are prose headers rather
than checksum lists; they are committed as they are and cannot be verified this way.

## Contents — 2971 files

| packet directory | files | size |
|---|---|---|
| `ae-closer` | 31 | 22 KB |
| `ae-spd-cchi` | 542 | 176 KB |
| `arpss-acpc-triage` | 24 | 9 KB |
| `decision-packet` | 58 | 672 KB |
| `dr-triage-shard` | 1380 | 410 KB |
| `grpe-triage` | 28 | 12 KB |
| `hg-triage` | 62 | 9 KB |
| `human-gate-packet` | 7 | 76 KB |
| `jarl-disk` | 15 | 132 KB |
| `packet` | 86 | 22 KB |
| `ssw-triage` | 18 | 8 KB |
| `stamp-packet-agent` | 2 | 14 KB |
| `task-triage` | 57 | 46 KB |
| `tgw-pdf-triage` | 36 | 29 KB |
| `triage-cch-agent` | 498 | 105 KB |
| `triage-dr-shard` | 108 | 150 KB |
| `triage-mob-stw` | 19 | 5 KB |

## What is NOT here, and why

The source snapshot is 58.2 MB. The criterion evidence in it is **0.50 MB**. The remaining
56.3 MB is 23 bulk `.json` ledger dumps — full offset walks of the task board captured as
working state. They are regenerable from the ledger, superseded by every later walk, and are
not what any packet promises. They are deliberately excluded so this directory stays the
evidence rather than the session's scratch:

| excluded file | size |
|---|---|
| `decision-packet/open_all.json` | 14.11 MB |
| `human-gate-packet/all-open.json` | 13.87 MB |
| `human-gate-packet/open-off500.json` | 3.65 MB |
| `human-gate-packet/open-p1.json` | 3.63 MB |
| `human-gate-packet/open-off1000.json` | 2.23 MB |
| `human-gate-packet/open-off1500.json` | 2.22 MB |
| `human-gate-packet/open-off2000.json` | 1.82 MB |
| `decision-packet/raw/open_0.json` | 1.62 MB |
| `decision-packet/raw/open_600.json` | 1.51 MB |
| `decision-packet/raw/open_400.json` | 1.47 MB |
| `decision-packet/raw/open_200.json` | 1.42 MB |
| `decision-packet/raw/open_800.json` | 1.30 MB |
| `decision-packet/raw/open_2000.json` | 1.11 MB |
| `decision-packet/raw/open_1400.json` | 0.93 MB |
| `decision-packet/raw/open_1600.json` | 0.90 MB |
| `decision-packet/raw/open_1800.json` | 0.90 MB |
| `decision-packet/raw/open_1000.json` | 0.89 MB |
| `decision-packet/raw/open_2200.json` | 0.87 MB |
| `decision-packet/raw/open_1200.json` | 0.85 MB |
| `decision-packet/hits.json` | 0.43 MB |
| `human-gate-packet/review.txt` | 0.30 MB |
| `ae-spd-cchi/packet/ALL-VERDICTS.tsv` | 0.16 MB |
| `triage-cch-agent/packet/packet.md` | 0.14 MB |

An omission nobody wrote down is indistinguishable from data loss, which is why they are
listed here by name. If any is wanted it can be added in a follow-up; the snapshot and a
tarball are retained outside the repo.
