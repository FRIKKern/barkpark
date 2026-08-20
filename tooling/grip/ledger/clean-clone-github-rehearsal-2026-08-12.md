# Re-derivation recipe — GitHub clean-clone rehearsal (epic-cycle distribution wave, verifier v6)

Date: 2026-08-12 · main @ `20dd241ad99819e40bd522c7f5b5e086d34b42f3`

## 1. Clone from GitHub (L1 for "what a new machine gets")

```
cd <scratch> && rm -rf cc2
git clone --depth 1 https://github.com/FRIKKern/barkpark.git cc2
```

## 2. Engines arrive byte-identical to this checkout's origin/main

```
cd cc2 && for f in .claude/workflows/*.workflow.js; do shasum "$f"; done
# compare against, from the working checkout:
for f in $(git ls-tree --name-only origin/main .claude/workflows/ | grep 'workflow.js$'); do \
  printf "%s  %s\n" "$(git show origin/main:$f | shasum | cut -d' ' -f1)" "$f"; done
```

Expected (all four, both sides):
```
b57e9101bfe1a4e43dfde90096e26ad808be2f48  bp-epic-cycle.workflow.js       (941 L)
dbe2a05eaf4ebea700501411d1d03d17e08c9ca0  deep-investigation.workflow.js  (495 L)
134aa652afdffdeb01f206db150943b264a8bf5a  view-edit-parity.workflow.js    (344 L)
c0a3b77f4580cf86874051cd7d4ef13045b23ae5  wild-bulk-cycle.workflow.js     (937 L)
```

Drift check: `git ls-remote https://github.com/FRIKKern/barkpark.git refs/heads/main` == `git rev-parse origin/main`.

## 3. Harness-mirror parse (the check that CAN fail)

```
for f in .claude/workflows/*.workflow.js; do \
  node -e "const fs=require('fs');const s=fs.readFileSync('$f','utf8').replace(/^export const meta/m,'const meta');new Function('a','d','l','return (async()=>{'+s+'})()');console.log('PARSE OK $f')"; done
```

## 4. `node --check` is VACUOUS on these files — minimal repro

```
printf 'export const meta = {a:1};\nfunction broken( {\n' > triv2.js
node --check triv2.js > /dev/null 2>&1; echo $?   # => 0  (node v22.22.0)
printf 'function a( {\n' > triv.js
node --check triv.js  > /dev/null 2>&1; echo $?   # => 1  (same error, no `export`)
```
Any file containing an `export` statement passes `node --check` regardless of syntax
errors. Every workflow file starts with `export const meta`. Do not use `node --check`
as the tripwire; use the Function-wrapper mirror (rc=1 on the same mutated file).

## 5. `.claude/worktrees/` ignore gap is real in a fresh clone

```
mkdir -p .claude/worktrees/probe && touch .claude/worktrees/probe/x
git status --porcelain | head        # => ?? .claude/worktrees/
git check-ignore -v .claude/worktrees/probe/x; echo $?   # => 1 (no rule matches)
cat .git/info/exclude                # => stock template, no claude lines
```
The ignore lives ONLY in this Mac's `.git/info/exclude` (lines 7-17), which git never
clones. On main, `.gitignore` carries only `.claude/scheduled_tasks.lock` and `api/.claude/`.

## 6. CLAUDE.md headroom holds on main and in the clone

```
git show origin/main:CLAUDE.md | wc -c   # 9996
wc -c CLAUDE.md   (in cc2)               # 9996
```

## 7. Absence facts (re-derive with real exit codes, never through a pipe)

```
grep -rl 'scriptPath' docs/ CLAUDE.md > /dev/null 2>&1; echo $?   # 1 = no doc mentions scriptPath
grep -rl '\.claude' .github/workflows/ > /dev/null 2>&1; echo $?  # 1 = no CI job touches .claude
```
