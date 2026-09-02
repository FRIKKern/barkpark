#!/usr/bin/env bash
# main-run-concurrency-check.sh — a MAIN run of a gate workflow must never be
# EVICTED by the next merge.
#
# THE DEFECT THIS FORBIDS, measured 2026-09-02 on main. elixir.yml and
# doc-gates.yml carried
#
#     concurrency:
#       group: <name>-${{ github.ref }}
#       cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
#
# never-cancel-main is honoured (a RUNNING main run is not killed) — but the
# group is per REF, so every push to main is a rival for one slot, and GitHub
# keeps exactly ONE not-yet-started run per group. Under merge cadence each
# merge evicts the pending main run before a runner picks it up: since 10:27Z,
# 40 main elixir runs, 37 cancelled, 1 completed. No main verdict existed to
# cite for the whole storm, and every ledger criterion that asks for a main-run
# log was starved. deploy.yml had the same shape until #15068.
#
# THE PROPERTY (the deploy gate's two halves, re-cut for a workflow that ALSO
# runs on pull requests, where superseding IS wanted):
#   (a) the group must vary by push sha ON MAIN — an expression that mentions
#       github.sha under a refs/heads/main condition — so two merges are never
#       rivals; PR refs may keep a per-ref group so a newer push supersedes;
#   (b) cancel-in-progress must be the literal boolean false OR the exact
#       never-cancel-main guard `${{ github.ref != 'refs/heads/main' }}` — the
#       shape scripts/never-cancel-main-check.sh accepts. A bare `true` would
#       cancel a running main run and is refused here as it is there.
#
# EXIT CODES
#   0  no main run of the targets can be evicted
#   1  FINDING — one can; the reason is named
#   2  CANNOT MEASURE — no python3/PyYAML, a missing target, no concurrency
#      block, or a bad flag. Never a vacuous green.
#
# HOW THE TARGET SET IS CHOSEN — and why it is no longer a list.
#
# The first cut of this gate hardcoded
#     TARGETS=".github/workflows/elixir.yml .github/workflows/doc-gates.yml"
# — the two files the fix that shipped it happened to touch. It then printed
# "2 workflow(s) keep one group per main sha" and exited 0 while
# go-tests.yml sat on main with the exact pre-fix stanza: MEASURED 2026-09-02,
# 13 of main go-tests last 20 runs cancelled, 5 failed, 2 succeeded. A gate
# whose corpus is a hand-written list cannot grow with the problem, and its
# green says only "the files I was told about are fine".
#
# So the corpus is DISCOVERED from the tree: every .github/workflows/*.yml that
# BOTH declares a top-level concurrency mapping AND triggers on a push to main
# (the same over-approximating branch reader scripts/never-cancel-main-check.sh
# uses: no branches filter, a glob, or a branches-ignore that spares main all
# count). A workflow with no concurrency block is not a target at all — with no
# group there is nothing to be evicted from.
#
# THE GRANDFATHER LEDGER, and why it is safe. Discovery found 35 evictable
# workflows on main, not one. Fixing all of them is a mechanical sweep, not this
# gate. GRANDFATHERED below names the ones known-evictable when discovery landed
# so this gate can be GREEN and HONEST at the same time — and it is a RATCHET,
# not an allowlist that grows:
#   * a discovered workflow NOT in the ledger and not per-sha-on-main is a hard
#     FAIL. A newly added main-triggered workflow with a bare per-ref group reds
#     here with nobody editing this gate. That is the property the hardcoded
#     list did not have.
#   * an entry in the ledger that IS now per-sha-on-main is ALSO a FAIL, with
#     the instruction to delete the line. The ledger can therefore only ever get
#     SHORTER; it cannot rot into a blanket waiver.
# The acceptance for retiring this ledger is an EMPTY list, not a longer one.
#
# USAGE
#   bash scripts/main-run-concurrency-check.sh
#   bash scripts/main-run-concurrency-check.sh --selftest
#   MAIN_CONCURRENCY_TARGETS="<file> <file>" bash scripts/main-run-concurrency-check.sh
#
# MAIN_CONCURRENCY_TARGETS pins an EXPLICIT corpus and disables discovery (and
# with it the ledger: an explicitly named file is judged on the shape alone).
# It exists so scripts/deploy-concurrency-check.test.sh (PART C) and --selftest
# can drive this end-to-end against planted fixtures, including a verbatim copy
# of the pre-fix stanza, which must red. MAIN_CONCURRENCY_ROOT overrides the
# discovery directory for the same reason. CI leaves both unset.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
  echo "main-run-concurrency-check: unknown argument '$1' (expected nothing or --selftest)" >&2
  echo "  point it at other files with MAIN_CONCURRENCY_TARGETS=\"<path> <path>\"." >&2
  exit 2
