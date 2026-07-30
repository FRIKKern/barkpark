# Re-derivation recipes — Site Spawner wave 11 ledger reconciliation (2026-07-30)

Worker: `wave11-verifier-ledger`. All writes read back immediately, one task at a time.

## 1. The six wave-10 slices are merged (the only unmet criterion was MERGE-GATED)

    cd /Volumes/SATECHI/github/barkpark
    for c in 0d855f94a 68cb7afcd fe264a35b 3e27a4915 4f046cce1 25e69158a; do
      git merge-base --is-ancestor $c origin/main && echo "$c ANCESTOR"; done
    git rev-parse --short origin/main            # 051112568

Mapping (commit → PR → slice), each verified by commit subject, not by assumption:

| commit | PR | slice |
|---|---|---|
| 0d855f94a | #7865 | ssw10-extractor-framing-integrity |
| 68cb7afcd | #7866 | ssw10-ability-implies-table |
| fe264a35b | #7867 | ssw10-retire-legacy-artifact-route |
| 3e27a4915 | #7868 | ssw10-fleet-build-admission-gate |
| 4f046cce1 | #7869 | ssw10-prebuilt-source-guard |
| 25e69158a | #7871 | ssw10-prebuilt-live-proof-journey |

Read the closed state back:

    for t in ssw10-extractor-framing-integrity ssw10-ability-implies-table \
             ssw10-retire-legacy-artifact-route ssw10-fleet-build-admission-gate \
             ssw10-prebuilt-source-guard ssw10-prebuilt-live-proof-journey; do
      bp task get $t -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];ac=d['content']['acceptance_criteria'];print(d['doc_id'],d['status'],d['lifecycle_status'],sum(1 for a in ac if a.get('met')),'/',len(ac))"; done

## 2. Two server gates make a close-time flip impossible (both hit for real)

* `bp task close --set 'criteria:=[…]'` on an unmet row → `{"error":{"code":"criteria_unmet:8"}}` —
  "criteria flipped in this very close command do not count". Stamp first, then close.
* `bp task stamp … --met` on a row whose text carries `MERGE-GATED` → refusal unless `--merge-gated`
  is passed ("that row is the lead's to close").

Working sequence per task: `bp task claim <id> <worker>` → read epoch → `bp task stamp <id> <worker>
<epoch> --criterion N --met --merge-gated --criterion-text "<verbatim>" --evidence "…"` → read back →
`bp task close <id> <worker> <epoch> done "…"` → read back.

## 3. The "phantom duplicate" is ordinary draft residue — discard, never cancel

    bp task ls --all -o json | python3 -c "import json,sys;ds=json.load(sys.stdin)['docs'];print(sum(1 for d in ds if d.get('status')=='draft'))"
    # 323 before, 322 after — drafts.<id> rows are a repo-wide convention, not a wave-10 mistake.

`drafts.ssw9-build-admission-gate` was the stale pre-cancel DRAFT of the published, already-cancelled
`ssw9-build-admission-gate` (`content.lifecycle_status: "open"` in the draft vs `"cancelled"`
published). A task-verb write there could have republished `open` and REVERTED the cancel. Correct kill:

    bp doc discard-draft task ssw9-build-admission-gate --yes      # {"operation":"discardDraft"}
    bp task get drafts.ssw9-build-admission-gate                    # not_found  (draft gone)
    bp task get ssw9-build-admission-gate -o json | grep -o '"rev":"[^"]*"' | head -1
    # rev c1758376738e81df4fe776df6016705d — unchanged, still cancelled

## 4. Not stamped, deliberately

* `ssw9-build-admission-gate` — already `cancelled` with
  `content.close_reason: "SUPERSEDED by ssw10-fleet-build-admission-gate … a strict SUPERSET"`.
  Stamping it against 3e27a4915 would credit one commit to two tasks.
* `ssw10-public-read-clamp` — left OPEN at 7/9: criterion 6 (reindex casualty) is a declared MISS in
  the holder's own now-line, and criterion 8 demands a NAMED independent reviewer per D83.
* `ssw10-prebuilt-journey-live-run` — still open 0/3; the crown-proof debt, untouched.

## 5. Charter position (premise smoke)

    git show origin/main:.claude/workflows/bp-cloud-site-spawner-charter.md | grep -c 'D98'   # 0
    git log -1 --format='%h %s' origin/main -- .claude/workflows/bp-cloud-site-spawner-charter.md
    # b0994f910 docs(spawner): wave 9 round-1 review log …  → main stops at D97
