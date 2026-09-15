#!/usr/bin/env bash
#
# stale-pr-citation-detector.sh — a comment whose CLAIM about the repo is
# contradicted by the repo, where the comment names a CHECKABLE REFERENT
# (a PR number). Comments, docstrings AND string constants; no comment-prefix
# constraint.
#
# ---------------------------------------------------------------------------
# WHY THIS SHAPE AND NOT THE OBVIOUS ONE — and why the obvious one is NOT here.
# ---------------------------------------------------------------------------
# THE IMPOSSIBILITY-VOCABULARY APPROACH IS DELIBERATELY NOT SHIPPED. Do not
# re-derive it; it was measured on 2026-09-07 with the corpus split into two
# competing feature arms and scored separately:
#
#   ARM 1 — impossibility vocabulary ("does not carry", "no way to",
#           "cannot", "not available"):        215 lines examined, ZERO confirmed.
#   ARM 2 — comments naming a PENDING CHANGE
#           ("until it lands", a PR number):    87 lines examined, ALL FIVE confirmed.
#
# Whole-sweep precision for the vocabulary approach was 2.5% raw / ~11% refined
# on the Elixir arm and 0.52% of a 958-line starting corpus on the Go/shell/JS
# arm. That is an audit aid at best, and no better word list rescues it — see
# noise family N4 below, which a keyword matcher cannot see at all.
#
# THE DISCRIMINATING PROPERTY IS NOT THAT A COMMENT CLAIMS AN IMPOSSIBILITY.
# IT IS THAT THE COMMENT CITES A CHECKABLE REFERENT. "Until PR #14863 lands"
# resolves mechanically against the repo. "X is not available" cannot be
# resolved at all, and yields only noise.
#
# ---------------------------------------------------------------------------
# AND THE SECOND RULE: VERIFY THE CLAIM, NOT THE CITATION.
# ---------------------------------------------------------------------------
# A PR number is NOT a stable key for "did this land". Two measured cases:
#   - #15489 re-landed as #15897.
#   - #11337 is CLOSED with mergedAt null — IT NEVER MERGED — and the comment
#     citing it in the present tense is STILL TRUE, because the work re-landed
#     as #11104/#11376.
# A naive closed-state lookup gets that exactly backwards: it sees CLOSED +
# never-merged + present tense and concludes the claim must be false, when the
# claim is the one part that is right.
#
# So the verdict is driven by CONTENT, never by PR state:
#
#   claim says the symbol is ABSENT  + symbol IS in the tree  -> STALE-CLAIM
#   claim says the symbol is PRESENT + symbol NOT in the tree -> FALSE-CLAIM
#   claim says ABSENT  + symbol absent   -> clean
#   claim says PRESENT + symbol present  -> clean (the citation may still be
#                                          dead; see DEAD-CITATION below)
#
# "In the tree" means ON A NON-COMMENT LINE. A symbol that appears only inside
# the comments that discuss it has not landed — counting those makes every
# citing comment vouch for itself.
#
# DEAD-CITATION / LIVE-CLAIM is a SEPARATE, LOWER severity and needs PR state,
# so it is reported only under --with-pr-state (which shells out to `gh`).
# ITS REMEDY IS TO RE-CITE, NOT TO REWRITE. A detector that rewrites the
# sentence there makes a TRUE statement WORSE. The tool never rewrites anything.
#
# ---------------------------------------------------------------------------
# THE FOUR NOISE FAMILIES, EXCLUDED STRUCTURALLY (not tuned away one at a time)
# ---------------------------------------------------------------------------
# Every one of them dies FIRST at the referent gate, because none of them
# carries a PR number. Each ALSO has a structural stance rule, so a specimen
# that happens to carry a citation is still excluded, and each has a fixture in
# --selftest that is proved to be a genuine specimen of its family before it is
# asserted excluded:
#
#   N1 GOAL STATEMENT — "exists to make X impossible". The house style for gate
#      rationale (~70 lines). A PURPOSE CLAUSE is not a factual claim about
#      repo state, so it can never be contradicted by repo state.
#   N2 REDACTION INVARIANT — "never carries a token/secret". An INVARIANT is a
#      requirement on the code, not a report about it. Obsoleting one is a BUG
#      REPORT, not a stale comment — the opposite of this defect class.
#   N3 HANDLED FAIL-CLOSED ARM — "cannot be read". Describes a RUNTIME BRANCH
#      being handled correctly, not the state of the repo.
#   N4 PAST-TENSE NARRATION — "had no way to ...". Narrates the bug the commit
#      just FIXED. It is the INVERSE of the target class and reads as a live
#      impossibility until you notice the tense. This family is why a
#      vocabulary detector cannot be rescued by a better word list.
#
#   N5 RUNTIME STATE (added 2026-09-07 by a second fence run) — "lands" /
#      "does not exist yet" said about RUNTIME state, not about a code change
#      ("until the job lands", "does not exist yet at this point in the
#      request"). Excluded by the referent gate: no PR number, no candidate.
#
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# MEASURED PRECISION, 2026-09-15, and THE VERDICT IT DECIDES
# ---------------------------------------------------------------------------
# THIS IS AN AUDIT AID. IT DOES NOT EARN A GATE. Only --selftest runs in CI.
#
# CORPUS, hand-labelled BEFORE the detector existed and before any scoring
# (labels frozen to disk first; the labeller had not yet looked at which files
# the real remediation touched). Tree A = 206a4d0530 = aaf6ce097^, the tree as
# it stood BEFORE commit aaf6ce097 ("SuccessExitStatus=143 LANDED — seven sites
# now say legacy box, not pending PR", #16800, 2026-09-08) remediated it.
# Labels: 6 POSITIVE, 3 NEGATIVE across 9 files / 117 citation lines.
# An INDEPENDENT ORACLE agreed 9/9: that commit touched exactly the 6 labelled
# positives and left all 3 labelled negatives alone, and its own message says
# "six naming #14863 as pending".
#
#   TREE A, the 9 labelled files:  TP 5 · FP 0 · FN 1 · TN 111
#     precision 5/5 = 100%   recall 5/6 = 83%   FP rate 0/111 = 0.0%
#   TREE B (HEAD, post-remediation), same invocation: 0 findings / 35 candidates.
#
#   BUT THAT CORPUS HAS ONE REFERENT (#14863) AND ONE DEFECT FAMILY, so 100% is
#   NOT a precision estimate. ON THE WHOLE TREE it is much worse, and that is
#   the number that decides the verdict:
#     WIDE arm  : 29 findings / 2099 citation lines. Adjudicated sample of 7:
#                 ONE true positive, six false. ~14% precision.
#     --strict  :  2 findings / 2081 citation lines. ONE true, one false.
#                 FP rate 1/2081 = 0.05%, but n=2 is not a precision measurement.
#
#   THE ONE CONFIRMED TRUE POSITIVE ON TODAY'S MAIN, found by this tool:
#     internal/cli/cloud_site_cmd.go — "this key is simply unreachable until
#     #11209 lands: MERGE THAT FIRST". #11209 MERGED 2026-08-09T15:34:26Z, and
#     `abandonment_bound` is live on non-comment lines with a test asserting it
#     equals 6. The comment is false by construction.
#
# WHY THE WIDE ARM IS WORSE, stated rather than tuned away: --strict keeps only
# a stance from an EXPLICIT PENDING FRAME ("until #N lands"). The wide arm also
# accepts a generic deficiency ("has no X", "is missing X"), and there the
# deficiency is almost always about something OTHER than the code-shaped symbol
# the extractor bound it to. That is ARM 2 of the 2026-09-07 sweep holding up
# and my generalisation of it not holding up.
#
# KNOWN UNDECIDABLE CLASS, NOT TUNED AWAY: a citation whose window yields no
# code-shaped symbol cannot be resolved by content (152 of 400 candidates on the
# full tree). Those are COUNTED and printed under UNDECIDABLE rather than
# dropped or guessed. The surviving false positives are the same class one step
# on — a symbol WAS extracted and it was the wrong one.
#
# KNOWN RECALL CEILING, STATED: the real remediation of the #14863 corpus
# (aaf6ce097, 2026-09-08) fixed SEVEN sites; only SIX named the PR. The seventh
# made the identical false claim with NO citation at all and is structurally
# invisible to this detector. That is the price of the referent gate and it is
# the right price — the vocabulary arm that could have seen it scored 0/215.
#
# EXIT: 0 no findings · 1 findings · 2 cannot measure.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.
# POSIX classes only in git grep -E: never \s or \d, which are PCRE and
# silently under-match. Flags ALWAYS precede the rev: `git grep -inE "$X" -i REV`
# resolves the trailing -i AS A REVISION, exits 128 with zero output, and reads
# exactly like a clean tree.

