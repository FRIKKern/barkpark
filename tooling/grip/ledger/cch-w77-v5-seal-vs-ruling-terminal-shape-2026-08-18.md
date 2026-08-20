<!-- doc-tier: cold | canonical-for: cch-w77-v5-seal-vs-ruling-rederivation | budget: 1200tok -->

# cch-w77 V5 — terminal shape: RULING not SEAL (re-derivation recipe)

Verifier assignment V5-seal-vs-ruling-terminal-shape. Every fact below re-derivable from
these commands. The seal-predicate binary is byte-identical to origin/main (`git diff
origin/main -- cloud/priv/static/__preview__/seal-predicate.mjs` = 0 lines) and reads a LIVE
roster, so a checkout 163 behind still yields a main-valid live verdict.

## The live terminal verdict (RUN, not read)

    node cloud/priv/static/__preview__/seal-predicate.mjs --successor cch-instruments-epic

VERDICT-TOKEN: `SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=422 considering=1
successor=cch-instruments-epic epic=cloud-console-hardening-epic mode=live roster=928`

- clause (b) = PASS — all 6 chartered divergences D1-D6 registered + proven (refetch-storm,
  session-peer-IP, token-in-log, head-prober-token, single-user-rate-limiter, css-on-deleted).
  The honesty arc's instruments are green. THE HONESTY MISSION IS COMPLETE ON ITS OWN DENOMINATOR.
- clause (a) = FAIL — forwarded under cch-instruments-epic = **0**; 422 orphans lack a
  forwarding address. The orphans are overwhelmingly gr-backlog-*/gr-bl-* GUI-remake FEATURE/OPS
  (tablet-width-audit, operator-palette-entry, operator-digest-send, tfa-confirm-throttle…).
- The predicate's OWN verdict prose: "This is an acceptable, pre-committed outcome. The named
  successor is the honest handoff."

## Why a=PASS cannot be forced this wave (the SEPARATION arithmetic)

The predicate forwards to ONE `--successor` via `forwarded = fetchRoster(SUCCESSOR)`
(seal-predicate.mjs line ~1324 SELF-SUCCESSOR refusal proves the roster-membership semantics).
Two — and only two — paths to a=PASS:

1. Dump all 422 into cch-instruments-epic → VIOLATES Standing Law 0 (instruments successor is
   gates/harness/ledger-hygiene ONLY) + D93 ("filing a bucket at ~40 converts adjudication into
   dumping"; here 422) + D83 (manufacturing a successor to force a verdict). FORBIDDEN.
2. Per-row re-parent each residue to its TRUE owner, drive the epic's own live roster to 0, then
   `--successor TERMINAL` (accepted only on live==0 AND considering==0). LEGITIMATE but D93 paces
   it at ≤ ~10 non-gate rows/wave — 422 rows = dozens of waves, NOT wave 77's job.

Therefore wave 77's honest terminal disposition = **RULING**, the Studio precedent
(`bp paper view studio-space-priority-desk-ruling-2026-07-20`: "THE EPIC ENDS ON A VERDICT,
NOT ON A SEAL … end the epic with an explicit NO SEAL ruling").

## The move-set (residue class → EXISTING owner, never invented)

    bp task get cch-instruments-epic -o json     # open, published, top-level, cc 254 — REAL
    bp task get task-47bc4168392dec17 -o json    # "Cloud GUI remake — BUILD epic (phase 1)" open, top-level — REAL

- Console-honesty rows: RESOLVED/MERGED this wave (survivor #12158 password-401), closed per-row
  w/ merge SHA + file:line. Stay in THIS epic, closed.
- Instrument/gate/harness/required-checks/ledger-hygiene rows → cch-instruments-epic (law 0).
- gr-* GUI-remake FEATURE/OPS bulk → task-47bc4168392dec17 (or per-row true GUI-remake phase
  owner). NEVER cch-instruments-epic. NEVER an invented bucket (D83/D93/D94).
- 3 permanent human gates (bucket c) DISCLOSED by name; 1 considering row disclosed.

## Both denominators, stated SEPARATELY

- HONESTY ARC: 6 chartered divergences (D1-D6) — ALL closed, each asserted by a fail-able
  instrument (clause b = PASS). Verdict: "already honest, with evidence." COMPLETE.
- INHERITED BACKLOG: 422 orphan residue rows, overwhelmingly gr-* GUI-remake feature/ops that
  never matched the honesty predicate — genuinely unbuilt, re-homed per-row to the GUI-remake
  BUILD owner over successor waves. NOT fake-closed, NOT dumped.
