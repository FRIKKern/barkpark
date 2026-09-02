#!/usr/bin/env bash
# docs-anchors-check.sh — CI link/anchor/header gate for the doc spine
# (strategy §5 + amendment A6).
#
# Blocking checks:
#   1. Every routing-table target in root CLAUDE.md resolves to a file.
#   2. Every docs/INDEX.md entry resolves to a file.
#   3. Every "Code anchors" line in docs/cards/*.md points at an existing
#      path; declared symbols (func/def/defmodule) grep to a real DEFINITION
#      with pattern 'func |def |defmodule ' (Go + Elixir). The '^#' heading
#      alternative (A6) applies to .md anchor paths ONLY — see §3.
#
# Self-test:  bash scripts/docs-anchors-check.sh --selftest
#   drives THIS script against mktemp fixture repos via DOCS_ANCHORS_ROOT,
#   proving each blocking check still reds on its own planted violation.
#   Unknown argument => exit 2 (distinct from a gate failure, exit 1).
#   4. G1 doc-tier header on every non-attic .md under docs/ and on surface
#      CLAUDE/AGENTS files. Exempt: web/CLAUDE.md (@AGENTS.md import stub),
#      _attic/, docs/cli/fixtures/. YAML-frontmatter files carry the header
#      on the first line after the closing '---'.
#   5. canonical-for values are unique repo-wide (one owner per fact-topic).
#   6. Every .md under _attic/docs-2026-06/ starts with "ARCHIVED" (G3;
#      scoped to docs-2026-06 only — legacy attic predates the convention;
#      .md only — log/xml/json residue would be corrupted by a banner).
#   8. @canonical capability:<slug> markers are unique repo-wide, sit on a
#      PUBLIC entry point, and their optional doc: backlink resolves — checked
#      only AFTER a planted fixture proves the scan can still find a defect.
#
# WARN-only (never fails the gate):
#   7. Duplication tripwires — prod IP literal, webhook signature literal,
#      dev-token literal outside their canonical owners. Vendored mirrors, the
#      append-only grip ledger and .changeset/ are pruned structurally (see §7).
#      Also warns when an ALLOWLIST entry has gone stale (path vanished, or the
#      file no longer carries the literal) — the one check here with a known
#      ground truth, so the section is not purely an absence proof.
#
# bash 3.2 compatible: no associative arrays, no mapfile.

set -euo pipefail

# Absolute path to THIS script — captured before any `cd`, so --selftest can
# re-invoke the REAL gate (never a copy) against a fixture root.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

usage() {
  echo "usage: docs-anchors-check.sh [--selftest|--help]"
  echo "  (no args)   run the gate over the repo (exit 0 pass / 1 fail)"
  echo "  --selftest  run the hermetic fixture suite (exit 0 pass / 1 fail)"
  echo "  DOCS_ANCHORS_ROOT=<dir> overrides the tree the gate walks"
}

MODE=run
if [ "$#" -gt 0 ]; then
  case "$1" in
    --selftest) MODE=selftest ;;
    -h|--help) usage; exit 0 ;;
    *) echo "docs-anchors-check: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi
if [ "$#" -gt 1 ]; then
  echo "docs-anchors-check: unexpected extra argument: $2" >&2; usage >&2; exit 2
fi

# --- self-test ---------------------------------------------------------------
# This gate was DARK: no fixture, no .test.sh, and REPO_ROOT hard-bound to
# `dirname $0/..`, so the only way to exercise it was to mutate the shared
# checkout. DOCS_ANCHORS_ROOT breaks that bind; every case below plants ONE
# violation in a throwaway 4-file repo and asserts the gate reds with a NAMED
# line — a green a blind harness would also produce is not a seal.
st_fixture() {
  local r="$1"
  mkdir -p "$r/docs/cards" "$r/api/lib"
  cat > "$r/CLAUDE.md" <<'FIXEOF'
<!-- doc-tier: agent | canonical-for: fixture-router | budget: 100tok -->
# Fixture router

| Group | Task pattern | Load |
|---|---|---|
| A | anything | `docs/cards/a.md` |
FIXEOF
  cat > "$r/docs/INDEX.md" <<'FIXEOF'
<!-- doc-tier: agent | canonical-for: fixture-index | budget: 100tok -->
- cards/a.md
FIXEOF
  cat > "$r/docs/cards/a.md" <<'FIXEOF'
<!-- doc-tier: agent | canonical-for: fixture-card-a | budget: 100tok -->
# Card A

## Code anchors

- api/lib/x.ex — defmodule Fixture.X
FIXEOF
  cat > "$r/api/lib/x.ex" <<'FIXEOF'
defmodule Fixture.X do
  def real_symbol, do: :ok
end
FIXEOF
}

ST_FAIL=0
st_case() {
  # $1 = case name, $2 = expected exit, $3 = substring the output must carry,
  # $4 = shell snippet mutating the fixture at $FIX
  local name="$1" want="$2" needle="$3" mutate="$4" out rc fix
  fix="$(mktemp -d)"
  st_fixture "$fix"
  # Cleared BEFORE the snippet runs, never after: the mutation is eval'd in THIS
  # shell, so an arm that supplies its own pin (`export CANON_PIN=...`) would
  # otherwise judge every later arm against it too.
  unset CANON_PIN
  # shellcheck disable=SC2034  # $FIX is consumed by the eval'd mutation snippet
  FIX="$fix"; eval "$mutate"
  set +e
  out=$(DOCS_ANCHORS_ROOT="$fix" bash "$SELF" 2>&1); rc=$?
  set -e
  rm -rf "$fix"
  if [ "$rc" != "$want" ]; then
    echo "SELFTEST FAIL: $name — expected exit $want, got $rc"
    printf '%s\n' "$out" | sed 's/^/    | /'
    ST_FAIL=1
    return
  fi
  if ! printf '%s\n' "$out" | grep -qF "$needle"; then
    echo "SELFTEST FAIL: $name — exit $rc as expected but output lacks: $needle"
    printf '%s\n' "$out" | sed 's/^/    | /'
    ST_FAIL=1
    return
  fi
  echo "ok:   selftest $name (exit $rc)"
}

