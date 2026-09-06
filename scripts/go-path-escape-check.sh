#!/usr/bin/env bash
#
# go-path-escape-check.sh — the Go suite's cross-tree read ratchet.
#
# WHY THIS EXISTS
# ---------------
# .github/workflows/go-tests.yml dispatches its Go job off ONE declaration:
# `on.push.paths`, which the `changes` job parses out of the file and matches
# against the PR's changed files. That shape is only honest while the declared
# path set is a SUPERSET of everything the Go suite actually READS. A read that
# escapes the set means a PR editing that file dispatches NO Go job — and the
# `Go gate` aggregator then reports green, because a skip is an allowed result.
#
# Measured 2026-09-06 (task-bb930319aeac0266): the Go suite reads seven paths
# under `api/` and three under `cloud/lib/`, and the declared list carried NOT
# ONE of them. Two main-reds in one day came through that hole:
#   #16366 (9eb1aac5e) -> fixed by #16416   manifest `paginated` flag
#   #16474 (80770b8ae) -> fixed by #16498   two new API error codes
# Both producing PRs were api/-only diffs, both reported `go-tests: success` by
# SKIPPING, and main went red on the next push run. A gate that declined to
# measure reported passing.
#
# So: this script re-derives the read census from the WORKING TREE on every run
# and FAILS when a resolved repo-root read is not covered by the declared set.
# Adding a new cross-tree read without widening the trigger is a red, not a
# silent hole.
#
# ONE DECLARATION, NOT TWO. Unlike scripts/cloud-path-escape-check.sh — which
# OWNS its set and hands it to cloud.yml — the Go path set already lives in
# go-tests.yml `on.push.paths` and is already parsed from there by the
# dispatcher. Copying it here would create a second source of truth that can
# drift from the first in silence. This script parses the SAME key with the SAME
# grammar, so the ratchet and the dispatcher can never disagree about what is
# declared.
#
# HOW A READ IS RESOLVED
# ----------------------
# Sources: every `internal/**/*_test.go` in the working tree (`find`, never
# `git ls-files` — an untracked test on disk is code `go test` will run, so it
# is code this ratchet must see; honest-gates D31).
#
# THREE authoring forms, ONE resolver. All three are LIVE in this tree, and a
# ratchet that reads only the first is evadable by authoring style alone:
#
#   1. `"../../docs/setup/CODEX.md"`            — the plain relative literal.
#      Resolved against the READING FILE'S OWN DIRECTORY, which is what `go
#      test` sets the cwd to (per-package, always).
#
#   2. `filepath.Join("..", "..", "api", "test", "fixtures", "claude_chat")`
#      — the SEGMENT-LIST form. The two forms above resolve to the identical
#      path and a `"\.\./"` grep sees only the first. Recognised as a run of
#      comma-adjacent string literals containing a bare `".."`, joined with `/`
#      and resolved against the reading file's directory.
#
#   3. `filepath.Join(dir, "api", "lib", "barkpark", "content", "errors.ex")`
#      — the WALK-UP form (internal/cli/errors_api_parity_test.go), where `dir`
#      climbs from the cwd until the candidate stats. The literal run carries NO
#      `..` at all, so arms 1 and 2 are both blind to it — and this is the exact
#      shape that read `api/lib/barkpark/content/errors.ex`, the file whose edit
#      reddened main via #16474. Recognised as a run of THREE OR MORE
#      comma-adjacent literals with no `..`, resolved against the REPO ROOT.
#      Three, not two: a two-literal floor turns ordinary test tables
#      (`[]string{"api", "studio"}`) into census rows, and measured on this tree
#      the >=3 floor yields eight rows of which seven are real reads.
#
# NOT RECOGNISED, named rather than left to be found:
#   * A path assembled by concatenation — `root + "/api/lib"`
#     (internal/cli/errors_ambiguous_split_test.go's `grepAPILib`, which walks
#     the WHOLE of api/lib looking for retired error-code literals). Closing
#     that form needs an expression evaluator, not a scanner, and the honest
#     declaration for it would be `api/lib/**` — measured on origin/main,
#     1292 of the last 4955 commits (26%) touch `api/lib`, which is the
#     `api/**` wholesale blast the CI diet exists to prevent. The residue is
#     therefore a KNOWN hole with a named shape: a NEW api/lib file that emits a
#     retired error code reds late, on the next Go-dispatching PR, rather than
#     on its own. The two files that arm actually pins — errors.ex, and
#     known_codes/0 through it — ARE declared, via arm 3.
#   * Reads from non-test `internal/**/*.go`. The suite's fixtures are read from
#     test files; a product file reading a repo path at RUNTIME (e.g.
#     internal/cli/setup/local.go joining `<root>/api`) is behaviour, not a
#     test dependency, and censusing it would declare paths no test reads.
#
# EXISTENCE IS THE FILTER. A literal resolving to nothing on disk is a traversal
# fixture (`"../../../etc/passwd"`), a 404 probe or a table entry — not a
# dependency. That is also why the enumeration walks the working tree.
#
# Two structural exclusions, both category rules rather than per-path waivers
# (this ratchet has NO allowlist, by design — the honest fix for a new read is
# to declare it in go-tests.yml, never to exempt it here):
#   * anything resolving inside `internal/` — already covered by `**/*.go` and
#     the testdata carve-outs, and not a cross-tree read by definition;
#   * anything under `.git/` — VCS metadata materialised by tests that init
#     throwaway repos (internal/cli/sites_tarball_test.go). It is not a source
#     path, cannot appear in a GitHub changed-file list, and therefore cannot be
#     dispatched on by anyone.
#
# USAGE
#   go-path-escape-check.sh                  # the ratchet (CI + the local gate)
#   go-path-escape-check.sh --list-reads     # print the resolved census
#   go-path-escape-check.sh --print-set      # print the declared globs
#   go-path-escape-check.sh --match          # changed paths on stdin -> true|false
#   go-path-escape-check.sh --selftest       # prove the scanner is not neutered
#
# Env, for proof runs only (neither can weaken a real run):
#   GO_PATH_ESCAPE_ROOT      retarget the tree that is scanned
#   GO_PATH_ESCAPE_WORKFLOW  read the declared set from another go-tests.yml —
#                            this is how the RED-on-the-pre-fix-tree proof is
#                            produced: same scanner, origin/main's declaration.

