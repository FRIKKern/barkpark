#!/usr/bin/env bash
#
# gate-refusal-vocabulary-check.sh — the structural guard over the REFUSAL
# channel of the `Cloud gate`'s instruments.
#
# WHY THIS EXISTS
# ---------------
# A gate that cannot say "I could not measure" reports a refusal as a defect,
# and — one step later, when someone adds an `|| true` to stop the noise — as a
# pass. `cloud.yml` runs FOUR scripts whose own headers declare a three-code
# vocabulary (0 clean · 1 measured defect · 2 CANNOT MEASURE) and then throws
# the code away: every step is a bare `bash scripts/X.sh`, so `exit 2` and
# `exit 1` arrive at `needs.<job>.result` as the same string, `failure`. The
# `Cloud gate` aggregator's `decide()` reads only `.result`. On that channel an
# unreachable hex.pm, a postgres container that never came up, a `--base-ref`
# that does not resolve and a genuine migration-version collision are ONE
# signal.
#
# `console-harness.yml` already has the vocabulary — `V_*` job outputs, a
# `REFUSED TO MEASURE (exit 2)` annotation distinct from the measured-defect
# one. This guard is what stops the Cloud half from drifting back out of it,
# and what makes a NEWLY ADDED `exit 2` at an undeclared call site red on the
# commit that adds it rather than on some later run that misreads it.
#
# WHAT IT ASSERTS (the rule, in words — a predicate, never a list)
# ---------------------------------------------------------------
# A1. CHANNEL AT THE CALL SITE. For every live `run:` step in a guarded
#     workflow that invokes `scripts/X.sh`: if `X.sh` is REFUSAL-CAPABLE, the
#     invocation must go through `scripts/run-instrument.sh`, which is the one
#     place that reads rc 2 and names it a refusal. A bare invocation is a red.
#
#     REFUSAL-CAPABLE is DERIVED FROM THE SCRIPT'S OWN BYTES, not from a list
#     in this file: `X.sh` is capable iff it contains at least one LIVE `exit 2`
#     statement (see the classifier below). So a script that gains its first
#     `exit 2` tomorrow flips from not-required to required, and its untouched
#     bare call site reds on that commit. Nothing has to be remembered.
#
# A2. THE CHANNEL REACHES THE VERDICT. A capture at the call site that nobody
#     reads is theatre. Every job holding at least one channelled step must
#     declare a `verdict` job output, and the workflow's aggregator job must
#     bind it (`V_<SLUG>: ${{ needs.<job>.outputs.verdict }}`) AND mention that
#     variable inside its decide body. Adding the channel and forgetting the
#     aggregator is the SECOND failure direction, and it is the one that turns
#     a refusal into a pass.
#
# A3. DENOMINATOR. A zero over an empty scan is indistinguishable from a zero
#     over a clean workflow. The check prints what it scanned — workflows,
#     script invocations, the refusal-capable set with each script's live site
#     count — and REFUSES (exit 2) if it found no invocations at all.
#
# THE `exit 2` CLASSIFIER (why a grep is not enough)
# --------------------------------------------------
# `git grep -c 'exit 2'` over these same scripts returns 26. TWELVE of those
# are prose: a comment (`# … REFUSES (exit 2) rather than answer`), a selftest
# assertion string (`bad "should refuse with exit 2, got exit $rc"`), or a
# `usage()` heredoc body (`disclosure (exit 2)`). A count that cannot tell a
# statement from a sentence about a statement measures nothing, and prose is
# exactly what already failed here.
#
# The classifier reads each line as shell:
#   * heredoc BODIES are skipped (`<<EOF` / `<<-'EOF'` … terminator);
#   * quoted spans are removed (single and double, backslash-aware), so
#     `echo "… exit 2 …"` contributes nothing;
#   * a `#` comment is removed when it begins the line or follows whitespace;
#   * what remains counts only when `exit 2` sits in STATEMENT POSITION —
#     at line start, or after `;` `&&` `||` `{` `(` `then` `else` `do`.
# Its own fixtures, one per specimen class above, run under `--selftest`.
#
# SCOPE — and the seam, stated so the next author can see it
# ----------------------------------------------------------
# GUARDED: `cloud.yml`, `elixir.yml`, `security.yml` — every workflow that
# publishes a REQUIRED aggregate context off a `decide()` body reading
# `needs.<job>.result`. That is the whole set the original defect was measured
# in; the guard makes no claim about any workflow outside it, which is the same
# vocabulary it enforces on the instruments.
#
# This guard does NOT assert that a refusal is IMPOSSIBLE in a guarded
# workflow. It asserts that where one is possible it is NAMED: channelled at
# the call site, published as a job verdict, and read by the aggregator. A
# deliberately bare site is an EXEMPTION with its reason on the line.
#
# EXIT CODES: 0 clean · 1 at least one violation · 2 cannot measure.
#
# bash 3.2 compatible (macOS runs it too). POSIX awk only.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The guarded set. One path per line. See SCOPE above before adding to it.
WORKFLOWS_DEFAULT=".github/workflows/cloud.yml .github/workflows/elixir.yml .github/workflows/security.yml"
WORKFLOWS="${REFUSAL_VOCAB_WORKFLOWS:-$WORKFLOWS_DEFAULT}"

