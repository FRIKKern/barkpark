# cgsi-v1 — crown subject-set adjudication (re-derivation recipe)

Tree under test: `origin/main` @ `bf499f54b63135b8ae078305b83f2b5b2c078877` (NOT 122fd0df81 — main moved).

## Extract a clean tree

    D=$(mktemp -d) && git archive origin/main | tar -x -C "$D"

## SET A — .exclusions rows with reason prefix S2/S4/S6/S7 (12 rows)

    git show origin/main:.github/required-checks.json \
      | jq -r '.exclusions[] | select(.reason|test("^S(2|4|6|7)")) | .context'

## SET B — the complement (93 rendered contexts)

Scripts committed beside this file:

    python3 tooling/grip/ledger/cgsi-subject-set-derive-2026-08-19.py  "$D"   # membership of A and B, needs-closure
    python3 tooling/grip/ledger/cgsi-structural-evidence-scan-2026-08-19.py  "$D"   # structural evidence scan (job name / own steps / job-adjacent prose)
    python3 tooling/grip/ledger/cgsi-file-header-prose-rule-2026-08-19.py  "$D"   # file-header prose rule (the false-red factory)
    python3 tooling/grip/ledger/cgsi-name-anchored-window-2026-08-19.py  "$D"   # name-anchored 200-char window (mirror of the forward clause)

## Decisive numbers (2026-08-19)

| shape | subject set | reds today | false reds |
|---|---|---|---|
| structural (name token + own step names + job-adjacent comment) | A (12) | 3 | 0 |
| structural | B (93) | **4** | 0 |
| file-header prose | all 50 files | 11 | >=5 (negations/corrections) |
| name-anchored 200-char window (mirror of forward clause) | A (12) | 3 | 3 (misses all 3 specimens) |
| name-anchored 200-char window | B (93) | 7 | >=4 (generic job keys `changes`,`build`,`control-plane`) |

- A is a STRICT SUBSET of B: `SET B members that HAVE an exclusion row` == exactly the 12 of A.
- All 13 S3 rows are inside the transitive needs-closure (13/13 `in-closure=True`) — the complement excludes S3 for free, no hand list.
- The 4th red only B sees: `connectors.yml` job `shim-confinement` / context
  `Cloud shim confinement + session-sandbox proofs (black-box, no real Vercel)` —
  job-adjacent comment says `BLOCKING — no continue-on-error ... a red here means a real
  confinement regression`; the context is not required, not in any needs-closure, and has NO
  exclusion row, so an `.exclusions` join can never see it.

## Hermeticity

`scripts/required-checks-verify.sh` accepts `--spec` and `--workflows` (line 846/851), so the
clause is drivable against a fixture tree with no repo mutation. Live arm still reds on main
the moment the clause lands (doc-gates.yml carries 21 `(blocking)` step names), so clause +
doc-gates step renaming must CO-MERGE.

## Confirmed absence

`grep -c exclusions scripts/required-checks-verify.sh` -> 0 across 872 lines.
`grep -rn 'name:.*(blocking)' .github/workflows/` -> 23 hits in exactly 3 files (doc-gates 21,
security 1, go-format 1). The "59 blocking-shaped names" figure in the digest is NOT the
literal `(blocking)` token census.
