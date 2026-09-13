#!/usr/bin/env bash
#
# boundary-marker-check.sh — the @boundary capability marker registry (D41).
#
# D41: "a coverage boundary must be MACHINE-CHECKED; a comment is not a
# tripwire." The hardening epic kept finding safety claims that survived as
# accurate-sounding prose after the test that enforced them was renamed, moved
# or deleted. A boundary comment is the highest-value prose in the tree and the
# least checked: nothing in CI read one before this file existed.
#
# THE MARKER
#
#     # @boundary capability:<slug> [doc:<path>.md] test:<relpath>#<test name>
#
#   `//` comments work too (Go / TS / JS / mjs). `test:` is ALWAYS LAST and its
#   name runs to end-of-line, because real test names carry spaces, commas and
#   parentheses; an optional `doc:` backlink therefore sits BEFORE it.
#
# TWO INVARIANTS, the §8 @canonical discipline applied to boundary prose:
#   (a) every capability:<slug> is UNIQUE repo-wide — two boundaries cannot
#       claim the same name, so `grep -rn '@boundary capability:'` IS the index;
#   (b) the `test:` pointer RESOLVES — the file exists AND the named test is
#       actually declared in it, matched by the declaration shape of that file's
#       language (see bnd_name_found below), never by a bare substring.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT — read this before citing the gate.
#
#   PROVES:     the PAIRING EXISTS. A boundary comment names a test; that test
#               file is on disk; that test name is declared inside it. A rename,
#               a move or a deletion of the enforcing test turns CI red on the
#               PR that does it, instead of leaving the prose behind as a claim
#               nothing backs.
#
#   DOES NOT PROVE: that the named test would FAIL if the boundary were
#               violated. A static grep cannot observe mutation-kill. A test that
#               asserts nothing, is skipped, or has gone vacuous satisfies this
#               gate completely. NECESSARY, NEVER SUFFICIENT. The kill burden
#               stays with authoring discipline (the worked example is PR #5434:
#               a stale boundary comment fixed AND a companion mutation-proven
#               census pin, in ONE commit). Do not cite a green here as evidence
#               that vacuous-green risk is closed for a boundary — it is not,
#               and this gate makes no such claim.
#
# DEMAND-DRIVEN, exactly like @canonical: markers are added where a boundary has
# already earned a mutation-proven test, never swept across the corpus. There is
# no assertion that the marker count is non-zero, and there must never be one —
# zero markers is a legitimate tree state, and --selftest below is what makes a
# report of zero a fact about the repo rather than a fact about this scanner.
#
# EXIT: 0 pass · 1 a marker is unpaired/duplicated/dangling · 2 bad usage.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${BOUNDARY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

usage() {
  echo "usage: boundary-marker-check.sh [--selftest|--help]"
  echo "  (no args)   scan the repo for @boundary markers (exit 0 pass / 1 fail)"
  echo "  --selftest  run the hermetic fixture suite (exit 0 pass / 1 fail)"
  echo "  BOUNDARY_ROOT=<dir> overrides the tree that is scanned"
}

MODE=run
if [ "$#" -gt 0 ]; then
  case "$1" in
    --selftest) MODE=selftest ;;
    -h|--help) usage; exit 0 ;;
    *) echo "boundary-marker-check: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi
if [ "$#" -gt 1 ]; then
  echo "boundary-marker-check: unexpected extra argument: $2" >&2; usage >&2; exit 2
fi

# The SAME scan surface as docs-anchors-check.sh §8's CANON_INCLUDES, including
# the .mjs/.js arms that §8 gained after a marker in a .mjs file sailed through
# a scan blind to JavaScript. This epic's boundaries concentrate in
# cloud/priv/static/*.mjs, so a copy of §8 that dropped those two includes would
# be blind to the exact surface it was written for. Test files are excluded for
# §8's reason: a test can only ever CONTAIN a marker as fixture data, and a
# fixture must never hold a slug against the real owner.
BND_INCLUDES=(--include='*.ex' --include='*.exs' --include='*.go'
  --include='*.ts' --include='*.tsx' --include='*.mjs' --include='*.js'
  --exclude='*_test.go' --exclude='*_test.exs' --exclude='*_test.ts'
  --exclude='*.test.ts' --exclude='*.test.tsx' --exclude='*.test.mjs'
  --exclude='*.test.js' --exclude='*.spec.mjs' --exclude='*.spec.js')