# The one wrapper that reads rc 2 and names it.
RUNNER_REL="scripts/run-instrument.sh"

# ── EXEMPTIONS ──────────────────────────────────────────────────────────────
# A refusal-capable script whose call site is deliberately bare, with the
# reason ON THE LINE. An exemption is a claim that rc 2 CANNOT arrive there,
# that nothing downstream could act on it, or that channelling would DESTROY a
# reading the step depends on; it is not a way to quiet the check. Keep it
# short or it stops being read.
#
# TWO KEY SHAPES, and the narrower one wins:
#   <workflow>:<job>:<script>   — this script, in THIS JOB only.
#   <workflow>:<script>         — this script anywhere in the workflow.
#
# The job-scoped key exists because one script is not one decision. In
# elixir.yml `elixir-impacted-tests.sh` is a plain instrument in `path-escape`
# and is channelled there, while in `mix-test` its STDOUT is the payload the
# step captures — two call sites, two correct answers, and a workflow-wide key
# could only give one of them. A guard whose exemption granularity is coarser
# than the decision it records forces the author to over-exempt, and an
# over-broad exemption is how a real bare site hides behind a true reason.
EXEMPTIONS="
cloud.yml:breaker-capture.sh  # not an instrument: a re-exec wrapper. Its own rc 2 fires only when it is called with no step script, which is a wiring bug in the step above it, and it re-execs the step so the step's rc — including 2 — passes through untouched to run-instrument.sh.
cloud.yml:file-ci-failure-issue.sh  # runs in report-main-failure, which is NOT in cloud-gate's needs set and publishes no required context. There is no verdict for its refusal to reach.
security.yml:breaker-capture.sh  # the identical re-exec wrapper cloud.yml exempts, in the identical one-line preamble at every site here: its own rc 2 fires only on a missing step script, and the step's real rc passes through untouched.
elixir.yml:mix-test:elixir-impacted-tests.sh  # both sites here consume the script's OUTPUT, not its verdict. The --xref-probe site runs under continue-on-error and its own step comment says a dead instrument is deliberately NOT a failure, so publishing REFUSED would red the required gate for the exact case that step exists to tolerate. The --select site captures STDOUT as the payload written to the selection file, which run-instrument.sh's own 'instrument X: exit N -> ...' line would corrupt, and that step already reads rc explicitly and falls back to the FULL suite.
elixir.yml:mix-prod-compile:prod-build-cache-guard.sh  # this script does NOT speak the house vocabulary at this site: under a deliberate 'set +e' the step reads its rc as 0=cached / 1=contaminated / 3=fall back and acts on each. run-instrument.sh would map rc 3 to UNKNOWN and collapse three live readings into one exit 1 -- channelling here would destroy a distinction rather than add one. Its --selftest sibling above IS channelled.
elixir.yml:mix-test:prod-build-cache-guard.sh  # the same script, the same deliberate 'set +e' reading of 0=cached / 1=contaminated / 3=fall back, in the test job's copy of the prod site's contract. Channelling would map rc 3 to UNKNOWN and collapse three live readings into one exit 1. The --selftest sibling in this job IS channelled, so a refusal of the harness still reaches outputs.verdict.
elixir.yml:validation-perf:prod-build-cache-guard.sh  # same script, same three-verdict reading, plus: this job publishes NO outputs.verdict for a channelled refusal to travel along -- elixir-gate reads only needs.validation-perf.result, which a non-zero exit already carries fail-closed. Its --selftest site is bare here for that reason and no other.
"

