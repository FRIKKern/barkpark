#!/usr/bin/env bash
# unaccounted-workflow-ratchet.sh — the population the partial-accounting clause
# deliberately cannot see, bounded so it can only shrink.
#
# ── THE GAP THIS CLOSES, quoted from the thing that has it ───────────────────
# scripts/required-checks-verify.sh, partial_accounting_check, states its own
# ceiling in its header: "ITS CEILING, stated: it sees job-level `name:` only. A
# workflow whose names are ALL unaccounted is invisible to it (that is the
# deliberate antecedent above, not an oversight) … Those are census_check's job,
# on the heads that render them."
#
# And census_check is SAMPLE-SCOPED: it can only judge names GitHub actually
# rendered on the head it read. So a workflow with no exclusion rows at all is
# judged by nothing until a sampled head happens to render one of its names.
#
# MEASURED, 2026-09-18 (pe-bl-main-advisory-gate-hygiene). .github/workflows/
# main-red-owner.yml landed with the job name `a red on main's tip gets an owner`
# and ZERO rows in .github/required-checks.json. Its pull_request arm is
# `paths:`-fenced to its own four scripts, so essentially no PR head rendered it;
# main pushes did. `Required-check spec drift (advisory)` sat GREEN at the census
# clause run after run — not because the ledger was complete, but because the
# name was not in the sample — and then went RED the moment a head finally
# rendered it (run 35299266243, job 105460030845, 2026-09-18T02:54Z):
#
#   FAIL: head 478053040… rendered check-run name(s) with NO status in
#         .github/required-checks.json — neither required nor excluded.
#            unaccounted: a red on main's tip gets an owner
#
# That is the advisory-red-on-main-for-days shape pe-bl-main-advisory-gate-
# hygiene was filed about: a red that already existed, that nothing could see,
# that trains reviewers to read the board's reds as noise.
#
# ── WHY A RATCHET AND NOT A GATE ─────────────────────────────────────────────
# Failing closed on "every workflow must be fully accounted" would red over 22
# workflows nobody has adjudicated — inherited debt, not a regression — which is
# the same advisory-red problem one layer out, and is exactly why
# partial_accounting_check chose its antecedent. So this file does not demand
# zero. It pins the SIZE of the unadjudicated population and refuses GROWTH: a
# new fully-unledgered workflow is a NEW decision nobody made, and it reds here
# on the PR that adds it, at PR time, with no dependency on what a sampled head
# happened to render.
#
# ── BOTH FAILURE DIRECTIONS ARE NAMED, on purpose ────────────────────────────
# A ratchet has two of them and only one is a defect. count > BASELINE is new
# debt and says so. count < BASELINE is the world getting BETTER — somebody
# adjudicated a workflow — and it still exits 1, because a silently-loosening
# ratchet rots back up to its old number unnoticed; but the message says GOOD
# NEWS and names the one-line edit. Nobody reading this red should have to guess
# which direction fired.
#
# ── BASELINE ─────────────────────────────────────────────────────────────────
# DERIVATION, so the next reader re-measures instead of trusting the integer:
#
#   bash scripts/unaccounted-workflow-ratchet.sh
#
# prints the full sorted population on every run, pass or fail. The integer below
# is the count of that list on the commit that last moved it. It read 23 before
# `a red on main's tip gets an owner` was adjudicated in this same commit.
#
# CEILING, stated: this is a COUNT, so when it reds on growth it cannot NAME the
# newcomer — diff the printed list against the previous run's. Naming it would
# need a committed list, and a list is a snapshot that goes stale silently, which
# is the fault this file exists to answer.
#
# 22 -> 21, 2026-09-24 (task-88edd0348e6f703d, PR #20086). Re-measured, not
# decremented: `bash scripts/unaccounted-workflow-ratchet.sh` printed count=21 on
# origin/main a3d6027da. Walking every commit that touched .github/required-checks.json
# or .github/workflows since 5541e5c33 (which set 22) with this script, the count
# first moves at 8d94b7a00 (#20042, the absent-context census fires on producer
# completion): `absent-context-census.yml` left the list because that PR gave its
# job name a status in the spec. Good news, recorded here so the ratchet holds it.
BASELINE=21

set -uo pipefail

SPEC=".github/required-checks.json"
WORKFLOWS=".github/workflows"

usage() { echo "usage: $0 [--selftest] [--spec F] [--workflows DIR] [--baseline N]" >&2; }

