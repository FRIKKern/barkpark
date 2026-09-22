#!/usr/bin/env bash
#
# PDS RECORD PARITY — the epic's law turned on the epic's OWN record.
#
# The law, unchanged since wave 22: NO BARKPARK VERB MAY REPORT SUCCESS ON AN
# EXIT CODE ALONE. Every arm this epic has shipped so far points that law at
# some OTHER surface — a controller, a census, a receipt. This one points it at
# the record the epic itself writes, on three axes:
#
#   AXIS A — A COMMIT MAY NOT CITE AN AUTHORITY THAT DOES NOT EXIST.
#            Every PDS-Dnnn cited in a commit message must be DEFINED in the
#            charter. A decision id in a commit is a citation; a citation to
#            nothing is a commit claiming an authority it never had.
#
#   AXIS D — A PDS SCRIPT MAY NOT CITE AN AUTHORITY THAT DOES NOT EXIST.
#            The same law as axis A, pointed at the corpus axis A cannot see:
#            the PDS-Dnnn literals carried in `scripts/pds-*.sh` and
#            `tooling/pds/**`. A commit message is written once; a script
#            comment survives the charter RENUMBER that invalidates it.
#            (There is no axis C. The letter is D for the D-numbers.)
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
#   bash scripts/pds-record-parity.sh --axis d            # script citations vs charter
#   bash scripts/pds-record-parity.sh --axis f            # harness thaw ledger (PDS-D759)
#   bash scripts/pds-record-parity.sh --axis f --charter <copy>  # the PLANTED CONTROL
#   bash scripts/pds-record-parity.sh --axis d --citation-root <dir>  # fixture tree
#   bash scripts/pds-record-parity.sh --limit 400 --grace-hours 6
#   bash scripts/pds-record-parity.sh --commits-file <file>  # axis A corpus, verbatim
#   bash scripts/pds-record-parity.sh --fixture-dir <dir>   # hermetic, selftest
#   bash scripts/pds-record-parity.sh --allocate-d <n> --for <label>  # MINT D numbers
#   bash scripts/pds-record-parity.sh --check-alloc          # every mint was reserved
#   bash scripts/pds-record-parity.sh --prefix D --charter <c> --alloc-ledger <l> --check-alloc
#                                          # the SAME arbiter, a DIFFERENT charter (see D-PREFIX below)
#   bash scripts/pds-record-parity.sh --print-defs [--charter <path>]  # the lens, alone
#   bash scripts/pds-record-parity.sh --print-synthetic <a|d>          # the roster, alone

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
# Axis D's corpus root — the repo by default, a fixture tree in the selftest.
CITATION_ROOT="${PDS_RECORD_PARITY_CITATION_ROOT:-.}"
FIXTURE_DIR=""           # hermetic transport for BOTH gh and the ledger
HEADING_LENS=0           # lens artifact demonstrator; never the gate
ALLOCATE_D=""            # --allocate-d <n>: mint n PDS-D numbers through the arbiter
ALLOC_FOR=""             # --for <label>: who is minting (e.g. "w50 DECIDE")
CHECK_ALLOC=0            # --check-alloc: every number minted since the seed was reserved
# READ-ONLY ACCESSORS. This file owns the definition lens and the synthetic
# roster; sibling arms must READ them, never re-derive them. The lens has
# drifted once already (PDS-D679: a heading-blind lens manufactured six phantom
# citations), and a second copy is a second thing to drift.
PRINT_DEFS=0             # --print-defs: the charter's defined numbers, one per line
PRINT_SYNTHETIC=""       # --print-synthetic <a|d>: that axis's skip roster
# THE RESERVATION LEDGER. The arbiter's whole substance: a durable record that
# a number has been SPOKEN FOR, written BEFORE the charter is. See allocate_d.
ALLOC_LEDGER="${PDS_D_ALLOC_LEDGER:-tooling/pds/d-number-reservations.tsv}"
# ── THE D-PREFIX: ONE ARBITER, MANY CHARTERS ─────────────────────────────────
# The allocation arms (--allocate-d / --check-alloc / --print-defs) are not
# specific to the PDS charter: the defect they fix — two correct readers of one
# unchanged document a minute apart minting the same number, because a document
# is a lagging record of what has LANDED and cannot express what is IN FLIGHT —
# belongs to every charter that numbers its decisions. It cost the DEPLOY
# charter a collision on D614 on 2026-09-16 (#18700 kept it, #18701 rebased).
#
# So the token is a parameter, not a literal. `--prefix D --charter
# .claude/workflows/bp-deploy-reliability-charter.md --alloc-ledger
# deploy/d-number-reservations.tsv` runs THIS arbiter over THAT charter.
# A SECOND copy of this logic is the outcome to avoid: two arbiters can drift,
# and the lens in here has drifted once already (PDS-D679).
#
# The default is PDS-D, so every existing caller, fixture and CI arm is
# byte-identical to before this parameter existed.
D_PREFIX="${PDS_RECORD_PARITY_PREFIX:-PDS-D}"

# ── THE RULING-NUMBER SHAPE: DIGITS WITH AN OPTIONAL LETTER SUFFIX ───────────
#
# A ruling number is NOT digits. The charter mints lettered rulings — 34 of them
# on main at the time of writing (PDS-D448a, PDS-D448b, PDS-D449a, … PDS-D496a)
# — and the scripts cite them: PDS-D220a x26, PDS-D220b x12, PDS-D391b, PDS-D480a.
#
# WHAT A DIGITS-ONLY PREDICATE COST, MEASURED. Every scan in here used to read
# the prefix followed by digits only, so `PDS-D480a` was extracted as `PDS-D480`
# — a DIFFERENT ruling. In all 34 cases the numeric base is itself a separately
# defined ruling, so the merge was SILENT rather than a missing-definition red,
# and the undefined-citation arm could not fire on a lettered typo at all: cite
# `PDS-D448` with a stray trailing `z` and it RESOLVED, because `PDS-D448`
# exists — and axis D would red on this very comment if it spelled that phantom
# out, which is the widening proving itself in its own header. The guard's whole
# purpose was defeated for that shape. Reproduced against a fixture tree, with a
# numeric phantom as the control, BEFORE this was widened.
#
# THE SAME SHAPE `scripts/pds-citation-expand.sh` CARRIES. Its every segment
# class is `[0-9]+[a-z]?` and its selftest arm 4b reds if anyone narrows it back.
# This file gets the same treatment: the shapes are NAMED here, every scan reads
# a name, and `pds-record-parity.test.sh` runs a PREDICATE over this whole file —
# not a list of line numbers somebody eyeballed — that reds if a digit class ever
# reappears beside the prefix. A constant nobody may bypass is the only form of
# this rule that survives the next edit.
D_NUM_RE='[0-9]+[a-z]?'          # a ruling number, as CITED and as DEFINED
D_BASE_RE='[0-9]+'               # the ALLOCATION base — see below
D_NAIVE_NUM_RE='[0-9]{3}[a-z]?'  # the contrast-only naive lens's fixed-width form

# WHY THE ALLOCATION LEDGER STAYS ON THE BASE. A letter is a SUB-ruling of a
# number that was already minted: `PDS-D448a` consumes no new number, and the
# arbiter's pointer is arithmetic (`high + 1`). Feeding `448a` into `-gt` or
# `sort -n` would be a type error wearing a widening's clothes. So the arbiter
# reads bases (charter_defined_bases), the RESOLUTION lenses read full ids, and
# neither borrows the other's shape.
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
    --citation-root) CITATION_ROOT="${2:-}"; shift 2 ;;
    --limit)         LIMIT="${2:-}"; shift 2 ;;
    --grace-hours)   GRACE_HOURS="${2:-}"; shift 2 ;;
    --charter)       CHARTER="${2:-}"; shift 2 ;;
    --commits-file)  COMMITS_FILE="${2:-}"; shift 2 ;;
    --fixture-dir)   FIXTURE_DIR="${2:-}"; shift 2 ;;
    --heading-lens)  HEADING_LENS=1; shift ;;
    --allocate-d)    ALLOCATE_D="${2:-}"; shift 2 ;;
    --for)           ALLOC_FOR="${2:-}"; shift 2 ;;
    --alloc-ledger)  ALLOC_LEDGER="${2:-}"; shift 2 ;;
    --prefix)        D_PREFIX="${2:-}"; shift 2 ;;
    --check-alloc)   CHECK_ALLOC=1; shift ;;
    --print-defs)    PRINT_DEFS=1; shift ;;
    --print-synthetic) PRINT_SYNTHETIC="${2:-}"; shift 2 ;;
    -h|--help)       usage ;;
    *) echo "pds-record-parity: unknown argument '$1'" >&2; usage ;;
  esac
done

case "$AXIS" in a|b|d|f|both) : ;; *) echo "pds-record-parity: --axis must be a|b|d|f|both, got '${AXIS}'" >&2; usage ;; esac
case "$LIMIT" in ''|*[!0-9]*|0) echo "pds-record-parity: --limit must be a positive integer, got '${LIMIT}'" >&2; usage ;; esac
case "$GRACE_HOURS" in ''|*[!0-9]*) echo "pds-record-parity: --grace-hours must be a non-negative integer, got '${GRACE_HOURS}'" >&2; usage ;; esac
case "$RETRIES" in ''|*[!0-9]*|0) echo "pds-record-parity: PDS_RECORD_PARITY_RETRIES must be a positive integer, got '${RETRIES}'" >&2; usage ;; esac