if [ "$MODE" = selftest ]; then
  echo "== docs-anchors-check --selftest =="

  st_case "clean fixture passes" 0 "docs-anchors-check: PASS" ':'

  # §3 / DEFECT A: a symbol that lives ONLY in a '#' comment must NOT satisfy a
  # code anchor (it did — a card could claim an anchor for a deleted function).
  st_case "comment-only symbol reds" 1 "anchor symbol 'totallyFakeSymbolXyz' not found" '
    printf -- "- api/lib/x.ex — func totallyFakeSymbolXyz\n" >> "$FIX/docs/cards/a.md"
    printf "# totallyFakeSymbolXyz is only a comment\n" >> "$FIX/api/lib/x.ex"'

  # the '^#' arm survives, scoped to .md anchor paths (A6 heading anchors)
  st_case "md heading anchor still resolves via ^#" 0 "docs/notes.md :: headingSymbol" '
    printf -- "%s\n" "<!-- doc-tier: agent | canonical-for: fixture-notes | budget: 100tok -->" \
      "# Notes" "" "# func headingSymbol" > "$FIX/docs/notes.md"
    printf -- "- docs/notes.md — func headingSymbol\n" >> "$FIX/docs/cards/a.md"'

  # §3 / DEFECT C: the symbol is a LITERAL, not an ERE
  st_case "dotted symbol does not match its underscored form" 1 "anchor symbol 'Fixture.Sub.Mod' not found" '
    printf -- "- api/lib/x.ex — defmodule Fixture.Sub.Mod\n" >> "$FIX/docs/cards/a.md"
    printf "defmodule Fixture_Sub_Mod do\nend\n" >> "$FIX/api/lib/x.ex"'
  st_case "?-suffixed symbol does not match the bare name" 1 "anchor symbol 'default_enabled?' not found" '
    printf -- "- api/lib/x.ex — def default_enabled?\n" >> "$FIX/docs/cards/a.md"
    printf "  def default_enabled, do: true\n" >> "$FIX/api/lib/x.ex"'

  st_case "missing anchor path reds" 1 "anchors missing path: api/lib/gone.ex" '
    printf -- "- api/lib/gone.ex — def whatever\n" >> "$FIX/docs/cards/a.md"'

  # §1 / §2 / §3b — DEFECT B: an empty grep result must NAME the outcome, never
  # abort the run under `set -euo pipefail` and skip §3c-§8.
  st_case "unresolvable routing target reds" 1 "routing-table target does not resolve: docs/cards/ghost.md" '
    printf -- "| B | ghost | \140docs/cards/ghost.md\140 |\n" >> "$FIX/CLAUDE.md"'
  st_case "empty routing table fails by name" 1 "no routing-table targets found" '
    sed "s/^|//" "$FIX/CLAUDE.md" > "$FIX/c.tmp" && mv "$FIX/c.tmp" "$FIX/CLAUDE.md"'
  st_case "empty INDEX fails by name" 1 "no INDEX.md entries found" '
    printf -- "<!-- doc-tier: agent | canonical-for: fixture-index | budget: 100tok -->\n" > "$FIX/docs/INDEX.md"'
  st_case "zero non-card anchor docs is a legitimate pass" 0 "no non-card docs carry a" ':'
  st_case "stale non-card anchor path reds" 1 "Code-anchor path does not exist: api/lib/moved.ex" '
    printf -- "%s\n" "<!-- doc-tier: agent | canonical-for: fixture-media | budget: 100tok -->" \
      "# Media" "" "## Code anchors" "" "- api/lib/moved.ex — the mover" > "$FIX/docs/media.md"'

  # §3c cross-doc links
  st_case "dead cross-doc link reds" 1 "links to a missing doc" '
    printf -- "See [gone](../gone.md)\n" >> "$FIX/docs/cards/a.md"'

  # §4 G1 header
  st_case "missing G1 header reds" 1 "missing G1 doc-tier header" '
    printf -- "# no header here\n" > "$FIX/docs/bare.md"'

  # §5 canonical-for uniqueness
  st_case "duplicate canonical-for reds" 1 "has more than one owner" '
    printf -- "<!-- doc-tier: agent | canonical-for: fixture-card-a | budget: 100tok -->\n" > "$FIX/docs/dup.md"'
  st_case "two canonical-for: none do not collide" 0 "all canonical-for values unique" '
    printf -- "<!-- doc-tier: cold | canonical-for: none | budget: 100tok -->\n" > "$FIX/docs/n1.md"
    printf -- "<!-- doc-tier: cold | canonical-for: none | budget: 100tok -->\n" > "$FIX/docs/n2.md"'

  # §8 @canonical capability markers
  st_case "marker over a private defp reds" 1 "has no public def/func/export within 6 lines" '
    printf -- "# @canonical capability:fixture-private\n  defp helper_fn, do: :ok\n" >> "$FIX/api/lib/x.ex"'
  st_case "duplicate capability slug reds" 1 "claimed by >1 impl" '
    printf -- "# @canonical capability:fixture-dup\ndef one_fn, do: 1\n# @canonical capability:fixture-dup\ndef two_fn, do: 2\n" >> "$FIX/api/lib/x.ex"'
  st_case "dead doc: backlink reds" 1 "doc: points at a missing doc" '
    printf -- "# @canonical capability:fixture-doc doc:docs/nope.md\ndef three_fn, do: 3\n" >> "$FIX/api/lib/x.ex"'
  # SILENT ARMS. The three above prove §8 BITES; these prove it bites only where
  # it should — otherwise a scan that reds on everything would pass them all.
  st_case "well-formed marker over a public def passes, and is COUNTED" 0 "§8 scanned 1 @canonical marker(s)" '
    printf -- "# @canonical capability:fixture-ok\ndef four_fn, do: 4\n" >> "$FIX/api/lib/x.ex"'
  # ZERO markers is a LEGITIMATE tree — CLAUDE.md says a marker is REMOVED once
  # dedup kills its decoys. This arm is why §8 must never grow a -z assertion.
  st_case "a corpus of ZERO markers is a legitimate pass, reported not asserted" 0 "§8 scanned 0 @canonical marker(s)" ':'
  st_case "marker under node_modules/ is not scanned" 0 "docs-anchors-check: PASS" '
    mkdir -p "$FIX/node_modules/vendor"
    printf -- "# @canonical capability:fixture-vendored\n  defp v_fn, do: :ok\n" > "$FIX/node_modules/vendor/dep.ex"'
  st_case "marker in an unscanned extension is not scanned" 0 "docs-anchors-check: PASS" '
    printf -- "# @canonical capability:fixture-unscanned\n  defp u_fn, do: :ok\n" > "$FIX/api/lib/x.rb"'
  # A marker inside a TEST is fixture data, never an implementation. `defp` here
  # is deliberate: if the exclusion ever regresses, this arm reds on the
  # public-entry rule instead of passing quietly.
  st_case "marker in a test file is not scanned" 0 "§8 scanned 0 @canonical marker(s)" '
    printf -- "# @canonical capability:fixture-in-test\n  defp t_fn, do: :ok\n" > "$FIX/api/lib/x_test.exs"
    printf -- "// @canonical capability:fixture-in-gotest\nfunc TFn() {}\n" > "$FIX/api/lib/x_test.go"'

  # DEFECT A — the scan used to be blind to JavaScript (no *.mjs/*.js in
  # CANON_INCLUDES), so a marker squatting a slug, or sitting over a private
  # helper, in a .mjs file sailed through while §8 still printed "ok". These
  # two arms plant the same violations the .ex arms above plant, but in .mjs.
  st_case ".mjs duplicate capability slug reds" 1 "claimed by >1 impl" '
    printf -- "// @canonical capability:fixture-mjs-dup\nexport function oneFn() { return 1; }\n// @canonical capability:fixture-mjs-dup\nexport function twoFn() { return 2; }\n" > "$FIX/api/lib/dup.mjs"'
  st_case ".mjs marker over a private (unexported) helper reds" 1 "has no public def/func/export within 6 lines" '
    printf -- "// @canonical capability:fixture-mjs-private\nfunction helperFn() { return 1; }\n" > "$FIX/api/lib/private.mjs"'
  # A plain .js script (no `import`/`export` anywhere — the cloud/priv/static/
  # app.js shape) has no module boundary, so a bare top-level `function` IS
  # its public entry point; `.mjs` directly above proves the SAME shape still
  # REDs there, where `export` is the only public keyword a real ES module has.
  st_case ".js (non-module) marker over a bare top-level function passes" 0 "§8 scanned 1 @canonical marker(s)" '
    printf -- "// @canonical capability:fixture-js-bare-function\nfunction plainHelper() { return 1; }\n" > "$FIX/api/lib/plain.js"'

  # DEFECT B — canon_hits() used to grep the bare literal anywhere in a file,
  # so a @moduledoc/docstring QUOTING an existing slug in prose false-REDded as
  # a duplicate (PR #12710). This plants a real marker AND a separate file
  # whose docstring merely quotes that same slug to explain it — the quote must
  # not be counted, so the run stays green with exactly one real marker.
  st_case "docstring quoting an existing slug does not false-RED as a duplicate" 0 "docs-anchors-check: PASS" '
    printf -- "# @canonical capability:fixture-quoted\ndef real_fn, do: :ok\n" >> "$FIX/api/lib/x.ex"
    printf -- "%s\n" \
      "defmodule Fixture.Quote do" \
      "  @moduledoc \"\"\"" \
      "  See @canonical capability:fixture-quoted for context on the predicate" \
      "  this module tests." \
      "  \"\"\"" \
      "end" > "$FIX/api/lib/quote.ex"'

  # §8b EXTRACTOR. Under the single-pass strip this pinned the literal token
  # `function`, so the supplied pin below would MISMATCH and the arm would red.
  st_case "8b pin reaches the identifier past 'export async function'" 0 "§8b all 1 marker pairing(s) match the pin" '
    printf -- "// @canonical capability:fixture-async\nexport async function fixtureAsyncFn(a) { return a; }\n" > "$FIX/api/lib/y.ts"
    printf -- "fixture-async\tfixtureAsyncFn\n" > "$FIX/pin"
    export CANON_PIN="$FIX/pin"'

  # §12 COLD-DOC BANNER. Two RED arms — one per fence shape — because keying only
  # on a bash-tagged fence would have covered 16 of 47 real cases (see §12's own
  # comment). Fixtures are built with QUOTED heredocs, never printf: a fence is
  # three backticks, and in the double-quoted printf these arms first used, bash
  # read them as command substitution. The files came out empty of fences, §12
  # scanned 0, and the two SILENT arms below passed on mangled input — a vacuous
  # green that a heredoc makes structurally impossible.
  st_case "cold doc with a bash-tagged fence and no banner REDS, naming the file" 1 "docs/cold-a.md is doc-tier: cold and carries runnable commands" '
    cat > "$FIX/docs/cold-a.md" <<"CASEA"
