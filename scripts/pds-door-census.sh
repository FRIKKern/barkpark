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
# CPU = user + sys, LABELLED WITH THE HOST IT WAS TAKEN ON, with the meter
# named. Never wall: a fixed workload's wall spanned 5.8x at essentially
# constant load on this host, so a wall second quotes the host's other tenants,
# not the door. Never user alone: on the hetzner door `sys` EXCEEDS `user`, so
# user-only understates by 2.1x as a pure CPU fact.
#
# THE HOST AXIS IS NOW REQUIRED AND HAS TWO VALUES (wave 48): LOCAL or FOREIGN.
# `price_shape_error` refuses a price wearing NEITHER, and `--measure` DERIVES
# the label from the host it actually ran on (GITHUB_ACTIONS/CI => FOREIGN) so
# the label descends from the run rather than from whoever typed the row.
#
# WHAT IS TRUE ABOUT THIS COLUMN TODAY, STATED EXACTLY:
#   * the INSTRUMENT exists — `--measure <basename>` meters a door and prints a
#     pasteable row, so a price can descend from a meter this file drove;
#   * the AXIS exists — a FOREIGN row is a legal, checked shape;
#   * and NO FOREIGN PRICE HAS BEEN TAKEN. Every figure below is a loaded
#     10-core Apple-Silicon mac, labelled LOCAL. Not "not yet": REFUSED, for a
#     measured reason, below.
#
# THE FOREIGN PRICE IS REFUSED, AND THIS IS THE REASON (PDS-D689, wave 48)
# -----------------------------------------------------------------------
# A price is a fact a third party can RE-OPEN. Wave 48 measured the whole
# citation surface a runner-taken row could cite, against live GitHub:
#   * workflow LOGS are HTTP 403 to an unauthenticated caller at EVERY age
#     (403 on a 23-day-old run and on a 100-day-old one alike), and 410 Gone at
#     ~90 days even to an authenticated one;
#   * the anon web per-step log URL that the job page itself embeds returns 404;
#   * ARTIFACTS are 401 anon, and `.github/workflows/ci.yml:141` pins
#     retention-days 14, so the receipt expires before the price does;
#   * `git grep -nE 'nproc|loadavg|uptime|/usr/bin/time' origin/main -- .github`
#     is EMPTY — no workflow emits a host measurement at all;
#   * the durable anonymous surfaces (the run JSON and the run's jobs LIST, both
#     still 200 at 100 days) carry WALL timings ONLY, which PDS-D648 forbids
#     outright as a price.
# So a runner-taken figure would cite an artifact NOBODY can re-open, and a
# pasted figure and a metered one are IDENTICAL BYTES in this ledger —
# `price_shape_error` matches bytes and can never see provenance. Taking the
# price anyway would put exactly the fraud this epic files INTO the column the
# epic built to end it. The row is not written. When a workflow emits a host
# measurement onto a durable anonymous surface, `--measure` is already the
# instrument that takes it.
#
# THE LOAD STAMPS BELOW ARE NOT AN ARTIFACT (PDS-D698, wave 48)
# ------------------------------------------------------------
# A doubt was filed that the four large stamps (41.63 / 79.23 / 24.26 / 26.44)
# were `tr`-mangled decimals rather than measurements. RULED OUT ON TWO LEGS,
# and the second is weaker than the first — said here rather than closed with
# one sentence:
#   (a) MECHANISM, decisive: the proposed `tr -d ,` mangling DESTROYS the
#       decimal point (a true 33.64 comes out as the integer `3364`). All four
#       suspect stamps carry a dot and exactly two decimals, so not one of them
#       is that artifact. This leg closes all four.
#   (b) PLAUSIBILITY, partial: the "implausible" premise was taken on a QUIET
#       host. Under wave load this 10-CPU host sustained load1 47.43 / 46.84 /
#       46.84 / 45.97 / 45.89, which brackets 41.63, 24.26 and 26.44 directly.
#       It does NOT reach 79.23 — that stamp is only within 1.7x of anything
#       observed here and was never itself observed. 79.23 stands on leg (a)
#       alone.
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
#   pds-door-census.sh --measure <basename> [arg...]   # meter a door, print a row
#   pds-door-census.sh --measure <basename> --via '<cmd>'  # meter an arbitrary arm
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
LIBRARY-MODULE
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
#
# PRICE IS THE PRICED-BUT-UNGATED HOLDING PEN, AND THAT IS THE MECHANISM BEHIND
# THE ONLY TWO ROTTEN FIGURES IN THE WHOLE COLUMN (wave 49). Sort the six
# committed price literals — n=6, the FOUR rows of PDS_DOOR_PRICES plus the TWO
# PRICE-classed dispositions here — by WHICH LEDGER HOLDS THEM and the
# separation is 6/6 perfect. Every PDS_DOOR_PRICES row is THROUGH a required
# gate ("THROUGH a required gate : 4 of 20" in the COUNTS block), and all four
# reproduce at a matched load stamp. Both PRICE-classed dispositions are through
# NO door — nothing required runs them — and BOTH were wrong by 1.5x and 17x.
# A THROUGH price is re-derived by reality on every merge: the gate executes the
# instrument, so the number is continuously contradictable. A PRICE-classed
# price is a figure for a workload nothing ever runs, so no gate can disagree
# with it and it rots undisturbed. A PRICE DESCENDS FROM A MEASUREMENT ONLY IF
# SOMETHING RE-TAKES IT — which is why `--measure` exists, and why the two rows
# below carry three trials each with their own load stamps instead of one
# hand-typed figure.
#
# AND THE PDS-D692 CLAUSE MANDATING A WALL FIGURE BESIDE THE CPU PRICE IS
# REFUSED HERE, IN WRITING, ON A MEASUREMENT (wave 49). D692 scopes its own
# mandate to PORT-CHILD riders — a meter wrapped around a BEAM that fans out to
# child BEAMs, where the CPU record genuinely goes blind (PDS-D633/D646, quoted
# in the METER BLIND SPOT note above). Both rows below are plain bash harnesses
# whose entire cost is direct-descendant CPU, and the `times` builtin is NOT
# blind to those: measured this wave,
#   LC_ALL=C bash -c <busy-loop child, output discarded>; times
# printed `0m0.001s 0m0.002s` for the metering shell and `0m0.739s 0m0.072s` for
# ITS CHILDREN, and `measure_sum` awk-accumulates over BOTH records. Paying the
# clause here would mean editing `run_measure` AND relaxing the required refute
# at api/test/barkpark/pds_door_census_test.exs:384 — weakening a required gate
# to add a figure that is, on a shared host, not a property of the door at all
# (a fixed workload swung 5.8x at constant load). The refuse is the ruling; the
# rider is not touched.
PDS_DOOR_DISPOSITIONS='pds-charter-ledger-sweep.sh	CONTENT-RED	by run 2026-08-04 at 683c2f00a: `--check` rc=1 "RED: an UNRESOLVED-CLAIM ARRIVAL is a charter claim nobody has adjudicated" (71 arrivals — the figure MOVES on every charter merge, because the lens is mined FROM the charter: 41 -> 45 -> 59 -> 71 across four merges, and the row read 59 while the sweep at that same commit printed 71); `--selftest` is rc=0 (3 of 3) and no longer hostage to the corpus; blocked on scripts/pds-charter-ledger-adjudication.md, not on price (CPU 3.42 s LOCAL)
pds-record-parity.sh	RED-BY-DESIGN-REPORTER	by run 2026-08-03: `--selftest` rc=3 "unknown argument" — the flag does not exist; its only non-vacuous axis resolves task ids against the LIVE ledger and is red by design. A reporter must never carry a required check name.
pds-window-sentinel.sh	NOT-YET-BUILT	source declares THREE verbs — `sample`, `watch`, `preflight` — cited as the WHOLE USAGE run (scripts/pds-window-sentinel.sh:63-65), and `sample` is the DEFAULT (`main()` opens `local cmd="${1:-sample}"`), so the omitted verb was also the most-used path. THE REASON WAS REFUTED AND REPLACED, NOT THE VERDICT: this row previously read "only `watch` and `preflight`" off a citation of :48-49 — a window one line too narrow, which excluded the very line that refutes it. That defect never reddened anything, because the lines it named were in range, non-blank, and said exactly what the claim said; tooling/doc-truth now detects the class (an exhaustive claim over a clipped run) and pins it as lineref-sweep selftest arms (e)/(f). NOT-YET-BUILT is RE-DERIVED on its own second clause and UPHELD: the file names no selftest anywhere (zero matches for selftest and for --check), and its documented exit contract (0 GO / 1 STAND-DOWN / 2 probe-failed) grades the HOST it samples, not the instrument — exit 2 means measured nothing, never the tool is broken. A host-facing exit contract is not a pass/fail selftest, so there is still nothing here a required gate could run.
pds-ledger-census_test.sh	PRICE	CPU=22.96+3.31=26.27s LOCAL meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=10 load1=7.30 2026-08-05 (no arguments, rc=0) — RE-TAKEN BY `--measure`, never by hand: 3 trials gave 26.27s at load1=7.30, 22.73s at load1=9.20, 22.80s at load1=7.32, all cpus=10. The OBSERVED BAND is 22.73-26.27 s CPU across load1 7.30-9.20, a 15.6% spread, and the row deliberately quotes the HIGH end of its own band, because the one direction a price column must not err is making an expensive thing look gate-able. It replaces 33.44+6.89=40.33s at load1=24.26, hand-typed through /usr/bin/time -p on 2026-08-03 and 1.53-1.77x this band. That figure was never re-derived by anything: no required gate runs this instrument, so nothing could contradict it. QUOTED AGAINST ITS OWN STAMP ONLY (PDS-D656) — this band is NOT poolable with the pds-scratch-target_test.sh band below, which was taken at systematically different loads, and it is NOT a quiet-host figure: the host carried 23 users at load averages 5,21 4,00 3,99 when the trials began. NOT VACUOUS: `--measure` discards subject output, so the full arm set was shown by a SEPARATE un-metered run — rc=0, `SELFTEST PASS: 173 checks.`; this harness prints NO failure(s) line on the green path at all (its counter prints only on the red path at :1400-1401), so 173 checks is the arm evidence in its place. Still the SECOND tiering case at ~23-26 s CPU on a 2-4 vCPU runner, which is why the class does not move.
pds-scratch-target_test.sh	PRICE	CPU=0.24+0.30=0.54s LOCAL meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=10 load1=9.56 2026-08-05 (no arguments, rc=0) — RE-TAKEN BY `--measure`, never by hand: 3 trials gave 0.54s at load1=9.56, 0.51s at load1=7.32, 0.54s at load1=6.76, all cpus=10; observed band 0.51-0.54 s CPU across load1 6.76-9.56, a 5.9% spread, high end quoted. It replaces 4.83+4.08=8.91s at load1=79.23, hand-typed 2026-08-03 and 16.5-17.5x this band — and the USER leg alone read 4.83 s stamped against 0.23-0.24 s measured, ~20x, which contention cannot manufacture: user CPU is work. NOT VACUOUS: a separate un-metered run exits 0 and prints `---- 0 failure(s)` then `SCRATCH TEST PASSED`, with 32 PASS / 0 FAIL arms and zero skips. THE STATED REASON MOVED WITH THE FIGURE, because a repaired number under an unrepaired justification still asserts what no measurement produced: the reason this row used to carry — that hermeticity on a runner WITHOUT local Postgres is unproven here — is REFUTED BY RUN. The harness names no Postgres binary anywhere in its source (zero matches for psql, pg_ctl, initdb or postgres; it drives two fake roots and a stub barkpark it writes itself) and it exits 0 with the same 32 PASS / 0 FAIL under PATH=/usr/bin:/bin:/usr/sbin:/sbin, with no Postgres reachable. WHAT SURVIVES IS THE CLASS, NOT ITS OLD REASON, and the class is now itself in doubt: 0.54 s is not a price that keeps any door shut, so this row is PRICE today only because nothing required runs it. The class move is NOT taken here — price_rows is exactly 2 against a required `assert length(price_rows) >= 2` (api/test/barkpark/pds_door_census_test.exs:344), so re-classing reds a required gate and must land WITH its rider in one commit. Filed as pds-w49-scratch-target-class-vs-its-own-price.
pds-live-hetzner-placement-group.sh	ENVIRONMENT	by run 2026-08-03: `--selftest` rc=3 "REFUSE — needs one WORKING credential"; needs HCLOUD_TOKEN or HCLOUD_CONFIG (scripts/pds-live-hetzner-placement-group.sh:17-21).
pds-draft-twin-sweep.sh	ENVIRONMENT	needs a bp-resolvable Barkpark server+token for its ONE raw ledger walk (scripts/pds-draft-twin-sweep.sh:123, `bp doc ls task --perspective raw --all`) and, in write mode, for `bp doc discard-draft` (:329); the raw walk is an offset walk over a LIVE collection that refuses with pagination_shifted under load, so no required gate can run it. Its `--selftest` is hermetic (synthetic fixture, no network, no credential) and green, but nothing required runs it — the same holding-pen shape as pds-scratch-target_test.sh; a rider would move the class, not this row.
pds-draft-only-task-census.sh	ENVIRONMENT	needs a bp-resolvable Barkpark server+token for its ONE raw ledger walk (scripts/pds-draft-only-task-census.sh:101, `bp doc ls task --perspective raw --all`) — the same walk and the same class as its sibling pds-draft-twin-sweep.sh. With no server the walk file comes back EMPTY and the run exits 1 CANNOT READ, printing no table and no SUMMARY, so its census arm cannot be measured on a credential-free box at all; the refusal is the design (a failed walk answering "0 draft-only rows" is the exact fraud this instrument exists to refuse). It NEVER writes: read verbs only, and the selftest greps the census path for write verbs and reds if one appears. Its OFFLINE arm IS through the door and green — by run 2026-09-04 at 8c0723b7f: `--selftest` rc=0, 26 of 26 synthetic arms, no ledger and no network.
pds-stranded-draft-cause.sh	ENVIRONMENT	needs a bp-resolvable Barkpark server+token for TWO reads — the ONE raw ledger walk it shares with scripts/pds-draft-only-task-census.sh (`bp doc ls task --perspective raw --all`, pull_raw) and the tag registry (`bp doc ls tag --all`, pull_tags). SAME WALK, SAME CLASS as that sibling and as pds-draft-twin-sweep.sh: the walk is an offset walk over a LIVE collection that refuses `pagination_shifted` under campaign traffic, so no required gate can run its live arm — MEASURED, not assumed: 5 consecutive census walks were refused before the 6th completed (2026-09-05, 8771 docs, 207 published tags). With no server BOTH reads come back empty and the run exits 1 CANNOT READ with no counts and no SUMMARY, and that refusal is the design — an empty registry would otherwise score EVERY tag UNREGISTERED and hand a lead a table confirming the filing row of this very instrument by construction, so the empty-registry case is its own separate refusal (`ZERO published tag docs`). It NEVER writes: read verbs only, and the selftest greps the live path for write verbs — including `doc create`, because the repair this instrument recommends IS a tag creation — and reds if one appears. Its OFFLINE arm IS through the door and green: by run 2026-09-05, `--selftest` rc=0, 32 of 32 synthetic arms, no ledger and no network, every gate shown REFUSING and PASSING. The load-bearing pair is gate ORDER: one fixture row carries a 19-char rationale AND an unregistered tag and must read SPINE, its twin carries the SAME tag with a clean spine and must read UNKNOWN-TAG, so neither arm can pass on a classifier that ignores the wall order.
pds-live-bp-write-receipt.sh	ENVIRONMENT	needs a bp-resolvable Barkpark server+token; refuses exit 3 otherwise (scripts/pds-live-bp-write-receipt.sh:219).
pds-ledger-census.sh	ENVIRONMENT	needs live ledger credentials (BARKPARK_SERVER, scripts/pds-ledger-census.sh:1325) and python3 (exit 3 at :348-350).
pds-pull-proof.sh	ENVIRONMENT	needs a pinned BARKPARK_HOME scratch target plus an admin-token curl against a live server (scripts/pds-pull-proof.sh:113,227).
pds-secret-scan.sh	ENVIRONMENT	needs psql on PATH and DB-sourced ammo (scripts/pds-secret-scan.sh:136,191).
pds-scratch-target.sh	ENVIRONMENT	needs a scratch Postgres root and free port (BARKPARK_HOME / BARKPARK_PG_PORT, scripts/pds-scratch-target.sh:22-25).
pds-crown-stamp.sh	ENVIRONMENT	writes bp ledger rows and hard-requires python3 (scripts/pds-crown-stamp.sh:134).
pds-crown-launch.sh	ENVIRONMENT	a long-running launcher that ssh-es a live host with a deploy key (scripts/pds-crown-launch.sh:319-323).
pds-climb-preflight.sh	ENVIRONMENT	needs `gh` workflow state and an ssh key for the source host (scripts/pds-climb-preflight.sh:210,273-283).
pds-export-peak-measure.sh	ENVIRONMENT	samples a live host over ssh (scripts/pds-export-peak-measure.sh:242).
pds-blind-spot-check.sh	PRICE	CPU=0.22+0.44=0.67s LOCAL meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=10 load1=12.08 2026-09-02 (--selftest, rc=0; 3 trials gave 0.67/0.59/0.58s CPU, observed band 0.58-0.67 s, HIGH END QUOTED per the rule of this column that a price must never err toward making an expensive thing look gate-able). Its ungated arm is the plain census at CPU=0.40+0.26=0.65s at the same load1=12.08 (3 trials 0.65/0.66/0.65s, a 1.5 percent spread). RE-TAKEN BY `--measure`, never hand-typed, and quoted against its own stamp only (PDS-D656). THE CLASS IS PRICE FOR THE HOLDING-PEN REASON, NOT THE DISQUALIFYING ONE, and the row says so rather than letting the label imply the opposite: 0.67 s keeps no door shut. Same shape as pds-scratch-target_test.sh above, whose row already reads "PRICE today only because nothing required runs it" — this instrument is cheap, hermetic (it reads the tree and writes only a mktemp -d it removes; it issues no network call and reads no credential) and green, and the ONLY thing between it and THROUGH is an ExUnit rider under api/test, which is outside the fence of the PR that added it. Filed as the follow-up named in that PR body. NOT VACUOUS: a separate un-metered run exits 0 and prints `SELFTEST: 10 PASS / 0 FAIL of 10 arms`, and the green descends from arms that can fail — arm 4 deletes the sentence from a compliant fixture and demands rc=1, arm 8 is a mutation this check FAILED on its first run (a source COMMENT naming the constant satisfied the emission scan, so deleting every emitter call from the real pds-pull-proof.sh left the tree GREEN) and now reds.
pds-blind-spot.sh	NOT-YET-BUILT	IT IS NOT A PROGRAM, and the denominator glob cannot tell: `scripts/pds-*.{sh,exs}` keys on the NAME, and this file is a SOURCED CONSTANT — three SYMBOLS, cited by name and not by line so the citation cannot rot on an insertion: `PDS_BLIND_SPOT`, `PDS_BLIND_SPOT_PLACEMENT` and `pds_blind_spot_note()` in scripts/pds-blind-spot.sh, which five instruments read with `.`. It sets no shell options, reads nothing, writes nothing, and executed directly it prints its two constants and exits 0 WHATEVER the tree looks like — so there is no verdict here for a required gate to run, which is the NOT-YET-BUILT clause as pds-window-sentinel.sh states it above. AND IT IS NOT UNCHECKED, which is the part a bare class would hide: its correctness is asserted by scripts/pds-blind-spot-check.sh, which sources it and whose 10 arms red on a one-byte drift of the constant (arm 6, `a one-byte DRIFTED copy of the sentence REDS`, rc=1 by run 2026-09-02). NO PRICE ROW: pricing a file that is never invoked as a program would be a figure for a workload nothing runs, which is precisely the rot the PRICE pen above documents.
pds-idle-sampler.sh	ENVIRONMENT	samples a live host over ssh, twice a minute (scripts/pds-idle-sampler.sh:7,182).
pds-pre-gate-papers-check.sh	PRICE	CPU=0.03+0.04=0.06s LOCAL meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=10 load1=4.11 2026-09-05 (--selftest, rc=0; 3 trials gave 0.06/0.05/0.06s CPU, observed band 0.05-0.06 s, HIGH END QUOTED per the rule of this column that a price must never err toward making an expensive thing look gate-able). TAKEN BY `--measure`, never hand-typed, and quoted against its own stamp only (PDS-D656). THE CLASS IS PRICE FOR THE HOLDING-PEN REASON, NOT THE DISQUALIFYING ONE, and the row says so rather than letting the label imply the opposite: 0.06 s keeps no door shut. Same shape as pds-blind-spot-check.sh above — the `--selftest` arm is offline and hermetic (it builds its fixtures in a mktemp -d it removes, calls no bp, no mix and no network, and reads no credential), and the ONLY thing between it and THROUGH is an ExUnit rider under api/test that would have to exec it. The OTHER arm, `--live`, is genuinely ENVIRONMENT-bound (it needs a BARKPARK_SERVER-resolvable bp AND a compiled api/ tree to shell the predicate, scripts/pds-pre-gate-papers-check.sh:41-42) — but the arm a gate would run is the offline one, so ENVIRONMENT would be a FALSE disposition for this door and PRICE is the honest one. NOT VACUOUS: a separate un-metered run exits 0 and prints `selftest failures: 0` over 7 arms, and the green descends from arms that can fail — case 2 plants a refused-and-UNREGISTERED id and demands rc=1 naming that id, so a comparison gutted by a copy-paste reds instead of passing empty.
pds-pre-gate-papers-predicate.exs	ENVIRONMENT	needs a COMPILED api/ tree and the server modules inside it — this is `mix run --no-start` fodder, not a standalone program. Proven by run 2026-09-05: `elixir scripts/pds-pre-gate-papers-predicate.exs /dev/null /dev/null` is rc=1 with `** (UndefinedFunctionError) function Jason.decode!/1 is undefined (module Jason is not available)` raised at scripts/pds-pre-gate-papers-predicate.exs:62, before a single one of its three server calls is reached — Barkpark.PortableDoc.Projection.read_blocks/1 (:107) and Barkpark.Content.Papers.BlockOps.normalize_render_shapes/1 plus validate_render_shapes/1 (:104,:110-111) are the publish gate OWN code and exist only inside the compiled application. The source states the dependency itself at :39-41 (`MIX_ENV=test mix run --no-start ../scripts/pds-pre-gate-papers-predicate.exs`). NOT NOT-YET-BUILT: this is a finished program with a real verdict, but it takes two positional file paths and declares no --selftest and no --check — its only argument arm is the rc=2 usage refusal at :56 — so there is nothing a required gate could run here WITHOUT standing up the api/ build it needs. Its offline comparison logic is exercised through its caller, scripts/pds-pre-gate-papers-check.sh --selftest.
rerun-adjudicate.mjs	RED-BY-DESIGN-REPORTER	ITS EXIT CODE IS DECLARED NOT TO BE A VERDICT, IN ITS OWN SOURCE. tooling/pds/rerun-adjudicate.mjs:16-21 reads: EXIT CODES ARE FOR THE SHELL, NEVER FOR A VERDICT -- 0 the run COMPLETED, it does NOT mean the reasons are true, read the line. A required gate consumes exactly one thing, an exit code, and this file refuses to make its exit code mean what a gate would read it as. Run-derived 2026-09-03 at ec8b97a09: `node tooling/pds/rerun-adjudicate.mjs` rc=0, printing `status COMPLETE`, `172 live adjudicated row(s)` and a five-row rerun variance census -- all of it over the DEFAULT corpus, which is the PINNED SNAPSHOT tooling/pds/fixtures/live-corpus-2026-07-31.json (read_at 2026-07-31, declared at :30). So the green is hermetic and reproducible and says nothing whatever about the board today; the one mode that would (--fetch, :12) reads the LIVE ledger and needs a credential. NOT NOT-YET-BUILT: it is built, it runs, and it prints a full verdict. What it does not have is an exit code a gate may read.
rerun-adjudicate.test.mjs	CONTENT-RED	by run 2026-09-03 at ec8b97a09: `node tooling/pds/rerun-adjudicate.test.mjs` rc=1, `pds/rerun-adjudicate: 117 checks, 7 failed`, naming arms 5.3, 5.4, 6.7, 6.8, 8.8, 8.9 and 9.2 -- a pds/grip polarity drift in which an absence claim comes back REFUSED where the arm expects RE-DERIVED. THE TREE ALREADY KNEW AND SAID SO IN WRITING: .github/workflows/research-coverage-suite.yml:37-42 excludes this file from the tooling node --test job (DELIBERATELY EXCLUDED -- it fails on a pds/grip polarity drift that needs evidence-weighed triage under a hard fence forbidding any tooling/grip edit) and names the follow-up wbt-pds-grip-polarity-drift-2026-08-31; the failure notice at :243 repeats it. IT IS RED, NOT UNRUN, AND THAT DISTINCTION DECIDES THE REMEDY: wiring a red harness into a blocking gate reds main on the first merge for a defect no PR introduced. It flips to THROUGH when the drift is adjudicated and an ExUnit rider executes it, and not before.'

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
PDS_DOOR_PRICES='pds-door-census.sh	CPU=0.49+0.77=1.26s LOCAL meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=10 load1=6.48 2026-08-05 (--check, rc=0; 3 trials gave 1.26/1.31/1.27s). Its gated arm is --selftest at CPU=0.58+1.01=1.59s at load1=5.19 (3 trials 1.59/1.53/1.62s — a 5.7% spread at one stamp, which is what makes the figure quotable against its own stamp rather than against the host). RE-TAKEN IN THIS PR BECAUSE THE INSTRUMENT CHANGED UNDERNEATH IT AGAIN: wave 48 took --selftest from 33 arms to 43 (the host axis in the grammar, the depth guard, the witness, the two LC_ALL pins, portability, writes-nothing), and a price whose instrument changed underneath it is the exact rot this row exists to prevent. AND THE METER ITSELF CHANGED — this is the first row in the column taken BY `--measure`, not by a hand-typed /usr/bin/time recipe, so it is quoted against the wave 47 figure only as a like-for-like re-take at a comparable stamp: 1.07s at load1=5.54 then, 1.59s at load1=5.19 now, i.e. the ten new arms cost ~+49% of the gated arm. The earlier 3.32s/0.16s at load1=41.63 is NOT comparable and is quoted as neither a delta nor a baseline: PDS-D656 — a price is quotable only against its own load stamp. The rider also runs --check once and a one-row mutant once. RE-TAKEN ON THE BUILDER HOST 2026-09-03 (wave 49, the widened denominator), BY --measure, NEVER PASTED, AND ADDED BESIDE THE STAMP ABOVE RATHER THAN OVER IT: --check CPU=3.25+10.01=13.25s at load1=69.60, 3.25+9.75=13.00s at load1=65.29, 3.27+10.14=13.41s at load1=83.63 (band 13.00-13.41 s, a 3.1 percent spread, cpus=10); --selftest CPU=2.03+6.26=8.29s at load1=66.84, 2.11+6.70=8.81s at load1=75.97, 1.96+5.91=7.87s at load1=75.62 (band 7.87-8.81 s, an 11.9 percent spread, cpus=10). THE INSTRUMENT DID CHANGE UNDERNEATH THE ROW AGAIN and that is why it was re-taken: --selftest went 45 arms to 49 and --check went from a population of 25 to 34 as the denominator reached tooling/pds. THE TWO STAMPS ARE NOT A DELTA AND MUST NOT BE READ AS ONE (PDS-D656): 1.26s at load1=6.48 against 13.25s at load1=69.60 is a TENFOLD gap on a host carrying ten times the load, and no part of it is attributable to the four new arms. A ratio taken across those stamps would measure this machine, not this change. The transferable facts here are the arm count, the population and the WITHIN-STAMP spreads; the quotable figure for a CI runner is still the load1=5-7 band above, which this run does not refute and cannot confirm.
pds-status-only-residue.exs	CPU=0.61+0.21=0.82s LOCAL meter=/usr/bin/time -p around bash -c load1=26.44 2026-08-03 (--selftest, 15/15 arms)
pds-record-parity.test.sh	CPU=1.45+3.00=4.45s LOCAL meter=/usr/bin/time -p around bash -c load1=26.44 2026-08-03 (76 checks, 0 failures)
pds-pull-proof_test.sh	CPU=0.32+0.28=0.59s LOCAL meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=10 load1=3.17 2026-09-06 (no arguments, rc=0; 3 trials gave 0.56/0.59/0.57s CPU at one stamp, observed band 0.56-0.59 s, a 5.4 percent spread, HIGH END QUOTED per the rule of this column that a price must never err toward making an expensive thing look gate-able). TAKEN BY `--measure`, never hand-typed, and quoted against its own stamp only (PDS-D656). THE CLASS IS THROUGH AND THE PRICE IS WHY THAT IS HONEST: 0.59 s keeps no door shut, and the instrument is hermetic — it builds tar fixtures in a mktemp -d it removes, sources scripts/pds-pull-proof.sh through the PDS_PROOF_LIB=1 library mode that script itself documents (it loads every rung and runs none), issues no network call, opens no ssh, reads no credential and touches no scratch target. THE SUBJECT STAYS ENVIRONMENT-DISPOSED: this harness prices the offline predicate full_meta_ok and its reader manifest_field, never the --all climb, which still needs a live server and a pinned BARKPARK_HOME, and the disposition row for pds-pull-proof.sh is unchanged. NOT VACUOUS: --measure discards subject output, so the arm evidence comes from a SEPARATE un-metered run — rc=0, 23 `ok` lines and `pds-pull-proof_test: PASS (23 arms: 13 refuse, 2 accept, 5 manifest_field, 2 identification, 1 discrimination)`. The green descends from arms that can FAIL, shown by mutation rather than asserted: reverting full_meta_ok to the origin/main predicate reds 16 arms, collapsing the manifest_field exit code back to a constant 0 reds 5 (including the legacy-accept arm, which is what proves the tightening did not simply refuse everything), deleting file(1) from the refusal message reds 2, and forcing that identification empty reds 2 — an arm that could only ever pass is what this column exists to refuse.
pds-window-sentinel_test.sh	CPU=0.016+0.023=0.039s LOCAL meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=10 load1=8.51 2026-08-22 (no arguments, rc=0; 3 trials gave 0.039/0.031/0.031s CPU, observed band 0.031-0.039 s, HIGH END QUOTED per the rule of this column that a price must never err toward making an expensive thing look gate-able). Quoted against its own stamp only (PDS-D656) and NOT poolable with the two bands above, which were taken at different loads. NOT VACUOUS: a separate un-metered run exits 0 and prints `pds-window-sentinel_test: PASS` over 8 arms, and the harness was run against the PRE-CHANGE sentinel where 3 of those 8 arms RED — so the green descends from arms that can fail. It is hermetic by construction: the probe is stubbed, no ssh is issued, no credential is read, and nothing about any live host is measured.
pds-published-artifact-door.sh	CPU=1.527+0.697=2.224s LOCAL meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=10 load1=5.16 2026-08-22 (origin/main, rc=1 REFUSE; 3 trials gave 2.224/2.193/2.206s CPU, observed band 2.193-2.224 s, HIGH END QUOTED per the rule of this column that a price must never err toward making an expensive thing look gate-able). Quoted against its own stamp only (PDS-D656). NOT VACUOUS: the gated arm is the SELFTEST below, not this live run -- main is RED today and correctly so, so gating on the live run would red every PR for a defect none of them introduced. This figure is the cost of the rider second arm, which asserts the door still NAMES the two react subpaths it was built to refuse and FLUNKS with a re-derivation instruction if it ever goes green.
pds-published-artifact-door_test.sh	CPU=3.557+1.956=5.513s LOCAL meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=10 load1=5.16 2026-08-22 (no arguments, rc=0; 3 trials gave 5.513/5.483/5.553s CPU, observed band 5.483-5.553 s, a 1.3 percent spread, high end quoted). Hermetic by construction: it builds a synthetic git fixture in a temp dir, issues no network call, reads no credential, and does not depend on the state of this repo history. NOT VACUOUS: 17 arms, every escape hatch carrying a MUTATION twin that removes the hatch and demands the same tree refuse, plus a PAIRED PROBE whose two packages differ only in the version literal -- a hatch that skips everything is indistinguishable from one that works unless you show the thing it was hiding.
pds-elixir-receipt-census.exs	CPU=39.16+3.14=42.30s LOCAL meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=10 load1=5.50-7.61 2026-08-05 — the FOUR GATED ARMS SUMMED, each metered separately by `--measure`: plain rc=0 at 11.76+0.93=12.69s (load1=5.66), the one-token tl/1 mutant rc=1 at 12.71+0.85=13.56s (load1=5.50), the D448 population-baseline mutant rc=1 at 11.76+0.93=12.69s (load1=7.61), the unknown-flag refusal rc=2 at 2.93+0.43=3.36s (load1=5.71). THE ROW SAID THREE FOR TWO WAVES WHILE THE RIDER RAN FOUR: api/test/barkpark/pds_elixir_census_test.exs carries arms at :135 :145 :187 :210, and the baseline-mutant arm (PDS-D678, wave 47) was never priced. IT WAS RE-METERED, NOT RE-WORDED — a prose-only repair here is INVISIBLE to every gate in this repo (proven by mutation: editing THREE to SEVENTEEN leaves --check rc=0 ERRORS 0 and the rider 9 tests / 0 failures), which is why the count and the figure moved together. THE UNIT IS DECIDED IN WRITING (PDS-D633/D692): this is an OS meter around a SHELL that runs the four census invocations DIRECTLY, never a meter around the ExUnit rider. Measured, not assumed — `--measure ... --via "mix test test/barkpark/pds_elixir_census_test.exs"` reports 0.90+1.26=2.16s for the same four arms, 19.6x under this leaf sum, because a meter wrapped around a BEAM that fans out to child BEAMs is blind to the fan-out in exactly the direction a price column must not err: it makes an expensive thing look gate-able. The four stamps span 5.50-7.61 and the figure is quotable against that band only, NOT against a quiet or a busier host (PDS-D656). Its `--selftest` is a DIFFERENT arm, separately disqualified at 210 s leaf CPU (D646), and is not what the gate runs.'

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

