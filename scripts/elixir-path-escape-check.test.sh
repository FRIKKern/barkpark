#!/usr/bin/env bash
#
# elixir-path-escape-check.test.sh — the harness for the Elixir path ratchet.
#
# Charter D26: a harness nobody runs is not a ratchet. This one is executed by
# elixir.yml's `path-escape` job (unfiltered, so it can never go dark) and by
# the slice gate, via `elixir-path-escape-check.sh --selftest`.
#
# The cases that matter are the ones that prove the ratchet can FAIL:
#   * an uncovered repo-root read must red                  (case 3)
#   * an uncovered read reached ONLY through the ROOT-ANCHOR
#     idiom must red                                        (case 3b) — the
#     newest measured false OK: `@repo_root Path.expand("../../../..",
#     __DIR__)` + `Path.join(@repo_root, "deploy/site-deploy.sh")` carries no
#     `"../<file>"` literal at the read site, so the literal doors never saw
#     it. On origin/main the ratchet printed `OK: every repo-root read … is
#     dispatched on.` at rc=0 on a byte-clean tree while FOUR such reads went
#     undeclared, inside the REQUIRED Elixir gate.
#   * an uncovered read in an UNTRACKED file must red       (case 4) — the
#     measured vacuous pass this ratchet was redesigned to avoid: a prototype
#     enumerating via `git ls-files` printed "OK: every repo-root read is
#     covered" and exited 0 with the mutation fixture sitting untracked on disk
#   * a neutered scanner must red rather than report clean  (case 5)
#   * a PARTIALLY neutered scanner must red too             (case 5b) — the
#     mutation the old whole-population floor could not see: deleting `api/test`
#     from list_escapes' `find` collapsed the census 29 -> 11 on origin/main and
#     still printed OK, exit 0, inside the REQUIRED Elixir gate. Case 5 only
#     ever exercised a TOTAL collapse, so it certified a floor that could not
#     fire on the failure its own comment named.
#   * a scanner door with no declared floor must red        (case 5c)
# A harness with only green cases is the defect, not the proof.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/elixir-path-escape-check.sh"
REAL_ROOT="$(cd -- "$HERE/.." && pwd)"

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  echo "  ok   — $1"
}
no() {
  fail=$((fail + 1))
  echo "  FAIL — $1" >&2
}

# ── charter D37: never `printf … | grep -q` ────────────────────────────────
# `printf '%s\n' "$x" | grep -q …` under `set -o pipefail` is a SIGPIPE trap on
# BSD grep (macOS): grep exits 0 the instant it matches, printf is killed by
# SIGPIPE, pipefail promotes 141 over grep's success, and the `if` takes the
# ELSE branch — reporting a FALSE failure for a match that did occur. Six
# consecutive local runs gave 6, 4, 3, 4, 5, 5 failures, never zero, while the
# same harness was 12/12 green on ubuntu/bash-5. That is wave 1's disease
# inverted: an assertion inside the anti-vacuous-pass harness returning a
# verdict for a reason foreign to what it tests.
#
# A here-string has no writer process to kill, so these are deterministic on
# every platform. Use them for EVERY match against a captured string; matches
# against a FILE (`grep -q … "$f"`) were never at risk and stay as they are.
has()      { grep -q  -- "$2" <<<"$1"; }   # substring/BRE anywhere in $1
has_line() { grep -qx -- "$2" <<<"$1"; }   # a whole line of $1 equals the BRE

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/elixir-path-escape-test.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# Build a synthetic mini-repo whose api/ tree escapes to known repo-root paths.
# `covered_rel` is a path INSIDE a declared set; `uncovered_rel` is not in any.
#
# THE FIXTURE MUST CLEAR EVERY IDIOM FLOOR, not one aggregate number. The
# ratchet floors each of its doors separately (`--print-floors`: test-cwd 8,
# test-dir 8, lib-cwd 5, lib-dir 5, test-root 2), so a fixture that reads only
# from api/test would red on `lib-*: 0` and the coverage cases below would
# "prove" coverage using a floor failure. Every `../../../…` literal written
# from api/{lib,test}/barkpark resolves identically under BOTH bases — the
# file's own directory and `api/` — so one literal feeds one `-dir` row and one
# `-cwd` row. Hence: ten literals in the api/test file, six in the api/lib file,
# which leaves real headroom over 8 and 5 rather than sitting exactly on them.
#
# The `test-root` block is the ROOT-ANCHOR idiom — an anchor bound once with
# `Path.expand("../../..", __DIR__)` and then `Path.join(@root, "literal")` at
# each read site. It is here for the same reason the api/lib literals are: it
# is a door with its own floor, and a fixture that omitted it would make every
# mutation case below red on `test-root: 0` instead of on the thing it tests.
# The anchor's own literal contributes NO `-dir`/`-cwd` row (it normalises to
# the empty string — which is exactly why the literal doors could never see
# this idiom, and why the door had to be added).
make_fixture() {
  local root="$1"
  mkdir -p "$root/api/lib/barkpark" "$root/api/test/barkpark" \
    "$root/internal/taskboard" "$root/internal/chat/testdata" \
    "$root/internal/pdrender/testdata" "$root/cmd/barkpark/testdata" \
    "$root/.codex/skills/epic-cycle/scripts" "$root/design" "$root/web/__tests__/fixtures"
  : >"$root/internal/taskboard/components.go"
  : >"$root/internal/taskboard/tokens_gen.go"
  : >"$root/internal/chat/testdata/workflow_summary.json"
  : >"$root/internal/pdrender/testdata/blocks.json"
  : >"$root/cmd/barkpark/testdata/preview-parity.json"
  : >"$root/.codex/skills/epic-cycle/scripts/run_concurrency_benchmark.py"
  : >"$root/design/status-manifest.json"
  : >"$root/design/tokens.json"
  : >"$root/web/__tests__/fixtures/preview-parity.json"
  # Ten covered reads from api/test -> test-dir 10, test-cwd 10 (floors: 8, 8).
  cat >"$root/api/test/barkpark/covered_test.exs" <<'EX'
  @a Path.expand("../../../internal/taskboard/components.go", __DIR__)
  @b Path.expand("../../../internal/taskboard/tokens_gen.go", __DIR__)
  @c Path.expand("../../../internal/chat/testdata/workflow_summary.json", __DIR__)
  @d Path.expand("../../../.codex/skills/epic-cycle/scripts/run_concurrency_benchmark.py", __DIR__)
  @e Path.expand("../../../design/status-manifest.json", __DIR__)
  @f Path.expand("../../../web/__tests__/fixtures/preview-parity.json", __DIR__)
  @g Path.expand("../../../internal/chat/testdata", __DIR__)
  @h Path.expand("../../../web/__tests__/fixtures", __DIR__)
  @j Path.expand("../../../internal/pdrender/testdata/blocks.json", __DIR__)
  @k Path.expand("../../../cmd/barkpark/testdata/preview-parity.json", __DIR__)
  @i File.read!("../design/status-manifest.json")
  # ROOT-ANCHOR idiom -> test-root 4 (floor: 2). The anchor literal itself
  # normalises to "" and is dropped, so these rows can ONLY come from the
  # `-root` door.
  @root Path.expand("../../..", __DIR__)
  @r1 Path.join(@root, "internal/taskboard/components.go")
  @r2 Path.join(@root, "design/tokens.json")
  @r3 Path.join(@root, "cmd/barkpark/testdata/preview-parity.json")
  @r4 Path.join(@root, "internal/pdrender/testdata/blocks.json")
  # traversal-attack fixtures: asserted on, never read — must NOT be counted
  @x "../etc/passwd"
  @y "../up"
EX
  # Six covered reads from api/lib -> lib-dir 6, lib-cwd 6 (floors: 5, 5). The
  # real tree reads across both halves (mix tasks in api/lib, tests in
  # api/test); a fixture that only had one half could not exercise the doors
  # that catch the other half going blind.
  cat >"$root/api/lib/barkpark/covered.ex" <<'EX'
  @a Path.expand("../../../design/status-manifest.json", __DIR__)
  @b Path.expand("../../../design/tokens.json", __DIR__)
  @c Path.expand("../../../cmd/barkpark/testdata/preview-parity.json", __DIR__)
  @d Path.expand("../../../internal/pdrender/testdata/blocks.json", __DIR__)
  @e Path.expand("../../../internal/taskboard/components.go", __DIR__)
  @f Path.expand("../../../internal/chat/testdata/workflow_summary.json", __DIR__)
EX
}

echo "elixir-path-escape-check.test.sh"
echo

# ── case 1: the real repo passes, and reports the measured population ───────
echo "case 1: the real repository is clean"
out="$("$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then ok "exit 0 on the real repo"; else no "expected exit 0, got $rc: $out"; fi
if has "$out" "OK: every repo-root read"; then
  ok "prints the OK verdict"
else
  no "missing OK verdict: $out"