# DECLARATION POSITION ONLY, same anchor as §8's canon_hits and for the same
# reason (PR #12710): a docstring that QUOTES a slug to explain it is prose on
# an uncommented line, and must not be counted as a second claim on that slug.
bnd_hits() {
  grep -rnE '^[[:space:]]*(#|//)[[:space:]]*@boundary capability:' \
    "${BND_INCLUDES[@]}" \
    "$1" 2>/dev/null | grep -vE '/_build/|/deps/|/\.claude/|/node_modules/|/_attic/' || true
}

# Is <name> DECLARED as a test in <file>? Matched by the declaration shape of
# the file's language, with grep -F on the quoted literal — a test name is full
# of regex metacharacters (`.`, `(`, `?`, `[`), so an ERE here would both
# false-match and false-miss. Stated per language so the grep shape is auditable:
#
#   .ex/.exs   ExUnit          test "<name>"        or  describe "<name>"
#   .mjs/.js/  node:test /     test("<name>"  it("<name>"  describe("<name>"
#   .ts/.tsx   vitest/jest     …and the single-quoted form of each
#   .go        go test         func <name>(   — <name> IS the Test… identifier
#   .sh        st_case harness "<name>"
#
# Any other extension is a REFUSAL (exit 2 from this function), not a pass: a
# marker that points into a file this reader cannot parse must not be able to
# claim coverage by being unreadable.
bnd_name_found() {
  local f="$1" n="$2"
  case "$f" in
    *.ex|*.exs)
      grep -cF "test \"$n\"" "$f" >/dev/null && return 0
      grep -cF "describe \"$n\"" "$f" >/dev/null && return 0
      return 1 ;;
    *.mjs|*.js|*.ts|*.tsx)
      grep -cF "test(\"$n\"" "$f" >/dev/null && return 0
      grep -cF "it(\"$n\"" "$f" >/dev/null && return 0
      grep -cF "describe(\"$n\"" "$f" >/dev/null && return 0
      grep -cF "test('$n'" "$f" >/dev/null && return 0
      grep -cF "it('$n'" "$f" >/dev/null && return 0
      grep -cF "describe('$n'" "$f" >/dev/null && return 0
      return 1 ;;
    *.go)
      grep -cE "^func +${n}\(" "$f" >/dev/null && return 0
      return 1 ;;
    *.sh)
      grep -cF "\"$n\"" "$f" >/dev/null && return 0
      return 1 ;;
    *) return 2 ;;
  esac
}

# One verdict per line for the CALLER to interpret. Nothing in here sets a
# failure flag, which is what lets the same code run over a tree that is
# SUPPOSED to be dirty (the --selftest fixtures).
#
#   DUP <slug>                         slug claimed by >1 boundary
#   NOTEST <file>:<line> <slug>        marker carries no test: clause at all
#   FILEMISS <slug> <path>             test file does not exist
#   BADEXT <slug> <path>               this reader cannot parse that language
#   NAMEMISS <slug> <path> <name>      file exists, the named test is not in it
#   DOCMISS <slug> <path>              doc: backlink points at a missing file
#   OK <file>:<line> <slug>            a conforming boundary marker
bnd_scan() {
  local root="$1" hits cf rest cl slug dpath spec tpath tname rc
  hits="$(bnd_hits "$root")"

  printf '%s\n' "$hits" | sed -E 's/.*@boundary capability:([A-Za-z0-9._-]+).*/\1/' \
    | grep . | sort | uniq -d | sed 's/^/DUP /' || true

  { printf '%s\n' "$hits" | grep . || true; } | while IFS= read -r hit; do
    cf=${hit%%:*}; rest=${hit#*:}; cl=${rest%%:*}
    slug=$(printf '%s' "$hit" | sed -E 's/.*@boundary capability:([A-Za-z0-9._-]+).*/\1/')

    dpath=$(printf '%s' "$hit" | sed -nE 's/.*[[:space:]]doc:([A-Za-z0-9._/-]+\.md).*/\1/p')
    if [ -n "$dpath" ] && [ ! -e "$root/$dpath" ] && [ ! -e "$dpath" ]; then
      echo "DOCMISS $slug $dpath"
    fi

    # `test:` is last and its value runs to EOL — the name carries spaces.
    spec=$(printf '%s' "$hit" | sed -nE 's/.*[[:space:]]test:(.*)$/\1/p')
    if [ -z "$spec" ]; then
      echo "NOTEST $cf:$cl $slug"
      continue
    fi
    tpath=${spec%%#*}
    tname=${spec#*#}
    if [ "$tpath" = "$spec" ] || [ -z "$tname" ]; then
      echo "NOTEST $cf:$cl $slug"
      continue
    fi
    if [ ! -f "$root/$tpath" ]; then
      echo "FILEMISS $slug $tpath"
      continue
    fi
    # rc captured BEFORE any pipe or test, so `set -e` cannot swallow a 2.
    set +e
    bnd_name_found "$root/$tpath" "$tname"
    rc=$?
    set -e
    case "$rc" in
      0) echo "OK $cf:$cl $slug" ;;
      2) echo "BADEXT $slug $tpath" ;;
      *) echo "NAMEMISS $slug $tpath $tname" ;;
    esac
  done
}

