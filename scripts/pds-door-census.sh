#!/usr/bin/env bash
#
# pds-door-census.sh — the PDS price column, computed instead of written down.
#
# WHY THIS EXISTS (PDS-D637, D649, D650)
# --------------------------------------
# The epic has argued for four waves about a single fraction: how many of its
# own instruments actually run under a REQUIRED gate. Every answer so far has
# been prose in a charter — hand-copied, re-hand-copied, and stale by the time
# the next wave read it. PDS-D650 rules that the owning surface of this
# inventory is THIS SCRIPT'S PRINTED OUTPUT: the repo caps doc cards at 7, and
# `docs/decisions/success-claim-census.md` (canonical-for: success-claim-census)
# carries zero instrument inventory in 286 lines, so there is no doc to disagree
# with. This file creates the owner.
#
# THE TWO LEGS OF "THROUGH THE DOOR"
# ----------------------------------
# An instrument is THROUGH when BOTH legs hold:
#
#   LEG A — an ExUnit case under api/test EXECUTES it. Three predicates, all
#           required (PDS-D649):
#             (i)   the relative literal sits on a NON-COMMENT line;
#             (ii)  it is ATTRIBUTE-BOUND — `@x_rel "../…/<instrument>"` — the
#                   uniform shape of all real doors today;
#             (iii) that same attribute is dereferenced, in the SAME file, into
#                   a `System.cmd`/`Port.open` argument list.
#           "`System.cmd` appears somewhere in the file" is NOT predicate (iii).
#           A prototype that used the weaker form PASSED the fraud below.
#
#   LEG B — `.github/workflows/elixir.yml`'s dispatcher actually runs the suite
#           on a PR that touches the instrument. Evaluated BY EXECUTION —
#           the candidate path is piped into
#           `scripts/elixir-path-escape-check.sh --match test` and its verdict
#           is read. Never by substring-matching the declared set: that grammar
#           is deliberately tiny (a `dir/**` prefix or an exact path), and a
#           future `scripts/**` entry would silently turn EVERY row THROUGH.
#
# THE FRAUD THIS BLOCKS (PDS-D649, and the reason predicates (i) and (ii) exist)
# -----------------------------------------------------------------------------
# `elixir-path-escape-check.sh`'s extractor is a line-based grep and is
# COMMENT-BLIND. Editing a test file's COMMENT to name a real instrument makes
# the escape census emit it as a repo-root read, drives `--check` RED demanding
# the declaration, and — once the maintainer adds the declaration the ratchet
# itself forced — a naive classifier reports THROUGH for a script no test ever
# runs. `--selftest` reproduces that tree and asserts it stays out.
#
# LEG B's one non-redundant class is the DEAD DECLARATION (declared, executed by
# nothing). Leg A already IMPLIES leg B by ratchet — MUT-1 (leg A, no leg B) is
# already red on main via `elixir.yml`'s escape-check job — so an "agreement"
# check between the two legs is structurally unable to fire. This is not that.
#
# FAIL-CLOSED IS THE POINT, NOT A DEFECT TO SOFTEN
# ------------------------------------------------
# A `scripts/pds-*` program this census cannot dispose is UNDISPOSED and the run
# exits NON-ZERO. A test-side reference it cannot classify is an ERROR, never a
# silent "not gated". On day one that reds on most of the inventory. That is the
# honest denominator, printed, rather than a comfortable number in prose.
#
# THE PRICE UNIT (PDS-D648)
# -------------------------
# CPU = user + sys, LABELLED LOCAL, with the meter named. Never wall: a fixed
# workload's wall spanned 5.8x at essentially constant load on this host, so a
# wall second quotes the host's other tenants, not the door. Never user alone:
# on the hetzner door `sys` EXCEEDS `user`, so user-only understates by 2.1x as
# a pure CPU fact. No pds door has ever been measured on `ubuntu-latest`; every
# figure below is a loaded 10-core Apple-Silicon mac and is labelled LOCAL so
# the door's own first CI run can overwrite it.
#
# THE METER BLIND SPOT (PDS-D633 / D646) — printed by every run, see BLIND_SPOT.
#
# PREDICATE (iii) WAS PROXIMITY, NOT MEMBERSHIP (wave 45, PDS-D649)
# -----------------------------------------------------------------
# THE CLAIM, recorded here because a comment ships with the merge and a PR body
# does not: until wave 45 predicate (iii) was implemented as TEXTUAL PROXIMITY,
# not argument-list membership. The classifier comment-filtered the line
# carrying the call and then spliced the NEXT TWO LINES IN RAW, so what it
# actually tested was "attribute-bound and NEAR something executed". Three
# shapes walked through it, each producing THROUGH with a price, rc=0, ERRORS 0:
# (A) the attribute named only in a COMMENT one line below an unrelated
# `System.cmd`; (B) the attribute only `File.regular?`'d on a line adjacent to
# an unrelated `System.cmd`; (C) a TRAILING `#` comment INSIDE the argument
# list, which survives a whole-line comment filter. A FOURTH, (D), survived the
# first repair and was closed in review: the span walk balanced the parens
# correctly but returned the WHOLE CLOSING LINE, so a token named AFTER the
# closing paren — `System.cmd(…) ; File.regular?(@fraud)` — still read as
# membership. One line of the old proximity window, living inside the new
# predicate. The span now stops at the column of the closing paren, and the arm
# reds LEGA-BOUND-EXEC on revert. The window was wrong in the
# OTHER direction too: a genuine five-line `Port.open` door classified
# BOUND-UNEXEC — an honest door declined — so the repair was never "decline
# more". It is `arg_span`: walk from the opening paren until parens balance.
#
# AND THE SELFTEST WAS GREEN ON ALL OF IT, because its fraud fixture
# (`pds-fx-fraud.sh`) forgets to BIND — the literal is on a comment line and
# never `@attr`-bound, so it exits at the COMMENT branch and never reaches the
# execution test at all. A fixture that cannot reach the predicate cannot
# exercise it. The six wave-45 arms all bind first, and each REDS on revert.
#
# RESIDUAL HOLES, STATED RATHER THAN IMPLIED GONE:
#   1. `blank_strings` understands DOUBLE-QUOTED strings only, not sigils or
#      charlists. A paren inside `~s(…)` miscounts, and the span then runs to
#      its bound — MORE permissive, never less, so it can admit a fraud, not
#      deny an honest door.
#   2. The 40-line bound is SILENT when hit. A call longer than 40 lines yields
#      a truncated span with no diagnostic.
#   3. BOUND-UNEXEC is tested BEFORE the leg-A aggregation in the table, so a
#      single decoy binding anywhere can RED a legitimately-through door. That
#      is PRE-EXISTING, not introduced here, and is not this slice to move.
#
# WHAT THIS DOES NOT MODEL
# ------------------------
# COMPOSITION. Several of these programs are wrappers that invoke peers. This
# census does not model that at all: every program is its own row, a wrapper's
# coverage is never credited to its callees, and a callee's price is never
# credited to its wrapper. Said here rather than left for a reader to discover,
# because an unstated simplification is how a column starts lying.
#
# WHAT THE LEDGER CHECKS ARE FOR (wave 46) — three claims, each measured
# --------------------------------------------------------------------
#   1. THE ROT CHECK TESTED EXISTENCE ONLY. It catches a row naming a deleted
#      file and nothing else. A row asserting that a now-THROUGH instrument is
#      environment-refused was not merely wrong, it was UNREAD: the cond
#      short-circuits to THROUGH before the disposition ledger is consulted, so
#      injecting one left the output BYTE-IDENTICAL, rc=0, stderr empty. Hence
#      the orphan check, and hence it is UNGATED (PDS-D602: a has-key guard in
#      front of it is conditionally blind by construction).
#   2. THE RETIRE SHAPE LEGALIZES TWO ROWS PER BASENAME, and both lookups exit
#      on their FIRST match. So retirement and the duplicate-key check are ONE
#      change, never two: shipping retirement alone would widen a hole it also
#      makes easier to hit. A retired row is exempt from the orphan check, which
#      is why it must still carry evidence naming what superseded it.
#   3. THE NAIVE HOIST OF THE PRICE SHAPE CHECK REDS CLEAN MAIN, and does worse
#      than red: reusing the *CPU=*LOCAL*meter=* pattern rejected the receipt
#      census's honest UNMEASURED-LOCAL row (rc=1 on an untouched tree), and
#      setting class='ERROR' inside the THROUGH branch silently dropped the
#      headline from 4 of 20 to 3 of 20 — it hid a door while reporting a ledger
#      typo. The answer was NOT an exemption for "no number": the row was
#      MEASURED (28.73 s CPU across its three gated arms), and the shape check
#      APPENDS to error_lines and increments errors and NEVER assigns class.
#
# THE TWO SILENCES CLOSED IN WAVE 47 — both re-proven on a clean origin/main
# --------------------------------------------------------------------------
#   1. THE PRICE LEDGER HAD NO ORPHAN DIRECTION. Wave 46 built one for the
#      DISPOSITION ledger and stopped there. A price row naming an instrument
#      that is not THROUGH passed in TOTAL silence: rc=0, ERRORS 0, and a diff of
#      the whole run against the unmutated one produced NO OUTPUT. The key is
#      `class != THROUGH`, NOT the obvious symmetry `computed == yes`, because
#      the case that decides it is computed='no' — see orphaned_price_error.
#      And RETIRED- is refused here on BOTH sides: the lookup reads through
#      `ledger_field` so a retire costume is not an exemption, and
#      `price_shape_error`'s globs are ANCHORED so the costume cannot pass the
#      shape arms either. The ruling sits above PDS_DOOR_PRICES.
#   2. THE COUNTS BLOCK ACCOUNTED FOR 4 ROWS OF 20. It printed the four COMPUTED
#      bands and none of the six LEDGER classes, so flipping an instrument from
#      NOT-YET-BUILT to CONTENT-RED moved EXACTLY ONE line of the output — the
#      table row — leaving the counts byte-identical and rc=0 both ways, inside
#      a block headed "derived from the rows above, never transcribed". The
#      derivation was honest; the COVERAGE was 20%. The partition now prints the
#      whole vocabulary INCLUDING ZEROES, sums it, and ASSERTS the sum.
#      CONTENT-RED still does not red the run, and that is a DECLARED ruling
#      (the exit contract above is scoped to DISPOSABILITY, PDS-D637 made
#      CONTENT-RED a REASON A DOOR IS NOT THROUGH, and the rider pins rc as a
#      DESCENT from the counts): disposed != healthy.
#
# USAGE
#   pds-door-census.sh                 # the census (default) — fail-closed
#   pds-door-census.sh --selftest      # the fraud + depth arms, no BEAM, no gate
#   pds-door-census.sh --list-refs     # every classified test-side reference
#   pds-door-census.sh --help

set -euo pipefail

SELF="pds-door-census"

# ---------------------------------------------------------------------------
# PDS-D633 / PDS-D646 — the sentence that must ship in the output, not in prose
# ---------------------------------------------------------------------------
BLIND_SPOT='METER BLIND SPOT (PDS-D633/D646): `:erlang.statistics(:runtime)` is sound in-BEAM to <1%
  but BLIND to port children (a child burning 2.58 s reports 6 ms), and an OS meter wrapped
  around a BEAM that fans out to child BEAMs is blind to the whole fan-out. DO NOT QUOTE A
  RATIO: real/user reads 113x, 123x or 236x for the SAME fan-out because `real` counts
  waiting, so the ratio measures host load, not blindness. The load-independent figure is a
  leaf-metered FLOOR — a 33-case fan-out whose wrapper reported user 6,05 s spawns nine
  children that each cost ~15 s of user CPU alone, so ~140 s is concealed at minimum, and
  the wrapper reads UNDER HALF the price of ONE child. The blindness errs in the ONE
  direction a price column must not: it makes an expensive thing look gate-able. Every price
  below is therefore an OS meter around a SHELL, never a figure taken inside a BEAM parent.'

# ---------------------------------------------------------------------------
# THE CLASS VOCABULARY — PDS-D637's FIVE, plus HUMAN-GATE. Never three.
# ---------------------------------------------------------------------------
# THROUGH is computed, never declared. Everything else needs a ledger row below
# whose class is one of these SIX; anything else is a hard error, not a warning.
PDS_DOOR_CLASSES='PRICE
ENVIRONMENT
NOT-YET-BUILT
CONTENT-RED
RED-BY-DESIGN-REPORTER
HUMAN-GATE'