fi
# The count is the anti-vacuity signal: a run that says "0 reads" is a broken
# scanner, and this case would notice it even if the floor were removed.
#
# NO HARD-CODED POPULATION HERE. This assertion used to read `-ge 20` under a
# label claiming the measured population was 24 — a PASSING test whose own name
# was stale by five (the tree measures 29), and a threshold nine under the live
# population, so the census could have lost nine reads and still said ok. Both
# halves are DERIVED now, and neither can rot:
#   (a) --check's count must agree with --list-escapes' own distinct count. Two
#       modes, one census; if they disagree, one of them is lying.
#   (b) every idiom the script declares a floor for must actually clear that
#       floor in --list-escapes. Computed from --list-escapes and --print-floors,
#       so it does not just re-read --check's arithmetic back to itself.
n="$(printf '%s' "$out" | sed -n 's/^elixir-path-escape-check: \([0-9]*\) distinct.*/\1/p')"
listed="$("$SCRIPT" --list-escapes | cut -f1 | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
if [ "${n:-0}" = "$listed" ] && [ "${n:-0}" -gt 0 ]; then
  ok "--check's count ($n) agrees with --list-escapes' distinct census"
else
  no "--check says ${n:-0} reads, --list-escapes says $listed — the two modes disagree"
fi
census_tagged="$("$SCRIPT" --list-escapes | cut -f1,3 | sed '/^$/d' | sort -u)"
floors="$("$SCRIPT" --print-floors)"
thin_idioms=0
while IFS= read -r frow; do
  [ -n "$frow" ] || continue
  fidiom="${frow%%	*}"
  fmin="${frow##*	}"
  fgot="$(printf '%s\n' "$census_tagged" | awk -F'\t' -v k="$fidiom" '$2 == k' | wc -l | tr -d ' ')"
  if [ "$fgot" -ge "$fmin" ]; then
    ok "idiom $fidiom is live: $fgot read(s), floor $fmin"
  else
    no "idiom $fidiom resolved $fgot read(s) but its floor is $fmin — this door is blind"
    thin_idioms=$((thin_idioms + 1))
  fi
done <<<"$floors"
if [ "$thin_idioms" -eq 0 ]; then
  ok "every declared idiom clears its own floor on the real tree"
else
  no "$thin_idioms idiom(s) are under their floor"
fi
if has "$out" "exempt: scripts/claude-pinned-version.txt"; then
  ok "the :real_binary-only read is reported as exempt, not silently dropped"
else
  no "exemption not reported"
fi
echo

# ── case 2: the census carries the three families the obvious list misses ───
echo "case 2: the census carries the three easily-missed families"
census="$("$SCRIPT" --list-escapes | cut -f1 | sort -u)"
for want in internal/taskboard/components.go internal/chat/testdata \
  .codex/skills/epic-cycle/scripts/run_concurrency_benchmark.py; do
  if has_line "$census" "$want"; then
    ok "census carries $want"
  else
    no "census MISSES $want"
  fi
done
# and the two measured over-inclusions are absent from the declared sets
sets="$("$SCRIPT" --print-set test)"
if has_line "$sets" 'templates/\*\*'; then
  no "repo-root templates/** is declared — measured over-inclusion"
else
  ok "repo-root templates/** is not declared"
fi
if has_line "$sets" 'scripts/claude-pinned-version.txt'; then
  no "scripts/claude-pinned-version.txt is declared — measured over-inclusion"
else
  ok "scripts/claude-pinned-version.txt is not declared"
fi
echo

# ── case 3: an uncovered repo-root read REDS (tracked file) ─────────────────
echo "case 3: an uncovered repo-root read reds (mutation)"
FX="$TMPROOT/tracked"
make_fixture "$FX"
mkdir -p "$FX/nowhere"
: >"$FX/nowhere/secret.json"
cat >"$FX/api/test/barkpark/escaping_test.exs" <<'EX'
  @bad Path.expand("../../../nowhere/secret.json", __DIR__)
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc (non-zero) on an uncovered read"; else no "PASSED with an uncovered read — vacuous"; fi
if has "$out" "UNCOVERED repo-root read: nowhere/secret.json"; then
  ok "names the uncovered path"
else
  no "did not name the uncovered path: $out"
fi
if has "$out" "read from: api/test/barkpark/escaping_test.exs"; then
  ok "names the file that reads it"
else
  no "did not attribute the read: $out"
fi
echo

# ── case 3b: THE ROOT-ANCHOR DOOR — the read no `"../…"` literal reveals ────
# The mutation that used to pass GREEN. `@repo_root Path.expand("../../..",
# __DIR__)` + `Path.join(@repo_root, "…")` carries no `"../<file>"` literal at
# the read site: the only literal is the anchor, which norm_path reduces to the
# empty string and the scanner discards. On origin/main this exact fixture
# exited 0 with the OK verdict — the same false-OK shape that hid four live
# undeclared reads (deploy/site-deploy.sh, deploy/site-deploy-node.sh,
# .github/workflows/deploy.yml, scripts/check-deployyml-filters.sh) inside the
# REQUIRED Elixir gate.
#
# The uncovered path is reached ONLY through this idiom, so a scanner that
# loses the `-root` door greens here again — which is what makes this a case
# that can fail, not decoration.
echo "case 3b: an uncovered read via the ROOT-ANCHOR idiom reds"
FX_ROOT="$TMPROOT/rootanchor"
make_fixture "$FX_ROOT"
mkdir -p "$FX_ROOT/nowhere"
: >"$FX_ROOT/nowhere/anchored.json"
cat >"$FX_ROOT/api/test/barkpark/anchored_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  @bad Path.join(@repo_root, "nowhere/anchored.json")
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_ROOT" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on a root-anchored uncovered read"
else
  no "PASSED with a root-anchored uncovered read — the -root door is blind: $out"
fi
if has "$out" "UNCOVERED repo-root read: nowhere/anchored.json"; then
  ok "names the path the anchor+Path.join resolved to"
else
  no "did not name the root-anchored path: $out"
fi
if has "$out" "read from: api/test/barkpark/anchored_test.exs"; then
  ok "attributes the root-anchored read to its file"
else
  no "did not attribute the root-anchored read: $out"
fi
# The `lower-case var =` binding form, not just the `@attr` form.
cat >"$FX_ROOT/api/test/barkpark/anchored_test.exs" <<'EX'
  root = Path.expand("../../..", __DIR__)
  bad = Path.join(root, "nowhere/anchored.json")
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_ROOT" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && has "$out" "UNCOVERED repo-root read: nowhere/anchored.json"; then
  ok "the plain-variable anchor binding is seen too"
else
  no "a plain-variable anchor binding is invisible to the -root door: $out"
fi
# A root-anchored read that IS declared must stay green — the door must not
# turn every anchored read into a red.
rm -f "$FX_ROOT/api/test/barkpark/anchored_test.exs"
cat >"$FX_ROOT/api/test/barkpark/anchored_ok_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  @good Path.join(@repo_root, "internal/taskboard/tokens_gen.go")
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_ROOT" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a DECLARED root-anchored read stays green"
else
  no "a declared root-anchored read redded — the door over-reports: $out"
fi
echo

# ── case 3c: THE OTHER TWO JOIN FORMS — pipe and list ───────────────────────
# Case 3b proves the `-root` door sees `Path.join(@root, "lit")`. It proves
# NOTHING about the two other ways the same anchor reaches the same file, and
# both are live idioms in api/lib + api/test:
#
#   `@root |> Path.join("lit")`        the pipe form   (tag `test-rootpipe`)
#   `Path.join([@root, "lit", …])`     the list form   (tag `test-rootlist`)
#
# MEASURED, and the reason this case exists: a 14-shape probe matrix planted in
# api/test — one file per idiom, each reading the undeclared repo-root file
# CLAUDE.md — was run against origin/main's scanner. It resolved 4 of the 14
# shapes cleanly. The pipe and list forms were among the nine it could not see,
# and NEITHER was named in the script's RESIDUE note, which listed only three
# known-blind shapes. So the gate was credited with 5 doors at full strength
# while seeing 4 of 14 shapes: counting doors is not counting what a door sees.
#
# Each form gets its OWN tag and therefore its own case. A single fused `-root`
# count would let one form's grep be deleted while the tag stayed populated by
# the other two — the aggregate blindness this whole file exists to refuse.
echo "case 3c: the PIPE and LIST join forms are seen, and each is load-bearing"
FX_FORMS="$TMPROOT/joinforms"
make_fixture "$FX_FORMS"
mkdir -p "$FX_FORMS/nowhere"
: >"$FX_FORMS/nowhere/piped.json"
: >"$FX_FORMS/nowhere/listed.json"

# --- the pipe form ---------------------------------------------------------
cat >"$FX_FORMS/api/test/barkpark/piped_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  def r, do: @repo_root |> Path.join("nowhere/piped.json") |> File.read!()
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_FORMS" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on a PIPE-form uncovered read"
else
  no "PASSED with a pipe-form uncovered read — the rootpipe arm is blind: $out"
fi
if has "$out" "UNCOVERED repo-root read: nowhere/piped.json"; then
  ok "names the path the pipe form resolved to"
else
  no "did not name the pipe-form path: $out"
fi
if has "$out" "read from: api/test/barkpark/piped_test.exs"; then
  ok "attributes the pipe-form read to its file"
else
  no "did not attribute the pipe-form read: $out"
fi
if has "$out" "idiom test-rootpipe: "; then
  ok "reports test-rootpipe as its own idiom, not folded into test-root"
else
  no "the pipe form has no tag of its own — a fused count cannot see it die: $out"
