# Re-derivation recipes — Claude Code workflow registration invariants (2026-08-12)

Subject: what `.claude/workflows/*.js` must satisfy to be discovered, listed and launched by the
Claude Code harness. Derived from the installed binary `~/.local/share/claude/versions/2.1.228`
(L2 for THIS host's harness; a different installed version may differ — re-derive, never quote).

## R1 — `node --check <file.js>` is VACUOUS on any file containing `export`

    printf 'export const meta={a:1}\nconst x = ;\n' > /tmp/mut.js
    node --check /tmp/mut.js ; echo "rc=$?"          # -> rc=0  (NO error printed)
    printf 'const x = ;\n' > /tmp/mut2.js
    node --check /tmp/mut2.js ; echo "rc=$?"         # -> rc=1  SyntaxError
    cp /tmp/mut.js /tmp/mut.mjs && node --check /tmp/mut.mjs ; echo "rc=$?"   # -> rc=1

Never chain these with `&&` after a command that can fail (a failing `cat`/`grep` swallows the run
and the trailing `echo` reports the WRONG rc).

## R2 — `--input-type=module --check` is unusable on our engines (top-level `return`)

    cd <repo>/.claude/workflows
    for f in *.workflow.js; do node --input-type=module --check < "$f" >/dev/null 2>&1; echo "$f rc=$?"; done
    # -> rc=1 for all four: "SyntaxError: Illegal return statement"

The harness parses with acorn `{sourceType:"module", allowAwaitOutsideFunction:true,
allowReturnOutsideFunction:true}`; node's module check does not allow top-level `return`.

## R3 — harness-equivalent syntax mirror (dependency-free)

    node -e "const fs=require('fs');const s=fs.readFileSync(process.argv[1],'utf8').replace(/^export const meta/m,'const meta');try{new Function('args','dispatch','log','return (async()=>{'+s+'})()');console.log('PASS')}catch(e){console.log('FAIL',e.message)}" <file>

PASSes all four real engines; FAILs both syntax mutants of R1. It is syntax-only — it does NOT
catch: statement-before-export, non-pure meta literal, missing/empty name or description.

## R4 — the validator invariants, quoted from the binary

    strings -a -n 4 ~/.local/share/claude/versions/2.1.228 > /tmp/s.txt
    grep -o 'function eD(e).\{0,1100\}'   /tmp/s.txt | head -2   # size cap, parse opts, FIRST-statement rule
    grep -o 'function bDb(.\{0,500\}'     /tmp/s.txt | head -1   # export const meta = {ObjectExpression}
    grep -o 'function TDb(.\{0,600\}'     /tmp/s.txt | head -1   # required name+description; optional title/whenToUse/phases
    grep -o 'function Pvp(.\{0,900\}'     /tmp/s.txt | head -1   # pure-literal evaluator
    grep -o 'pM=[0-9]\{1,8\}'             /tmp/s.txt | head -1   # 524288

macOS `strings` needs `-a`; without it the JS payload is not scanned.

## R5 — skill-listing text and its 1536-char cut

    grep -o 'function fKt(.\{0,200\}' /tmp/s.txt   # `${description} - ${whenToUse}`
    grep -o 'function ZEb(.\{0,200\}' /tmp/s.txt   # slice(0, cap-1) + "…"
    grep -o 'function dKt(.\{0,120\}' /tmp/s.txt   # cap = skillListingMaxDescChars ?? JEb
    grep -o 'JEb=[0-9]\{1,6\}'        /tmp/s.txt   # 1536

Measure a file's listing length by evaluating its meta literal and comparing
`description + " - " + whenToUse` against 1536; the tail after `slice(0,1535)+"…"` must equal the
tail shown in the session's skill listing.

## R6 — discovery / precedence

    grep -o 'function VKt(.\{0,900\}'       /tmp/s.txt   # ancestor walk: <dir>/.claude/<kind> up to $HOME
    grep -o 'async function nEp(.\{0,1600\}' /tmp/s.txt  # flat readdir, *.js only, .mjs/.cjs/.ts = nearMissExt
    grep -o 'async function oEp(.\{0,1800\}' /tmp/s.txt  # Map by meta.name; farthest→nearest, so NEAREST wins
    grep -o 'async function ejt(.\{0,600\}'  /tmp/s.txt  # scriptPath = path.resolve(sessionCwd, scriptPath)

## R7 — meta.phases vs phase() drift

    node -e '<brace-match meta, eval, compare declared titles to /\bphase\((["\x27`])(...)\1/ matches>'

2026-08-12 reading: bp-epic-cycle 7/7, deep-investigation 6/6, view-edit-parity 5/5,
wild-bulk-cycle 11 declared vs 6 called (Recon, Survey, Build, Review, Polish never fire).