set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${GO_PATH_ESCAPE_ROOT:-$(cd -- "$SELF_DIR/.." && pwd)}"
WORKFLOW="${GO_PATH_ESCAPE_WORKFLOW:-$REPO_ROOT/.github/workflows/go-tests.yml}"

# The census floor — a LOWER BOUND on the SCANNER's liveness, not a headcount.
# A regex that silently stopped matching would report "0 uncovered reads" and
# exit 0: clean-looking, and completely blind. Measured population on
# origin/main at the time of writing: 42 distinct resolved reads. The floor is
# set at 30, close enough that losing one whole arm (arm 3 contributes 4 rows
# nothing else sees; the docs/setup onramp block alone is 12) is caught, and far
# enough under the population that legitimately DELETING a fixture is not a
# false red. A new read does NOT raise it — the floor bounds the scanner, not
# the repo.
#
# A CONSTANT on purpose: an env override would be a one-line CI bypass of the
# only check that can tell "clean" from "blind".
GO_ESCAPE_MIN=30

# ---------------------------------------------------------------------------
# the declared set — parsed from go-tests.yml `on.push.paths`
# ---------------------------------------------------------------------------
# Same grammar as the dispatcher's own awk (go-tests.yml, "the ONE
# declaration"): comment lines inside the list are skipped, quotes stripped.
declared_globs() {
  if [ ! -f "$WORKFLOW" ]; then
    echo "::error::go-path-escape-check: $WORKFLOW is not readable; refusing to guess the declared set." >&2
    exit 2
  fi
  awk '
    /^on:[ \t]*$/               { inon = 1; next }
    inon && /^[^ \t#]/          { inon = 0; inpush = 0; inp = 0 }
    inon && /^  push:[ \t]*$/   { inpush = 1; inp = 0; next }
    inon && /^  [^ \t#]/        { inpush = 0; inp = 0 }
    inpush && /^    paths:[ \t]*$/ { inp = 1; next }
    inpush && inp && /^    [^ \t#]/ { inp = 0 }
    inp && /^[ \t]*#/           { next }
    inp && /^[ \t]*- / {
      s = $0
      sub(/^[ \t]*-[ \t]*/, "", s)
      gsub(/"/, "", s)
      if (s != "") print s
    }
  ' "$WORKFLOW"
}

# GitHub path globs -> one anchored alternation ERE. `**/` spans separators,
# `*` does not. Character-for-character the dispatcher's g2e(), so the two can
# never disagree about what a glob means.
globs_to_ere() {
  awk '
    function g2e(p,   rx, i, c, n) {
      rx = ""; i = 1; n = length(p)
      while (i <= n) {
        c = substr(p, i, 1)
        if (c == "*") {
          if (substr(p, i, 3) == "**/") { rx = rx "(.*/)?"; i = i + 3; continue }
          if (substr(p, i, 2) == "**")  { rx = rx ".*";     i = i + 2; continue }
          rx = rx "[^/]*"; i = i + 1; continue
        }
        if (c == "?") { rx = rx "[^/]" }
        else if (index(".+()[]{}^$|\\", c) > 0) { rx = rx "\\" c }
        else { rx = rx c }
        i = i + 1
      }
      return "^" rx "$"
    }
    NF { if (out != "") out = out "|"; out = out g2e($0) }
    END { print out }
  '
}

# ---------------------------------------------------------------------------
# the census
# ---------------------------------------------------------------------------
# Prints `<resolved-path><TAB><source-test-file>` per read, one per line.
# Takes the tree to scan as $1 (defaults to $REPO_ROOT) rather than reading a
# global: the selftest scans a synthetic tree in the same process, and a
# `REPO_ROOT=... list_reads` prefix would leave REPO_ROOT reassigned in the
# CALLING shell afterwards (bash does that for functions), silently retargeting
# every later call.
list_reads() {
  local root="${1:-$REPO_ROOT}"
  # SC2016 is deliberate below: the perl program is a single-quoted heredoc-ish
  # literal and NOTHING in it may be expanded by the shell.
  # shellcheck disable=SC2016
  ( cd -- "$root" && find internal -type f -name '*_test.go' 2>/dev/null | LC_ALL=C sort ) \
    | ( cd -- "$root" && xargs -- perl -e '
      use strict; use warnings;
      my %out;
      sub norm {
        my @o;
        for my $s (split m{/}, $_[0]) {
          next if $s eq q{} || $s eq q{.};
          if ($s eq q{..}) { pop @o } else { push @o, $s }
        }
        return join(q{/}, @o);
      }
      sub emit {
        my ($r, $f) = @_;
        return unless defined $r && length $r;
        return unless $r =~ m{/};                 # bare top-level dir: not a read
        return if $r =~ m{^internal(/|$)};        # already covered by **/*.go
        return if $r =~ m{^\.git(/|$)};           # VCS metadata, never dispatchable
        return unless -e $r;
        $out{"$r\t$f"} = 1;
      }
      for my $f (@ARGV) {
        open my $fh, "<", $f or next;
        local $/;
        my $body = <$fh>;
        close $fh;
        my $d = $f; $d =~ s{/[^/]*$}{};
        # every double-quoted literal, with the text that preceded it, in order
        my @flat;
        while ($body =~ /\G(.*?)"((?:[^"\\\n]|\\.)*)"/sg) { push @flat, [$1, $2] }
        # arm 2/3: runs of comma-adjacent literals
        my (@runs, @run);
        for my $t (@flat) {
          my ($gap, $tok) = @$t;
          if (@run && $gap !~ /^\s*,\s*$/) { push @runs, [@run] if @run >= 2; @run = () }
          push @run, $tok;
        }
        push @runs, [@run] if @run >= 2;
        # arm 1: the plain relative literal
        for my $lit (map { $_->[1] } @flat) {
          next unless length $lit;
          next if $lit =~ /\*/;
          next unless $lit =~ m{(^|/)\.\.(/|$)};
          emit(norm("$d/$lit"), $f);
        }
        for my $r (@runs) {
          my $joined = join(q{/}, @$r);
          next if $joined =~ /\*/;
          if ($joined =~ m{(^|/)\.\.(/|$)}) {
            emit(norm("$d/$joined"), $f);         # arm 2: segment list
          } elsif (@$r >= 3) {
            emit(norm($joined), $f);              # arm 3: walk-up to repo root
          }
        }
      }
      print "$_\n" for sort keys %out;
    ' )
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------
mode="${1:---check}"

case "$mode" in
  --print-set) declared_globs; exit 0 ;;
  --match)
    # Changed paths on stdin -> `true` if ANY of them is in the declared set.
    # This is the DISPATCHER's decision, computed by this script's copy of the
    # same parser and the same glob translator — it exists so a dry run (e.g.
    # "would this historical PR have dispatched the Go job?") is answered by
    # shipped code rather than by a one-off re-implementation in a PR body.
    # go-tests.yml still computes its own verdict in-job; the two are pinned to
    # each other by being character-for-character the same awk.
    m_globs="$(declared_globs)"
    m_ere="$(printf '%s\n' "$m_globs" | globs_to_ere)"
    if [ -z "$m_ere" ]; then
      echo "::error::go-path-escape-check --match: the declared set translated to an EMPTY pattern, which matches everything. Refusing to answer." >&2
      exit 2
    fi
    m_changed="$(cat)"
    if grep -Eq -- "$m_ere" <<<"$m_changed"; then echo true; else echo false; fi
    exit 0
    ;;
  --list-reads)
    reads="$(list_reads)"
    printf '%s\n' "$reads" | sed '/^$/d' | sort -u
    exit 0
    ;;
  --selftest) ;;
  --check) ;;
  *)
    echo "go-path-escape-check: unknown argument '$mode'" >&2
    echo "usage: $0 [--check|--selftest|--list-reads|--print-set|--match]" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# --selftest — prove the scanner is not neutered