fi
rm -f "$FX_FORMS/api/test/barkpark/piped_test.exs"

# --- the list form ---------------------------------------------------------
cat >"$FX_FORMS/api/test/barkpark/listed_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  def r, do: File.read!(Path.join([@repo_root, "nowhere/listed.json"]))
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_FORMS" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on a LIST-form uncovered read"
else
  no "PASSED with a list-form uncovered read — the rootlist arm is blind: $out"
fi
if has "$out" "UNCOVERED repo-root read: nowhere/listed.json"; then
  ok "names the path the list form resolved to"
else
  no "did not name the list-form path: $out"
fi
if has "$out" "idiom test-rootlist: "; then
  ok "reports test-rootlist as its own idiom"
else
  no "the list form has no tag of its own: $out"
fi

# --- a DECLARED read through either form must stay green -------------------
# The forms must not turn every anchored read into a red; over-reporting costs
# the dispatcher exactly what it exists to save.
rm -f "$FX_FORMS/api/test/barkpark/listed_test.exs"
cat >"$FX_FORMS/api/test/barkpark/forms_ok_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  def a, do: @repo_root |> Path.join("internal/taskboard/tokens_gen.go")
  def b, do: Path.join([@repo_root, "internal/taskboard/components.go"])
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_FORMS" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "DECLARED reads through the pipe and list forms stay green"
else
  no "a declared pipe/list read redded — the new arms over-report: $out"
fi

# --- the arms are LOAD-BEARING --------------------------------------------
# A case that only ever watches the arm succeed has agreed with it, not tested
# it. Delete the two new arms from a COPY and the pipe fixture must green again
# — that green IS the proof the arm is what caught it.
rm -f "$FX_FORMS/api/test/barkpark/forms_ok_test.exs"
cat >"$FX_FORMS/api/test/barkpark/piped_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  def r, do: @repo_root |> Path.join("nowhere/piped.json") |> File.read!()
EX
MUT_FORMS="$TMPROOT/mutant-no-join-forms.sh"
sed 's|for form in root rootpipe rootlist; do|for form in root; do|' "$SCRIPT" >"$MUT_FORMS"
if ! cmp -s "$MUT_FORMS" "$SCRIPT"; then
  ok "the join-form mutation applied (the form loop really changed)"
else
  no "the join-form mutation did NOT apply — this case would prove nothing"
fi
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_FORMS" bash "$MUT_FORMS" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "without the rootpipe/rootlist arms the same read greens — the arms are load-bearing"
else
  no "the pipe fixture redded even with the arms deleted — case 3c proves nothing: $out"
fi
echo

# ── case 3d: SHAPE 1 — the INTERPOLATED ANCHOR is seen (tag test-rootinterp) ─
# `Path.expand("../../..#{""}", __DIR__)` — the anchor's own literal carries a
# splice. wbt-jwt-path-escape-blind-idioms closes this: the anchor regex used
# to require the literal to be PURE dots-and-slashes, so an interpolated
# anchor failed the match entirely and everything joined off it went dark.
# Every join form resolves off the SAME computed anchor directory, so this
# uses the plain `Path.join(@anchor, "lit")` form already proven live by case
# 3b; the point here is the ANCHOR capture itself, not a new join shape.
echo "case 3d: SHAPE 1 — an interpolated anchor literal is seen, tagged test-rootinterp"
FX_INTERP="$TMPROOT/interpanchor"
make_fixture "$FX_INTERP"
mkdir -p "$FX_INTERP/nowhere"
: >"$FX_INTERP/nowhere/interp.json"
cat >"$FX_INTERP/api/test/barkpark/interp_test.exs" <<'EX'
  @repo_root Path.expand("../../..#{""}", __DIR__)
  @bad Path.join(@repo_root, "nowhere/interp.json")
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_INTERP" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on an interpolated-anchor uncovered read"
else
  no "PASSED with an interpolated-anchor uncovered read — shape 1 is blind: $out"
fi
if has "$out" "UNCOVERED repo-root read: nowhere/interp.json"; then
  ok "names the path the interpolated anchor resolved to"
else
  no "did not name the interpolated-anchor path: $out"
fi
if has "$out" "read from: api/test/barkpark/interp_test.exs"; then
  ok "attributes the interpolated-anchor read to its file"
else
  no "did not attribute the interpolated-anchor read: $out"
fi
if has "$out" "idiom test-rootinterp: "; then
  ok "reports test-rootinterp as its own idiom, not folded into test-root"
else
  no "the interpolated anchor has no tag of its own — a fused count cannot see it die: $out"
fi
# a DECLARED read through an interpolated anchor must stay green — the door
# must not turn every interpolated anchor into a red.
rm -f "$FX_INTERP/api/test/barkpark/interp_test.exs"
cat >"$FX_INTERP/api/test/barkpark/interp_ok_test.exs" <<'EX'
  @repo_root Path.expand("../../..#{""}", __DIR__)
  @good Path.join(@repo_root, "internal/taskboard/tokens_gen.go")
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_INTERP" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a DECLARED read through an interpolated anchor stays green"
else
  no "a declared interpolated-anchor read redded — the door over-reports: $out"
fi
# the fix is LOAD-BEARING: reverting the anchor literal back to its pre-fix
# `[./]+` (pure dots-and-slashes, no splice tolerance) must make the very same
# uncovered fixture green again — that green IS the proof the widened regex
# is what caught it, not a fixture quirk.
rm -f "$FX_INTERP/api/test/barkpark/interp_ok_test.exs"
cat >"$FX_INTERP/api/test/barkpark/interp_test.exs" <<'EX'
  @repo_root Path.expand("../../..#{""}", __DIR__)
  @bad Path.join(@repo_root, "nowhere/interp.json")
EX
MUT_INTERP="$TMPROOT/mutant-no-interp-anchor.sh"
python3 - "$SCRIPT" "$MUT_INTERP" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = r'"[./]*(\#\{[^}]*\})?[./]*"'
new = r'"[./]+"'
assert text.count(old) == 1, "anchor regex literal not found exactly once — mutation would prove nothing"
open(dst, "w").write(text.replace(old, new, 1))
PY
if ! cmp -s "$MUT_INTERP" "$SCRIPT"; then
  ok "the interpolated-anchor mutation applied (the anchor regex really changed)"
else
  no "the interpolated-anchor mutation did NOT apply — this case would prove nothing"
fi
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_INTERP" bash "$MUT_INTERP" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "without interpolation tolerance the same read greens — shape 1's fix is load-bearing"
else
  no "the interpolated-anchor fixture redded even with the widened regex reverted — case 3d proves nothing: $out"
fi
echo

# ── case 3e: SHAPE 4 — NON-__DIR__ BASE is seen (tag test-rootbase) ─────────
# `Path.expand("lit", @root)` / `Path.absname("lit", @root)` — the anchor is
# the SECOND argument, so none of the three join-form doors (all of which
# look for the anchor BEFORE the comma) ever see it.
echo "case 3e: SHAPE 4 — Path.expand/absname(\"lit\", @anchor) is seen, tagged test-rootbase"
FX_BASE="$TMPROOT/rootbase"
make_fixture "$FX_BASE"
mkdir -p "$FX_BASE/nowhere"
: >"$FX_BASE/nowhere/based.json"
: >"$FX_BASE/nowhere/absbased.json"
cat >"$FX_BASE/api/test/barkpark/based_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  @bad Path.expand("nowhere/based.json", @repo_root)
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_BASE" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on a Path.expand(lit, @anchor) uncovered read"
else
  no "PASSED with a Path.expand(lit, @anchor) uncovered read — shape 4 is blind: $out"
fi
if has "$out" "UNCOVERED repo-root read: nowhere/based.json"; then
  ok "names the path Path.expand(lit, @anchor) resolved to"
else
  no "did not name the Path.expand(lit, @anchor) path: $out"
fi
if has "$out" "read from: api/test/barkpark/based_test.exs"; then
  ok "attributes the Path.expand(lit, @anchor) read to its file"
else
  no "did not attribute the Path.expand(lit, @anchor) read: $out"
fi
if has "$out" "idiom test-rootbase: "; then
  ok "reports test-rootbase as its own idiom"
else
  no "Path.expand(lit, @anchor) has no tag of its own: $out"
fi
# the Path.absname sibling form must be seen too, not just Path.expand
rm -f "$FX_BASE/api/test/barkpark/based_test.exs"
cat >"$FX_BASE/api/test/barkpark/absbased_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  @bad Path.absname("nowhere/absbased.json", @repo_root)
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_BASE" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && has "$out" "UNCOVERED repo-root read: nowhere/absbased.json"; then
  ok "the Path.absname(lit, @anchor) sibling form is seen too"
else
  no "Path.absname(lit, @anchor) is invisible to the rootbase door: $out"
fi
# a DECLARED read through this form must stay green
rm -f "$FX_BASE/api/test/barkpark/absbased_test.exs"
cat >"$FX_BASE/api/test/barkpark/based_ok_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  @good Path.expand("internal/taskboard/tokens_gen.go", @repo_root)
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_BASE" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a DECLARED read through Path.expand(lit, @anchor) stays green"
else
  no "a declared Path.expand(lit, @anchor) read redded — the door over-reports: $out"
