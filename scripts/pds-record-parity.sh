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
# ── FIVE RULINGS THIS ARM HONOURS, EACH ONE MEASURED ──────────────────────────
#
# (1) THE D-DEFINITION TEST KEYS ON THE UNION OF THE TWO FORMS THE CHARTER
#     ACTUALLY DEFINES DECISIONS IN — BOLD-LEAD BULLET **AND** OWN-LINE HEADING.
#
#     SUPERSEDED, AND KEPT VERBATIM SO THE DRIFT IS LEGIBLE — this ruling used to
#     read: "The charter defines its decisions as `- **PDS-D123** …` bullets.
#     Keying the 'is this D defined?' test on a markdown HEADING measures the
#     charter's markdown dialect instead of its record: THE CHARTER DEFINES
#     ESSENTIALLY NO D AS A HEADING, so a heading lens reports the overwhelming
#     majority of cited ids as UNRESOLVED and the arm's red becomes an artifact
#     of its own lens rather than a finding about the corpus."
#
#     IT NOW READS: the charter defines its decisions in TWO forms, and the
#     resolution lens is their UNION. The bold-lead bullet is still the majority
#     form (652 distinct numbers), but since wave 44 the charter also opens a
#     decision as its own heading — `### PDS-D643 — TITLE.` — and 24 numbers,
#     D643 through D673, are defined THAT WAY AND ONLY THAT WAY. The sentence in
#     capitals above was true when it was written and is false today.
#     WHAT THE DRIFT COST, MEASURED: over the 216 distinct PDS-D cited in
#     `git log origin/main` at 49345a98c, the bold-lead-only lens printed
#     `unresolved: 6` — D644 D649 D656 D661 D666 D667 — and every one of the six
#     is defined, as a heading (D656 at charter :12813, D667 at :13409). An arm
#     built to catch phantom citations was MANUFACTURING them, and because it is
#     advisory (zero hits for `pds-record-parity` under `.github/`) nothing ever
#     forced the correction. A lens is a measurement of the corpus or it is a
#     measurement of itself; this one had quietly become the second.
#     `--heading-lens` still exists and is still NOT the gate: it is the LOOSE
#     lens (any heading MENTIONING a D anywhere in its text), it loses every
#     bullet-defined number, and running it is how you SEE a lens artifact —
#     never how you gate on one.
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
# (4) A TRUNCATED COMMIT WALK IS UNCHECKED, AND TRUNCATION IS TESTED ON THE
#     WALK — NEVER ON THE STORE-LEVEL SHALLOW FLAG.
#     Axis A's default corpus is `git log`. Under `git clone --depth 1` that
#     walk sees ONE commit, the citation set is empty, `comm -23` over an empty
#     left side is empty, and the arm printed `cited: 0 / unresolved: 0` and
#     PARITY at exit 0 — the SAME verdict sentence a full checkout prints over
#     188 citations. actions/checkout@v4 is shallow BY DEFAULT, so wiring this
#     arm into CI unguarded ships a structurally-unfailable green in the very
#     lane meant to guard it.
#     THE TEMPTING WRONG PREDICATE, WHICH THIS REPO ITSELF REFUTES: sibling
#     scripts/release-scan.sh keys its FATAL on `git rev-parse
#     --is-shallow-repository`. The shared checkout answers TRUE while
#     `git log HEAD` reaches the root (5132 commits, exactly one root) — the
#     sole .git/shallow graft is NOT an ancestor of HEAD, left behind by one
#     off-HEAD `--depth` fetch, and a single such fetch flips a STORE-level
#     flag for the whole repository. A store-level guard was built first here
#     and watched UNCHECK the FULL checkout with "TRUNCATED to 5132 commit(s)":
#     the mirror-image lie, an arm refusing to read a corpus it holds in full.
#     SO THE PREDICATE IS: store-shallow AND at least one entry of
#     `$(git rev-parse --git-common-dir)/shallow` is an ancestor of HEAD.
#     Under --depth 1 the graft list holds HEAD itself, `--is-ancestor HEAD
#     HEAD` is true, and the real case still fires. An unreadable graft list,
#     a missing common-dir, a graft that cannot be tested, or a non-true/false
#     answer all FAIL CLOSED to UNCHECKED.
#     NO ENV ESCAPE. release-scan's truncated commits[] is still useful draft
#     material, so its stamped RELEASE_SCAN_ALLOW_SHALLOW buys something. This
#     arm's entire output is a VERDICT, and a verdict over a corpus you cannot
#     see is exactly the vacuous green the epic exists to refuse. The honest
#     escape is on the CLI already: --commits-file hands the arm its corpus.
#     FENCED TO THE GIT-LOG PATH. Never top-level: axis B reads gh and the
#     ledger and touches no history, so a top-level guard would UNCHECK
#     `--axis b` on every shallow CI checkout for no reason at all.
#
# (5) "RESOLVED" IS A CLAIM ABOUT A LAW, AND A LAW THAT NAMES TWO FINDINGS IS
#     NOT ONE LAW. THE ARM MEASURES UNIQUENESS INSTEAD OF ASSUMING IT.
#     Until this wave the definition set was built with `… | sort -u`, so a
#     number defined TWICE read as resolved and the arm said so. It was blind to
#     duplicates BY CONSTRUCTION: it never counted, so it could never notice.
#     PDS-D664 names two unrelated findings — :2654 "A REPAIRED PREDICATE CARRIES
#     ITS OLD DEFECT FOR EXACTLY ONE LINE" and :13311 "THE CLASS PREDICATE DOES
#     NOT EXIST AND WILL NOT BE INVENTED THIS WAVE" — and a citation of D664
#     resolved happily against whichever one the sort happened to keep. That is
#     a success claim that descends from no measurement of the thing claimed.
#
#     TWO GRAMMARS, AND THE ASYMMETRY IS DELIBERATE AND MEASURED:
#       RESOLUTION is PERMISSIVE (bold-lead ∪ heading, no title separator
#       required). Under-matching here manufactures phantom UNRESOLVED reds —
#       that is defect (1) above, six of them.
#       UNIQUENESS is STRICT: a TITLED definition, `**PDS-D### —` or
#       `### PDS-D### —`, the number followed by the em-dash that opens its
#       title. Over-matching here manufactures phantom collisions, because the
#       bare bold `**PDS-D399**` is how the charter CITES a decision inside
#       another decision's body. Measured on the 13,698-line charter: the
#       permissive grammar scores 65 "duplicated" numbers, the titled grammar
#       scores 20. 45 of that gap is bare-bold citations, not second findings.
#
#     THE BASELINE IS PINNED BY NUMBER, NEVER BY LINE. `cite-by-line forever` is
#     REFUTED on this epic's own record: tooling/grip/ledger/pds-w30-charter-
#     coverage-rederivation.md:14 pins the D399 pair at :6503/:6586; today they
#     are at :8625/:8708 and the charter has gone 6,888 → 13,698 lines. Lines are
#     PRINTED (so a reader can go look) and pinned NOWHERE.
#     The baseline is two-sided: an UNBASELINED duplicate reds, and a baselined
#     duplicate that has VANISHED reds too. A one-sided baseline decays into a
#     suppression list that nobody can ever prove is still describing the corpus.
#
#     THE MECHANISM, RECORDED BECAUSE THE SYMPTOM ALONE TEACHES NOTHING: every
#     genuine pair is one occurrence in a wave's REVIEW block and one in the NEXT
#     wave's DECIDE block. D664 :2654 sits under `### Wave 45 … REVIEWED`, its
#     twin :13311 under `## WAVE 46 … (decided 2026-08-04)`; D553–D556 are w38
#     REVIEW vs WAVE 39 DECIDE; D570–D573 are w39 REVIEW vs WAVE 40 DECIDE. The
#     reviewer and the decider allocate from ONE next-number pointer with no
#     arbiter between them, so this recurs EVERY wave — including the wave that
#     is reading this line.
#     THREE SHAPES A NAIVE GREP GETS WRONG, HANDLED BY NAME AND NOT BY THRESHOLD:
#     D559 is NOT a duplicate (:11859 is an inline parenthetical inside another
#     decision's body — "(CORRECTED wave 39, PDS-D559 — this entry read …)" — and
#     only :12003 defines it); D145 and D146 are BENIGN RESTATEMENTS of one
#     finding each, D146's two headings identical but for the bullet marker.
#     A threshold ("allow up to N duplicates") would have swallowed all three
#     silently along with every real collision. Names are auditable; a number is
#     not.
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
#   1  DIVERGENT — at least one leaf slice merged over an open row, a cited
#                  D that the charter does not define, or a D-number defined
#                  twice that the pinned baseline does not already carry (and
#                  the mirror: a baselined pair that has vanished)
#   2  UNCHECKED — the arm could not look (no gh, no credentials, ledger down,
#                  no charter, a TRUNCATED commit walk) OR it REFUSED to run
#                  vacuously (grace >= span)
#   3  USAGE     — bad invocation
#
# usage:
#   bash scripts/pds-record-parity.sh
#   bash scripts/pds-record-parity.sh --axis a
#   bash scripts/pds-record-parity.sh --limit 400 --grace-hours 6
#   bash scripts/pds-record-parity.sh --commits-file <file>  # axis A corpus, verbatim
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