# The prefix is spliced into an ERE and into sed/awk patterns. Restrict it to
# the shape a charter token actually has, so a metacharacter cannot silently
# widen the lens into the "any D-number anywhere" scan this whole arm exists to
# refuse. An empty prefix would match every bare integer; it is refused too.
case "$D_PREFIX" in
  '' | *[!A-Za-z0-9-]* ) echo "pds-record-parity: --prefix must be non-empty and only [A-Za-z0-9-], got '${D_PREFIX}'" >&2; usage ;;
esac

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

# ══ THE D-NUMBER ARBITER — fix the pointer, not the symptom ══════════════════
#
# THE DEFECT, STATED AS A MECHANISM AND NOT AS A SYMPTOM. Eighteen numbers in
# this charter name two unrelated findings each, and every one of the eighteen
# has the SAME shape: one occurrence in a wave's REVIEW block, one in the NEXT
# wave's DECIDE block. Both authors computed the next number the only way there
# was — `max(defined in the charter) + 1` — and both computed it BEFORE either
# block was written down. Two reads of one unchanged corpus return one answer.
# That is not bad luck and it is not carelessness; it is a pointer with no
# write-side. It recurs every wave that allocates in both blocks, which is why
# the uniqueness leg's baseline grows and why a threshold would have hidden it.
#
# THE FIX IS A RESERVATION, NOT A RE-READ. The arbiter writes the claim down
# BEFORE the charter carries it, and every subsequent allocation reads the
# charter AND the reservations. The REVIEW author reserves D719; the DECIDE
# author, minutes later and with the charter still untouched, reads a corpus
# that now says 719 is taken and mints D720. The collision is not detected
# afterwards — it cannot be minted.
#
# WHY A LEDGER FILE AND NOT A BIGGER GREP. Every lens over the charter alone
# shares the one property that causes this: it can only see numbers that have
# already been WRITTEN. The window between "I decided to use 719" and "719 is
# in the charter" is exactly where the collision lives, and no reader of the
# charter can see into it. Something outside the charter has to hold the claim.
#
# MUTUAL EXCLUSION IS `mkdir`, NOT A FLAG FILE. `mkdir` is atomic and fails if
# the directory exists — one syscall, no test-then-act window. `[ -e lock ] &&
# exit || touch lock` is the classic two-step that loses exactly the race it was
# written for. A lock that cannot be taken is UNCHECKED (exit 2), never a silent
# proceed: the whole point is that minting without the arbiter is what broke.
#
# THE SEED. Numbers at or below the seed predate the arbiter and are not
# reserved retroactively — a retroactive reservation would be a claim about
# history nobody measured. --check-alloc therefore scores only numbers ABOVE
# the seed, which is the set the arbiter could actually have governed.

# The DEFINITION lens — bold-lead bullet UNION own-line heading, the same union
# axis A resolves citations against. NOT "any PDS-D anywhere": the charter's own
# prose mentions the synthetic fixtures PDS-D777/PDS-D999, and a lens that
# counted those would jump the pointer to 1000 on the strength of a sentence
# about a test fixture.
charter_defined_numbers() {
  [ -f "$CHARTER" ] || return 1
  # `sort -u` then `sort -n -s`, NEVER `sort -n -u`: under a numeric key `448`
  # and `448a` compare EQUAL, so `-n -u` would silently drop one of them — the
  # very collapse this widening exists to stop, reintroduced by the sort. The
  # lexicographic `-u` dedups on the WHOLE id; the stable numeric pass then
  # orders `404 448 448a 1000` and keeps `448` ahead of `448a`.
  {
    grep -oE "^[[:space:]]*([-*][[:space:]]+)?\*\*${D_PREFIX}${D_NUM_RE}" "$CHARTER"
    grep -oE "^#+[[:space:]]+${D_PREFIX}${D_NUM_RE}([[:space:]]|$)" "$CHARTER"
  } | grep -oE "${D_PREFIX}${D_NUM_RE}" | sed "s/^${D_PREFIX}//" | sort -u | sort -n -s
}

# The same lens, projected onto the ALLOCATION base — `448a` -> `448`. This is
# what the arbiter scores: a letter never consumed a number, so a lettered
# definition must not read as an unreserved mint and must not move the pointer.
charter_defined_bases() {
  charter_defined_numbers | sed 's/[a-z]*$//' | sort -n -u
}

# ── THE CLAUSE LENS — AND WHY IT IS NOT "RESOLVE A LETTER BY ITS BASE" ───────
#
# Widening the extractor turns up a THIRD shape, live on main: `PDS-D220a` x26
# and `PDS-D220b` x12 and `PDS-D391b`, which are not rulings at all. They name a
# CLAUSE inside a ruling — D220's definition line literally reads
#   `- **PDS-D220 — TWO PRE-MERGE INSTRUMENT FIXES …** (a) **THE ZERO-SAMPLE …`
# and the scripts cite clause (a) as `PDS-D220a`. That is a real citation to a
# real authority and must not red.
#
# THE TEMPTING FIX IS THE DEFECT AGAIN. "A lettered citation resolves if its
# numeric base is defined" would green `PDS-D220a` — and green a `PDS-D448` with
# a stray `z` with it, which is precisely the blind spot this file was widened to
# close. The base
# is not the discriminator. The CHARTER is: a clause reference resolves only if
# the base's own definition BLOCK carries the literal marker `(a)`. D220's does;
# D448's carries no `(z)`, and no charter block anywhere carries one. Measured on
# main: 220a, 220b, 391b resolve here; the `z`-suffixed phantoms of 448, 480 and
# 391 do not. (Spelled that way on purpose: a phantom written out in full in a
# pds-*.sh comment is a citation, and axis D reds on it — as it should.)
#
# The block runs from the base's definition line to the NEXT definition line, so
# a marker belonging to some other ruling cannot be borrowed.
charter_clause_defined() { # charter_clause_defined <id, e.g. 220a> — rc 0 if it is a clause
  case "$1" in *[a-z]) : ;; *) return 1 ;; esac
  [ -f "$CHARTER" ] || return 1
  local base="${1%[a-z]}" letter="${1##*[0-9]}"
  awk -v pfx="$D_PREFIX" -v num="$D_NUM_RE" -v base="$base" -v l="$letter" '
    BEGIN {
      anydef = "^[ \t]*([-*][ \t]+)?\\*\\*" pfx num "|^#+[ \t]+" pfx num
      # `[^0-9a-zA-Z]` after the base so 22 cannot claim 220s definition line.
      thisdef = "^[ \t]*([-*][ \t]+)?\\*\\*" pfx base "[^0-9a-zA-Z]|^#+[ \t]+" pfx base "[^0-9a-zA-Z]"
    }
    $0 ~ anydef { if (inblock) exit; if ($0 ~ thisdef) inblock = 1 }
    inblock && index($0, "(" l ")") { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$CHARTER"
}

alloc_ledger_numbers() { # every number this ledger has ever spoken for, seed excluded
  [ -f "$ALLOC_LEDGER" ] || return 0
  awk -F'\t' -v pfx="$D_PREFIX" -v num="$D_BASE_RE" '$1 ~ "^" pfx num "$" { sub("^" pfx, "", $1); print $1 }' "$ALLOC_LEDGER" | sort -n -u
}

alloc_seed() { # the high-water mark at adoption; empty if the ledger has none
  [ -f "$ALLOC_LEDGER" ] || return 0
  awk -F'\t' '$1 == "SEED" { print $2; exit }' "$ALLOC_LEDGER"
}