# ── the population predicate ─────────────────────────────────────────────────
# Prints one basename per fully-unaccounted workflow, sorted. Exit 2 = BLOCKED
# (an input could not be read, or reading it would make the verdict vacuous) —
# never 0, because a vacuous green here is the failure mode this whole family
# refuses.
population() {
  local spec="$1" wfdir="$2" tmp rc_files acc n_acc f names a
  tmp="$(mktemp -d)" || return 2
  if ! jq -r '(.protection.required_status_checks.checks[]?.context),
              (.exclusions[]?.context)' "$spec" 2>/dev/null | sort -u > "$tmp/accounted"; then
    echo "BLOCKED: $spec is not readable as the required-checks spec." >&2
    rm -rf "$tmp"; return 2
  fi
  n_acc="$(grep -c . < "$tmp/accounted" || true)"
  # CONTROL 1 — an empty accounted set makes EVERY workflow fully unaccounted,
  # so the count would balloon and the red would be about the spec, not the tree.
  if [ "${n_acc:-0}" -lt 2 ]; then
    echo "BLOCKED: $spec yielded $n_acc accounted context(s); with no accounted set every workflow is trivially unaccounted and this count would mean nothing." >&2
    rm -rf "$tmp"; return 2
  fi
  rc_files="$(find "$wfdir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)"
  if [ -z "$rc_files" ]; then
    echo "BLOCKED: $wfdir yielded 0 workflow file(s); scanning zero is a vacuous pass, not a green." >&2
    rm -rf "$tmp"; return 2
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Job-level `name:` is exactly four spaces under `jobs:` — step names sit at
    # six or more and the workflow-level one at zero, so the indent IS the
    # discriminator. Same reader as partial_accounting_check, deliberately: two
    # clauses disagreeing about what a job name is would be worse than either.
    # A matrix-templated name is skipped because the rendered string is not
    # derivable from the file.
    names="$(awk '/^    name: /{ s=$0; sub(/^    name: /,"",s);
                                 gsub(/^[ \t]+|[ \t]+$/,"",s);
                                 gsub(/^"|"$|^'"'"'|'"'"'$/,"",s);
                                 if (s !~ /\$\{\{/) print s }' "$f" | sort -u)"
    [ -n "$names" ] || continue
    printf '%s\n' "$names" > "$tmp/names"
    a="$(comm -12 "$tmp/names" "$tmp/accounted" | grep -c . || true)"
    [ "${a:-0}" -eq 0 ] || continue
    basename "$f"
  done <<EOF
$rc_files
EOF
  rm -rf "$tmp"
  return 0
}

run_check() {
  local spec="$1" wfdir="$2" baseline="$3" pop n
  pop="$(population "$spec" "$wfdir")" || return 2
  n="$(printf '%s\n' "$pop" | grep -c . || true)"
  echo "── fully-unledgered workflows (no job name carries a status in $spec) ──"
  if [ "${n:-0}" -gt 0 ]; then printf '%s\n' "$pop" | sed 's/^/   /'; fi
  echo "   count=$n baseline=$baseline"
  if [ "${n:-0}" -gt "$baseline" ]; then
    echo "FAIL: the unledgered-workflow population GREW ($baseline -> $n)." >&2
    echo "      A workflow with no row at all is judged by nothing until a sampled head happens to render one of its names, so this red is the ONLY thing that sees it at PR time." >&2
    echo "      FIX: add a row to .exclusions in $spec for at least one job name in the new workflow, saying WHAT the check is and WHY it does not gate (S2 advisory / S3 subsumed / S4 paths-filtered or structurally absent on a PR head / S6 leaf of an excluded aggregator / S7 by decision), or register it." >&2
    return 1
  fi
  if [ "${n:-0}" -lt "$baseline" ]; then
    echo "FAIL: GOOD NEWS, NOT A DEFECT — the unledgered-workflow population SHRANK ($baseline -> $n)." >&2
    echo "      Somebody adjudicated a workflow. Nothing is broken; this reds only so the ratchet cannot loosen and rot back up unnoticed." >&2
    echo "      FIX: set BASELINE=$n in $0 (one line) and re-run." >&2
    return 1
  fi
  echo "  ok     unledgered-workflow population held at $n (ratchet)"
  return 0
}