# THE BLIND-SPOT SENTENCE, BY REFERENCE (PDS-D633). Sourced, never retyped:
# `$PDS_BLIND_SPOT` and `pds_blind_spot_note` come from here, and
# scripts/pds-blind-spot-check.sh reds if any instrument's copy has drifted from
# it. Fail-closed on purpose — an instrument that cannot find the sentence it is
# obliged to print must refuse, not print a price without it.
# shellcheck source=scripts/pds-blind-spot.sh
. "$SCRIPT_DIR/pds-blind-spot.sh"

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
#
# THE DENOMINATOR IS DIRECTORY-SCOPED NO LONGER (wave 49). Until this change the
# enumerator cd'd into $SCAN_ROOT/scripts and emitted BASENAMES, so the whole
# population was `scripts/pds-*` by construction: tooling/pds/*.mjs was not
# UNDISPOSED, it was UNCLASSIFIED — outside the population entirely, invisible to
# every count this file prints. A census whose denominator is a directory reports
# honestly about a set it chose, which is the shape of vacuous green this
# instrument exists to refuse. The globs below are per-DIRECTORY and the output is
# REPO-RELATIVE, so a reader can tell scripts/pds-blind-spot.sh from a
# tooling-side program by looking at the row rather than by knowing the
# convention.
#
# THE KEY DID NOT MOVE WITH THE PATH. Both ledgers are keyed by BASENAME and every
# committed row still is; run_census derives the basename per row and keys the
# ledgers on it, so widening the population rewrote NO ledger row. The price of
# that choice is that two instruments sharing a basename would silently share one
# ledger answer, so run_census REFUSES a colliding population outright rather than
# letting the first row decide.
instruments() {
  instrument_paths | while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "${p##*/}"
  done
}

