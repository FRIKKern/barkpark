#!/usr/bin/env bash
#
# PDS RECORD PARITY — the epic's law turned on the epic's OWN record.
#
# The law, unchanged since wave 22: NO BARKPARK VERB MAY REPORT SUCCESS ON AN
# EXIT CODE ALONE. Every arm this epic has shipped so far points that law at
# some OTHER surface — a controller, a census, a receipt. This one points it at
# the record the epic itself writes, on two axes:
#
#   AXIS A — A COMMIT MAY NOT CITE AN AUTHORITY THAT DOES NOT EXIST.
#            Every PDS-Dnnn cited in a commit message must be DEFINED in the
#            charter. A decision id in a commit is a citation; a citation to
#            nothing is a commit claiming an authority it never had.
#
#   AXIS B — A MERGED PR MAY NOT LEAVE ITS TASK ROW OPEN.
#            Every merged PR names a task. That task must have reached a
#            terminal lifecycle. A merged PR over an `open` row is the epic's
#            own disease — a closure the ledger does not carry.
#
# ── WHY AXIS B IS THE PROOF OF LIFE, AND AXIS A IS ONLY A TRIPWIRE ────────────
#
# Axis A is GREEN TODAY and was green the moment #8971 merged, which is exactly
# why it must not be presented as this arm's evidence. Its red vanished on an
# unrelated merge; an arm whose red can evaporate that way is a red nobody
# believes twice. It ships as a STANDING TRIPWIRE — the next commit citing an
# undefined D reds it — and the run header says so in as many words.
#
# AXIS B IS THE NON-VACUITY PROOF. Over the most recent merged PRs it resolves
# a few hundred distinct task ids against the live ledger and reds on the leaf
# slices whose rows are still open. It is red today, on real rows, by name. A
# green here would be news.
#
# ── THREE RULINGS THIS ARM HONOURS, EACH ONE MEASURED ─────────────────────────
#
# (1) THE STRICT D-DEFINITION TEST KEYS ON THE CHARTER'S BOLD-LEAD BULLET FORM,
#     NEVER ON A MARKDOWN HEADING.
#     The charter defines its decisions as `- **PDS-D123** …` bullets. Keying
#     the "is this D defined?" test on a markdown HEADING measures the charter's
#     markdown dialect instead of its record: the charter defines essentially no
#     D as a heading, so a heading lens reports the overwhelming majority of
#     cited ids as UNRESOLVED and the arm's red becomes an artifact of its own
#     lens rather than a finding about the corpus. `--heading-lens` exists ONLY
#     so that claim can be re-derived on demand (and by the selftest) — running
#     it is how you SEE the artifact, never how you gate on it.
#
# (2) EPIC ROOTS ARE ADVISORY, NEVER REDDING.
#     A divergent row whose parent_id is null is an EPIC ROOT, and an epic root
#     that is open while its children merge is CORRECT — that is what an epic in
#     flight looks like. Those rows print as EPIC-ROOT-IN-FLIGHT and are counted,
#     not scored. Only LEAF slices red.
#     Two lenses that look plausible here and are NOT used: PR-COUNT (many rows
#     carry more than one merged PR; that is a symptom of slicing, not of a
#     lifecycle lie) and `kind` (every row on this ledger reads kind=task, so it
#     discriminates nothing).
#
# (3) THE GRACE WINDOW MUST BE SMALLER THAN THE WINDOW IT IS APPLIED TO, AND
#     THE ARM ASSERTS THAT AT RUNTIME.
#     Grace exists for one honest case: a PR merged minutes ago whose lead has
#     not closed the row yet. But `--limit N` is a COUNT bound masquerading as a
#     TIME bound — it spans whatever it spans, and that span SHRINKS as the merge
#     rate rises. A grace as wide as the fetched window suppresses EVERY row in
#     it and prints a green that proves nothing: the arm would then be wearing
#     its LENS instead of the CORPUS. So the arm derives the window span and
#     REFUSES (exit 2) unless grace < span. That refusal is not a nicety; it is
#     the only thing standing between this arm and structural vacuity.
#
# ── REUSE, DO NOT REWRITE ─────────────────────────────────────────────────────
#
# The task-id extractor is `scripts/pr-task-gate.sh --extract-task-id` — this
# repo's already-hardened `Task:` trailer grammar. A second, ad-hoc lens (a jq
# regex over the body) keeps the markdown backticks that wrap some ids, and a
# backticked id 404s on the ledger — manufacturing NOT_FOUNDs that are artifacts
# of the reader. One grammar, one owner.
#
# TWO SHARP EDGES IN THAT REUSE, both load-bearing:
#   (a) `--extract-task-id` EXITS 0 EVEN WHEN THERE IS NO TRAILER. It signals
#       absence ONLY by empty stdout. An arm that tests `$?` reads every
#       trailer-less PR as a successful extraction of the empty id. So this arm
#       tests THE STRING, never the status.
#   (b) pr-task-gate's `fail`/`unchecked`/`pass` helpers each call `exit`. A
#       sweep over hundreds of rows cannot call them per row without dying on
#       the first finding. This arm reuses the 0/1/2 SEMANTICS with a worst-case
#       fold — any UNCHECKED wins over any DIVERGENT wins over parity — and
#       keeps the helpers out of the loop entirely.
#
# ── WHY IT READS PR BODIES AND NOT COMMIT MESSAGES ────────────────────────────
#
# Merge commits do not reliably carry the trailer. #8647 (1cef6eed3) and #8648
# (8b2018bc0) land on main with no `Task:` line and no grep-able id anywhere in
# their commit messages — a commit-message-side arm can only report them
# UNCHECKED. Their PR BODIES carry the trailer plainly. The record of what a PR
# was for lives on the PR and on the ledger, not in the squash subject line.
#
# ── OFFLINE IS UNCHECKED, NEVER A SILENT PASS ─────────────────────────────────
#
# `gh` absent (command -v exits 1) and `gh` present-but-credential-less (exits 4)
# are both distinguishable and both land in UNCHECKED / exit 2. A gate that
# greens because it could not look is the vacuous green this whole epic exists
# to make impossible. Ledger reads retry only INDECISIVE answers — a 404 and a
# 2xx are ANSWERS and retrying an answer would make the verdict a function of
# the wall clock.
#
# NO `timeout(1)` ANYWHERE. It does not exist on this darwin host, and inside an
# `&&` chain behind a pipe it printed EXIT=0 for a command that never ran.
# curl's own `-m` is the per-request bound.
#
# ── EXIT CODES ────────────────────────────────────────────────────────────────
#   0  PARITY    — every axis checked, nothing divergent
#   1  DIVERGENT — at least one leaf slice merged over an open row, or a cited
#                  D that the charter does not define
#   2  UNCHECKED — the arm could not look (no gh, no credentials, ledger down,
#                  no charter) OR it REFUSED to run vacuously (grace >= span)
#   3  USAGE     — bad invocation
#
# usage:
#   bash scripts/pds-record-parity.sh
#   bash scripts/pds-record-parity.sh --axis a
#   bash scripts/pds-record-parity.sh --limit 400 --grace-hours 6
#   bash scripts/pds-record-parity.sh --fixture-dir <dir>   # hermetic, selftest