if [ "$MODE" = selftest ]; then
  echo "== boundary-marker-check --selftest =="
  ST_FAIL=0

  st_fixture() {
    local r="$1"
    mkdir -p "$r/lib" "$r/test" "$r/docs"
    cat > "$r/lib/impl.ex" <<'FIXEOF'
defmodule Fixture.Impl do
  # COVERAGE BOUNDARY: this fences exactly one thing.
  # @boundary capability:fixture-fence test:test/fence_test.exs#the fence holds, in order
  def guarded, do: :ok
end
FIXEOF
    cat > "$r/test/fence_test.exs" <<'FIXEOF'
defmodule Fixture.FenceTest do
  use ExUnit.Case
  test "the fence holds, in order" do
    assert true
  end
end
FIXEOF
  }

  st_case() {
    # $1 name, $2 expected exit, $3 substring the output must carry,
    # $4 shell snippet mutating the fixture at $FIX
    local name="$1" want="$2" needle="$3" mutate="$4" out rc fix
    fix="$(mktemp -d)"
    st_fixture "$fix"
    # shellcheck disable=SC2034  # $FIX is consumed by the eval'd mutation snippet
    FIX="$fix"; eval "$mutate"
    set +e
    out=$(BOUNDARY_ROOT="$fix" bash "$SELF" 2>&1); rc=$?
    set -e
    rm -rf "$fix"
    if [ "$rc" != "$want" ]; then
      echo "SELFTEST FAIL: $name — expected exit $want, got $rc"
      printf '%s\n' "$out" | sed 's/^/    | /'
      ST_FAIL=1
      return
    fi
    if ! printf '%s\n' "$out" | grep -cF "$needle" >/dev/null; then
      echo "SELFTEST FAIL: $name — exit $rc as expected but output lacks: $needle"
      printf '%s\n' "$out" | sed 's/^/    | /'
      ST_FAIL=1
      return
    fi
    echo "ok:   selftest $name (exit $rc)"
  }

  # --- the two invariants RED on their own planted violation ----------------
  st_case "a marker whose test FILE is gone reds" 1 "names a test file that does not exist: test/fence_test.exs" '
    rm "$FIX/test/fence_test.exs"'

  st_case "a marker whose test NAME is gone reds (the rename case)" 1 "does not declare a test named" '
    sed "s/the fence holds, in order/the fence holds/" "$FIX/test/fence_test.exs" > "$FIX/t.tmp" \
      && mv "$FIX/t.tmp" "$FIX/test/fence_test.exs"'

  st_case "a duplicate boundary slug reds" 1 "claimed by >1 boundary" '
    printf -- "# @boundary capability:fixture-fence test:test/fence_test.exs#the fence holds, in order\ndef other, do: :ok\n" >> "$FIX/lib/impl.ex"'

  st_case "a marker with no test: clause reds" 1 "carries no test: pointer" '
    printf -- "# @boundary capability:fixture-bare\ndef bare, do: :ok\n" >> "$FIX/lib/impl.ex"'

  st_case "a marker whose test: clause has no #name reds" 1 "carries no test: pointer" '
    printf -- "# @boundary capability:fixture-nohash test:test/fence_test.exs\ndef nohash, do: :ok\n" >> "$FIX/lib/impl.ex"'

  st_case "a marker pointing into a language this reader cannot parse reds" 1 "cannot parse" '
    printf -- "readme\n" > "$FIX/test/notes.rb"
    printf -- "# @boundary capability:fixture-rb test:test/notes.rb#whatever\ndef rb, do: :ok\n" >> "$FIX/lib/impl.ex"'

  st_case "a dead doc: backlink reds" 1 "doc: points at a missing doc" '
    printf -- "# @boundary capability:fixture-doc doc:docs/nope.md test:test/fence_test.exs#the fence holds, in order\ndef d, do: :ok\n" >> "$FIX/lib/impl.ex"
    sed "/fixture-fence/d" "$FIX/lib/impl.ex" > "$FIX/i.tmp" && mv "$FIX/i.tmp" "$FIX/lib/impl.ex"'

  # --- SILENT ARMS: it must bite ONLY where it should -----------------------
  # Each asserts the COUNT, so a scanner that has gone blind cannot pass them.
  st_case "the clean fixture passes and the marker is COUNTED" 0 "scanned 1 @boundary marker(s)" ':'

  st_case "a corpus of ZERO markers is a legitimate pass, reported not asserted" 0 "scanned 0 @boundary marker(s)" '
    sed "/@boundary/d" "$FIX/lib/impl.ex" > "$FIX/i.tmp" && mv "$FIX/i.tmp" "$FIX/lib/impl.ex"'

  # THE .mjs ARM. §8 was blind to JavaScript until a defect proved it; this
  # copy would inherit that blindness silently, so the .mjs surface — where
  # this epic's boundaries actually live — gets its own RED and its own GREEN.
  st_case ".mjs marker resolving to a node test passes, and is counted" 0 "scanned 2 @boundary marker(s)" '
    printf -- "// @boundary capability:fixture-mjs test:test/x.test.mjs#E2 only sees literals\nexport function e2() {}\n" > "$FIX/lib/x.mjs"
    printf -- "test(\"E2 only sees literals\", () => {});\n" > "$FIX/test/x.test.mjs"'
  st_case ".mjs marker whose node test was renamed reds" 1 "does not declare a test named" '
    printf -- "// @boundary capability:fixture-mjs test:test/x.test.mjs#E2 only sees literals\nexport function e2() {}\n" > "$FIX/lib/x.mjs"
    printf -- "test(\"E2 sees literals\", () => {});\n" > "$FIX/test/x.test.mjs"'
  st_case ".mjs single-quoted test name resolves too" 0 "scanned 2 @boundary marker(s)" '
    printf -- "// @boundary capability:fixture-mjs test:test/x.test.mjs#E2 only sees literals\nexport function e2() {}\n" > "$FIX/lib/x.mjs"
    printf -- "it('"'"'E2 only sees literals'"'"', () => {});\n" > "$FIX/test/x.test.mjs"'

  st_case "a Go marker resolves via its func Test identifier" 0 "scanned 2 @boundary marker(s)" '
    printf -- "// @boundary capability:fixture-go test:test/x_test.go#TestFence\nfunc Fence() {}\n" > "$FIX/lib/x.go"
    printf -- "func TestFence(t *testing.T) {}\n" > "$FIX/test/x_test.go"'

  st_case "a marker under node_modules/ is not scanned" 0 "scanned 1 @boundary marker(s)" '
    mkdir -p "$FIX/node_modules/vendor"
    printf -- "// @boundary capability:fixture-vendored test:nowhere/gone.exs#nope\nexport function v() {}\n" > "$FIX/node_modules/vendor/dep.mjs"'

  st_case "a marker in a test file is fixture data, not a claim" 0 "scanned 1 @boundary marker(s)" '
    printf -- "# @boundary capability:fixture-in-test test:nowhere/gone.exs#nope\n" > "$FIX/test/other_test.exs"'

  # DECLARATION POSITION (the §8 PR #12710 defect, inherited by construction):
  # prose QUOTING an existing slug must not false-RED as a duplicate.
  st_case "a docstring quoting a slug does not false-RED as a duplicate" 0 "scanned 1 @boundary marker(s)" '
    printf -- "%s\n" "defmodule Fixture.Quote do" "  @moduledoc \"\"\"" \
      "  See @boundary capability:fixture-fence for why this is fenced." "  \"\"\"" "end" > "$FIX/lib/quote.ex"'

  echo ""
  if [ "$ST_FAIL" -ne 0 ]; then
    echo "boundary-marker-check --selftest: FAILED"
    exit 1
  fi
  echo "boundary-marker-check --selftest: PASS"
  exit 0