# The bands a row can land in WITHOUT a ledger row — derived from the tree by the
# cond in run_census. Declared here beside the ledger vocabulary because the two
# lists TOGETHER are the whole partition: every row of the column ends in exactly
# one of these eleven names, and the COUNTS block below asserts that sum against
# the population rather than printing four of the bands and going quiet about the
# rest. Until wave 47 the block accounted for 4 rows of 20 — the four computed
# bands — so flipping an instrument from NOT-YET-BUILT to CONTENT-RED moved
# EXACTLY ONE line of the whole output (its table row) and left the counts
# byte-identical: the flagship instrument could not tell "one instrument is RED
# right now" from "one instrument was never built" anywhere a reader looks.
PDS_DOOR_COMPUTED_BANDS='THROUGH
IN-BEAM-REQUIRED
DEAD-DECLARATION
UNDISPOSED
ERROR'

# ---------------------------------------------------------------------------
# THE DISPOSITION LEDGER — why a non-THROUGH instrument is not through.
# ---------------------------------------------------------------------------
# `<basename><TAB><CLASS><TAB><evidence>`. Every row's evidence names either a
# RUN (verdict + exit code) or a FILE:LINE in the instrument's own source. A row
# whose evidence is empty, or whose class is outside the vocabulary above, is a
# hard error — a disposition without evidence is the vacuous green this epic
# exists to remove. Absent rows are UNDISPOSED and red the run.
#
# THE RETIRE SHAPE. A disposition that stopped being true has exactly two legal
# endings, never a third: DELETE the row, or RETIRE it by prefixing its class
# `RETIRED-` and REPLACING its evidence with what superseded it. A retired row is
# invisible to the live path (it can never dispose anything), exempt from the
# orphan check, and STILL rot-checked for existence and STILL required to carry
# evidence. `RETIRED-*` is deliberately NOT in the vocabulary above and
# `class_known` refuses it by an explicit arm, so a retired class can never be
# smuggled back in as a live one.
PDS_DOOR_DISPOSITIONS='pds-charter-ledger-sweep.sh	CONTENT-RED	by run 2026-08-04 at 683c2f00a: `--check` rc=1 "RED: an UNRESOLVED-CLAIM ARRIVAL is a charter claim nobody has adjudicated" (71 arrivals — the figure MOVES on every charter merge, because the lens is mined FROM the charter: 41 -> 45 -> 59 -> 71 across four merges, and the row read 59 while the sweep at that same commit printed 71); `--selftest` is rc=0 (3 of 3) and no longer hostage to the corpus; blocked on scripts/pds-charter-ledger-adjudication.md, not on price (CPU 3.42 s LOCAL)
pds-record-parity.sh	RED-BY-DESIGN-REPORTER	by run 2026-08-03: `--selftest` rc=3 "unknown argument" — the flag does not exist; its only non-vacuous axis resolves task ids against the LIVE ledger and is red by design. A reporter must never carry a required check name.
pds-window-sentinel.sh	NOT-YET-BUILT	source declares only `watch` and `preflight` verbs (scripts/pds-window-sentinel.sh:48-49); it is a host watcher with no pass/fail selftest to gate on.
pds-ledger-census_test.sh	PRICE	CPU=33.44+6.89=40.33s LOCAL meter=/usr/bin/time -p around bash -c load1=24.26 2026-08-03 (rc=0, wall 68.24 s) — the SECOND tiering case; ~40 s CPU on a 2-4 vCPU runner needs its own justification.
pds-scratch-target_test.sh	PRICE	CPU=4.83+4.08=8.91s LOCAL meter=/usr/bin/time -p around bash -c load1=79.23 2026-08-03 (rc=0, stub barkpark). Hermeticity on a runner WITHOUT local Postgres is unproven here.
pds-live-hetzner-placement-group.sh	ENVIRONMENT	by run 2026-08-03: `--selftest` rc=3 "REFUSE — needs one WORKING credential"; needs HCLOUD_TOKEN or HCLOUD_CONFIG (scripts/pds-live-hetzner-placement-group.sh:17-21).
pds-live-bp-write-receipt.sh	ENVIRONMENT	needs a bp-resolvable Barkpark server+token; refuses exit 3 otherwise (scripts/pds-live-bp-write-receipt.sh:219).
pds-ledger-census.sh	ENVIRONMENT	needs live ledger credentials (BARKPARK_SERVER, scripts/pds-ledger-census.sh:1325) and python3 (exit 3 at :348-350).
pds-pull-proof.sh	ENVIRONMENT	needs a pinned BARKPARK_HOME scratch target plus an admin-token curl against a live server (scripts/pds-pull-proof.sh:113,227).
pds-secret-scan.sh	ENVIRONMENT	needs psql on PATH and DB-sourced ammo (scripts/pds-secret-scan.sh:136,191).
pds-scratch-target.sh	ENVIRONMENT	needs a scratch Postgres root and free port (BARKPARK_HOME / BARKPARK_PG_PORT, scripts/pds-scratch-target.sh:22-25).
pds-crown-stamp.sh	ENVIRONMENT	writes bp ledger rows and hard-requires python3 (scripts/pds-crown-stamp.sh:134).
pds-crown-launch.sh	ENVIRONMENT	a long-running launcher that ssh-es a live host with a deploy key (scripts/pds-crown-launch.sh:319-323).
pds-climb-preflight.sh	ENVIRONMENT	needs `gh` workflow state and an ssh key for the source host (scripts/pds-climb-preflight.sh:210,273-283).
pds-export-peak-measure.sh	ENVIRONMENT	samples a live host over ssh (scripts/pds-export-peak-measure.sh:242).
pds-idle-sampler.sh	ENVIRONMENT	samples a live host over ssh, twice a minute (scripts/pds-idle-sampler.sh:7,182).'

# ---------------------------------------------------------------------------
# THE PRICE LEDGER — measured prices for rows that ARE through the door.
# ---------------------------------------------------------------------------
# `<basename><TAB>CPU=<user>+<sys>=<total>s LOCAL meter=<meter> … load1=<n>`. A
# THROUGH row with NO entry is UNPRICED and REDS, exactly as a non-THROUGH
# instrument with no disposition row is UNDISPOSED and reds: an unmeasured price
# is a missing fact, never a zero, and never a silent default either. There is no
# UNMEASURED-LOCAL escape hatch (PDS-D666) — a legal shape meaning "no number"
# inside the very predicate whose purpose is that a price descends from a meter
# is the fraud this column exists to remove. The load1 stamp is REQUIRED
# (PDS-D656): CPU is not load-independent, so a figure with no load beside it is
# a number nobody can re-take.
#
# A PRICE HAS EXACTLY ONE LEGAL ENDING: DELETE THE ROW. The disposition ledger's
# retire shape does NOT exist here and must never be imported, because the two
# ledgers do not have the same columns: a disposition row carries a CLASS in
# field 2, so `RETIRED-<CLASS>` is a legal value there; THIS ledger's field 2 IS
# THE PRICE. There is nothing to prefix. A price is not a refusal that needs
# superseding evidence attached to it — its supersession IS a new measurement,
# and a new measurement REPLACES field 2 in place. `RETIRED-CPU=…` is therefore
# refused by `price_shape_error` on its own explicit arm, and the CPU= glob is
# ANCHORED at the start of the field rather than floating: until wave 47 the
# globs were `*'CPU='*'LOCAL'*'meter='*`, so `RETIRED-CPU=0.01+0.01=0.02s LOCAL
# meter=… load1=1.00` passed EVERY shape arm while `ledger_field` handed that
# same text to the THROUGH branch and printed it as a LIVE price — a working
# price wearing a costume, silent on main, rc=0, ERRORS 0.
#
# AND A PRICE ROW FOR AN INSTRUMENT THAT IS NOT THROUGH IS AN ORPHAN. This
# ledger is read at exactly ONE site, inside the THROUGH branch, so a row naming
# any other instrument is a price nobody pays and nothing reads —
# `orphaned_price_error` below is what makes that say so instead of passing in
# total silence.
PDS_DOOR_PRICES='pds-door-census.sh	CPU=0.51+0.72=1.23s LOCAL meter=/usr/bin/time -p around bash -c load1=5.26 2026-08-04 (--check, rc=0; 3 trials gave 1.24/1.22/1.23s). Its gated arm is --selftest at CPU=0.41+0.66=1.07s at load1=5.54 (5 trials 1.10/1.08/1.05/1.04/1.07 — a 5.7% spread across stamps 5.54-5.57, which is what makes the figure quotable against its own stamp rather than against the host). RE-TAKEN IN THIS PR BECAUSE THE INSTRUMENT CHANGED UNDERNEATH IT: wave 47 took --selftest from 24 arms to 33, seven of the nine running the real run_census over the two-instrument fixture tree, and a price whose instrument changed underneath it is the exact rot this row exists to prevent. THE DELTA IS MEASURED, NOT ESTIMATED, and only because both sides were metered in the SAME window: the untouched origin/main export (49345a98c) ran its --selftest at 0.54/0.58/0.53s at load1 5.26-5.37, so the nine new arms cost +95% of the gated arm — nearly double, not the ~+44% this slice was briefed with. The earlier 1.07s/0.47s at load1=3.26 and the 3.32s/0.16s at load1=41.63 are NOT comparable and are quoted as neither a delta nor a baseline: PDS-D656 — a price is quotable only against its own load stamp. The rider also runs --check once and a one-row mutant once.
pds-status-only-residue.exs	CPU=0.61+0.21=0.82s LOCAL meter=/usr/bin/time -p around bash -c load1=26.44 2026-08-03 (--selftest, 15/15 arms)
pds-record-parity.test.sh	CPU=1.45+3.00=4.45s LOCAL meter=/usr/bin/time -p around bash -c load1=26.44 2026-08-03 (76 checks, 0 failures)
pds-elixir-receipt-census.exs	CPU=26.47+2.26=28.73s LOCAL meter=/usr/bin/time -p around bash -c load1=2.93 2026-08-04 — the THREE GATED ARMS SUMMED, each metered separately: plain rc=0 at 11.81+0.94=12.75s, the one-token tl/1 mutant rc=1 at 11.53+0.91=12.44s (the mutant of api/test/barkpark/pds_elixir_census_test.exs:69-70, rebuilt in a tmp dir and run with cwd=repo root), the unknown-flag refusal rc=2 at 3.13+0.41=3.54s. THREE trials at load1 2.13 / 3.43 / 2.93 gave 29.20 / 28.61 / 28.73s total CPU — a 2% spread, so this row is quotable against its own load stamp and NOT against a busier host. Its `--selftest` is a DIFFERENT arm, separately disqualified at 210 s leaf CPU (D646), and is not what the gate runs.'

# ---------------------------------------------------------------------------
# roots
# ---------------------------------------------------------------------------
# PDS_DOOR_CENSUS_ROOT retargets the scan at a synthetic fixture tree; --selftest
# is its only caller. It cannot weaken a real run — pointing it at the repo gives
# the identical verdict.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCAN_ROOT="${PDS_DOOR_CENSUS_ROOT:-$REPO_ROOT}"
ESCAPE_CHECK="$SCRIPT_DIR/elixir-path-escape-check.sh"

# ---------------------------------------------------------------------------
# THE DENOMINATOR (PDS-D650)
# ---------------------------------------------------------------------------
# `scripts/pds-*.{sh,exs}` — NEVER a bare `scripts/pds-*` glob. The bare glob is
# 43 files, 24 of them .md runbooks and .txt transcripts, and it collapses the
# fraction by 2.3x. `.sh`-only is wrong the other way: the first instrument ever
# put through the door is an `.exs`.
#
# Harness-hood is DERIVED from the name, not listed: `*_test.sh` / `*.test.sh`.
# Both conventions (19 with harnesses, 16 peers-only) are defensible, so the
# census PRINTS WHICH ONE IT USED — otherwise its denominator is not derivable
# by a reader.
DENOMINATOR_CONVENTION='WITH-HARNESSES'