set -uo pipefail

cd "$(dirname "$0")/.." || { echo "pds-record-parity: cannot cd to the repo root" >&2; exit 2; }

# ── configuration ─────────────────────────────────────────────────────────────
AXIS="both"
LIMIT="${PDS_RECORD_PARITY_LIMIT:-400}"
# 6 hours. Measured against the live window: 6h suppresses the handful of rows
# whose lead has genuinely not caught up yet; 24h buys a couple more suppressions
# for four times the blindness; anything approaching the window span suppresses
# everything and is refused outright by the assertion below.
GRACE_HOURS="${PDS_RECORD_PARITY_GRACE_HOURS:-6}"
CHARTER="${PDS_RECORD_PARITY_CHARTER:-.claude/workflows/bp-pds-charter.md}"
COMMITS_FILE=""          # axis A corpus override (fixtures); default = git log
FIXTURE_DIR=""           # hermetic transport for BOTH gh and the ledger
HEADING_LENS=0           # lens artifact demonstrator; never the gate
REPO="${PDS_RECORD_PARITY_REPO:-FRIKKern/barkpark}"
LEDGER_BASE="${LEDGER_BASE:-https://guerrilla.barkpark.cloud}"
DATASET="${LEDGER_DATASET:-production}"
RETRIES="${PDS_RECORD_PARITY_RETRIES:-3}"
RETRY_DELAY="${PDS_RECORD_PARITY_RETRY_DELAY:-2}"
# Serial and paced. A parallel sweep of a few hundred ledger rows gets
# rate-limited, and a 429 body is VALID JSON — a reader that scores on "did it
# parse?" counts a rate limit as data.
PACE="${PDS_RECORD_PARITY_PACE:-0}"
EXTRACTOR="${PDS_RECORD_PARITY_EXTRACTOR:-scripts/pr-task-gate.sh}"

