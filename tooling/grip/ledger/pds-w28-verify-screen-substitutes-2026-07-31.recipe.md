# Recipe — PDS wave 28 verify [screen-substitutes]: which floor predicates slice 1 may legally use

Verifier lane `screen-substitutes` (PDS wave 28, 2026-07-31). Baseline: `origin/main` at run time;
`tooling/grip` read from the worktree AND cross-checked with `git show origin/main:…`.
Every row below is a re-DERIVATION recipe, not a citation.

## R1 — the (level, ok) pair for the whole substitute table

```
node -e 'Promise.all([import("./tooling/grip/level.mjs"),import("./tooling/grip/screen.mjs")]).then(([L,S])=>["git merge-base --is-ancestor abc origin/main","git branch --contains abc","git rev-list --count abc..origin/main","git cat-file -e origin/main:CLAUDE.md","git show origin/main:CLAUDE.md | sed -n 5p","git grep -n foo origin/main -- internal/cli","test -f CLAUDE.md","node -e 1","","git show origin/main:CLAUDE.md | head -1"].forEach(c=>{const s=S.screenCommand(c);console.log(JSON.stringify({c,level:L.deriveLevel(c),ok:s.ok,reason:s.reason}))}))'
```

Result, 10/10: only `merge-base` (L3) is refused with `write shape: git write verb`; `test -f` is
refused as an unknown head (fails CLOSED, L6); `node -e` is refused by name (L3); the empty string is
refused. Admitted: `branch --contains` L3, `rev-list --count` L3, `cat-file -e` L3,
`git show …| sed -n Np` **L2**, `git grep -n … origin/main -- path` **L3**, `git show …| head -1` L2.

## R2 — WHICH pattern fires (it is one alternation, not the allowlist)

```
git show origin/main:tooling/grip/screen.mjs | sed -n '1299p'      # the git write-verb entry
node -e 'console.log("git merge-base --is-ancestor a b".match(/\bgit\s+(push|commit|checkout|switch|reset|rebase|merge|clean|apply|am|fetch|pull|cherry-pick|restore|worktree\s+(add|remove|prune))\b/)[0])'   # -> "git merge"
git show origin/main:tooling/grip/screen.mjs | sed -n '362,365p'   # merge-base IS in GIT_READ_VERBS
```

Layer (b) ADMITS `merge-base`; layer (c)'s `\bmerge\b` matches the prefix because `-` is a word
boundary. Same shape over-refuses `git merge-tree` and `git checkout-index` — both still refused by
layer (b), so the carve-out costs no defence.

## R3 — the fix is PRECEDENTED, already shipped one module over

```
grep -n "merge(?!-base)" tooling/grip/rerun.mjs tooling/grip/test/rerun.test.mjs
sed -n '636,665p' tooling/grip/test/rerun.test.mjs      # §6c carve-out + PROTECTIVE fence test
```

`rerun.mjs` fixed this exact bug with `merge(?!-base)` plus a fence test asserting every real
`git merge` stays refused. `screen.mjs` never received it.

## R4 — the two pins the one-liner flips (this is the whole cost)

```
sed -n '418,428p' tooling/grip/test/adjudicate.test.mjs   # asserts screenCommand(merge-base).ok===false
sed -n '632,635p' tooling/grip/test/screen.test.mjs       # WAVE5_REACH = 254 over the frozen corpus
node -e '/* patch WRITE_SHAPES in memory, re-count fixtures/evidence-corpus.json */'
```

Measured: 652 corpus commands, admitted **254 → 258** (+4, all four `git merge-base --is-ancestor`).
`adjudicate.test.mjs:423` loops merge-base together with `git -C … show`; the loop must SPLIT, since
the `git -C` half stays refused (different defect).

## R5 — the global-option hole is OVER-PERMISSION, live, and orthogonal

```
node -e 'import("./tooling/grip/screen.mjs").then(S=>["git -C log push origin main","git -C show commit -m x","git --git-dir log push"].forEach(c=>console.log(c,JSON.stringify(S.screenCommand(c)))))'
```

All three ADMITTED (`ok:true`) — the global option's value is read as the sub-verb. Nothing in slice 1
may spell a substitute with `git -C`: that spelling is simultaneously over-refused in one shape and
the vehicle of a live write hole (`tgw4-screen-git-global-option-audit`, open).