fi

# --- the scan over the real tree ---------------------------------------------
FAIL=0
BND_OUT="$(bnd_scan "$ROOT")"
BND_N=$(printf '%s\n' "$BND_OUT" | grep -cE '^(OK|NOTEST|FILEMISS|BADEXT|NAMEMISS) ' || true)

{ printf '%s\n' "$BND_OUT" | grep '^DUP ' || true; } | while IFS=' ' read -r _ d; do
  echo "FAIL: @boundary capability:$d claimed by >1 boundary (a copy-paste that kept the marker?)"
done
if printf '%s\n' "$BND_OUT" | grep -c '^DUP ' >/dev/null; then FAIL=1; else echo "ok:   @boundary capability slugs unique"; fi

{ printf '%s\n' "$BND_OUT" | grep '^NOTEST ' || true; } | while IFS=' ' read -r _ loc slug; do
  echo "FAIL: @boundary capability:$slug at $loc carries no test: pointer of the form test:<relpath>#<test name> (a boundary without an executable owner is the prose D41 forbids)"
done
{ printf '%s\n' "$BND_OUT" | grep '^FILEMISS ' || true; } | while IFS=' ' read -r _ slug p; do
  echo "FAIL: @boundary capability:$slug names a test file that does not exist: $p"
done
{ printf '%s\n' "$BND_OUT" | grep '^BADEXT ' || true; } | while IFS=' ' read -r _ slug p; do
  echo "FAIL: @boundary capability:$slug points at $p, whose language this reader cannot parse (supported: .ex .exs .mjs .js .ts .tsx .go .sh)"