usage() { sed -n '/^# usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 3; }

while [ $# -gt 0 ]; do
  case "$1" in
    --axis)          AXIS="${2:-}"; shift 2 ;;
    --limit)         LIMIT="${2:-}"; shift 2 ;;
    --grace-hours)   GRACE_HOURS="${2:-}"; shift 2 ;;
    --charter)       CHARTER="${2:-}"; shift 2 ;;
    --commits-file)  COMMITS_FILE="${2:-}"; shift 2 ;;
    --fixture-dir)   FIXTURE_DIR="${2:-}"; shift 2 ;;
    --heading-lens)  HEADING_LENS=1; shift ;;
    -h|--help)       usage ;;
    *) echo "pds-record-parity: unknown argument '$1'" >&2; usage ;;
  esac
done

case "$AXIS" in a|b|both) : ;; *) echo "pds-record-parity: --axis must be a|b|both, got '${AXIS}'" >&2; usage ;; esac
case "$LIMIT" in ''|*[!0-9]*|0) echo "pds-record-parity: --limit must be a positive integer, got '${LIMIT}'" >&2; usage ;; esac
case "$GRACE_HOURS" in ''|*[!0-9]*) echo "pds-record-parity: --grace-hours must be a non-negative integer, got '${GRACE_HOURS}'" >&2; usage ;; esac
case "$RETRIES" in ''|*[!0-9]*|0) echo "pds-record-parity: PDS_RECORD_PARITY_RETRIES must be a positive integer, got '${RETRIES}'" >&2; usage ;; esac

command -v jq >/dev/null 2>&1 || { echo "pds-record-parity: UNCHECKED: jq is not installed — the arm cannot read either the PR list or the ledger" >&2; exit 2; }

# One scratch dir, one EXIT trap. Deliberately NOT per-function RETURN traps:
# a nested RETURN trap silently replaces its parent's and the loser's temp files
# survive the run — a leak that only shows up as a full disk weeks later.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pds-record-parity.XXXXXX")"
trap 'rm -rf -- "$WORKDIR"' EXIT

# ── worst-case fold ───────────────────────────────────────────────────────────
# The 0/1/2 SEMANTICS of pr-task-gate, reused without its exiting helpers:
# UNCHECKED beats DIVERGENT beats PARITY, and nothing can lower a verdict once
# raised. Every per-row disposition folds through here.
WORST=0
raise() { # raise <code>
  case "$1" in
    2) WORST=2 ;;
    1) [ "$WORST" -lt 1 ] && WORST=1 ;;
  esac
  return 0
}

# ── portable ISO-8601 → epoch seconds ─────────────────────────────────────────
# GNU date and BSD date disagree on everything; this arm runs on a darwin host
# and in ubuntu CI. An unparseable timestamp prints nothing and the caller
# treats that as UNCHECKED — never as "zero seconds ago", which would silently
# grace-suppress a row.
iso_to_epoch() {
  local iso="$1" e=""
  e="$(date -u -d "$iso" +%s 2>/dev/null)" || e=""
  if [ -z "$e" ]; then
    e="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null)" || e=""
  fi
  printf '%s' "$e"
}

# `now`, overridable so the selftest's grace fixtures are deterministic. A
# fixture whose verdict depends on the wall clock is a fixture that rots.
now_epoch() {
  if [ -n "${PDS_RECORD_PARITY_NOW:-}" ]; then printf '%s' "${PDS_RECORD_PARITY_NOW}"; else date -u +%s; fi
}

echo "pds-record-parity: the epic's law, turned on the epic's own record"
echo "  repo=${REPO}  ledger=${LEDGER_BASE}  dataset=${DATASET}${FIXTURE_DIR:+  transport=FIXTURES(${FIXTURE_DIR})}"