# ── the uniqueness baseline (ruling 5) ────────────────────────────────────────
# NUMBERS, never lines. Measured on 2026-08-04 at 49345a98c over the 13,698-line
# charter with the TITLED-DEFINITION grammar (see uniqueness_leg): 696 titled
# definitions over 676 distinct numbers, 20 of which are defined twice.
#
# GENUINE — 18 numbers where ONE token names TWO UNRELATED FINDINGS. Every one is
# a wave-REVIEW block colliding with the NEXT wave's DECIDE block, both allocating
# from one next-number pointer with no arbiter. Left standing because renumbering
# them would break citations already shipped in Go (`PDS-D400` appears nine times
# in internal/cli/, `PDS-D399` six) — the honest move is to SEE them, not to hide
# them and not to rewrite history around them.
DUP_BASELINE_GENUINE="397 398 399 400 492 493 494 495 553 554 555 556 570 571 572 573 664 665"
# BENIGN — one finding restated, not two. D146's two headings are identical but
# for the leading bullet marker; D145's second is the same finding re-worded.
DUP_BASELINE_BENIGN="145 146"
# NOT A DEFINITION AT ALL — a naive `PDS-D### —` grep counts 21 numbers; this
# grammar counts 20. The gap is D559, whose :11859 occurrence is an inline
# parenthetical INSIDE another decision's body. Named, not thresholded.
DUP_NONDEF_BY_NAME="559"
# The baseline describes THIS charter. Applied only when the charter under test
# is the epic's own; any other charter (a fixture, a fork) gets no excuses, since
# nobody has measured it.
BASELINED_CHARTER_BASENAME="bp-pds-charter.md"
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