instrument_paths() {
  (
    cd -- "$SCAN_ROOT" 2>/dev/null || exit 0
    for g in 'scripts/pds-*.sh' 'scripts/pds-*.exs' 'tooling/pds/*.mjs'; do
      # shellcheck disable=SC2086  # $g is a glob PATTERN — expansion is the point
      for f in $g; do
        [ -e "$f" ] || continue
        printf '%s\n' "$f"
      done
    done | LC_ALL=C sort -u
  )
}

# LEG C — IS THIS A PROGRAM AT ALL, OR A LIBRARY THE PROGRAMS IMPORT?
#
# Widening the population to tooling/pds/*.mjs brought in nine files of which
# SEVEN are ES modules with no `#!` line and no CLI entry point: they are imported
# by their siblings and executed by nothing, ever, by design. Filing those as
# UNDISPOSED would be false (there is no door to open), and filing them under a
# ledger class would be disposing a row by widening a class until it matches —
# refused. So the band is DERIVED FROM THE TREE, exactly like THROUGH is: no
# shebang on line 1 AND at least one sibling in the same directory importing it by
# name. Add a shebang to one of them and it LEAVES this band on the next run,
# which is the mutation that proves the band is read rather than asserted.
is_library_module() {
  local rel="$1" abs dir base n
  abs="$SCAN_ROOT/$rel"
  [ -f "$abs" ] || return 1
  case "$(head -n 1 -- "$abs" 2>/dev/null)" in '#!'*) return 1 ;; esac
  dir="${rel%/*}"
  base="${rel##*/}"
  [ "$dir" != "$rel" ] || return 1
  n="$(
    cd -- "$SCAN_ROOT/$dir" 2>/dev/null || exit 0
    # `grep -cv` counts the siblings directly. `|| true` is REQUIRED, not tidy:
    # grep -c prints its count AND exits 1 when that count is zero, which under
    # `set -e` would kill the census on the ordinary case of an unimported file.
    grep -lF -- "./$base" ./*.mjs 2>/dev/null | grep -cvxF -- "./$base" || true
  )"
  [ -n "$n" ] && [ "$n" -gt 0 ]
}

library_module_importers() {
  local rel="$1" dir base
  dir="${rel%/*}"
  base="${rel##*/}"
  (
    cd -- "$SCAN_ROOT/$dir" 2>/dev/null || exit 0
    grep -lF -- "./$base" ./*.mjs 2>/dev/null | grep -vxF "./$base" |
      sed "s|^\./|$dir/|" | LC_ALL=C sort | tr '\n' ' '
  )
}

# THE COLLISION PREDICATE, EXTRACTED SO IT CAN BE FIRED.
#
# It is UNREACHABLE under today's two globs -- scripts/pds-*.{sh,exs} and
# tooling/pds/*.mjs cannot produce the same basename, because the extensions are
# disjoint -- and that is precisely why it lives in a function with its own arm
# rather than inline where nothing could ever exercise it. It is a tripwire for
# the NEXT widening, and an untestable tripwire is the thing this file exists to
# refuse. The selftest fires it directly on a colliding list.
basename_collisions() {
  printf '%s\n' "$1" | LC_ALL=C sort | uniq -d
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
    # SIGIL-AWARE (pds-w45-argspan-sigil-and-silent-bound). A paren inside a
    # sigil (~s|a ( b|, ~r/(/ …) used to count as STRUCTURE, so the span closed
    # early or overran to the 40-line bound — MORE permissive, i.e. it could
    # admit a fraudulent THROUGH. Sigil CONTENTS are now blanked one-for-one
    # (length preserved — the span-column arithmetic depends on it), with the
    # delimiters kept: a paired-delimiter sigil keeps its own ( ) which balance
    # each other, and nested paired delimiters inside track depth exactly as
    # the Elixir lexer does. Single-quoted charlists are DELIBERATELY not
    # tracked: an apostrophe in a comment (dont, isnt…) would swallow the rest
    # of the line including its # and defeat cut_comment — a worse, more
    # permissive failure than the rare charlist paren.
    function sigil_close(d) {
      if (d == "(") return ")"
      if (d == "[") return "]"
      if (d == "{") return "}"
      if (d == "<") return ">"
      return d
    }
    function blank_strings(s,   out, i, c, inq, esc, n, insig, sopen, sclose, sdepth, nxt, dlm) {
      out = ""; inq = 0; esc = 0; insig = 0
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (inq) {
          if (esc) { esc = 0; out = out " "; continue }
          if (c == "\\") { esc = 1; out = out " "; continue }
          if (c == "\"") { inq = 0; out = out "\""; continue }
          out = out " "
        } else if (insig) {
          if (esc) { esc = 0; out = out " "; continue }
          if (c == "\\") { esc = 1; out = out " "; continue }
          if (c == sopen && sopen != sclose) { sdepth++; out = out " "; continue }
          if (c == sclose) {
            sdepth--
            if (sdepth <= 0) { insig = 0; out = out c; continue }
            out = out " "; continue
          }
          out = out " "
        } else {
          if (c == "~" && i + 2 <= n) {
            nxt = substr(s, i + 1, 1)
            dlm = substr(s, i + 2, 1)
            if (nxt ~ /[A-Za-z]/ && index("([{<|/\"", dlm) > 0) {
              insig = 1; sopen = dlm; sclose = sigil_close(dlm); sdepth = 1
              out = out c nxt dlm
              i += 2
              continue
            }
          }
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
      SPAN_TRUNC = 0
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
      # Fell out of the loop: the 40-line bound was hit (or the file ended)
      # with parens still open. The span is INCOMPLETE — say so, out of band,
      # so the caller can emit an attributable row instead of a silent decline
      # (the census law turned on itself: a verdict that does not descend from
      # a complete read must say so).
      SPAN_TRUNC = 1
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
        trunc_at = 0
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
            if (SPAN_TRUNC && trunc_at == 0) trunc_at = i
            if (span == "") continue
            if (attr != "" && mentions_attr(span, attr)) exec_at = i
            if (exec_at == 0) for (v in TV) if (mentions(span, v)) { exec_at = i; break }
            if (exec_at != 0) break
          }
        }

        # A truncated span means NO verdict about this binding descends from a
        # complete read — the honest-decline law applied to the census itself.
        # The row is emitted BESIDE the verdict so the table can outrank it.
        if (trunc_at > 0)
          printf "%s\t%d\tSPAN-TRUNCATED\t%s\t%s\n", FNAME, trunc_at, bbase[b], blit[b]

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
  #
  # THE HOST AXIS IS REQUIRED AND HAS EXACTLY TWO VALUES (wave 48, PDS-D648):
  # LOCAL or FOREIGN. Widening the axis WITHOUT the refusal arm below would turn
  # a pin into a hole — the token would become optional, and a price could then
  # say nothing at all about where it was taken, which is the one thing a CPU
  # figure cannot be quoted without. So the third arm is not decoration: it is
  # the half that makes the widening safe, and `--selftest` reds when a price
  # carrying NEITHER token passes.
  case "$2" in
    'CPU='*'LOCAL'*'meter='*) ;;
    'CPU='*'FOREIGN'*'meter='*) ;;
    *)
      printf '  %s: a price must carry CPU=<user>+<sys>=<total>s followed by its HOST AXIS — LOCAL or FOREIGN, one of the two, never neither — and meter=<name> (PDS-D648). A CPU second is not comparable across hosts, so a price that does not say which host it was taken on is a number nobody can re-take. It carries: %s' "$1" "$2"
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
  local list paths total sh_n exs_n mjs_n harnesses harness_n peers_n dupes
  paths="$(instrument_paths)"
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
  mjs_n="$(printf '%s\n' "$list" | grep -c '\.mjs$' || true)"

  # THE COLLISION REFUSAL. Both ledgers are keyed by basename and the population
  # is now drawn from two directories, so two same-named programs would silently
  # share one disposition and one price — the first row deciding for both, with
  # nothing printed. That is precisely the "first match wins, silently" defect the
  # duplicate-key checks below already refuse on the ledger side, so it is refused
  # on the population side too rather than left to luck.
  dupes="$(basename_collisions "$list")"
  if [ -n "$dupes" ]; then
    echo "::error::$SELF: BASENAME COLLISION in the population: $(printf '%s' "$dupes" | tr '\n' ' ')" >&2
    echo "  Both ledgers are keyed by basename, so a collision makes one row answer for two" >&2
    echo "  instruments with nothing printed. Rename one, or key the ledgers by path." >&2
    return 1
  fi
  harnesses="$(printf '%s\n' "$list" | grep -E '(_test\.sh|\.test\.sh)$' || true)"
  harness_n="$(printf '%s\n' "$harnesses" | sed '/^$/d' | wc -l | tr -d ' ')"
  peers_n=$((total - harness_n))

  echo "$SELF: scanning \$SCAN_ROOT=$SCAN_ROOT"
  echo
  echo "DENOMINATOR — the globs are scripts/pds-*.{sh,exs} and tooling/pds/*.mjs,"
  echo "  NEVER a bare scripts/pds-* and NEVER scripts/ alone (wave 49: a"
  echo "  directory-scoped denominator left tooling/pds UNCLASSIFIED, not merely"
  echo "  undisposed — outside the population, invisible to every count below)."
  echo "  enumerated by: ls -1 scripts/pds-*.sh scripts/pds-*.exs tooling/pds/*.mjs"
  echo "  population    : $total ($sh_n .sh + $exs_n .exs + $mjs_n .mjs)"
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
  local b bpath kinds legA legB class evidence price row computed shape_err orphan_err
  local orphan_price_err
  local through=0 undisposed=0 errors=0 inbeam=0 dead=0 libmod=0 error_rows=0
  local through_names="" undisposed_names="" error_lines="" class_tally=""

  echo "THE COLUMN"
  printf '  %-40s %-6s %-6s %-22s %s\n' INSTRUMENT LEG-A LEG-B DISPOSITION DETAIL
  while IFS= read -r bpath; do
    [ -n "$bpath" ] || continue
    # THE ROW IS A PATH; THE LEDGER KEY IS ITS BASENAME. Keeping the two apart is
    # what let the population widen without rewriting a single committed row.
    b="${bpath##*/}"
    kinds="$(printf '%s\n' "$refs" | awk -F'\t' -v b="$b" '$4 == b { print $3 }' | LC_ALL=C sort -u)"

    legA='no'
    case "$kinds" in *LEGA-BOUND-EXEC*) legA='yes' ;; esac
    legB="$(leg_b "$bpath")"

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
    if has_line "$kinds" 'SPAN-TRUNCATED'; then
      class='ERROR'
      evidence='a System.cmd/Port.open argument-list span hit the arg_span 40-line bound (or the file ended with parens open) — the read is INCOMPLETE, so no verdict about this binding descends from a complete read. Split the call under 40 lines or fix the unbalanced paren; never let a truncated read decline (or admit) a door quietly.'
    elif has_line "$kinds" 'BOUND-UNEXEC'; then
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
    elif is_library_module "$bpath"; then
      # DERIVED, NOT DECLARED — and ordered AFTER every gated band, so a library
      # that ever does become gated classifies THROUGH and never hides here.
      computed='no'
      class='LIBRARY-MODULE'
      evidence="no \`#!\` on line 1 and no CLI entry point; imported by $(library_module_importers "$bpath")— a library the programs import, not a door. Re-derived every run: add a shebang and this row LEAVES the band."
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
        # THE SUMMARY NAMES LEDGER KEYS, THE COLUMN NAMES PATHS. Both ledgers
        # are keyed by basename, so the two summary lists below stay basenames:
        # a reader who takes a name from here and greps the ledger for it finds
        # the row, and the table above is where the path lives.
        through_names="$through_names $b"
        ;;
      IN-BEAM-REQUIRED) inbeam=$((inbeam + 1)) ;;
      DEAD-DECLARATION) dead=$((dead + 1)) ;;
      LIBRARY-MODULE) libmod=$((libmod + 1)) ;;
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

    printf '  %-40s %-6s %-6s %-22s %s\n' "$bpath" "$legA" "$legB" "$class" "$evidence"
  done <<EOF