# ══ AXIS A — a commit may not cite an authority that does not exist ═══════════
axis_a() {
  echo
  echo "AXIS A — cited PDS-D numbers must resolve in the charter"
  echo "  NOTE: axis A is a STANDING TRIPWIRE, not this arm's proof of life."
  echo "        It went to zero when the wave-37 charter merged; a red that can"
  echo "        vanish on an unrelated merge is not evidence of an arm's health."
  echo "        Axis B is the non-vacuity proof. See the header."

  if [ ! -f "$CHARTER" ]; then
    echo "  UNCHECKED: charter not found at ${CHARTER} — the arm cannot resolve a single citation" >&2
    raise 2; return 0
  fi

  local defs="$WORKDIR/defs" cites="$WORKDIR/cites" unresolved="$WORKDIR/unresolved" lens

  if [ "$HEADING_LENS" -eq 1 ]; then
    lens="HEADING (lens-artifact demonstrator — NOT the gate)"
    grep -oE '^#+[[:space:]].*PDS-D[0-9]+' "$CHARTER" | grep -oE 'PDS-D[0-9]+' | sort -u > "$defs"
  else
    # THE STRICT FORM: a bold lead at the start of a line, optionally bulleted.
    #   **PDS-D123** …    - **PDS-D123** …    * **PDS-D123** …
    lens="BOLD-LEAD BULLET (the form the charter actually defines D's in)"
    grep -oE '^[[:space:]]*([-*][[:space:]]+)?\*\*PDS-D[0-9]+' "$CHARTER" \
      | grep -oE 'PDS-D[0-9]+' | sort -u > "$defs"
  fi

  if [ -n "$COMMITS_FILE" ]; then
    [ -f "$COMMITS_FILE" ] || { echo "  UNCHECKED: --commits-file ${COMMITS_FILE} not found" >&2; raise 2; return 0; }
    grep -oE 'PDS-D[0-9]+' "$COMMITS_FILE" | sort -u > "$cites"
  else
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
      echo "  UNCHECKED: not inside a git work tree — the commit corpus is unreachable" >&2
      raise 2; return 0
    fi
    git log --format=%B | grep -oE 'PDS-D[0-9]+' | sort -u > "$cites"
  fi

  comm -23 "$cites" "$defs" > "$unresolved"

  local n_def n_cite n_unres
  n_def="$(wc -l < "$defs" | tr -d ' ')"
  n_cite="$(wc -l < "$cites" | tr -d ' ')"
  n_unres="$(wc -l < "$unresolved" | tr -d ' ')"

  echo "  lens:       ${lens}"
  echo "  charter:    ${CHARTER}"
  echo "  defined:    ${n_def} distinct PDS-D"
  echo "  cited:      ${n_cite} distinct PDS-D across the commit corpus"
  echo "  unresolved: ${n_unres}"

  if [ "$n_unres" -gt 0 ]; then
    sed 's/^/    UNRESOLVED-CITATION /' "$unresolved"
    if [ "$HEADING_LENS" -eq 1 ]; then
      echo "  ADVISORY: this run used the HEADING lens, which measures the charter's"
      echo "            markdown dialect, not its record. Its red is a LENS ARTIFACT."
      echo "            Not folded into the exit code — re-run without --heading-lens."
      return 0
    fi
    raise 1
  fi
  return 0
}

# ══ AXIS B — a merged PR may not leave its task row open ═════════════════════

# Ledger read. Sets LF_CODE and writes the body to $LF_BODY. Retries only
# INDECISIVE answers; 404 and 2xx are answers.
LF_BODY=""
LF_CODE=""
LF_REASON=""
ledger_fetch() { # ledger_fetch <task-id>
  local id="$1"
  LF_REASON=""
  if [ -n "$FIXTURE_DIR" ]; then
    local f="${FIXTURE_DIR}/task/${id}.http"
    if [ ! -f "$f" ]; then LF_CODE=404; : > "$LF_BODY"; return 0; fi
    LF_CODE="$(head -1 "$f" | sed -E 's/^HTTP[[:space:]]*//')"
    tail -n +2 "$f" > "$LF_BODY"
    return 0
  fi
  local url="${LEDGER_BASE%/}/v1/data/doc/${DATASET}/task/${id}"
  local attempt=1
  while : ; do
    if LF_CODE="$(curl -sS -m 20 -o "$LF_BODY" -w '%{http_code}' "$url" 2>/dev/null)"; then
      case "$LF_CODE" in 404|2??) return 0 ;; esac
      LF_REASON="ledger returned HTTP ${LF_CODE}"
    else
      LF_CODE="000"
      LF_REASON="could not reach the ledger at ${LEDGER_BASE}"
    fi
    [ "$attempt" -ge "$RETRIES" ] && return 1
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