# PER GLOB, NEVER ONE `ls` OVER TWO. `ls -1 pds-*.sh pds-*.exs` exits NON-ZERO
# when EITHER glob is unmatched, and the plain `list="$(instruments)"` assignment
# inherits that rc under `set -euo pipefail` (:85) — a tree with .sh files and no
# .exs aborted the whole run at rc=1 having printed NOT ONE BYTE on stdout or
# stderr, the exact silent success/failure this instrument exists to catch. It
# also made run_census()'s own "enumerated ZERO ... the enumerator is broken, not
# the repo empty" diagnostic DEAD CODE: `set -e` killed the script before the
# guard could be reached. A glob that matches nothing must contribute nothing,
# never kill the census.
instruments() {
  (
    cd -- "$SCAN_ROOT/scripts" 2>/dev/null || exit 0
    for g in 'pds-*.sh' 'pds-*.exs'; do
      # shellcheck disable=SC2086  # $g is a glob PATTERN — expansion is the point
      for f in $g; do
        [ -e "$f" ] || continue
        printf '%s\n' "$f"
      done
    done | LC_ALL=C sort -u
  )
}

is_harness() {
  case "$1" in
    *_test.sh | *.test.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# LEG A — the reference classifier
# ---------------------------------------------------------------------------
# Emits `<file>\t<line>\t<KIND>\t<basename>\t<literal>` for every quoted RELATIVE
# literal under api/lib + api/test whose basename is one of the instruments.
#
# DEPTH IS DERIVED, NEVER HARDCODED: the match is `("../")+` + basename, so three
# dots at api/test/barkpark/, four at api/test/barkpark_web/studio/, and a
# single-arg `Path.expand("../…")` resolved against the `mix test` cwd `api/` all
# land. A hardcoded three-dot prefix passes today and breaks SILENTLY on the
# first barkpark_web-placed instrument.
#
# KINDS
#   LEGA-BOUND-EXEC   attribute-bound + dereferenced into System.cmd/Port.open
#   BOUND-UNEXEC      attribute-bound, executed by nothing            (ERROR)
#   IN-BEAM-REQUIRE   `Code.require_file` — in-BEAM, NOT priceable by an OS
#                     meter around a shell, so never THROUGH-with-a-price
#   INLINE-EXEC       executed, but the literal is not attribute-bound  (ERROR)
#   INLINE-UNEXEC     neither bound nor executed                        (ERROR)
#   COMMENT           the literal is on a comment line — NOT a reference
classify_refs() {
  local files f
  # WORKING TREE enumeration, and ONE grep for the whole prefilter: only a file
  # carrying a relative literal that names a pds program can produce a record.
  # A per-file grep spawned ~2 000 processes and was most of this instrument's
  # own price — the census is not exempt from the column it prints.
  files="$(
    cd -- "$SCAN_ROOT" 2>/dev/null &&
      grep -rlE --include='*.ex' --include='*.exs' \
        '"(\.\./)+[^"]*pds-[^"]*"' api/lib api/test 2>/dev/null |
      LC_ALL=C sort
  )" || true
  [ -n "$files" ] || return 0

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    classify_one_file "$f"
  done <<EOF
$files
EOF
}