$paths
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
  $lb: STALE LEDGER ROW — disposed/priced here, but the population holds no scripts/pds-*.{sh,exs} and no tooling/pds/*.mjs program of that basename."
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
  echo "  LIBRARY-MODULE          : $libmod of $total  (derived: no shebang, imported by a sibling)"
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
  echo
  echo "THE INSTRUMENT CANNOT WITNESS ITS OWN REMOVAL — MEASURED, NOT ASSERTED (wave 49)"
  echo "  Measured on 2026-09-03 at ec8b97a09 by moving api/test/barkpark/pds_door_census_test.exs"
  echo "  out of the tree and re-running each gate:"
  echo "    scripts/elixir-path-escape-check.sh --check   rc=0 BOTH ways. Its read count fell"
  echo "      44 -> 43 distinct repo-root reads and its test-cwd idiom 38 -> 37, silently, against"
  echo "      a floor of 8. A count that decrements without a verdict is not a gate."
  echo "    scripts/pds-door-census.sh --check             rc=1, DEAD-DECLARATION 1 of 34, naming"
  echo "      scripts/pds-door-census.sh itself: declared in ELIXIR_TEST_ONLY_PATHS, executed by"
  echo "      no ExUnit case. This census is the ONLY instrument that sees the deletion."
  echo "  AND THAT IS THE HOLE: the sole executor of this census is the very file whose removal it"
  echo "  detects, so a PR deleting that one file removes the only reader of the only gate that"
  echo "  could object. Nothing here closes it — an arm asserting that every declared pds path has"
  echo "  a live reader would still be run BY that reader. It is recorded rather than fixed, because"
  echo "  a fix belongs in whatever executes the census, which is outside this file. Not closing it"
  echo "  is a decision on the record, which is the one thing better than silence about it."
  echo "  NOT MEASURED IN THIS RUN: scripts/pds-elixir-receipt-census.exs was not re-run under the"
  echo "  mutation (it is a BEAM instrument and the host carried load1 ~70), so its rc is not quoted."
  echo
  echo "WHAT THE DOORS DO AND DO NOT PROVE (PDS-D637): a green door gates the ARM'S OWN LOGIC"
  echo "  against regression. It does not gate the epic's record — record-parity's harness is"
  echo "  hermetic and reads zero live ledger rows."
  echo
  printf '%s\n' "$BLIND_SPOT"
  echo
  pds_blind_spot_note \
    "the PRICE column above: every row is an OS meter around a SHELL (bash times builtin around LC_ALL=C bash -c), taken by --measure, never inside a BEAM parent" \
    "the price column"
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
# --measure — the instrument a price DESCENDS FROM (PDS-D663, PDS-D669)
# ---------------------------------------------------------------------------
# PDS-D663: "D648's directive that the door's own first CI run overwrite the
# local figure remains law, and --measure is its instrument." A column whose
# rows are typed by hand is a column of assertions; this is the meter that makes
# them measurements.
#
# IT EMITS AND WRITES NOTHING. `--measure` prints ONE pasteable ledger row on
# stdout and touches no file — the row is pasted into PDS_DOOR_PRICES by a human
# in a reviewable diff. A meter that edited the ledger it feeds would be a
# program that can silently re-price the column it is checked by.
#
# IT IS NEVER GATED, AND THAT RULE IS FALSIFIABLE RATHER THAN A COMMENT
# (PDS-D669). Two mechanisms, both exercised by `--selftest`:
#   * PDS_DOOR_MEASURE_DEPTH — `--measure` exports it into its own metering
#     shell and REFUSES (rc=4) if it is already set. A meter inside a meter
#     prices the meter, and that is how a gated `--measure` would look from the
#     inside;
#   * PDS_DOOR_MEASURE_WITNESS — when set, `run_measure` touches that path on
#     entry. A `--check` run must leave it ABSENT. If anyone ever wires the
#     meter into the census's verification path, the witness appears and the
#     arm reds. Absence-from-the-code is not a guard; this is.
# The converse holds by construction: `--measure` runs its subject with output
# discarded and NEVER reads its verdict — the subject's rc is quoted in the
# row's note as provenance and gates nothing.
#
# WHY `times` AND NOT `/usr/bin/time -p` (PDS-D669's exec-discard trap)
# --------------------------------------------------------------------
# `times` is a SHELL BUILTIN, so it is never exec'd, so no accumulated
# RUSAGE_CHILDREN can be discarded by an exec — D669's trap is STRUCTURALLY
# unreachable rather than avoided by a mandatory trailing no-op somebody can
# delete. It also needs no time(1) binary on the host. It is the FINAL command
# of the metering shell for the same reason. Recorded honestly: D669's trap did
# NOT reproduce on this host's bash 3.2.57; that does not refute D669 on another
# bash/libc, and is one more argument for structural immunity over empirical.
# `times` reports the shell's OWN cpu and its WAITED-FOR CHILDREN's cpu, and
# RUSAGE_CHILDREN accumulates grandchildren too — which is precisely the port
# children PDS-D633 warns an in-BEAM meter is blind to.
#
# LC_ALL=C PINS THE WHOLE RECIPE, NOT JUST THE METER (PDS-D691)
# -------------------------------------------------------------
# Two pins, and BOTH are load-bearing — a meter-only pin is a hole whose new
# failure mode reds nothing:
#   * the METER pin (PDS_DOOR_MEASURE_METER_LC): under a comma-decimal locale a
#     glibc `times` prints `0m0,724s`, and an unguarded summer reads that as
#     zeroes;
#   * the SUMMER pin (PDS_DOOR_MEASURE_SUM_LC): awk's `strtod` is locale-bound
#     BOTH ways. Measured on this host: default-locale awk on `0.53 0.72` prints
#     `0`, and `LC_ALL=C` awk on `0,53 0,72` prints `0`. Its `printf "%.2f"` is
#     locale-bound too, which is how the fabricated `CPU=0+1=1,00s` shape gets
#     its comma — a REAL measurement rendered 2.5x low, which census.sh's
#     substring globs would have ACCEPTED.
# Both variables default to C and exist ONLY so `--selftest` can remove a pin
# and prove the arm reds. And the summer is FAIL-CLOSED on radix in both
# directions: it refuses `times` fields that are not dot-decimal, and refuses
# its own sum if it did not come out dot-decimal. That refusal is what holds on
# a host with no comma-radix locale installed, where the fabrication cannot be
# staged at all.
PDS_DOOR_MEASURE_METER_LC="${PDS_DOOR_MEASURE_METER_LC:-C}"
PDS_DOOR_MEASURE_SUM_LC="${PDS_DOOR_MEASURE_SUM_LC:-C}"

# THE HOST AXIS, DERIVED FROM THE HOST — never typed. A hand-typed axis is the
# same class of fact as a hand-typed price.
measure_host_label() {
  if [ -n "${GITHUB_ACTIONS:-}" ] || [ "${CI:-}" = 'true' ]; then
    printf 'FOREIGN'
  else
    printf 'LOCAL'
  fi
}

# THE FIRST COMMA-RADIX LOCALE THIS HOST ACTUALLY HAS, or nothing. `--selftest`
# uses it to REMOVE a pin and prove the arm reds; a host with none (ubuntu-latest
# ships C/C.UTF-8/en_US only) cannot stage the fabrication at all, and the arm
# says so in words instead of passing quietly.
# NOT `locale -a | grep -q`: `set -o pipefail` is on, `grep -q` closes the pipe
# on its first match, and the SIGPIPE'd `locale` then decides the pipeline's rc —
# so the lookup reported "no locale installed" on a host that has five. Matched
# on an EXACT line inside a captured string instead, which no signal can flip.
measure_comma_locale() {
  local l avail
  avail="$(locale -a 2>/dev/null || true)"
  avail="$(printf '\n%s\n' "$avail")"
  for l in nb_NO.UTF-8 nn_NO.UTF-8 da_DK.UTF-8 de_DE.UTF-8 fr_FR.UTF-8; do
    case "$avail" in
      *$'\n'"$l"$'\n'*)
        printf '%s' "$l"
        return 0
        ;;
    esac
  done
  return 1
}

# PORTABLE BY DESIGN: `nproc` does not exist on macOS and neither does
# /proc/loadavg. Without these fallbacks the host axis is Linux-only by
# accident, and a darwin row would carry no cpu count at all. Both refuse
# rather than guess: an unknown cpu count or load stamp REDS the measurement.
measure_cpus() {
  local n=''
  if [ -z "${PDS_DOOR_MEASURE_NO_NPROC:-}" ] && command -v nproc >/dev/null 2>&1; then
    n="$(nproc 2>/dev/null || true)"
  fi
  if [ -z "$n" ]; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  case "$n" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$n"
}

measure_load1() {
  local l=''
  if [ -z "${PDS_DOOR_MEASURE_NO_PROCLOAD:-}" ] && [ -r /proc/loadavg ]; then
    l="$(LC_ALL=C awk '{print $1}' /proc/loadavg 2>/dev/null || true)"
  fi
  if [ -z "$l" ]; then
    # linux `uptime`: "load average: 0.52, 0.58, 0.59"
    # darwin `uptime`: "load averages: 4.31 4.51 4.66"
    # LC_ALL=C throughout so a comma-decimal locale cannot turn the FIRST field
    # into half a number the moment `tr` splits on commas.
    l="$(LC_ALL=C uptime 2>/dev/null |
      LC_ALL=C sed -e 's/.*load averages*: *//' |
      LC_ALL=C tr ',' ' ' |
      LC_ALL=C awk '{print $1}' || true)"
  fi
  case "$l" in
    '' | *[!0-9.]*) return 1 ;;
  esac
  printf '%s' "$l"
}

