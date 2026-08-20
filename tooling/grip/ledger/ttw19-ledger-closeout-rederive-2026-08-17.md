# Task-TUI Wave 19 — ledger-closeout re-derivation recipes (2026-08-17)

Verifier: ledger-closeout-pack. NOT committed by me — Decide commits one phase later.

## (a) No prior D109 draft exists — Decide authors fresh
- `bp task get dr-w35-s1-union-charter-reconcile -o json` → parent_id `task-fb4fb869490b4213`, main_tag `deploy-reliability`, charter `bp-deploy-reliability-charter.md` D594. This is the DEPLOY-RELIABILITY charter reconcile (merged PR #11699), NOT task-tui. Zero bearing on task-tui D109.
- `git show origin/main:.claude/workflows/bp-task-tui-epic-charter.md | grep -n "Next D-number"` → `2346:Next D-number: D109.` (D109 unauthored). The one D114 hit at :2273 is a cross-ref to a felix decision, not a task-tui D-def.
- `bp doc history paper task-tui-wave-2026-08-17` → 4 revisions, ALL 2026-08-17 (this wave's own strategize+digest). Paper mentions "D109" 48x but as the PLANNED block, not a prior authored draft.

## (b) ttw18-narrow-rail-hover hygiene close AUTHORIZED, cite #6002
- `git show 425001b42a --stat` = PR #6002 "feat(taskboard): narrow-mode reading-frame rail stops gain hover paint (D99 close-out)", `Task: ttw18-narrow-rail-hover` trailer, files compose.go/compose_test.go/hitmap.go/hitmap_test.go/motion_test.go/program.go — exactly the criteria's files.
- `git merge-base --is-ancestor 425001b42a origin/main` → exit 0 (ON MAIN).
- `bp task get ttw18-narrow-rail-hover -o json` → criteria 0-4 all met=true with evidence; criterion 5 (MERGE-GATED, lead-closes-on-merge) met=false ONLY because never stamped. Merge happened. Close is evidence-backed.

## (c) NO live foreign claims on any taskboard task
- `bp task get task-tui-goal` → 14 children, 6 open, ALL assignee=None, zero live claims.
- Other taskboard-tagged tasks (taskboard-thread-chrome-tokens, ttm-s3-hover-tint, ttw17-rail-stop-hover, rail-awareness-l3/l4, tlv-bl-board-live-connected-mount-regression) all done, no live claim. mob-zb-bl-tui-board-thought-lanes + gr-bl-tasks-route-parent-filter-ignored open+unclaimed.

## (d) PDS epic — premise partly stale
- `bp task get task-2ac1f95237c4a8e5` → 596 children, last updated 2026-08-05 (dormant re taskboard). 
- pds-bl-taskboard-fetchpaper-unfenced: OPEN, P3, unclaimed, updated 2026-07-31.
- pds-bl-board-tui-reader-honesty: DONE (merged #8648 = 8b2018bc00), not open.
- pds-bl-twin-policy-split: DOES NOT EXIST (`bp task get` → not_found; `bp search query "twin policy split"` → no matching task). Premise wrong.

## (e) Four ttw* backlog lifecycle/priority/claim
| task | lifecycle | priority | assignee | claim |
|---|---|---|---|---|
| ttw18-narrow-rail-hover | open | 1 | epic-builder-…-gai (stale, expired 2026-07-23) | expired |
| ttw18-bl-wide-footer-verb-clicks | open | 3 | None | null |
| ttw18-bl-narrow-reading-width-skew | open | 3 | None | null |
| ttw17-bl-live-tmux-drive | open | 3 | None | null |
