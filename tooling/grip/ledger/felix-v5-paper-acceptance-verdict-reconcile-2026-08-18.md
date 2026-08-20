# Felix V5 — paper-acceptance verdict-count reconcile (d02–d11)

Re-derives: do the 10 domain-audit paper-acceptance rows' STATED verdicts (in
criterion-1 evidence) reconcile against the actual verdict table in their cited
`/papers/felix-findings-<domain>`? Verdict: ALL 10 RECONCILE. 0 soft false-dones.
Two harmless summary off-by-ones (d08, d09), both zero-impact (task-producing
ADOPT/FILED/FINDING counts match exactly in every row).

## Row → domain → paper map (assignee felix-dNN)

| row task | assignee | paper slug |
|---|---|---|
| task-e65bb6be90a5551f | felix-d02 | felix-findings-plug-router |
| task-61962899695d9dfa | felix-d03 | felix-findings-boundaries-plugins |
| task-af49ba1c79935938 | felix-d04 | felix-findings-schemas-changesets |
| task-290094e86585781b | felix-d05 | felix-findings-transactions |
| task-18e49bfeea74287f | felix-d06 | felix-findings-queries-indexes |
| task-fa0adcb6b0c1fdf3 | felix-d07 | felix-findings-liveview-tracking |
| task-30564ed509eb2997 | felix-d08 | felix-findings-liveview-collections |
| task-57c1fafec69f1bd2 | felix-d09 | felix-findings-realtime |
| task-5b2231f3be5fd20d | felix-d10 | felix-findings-security-tenancy |
| task-45e104000ccb92d4 | felix-d11 | felix-findings-test-doctrine |

## Re-run (stated evidence)

    bp task get <row> -o json | python3 -c "import json,sys; print(json.load(sys.stdin)['doc']['content']['acceptance_criteria'][0]['evidence'])"

## Re-run (paper verdict table — code block carrying 'VERDICT')

    bp paper view felix-findings-<domain> -o json | python3 -c "import json,sys; [print(b['value']) for b in json.load(sys.stdin)['blocks'] if b.get('type')=='code' and 'VERDICT' in b.get('value','').upper()]"

NOTE: papers WITHOUT a dashed separator line under the header (d04) put the first
data row on line index 1 — a lines[2:] slice silently drops it. Count non-empty
lines and subtract the header line(s), do not slice blindly.

## Per-row verdict

- d02: table 9 concepts = 2 ADOPT / 5 already-good / 2 rejected. Stated enumeration matches exactly. PASS.
- d03: table 5 concepts = 3 already-good / 1 FINDING×2 (core-reaches-into-plugin) / 1 rejected. Exact match. PASS.
- d04: table 6 concepts = 3 already-good / 2 FINDING (binary_id, validations) / 1 rejected. All 6 named concepts match "all 6 concepts". PASS.
- d05: table 11 concepts = 2 ADOPT / 8 already-good (incl 1 documented-deferral: Sheets LWW) / 1 rejected-for-fashion (Ecto.Multi). Named verdicts match; no numeric count stated. PASS.
- d06: table 15 concepts = 9 already-good / 5 rejected-with-reason / 1 ADOPT(ready_query). "15 concepts" matches. PASS.
- d07: table 10 rows / stated 9 verdicts. Transcript concept split into 2 table rows (recompute + per-socket memory) both → same F1 task; stated folded into one line. Enumeration matches; harmless. PASS.
- d08: table = 1 ADOPT / 6 already-good / 3 rejected. Stated = "1 ADOPT / 5 already-good / 4 rejected". OFF-BY-ONE on the already-good↔rejected split of a borderline candidate row (AI-call-off-process assign_async cand). Total 10 and ADOPT 1 both match. HARMLESS: AG and rejected both file zero tasks → zero false-done impact.
- d09: table 14 rows = 12 already-good / 2 FILED. Stated "13-concept" (off by one) + legend lists "rejected-with-reason" but no row carries it (0 rows). FILED count = 2 matches exactly. HARMLESS.
- d10: 6-row table (a–f) matches stated exactly. Extra stated "webhook :internal + SAML CSRF rejected-with-reason" confirmed present in paper prose (felix-findings-security-tenancy line 119: "Webhook :internal payload — REJECTED-WITH-REASON"). PASS.
- d11: table 9 concepts = 3 already-good / 4 FINDING (sleep, async-env-scar, time-of-day, async-density) / 1 mostly-proper+gap / 1 rejected. Stated "flake taxonomy (3 findings)" = the 3 flake FINDING rows (order-dep flake is already-good, correctly excluded); +async-density FINDING = 4 total. Matches. PASS.

## Bottom line

Paper cohort fully reconciled: 12/12 (d01+d12 previously; d02–d11 here). No count
mismatch beyond harmless summary off-by-ones. No reopen warranted from V5.