# ── selftest ────────────────────────────────────────────────────────────────
# Present-in-file is not fires-when-it-should. Every arm below runs THIS
# checker over a real fixture tree and asserts the exit code AND the direction
# word, so an arm cannot pass on a red that fired for the wrong reason.
selftest() {
  local tmp rc=0 out code
  tmp="$(mktemp -d)"
  mk_spec() { # $1=path, $2..=accounted contexts
    local p="$1"; shift
    printf '%s\n' "$*" | tr ' ' '\n' > /dev/null
    { echo '{"protection":{"required_status_checks":{"checks":[]}},"exclusions":['
      local first=1 c
      for c in "$@"; do [ $first -eq 1 ] || echo ','; first=0; printf '{"context":"%s","reason":"fixture"}' "$c"; done
      echo ']}'; } > "$p"
  }
  mk_wf() { # $1=dir $2=file $3..=job names
    local d="$1" f="$2"; shift 2
    mkdir -p "$d"
    { echo "name: fixture"; echo "jobs:"; local i=0 n
      for n in "$@"; do i=$((i+1)); echo "  j$i:"; echo "    name: $n"; echo "      name: a step name at six spaces"; done; } > "$d/$f"
  }
  probe() { # $1=label $2=want_code $3=want_substr $4..=args
    local label="$1" want="$2" want_s="$3"; shift 3
    out="$("$0" "$@" 2>&1)"; code=$?
    if [ "$code" -ne "$want" ]; then
      echo "  FAIL  $label: exit $code, wanted $want"; printf '%s\n' "$out" | sed 's/^/        /'; rc=1; return
    fi
    if [ -n "$want_s" ] && ! printf '%s' "$out" | grep -qF -- "$want_s"; then
      echo "  FAIL  $label: exit $code as wanted, but output never said '$want_s'"; printf '%s\n' "$out" | sed 's/^/        /'; rc=1; return
    fi
    echo "  ok    $label"
  }

  mk_spec "$tmp/spec.json" "Ledgered alpha" "Ledgered beta"

  # BASE TREE: two workflows, one ledgered, one fully unledgered => population 1.
  mk_wf "$tmp/wf-base" "ledgered.yml" "Ledgered alpha"
  mk_wf "$tmp/wf-base" "orphan.yml"   "Unledgered gamma"

  # 1. QUIET when it should be: population == baseline.
  probe "at baseline, silent" 0 "held at 1" --spec "$tmp/spec.json" --workflows "$tmp/wf-base" --baseline 1

  # 2. FIRES on growth: a second fully-unledgered workflow appears.
  cp -R "$tmp/wf-base" "$tmp/wf-grew"
  mk_wf "$tmp/wf-grew" "orphan2.yml" "Unledgered delta"
  probe "growth reds, says GREW" 1 "GREW (1 -> 2)" --spec "$tmp/spec.json" --workflows "$tmp/wf-grew" --baseline 1

  # 3. FIRES the OTHER way, and says so: the population shrank.
  probe "shrink reds, says SHRANK" 1 "SHRANK (2 -> 1)" --spec "$tmp/spec.json" --workflows "$tmp/wf-base" --baseline 2

  # 4. A PARTIALLY-ledgered workflow is NOT this file's population. orphan.yml
  #    gains one ledgered name; it leaves the set even though `Unledgered gamma`
  #    is still unaccounted — that name is partial_accounting_check's job, and an
  #    arm here proves the two clauses do not double-count it.
  cp -R "$tmp/wf-base" "$tmp/wf-partial"
  mk_wf "$tmp/wf-partial" "orphan.yml" "Ledgered beta" "Unledgered gamma"
  probe "partially-ledgered is not this population" 1 "SHRANK (1 -> 0)" --spec "$tmp/spec.json" --workflows "$tmp/wf-partial" --baseline 1

  # 5. A matrix-templated name is not derivable from the file, so a workflow
  #    whose ONLY name is templated contributes nothing either way.
  cp -R "$tmp/wf-base" "$tmp/wf-matrix"
  mk_wf "$tmp/wf-matrix" "matrix.yml" 'Gate (${{ matrix.v }})'
  probe "templated-only workflow is skipped" 0 "held at 1" --spec "$tmp/spec.json" --workflows "$tmp/wf-matrix" --baseline 1

  # 6. CONTROL — an empty accounted set must BLOCK (exit 2), not report a huge
  #    count as if the tree had regressed.
  mk_spec "$tmp/spec-empty.json"
  probe "empty accounted set BLOCKS" 2 "with no accounted set" --spec "$tmp/spec-empty.json" --workflows "$tmp/wf-base" --baseline 1

  # 7. CONTROL — zero workflow files must BLOCK, not pass vacuously.
  mkdir -p "$tmp/wf-empty"
  probe "zero workflow files BLOCKS" 2 "vacuous pass" --spec "$tmp/spec.json" --workflows "$tmp/wf-empty" --baseline 1

  # 8. CONTROL — an unreadable spec must BLOCK.
  echo 'not json' > "$tmp/spec-bad.json"
  probe "unreadable spec BLOCKS" 2 "BLOCKED" --spec "$tmp/spec-bad.json" --workflows "$tmp/wf-base" --baseline 1

  rm -rf "$tmp"
  if [ "$rc" -eq 0 ]; then echo "selftest: 8/8 arms passed"; else echo "selftest: FAILED"; fi
  return "$rc"
}

SELFTEST=0
BASELINE_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) SELFTEST=1; shift ;;
    --spec) SPEC="$2"; shift 2 ;;
    --workflows) WORKFLOWS="$2"; shift 2 ;;
    --baseline) BASELINE_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ "$SELFTEST" -eq 1 ]; then selftest; exit $?; fi
run_check "$SPEC" "$WORKFLOWS" "${BASELINE_OVERRIDE:-$BASELINE}"