# ── is THIS walk truncated? (ruling 4) ────────────────────────────────────────
# Sets WALK_STATE to one of:
#   complete   — `git log HEAD` reaches the root; the corpus is whole
#   truncated  — a graft sits on HEAD's own history; the walk stops early
#   unknown    — git would not answer; FAIL CLOSED, treated as truncated
# WALK_GRAFT names the offending graft, WALK_REASON explains an `unknown`.
#
# The store-level flag ALONE is not the question. It is repository-wide, and one
# off-HEAD `--depth` fetch sets it for a checkout whose HEAD history is complete
# (this repo, today). The question is whether a graft lies on HEAD's OWN history.
WALK_STATE=""
WALK_GRAFT=""
WALK_REASON=""
walk_truncation() {
  WALK_STATE=""; WALK_GRAFT=""; WALK_REASON=""

  local store
  store="$(git rev-parse --is-shallow-repository 2>/dev/null)" || store=""
  case "$store" in
    false) WALK_STATE="complete"; return 0 ;;
    true)  : ;;
    *)     WALK_STATE="unknown"
           WALK_REASON="\`git rev-parse --is-shallow-repository\` answered '${store:-<nothing>}', which is neither true nor false"
           return 0 ;;
  esac

  # Store-shallow. Now ask whether it touches HEAD.
  local common
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || common=""
  if [ -z "$common" ]; then
    WALK_STATE="unknown"
    WALK_REASON="the store is shallow but \`git rev-parse --git-common-dir\` answered nothing, so the graft list cannot be located"
    return 0
  fi

  local grafts="${common%/}/shallow"
  if [ ! -r "$grafts" ]; then
    WALK_STATE="unknown"
    WALK_REASON="the store is shallow but the graft list ${grafts} is missing or unreadable, so no graft can be tested against HEAD"
    return 0
  fi

  local g rc
  while read -r g || [ -n "$g" ]; do
    case "$g" in ''|\#*) continue ;; esac
    git merge-base --is-ancestor "$g" HEAD >/dev/null 2>&1
    rc=$?
    case "$rc" in
      0) WALK_STATE="truncated"; WALK_GRAFT="$g"; return 0 ;;
      1) : ;;   # a real answer: this graft is off HEAD's history
      *) WALK_STATE="unknown"
         WALK_GRAFT="$g"
         WALK_REASON="graft ${g} could not be tested against HEAD (git merge-base --is-ancestor exit ${rc})"
         return 0 ;;
    esac
  done < "$grafts"

  WALK_STATE="complete"
  WALK_REASON="store-shallow, but no graft in ${grafts} lies on HEAD's history"
  return 0
}