allocate_d() { # allocate_d <count>
  local count="$1"
  local dir lock
  dir="$(dirname -- "$ALLOC_LEDGER")"
  mkdir -p "$dir" 2>/dev/null || { echo "pds-record-parity: UNCHECKED: cannot create ${dir}" >&2; return 2; }
  lock="${dir}/.d-alloc.lock"

  # ATOMIC, AND IT FAILS CLOSED. No retry loop and no stale-lock reaper: a
  # reaper is a second race (two callers can both decide a lock is stale) and
  # an allocation is a five-second human act, not a queue. A held lock means
  # somebody is minting right now — come back, or remove the directory by hand
  # after you have looked at who owns it.
  if ! mkdir "$lock" 2>/dev/null; then
    echo "pds-record-parity: UNCHECKED: the allocation lock ${lock} is held." >&2
    echo "  Another allocation is in flight. This is a REFUSAL, not a failure:" >&2
    echo "  proceeding without the lock is exactly how the eighteen pairs were minted." >&2
    return 2
  fi
  # The trap already removes WORKDIR; extend it rather than replace it, because
  # a second `trap ... EXIT` silently discards the first and leaks the scratch dir.
  trap 'rm -rf -- "$WORKDIR"; rmdir "'"$lock"'" 2>/dev/null' EXIT

  local defs high_charter high_res high seed now
  defs="$(charter_defined_bases)" || {
    echo "pds-record-parity: UNCHECKED: charter ${CHARTER} not found — the arbiter will not" >&2
    echo "  mint a number against a corpus it cannot read." >&2
    rmdir "$lock" 2>/dev/null; return 2
  }
  high_charter="$(printf '%s\n' "$defs" | tail -1)"
  [ -n "$high_charter" ] || { echo "pds-record-parity: UNCHECKED: ${CHARTER} defines no ${D_PREFIX} at all" >&2; rmdir "$lock" 2>/dev/null; return 2; }

  # THE ARM UNDER MUTATION. Delete the next line and the pointer is `max(charter)
  # + 1` again — the pre-arbiter pointer that minted all eighteen pairs. The
  # selftest does exactly that deletion and watches the collision come back.
  high_res="$(alloc_ledger_numbers | tail -1)"   # revert-marker: arbiter-reserve-arm
  high="$high_charter"
  [ -n "${high_res:-}" ] && [ "$high_res" -gt "$high" ] && high="$high_res"

  seed="$(alloc_seed)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -z "$seed" ]; then
    # The `[ -f ]` test is taken BEFORE the redirection, not inside it: `>>` on a
    # group creates the file first, so a test inside the group always sees it
    # existing and the header line is never written.
    local had_ledger=1; [ -f "$ALLOC_LEDGER" ] || had_ledger=0
    { [ "$had_ledger" -eq 1 ] || printf '# %s RESERVATION LEDGER — a number is SPOKEN FOR here before the charter carries it.\n# number\treserved_at\tfor\n' "$D_PREFIX"
      printf 'SEED\t%s\t%s\thigh-water mark at adoption; numbers at or below it predate the arbiter\n' "$high_charter" "$now"
    } >> "$ALLOC_LEDGER" || { echo "pds-record-parity: UNCHECKED: cannot write ${ALLOC_LEDGER}" >&2; rmdir "$lock" 2>/dev/null; return 2; }
    seed="$high_charter"
  fi

  local i=0 n
  while [ "$i" -lt "$count" ]; do
    n=$(( high + 1 + i ))
    printf '%s%s\t%s\t%s\n' "$D_PREFIX" "$n" "$now" "${ALLOC_FOR:-(unattributed)}" >> "$ALLOC_LEDGER" || {
      echo "pds-record-parity: UNCHECKED: cannot append to ${ALLOC_LEDGER}" >&2; rmdir "$lock" 2>/dev/null; return 2; }
    printf '%s%s\n' "$D_PREFIX" "$n"
    i=$((i + 1))
  done
  rmdir "$lock" 2>/dev/null
  echo "pds-record-parity: RESERVED ${count} number(s) in ${ALLOC_LEDGER} (charter high-water ${high_charter}, ledger high-water ${high}, seed ${seed})." >&2
  echo "  Write them into the charter now. The reservation is what stops the NEXT block" >&2
  echo "  minting them again while this one is still unwritten." >&2
  return 0
}

check_alloc() {
  local seed defs res unreserved=0 dupres=0 n
  seed="$(alloc_seed)"
  if [ -z "$seed" ]; then
    echo "pds-record-parity: UNCHECKED: ${ALLOC_LEDGER} carries no SEED row — nothing has been" >&2
    echo "  minted through the arbiter yet, so there is no population to check. Run" >&2
    echo "  --allocate-d once to adopt it." >&2
    # `return 2` ALONE IS THE VACUOUS GREEN. The caller folds through raise() and
    # scores WORST; a bare return here printed UNCHECKED to stderr and then exited
    # 0 — a verb reporting success having verified nothing, inside the arm written
    # to make that impossible. The selftest fixture below caught it.
    raise 2; return 0
  fi
  defs="$(charter_defined_bases)" || { echo "pds-record-parity: UNCHECKED: charter ${CHARTER} not found" >&2; raise 2; return 0; }
  res="$(alloc_ledger_numbers)"
  echo "D-NUMBER ALLOCATION — every number minted since the seed was reserved first"
  echo "  prefix:     ${D_PREFIX}"
  echo "  charter:    ${CHARTER}"
  echo "  ledger:     ${ALLOC_LEDGER}"
  echo "  seed:       ${seed} (numbers at or below it predate the arbiter and are not scored)"
  echo "  reserved:   $(printf '%s\n' "$res" | grep -c '[0-9]') number(s)"
  # A ledger that reserves one number twice is the defect wearing the fix's
  # clothes, so it is scored before anything else.
  dupres="$(awk -F'\t' -v pfx="$D_PREFIX" -v num="$D_BASE_RE" '$1 ~ "^" pfx num "$" { c[$1]++ } END { n=0; for (k in c) if (c[k] > 1) n++; print n }' "$ALLOC_LEDGER" 2>/dev/null || echo 0)"
  if [ "${dupres:-0}" -gt 0 ]; then
    echo "  DIVERGENT: ${dupres} number(s) reserved MORE THAN ONCE — the arbiter minted a collision."
    raise 1
  fi
  for n in $defs; do
    [ "$n" -le "$seed" ] && continue
    if ! printf '%s\n' "$res" | grep -qx "$n"; then
      echo "    UNRESERVED-MINT      ${D_PREFIX}${n} — defined in the charter above the seed, never"
      echo "                         reserved. Somebody minted it by reading the charter, which"
      echo "                         is the pointer that produced all eighteen pairs."
      unreserved=$((unreserved + 1))
    fi
  done
  if [ "$unreserved" -gt 0 ]; then
    echo "  DIVERGENT: ${unreserved} number(s) minted without a reservation."
    raise 1
  else
    echo "  PARITY:     every charter number above the seed was reserved first."
  fi
  return 0
}

if [ "$PRINT_DEFS" -eq 1 ]; then
  charter_defined_numbers || { echo "pds-record-parity: UNCHECKED: charter ${CHARTER} not found" >&2; exit 2; }
  exit 0
fi
if [ -n "$ALLOCATE_D" ]; then
  case "$ALLOCATE_D" in ''|*[!0-9]*|0) echo "pds-record-parity: --allocate-d must be a positive integer, got '${ALLOCATE_D}'" >&2; usage ;; esac
  allocate_d "$ALLOCATE_D"; exit $?
fi
if [ "$CHECK_ALLOC" -eq 1 ]; then
  check_alloc
  case "$WORST" in
    0) echo "pds-record-parity: PARITY — every number above the seed was reserved before it was minted." ;;
    1) echo "pds-record-parity: DIVERGENT — see above." >&2 ;;
    2) echo "pds-record-parity: UNCHECKED — the allocation ledger could not be scored. NOT a pass." >&2 ;;
  esac
  exit "$WORST"
fi

echo "pds-record-parity: the epic's law, turned on the epic's own record"
echo "  repo=${REPO}  ledger=${LEDGER_BASE}  dataset=${DATASET}${FIXTURE_DIR:+  transport=FIXTURES(${FIXTURE_DIR})}"
# ── THIS ARM IS A REPORTER. IT MUST NEVER CARRY A REQUIRED CHECK NAME. ────────
# Said in the output and not only in a comment, because the comment is read by
# whoever is already editing the file and the sentence is for whoever is reading
# the RUN. Axis B reds on leaf rows belonging to epics that never consented to
# this instrument — 93.4% of the wave-39 population belonged to eleven OTHER
# epics — so a blocking version would fail other people's PRs on other people's
# ledger hygiene. The structure agrees with the sentence today, in two places:
# .github/workflows/shell-harnesses.yml carries a workflow-level
# `on: pull_request: paths:` filter, so on a PR touching none of those paths the
# `pds-harnesses` context is ABSENT — and a required context that is absent
# reports "expected" forever (PDS-D18). .github/required-checks.json records
# exactly that as an S4 PATHS-FILTERED exclusion for this job. So the arm
# structurally CANNOT be required, and that is the design, not an accident.
echo "  standing:   REPORTER, never a gate. Its red names OTHER epics' rows and must"
echo "              never carry a required check name. shell-harnesses.yml is"
echo "              paths-filtered, so the pds-harnesses context is ABSENT on a PR that"
echo "              touches none of those paths — an absent required context reports"
echo "              'expected' forever — and required-checks.json carries it as an"
echo "              S4 PATHS-FILTERED exclusion. It structurally cannot be required."

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
  # A DYNAMIC regex built from the named shapes above, not a literal, so this
  # lens cannot drift away from the ones the axes resolve with. `\\*` inside a
  # STRING regex is the escaped asterisk awk's regex compiler sees as `\*`.
  awk -v pfx="$D_PREFIX" -v num="$D_NUM_RE" '
    match($0, "^[ \t]*([-*][ \t]+)?\\*\\*" pfx num " —") ||
    match($0, "^#+[ \t]+" pfx num " —") {
      if (match($0, pfx num)) print substr($0, RSTART, RLENGTH), NR
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
  grep -oE "${D_PREFIX}${D_NAIVE_NUM_RE} —" "$CHARTER" | sed 's/ —$//' | sort | uniq -c \
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
    # THE EXEMPLAR'S LINES ARE READ OFF THIS RUN, NOT TYPED. This sentence used
    # to pin "D664 :2654 … :13311" in its own literal text, which is the very
    # cite-by-line the baseline above refutes in the next breath: at the time of
    # writing D664 sat at :2789/:13485 and the printed pair had been wrong for
    # several waves, inside the paragraph explaining why lines must never be
    # pinned. Re-derive it from $dups or do not print it.
    local ex_num ex_lines
    read -r ex_num ex_lines <<EOF
$(awk -v g="$DUP_BASELINE_GENUINE" 'BEGIN{split(g,a," ");for(i in a)w["PDS-D" a[i]]=1} w[$1]{ n=$1; $1=""; $2=""; sub(/^  */,""); print n, $0; exit }' "$dups")
EOF
    echo "  MECHANISM: a duplicate is not bad luck. Every genuine pair is ONE occurrence"
    echo "             in a wave's REVIEW block and ONE in the NEXT wave's DECIDE block."
    [ -n "${ex_num:-}" ] && echo "             This run's exemplar, lines read off THIS charter: ${ex_num} ${ex_lines}."
    echo "             D553–D556 are w38 REVIEW vs WAVE 39 DECIDE; D570–D573 are w39"
    echo "             REVIEW vs WAVE 40 DECIDE. The reviewer and the decider allocate from"
    echo "             ONE next-number pointer, so it recurs EVERY wave — unless the number"
    echo "             is minted through the arbiter: \`--allocate-d N\` reserves before the"
    echo "             charter is written, so the next caller cannot re-mint it."
  fi

  if [ "$unexpected" -gt 0 ] || [ "$vanished" -gt 0 ] || [ "$misclass" -gt 0 ]; then
    echo "  DIVERGENT: ${unexpected} unbaselined duplicate(s), ${vanished} stale baseline entrie(s), ${misclass} baseline miscount(s)."
    echo "             The baseline is two-sided on purpose — it must keep descending from"
    echo "             a measurement of the charter as it is, not as it was."
    raise 1
  fi
  return 0
}