<!-- doc-tier: cold | canonical-for: fixture-cold-a | budget: 100tok -->
# Cold A

```bash
git status
```
CASEA'

  st_case "cold doc with an UNTAGGED fence of commands and no banner REDS" 1 "docs/cold-b.md is doc-tier: cold and carries runnable commands" '
    cat > "$FIX/docs/cold-b.md" <<"CASEB"
<!-- doc-tier: cold | canonical-for: fixture-cold-b | budget: 100tok -->
# Cold B

```
bp task close x w 1 done "s"
```
CASEB'

  # SILENT ARMS — §12 must bite ONLY where it should, or the banner becomes noise
  # that gets waived. Each of these three is a GREEN the gate has to earn, and
  # each asserts the COUNT, so a detector that has gone blind cannot pass them.
  st_case "the banner satisfies §12, and the doc is COUNTED" 0 "§12 scanned 1 cold doc(s) carrying runnable commands; 0 missing" '
    cat > "$FIX/docs/cold-c.md" <<"CASEC"
<!-- doc-tier: cold | canonical-for: fixture-cold-c | budget: 100tok -->
# Cold C

> HISTORICAL RECORD (2026-01-02) — the commands below were run on that date.

```bash
git status
```
CASEC'

  st_case "an untagged fence of OUTPUT is not a command block" 0 "§12 scanned 0 cold doc(s)" '
    cat > "$FIX/docs/cold-d.md" <<"CASED"
<!-- doc-tier: cold | canonical-for: fixture-cold-d | budget: 100tok -->
# Cold D

```
cond_b=OK ok=1
total 42
```
CASED'

  st_case "an agent-tier doc with commands is out of scope for 12" 0 "§12 scanned 0 cold doc(s)" '
    cat > "$FIX/docs/warm-e.md" <<"CASEE"
<!-- doc-tier: agent | canonical-for: fixture-warm-e | budget: 100tok -->
# Warm E

```bash
git status
```
CASEE'

  echo ""
  if [ "$ST_FAIL" -ne 0 ]; then
    echo "docs-anchors-check --selftest: FAILED"
    exit 1
  fi
  echo "docs-anchors-check --selftest: PASS"
  exit 0
fi

# DOCS_ANCHORS_ROOT lets --selftest (and any future harness) point the gate at a
# fixture tree instead of the shared checkout. Unset in CI: the default is the
# repo this script lives in.
REPO_ROOT="${DOCS_ANCHORS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_ROOT"

# §8b marker→symbol pin. Overridable so a harness can point it at a temp file
# and prove the arm REDs without planting anything in the real checkout.
# Whether the caller SUPPLIED one is captured before defaulting: the pin belongs
# to THIS repo, so a fixture root must not be judged against it unless the
# harness brought its own.
CANON_PIN_EXPLICIT=${CANON_PIN+1}
CANON_PIN_EXPLICIT=${CANON_PIN_EXPLICIT:-0}
CANON_PIN="${CANON_PIN:-$REPO_ROOT/scripts/canonical-marker-bindings.pin}"

FAIL=0
WARN=0

fail() { echo "FAIL: $*"; FAIL=1; }
warn() { echo "WARN: $*"; WARN=$((WARN + 1)); }

# --- generated / scratch trees: PRUNE at the walk, not after it (D18) --------
# §5, §7 and §8 walk the whole repo. On a clean CI checkout that is cheap; on a
# working checkout node_modules (~46k files), js/node_modules (another ~1.3G),
# _build, deps and the .omx / .claude worktree scratch trees dominate the walk —
# the run took 17+ minutes and had to be killed, i.e. the gate was not runnable
# LOCALLY, which is exactly where doc edits are made. Every directory below was
# ALREADY dropped by a `-not -path` / `grep -v` filter AFTER the walk, so moving
# the exclusion INTO the walk is a pure performance fix: same result set, one
# order of magnitude less I/O. Scratch checkouts (.omx, .tmp-bp89, .claude) are
# copies of the repo — their headers/markers are duplicates by construction and
# were already excluded by §7 (D26) and by §5's './.claude' exclusion.
# `find`: name-matched so nested copies (js/node_modules, api/_build) prune too.
prune_find() {
  # $@ = extra find predicates applied to the surviving tree
  find . \
    \( -name node_modules -o -name _build -o -name deps -o -name .git \
       -o -name .omx -o -name .tmp-bp89 -o -name .claude -o -name .artifacts \
       -o -path './_attic' -o -path './cloud/priv/templates' \) -prune -o \
    "$@"
}
# `grep -r`: same trees, minus _attic (§7/§8 filter _attic themselves downstream).
GREP_PRUNE=(--exclude-dir=node_modules --exclude-dir=_build --exclude-dir=deps
  --exclude-dir=.git --exclude-dir=.omx --exclude-dir=.tmp-bp89
  --exclude-dir=.claude --exclude-dir=.artifacts)

HEADER_RE='^<!-- doc-tier: (agent|human|cold) \| canonical-for: [A-Za-z0-9._-]+ \| budget: [0-9]+tok -->'

# Return the G1 header line of a file (first line, or first line after a
# leading YAML frontmatter block), or nothing.
header_line() {
  local f="$1" first
  first=$(head -n 1 "$f")
  if printf '%s\n' "$first" | grep -Eq "$HEADER_RE"; then
    printf '%s\n' "$first"
    return 0
  fi
  if [ "$first" = "---" ]; then
    awk 'NR==1{next} /^---$/{getline; while ($0 == "") getline; print; exit}' "$f"
  fi
}

# --- 1. routing-table targets in root CLAUDE.md ----------------------------
echo "== routing-table targets (CLAUDE.md) =="
# `|| true`: a table that has been reformatted away makes `grep` exit 1, and
# under `set -euo pipefail` that aborted the WHOLE run — printing only the
# section header and leaving the friendly failure below PROVABLY UNREACHABLE
# (and §3c-§8 never running, so a real duplicate canonical-for stayed hidden
# behind it). Same idiom §5/§8 already use. A non-match is not an error.
ROUTE_TARGETS=$(grep -E '^\|' CLAUDE.md | grep -oE '`[A-Za-z0-9._/-]+\.md`' | tr -d '`' | sort -u || true)
if [ -z "$ROUTE_TARGETS" ]; then
  fail "no routing-table targets found in CLAUDE.md — table missing or reformatted"
fi
for t in $ROUTE_TARGETS; do
  if [ -f "$t" ]; then
    echo "ok:   route -> $t"
  else
    fail "routing-table target does not resolve: $t"
  fi
done

# --- 2. docs/INDEX.md entries ----------------------------------------------
echo "== INDEX entries (docs/INDEX.md) =="
# `|| true` for the same pipefail reason as §1: an INDEX.md that lists nothing
# (or only self-references) is a real failure, but it must be REPORTED, not an
# undiagnosed exit 1 that also skips every later section.
INDEX_ENTRIES=$(grep -oE '[A-Za-z0-9._/-]+\.md' docs/INDEX.md | grep -v '^INDEX\.md$' | sort -u || true)
if [ -z "$INDEX_ENTRIES" ]; then
  fail "no INDEX.md entries found in docs/INDEX.md — index empty, self-referential, or reformatted"