classify_one_file() {
  local f="$1"
  # The instrument list travels through the ENVIRONMENT, not `awk -v`: -v runs
  # the value through escape processing and chokes on the embedded newlines.
  PDS_DOOR_INSTRUMENTS="$INSTRUMENT_LIST" awk -v FNAME="$f" '
    function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
    function is_comment(s) { return (substr(ltrim(s), 1, 1) == "#") }
    function bname(p,   n, a) { n = split(p, a, "/"); return a[n] }
    # word-boundary match for a bare identifier, including the `ctx.name` form
    function mentions(line, tok) {
      return (line ~ ("(^|[^A-Za-z0-9_@])" tok "([^A-Za-z0-9_]|$)"))
    }
    function mentions_attr(line, a) {
      return (line ~ ("@" a "([^A-Za-z0-9_]|$)"))
    }

    # --- ARGUMENT-LIST MEMBERSHIP, not textual proximity -------------------
    # The shipped predicate spliced the call line plus the NEXT TWO LINES RAW
    # into a match window. That is "bound and NEAR something executed", and
    # PDS-D649 demands "bound AND EXECUTED" — three fraud shapes walked through
    # it (see the header) and a genuine five-line Port.open door was DECLINED.
    # These three functions replace the window with the real question: is the
    # tainted token INSIDE the argument list of this call?

    # Blank the CONTENTS of double-quoted strings, keeping the delimiters, so a
    # `)` or a `#` inside a literal can neither close a span nor start a comment.
    # Only for the COUNTING/scanning pass — membership is tested against the raw
    # text, because blanking would erase a literal that IS the argument.
    function blank_strings(s,   out, i, c, inq, esc, n) {
      out = ""; inq = 0; esc = 0
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (inq) {
          if (esc) { esc = 0; out = out " "; continue }
          if (c == "\\") { esc = 1; out = out " "; continue }
          if (c == "\"") { inq = 0; out = out "\""; continue }
          out = out " "
        } else {
          if (c == "\"") { inq = 1; out = out "\""; continue }
          out = out c
        }
      }
      return out
    }

    # Cut a line at its first UNQUOTED `#`. This is what closes fraud C — a
    # TRAILING comment INSIDE the argument list, which survives a whole-line
    # comment filter. Offsets are preserved (the result is a prefix), so a
    # position taken in the cut line indexes the raw line identically.
    function cut_comment(s,   b, p) {
      b = blank_strings(s)
      p = index(b, "#")
      if (p > 0) return substr(s, 1, p - 1)
      return s
    }

    # Walk from the opening paren at L[start][pos] until parens BALANCE, and
    # return the RAW (comment-cut, un-blanked) text of the span. Whole comment
    # lines drop out; every line is cut at its first unquoted `#`; the counting
    # pass runs over the string-blanked text. Bounded at 40 lines so a file with
    # an unbalanced paren cannot make this walk the whole tree.
    #
    # THE SPAN STOPS AT THE CLOSING PAREN, NOT AT THE END OF ITS LINE. Returning
    # the whole final line would smuggle a slice of the OLD proximity window back
    # in through the closing line: `System.cmd(..) ; File.regular?(@fraud)` would
    # read as membership because `@fraud` sits in the returned text — bound, never
    # executed, classified LEGA-BOUND-EXEC. Cutting back to the column of the
    # paren itself is what makes "inside the argument list" mean inside it.
    # (No apostrophes in here: this whole program is one single-quoted shell
    # word, so one of them ends it and the census dies at parse time.)
    function arg_span(start, pos,   span, depth, k, cut, blk, ch, m, n) {
      span = ""; depth = 0
      for (k = start; k <= NR && k < start + 40; k++) {
        if (k > start && is_comment(L[k])) continue
        cut = cut_comment(L[k])
        if (k == start) {
          cut = substr(cut, pos)
          if (cut == "") return ""
        }
        span = (span == "") ? cut : (span "\n" cut)
        blk = blank_strings(cut)
        n = length(blk)
        for (m = 1; m <= n; m++) {
          ch = substr(blk, m, 1)
          if (ch == "(") depth++
          else if (ch == ")") {
            depth--
            # `cut` is a SUFFIX of `span` and `blank_strings` is length-
            # preserving, so column m of `cut` is column
            # length(span) - length(cut) + m of `span`.
            if (depth <= 0) return substr(span, 1, length(span) - length(cut) + m)
          }
        }
      }
      return span
    }

    BEGIN {
      n = split(ENVIRON["PDS_DOOR_INSTRUMENTS"], ia, "\n")
      for (i = 1; i <= n; i++) if (ia[i] != "") KNOWN[ia[i]] = 1
    }

    { L[NR] = $0 }

    END {
      # ---- collect bindings ------------------------------------------------
      nb = 0
      for (i = 1; i <= NR; i++) {
        line = L[i]
        rest = line
        while (match(rest, /"(\.\.\/)+[^"]*"/)) {
          lit = substr(rest, RSTART + 1, RLENGTH - 2)
          rest = substr(rest, RSTART + RLENGTH)
          base = bname(lit)
          if (!(base in KNOWN)) continue

          if (is_comment(line)) {
            printf "%s\t%d\tCOMMENT\t%s\t%s\n", FNAME, i, base, lit
            continue
          }

          nb++
          bline[nb] = i; blit[nb] = lit; bbase[nb] = base
          bseed[nb] = ""; bkind[nb] = ""

          # attribute-bound?  `@name "…"`
          s = ltrim(line)
          if (match(s, /^@[A-Za-z_][A-Za-z0-9_]*[ \t]+"/)) {
            a = substr(s, 2, RLENGTH - 1)
            sub(/[ \t]+"$/, "", a)
            bseed[nb] = "@" a; bkind[nb] = "ATTR"
            continue
          }
          # `Code.require_file("…", __DIR__)` — in-BEAM, its own disposition
          if (line ~ /Code\.require_file[ \t]*\(/) {
            bkind[nb] = "REQUIRE"
            continue
          }
          # `name = … "…" …` — a var-bound literal (the E4 shape: the script is
          # argv[2] of an interpreter-with-inline-program invocation)
          if (match(line, /^[ \t]*[a-z_][A-Za-z0-9_]*[ \t]*=[^=]/)) {
            v = ltrim(substr(line, RSTART, RLENGTH))
            sub(/[ \t]*=.*$/, "", v)
            bseed[nb] = v; bkind[nb] = "VAR"
            continue
          }
          # the literal sits directly in a call
          if (line ~ /System\.cmd[ \t]*\(/ || line ~ /Port\.open[ \t]*\(/) {
            bkind[nb] = "DIRECT"
            continue
          }
          bkind[nb] = "LOOSE"
        }
      }

      # ---- per-binding taint + execution ----------------------------------
      for (b = 1; b <= nb; b++) {
        if (bkind[b] == "REQUIRE") {
          printf "%s\t%d\tIN-BEAM-REQUIRE\t%s\t%s\n", FNAME, bline[b], bbase[b], blit[b]
          continue
        }
        if (bkind[b] == "DIRECT") {
          printf "%s\t%d\tINLINE-EXEC\t%s\t%s\n", FNAME, bline[b], bbase[b], blit[b]
          continue
        }
        if (bkind[b] == "LOOSE") {
          printf "%s\t%d\tINLINE-UNEXEC\t%s\t%s\n", FNAME, bline[b], bbase[b], blit[b]
          continue
        }

        delete TV
        attr = ""
        if (bkind[b] == "ATTR") { attr = substr(bseed[b], 2) } else { TV[bseed[b]] = 1 }

        # Three forward sweeps: enough for the bind -> setup_all -> ctx hop the
        # doors actually use, and bounded so a pathological file cannot spin.
        for (pass = 1; pass <= 3; pass++) {
          for (i = 1; i <= NR; i++) {
            line = L[i]
            if (is_comment(line)) continue
            hit = 0
            if (attr != "" && mentions_attr(line, attr)) hit = 1
            if (!hit) for (v in TV) if (mentions(line, v)) { hit = 1; break }
            if (!hit) continue

            # assignment harvest:  `name = … <tainted> …`
            if (match(line, /^[ \t]*[a-z_][A-Za-z0-9_]*[ \t]*=[^=]/)) {
              lhs = ltrim(substr(line, RSTART, RLENGTH))
              sub(/[ \t]*=.*$/, "", lhs)
              TV[lhs] = 1
            }
            # keyword harvest, PER PAIR:  `key: <tainted>` (the setup_all hop)
            kr = line
            while (match(kr, /[a-z_][A-Za-z0-9_]*:[ \t]*[A-Za-z_@][A-Za-z0-9_.]*/)) {
              pair = substr(kr, RSTART, RLENGTH)
              kr = substr(kr, RSTART + RLENGTH)
              ci = index(pair, ":")
              k = substr(pair, 1, ci - 1)
              val = ltrim(substr(pair, ci + 1))
              vn = split(val, va, ".")
              lv = va[vn]
              if (lv in TV) TV[k] = 1
              else if (attr != "" && val == ("@" attr)) TV[k] = 1
            }
          }
        }

        # EXECUTION: a tainted token inside a System.cmd/Port.open ARGUMENT LIST,
        # delimited by arg_span. EVERY call opening on the line is scanned, not
        # just the first — a line carrying two calls would otherwise hide the
        # second one behind the first.
        exec_at = 0
        for (i = 1; i <= NR && exec_at == 0; i++) {
          if (is_comment(L[i])) continue
          probe = cut_comment(L[i])
          if (probe !~ /System\.cmd[ \t]*\(/ && probe !~ /Port\.open[ \t]*\(/) continue
          rest2 = probe
          off = 0
          while (match(rest2, /(System\.cmd|Port\.open)[ \t]*\(/)) {
            popen = off + RSTART + RLENGTH - 1   # 1-based index of "(" in L[i]
            rest2 = substr(rest2, RSTART + RLENGTH)
            off = popen
            span = arg_span(i, popen)
            if (span == "") continue
            if (attr != "" && mentions_attr(span, attr)) exec_at = i
            if (exec_at == 0) for (v in TV) if (mentions(span, v)) { exec_at = i; break }
            if (exec_at != 0) break
          }
        }

        if (bkind[b] == "ATTR") {
          if (exec_at > 0)
            printf "%s\t%d\tLEGA-BOUND-EXEC\t%s\t%s\n", FNAME, bline[b], bbase[b], blit[b]
          else
            printf "%s\t%d\tBOUND-UNEXEC\t%s\t%s\n", FNAME, bline[b], bbase[b], blit[b]
        } else {
          if (exec_at > 0)
            printf "%s\t%d\tINLINE-EXEC\t%s\t%s\n", FNAME, bline[b], bbase[b], blit[b]
          else
            printf "%s\t%d\tINLINE-UNEXEC\t%s\t%s\n", FNAME, bline[b], bbase[b], blit[b]
        }
      }
    }
  ' "$SCAN_ROOT/$f"
}

# ---------------------------------------------------------------------------
# LEG B — BY EXECUTION
# ---------------------------------------------------------------------------
# The candidate path goes into `elixir-path-escape-check.sh --match test` on
# stdin and its printed verdict is read. rc is captured WITHOUT a pipe: reading
# an exit code through a pipe reads the pipe's, and this epic has been bitten by
# exactly that.
leg_b() {
  local path="$1" out rc
  # NO PIPE. `--match` greps stdin with -q and exits the moment it matches, so a
  # `printf | bash` form would hand SIGPIPE to printf and, under `pipefail`,
  # report rc=141 for a perfectly good verdict — an exit code read through a
  # pipe, which is the exact defect this epic exists to remove. A here-doc feeds
  # stdin without one.
  out="$(bash "$ESCAPE_CHECK" --match test 2>&1 <<EOF
$path
EOF
  )"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'ERROR'
    return 0
  fi
  case "$out" in
    true) printf 'true' ;;
    false) printf 'false' ;;
    *) printf 'ERROR' ;;
  esac
}

# ---------------------------------------------------------------------------
# ledger lookup
# ---------------------------------------------------------------------------
ledger_field() {
  # $1 = ledger text, $2 = basename, $3 = field index (2=class, 3=evidence)
  # Here-doc, never a pipe: the awk program exits on its first match, and a pipe
  # would turn that into a SIGPIPE on the writer (rc=141 under `pipefail`).
  awk -F'\t' -v b="$2" -v i="$3" '$1 == b { print $i; exit }' <<EOF
$1
EOF
}

# Exact-line membership without a pipe, for the same reason.
has_line() {
  local l
  while IFS= read -r l; do
    if [ "$l" = "$2" ]; then return 0; fi
  done <<EOF
$1
EOF
  return 1
}

class_known() {
  # RETIRED-* is refused BY THIS ARM, not merely by absence from the vocabulary.
  # Absence is a weak guarantee: adding `RETIRED-ENVIRONMENT` to the list above
  # took a SHUT door to full green (rc=0, ERRORS 0) and only the arm counting the
  # vocabulary at six noticed. A retired class is a fact about a row that has
  # STOPPED disposing anything; it must never be able to dispose one again, and
  # that must not depend on someone remembering to keep it out of a list.
  case "$1" in
    RETIRED-*) return 1 ;;
  esac
  has_line "$PDS_DOOR_CLASSES" "$1"
}

# The FIRST row for $2 whose class is NOT RETIRED-*. This is the ONLY lookup the
# live path uses; `ledger_field` remains for the rot check, which must still see
# retired rows. Here-doc, never a pipe, for the reason above ledger_field.
live_ledger_field() {
  # $1 = ledger text, $2 = basename, $3 = field index (2=class, 3=evidence)
  awk -F'\t' -v b="$2" -v i="$3" '$1 == b && $2 !~ /^RETIRED-/ { print $i; exit }' <<EOF
$1
EOF
}

# ---------------------------------------------------------------------------
# THE PARTITION — every row of the column lands in exactly one printed band
# ---------------------------------------------------------------------------
# Ported from scripts/pds-elixir-receipt-census.exs's report_derivation_partition/2
# ("THE PARTITION, PRINTED IN FULL", built by pds-w40-derivation-partition): the
# full vocabulary is printed INCLUDING ZEROES, the printed lines are SUMMED, and
# the sum is checked against the population. A `uniq -c` over the observed
# classes would have been shorter and wrong — it omits the classes at zero, and
# HUMAN-GATE is at zero right now, which the charter records as a LIVE FINDING.
# A band that vanishes when it empties hides exactly the fact worth printing.
class_tally_count() {
  # $1 = the newline-separated per-row class list, $2 = the band name.
  # An exact-line count, never a substring: `ERROR` must not also count
  # `RED-BY-DESIGN-REPORTER`, and `PRICE` must not count itself twice.
  # An `if`, never `[ … ] && n=…`: a trailing AND-list whose test fails leaves the
  # loop with a non-zero status, and this whole file runs under `set -e`.
  local l n=0
  while IFS= read -r l; do
    if [ "$l" = "$2" ]; then n=$((n + 1)); fi
  done <<EOF
$1
EOF
  printf '%s' "$n"
}

# The RESIDUAL BAND, stated rather than assumed away: every class this run
# produced that is in NEITHER declared list. On a healthy tree it is empty, and
# an empty residual is the only thing that makes the printed sum a derivation
# rather than a coincidence.
unaccounted_classes() {
  # $1 = the per-row class list. Prints the offending class names, deduped.
  local l
  {
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      if has_line "$PDS_DOOR_CLASSES" "$l"; then continue; fi
      if has_line "$PDS_DOOR_COMPUTED_BANDS" "$l"; then continue; fi
      printf '%s\n' "$l"
    done <<EOF
$1
EOF
  } | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# ORPHANED DISPOSITION — a ledger row nobody reads
# ---------------------------------------------------------------------------
# The class cond below short-circuits leg A + leg B to THROUGH (and the leg-A
# kinds to ERROR, and Code.require_file to IN-BEAM-REQUIRED) BEFORE the
# disposition ledger is consulted at all. So a row asserting that a now-THROUGH
# instrument is environment-refused is not merely wrong — it is UNREAD: injecting
# one left the output byte-identical, rc=0, stderr empty. A ledger nobody reads
# is how a disposition column drifts back into prose.
#
# THIS CHECK IS UNGATED ON PURPOSE. It runs for every row whose class was
# COMPUTED, with no has-key or membership guard in front of it: PDS-D602 records
# the sibling census's guarded orphan direction as CONDITIONALLY BLIND — a guard
# that asks "is this basename in the ledger?" before asking "should it be?"
# cannot see the case where the answer to the second question is no.
orphan_error() {
  # $1 = basename, $2 = the COMPUTED class, $3 = disposition ledger text.
  # Prints one error line, or nothing. Retired rows are exempt by construction:
  # live_ledger_field cannot see them.
  local lclass
  lclass="$(live_ledger_field "$3" "$1" 2)"
  [ -n "$lclass" ] || return 0
  printf '  %s: ORPHANED DISPOSITION — the ledger carries a live %s row for it, but this run COMPUTED %s from the tree. The cond never reads a disposition for a computed row, so this row asserts a refusal nobody consults. Retire it (RETIRED-%s + what superseded it) or delete it.' \
    "$1" "$lclass" "$2" "$lclass"
}

# ---------------------------------------------------------------------------
# ORPHANED PRICE — a price row nobody pays
# ---------------------------------------------------------------------------
# The disposition ledger's orphan direction (above) has a mirror image that went
# unbuilt for four waves: PDS_DOOR_PRICES is read at EXACTLY ONE site, inside the
# THROUGH branch, so a price row naming an instrument this run did not compute
# THROUGH is read by nothing at all. Appending one for `pds-secret-scan.sh`
# (class ENVIRONMENT) left `--check` at rc=0, ERRORS 0, and the COUNTS block
# BYTE-IDENTICAL — the same total silence the disposition orphan check was built
# to end, in the other ledger.
#
# THE KEY IS `class != THROUGH`, NOT `computed == yes`, and the case that decides
# it is the CROSS-LEDGER CONTRADICTION: an instrument disposed PRICE carries its
# price in its DISPOSITION evidence (field 3, shape-checked in the else branch)
# with computed='no', so a SECOND and CONTRADICTING figure in PDS_DOOR_PRICES is
# two ledgers naming one price. `ledger_keys` refuses a cross-ledger union by
# deliberate design (a union double-reports one within-ledger duplicate), so
# nothing else in this instrument can see it. A `computed == yes` key — the
# obvious symmetry with orphan_error — ships a half-fix that leaves exactly that
# case silent: planting 19.98s against pds-scratch-target_test.sh's own 8.91s is
# rc=0 under it and rc=1 under this one.
#
# UNGATED, for PDS-D602's reason: no has-key or membership guard runs in front of
# it. A guard that asks "is this basename priced?" before asking "should it be?"
# is conditionally blind by construction.
#
# `ledger_field`, NEVER `live_ledger_field`: the price ledger has no retire shape
# (see the ruling above PDS_DOOR_PRICES), and looking this up through the
# retirement-aware helper would silently make `RETIRED-` an EXEMPTION from the
# orphan check in a ledger where it is not even a legal value.
orphaned_price_error() {
  # $1 = basename, $2 = this run's class for it, $3 = price ledger text.
  # Prints one error line, or nothing. NEVER assigns class (PDS-D667).
  local p
  [ "$2" != 'THROUGH' ] || return 0
  p="$(ledger_field "$3" "$1" 2)"
  [ -n "$p" ] || return 0
  printf '  %s: ORPHANED PRICE — the price ledger carries a row for it, but this run classed it %s, not THROUGH. PDS_DOOR_PRICES is read at exactly one site, inside the THROUGH branch, so this row is a price nobody pays and nothing reads. If its class is PRICE the row is worse than unread: the disposition evidence carries that price too, and two ledgers naming one price is a contradiction neither duplicate-key scan can see (each is scoped to its own ledger by design). DELETE THE ROW; a price has no other legal ending. It carries: %s' \
    "$1" "$2" "$p"
}

# ---------------------------------------------------------------------------
# PRICE SHAPE — one predicate, applied to EVERY price, THROUGH or PRICE-classed
# ---------------------------------------------------------------------------
# SEPARATED AXIS, and this is law (PDS-D667): a shape check APPENDS to
# error_lines and increments errors, and NEVER assigns class. A malformed price
# is a fact about the LEDGER; THROUGH is a fact about the WIRING. The naive
# version of this check set class='ERROR' inside the THROUGH branch and silently
# dropped the headline from THROUGH 4 of 20 to 3 of 20 — it hid a door while
# reporting a ledger typo.
price_shape_error() {
  # $1 = basename, $2 = the price text. Prints one error line, or nothing.
  #
  # RETIRED- ON ITS OWN ARM, not merely by falling off the anchored glob below:
  # the retire shape is a DISPOSITION shape, and importing it here silently turns
  # a live price into one — see the ruling above PDS_DOOR_PRICES. The arm is
  # separate so the message names the ruling rather than reading as a typo.
  case "$2" in
    RETIRED-*)
      printf '  %s: a price cannot be RETIRED. The retire shape belongs to the DISPOSITION ledger, whose field 2 is a CLASS; this ledger'"'"'s field 2 is THE PRICE, so there is nothing to prefix. A price has exactly ONE legal ending: DELETE THE ROW (its supersession is a new measurement, which replaces field 2 in place). It carries: %s' "$1" "$2"
      return 0
      ;;
  esac
  # ANCHORED AT THE START, never floating: the old leading `*` admitted ANY
  # prefix in front of CPU=, which is how the retire costume walked through.
  case "$2" in
    'CPU='*'LOCAL'*'meter='*) ;;
    *)
      printf '  %s: a price must carry CPU=<user>+<sys>=<total>s LOCAL meter=<name> (PDS-D648). It carries: %s' "$1" "$2"
      return 0
      ;;
  esac
  case "$2" in
    *'load1='*) ;;
    *)
      printf '  %s: a price must carry its own load1=<n> stamp (PDS-D656 — CPU is NOT load-independent; the same byte-identical workload spanned 1.91-3.90 s across wave 45). It carries: %s' "$1" "$2"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# DUPLICATE KEYS — the first row silently wins