# ══ THE SYNTHETIC FIXTURE ROSTER — ONE DECLARATION, BOTH AXES READ IT ═════════
#
# This harness family mints D-numbers that no charter will ever define: prose
# examples in this script's own header, and phantoms the selftest PLANTS to
# prove an axis can fire. Two axes meet them in two different corpora, so the
# skip has to be declared once and DERIVED, never copied — a copy is a second
# thing to forget, and forgetting it is what put this block here. The incident:
# the squash commit of the PR that ADDED axis D described its own fixtures in
# its commit message, and axis A — whose corpus is `git log --format=%B` — read
# that sentence as a claim on an authority and reddened main. The guard's own
# commit message tripped its sibling axis.
#
# Each entry is `<number>:<axes that SKIP it>`:
#
#   :ad — a synthetic this harness DOCUMENTS in its own prose. Axis A skips it
#         (a sentence ABOUT a fixture is not a claim on an authority) and axis D
#         skips it (this subject script writes the three of them out in the
#         header above, and a guard that reds on its own documentation is a
#         guard nobody keeps). These are the same three the DEFINITION lens is
#         written strictly to refuse minting from — see charter_defined_numbers.
#
#   :a  — axis A skips it; axis D MUST NOT. This is the selftest's PHANTOM: the
#         number it plants in a subject script so `--axis d` reds by name. Put
#         it in the :ad set and that proof goes vacuous — the arm would skip the
#         very citation the assertion is waiting for. So it is skipped exactly
#         where it is only ever PROSE (a commit message) and left live exactly
#         where it is a planted CITATION (a file).
#
# WHAT THIS DELIBERATELY DOES NOT DO: it does not widen a grace window and it
# names no commit. A commit message citing an undefined number that is NOT on
# this roster still reds axis A — that is the whole of the axis, and the
# selftest pins both directions.
#
# (Written WITHOUT the `PDS-` prefix on purpose: axis D scans THIS file, and a
# prefixed literal here would be a citation of a number nothing defines.)
PDS_SYNTHETIC_FIXTURES="777:ad 999:ad 1000:ad 9999:a"

# pds_synthetic_numbers <a|d> — the numbers the named axis skips, space-separated.
# Both axes derive from the one declaration above; neither keeps a list.
pds_synthetic_numbers() {
  local axis="$1" entry out=""
  for entry in $PDS_SYNTHETIC_FIXTURES; do
    case "${entry#*:}" in
      *"$axis"*) out="${out:+$out }${entry%%:*}" ;;
    esac
  done
  printf '%s' "$out"
}

if [ -n "$PRINT_SYNTHETIC" ]; then
  case "$PRINT_SYNTHETIC" in a|d) : ;; *) echo "pds-record-parity: --print-synthetic must be a or d, got '${PRINT_SYNTHETIC}'" >&2; usage ;; esac
  pds_synthetic_numbers "$PRINT_SYNTHETIC"; echo
  exit 0
fi


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
    grep -oE "^#+[[:space:]].*${D_PREFIX}${D_NUM_RE}" "$CHARTER" | grep -oE "${D_PREFIX}${D_NUM_RE}" | sort -u > "$defs"
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
      grep -oE "^[[:space:]]*([-*][[:space:]]+)?\*\*${D_PREFIX}${D_NUM_RE}" "$CHARTER"
      grep -oE "^#+[[:space:]]+${D_PREFIX}${D_NUM_RE}([[:space:]]|$)" "$CHARTER" # revert-marker: heading-arm
    } | grep -oE "${D_PREFIX}${D_NUM_RE}" | sort -u > "$defs"
  fi

  if [ -n "$COMMITS_FILE" ]; then
    [ -f "$COMMITS_FILE" ] || { echo "  UNCHECKED: --commits-file ${COMMITS_FILE} not found" >&2; raise 2; return 0; }
    grep -oE "${D_PREFIX}${D_NUM_RE}" "$COMMITS_FILE" | sort -u > "$cites"
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
      seen_cites="$(git log --format=%B 2>/dev/null | grep -oE "${D_PREFIX}${D_NUM_RE}" | sort -u | wc -l | tr -d ' ')"
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

    git log --format=%B | grep -oE "${D_PREFIX}${D_NUM_RE}" | sort -u > "$cites"
  fi

  # THE ROSTER, OUT OF THE CORPUS — the same declaration axis D reads, taken at
  # this axis's scope. A commit message that DISCUSSES a synthetic fixture is
  # prose about the harness, not a claim on an authority, and axis A reading it
  # as one is how this arm reddened its own main. Counted and PRINTED, so the
  # skip is visible in the run rather than hidden in a lens. Nothing else is
  # removed: an undefined number that is not on the roster still reds below.
  local a_sent_nums a_sent_re a_sent_skipped
  a_sent_nums="$(pds_synthetic_numbers a)"
  a_sent_re="$(printf '%s' "$a_sent_nums" | tr ' ' '|')"
  a_sent_skipped="$(grep -cE "^PDS-D(${a_sent_re})\$" "$cites" || true)"
  grep -vE "^PDS-D(${a_sent_re})\$" "$cites" > "$WORKDIR/a_cites_real" || true
  mv -f "$WORKDIR/a_cites_real" "$cites"

  comm -23 "$cites" "$defs" > "$unresolved"

  # THE CLAUSE LENS, ON THIS AXIS TOO. A commit message cites clause (a) of a
  # ruling as PDS-D220a exactly as a script does, so the two axes must resolve
  # the same shape the same way — an axis that reds on what its sibling greens
  # is a lens artifact wearing a finding's clothes. Same rule, not a softer one:
  # the base's definition BLOCK must carry the literal (x) marker, so a letter
  # that is a typo still reds here. COUNTED and PRINTED below.
  local a_clause=0
  if [ -s "$unresolved" ]; then
    : > "$WORKDIR/a_unres_real"
    while IFS= read -r cited; do
      [ -n "$cited" ] || continue
      if charter_clause_defined "${cited#"$D_PREFIX"}"; then
        a_clause=$((a_clause + 1)); continue
      fi
      printf '%s\n' "$cited" >> "$WORKDIR/a_unres_real"
    done < "$unresolved"
    mv -f "$WORKDIR/a_unres_real" "$unresolved"
  fi

  local n_def n_cite n_unres
  n_def="$(wc -l < "$defs" | tr -d ' ')"
  n_cite="$(wc -l < "$cites" | tr -d ' ')"
  n_unres="$(wc -l < "$unresolved" | tr -d ' ')"

  echo "  lens:       ${lens}"
  echo "  charter:    ${CHARTER}"
  echo "  defined:    ${n_def} distinct PDS-D"
  echo "  cited:      ${n_cite} distinct PDS-D across the commit corpus"
  echo "  fixtures:   ${a_sent_skipped} dropped before resolving, off a roster of $(printf '%s' "$a_sent_nums" | wc -w | tr -d ' ') (PDS-D$(printf '%s' "$a_sent_nums" | sed 's/ /, PDS-D/g'))"
  echo "  clauses:    ${a_clause} lettered citation(s) resolved as a CLAUSE of their base"
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