set -uo pipefail

ROOT="${DETECTOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WINDOW="${DETECTOR_WINDOW:-2}"

# The scan scope. Source trees only. Markdown is EXCLUDED BY DESIGN: the
# charters under .claude/workflows/ and the ledgers under tooling/grip/ledger/
# are append-only DECISION LOGS whose entire job is to narrate history in the
# tense it happened. A citation there is a record, never a claim about today.
PATHSPECS="${DETECTOR_PATHSPECS:-*.ex *.exs *.go *.js *.mjs *.sh *.heex *.service}"

# GENERATED ARTEFACTS carry no authored comment and must never be scanned. A
# minified bundle is one enormous line, so the +/-2-line window swallows
# kilobytes of machine output and any `#`-plus-digits inside it reads as a
# citation. Measured: 4 of the 6 --strict findings on the first full-tree run
# were bundles matching #000000 — a CSS HEX COLOUR.
EXCLUDES=':(exclude)*.bundle.js :(exclude)*.min.js :(exclude)*/priv/static/assets/* :(exclude)web/public/* :(exclude)*/node_modules/*'


usage() {
  cat <<'USAGE'
usage: stale-pr-citation-detector.sh [--rev REV] [--selftest] [--with-pr-state] [-v]
  --rev REV        scan this tree (default: HEAD)
  --selftest       run the fixture arms and exit
  --strict         keep only stances from an EXPLICIT PENDING FRAME
                   ("until #N lands"). The high-precision arm; see the header.
  --with-pr-state  additionally resolve each citation's PR state via `gh`
                   to separate DEAD-CITATION/LIVE-CLAIM (remedy: re-cite)
  -v               print every candidate with its stance and verdict
USAGE
}