# THE SUMMER — fail-closed on radix in BOTH directions (PDS-D691).
measure_sum() {
  # $1 = raw `times` output (two lines, four fields). Prints "<user> <sys> <total>".
  local f n=0 bad='' out
  for f in $(printf '%s\n' "$1"); do
    n=$((n + 1))
    case "$f" in
      [0-9]*m[0-9]*.[0-9]*s) ;;
      *) bad="$bad [$f]" ;;
    esac
  done
  if [ "$n" -ne 4 ] || [ -n "$bad" ]; then
    printf '%s: REFUSE — the meter did not emit four dot-decimal `times` fields; it emitted %d field(s)%s. That is the PDS-D691 fabrication: a comma-decimal `times` line parses as zeroes and yields a REAL measurement rendered LOW. No figure is printed.\n' \
      "$SELF" "$n" "$bad" >&2
    return 5
  fi
  out="$(LC_ALL="$PDS_DOOR_MEASURE_SUM_LC" awk '
    { gsub(/[ms]/, " "); u += $1 * 60 + $2; s += $3 * 60 + $4 }
    END { printf "%.2f %.2f %.2f\n", u, s, u + s }
  ' <<EOF
$1
EOF
  )"
  # AND THE SUM ITSELF IS CHECKED: an unpinned summer both PARSES and PRINTS in
  # the locale's radix, so `0,00` (or a silent `0`) is what a removed pin looks
  # like on the way out. Refusing it is what makes the pin's absence LOUD on a
  # host where the comma locale exists, and harmless where it does not.
  case "$out" in
    [0-9]*.[0-9][0-9]' '[0-9]*.[0-9][0-9]' '[0-9]*.[0-9][0-9]) ;;
    *)
      printf '%s: REFUSE — the summer produced "%s", which is not three dot-decimal figures. The LC_ALL pin on the SUMMER is missing or wrong: awk parses AND prints in the locale radix, so an unpinned summer turns a real measurement into a low or zero one (PDS-D691). No figure is printed.\n' \
        "$SELF" "$out" >&2
      return 5
      ;;
  esac
  printf '%s' "$out"
}