# ══ AXIS D — a PDS-* SCRIPT may not cite an authority that does not exist ═════
#
# WHY THIS IS A SEPARATE AXIS AND NOT A WIDER AXIS A. Axis A's corpus is the
# COMMIT MESSAGE. A commit message is written once and never rebased; a comment
# in a script is carried forward, copied, and — this is the whole defect —
# survives a charter RENUMBER unchanged. Measured 2026-09-13 on origin/main
# (4ecd652ee): 663 PDS-D occurrences across 33 `scripts/pds-*.sh` and 23 more
# across `tooling/pds/**`, and NOT ONE of them is read by any gate in the repo.
#   * axis A never sees them — it reads `git log --format=%B`, nothing else.
#   * scripts/charter-citation-check.sh never sees them either, and says so in
#     its own grammar section: its anchor is the WORD `charter` followed by a
#     bare `D<n>`, and "Prefixed forms (`PDS-D155`, …) never carry the `charter`
#     anchor and are outside the grammar entirely."
# So the prefixed citation — the ONLY form the PDS surfaces actually use — sat
# in the gap between the two checks that look like they cover it.
#
# THE OBSERVED FAILURE. A charter PR's decision block is renumbered on rebase
# (main took D719 while #17937 was in flight, so its D719–D739 block became
# D720–D740). Every script comment citing the pre-rebase number now points at a
# DIFFERENT ruling, or at one that does not exist. Both happened in one week on
# scripts/pds-secret-scan.sh: D736 (stale by one) and, earlier, D532 — a wholly
# unrelated ruling ("THE REGISTER SURVIVES ITS OWN WAVE"). Nothing red.
#
# (The two numbers above are written WITHOUT the `PDS-` prefix on purpose. This
# axis scans this file, a prefixed literal here would be a citation, and a guard
# that reds on its own account of the defect it guards is a guard nobody keeps.)
#
# WHAT THIS AXIS CAN AND CANNOT SEE — stated so a green is not over-read.
# It is an EXISTENCE check, not a semantic one. It catches the citation that
# resolves to NOTHING, which is the whole of the D736 case while the charter
# tops out below 736, and it is structurally blind to the D532 case, where the
# number exists and names something unrelated. Judging "does this ruling's title
# have anything to do with this sentence?" is not mechanisable here, so it is
# not claimed. A hand sample of 20 citations on 4ecd652ee found 0 mis-pointed
# by title and 2 that are not citations at all (a grammar EXAMPLE in this
# script's own header, a fixture string in its selftest) — both resolve, neither
# asserts an authority. The axis therefore reds on existence alone.
#
# THE SENTINELS are declared ONCE, above axis A, in PDS_SYNTHETIC_FIXTURES, and
# this axis reads its share of them through `pds_synthetic_numbers d`. They are
# excluded BY NUMBER and the count of skipped occurrences is PRINTED, so the
# exclusion is visible in the run rather than hidden in a lens.
#
# THE TEST HARNESSES ARE OUT OF SCOPE, AND THIS IS THE ONE NARROWING.
# `scripts/pds-*.test.sh` and `scripts/pds-*_test.sh` PLANT undefined D-numbers
# on purpose — that is what a mutation fixture IS — and no property of the text
# distinguishes a planted phantom from a stale citation. Keeping them in scope
# would make this axis red on its own fixtures, and a guard that reds on its own
# fixtures gets deleted rather than repaired. The cost is stated rather than
# hidden: prose citations inside a `pds-*` harness are NOT checked by this axis.
# It is the SUBJECT scripts — the ones that carry a ruling forward across a
# rebase — that the renumber defect actually lives in.
axis_d_is_harness() { # axis_d_is_harness <path>
  case "${1##*/}" in
    pds-*.test.sh|pds-*_test.sh) return 0 ;;
    *) return 1 ;;
  esac
}
#
# THE BASELINE ALLOWLIST — `path:line:number`, one per line, each dated with the
# ruling or rebase that stranded it. IT SHRINKS AND NEVER GROWS: an entry is a
# citation somebody still has to repair, not a dispensation to write another.
# Adding a line here is the wrong repair for a new red — the right one is to fix
# the citation. The count is printed on every run so an allowlist that stopped
# shrinking is visible.
#
# THE NUMBER IS BARE — `scripts/pds-foo.sh:12:736`, never the prefixed form. The
# prefixed form would make this very file cite the undefined number it is
# excusing, and the axis would then red on its own baseline — proven by a
# planted entry before the format was fixed. A baseline that cannot be written
# without tripping the check it feeds is not a baseline.
#
# MEASURED 2026-09-13 at 4ecd652ee: EMPTY. Every one of the 686 citations in the
# corpus resolves once the three sentinels are excluded, so this guard lands on
# a clean main and its first red will be a real one.
AXIS_D_ALLOWLIST=""

# The corpus root, overridable so the selftest can point the axis at a fixture
# tree instead of the live checkout.
axis_d_corpus_files() { # axis_d_corpus_files <root>
  local root="$1"
  if [ -d "$root/scripts" ]; then
    find "$root/scripts" -maxdepth 1 -type f -name 'pds-*.sh' | while IFS= read -r f; do
      axis_d_is_harness "$f" || printf '%s\n' "$f"
    done
  fi
  [ -d "$root/tooling/pds" ] && find "$root/tooling/pds" -type f
  return 0
}