# ---------------------------------------------------------------------------
# stance <window-text>  ->  ABSENT | PRESENT | NONE
#
# ABSENT : the window asserts the cited thing is not in the tree.
# PRESENT: the window asserts it is.
# NONE   : no claim about repo state -> not a candidate. The four noise
#          families land here, as does a bare "see #12345".
# ---------------------------------------------------------------------------
stance() {
  local w="$1"
  # DETECTOR_BYPASS names ONE noise family to skip. It exists only so
  # --selftest can prove each family rule is LOAD-BEARING: with the rule
  # bypassed the same fixture MUST become a finding. Four rules that pass their
  # arms while doing nothing is the failure this switch exists to expose — the
  # first draft of this file had exactly that, and the arms were all green.
  local bypass="${DETECTOR_BYPASS:-}"

  # --- STRUCTURAL EXCLUSIONS, applied BEFORE any stance word is read. -------
  # N4 PAST-TENSE NARRATION. First, because it is the family that reads most
  # like a live claim. A past frame describes a world that no longer exists,
  # so present repo state cannot contradict it.
  [ "$bypass" = N4 ] || case "$w" in
    *"had no way"*|*"used to "*|*"previously"*|*"formerly"*|*"historically"*|\
    *"at the time"*|*"no longer"*|*"before #"*|*"prior to #"*|*"back when"*)
      echo NONE; return ;;
  esac
  # N1 GOAL STATEMENT. A purpose clause states intent, not fact.
  [ "$bypass" = N1 ] || case "$w" in
    *"exists to "*|*"exist to "*|*"in order to "*|*"the point of "*|\
    *"designed to "*|*"so that "*|*"whose job is"*|*"is there to "*)
      echo NONE; return ;;
  esac
  # N2 REDACTION INVARIANT. A requirement on the code, not a report about it.
  if [ "$bypass" != N2 ] && printf '%s' "$w" | grep -qiE '(never|must not|does not|do not)[^.]{0,40}(carr(y|ies)|contain|include|log|expose|leak|hold)[^.]{0,40}(token|secret|credential|password|api key|bearer)'; then
    echo NONE; return
  fi
  # N3 HANDLED FAIL-CLOSED ARM. A runtime branch, not repo state.
  if [ "$bypass" != N3 ] && printf '%s' "$w" | grep -qiE '(cannot|can not|could not|couldn.t)[[:space:]]+be[[:space:]]+(read|decrypted|parsed|reached|resolved|loaded|opened)'; then
    echo NONE; return
  fi

  # N5 RUNTIME STATE. A deficiency verb whose SUBJECT is a running thing — a
  # box, an agent, an instance, a node — reports the state of the FLEET, not of
  # the repo, so repo content cannot contradict it. "a box that predates the
  # probe sends no such key" is true forever and is not a stale comment. Named
  # by a second fence run on 2026-09-07 ("lands"/"does not exist yet" said about
  # RUNTIME state); it produced 2 of the 6 false positives in the first measured
  # run here, which is the second independent sighting of the same family.
  #
  # IT IS THIS NARROW ON PURPOSE, AND THE FIRST DRAFT WAS NOT. A wider version
  # keyed on "<noun> lacks" also matched "the unit lacks SuccessExitStatus" —
  # the exact shape of FIVE of the six real positives. It deleted the whole
  # true-positive class, and the suite still reported 20 of 21 arms green. So
  # the RELATIVE CLAUSE ("a box THAT predates") is required, and `unit`/`slot`
  # are NOT runtime nouns here: a systemd unit FILE is a repo artifact and a
  # claim about it IS checkable.
  if [ "$bypass" != N5 ] && printf '%s' "$w" | grep -qiE '\b(an?|the|every|any|some|each)[[:space:]]+(box|agent|instance|node|consumer|tenant|client|deployment)[[:space:]]+that[[:space:]]+(predates|lacks|has no|is missing|does not|sends no|omits|carries no)'; then
    echo NONE; return
  fi

  # --- STANCE, in PRECEDENCE order. An EXPLICIT PENDING FRAME outranks
  # everything: "until it lands" is a temporal claim that the thing has not
  # happened, and it beats a tenseless verb in the same window. "PR #N adds X.
  # Until it lands, ..." is PENDING, and testing PRESENT first read it SHIPPED
  # and silently dropped 2 of the 6 real positives.
  if printf '%s' "$w" | grep -qiE 'until (it|#?[0-9]{3,6}) lands|does not exist yet|not yet (landed|merged|shipped|there)|still (pending|open)\b|once (it|#?[0-9]{3,6}) lands'; then
    echo ABSENT-FRAME; return
  fi
  # --- Then PRESENT, which is tested before the deficiency verbs: a window carrying BOTH ("predates X.
  # PR #N landed that line") is a REMEDIATED site and must not read ABSENT.
  if printf '%s' "$w" | grep -qiE '\b(landed|merged|shipped|has since|now (carries|sets|has|declares)|since #?[0-9]{3,6}|deployed since)\b'; then
    echo PRESENT; return
  fi
  if printf '%s' "$w" | grep -qiE '\b(ships|introduces|adds|added|carries|declares|sets)\b[^.]{0,60}#[0-9]{3,6}|#[0-9]{3,6}[^.]{0,60}\b(ships|introduces|adds|carries|declares)\b'; then
    echo PRESENT; return
  fi
  # NOTE on the anchors above: `\b` before `#` is NOT a word boundary. A space
  # followed by `#` is non-word followed by non-word, so `\b(#[0-9]+)` can never
  # match and that whole alternative was DEAD — "#11337 ships the wording" read
  # stance NONE and never became a candidate. Anchor on the `#` itself.
  # ABSENT: a present-tense deficiency, or an explicit pending frame.
  if printf '%s' "$w" | grep -qiE '\b(lacks|lack|is missing|are missing|has no|have no|predates|omits)\b'; then
    echo ABSENT; return
  fi
  echo NONE
}

