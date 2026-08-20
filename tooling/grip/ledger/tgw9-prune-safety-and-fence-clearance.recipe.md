# Recipe — wave-9 prune safety, fence clearance, worktree strand scan

Verifier: `prune-safety-and-fence-clearance` (truth-grip wave 9, 2026-07-27).
Baseline at run time: `origin/main = 3651da6cf3a83873976c11e635190c39e559b4dd`
(Strategize quoted `d505293a5`; main advanced by exactly 1 commit, `#6307`, which
touches only `.claude/workflows/bp-barkpark-tasks-mobile-charter.md` — outside this fence).

## R1 — the six branches are prune-safe (unique-file test, guarded)

```
git fetch origin --prune
git ls-tree -r --name-only origin/main | sort > /tmp/main.txt
for b in tgw4-round0-land docs/truth-grip-wave-8 docs/truth-grip-wave-8-charter-r \
         tgw2-charter-amendment truth-grip/wave5-decide truth-grip/wave6-decide-charter; do
  echo "== $b"
  comm -13 /tmp/main.txt <(git ls-tree -r --name-only origin/$b | sort)
done
```

Expected: each branch prints the SAME four paths, and only those four:
`api/lib/barkpark/studio_chat/notifier.ex`, `api/test/barkpark/studio_chat/notifier_test.exs`,
`cloud/lib/barkpark_cloud/sites/content_publish_verifier.ex`,
`templates/search-starter/app/(finder)/d/[type]/[slug]/loading.tsx`.

These are NOT branch work — they are files main DELETED after the branches forked. Prove it:

```
git log origin/main --oneline --diff-filter=D -- api/lib/barkpark/studio_chat/notifier.ex
# -> 8cc3e1f0c ... (#5562)   [also #6122 and #6212 for the other three]
```

Fence-scoped (`-- tooling/grip .claude/workflows .github/workflows`) the unique-file set is EMPTY
for all six. Conclusion: zero content is lost by deleting these refs.

## R2 — provenance: five merged, one not

```
for b in <the six>; do gh pr list --state all --head "$b" --limit 5 \
  --json number,state,mergedAt --jq '.[]|"#\(.number) \(.state) \(.mergedAt)"'; done
```

Five return a MERGED PR (#5191, #5491, #4937, #5314, #5384). `docs/truth-grip-wave-8`
returns NOTHING — it is the only ref with no PR, so it needs the content argument, not provenance:

```
C=.claude/workflows/bp-truth-grip-charter.md
git rev-parse origin/main:$C origin/docs/truth-grip-wave-8-charter-r:$C   # IDENTICAL blob
git show origin/docs/truth-grip-wave-8:$C | grep -nE '3\.(69|71)x|2(29|30) rows'
```

`docs/truth-grip-wave-8` carries the PRE-RATIFICATION draft (`229 rows`, `3.69x`, 1878 lines);
its sibling `-charter-r` landed the ratified text (`230 rows`, `3.71x`, 1905 lines) and that
blob is byte-identical to main. Deleting the draft REMOVES a wrong-digit copy — a prune that
improves the store rather than risking it.

## R3 — open-PR fence collisions (there are TWO, not one)

```
gh pr list --state open --limit 100 --json number,headRefName
gh pr view 6086 --json files --jq '.files[].path'
gh pr view 5754 --json files --jq '.files[].path'
```

- #6086 `feat/epic-memory-journeys-debrief` — modifies `.claude/workflows/bp-epic-cycle.workflow.js`
  (+200/-17, updated 2026-07-25, OPEN). CONFIRMED collision → drop that file from the fence.
- #5754 `docs/grad-ledger-w17` — modifies THREE `tooling/grip/ledger/*.json`. Collision is inside
  the fence, but harmless: all three blobs are ALREADY on origin/main and byte-identical.
  ```
  git cat-file -e origin/main:tooling/grip/ledger/grip-20260723T000000Z-v-fence-controlflow.json
  ```
  → #5754 is content-superseded and closable.

## R4 — worktree strand scan (1463 worktrees, not 11)

```
git worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' > /tmp/wt.txt
wc -l < /tmp/wt.txt                       # 1463
tr '\n' '\0' < /tmp/wt.txt | xargs -0 -P 12 -n 1 <scan.sh>
```

`scan.sh` must run `git -C "$wt" status --porcelain -- tooling/grip .claude/workflows .github/workflows`
and MUST echo a distinct `ERR(<rc>)` row on non-zero rc. Traps proven live:

- BSD `xargs` has no `-a` / `-d` → the naive form runs ZERO jobs and prints "0 dirty" (vacuous green).
- macOS has NO `timeout` binary → rc 127 on every worktree. Without the ERR branch this also
  reads as "0 dirty". (Note the irony: rc 127 is the same PATH_GONE signature `census.mjs:422`
  mis-files into the DECAYED set.)
- Prove the scan CAN fail before trusting it: plant an untracked file under a worktree's
  `tooling/grip/` and confirm it appears; remove it after.

Result at run time: `OK 1463 / DIRTY 70 / MISSING 0 / ERR 0`, 6.7s wall.

## R5 — what the scan found (the load-bearing part)

Uncommitted, absent-from-main edits to GRIP MODULES in four worktrees:

| worktree (under `/Volumes/SATECHI/github/barkpark/.claude/worktrees/`) | file | size |
|---|---|---|
| `wf_6d5c9474-c05-24` | `tooling/grip/screen.mjs` | +71/-2 — `--output=` / `--output <f>` write-flag guard on git verbs |
| `wf_0d2d3629-17e-30` | `tooling/grip/rerun.mjs` | +64/-3 — quote-blindness: WRITE_SHAPES firing on `>` inside quoted args |
| `wf_6d5c9474-c05-25` | `tooling/grip/rerun.mjs` | +17/-3 — argv-form (no `/bin/sh -c`) for untrusted `url` |
| `wf_6d5c9474-c05-21` | `tooling/grip/level.mjs` + `test/level.test.mjs` | +61/-5 — `segmentLevel` mention-immunity |
| `wf_d2874b15-076-4` | `.claude/workflows/bp-epic-cycle.workflow.js` | +32/-1 — E1 premise-smoke graduation |

Confirm any row is genuinely stranded (not merely behind main) by probing added lines:

```
git -C .claude/worktrees/wf_6d5c9474-c05-24 diff -- tooling/grip/screen.mjs \
  | grep '^+' | grep -v '^+++' | head
git grep -F "GIT_OUTPUT_RE" origin/main -- tooling/grip/screen.mjs   # no hit -> stranded
```

COMMITTED grip source, by contrast, is fully landed: across the 48 worktrees whose
`HEAD:tooling/grip` tree differs from main, the non-ledger unique-path set is EMPTY.
The only committed uniqueness is 11 ledger rows, all in `spill-janitor-wt`, plus 5
untracked ledger rows in `e2-review-w17`.

## R6 — the primary checkout is 3 commits AHEAD of origin/main

```
git rev-list --left-right --count main...origin/main    # -> 3   1
git diff --name-only origin/main...main -- tooling/grip .claude/workflows .github/workflows
```

The three are PR #6305's `api/**` work; fence overlap is EMPTY. But this is exactly why D83
says builders branch from `origin/main`, not from local `main`.