fi
for e in $INDEX_ENTRIES; do
  # entries are relative to docs/ (../_attic/... resolves out of docs/)
  if [ -f "docs/$e" ]; then
    echo "ok:   index -> docs/$e"
  else
    fail "INDEX.md entry does not resolve: docs/$e"
  fi
done

# --- 3. card Code anchors ---------------------------------------------------
echo "== card Code anchors =="
for card in docs/cards/*.md; do
  if ! grep -q '^## Code anchors' "$card"; then
    fail "$card has no '## Code anchors' section"
    continue
  fi
  # anchor lines: "- <path> — <description with optional func/def/defmodule symbols>"
  awk '/^## Code anchors/{on=1; next} /^## /{on=0} on && /^- /' "$card" |
  while IFS= read -r line; do
    apath=$(printf '%s\n' "$line" | sed -E 's/^- ([^ ]+) —.*/\1/')
    if [ -z "$apath" ] || [ "$apath" = "$line" ]; then
      echo "FAIL: $card anchor line not parseable: $line"
      continue
    fi
    if [ ! -e "$apath" ]; then
      echo "FAIL: $card anchors missing path: $apath"
      continue
    fi
    # extract symbols declared after func/def/defmodule keywords
    symbols=$(printf '%s\n' "$line" |
      grep -oE '(func|def|defmodule) [A-Za-z_][A-Za-z0-9_.]*[?!]?' |
      awk '{print $2}' || true)
    if [ -z "$symbols" ]; then
      echo "ok:   $card -> $apath (path only)"
      continue
    fi
    # The '^#' alternative (A6) is for MARKDOWN heading anchors — but applied to
    # code it matched any '#' comment, so a symbol surviving only in a comment
    # satisfied the anchor (proven with a .go file, where '#' is not even a
    # comment character): a card could claim an anchor for a DELETED function,
    # the exact rot this section exists to prevent. Scope it to .md paths.
    case "$apath" in
      *.md) symbol_pat='(func |def |defmodule |^#)'; symbol_pat_desc='func |def |defmodule |^#' ;;
      *)    symbol_pat='(func |def |defmodule )';    symbol_pat_desc='func |def |defmodule ' ;;
    esac
    for sym in $symbols; do
      # $sym is a LITERAL, not a sub-pattern: unescaped, 'Barkpark.Media.X' was
      # satisfied by 'Barkpark_Media_X' (dot = any char) and 'default_enabled?'
      # by 'def default_enabled' (? = optional preceding char).
      sym_lit=$(printf '%s' "$sym" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
      if grep -Eq "$symbol_pat.*$sym_lit" "$apath"; then
        echo "ok:   $card -> $apath :: $sym"
      else
        echo "FAIL: $card anchor symbol '$sym' not found in $apath (pattern: $symbol_pat_desc)"
      fi
    done
  done > /tmp/anchors-out.$$ || true
  cat /tmp/anchors-out.$$
  if grep -q '^FAIL:' /tmp/anchors-out.$$; then FAIL=1; fi
  rm -f /tmp/anchors-out.$$
done

# --- 3b. Code anchors in NON-card agent docs (path existence) ---------------
# Cards (3 above) are fully validated, but other docs carrying a '## Code
# anchors' section were UNCHECKED — a stale ref in docs/media/DISCOVERY.md
# (api/lib/barkpark/media/search.ex, a file that moved) sailed past CI. A live
# doc pointing at a deleted path is worse than dead: it misdirects every reader
# (human and AI). Validate that every non-card anchor PATH still exists.
# Handles both formats: bare "- path —" and backticked "- `path` —"; requires
# the " —" separator so prose bullets are skipped, not false-failed.
echo "== Code anchors in non-card docs (path existence) =="
# `|| true`: ZERO non-card docs carrying a '## Code anchors' section is a
# LEGITIMATE state — without it the empty grep aborted the run (a FALSE RED with
# no message, and §3c-§8 silently skipped). Say so by name instead.
NONCARD_ANCHOR_DOCS=$(grep -rl '^## Code anchors' docs --include='*.md' | grep -v '^docs/cards/' | sort -u || true)
if [ -z "$NONCARD_ANCHOR_DOCS" ]; then
  echo "ok:   no non-card docs carry a '## Code anchors' section"
fi
for doc in $NONCARD_ANCHOR_DOCS; do
  awk '/^## Code anchors/{on=1; next} /^## /{on=0} on && /^- /' "$doc" |
  while IFS= read -r line; do
    apath=$(printf '%s\n' "$line" | sed -E 's/^- *`?([A-Za-z0-9_./-]+)`? *—.*/\1/' | sed 's#/$##')
    case "$apath" in ""|"-"|*" "*) continue ;; esac   # no " —" anchor → prose bullet, skip
    if [ -e "$apath" ]; then
      echo "ok:   $doc -> $apath"
    else
      echo "FAIL: $doc Code-anchor path does not exist: $apath (stale reference — repoint or remove)"
    fi
  done > /tmp/nc-anchors.$$ || true
  cat /tmp/nc-anchors.$$
  if grep -q '^FAIL:' /tmp/nc-anchors.$$; then FAIL=1; fi
  rm -f /tmp/nc-anchors.$$
done

# --- 3c. Cross-doc markdown links (.md) resolve ----------------------------
# Inline [text](path.md) and reference-style [id]: path.md links to OTHER docs
# must resolve to a real file. Catches "docs referencing removed docs" — e.g.
# bokbasen-api-contract.md linked a companion deleted in #216, seven times, and
# every prior gate (Code anchors, routing table, INDEX) missed inline .md links.
# Relative .md links only; external (http), absolute (/…), and #anchor-only links
# are skipped, and links carrying a "title" are under-checked rather than
# false-failed — so this stays safe as a blocking gate. (rustc-dev-guide style.)
echo "== cross-doc .md links =="
LINK_DOCS=$(
  {
    find docs -name '*.md' -not -path 'docs/cli/fixtures/*'
    find . -maxdepth 2 \( -name 'CLAUDE.md' -o -name 'AGENTS.md' -o -name 'README.md' \) \
      -not -path './node_modules/*' -not -path './deps/*' -not -path './_build/*'
  } | sed 's|^\./||' | sort -u
)
for doc in $LINK_DOCS; do
  dir=$(dirname "$doc")
  {
    grep -oE '\]\([^) ]+\)' "$doc" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//'
    grep -oE '^\[[^]]+\]:[[:space:]]+[^[:space:]]+' "$doc" 2>/dev/null | sed -E 's/^\[[^]]+\]:[[:space:]]+//'
  } | while IFS= read -r raw; do
    lnk=${raw%%#*}
    case "$lnk" in *.md) ;; *) continue ;; esac
    case "$lnk" in http*|/*|"") continue ;; esac
    resolved=$(python3 -c "import posixpath,sys; print(posixpath.normpath(posixpath.join(sys.argv[1],sys.argv[2])))" "$dir" "$lnk" 2>/dev/null)
    [ -e "$resolved" ] || echo "FAIL: $doc links to a missing doc: $lnk (resolved: $resolved)"
  done > /tmp/doclinks.$$ || true
  cat /tmp/doclinks.$$
  if grep -q '^FAIL:' /tmp/doclinks.$$; then FAIL=1; fi
  rm -f /tmp/doclinks.$$
done

# --- 4. G1 doc-tier header --------------------------------------------------
echo "== G1 doc-tier headers =="
HEADER_FILES=$(
  {
    find docs -name '*.md' -not -path 'docs/cli/fixtures/*'
    find . -maxdepth 2 \( -name 'CLAUDE.md' -o -name 'AGENTS.md' \) \
      -not -path './_attic/*' -not -path './node_modules/*' \
      -not -path './web/CLAUDE.md'
  } | sed 's|^\./||' | sort -u
)
for f in $HEADER_FILES; do
  h=$(header_line "$f")
  if printf '%s\n' "$h" | grep -Eq "$HEADER_RE"; then
    echo "ok:   header $f"
  else
    fail "$f missing G1 doc-tier header (<!-- doc-tier: agent|human|cold | canonical-for: <topic> | budget: <N>tok -->)"
  fi
done

# --- 5. canonical-for uniqueness (repo-wide, non-attic) ----------------------
echo "== canonical-for uniqueness =="
DUPES=$(
  prune_find -name '*.md' -print |
  while IFS= read -r f; do
    h=$(header_line "$f")
    # `grep` returns 1 for a header-less file (README etc.); `|| true` keeps that
    # benign miss from aborting the substitution when the gate runs under
    # `set -o pipefail` (GitHub Actions' default shell) — a non-match is not an error.
    printf '%s\n' "$h" | { grep -E "$HEADER_RE" || true; } |
      sed -E 's/.*canonical-for: ([A-Za-z0-9._-]+) \|.*/\1/'
    # `none` is the explicit "owns no fact-topic" value: cold/ledger evidence
    # files (tooling/grip/ledger/*.md, wave verdicts) legitimately share it, so
    # it is exempt from the one-owner-per-topic rule. Only REAL topic slugs must
    # be unique. Without this, three wave ledger files each declaring `none`
    # collide on main (each green alone — the stale-green accumulator), redding
    # doc-gates for a non-violation. Real duplicate slugs are still caught below.
  done | grep -vxE 'none' | sort | uniq -d || true
)
if [ -n "$DUPES" ]; then
  for d in $DUPES; do
    fail "canonical-for '$d' has more than one owner: $(grep -rl "canonical-for: $d " --include='*.md' "${GREP_PRUNE[@]}" . | grep -v _attic | grep -v node_modules | tr '\n' ' ')"
  done