# ---------------------------------------------------------------------------
# symbols <window-text> -> code-shaped tokens, one per line.
# A CLAIMED SYMBOL is what makes the claim checkable. Backticked tokens, and
# bare tokens that are code-shaped (CamelCase, snake_case, or KEY=value) and
# at least 6 chars. English prose does not survive this filter.
# ---------------------------------------------------------------------------
symbols() {
  printf '%s' "$1" \
    | tr ' \t(),.;:"' '\n' \
    | sed 's/^`//; s/`$//; s/=.*$//' \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]{5,}$' \
    | grep -E '[a-z][A-Z]|_' \
    | grep -viE '^(measured|deliberate|because|exactly|reports|carries|instance|systemd|control|pointer|readers?|require|comment|status|result)$' \
    | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# landed <rev> <symbol> <citing-file> -> 0 if the symbol is on a NON-COMMENT
# line somewhere in the tree other than the citing file itself.
# ---------------------------------------------------------------------------
landed() {
  local rev="$1" sym="$2" src="$3" n
  # The comment-line filter is what stops a citation vouching for itself, and
  # it is enough. An EARLIER DRAFT also excluded the citing FILE wholesale, and
  # that was a bug, not a safeguard: a symbol DEFINED in the citing file (a test
  # helper named by the test that cites a PR) then always read NOT-LANDED, and
  # every such comment was reported FALSE-CLAIM. It produced 2 of the 6 false
  # positives in the first measured run. $src is kept in the signature because
  # the path arm below needs it.
  n=$(git -C "$ROOT" grep -nE "$sym" "$rev" -- . 2>/dev/null \
        | sed "s|^$rev:||" \
        | grep -vE ':[0-9]+:[[:space:]]*(#|//|\*|--|<!--)' \
        | wc -l | tr -d ' ')
  [ "${n:-0}" -gt 0 ] && return 0
  # A symbol can also be a FILENAME ("the CLI half landed as cloud_update_cmd.go").
  # A path that exists IS the thing having landed.
  #
  # NOT `| grep -q`. Under `set -o pipefail` a `grep -q` that matches EARLY
  # closes the pipe, ls-tree dies of SIGPIPE, and the pipeline returns 141 —
  # so a symbol that IS a real path read NOT-LANDED and was reported a
  # FALSE-CLAIM. It cost one measured false positive here. Count instead: the
  # reader consumes all of its input and cannot SIGPIPE its writer.
  n=$(git -C "$ROOT" ls-tree -r --name-only "$rev" 2>/dev/null | grep -c "$sym")
  [ "${n:-0}" -gt 0 ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
scan() {
  local rev="$1" verbose="${2:-}" pr_state="${3:-}" strict="${4:-}"
  local hits line file ln cite win st syms sym verdict
  local n_cand=0 n_find=0 n_undec=0

  # shellcheck disable=SC2086
  hits=$(git -C "$ROOT" grep -nE '(#|PR |pull/)[0-9]{4,6}' "$rev" -- $PATHSPECS $EXCLUDES 2>/dev/null | sed "s|^$rev:||")
  if [ -z "$hits" ]; then
    echo "stale-pr-citation-detector: REFUSING — ZERO citation lines over the scan scope at $rev." >&2
    echo "A clean verdict over an empty corpus is the failure this tool exists to not produce." >&2
    return 2
  fi
  echo "corpus: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') citation lines at $rev"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%:*}"; line="${line#*:}"; ln="${line%%:*}"
    case "$ln" in ''|*[!0-9]*) continue ;; esac

    win=$(git -C "$ROOT" show "$rev:$file" 2>/dev/null \
            | sed -n "$((ln>WINDOW?ln-WINDOW:1)),$((ln+WINDOW))p" \
            | sed 's|^[[:space:]]*\(#\|//\|\*\|--\)[[:space:]]*||' \
            | tr '\n' ' ')
    [ -n "$win" ] || continue

    st=$(stance "$win")
    [ "$st" = NONE ] && continue
    # --strict keeps ONLY a stance derived from an EXPLICIT PENDING FRAME
    # ("until #N lands"). MEASURED on the full tree at HEAD: the generic
    # deficiency stance ("has no X", "is missing X") is where essentially every
    # false positive lives, because the deficiency is almost always about
    # something OTHER than the code-shaped symbol the extractor bound it to.
    # The frame arm is the ARM-2 signal this file was commissioned for; the
    # deficiency arm is a generalisation of it that did NOT hold up. Default is
    # the wide arm (an AUDIT AID); --strict is the narrow, gateable one.
    if [ -n "$strict" ] && [ "$st" != ABSENT-FRAME ]; then continue; fi
    case "$st" in ABSENT-FRAME) st=ABSENT ;; esac
    n_cand=$((n_cand+1))

    # A PR number is DECIMAL. `#000000` and `#12ab34` are CSS colours, and a
    # 6-digit all-hex run preceded by nothing word-ish is overwhelmingly a
    # colour, not a citation. Require at least one digit outside 0-9a-f's
    # letter range is not enough (decimals are a subset of hex), so the rule
    # is: a 6-character run that is ALL hex AND contains a hex LETTER is a
    # colour; a pure-decimal run stays a candidate citation.
    cite=$(printf '%s' "$win" | grep -oE '#[0-9]{4,6}' \
             | grep -vE '^#0{4,6}$' | head -1)
    syms=$(symbols "$win")
    if [ -z "$syms" ]; then
      n_undec=$((n_undec+1))
      [ -n "$verbose" ] && printf '  UNDECIDABLE  %-6s %s:%s  (no code-shaped symbol) %s\n' "$st" "$file" "$ln" "$cite"
      continue
    fi

    verdict=""
    for sym in $syms; do
      if landed "$rev" "$sym" "$file"; then
        [ "$st" = ABSENT ] && { verdict="STALE-CLAIM"; break; }
      else
        [ "$st" = PRESENT ] && { verdict="FALSE-CLAIM"; break; }
      fi
    done

    if [ -n "$verdict" ]; then
      n_find=$((n_find+1))
      printf 'FINDING %-12s %s:%s  cites %s  claim=%s  symbol=%s\n' \
        "$verdict" "$file" "$ln" "${cite:-?}" "$st" "$sym"
      printf '        %s\n' "$(printf '%s' "$win" | cut -c1-150)"
      if [ -n "$pr_state" ] && [ -n "$cite" ]; then
        printf '        PR state: %s\n' "$(gh pr view "${cite#\#}" --json state,mergedAt -q '.state+" mergedAt="+(.mergedAt//"null")' 2>/dev/null || echo unresolved)"
      fi
    elif [ -n "$verbose" ]; then
      printf '  clean        %-6s %s:%s %s\n' "$st" "$file" "$ln" "$cite"
    fi
  done <<EOF
$hits
EOF

  echo "candidates: $n_cand   findings: $n_find   undecidable: $n_undec"
  [ "$n_find" -gt 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
# SELFTEST
#
# THE ARMS CANNOT GO VACUOUS, and that is enforced three ways:
#
#  (1) Every arm RUNS the real scan() over a real git tree built here. No arm
#      asserts over a pattern in isolation; the fixture travels the SAME code
#      path as a live run — same scan(), same stance(), same landed().
#  (2) The POSITIVE arm asserts a known-positive IS detected. If the detector
#      were inert, this arm fails. A suite of only-negative arms passes when
#      the detector is deleted, which is the failure this guards.
#  (3) Each NOISE-FAMILY arm carries a PRECONDITION arm proving the fixture is
#      a GENUINE specimen of its family — the impossibility-vocabulary matcher
#      (the approach this file refuses to ship) MUST match it. Without that,
#      "family N is not detected" is satisfied by a fixture that was never a
#      specimen, and the exclusion is proved over an empty set.
#
# The arm count is printed by COUNTING THE ARMS THAT RAN, never asserted.
# ---------------------------------------------------------------------------

ARMS=0; FAILS=0
arm() { # arm <name> <expect: yes|no> <needle> <output-file>
  local name="$1" expect="$2" needle="$3" out="$4" got
  ARMS=$((ARMS+1))
  if grep -qE "$needle" "$out"; then got=yes; else got=no; fi
  if [ "$got" = "$expect" ]; then
    printf '  ok   %-58s (expect=%s)\n' "$name" "$expect"
  else
    printf '  FAIL %-58s expect=%s got=%s\n' "$name" "$expect" "$got"; FAILS=$((FAILS+1))
  fi
}

# The approach this file REFUSES to ship, kept ONLY as the precondition oracle
# for the noise-family arms. It is never consulted for a verdict.
vocab_matches() {
  printf '%s' "$1" | grep -qiE 'does not carry|no way to|cannot|can not|not available|impossible|never carries'
}

selftest() {
  local tmp out rc
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sprc.XXXXXX")" || return 2
  mkdir -p "$tmp/deploy/systemd" "$tmp/internal/agent" "$tmp/lib"

  # ---- THE LANDED SYMBOL. A real non-comment line, the thing every ABSENT
  # ---- claim below is contradicted BY.
  printf '[Service]\nSuccessExitStatus=143\n' > "$tmp/deploy/systemd/site.service"
  printf 'function usageUnavailableText(k) { return k; }\n' > "$tmp/lib/live.js"

  # ---- P1 POSITIVE: ABSENT stance + landed symbol. MUST be detected.
  cat > "$tmp/internal/agent/report.go" <<'GO'
// Measured 2026-09-01: the box is failed with Result=exit-code, status 143.
// PR #14863 adds SuccessExitStatus=143 to the unit file for exactly this.
// Until it lands, a reader that treats failed as a crash reads a clean stop
// as an outage.
func reason() string { return "" }
GO

  # ---- P2 POSITIVE, the split-line shape: the deficiency verb and the
  # ---- citation are on DIFFERENT lines. A line-scoped detector misses this;
  # ---- 2 of the 6 real corpus positives have exactly this shape.
  cat > "$tmp/internal/agent/client.go" <<'GO'
// filed by systemd as an exit code because the unit lacks
// SuccessExitStatus=143 (PR #14863). result alone reads a deliberate stop
// as a crash.
func read() string { return "" }
GO

  # ---- P3 POSITIVE, FALSE-CLAIM direction: PRESENT stance + symbol NOT in
  # ---- the tree. The claim says it shipped; nothing in the tree carries it.
  cat > "$tmp/lib/false_claim.js" <<'JS'
// PR #99011 landed retireGraceWindow on the instance seam, so the caller
// no more needs its own timer.
function x() { return 1; }
JS

  # ---- N0 NEGATIVE: the REMEDIATED wording. PRESENT stance + landed symbol.
  # ---- This is the real post-fix text from aaf6ce097 and must stay clean.
  cat > "$tmp/lib/remediated.js" <<'JS'
// that box's unit file predates SuccessExitStatus=143. PR #14863 landed that
// line (merged 2026-09-02) into the site unit, preflight-enforced on deploy.
function y() { return 2; }
JS

  # ---- N-FP NEGATIVE: the row's named nearest-neighbour false positive.
  # ---- Cites the PR, makes NO claim about its state, and is TRUE.
  cat > "$tmp/lib/nearest.js" <<'JS'
// exit-code alone reads a deliberate SIGTERM retire (status 143) as a crash
// — measured 2026-09-01, and the reason PR #14863 exists.
function z() { return 3; }
JS

  # ---- THE FOUR NOISE FAMILIES. Each carries a PR citation ON PURPOSE, so
  # ---- the referent gate alone cannot be what excludes it — the structural
  # ---- stance rule has to do the work.
  cat > "$tmp/lib/n1_goal.js" <<'JS'
// The deploy preflight exists to make a silent skip impossible: a unit that
// lacks SuccessExitStatus=143 never reaches a box at all (PR #14863).
function n1() { return 1; }
JS
  cat > "$tmp/lib/n2_redaction.js" <<'JS'
// The audit row never carries a bearer token — it lacks SuccessExitStatus=143
// and every other field of the unit block too (see PR #14863).
function n2() { return 2; }
JS
  cat > "$tmp/lib/n3_failclosed.js" <<'JS'
// When the stored admin credential cannot be read we refuse the write, because
// the legacy unit lacks SuccessExitStatus=143 (PR #14863) and would look failed.
function n3() { return 3; }
JS
  cat > "$tmp/lib/n4_pasttense.js" <<'JS'
// Before #14863 the unit had no way to signal a clean stop: it lacks
// SuccessExitStatus=143, so every deliberate retire read as a crash.
function n4() { return 4; }
JS

  cat > "$tmp/lib/n5_runtime.js" <<'JS'
// A box that predates the probe reports no SuccessExitStatus key at all and may
// be perfectly armed, so ANY absence renders as null rather than "unarmed" (#14863).
function n5() { return 5; }
JS

  ( cd "$tmp" && git init -q . && git add -A && \
    git -c user.email=s@e -c user.name=s commit -qm fixture ) >/dev/null 2>&1 \
    || { echo "selftest: REFUSING — could not build the fixture repo" >&2; return 2; }

  out="$tmp/out.txt"
  ( DETECTOR_ROOT="$tmp" ROOT="$tmp" scan HEAD -v ) > "$out" 2>&1
  rc=$?
  echo "--- fixture scan (rc=$rc) ---"; cat "$out"; echo "--- arms ---"

  # NON-VACUITY GUARD ZERO: the fixture scan must have produced candidates at
  # all. A scan that examined nothing makes every arm below meaningless.
  ARMS=$((ARMS+1))
  if grep -qE 'candidates: [1-9]' "$out"; then
    printf '  ok   %-58s (expect=yes)\n' "non-vacuity: the fixture scan produced candidates"
  else
    printf '  FAIL %-58s the scan examined NOTHING\n' "non-vacuity: the fixture scan produced candidates"; FAILS=$((FAILS+1))
  fi

  # POSITIVE ARMS — the detector must SAY YES.
  arm "P1 pending-claim + landed symbol IS detected"      yes "FINDING STALE-CLAIM  internal/agent/report.go" "$out"
  arm "P2 split-line 'lacks' shape IS detected"           yes "FINDING STALE-CLAIM  internal/agent/client.go" "$out"
  arm "P3 shipped-claim + absent symbol IS detected"      yes "FINDING FALSE-CLAIM  lib/false_claim.js"       "$out"

  # NEGATIVE ARMS — the detector must stay quiet.
  # The needle is anchored on FINDING, never on the bare filename: -v prints a
  # `clean ... <file>` line for every examined candidate, so a bare-substring
  # needle reports the file as DETECTED the moment the detector clears it.
  arm "N0 remediated wording is NOT detected"             no  "FINDING.*remediated.js"    "$out"
  arm "NFP nearest-neighbour FP is NOT detected"          no  "FINDING.*nearest.js"       "$out"
  arm "N1 goal statement is NOT detected"                 no  "FINDING.*n1_goal.js"       "$out"
  arm "N2 redaction invariant is NOT detected"            no  "FINDING.*n2_redaction.js"  "$out"
  arm "N3 handled fail-closed arm is NOT detected"        no  "FINDING.*n3_failclosed.js" "$out"
  arm "N4 past-tense narration is NOT detected"           no  "FINDING.*n4_pasttense.js"  "$out"
  arm "N5 runtime-state claim is NOT detected"            no  "FINDING.*n5_runtime.js"    "$out"

  # PRECONDITION ARMS. Each proves its fixture really IS a specimen of the
  # family — the rejected impossibility-vocabulary matcher fires on it. Without
  # these, the four "NOT detected" arms above are proved over an empty set.
  local f
  for f in n1_goal n2_redaction n3_failclosed n4_pasttense; do
    ARMS=$((ARMS+1))
    if vocab_matches "$(cat "$tmp/lib/$f.js")"; then
      printf '  ok   %-58s (precondition)\n' "$f IS a genuine specimen (vocabulary arm matches it)"
    else
      printf '  FAIL %-58s fixture is NOT a specimen; its exclusion proves nothing\n' "$f IS a genuine specimen"; FAILS=$((FAILS+1))
    fi
  done

  # --strict ARM: the frame fixture survives, the deficiency-only one does not.
  local sout="$tmp/strict.txt"
  ( DETECTOR_ROOT="$tmp" ROOT="$tmp" scan HEAD -v "" 1 ) > "$sout" 2>&1
  arm "--strict KEEPS the explicit-frame positive"        yes "FINDING.*report.go"  "$sout"
  arm "--strict DROPS the deficiency-only positive"       no  "FINDING.*client.go"  "$sout"

  # LOAD-BEARING ARMS. For each family, re-run the SAME fixture with ONLY that
  # family's rule bypassed. It MUST become a finding. An exclusion rule that
  # changes no verdict when removed is decorative, and its "not detected" arm
  # is satisfied by something else entirely.
  local fam mout
  for fam in N1 N2 N3 N4 N5; do
    mout="$tmp/bypass_$fam.txt"
    ( DETECTOR_ROOT="$tmp" ROOT="$tmp" DETECTOR_BYPASS="$fam" scan HEAD -v ) > "$mout" 2>&1
    ARMS=$((ARMS+1))
    if grep -qE "FINDING.*$(echo "$fam" | tr 'A-Z' 'a-z')_" "$mout"; then
      printf '  ok   %-58s (load-bearing)\n' "$fam rule is LOAD-BEARING (bypassing it yields a FINDING)"
    else
      printf '  FAIL %-58s bypassing the rule changes NOTHING; it is decorative\n' "$fam rule is LOAD-BEARING"; FAILS=$((FAILS+1))
    fi
  done

  # And the inverse precondition: the vocabulary approach would have flagged
  # all four, which is the 0-of-215 result restated as a runnable fact.
  ARMS=$((ARMS+1))
  if vocab_matches "$(cat "$tmp/lib/remediated.js")"; then
    printf '  FAIL %-58s\n' "control: vocabulary arm must NOT match the clean remediated text"; FAILS=$((FAILS+1))
  else
    printf '  ok   %-58s (control)\n' "vocabulary arm does NOT match the clean remediated text"
  fi

  rm -rf "$tmp"
  echo "arms RUN: $ARMS   failures: $FAILS"
  [ "$FAILS" -eq 0 ] || { echo "FAIL stale-pr-citation-detector --selftest"; return 1; }
  echo "PASS stale-pr-citation-detector --selftest ($ARMS arms)"
  return 0
}

# ---------------------------------------------------------------------------
REV=HEAD; MODE=scan; VERBOSE=; PRSTATE=; STRICT=
while [ $# -gt 0 ]; do
  case "$1" in
    --rev) REV="$2"; shift 2 ;;
    --selftest) MODE=selftest; shift ;;
    --with-pr-state) PRSTATE=1; shift ;;
    --strict) STRICT=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$MODE" = selftest ]; then selftest; exit $?; fi
scan "$REV" "$VERBOSE" "$PRSTATE" "$STRICT"; exit $?
