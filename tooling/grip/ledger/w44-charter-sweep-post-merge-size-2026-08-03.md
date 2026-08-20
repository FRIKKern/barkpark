# w44 — pds-charter-ledger-sweep: the real post-merge size, and the one place it fails OPEN

Derived 2026-08-03 against `origin/main` exported with `git archive` into a non-repo dir, and
against **#9312's charter blob** (`97421313a682eaaec952362d2ae8a888633f5b3a`, +303/-0, two
insertion hunks at charter lines 2578 and 2596 — everything below 2577 shifts by +302).
Host was NOT quiet (a wave is running). USER CPU is stable across trials; WALL is network and
varies 10.7 s → 43 s on the same command.

## Re-derivation

```bash
D=$(mktemp -d); git -C <repo> archive origin/main | tar -x -C "$D"; cd "$D"

# 1. main today — the CONTENT-RED
out=$(bash scripts/pds-charter-ledger-sweep.sh 2>&1); echo rc=$?      # -> rc=1
#   charter : .claude/workflows/bp-pds-charter.md (12012 lines)
#   table   : scripts/pds-charter-ledger-adjudication.md (105 adjudicated rows)
#   4. ADJUDICATION — 146 candidate lines / 100 slugs, ALL adjudicated
#   unresolved-claim arrivals : 41      (105 + 41 = 146, exactly)

# 2. --selftest dies at LEG 1 for the same root cause; legs 2 and 3 never run
bash scripts/pds-charter-ledger-sweep.sh --selftest 2>&1 | head -3; # rc=1
#   SELFTEST FAIL: the mutant run did not reach a clean arrival count (rc=1)

# 3. POST-MERGE — the same lens over #9312's charter blob
git show 97421313a682eaaec952362d2ae8a888633f5b3a:.claude/workflows/bp-pds-charter.md > /tmp/c9312.md
bash scripts/pds-charter-ledger-sweep.sh --charter /tmp/c9312.md; echo rc=$?   # -> rc=1
#   4. ADJUDICATION — 150 candidate lines / 102 slugs
#   unresolved-claim arrivals : 45 · misclassified : 0 · STALE ADJUDICATION ROWS : 0

# 4. THE FINGERPRINT IS LINE-FREE — fp = sha1(slug + "|" + normalized-line)[:12], sweep:312.
#    Diff the two --emit-template outputs: ZERO fingerprints dropped, exactly FOUR new.
bash scripts/pds-charter-ledger-sweep.sh --emit-template                 > /tmp/tpl-main.txt
bash scripts/pds-charter-ledger-sweep.sh --emit-template --charter /tmp/c9312.md > /tmp/tpl-9312.txt
comm -23 <(cut -d'|' -f2 /tmp/tpl-main.txt|tr -d ' '|grep -E '^[0-9a-f]{12}$'|sort) \
         <(cut -d'|' -f2 /tmp/tpl-9312.txt|tr -d ' '|grep -E '^[0-9a-f]{12}$'|sort)   # EMPTY
#   new: 468abae797a8 :2677 pds-w42-bl-grant-graded-component-arm-unbuilt [open]
#        16474b611076 :2712 pds-charter-ledger-adjudication.md          [updated]
#        b3e7d2e36f26 :2731 pds-idle-sampler.sh                         [now]
#        fce285a3aab9 :2876 pds-w42-caps-prop-is-a-mount-snapshot       [likewise]
#   ALL FOUR live inside the inserted block. The stopword shift (vocab 62 -> 63 tokens)
#   admitted ZERO previously-invisible OLD lines this time — unlike wave 39, whose
#   adjudication doc records charter:6923 arriving exactly that way.

# 5. 45 ROWS IS THE WHOLE PRICE — append them, the instrument goes GREEN.
#    (5 non-task + 40 non-disposition, appended mechanically to a COPY of the table)
bash scripts/pds-charter-ledger-sweep.sh --charter /tmp/c9312.md --table /tmp/tbl-9312.md; echo rc=$?
#   -> rc=0 · arrivals 0 · misclassified 0
#   OK: every one of the 150 candidate claims is adjudicated and resolved against the live ledger.

# 6. LEGS 2 AND 3 ARE SOUND — observed for the first time, with a completed table.
bash scripts/pds-charter-ledger-sweep.sh --selftest --table /tmp/tbl-full.md; echo rc=$?   # rc=0
#   RESIDUE-SLUG pds-selftest-cross-line-sentinel lines=12014
#   PROVEN: the run NAMES the planted cross-line claim as residue.
#   PROVEN: an unadjudicated same-line claim reds with rc=1 and is NAMED.
#   === SELFTEST OK: 3 of 3 ===        (wall 34 s)

# 7. THE PRICE, OS-metered around a SHELL (D633's only legal method)
/usr/bin/time -p bash scripts/pds-charter-ledger-sweep.sh              # real 42.96 user 3.20 sys 0.74
/usr/bin/time -p bash scripts/pds-charter-ledger-sweep.sh --ledger-cache <warm>  # real 10.69 user 2.62 sys 0.20
#   ~39 s of the cold wall is network + a deliberate time.sleep(0.3) per second-read (sweep:212).

# 8. ENVIRONMENT — fails CLOSED on the paged read, fails OPEN on the per-slug second read
env PATH=/usr/bin:/bin bash scripts/pds-charter-ledger-sweep.sh; echo rc=$?      # rc=2
#   pds-charter-ledger-sweep: UNCHECKED: bp is not installed
env BARKPARK_HOME=$(mktemp -d) XDG_CONFIG_HOME=$(mktemp -d) bash scripts/…sweep.sh; echo rc=$?  # rc=2
#   UNCHECKED: bp doc query … exited 1: bp: no server configured.
# BUT: prime --ledger-cache, delete confirm.json, remove ONE live slug from the cache so
# resolve() must take the second read, then put a bp shim that always `exit 1` on PATH:
#   real bp    -> "pds-w29-pay-lb  terminal  open  DISAGREES"
#   failing bp -> "pds-w29-pay-lb  terminal  -     MISCLASSIFIED" … "live reads None"
# Same corpus, same table, one variable changed. `resolve()` (sweep:194-213) calls
# bp_json(..., allow_error=True), which swallows BOTH a nonzero rc AND non-JSON output and
# returns None — indistinguishable from "confirmed absent". The run keeps printing
# "Each was CONFIRMED with a second read (`bp task get`)" while that read failed.
```

## What this settles

- **41 on main, 45 post-merge.** The delta is 4 rows, not a re-adjudication. The `line` column
  goes stale on 97 of the 105 committed rows (+302) but is display-only — never matched.
- **"Guaranteed rework" is too strong.** 41 of the 45 rows are portable across the merge
  byte-identical, because the fingerprint carries no line number. Ordering still matters — do it
  against #9312's blob and get all 45 in one pass — but the pre-merge work is 91% reusable, and
  wave 39's precedent (a stopword shift admitting an old line) did NOT recur here.
- **CONTENT-RED alone is the wrong single label.** The instrument reaches the live ledger every
  run; it is UNCHECKED-clean when bp is absent or unconfigured, and it fails OPEN in exactly one
  place — the per-slug second read — where a transient failure silently becomes NOT-A-TASK /
  MISCLASSIFIED. That is the epic's own law broken inside the instrument that enforces it.
- **The instrument has ZERO gate legs.** `grep -rn pds-charter-ledger-sweep` outside its own file
  returns nothing; `scripts/elixir-path-escape-check.sh` declares three pds- paths and this is not
  one of them. Its ~43 s cold wall and its live-ledger dependency make it a poor gate candidate
  regardless of the adjudication backlog.
