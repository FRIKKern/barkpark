#!/usr/bin/env bash
# dependabot-roots-check.sh — the BOTH-DIRECTIONS drift gate over
# .github/dependabot.yml (task-c33fee1e82700787).
#
# THE PROBLEM THIS EXISTS FOR. A dependency-updater config is a hand-written
# list of directories that silently stops describing the repo the moment
# somebody adds a lockfile. Nothing in GitHub tells you: Dependabot updates the
# roots it was told about and says nothing about the ones it was not. A hole is
# INVISIBLE — the config is green, the PRs keep arriving for the roots it does
# know, and the new tree simply never ages into view. That is the exact shape
# the row behind this script was filed for, one level up: the repo had no
# updater at all and no signal that it had none.
#
# SO THE ROOT SET IS DERIVED, NEVER TRUSTED. This script re-derives every
# lockfile-bearing directory from `git ls-tree -r HEAD` and asserts the
# `updates:` entries in .github/dependabot.yml match it EXACTLY:
#
#   MISSING  — a derived root with no entry. The hole above.
#   ORPHAN   — an entry naming a root that holds no lockfile. Not harmless:
#              Dependabot reports an unresolvable directory as a CONFIG ERROR on
#              the repo's Dependabot page, which is off to the side where nobody
#              looks, and a config error can suppress the whole file.
#
# Both directions are checked because an orphan is as wrong as a hole, and the
# usual half-built version of this gate only checks one.
#
# A ROOT IS A DIRECTORY THAT HOLDS A LOCKFILE, not one that holds a
# package.json. Workspace MEMBERS (js/packages/*, apps/mobile, packages/client,
# js/docs) carry a package.json and no lockfile; Dependabot resolves them from
# their workspace root, so an entry per member would be a duplicate or an error.
# The rationale, and the list of package.json trees this consciously does NOT
# cover, is written down in .github/dependabot.yml's own header.
#
# WHAT THIS DOES NOT CHECK, said plainly: it does not run Dependabot, does not
# validate the schedule/groups/limit fields, and does not know whether GitHub
# accepts the file. It answers ONE question — is the set of directories in the
# config the set of directories in the tree — and a green here is exactly that
# claim and no larger.
#
# BLAST RADIUS. This gate runs as a step in doc-gates.yml, which publishes the
# "Doc budgets + anchors" context. That context is NOT in
# .github/required-checks.json's required set — it carries an explicit S4
# exclusion row there — so a RED here is visible on the PR and CANNOT block a
# merge. Wiring it makes it RUN, not BLOCK.
#
# ── THIS SCRIPT HAS TWO SECTIONS, and the second one is not about Dependabot ─
#
# §1 DEPENDABOT ROOTS — everything above: the config describes the tree.
# §2 GOVULNCHECK STEP SHAPE — go-tests.yml's `go vet + test` job must carry a
#    govulncheck step, and that step must be ADVISORY.
#
# WHY §2 LIVES HERE rather than in a file of its own. The two halves are one
# change: task-c33fee1e82700787 asked for dependency FRESHNESS, which is an
# updater (§1) plus a vulnerability reader (§2), and neither half is worth much
# without the other — an updater with no scanner bumps blind, a scanner with no
# updater reports a fix nobody applies. §2 guards TWO deletions that are
# otherwise completely unguarded, because a CI step is not code and no test
# suite reaches it: (a) somebody deletes the step and the scan silently stops
# happening — the exact failure the row was filed for, restored; (b) somebody
# "fixes the red" by dropping `continue-on-error`, which converts a permanently
# correct stdlib-currency finding into a block no PR can clear (see the long
# comment above the step in go-tests.yml, and `Security gate`'s S7 row in
# .github/required-checks.json for the precedent this repo already ruled on).
#
# §2 is a SHAPE check over the workflow file. It does not run govulncheck and
# claims nothing about vulnerabilities.
#
# Usage:
#   scripts/dependabot-roots-check.sh            # check (CI)
#   scripts/dependabot-roots-check.sh --selftest # tripwire: plant each failure
#                                                # direction in a temp repo and
#                                                # prove this script REDS.
# Any other argument exits 2 — a typo'd flag must never read as a clean check.
#
# Overrides (used only by --selftest to drive temp trees):
#   DEPENDABOT_ROOTS_ROOT  repo root to scan (default: the git toplevel)
#
# bash 3.2 compatible (macOS ships 3.2; no mapfile, no associative arrays).