fi

# THE GRANDFATHER LEDGER — one basename per line, known-evictable when discovery
# landed (2026-09-02). SHRINK ONLY: fix a workflow, delete its line. Adding a
# line to silence a NEW workflow defeats the gate; fix the workflow instead.
GRANDFATHERED="$(cat <<'LEDGER'
astro-finder-drift.yml
astro-search-finder-test.yml
bp-graph-drift.yml
breakglass-watch.yml
ci.yml
cli-release.yml
cloud.yml
compose-smoke.yml
connectors.yml
console-harness.yml
create-quickstart-smoke.yml
crown-reconcile.yml
deploy.yml
grip-suite.yml
hundesteder.yml
js-tests.yml
landed-mark.yml
mobile.yml
paper-editor.yml
pdrender-wasm.yml
plugin-node.yml
pr-meta.yml
release-artifact.yml
release.yml
required-checks-drift.yml
research-coverage-suite.yml
scaffy-catalog-drift.yml
sdk-tests.yml
search-starter-smoke.yml
sheet-grid-js.yml
shell-harnesses.yml
stale-verdict-watch.yml
studio-journey-smoke.yml
web-fork-drift.yml
windows-smoke.yml
LEDGER
)"
# deploy.yml and landed-mark.yml are listed for a DIFFERENT reason than the
# rest: both already vary their group by github.sha (deploy.yml under an
# event_name == push condition, landed-mark.yml unconditionally), so neither can
# be evicted on main. They are named here only because the shape rule below
# demands the sha be reached under an explicit refs/heads/main condition — the
# deliberate C5 decision in deploy-concurrency-check.test.sh, which refuses a
# per-sha group that ALSO applies to PR refs. deploy.yml additionally has its
# own dedicated gate, scripts/deploy-concurrency-check.sh.

# discover — prints the workflow paths this gate judges, one per line.
discover() {
  python3 - "$1" <<'PY'
import sys, glob, os, fnmatch

try:
    import yaml
except ImportError:
    print("HARNESS-UNAVAILABLE: PyYAML not importable; this is NOT a verdict on the workflows")
    sys.exit(2)


def triggers_push_to_main(on):
    # Same over-approximation as scripts/never-cancel-main-check.sh: a push with
    # no branches filter, a glob that selects main, or a branches-ignore that
    # does not name main all fire on main.
    if not isinstance(on, dict):
        if on == "push":
            return True
        return isinstance(on, list) and "push" in on
    if "push" not in on:
        return False
    push = on["push"]
    if not isinstance(push, dict):
        return True

    def as_list(v):
        if isinstance(v, str):
            return [v]
        return v if isinstance(v, list) else []

    branches = as_list(push.get("branches"))
    ignore = as_list(push.get("branches-ignore"))
    if branches:
        return any(fnmatch.fnmatch("main", str(p)) for p in branches)
    if ignore:
        return not any(fnmatch.fnmatch("main", str(p)) for p in ignore)
    return True


root = sys.argv[1]
paths = sorted(glob.glob(os.path.join(root, "*.yml")) + glob.glob(os.path.join(root, "*.yaml")))
for path in paths:
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:
        print("HARNESS-UNAVAILABLE: %s did not parse as YAML: %s" % (path, exc))
        sys.exit(2)
    if not isinstance(doc, dict):
        continue
    # YAML 1.1 resolves a bare `on:` key to boolean True; accept both forms.
    on = doc.get("on", doc.get(True))
    # No concurrency block means no group, so nothing can be evicted from one.
    if not isinstance(doc.get("concurrency"), dict):
        continue
    if triggers_push_to_main(on):
        print(path)
PY
}