MODE="check"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --selftest) MODE="selftest"; shift ;;
    --list)     MODE="list"; shift ;;
    --workflow) WORKFLOWS="${2:?--workflow needs a path}"; shift 2 ;;
    --root)     REPO_ROOT="${2:?--root needs a directory}"; shift 2 ;;
    *) echo "CANNOT READ: unknown argument $1" >&2
       echo "usage: $0 [--selftest|--list] [--workflow PATH] [--root DIR]" >&2
       exit 2 ;;
  esac
done

# ── the classifier ──────────────────────────────────────────────────────────
# stdin: a shell script. stdout: one line number per LIVE `exit 2` statement.
live_exit2_lines() {
  awk '
    # Truncate at the first UNQUOTED `#`. Quotes survive, because the heredoc
    # reader needs the tag — and the tag is usually quoted (`<<\047EOF\047`).
    # Comment-stripping must happen BEFORE heredoc detection, or the header
    # line above — "heredoc BODIES are skipped (`<<EOF` …)" — opens a phantom
    # heredoc whose terminator never arrives, and every `exit 2` below it goes
    # silently uncounted. That was a real defect in this file, caught by
    # pointing the check at itself.
    function uncomment(s,   i, c, out, q, prev) {
      out = ""; q = ""; prev = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") {
          out = out c
          if (c == "\\" && q == "\"") { i++; out = out substr(s, i, 1); continue }
          if (c == q) q = ""
          continue
        }
        if (c == "\\") { out = out c substr(s, i + 1, 1); i++; prev = ""; continue }
        if (c == "\047" || c == "\"") { q = c; out = out c; prev = c; continue }
        if (c == "#" && (prev == "" || prev == " " || prev == "\t")) break
        out = out c
        prev = c
      }
      return out
    }
    # remove quoted spans; return the code that is left
    function decode(s,   i, c, out, q, prev) {
      out = ""; q = ""; prev = " "
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") {
          if (c == "\\" && q == "\"") { i++; continue }
          if (c == q) { q = ""; out = out " " }
          continue
        }
        if (c == "\\") { i++; out = out " "; prev = " "; continue }
        if (c == "\047" || c == "\"") { q = c; continue }
        if (c == "#" && (prev == " " || prev == "\t" || out == "")) break
        out = out c
        prev = c
      }
      return out
    }
    {
      line = $0

      # ── heredoc bodies are text, not code ──
      if (hd != "") {
        t = line; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        if (t == hd) hd = ""
        next
      }
      # the heredoc OPENER is read off the UNCOMMENTED line: decode() strips
      # quotes and `<<\047USAGE\047` loses its tag to that strip, while the raw
      # line would let a COMMENT about heredocs open one.
      bare = uncomment(line)
      if (match(bare, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*/)) {
        tag = substr(bare, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*[\047"]?/, "", tag)
        hd = tag
      }
      code = decode(bare)

      # ── statement position ──
      # a leading sentinel so a line-start match has something to anchor on
      probe = ";" code
      if (probe ~ /[;&|{][ \t]*exit[ \t]+2([ \t]*[;&|)}]|[ \t]*$)/) { print NR; next }
      if (probe ~ /(then|else|do)[ \t]+exit[ \t]+2([ \t]*[;&|)}]|[ \t]*$)/) { print NR }
    }
  '
}

is_capable() {  # $1 = absolute path to a script
  [ -r "$1" ] || return 1
  [ -n "$(live_exit2_lines < "$1")" ]
}

capable_count() { live_exit2_lines < "$1" | wc -l | tr -d ' '; }

exemption_reason() {  # $1 = wf basename, $2 = job, $3 = script basename
  # NARROWEST FIRST. A job-scoped row must be able to say something the
  # workflow-wide row for the same script does not, so it wins outright; the
  # workflow-wide key is only consulted when no job-scoped row matched.
  printf '%s\n' "$EXEMPTIONS" | awk -v ks="$1:$2:$3" -v kw="$1:$3" '
    $1 == ks { sub(/^[^ \t]+[ \t]*/, ""); print; found = 1; exit }
    $1 == kw && w == "" { w = $0; sub(/^[^ \t]+[ \t]*/, "", w) }
    END { if (!found && w != "") print w }'
}