axis_b() {
  echo
  echo "AXIS B — a merged PR may not leave its task row open"

  local prs="$WORKDIR/prs.json" ids="$WORKDIR/ids.tsv" leaves="$WORKDIR/leaves"
  LF_BODY="$WORKDIR/ledger-body"
  : > "$ids"; : > "$leaves"

  # ── the PR window ───────────────────────────────────────────────────────────
  if [ -n "$FIXTURE_DIR" ]; then
    [ -f "${FIXTURE_DIR}/prs.json" ] || { echo "  UNCHECKED: fixture ${FIXTURE_DIR}/prs.json not found" >&2; raise 2; return 0; }
    cp "${FIXTURE_DIR}/prs.json" "$prs"
  else
    if ! command -v gh >/dev/null 2>&1; then
      echo "  UNCHECKED: \`gh\` is not installed — the merged-PR window cannot be read." >&2
      echo "             This is NOT a pass: the arm could not look. Install gh and re-run." >&2
      raise 2; return 0
    fi
    local gherr="$WORKDIR/gh.err" rc
    gh pr list --repo "$REPO" --state merged --limit "$LIMIT" \
       --json number,mergedAt,body,title > "$prs" 2>"$gherr"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "  UNCHECKED: \`gh pr list\` exited ${rc} ($(head -1 "$gherr" 2>/dev/null))" >&2
      [ "$rc" -eq 4 ] && echo "             exit 4 is gh's NO CREDENTIALS code — run \`gh auth login\`." >&2
      echo "             This is NOT a pass: the arm could not look." >&2
      raise 2; return 0
    fi
  fi

  if ! jq -e 'type == "array"' "$prs" >/dev/null 2>&1; then
    echo "  UNCHECKED: the PR list is not a JSON array — the transport answered without answering" >&2
    raise 2; return 0
  fi

  local n_prs
  n_prs="$(jq 'length' "$prs")"
  if [ "$n_prs" -eq 0 ]; then
    echo "  UNCHECKED: the merged-PR window is EMPTY. A window of zero rows cannot" >&2
    echo "             falsify anything, and exiting 0 over it would be the exact" >&2
    echo "             vacuous green this arm exists to refuse." >&2
    raise 2; return 0
  fi

  local pr_min pr_max t_min t_max e_min e_max span_h
  pr_min="$(jq -r '[.[].number]|min' "$prs")"
  pr_max="$(jq -r '[.[].number]|max' "$prs")"
  t_min="$(jq -r '[.[].mergedAt]|min' "$prs")"
  t_max="$(jq -r '[.[].mergedAt]|max' "$prs")"
  e_min="$(iso_to_epoch "$t_min")"; e_max="$(iso_to_epoch "$t_max")"
  if [ -z "$e_min" ] || [ -z "$e_max" ]; then
    echo "  UNCHECKED: could not parse the window bounds (${t_min} … ${t_max})" >&2
    raise 2; return 0
  fi
  # One decimal, integer arithmetic — no bc dependency.
  span_h="$(( (e_max - e_min) * 10 / 3600 ))"
  span_h="$(( span_h / 10 )).$(( span_h % 10 ))"

  # ── THE WINDOW HEADER. Printed every run, without exception. ───────────────
  # `--limit N` is a COUNT bound wearing a TIME bound's clothes: the span it
  # reaches shrinks as the merge rate rises, and a denominator that drifts in
  # silence is the defect this whole wave exists to name.
  echo "  window:     ${n_prs} merged PRs  (asked --limit ${LIMIT})"
  echo "  PR range:   #${pr_min} … #${pr_max}"
  echo "  merged:     ${t_min} … ${t_max}"
  echo "  span:       ${span_h} h"
  echo "  grace:      ${GRACE_HOURS} h"

  # ── THE VACUITY ASSERTION ─────────────────────────────────────────────────
  # Integer compare against the FLOOR of the span, so the refusal is
  # conservative in the right direction: a grace equal to the span is refused.
  local span_floor=$(( (e_max - e_min) / 3600 ))
  if [ "$GRACE_HOURS" -ge "$span_floor" ]; then
    echo "  REFUSED: grace (${GRACE_HOURS} h) >= window span (${span_floor} h floor)." >&2
    echo "           A grace at least as wide as the window it is applied to" >&2
    echo "           suppresses EVERY divergent row in that window and prints a" >&2
    echo "           green that proves nothing — the arm wearing its LENS instead" >&2
    echo "           of the CORPUS. Refusing to run vacuously. Lower --grace-hours" >&2
    echo "           or widen --limit." >&2
    raise 2; return 0
  fi

  # ── extraction, through the ONE grammar ───────────────────────────────────
  # scripts/pr-task-gate.sh --extract-task-id. NOT a second lens: an ad-hoc jq
  # regex keeps the markdown backticks some trailers wrap their id in, and a
  # backticked id 404s — inventing NOT_FOUNDs out of the reader's own defect.
  if [ ! -f "$EXTRACTOR" ]; then
    echo "  UNCHECKED: the canonical extractor ${EXTRACTOR} is missing — this arm" >&2
    echo "             refuses to grow a second copy of the trailer grammar." >&2
    raise 2; return 0
  fi

  local no_trailer=0 i=0 body id num merged b64
  # The body is carried BASE64, not TSV-escaped. A PR body is arbitrary
  # markdown — it contains newlines (which the trailer grammar anchors to and
  # therefore must survive intact), tabs, and backslashes. Round-tripping it
  # through jq's @tsv escaping and `printf %b` double-escapes every backslash
  # and silently flattens the very line breaks the grammar keys on.
  while IFS=$'\t' read -r num merged b64; do
    i=$((i + 1))
    body="$(printf '%s' "$b64" | base64 --decode 2>/dev/null)"
    # SHARP EDGE (a): --extract-task-id EXITS 0 EVEN WITH NO TRAILER and signals
    # absence ONLY by empty stdout. Test the STRING. Testing `$?` here would
    # read every trailer-less PR as a successful extraction of the empty id.
    id="$(PR_BODY="$body" bash "$EXTRACTOR" --extract-task-id 2>/dev/null)"
    if [ -z "$id" ]; then
      no_trailer=$((no_trailer + 1))
      continue
    fi
    printf '%s\t%s\t%s\n' "$id" "$num" "$merged" >> "$ids"
  done < <(jq -r '.[] | [(.number|tostring), .mergedAt, (.body // "" | @base64)] | @tsv' "$prs")

  local n_ids
  n_ids="$(cut -f1 "$ids" | sort -u | wc -l | tr -d ' ')"
  echo "  extractor:  ${EXTRACTOR} --extract-task-id  (absence = EMPTY STDOUT, never \$?)"
  echo "  task ids:   ${n_ids} distinct across ${i} PRs"
  echo "  no trailer: ${no_trailer} PRs carry no Task: trailer (advisory — predates the gate)"

  # ── ledger sweep, serial and paced ────────────────────────────────────────
  local now grace_secs
  now="$(now_epoch)"
  grace_secs=$(( GRACE_HOURS * 3600 ))

  local n_terminal=0 n_open=0 n_notfound=0 n_unchecked=0 n_grace=0 n_root=0 n_leaf=0
  local tid latest prlist lifecycle parent has_result age
  while read -r tid; do
    [ -n "$tid" ] || continue
    # The row's own recency is the MAX mergedAt across every PR naming it —
    # a task whose latest PR merged an hour ago is inside grace even if its
    # first one merged days back.
    latest="$(awk -F'\t' -v t="$tid" '$1==t {print $3}' "$ids" | sort | tail -1)"
    prlist="$(awk -F'\t' -v t="$tid" '$1==t {print "#"$2}' "$ids" | sort -u | tr '\n' ',' | sed 's/,$//')"

    if ! ledger_fetch "$tid"; then
      echo "    UNCHECKED  ${tid}  (${LF_REASON} after ${RETRIES} attempts)  ${prlist}"
      n_unchecked=$((n_unchecked + 1)); raise 2
      continue
    fi

    case "$LF_CODE" in
      404)
        echo "    NOT-FOUND  ${tid}  merged over a task id the ledger does not carry  ${prlist}"
        n_notfound=$((n_notfound + 1)); n_leaf=$((n_leaf + 1)); raise 1
        continue ;;
      2??) : ;;
      *)
        echo "    UNCHECKED  ${tid}  (unexpected HTTP ${LF_CODE})  ${prlist}"
        n_unchecked=$((n_unchecked + 1)); raise 2
        continue ;;
    esac

    # A 2xx with no `result` is an answer that answers nothing — it is NOT
    # evidence the task is absent (absence answers 404). UNCHECKED.
    has_result="$(jq -r 'if (.result? // null) == null then "no" else "yes" end' "$LF_BODY" 2>/dev/null)" || has_result="no"
    if [ "$has_result" != "yes" ]; then
      echo "    UNCHECKED  ${tid}  (HTTP ${LF_CODE} with no task document in the envelope)  ${prlist}"
      n_unchecked=$((n_unchecked + 1)); raise 2
      continue
    fi

    lifecycle="$(jq -r '.result.lifecycle_status // "-"' "$LF_BODY")"
    parent="$(jq -r 'if (.result.parent_id // null) == null or (.result.parent_id == "") then "-" else .result.parent_id end' "$LF_BODY")"

    case "$lifecycle" in
      done|cancelled)
        n_terminal=$((n_terminal + 1))
        continue ;;
    esac

    n_open=$((n_open + 1))

    # ROOT BEFORE GRACE, deliberately. Both dispositions are non-redding, so
    # the ORDER cannot change the verdict — but it changes the REPORTED SPLIT,
    # and the split is the thing a reader reasons about. Disposing roots first
    # makes `EPIC-ROOT-IN-FLIGHT` the true count of open epics in the window and
    # leaves `grace` meaning exactly one thing: leaf slices too fresh to judge.
    # Grace-first would silently reclassify any recently-merged epic root as a
    # timing artifact and undercount the roots.
    if [ "$parent" = "-" ]; then
      # RULING 2: an epic root open while its children merge is CORRECT.
      echo "    EPIC-ROOT-IN-FLIGHT  ${tid}  lifecycle=${lifecycle}  parent_id=null (advisory, never redding)  ${prlist}"
      n_root=$((n_root + 1))
      continue
    fi

    # Grace: only the honestly-recent get it, and only because grace < span was
    # asserted above. An unparseable mergedAt does NOT get graced — a row whose
    # timestamp cannot be read is judged, never excused.
    local e_latest=""
    [ -n "$latest" ] && e_latest="$(iso_to_epoch "$latest")"
    if [ -n "$e_latest" ]; then
      age=$(( now - e_latest ))
      if [ "$age" -lt "$grace_secs" ] && [ "$age" -ge 0 ]; then
        echo "    GRACE      ${tid}  lifecycle=${lifecycle}  latest merge ${age}s ago < ${GRACE_HOURS}h  ${prlist}"
        n_grace=$((n_grace + 1))
        continue
      fi
    fi

    echo "    DIVERGENT  ${tid}  lifecycle=${lifecycle}  parent=${parent}  merged over an OPEN row  ${prlist}"
    printf '%s\n' "$tid" >> "$leaves"
    n_leaf=$((n_leaf + 1)); raise 1

    [ "$PACE" != "0" ] && sleep "$PACE"
  done < <(cut -f1 "$ids" | sort -u)

  local n_divergent=$(( n_open + n_notfound ))
  echo
  echo "  AXIS B TALLY"
  echo "    terminal (done|cancelled):   ${n_terminal}"
  echo "    non-terminal:                ${n_open}"
  echo "    not found on the ledger:     ${n_notfound}"
  echo "    unchecked:                   ${n_unchecked}"
  echo "    ── divergent set:            ${n_divergent}"
  echo "       EPIC-ROOT-IN-FLIGHT (advisory): ${n_root}"
  echo "       leaf, suppressed by ${GRACE_HOURS}h grace: ${n_grace}"
  echo "       LEAF slices (REDDING):          ${n_leaf}"
  return 0
}

case "$AXIS" in a|both) axis_a ;; esac
case "$AXIS" in b|both) axis_b ;; esac

echo
case "$WORST" in
  0) echo "pds-record-parity: PARITY — every axis checked, nothing divergent." ;;
  1) echo "pds-record-parity: DIVERGENT — the record and the ledger disagree above." >&2
     echo "  This red is the arm's non-vacuity proof. Close the rows or reopen them" >&2
     echo "  with a reason; do not widen the grace window to make it green." >&2 ;;
  2) echo "pds-record-parity: UNCHECKED — the arm could not look, or refused to look vacuously." >&2
     echo "  This is NOT a pass. A verb that reports success having verified nothing" >&2
     echo "  is the exact defect this epic exists to make impossible." >&2 ;;
esac
exit "$WORST"
