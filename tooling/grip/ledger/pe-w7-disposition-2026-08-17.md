<!-- doc-tier: cold | canonical-for: pe-w7-disposition-census | budget: 1400tok -->
# pe-w7 ledger disposition — the non-terminal children, honestly sorted before the seal

> HISTORICAL RECORD (2026-08-17) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Slice `pe-w7-ledger-disposition` (task, epic `task-4792223ca9eb5a7d`). Executed live against
guerrilla.barkpark.cloud on 2026-08-17. The epic cannot close over a pile of open children —
this is the D51 SPLIT disposition (never a blanket close): merge-stranded rows closed on their
merged PR, genuine backlog re-parented to root so nothing orphans under the closed epic, and the
lead-owned residue left open and recorded.

## Before / after census (direct children of the epic)

| lifecycle    | BEFORE | AFTER |
|--------------|-------:|------:|
| in_progress  |      5 |     5 |
| open         |     37 |     8 |
| done         |     28 |    30 |
| cancelled    |      5 |     5 |
| **total**    | **75** | **48** |

27 children left the epic's rail (26 Bucket-B backlog + `pe-w3-wave-lead-ops`, all → root).
2 open rows advanced to done (Bucket-A closes). The 8 open + 5 in_progress that remain under the
epic are the intended survivors (this wave's own slices, the D52 live crown briefs, and the two
merge-gated stay-open rows) — see the exclusion list below.

## Bucket A — merge-stranded rows, closed on their merged PR (stamp-then-bare-close)

| row | PR | merged | disposition |
|-----|----|--------|-------------|
| pe-w6-notes-kernel-tier | #11929 | 18:11:28Z | already done 6/6 (lead-loop epoch 9) — no-op, recorded |
| pe-w6-census-recheck | #11935 | 18:09:31Z | already done 5/5 (lead-loop epoch 9) — no-op, recorded |
| pe-w6-authoring-door | #11930 | 18:39:42Z | already done 5/5 (lead-loop epoch 9) — no-op, recorded |
| pe-w4-bpml-fix-11814-fixtures | #11814 | 15:39:32Z (sha 23b08c1211) | crit2 stamped + bare-closed here, epoch 7 → done 3/3 |
| paper-excellence-wave-3-log | #11788 | 13:10:23Z (sha c936f88060) | crit2 stamped + bare-closed here, epoch 11 → done 3/3 |

None were foreign-claimed with an unexpired lease (the three w6 rows were already closed; the two
open rows carried no live claim). PR merge states verified with `gh pr view`. Choreography per
`pe-w7-close-recipe-live-proof-2026-08-17.md`: stamp every remaining criterion with verbatim
`--criterion-text` + evidence, then a bare `bp task close` (stamps do not bump the claim epoch).