# ── the workflow reader ─────────────────────────────────────────────────────
# stdin: a workflow file. stdout, one record per LIVE script invocation:
#   INVOKE <line> <job> <script-rel> <through-runner:0|1>
# and one record per job that owns at least one runner-channelled step:
#   CHANNELJOB <job>
# A YAML comment line (first non-space char `#`) is not an invocation — that is
# how the prose-vs-code distinction is drawn on this side too.
scan_workflow() {
  awk -v runner="$RUNNER_REL" '
    function trimc(s) { sub(/^[ \t]+/, "", s); return s }
    # An INVOCATION, not a MENTION. `pin_script="scripts/x.sh"`,
    # `git show ref:scripts/x.sh` and `[ -f "$GITHUB_WORKSPACE/scripts/x.sh" ]`
    # all name the script and none of them RUNS it; scoring a mention as a call
    # site is how a guard accumulates reds nobody can act on. The text
    # immediately left of the reference must be an interpreter word once the
    # quoting and any `$VAR/` path prefix are peeled off.
    function invoked(pre,   before) {
      do {
        before = pre
        sub(/[\047"]$/, "", pre)
        sub(/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\/$/, "", pre)
        sub(/[ \t]+$/, "", pre)
      } while (pre != before)
      return (pre ~ /(^|[ \t;&|(){}])(bash|sh|zsh|exec bash|exec sh)$/) || (pre ~ /\.$/)
    }
    {
      raw = $0
      t = trimc(raw)
      indent = match(raw, /[^ ]/) - 1

      # top-level job key: exactly two spaces of indent, `name:` shape
      if (raw ~ /^  [A-Za-z0-9_-]+:[ \t]*(#.*)?$/) {
        job = raw; sub(/^  /, "", job); sub(/:.*$/, "", job)
        next
      }
      if (t ~ /^#/) next                    # a comment is prose, never a call

      # A single `run:` line can name TWO scripts — the wrapper and the
      # instrument it wraps — so walk every reference on the line, not the
      # first. Reading only the first is how a channelled call site would
      # read as no call site at all.
      rest = raw
      through = (raw ~ runner) || (prev ~ runner) || (prev2 ~ runner)
      while (match(rest, /scripts\/[A-Za-z0-9_.-]+\.(sh|mjs)/)) {
        s = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        if (s == runner) continue           # the wrapper itself
        if (!invoked(substr(raw, 1, length(raw) - length(rest) - length(s)))) continue
        printf "INVOKE %d %s %s %d\n", NR, job, s, through
        if (through) printf "CHANNELJOB %s\n", job
      }
      prev2 = prev; prev = raw
    }
  '
}

# ── A2: the aggregator binding ──────────────────────────────────────────────
# stdin: the workflow. Prints `BOUND <job>` for every job whose verdict output
# is both bound to a `V_*` env in some job and mentioned in that job's body.
scan_bindings() {
  awk '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (match(line[i], /V_[A-Z0-9_]+:[ \t]*\$\{\{[ \t]*needs\.[A-Za-z0-9_-]+\.outputs\.verdict/)) {
          v = line[i]; sub(/^[ \t]*/, "", v); var = v; sub(/:.*$/, "", var)
          j = line[i]; sub(/^.*needs\./, "", j); sub(/\.outputs\.verdict.*$/, "", j)
          used = 0
          # `${V_X}`, `${V_X:-}`, `"$V_X"`, `$V_X ` all count as a read. The
          # guard must not push the author towards one spelling — a `:-`
          # default is the CORRECT spelling here, because an empty verdict is
          # legitimate (the job skipped) and the decide body runs under
          # `set -u`.
          for (k = i + 1; k <= NR; k++)
            if (line[k] ~ ("[$][{]" var "([:}]|-)") || line[k] ~ ("[$]" var "([^A-Za-z0-9_]|$)")) { used = 1; break }
          if (used) printf "BOUND %s\n", j
          else printf "UNUSED %s %s\n", j, var
        }
      }
    }
  '
}

declares_verdict() {  # $1 = workflow path, $2 = job
  awk -v job="$2" '
    $0 ~ "^  " job ":[ \t]*(#.*)?$" { inj = 1; next }
    inj && /^  [A-Za-z0-9_-]+:[ \t]*(#.*)?$/ { inj = 0 }
    inj && /^    outputs:/ { ino = 1; next }
    inj && ino && /^    [a-z]/ { ino = 0 }
    inj && ino && /^      verdict:/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# ── the check ───────────────────────────────────────────────────────────────
run_check() {
  local bad=0 n_invoke=0 n_capable=0 wf wfpath base
  echo "gate-refusal-vocabulary-check — guarded workflows:"
  printf '%s\n' "$WORKFLOWS" | tr ' ' '\n' | while read -r wf; do [ -n "$wf" ] && echo "  $wf"; done
  echo

  local tmp; tmp="$(mktemp -t refvocab.XXXXXX)" || { echo "CANNOT MEASURE: mktemp failed" >&2; return 2; }
  : > "$tmp"

  for wf in $WORKFLOWS; do
    wfpath="$REPO_ROOT/$wf"
    if [ ! -r "$wfpath" ]; then
      echo "CANNOT MEASURE: guarded workflow $wf is not readable at $wfpath" >&2
      rm -f "$tmp"; return 2
    fi
    base="$(basename "$wf")"
    echo "── $wf ──"

    scan_workflow < "$wfpath" > "$tmp.scan"
    local chan_jobs; chan_jobs="$(awk '$1=="CHANNELJOB"{print $2}' "$tmp.scan" | sort -u)"

    # A1
    while read -r _tag lno job srel through; do
      [ "$_tag" = "INVOKE" ] || continue
      n_invoke=$((n_invoke + 1))
      local sabs="$REPO_ROOT/$srel" sbase; sbase="$(basename "$srel")"
      if ! is_capable "$sabs"; then
        printf '  ok      %s:%s  %s — not refusal-capable (0 live exit-2 statements)\n' "$base" "$lno" "$srel"
        continue
      fi
      n_capable=$((n_capable + 1))
      local sites; sites="$(capable_count "$sabs")"
      if [ "$through" = "1" ]; then
        printf '  ok      %s:%s  %s — %s live exit-2 site(s), channelled through %s\n' "$base" "$lno" "$srel" "$sites" "$RUNNER_REL"
        continue
      fi
      local why; why="$(exemption_reason "$base" "$job" "$sbase")"
      if [ -n "$why" ]; then
        printf '  ok      %s:%s  %s — EXEMPT: %s\n' "$base" "$lno" "$srel" "$why"
        continue
      fi
      printf '  FAIL    %s:%s  %s is REFUSAL-CAPABLE (%s live exit-2 statement(s)) and is invoked BARE.\n' "$base" "$lno" "$srel" "$sites"
      printf '          Its rc 2 means "I could not measure". Invoked like this, rc 2 and rc 1 both\n'
      printf '          arrive at needs.%s.result as the string "failure", and the aggregator cannot\n' "$job"
      printf '          tell a refusal from a defect. Route it through %s, or\n' "$RUNNER_REL"
      printf '          add a %s:%s:%s (or the workflow-wide %s:%s) exemption WITH THE REASON in this script.\n' "$base" "$job" "$sbase" "$base" "$sbase"
      echo 1 >> "$tmp"
    done < "$tmp.scan"

    # A2
    local bound; bound="$(scan_bindings < "$wfpath")"
    for job in $chan_jobs; do
      if ! declares_verdict "$wfpath" "$job"; then
        printf '  FAIL    %s: job `%s` channels a refusal but declares no `outputs.verdict`.\n' "$base" "$job"
        printf '          The capture at the call site has nowhere to go.\n'
        echo 1 >> "$tmp"; continue
      fi
      if printf '%s\n' "$bound" | grep -q "^BOUND $job\$"; then
        printf '  ok      %s: job `%s` publishes outputs.verdict and the aggregator reads it\n' "$base" "$job"
      elif printf '%s\n' "$bound" | grep -q "^UNUSED $job "; then
        printf '  FAIL    %s: job `%s` verdict is bound to a V_* env the decide body never reads.\n' "$base" "$job"
        printf '          A bound-but-unread verdict is the SECOND failure direction: the refusal is\n'
        printf '          carried all the way to the aggregator and then dropped.\n'
        echo 1 >> "$tmp"
      else
        printf '  FAIL    %s: job `%s` publishes outputs.verdict but NO aggregator job binds it\n' "$base" "$job"
        printf '          as `V_<SLUG>: ${{ needs.%s.outputs.verdict }}`. Nothing downstream can\n' "$job"
        printf '          distinguish its refusal from its defect.\n'
        echo 1 >> "$tmp"
      fi
    done
    echo
  done

  bad="$(wc -l < "$tmp" | tr -d ' ')"
  rm -f "$tmp" "$tmp.scan"

  # A3 — the denominator
  echo "scanned: ${n_invoke} live script invocation(s), ${n_capable} of them refusal-capable"
  if [ "$n_invoke" -eq 0 ]; then
    echo "CANNOT MEASURE: the workflow reader found ZERO script invocations. A clean" >&2
    echo "verdict over an empty scan is not a clean verdict — most likely the YAML" >&2
    echo "shape changed under the reader. Refusing (exit 2) rather than greening." >&2
    return 2
  fi
  if [ "$bad" -ne 0 ]; then
    echo "REFUSAL VOCABULARY: ${bad} violation(s) above."
    return 1
  fi
  echo "REFUSAL VOCABULARY: every refusal-capable instrument in the guarded set declares its channel."
  return 0
}

run_list() {
  local wf wfpath srel
  for wf in $WORKFLOWS; do
    wfpath="$REPO_ROOT/$wf"
    scan_workflow < "$wfpath" | awk '$1=="INVOKE"{print $4}' | sort -u | while read -r srel; do
      if is_capable "$REPO_ROOT/$srel"; then
        printf 'CAPABLE     %-52s %s live exit-2 site(s): %s\n' "$srel" "$(capable_count "$REPO_ROOT/$srel")" \
          "$(live_exit2_lines < "$REPO_ROOT/$srel" | tr '\n' ',' | sed 's/,$//')"
      else
        printf 'not capable %s\n' "$srel"
      fi
    done
  done
}

# ── selftest ────────────────────────────────────────────────────────────────
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  BAD  %s\n' "$1"; }

run_selftest() {
  echo "gate-refusal-vocabulary-check --selftest"
  echo
  echo "── the exit-2 classifier: one fixture per specimen class on main ──"
  local d; d="$(mktemp -d -t refvocabst.XXXXXX)" || { echo "CANNOT MEASURE: mktemp -d failed" >&2; return 2; }

  # Every fixture below is a VERBATIM shape lifted from a script cloud.yml runs.
  cat > "$d/mixed.sh" <<'FIX'
#!/usr/bin/env bash
# check REFUSES (exit 2) rather than answer.            <- comment: NOT live
usage() {
  cat <<'USAGE'
  --require-db    disclosure (exit 2)
USAGE
}
  *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
    ok "a missing Go source root REFUSES (exit 2), not a clean tree"
  else bad "should refuse with exit 2, got exit $rc"; fi
echo "UNCHECKED: this refusal is exit 2 — a toolchain refusal." >&2
exit 2
[ -n "$S" ] || { echo "no step script given" >&2; exit 2; }
if [ -z "$x" ]; then exit 2; fi
FIX
  local got want
  got="$(live_exit2_lines < "$d/mixed.sh" | tr '\n' ' ' | sed 's/ $//')"
  want="8 12 13 14"
  if [ "$got" = "$want" ]; then
    ok "classifier: 4 live statements found, 5 prose occurrences (comment, heredoc body, two quoted selftest strings, one quoted echo) correctly ignored"
  else
    bad "classifier: expected live lines '$want', got '$got'"
    awk '{printf "       %2d %s\n", NR, $0}' "$d/mixed.sh"
  fi

  cat > "$d/phantom-heredoc.sh" <<'FIX'
#!/usr/bin/env bash
# heredoc BODIES are skipped (`<<EOF` / `<<-'EOF'` … terminator)
exit 2
FIX
  if [ "$(live_exit2_lines < "$d/phantom-heredoc.sh")" = "3" ]; then
    ok "classifier: a COMMENT mentioning \`<<EOF\` does not open a heredoc that swallows the rest of the file"
  else
    bad "classifier: a commented-out heredoc opener swallowed the file (this exact defect lived in THIS script)"
  fi

  cat > "$d/prose-only.sh" <<'FIX'
#!/usr/bin/env bash
# EXIT CODES: 0 clean · 1 defect · 2 exit 2 cannot measure
echo "the sibling would exit 2 here"
FIX
  if [ -z "$(live_exit2_lines < "$d/prose-only.sh")" ]; then
    ok "classifier: a script that only TALKS about exit 2 is not refusal-capable"
  else bad "classifier: prose-only script was called capable"; fi

  cat > "$d/one.sh" <<'FIX'
#!/usr/bin/env bash
exit 2
FIX
  if is_capable "$d/one.sh"; then ok "classifier: a bare \`exit 2\` statement IS capable"
  else bad "classifier: a bare exit 2 was not detected"; fi

  echo
  echo "── the guard, mutation-proved in BOTH directions ──"

  # A synthetic repo: a workflow + a script, so the proof does not depend on
  # the state of the real one.
  mkdir -p "$d/repo/scripts" "$d/repo/.github/workflows"
  cp "$REPO_ROOT/$RUNNER_REL" "$d/repo/$RUNNER_REL" 2>/dev/null || printf '#!/usr/bin/env bash\nexit 0\n' > "$d/repo/$RUNNER_REL"
  printf '#!/usr/bin/env bash\necho clean\nexit 0\n' > "$d/repo/scripts/probe.sh"
  cat > "$d/repo/.github/workflows/fix.yml" <<'FIX'
name: fix
on: [push]
jobs:
  work:
    name: Work
    runs-on: ubuntu-latest
    steps:
      - name: Probe
        run: bash scripts/probe.sh
  agg:
    name: Gate
    needs: [work]
    runs-on: ubuntu-latest
    steps:
      - name: Decide
        run: echo done
FIX
  local out rc
  out="$(REFUSAL_VOCAB_WORKFLOWS=".github/workflows/fix.yml" bash "$0" --root "$d/repo" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "GREEN BEFORE: a bare call site is fine while the script cannot refuse (rc=0)"
  else bad "GREEN BEFORE: expected rc 0 on the unmutated fixture, got $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  # ── THE MUTATION: the script gains its FIRST exit 2. The workflow is not
  #    touched. This is the case the whole guard exists for.
  printf '#!/usr/bin/env bash\nif [ -z "${DB:-}" ]; then echo "CANNOT MEASURE: no DB" >&2; exit 2; fi\nexit 0\n' > "$d/repo/scripts/probe.sh"
  out="$(REFUSAL_VOCAB_WORKFLOWS=".github/workflows/fix.yml" bash "$0" --root "$d/repo" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'REFUSAL-CAPABLE .* and is invoked BARE'; then
    ok "RED AFTER: a NEWLY ADDED, UNDECLARED exit 2 reds the guard with the workflow byte-identical (rc=1)"
  else
    bad "RED AFTER: expected rc 1 naming the bare call site, got rc=$rc"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # ── the remedy makes it green again: channel + verdict + aggregator read
  cat > "$d/repo/.github/workflows/fix.yml" <<'FIX'
name: fix
on: [push]
jobs:
  work:
    name: Work
    runs-on: ubuntu-latest
    outputs:
      verdict: ${{ steps.probe.outputs.verdict }}
    steps:
      - name: Probe
        id: probe
        run: bash scripts/run-instrument.sh probe -- bash scripts/probe.sh
  agg:
    name: Gate
    needs: [work]
    runs-on: ubuntu-latest
    steps:
      - name: Decide
        env:
          V_WORK: ${{ needs.work.outputs.verdict }}
        run: |
          echo "verdict: ${V_WORK}"
FIX
  out="$(REFUSAL_VOCAB_WORKFLOWS=".github/workflows/fix.yml" bash "$0" --root "$d/repo" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "GREEN AFTER REMEDY: channel + outputs.verdict + an aggregator that READS it"
  else bad "GREEN AFTER REMEDY: expected rc 0, got $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  # ── the SECOND direction: the verdict is bound and then never read.
  # a `:-` default is still a READ — the guard must not force one spelling
  sed -i.bak 's/echo "verdict: ${V_WORK}"/echo "verdict: ${V_WORK:-}"/' "$d/repo/.github/workflows/fix.yml"
  out="$(REFUSAL_VOCAB_WORKFLOWS=".github/workflows/fix.yml" bash "$0" --root "$d/repo" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "a \`\${V_X:-}\` default counts as a read (an empty verdict is legitimate and decide runs under set -u)"
  else bad "expected rc 0 with a :- default read, got $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  sed -i.bak 's/echo "verdict: ${V_WORK:-}"/echo "nothing to see"/' "$d/repo/.github/workflows/fix.yml"
  out="$(REFUSAL_VOCAB_WORKFLOWS=".github/workflows/fix.yml" bash "$0" --root "$d/repo" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'never reads'; then
    ok "RED: a verdict bound into the aggregator's env and never read is caught (the refusal-scored-as-a-pass direction)"
  else
    bad "RED (unread verdict): expected rc 1, got rc=$rc"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # ── A3: the denominator refuses rather than greening on an empty scan.
  cat > "$d/repo/.github/workflows/fix.yml" <<'FIX'
name: fix
on: [push]
jobs:
  work:
    runs-on: ubuntu-latest
    steps:
      - run: echo "no scripts here at all"
FIX
  out="$(REFUSAL_VOCAB_WORKFLOWS=".github/workflows/fix.yml" bash "$0" --root "$d/repo" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ]; then ok "A3: an EMPTY scan REFUSES (exit 2) instead of reporting a clean zero"
  else bad "A3: expected rc 2 on an empty scan, got $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  # ── EXEMPTION KEYS: the narrow key must be able to say what the broad one
  #    cannot, and must NOT fire for a job it does not name. Both directions,
  #    because an exemption that matches too widely is a blind spot wearing a
  #    reason, and that is worse than a missing row.
  exr() { exemption_reason "$1" "$2" "$3"; }
  saved_EXEMPTIONS="$EXEMPTIONS"
  EXEMPTIONS="
w.yml:probe.sh  # broad reason
w.yml:jobA:probe.sh  # narrow reason
"
  [ "$(exr w.yml jobA probe.sh)" = "# narrow reason" ] \
    && ok "exemption: the JOB-scoped row wins over the workflow-wide one" \
    || bad "exemption: jobA should read the narrow row, got '$(exr w.yml jobA probe.sh)'"
  [ "$(exr w.yml jobB probe.sh)" = "# broad reason" ] \
    && ok "exemption: a job with no narrow row falls back to the workflow-wide one" \
    || bad "exemption: jobB should fall back to the broad row, got '$(exr w.yml jobB probe.sh)'"
  EXEMPTIONS="
w.yml:jobA:probe.sh  # narrow reason
"
  [ -z "$(exr w.yml jobB probe.sh)" ] \
    && ok "exemption: a JOB-scoped row does NOT exempt a different job" \
    || bad "exemption: jobB matched a jobA-scoped row — the key is not job-scoped"
  [ -z "$(exr other.yml jobA probe.sh)" ] \
    && ok "exemption: a row does not leak across workflows" \
    || bad "exemption: other.yml matched w.yml's row"
  EXEMPTIONS="$saved_EXEMPTIONS"

  # ── NO BACKTICK MAY APPEAR IN THE EXEMPTIONS TABLE. It is a double-quoted
  #    shell string, so a backtick span is COMMAND SUBSTITUTION: it runs at
  #    source time and the reason silently loses the text between the ticks.
  #    Measured while this table was being written — `set +e` in a reason both
  #    executed and vanished from the printed exemption. The assertion reads
  #    the SOURCE, not the expanded variable, because by the time the variable
  #    exists the damage is already done and invisible.
  if awk '/^EXEMPTIONS="$/{i=1;next} /^"$/{i=0} i' "$0" | grep -q '`'; then
    bad "EXEMPTIONS contains a backtick — that span is command substitution, not prose"
  else
    ok "EXEMPTIONS carries no backtick (a backtick there would RUN, not quote)"
  fi
  # the control: the detector must be able to see one at all
  if printf 'EXEMPTIONS="\nx.yml:y.sh  # a `tick` here\n"\n' | awk '/^EXEMPTIONS="$/{i=1;next} /^"$/{i=0} i' | grep -q '`'; then
    ok "…and that backtick detector fires on a planted one (it is not blind)"
  else
    bad "the backtick detector found nothing in a fixture that CONTAINS one"
  fi

  # ── the guard speaks its own vocabulary: an unknown argument refuses.
  out="$(bash "$0" --no-such-flag 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ]; then ok "an unrecognised argument REFUSES (exit 2), it does not report a clean tree"
  else bad "unknown argument should refuse with exit 2, got $rc"; fi

  rm -rf "$d"
  echo
  echo "# pass $PASS"
  echo "# fail $FAIL"
  [ "$FAIL" -eq 0 ] || return 1
  return 0
}

case "$MODE" in
  selftest) run_selftest; exit $? ;;
  list)     run_list; exit $? ;;
  check)    run_check; exit $? ;;
esac