# ---------------------------------------------------------------------------
# A synthetic tree with one read per arm, plus the two structural exclusions and
# the nonexistent-target filter. Each case asserts a SPECIFIC row present or
# absent; a scanner that lost an arm fails here even when the real tree happens
# to be clean. The pass count is asserted against a floor, because "0 tests run"
# is a pass in every runner.
if [ "$mode" = "--selftest" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/internal/pkg" "$tmp/api/lib/barkpark/content" "$tmp/api/test/fixtures/claude_chat" \
           "$tmp/docs/setup" "$tmp/.git/refs" "$tmp/internal/other"
  : >"$tmp/api/lib/barkpark/content/errors.ex"
  : >"$tmp/api/test/fixtures/claude_chat/one.json"
  : >"$tmp/docs/setup/CODEX.md"
  : >"$tmp/.git/refs/heads"
  : >"$tmp/internal/other/x.go"
  cat >"$tmp/internal/pkg/a_test.go" <<'GO'
package pkg

// arm 1: plain relative literal
var one = "../../docs/setup/CODEX.md"

// arm 2: segment list carrying ".."
var two = filepath.Join("..", "..", "api", "test", "fixtures", "claude_chat")

// arm 3: walk-up, no ".." anywhere
var three = filepath.Join(dir, "api", "lib", "barkpark", "content", "errors.ex")

// excluded: resolves inside internal/
var four = filepath.Join("..", "other", "x.go")

// excluded: .git metadata
var five = filepath.Join(root, ".git", "refs", "heads")

// excluded: nothing on disk (traversal fixture)
var six = "../../../etc/shadow-not-here"

// not a read: a two-literal table row that happens to look like a path
var seven = []string{"api", "studio"}
GO
  pass=0; fail=0
  # The census of the SYNTHETIC tree, computed ONCE. A subshell, because
  # `VAR=v func` in bash leaves VAR set in the CALLING shell after the call —
  # which would silently retarget every later run in this process at $tmp.
  fixture_census="$(list_reads "$tmp" | cut -f1 | sort -u)"
  want() { # want <present|absent> <path> <label>
    # HERE-STRING, never `printf … | grep -q`: grep -q exits on the first match,
    # the writer takes SIGPIPE, and under pipefail the pipeline returns 141 —
    # which reads as "no match" and turns every present-case into a false FAIL.
    if grep -qxF -- "$2" <<<"$fixture_census"; then found=yes; else found=no; fi
    if [ "$1" = present ]; then
      if [ "$found" = yes ]; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL [$3]: expected '$2' in census, got:"; printf '  %s\n' "${fixture_census//$'\n'/$'\n  '}"; fi
    else
      if [ "$found" = yes ]; then
        fail=$((fail+1)); echo "FAIL [$3]: '$2' must NOT be in the census"; else pass=$((pass+1)); fi
    fi
  }
  want present "docs/setup/CODEX.md"                        "arm 1 relative literal"
  want present "api/test/fixtures/claude_chat"              "arm 2 segment list"
  want present "api/lib/barkpark/content/errors.ex"         "arm 3 walk-up"
  want absent  "internal/other/x.go"                        "internal/ excluded"
  want absent  ".git/refs/heads"                            ".git excluded"
  want absent  "etc/shadow-not-here"                        "nonexistent excluded"
  want absent  "api/studio"                                 "2-literal table not a read"

  # A declared-set parse that returns nothing would make every read look covered.
  n_globs="$(declared_globs | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$n_globs" -ge 10 ]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL [declared-set parse]: parsed only $n_globs glob(s) from $WORKFLOW"; fi

  echo "go-path-escape-check --selftest: $pass passed, $fail failed"
  # COUNT FLOOR. Zero assertions executed is a pass in every runner; say the
  # number out loud and refuse a run that produced fewer than the cases above.
  if [ "$pass" -lt 8 ] && [ "$fail" -eq 0 ]; then
    echo "::error::go-path-escape-check --selftest: only $pass assertion(s) ran, expected at least 8. The harness itself is broken." >&2
    exit 1
  fi
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# --check: the ratchet
# ---------------------------------------------------------------------------
census="$(list_reads | sed '/^$/d' | sort -u || true)"
paths="$(printf '%s\n' "$census" | cut -f1 | sed '/^$/d' | sort -u)"
count="$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l | tr -d ' ')"

echo "go-path-escape-check: scanning \$REPO_ROOT=$REPO_ROOT"
echo "go-path-escape-check: declared set read from $WORKFLOW"
echo "go-path-escape-check: $count distinct cross-tree read(s) resolved from internal/**/*_test.go"

if [ "$count" -lt "$GO_ESCAPE_MIN" ]; then
  echo "::error::go-path-escape-check: only $count cross-tree read(s) found, floor is $GO_ESCAPE_MIN. The SCANNER is broken, not the repo clean — check the regexes in list_reads before touching the floor." >&2
  exit 1
fi

globs="$(declared_globs)"
n_globs="$(printf '%s\n' "$globs" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$n_globs" -lt 10 ]; then
  echo "::error::go-path-escape-check: parsed only $n_globs glob(s) from the declared set. An empty or truncated parse makes every read look UNCOVERED; refusing to emit a verdict." >&2
  exit 1