# NO APOSTROPHES OR BACKTICKS IN THE PYTHON BLOCK (bash 3.2 heredoc-in-subst).
scan() {
  python3 - "$1" <<'PY'
import sys

try:
    import yaml
except ImportError:
    print("HARNESS-UNAVAILABLE: PyYAML not importable; this is NOT a verdict on the workflow")
    sys.exit(2)

path = sys.argv[1]
try:
    with open(path) as fh:
        doc = yaml.safe_load(fh)
except Exception as exc:
    print("HARNESS-UNAVAILABLE: %s did not parse as YAML: %s" % (path, exc))
    sys.exit(2)
if not isinstance(doc, dict):
    print("HARNESS-UNAVAILABLE: %s is not a YAML mapping" % path)
    sys.exit(2)

conc = doc.get("concurrency")
if conc is None:
    print("HARNESS-UNAVAILABLE: %s declares no top-level concurrency block" % path)
    sys.exit(2)
if not isinstance(conc, dict):
    print("HARNESS-UNAVAILABLE: %s concurrency is not a mapping (shorthand string form)" % path)
    sys.exit(2)
group = conc.get("group")
if not isinstance(group, str) or not group.strip():
    print("HARNESS-UNAVAILABLE: %s concurrency.group is missing or not a string" % path)
    sys.exit(2)
cip = conc.get("cancel-in-progress", False)

GUARD = "${{ github.ref != 'refs/heads/main' }}".replace("'", chr(39))
findings = []
if "github.sha" not in group or "refs/heads/main" not in group:
    findings.append(
        "concurrency.group %r is not per push sha on main. GitHub keeps ONE "
        "not-yet-started run per group, so under merge cadence each merge evicts "
        "the pending main run before a runner picks it up (measured 2026-09-02: "
        "37 of 40 main runs cancelled). Expected an expression mentioning "
        "github.sha under a refs/heads/main condition." % group
    )
if cip is not False and (not isinstance(cip, str) or cip.strip() != GUARD):
    findings.append(
        "concurrency.cancel-in-progress is %r, neither the literal false nor the "
        "never-cancel-main guard %r; a bare true cancels a RUNNING main run."
        % (cip, GUARD)
    )

print("target: %s" % path)
print("group: %s" % group)
print("cancel-in-progress: %r" % (cip,))
for f in findings:
    print("FAIL " + f)
if not findings:
    print("OK a queued main run cannot be evicted, and a running one cannot be cancelled")
PY
}

in_ledger() {
  grep -qx -- "$1" <<<"$GRANDFATHERED"
}