# ---------------------------------------------------------------------------
# ledger_field and live_ledger_field both exit on their FIRST match, so a second
# row for the same basename is silently ignored and the first one decides. The
# retire shape LEGALIZES two rows per basename, so shipping retirement without
# this check widens a hole it also makes easier to hit: both, or neither.
#
# EACH LEDGER IS SCANNED ON ITS OWN, and each side is de-duplicated BEFORE any
# union. Concatenating two key streams and then `uniq -d`ing the union
# DOUBLE-REPORTS one within-ledger duplicate as a phantom cross-ledger collision
# (ERRORS 2 for one defect). The scan is scoped to the VARIABLE, never to a line
# range: a line-range scan straddles the comment block between the two literals
# and reports a COMMENT LINE as a duplicate key.
ledger_keys() {
  # $1 = ledger text, $2 = 'live' to skip RETIRED-* rows, else every row
  awk -F'\t' -v mode="${2:-all}" '
    $1 == "" { next }
    mode == "live" && $2 ~ /^RETIRED-/ { next }
    { print $1 }
  ' <<EOF
$1
EOF
}

# A retired row must still say what superseded it. Retired rows are skipped by
# the live path, so they never reach the empty-evidence hard error the live rows
# are held to — retirement as designed is an unconditional exemption, and an
# exemption with no evidence attached is a row that says only "not this any
# more", which is the vacuous green under a different name.
retired_evidence_errors() {
  # $1 = disposition ledger text. Prints zero or more error lines.
  awk -F'\t' '
    $2 ~ /^RETIRED-/ && $3 == "" {
      printf "  %s: RETIRED row with EMPTY evidence. Retiring a disposition means REPLACING its evidence with what superseded it, not deleting it — a retired row is exempt from the orphan check, and an exemption nobody justified is the vacuous green under another name.\n", $1
    }
  ' <<EOF
$1
EOF
}

# ---------------------------------------------------------------------------
# the census
# ---------------------------------------------------------------------------
run_census() {
  local list total sh_n exs_n harnesses harness_n peers_n
  list="$(instruments)"
  if [ -z "$list" ]; then
    echo "::error::$SELF: enumerated ZERO scripts/pds-*.{sh,exs} under $SCAN_ROOT." >&2
    echo "  Nothing found is never good news here — the enumerator is broken, not the repo empty." >&2
    return 1
  fi

  INSTRUMENT_LIST="$list"
  total="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
  sh_n="$(printf '%s\n' "$list" | grep -c '\.sh$' || true)"
  exs_n="$(printf '%s\n' "$list" | grep -c '\.exs$' || true)"
  harnesses="$(printf '%s\n' "$list" | grep -E '(_test\.sh|\.test\.sh)$' || true)"
  harness_n="$(printf '%s\n' "$harnesses" | sed '/^$/d' | wc -l | tr -d ' ')"
  peers_n=$((total - harness_n))

  echo "$SELF: scanning \$SCAN_ROOT=$SCAN_ROOT"
  echo
  echo "DENOMINATOR — the glob is scripts/pds-*.{sh,exs}, NEVER a bare scripts/pds-*"
  echo "  enumerated by: ls -1 scripts/pds-*.sh scripts/pds-*.exs"
  echo "  population    : $total ($sh_n .sh + $exs_n .exs)"
  echo "  harnesses     : $harness_n (derived from the *_test.sh / *.test.sh name, not listed):"
  printf '%s\n' "$harnesses" | sed '/^$/d' | sed 's/^/                  /'
  echo "  peers-only    : $peers_n"
  echo "  CONVENTION USED: $DENOMINATOR_CONVENTION -> the denominator below is $total"
  echo "  without THIS instrument the population is $((total - 1)) — an instrument that counts"
  echo "  instruments enters its own denominator, and a census that hid itself would be the"
  echo "  first thing it exists to catch."
  echo

  # ---- leg A ---------------------------------------------------------------
  local refs
  refs="$(classify_refs || true)"

  echo "TEST-SIDE REFERENCES (depth derived: the match is (\"../\")+ plus the basename)"
  if [ -n "$refs" ]; then
    printf '%s\n' "$refs" |
      awk -F'\t' '{ printf "  %-18s %s:%s  %s\n", $3, $1, $2, $5 }'
  else
    echo "  (none)"
  fi
  echo

  # ---- the table -----------------------------------------------------------
  local b kinds legA legB class evidence price row computed shape_err orphan_err
  local orphan_price_err
  local through=0 undisposed=0 errors=0 inbeam=0 dead=0 error_rows=0
  local through_names="" undisposed_names="" error_lines="" class_tally=""

  echo "THE COLUMN"
  printf '  %-38s %-6s %-6s %-22s %s\n' INSTRUMENT LEG-A LEG-B DISPOSITION DETAIL
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    kinds="$(printf '%s\n' "$refs" | awk -F'\t' -v b="$b" '$4 == b { print $3 }' | LC_ALL=C sort -u)"

    legA='no'
    case "$kinds" in *LEGA-BOUND-EXEC*) legA='yes' ;; esac
    legB="$(leg_b "scripts/$b")"

    class=''
    evidence=''
    price=''
    # COMPUTED means: this row's class came from the TREE, not from the ledger.
    # Only the terminal else reads a class; everything above it derives one, and
    # every derived row is one the disposition ledger must not be asserting
    # anything about. The flag is what the orphan check keys on.
    computed='yes'

    # unclassifiable test-side references are ERRORS, never a silent "not gated"
    row=''
    if has_line "$kinds" 'BOUND-UNEXEC'; then
      class='ERROR'
      evidence='attribute-bound but executed by nothing — a door pointed at nothing. Wire it into System.cmd/Port.open or delete the binding, never both quietly.'
    elif has_line "$kinds" 'INLINE-EXEC'; then
      class='ERROR'
      evidence='executed from a literal that is NOT attribute-bound — leg A requires the @x_rel shape so scripts/elixir-path-escape-check.sh can resolve it. Bind it.'
    elif has_line "$kinds" 'INLINE-UNEXEC'; then
      class='ERROR'
      evidence='a relative literal naming this instrument that is neither bound nor executed — unclassifiable, so it is an error rather than a silent pass.'
    elif [ "$legA" = 'yes' ] && [ "$legB" = 'true' ]; then
      class='THROUGH'
      price="$(ledger_field "$PDS_DOOR_PRICES" "$b" 2)"
      if [ -z "$price" ]; then
        # NO SILENT DEFAULT. The old arm printed `price=UNMEASURED-LOCAL` here,
        # which made an author's reasoned refusal to price and a row nobody ever
        # wrote indistinguishable — and deleting a genuinely measured price row
        # left rc=0, ERRORS 0 and all four counts unmoved.
        error_lines="$error_lines
  $b: UNPRICED — THROUGH a required gate with no row in PDS_DOOR_PRICES. An absent price is a missing fact, exactly as an absent disposition is. Measure it (an OS meter around a SHELL, with its load1 stamp) and add the row. FAIL-CLOSED."
        errors=$((errors + 1))
        evidence='price=UNPRICED — no row in the price ledger. FAIL-CLOSED.'
      else
        # SEPARATED AXIS: the shape verdict never touches $class. A malformed
        # price reds the run and leaves the door counted as the door it is.
        shape_err="$(price_shape_error "$b" "$price")"
        if [ -n "$shape_err" ]; then
          error_lines="$error_lines
$shape_err"
          errors=$((errors + 1))
        fi
        evidence="$price"
      fi
    elif has_line "$kinds" 'IN-BEAM-REQUIRE'; then
      # E3: Code.require_file runs IN the ExUnit BEAM. It is genuinely gated, but
      # it is NOT priceable by an OS meter around a shell, so it never gets a
      # price and never claims THROUGH-with-a-price.
      class='IN-BEAM-REQUIRED'
      evidence='Code.require_file — runs inside the ExUnit BEAM, so D633 forbids an OS-meter price for it. Gated, unpriceable, its own row.'
    elif [ "$legA" = 'no' ] && [ "$legB" = 'true' ]; then
      class='DEAD-DECLARATION'
      evidence='declared in ELIXIR_TEST_ONLY_PATHS but executed by no ExUnit case — leg B without leg A. This is the one class no existing gate can see.'
    else
      # THE ONE BRANCH THAT READS. A retired row is invisible here, so an
      # instrument whose ONLY row is retired falls to UNDISPOSED and reds — you
      # cannot retire the only explanation of a shut door.
      computed='no'
      class="$(live_ledger_field "$PDS_DOOR_DISPOSITIONS" "$b" 2)"
      evidence="$(live_ledger_field "$PDS_DOOR_DISPOSITIONS" "$b" 3)"
      if [ -z "$class" ]; then
        class='UNDISPOSED'
        evidence='no ledger row — this instrument has no measured price, no named environment, and no other class. FAIL-CLOSED.'
      elif ! class_known "$class"; then
        error_lines="$error_lines
  $b: ledger class '$class' is outside the vocabulary (PDS-D637's five plus HUMAN-GATE)."
        class='ERROR'
      elif [ -z "$evidence" ]; then
        error_lines="$error_lines
  $b: ledger row carries class '$class' with EMPTY evidence."
        class='ERROR'
      elif [ "$class" = 'PRICE' ]; then
        # Same predicate as the THROUGH branch, same separated axis: a PRICE row
        # with a malformed price is still a PRICE row, and the run still reds.
        shape_err="$(price_shape_error "$b" "$evidence")"
        if [ -n "$shape_err" ]; then
          error_lines="$error_lines
$shape_err"
          errors=$((errors + 1))
        fi
      fi
    fi

    # ---- the orphan check, ungated ----------------------------------------
    if [ "$computed" = 'yes' ]; then
      orphan_err="$(orphan_error "$b" "$class" "$PDS_DOOR_DISPOSITIONS")"
      if [ -n "$orphan_err" ]; then
        error_lines="$error_lines
$orphan_err"
        errors=$((errors + 1))
      fi
    fi

    if [ "$legB" = 'ERROR' ]; then
      error_lines="$error_lines
  $b: leg B could not be evaluated — elixir-path-escape-check.sh --match test gave no verdict."
      class='ERROR'
    fi

    # ---- the orphaned-price check, ungated, keyed on class != THROUGH ------
    # Runs for EVERY instrument with no has-key guard (PDS-D602), and after the
    # leg-B arm above so it reads the class this run actually landed on.
    orphan_price_err="$(orphaned_price_error "$b" "$class" "$PDS_DOOR_PRICES")"
    if [ -n "$orphan_price_err" ]; then
      error_lines="$error_lines
$orphan_price_err"
      errors=$((errors + 1))
    fi

    # THE ROW'S FINAL CLASS, recorded for the partition below. Every row lands in
    # exactly one band; a class that lands in NONE is what the residual names.
    class_tally="$class_tally
$class"

    case "$class" in
      THROUGH)
        through=$((through + 1))
        through_names="$through_names $b"
        ;;
      IN-BEAM-REQUIRED) inbeam=$((inbeam + 1)) ;;
      DEAD-DECLARATION) dead=$((dead + 1)) ;;
      UNDISPOSED)
        undisposed=$((undisposed + 1))
        undisposed_names="$undisposed_names $b"
        ;;
      ERROR)
        errors=$((errors + 1))
        # A SEPARATE COUNTER, because ERRORS is not a row count: it also carries
        # shape errors, orphan errors, stale rows and duplicate keys, none of
        # which are rows of the column. The partition sums ROWS.
        error_rows=$((error_rows + 1))
        ;;
    esac

    printf '  %-38s %-6s %-6s %-22s %s\n' "$b" "$legA" "$legB" "$class" "$evidence"
  done <<EOF