axis_d() {
  echo
  echo "AXIS D — PDS-D numbers cited by the PDS SCRIPTS must resolve in the charter"
  echo "  scope:      scripts/pds-*.sh + tooling/pds/** under ${CITATION_ROOT}"
  echo "              (pds-*.test.sh / pds-*_test.sh EXCLUDED — they plant phantoms)"
  echo "  NOTE: EXISTENCE only. A citation that is STALE BY ONE onto a number that"
  echo "        happens to exist resolves here and is NOT caught. See the header."

  if [ ! -f "$CHARTER" ]; then
    echo "  UNCHECKED: charter not found at ${CHARTER} — the axis cannot resolve a single citation" >&2
    raise 2; return 0
  fi

  local defs="$WORKDIR/d_defs" cites="$WORKDIR/d_cites" files="$WORKDIR/d_files"
  local unres="$WORKDIR/d_unres" allow="$WORKDIR/d_allow" fired="$WORKDIR/d_fired"

  charter_defined_numbers > "$defs" || { echo "  UNCHECKED: the definition lens read nothing" >&2; raise 2; return 0; }
  if [ ! -s "$defs" ]; then
    echo "  UNCHECKED: ${CHARTER} defines no PDS-D at all — the lens is measuring itself" >&2
    raise 2; return 0
  fi

  axis_d_corpus_files "$CITATION_ROOT" | sort > "$files"
  if [ ! -s "$files" ]; then
    echo "  UNCHECKED: the scope matched no file under ${CITATION_ROOT} — a verdict over a" >&2
    echo "             corpus that was never read is not a pass." >&2
    raise 2; return 0
  fi

  # file:line:PDS-Dn, one per occurrence. `-I` drops binaries; the corpus is
  # text today and a future .png in tooling/pds must not make the axis UNCHECKED.
  #
  # THE PRODUCER SURFACES ITS OWN REFUSAL. grep rc 1 means "this file cites no
  # PDS-D" — normal, and true of most of the corpus, so it must never red. rc >= 2
  # is grep REFUSING (unreadable file, a corpus root that moved under the scan):
  # it contributes no lines, and left silent it shows up only as a short — or
  # zero — citation count, which the reader below then reports as its OWN "ZERO
  # citations" complaint. The refusal is named HERE, by file, carrying grep's own
  # stderr, before any consumer can mistake it for a clean answer. Teaching that
  # consumer to tolerate a short corpus instead would turn a detectable refusal
  # into a silent zero: the same defect, one layer deeper, on the arbiter.
  : > "$cites"
  local f_err="$WORKDIR/d_grep_err" f_refused="$WORKDIR/d_refused" grc=0
  : > "$f_refused"
  while IFS= read -r f; do
    grep -I -noE "${D_PREFIX}${D_NUM_RE}" "$f" 2>"$f_err" | sed "s|^|${f#"$CITATION_ROOT"/}:|" >> "$cites"
    grc="${PIPESTATUS[0]}"
    [ "$grc" -le 1 ] && continue
    printf '%s (grep rc=%s) %s\n' "${f#"$CITATION_ROOT"/}" "$grc" "$(tr '\n' ' ' < "$f_err")" >> "$f_refused"
  done < "$files"

  if [ -s "$f_refused" ]; then
    echo "  UNCHECKED: the citation scan REFUSED on $(wc -l < "$f_refused" | tr -d ' ') file(s)." >&2
    echo "             grep exited >=2 on them, so their citations are ABSENT from the" >&2
    echo "             corpus and every count below would be short. This is the" >&2
    echo "             PRODUCER refusal, named before the reader can report it as" >&2
    echo "             its own empty-artifact complaint:" >&2
    sed 's/^/               /' "$f_refused" >&2
    raise 2; return 0
  fi

  local n_files n_occ n_distinct
  n_files="$(wc -l < "$files" | tr -d ' ')"
  n_occ="$(wc -l < "$cites" | tr -d ' ')"
  n_distinct="$(sed -E "s/.*:(${D_PREFIX}${D_NUM_RE})\$/\1/" "$cites" | sort -u | wc -l | tr -d ' ')"

  if [ "$n_occ" -eq 0 ]; then
    echo "  UNCHECKED: ${n_files} file(s) in scope and ZERO citations in any of them." >&2
    echo "             The PDS scripts cite the charter constantly; zero means the scan" >&2
    echo "             broke, not that the corpus is clean." >&2
    raise 2; return 0
  fi

  # Sentinels out, by number, counted. DERIVED from the one roster, never copied.
  local sent_nums sent_re sent_skipped
  sent_nums="$(pds_synthetic_numbers d)"
  sent_re="$(printf '%s' "$sent_nums" | tr ' ' '|')"
  sent_skipped="$(grep -cE ":PDS-D(${sent_re})\$" "$cites" || true)"
  grep -vE ":PDS-D(${sent_re})\$" "$cites" > "$WORKDIR/d_cites_real" || true

  # NORMALISED to `path:line:number` — the bare number, so the allowlist below
  # can name an entry without itself becoming a citation of it.
  sed -E "s/:${D_PREFIX}(${D_NUM_RE})\$/:\1/" "$WORKDIR/d_cites_real" > "$WORKDIR/d_cites_norm"

  # Undefined = the number is not in the definition lens's output.
  : > "$unres"
  local n_clause=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local num="${line##*:}"
    grep -qx "$num" "$defs" && continue
    # A clause reference resolves against the base's definition BLOCK, never
    # against the base's mere existence. COUNTED and PRINTED below, because a
    # resolution path nobody can see in the run is the next silent merge.
    if charter_clause_defined "$num"; then n_clause=$((n_clause + 1)); continue; fi
    printf '%s\n' "$line" >> "$unres"
  done < "$WORKDIR/d_cites_norm"

  printf '%s\n' "$AXIS_D_ALLOWLIST" | sed '/^[[:space:]]*$/d' | sort -u > "$allow"

  echo "  charter:    ${CHARTER}"
  echo "  files:      ${n_files} in scope"
  echo "  citations:  ${n_occ} occurrence(s), ${n_distinct} distinct PDS-D"
  echo "  sentinels:  ${sent_skipped} occurrence(s) skipped (PDS-D$(printf '%s' "$sent_nums" | sed 's/ /, PDS-D/g'))"
  echo "  defined:    $(wc -l < "$defs" | tr -d ' ') distinct PDS-D in the charter"
  echo "  allowlist:  $(wc -l < "$allow" | tr -d ' ') entry(ies) — shrinks, never grows"
  echo "  clauses:    ${n_clause} lettered citation(s) resolved as a CLAUSE of their base"
  echo "              (the base's definition block carries the literal (x) marker;"
  echo "               a letter whose base has no such marker still reds — that is"
  echo "               the lettered-typo arm this axis was widened to get back)"

  : > "$fired"
  local n_allowed=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if grep -qxF "$line" "$allow"; then
      n_allowed=$((n_allowed + 1))
      echo "    ALLOWLISTED-CITATION ${line} (PDS-D${line##*:}) — baselined, still unrepaired"
      continue
    fi
    printf '%s\n' "$line" >> "$fired"
  done < "$unres"

  if [ -s "$fired" ]; then
    while IFS= read -r line; do
      local num="${line##*:}" below above near=""
      # BASE-AWARE. `$1 < n` alone compares "1000" against "448a" as STRINGS the
      # moment a letter enters the set, and prints a nearest number that is not
      # near anything. The base orders; the whole id breaks the tie.
      below="$(awk -v n="$num" 'function b(x){sub(/[a-z]+$/,"",x); return x+0}
               b($1) < b(n) || (b($1) == b(n) && $1 < n) {v=$1} END {print v}' "$defs")"
      above="$(awk -v n="$num" 'function b(x){sub(/[a-z]+$/,"",x); return x+0}
               b($1) > b(n) || (b($1) == b(n) && $1 > n) {print $1; exit}' "$defs")"
      [ -n "$below" ] && near="PDS-D${below}"
      [ -n "$above" ] && near="${near:+${near}, }PDS-D${above}"
      echo "    UNDEFINED-CITATION   ${line%:*} cites PDS-D${num}"
      echo "                         nearest defined: ${near:-<none>}"
      echo "                         (the charter defines neither this number nor anything"
      echo "                          claiming it — repair the citation, do not allowlist it)"
    done < "$fired"
    raise 1
  fi

  # THE MIRROR. An allowlist entry that no longer names an undefined citation is
  # a repair nobody deleted the baseline for, and a baseline that only ever grows
  # is the thing this axis exists to refuse.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF "$line" "$unres" || {
      echo "    STALE-ALLOWLIST      ${line} — no longer an undefined citation; delete this entry"
      raise 1
    }
  done < "$allow"

  echo "  undefined:  $(wc -l < "$fired" | tr -d ' ') firing, ${n_allowed} allowlisted"
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

  # MATERIALISED, NOT PIPED, AND FOR ONE REASON: the count printed here is the
  # SAME list the sweep below reads on fd 0. A `cut | sort -u` in the header and
  # a second one in the loop's redirect are two enumerations that a reader is
  # invited to assume are one; writing it once makes `n_ids` the denominator of
  # the count identity after the loop instead of a coincidentally equal number.
  # `awk 'NF'`, not `wc -l`: it counts NON-BLANK lines, which is exactly what the
  # loop counts (its first statement skips a blank id), so the two sides of the
  # identity are the same population by construction.
  local n_ids uids="$WORKDIR/axis-b-uids"
  cut -f1 "$ids" | sort -u > "$uids"
  n_ids="$(awk 'NF { n++ } END { print n+0 }' "$uids")"
  echo "  extractor:  ${EXTRACTOR} --extract-task-id  (absence = EMPTY STDOUT, never \$?)"
  echo "  task ids:   ${n_ids} distinct across ${i} PRs"
  echo "  no trailer: ${no_trailer} PRs carry no Task: trailer (advisory — predates the gate)"
  echo "  declared none: ${declared_none} PRs declare a SENTINEL id (Task: n/a and friends) — the same"
  echo "                 fact as no trailer, said out loud (advisory, never a ghost-task red)"

  # ── ledger sweep, serial and paced ────────────────────────────────────────
  local now grace_secs
  now="$(now_epoch)"
  grace_secs=$(( GRACE_HOURS * 3600 ))

  # THE REDDING TALLY IS TWO CLASSES, NOT ONE. `n_leaf` used to be a single
  # counter bumped from BOTH the 404 branch and the DIVERGENT branch, printed
  # under one label — "LEAF slices (REDDING)" — that names only the second.
  # It read clean only while not-found was 0; the day an id is renamed the
  # headline grows for a reason its own sentence denies, and the reader cannot
  # tell which half moved. Count them separately and print the composition.
  local n_terminal=0 n_open=0 n_notfound=0 n_unchecked=0 n_grace=0 n_root=0
  local n_leaf_open=0 n_leaf_ghost=0
  local tid latest prlist lifecycle parent has_result age
  # `n_swept` COUNTS ITERATIONS. It is not a tally of any disposition — every
  # `continue` arm below has already been counted by the time it fires, because
  # an id that was HANDED to the loop was swept whichever branch disposed of it.
  # The identity after the loop is therefore exactly "iterations == lines handed".
  local n_swept=0
  # `|| [ -n "$tid" ]` — `sort -u` always terminates its last line, so this can
  # not fire today; it is here so the identity below can never refuse a COMPLETE
  # list as short if this redirect is ever pointed at a file that lacks one.
  while read -r tid || [ -n "$tid" ]; do
    [ -n "$tid" ] || continue
    n_swept=$((n_swept + 1))
    # The marker below is a NO-OP on every real run. It exists so the control
    # arm in scripts/pds-record-parity.test.sh can splice a stdin-draining child
    # into this loop body at a unique, greppable point and prove the identity
    # above actually fires — a guard nothing has ever been seen to trip is a
    # guard nobody can tell from a comment.
    : # MUT-BODY: axis-b-loop-body
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
        printf '%s\t%s\t%s\n' "(no ledger row)" "$tid" "$prlist" >> "$leaves"
        n_notfound=$((n_notfound + 1)); n_leaf_ghost=$((n_leaf_ghost + 1)); raise 1
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
    printf '%s\t%s\t%s\n' "$parent" "$tid" "$prlist" >> "$leaves"
    n_leaf_open=$((n_leaf_open + 1)); raise 1
  done < "$uids"

  # ── THE COUNT IDENTITY ─────────────────────────────────────────────────────
  # WHY IT EXISTS (task-d5485c04e0e63488). The sweep above reads the unique task
  # id list on fd 0 and runs children in its body. Any body child that reads
  # stdin — a future `gh` without `</dev/null`, a `psql`, an `ssh` into the box —
  # swallows the remaining ids and the loop ENDS EARLY with no error and no
  # non-zero status. Every tally below is then SMALLER and the divergent set is
  # EMPTY, so a sweep of 1 id in 200 prints a GREEN AXIS B in the same words as a
  # real one. The failure direction is silence, which is the direction a parity
  # check cannot afford: the rows that would have redded it were never fetched.
  #
  # No `-eq 0` floor can see that — zero separates "nothing" from "something",
  # never "some" from "all". Only the identity can, and it names BOTH numbers so
  # a reader can see how much of the window was actually examined.
  # MUT-ANCHOR: axis-b-count-identity
  if [ "$n_swept" -ne "$n_ids" ]; then
    echo "  UNCHECKED: axis B swept ${n_swept} of ${n_ids} task id(s) the enumeration handed it." >&2
    echo "             The sweep loop ended before its id list did (a loop-body child that reads" >&2
    echo "             stdin consumes the remaining ids silently). A partial sweep must never" >&2
    echo "             print this axis's tally in the same words as a complete one, so the tally" >&2
    echo "             is WITHHELD: the numbers it would print are true of a corpus nobody chose." >&2
    raise 2
    return 0
  fi
  # MUT-END: axis-b-count-identity

  local n_divergent=$(( n_open + n_notfound ))
  local n_leaf=$(( n_leaf_open + n_leaf_ghost ))
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
  echo "         of which merged over an OPEN row:    ${n_leaf_open}"
  echo "         of which merged over a MISSING id:   ${n_leaf_ghost}"

  # ── THE PER-OWNER REPORT — THE ONLY DISPOSAL SHAPE THIS RED HAS ────────────
  # A red here is almost never PDS's. At wave 39 the population was 61 leaf
  # reds and 93.4% of them belonged to ELEVEN OTHER EPICS; PDS owned 6.6%.
  # A sweep that prints one flat list hands every owner somebody else's work
  # and is ignored by all of them, which is how a standing red becomes
  # furniture. So the arm groups by THE ROWS' OWN parent_id and prints one
  # block per owner — the disposal shape pds-w38-ledger-hygiene-derived used
  # to close nine rows on derived numbers.
  #
  # BY parent_id, NEVER BY SLUG PREFIX. At wave 39 three of the 61 carried
  # opaque `task-…` ids that no prefix lens can group at all, and a prefix is
  # a naming convention (a thing authors drift from) where parent_id is the
  # ledger's own answer to "whose row is this?".
  #
  # AND IT IS COMPUTED, NEVER TRANSCRIBED. The wave-39 table of 61 was a
  # SNAPSHOT of a window, and `--limit N` is a COUNT bound wearing a TIME
  # bound's clothes (ruling 3): as the merge rate rose, 400 PRs stopped
  # reaching wave 39 at all. A frozen table decays into a claim about a
  # corpus nobody is looking at any more; a rule re-derives at whatever
  # window you hand it. This is the rule.
  if [ "$n_leaf" -gt 0 ]; then
    echo
    echo "  PER-OWNER REPORT — ${n_leaf} leaf red(s), grouped by the rows' own parent_id"
    echo "    (a REPORT, never a gate: most of these belong to epics that never"
    echo "     consented to this instrument. Hand each owner their own block.)"
    # THE SAME FD-0 EXPOSURE, ONE LOOP LATER. The reconciliation below compares
    # `wc -l "$leaves"` to the tally — two numbers computed OUTSIDE this loop, so
    # neither moves when the loop itself ends early. A body child that drained fd 0
    # would print one OWNER block, report `owners: 1`, and still pass the coverage
    # check word for word. So this loop gets its own identity against its own
    # materialised list.
    local owners_list="$WORKDIR/axis-b-owners"
    cut -f1 "$leaves" | sort | uniq -c | sort -rn | awk '{ $1=""; sub(/^ /,""); print }' > "$owners_list"
    local n_owners_enum
    n_owners_enum="$(awk 'NF { n++ } END { print n+0 }' "$owners_list")"
    local owner n_owners=0 owner_rows
    while read -r owner || [ -n "$owner" ]; do
      [ -n "$owner" ] || continue
      n_owners=$((n_owners + 1))
      # A NO-OP on every real run; the control arm splices a stdin-draining
      # child here. See the note on the sweep loop's marker above.
      : # MUT-BODY: axis-b-owner-body
      owner_rows="$(awk -F'\t' -v o="$owner" '$1==o' "$leaves" | wc -l | tr -d ' ')"
      echo "    OWNER ${owner}  —  ${owner_rows} leaf red(s)"
      awk -F'\t' -v o="$owner" '$1==o { printf "      %s  %s\n", $2, $3 }' "$leaves"
    done < "$owners_list"
    # MUT-ANCHOR: axis-b-owner-identity
    if [ "$n_owners" -ne "$n_owners_enum" ]; then
      echo "  UNCHECKED: the per-owner report printed ${n_owners} of ${n_owners_enum} owner block(s)." >&2
      echo "             The grouping loop ended before its owner list did; the blocks above are a" >&2
      echo "             PREFIX of the report, not the report." >&2
      raise 2
      return 0
    fi
    # MUT-END: axis-b-owner-identity
    # THE HEADLINE MUST EQUAL WHAT IS UNDER IT. A per-owner block that prints
    # fewer rows than the tally counted is the shape where a reader trusts a
    # number nothing under it descends from, so the two are reconciled out loud
    # and a disagreement is UNCHECKED — the arm can no longer say what it saw.
    local n_grouped
    n_grouped="$(wc -l < "$leaves" | tr -d ' ')"
    echo "    owners:     ${n_owners}  covering ${n_grouped} of ${n_leaf} leaf red(s)"
    if [ "$n_grouped" -ne "$n_leaf" ]; then
      echo "  UNCHECKED: the per-owner blocks cover ${n_grouped} rows but the tally counted ${n_leaf}." >&2
      echo "             The report and the headline stopped descending from one measurement." >&2
      raise 2
    fi
  fi
  return 0
}