# run_gate — the whole verdict, factored out so --selftest can re-exec this
# script end-to-end (a selftest that only asserts on scan() text certifies
# nothing about the branch that turns text into an exit code).
run_gate() {
  local TARGETS MODE ROOT
  if [ -n "${MAIN_CONCURRENCY_TARGETS:-}" ]; then
    MODE=explicit
    TARGETS="$MAIN_CONCURRENCY_TARGETS"
  else
    MODE=discovery
    ROOT="${MAIN_CONCURRENCY_ROOT:-.github/workflows}"
    if [ ! -d "$ROOT" ]; then
      echo "main-run-concurrency gate could not RUN: discovery root '$ROOT' is not a directory — this is NOT a verdict." >&2
      exit 2
    fi
    # THE NON-EMPTY FLOOR. discover walks a glob: over a missing or empty
    # directory it prints nothing and exits 0, and the verdict below would then
    # report green over a corpus of zero files — a gate that certifies rather
    # than measures.
    local ROOT_COUNT
    ROOT_COUNT="$(find "$ROOT" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) -type f | wc -l | tr -d ' ')"
    if [ "$ROOT_COUNT" -eq 0 ]; then
      echo "main-run-concurrency gate could not RUN: discovery root '$ROOT' holds ZERO workflow files — refusing a green over an empty corpus." >&2
      exit 2
    fi
    local DISCOVER_STATUS=0
    TARGETS="$(discover "$ROOT")" || DISCOVER_STATUS=$?
    if [ "$DISCOVER_STATUS" -ne 0 ] || grep -q '^HARNESS-UNAVAILABLE' <<<"$TARGETS"; then
      echo "main-run-concurrency gate could not RUN: discovery failed (exit ${DISCOVER_STATUS}) — this is NOT a verdict." >&2
      echo "${TARGETS:-(the harness produced no output)}" >&2
      exit 2
    fi
  fi

  local RC=0 SEEN=0 CLEAN=0 GRAND=0 TARGET BASE SCAN_STATUS RESULT
  for TARGET in $TARGETS; do
    SEEN=$((SEEN + 1))
    BASE="$(basename "$TARGET")"
    if [ ! -f "$TARGET" ]; then
      echo "main-run-concurrency gate could not RUN: target '$TARGET' is not a file — this is NOT a verdict." >&2
      exit 2
    fi
    SCAN_STATUS=0
    RESULT="$(scan "$TARGET")" || SCAN_STATUS=$?
    if [ "$SCAN_STATUS" -ne 0 ] || grep -q '^HARNESS-UNAVAILABLE' <<<"$RESULT"; then
      echo "main-run-concurrency gate could not RUN on ${TARGET} (harness exit ${SCAN_STATUS}) — this is NOT a verdict." >&2
      echo "${RESULT:-(the harness produced no output)}" >&2
      exit 2
    fi
    if grep -q '^FAIL ' <<<"$RESULT"; then
      if [ "$MODE" = discovery ] && in_ledger "$BASE"; then
        GRAND=$((GRAND + 1))
        echo "GRANDFATHERED ${BASE}: evictable on main, known debt — see the ledger in $0"
        continue
      fi
      echo "$RESULT"
      RC=1
    else
      # RATCHET: a ledger entry that is now correct must be DELETED, or the
      # ledger becomes a blanket waiver nobody re-reads.
      if [ "$MODE" = discovery ] && in_ledger "$BASE"; then
        echo "FAIL ${BASE} is per-sha on main now, but is still named in the GRANDFATHERED ledger. Delete that line: the ledger shrinks, never grows." >&2
        RC=1
        continue
      fi
      CLEAN=$((CLEAN + 1))
    fi
  done

  if [ "$SEEN" -eq 0 ]; then
    echo "main-run-concurrency gate could not RUN: no targets — an empty scan is not a pass." >&2
    exit 2
  fi

  if [ "$RC" -ne 0 ]; then
    echo "" >&2
    echo "main-run-concurrency gate FAILED — a main run of a gate workflow can be evicted by the next merge." >&2
    echo "Fix, in the workflow:" >&2
    echo "    concurrency:" >&2
    # shellcheck disable=SC2016  # literal prose, not substitution
    echo '      group: <name>-${{ github.ref == '"'"'refs/heads/main'"'"' && github.sha || github.ref }}' >&2
    # shellcheck disable=SC2016
    echo '      cancel-in-progress: ${{ github.ref != '"'"'refs/heads/main'"'"' }}' >&2
    exit 1
  fi
  if [ "$MODE" = discovery ]; then
    echo "main-run-concurrency gate OK — ${SEEN} main-triggered workflow(s) with a concurrency block discovered: ${CLEAN} keep one group per main sha and never cancel main, ${GRAND} grandfathered as known debt."
  else
    echo "main-run-concurrency gate OK — ${SEEN} workflow(s) keep one group per main sha and never cancel main."
  fi
}

SELFTEST_TMP=""
cleanup_selftest() { [ -n "$SELFTEST_TMP" ] && rm -rf "$SELFTEST_TMP"; return 0; }
trap cleanup_selftest EXIT