fi
# the door is LOAD-BEARING: disabling its grep must make the uncovered
# fixture green again.
rm -f "$FX_BASE/api/test/barkpark/based_ok_test.exs"
cat >"$FX_BASE/api/test/barkpark/based_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  @bad Path.expand("nowhere/based.json", @repo_root)
EX
MUT_BASE="$TMPROOT/mutant-no-rootbase.sh"
python3 - "$SCRIPT" "$MUT_BASE" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines(keepends=True)
target = None
for i, line in enumerate(lines):
    if 'based="$(grep -Eoh' in line:
        target = i
        break
assert target is not None, "the shape-4 grep line was not found — mutation would prove nothing"
indent = lines[target][:len(lines[target]) - len(lines[target].lstrip())]
lines[target] = indent + 'based=""\n'
open(dst, "w").writelines(lines)
PY
if ! cmp -s "$MUT_BASE" "$SCRIPT"; then
  ok "the rootbase mutation applied (the Path.expand/absname grep really changed)"
else
  no "the rootbase mutation did NOT apply — this case would prove nothing"
fi
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_BASE" bash "$MUT_BASE" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "without the rootbase grep the same read greens — shape 4's door is load-bearing"
else
  no "the based fixture redded even with the grep disabled — case 3e proves nothing: $out"
fi
echo

# ── case 3f: SHAPE 6 — a MULTI-LINE Path.join( is seen (tag test-rootmulti) ──
# A `Path.join(` whose anchor and literal sit on the lines AFTER the opener —
# every other door is line-based, so none of them see it. This door reads a
# WINDOW instead. LIVE today, anchored on `System.tmp_dir!()` rather than a
# tracked repo-root anchor, at api/lib/barkpark/plugins/tickets/
# attachments.ex:253 and api/lib/barkpark/plugins/onixedit/export/
# validator.ex:93 — so this case proves BOTH halves: a tracked anchor in this
# shape is caught, and the two real sites are SEEN (the opener scan runs
# unconditionally) without being wrongly resolved to a new read.
echo "case 3f: SHAPE 6 — a multi-line Path.join( is seen, tagged test-rootmulti"
FX_MULTI="$TMPROOT/multiline"
make_fixture "$FX_MULTI"
mkdir -p "$FX_MULTI/nowhere"
: >"$FX_MULTI/nowhere/multiline.json"
cat >"$FX_MULTI/api/test/barkpark/multiline_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  def r do
    Path.join(
      @repo_root,
      "nowhere/multiline.json"
    )
  end
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_MULTI" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on a multi-line-join uncovered read"
else
  no "PASSED with a multi-line-join uncovered read — shape 6 is blind: $out"
fi
if has "$out" "UNCOVERED repo-root read: nowhere/multiline.json"; then
  ok "names the path the multi-line join resolved to"
else
  no "did not name the multi-line-join path: $out"
fi
if has "$out" "read from: api/test/barkpark/multiline_test.exs"; then
  ok "attributes the multi-line-join read to its file"
else
  no "did not attribute the multi-line-join read: $out"
fi
if has "$out" "idiom test-rootmulti: "; then
  ok "reports test-rootmulti as its own idiom"
else
  no "the multi-line join has no tag of its own: $out"
fi
# a DECLARED read through the multi-line form must stay green
rm -f "$FX_MULTI/api/test/barkpark/multiline_test.exs"
cat >"$FX_MULTI/api/test/barkpark/multiline_ok_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  def r do
    Path.join(
      @repo_root,
      "internal/taskboard/tokens_gen.go"
    )
  end
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_MULTI" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a DECLARED read through the multi-line form stays green"
else
  no "a declared multi-line-join read redded — the door over-reports: $out"
fi
rm -f "$FX_MULTI/api/test/barkpark/multiline_ok_test.exs"

# sanity against the REAL tree: the two live sites the task names really do
# carry the bare `Path.join(` opener this door scans for, and contribute no
# census row — "seen, not resolved", because neither binds its anchor
# (System.tmp_dir!()) via Path.expand(…, __DIR__).
for site in api/lib/barkpark/plugins/tickets/attachments.ex \
  api/lib/barkpark/plugins/onixedit/export/validator.ex; do
  if grep -qE '^[[:space:]]*Path\.join\([[:space:]]*$' "$REAL_ROOT/$site"; then
    ok "the live multi-line opener in $site matches what shape 6 scans for"
  else
    no "the live multi-line opener in $site no longer matches — the task's claim is stale"
  fi
done
# `--list-escapes` rows are `<path><TAB><source-file><TAB><idiom>`; the source
# file is the SECOND column, so check it there rather than a bare substring
# search (which could in principle also match a resolved PATH by accident).
real_census_sources="$("$SCRIPT" --list-escapes | cut -f2 | sort -u)"
for site in api/lib/barkpark/plugins/tickets/attachments.ex \
  api/lib/barkpark/plugins/onixedit/export/validator.ex; do
  if has_line "$real_census_sources" "$site"; then
    no "$site unexpectedly contributes a census row via shape 6"
  else
    ok "$site is seen by the opener scan but resolves to no new read (anchors on System.tmp_dir!(), not tracked)"
  fi
done

# the door is LOAD-BEARING: disabling the opener scan must make the synthetic
# fixture green again.
cat >"$FX_MULTI/api/test/barkpark/multiline_test.exs" <<'EX'
  @repo_root Path.expand("../../..", __DIR__)
  def r do
    Path.join(
      @repo_root,
      "nowhere/multiline.json"
    )
  end
EX
MUT_MULTI="$TMPROOT/mutant-no-multiline.sh"
python3 - "$SCRIPT" "$MUT_MULTI" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines(keepends=True)
target = None
for i, line in enumerate(lines):
    if 'openers="$(grep -noE' in line:
        target = i
        break
assert target is not None, "the shape-6 opener-scan line was not found — mutation would prove nothing"
indent = lines[target][:len(lines[target]) - len(lines[target].lstrip())]
lines[target] = indent + 'openers=""\n'
open(dst, "w").writelines(lines)
PY
if ! cmp -s "$MUT_MULTI" "$SCRIPT"; then
  ok "the multi-line-join mutation applied (the opener scan really changed)"
else
  no "the multi-line-join mutation did NOT apply — this case would prove nothing"
fi
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX_MULTI" bash "$MUT_MULTI" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "without the opener scan the same read greens — shape 6's door is load-bearing"
else
  no "the multi-line fixture redded even with the opener scan disabled — case 3f proves nothing: $out"
fi
echo

# ── case 4: THE UNTRACKED CASE — the measured vacuous pass ──────────────────
# Same mutation, but inside a real git repo where the offending fixture is
# present on disk and NOT tracked. A `git ls-files` enumeration reports clean
# here; a working-tree enumeration reds.
echo "case 4: an uncovered read in an UNTRACKED file still reds"
FX2="$TMPROOT/untracked"
make_fixture "$FX2"
git -C "$FX2" init -q
git -C "$FX2" add -A >/dev/null 2>&1
git -C "$FX2" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
mkdir -p "$FX2/nowhere"
: >"$FX2/nowhere/secret.json"
cat >"$FX2/api/test/barkpark/untracked_escape_test.exs" <<'EX'
  @bad Path.expand("../../../nowhere/secret.json", __DIR__)
EX
# sanity: the fixture really is invisible to git
if git -C "$FX2" ls-files --error-unmatch api/test/barkpark/untracked_escape_test.exs >/dev/null 2>&1; then
  no "fixture setup wrong — the mutation file is TRACKED, so this case proves nothing"
else
  ok "fixture is genuinely untracked (git ls-files does not see it)"
fi
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX2" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) — the working-tree scan sees untracked code"
else
  no "PASSED on an untracked uncovered read — this is the git ls-files vacuous pass (D31)"
fi
if has "$out" "read from: api/test/barkpark/untracked_escape_test.exs"; then
  ok "attributes the read to the untracked file"
else
  no "did not attribute the untracked read: $out"
fi
echo

# ── case 5: a neutered scanner reds on the floor, never reports clean ───────
echo "case 5: the min-escapes floor catches a neutered scanner"
FX3="$TMPROOT/thin"
mkdir -p "$FX3/api/lib" "$FX3/api/test" "$FX3/design"
: >"$FX3/design/status-manifest.json"
cat >"$FX3/api/test/one_test.exs" <<'EX'
  @a Path.expand("../../design/status-manifest.json", __DIR__)
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX3" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) when the population collapses below the floor"
else
  no "reported CLEAN with 1 read — a neutered scanner would pass"
fi
if has "$out" "SCANNER is broken, not the repo clean"; then
  ok "says the scanner is broken, not that the repo is clean"
else
  no "wrong diagnosis: $out"
fi
# and the floor is NOT overridable outside the harness
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX3" ELIXIR_ESCAPE_IDIOM_MIN='test-dir	0
test-cwd	0
lib-dir	0
lib-cwd	0' "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "ELIXIR_ESCAPE_IDIOM_MIN in the environment cannot lower the floors"
else
  no "the floors were lowered by an env var — that is a one-line CI bypass"
fi
echo