run_measure() {
  # $1 = basename of the instrument the row is FOR; the rest is either
  # arguments to it, or `--via <command>` for a gated arm that is not a direct
  # invocation of the instrument (an ExUnit rider, say).
  local base="$1" cmd='' note='' path='' interp='' raw='' sums='' user='' sys='' total=''
  local cpus='' load1='' host='' rcfile='' subject_rc='' stamp='' arg=''
  shift

  # THE DEPTH GUARD, FIRST — before the witness, before any work. PDS-D669.
  if [ -n "${PDS_DOOR_MEASURE_DEPTH:-}" ]; then
    printf '%s: REFUSE — PDS_DOOR_MEASURE_DEPTH=%s is already set, so this --measure is running INSIDE a metered subtree. A meter inside a meter prices the meter (PDS-D669: --measure is first-class and is NEVER gated). Nothing measured, nothing printed.\n' \
      "$SELF" "$PDS_DOOR_MEASURE_DEPTH" >&2
    return 4
  fi
  # THE WITNESS — the only file this mode ever touches, and only when a caller
  # (i.e. `--selftest`) asks for it. It exists so "`--check` never invokes
  # `--measure`" is a fact a run can DISPROVE.
  if [ -n "${PDS_DOOR_MEASURE_WITNESS:-}" ]; then
    : >"$PDS_DOOR_MEASURE_WITNESS"
  fi

  if [ "${1:-}" = '--via' ]; then
    shift
    [ $# -ge 1 ] || {
      printf '%s: --via needs a command\n' "$SELF" >&2
      return 2
    }
    cmd="$*"
    note="via: $cmd"
  else
    path="$SCRIPT_DIR/$base"
    if [ ! -f "$path" ]; then
      printf '%s: REFUSE — no such instrument: %s. --measure prices a real file or nothing.\n' "$SELF" "$path" >&2
      return 5
    fi
    case "$base" in
      *.exs) interp='elixir' ;;
      *) interp='bash' ;;
    esac
    cmd="$interp $(printf '%q' "$path")"
    for arg in "$@"; do cmd="$cmd $(printf '%q' "$arg")"; done
    note="$*"
    [ -n "$note" ] || note='no arguments'
  fi

  cpus="$(measure_cpus)" || {
    printf '%s: REFUSE — could not derive a cpu count from nproc or getconf _NPROCESSORS_ONLN. A CPU figure with no cpu count beside it is not re-takeable.\n' "$SELF" >&2
    return 5
  }
  load1="$(measure_load1)" || {
    printf '%s: REFUSE — could not derive load1 from /proc/loadavg or uptime. PDS-D656: CPU is not load-independent, so a figure with no load stamp is a number nobody can re-take.\n' "$SELF" >&2
    return 5
  }
  host="$(measure_host_label)"
  stamp="$(LC_ALL=C date +%Y-%m-%d)"

  rcfile="$(mktemp "${TMPDIR:-/tmp}/pds-door-measure.XXXXXX")"

  # THE RECIPE. `times` is the FINAL command of the metering shell; the subject's
  # output is DISCARDED and its rc is stashed by a BUILTIN (printf) so that stays
  # true. LC_ALL is pinned around the WHOLE recipe, not just the summer.
  #
  # PDS-BLIND-SPOT-METER: bash's `times` builtin, around a SHELL (`bash -c`) that
  # runs the subject — an OS-level meter OUTSIDE any BEAM, which is placement (a)
  # of PDS-D633's law. `times` reports the shell's own CPU plus RUSAGE_CHILDREN,
  # which accumulates grandchildren, so the port children an in-BEAM meter is
  # blind to ARE charged here. The forbidden placement is the other one: a figure
  # taken from inside a BEAM parent (`:erlang.statistics(:runtime)`, or
  # /usr/bin/time wrapped around a BEAM that fans out) reads under HALF the price
  # of ONE of its children. This is why `--via "mix test ..."` reports 2.16s for
  # four census arms that cost 42.30s leaf-metered: it is the same 19.6x
  # blindness, in the one direction a price column must not err. For a REGRESSION
  # RATCHET under a required gate the unit is not seconds at all but
  # `Process.info(pid, :reductions)`, byte-identical at 0, 4 and 8 noise
  # processes where milliseconds moved 5x.
  raw="$(
    cd "$REPO_ROOT" &&
      LC_ALL="$PDS_DOOR_MEASURE_METER_LC" PDS_DOOR_MEASURE_DEPTH=1 \
        bash -c "$cmd >/dev/null 2>&1; printf '%s' \$? >'$rcfile'; times"
  )"
  subject_rc="$(cat "$rcfile" 2>/dev/null || printf '?')"
  rm -f "$rcfile"

  sums="$(measure_sum "$raw")" || return $?
  user="${sums%% *}"
  total="${sums##* }"
  sys="${sums#* }"
  sys="${sys%% *}"

  # ONE PASTEABLE ROW ON STDOUT. Nothing else, nowhere else.
  printf '%s\tCPU=%s+%s=%ss %s meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=%s load1=%s %s (%s, rc=%s)' \
    "$base" "$user" "$sys" "$total" "$host" "$cpus" "$load1" "$stamp" "$note" "$subject_rc"
  if [ "$host" = 'FOREIGN' ]; then
    printf ' runner=%s run=%s sha=%s' \
      "${RUNNER_OS:-unknown}" "${GITHUB_RUN_ID:-unknown}" "${GITHUB_SHA:-unknown}"
  fi
  printf '\n'

  # THE SENTENCE, ON STDERR, BESIDE THE FIGURE. Not on stdout: the row above is
  # PASTEABLE into the ledger by contract ("one pasteable row, nothing else"),
  # and a sentence inside it would be pasted into a ledger cell. stderr keeps it
  # on the same terminal, next to the number, where a reader quoting the figure
  # cannot miss it, without making it part of the artefact.
  pds_blind_spot_note \
    "bash times builtin around LC_ALL=$PDS_DOOR_MEASURE_METER_LC bash -c — an OS meter around a SHELL, outside every BEAM (PDS-D633 placement (a))" \
    "$base" >&2
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
    pds-fx-tail.sh pds-fx-sigil.sh pds-fx-long.sh; do
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

  # SIGIL (pds-w45-argspan-sigil-and-silent-bound, hole 1) — a System.cmd whose
  # argument list carries a pipe-delimited sigil holding an UNBALANCED open
  # paren (legal Elixir: no escaping needed outside paired delimiters). The
  # bound instrument is only File.regular?-checked AFTER that call. A
  # sigil-blind scanner counts the paren as structure, never balances, and the
  # overrun span swallows the File.regular? line — admitting a fraudulent
  # LEGA-BOUND-EXEC. Correct classification: BOUND-UNEXEC.
  cat >"$tmp/api/test/barkpark/sigil_test.exs" <<'EOF'