$list
EOF

  # ---- the ledger must not rot -------------------------------------------
  # A disposition or price row naming a program that is no longer on disk is a
  # fact about a tree that no longer exists. Left unchecked it is how a price
  # column drifts back into prose: the rows outlive the instruments and nobody
  # notices, because nothing reads them.
  local lb
  while IFS= read -r lb; do
    lb="${lb%%	*}"
    [ -n "$lb" ] || continue
    if ! has_line "$list" "$lb"; then
      error_lines="$error_lines
  $lb: STALE LEDGER ROW — disposed/priced here, but no such scripts/pds-*.{sh,exs} program exists."
      errors=$((errors + 1))
    fi
  done <<EOF
$PDS_DOOR_DISPOSITIONS
$PDS_DOOR_PRICES
EOF

  # ---- the ledger must not carry two answers to one question --------------
  local dk
  while IFS= read -r dk; do
    [ -n "$dk" ] || continue
    error_lines="$error_lines
  $dk: DUPLICATE DISPOSITION KEY — more than one LIVE (non-retired) row. Both lookups exit on the FIRST match, so the second row is silently ignored and the first one decides; a contradictory row above a true one reclassifies an instrument with nothing printed at all."
    errors=$((errors + 1))
  done <<EOF
$(ledger_keys "$PDS_DOOR_DISPOSITIONS" live | LC_ALL=C sort | uniq -d)
EOF

  local pk
  while IFS= read -r pk; do
    [ -n "$pk" ] || continue
    error_lines="$error_lines
  $pk: DUPLICATE PRICE KEY — more than one row in PDS_DOOR_PRICES. The first one silently becomes the price."
    errors=$((errors + 1))
  done <<EOF
$(ledger_keys "$PDS_DOOR_PRICES" all | LC_ALL=C sort | uniq -d)
EOF

  # ---- a retired row must still say what superseded it --------------------
  local re
  while IFS= read -r re; do
    [ -n "$re" ] || continue
    error_lines="$error_lines
$re"
    errors=$((errors + 1))
  done <<EOF
$(retired_evidence_errors "$PDS_DOOR_DISPOSITIONS")
EOF

  # ---- the partition, computed BEFORE the block prints ---------------------
  # ERRORS is printed last and must carry the shortfall verdict, so the sum is
  # taken here rather than inside the echoes below.
  # ACCOUNTED FOR is summed from the SAME tally the residual is derived from —
  # never from the four running counters beside it. Two sources would let the sum
  # and the residual disagree, and a partition whose two halves disagree is the
  # transcription this block's header refuses.
  local cname cn accounted residual ledger_lines
  accounted=0
  while IFS= read -r cname; do
    [ -n "$cname" ] || continue
    accounted=$((accounted + $(class_tally_count "$class_tally" "$cname")))
  done <<EOF
$PDS_DOOR_COMPUTED_BANDS
EOF
  ledger_lines=''
  while IFS= read -r cname; do
    [ -n "$cname" ] || continue
    cn="$(class_tally_count "$class_tally" "$cname")"
    ledger_lines="$ledger_lines
$(printf '    %-24s: %s of %s' "$cname" "$cn" "$total")"
    accounted=$((accounted + cn))
  done <<EOF
$PDS_DOOR_CLASSES
EOF

  residual="$(unaccounted_classes "$class_tally")"

  # ASSERTED, NOT MERELY PRINTED — a printed sum nobody checks is a number, not
  # a verdict, and it reds the run through error_lines like every other finding
  # here rather than through a class assignment (PDS-D667).
  if [ "$accounted" -ne "$total" ]; then
    error_lines="$error_lines
  PARTITION SHORTFALL — the printed bands account for $accounted of $total rows. Every row of the column must land in exactly one of PDS_DOOR_CLASSES or PDS_DOOR_COMPUTED_BANDS; a row in neither is a class the COUNTS block cannot see, which is the silence this partition replaced. Unaccounted class(es): $(printf '%s' "$residual" | tr '\n' ' ')"
    errors=$((errors + 1))
  fi

  echo
  echo "COUNTS — derived from the rows above, never transcribed"
  echo "  THROUGH a required gate : $through of $total  ($DENOMINATOR_CONVENTION)"
  echo "    ->$through_names"
  echo "  IN-BEAM-REQUIRED        : $inbeam of $total  (gated; not priceable by an OS meter)"
  echo "  DEAD-DECLARATION        : $dead of $total"
  echo "  UNDISPOSED              : $undisposed of $total"
  echo "  ERROR rows              : $error_rows of $total  (rows the classifier could not classify)"
  echo "  BY LEDGER CLASS — the FULL declared vocabulary, INCLUDING the ones at zero:"
  printf '%s\n' "$ledger_lines" | sed '/^$/d'
  echo "  ACCOUNTED FOR           : $accounted of $total  (the eleven bands above, summed and asserted)"
  if [ -n "$residual" ]; then
    echo "  RESIDUAL (in no declared band):"
    printf '%s\n' "$residual" | sed 's/^/    /'
  else
    echo "  RESIDUAL (in no declared band): none"
  fi
  echo "  ERRORS                  : $errors"
  echo
  echo "WHAT THE DOORS DO AND DO NOT PROVE (PDS-D637): a green door gates the ARM'S OWN LOGIC"
  echo "  against regression. It does not gate the epic's record — record-parity's harness is"
  echo "  hermetic and reads zero live ledger rows."
  echo
  printf '%s\n' "$BLIND_SPOT"
  echo

  if [ -n "$error_lines" ]; then
    printf '::error::%s: unclassifiable or malformed rows:%s\n' "$SELF" "$error_lines" >&2
  fi

  if [ "$errors" -gt 0 ] || [ "$undisposed" -gt 0 ]; then
    cat >&2 <<MSG
::error::$SELF: $undisposed UNDISPOSED row(s) and $errors error row(s).

FAIL-CLOSED, AND THIS IS THE POINT. An instrument with no disposition is not
"probably fine" — it is a row of the price column nobody has computed. Dispose it
by adding a ledger row above with one of PDS-D637's five classes plus HUMAN-GATE,
carrying evidence that names a RUN or a FILE:LINE. A PRICE row needs a CPU figure
(user+sys) labelled LOCAL with the meter named — never a wall second, never a
projected CI number.

UNDISPOSED:$undisposed_names
MSG
    return 1
  fi

  echo "OK: every scripts/pds-*.{sh,exs} program is disposed."
  return 0
}

# ---------------------------------------------------------------------------
# --selftest — the fraud arm and the depth arms. No BEAM, no gate, no network.
# ---------------------------------------------------------------------------
# Leg B is deliberately NOT exercised here: it is evaluated against the REAL
# declared path sets, and a fixture tree cannot move those. This arm proves the
# half that the fraud attacks — leg A's three predicates and derived depth.
selftest() {
  local pass=0 fail=0 out tmp

  # A GLOBAL, not a local: the EXIT trap fires after this function's frame is
  # gone, and a trap that reads a dead local is an unbound-variable crash under
  # `set -u` — which would mask the arms' own verdict.
  PDS_DOOR_SELFTEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pds-door-census-selftest.XXXXXX")"
  tmp="$PDS_DOOR_SELFTEST_TMP"
  trap 'rm -rf "$PDS_DOOR_SELFTEST_TMP"' EXIT

  mkdir -p "$tmp/scripts" "$tmp/api/test/barkpark" "$tmp/api/test/barkpark_web/studio" "$tmp/api/lib"

  for s in pds-fx-three.sh pds-fx-four.sh pds-fx-inline.sh pds-fx-fraud.sh pds-fx-orphan.sh \
    pds-fx-nearcomment.sh pds-fx-nearread.sh pds-fx-trailing.sh pds-fx-port.sh \
    pds-fx-tail.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/scripts/$s"
  done
  printf '# fixture\n' >"$tmp/scripts/pds-fx-inbeam.exs"

  # THREE DOTS — api/test/barkpark/, the shape every real door uses today.
  cat >"$tmp/api/test/barkpark/three_test.exs" <<'EOF'
defmodule ThreeTest do
  use ExUnit.Case, async: false
  @three_rel "../../../scripts/pds-fx-three.sh"
  setup_all do
    three = Path.expand(@three_rel, __DIR__)
    {:ok, three: three, bash: System.find_executable("bash")}
  end
  test "runs", ctx do
    {_out, 0} = System.cmd(ctx.bash, [ctx.three], stderr_to_stdout: true)
  end
end
EOF

  # FOUR DOTS — api/test/barkpark_web/studio/. A hardcoded three-dot prefix
  # passes today and breaks SILENTLY on the first door placed here.
  cat >"$tmp/api/test/barkpark_web/studio/four_test.exs" <<'EOF'
defmodule FourTest do
  use ExUnit.Case, async: false
  @four_rel "../../../../scripts/pds-fx-four.sh"
  setup_all do
    four = Path.expand(@four_rel, __DIR__)
    {:ok, four: four}
  end
  test "runs", ctx do
    {_out, 0} = System.cmd("bash", [ctx.four])
  end
end
EOF

  # SINGLE-ARG Path.expand — resolved against the `mix test` cwd api/, so ONE
  # dot-dot, and the script is argv[2] of an interpreter-with-inline-program.
  cat >"$tmp/api/test/barkpark/inline_test.exs" <<'EOF'
defmodule InlineTest do
  use ExUnit.Case, async: false
  test "runs" do
    script = Path.expand("../scripts/pds-fx-inline.sh")
    prog = "print(1)"
    assert {_o, 0} = System.cmd("python3", ["-c", prog, script])
  end
end
EOF

  # IN-BEAM — Code.require_file. Gated, but not priceable by an OS meter.
  cat >"$tmp/api/test/barkpark/inbeam_test.exs" <<'EOF'
defmodule InbeamTest do
  use ExUnit.Case, async: false
  Code.require_file("../../../scripts/pds-fx-inbeam.exs", __DIR__)
  test "loaded", do: assert(true)
end
EOF

  # THE FRAUD — the literal names a REAL instrument, on a COMMENT line, in a file
  # that DOES call System.cmd. A leg-A predicate keyed on "System.cmd appears
  # somewhere in the file" passes this; all three predicates together do not.
  cat >"$tmp/api/test/barkpark/fraud_test.exs" <<'EOF'
defmodule FraudTest do
  use ExUnit.Case, async: false
  # the door is at "../../../scripts/pds-fx-fraud.sh" and is load-bearing
  @real_rel "../../../scripts/pds-fx-three.sh"
  test "runs something else" do
    {_o, 0} = System.cmd("bash", [Path.expand(@real_rel, __DIR__)])
  end
end
EOF

  # BOUND, EXECUTED BY NOTHING — a door pointed at nothing. Must ERROR.
  cat >"$tmp/api/test/barkpark/orphan_test.exs" <<'EOF'
defmodule OrphanTest do
  use ExUnit.Case, async: false
  @orphan_rel "../../../scripts/pds-fx-orphan.sh"
  test "reads it" do
    assert File.regular?(Path.expand(@orphan_rel, __DIR__))
  end
end
EOF

  # ---- THE PROXIMITY FRAUDS (PDS-D649, wave 45) ---------------------------
  # The shipped predicate spliced the call line plus the NEXT TWO LINES RAW into
  # a match window, which implements "bound and NEAR something executed". Each
  # of the three fixtures below is BOUND and NEVER EXECUTED, and each produced
  # LEGA-BOUND-EXEC — a THROUGH with a price, rc=0, ERRORS 0 — under that window.
  # Every one of them also carries a GENUINE door in the same file, so an arm
  # that merely declined everything nearby would not go green here.

  # FRAUD A — named ONLY in a COMMENT one line below an unrelated System.cmd.
  cat >"$tmp/api/test/barkpark/nearcomment_test.exs" <<'EOF'
defmodule NearCommentTest do
  use ExUnit.Case, async: false
  @near_rel "../../../scripts/pds-fx-nearcomment.sh"
  @real_a_rel "../../../scripts/pds-fx-three.sh"
  test "runs something else" do
    {_o, 0} = System.cmd("bash", [Path.expand(@real_a_rel, __DIR__)])
    # @near_rel is covered too, honest
  end
end
EOF

  # FRAUD B — only File.regular?'d, on a line ADJACENT to an unrelated
  # System.cmd. This is the orphan fixture above differing by ONE line of
  # proximity: the ERROR arm was one neighbour away from unreachable.
  cat >"$tmp/api/test/barkpark/nearread_test.exs" <<'EOF'
defmodule NearReadTest do
  use ExUnit.Case, async: false
  @nearread_rel "../../../scripts/pds-fx-nearread.sh"
  @real_b_rel "../../../scripts/pds-fx-three.sh"
  test "reads one, runs another" do
    {_o, 0} = System.cmd("bash", [Path.expand(@real_b_rel, __DIR__)])
    assert File.regular?(Path.expand(@nearread_rel, __DIR__))
  end
end
EOF

  # FRAUD C — a TRAILING `#` comment INSIDE the argument list. The tightest of
  # the three: it survives a WHOLE-LINE comment filter, so only a cut at the
  # first UNQUOTED `#` removes it.
  cat >"$tmp/api/test/barkpark/trailing_test.exs" <<'EOF'
defmodule TrailingTest do
  use ExUnit.Case, async: false
  @trailing_rel "../../../scripts/pds-fx-trailing.sh"
  @real_c_rel "../../../scripts/pds-fx-three.sh"
  test "runs something else" do
    {_o, 0} = System.cmd("bash", [
      Path.expand(@real_c_rel, __DIR__) # @trailing_rel is also run
    ])
  end
end
EOF

  # THE SECOND DIRECTION — an HONEST Port.open door whose argument list spans
  # FIVE lines. The 3-line window DECLINED this one (BOUND-UNEXEC), so a fix
  # that only declined harder would fail this arm. The span must reach further
  # than the window did AND stop at the closing paren.
  cat >"$tmp/api/test/barkpark/port_test.exs" <<'EOF'
defmodule PortDoorTest do
  use ExUnit.Case, async: false
  @port_rel "../../../scripts/pds-fx-port.sh"
  test "runs the door through a port" do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash")},
        [
          :binary,
          :exit_status,
          args: [Path.expand(@port_rel, __DIR__)]
        ]
      )
    assert is_port(port)
  end