else
  echo "ok:   all canonical-for values unique"
fi

# --- 6. ARCHIVED banner (scoped to _attic/docs-2026-06/, .md only — A6) ------
echo "== ARCHIVED banners (_attic/docs-2026-06/) =="
if [ -d "_attic/docs-2026-06" ]; then
  find _attic/docs-2026-06 -name '*.md' | while IFS= read -r f; do
    if head -n 1 "$f" | grep -q '^ARCHIVED'; then
      echo "ok:   banner $f"
    else
      echo "FAIL: $f first line must start with 'ARCHIVED — do not load' (G3)"
    fi
  done > /tmp/banners-out.$$
  cat /tmp/banners-out.$$
  if grep -q '^FAIL:' /tmp/banners-out.$$; then FAIL=1; fi
  rm -f /tmp/banners-out.$$
fi

# --- 7. duplication tripwires (WARN only) ------------------------------------
echo "== duplication tripwires (WARN) =="
tripwire() {
  # $1 = literal, $2 = space-separated allowlist
  local literal="$1" allow="$2" hits f allowed a
  # Exclude worktree/scratch trees: .claude (git worktrees + charters), .omx and
  # .tmp-bp89 (nested-checkout scratch). Use the ANCHORED (^|/)\.claude/ form —
  # after `sed 's|^\./||'` a top-level hit reads '.claude/…' with NO leading
  # slash, so an unanchored '/\.claude/' would miss it and leave thousands of
  # worktree-copy WARNs (D26).
  # Three trees are pruned STRUCTURALLY, not allowlisted file-by-file, because
  # every file they will ever hold is exempt for the same reason — an allowlist
  # would need a new entry per file forever and would still be behind:
  #
  #   cloud/priv/templates/  A byte-identical machine copy of the already-
  #     allowlisted js/packages/create-barkpark-app/templates/<t>/, produced by
  #     `make cloud-templates-sync` and held identical by
  #     BarkparkCloud.Templates.AppFilesDriftTest. "Prefer a pointer" here would
  #     turn that drift test RED — the advice is not merely noise, it is wrong.
  #     `prune_find` (§2/§5) already prunes this tree; §7 walking it was the drift.
  #   tooling/grip/ledger/   A documented "shared append-only commons" (see
  #     tooling/grip/README.md) of dated, immutable evidence rows. A record must
  #     quote what it observed; rewriting one to a pointer falsifies it. Same
  #     class as docs/ops/studio-nav-bug-2026-04-19.md below ("path-frozen
  #     history") — and it grows every wave, so file-by-file never converges.
  #   .changeset/            Release-note fragments that `changeset version`
  #     consumes and DELETES. Not docs; they cannot own or point at anything.
  hits=$(grep -rlF "$literal" --include='*.md' "${GREP_PRUNE[@]}" . 2>/dev/null |
    sed 's|^\./||' | grep -v '^_attic/' | grep -v node_modules | grep -v '^\.artifacts/' \
    | grep -v '/_build/' | grep -v '/deps/' \
    | grep -vE '(^|/)\.claude/' | grep -vE '(^|/)\.omx/' | grep -vE '(^|/)\.tmp-bp89/' \
    | grep -v '^cloud/priv/templates/' | grep -v '^tooling/grip/ledger/' \
    | grep -vE '(^|/)\.changeset/' || true)
  for f in $hits; do
    allowed=0
    for a in $allow; do
      [ "$f" = "$a" ] && allowed=1
    done
    if [ "$allowed" -eq 0 ]; then
      warn "'$literal' appears in $f — canonical owner is elsewhere; prefer a pointer"
    fi
  done
  # Positive control on the ALLOWLIST itself. Every check above is an absence
  # proof: it prints nothing when it finds nothing, and a scan that has silently
  # stopped finding anything prints exactly the same nothing (the hazard §8
  # documents at length). The allowlist is the one thing here with a known
  # ground truth — each entry was added BECAUSE that file carries the literal —
  # so a stale entry is decidable: the file moved, was retired, or the literal
  # was edited out, and the entry now exempts nothing while quietly shrinking
  # what the tripwire covers. It also doubles as the rotation change-set: when
  # the prod IP or dev token changes, the allowlist IS the list of files to edit,
  # which is only true while every entry still resolves.
  # Skipped under a custom DOCS_ANCHORS_ROOT, following §8b: the allowlist names
  # REAL repo paths, so in a 4-file fixture every entry would read as stale and
  # bury the arm's own output in noise. Announced once below, never silent.
  if [ -z "${DOCS_ANCHORS_ROOT:-}" ]; then
    for a in $allow; do
      if [ ! -e "$a" ]; then
        warn "allowlist for '$literal' names $a, which does not exist — entry is stale"
      elif ! grep -qF "$literal" "$a" 2>/dev/null; then
        warn "allowlist for '$literal' names $a, which no longer contains it — entry is stale"
      fi
    done
  fi
}

# Allowlist rationale: copy-paste-ready examples beat pointers in user-facing
# setup guides and starter templates — those files legitimately repeat the dev
# token / signature shape. studio-nav-bug is path-frozen history. The tripwire
# still catches NEW files repeating these.
#
# Five entries were REMOVED when the stale-entry control above first ran: the
# IP had left docs/ops/bokbasen-go-live.md, deploy/systemd/README.md and
# README.md (whose exemption this comment used to justify), and the dev token
# had left CLAUDE.md and js/CLAUDE.md. Each was exempting nothing while
# silently narrowing what the tripwire covers; dropping them re-arms those
# files, so the literal reappearing there warns again.
#
# Entries below the original set, each verified against the code before adding —
# a WARN is only noise once you have checked that the claim behind it is true:
#   deploy/README.md            names the box in a parenthetical that ALREADY
#                               attributes it to CLAUDE.md ("the CLAUDE.md prod
#                               box …") — a pointer that happens to quote.
#   api/lib/barkpark/sync/HANDOFF.md   runnable `ssh root@<ip>` for an agent.
#   templates/DEPLOYING.md      runnable `--token-ssh root@<ip>`; the flag is
#                               real (scripts/bp-vercel-quick-setup.sh).
#   templates/place-directory/README.md   the starter-README class already
#                               exempted above; the dev token is real on the
#                               `mix setup` path it documents (BARKPARK_SEED_
#                               PROFILE defaults to demo, which mints it).
#   tooling/doc-onboarding/TRUTH-AUDIT.md   the literal IS the subject of its
#                               audit table — it cannot be replaced by a
#                               pointer without deleting the finding.
tripwire '89.167.28.206' \
  "docs/ops/PROD_OPS.md CLAUDE.md docs/ops/adding-a-domain.md docs/ops/vercel-dns-connect.md deploy/uptime-kuma/README.md docs/studio/user-guide.md docs/ops/studio-nav-bug-2026-04-19.md deploy/README.md api/lib/barkpark/sync/HANDOFF.md templates/DEPLOYING.md"