Left OPEN by design (merge-gated, PRs still open — the lead closes on merge):
`pe-w6-bp-paper-new` (#11934 OPEN, 4/5) and `task-421937b559e1c570` (#11889 OPEN, 4/5).

## Bucket B — 26 genuine-backlog children re-parented to root (never stale-closed)

All moved with `bp task move <id>` (omit parent = root); each reads back `parent_id=null`, open,
criteria untouched. Moving (not closing) keeps real remaining work visible and un-orphaned.

pe-bl-asciicast-selfhost · pe-bl-clock-strip-block · pe-bl-code-emphasis ·
pe-bl-container-child-guard · pe-bl-declaration-panel · pe-bl-json-source-route-500s ·
pe-bl-live-census-post-deploy · pe-bl-main-advisory-gate-hygiene ·
pe-bl-notes-malformed-shapes-followup · pe-bl-stat-tile-dots · pe-bl-type-literal-ratchet ·
pe-bl-verdict-accent-tokens · pe-w1-bundle-table-scroll-chrome-gap (genuine 0/3, NOT stale) ·
pe-w2-bl-blockless-wave-papers · pe-w2-bl-device6-panels-stat-tone · pe-w2-bl-hollow-corpus-repair ·
pe-w2-bl-media-delete-where-used · pe-w2-bl-tripwire-nested-checkouts · pe-w2-bl-tui-token-bridge ·
pe-w2-rig-1x-demotion-branch-decide · pe-w2-rig-ci-image-baselines ·
pe-w2-verbatim-html-overwrite-hazard · pe-w5-shared-checkout-unblock · task-0098ba55d2642545 ·
task-21b7dd42b946b64e · task-328fe6a7248277c0

Read-back sample: `pe-w1-bundle-table-scroll-chrome-gap` → parent=None, life=open, 0/3.

## Excluded from the move (stay under the epic on purpose)

- **This wave's own slices**: pe-w7-cold-harness, pe-w7-fix-11934-regression, pe-w7-rubric-freeze,
  pe-w7-ledger-disposition, pe-w7-epic-seal, pe-w7-hg-anthropic-key, pe-bl-cold-agent-run,
  paper-excellence-wave-7-log.
- **D52 live crown briefs** (behind #11889): pe-bl-framed-finale-authoring (testimony-inviolable),
  pe-bl-css-bundle-freshness-gate, pe-w2-bl-device3-display-scale.
- **Merge-gated stay-open**: pe-w6-bp-paper-new (#11934), task-421937b559e1c570 (#11889).

## The split of pe-w3-wave-lead-ops (D51)

Re-claimed (fresh epoch 1), split, then released + moved to root. Final state **2/6, open**:

- **crit1 MET** — rehydrate `--write` under the active slot, int_3 census 60→0 — cites
  `pe-w5-serve-and-sweep` crit1 (`scanned 684, 0 to rewrite, 676 rewritten`).
- **crit3 MET** — 11 probe slugs 404 + `pe-bl-probe-paper-cleanup` closed — cites
  `pe-w5-serve-and-sweep` crit2.
- **crit0 MISS** — #11814 IS merged (sha 23b08c1211) and pe-w2-bpml-inline-vocabulary +
  pe-w2-section-frame-hook are done, but the `.instance-deploy-last` quote was not re-derived here.
- **crit2 MISS** — reader-stamp-guard half done via pe-w5; the bundle-table half is genuine 0/3
  backlog, re-filed standalone to root (`pe-w1-bundle-table-scroll-chrome-gap`), NOT stale-closed.
- **crit4 MISS** — shared-checkout fast-forward: lead/primary-host op, excluded this wave.
- **crit5 MISS** — GitHub issues #11754/#11770: lead issue op, excluded this wave.

## The three stray unpublished draft probes

`task-e0624364377ec229`, `task-6c1aa3b9189d5177`, `task-f6fe01dcf2bbd9a6` — all confirmed absent
from `bp task ls --all` (unpublished drafts, invisible to every board and to the epic's child
rail). They cannot orphan and cannot block the seal; recorded here rather than purged.

## Review addendum (wave-7 review, later the same day)

The rerun census now reads `48 {done: 31, in_progress: 5, open: 7, cancelled: 5}` — one
open→done beyond the AFTER column: **#11889 merged** (origin/main 4cb125cde1) and the lead
closed `task-421937b559e1c570` 5/5 on that merge, exactly the merge-gated path this row left
open for it. Consequence for D52: the crown gate is LIT — the three parked crown briefs
(pe-bl-framed-finale-authoring, pe-bl-css-bundle-freshness-gate, pe-w2-bl-device3-display-scale)
are now dispatchable. `pe-w6-bp-paper-new` (#11934) remains the one merge-gated open row.

## Rerun

```
bp task ls --all -o json | python3 -c "import json,sys; d=json.load(sys.stdin)['docs']; k=[t for t in d if t.get('parent_id')=='task-4792223ca9eb5a7d']; from collections import Counter; print(len(k), dict(Counter(t['lifecycle_status'] for t in k)))"
```