defmodule SigilTest do
  use ExUnit.Case, async: false
  @sigil_rel "../../../scripts/pds-fx-sigil.sh"
  test "sigil paren must not open a structural span" do
    {_o, 0} = System.cmd("echo", [~s|an ( unbalanced paren|])
    assert File.regular?(Path.expand(@sigil_rel, __DIR__))
  end
end
EOF

  # LONG SPAN (hole 2) — an argument list whose closing paren sits past the
  # 40-line bound, with the bound token BEYOND the bound. The old behaviour was
  # a silent BOUND-UNEXEC (an honest door declined quietly); now the truncation
  # is NAMED beside the verdict, and the table turns it into an ERROR row.
  {
    printf 'defmodule LongTest do\n'
    printf '  use ExUnit.Case, async: false\n'
    printf '  @long_rel "../../../scripts/pds-fx-long.sh"\n'
    printf '  test "an argument list longer than the span bound" do\n'
    printf '    {_o, 0} = System.cmd("echo", [\n'
    for i in $(seq 1 42); do printf '      "filler-%d",\n' "$i"; done
    printf '      Path.expand(@long_rel, __DIR__)\n'
    printf '    ])\n'
    printf '  end\n'
    printf 'end\n'
  } >"$tmp/api/test/barkpark/long_test.exs"

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
  check "SIGIL: an unbalanced paren inside ~s|...| is CONTENT, not structure" \
    BOUND-UNEXEC pds-fx-sigil.sh
  check "LONG SPAN: a 40-line-plus argument list is NAMED truncated, never a silent decline" \
    "BOUND-UNEXEC,SPAN-TRUNCATED" pds-fx-long.sh

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

  # ---- THE HOST AXIS IN THE GRAMMAR (wave 48) -----------------------------
  # THREE DIRECTIONS, and the third is the one that makes the widening safe. A
  # LOCAL price passes (the CONTROL arm at the top of this block is that same
  # direction), a FOREIGN price passes, and a price wearing NEITHER token REDS.
  # Widening the glob without this last arm converts a pin into a hole: the
  # mutation that proves the pin (relabel one price) would then pass silently.
  census_run "$d_ok" "$(printf 'pds-fx-through.sh\tCPU=0.01+0.01=0.02s LOCAL meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=2 load1=1.00 2026-08-04 (fixture)')"
  census_arm "HOST AXIS: a LOCAL price PASSES" 0 \
    'ERRORS                  : 0' 'THROUGH a required gate : 1 of 2'

  census_run "$d_ok" "$(printf 'pds-fx-through.sh\tCPU=0.01+0.01=0.02s FOREIGN meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=2 load1=1.00 2026-08-04 (fixture)')"
  census_arm "HOST AXIS: a FOREIGN price PASSES" 0 \
    'ERRORS                  : 0' 'THROUGH a required gate : 1 of 2'

  census_run "$d_ok" "$(printf 'pds-fx-through.sh\tCPU=0.01+0.01=0.02s meter=bash-times-builtin-around-LC_ALL=C-bash-c cpus=2 load1=1.00 2026-08-04 (fixture)')"
  census_arm "HOST AXIS: a price wearing NEITHER LOCAL NOR FOREIGN REDS, and is NAMED" 1 \
    'LOCAL or FOREIGN, one of the two, never neither' 'pds-fx-through.sh' \
    'THROUGH a required gate : 1 of 2'

  # ---- THE METER (wave 48, PDS-D663/D669/D691) ----------------------------
  # THE ARMS BELOW STAGE BOTH DEPTH STATES DELIBERATELY, and that is why three
  # of them carry `PDS_DOOR_MEASURE_DEPTH=`. `--selftest` is itself a PRICED
  # gated arm, so `--measure pds-door-census.sh --selftest` must be able to run
  # it — and inside that metered subtree every arm here inherits DEPTH=1 and the
  # guard would refuse the arms that are supposed to succeed, taking the census's
  # own price with them. A harness staging a condition is not a meter nesting
  # inside a meter: the guard arm SETS the depth explicitly, the arms that need a
  # working meter CLEAR it explicitly, and both are visible in one place rather
  # than inferred from an env var's history.
  local self_path measure_out measure_rc witness comma_locale sum_ok sum_bad raw_fab
  self_path="${BASH_SOURCE[0]}"

  # THE DEPTH GUARD FIRES. `--measure` inside a metered subtree prices the
  # meter, which is what a GATED --measure looks like from the inside. This is
  # PDS-D669 as a runnable fact rather than a comment.
  set +e
  measure_out="$(PDS_DOOR_MEASURE_DEPTH=1 bash "$self_path" --measure pds-door-census.sh --via true 2>&1)"
  measure_rc=$?
  set -e
  case "$measure_out" in
    *'PDS_DOOR_MEASURE_DEPTH=1 is already set'*) sum_ok=yes ;;
    *) sum_ok=no ;;
  esac
  if [ "$measure_rc" = '4' ] && [ "$sum_ok" = 'yes' ]; then
    echo "  PASS  THE DEPTH GUARD FIRES: --measure inside a metered subtree refuses rc=4 and prints nothing"
    pass=$((pass + 1))
  else
    echo "  FAIL  --measure under PDS_DOOR_MEASURE_DEPTH=1 exited $measure_rc (wanted 4): $measure_out"
    fail=$((fail + 1))
  fi

  # IT IS NEVER GATED — the witness direction, both ways. A `--check` run must
  # leave the witness ABSENT; a `--measure` run must create it. If anyone wires
  # the meter into the census's verification path, the first leg reds.
  witness="$tmp/measure-witness"
  rm -f "$witness"
  set +e
  PDS_DOOR_MEASURE_WITNESS="$witness" PDS_DOOR_CENSUS_ROOT="$croot" \
    bash "$self_path" --check >/dev/null 2>&1
  set -e
  if [ ! -e "$witness" ]; then
    rm -f "$witness"
    set +e
    PDS_DOOR_MEASURE_WITNESS="$witness" PDS_DOOR_MEASURE_DEPTH= bash "$self_path" --measure pds-door-census.sh --via true >/dev/null 2>&1
    set -e
    if [ -e "$witness" ]; then
      echo "  PASS  --check NEVER invokes --measure (witness absent), and --measure does (witness present)"
      pass=$((pass + 1))
    else
      echo "  FAIL  the witness is not written by --measure either, so its absence after --check proves nothing"
      fail=$((fail + 1))
    fi
  else
    echo "  FAIL  a --check run touched the --measure witness: the meter is on the verification path (PDS-D669)"
    fail=$((fail + 1))
  fi
  rm -f "$witness"

  # ---- THE WIDENED DENOMINATOR (wave 49) ---------------------------------
  #
  # Three arms, and the second is the only non-vacuous one: a band that cannot
  # be LEFT is a label, not a classification. The fixture root is its own tree so
  # the counts above are untouched by it.
  local wroot saved_croot
  wroot="$tmp/widened"
  mkdir -p "$wroot/scripts" "$wroot/tooling/pds" "$wroot/api/test/barkpark"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$wroot/scripts/pds-fx-shut.sh"
  printf 'export const K = 1;\n' >"$wroot/tooling/pds/fx-lib.mjs"
  printf '#!/usr/bin/env node\nimport { K } from "./fx-lib.mjs";\nprocess.exit(K - 1);\n' \
    >"$wroot/tooling/pds/fx-main.mjs"

  local w_d
  w_d="$(printf 'pds-fx-shut.sh\tENVIRONMENT\tfixture: needs a credential it will never have.\nfx-main.mjs\tENVIRONMENT\tfixture: reads a live board.')"

  saved_croot="$croot"
  croot="$wroot"

  census_run "$w_d" ''
  census_arm "THE DENOMINATOR REACHES tooling/pds: population 3, and the .mjs count is printed" 0 \
    'tooling/pds/*.mjs' 'population    : 3 (1 .sh + 0 .exs + 2 .mjs)' \
    'tooling/pds/fx-lib.mjs' 'tooling/pds/fx-main.mjs' \
    'LIBRARY-MODULE          : 1 of 3' 'UNDISPOSED              : 0 of 3' \
    'ACCOUNTED FOR           : 3 of 3'

  # THE MUTATION. A shebang on the library makes it a program, and a program with
  # no ledger row is UNDISPOSED and reds. If this arm cannot go red, LIBRARY-MODULE
  # is a place rows go to be forgotten rather than a fact re-derived from the tree.
  printf '#!/usr/bin/env node\nexport const K = 1;\n' >"$wroot/tooling/pds/fx-lib.mjs"
  census_run "$w_d" ''
  census_arm "MUTATION: a shebang makes the library a PROGRAM, so it LEAVES the band and reds" 1 \
    'LIBRARY-MODULE          : 0 of 3' 'UNDISPOSED              : 1 of 3' \
    'tooling/pds/fx-lib.mjs'
  printf 'export const K = 1;\n' >"$wroot/tooling/pds/fx-lib.mjs"

  # THE SECOND MUTATION, in the other direction: an UNIMPORTED module with no
  # shebang is NOT a library -- nothing reads it -- so it must NOT be waved
  # through. This is the arm that stops the band from becoming "anything without
  # a shebang".
  printf 'export const ORPHAN = 1;\n' >"$wroot/tooling/pds/fx-orphan.mjs"
  census_run "$w_d" ''
  census_arm "MUTATION: a module NO sibling imports is UNDISPOSED, not a library" 1 \
    'LIBRARY-MODULE          : 1 of 4' 'UNDISPOSED              : 1 of 4' \
    'tooling/pds/fx-orphan.mjs'
  rm -f "$wroot/tooling/pds/fx-orphan.mjs"

  croot="$saved_croot"

  # THE COLLISION TRIPWIRE, fired directly. It is unreachable through today's
  # globs (disjoint extensions), so an arm through run_census would be vacuous;
  # this one feeds the predicate the list a future widening would produce.
  local coll_hit coll_clean
  coll_hit="$(basename_collisions "$(printf 'pds-a.sh\npds-b.sh\npds-a.sh')")"
  coll_clean="$(basename_collisions "$(printf 'pds-a.sh\npds-b.sh\ntooling-c.mjs')")"
  if [ "$coll_hit" = 'pds-a.sh' ] && [ -z "$coll_clean" ]; then
    echo "  PASS  the basename-collision tripwire names the collision [$coll_hit] and stays silent without one"
    pass=$((pass + 1))
  else
    echo "  FAIL  the collision tripwire gave [$coll_hit] on a colliding list and [$coll_clean] on a clean one —"
    echo "        both ledgers are keyed by basename, so a collision it cannot see is one row answering for two"
    fail=$((fail + 1))
  fi

  # THE SUMMER IS FAIL-CLOSED ON RADIX, and the fabrication is QUOTED beside the
  # refusal so the arm shows what it is refusing. Host-independent: it needs no
  # locale installed, because it feeds the summer the bytes a comma-radix meter
  # would have produced.
  raw_fab="$(LC_ALL=C awk '
    { gsub(/[ms]/, " "); u += $1 * 60 + $2; s += $3 * 60 + $4 }
    END { printf "%.2f", u + s }
  ' <<'EOF'