tripwire 'v1=<hex>' \
  "docs/contracts/webhook-realtime.md js/packages/create-barkpark-app/templates/blog-starter/README.md js/packages/create-barkpark-app/templates/website-starter/README.md"
tripwire 'barkpark-dev-token' \
  "docs/auth.md docs/api-v1.md api/CLAUDE.md docs/setup/SETUP.md docs/setup/WINDOWS.md docs/setup/TASK-SYSTEM.md docs/ops/branch-protection-and-overrides.md js/packages/create-barkpark-app/templates/blog-starter/README.md js/packages/create-barkpark-app/templates/website-starter/README.md templates/place-directory/README.md tooling/doc-onboarding/TRUTH-AUDIT.md"

if [ -n "${DOCS_ANCHORS_ROOT:-}" ]; then
  echo "ok:   allowlist staleness not applicable to a custom DOCS_ANCHORS_ROOT"
else
  echo "ok:   every tripwire allowlist entry still exists and still carries its literal"
fi

# --- 8. @canonical capability markers (code-side canonical pointers) ---------
# In-code `@canonical capability:<slug>` markers name the ONE canonical impl of a
# capability, cross-language — the complement of dedup: dedup makes one true impl
# exist, this makes a cold agent LAND on it (`grep '@canonical capability:'` IS
# the index — no new card, dodging the 7-card cap). Two invariants, the §5
# canonical-for discipline applied to CODE: (a) every capability:<slug> is UNIQUE
# repo-wide — a copy-paste that keeps the marker fails here, turning dedup into a
# tripwire; (b) each marker sits on a PUBLIC entry point (a public def / Go func /
# JS export within 6 lines below; never an Elixir private defp), so a rename out
# from under a marker turns CI red instead of rotting silently like a prose
# pointer. The .ex/.go/.exs/.ts trigger in doc-gates.yml is the keystone — without
# it this never re-runs on a code-only rename (the exact way prose pointers rot).
#
# WHY THIS SECTION CARRIES A POSITIVE CONTROL
# -------------------------------------------
# Both invariants are ABSENCE proofs: they print `ok:` when their scan comes back
# with nothing to complain about — and a scan that returns NOTHING AT ALL prints
# exactly the same `ok:`. §1 of this script already fails closed on that shape
# ("no routing-table targets found in CLAUDE.md — table missing or reformatted");
# §8 did not. The corpus is non-empty today, so this was not vacuous yet, but
# nothing here would have said when it became so.
#
# The control is NOT "assert the marker count is non-zero". CLAUDE.md is
# explicit that markers are demand-driven and "should be REMOVED once dedup
# eliminates its decoys" — an empty corpus is a legitimate future state, and a
# non-empty assertion would eventually red on a correct tree. The control is
# `--selftest` at the top of this file: it plants a duplicate slug, a marker over
# a private defp and a dangling doc: backlink in a throwaway repo, re-invokes
# THIS script against it via DOCS_ANCHORS_ROOT, and requires each to red with a
# named line; three further arms require it to stay silent on a well-formed
# marker, on vendored code and on an unscanned extension, and to report a
# corpus of zero as a legitimate PASS. With the scanner certified there, a
# report of zero markers here is a fact about the repo rather than a fact about
# the scanner — and §8 states the count out loud so the number is visible.

# TEST FILES ARE EXCLUDED, and that is a correctness rule, not a speed one. A
# test can only ever CONTAIN a marker as fixture data — `internal/scaffy/
# insertbefore_test.go` asserts the rendered output of the
# `scaffy/commands/add-canonical-marker.scaffy` command, so its `want := ...`
# raw string carried `capability:api-client-new` and `capability:zero-check`.
# Those are not implementations, yet under (a) they HELD both slugs repo-wide:
# marking the true owner — `internal/apiclient/client.go`'s `func New(cfg
# Config) *Client`, the very target the command's own EXAMPLES name — would have
# red as "a copy-paste that kept the marker". The guard was defending the
# squatter against the owner. A test is never a canonical implementation, so the
# index does not read one.
CANON_INCLUDES=(--include='*.ex' --include='*.exs' --include='*.go'
  --include='*.ts' --include='*.tsx' --include='*.mjs' --include='*.js'
  --exclude='*_test.go' --exclude='*_test.exs' --exclude='*_test.ts'
  --exclude='*.test.ts' --exclude='*.test.tsx' --exclude='*.test.mjs'
  --exclude='*.test.js' --exclude='*.spec.mjs' --exclude='*.spec.js')

# Every `@canonical capability:` hit under $1, as file:line:text. The ONE reader
# both invariants and the control go through, so a control that passes is a
# statement about the shipping code path.
#
# DECLARATION-POSITION ONLY. A bare-literal grep for the marker string matched
# anywhere it appeared, including inside a @moduledoc/docstring heredoc that
# merely QUOTES an existing slug to explain it in prose (PR #12710: a test
# moduledoc quoting `workspace-admin-authority` false-REDded as a duplicate, and
# the workaround was deleting the explanatory prose — the gate punished better
# documentation). Every real marker in this repo is a COMMENT whose content
# starts with `@canonical capability:` right after the `#` or `//` marker
# (Elixir/Go/bash use `#`; Go/TS/JS/mjs use `//`) — a docstring quote is prose
# on an uncommented line and never satisfies that shape. Anchoring on
# `^[[:space:]]*(#|//)[[:space:]]*@canonical capability:` keeps a real
# duplicate red while letting prose pass.
canon_hits() {
  grep -rnE '^[[:space:]]*(#|//)[[:space:]]*@canonical capability:' \
    "${CANON_INCLUDES[@]}" "${GREP_PRUNE[@]}" \
    "$1" 2>/dev/null | grep -vE '/_build/|/deps/|/\.claude/|/node_modules/' || true
}

# The verdicts for one root, one per line, for the CALLER to interpret:
#   DUP <slug>                     slug claimed by >1 impl
#   PRIVATE <file>:<line> <slug>   no public def/func/export within 6 lines below
#   DOCMISS <slug> <path>          doc: backlink points at a missing file
#   OK <file>:<line> <slug>        a conforming marker
# The gate turns findings into fail(); the control asserts they appear. Nothing
# in here touches $FAIL, which is what lets the same code run over a tree that
# is SUPPOSED to be dirty.
canon_scan() {
  local root="$1" hits cf rest cl slug dpath pubentry_pat
  hits="$(canon_hits "$root")"

  printf '%s\n' "$hits" | sed -E 's/.*capability:([A-Za-z0-9._-]+).*/\1/' \
    | grep . | sort | uniq -d | sed 's/^/DUP /' || true

  { printf '%s\n' "$hits" | grep . || true; } | while IFS= read -r hit; do
    cf=${hit%%:*}; rest=${hit#*:}; cl=${rest%%:*}
    slug=$(printf '%s' "$hit" | sed -E 's/.*capability:([A-Za-z0-9._-]+).*/\1/')
    # `export` is the public-entry keyword for a real ES MODULE (.mjs, .ts,
    # .tsx — every one of those is module-scoped, so anything not exported is
    # module-private). A plain `.js` script is not necessarily a module at
    # all — cloud/priv/static/app.js says so in its own header comment
    # ("vanilla SPA, no framework, no build step") and attaches its public
    # surface to an object literal far below the marker, not via `export`.
    # For that shape a bare top-level `function` declaration IS the public
    # entry (the widest visibility an IIFE-scoped script has), so `.js` alone
    # — never `.mjs` — also accepts it.
    case "$cf" in
      *.js) pubentry_pat='^[[:space:]]*(def |func |export |function )' ;;
      *)    pubentry_pat='^[[:space:]]*(def |func |export )' ;;
    esac
    if sed -n "$((cl + 1)),$((cl + 6))p" "$cf" 2>/dev/null | grep -qE "$pubentry_pat"; then
      echo "OK $cf:$cl $slug"
      # WHICH symbol the marker actually landed on — the 8b pin's payload.
      # "a public def within 6 lines" is an EXISTENCE test, and an inserted def
      # satisfies it while stealing the marker from the one below it. Recording
      # the NAME is what turns that into a comparison. `|| true` throughout: this
      # file runs under `set -euo pipefail`, and a grep that matches nothing must
      # yield an empty symbol, not kill the scan.
      # The modifier strip LOOPS (`:a` … `ta`). A single pass stopped after ONE
      # keyword, so `export async function resolveTenantForEvent(` reduced to the
      # literal token `function` — which is what the pin recorded for
      # connector-tenant-routing. A pairing whose symbol is a language keyword
      # pins nothing: the rename this section exists to catch still matches it,
      # and every `export async function` marker collapses onto the same token.
      # Looping walks the whole modifier run (`export default async function foo`
      # -> `foo`) and leaves every already-correct shape byte-identical.
      sym=$(sed -n "$((cl + 1)),$((cl + 6))p" "$cf" 2>/dev/null \
        | grep -m1 -E "$pubentry_pat" 2>/dev/null \
        | sed -E -e 's/^[[:space:]]*(def|func|export|function)[[:space:]]+//' \
                 -e ':a' -e 's/^(async|function|const|let|var|class|default)[[:space:]]+//' -e 'ta' \
                 -e 's/[^A-Za-z0-9_?!].*$//' || true)
      [ -n "$sym" ] && echo "PAIR $slug $sym"
    else
      echo "PRIVATE $cf:$cl $slug"
    fi
    dpath=$(printf '%s' "$hit" | sed -nE 's/.*doc:([A-Za-z0-9._/-]+\.md).*/\1/p')
    if [ -n "$dpath" ] && [ ! -e "$dpath" ]; then echo "DOCMISS $slug $dpath"; fi
  done
}