set -euo pipefail

LOCKFILES='package-lock.json|pnpm-lock.yaml|yarn.lock|npm-shrinkwrap.json|bun.lockb'

usage() { echo "usage: scripts/dependabot-roots-check.sh [--selftest]" >&2; }

# ── derivation ──────────────────────────────────────────────────────────────
# Emits "<ecosystem>\t<directory>" lines, sorted and deduped. Directories are
# Dependabot-shaped: leading slash, "/" for the repo root.
derive() {
  local root="$1" files=""

  if git -C "$root" rev-parse --verify HEAD >/dev/null 2>&1; then
    files="$(git -C "$root" ls-tree -r --name-only HEAD)"
  else
    # Fallback for a non-git tree. Deliberately second: the committed tree is
    # what Dependabot reads, so an uncommitted lockfile is NOT a root yet.
    files="$(cd "$root" && find . -type f \
      \( -name package-lock.json -o -name pnpm-lock.yaml -o -name yarn.lock \
         -o -name npm-shrinkwrap.json -o -name bun.lockb -o -name go.mod \) \
      -not -path './.git/*' | sed 's|^\./||')"
  fi

  {
    # npm/pnpm roots — deduped by DIRECTORY, because the repo root holds BOTH a
    # package-lock.json and a pnpm-lock.yaml and Dependabot permits exactly one
    # entry per (ecosystem, directory) pair.
    printf '%s\n' "$files" | { grep -E "(^|/)($LOCKFILES)\$" || true; } | while IFS= read -r f; do
      [ -n "$f" ] || continue
      d="$(dirname "$f")"
      if [ "$d" = "." ]; then d=""; fi
      printf 'npm\t/%s\n' "$d"
    done

    # Go modules.
    printf '%s\n' "$files" | { grep -E '(^|/)go\.mod$' || true; } | while IFS= read -r f; do
      [ -n "$f" ] || continue
      d="$(dirname "$f")"
      if [ "$d" = "." ]; then d=""; fi
      printf 'gomod\t/%s\n' "$d"
    done

    # GitHub Actions pins are not lockfile-backed and cannot be derived from a
    # file listing; the workflow directory is the only place they can live, so
    # the root entry is a CONSTANT of the check rather than a derivation.
    if [ -d "$root/.github/workflows" ]; then
      printf 'github-actions\t/\n'
    fi
  } | sort -u
}