end
EOF

  # FRAUD D — bound and named AFTER the closing paren, on the CLOSING LINE of a
  # real System.cmd. The span walk balances parens correctly and would still have
  # returned the WHOLE final line, so the old proximity window survived inside
  # the new predicate for exactly one line. It is the tightest of the four: the
  # token is on the same line as a genuine call, outside its argument list.
  cat >"$tmp/api/test/barkpark/tail_test.exs" <<'EOF'
defmodule TailTest do
  use ExUnit.Case, async: false
  @tail_rel "../../../scripts/pds-fx-tail.sh"
  @real_d_rel "../../../scripts/pds-fx-three.sh"
  test "runs one, merely reads the other on the closing line" do
    {_o, 0} = System.cmd("bash", [Path.expand(@real_d_rel, __DIR__)]); assert File.regular?(Path.expand(@tail_rel, __DIR__))
  end
end
EOF

  INSTRUMENT_LIST="$(cd "$tmp/scripts" && ls -1 pds-*.sh pds-*.exs | LC_ALL=C sort)"

  local saved_root="$SCAN_ROOT"
  SCAN_ROOT="$tmp"
  out="$(classify_refs || true)"
  SCAN_ROOT="$saved_root"

  check() {
    # $1 = label, $2 = expected KIND, $3 = basename
    local got
    got="$(printf '%s\n' "$out" | awk -F'\t' -v b="$3" '$4 == b { print $3 }' | LC_ALL=C sort -u | tr '\n' ',')"
    if [ "$got" = "$2," ]; then
      echo "  PASS  $1 ($3 -> $2)"
      pass=$((pass + 1))
    else
      echo "  FAIL  $1 ($3): expected [$2], got [${got%,}]"
      fail=$((fail + 1))
    fi
  }

  echo "$SELF --selftest — leg A only (leg B is evaluated against the REAL declared sets)"
  echo
  check "three dots, api/test/barkpark/" LEGA-BOUND-EXEC pds-fx-three.sh
  check "four dots, api/test/barkpark_web/studio/" LEGA-BOUND-EXEC pds-fx-four.sh
  check "single-arg Path.expand vs cwd api/, script as argv[2]" INLINE-EXEC pds-fx-inline.sh
  check "Code.require_file gets its OWN disposition" IN-BEAM-REQUIRE pds-fx-inbeam.exs
  check "THE FRAUD: comment naming a real instrument in a System.cmd file" COMMENT pds-fx-fraud.sh
  check "bound but executed by nothing" BOUND-UNEXEC pds-fx-orphan.sh
  check "FRAUD A: bound, named only in a COMMENT one line below a real System.cmd" \
    BOUND-UNEXEC pds-fx-nearcomment.sh
  check "FRAUD B: bound, only File.regular?'d NEXT TO an unrelated System.cmd" \
    BOUND-UNEXEC pds-fx-nearread.sh
  check "FRAUD C: bound, named only in a TRAILING # comment INSIDE the arg list" \
    BOUND-UNEXEC pds-fx-trailing.sh
  check "FRAUD D: bound, named AFTER the closing paren on the call's own line" \
    BOUND-UNEXEC pds-fx-tail.sh
  check "SECOND DIRECTION: an HONEST Port.open door spanning FIVE lines" \
    LEGA-BOUND-EXEC pds-fx-port.sh

  # The fraud arm, said the other way round: the file DOES contain System.cmd,
  # so the weaker predicate would have admitted it.
  if grep -q 'System\.cmd' "$tmp/api/test/barkpark/fraud_test.exs"; then
    echo "  PASS  the fraud fixture DOES contain System.cmd — the weak predicate would have passed it"
    pass=$((pass + 1))
  else
    echo "  FAIL  the fraud fixture lost its System.cmd; the arm proves nothing"
    fail=$((fail + 1))
  fi

  # The class vocabulary is SIX, never three.
  local nclasses
  nclasses="$(printf '%s\n' "$PDS_DOOR_CLASSES" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$nclasses" -eq 6 ] && class_known CONTENT-RED && class_known HUMAN-GATE && ! class_known FENCE; then
    echo "  PASS  the class vocabulary is 6 (D637's five plus HUMAN-GATE) and 'FENCE' is not one"
    pass=$((pass + 1))
  else
    echo "  FAIL  the class vocabulary is $nclasses, or admits a class it must not"
    fail=$((fail + 1))
  fi

  # THE ENUMERATOR MUST NOT DIE SILENTLY. One `ls` over two globs inherits a
  # non-zero rc when EITHER is unmatched, and `set -e` then aborted the run
  # having printed nothing at all. The `if` is what makes this arm SURVIVABLE:
  # under the shipped enumerator the assignment fails and the else branch fires
  # instead of killing the selftest — which is exactly how this arm REDS on a
  # revert rather than taking the whole run down with it.
  local shonly enum_out enum_rc saved_root2
  shonly="$tmp/shonly"
  mkdir -p "$shonly/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$shonly/scripts/pds-fx-shonly.sh"
  saved_root2="$SCAN_ROOT"
  SCAN_ROOT="$shonly"
  enum_out=''
  if enum_out="$(instruments)"; then enum_rc=0; else enum_rc=$?; fi
  if [ "$enum_rc" -eq 0 ] && [ "$enum_out" = 'pds-fx-shonly.sh' ]; then
    echo "  PASS  the enumerator survives a .sh-only tree (no pds-*.exs): rc=0, [$enum_out]"
    pass=$((pass + 1))
  else
    echo "  FAIL  the enumerator on a .sh-only tree gave rc=$enum_rc, [$enum_out] —"
    echo "        a NON-ZERO rc here aborts the whole run under set -e having printed"
    echo "        NOTHING, which is the silent failure this census exists to catch"
    fail=$((fail + 1))
  fi
  SCAN_ROOT="$saved_root2"

  # ---- THE LEDGER ARMS ----------------------------------------------------
  # Everything above tests leg A. These test what the LEDGER does, end to end,
  # through the REAL run_census — over a two-instrument fixture tree so the arms
  # stay cheap enough to keep --selftest a fraction of a second. Leg B is stubbed
  # INSIDE a command substitution (it cannot leak into a real run, and the real
  # leg B answers against declared path sets no fixture name is in), which is the
  # one thing a fixture tree cannot move. Each arm below REDS when its own repair
  # is reverted — a repair whose own selftest cannot fail is this epic's law
  # broken.
  local croot
  croot="$tmp/census"
  mkdir -p "$croot/scripts" "$croot/api/test/barkpark"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$croot/scripts/pds-fx-through.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$croot/scripts/pds-fx-shut.sh"
  cat >"$croot/api/test/barkpark/census_door_test.exs" <<'EOF'
defmodule CensusDoorTest do
  use ExUnit.Case, async: false
  @through_rel "../../../scripts/pds-fx-through.sh"
  test "runs the door" do
    {_o, 0} = System.cmd("bash", [Path.expand(@through_rel, __DIR__)])
  end