echo "== @canonical capability markers =="

CANON_OUT="$(canon_scan .)"
CANON_N=$(printf '%s\n' "$CANON_OUT" | grep -cE '^(OK|PRIVATE) ' || true)

{ printf '%s\n' "$CANON_OUT" | grep '^DUP ' || true; } | while IFS=' ' read -r _ d; do
  echo "FAIL: @canonical capability:$d claimed by >1 impl (a copy-paste that kept the marker?)"
done
if printf '%s\n' "$CANON_OUT" | grep -q '^DUP '; then FAIL=1; else echo "ok:   @canonical capability slugs unique"; fi

printf '%s\n' "$CANON_OUT" | grep '^OK ' | sed 's/^OK /ok:   /' | sed 's/ \([A-Za-z0-9._-]*\)$/ capability:\1/' || true
{ printf '%s\n' "$CANON_OUT" | grep '^PRIVATE ' || true; } | while IFS=' ' read -r _ loc slug; do
  echo "FAIL: @canonical capability:$slug at $loc has no public def/func/export within 6 lines below (mark a PUBLIC entry point, not a private helper)"
done
{ printf '%s\n' "$CANON_OUT" | grep '^DOCMISS ' || true; } | while IFS=' ' read -r _ slug dp; do
  echo "FAIL: @canonical capability:$slug doc: points at a missing doc: $dp"
done
if printf '%s\n' "$CANON_OUT" | grep -qE '^(PRIVATE|DOCMISS) '; then FAIL=1; fi

# Stated out loud, every run. Zero is a LEGITIMATE result — CLAUDE.md says
# markers are demand-driven and get removed as dedup lands — so this reports the
# count rather than asserting on it. 8a is what makes a zero here trustworthy.
echo "ok:   §8 scanned $CANON_N @canonical marker(s) in the repo corpus"

# --- 8b. marker→symbol PIN (task-51400f894d40abdf) ---------------------------
# §8 above asks "is there a public def within 6 lines below this marker?" — an
# EXISTENCE test, and existence is exactly what a thief satisfies. Define a new
# public function between a marker and the function it names, and the marker now
# certifies the WRONG implementation while §8 still prints ok: the slug is still
# unique, and there is still a public def below it. Same hole as the sobelow
# annotation reassignment fixed in api/scripts/sobelow-inline-overlap-check.sh,
# and it is the same fix: record the PAIRING and compare, because "the symbol the
# author meant" is not recoverable from the current tree.
#
# The pin is `slug<TAB>symbol`, sorted, NO line numbers — a marker that moves
# down a file must not churn the pin, only one that changes what it points AT.
# Regenerate deliberately with --regen-canonical-pin and READ THE DIFF: a changed
# symbol means the canonical pointer now names different code.
CANON_PAIRS=$(printf '%s\n' "$CANON_OUT" | grep '^PAIR ' | sed 's/^PAIR //' \
  | awk '{ print $1 "\t" $2 }' | LC_ALL=C sort || true)
CANON_PAIR_N=$(printf '%s' "$CANON_PAIRS" | grep -c . || true)

if [ -n "${DOCS_ANCHORS_ROOT:-}" ] && [ "$CANON_PIN_EXPLICIT" != "1" ]; then
  # A CUSTOM ROOT IS NOT THIS REPO. --selftest drives the real gate against
  # throwaway fixture repos via DOCS_ANCHORS_ROOT; one of them plants a marker
  # on purpose, so "zero pairings" does not cover this case and a missing pin
  # there reddened the fixture — and with it the whole gate. The pin is a
  # statement about the committed corpus; a harness that wants it asserted
  # supplies its own with CANON_PIN=.
  echo "ok:   §8b pin not applicable to a custom DOCS_ANCHORS_ROOT (set CANON_PIN= to assert one)"
elif [ "${REGEN_CANON_PIN:-0}" = "1" ]; then
  printf '%s\n' "$CANON_PAIRS" > "$CANON_PIN"
  echo "regenerated $CANON_PIN ($CANON_PAIR_N pairing(s)) — READ THE DIFF:"
  echo "      a changed symbol means the canonical pointer now names different code."
elif [ "$CANON_PAIR_N" -eq 0 ]; then
  # NOTHING TO COMPARE IS NOT A FAILURE HERE, and this arm cost a CI red to get
  # right. §8 states it directly: zero markers is a LEGITIMATE result, because
  # CLAUDE.md makes them demand-driven and says they are REMOVED once dedup kills
  # their decoys. It is also the state of every --selftest fixture root, which
  # carries four files and no markers at all — so a fail-closed branch here reds
  # all eight selftest cases and the gate with them. The pin protects a
  # NON-EMPTY corpus; on an empty one there is no pairing that could have moved.
  echo "ok:   §8b no marker pairings to compare (§8 scanned $CANON_N marker(s))"
elif [ ! -f "$CANON_PIN" ]; then
  echo "FAIL: §8b marker→symbol pin missing: $CANON_PIN (regenerate: REGEN_CANON_PIN=1 $0)"
  FAIL=1
elif ! printf '%s\n' "$CANON_PAIRS" | diff -u "$CANON_PIN" - >/dev/null 2>&1; then
  echo "FAIL: §8b a @canonical marker now names a DIFFERENT symbol than the pin records."
  echo "      < pinned (the impl the marker was written for)   > current"
  printf '%s\n' "$CANON_PAIRS" | diff -u "$CANON_PIN" - | tail -n +3 | sed 's/^/      /'
  echo "      A public def inserted between a marker and its function STEALS the"
  echo "      marker — slug uniqueness and the within-6-lines rule both still pass."
  echo "      Move the marker back onto its entry point. If the rename is intended:"
  echo "        REGEN_CANON_PIN=1 $0    # then READ THE DIFF"
  FAIL=1
else
  echo "ok:   §8b all $CANON_PAIR_N marker pairing(s) match the pin — none has migrated"
fi

