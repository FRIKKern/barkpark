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
# list, which survives a whole-line comment filter. The window was wrong in the
# OTHER direction too: a genuine five-line `Port.open` door classified
# BOUND-UNEXEC — an honest door declined — so the repair was never "decline
# more". It is `arg_span`: walk from the opening paren until parens balance.
#
# AND THE SELFTEST WAS GREEN ON ALL OF IT, because its fraud fixture
# (`pds-fx-fraud.sh`) forgets to BIND — the literal is on a comment line and
# never `@attr`-bound, so it exits at the COMMENT branch and never reaches the
# execution test at all. A fixture that cannot reach the predicate cannot
# exercise it. The five wave-45 arms all bind first, and each REDS on revert.
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

# ---------------------------------------------------------------------------
# THE DISPOSITION LEDGER — why a non-THROUGH instrument is not through.
# ---------------------------------------------------------------------------
# `<basename><TAB><CLASS><TAB><evidence>`. Every row's evidence names either a
# RUN (verdict + exit code) or a FILE:LINE in the instrument's own source. A row
# whose evidence is empty, or whose class is outside the vocabulary above, is a
# hard error — a disposition without evidence is the vacuous green this epic
# exists to remove. Absent rows are UNDISPOSED and red the run.
PDS_DOOR_DISPOSITIONS='pds-charter-ledger-sweep.sh	CONTENT-RED	by run 2026-08-03: `--selftest` rc=1 "RED: an UNRESOLVED-CLAIM ARRIVAL is a charter claim nobody has adjudicated"; blocked on scripts/pds-charter-ledger-adjudication.md, not on price (CPU 3.42 s LOCAL)
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
# `<basename><TAB>CPU=<user>+<sys>=<total>s LOCAL meter=<meter> …`. A THROUGH row
# with no entry prints `price=UNMEASURED-LOCAL` rather than borrowing a number:
# an unmeasured price is a missing fact, never a zero.
PDS_DOOR_PRICES='pds-door-census.sh	CPU=0.91+2.41=3.32s LOCAL meter=/usr/bin/time -p around bash -c load1=41.63 2026-08-03 (--check, rc=0). Its gated arm is --selftest at CPU=0.04+0.12=0.16s; the rider also runs --check once and a one-row mutant once.
pds-status-only-residue.exs	CPU=0.61+0.21=0.82s LOCAL meter=/usr/bin/time -p around bash -c load1=26.44 2026-08-03 (--selftest, 15/15 arms)
pds-record-parity.test.sh	CPU=1.45+3.00=4.45s LOCAL meter=/usr/bin/time -p around bash -c load1=26.44 2026-08-03 (76 checks, 0 failures)
pds-elixir-receipt-census.exs	UNMEASURED-LOCAL (plain+mutant+refusal is the expensive arm; its `--selftest` is separately disqualified at 210 s leaf CPU, and D646 shows even that understates the wall a gate would enforce)'

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
            if (depth <= 0) return span
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
  has_line "$PDS_DOOR_CLASSES" "$1"
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
  local b kinds legA legB class evidence price row
  local through=0 undisposed=0 errors=0 inbeam=0 dead=0
  local through_names="" undisposed_names="" error_lines=""

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
      [ -n "$price" ] || price='price=UNMEASURED-LOCAL'
      evidence="$price"
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
      class="$(ledger_field "$PDS_DOOR_DISPOSITIONS" "$b" 2)"
      evidence="$(ledger_field "$PDS_DOOR_DISPOSITIONS" "$b" 3)"
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
        case "$evidence" in
          *'CPU='*'LOCAL'*'meter='*) ;;
          *)
            error_lines="$error_lines
  $b: a PRICE row must carry CPU=<user>+<sys>=<total>s LOCAL meter=<name> (PDS-D648). It carries: $evidence"
            class='ERROR'
            ;;
        esac
      fi
    fi

    if [ "$legB" = 'ERROR' ]; then
      error_lines="$error_lines
  $b: leg B could not be evaluated — elixir-path-escape-check.sh --match test gave no verdict."
      class='ERROR'
    fi

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
      ERROR) errors=$((errors + 1)) ;;
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

  echo
  echo "COUNTS — derived from the rows above, never transcribed"
  echo "  THROUGH a required gate : $through of $total  ($DENOMINATOR_CONVENTION)"
  echo "    ->$through_names"
  echo "  IN-BEAM-REQUIRED        : $inbeam of $total  (gated; not priceable by an OS meter)"
  echo "  DEAD-DECLARATION        : $dead of $total"
  echo "  UNDISPOSED              : $undisposed of $total"
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
    pds-fx-nearcomment.sh pds-fx-nearread.sh pds-fx-trailing.sh pds-fx-port.sh; do
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