# ── case 5b: THE PARTIAL BLINDING — one door goes dark, on the REAL tree ────
# This is the case the old whole-population floor could not have: it never
# exercised anything but a TOTAL collapse (case 5's one-read fixture), so it
# certified a floor that could not fire on the failure its own comment named.
#
# Measured on origin/main at the time this case was written: deleting `api/test`
# from list_escapes' `find` — ONE WORD — collapsed the census 29 -> 11, a 62%
# loss of scanner coverage, and the ratchet printed `OK` and exited 0 inside the
# REQUIRED Elixir gate. The surviving api/lib reads alone cleared the old floor
# of 8. So the mutation is applied to a COPY of the real script and run against
# the REAL repository: a partially-blinded scanner must red, and it must accuse
# itself rather than the repo.
echo "case 5b: blinding ONE door (api/test) reds on the real tree"
MUT="$TMPROOT/mutant-no-api-test.sh"
sed 's|find api/lib api/test|find api/lib|' "$SCRIPT" >"$MUT"
if ! cmp -s "$MUT" "$SCRIPT"; then
  ok "the mutation applied (the find in list_escapes really changed)"
else
  no "the mutation did NOT apply — this case would prove nothing"
fi
out="$(ELIXIR_PATH_ESCAPE_ROOT="$REAL_ROOT" bash "$MUT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) when the api/test door goes blind"
else
  no "a scanner that lost api/test reported CLEAN — the exact origin/main defect"
fi
if has "$out" "idiom 'test-dir' resolved only 0 repo-root read"; then
  ok "names the blind door: test-dir"
else
  no "did not name the blind door: $out"
fi
if has "$out" "idiom 'test-cwd' resolved only 0 repo-root read"; then
  ok "names the blind door: test-cwd"
else
  no "did not name the blind door: $out"
fi
if has "$out" "SCANNER is broken, not the repo clean"; then
  ok "accuses the scanner, not the repository"
else
  no "wrong diagnosis: $out"
fi
# …and the surviving door is reported LIVE in the same breath, so the operator
# can see which half went dark instead of guessing.
if has "$out" "idiom lib-dir: "; then
  ok "still reports the surviving door's population"
else
  no "no per-idiom breakdown to diagnose from: $out"
fi
echo

# ── case 5c: a door with NO floor entry is an unguarded door ────────────────
# The floor table doubles as the idiom inventory. Widening list_escapes' `find`
# without adding a floor would ship a new door that nothing can catch going
# blind, so the tag it emits (`other-*`) must red on sight.
echo "case 5c: a scanner door with no floor entry reds"
MUT2="$TMPROOT/mutant-undeclared-door.sh"
sed 's|find api/lib api/test|find api/lib api/test scripts|' "$SCRIPT" >"$MUT2"
FX4="$TMPROOT/newdoor"
make_fixture "$FX4"
mkdir -p "$FX4/scripts"
cat >"$FX4/scripts/probe.exs" <<'EX'
  @a Path.expand("../design/status-manifest.json", __DIR__)
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX4" bash "$MUT2" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) when the scanner emits an undeclared idiom"
else
  no "an undeclared door shipped with no floor and the ratchet said OK"
fi
if has "$out" "has no entry in ELIXIR_ESCAPE_IDIOM_MIN"; then
  ok "names the unguarded door"
else
  no "did not name the unguarded door: $out"
fi
echo

# ── case 6: --match, the predicate elixir.yml actually dispatches on ────────
echo "case 6: --match agrees with the declared sets"
m() { "$SCRIPT" --match "$2" <<<"$1"; }
check_match() {
  local got
  got="$(m "$1" "$2")"
  if [ "$got" = "$3" ]; then
    ok "$2: '$1' -> $3"
  else
    no "$2: '$1' -> $got, wanted $3"
  fi
}
check_match "api/lib/barkpark.ex" compile true
check_match "design/status-manifest.json" compile true
check_match ".github/workflows/elixir.yml" compile true
check_match "scripts/elixir-path-escape-check.sh" compile true
check_match "docs/ops/merge-gates.md" compile false
check_match "docs/ops/merge-gates.md" test false
check_match "README.md" test false
check_match "web/src/app/page.tsx" test false
check_match "internal/taskboard/components.go" test true
check_match "internal/taskboard/components.go" compile false
check_match "internal/chat/testdata" test true
check_match "docs/openapi.json" test true
check_match "docs/api-v1.md" test true
check_match "docs/api/error-codes.md" test true
# exact-file entries must not match by prefix
check_match "docs/openapi.json.bak" test false
check_match "scripts/async_env_seam_scan.exs.orig" test false
# Every compile path is also a test path. The invariant belongs to the SETS,
# not to any `needs` edge between the jobs: compile ⊆ test must hold however
# the graph is wired. elixir.yml's dispatcher asserts it at runtime and hard-
# fails ("compile=true but test=…"), so a set edit that broke containment would
# deadlock every api/** PR rather than mis-dispatch one. Proven statically here
# so that failure lands in the harness instead of on a stranger's PR.
while IFS= read -r g; do
  [ -n "$g" ] || continue
  probe="${g%/\*\*}"
  case "$g" in */'**') probe="$probe/probe.txt" ;; esac
  check_match "$probe" test true
done <<EOF
$("$SCRIPT" --print-set compile)
EOF
echo

# ── case 7: a bad set name is an error, not a silent false ──────────────────
echo "case 7: an unknown set name errors"
out="$("$SCRIPT" --match nonsense <<<'api/x' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on an unknown set"; else no "unknown set returned '$out' instead of failing"; fi
out="$("$SCRIPT" --bogus-flag 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on an unknown flag"; else no "unknown flag silently accepted"; fi
echo

# ── case 8: elixir.yml's structural invariants ─────────────────────────────
# These are the ones a reviewer's eye slides over and a required-check spec
# cannot recover from. Asserted mechanically, against the real file.
echo "case 8: elixir.yml structural invariants"
WF="$REAL_ROOT/.github/workflows/elixir.yml"
if [ ! -f "$WF" ]; then
  no "elixir.yml not found at $WF"
else
  # Written to a file, not captured inline: bash 3.2 (macOS, and therefore the
  # local gate) mis-parses a heredoc inside a command substitution.
  #
  # The emitter itself is a FILE rather than an inline heredoc so the mutation
  # proof below can run the very same code over deliberately-broken copies of
  # elixir.yml. A detector that is never pointed at a broken input has not been
  # shown to detect anything.
  FACTS="$TMPROOT/elixir-yml-facts.txt"
  EMIT="$TMPROOT/emit-elixir-yml-facts.py"
  cat >"$EMIT" <<'PY'
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
out = open(sys.argv[2], "w")
on = wf.get(True, wf.get("on"))            # PyYAML parses bare `on:` as True
jobs = wf["jobs"]
def emit(k, v): out.write(f"{k}={v}\n")
# D18: a workflow-level paths filter deadlocks any required name pointing here.
emit("workflow_paths", any(
    isinstance(v, dict) and ("paths" in v or "paths-ignore" in v)
    for v in (on or {}).values()))
agg = jobs.get("elixir-gate", {})
emit("agg_present", bool(agg))
emit("agg_matrix", "strategy" in agg and "matrix" in agg.get("strategy", {}))
emit("agg_if", str(agg.get("if")).strip())
emit("agg_name", agg.get("name"))
emit("agg_needs", ",".join(agg.get("needs", [])))
# continue-on-error jobs must never appear in the aggregator's needs set:
# needs.<job>.result reads `success` for a FAILED continue-on-error job.
coe = [n for n, j in jobs.items() if j.get("continue-on-error") is True]
emit("coe_jobs", ",".join(sorted(coe)))
emit("coe_in_needs", ",".join(sorted(set(coe) & set(agg.get("needs", [])))))
# …and the mirror hazard, which the allow-set cannot see: a BLOCKING job added
# to elixir.yml but never wired into `needs`. The aggregator cannot judge a job
# nobody told it about, so it would green while that job is red.
blocking = {n for n, j in jobs.items()
            if j.get("continue-on-error") is not True and n != "elixir-gate"}
emit("blocking_not_in_needs", ",".join(sorted(blocking - set(agg.get("needs", [])))))
# D36 — THE OTHER HALF OF THAT GUARD. `blocking_not_in_needs` proves a job
# reached the aggregator's `needs`. Nothing proved the step body actually
# JUDGES it, and reaching `needs` alone changes nothing: `needs.<job>.result`
# is only consulted if the job is bound to a step env var AND that var is
# passed to `decide`. Measured: add a blocking job, wire it into `needs` and
# into `env:` as R_CEILING but omit its `decide` line, and every fact above is
# byte-identical to a clean tree while the real extracted step body greens at
# EXIT=0 with R_CEILING=failure. So walk the whole chain per job —
#   needs entry -> env var bound to needs.<job>.result -> decide's 2nd argument
# — and name every job that falls out of it. The decide side keys on the
# SECOND positional argument, which is label-independent: the first argument is
# a human label ("changes (dispatcher)") that deliberately does not match the
# job name, so matching on it would be a guard that reds on a rename.
agg_needs = list(agg.get("needs", []))
step = next((s for s in agg.get("steps", []) if "run" in s), {})
var_for = {}
for var, expr in (step.get("env") or {}).items():
    m = re.search(r"needs\.([A-Za-z0-9_.-]+)\.result", str(expr))
    if m:
        var_for[m.group(1)] = var