end
EOF

  CENSUS_OUT=''
  CENSUS_RC=0

  census_run() {
    # $1 = disposition ledger, $2 = price ledger. Sets CENSUS_OUT / CENSUS_RC.
    local saved_scan="$SCAN_ROOT" saved_d="$PDS_DOOR_DISPOSITIONS" saved_p="$PDS_DOOR_PRICES"
    SCAN_ROOT="$croot"
    PDS_DOOR_DISPOSITIONS="$1"
    PDS_DOOR_PRICES="$2"
    # The `if` is what keeps a red census from killing the selftest under set -e.
    # The patterns are written `(…)` rather than `…)`: an unbalanced `)` inside
    # `$( … )` ends the substitution early, which is a parse error, not a wrong
    # answer — but it is a parse error that only fires at RUN time.
    if CENSUS_OUT="$(
      leg_b() { case "$1" in (*/pds-fx-through.sh) printf 'true' ;; (*) printf 'false' ;; esac; }
      run_census 2>&1
    )"; then CENSUS_RC=0; else CENSUS_RC=$?; fi
    SCAN_ROOT="$saved_scan"
    PDS_DOOR_DISPOSITIONS="$saved_d"
    PDS_DOOR_PRICES="$saved_p"
  }

  census_arm() {
    # $1 = label, $2 = expected rc, $3.. = substrings the output MUST contain
    local label="$1" want="$2" missing='' s
    shift 2
    for s in "$@"; do
      case "$CENSUS_OUT" in
        *"$s"*) ;;
        *) missing="$missing [$s]" ;;
      esac
    done
    if [ "$CENSUS_RC" = "$want" ] && [ -z "$missing" ]; then
      echo "  PASS  $label (rc=$CENSUS_RC)"
      pass=$((pass + 1))
    else
      echo "  FAIL  $label: rc=$CENSUS_RC (wanted $want), missing:$missing"
      fail=$((fail + 1))
    fi
  }

  local d_ok p_ok
  d_ok="$(printf 'pds-fx-shut.sh\tENVIRONMENT\tfixture: needs a credential it will never have.')"
  p_ok="$(printf 'pds-fx-through.sh\tCPU=0.01+0.01=0.02s LOCAL meter=/usr/bin/time -p around bash -c load1=1.00 2026-08-04 (fixture)')"

  # CONTROL — the harness itself can be green, so a red arm below means the
  # defect, not the harness.
  census_run "$d_ok" "$p_ok"
  census_arm "LEDGER CONTROL: the fixture census is GREEN" 0 \
    'THROUGH a required gate : 1 of 2' 'ERRORS                  : 0'

  # ORPHAN — a live row asserting a refusal for an instrument the tree says is
  # THROUGH. Before this slice it was INVISIBLE: byte-identical output, rc=0.
  census_run "$(printf '%s\npds-fx-through.sh\tENVIRONMENT\tfixture: contradicts the wiring.' "$d_ok")" "$p_ok"
  census_arm "ORPHAN FIRES: a live row for a COMPUTED instrument reds, count unmoved" 1 \
    'ORPHANED DISPOSITION' 'THROUGH a required gate : 1 of 2'

  # RETIREMENT EXEMPTS — the same row, retired, with what superseded it.
  census_run "$(printf '%s\npds-fx-through.sh\tRETIRED-ENVIRONMENT\tsuperseded 2026-08-04: the door was wired; leg A + leg B now compute THROUGH.' "$d_ok")" "$p_ok"
  census_arm "RETIREMENT EXEMPTS: a RETIRED- row is invisible to the live path" 0 \
    'ERRORS                  : 0' 'THROUGH a required gate : 1 of 2'

  # ...AND CANNOT BE ABUSED — this is the direction that is not vacuous. With the
  # door SHUT, its only row retired, the instrument is UNDISPOSED and the run
  # reds: you cannot retire the only explanation of a shut door.
  census_run "$(printf 'pds-fx-shut.sh\tRETIRED-ENVIRONMENT\tsuperseded 2026-08-04: by nothing at all.')" "$p_ok"
  census_arm "RETIREMENT IS NOT A BYPASS: a retired-only row on a SHUT door reds UNDISPOSED" 1 \
    'UNDISPOSED              : 1 of 2'

  # A RETIRED ROW MUST STILL SAY WHAT SUPERSEDED IT.
  census_run "$(printf '%s\npds-fx-through.sh\tRETIRED-ENVIRONMENT\t' "$d_ok")" "$p_ok"
  census_arm "A RETIRED ROW WITH EMPTY EVIDENCE REDS" 1 \
    'RETIRED row with EMPTY evidence'

  # TWO LIVE ROWS FOR ONE BASENAME — the first silently wins.
  census_run "$(printf 'pds-fx-shut.sh\tNOT-YET-BUILT\tfixture: the contradictory row above the true one.\n%s' "$d_ok")" "$p_ok"
  census_arm "A DUPLICATE LIVE DISPOSITION KEY REDS" 1 \
    'DUPLICATE DISPOSITION KEY'

  # A THROUGH PRICE OF PROSE. Note the count: the shape verdict never touches it.
  census_run "$d_ok" "$(printf 'pds-fx-through.sh\tit is free, trust me')"
  census_arm "A PROSE THROUGH PRICE REDS, and the THROUGH count does NOT move" 1 \
    'a price must carry CPU=' 'THROUGH a required gate : 1 of 2'

  # A D648-SHAPED PRICE WITH NO LOAD STAMP (PDS-D656).
  census_run "$d_ok" "$(printf 'pds-fx-through.sh\tCPU=0.01+0.01=0.02s LOCAL meter=/usr/bin/time -p around bash -c 2026-08-04 (fixture)')"
  census_arm "A PRICE WITH NO load1= STAMP REDS, and the THROUGH count does NOT move" 1 \
    'must carry its own load1=<n> stamp' 'THROUGH a required gate : 1 of 2'

  # NO PRICE ROW AT ALL — the deleted silent default.
  census_run "$d_ok" ''
  census_arm "AN ABSENT THROUGH PRICE IS UNPRICED and REDS" 1 \
    'UNPRICED' 'THROUGH a required gate : 1 of 2'

  # ---- THE PRICE-LEDGER ORPHAN DIRECTION (wave 47) ------------------------
  # A price row for an instrument that is NOT THROUGH. Before this slice it was
  # invisible in exactly the way the disposition orphan was: rc=0, ERRORS 0, and
  # a COUNTS diff producing no output at all.
  census_run "$d_ok" "$(printf '%s\npds-fx-shut.sh\tCPU=9.99+9.99=19.98s LOCAL meter=/usr/bin/time -p around bash -c load1=1.00 2026-08-04 (fixture: a price nobody pays)' "$p_ok")"
  census_arm "ORPHANED PRICE FIRES: a price row for a non-THROUGH instrument reds, count unmoved" 1 \
    'ORPHANED PRICE' 'pds-fx-shut.sh' 'THROUGH a required gate : 1 of 2'

  # THE CROSS-LEDGER CONTRADICTION, which is why the key is `class != THROUGH`
  # and NOT `computed == yes`: this row is computed='no' (it came from the
  # disposition ledger's terminal else branch), so a computed-keyed predicate
  # would skip it and leave two ledgers naming one price silent.
  census_run \
    "$(printf 'pds-fx-shut.sh\tPRICE\tCPU=0.01+0.01=0.02s LOCAL meter=/usr/bin/time -p around bash -c load1=1.00 2026-08-04 (fixture: its OWN figure)')" \
    "$(printf '%s\npds-fx-shut.sh\tCPU=9.99+9.99=19.98s LOCAL meter=/usr/bin/time -p around bash -c load1=1.00 2026-08-04 (fixture: a SECOND, contradicting figure)' "$p_ok")"
  census_arm "CROSS-LEDGER CONTRADICTION: a PRICE-classed row (computed=no) with a second figure reds" 1 \
    'ORPHANED PRICE' 'classed it PRICE, not THROUGH'

  # THE RETIRE COSTUME ON AN ORPHAN. This row never reaches price_shape_error at
  # all (its instrument is shut, so no shape check runs on it) — only the orphan
  # lookup can see it, and only because it reads through `ledger_field`. Swapping
  # that one token for `live_ledger_field` takes this arm silent, which is
  # retirement becoming an EXEMPTION in a ledger that has no retire shape.
  census_run "$d_ok" "$(printf '%s\npds-fx-shut.sh\tRETIRED-CPU=0.01+0.01=0.02s LOCAL meter=/usr/bin/time -p around bash -c load1=1.00 2026-08-04 (fixture)' "$p_ok")"
  census_arm "A RETIRE COSTUME DOES NOT EXEMPT AN ORPHANED PRICE (ledger_field, not live_)" 1 \
    'ORPHANED PRICE' 'pds-fx-shut.sh'

  # RETIRED- IN THE PRICE LEDGER, on a genuinely THROUGH row. On main this passed
  # EVERY shape arm — the globs floated — and was printed as a LIVE price.
  census_run "$d_ok" "$(printf 'pds-fx-through.sh\tRETIRED-CPU=0.01+0.01=0.02s LOCAL meter=/usr/bin/time -p around bash -c load1=1.00 2026-08-04 (fixture)')"
  census_arm "A RETIRED- PRICE IS REFUSED, and the THROUGH count does NOT move" 1 \
    'a price cannot be RETIRED' 'THROUGH a required gate : 1 of 2'

  # THE ANCHOR ITSELF, said without the word RETIRED: any prefix at all in front
  # of CPU= is refused now, so the repair is the anchor and not a RETIRED- filter.
  census_run "$d_ok" "$(printf 'pds-fx-through.sh\troughly CPU=0.01+0.01=0.02s LOCAL meter=/usr/bin/time -p around bash -c load1=1.00 2026-08-04 (fixture)')"
  census_arm "AN UNANCHORED PREFIX IN FRONT OF CPU= IS REFUSED" 1 \
    'a price must carry CPU=' 'THROUGH a required gate : 1 of 2'

  # ---- THE PARTITION (wave 47) --------------------------------------------
  # The full vocabulary, INCLUDING the classes at zero, plus the summed and
  # asserted ACCOUNTED FOR line. HUMAN-GATE at zero is the arm that matters: a
  # `uniq -c` remedy prints five lines here and hides the sixth.
  census_run "$d_ok" "$p_ok"
  census_arm "THE PARTITION PRINTS THE FULL VOCABULARY INCLUDING ZEROES, and sums to the population" 0 \
    'BY LEDGER CLASS' 'HUMAN-GATE              : 0 of 2' 'ENVIRONMENT             : 1 of 2' \
    'ACCOUNTED FOR           : 2 of 2' 'RESIDUAL (in no declared band): none'

  # AND THE SUM IS ASSERTED, not merely printed. Reached by shrinking the
  # DECLARED band list rather than by inventing a class — a class outside the
  # vocabulary cannot be smuggled through a fixture ledger (class_known refuses
  # it into ERROR, which is itself a declared band), so the honest way to make a
  # row land in no band is to take a band away. rc must FOLLOW.
  local saved_bands
  saved_bands="$PDS_DOOR_COMPUTED_BANDS"
  PDS_DOOR_COMPUTED_BANDS='IN-BEAM-REQUIRED
DEAD-DECLARATION
UNDISPOSED
ERROR'
  census_run "$d_ok" "$p_ok"
  PDS_DOOR_COMPUTED_BANDS="$saved_bands"
  census_arm "THE SUM IS ASSERTED: a row in no declared band reds and is NAMED" 1 \
    'PARTITION SHORTFALL' 'ACCOUNTED FOR           : 1 of 2' 'Unaccounted class(es): THROUGH'

  # AND THE RESIDUAL DETECTOR ITSELF, called directly — the shortfall it names
  # cannot be reached through a fixture ledger (every ledger class it could carry
  # is by definition IN the vocabulary), so it is exercised the way class_known
  # is: on a synthetic tally.
  local resid_bad resid_ok
  resid_bad="$(unaccounted_classes "$(printf 'THROUGH\nENVIRONMENT\nUNDECLARED-BAND\nHUMAN-GATE')")"
  resid_ok="$(unaccounted_classes "$(printf 'THROUGH\nENVIRONMENT\nERROR\nUNDISPOSED\nPRICE')")"
  if [ "$resid_bad" = 'UNDECLARED-BAND' ] && [ -z "$resid_ok" ]; then
    echo "  PASS  the residual band names a class in NEITHER declared list, and is empty otherwise"
    pass=$((pass + 1))
  else
    echo "  FAIL  the residual band reported [$resid_bad] for a tally carrying UNDECLARED-BAND"
    echo "        and [$resid_ok] for a wholly-declared one — a partition whose residual cannot"
    echo "        fire is a sum that agrees with itself"
    fail=$((fail + 1))
  fi

  # EXACT-LINE COUNTING, never a substring: the tally is counted with `[ = ]` per
  # line, so a band name that is a prefix of another cannot inflate it.
  local tally_n tally_zero
  tally_n="$(class_tally_count "$(printf 'PRICE\nPRICE-ADJACENT\nPRICE')" PRICE)"
  tally_zero="$(class_tally_count "$(printf 'THROUGH\nERROR')" HUMAN-GATE)"
  if [ "$tally_n" = '2' ] && [ "$tally_zero" = '0' ]; then
    echo "  PASS  the class tally counts EXACT lines (PRICE=2 beside a PRICE-ADJACENT row) and returns 0, not blank"
    pass=$((pass + 1))
  else
    echo "  FAIL  the class tally counted PRICE=$tally_n (wanted 2) / HUMAN-GATE=$tally_zero (wanted 0)"
    fail=$((fail + 1))
  fi

  # THE VOCABULARY BYPASS. class_known must refuse RETIRED-* BY ITS OWN ARM, not
  # by absence from the list: adding RETIRED-ENVIRONMENT to PDS_DOOR_CLASSES took
  # a SHUT door to full green, and only the arm counting the vocabulary saw it.
  local saved_classes
  saved_classes="$PDS_DOOR_CLASSES"
  PDS_DOOR_CLASSES="$PDS_DOOR_CLASSES
RETIRED-ENVIRONMENT"
  if ! class_known RETIRED-ENVIRONMENT && class_known ENVIRONMENT; then
    echo "  PASS  class_known REFUSES RETIRED-* even when the vocabulary carries it"
    pass=$((pass + 1))
  else
    echo "  FAIL  class_known admitted RETIRED-ENVIRONMENT once it was added to the vocabulary —"
    echo "        absence from a list is not a guard, and this is the ONLY working bypass"
    fail=$((fail + 1))
  fi
  PDS_DOOR_CLASSES="$saved_classes"

  echo
  printf '%s\n' "$BLIND_SPOT"
  echo
  echo "SELFTEST: $pass PASS / $fail FAIL of $((pass + fail)) arms"
  if [ "$fail" -gt 0 ]; then
    echo "SELFTEST RED — exit 1"
    return 1
  fi
  echo "SELFTEST GREEN — exit 0"
  return 0
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------
INSTRUMENT_LIST=''
PDS_DOOR_SELFTEST_TMP=''

mode="${1:---check}"
case "$mode" in
  --check)
    INSTRUMENT_LIST="$(instruments)"
    run_census
    ;;
  --selftest)
    selftest
    ;;
  --list-refs)
    INSTRUMENT_LIST="$(instruments)"
    classify_refs
    ;;
  --help | -h)
    sed -n '3,60p' "${BASH_SOURCE[0]}"
    ;;
  *)
    echo "$SELF: unknown argument '$mode'" >&2
    echo "usage: $0 [--check|--selftest|--list-refs|--help]" >&2
    exit 2
    ;;
esac
