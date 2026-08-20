# Portability tripwire — mutation proof + node --check vacuity (epic-dist w1, v7)

Re-derivation recipes for the workflow-portability tripwire design. Prototype +
fixture live in the v7 scratchpad; the committed homes are
`scripts/workflow-portability-check.sh` + `scripts/workflow-portability-check.test.sh`.

## The engine dialect is valid in NO stock node mode

Engines are `export const meta` + top-level `return` + top-level `await` —
ESM reds on the return, CJS reds on the export. Only an async-body compile
after stripping `export ` mirrors the harness's acorn options:

    node -e 'const fs=require("fs");const s=fs.readFileSync(".claude/workflows/bp-epic-cycle.workflow.js","utf8");new (async function(){}).constructor(s.replace(/^export\s+/,""));console.log("compiles")'

## node --check is vacuous on every engine (mutation-proven)

`--check` bails GREEN as soon as module syntax is detected (node v22.22.0);
it only validates CJS files. Since every engine begins with `export`, the
chartered `node --check` clause can never fail:

    printf 'const broken = ;\n' > /tmp/a.js && node --check /tmp/a.js; echo $?          # 1 — real parse
    printf 'export const x = 1;\nconst broken = ;\n' > /tmp/b.js && node --check /tmp/b.js; echo $?   # 0 — VACUOUS

## Reference existence must be asserted against GIT, not disk (D31 inverse)

An untracked-but-on-disk charter passes every stat on this Mac and 404s on a
fresh clone; distribution is git, so the oracle is:

    git cat-file -e HEAD:.claude/workflows/bp-cloud-epic-charter.md; echo $?   # 0 = tracked

Corpus ENUMERATION stays working-tree (the harness readdirs disk); only
REFERENCES are asserted against HEAD. This is the deliberate inverse of
`scripts/cloud-path-escape-check.sh` honest-gates D31, where untracked disk
files are inputs to the running suite.

## Today's real-corpus verdict (4 findings, all view-edit-parity)

    grep -nE '/Volumes/|/Users/' .claude/workflows/*.workflow.js
    # view-edit-parity.workflow.js:65,66 (/Volumes consts) + :287,343 (/Users report path)

Home-relative clause (`$HOME|os\.homedir\(|process\.env\.HOME|['"` + backtick + `]~/`)
has ZERO hits in today's corpus — adopting it as RED costs no backlog.

## Sequencing inputs

    gh pr view 6086 --json state,mergeable,files   # OPEN, CONFLICTING, touches bp-epic-cycle.workflow.js
    gh pr diff 6086 | grep -cE '^\+.*(/Users/|/Volumes/)'   # 0 — tripwire independent of #6086

Guard-plus-fix: de-localize view-edit-parity FIRST (own PR), guard PR second,
so the guard's fail-before proof can run. Venue: shell-harnesses.yml
(pull_request + explicit paths; NOT one of the four required contexts) with
trigger glob `.claude/workflows/*.workflow.js` = the corpus definition itself.