consumed = set(re.findall(
    r'^\s*decide\s+"[^"]*"\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"',
    step.get("run", ""), re.M))
emit("needs_without_decide",
     ",".join(sorted(j for j in agg_needs if var_for.get(j) not in consumed)))
# Companion cardinalities. An empty difference is only meaningful if the three
# sets it is computed from are populated: a regex that stops matching, or a
# `needs` list read as empty, would report a serene "" forever. These make a
# NEUTERED detector red instead of clean.
emit("needs_count", len(agg_needs))
emit("needs_results_count", len(var_for))
emit("decide_consumes_count", len(consumed))
# ── the allow-set guard never asserted decide()'s THIRD positional ─────────
# `consumed` above only proves a job's result reaches `decide` at all — not
# that it is judged against the RIGHT pole. `decide "path-escape ratchet"
# "${R_ESCAPE}" "${O_COMPILE}"` reaches `decide` exactly as easily as the
# correct "NEVER", and every fact above stays byte-identical between the two:
# `consumed`'s regex only ever captures the SECOND positional. So capture the
# THIRD too, derive what it SHOULD be from the job's own `if:`, and compare.
#
# Derivation: a job with no `if:` at all must be gated NEVER (it always runs,
# so a skip is never legitimate for it). A job whose `if:` is exactly
# `needs.changes.outputs.<X> == 'true'` must be gated on whichever env var the
# aggregator itself binds to `needs.changes.outputs.<X>`. Anything else — a
# compound `if:`, or one that does not reference a dispatcher output at all —
# cannot be derived, and MUST surface as an explicit mismatch rather than
# silently defaulting to NEVER: defaulting there would launder exactly the
# kind of job this guard exists to catch (one gated on something that is not
# a dispatcher output at all).
decide_calls = re.findall(
    r'^\s*decide\s+"([^"]*)"\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"\s+"([^"]*)"',
    step.get("run", ""), re.M)
emit("decide_gates_count", len(decide_calls))
result_var_to_job = {v: k for k, v in var_for.items()}
out_var_for = {}
for var, expr in (step.get("env") or {}).items():
    m = re.search(r"needs\.changes\.outputs\.([A-Za-z0-9_]+)", str(expr))
    if m:
        out_var_for[m.group(1)] = var
def expected_gate(job):
    if_expr = str(jobs.get(job, {}).get("if") or "").strip()
    if if_expr == "":
        return "NEVER"
    m = re.fullmatch(r"needs\.changes\.outputs\.([A-Za-z0-9_]+) == 'true'", if_expr)
    if m:
        var = out_var_for.get(m.group(1))
        if var:
            return "${%s}" % var
    return None   # unresolvable — never defaults to NEVER
mismatches = []
for label, second_var, third_val in decide_calls:
    job = result_var_to_job.get(second_var)
    if job is None:
        continue
    want = expected_gate(job)
    if want is None:
        mismatches.append("%s: if: %r is not a recognised dispatcher-output "
                           "guard, got gate=%s"
                           % (job, jobs.get(job, {}).get("if"), third_val))
    elif third_val != want:
        mismatches.append("%s: gate=%s want=%s" % (job, third_val, want))
emit("gate_mismatches", ",".join(mismatches))
disp = jobs.get("changes", {})
emit("dispatcher_if", str(disp.get("if", "")))
emit("dispatcher_matrix", "strategy" in disp)
emit("dispatcher_outputs", ",".join(sorted(disp.get("outputs", {}))))
esc = jobs.get("path-escape", {})
emit("escape_if", str(esc.get("if", "")))
emit("escape_needs", ",".join(esc.get("needs", [])))
for n in ("mix-test", "mix-prod-compile", "validation-perf"):
    emit(f"if::{n}", str(jobs.get(n, {}).get("if", "")))
out.close()
PY
  python3 "$EMIT" "$WF" "$FACTS"
  fact() { sed -n "s|^$1=||p" "$FACTS"; }
  assert_fact() {
    if [ "$(fact "$1")" = "$2" ]; then ok "$1 = $2"; else no "$1 = '$(fact "$1")', wanted '$2'"; fi
  }
  # A lower bound, never an equality: pinning the exact roster here would red
  # this harness the day a legitimate blocking job is added (S4's format
  # ceiling is the next one), which is churn, not safety. The bound only has
  # to exclude ZERO — the value a broken parser returns.
  assert_fact_min() {
    local got
    got="$(fact "$1")"
    case "$got" in
      '' | *[!0-9]*) no "$1 = '$got' — not a number, the emitter is broken" ;;
      *)
        if [ "$got" -ge "$2" ]; then ok "$1 = $got (>= $2)"; else
          no "$1 = $got, wanted >= $2 — the detector is neutered, not the tree clean"
        fi
        ;;
    esac
  }
  assert_fact workflow_paths False
  assert_fact agg_present True
  assert_fact agg_matrix False
  assert_fact agg_if "always()"
  assert_fact agg_name "Elixir gate"
  assert_fact coe_jobs format
  assert_fact coe_in_needs ""
  # Every blocking job must be in the aggregator's needs set. Without this, a
  # future slice (S4's format ceiling is the next one) can add a blocking job
  # and the required context stays green while that job reds — the aggregator's
  # one structural blind spot, closed here rather than left to a reviewer's eye.
  assert_fact blocking_not_in_needs ""
  # …and every job that IS in needs must actually be judged (D36). Empty means
  # every needs entry survives needs -> env -> decide. The three cardinalities
  # are the anti-vacuity companions: without them a detector that matched
  # nothing would report this same serene "".
  assert_fact needs_without_decide ""
  assert_fact_min needs_count 5
  assert_fact_min needs_results_count 5
  assert_fact_min decide_consumes_count 5
  assert_fact dispatcher_if ""
  assert_fact dispatcher_matrix False
  assert_fact dispatcher_outputs "compile,test"
  assert_fact escape_if ""
  assert_fact escape_needs ""
  assert_fact "if::mix-test" "needs.changes.outputs.test == 'true'"
  assert_fact "if::mix-prod-compile" "needs.changes.outputs.compile == 'true'"
  assert_fact "if::validation-perf" "needs.changes.outputs.compile == 'true'"
  # …and every decide() call's THIRD positional (the gate) matches what the
  # job's own `if:` says it should be. `needs_without_decide` above proves the
  # job's RESULT is judged; this proves it is judged against the RIGHT POLE —
  # a job silently gated NEVER (always accepted skipped) while its `if:` says
  # it only runs conditionally is invisible to every fact above it.
  assert_fact gate_mismatches ""
  assert_fact_min decide_gates_count 5

  # ── D36 mutation proof: the fifth fact must FIRE, and must go quiet ────────
  # Four deliberately-broken copies of the REAL elixir.yml, one per direction
  # the guard has to tell apart. This is the only thing separating a guard from
  # a decoration: `needs_without_decide = ""` above proves nothing unless the
  # same emitter, on the same file, returns a non-empty answer when the wiring
  # is genuinely broken. The mutation is the one measured in charter D36 — a
  # blocking `format-ceiling` job, added in three increasingly-complete stages.
  MUT="$TMPROOT/mutate-elixir-yml.py"
  cat >"$MUT" <<'PY'
import sys, yaml
src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
wf = yaml.safe_load(open(src))
agg = wf["jobs"]["elixir-gate"]
step = next(s for s in agg["steps"] if "run" in s)
MODES = ("clean", "needs", "env", "wired",
         "gate-mixtest-never", "gate-escape-compile", "gate-compound-if")
assert mode in MODES, mode   # a typo'd mode is not a pass
if mode in ("needs", "env", "wired"):
    # a BLOCKING job (no continue-on-error), wired into the aggregator's needs
    wf["jobs"]["format-ceiling"] = {"runs-on": "ubuntu-latest",
                                    "steps": [{"run": "exit 1"}]}
    agg["needs"] = list(agg["needs"]) + ["format-ceiling"]
if mode in ("env", "wired"):
    step.setdefault("env", {})["R_CEILING"] = "${{ needs.format-ceiling.result }}"
if mode == "wired":
    step["run"] = step["run"].replace(
        'decide "changes (dispatcher)"',
        'decide "format ceiling"         "${R_CEILING}" "NEVER"\n'
        'decide "changes (dispatcher)"', 1)
# ── the two directions the THIRD-positional guard exists to catch (D... this
#    slice) ──────────────────────────────────────────────────────────────
# MUT1: a job whose `if:` DOES gate it on a dispatcher output, mutated to the
# literal NEVER — the false-RED direction's mirror: it would now accept a skip
# that its own `if:` never licensed.
if mode == "gate-mixtest-never":
    step["run"] = step["run"].replace(
        'decide "mix-test"                "${R_TEST}"    "${O_TEST}"',
        'decide "mix-test"                "${R_TEST}"    "NEVER"', 1)
# MUT2: the unfiltered ratchet — gated NEVER because it has no `if:` at all —
# mutated onto a dispatcher output. This is the false-GREEN this slice exists
# for: measured on origin/main, it passes the pre-fix harness 101/101 while a
# docs-only PR would then legitimately skip a job that must never skip.
if mode == "gate-escape-compile":
    step["run"] = step["run"].replace(
        'decide "path-escape ratchet"     "${R_ESCAPE}"  "NEVER"',
        'decide "path-escape ratchet"     "${R_ESCAPE}"  "${O_COMPILE}"', 1)