done
{ printf '%s\n' "$BND_OUT" | grep '^NAMEMISS ' || true; } | while IFS=' ' read -r _ slug p n; do
  echo "FAIL: @boundary capability:$slug points at $p, which does not declare a test named: $n"
  echo "      The enforcing test was renamed, moved or deleted and the boundary comment stayed behind as a claim nothing backs. Repoint the marker, or restore the test."
done
{ printf '%s\n' "$BND_OUT" | grep '^DOCMISS ' || true; } | while IFS=' ' read -r _ slug dp; do
  echo "FAIL: @boundary capability:$slug doc: points at a missing doc: $dp"
done
if printf '%s\n' "$BND_OUT" | grep -cE '^(NOTEST|FILEMISS|BADEXT|NAMEMISS|DOCMISS) ' >/dev/null; then FAIL=1; fi

printf '%s\n' "$BND_OUT" | grep '^OK ' | sed 's/^OK /ok:   /' \
  | sed "s|$ROOT/||" | sed 's/ \([A-Za-z0-9._-]*\)$/ capability:\1/' || true

# Stated out loud every run. Zero is a LEGITIMATE result (markers are
# demand-driven), so this REPORTS the count instead of asserting on it —
# --selftest above is what makes a zero here trustworthy.
echo "ok:   scanned $BND_N @boundary marker(s) in the repo corpus"
echo "      (static pairing only: this proves the named test EXISTS, never that it would FAIL if the boundary broke)"

if [ "$FAIL" -ne 0 ]; then
  echo "boundary-marker-check: FAILED"
  exit 1
fi
echo "boundary-marker-check: PASS"