fi
ere="$(printf '%s\n' "$globs" | globs_to_ere)"
if [ -z "$ere" ]; then
  echo "::error::go-path-escape-check: the declared set translated to an EMPTY pattern. An empty ERE matches everything, which would make this ratchet permanently green." >&2
  exit 1
fi

uncovered=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # A DIRECTORY read is matched through a synthetic deep child, not by its own
  # name. git never reports a directory in a changed-file list, so the honest
  # question for `filepath.Join("..","..","api","test","fixtures","claude_chat")`
  # is "does the declared set dispatch on ANY file at ANY depth under it?" —
  # which is exactly what a `dir/**` glob answers and an exact-file entry does
  # not. Matching the bare directory name instead would report `docs/cli/fixtures`
  # UNCOVERED while `docs/cli/fixtures/**` sits in the list: a false red that
  # reads exactly like a true one.
  probe="$p"
  [ -d "$REPO_ROOT/$p" ] && probe="$p/__probe__/__probe__"
  # HERE-STRING, never `printf … | grep -q`: under pipefail the writer takes
  # SIGPIPE on the first match and the pipeline returns 141, which reads as
  # "no match" — an uncovered read would then be reported as covered.
  if ! grep -Eq -- "$ere" <<<"$probe"; then
    uncovered="$uncovered$p"$'\n'
  fi
done <<EOF
$paths
EOF

if [ -n "$uncovered" ]; then
  echo
  echo "UNCOVERED cross-tree reads (the Go suite reads them; go-tests.yml does not dispatch on them):"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "  $p"
    printf '%s\n' "$census" | awk -F'\t' -v want="$p" '$1 == want { print "      read by " $2 }' | sort -u
  done <<EOF
$uncovered
EOF
  n="$(printf '%s' "$uncovered" | sed '/^$/d' | wc -l | tr -d ' ')"
  echo
  echo "::error::go-path-escape-check: $n cross-tree read(s) are NOT in go-tests.yml on.push.paths. A PR that edits one of them dispatches NO Go job, and the Go gate then reports green because a skip is an allowed result. Declare each path in on.push.paths with a one-line comment naming the test that reads it." >&2
  exit 1
fi

echo "OK: every cross-tree read the Go suite makes is covered by go-tests.yml on.push.paths."