# --- 8c. merge-gates.md -> elixir.yml anchors (delegated) --------------------
# WHY THIS SECTION EXISTS, and why it is a delegation rather than an inline arm.
#
# docs/ops/merge-gates.md is the card the routing table hands an agent who needs
# to verify a MERGE-AUTHORITY claim, and four of its pointers into
# .github/workflows/elixir.yml were bare line numbers. Insertions above them slid
# every one by 80-95 lines: :510 landed on a golden-parity step, :667 on a
# `MIX_ENV: prod` line, :655 on a libvips install. Every SENTENCE stayed true;
# every POINTER stopped resolving, so a reader sent to confirm "no needs:
# mix-test edge" read unrelated YAML instead. NOTHING IN CI READ THEM: §3/§3b
# of this file validate PATH and SYMBOL anchors and have no line-number arm, so
# the whole class was invisible here by construction. The pins are now job keys
# and quoted comment text (#14842); this is what stops them rotting back.
#
# THE TRIGGER IS ALREADY CORRECT, which is the whole reason the check is mounted
# HERE rather than in a workflow of its own: doc-gates.yml runs this script and
# fires on `**/*.md` AND `.github/workflows/**` -- exactly the pair this guard
# needs, since either side of the anchor can move. A new workflow would have had
# to re-derive that trigger pair and be kept in sync with it forever.
#
# WHAT THIS BUYS, said honestly: doc-gates.yml's `Doc budgets + anchors` job is
# NOT in the required set (its own header says its red does not stop a merge,
# and .github/required-checks.json carries an S4 exclusion row). So this is a
# real trigger on the right path pair -- wired and triggering, NOT merge
# authority. Do not upgrade that wording without upgrading the job.
#
# DELEGATED, NOT INLINED. scripts/merge-gates-elixir-anchor-check.sh owns its
# ANCHORS table, its non-vacuity row count and a 5-arm --selftest (a rename REDS;
# a 40-line insertion above every job stays GREEN -- that pair is the argument
# for anchors over line pins, and it is not restatable in three lines here).
# Inlining it would copy the table into a second owner, which is the failure
# §5 of this very file exists to prevent.
MG_ANCHOR_GUARD="$REPO_ROOT/scripts/merge-gates-elixir-anchor-check.sh"
if [ -n "${DOCS_ANCHORS_ROOT:-}" ]; then
  # A CUSTOM ROOT IS NOT THIS REPO -- same reasoning as §8b. --selftest drives
  # this gate against throwaway fixture trees carrying neither
  # docs/ops/merge-gates.md nor .github/workflows/elixir.yml, and the delegated
  # guard resolves both paths from ITS OWN location (the real checkout), so
  # running it under a fixture root would judge the real repo while claiming to
  # judge the fixture -- a pass or a fail that means nothing either way. This is
  # also why §8c adds no st_case arm: the harness cannot reach it. Its coverage
  # is the guard's own --selftest, run as a step beside this one.
  echo "ok:   §8c merge-gates anchor check not applicable to a custom DOCS_ANCHORS_ROOT"
elif [ ! -f "$MG_ANCHOR_GUARD" ]; then
  # FAIL-CLOSED ON ABSENCE. A deleted guard must RED here rather than skip:
  # otherwise "the file is gone" and "the anchors are fine" print the same
  # `ok:`, which is the vacuous-green shape §8's positive control exists to kill.
  echo "FAIL: §8c scripts/merge-gates-elixir-anchor-check.sh is missing."
  echo "      merge-gates.md's elixir.yml anchors are then unguarded and will rot"
  echo "      back to line pins. Restore it, or remove this section deliberately."
  FAIL=1
else
  MG_OUT="$(mktemp)"
  if bash "$MG_ANCHOR_GUARD" >"$MG_OUT" 2>&1; then
    MG_OK=$(grep -c '^ok:' "$MG_OUT" || true)
    echo "ok:   §8c ${MG_OK:-0} merge-gates.md -> elixir.yml anchor check(s) resolve"
  else
    echo "FAIL: §8c docs/ops/merge-gates.md's pointers into elixir.yml no longer resolve:"
    sed 's/^/      /' "$MG_OUT"
    FAIL=1
  fi
  rm -f "$MG_OUT"
fi

# --- 12. a `cold` doc that still carries RUNNABLE COMMANDS must say so --------
# (task-fed001f6174e5c4c)
#
# CLAUDE.md tiers `cold` as finished work an agent must not LOAD to learn how the
# repo works. It never meant "unreachable": `git grep` does not read tier headers,
# and a recipe is found by grepping for the command in it. So the one thing a
# cold doc must not be is a page of copyable commands with nothing on it saying
# when they ran. tooling/grip/ledger/pds-w27-bare30-content-recheck-2026-07-31
# was exactly that — a census recipe whose `cd /tmp` was still being copied
# months after the tier said nobody reads the file (defused in #13772).
#
# THE RULE, and why it is a banner rather than a deletion. §7 above already
# records the answer for the biggest cohort: tooling/grip/ledger/ is a
# "shared append-only commons … of dated, immutable evidence rows", and "a record
# must quote what it observed". Those records are CONSULTED — that is their whole
# job — so `cold` is right about "do not load this to learn the system" and wrong
# about "nobody reads it". The banner reconciles the two: the doc stays, the
# commands stay re-runnable (grip's ledger is an index of HOW TO VERIFY), and the
# reader is told the OUTPUT is pinned to a date and is not current.
#
# WHY BARE FENCES COUNT. Keying only on ```bash would have covered 16 of the 47
# command-carrying cold docs in this repo at the time of writing; the other 31
# hold their commands in an untagged ``` fence — including
# `bp task close <id> <worker> <epoch>`, a PROD WRITE. A tripwire that sees a
# third of its class is not a tripwire, so an untagged fence whose body opens a
# line with an executing verb counts too. The verb list is deliberately narrow:
# a false positive costs one banner line, a false negative is the defect above.
CMD_VERBS='git|gh|bp|curl|mix|cd|ssh|make|npm|npx|node|python3?|psql|bash|sh|jq|for|while|grep|awk|sed|find|rm|mkdir|export|sudo|systemctl|docker|go|cargo|pnpm|yarn'
COLD_N=0
COLD_BAD=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # Tier lives on line 1 by contract ("First line of every active doc").
  head -1 "$f" 2>/dev/null | grep -q 'doc-tier: *cold' || continue
  awk -v verbs="$CMD_VERBS" '
    BEGIN { inf = 0; runnable = 0 }
    /^[[:space:]]*```/ {
      if (inf == 0) {
        lang = $0; sub(/^[[:space:]]*```/, "", lang); gsub(/[[:space:]]/, "", lang)
        inf = 1; cur = lang; body = ""
      } else {
        inf = 0
        if (cur ~ /^(bash|sh|shell|zsh|console)$/) runnable = 1
        else if (cur == "" && body ~ ("(^|\n)[ \t]*(" verbs ")[ \t]")) runnable = 1
      }
      next
    }
    { if (inf == 1) body = body "\n" $0 }
    END { exit (runnable ? 0 : 1) }
  ' "$f" || continue
  COLD_N=$((COLD_N + 1))
  # The banner must be near the top — a reader who opens the file sees it before
  # the first fence. Ten lines covers "marker, blank, H1, blank, banner" with room.
  if ! head -10 "$f" | grep -q '^> HISTORICAL RECORD ('; then
    COLD_BAD="$COLD_BAD $f"
  fi
done <<COLDEOF
$(prune_find -name '*.md' -type f -print | sed 's|^\./||' | grep -v '^_attic/' | LC_ALL=C sort)
COLDEOF

for f in $COLD_BAD; do
  echo "FAIL: $f is doc-tier: cold and carries runnable commands, but has no '> HISTORICAL RECORD (<date>)' banner in its first 10 lines."
  echo "      A cold doc is not unreachable — git grep finds recipes by their commands, not by their tier."
  echo "      Add, directly under the title: > HISTORICAL RECORD (YYYY-MM-DD) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current."
  FAIL=1
done
# Stated out loud every run, like §8: this section is otherwise an absence proof,
# and a detector that has gone blind prints the same nothing as a clean tree. The
# count is the non-vacuity signal — if it collapses toward zero while the ledger
# keeps growing, the fence walker broke, not the corpus.
echo "ok:   §12 scanned $COLD_N cold doc(s) carrying runnable commands; $(printf '%s' "$COLD_BAD" | wc -w | tr -d ' ') missing the HISTORICAL RECORD banner"

# --- summary ------------------------------------------------------------------
echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "docs-anchors-check: FAILED"
  exit 1
fi
echo "docs-anchors-check: PASS (${WARN} warning(s))"