# ── AXIS A, UNIQUENESS LEG — one D-number, one finding (ruling 5) ─────────────
#
# `resolved` used to be an assertion with no measurement under it: the definition
# set was `sort -u`'d, so a number defined twice was indistinguishable from a
# number defined once and a citation resolved against whichever copy survived the
# sort. This leg does the counting the claim always presupposed.
in_list() { # in_list <needle> <space-separated list>
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

uniqueness_leg() { # uniqueness_leg <cites-file>
  local cites="$1"
  local occ="$WORKDIR/titled-occ" dups="$WORKDIR/dups"
  local baselined=0

  # THE TITLED-DEFINITION GRAMMAR. Anchored at line start, and the number must be
  # followed by ` —`, the em dash that opens a decision's title. The anchor is
  # what makes the FIRST PDS-D on the line the defined one, so a title that goes
  # on to cite other decisions cannot be misattributed by a greedy match.
  # `[ \t]` and NOT `[[:space:]]`: mawk before 1.3.4 does not implement POSIX
  # character classes and matches NOTHING for them — silently, which here would
  # mean `titled: 0` and a uniqueness leg that greens because it parsed nothing.
  # The selftest pins a non-zero titled count for exactly that reason.
  awk '
    match($0, /^[ \t]*([-*][ \t]+)?\*\*PDS-D[0-9]+ —/) ||
    match($0, /^#+[ \t]+PDS-D[0-9]+ —/) {
      if (match($0, /PDS-D[0-9]+/)) print substr($0, RSTART, RLENGTH), NR
    }
  ' "$CHARTER" > "$occ"

  # number, count, " :line :line …"
  awk '{ n[$1]++; at[$1] = at[$1] " :" $2 }
       END { for (k in n) if (n[k] > 1) print k, n[k] at[k] }' "$occ" \
    | sort -k1.6n > "$dups"

  local n_occ n_distinct n_dup
  n_occ="$(wc -l < "$occ" | tr -d ' ')"
  n_distinct="$(awk '{print $1}' "$occ" | sort -u | wc -l | tr -d ' ')"
  n_dup="$(wc -l < "$dups" | tr -d ' ')"

  case "$(basename -- "$CHARTER")" in
    "$BASELINED_CHARTER_BASENAME") baselined=1 ;;
  esac

  echo "  ── uniqueness leg: one D-number, one finding ─────────────────────────"
  echo "  grammar:    TITLED DEFINITION — \`**PDS-D### —\` or \`### PDS-D### —\`."
  echo "              Strict on purpose: the bare bold \`**PDS-D399**\` is how the"
  echo "              charter CITES a decision, not how it defines one."
  echo "  titled:     ${n_occ} definitions over ${n_distinct} distinct PDS-D"
  echo "  duplicated: ${n_dup} number(s) defined more than once"
  # The printed class counts are DERIVED from the lists, never typed: a typed
  # literal stands still while the list grows, printing "18 genuine" beside a
  # 19-entry list (the printed-a-measurement-when-nothing-was-measured shape).
  local n_base_genuine n_base_benign
  n_base_genuine="$(echo "$DUP_BASELINE_GENUINE" | wc -w | tr -d ' ')"
  n_base_benign="$(echo "$DUP_BASELINE_BENIGN" | wc -w | tr -d ' ')"
  if [ "$baselined" -eq 1 ]; then
    echo "  baseline:   PINNED for $(basename -- "$CHARTER") — ${n_base_genuine} genuine + ${n_base_benign} benign, BY NUMBER."
    echo "              Lines are printed, never pinned: cite-by-line is refuted on"
    echo "              this epic's own record (D399 was :6503/:6586, is :8625/:8708)."
  else
    echo "  baseline:   NONE — $(basename -- "$CHARTER") is not the charter the baseline was"
    echo "              measured on, so no duplicate in it is excused. Nobody measured it."
  fi

  local num count lines n unexpected=0 benign=0 genuine=0
  while read -r num count lines; do
    n="${num#PDS-D}"
    if [ "$baselined" -eq 1 ] && in_list "$n" "$DUP_BASELINE_BENIGN"; then
      benign=$((benign + 1))
      echo "    BENIGN-RESTATEMENT   ${num} ${lines} — one finding restated, not two (baselined)"
    elif [ "$baselined" -eq 1 ] && in_list "$n" "$DUP_BASELINE_GENUINE"; then
      genuine=$((genuine + 1))
      echo "    DUPLICATE-DEFINITION ${num} ${lines} — ${count} unrelated findings under one number (baselined)"
    else
      unexpected=$((unexpected + 1))
      echo "    DUPLICATE-DEFINITION ${num} ${lines} — ${count} definitions, NOT IN THE BASELINE"
    fi
  done < "$dups"

  # THE MIRROR SIDE. A baseline that only ever forgives is a suppression list
  # nobody can prove still describes the corpus; a pair that has been resolved
  # must be un-pinned, and the arm says which one.
  local vanished=0
  if [ "$baselined" -eq 1 ]; then
    for n in $DUP_BASELINE_GENUINE $DUP_BASELINE_BENIGN; do
      if ! grep -q "^PDS-D${n} " "$dups"; then
        vanished=$((vanished + 1))
        echo "    STALE-BASELINE       PDS-D${n} — baselined as duplicated, but the charter now"
        echo "                         defines it once. Drop it from the baseline."
      fi
    done
  fi

  # THE COUNTED CLASSES MUST MATCH THE LISTS THAT EXCUSED THEM. benign/genuine
  # used to be computed here and then never read — the ruling ran on unexpected
  # and vanished alone, so a baselined number classified by the WRONG arm (or a
  # number sitting in both lists) changed nothing. Re-derive, per list, how many
  # baselined numbers actually FIRED and require the classification counters to
  # agree; disagreement is DIVERGENT, not decoration.
  local misclass=0
  if [ "$baselined" -eq 1 ]; then
    local fired_genuine=0 fired_benign=0
    for n in $DUP_BASELINE_GENUINE; do
      grep -q "^PDS-D${n} " "$dups" && fired_genuine=$((fired_genuine + 1))
    done
    for n in $DUP_BASELINE_BENIGN; do
      grep -q "^PDS-D${n} " "$dups" && fired_benign=$((fired_benign + 1))
    done
    if [ "$genuine" -ne "$fired_genuine" ] || [ "$benign" -ne "$fired_benign" ]; then
      misclass=1
      echo "    BASELINE-MISCOUNT    classified genuine=${genuine} benign=${benign}, but the lists say"
      echo "                         ${fired_genuine} genuine + ${fired_benign} benign fired — a baselined number was"
      echo "                         classified by a different arm than its list claims (or sits in"
      echo "                         both lists). The baseline no longer describes the classifier."
    fi
  fi

  # THE THREE SHAPES A NAIVE GREP GETS WRONG, HANDLED BY NAME. A naive
  # `PDS-D### —` grep counts occurrences ANYWHERE on a line, including inside
  # another decision's prose. The gap between the two counts is re-derived on
  # every run and every number in it must be named, or the arm says so.
  local naive="$WORKDIR/naive-dups"
  grep -oE 'PDS-D[0-9]{3} —' "$CHARTER" | sed 's/ —$//' | sort | uniq -c \
    | awk '$1 > 1 { print $2 }' | sort -k1.6n > "$naive"
  echo "  naive grep: $(wc -l < "$naive" | tr -d ' ') number(s) — the unanchored \`PDS-D### —\` count, for contrast only"
  local nn
  while read -r num; do
    grep -q "^${num} " "$dups" && continue
    nn="${num#PDS-D}"
    if in_list "$nn" "$DUP_NONDEF_BY_NAME"; then
      echo "    NOT-A-DUPLICATE      ${num} — the second occurrence is an inline parenthetical"
      echo "                         inside another decision's body, not a definition (named)"
    else
      echo "    UNNAMED-NAIVE-ONLY   ${num} — a naive grep counts it, the titled grammar does"
      echo "                         not. Classify it by name; not scored (the naive grep is"
      echo "                         a contrast, never the law)."
    fi
  done < "$naive"

  # WHAT A CITATION OF A DUPLICATED NUMBER ACTUALLY RESOLVES TO: nothing single.
  # Reported, not scored — the scored quantity is the duplicate set itself, and
  # scoring the same defect twice would just double-count one measurement.
  local amb="$WORKDIR/ambiguous"
  awk '{print $1}' "$dups" | sort > "$WORKDIR/dupnums"
  comm -12 "$cites" "$WORKDIR/dupnums" > "$amb"
  # The headline count must equal the number of lines under it. A benign
  # restatement is CITED-BUT-UNAMBIGUOUS — it resolves to one finding stated
  # twice — so it is counted separately rather than folded in and left unprinted.
  local n_amb=0 n_amb_benign=0
  while read -r num; do
    n="${num#PDS-D}"
    if [ "$baselined" -eq 1 ] && in_list "$n" "$DUP_BASELINE_BENIGN"; then
      n_amb_benign=$((n_amb_benign + 1))
    else
      n_amb=$((n_amb + 1))
    fi
  done < "$amb"
  echo "  ambiguous:  ${n_amb} cited number(s) resolve to more than one FINDING"
  echo "              (+${n_amb_benign} cited number(s) defined twice but naming ONE finding)"
  while read -r num; do
    n="${num#PDS-D}"
    if [ "$baselined" -eq 1 ] && in_list "$n" "$DUP_BASELINE_BENIGN"; then continue; fi
    lines="$(awk -v k="$num" '$1 == k { $1=""; $2=""; print }' "$dups" | sed 's/^  *//')"
    echo "    AMBIGUOUS-CITATION   ${num} ${lines} — the commit corpus cites it; the charter"
    echo "                         answers with two findings. Reported, not scored."
  done < "$amb"

  if [ "$n_dup" -gt 0 ] || [ "$vanished" -gt 0 ]; then
    echo "  MECHANISM: a duplicate is not bad luck. Every genuine pair is ONE occurrence"
    echo "             in a wave's REVIEW block and ONE in the NEXT wave's DECIDE block —"
    echo "             D664 :2654 under \`### Wave 45 … REVIEWED\` vs :13311 under \`## WAVE 46\`"
    echo "             … DECIDED; D553–D556 w38 REVIEW vs WAVE 39 DECIDE; D570–D573 w39"
    echo "             REVIEW vs WAVE 40 DECIDE. The reviewer and the decider allocate from"
    echo "             ONE next-number pointer with no arbiter, so it recurs EVERY wave,"
    echo "             including this one. Fix the pointer, not the symptom."
  fi

  if [ "$unexpected" -gt 0 ] || [ "$vanished" -gt 0 ] || [ "$misclass" -gt 0 ]; then
    echo "  DIVERGENT: ${unexpected} unbaselined duplicate(s), ${vanished} stale baseline entrie(s), ${misclass} baseline miscount(s)."
    echo "             The baseline is two-sided on purpose — it must keep descending from"
    echo "             a measurement of the charter as it is, not as it was."
    raise 1
  fi
  return 0
}

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
    # The LOOSE heading lens: any heading that MENTIONS a D anywhere in its text.
    # It loses every bullet-defined number and is kept only to demonstrate what a
    # lens artifact looks like. Never the gate. See ruling (1).
    lens="LOOSE HEADING (lens-artifact demonstrator — NOT the gate)"
    grep -oE '^#+[[:space:]].*PDS-D[0-9]+' "$CHARTER" | grep -oE 'PDS-D[0-9]+' | sort -u > "$defs"
  else
    # THE UNION OF THE TWO FORMS THE CHARTER DEFINES DECISIONS IN (ruling 1):
    #   a bold lead at the start of a line, optionally bulleted —
    #     **PDS-D123** …    - **PDS-D123** …    * **PDS-D123** …
    #   and a heading whose text OPENS with the number —
    #     ### PDS-D643 — TITLE.
    # The heading arm anchors on the number at the START of the heading text, so
    # a heading that merely mentions a D in passing ("## WAVE 46 … (PDS-D640)")
    # is a reference and is not counted. That distinction is the whole difference
    # between this lens and --heading-lens.
    lens="DEFINITION FORMS — bold-lead bullet UNION own-line heading"
    {
      grep -oE '^[[:space:]]*([-*][[:space:]]+)?\*\*PDS-D[0-9]+' "$CHARTER"
      grep -oE '^#+[[:space:]]+PDS-D[0-9]+([[:space:]]|$)' "$CHARTER" # revert-marker: heading-arm
    } | grep -oE 'PDS-D[0-9]+' | sort -u > "$defs"
  fi

  if [ -n "$COMMITS_FILE" ]; then
    [ -f "$COMMITS_FILE" ] || { echo "  UNCHECKED: --commits-file ${COMMITS_FILE} not found" >&2; raise 2; return 0; }
    grep -oE 'PDS-D[0-9]+' "$COMMITS_FILE" | sort -u > "$cites"
  else
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
      echo "  UNCHECKED: not inside a git work tree — the commit corpus is unreachable" >&2
      raise 2; return 0
    fi

    # RULING 4. A shallow checkout IS a work tree, so the check above passes and
    # `git log` happily walks its one commit. Fenced HERE, to the git-log path
    # only — --commits-file brings its own corpus and axis B reads no history.
    walk_truncation
    if [ "$WALK_STATE" != "complete" ]; then
      local seen_commits seen_cites
      seen_commits="$(git rev-list --count HEAD 2>/dev/null)" || seen_commits=""
      seen_cites="$(git log --format=%B 2>/dev/null | grep -oE 'PDS-D[0-9]+' | sort -u | wc -l | tr -d ' ')"
      {
        if [ "$WALK_STATE" = "truncated" ]; then
          echo "  UNCHECKED: TRUNCATED WALK — this checkout's history is grafted ON HEAD, so"
          echo "             any citation tally printed here would be a tally over a corpus"
          echo "             the arm never read."
          echo "             graft:   ${WALK_GRAFT} (an ancestor of HEAD — the walk stops here)"
        else
          echo "  UNCHECKED: WALK COMPLETENESS UNKNOWN — the arm could not establish that it"
          echo "             can see the whole history, and it fails CLOSED rather than green."
          echo "             reason:  ${WALK_REASON}"
          [ -n "$WALK_GRAFT" ] && echo "             graft:   ${WALK_GRAFT}"
        fi
        echo "             visible: ${seen_commits:-unknown} commit(s) reachable from HEAD, ${seen_cites} distinct PDS-D"
        echo "             A verdict over a corpus you cannot see is the vacuous green this arm"
        echo "             exists to refuse, so it refuses instead of printing PARITY at exit 0."
        echo "             fix (CI):    check out with \`fetch-depth: 0\` (actions/checkout is shallow BY DEFAULT)"
        echo "             fix (local): \`git fetch --unshallow\`"
        echo "             or hand the arm its corpus explicitly: --commits-file <file>"
      } >&2
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
      echo "  ADVISORY: this run used the LOOSE HEADING lens, which measures the charter's"
      echo "            markdown dialect, not its record. Its red is a LENS ARTIFACT."
      echo "            Not folded into the exit code — re-run without --heading-lens."
    else
      raise 1
    fi
  fi

  # The uniqueness leg is a property of the CHARTER, not of the resolution lens,
  # so it runs under --heading-lens too and its verdict is its own. The two legs
  # are independent by construction: breaking one cannot green or red the other.
  uniqueness_leg "$cites"
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

  local no_trailer=0 declared_none=0 i=0 body id num merged b64 idlc
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
    # A DECLARED ABSENCE IS AN ABSENCE, NOT A GHOST TASK. #6371's body says
    # literally `Task: n/a`. The canonical grammar extracts `n/a` as the id and
    # the ledger 404s on it, which the row disposition would then report as
    # "merged over a task id the ledger does not carry" — a TRUE statement
    # wearing the WRONG sentence, and a RED where the structurally identical
    # case (no trailer at all, #105 in the fixtures) is advisory. Both are the
    # same fact: the PR declared no task. This is a DISPOSITION rule over the
    # extracted string, not a second trailer grammar — the grammar still runs
    # first and still owns what counts as an id.
    idlc="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
    case "$idlc" in
      n/a|n\\a|na|none|nil|null|tbd|-|todo)
        declared_none=$((declared_none + 1))
        continue ;;
    esac
    printf '%s\t%s\t%s\n' "$id" "$num" "$merged" >> "$ids"
  done < <(jq -r '.[] | [(.number|tostring), .mergedAt, (.body // "" | @base64)] | @tsv' "$prs")

  local n_ids
  n_ids="$(cut -f1 "$ids" | sort -u | wc -l | tr -d ' ')"
  echo "  extractor:  ${EXTRACTOR} --extract-task-id  (absence = EMPTY STDOUT, never \$?)"
  echo "  task ids:   ${n_ids} distinct across ${i} PRs"
  echo "  no trailer: ${no_trailer} PRs carry no Task: trailer (advisory — predates the gate)"
  echo "  declared none: ${declared_none} PRs declare a SENTINEL id (Task: n/a and friends) — the same"
  echo "                 fact as no trailer, said out loud (advisory, never a ghost-task red)"

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

    # PACE THE READ, NOT THE VERDICT. This sleep used to sit at the BOTTOM of
    # the loop body, after every `continue` — so it fired only on the DIVERGENT
    # rows and paced nothing on a healthy ledger, which is precisely the sweep
    # that needs pacing. It belongs immediately before the request.
    [ "$PACE" != "0" ] && sleep "$PACE"

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
