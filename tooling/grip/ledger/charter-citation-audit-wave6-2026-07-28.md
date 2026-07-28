# Re-derivation recipes — charter & citation audit (cloud-console-hardening wave 6, 2026-07-28)

Baseline: `origin/main` (checkout HEAD a8c767dbd26e4770bd942f61a3e9c94ab5da8b87, clean tree).
Every command below reads `origin/main` directly, not the worktree.

| # | Claim | Re-derive with |
|---|---|---|
| 1 | The hardening charter cites NO GR-number except GR112 (line 305, itself a correction of borrowed arithmetic) | `git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \| grep -n 'GR[0-9]'` |
| 2 | GR27/28/36/44/57/65/77/90 all live in the GUI-Remake charter | `git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md \| grep -n 'GR27\|GR28\|GR36\|GR44\|GR57\|GR65\|GR77\|GR90'` |
| 3 | GR36 G-02 chose the connect refusal as a STOPGAP (rationale = backend state; names successor row) | `git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md \| sed -n '54p'` |
| 4 | GR44 already REVERSED it ("G-02's copy relaxes to allow re-connect in place") | `git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md \| sed -n '67p'` |
| 5 | The client relax was chartered into spa-finishers (l.292) then dropped at GR64's split (l.366 lists only 4 wire-ups) | `git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md \| sed -n '292p;366p'` |
| 6 | gr-p5-honesty-batch-2 PROVED zero app.js edits — the client was fenced out, not decided against | `bp task get gr-p5-honesty-batch-2 -o json` (criterion 5) |
| 7 | Stale claim lines on main are 1999/2001/2024, not the task brief's 1959-1964 | `git show origin/main:cloud/priv/static/app.js \| grep -n 'no unique index\|disconnect to replace\|Disconnect one above'` |
| 8 | The three client pins name GR36 as their rationale | `git show origin/main:cloud/priv/static/__app.test.mjs \| grep -n 'already-connected'` ; `git show origin/main:cloud/priv/static/__preview__/smoke.mjs \| grep -n 'GR36'` |
| 9 | GR65 falsely asserts "every other --ring-soft target changes colour per accent"; app.css:534 calls it "evergreen-frozen" | `git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md \| sed -n '90p'` ; `git show origin/main:cloud/priv/static/app.css \| sed -n '289p;376p;534,535p'` |
| 10 | ring-soft row is charter-recorded "unruled, not confirmed" (l.727) and Band 5 (l.1105) | `git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md \| sed -n '727p;1105,1106p'` |
| 11 | GR90 NARROWED the ok/danger defect to background-only and censused NO other colour-only pair | `git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md \| sed -n '121p'` |
| 12 | --danger is var(--cc-red-strong)/var(--cc-red), not derived from --danger-hsl; --danger-hsl does feed the vf-chip FAIL border | `git show origin/main:cloud/priv/static/app.css \| sed -n '68,69p;105,106p;3388,3389p'` |
| 13 | GR27/GR28(5) ratify trigger-only scoped to "this wave"; the backlog row demands a NEW permanent decision | `git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md \| sed -n '42p;43p'` ; row text at `sed -n '1073,1077p'` |
| 14 | Hardening fence = `cloud/` + `api/lib/barkpark_web/live/` | `git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \| sed -n '88,90p'` |
| 15 | bp search is REACHABLE (exit 0, non-empty) — the survey's "unchecked prior art" no longer holds | `bp search query "provider connect reconnect rotation already-connected" -o json > /tmp/s.json; echo $?; head -c 300 /tmp/s.json` |

Trap note: never `cmd | head && echo ok` — `head` supplies the exit status and masks a failing `cmd`.
