#!/usr/bin/env bash
# release-curator-draft.test.sh — the harness that proves the NO-TAG, NO-PUBLISH
# invariant of scripts/release-curator-draft.sh and .github/workflows/release-curator-draft.yml.
#
# The ruling those two files implement (orchestrator 2026-09-13T08:10Z) is a
# pair of NEVERS: "a scheduled release-curator run that DRAFTS only; a human
# blesses and tags. Never an autonomous tag on green main." A never is only
# worth the mechanism that catches its violation, so this file has two arms and
# both are mutation-proved.
#
#   ARM 1 — BEHAVIOURAL. Runs the REAL script body with a fake `gh` and a
#           logging `git` on PATH, inside a real git repo with a real (local,
#           bare) origin, and asserts over the RECORDED ARGV: every
#           `gh release create` carries `--draft`, no `git tag` and no
#           `git push` is ever invoked, an existing draft is EDITED rather than
#           re-created, and each CANNOT-READ / CANNOT-WRITE / INVARIANT path
#           produces its own exit code.
#
#   ARM 2 — STATIC. Parses the workflow YAML (with `python3 -c` + yaml, the
#           same reader CI has) and fails if any `on:` key other than
#           `schedule`/`workflow_dispatch` appears, or if any step's `run:`
#           body contains `git tag`, `git push`, or a `gh release create`
#           without `--draft`.
#
# MUTATION PROOF — every claim below was produced by BREAKING the real files and
# running this harness against the broken copy. The reds are quoted verbatim so
# a reader can tell a live assertion from a decorative one.
#
#   M1b  delete `--draft` from the create argv in release-curator-draft.sh.
#        The script's OWN one-door guard fires before gh is ever reached:
#          PASS: M1b exit 4 when the create argv loses --draft
#          PASS: M1b the guard names the missing flag
#          PASS: M1b no gh release create reached gh
#        (M1b is a case below: it builds the mutant and asserts the red, so this
#        proof re-runs on every tick rather than dating from the day it was written.)
#
#   M1c  delete `--draft` AND disable the one-door guard, so ARM 1's own argv
#        assertions are the only thing left. Run against the live harness, 3 FAILED:
#          FAIL: A2 gh release create argv carries --draft
#            expected to contain: --draft
#            actual:   release create v0.2.26 --repo o/r --target 1111111111111111111111111111111111111111 --title Barkpark 0.2.26 (candidate) --notes-file .../notes.md
#          FAIL: A7 no gh release create WITHOUT --draft
#        M1c is NOT a case below — it would require the harness to disable a guard
#        inside its own subject, and a test that edits the thing it tests into
#        compliance is how a proof goes vacuous. It was run by hand; the reds above
#        are that run's output.
#
#   M2   add `pull_request:` and `push: branches: [main]` arms to the workflow:
#          FAIL: live B1 the workflow triggers on schedule/workflow_dispatch ONLY
#            expected: schedule, workflow_dispatch
#            actual:   pull_request, push, schedule, workflow_dispatch
#
#   M3/M4  append a step running `git tag v9.9.9 && git push origin v9.9.9` and
#        `gh release create v9.9.9 --title x` to the workflow:
#          FAIL: live B2 no step runs git tag or git push
#            actual:   mutant\tgit tag v9.9.9 && git push origin v9.9.9 ...
#          FAIL: live B3 no step runs gh release create without --draft
#            actual:   mutant\tgit tag v9.9.9 && git push origin v9.9.9 ... gh release create v9.9.9 --title x
#        M2/M3/M4 also run as cases below, against copies this file builds.
#
# WHAT THIS HARNESS ALREADY CAUGHT, on its first run against the real subject:
# `rc=$?` written inside an `if ! cmd; then` branch reads the status of the
# NEGATION (always 0), not the command's. The script reported
# "CANNOT READ: release-scan.sh exited 0" on a refusal — a number that is both
# reassuring and wrong. Case G2 is the assertion that found it.
#
# The mutations are not merely described — cases M1b, M2, M3 and M4 below BUILD
# the broken copy and assert the red, so the proof re-runs on every CI tick
# rather than dating from the day it was written.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.
# Templated on scripts/release-scan.test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="$HERE/release-curator-draft.sh"
WORKFLOW="$HERE/../.github/workflows/release-curator-draft.yml"

fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; printf '    expected: %s\n    actual:   %s\n' "$2" "$3"; fi; }
assert_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1"; printf '    expected to contain: %s\n    actual:   %s\n' "$2" "$3" ;; esac; }
assert_absent() { case "$3" in *"$2"*) fail "$1"; printf '    expected NOT to contain: %s\n    actual:   %s\n' "$2" "$3" ;; *) pass "$1" ;; esac; }

[ -f "$SUBJECT" ] || { echo "REFUSING: no subject at $SUBJECT" >&2; exit 2; }
[ -f "$WORKFLOW" ] || { echo "REFUSING: no workflow at $WORKFLOW" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "REFUSING: jq is not on PATH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "REFUSING: python3 is not on PATH" >&2; exit 2; }

REAL_GIT="$(command -v git)" || { echo "REFUSING: no git on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null || true; find "$TMP" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

# ── the fixture ──────────────────────────────────────────────────────────────
# A real repo with a real bare origin, so `git ls-remote --tags origin` in the
# subject answers for real rather than being stubbed into agreement. A stubbed
# ls-remote would make the no-tag assertion vacuous — the exact defect this
# harness exists to prevent.
mk_repo() { # <dir>
  local d="$1"
  mkdir -p "$d/origin.git" "$d/work/scripts"
  "$REAL_GIT" init --bare -q "$d/origin.git"
  "$REAL_GIT" init -q -b main "$d/work"
  "$REAL_GIT" -C "$d/work" config user.email t@t; "$REAL_GIT" -C "$d/work" config user.name t
  echo x >"$d/work/f"; "$REAL_GIT" -C "$d/work" add f
  "$REAL_GIT" -C "$d/work" commit -qm "feat: one"
  "$REAL_GIT" -C "$d/work" remote add origin "$d/origin.git"
  "$REAL_GIT" -C "$d/work" push -q origin main
}

# A fake release-scan.sh: prints whatever JSON the case wants, exits with
# whatever code the case wants. The subject calls it through
# RELEASE_CURATOR_SCAN, so no network and no real scan is involved.
mk_scan() { # <path> <exit> <json>
  cat >"$1" <<EOS
#!/usr/bin/env bash
cat <<'EOJ'
$3
EOJ
exit $2
EOS
  chmod +x "$1"
}

# A fake `gh`: records its argv one line per call, and answers `release view`
# from a file the case controls. A logging `git` shim sits beside it — it
# records every git argv the subject issues and then EXECS the real git, so
# reads still work and `git tag` / `git push` would be VISIBLE if attempted.
mk_bin() { # <dir> <gh-exit> [release-view-json]
  local b="$1/bin"
  mkdir -p "$b"
  cat >"$b/gh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$1/gh.argv"
if [ "\${1:-}" = "release" ] && [ "\${2:-}" = "view" ]; then
  if [ -s "$1/release-view.json" ]; then cat "$1/release-view.json"; exit 0; else exit 1; fi
fi
exit $2
EOS
  cat >"$b/git" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$1/git.argv"
exec "$REAL_GIT" "\$@"
EOS
  chmod +x "$b/gh" "$b/git"
  : >"$1/gh.argv"; : >"$1/git.argv"
  printf '%s' "${3:-}" >"$1/release-view.json"
}

GREEN_JSON='{"repo":"o/r","ref":"origin/main","shallow":false,"last_tag":"v0.2.25","head_sha":"1111111111111111111111111111111111111111","head_short":"111111111111","commit_count":2,"suggested_bump":"patch","suggested_version":"0.2.26","ci":{"status":"success","status_reason":"all 9 referenced check suites rolled up green","advisory_certainty":"known","checks_total":9,"suites_total":9,"failures":[],"cancelled_runs":[]},"commits":[{"sha":"aaaaaaaaaaaa","subject":"feat: a thing","pr":100},{"sha":"bbbbbbbbbbbb","subject":"chore: tidy","pr":101}]}'

# run_case <name> <scan-exit> <scan-json> <gh-exit> <release-view-json> [subject-override]
# Sets: RC, OUT, GH_ARGV, GIT_ARGV
run_case() {
  local d="$TMP/$1" scan_exit="$2" scan_json="$3" gh_exit="$4" view="$5" subj="${6:-$SUBJECT}"
  rm -rf "$d"; mk_repo "$d"; mk_bin "$d" "$gh_exit" "$view"
  cp "$subj" "$d/work/scripts/release-curator-draft.sh"
  mk_scan "$d/scan.sh" "$scan_exit" "$scan_json"
  OUT="$(cd "$d/work" && PATH="$d/bin:$PATH" \
        RELEASE_CURATOR_REPO=o/r RELEASE_CURATOR_REF=HEAD \
        RELEASE_CURATOR_SCAN="$d/scan.sh" RELEASE_CURATOR_OUTDIR="$d/out" \
        bash "$d/work/scripts/release-curator-draft.sh" 2>&1)"
  RC=$?
  GH_ARGV="$(cat "$d/gh.argv" 2>/dev/null || true)"
  GIT_ARGV="$(cat "$d/git.argv" 2>/dev/null || true)"
  CASE_DIR="$d"
}

echo "── ARM 1: behaviour (real script, fake gh, real git shim, real origin) ──"

# A — green main with commits: ONE draft create, carrying --draft.
run_case A 0 "$GREEN_JSON" 0 ""
assert_eq       "A1 exit 0 on a drafted candidate" "0" "$RC"
create_line="$(printf '%s\n' "$GH_ARGV" | grep '^release create' || true)"
assert_contains "A2 gh release create argv carries --draft" "--draft" "$create_line"
assert_contains "A3 the created tag is the suggested version" "release create v0.2.26" "$create_line"
assert_contains "A4 the draft targets the scanned head sha" "--target 1111111111111111111111111111111111111111" "$create_line"
assert_contains "A5 the title marks it a candidate" "--title Barkpark 0.2.26 (candidate)" "$create_line"
assert_eq       "A6 exactly one release create call" "1" "$(printf '%s\n' "$GH_ARGV" | grep -c '^release create' || true)"
assert_absent   "A7 no gh release create WITHOUT --draft" "release create v0.2.26 --repo o/r --target" "$GH_ARGV"
assert_absent   "A8 no git tag was invoked" "tag " "$GIT_ARGV"
assert_absent   "A9 no git push was invoked" "push " "$GIT_ARGV"
assert_contains "A10 the run asserts the no-tag invariant out loud" "NO TAG: git ls-remote --tags origin refs/tags/v0.2.26 is empty" "$OUT"
assert_contains "A11 the ls-remote assertion actually ran" "ls-remote --tags origin refs/tags/v0.2.26" "$GIT_ARGV"
assert_contains "A12 the notes carry the DRAFT — not blessed banner" "DRAFT — not blessed" "$(cat "$CASE_DIR/out/notes.md")"
assert_contains "A13 the notes group the feat commit" "- feat: a thing (#100)" "$(cat "$CASE_DIR/out/notes.md")"

# B — an existing DRAFT for the same candidate: edit, never a second create.
run_case B 0 "$GREEN_JSON" 0 '{"isDraft":true,"url":"https://example/rel"}'
assert_eq       "B1 exit 0 when refreshing an existing draft" "0" "$RC"
assert_eq       "B2 no second release create" "0" "$(printf '%s\n' "$GH_ARGV" | grep -c '^release create' || true)"
assert_eq       "B3 exactly one release edit" "1" "$(printf '%s\n' "$GH_ARGV" | grep -c '^release edit' || true)"
assert_contains "B4 the run says it refreshed" "REFRESHED: v0.2.26" "$OUT"

# C — the candidate is already PUBLISHED: hold, write nothing.
run_case C 0 "$GREEN_JSON" 0 '{"isDraft":false,"url":"https://example/rel"}'
assert_eq       "C1 exit 0 on an already-published candidate" "0" "$RC"
assert_contains "C2 it says it will not overwrite a blessed release" "already PUBLISHED" "$OUT"
assert_eq       "C3 no create and no edit" "0" "$(printf '%s\n' "$GH_ARGV" | grep -cE '^release (create|edit)' || true)"

# D — nothing since the last tag.
run_case D 0 "$(printf '%s' "$GREEN_JSON" | jq -c '.commit_count = 0 | .commits = []')" 0 ""
assert_eq       "D1 exit 0 with nothing to draft" "0" "$RC"
assert_contains "D2 it names the reason" "HOLDING: no commits since v0.2.25" "$OUT"
assert_eq       "D3 no gh write at all" "0" "$(printf '%s\n' "$GH_ARGV" | grep -cE '^release (create|edit)' || true)"

# E — main is RED. A judgment, so exit 0, and NOTHING is drafted.
run_case E 0 "$(printf '%s' "$GREEN_JSON" | jq -c '.ci.status="failure" | .ci.status_reason="2 of 9 referenced check suites rolled up red" | .ci.failures=[{"name":"Elixir gate","conclusion":"failure","advisory":"blocking"}]')" 0 ""
assert_eq       "E1 exit 0 on red main (a judgment never reds the job)" "0" "$RC"
assert_contains "E2 it names the red" "main is RED" "$OUT"
assert_contains "E3 it quotes the failing check" "Elixir gate [blocking]" "$OUT"
assert_eq       "E4 no draft opened on red main" "0" "$(printf '%s\n' "$GH_ARGV" | grep -cE '^release (create|edit)' || true)"

# F — CI still running.
run_case F 0 "$(printf '%s' "$GREEN_JSON" | jq -c '.ci.status="pending" | .ci.status_reason="3 referenced check suites are still running"')" 0 ""
assert_eq       "F1 exit 0 while checks run" "0" "$RC"
assert_contains "F2 it defers to the next tick" "still running" "$OUT"

# G — the scan REFUSED (its shallow guard, exit 3). CANNOT READ, distinct exit.
run_case G 3 '{}' 0 ""
assert_eq       "G1 exit 2 when release-scan refuses" "2" "$RC"
assert_contains "G2 a distinct CANNOT READ line names the scan exit" "CANNOT READ: release-scan.sh exited 3" "$OUT"

# H — the scan emitted a truncated walk despite fetch-depth: 0.
run_case H 0 "$(printf '%s' "$GREEN_JSON" | jq -c '.shallow=true')" 0 ""
assert_eq       "H1 exit 2 on shallow:true" "2" "$RC"
assert_contains "H2 a distinct CANNOT READ line names the truncation" "CANNOT READ: the scan reports shallow:true" "$OUT"

# I — gh itself fails. CANNOT WRITE, its own exit, and nothing was drafted.
run_case I 0 "$GREEN_JSON" 7 ""
assert_eq       "I1 exit 3 when gh fails" "3" "$RC"
assert_contains "I2 a distinct CANNOT WRITE line" "CANNOT WRITE: gh release create v0.2.26 --draft failed" "$OUT"

# J — THE INVARIANT FIRES. A tag for the candidate exists on origin after the
# draft-only write. This is the one thing the ruling forbids, and the case
# plants a real tag in the real bare origin rather than stubbing the answer.
run_case J 0 "$GREEN_JSON" 0 ""
"$REAL_GIT" -C "$CASE_DIR/work" tag v0.2.26 >/dev/null 2>&1
"$REAL_GIT" -C "$CASE_DIR/work" push -q origin v0.2.26 >/dev/null 2>&1
OUT="$(cd "$CASE_DIR/work" && PATH="$CASE_DIR/bin:$PATH" \
      RELEASE_CURATOR_REPO=o/r RELEASE_CURATOR_REF=HEAD \
      RELEASE_CURATOR_SCAN="$CASE_DIR/scan.sh" RELEASE_CURATOR_OUTDIR="$CASE_DIR/out2" \
      bash "$CASE_DIR/work/scripts/release-curator-draft.sh" 2>&1)"; RC=$?
assert_eq       "J1 exit 4 when a tag exists for the candidate" "4" "$RC"
assert_contains "J2 the violation is named, not summarised" "INVARIANT VIOLATED: refs/tags/v0.2.26 EXISTS on origin" "$OUT"

# ── MUTATION M1b: the subject's own one-door guard ───────────────────────────
# Strip `--draft` from the create call in a COPY of the subject and re-run
# case A. A green here would mean the guard is decorative.
MUT="$TMP/mutant-no-draft.sh"
sed 's/--draft --target "\$head_sha"/--target "$head_sha"/' "$SUBJECT" >"$MUT"
if cmp -s "$MUT" "$SUBJECT"; then
  fail "M1b the --draft mutation did not change the subject (the sed anchor rotted)"
else
  run_case M1b 0 "$GREEN_JSON" 0 "" "$MUT"
  assert_eq     "M1b exit 4 when the create argv loses --draft" "4" "$RC"
  assert_contains "M1b the guard names the missing flag" "assembled WITHOUT --draft" "$OUT"
  assert_eq     "M1b no gh release create reached gh" "0" "$(printf '%s\n' "$GH_ARGV" | grep -c '^release create' || true)"
fi

echo "── ARM 2: static (the workflow file itself) ──"

# The reader. Prints: a sorted comma list of `on:` keys, then one
# `STEP<TAB><name><TAB><run body, newlines folded>` line per step.
read_workflow() { # <path>
  python3 - "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
# PyYAML resolves a bare `on:` to the boolean True (YAML 1.1). Accept both.
on = d.get('on', d.get(True))
keys = sorted(on.keys()) if isinstance(on, dict) else [str(on)]
print("ON\t" + ", ".join(keys))
for jid, job in (d.get('jobs') or {}).items():
    for st in (job.get('steps') or []):
        run = (st.get('run') or '').replace('\n', ' ⏎ ')
        print("STEP\t%s\t%s" % (st.get('name') or st.get('uses') or jid, run))
PY
}

static_arm() { # <path> <label>
  local path="$1" label="$2" parsed on steps bad
  parsed="$(read_workflow "$path" 2>&1)" || { fail "$label the workflow does not parse: $parsed"; return 1; }
  on="$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="ON"{print $2}')"
  assert_eq "$label B1 the workflow triggers on schedule/workflow_dispatch ONLY" "schedule, workflow_dispatch" "$on"

  steps="$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="STEP"{print $2 "\t" $3}')"
  bad="$(printf '%s\n' "$steps" | grep -E 'git (tag|push)' | head -3 || true)"
  assert_eq "$label B2 no step runs git tag or git push" "" "$bad"
  # `gh release create` is only allowed with --draft on the SAME line.
  bad="$(printf '%s\n' "$steps" | grep 'gh release create' | grep -v -- '--draft' | head -3 || true)"
  assert_eq "$label B3 no step runs gh release create without --draft" "" "$bad"
}

static_arm "$WORKFLOW" "live"

# The workflow must call the subject, not an inlined copy of it — otherwise
# ARM 1 proves nothing about what CI runs.
assert_contains "B4 the workflow's job body IS scripts/release-curator-draft.sh" \
  "bash scripts/release-curator-draft.sh" "$(cat "$WORKFLOW")"
assert_contains "B5 the checkout is full-history (release-scan refuses a truncated walk)" \
  "fetch-depth: 0" "$(cat "$WORKFLOW")"
assert_contains "B6 permissions are declared (contents: write is what the releases API needs)" \
  "contents: write" "$(cat "$WORKFLOW")"

# ── MUTATIONS M2/M3/M4: prove ARM 2 can go red ───────────────────────────────
# Each builds a broken copy and asserts the SPECIFIC assertion flips. They run
# the checks inline (not via static_arm, whose pass/fail would pollute the
# tally) and assert the RED.
mutant_on_push() {
  local p="$TMP/m2.yml"
  sed 's/^on:$/on:\n  pull_request:/' "$WORKFLOW" >"$p"
  local on; on="$(read_workflow "$p" | awk -F'\t' '$1=="ON"{print $2}')"
  if [ "$on" = "schedule, workflow_dispatch" ]; then
    fail "M2 adding a pull_request arm did NOT change the trigger set — the static arm is blind"
  else
    assert_eq "M2 a pull_request arm is visible to the trigger check" "pull_request, schedule, workflow_dispatch" "$on"
  fi
}
mutant_step() { # <label> <run body> <grep> <assert-name>
  local p="$TMP/m-$1.yml"
  { cat "$WORKFLOW"; printf '\n      - name: mutant\n        run: %s\n' "$2"; } >"$p"
  local steps bad
  steps="$(read_workflow "$p" | awk -F'\t' '$1=="STEP"{print $2 "\t" $3}')"
  case "$1" in
    m3) bad="$(printf '%s\n' "$steps" | grep 'gh release create' | grep -v -- '--draft' || true)" ;;
    m4) bad="$(printf '%s\n' "$steps" | grep -E 'git (tag|push)' || true)" ;;
  esac
  if [ -z "$bad" ]; then fail "$4 the planted step was NOT caught — the static arm is blind"
  else pass "$4 (caught: $(printf '%s' "$bad" | head -1))"; fi
}
mutant_on_push
mutant_step m3 "gh release create v9.9.9" "" "M3 a gh release create without --draft is caught"
mutant_step m4 "git push origin v9.9.9" "" "M4 a git push step is caught"

echo
if [ "$fails" -eq 0 ]; then
  echo "release-curator-draft.test.sh: ALL PASS"
  exit 0
fi
echo "release-curator-draft.test.sh: $fails FAILED"
exit 1
