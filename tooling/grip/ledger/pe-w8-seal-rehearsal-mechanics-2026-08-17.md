# pe-w8 seal-rehearsal — proven close/stamp mechanics (2026-08-17)

Re-derivation recipes for the D51 seal choreography, proven LIVE on throwaway
scratch tasks (task-8b185c906180c062 single-shot path; task-a290a437df2174d5
bare-close path — both created, closed done, safe to delete). Verifier: read-only
on the real epic; NEVER claimed task-4792223ca9eb5a7d.

## Facts proven (each with its rerun)

1. **Stamp does NOT bump the claim epoch.** Claim returned epoch 1; after
   `bp task stamp <id> w8-verify 1 --criterion 0 --met ...` the epoch stayed 1.
   Rerun (fresh scratch): claim, capture `.doc.claim.epoch`, stamp at that epoch,
   `bp task get <id> -o json | python3 -c '...print(d["claim"]["epoch"])'` → same.

2. **The "forbidden single-shot close --set" is NOT a self-grading refusal, and the
   exit code is 5, NOT 2 (D51 said exit 2 — REFUTED).** The ONLY guard is the same
   criterion-text guard stamp has:
   `bp task close <id> w8-verify 1 --set 'criteria:=[{"index":0,"met":true}]'`
   → exit 5, `{"error":{"code":"criterion_text_required",...}}`.

3. **A single-shot close --set WITH the verbatim criterion text SUCCEEDS** (there is
   no self-grading prohibition):
   `bp task close <id> w8-verify 1 done "..." --set 'criteria:=[{"index":0,"met":true,"criterion":"<verbatim>","evidence":"..."}]'`
   → exit 0, task closes done, criterion flips met. So D51's premise that the
   single-shot path is FORBIDDEN is wrong; it is merely GUARDED identically to stamp.
   The real seal may still prefer stamp-then-bare-close for a clean event trail, but
   the single-shot is not a trap.

4. **Clean bare-close path works** (the prescribed seal path):
   claim → stamp criterion → `bp task close <id> w8-verify <epoch> done "reason"`
   (no --set) → lifecycle=done, closed_by set, criteria_progress preserved.

## Epic current state (re-read live, do NOT claim)

`bp task get task-4792223ca9eb5a7d -o json` →
- lifecycle_status = open
- claim.epoch = **2**, claim.worker = **null** (LAPSED; expired_at 2026-08-17T16:30:01Z),
  previous_worker = epic-builder-serve-the-dark-60-and-sweep-guerrilla-op
- criteria_progress = {met:2, total:3}
- Next claim bumps epoch 2→3 (the 1→2 history + null worker already evidences that a
  re-claim-after-lapse bumps). The epoch-3 seal assumption holds ONLY if no one
  re-claims first; re-read immediately before the real seal.

## Verbatim text for the real stamp (index 2, the unmet criterion)

`Agent authoring guidance ships so a cold agent produces a premium Paper without hand-holding, verified by an actual cold-agent run`

Pass this EXACT string to `--criterion-text` (index 2) or the stamp/close 409s
criterion_text_required / criteria_mismatch.

## Publish-wall gotcha for the scratch (cost 6 failed drafts)

`bp task create --publish` trips THREE walls in sequence: label_spine (needs
non-trivial description + weighted tags with distinct strengths), unknown_tag
(tags[].tag must be REGISTERED — use `bp tag browse`; e.g. `tasks`,
`task-lifecycle`, `testing`), and duplicate_of (differentiate title+description).
Tag shape that passed: `[{"tag":"tasks","strength":81,"rationale":"..."},{"tag":"task-lifecycle","strength":56,"rationale":"..."}]`.
Guerrilla also threw one transient DBConnection.ConnectionError mid-run (known
swap-thrash 500) — the retry succeeded.