0m0,527s 0m0,820s
0m0,000s 0m0,000s
EOF
  )"
  set +e
  measure_out="$(measure_sum "$(printf '0m0,527s 0m0,820s\n0m0,000s 0m0,000s')" 2>&1)"
  measure_rc=$?
  set -e
  sum_ok="$(measure_sum "$(printf '0m0.527s 0m0.820s\n0m0.000s 0m0.000s')")"
  if [ "$raw_fab" = '0.00' ] && [ "$measure_rc" = '5' ] && [ "$sum_ok" = '0.53 0.82 1.35' ]; then
    echo "  PASS  THE SUMMER REFUSES COMMA-RADIX times OUTPUT (an unguarded awk fabricates ${raw_fab}s out of a real 1.35s), and sums dot-radix correctly"
    pass=$((pass + 1))
  else
    echo "  FAIL  unguarded awk gave [$raw_fab] (wanted 0.00), the guarded summer exited $measure_rc (wanted 5)"
    echo "        and the dot-radix control summed to [$sum_ok] (wanted 0.53 0.82 1.35) — a summer that"
    echo "        returns a silent 0 instead of refusing is PDS-D691's fabrication, shipped"
    fail=$((fail + 1))
  fi

  # THE SUMMER'S OWN PIN, REMOVED. awk's strtod is locale-bound in BOTH
  # directions and so is its printf, so an unpinned summer misreads dot-radix
  # input under a comma locale — measured here, not asserted: LC_ALL=nb_NO awk
  # on `0.527 0.820` prints `0,00`.
  comma_locale="$(measure_comma_locale || true)"
  if [ -n "$comma_locale" ]; then
    set +e
    measure_out="$(PDS_DOOR_MEASURE_SUM_LC="$comma_locale" measure_sum "$(printf '0m0.527s 0m0.820s\n0m0.000s 0m0.000s')" 2>&1)"
    measure_rc=$?
    set -e
    if [ "$measure_rc" = '5' ]; then
      echo "  PASS  THE SUMMER PIN IS LOAD-BEARING: with LC_ALL=$comma_locale it fabricates and the guard reds it"
      pass=$((pass + 1))
    else
      echo "  FAIL  with the summer pin removed (LC_ALL=$comma_locale) the summer exited $measure_rc, not 5: $measure_out"
      echo "        a meter-only pin is a hole — the arithmetic reads the meter's output and is locale-bound too"
      fail=$((fail + 1))
    fi
  else
    echo "  PASS  THE SUMMER PIN: no comma-radix locale is installed on this host, so removing the pin"
    echo "        cannot be staged HERE and this leg is degenerate — SAID rather than counted as proof."
    echo "        The fail-closed refusal arm above is what holds on such a host."
    pass=$((pass + 1))
  fi

  # THE METER'S OWN PIN. Under a comma-radix locale a glibc `times` prints
  # `0m0,724s`; darwin's bash 3.2 ignores LC_NUMERIC there. The arm asserts the
  # property that must hold on EITHER libc: no comma-decimal figure ever escapes
  # into a row. Deleting the summer's radix guard reds this on glibc.
  if [ -n "$comma_locale" ]; then
    set +e
    measure_out="$(PDS_DOOR_MEASURE_METER_LC="$comma_locale" PDS_DOOR_MEASURE_DEPTH= bash "$self_path" --measure pds-door-census.sh --via true 2>&1)"
    measure_rc=$?
    set -e
    # THE FIGURE ITSELF, never the whole line: the row's trailing note carries
    # commas of its own (`(--check, rc=0)`), and a naive `*','*` scan reds on
    # them — a detector that fires on a legal row is not a detector.
    local fig
    fig="$(printf '%s' "$measure_out" | LC_ALL=C awk -F'\t' 'NF > 1 { split($2, a, " "); print a[1] }')"
    case "$fig" in
      *,*) sum_bad=yes ;;
      *) sum_bad=no ;;
    esac
    if [ "$sum_bad" = 'no' ]; then
      echo "  PASS  THE METER PIN: under LC_ALL=$comma_locale no comma-decimal figure escapes (rc=$measure_rc — refused on glibc, dot-radix on a libc that ignores LC_NUMERIC in \`times\`)"
      pass=$((pass + 1))
    else
      echo "  FAIL  a comma-decimal CPU figure escaped the meter under LC_ALL=$comma_locale: $measure_out"
      echo "        that is a REAL measurement rendered ~2.5x LOW, and the ledger's substring globs accept it"
      fail=$((fail + 1))
    fi
  else
    echo "  PASS  THE METER PIN: no comma-radix locale on this host, so the meter's pin cannot be"
    echo "        removed observably here — degenerate leg, SAID rather than counted as proof."
    pass=$((pass + 1))
  fi

  # THE HOST AXIS IS PORTABLE. Both fallbacks are FORCED, so the darwin leg is
  # exercised on linux and vice versa: `nproc` and /proc/loadavg do not exist on
  # macOS, and without these the axis would be linux-only by accident.
  local cpus_fb load_fb cpus_nat load_nat
  cpus_fb="$(PDS_DOOR_MEASURE_NO_NPROC=1 measure_cpus || printf 'REFUSED')"
  load_fb="$(PDS_DOOR_MEASURE_NO_PROCLOAD=1 measure_load1 || printf 'REFUSED')"
  cpus_nat="$(measure_cpus || printf 'REFUSED')"
  load_nat="$(measure_load1 || printf 'REFUSED')"
  case "$cpus_fb$cpus_nat" in
    *[!0-9]*) sum_ok=no ;;
    '') sum_ok=no ;;
    *) sum_ok=yes ;;
  esac
  case "$load_fb" in
    '' | *[!0-9.]*) sum_ok=no ;;
  esac
  case "$load_nat" in
    '' | *[!0-9.]*) sum_ok=no ;;
  esac
  if [ "$sum_ok" = 'yes' ]; then
    echo "  PASS  THE HOST AXIS IS PORTABLE: cpus=$cpus_nat (getconf fallback: $cpus_fb), load1=$load_nat (uptime fallback: $load_fb)"
    pass=$((pass + 1))
  else
    echo "  FAIL  the host axis did not derive on both paths: cpus native=$cpus_nat fallback=$cpus_fb,"
    echo "        load1 native=$load_nat fallback=$load_fb — a REFUSED leg means a price could ship"
    echo "        without a cpu count or a load stamp on one of the two operating systems"
    fail=$((fail + 1))
  fi

  # --measure WRITES NOTHING. The instrument that feeds the ledger must not be
  # able to edit it: checksummed before and after a real metered run, together
  # with the scripts directory listing, so a new file counts as a write too.
  local snap_before snap_after
  snap_before="$(cksum <"$self_path")|$(ls -1 "$SCRIPT_DIR" | cksum)"
  set +e
  PDS_DOOR_MEASURE_DEPTH= bash "$self_path" --measure pds-door-census.sh --via true >/dev/null 2>&1
  set -e
  snap_after="$(cksum <"$self_path")|$(ls -1 "$SCRIPT_DIR" | cksum)"
  if [ "$snap_before" = "$snap_after" ]; then
    echo "  PASS  --measure WRITES NOTHING: the census file and the scripts directory are byte-identical after a metered run"
    pass=$((pass + 1))
  else
    echo "  FAIL  --measure changed the tree it prices: [$snap_before] -> [$snap_after]"
    fail=$((fail + 1))
  fi

  echo
  printf '%s\n' "$BLIND_SPOT"
  echo
  pds_blind_spot_note \
    "the PRICE column above: every row is an OS meter around a SHELL (bash times builtin around LC_ALL=C bash -c), taken by --measure, never inside a BEAM parent" \
    "the price column"
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
  --measure)
    shift
    if [ $# -lt 1 ]; then
      echo "$SELF: --measure needs the basename of the instrument the row is for" >&2
      echo "usage: $0 --measure <basename> [arg...] | --measure <basename> --via '<command>'" >&2
      exit 2
    fi
    run_measure "$@"
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
