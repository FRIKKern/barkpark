<!-- doc-tier: cold -->
# Felix W31 — charter D208 floor + #12147 union-collision (re-derivation recipe)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Assignment charter-d208-floor-collision. All derived from origin/main at fetch time 2026-08-18.

## Facts + rerun

- **Max Felix D-number on origin/main = D201** (D202-D207 ABSENT, count 0):

  ```
  git fetch origin main -q
  git show origin/main:.claude/workflows/bp-felix-pristine-charter.md \
    | grep -oE '\*\*D[0-9]{1,3}' | grep -oE '[0-9]+' | sort -n | tail -3
  # -> 199 / 200 / 201
  git show origin/main:.claude/workflows/bp-felix-pristine-charter.md | grep -cE 'D20[2-7]'
  # -> 0
  ```

  Therefore Wave 31's first decision is **D208** (D202-D207 are reserved by open PR #12147).

- **D202-D207 are owned by the ONLY open PR touching the charter: #12147** (wave-30, head
  `epic-charter/felix-pristine-w30-20260818T020706Z`, state OPEN, merged=null, mergeState=BLOCKED):

  ```
  gh pr list --state open --limit 200 --json number,title,files \
    -q '.[] | select(.files[].path==".claude/workflows/bp-felix-pristine-charter.md") | "#"+(.number|tostring)+" "+.title'
  # -> #12147 docs(felix): wave-30 charter ... (D202-D207)
  gh pr view 12147 --json state,mergedAt,mergeStateStatus,headRefName
  ```

- **Insertion points** (line numbers on origin/main; re-derive, they drift):

  ```
  git show origin/main:.claude/workflows/bp-felix-pristine-charter.md | grep -nE '^## Wave log'
  # -> 2849:## Wave log
  ```

  - New `## Wave 31 Decisions (2026-08-18) — ...` block: insert IMMEDIATELY BEFORE `## Wave log`
    (currently line 2849). Last decisions section in file-order is `## Wave 28 Decisions` (line 2714),
    ending at the blank line before 2849. Note file-order is non-monotone: D199-D201 live in the
    `## Wave 29 Decisions` block (line 2622), which precedes Wave 28 in the file.
  - New `### Wave 2026-08-18 — Wave 31 ...` log entry: insert at the TOP of the Wave-log list
    (currently line 2851, above the Wave 29 entry) — the log is newest-first.

- **No `## Wave 30`/`## Wave 31 Decisions` header exists on origin/main** (grep returns NONE) — so
  D208 does not collide with anything landed.

## Merge-order rule (union collision with #12147)

Both Wave 31's charter note and #12147 edit `.claude/workflows/bp-felix-pristine-charter.md`, and both
add content at the same region (decisions block + top of Wave log) → a union/append conflict is likely.

- **If #12147 lands FIRST:** rebase Wave 31's note onto the new main. D202-D207 will then exist;
  Wave 31 KEEPS D208 and resolves the union by appending its block after #12147's D202-D207 and its
  log entry above #12147's wave-30 entry.
- **If Wave 31's note would land BEFORE #12147:** do NOT — that renumbers the ledger. Either wait for
  #12147, or #12147/wave-30 renumbers. Prefer: #12147 merges first, then Wave 31 rebases to D208.
  (#12147 is currently BLOCKED — red Sobelow gate per wave digest — so it will not race ahead.)

## Fence verdict

`.claude/workflows/bp-felix-pristine-charter.md` is NOT under `tooling/grip/`, `api/`, or `cloud/`.
No CLOUD_PATHS / CONSOLE_PATHS / truth-grip gate fires on this edit; only `doc-gates` (non-blocking).