# ── AXIS F — THE HARNESS THAW LEDGER (PDS-D759) ───────────────────────────────
#
# THE LAW, POINTED AT THE FREEZE. Axis A rules that a commit may not cite an
# authority that does not exist. Axis F is its mirror image: a commit may not
# MOVE the frozen harness without leaving an authority behind. Every commit that
# changes `scripts/pds-pull-proof.sh` is a THAW, sanctioned or not, and the
# charter must be able to answer, after the fact, "which PDS-D records this
# thaw, and what post-merge blob OID did it produce?".
#
# THE JOIN KEY IS THE POST-MERGE BLOB OID AND NOTHING ELSE. It is read with
# `git rev-parse <sha>:scripts/pds-pull-proof.sh` and NEVER with `shasum`
# (PDS-D154). A PR number was measured as a join key and REJECTED: the charter
# cites PR numbers for a dozen reasons that have nothing to do with a freeze,
# so a PR-number join resolves commits the charter never recorded as thaws
# (measured on origin/main: PR-number join 9/25, blob join 3/25 — the extra six
# were all coincidental mentions). A 40-hex blob OID in this charter can only
# ever have got there as a freeze record.
#
# HOW THIS DOES NOT REOPEN PDS-D732. D732 rules the freeze identity is READ,
# never TYPED, because a hand-typed hash manufactures a false THAWED verdict the
# day a sanctioned thaw lands. A recorded OID here is `FREEZE_BLOB_HISTORICAL`
# in D732's own taxonomy — a HISTORICAL record OF ONE THAW, never a statement of
# the current freeze, which stays DERIVED at run time by
# `scripts/pds-climb-preflight.sh:128`. This arm reads the charter's OIDs as a
# LEDGER OF THE PAST and never compares any of them to origin/main's live blob;
# that comparison is the preflight's job and this arm does not do it.
#
# THE WINDOW BOUNDARY IS A FLOOR THAT ONLY RATCHETS BACK — IT IS NOT READ OUT OF
# THE LEDGER THIS ARM GUARDS. The first cut derived the boundary entirely from the
# charter: the anchor was the OLDEST harness-moving commit whose blob the charter
# recorded, and everything older was EXEMPT. That is a guard whose expected value
# is read from the thing it guards, and it is inert against exactly one edit —
# DELETING THE OLDEST LEDGER ROW. The deleted commit did not become unrecorded; it
# became the new anchor's elder and therefore EXEMPT, the window shrank by one to
# match, and the arm printed PARITY rc 0. Measured: deleting `e219e97cc…` took the
# window 20 -> 19 and stayed green; deleting the four oldest rows in one pass took
# it 20 -> 16 and stayed green. Induction erases the ledger from the bottom, one
# row per commit, with the arm green at every step. The realistic adversary is not
# a malicious deletion but a charter SPLIT or REWRITE that drops the oldest rows
# as historical noise — and that edit landed green.
#
# SO THE BOUNDARY IS NOW THE OLDER OF TWO VALUES:
#
#   1. AXIS_F_FLOOR_COMMIT — a LITERAL 40-hex commit in THIS FILE. It is the last
#      harness edit before the freeze doctrine (#4686, 2026-07-20, "the last legal
#      harness edit before the freeze"), so every thaw of the doctrine era is at or
#      newer than it. A charter edit cannot move it: it does not live in the
#      charter, it lives in scripts/, which is a different file, a different fence
#      and a different review. Deleting every ledger row in the charter leaves this
#      value untouched and the window at its full 21 commits, so the deletion shows
#      up as N unrecorded rows and reds, naming each commit.
#
#   2. the oldest harness-moving commit the charter records, used ONLY when it is
#      strictly OLDER than the floor.
#
# Direction is the whole point. The charter can still move the boundary BACK —
# record an older thaw and the window widens by itself, which is the predicate
# property the first cut was built for and which an enumeration of exempt shas
# would have lost. It can never move it FORWARD. A ledger row is now a claim the
# arm checks, never an input to the question it asks.
#
# The exemption's mechanical test is unchanged and still printed, not implied:
# `git merge-base --is-ancestor <sha> <boundary>`.
#
# WHY A PINNED COMMIT AND NOT A MONOTONIC COUNT FLOOR. A count floor (the idiom in
# scripts/pds-charter-anchors-check.sh's DEF_FLOOR) needs raising on every thaw and
# reds in two directions; worse, it says a row went missing without saying WHICH.
# A pinned boundary needs no maintenance as thaws land — new thaws are newer than
# it by construction — and it names the exact commit whose record was dropped.
axis_f_harness_path() { printf '%s\n' "scripts/pds-pull-proof.sh"; }