# a job gated on a COMPOUND if: (references a dispatcher output but is not
# exactly `needs.changes.outputs.X == 'true'`) must be an explicit mismatch,
# never a silent default to NEVER — the derivation cannot tell what pole a
# compound condition implies, so it must say so rather than guess.
if mode == "gate-compound-if":
    wf["jobs"]["compound-job"] = {
        "runs-on": "ubuntu-latest",
        "if": "needs.changes.outputs.test == 'true' && github.actor != 'nobody'",
        "steps": [{"run": "exit 0"}],
    }
    agg["needs"] = list(agg["needs"]) + ["compound-job"]
    step.setdefault("env", {})["R_COMPOUND"] = "${{ needs.compound-job.result }}"
    step["run"] = step["run"].replace(
        'decide "changes (dispatcher)"',
        'decide "compound job"           "${R_COMPOUND}" "${O_TEST}"\n'
        'decide "changes (dispatcher)"', 1)
yaml.safe_dump(wf, open(dst, "w"))
PY
  # direction <mode> <expected needs_without_decide>
  direction() {
    local mode="$1" want="$2" f="$TMPROOT/mut-$1.yml" ff="$TMPROOT/mut-$1.facts" got
    # `clean` goes through the same load/dump round-trip as the three broken
    # copies, so the ONLY variable between the four is the mutation itself —
    # not a YAML-dumper artefact.
    python3 "$MUT" "$WF" "$f" "$mode"
    python3 "$EMIT" "$f" "$ff"
    got="$(sed -n 's|^needs_without_decide=||p' "$ff")"
    if [ "$got" = "$want" ]; then
      ok "  mutation[$mode]: needs_without_decide = '${got}'"
    else
      no "  mutation[$mode]: needs_without_decide = '${got}', wanted '${want}'"
    fi
  }
  direction clean ""                             # untouched tree — silent
  direction needs "format-ceiling"               # in needs, no env binding
  direction env   "format-ceiling"               # in needs + env, never decided
  direction wired ""                             # fully wired — silent again

  # ── mutation proof for gate_mismatches, BOTH directions + the third case ──
  # direction_gate <mode> <fact-must-contain>
  direction_gate() {
    local mode="$1" want_substr="$2" f="$TMPROOT/mut-$1.yml" ff="$TMPROOT/mut-$1.facts" got
    python3 "$MUT" "$WF" "$f" "$mode"
    python3 "$EMIT" "$f" "$ff"
    got="$(sed -n 's|^gate_mismatches=||p' "$ff")"
    if has "$got" "$want_substr"; then
      ok "  mutation[$mode]: gate_mismatches names it ($got)"
    else
      no "  mutation[$mode]: gate_mismatches = '${got}', wanted to contain '${want_substr}'"
    fi
  }
  # a clean tree must report no mismatches even after the round-trip
  ff="$TMPROOT/mut-clean.facts"
  got="$(sed -n 's|^gate_mismatches=||p' "$ff")"
  if [ "$got" = "" ]; then
    ok "  mutation[clean]: gate_mismatches = ''"
  else
    no "  mutation[clean]: gate_mismatches = '${got}', wanted ''"
  fi
  # MUT1: mix-test's gate mutated to the literal NEVER — its `if:` says
  # otherwise, so this must be reported as got=NEVER want=${O_TEST}.
  direction_gate gate-mixtest-never "mix-test: gate=NEVER want=\${O_TEST}"
  # MUT2: path-escape's gate mutated onto the compile output — it has no
  # `if:` at all, so this must be reported as got=${O_COMPILE} want=NEVER.
  direction_gate gate-escape-compile 'path-escape: gate=${O_COMPILE} want=NEVER'
  # a compound `if:` cannot be derived and must be an EXPLICIT mismatch, not a
  # silent default to NEVER.
  direction_gate gate-compound-if "compound-job: if:"
fi
echo

# ── case 9: the aggregator's allow-set, driven by mutation ─────────────────
# The step body is EXTRACTED FROM elixir.yml and executed, so this cannot
# drift from what CI runs (charter D26: a harness must execute the step body,
# not a paraphrase of it). Each case supplies exactly the env GitHub would.
echo "case 9: the aggregator decides, and can be made red on purpose"
AGG="$TMPROOT/elixir-gate-step.sh"
python3 - "$WF" "$AGG" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = [s for s in wf["jobs"]["elixir-gate"]["steps"] if "run" in s][0]
open(sys.argv[2], "w").write(step["run"])
PY

# gate <label> <expected-rc> KEY=VAL...
#
# The step's output lands in $GATE_OUT, never on stdout: a `gate` call wrapped
# in `$( … )` would run its ok/no in a SUBSHELL and silently lose the counter —
# a pass that proves nothing, which is the exact defect class this epic exists
# to remove. Follow-up assertions read the file.
GATE_OUT="$TMPROOT/gate.out"
gate() {
  local label="$1" want="$2"
  shift 2
  local rc
  env -i PATH="$PATH" HOME="$HOME" "$@" bash --noprofile --norc "$AGG" >"$GATE_OUT" 2>&1 && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "$label -> exit $rc"
  else
    no "$label -> exit $rc, wanted $want"
    sed 's/^/        /' "$GATE_OUT" >&2
  fi
  # The exit code ALONE is not a verdict. Eight of the ten cases below expect
  # exit 1 — and a step body that never decided anything exits 1 too: an
  # unbound variable under `set -u`, a syntax error, a `decide` that was
  # renamed out from under its call sites. Every one of those would have read
  # as `ok` here while proving nothing about the allow-set. So also require the
  # aggregator to have reached its own conclusion, in the polarity expected.
  local verdict
  if [ "$want" -eq 0 ]; then
    verdict="Elixir gate: every upstream job either succeeded"
  else
    verdict="::error::Elixir gate: at least one upstream job is not in the allow-set"
  fi
  if grep -qF -- "$verdict" "$GATE_OUT"; then
    ok "  …and reached its own verdict line"
  else
    no "  …but printed NO verdict line — the step body crashed rather than decided"
    sed 's/^/        /' "$GATE_OUT" >&2
  fi
}
gate_says() {
  if grep -q -- "$1" "$GATE_OUT"; then ok "$2"; else no "$2 (not in the step output)"; fi
}
# gate_names <must-name> <must-not-name> — D770/D771.
#
# `gate_says` reads the whole step OUTPUT, which has always named the failing
# job in its log. This reads the `::error::` ANNOTATION ONLY — the single line
# the check-run API carries, and therefore the only line a human at the merge
# button or the merge queue ever sees. Until this slice that line said "at least
# one upstream job" and stopped.
#
# It is a PAIR by construction: naming the job that failed is worth nothing on
# its own (a hardcoded sentence satisfies it), so the same call also refuses an
# annotation that names a job which PASSED in this very run.
gate_names() {
  local ann named
  ann="$(grep '^::error' "$GATE_OUT" | tr '\n' ' ')"
  named="${ann#*NOT IN THE ALLOW-SET: }"
  if [ -z "$ann" ] || [ "$named" = "$ann" ]; then
    no "  …but the annotation names no job at all: ${ann:-<no ::error:: line>}"
    return 0
  fi
  case "$named" in
    *"$1"*) ok "  …and the annotation names the refusing '$1'" ;;
    *) no "  …but the annotation never named the refusing '$1': $ann" ;;
  esac
  case "$named" in
    *"$2"*) no "  …and it names '$2', which PASSED in this run: $ann" ;;
    *) ok "  …and does not name the passing '$2'" ;;
  esac
}

# (a) the happy path: a full api/** PR, everything ran and passed
gate "full run, all green" 0 \
  R_CHANGES=success R_TEST=success R_PROD=success R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true

# (b) a legitimate docs-only skip greens the required context
gate "docs-only PR, expensive jobs legitimately skipped" 0 \
  R_CHANGES=success R_TEST=skipped R_PROD=skipped R_PERF=skipped R_ESCAPE=success \
  O_COMPILE=false O_TEST=false
gate_says "legitimately not dispatched" "…and says so, rather than claiming the suite passed"

# (c) an upstream FAILURE reds it
gate "mix-test failed" 1 \
  R_CHANGES=success R_TEST=failure R_PROD=skipped R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true
gate_names "mix-test" "validation-perf"

# (d) THE BYPASS THIS SLICE EXISTS TO CLOSE: prod-compile `skipped` only
#     because its dependency died, while the dispatcher said it WAS needed.
gate "prod-compile skipped behind a live gate (upstream died)" 1 \
  R_CHANGES=success R_TEST=success R_PROD=skipped R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true
gate_says "its gate is 'true', not 'false'" "…and names the reason (a skip is not a pass)"
# …and the SKIP arm accumulates too, not just the failure arm: this red never
# passes through `failure`, so an accumulator wired only there would leave the
# annotation contentless on exactly the bypass this shape exists to close.
gate_names "mix-prod-compile" "mix-test"

# (e) the dispatcher itself failing reds it, with empty outputs
gate "dispatcher failed, outputs empty" 1 \
  R_CHANGES=failure R_TEST=skipped R_PROD=skipped R_PERF=skipped R_ESCAPE=success \
  O_COMPILE= O_TEST=

