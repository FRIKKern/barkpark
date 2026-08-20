# tgw10 — security close-by-content + dirty-worktree inventory (re-derivation recipes)

Every line below was RUN on 2026-07-27 against origin/main = 90ba3dcce.
Nothing here is a claim; each row is the command that re-derives the claim.

## 1. The shell-injection control behaves as a control (base 81c3afa3b)

    D=$(mktemp -d); cd "$D" && git -C /Volumes/SATECHI/github/barkpark archive 81c3afa3b tooling/grip | tar x \
      && M=/tmp/INJA-$$ && node -e "import('./tooling/grip/rerun.mjs').then(m=>{const r=m.probeHttp('http://localhost:1/\$(echo X > $M)',3000);console.log(JSON.stringify(r),require('fs').existsSync('$M'))})"
    # → {"code":0,"exit":7,"ms":18} true      ← curl failed (7), the injected write STILL happened

## 2. origin/main is NOT vulnerable

    D=$(mktemp -d); cd "$D" && git -C /Volumes/SATECHI/github/barkpark archive origin/main tooling/grip | tar x \
      && M2=/tmp/INJB-$$ && node -e "import('./tooling/grip/rerun.mjs').then(m=>{m.probeHttp('http://localhost:1/\$(echo X > $M2)',3000);setTimeout(()=>console.log('MAIN vulnerable:',require('fs').existsSync('$M2')),500)})"
    # → MAIN vulnerable: false
    # Mechanism: git show origin/main:tooling/grip/rerun.mjs | sed -n '414,423p'   (spawnArgv, no shell)
    # Landed: git log --oneline -1 8e3c9fbb7   (#5350, tgw4-bl-probehttp-shell-injection)

## 3. screen.mjs write-flag guards are ALL live on main (14-shape matrix, 10 refuse / 4 admit)

    node -e 'import("./tooling/grip/screen.mjs").then(m=>{for(const c of ["git log --output=/tmp/x -1","git log --output /tmp/x -1","git show --output=/tmp/x HEAD","go test -c ./...","go test -coverprofile=/tmp/x ./...","go test -trace=/tmp/t ./...","mix test --cover","mix test --export-coverage=x","npm version patch","npm config set x y","npm config get x","go test ./...","git log -1","npm version"])console.log(m.screenCommand(c).ok,"|",c)})'
    # The identifier GIT_OUTPUT_RE is ABSENT on main (grep -c → 0); the CAPABILITY is at screen.mjs:402-403.
    # An identifier grep is a LEVEL-SKIP for a capability question. Grep the behaviour, not the name.

## 4. classifySafety quote-awareness + the interpreter trap

    node -e 'import("./tooling/grip/rerun.mjs").then(m=>{for(const c of ["grep -n \"a > b\" f","echo hi > /tmp/x","sh -c \"rm -rf /tmp/y\"","psql -c \x27DROP TABLE docs\x27"])console.log(JSON.stringify(m.classifySafety(c)),"|",c)})'
    # → safe / refused(redirect) / refused(rm) / refused(SQL write). Landed 0f3a881b5 (#4983, tgw2).

## 5. Never-cry-wolf and the two owned test files, on main, TODAY

    node -e 'import("./tooling/grip/screen.mjs").then(m=>console.log(JSON.stringify(m.runNamedSets())))'
    # → {"falsePermissions":[],"falseRefusals":[]}
    node --test tooling/grip/test/screen.test.mjs tooling/grip/test/rerun.test.mjs   # → # fail 0 / # skipped 1
    # WARNING: run this in the REAL repo. Running it inside a `git archive tooling/grip` temp dir
    # manufactures 7 false failures (rerun.test.mjs needs a git repo). A control that is not a control.

## 6. Dirty grip worktrees — SERIAL scan, never parallel xargs

    git worktree list --porcelain | awk '/^worktree /{print $2}' | while IFS= read -r w; do \
      [ -d "$w" ] && git -C "$w" status --porcelain 2>/dev/null \
        | grep -E 'tooling/grip|bp-truth-grip-charter|wild-bulk-cycle' | sed "s|^|${w##*/} |"; done
    # 1455 worktrees, FIVE carry fence dirt:
    #   wf_6d5c9474-c05-24  M screen.mjs        → superseded by main (row 3)
    #   wf_6d5c9474-c05-25  M rerun.mjs         → superseded by main (row 2)
    #   wf_0d2d3629-17e-30  M rerun.mjs         → superseded by main (row 4)
    #   wf_6d5c9474-c05-21  M level.mjs + test  → NOT on main. Filed as tgw5-bl-level-mention-promotion.
    #   e2-review-w17       ?? 5 ledger rows    → 4 byte-identical to main, 1 absent:
    #                                             w34-chatlive-belt-semantics.recipe.md

## 7. The prune-destruction premise is FALSE

    git worktree prune --dry-run -v          # → ZERO lines. Nothing is prunable.
    # prune removes admin records only for worktrees whose DIRECTORY HAS VANISHED. All five dirs exist.
    # D106's "one `git worktree prune` from destruction" does not describe this repo's state.
    # The ban still costs nothing — keep it — but it is not the emergency it was booked as.