# --selftest proves this gate is ABLE TO FAIL on the thing it now measures:
# DISCOVERY. Every arm drives the whole script against a fixture root, so a
# disarm of the verdict wiring reds here. It plants nothing in the tree.
selftest() {
  SELFTEST_TMP="$(mktemp -d)"
  local tmp="$SELFTEST_TMP" pass=0 fail=0 rc out
  ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
  bad() { fail=$((fail + 1)); echo "  FAIL $1" >&2; [ -n "${2:-}" ] && echo "       $2" >&2; return 0; }

  write_wf() {
    # write_wf <dir> <name> <group> <cancel-in-progress> [<on-block>]
    local dir="$1" name="$2" group="$3" cip="$4" on="${5:-}"
    mkdir -p "$dir"
    {
      echo "name: ${name%.yml}"
      if [ -n "$on" ]; then printf '%s\n' "$on"; else
        echo "on:"
        echo "  pull_request:"
        echo "  push:"
        echo "    branches: [main]"
      fi
      echo "concurrency:"
      echo "  group: $group"
      echo "  cancel-in-progress: $cip"
      echo "jobs:"
      echo "  x:"
      echo "    runs-on: ubuntu-latest"
      echo "    steps:"
      echo "      - run: true"
    } > "$dir/$name"
  }

  # NOTE ON QUOTING: these group strings carry ${{ }} verbatim into the YAML, so
  # they are written single-quoted and never expanded by bash.
  # shellcheck disable=SC2016  # ${{ }} is GitHub expression syntax written
  # verbatim into the fixture YAML; bash must NOT expand it.
  local PERREF='fixture-${{ github.ref }}'
  # shellcheck disable=SC2016
  local PERSHA='fixture-${{ github.ref == '"'"'refs/heads/main'"'"' && github.sha || github.ref }}'
  # shellcheck disable=SC2016
  local GUARD='${{ github.ref != '"'"'refs/heads/main'"'"' }}'

  # (1) THE ACCEPTANCE PROPERTY. A root holding one main-triggered workflow with
  #     a bare per-ref group must RED — and its name is NOT in GRANDFATHERED, so
  #     nobody edited this gate to make that happen. This is exactly the shape
  #     go-tests.yml carried while the hardcoded two-file corpus reported green.
  local d1="$tmp/r1"; write_wf "$d1" "brandnew.yml" "$PERREF" "$GUARD"
  rc=0; out="$(MAIN_CONCURRENCY_ROOT="$d1" bash "$0" 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ] && grep -q 'brandnew.yml' <<<"$out"; then
    ok "a discovered main workflow with a bare per-ref group REDS, naming the file"
  else
    bad "a discovered per-ref main workflow must red (rc=$rc)" "$(head -3 <<<"$out" | tr '\n' ' ')"
  fi

  # (2) THE OTHER DIRECTION. The per-sha form over the same root GREENS —
  #     without this arm a gate hard-wired to exit 1 would pass arm (1).
  local d2="$tmp/r2"; write_wf "$d2" "brandnew.yml" "$PERSHA" "$GUARD"
  rc=0; out="$(MAIN_CONCURRENCY_ROOT="$d2" bash "$0" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && grep -q '1 keep one group per main sha' <<<"$out"; then
    ok "the per-sha-on-main form GREENS, and the count says 1 was measured"
  else
    bad "the per-sha form must green with a real count (rc=$rc)" "$(head -3 <<<"$out" | tr '\n' ' ')"
  fi

  # (3) A pull_request-ONLY workflow is not discovered: it never runs on main,
  #     so it has nothing to be evicted. An empty corpus is rc 2, not a green.
  local d3="$tmp/r3"
  write_wf "$d3" "pronly.yml" "$PERREF" "true" "$(printf 'on:\n  pull_request:\n')"
  rc=0; out="$(MAIN_CONCURRENCY_ROOT="$d3" bash "$0" 2>&1)" || rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "a pull_request-only workflow is not a target (root yields nothing -> rc 2, never a vacuous green)"
  else
    bad "a PR-only root must be rc 2 (got rc=$rc)" "$(head -3 <<<"$out" | tr '\n' ' ')"
  fi

  # (4) A workflow with NO concurrency block is not a target either — no group,
  #     nothing to evict. Paired with a good one so the root is non-empty.
  local d4="$tmp/r4"; write_wf "$d4" "good.yml" "$PERSHA" "$GUARD"
  mkdir -p "$d4"
  printf 'name: noconc\non:\n  push:\n    branches: [main]\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' > "$d4/noconc.yml"
  rc=0; out="$(MAIN_CONCURRENCY_ROOT="$d4" bash "$0" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && grep -q '1 main-triggered workflow' <<<"$out"; then
    ok "a workflow with no concurrency block is skipped, not counted and not an rc-2 refusal"
  else
    bad "no-concurrency workflow must be skipped (rc=$rc)" "$(head -3 <<<"$out" | tr '\n' ' ')"
  fi

  # (5) A main-selecting shape that names no literal `main` branch is still
  #     discovered — the under-detection never-cancel-main-check.sh had to fix.
  local d5="$tmp/r5"
  write_wf "$d5" "nofilter.yml" "$PERREF" "$GUARD" "$(printf 'on:\n  push:\n')"
  rc=0; out="$(MAIN_CONCURRENCY_ROOT="$d5" bash "$0" 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ] && grep -q 'nofilter.yml' <<<"$out"; then
    ok "a bare 'push:' with no branches filter is discovered as main-triggered and REDS"
  else
    bad "an unfiltered push must be discovered (rc=$rc)" "$(head -3 <<<"$out" | tr '\n' ' ')"
  fi

  # (6) THE RATCHET. A ledger name that is per-sha now must red with "delete
  #     that line", so the ledger cannot rot into a blanket waiver.
  local d6="$tmp/r6"; write_wf "$d6" "ci.yml" "$PERSHA" "$GUARD"
  rc=0; out="$(MAIN_CONCURRENCY_ROOT="$d6" bash "$0" 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ] && grep -q 'still named in the GRANDFATHERED ledger' <<<"$out"; then
    ok "a fixed workflow still in the ledger REDS — the ledger can only shrink"
  else
    bad "the ledger ratchet must red on a fixed entry (rc=$rc)" "$(head -3 <<<"$out" | tr '\n' ' ')"
  fi

  # (7) A ledger name that is STILL evictable is tolerated, and says so out loud.
  local d7="$tmp/r7"; write_wf "$d7" "ci.yml" "$PERREF" "$GUARD"
  rc=0; out="$(MAIN_CONCURRENCY_ROOT="$d7" bash "$0" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && grep -q '^GRANDFATHERED ci.yml' <<<"$out"; then
    ok "a still-evictable ledger entry is reported as GRANDFATHERED, not silently dropped"
  else
    bad "a ledger entry must be reported, not hidden (rc=$rc)" "$(head -3 <<<"$out" | tr '\n' ' ')"
  fi

  # (8) MAIN_CONCURRENCY_TARGETS ignores the ledger: a file named explicitly is
  #     judged on shape alone, which is what PART C of
  #     deploy-concurrency-check.test.sh relies on.
  rc=0; out="$(MAIN_CONCURRENCY_TARGETS="$d7/ci.yml" bash "$0" 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ]; then
    ok "an explicitly targeted ledger name still REDS (explicit mode ignores the ledger)"
  else
    bad "explicit mode must ignore the ledger (rc=$rc)" "$(head -3 <<<"$out" | tr '\n' ' ')"
  fi

  # (9) A missing discovery root is a refusal, never a pass.
  rc=0; MAIN_CONCURRENCY_ROOT="$tmp/does-not-exist" bash "$0" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then ok "a MISSING discovery root is rc 2"; else bad "missing root must be rc 2 (got $rc)"; fi

  # (10) An EMPTY discovery root is a refusal too.
  mkdir -p "$tmp/empty"
  rc=0; MAIN_CONCURRENCY_ROOT="$tmp/empty" bash "$0" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then ok "an EMPTY discovery root is rc 2"; else bad "empty root must be rc 2 (got $rc)"; fi

  # (11) THE LIVE TREE. go-tests.yml must be among the discovered targets — the
  #      file the hardcoded corpus could not see. A discovery that silently
  #      stopped finding it would make this whole change vacuous.
  local live
  live="$(discover .github/workflows | xargs -n1 basename)"
  if grep -qx 'go-tests.yml' <<<"$live" && grep -qx 'elixir.yml' <<<"$live"; then
    ok "live discovery finds go-tests.yml and elixir.yml ($(grep -c . <<<"$live") targets)"
  else
    bad "live discovery must include go-tests.yml and elixir.yml"
  fi

  # (12) No ledger line names a file that does not exist — a rename would
  #      otherwise leave a dead waiver behind.
  local missing=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ -f ".github/workflows/$entry" ] || missing="$missing $entry"
  done <<<"$GRANDFATHERED"
  if [ -z "$missing" ]; then
    ok "every GRANDFATHERED entry names a workflow that exists"
  else
    bad "GRANDFATHERED names files that do not exist:$missing"
  fi

  echo ""
  printf 'main-run-concurrency-check --selftest: %d passed, %d failed\n' "$pass" "$fail"
  if [ "$pass" -eq 0 ]; then
    echo "HARNESS-UNAVAILABLE: zero selftest cases ran — a green over an empty matrix is not a verdict" >&2
    exit 2
  fi
  [ "$fail" -eq 0 ] || exit 1
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

run_gate