# (f) the unfiltered ratchet may never skip
gate "path-escape skipped" 1 \
  R_CHANGES=success R_TEST=success R_PROD=success R_PERF=success R_ESCAPE=skipped \
  O_COMPILE=true O_TEST=true

# (g) cancelled is not success
gate "a cancelled upstream" 1 \
  R_CHANGES=success R_TEST=cancelled R_PROD=skipped R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true
gate_says "CANCELLED — this job did not fail" "…and the step log names CANCELLATION (the D57 arm), not a generic failure"
gate_names "mix-test (cancelled, not failed)" "validation-perf"

# (h) anything unrecognised is red — "cannot tell" is a failure, not a pass
gate "an unrecognised result value" 1 \
  R_CHANGES=success R_TEST=neutral R_PROD=success R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true

# (i) an EMPTY result (a job silently dropped from `needs`) is red
gate "an empty result string" 1 \
  R_CHANGES=success R_TEST= R_PROD=success R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true

# (j) a garbage gate value must not license a skip
gate "skip against a garbage gate value" 1 \
  R_CHANGES=success R_TEST=skipped R_PROD=skipped R_PERF=skipped R_ESCAPE=success \
  O_COMPILE=maybe O_TEST=maybe

# (k) the aggregator's own step body must be able to fail. If the extracted
#     script were empty or unparseable every case above would "pass" at exit 0
#     for the wrong reason — so assert it produced a real verdict line.
if [ -s "$AGG" ] && grep -q "unrecognised result" "$AGG"; then
  ok "the extracted step body is the real one (non-empty, carries the allow-set)"
else
  no "extracted an empty or wrong step body — every case above proved nothing"
fi
echo

# ── case 10: the dispatcher, driven against a real git repo ────────────────
# Same extraction discipline as case 9. The two `${{ … }}` expressions are
# substituted from the environment so the body can run outside Actions.
echo "case 10: the dispatcher fails rather than skips when it cannot tell"
DISP="$TMPROOT/dispatch-step.sh"
python3 - "$WF" "$DISP" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = [s for s in wf["jobs"]["changes"]["steps"] if s.get("id") == "sets"][0]
body = (step["run"]
        .replace("${{ github.event_name }}", "${T_EVENT}")
        .replace("${{ github.event.pull_request.base.sha }}", "${T_BASE}"))
open(sys.argv[2], "w").write(body)
PY

DR="$TMPROOT/dispatchrepo"
mkdir -p "$DR/api/lib" "$DR/docs" "$DR/internal/taskboard" "$DR/scripts"
cp "$SCRIPT" "$REAL_ROOT/scripts/elixir-path-escape-check.test.sh" "$DR/scripts/"
: >"$DR/api/lib/a.ex"
# NON-EMPTY on purpose: the rename cases below need git's rename detection to
# actually fire, and an empty blob is not a rename source worth the name.
printf 'moved-a\nmoved-b\nmoved-c\n' >"$DR/api/lib/moved.ex"
: >"$DR/docs/guide.md"
: >"$DR/internal/taskboard/components.go"
git -C "$DR" init -q
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
BASE_SHA="$(git -C "$DR" rev-parse HEAD)"

# dispatch <label> <expected-rc> <expected-compile> <expected-test> <event> <base>
dispatch() {
  local label="$1" want="$2" wc="$3" wt="$4" ev="$5" bs="$6"
  local rc gotc gott
  : >"$TMPROOT/gh_output"
  (cd "$DR" && env T_EVENT="$ev" T_BASE="$bs" GITHUB_OUTPUT="$TMPROOT/gh_output" \
    bash --noprofile --norc "$DISP") >"$GATE_OUT" 2>&1 && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "$label -> exit $rc"
  else
    no "$label -> exit $rc, wanted $want"
    sed 's/^/        /' "$GATE_OUT" >&2
    return 0
  fi
  # A bare `return` here would propagate the test's exit status and, under
  # `set -e`, abort the whole harness mid-run — silently truncating the
  # remaining cases into an apparent pass.
  [ "$want" -eq 0 ] || return 0
  gotc="$(sed -n 's/^compile=//p' "$TMPROOT/gh_output")"
  gott="$(sed -n 's/^test=//p' "$TMPROOT/gh_output")"
  if [ "$gotc" = "$wc" ] && [ "$gott" = "$wt" ]; then
    ok "  …emits compile=$gotc test=$gott"
  else
    no "  …emitted compile=$gotc test=$gott, wanted compile=$wc test=$wt"
  fi
}

# a docs-only PR is the whole point of the shim: skip the suite, honestly
git -C "$DR" checkout -q -b docs-only
: >"$DR/docs/another.md"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm docs >/dev/null 2>&1
dispatch "docs-only PR" 0 false false pull_request "$BASE_SHA"

# a Go glyph-table change selects the TEST set but not the compile set — the
# family the obvious `api/**` filter silently drops (charter D31)
git -C "$DR" checkout -q -b taskboard "$BASE_SHA"
printf 'x\n' >"$DR/internal/taskboard/components.go"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm glyphs >/dev/null 2>&1
dispatch "internal/taskboard-only PR" 0 false true pull_request "$BASE_SHA"

# an api/** change selects everything
git -C "$DR" checkout -q -b apichange "$BASE_SHA"
printf 'x\n' >"$DR/api/lib/a.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm api >/dev/null 2>&1
dispatch "api/** PR" 0 true true pull_request "$BASE_SHA"

# push to main never skips, regardless of what changed
dispatch "push event" 0 true true push ""

# ── THE FIVE FALSE-GREEN CLASSES the plain `--name-only` producer let through ─
# Every probe above this line is ASCII and rename-free, which is exactly why the
# harness could never have caught either family — and `Elixir gate` is a
# REGISTERED, enforced-today required context, so a false `compile=false
# test=false` here skips the whole suite under a green check. `git diff
# --name-only` QUOTES a path containing `"` (even under core.quotepath=false),
# and rename detection prints only the DESTINATION. Both classify FALSE on the
# pre-fix line.

# (1) a DOUBLE-QUOTE path inside the declared set. Not merely a non-ASCII one:
#     core.quotepath=false silences the octal escaping and leaves this class
#     wide open, so a fix tested only against é would certify a hole.
git -C "$DR" checkout -q -b dquote "$BASE_SHA"
printf 'x\n' >"$DR/api/lib/we\"ird.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm dquote >/dev/null 2>&1
dispatch 'a path containing a double quote' 0 true true pull_request "$BASE_SHA"

# (2) a rename OUT of the declared set. Compiled code just left api/** — the
#     suite MUST run — but rename detection names only docs/.
git -C "$DR" checkout -q -b renameout "$BASE_SHA"
git -C "$DR" mv api/lib/moved.ex docs/moved.ex >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm renameout >/dev/null 2>&1
dispatch "a rename OUT of the declared set" 0 true true pull_request "$BASE_SHA"

# (3) …and a rename INTO the set still classifies true — `--no-renames` prints
#     BOTH sides, so closing (2) must not have cost the obvious direction.
git -C "$DR" checkout -q -b renamein "$BASE_SHA"
git -C "$DR" mv docs/guide.md api/lib/guide.md >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm renamein >/dev/null 2>&1
dispatch "a rename INTO the declared set" 0 true true pull_request "$BASE_SHA"

# THE FAILURE PATHS — the polarity that makes the shim safe.
# An empty diff is the ONE "cannot tell" that does not fail: a revert pair or a
# branch-sync PR nets to nothing and is perfectly legal, and the old ::error::
# left its author with a permanently red required context and no self-service
# fix. It dispatches TRUE — the full suite, measured 9m31s-16m29s: expensive,
# never wrong. Everything else still reds.
git -C "$DR" checkout -q -b emptydiff "$BASE_SHA"
dispatch "empty diff (base == HEAD)" 0 true true pull_request "$(git -C "$DR" rev-parse HEAD)"
gate_says "changed-file set is EMPTY" "  …and names the shape"
gate_says "::warning" "  …as a WARNING, not a brick"
gate_says "9m31s-16m29s" "  …and names the cost it just chose to pay"
dispatch "unresolvable base sha" 1 - - pull_request 0000000000000000000000000000000000000000
gate_says "not resolvable in this checkout" "  …and refuses to guess a base"
dispatch "missing base sha" 1 - - pull_request ""
gate_says "carries no base sha" "  …and says why"

# a base with NO common ancestor: `git diff base...HEAD` exits 128 with a bare
# `fatal: … no merge base` and zero annotation. Named, not fatalled.
git -C "$DR" checkout -q --orphan noancestor >/dev/null 2>&1
git -C "$DR" rm -rq --cached . >/dev/null 2>&1 || true
rm -rf "${DR:?}/api" "${DR:?}/docs" "${DR:?}/internal"
mkdir -p "$DR/api/lib"
printf 'z\n' >"$DR/api/lib/orphan.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm orphan >/dev/null 2>&1
dispatch "a base with no common ancestor" 1 - - pull_request "$BASE_SHA"
gate_says "share NO common ancestor" "  …and names the condition, not a raw git fatal"
gate_says "refusing a two-dot fallback" "  …and refuses the fallback that sweeps in the whole base"
echo

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
