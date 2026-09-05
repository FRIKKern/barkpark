<!-- doc-tier: cold | canonical-for: sidecar-correction-cch-w22-s7-crit15 | budget: 300tok -->
# CORRECTION (dated 2026-09-03) — cch-w22-s7 crit15

The sibling file `cch-w22-s7-cruelty-ledger-effective-caps-and-classes__crit15.txt` is a
byte-unchanged capture (see the directory README) of that row's criterion 15 as it stood on
2026-08-23. Its sentence about the merge gates is a DATED RECORD and is now false: it used to
say `Console gate` and `Cloud gate` were advisory on the live branch under charter D259. As
measured on 2026-09-03, live branch protection requires all four contexts in
`.github/required-checks.json` (`enforced: true`) and every one of them blocks the merge.

The capture is not edited because it is evidence, not a charter. This record sits beside it
so a reader takes the sentence as history. The claim is pinned in
`scripts/required-checks-verify.sh` (`PROSE_CLAIM_PINS`, owner lead-gates-3, ruling from main
2026-09-03 15:43Z); the pin drops when this packet is retired.