# ── config parse ────────────────────────────────────────────────────────────
# STRICT BY DESIGN. This reads a deliberately narrow shape:
#
#     - package-ecosystem: "npm"
#       directory: "/web"
#
# `directory:` must be the line IMMEDIATELY after `- package-ecosystem:`, both
# double-quoted. Anything else — the plural `directories:` key, a reordered
# entry, an unquoted value, a comment wedged between the two — exits 2 rather
# than parsing to a partial answer. A YAML parser that silently skips what it
# does not understand is how a drift gate goes blind, and there is no PyYAML
# guarantee on a GitHub runner anyway; a refusal is the honest failure here.
parse_config() {
  awk '
    /^[[:space:]]*directories:/ {
      print "MALFORMED\tthe plural `directories:` key is not supported by this checker; use one entry per directory"
      exit 0
    }
    {
      if (pending != "") {
        if ($0 ~ /^[[:space:]]+directory:[[:space:]]*"[^"]*"[[:space:]]*$/) {
          d = $0; sub(/^[^"]*"/, "", d); sub(/".*$/, "", d)
          print "ENTRY\t" pending "\t" d
          pending = ""
          next
        }
        print "MALFORMED\tpackage-ecosystem \"" pending "\" is not immediately followed by a quoted `directory:` line"
        exit 0
      }
      if ($0 ~ /^[[:space:]]*-[[:space:]]*package-ecosystem:[[:space:]]*"[^"]*"[[:space:]]*$/) {
        e = $0; sub(/^[^"]*"/, "", e); sub(/".*$/, "", e)
        pending = e
      }
    }
    END {
      if (pending != "") print "MALFORMED\ttrailing package-ecosystem \"" pending "\" with no directory"
    }
  ' "$1"
}

# ── §2: the govulncheck step's shape ────────────────────────────────────────
# Extracts the `- name: govulncheck…` step out of .github/workflows/go-tests.yml
# by indentation (from its `- name:` line up to the next sibling `- name:` or
# the next job) and asserts three things about it. Every assertion names the
# thing it is protecting, because a shape gate whose message is "shape check
# failed" teaches the reader to delete it.
check_govulncheck_step() {
  local root="$1"
  local wf="$root/.github/workflows/go-tests.yml"

  if [ ! -f "$wf" ]; then
    echo "dependabot-roots-check §2: HARNESS-UNAVAILABLE — $wf does not exist." >&2
    echo "  §2 asserts a step inside that workflow; with the file gone it can prove nothing." >&2
    return 2
  fi

  local n
  n="$(grep -c '^ *- name: govulncheck' "$wf" || true)"
  if [ "$n" -eq 0 ]; then
    echo "dependabot-roots-check §2: FAIL — no govulncheck step in $wf." >&2
    echo "  The Go module tree has NO vulnerability scanner in any workflow again." >&2
    echo "  That is the defect task-c33fee1e82700787 closed; do not reopen it silently." >&2
    return 1
  fi
  if [ "$n" -ne 1 ]; then
    echo "dependabot-roots-check §2: FAIL — $n govulncheck steps in $wf, expected exactly 1." >&2
    echo "  Two scanners publish two verdicts and this gate can only reason about one." >&2
    return 1
  fi

  # The step block: from its `- name:` line to the line before the next
  # `- name:` at the same indentation (or EOF).
  local block
  block="$(awk '
    /^ *- name: govulncheck/ { inblock = 1; indent = index($0, "-"); print; next }
    inblock && /^ *- name: / && index($0, "-") == indent { inblock = 0 }
    inblock { print }
  ' "$wf")"

  # NOT `grep -q`: it exits on the FIRST match, printf takes SIGPIPE (141), and
  # under `set -o pipefail` the pipeline reports 141 — a MATCH read as a
  # failure. grep without -q drains its input, so the status is the verdict.
  if ! printf '%s\n' "$block" | grep -E '^ *continue-on-error: true *$' >/dev/null; then
    echo "dependabot-roots-check §2: FAIL — the govulncheck step is not marked advisory." >&2
    echo "  \`continue-on-error: true\` is missing from the step block." >&2
    echo "  govulncheck's findings on this tree are Go STANDARD LIBRARY findings, cleared by" >&2
    echo "  bumping the toolchain and NOT by editing this repo. A blocking step therefore reds" >&2
    echo "  every open PR the day an advisory lands, and no PR can clear it — the same shape" >&2
    echo "  .github/required-checks.json cites when it holds \`Security gate\` out of branch" >&2
    echo "  protection. If you want this blocking, that is a policy decision with a ledger row," >&2
    echo "  not a one-line edit." >&2
    return 1
  fi

  if ! printf '%s\n' "$block" | grep -F -- '-scan symbol' >/dev/null; then
    echo "dependabot-roots-check §2: FAIL — the govulncheck step does not pass \`-scan symbol\`." >&2
    echo "  The scan mode is written out on purpose: module mode reports every module with any" >&2
    echo "  advisory whether or not the code is reachable, which on a 99-module go.sum is a wall" >&2
    echo "  of findings nobody triages. If the mode is being changed, change this line with it." >&2
    return 1
  fi

  echo "dependabot-roots-check §2: OK — go-tests.yml carries exactly 1 govulncheck step, advisory (continue-on-error: true), scan=symbol."
  return 0
}

# ── the check ───────────────────────────────────────────────────────────────
run_check() {
  local root="$1"
  local cfg="$root/.github/dependabot.yml"

  if [ ! -f "$cfg" ]; then
    echo "dependabot-roots-check: FAIL — $cfg does not exist." >&2
    echo "  The repo has lockfiles and no updater config. That is the defect this gate names." >&2
    return 1
  fi

  local derived parsed malformed entries
  derived="$(derive "$root")"

  # NON-VACUITY FLOOR (distrust vacuous green). A derivation that returns
  # nothing would make every comparison below trivially agree with an empty
  # config. Zero derived roots in a tree that has a dependabot.yml means the
  # DERIVER broke, not that the repo has no dependencies.
  if [ -z "$derived" ]; then
    echo "dependabot-roots-check: HARNESS-UNAVAILABLE — derived ZERO roots from '$root'." >&2
    echo "  A comparison against an empty derived set proves nothing. Refusing to report a verdict." >&2
    return 2
  fi

  parsed="$(parse_config "$cfg")"
  malformed="$(printf '%s\n' "$parsed" | grep '^MALFORMED' || true)"
  if [ -n "$malformed" ]; then
    echo "dependabot-roots-check: HARNESS-UNAVAILABLE — could not parse $cfg:" >&2
    printf '%s\n' "$malformed" | sed 's/^MALFORMED\t/  /' >&2
    return 2
  fi

  entries="$(printf '%s\n' "$parsed" | sed -n 's/^ENTRY\t//p' | sort -u)"

  local missing orphan
  missing="$(comm -23 <(printf '%s\n' "$derived") <(printf '%s\n' "$entries") || true)"
  orphan="$(comm -13 <(printf '%s\n' "$derived") <(printf '%s\n' "$entries") || true)"

  local n_derived n_entries
  n_derived="$(printf '%s\n' "$derived" | grep -c . || true)"
  n_entries="$(printf '%s\n' "$entries" | grep -c . || true)"

  if [ -z "$missing" ] && [ -z "$orphan" ]; then
    echo "dependabot-roots-check: OK — ${n_derived} derived root(s) and ${n_entries} dependabot entr(ies) agree, both directions."
    printf '%s\n' "$derived" | sed 's/^/  ok  /'
    return 0
  fi

  echo "dependabot-roots-check: FAIL — .github/dependabot.yml does not describe this tree." >&2
  if [ -n "$missing" ]; then
    echo "  MISSING (a lockfile-bearing root with no updates: entry — it ages unwatched):" >&2
    printf '%s\n' "$missing" | sed 's/^/    + /' >&2
  fi
  if [ -n "$orphan" ]; then
    echo "  ORPHAN (an updates: entry whose directory holds no lockfile — Dependabot reports this as a config error):" >&2
    printf '%s\n' "$orphan" | sed 's/^/    - /' >&2
  fi
  echo "  Derived from \`git ls-tree -r HEAD\` at: $root" >&2
  return 1
}

# ── selftest ────────────────────────────────────────────────────────────────
# Plants BOTH failure directions plus both refusal directions in throwaway git
# repos and re-invokes THIS script against each. It plants nothing in the real
# tree. Every arm asserts the exit code AND a substring of the message, so an
# arm cannot pass on the right colour for the wrong reason.
# The temp root is a GLOBAL, not a `local`: the EXIT trap below fires in the
# top-level shell, after this function has returned and its locals are gone —
# with `set -u` that made the cleanup itself die with "tmp: unbound variable"
# AFTER every arm had passed, turning an all-green harness into rc=1.
SELFTEST_TMP=""
cleanup_selftest() { [ -n "${SELFTEST_TMP:-}" ] && rm -rf "$SELFTEST_TMP"; return 0; }

selftest() {
  local fails=0 arm_n=0 tmp
  SELFTEST_TMP="$(mktemp -d)"
  tmp="$SELFTEST_TMP"
  trap cleanup_selftest EXIT

  local self="$0"
  case "$self" in /*) ;; *) self="$PWD/$self" ;; esac

  # arm <name> <expected-rc> <expected-substring> <fixture-dir>
  arm() {
    local name="$1" want_rc="$2" want_sub="$3" dir="$4"
    arm_n=$((arm_n + 1))
    local out rc
    set +e
    out="$(DEPENDABOT_ROOTS_ROOT="$dir" bash "$self" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -ne "$want_rc" ]; then
      echo "  FAIL  [$arm_n] $name: expected rc=$want_rc, got rc=$rc"
      printf '%s\n' "$out" | sed 's/^/          | /'
      fails=$((fails + 1))
      return
    fi
    case "$out" in
      *"$want_sub"*) echo "  ok    [$arm_n] $name (rc=$rc, said: $want_sub)" ;;
      *)
        echo "  FAIL  [$arm_n] $name: rc=$want_rc as expected, but the message never said '$want_sub'"
        printf '%s\n' "$out" | sed 's/^/          | /'
        fails=$((fails + 1))
        ;;
    esac
  }

  # Build a minimal but REAL fixture repo: two npm roots, one go module, a
  # workflows dir, and a package.json with no lockfile that must NOT become a root.
  mk_fixture() {
    local d="$1"
    mkdir -p "$d/web" "$d/member" "$d/.github/workflows"
    echo '{}'                 > "$d/package.json"
    echo '{}'                 > "$d/package-lock.json"
    echo 'lockfileVersion: 9' > "$d/web/pnpm-lock.yaml"
    echo '{}'                 > "$d/member/package.json"   # member: NO lockfile
    echo 'module x'           > "$d/go.mod"
    echo 'name: x'            > "$d/.github/workflows/x.yml"
    # §2's subject. A COMPLIANT miniature of the real step: same shape, same
    # three properties, so the §1 arms below stay green on §2 and the §2 arms
    # mutate one property at a time out of a known-good baseline.
    mk_gotests "$d" compliant
    git -C "$d" init -q
    git -C "$d" -c user.email=t@t -c user.name=t add -A
    git -C "$d" -c user.email=t@t -c user.name=t commit -qm f
  }

  # mk_gotests <dir> <variant>
  #   compliant  — one govulncheck step, advisory, -scan symbol
  #   absent     — no govulncheck step at all (the pre-fix state, restored)
  #   blocking   — the step, with `continue-on-error: true` removed
  #   modulescan — the step, with `-scan symbol` swapped for `-scan module`
  #   doubled    — two govulncheck steps
  mk_gotests() {
    local d="$1" variant="$2"
    mkdir -p "$d/.github/workflows"
    {
      printf 'jobs:\n  test:\n    name: go vet + test\n    steps:\n'
      printf '      - name: go vet\n        run: go vet ./...\n'
      if [ "$variant" != "absent" ]; then
        printf '      - name: govulncheck (advisory — reports, never blocks)\n'
        [ "$variant" = "blocking" ] || printf '        continue-on-error: true\n'
        if [ "$variant" = "modulescan" ]; then
          printf '        run: govulncheck -scan module ./...\n'
        else
          printf '        run: govulncheck -scan symbol ./...\n'
        fi
      fi
      if [ "$variant" = "doubled" ]; then
        printf '      - name: govulncheck (second copy)\n'
        printf '        continue-on-error: true\n'
        printf '        run: govulncheck -scan symbol ./...\n'
      fi
    } > "$d/.github/workflows/go-tests.yml"
  }

  write_cfg() {
    # write_cfg <dir> <extra-entries-file-or-empty> ; base = the correct set
    local d="$1"
    mkdir -p "$d/.github"
    {
      echo 'version: 2'
      echo 'updates:'
      shift
      while [ "$#" -gt 0 ]; do
        printf '  - package-ecosystem: "%s"\n' "${1%%:*}"
        printf '    directory: "%s"\n' "${1#*:}"
        printf '    schedule:\n      interval: "weekly"\n'
        shift
      done
    } > "$d/.github/dependabot.yml"
  }

  # (1) GREEN — the config exactly describes the tree. If this arm ever fails,
  #     every red below is meaningless (they could be reding on anything).
  local g="$tmp/green"; mkdir -p "$g"; mk_fixture "$g"
  write_cfg "$g" 'npm:/' 'npm:/web' 'gomod:/' 'github-actions:/'
  arm "green baseline: derived set == config set" 0 "both directions" "$g"

  # (2) RED, direction ONE — delete the /web entry. A real lockfile root goes
  #     unwatched; this is the hole the gate exists to catch.
  local m="$tmp/missing"; mkdir -p "$m"; mk_fixture "$m"
  write_cfg "$m" 'npm:/' 'gomod:/' 'github-actions:/'
  arm "MUTATION: a lockfile root with no entry REDS" 1 "+ npm	/web" "$m"

  # (3) RED, direction TWO — an entry for a directory that holds no lockfile.
  #     A one-directional gate passes this; that is why both directions exist.
  local o="$tmp/orphan"; mkdir -p "$o"; mk_fixture "$o"
  write_cfg "$o" 'npm:/' 'npm:/web' 'npm:/nope' 'gomod:/' 'github-actions:/'
  arm "MUTATION: an entry naming a lockfile-less directory REDS" 1 "- npm	/nope" "$o"

  # (4) A package.json WITHOUT a lockfile must NOT be demanded as a root. This
  #     is the judgement call in dependabot.yml's header, locked in: arm (1)
  #     already proves it (member/ has a package.json and no entry) — this arm
  #     proves the INVERSE, that adding an entry for it is reported as an orphan.
  local w="$tmp/member"; mkdir -p "$w"; mk_fixture "$w"
  write_cfg "$w" 'npm:/' 'npm:/web' 'npm:/member' 'gomod:/' 'github-actions:/'
  arm "MUTATION: a package.json-only member is an ORPHAN, not a root" 1 "- npm	/member" "$w"

  # (5) REFUSAL — the plural `directories:` key. Must exit 2, never green.
  local p="$tmp/plural"; mkdir -p "$p"; mk_fixture "$p"
  printf 'version: 2\nupdates:\n  - package-ecosystem: "npm"\n    directories:\n      - "/"\n' \
    > "$p/.github/dependabot.yml"
  arm "REFUSAL: plural directories: exits 2, not green" 2 "plural" "$p"

  # (6) REFUSAL — a reordered entry the strict parser cannot read. Proves the
  #     parser does not silently drop what it does not understand.
  local r="$tmp/reordered"; mkdir -p "$r"; mk_fixture "$r"
  printf 'version: 2\nupdates:\n  - package-ecosystem: "npm"\n    schedule:\n      interval: "weekly"\n    directory: "/"\n' \
    > "$r/.github/dependabot.yml"
  arm "REFUSAL: an unreadable entry exits 2, not green" 2 "not immediately followed" "$r"

  # (7) NON-VACUITY — a tree with no lockfiles at all. The derived set is empty,
  #     so every comparison would trivially agree. Must refuse, not green.
  local e="$tmp/empty"; mkdir -p "$e/.github"
  echo 'x' > "$e/README.md"
  git -C "$e" init -q
  printf 'version: 2\nupdates: []\n' > "$e/.github/dependabot.yml"
  git -C "$e" -c user.email=t@t -c user.name=t add -A
  git -C "$e" -c user.email=t@t -c user.name=t commit -qm f
  arm "NON-VACUITY: zero derived roots refuses instead of greening" 2 "derived ZERO roots" "$e"

  # (8) MISSING FILE — no dependabot.yml at all. This is the pre-fix state of
  #     this very repo, and it must be a RED, not a skip.
  local n="$tmp/nocfg"; mkdir -p "$n"; mk_fixture "$n"
  arm "no dependabot.yml at all REDS (the pre-fix state)" 1 "does not exist" "$n"

  # ── §2 arms. Each starts from the arm-(1) green fixture and mutates ONE
  #    property of the govulncheck step, so a red can only be that property.

  # (9) The step is DELETED — the row's own defect, restored. This is the arm
  #     the criterion asks for: put the defect back, watch a named check red.
  local a="$tmp/gvc-absent"; mkdir -p "$a"; mk_fixture "$a"
  write_cfg "$a" 'npm:/' 'npm:/web' 'gomod:/' 'github-actions:/'
  mk_gotests "$a" absent
  arm "MUTATION §2: deleting the govulncheck step REDS" 1 "no govulncheck step" "$a"

  # (10) `continue-on-error` dropped — the "fix the red by making it blocking"
  #      edit, which is the one that deadlocks every open PR on a stdlib CVE.
  local b="$tmp/gvc-blocking"; mkdir -p "$b"; mk_fixture "$b"
  write_cfg "$b" 'npm:/' 'npm:/web' 'gomod:/' 'github-actions:/'
  mk_gotests "$b" blocking
  arm "MUTATION §2: dropping continue-on-error REDS" 1 "not marked advisory" "$b"

  # (11) Scan mode silently widened to module.
  local c="$tmp/gvc-module"; mkdir -p "$c"; mk_fixture "$c"
  write_cfg "$c" 'npm:/' 'npm:/web' 'gomod:/' 'github-actions:/'
  mk_gotests "$c" modulescan
  arm "MUTATION §2: -scan module instead of symbol REDS" 1 "does not pass" "$c"

  # (12) Two scanners: two verdicts, and this gate reasons about one.
  local dd="$tmp/gvc-double"; mkdir -p "$dd"; mk_fixture "$dd"
  write_cfg "$dd" 'npm:/' 'npm:/web' 'gomod:/' 'github-actions:/'
  mk_gotests "$dd" doubled
  arm "MUTATION §2: two govulncheck steps REDS" 1 "expected exactly 1" "$dd"

  # (13) The workflow file itself is gone. §2 can prove nothing, so it REFUSES
  #      (2) instead of greening on an absent subject.
  local e2="$tmp/gvc-nowf"; mkdir -p "$e2"; mk_fixture "$e2"
  write_cfg "$e2" 'npm:/' 'npm:/web' 'gomod:/' 'github-actions:/'
  rm -f "$e2/.github/workflows/go-tests.yml"
  arm "REFUSAL §2: no go-tests.yml exits 2, not green" 2 "HARNESS-UNAVAILABLE" "$e2"

  # (14) WORST-VERDICT WINS. A §1 drift and a §2 deletion at once must still
  #      report BOTH — `&&` would have hidden the second behind the first.
  local w2="$tmp/both"; mkdir -p "$w2"; mk_fixture "$w2"
  write_cfg "$w2" 'npm:/' 'gomod:/' 'github-actions:/'
  mk_gotests "$w2" absent
  arm "both sections red: §1 drift does not hide the §2 red" 1 "no govulncheck step" "$w2"

  echo
  if [ "$fails" -ne 0 ]; then
    echo "dependabot-roots-check --selftest: $fails of $arm_n arm(s) FAILED"
    return 1
  fi
  echo "dependabot-roots-check --selftest: all $arm_n arms passed"
  return 0
}

# ── entrypoint ──────────────────────────────────────────────────────────────
case "${1:-}" in
  "") ;;
  --selftest) ;;
  *) echo "dependabot-roots-check: unknown argument: $1" >&2; usage; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "dependabot-roots-check: too many arguments" >&2; usage; exit 2
fi

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

ROOT="${DEPENDABOT_ROOTS_ROOT:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$ROOT" ] || ROOT="$PWD"
fi

# BOTH sections always run, and the WORST verdict wins. Not `&&`: a §1 failure
# must not hide a §2 failure — one red step skipping the next is how a repair
# lands half-done and reads green on the retry.
rc1=0; run_check "$ROOT" || rc1=$?
rc2=0; check_govulncheck_step "$ROOT" || rc2=$?

worst=0
for r in "$rc1" "$rc2"; do
  # 2 (cannot tell) outranks 1 (drift) outranks 0.
  if [ "$r" -eq 2 ]; then worst=2; elif [ "$r" -ne 0 ] && [ "$worst" -ne 2 ]; then worst=1; fi
done
exit "$worst"