# The last harness edit before the freeze doctrine: 1f15017bf, #4686, 2026-07-20.
# OVERRIDABLE FOR FIXTURES ONLY, and a non-default value is printed loudly — a
# fixture repo has no such commit, so a selftest must be able to say so.
AXIS_F_FLOOR_COMMIT_DEFAULT="1f15017bf3d51ac85c34d3e4f5aa2f903a0815a6"
AXIS_F_FLOOR_COMMIT="${AXIS_F_FLOOR_COMMIT:-$AXIS_F_FLOOR_COMMIT_DEFAULT}"

axis_f() {
  local hp charter anchor anchor_blob sha blob n_total n_window n_resolved n_unrec
  hp="$(axis_f_harness_path)"
  charter="$CHARTER"
  echo
  echo "axis F — THE HARNESS THAW LEDGER (does every thaw of ${hp} name a ${D_PREFIX}?)"

  if [ ! -f "$charter" ]; then
    echo "  UNCHECKED: no charter at ${charter}." >&2; raise 2; return 0
  fi
  if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    echo "  UNCHECKED: not a git checkout." >&2; raise 2; return 0
  fi

  local base="origin/main"
  git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || base="HEAD"

  local commits; commits="$(git log --format=%H "$base" -- "$hp")"
  if [ -z "$commits" ]; then
    echo "  UNCHECKED: no commit in this checkout has ever touched ${hp}." >&2; raise 2; return 0
  fi
  n_total="$(printf '%s\n' "$commits" | wc -l | tr -d ' ')"

  # THE CONTROL THAT MAKES AN EMPTY READ INADMISSIBLE. Before any per-commit
  # grep is believed, prove the grep can fire on this charter at all. A charter
  # that answers 0 to everything reads exactly like a perfectly-recorded one.
  local ctl; ctl="$(grep -c -- "${D_PREFIX}" "$charter" 2>/dev/null || true)"
  case "$ctl" in ''|0)
    echo "  UNCHECKED: the control grep for '${D_PREFIX}' found 0 hits in ${charter}." >&2
    echo "             Every per-commit 0 below would be an artifact of the lens." >&2
    raise 2; return 0 ;;
  esac
  echo "  control grep .......... ${ctl} '${D_PREFIX}' hit(s) in ${charter} — the lens fires"

  # THE PINNED FLOOR. A literal in this file, not a value read back out of the
  # charter — see the block above axis_f_harness_path() for why. Absent from this
  # checkout (a shallow clone, a fixture repo) the arm refuses to score rather
  # than falling back to the ledger it is guarding: a fallback would reinstate the
  # exact hole the floor exists to close, and would do it silently.
  local floor_sha
  floor_sha="$(git rev-parse --verify --quiet "${AXIS_F_FLOOR_COMMIT}^{commit}" 2>/dev/null || true)"
  if [ -z "$floor_sha" ]; then
    echo "  UNCHECKED: the pinned window floor ${AXIS_F_FLOOR_COMMIT} is not a commit in this" >&2
    echo "             checkout. The arm will NOT fall back to deriving the boundary from the" >&2
    echo "             charter — that is the defect this floor exists to close." >&2
    raise 2; return 0
  fi
  if ! git merge-base --is-ancestor "$floor_sha" "$base" 2>/dev/null; then
    echo "  UNCHECKED: the pinned window floor $(git rev-parse --short=9 "$floor_sha") is not an" >&2
    echo "             ancestor of ${base}; history has been rewritten under the floor." >&2
    raise 2; return 0
  fi
  if [ "$AXIS_F_FLOOR_COMMIT" != "$AXIS_F_FLOOR_COMMIT_DEFAULT" ]; then
    echo "  !! FLOOR OVERRIDDEN via AXIS_F_FLOOR_COMMIT — this is a FIXTURE run, not the real ledger."
  fi

  # THE LEDGER MAY ONLY WIDEN THE WINDOW. The oldest harness-moving commit the
  # charter records is consulted, but it replaces the floor ONLY when it is
  # strictly older. Deleting ledger rows moves this value FORWARD, which the
  # min() below discards — so a deletion can no longer shrink the window.
  anchor=""; anchor_blob=""
  while IFS= read -r sha; do
    blob="$(git rev-parse --verify --quiet "${sha}:${hp}" 2>/dev/null || true)"
    [ -n "$blob" ] || continue
    if grep -q -- "$blob" "$charter"; then anchor="$sha"; anchor_blob="$blob"; fi
  done <<< "$commits"

  local boundary="$floor_sha" boundary_src="pinned floor (a literal in $(basename "$0"), not in the charter)"
  if [ -n "$anchor" ] && [ "$anchor" != "$floor_sha" ] &&
     git merge-base --is-ancestor "$anchor" "$floor_sha" 2>/dev/null; then
    boundary="$anchor"
    boundary_src="charter-recorded thaw OLDER than the floor, blob ${anchor_blob} — the ledger widened the window"
  fi

  echo "  pinned window floor ... $(git rev-parse --short=9 "$floor_sha") (${AXIS_F_FLOOR_COMMIT})"
  if [ -n "$anchor" ]; then
    echo "  oldest ledger row ..... $(git rev-parse --short=9 "$anchor") (blob ${anchor_blob}) — may widen the window, never narrow it"
  else
    echo "  oldest ledger row ..... NONE — the charter records no harness blob at all; every in-window thaw below is unrecorded"
  fi
  echo "  window boundary ....... $(git rev-parse --short=9 "$boundary")  [${boundary_src}]"
  echo "  exemption test ........ git merge-base --is-ancestor <sha> $(git rev-parse --short=9 "$boundary")  → EXEMPT (pre-doctrine)"

  local unrec; unrec="$(mktemp)"
  n_window=0; n_resolved=0
  while IFS= read -r sha; do
    [ "$sha" = "$boundary" ] && continue
    git merge-base --is-ancestor "$sha" "$boundary" 2>/dev/null && continue   # out of window: EXEMPT
    blob="$(git rev-parse --verify --quiet "${sha}:${hp}" 2>/dev/null || true)"
    if [ -z "$blob" ]; then
      echo "  UNCHECKED: ${hp} has no blob at ${sha}; the walk cannot be scored." >&2
      raise 2; rm -f "$unrec"; return 0
    fi
    n_window=$((n_window + 1))
    if grep -q -- "$blob" "$charter"; then
      n_resolved=$((n_resolved + 1))
    else
      printf '%s\t%s\t%s\t%s\n' "$(git rev-parse --short=9 "$sha")" "$blob" \
        "$(git log -1 --format=%cs "$sha")" "$(git log -1 --format=%s "$sha" | cut -c1-72)" >> "$unrec"
    fi
  done <<< "$commits"

  n_unrec="$(wc -l < "$unrec" | tr -d ' ')"
  # TWO NUMBERS, NEVER ONE VERDICT.
  echo "  harness-moving commits, all history .... ${n_total}"
  echo "  harness-moving commits IN WINDOW ....... ${n_window}  (the boundary itself excluded; older ones EXEMPT)"
  echo "  ...of those, resolving to a ${D_PREFIX} record .. ${n_resolved}"
  echo "  ...unrecorded .......................... ${n_unrec}"

  if [ "$n_unrec" -gt 0 ]; then
    echo "  DIVERGENT — these thaws moved ${hp} and no ${D_PREFIX} records the blob they produced:" >&2
    while IFS=$'\t' read -r s b d t; do
      echo "    ${s}  ${d}  blob ${b}" >&2
      echo "        ${t}" >&2
    done < "$unrec"
    echo "    Record each under a ${D_PREFIX} minted through --allocate-d, as a HISTORICAL" >&2
    echo "    thaw record (PDS-D732: never as a statement of the current freeze)." >&2
    raise 1
  else
    echo "  PARITY — every in-window thaw names the ${D_PREFIX} that records its blob."
  fi
  rm -f "$unrec"
  return 0
}

case "$AXIS" in a|both) axis_a ;; esac
case "$AXIS" in b|both) axis_b ;; esac
case "$AXIS" in d|both) axis_d ;; esac
case "$AXIS" in f|both) axis_f ;; esac

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
