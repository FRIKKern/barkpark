# TASK-SYSTEM.md at its byte cap — the ration decision (2026-08-23)

Row: `pds-bl-task-system-md-at-its-byte-cap`. Measured on origin/main 60b08453f9:
`docs/setup/TASK-SYSTEM.md` = 15,998 B of a 16,000 B cap (2 B headroom — the row's
own 15,979/21 B had already decayed by three edits).

## Inventory (fence-aware; command below)

```
awk 'BEGIN{sec="(preamble)"} /^```/{fence=!fence} (!fence && /^#{1,3} /){if(bytes)printf "%6d  %s\n",bytes,sec; sec=$0; bytes=0} {bytes+=length($0)+1} END{printf "%6d  %s\n",bytes,sec}' docs/setup/TASK-SYSTEM.md
```

|     B | section |
|------:|---|
|    78 | (preamble/doc-tier line) |
|   297 | # The Task System |
|  1095 | ## What you get |
|   741 | ## Set up from zero |
|  6954 | ## Point an AI agent at it |
|   943 | ## Task ↔ code linkage |
|   791 | ## The cmux bridge |
|   995 | ## Working with your AI in Studio |
|   479 | ## Goals and phases |
|  1035 | ### How to organize tasks |
|   720 | ## Workspaces, projects, datasets |
|  1870 | ## Troubleshooting |

## Decision: RATION

The file stays whole and FULL. Every future addition must retire at least equal
weight of PROVEN in-file duplicate (name the owning line) or compress phrasing
with zero fact loss. Never raise the cap.

- **Split rejected**: no coherent section has an existing owner elsewhere
  (`canonical-for` map checked), and a new destination doc needs its own cap row
  in `scripts/check-doc-budgets.sh` — a FIXED allowlist whose edit is outside a
  docs-only change; an unlisted doc is silently ungated (the laundering channel
  the api-v1 relocation row proves by mutation).
- **Re-home rejected**: the authoring conventions (§How to organize) are the
  class a re-home would move, but no existing doc owns task-authoring; minting a
  new owner meets the same ungated-destination problem as split.

## The accounting (this PR)

Freed 172 B, all duplicates with a named surviving owner, or pure compression:
`:12` "criteria-first" (owner `:93` reader-order contract) · `:33` "(1 min)"
(owner `:90` per-minute sweeper) · `:66` + `:76` code-comment fencing prose
(owners `:85` Release / `:89` Close bullets) · `:141` "(re-claim = renewal)"
(owner `:193` not_ready row) · `:145` "(`c`/`x`)" (owner `:12`) and
"dependencies/claim read-only" (owner `:10` Studio row) · `:189` holder-only
enumeration (owners `:85/:86/:88/:89`; compressed in place, fact retained).

Spent 110 B: rule 5 gains the merge-gate flag sentence (the homeless sentence
from `pds-bl-merge-gated-criteria-carry-the-flag` criterion index 3, 'TASK-SYSTEM.md documents the shipped rule'): "Merge-gated
criteria need `merge_gate:true` — a `landed` close auto-flips only the flag;
wording alone just warns." (Shipped rule: PRs #12975/#13006/#13175.)

After: 15,936 B → **64 B headroom**, `check-doc-budgets.sh` PASS (exit read
directly, unpiped).
