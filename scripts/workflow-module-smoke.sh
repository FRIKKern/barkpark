#!/usr/bin/env bash
# workflow-module-smoke.sh — the syntax gate for .claude/workflows/*.workflow.js.
#
# WHY THIS EXISTS (honest-gates charter D66): the two gates previously written for
# these files are BOTH broken, in OPPOSITE directions, and each was measured:
#
#   • `node --check <file>` is VACUOUS. It exits 0 on bp-epic-cycle.workflow.js
#     with `const x = (((;` appended. A file carrying BOTH a top-level `export`
#     and a top-level `return` defeats Node's format sniffing: export+return+garbage
#     exits 0, while either one alone + the same garbage exits 1.
#   • `node --input-type=module --check < <file>` is a FALSE RED. It exits 1 on
#     UNMODIFIED main with `SyntaxError: Illegal return statement` at line 751,
#     because these files are run as a CLASSIC SCRIPT inside a vm by the workflow
#     runner and legitimately top-level `return`.
#
# THE WORKING GATE. A workflow file is neither a real ESM module nor a real script:
# it carries `export const meta`, a top-level `return`, and top-level `await`. So
# strip the ESM `export` keyword (/^export\s+/gm — the declarations stay, they just
# stop being exports) and parse the remainder as an ASYNC FUNCTION BODY via the
# AsyncFunction constructor, which legalises both the top-level `return` and the
# top-level `await`. Construction parses without executing: a SyntaxError fails the
# gate, anything else passes.
#
# MUTATION-PROVEN (this is a gate that CAN fail): green on all three workflow files,
# exit 1 with `Unexpected token ';'` on a copy with `const x = (((;` appended.
#
# USAGE:
#   scripts/workflow-module-smoke.sh                       # every .claude/workflows/*.workflow.js
#   scripts/workflow-module-smoke.sh path/to/one.js [...]  # only the named files
set -euo pipefail

cd "$(dirname "$0")/.."

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  while IFS= read -r f; do files+=("$f"); done < <(find .claude/workflows -maxdepth 1 -name '*.workflow.js' | sort)
fi

if [ ${#files[@]} -eq 0 ]; then
  echo "workflow-module-smoke: no .claude/workflows/*.workflow.js found — nothing to check" >&2
  exit 1
fi

status=0
for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "FAIL $f — no such file"
    status=1
    continue
  fi
  if err=$(node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8").replace(/^export\s+/gm, "")
    const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
    try {
      new AsyncFunction(src)
    } catch (e) {
      if (e instanceof SyntaxError) {
        process.stderr.write(e.message)
        process.exit(1)
      }
      throw e
    }
  ' "$f" 2>&1 >/dev/null); then
    echo "MODULE-SCOPE-OK $f"
  else
    echo "FAIL $f — ${err:-SyntaxError}"
    status=1
  fi
done

exit $status
