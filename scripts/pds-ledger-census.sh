#!/usr/bin/env bash
#
# PDS LEDGER CENSUS — re-derive the Personal Development Server epic's board
# from the ledger itself, and FAIL LOUDLY on every lens that silently
# undercounts it.
#
# WHY A SCRIPT AND NOT A PAPER. A number that lives only in a Paper is a number
# nobody can re-derive. The epic's law is that no verb may report success on an
# exit code alone; a census is a verb whose whole output is a success claim
# ("the board is N rows, M of them live"), so it is exactly the verb most able
# to lie. Every clause below was EARNED by a silent undercount measured against
# the live board during wave 24 — each one exits 0 today and reports a SMALLER
# board with no error, which is the vacuous green this instrument exists to
# make impossible.
#
# THE FIVE CLAUSES, AND THE MEASUREMENT BEHIND EACH
#
#   (1) PAGE, AND PROVE THE PAGE WAS HONOURED.
#       GET /v1/data/query/production/task?limit=5000 returns HTTP 200 and
#       `result.limit: 1000` — the server silently caps and never says so.
#       Measured 2026-07-30: asked 5000, echoed 1000, 1000 documents. A reader
#       that trusts its own request builds a 127-descendant closure and exits
#       0 — a ~54% undercount with no error anywhere. So: page by EXPLICIT
#       offsets until a short page, and assert on every page that the server
#       echoed back the limit and offset that were ASKED FOR. A cap that is
#       not echoed honestly is a transport failure, not a smaller board.
#
#   (2) WALK THE TRANSITIVE CLOSURE OVER parent_id — NEVER `.children`.
#       `bp task get <root> | .children` is a ONE-LEVEL read: 179 rows against
#       a closure of 285 descendants / 168 live, with 57 live rows hanging
#       under done/cancelled parents. Re-measured here 2026-07-30 with this
#       script: `--lens children` drops 106 rows (181 of 287) and the fixpoint
#       assertion names every one of them, e.g. pds-bl-bandit-request-line-
#       ceiling under pds-w1-crown-proof. A `.children` census scores ~63% of
#       the board and greens. `blocked` appears in the closure and NOWHERE at
#       level 1, so a status vocabulary built from `.children` does not even
#       know `blocked` is legal. The guard is not "use the right lens" (a
#       classification string, which is what wave 23 refused to ship) but a
#       BEHAVIOURAL fixpoint assertion: after the walk, no row anywhere in the
#       fully-paged corpus may have a parent inside the closure while sitting
#       outside it. A one-level lens violates that on its first grandchild.
#       `--lens children` exists ONLY so the selftest can inject that lens and
#       watch the fixpoint assertion catch it.
#
#   (3) SCORE ON HTTP STATUS AND AN ASSERTED SHAPE — NEVER AN ENVELOPE KEY,
#       NEVER "json.load SUCCEEDED".
#       /v1/data/* fails with {"ok":false,"error":{"code":...}}; /v1/tasks/*
#       fails with {"ok":false,"reason":...}. A census keyed on `error.code`
#       reads every tasks-API failure as a success. Worse, the 429 body
#       {"ok":false,"error":{"code":"rate_limited"}} is VALID JSON, so a
#       "did it parse?" test reads a rate limit AS DATA and counts the row as
#       a leaf. Here: the HTTP status decides first, and a 2xx still has to
#       produce a body of the asserted shape (result{count,offset,limit,
#       documents:list}) before a single row is counted.
#
#   (4) SERIAL, PACED, WITH BACKOFF.
#       A 10-way parallel walk of the same board returned 191 of 285 nodes and
#       exited 0, caching five rate-limited responses AS DOCUMENTS. guerrilla
#       rate-limits hard under concurrent wave load, and `bp` re-fetches
#       /v1/capabilities on EVERY invocation against the same budget, where a
#       429 surfaces as a config-shaped BARKPARK_MANIFEST error that looks
#       nothing like rate limiting. This instrument therefore issues its own
#       requests, one at a time, paced, and treats 429 as retry-then-fail —
#       never as an empty page. Deriving the closure from the paged corpus
#       (a handful of requests) rather than fetching each of 285 nodes is the
#       same closure at ~1/50th the request budget.
#
#   (5) NAME THE INSTANT AND ASSERT COHERENCE.
#       A census is a snapshot or it is an average. The window is named in the
#       output, and any row in the closure whose _updatedAt lands INSIDE that
#       window (or any row served twice across pages) makes the run exit 4:
#       the board moved under the read, so re-run it. Silence about drift is
#       how an average gets quoted as a snapshot.
#
# THE DONE-CONDITION. `--assert-round-done` demands that every non-empty
# disposition_reason be DISTINCT (distinct reason hashes == non-empty reasons)
# and that zero rows carry an off-vocabulary disposition. It is honestly RED on
# today's board — a done-condition that is green before the work is done is not
# a done-condition. Measured 2026-07-30: 145 non-empty reasons collapsing to
# 127 distinct hashes (the 18-row boilerplate gap), 78 off-vocabulary
# dispositions. Exit 1.
#
# CLAUSE 4 OF THE DONE-CONDITION — LIVE COVERAGE (wave 25, PDS-D346/D347).
# Clauses 1-3 above are CLOSURE-scoped and they are correctly so: distinctness
# and vocabulary are properties of everything ever written. But they are all
# satisfiable by a board that says NOTHING. A live row with no disposition lands
# in the `<unset>` bucket no clause reads; a blank reason is skipped before it is
# hashed; an unset disposition is skipped before it is scored. So the predicate
# that is supposed to certify "the round adjudicated the board" could go green
# over a board where every LIVE row is silent — the exact vacuous green this
# instrument exists to make impossible. Clause 4 is therefore the ONE
# LIVE-scoped clause, with three sub-lines that each say no on their own:
#
#   (a) a LIVE row with no disposition at all — it says nothing;
#   (b) a LIVE row that carries a disposition but no disposition_reason — it
#       asserts a verdict it cannot prove;
#   (c) a LIVE `parked` row with no STRUCTURED `reopen_trigger` — a park with
#       no machine-evaluable way back out is a park nobody will ever revisit.
#
# CLAUSE 6 — THE CLAIMABLE-AND-CLOSED CONTRADICTION (wave 27, PDS-D372/D373).
# Clause 4 asks whether a live row SAYS anything. It never asks whether what the
# row says AGREES with what the queue does with it. Measured on the live board
# 2026-07-31: THIRTEEN closure rows are simultaneously lifecycle-claimable and
# disposition-`closed`. Clause 4(a) counts every one of them in its numerator as
# SATISFIED — they carry a disposition — while `bp task ready` hands them to a
# worker, because `queue.ex` does not read `disposition` at all
# (`git show origin/main:api/lib/barkpark/tasks/queue.ex | grep -c disposition`
# -> 0). No instrument anywhere looks at the pair, so the row is adjudicated
# closed on one axis and dispatched as work on the other. That is not a missing
# field; it is two organs of the same system reporting opposite truths, which is
# exactly the lie class this epic exists to kill.
#
# CLOSED-ONLY, AND THAT IS RULED (PDS-D372). The clause fires on `closed` and on
# nothing else. Extending it to `parked` was measured and is REFUSED ON THE
# RECORD: it fails 7 of 80 selftest checks, and the FIRST failure is the CONTROL
# — build_healthy's `kid-c` is `blocked parked`, inherited by all 34 fixture
# dirs — and it reds SHAREDTRIG, the fixture that exists specifically so no
# future wave can quietly tighten clause 4 (PDS-D336(a)). Live, all 29 parked
# closure rows carry a STRUCTURED reopen_trigger. A live park awaiting its
# trigger is not a contradiction; it is a park, and clause 4(c) already owns it.
#
# THE VOCABULARY IS THE GUARD (PDS-D373). The match is against the NORMALISED
# vocabulary and is CASE-EXACT, exactly like every other disposition read here:
# an unrecognised disposition is treated as LIVE and is clause 3's business, not
# this clause's. Store-wide there are 41 off-vocabulary values, 26 of them `tgw*`
# rows carrying the literal prose `open — demoted child of truth-grip-epic
# (charter D117)`. A rule phrased `disposition IS NOT NULL AND != 'open'` would
# silently sweep 26 rows out of a NEIGHBOUR EPIC's queue — the same undercount,
# committed by the instrument that exists to catch it.
#
# IT REPORTS A WORKLIST, NEVER A COUNT. `live_contradiction` is a ROW-ID LIST:
# a count nobody can turn back into rows is not a worklist.
#
# (c) READS `reopen_trigger` AND NOTHING ELSE. It deliberately does NOT inherit
# the REOPEN_TRIGGER_RE prose match used by the display counter below: prose
# that says "REOPEN: when the cap lifts" inside a reason is DECORATION, not a
# field a script can evaluate, and PDS-D336(b) condemns scoring it by name. The
# two are reported side by side and NEVER summed — on the live board of
# 2026-07-30 that is 0 structured against 40 prose-only, and a summed counter
# would have read 40 and called it coverage.
#
# CLAUSE 4(a) IS ROUND-ANCHORED (wave 26, PDS-D364/D365). Clause 4(a) as wave 25
# shipped it is STRUCTURALLY UNREACHABLE by any round that discovers work: a row
# is BORN with no disposition, so a round that files a single new row can never
# satisfy "every live row carries a disposition" at the instant it wants to
# certify. Wave 25 ended with 19 bare rows that were ITS OWN residue. The fix is
# not to weaken the clause but to say WHICH ROUND it is asking about:
#
#   --anchor-from-paper <wave-slug> resolves GET /v1/data/doc/<dataset>/paper/
#   <slug> and reads `result._createdAt` -- the instant the round was born.
#   4(a) then asserts over the live rows that existed AT OR BEFORE that instant,
#   and every live bare row born AFTER it is printed as a NAMED residue list:
#   the next round's inbox, not this round's failure.
#
# THE ANCHOR IS DERIVED, NEVER ARGUED. `--anchor 2020-01-01T00:00:00Z` was
# measured on the LIVE board to flip 4(a) from `157/172 FAIL` to `172/172 PASS`
# -- a round could seal itself by argv. So the raw `--anchor` is reachable ONLY
# under --fixture-dir (it is the selftest's clock), and --anchor-from-paper FAILS
# CLOSED on a non-200 or an unreadable `_createdAt`. It NEVER falls back to now():
# an anchor at now() is an anchor that excuses every row the round just filed.
#
# ...AND THE DERIVATION IS BOUND TO THE ROUND IT CERTIFIES (wave 28). Deriving
# the instant from a Paper closed only half the hole: NOTHING checked that the
# Paper IS this round's. A caller passing an EARLIER wave's slug gets an EARLIER
# anchor, which makes MORE rows fall after it and be deferred as residue -- a
# greener 4(a) reached by MOVING THE BOUNDARY rather than by adjudicating, which
# is the same vacuous green under a different verb. The round already names its
# own Paper: the epic root row carries `wave_paper` (ROUND_ANCHOR_FIELD below),
# and /v1/data/query flattens content.* to the top level, so it arrives in the
# corpus this census already pages -- no second read, nothing to keep in sync.
# So:
#
#   * with NO anchor flag, the anchor is DERIVED from the root's `wave_paper`;
#   * `--anchor-from-paper <slug>` that DISAGREES with it is REFUSED (exit 3);
#   * `--anchor-unbound` accepts the disagreement and SAYS SO, in the human
#     render and as `round_anchor_binding: "override"` in --json;
#   * a root that declares no `wave_paper` cannot bind anything, and that is
#     reported as `unverifiable` -- never as a silent pass;
#   * `--no-anchor` opts back INTO the unanchored clause. It is the only opt-out
#     and it is strictly STRICTER, so it can never seal a round.
#
# The binding therefore lives in the report as well as in the guard: a
# certifying run proves which round it anchored on instead of being trusted.
#
# IT TERMINATES, AND THAT WAS OBSERVED, NOT ARGUED. Anchored at wave 25's Paper
# the live board reports residue 14 and 4(a) 171/172; anchored at wave 26's,
# residue 0 and 4(a) 157/172. The SAME 14 rows are residue for round N and
# in-scope for round N+1 -- deferred by exactly one round, never forever, and
# adjudicating a row files no new rows.
#
# FAIL CLOSED ON A ROW THE PREDICATE CANNOT PLACE. A live bare row with a missing
# or unreadable `_createdAt` exits 2, exactly as clause 5 does for `_updatedAt`.
# A row that cannot be placed on either side of the anchor must never be silently
# excused into the residue.
#
# THE ANCHOR ENTERS IN EXACTLY ONE PLACE: census()'s clause-4(a) live subset. It
# does NOT touch build_closure or read_corpus -- the closure stays WHOLE or the
# fixpoint assertion stops being able to catch a truncated walk (PDS-D347: clause
# 4 is added BESIDE clauses 1-3 and never rescopes them). 4(b) and 4(c) stay
# whole-live: a row that HAS a disposition owes a reason regardless of birth.
#
# CLAUSE 5 IS ORTHOGONAL AND STAYS SO. Its window is THIS CENSUS'S OWN READ
# WINDOW (`started` below, measured 17.9-30.8s wide live), not the round window.
# Widening it to the round window would trip on every residue write by
# construction and make a certifying run impossible. Because exit 4 fires BEFORE
# the predicate block prints, the operational rule is:
#
#     ADJUDICATE -> QUIESCE -> CERTIFY
#
# adjudicate the board, stop writing to it, and only then run the census with
# --assert-round-done --anchor-from-paper <this wave's Paper>. Exit 4 is
# retryable and means only "you were still writing"; re-run once quiet.
#
# PDS-D336(a) is pinned in the other direction too: triggers are NOT required to
# be distinct. One family trigger over several distinct reasons ("REOPEN when
# the Hetzner rate cap lifts") is legitimate and is what the board's best rows
# already do; only REASONS must be distinct.
#
# THE KEY PATH IS SETTLED: /v1/data/query FLATTENS content.* to the top level,
# so reading `disposition` / `disposition_reason` / `reopen_trigger` off the row
# is correct and an absence measured here is a REAL absence. Do not add a
# content-unwrapping normaliser: 13 corpus rows carry a literal top-level
# `content` key and one of them is null, so unwrapping would corrupt the read.
#
# CASE IS PART OF THE VALUE. Dispositions are counted CASE-EXACT, so `OPEN`
# (67 rows on 2026-07-30) and `open` (44) are two different things and the
# split is visible rather than averaged away. `open` is the canonical form and
# lives in one named constant (CANONICAL_OPEN) — change it there, nowhere else.
#
# STDOUT IS THE MACHINE CHANNEL AND NOTHING ELSE (wave 27). `--json` used to
# dump the report and THEN write the human VERDICT / ROUND-DONE PREDICATE block
# to the SAME stdout, so `jq -e .` exited 5 ("Invalid numeric literal") — and the
# GREEN path was poisoned identically: on a healthy fixture the run exited 0 and
# jq still failed. The certificate was unpipeable exactly when it certified.
# UNDER `--json` the whole human block therefore goes to STDERR, beside the
# failure VERDICT that already did. Under the DEFAULT render stdout is the human
# channel already (the report is printed there), so the block stays with the
# report it belongs to — otherwise `census.sh --assert-round-done > report.txt`
# would silently lose the verdict it was run for. ONE `human` stream variable
# decides, so the two modes cannot drift. The predicate is also folded into the
# payload as `round_done` (bool) + `round_done_failures` (list) so a scripted
# consumer has a machine path rather than a stream to scrape.
#
# THE EMIT IS NEVER DEFERRED. The predicate is a PURE function of `report`
# (round_done_predicate) computed BEFORE the single emit site, precisely so the
# emit stays where it is. Computing it after the emit — the obvious refactor —
# was measured and is a FRESH honesty regression inside the honesty fix: the
# clause-5 incoherence path (exit 4) runs AFTER the emit and still prints a
# valid 985-byte payload today, and a deferred emit turns that into rc=4, 0
# bytes, jq rc=4. A run that fails is exactly when its payload matters most.
#
# THE PAGED READ HAS A TOTAL ORDER, AND ONLY ONE SPELLING IS CORRECT. Without an
# `order` param the query falls through to `desc: d.updated_at` — a MUTATING sort
# key paged by EXPLICIT offset. A concurrent write teleports its row to index 0
# and shifts every row between; proven live in six requests (a probe row at index
# 3 was NEVER SERVED, and offsets 0 and 1 both returned the same row). The
# duplicate half of that shift exits 4, but the concurrent-DELETE half shifts
# rows UP and produces no duplicate at all — a silent skip. So every page is
# requested with `&order=_createdAt:asc` (PAGE_ORDER below): measured immune —
# 3901 rows, zero `_createdAt` ties, globally sorted across four 1000-row pages,
# and a probe row held index 3894 across a stage write that put it at index 0
# under the default order. TWO TRAPS SIT ONE KEYSTROKE AWAY, and both are this
# epic's own lie class living in a URL param:
#   (a) `order=doc_id` (no direction) does NOT error. It fails
#       query_controller.ex's `<field>:(asc|desc)` regex and SILENTLY falls back
#       to updated_at DESC at HTTP 200. Probed live 2026-07-31: the id sequence
#       is IDENTICAL to sending no order at all, while a no-order pair taken in
#       the same interleave is stable — a "fix" spelled this way is a green diff
#       with zero behaviour change.
#   (b) `order=doc_id:asc` parses as a CONTENT field and sorts
#       jsonb_extract_path(content,'doc_id'), which is NULL for every task row.
#       An all-NULL sort key is an UNSPECIFIED order that can skip and duplicate
#       with no concurrent write at all — strictly worse than the bug.
#
# CLAUSE 7 — THE LEDGER LAPSE, AND WHY ONE KEY CANNOT SEE BOTH ITS SHAPES
# (wave 43, PDS-D638). Two waves running, slice rows lapsed to `open` with their
# work DONE — three in wave 41, two in wave 42 — and each debrief wrote the same
# paragraph about it. A lesson restated is not a lesson learned; it is a defect
# with good manners. So it stops being a paragraph here and becomes an arm with
# a fixture that can go red.
#
# `claim` rides /v1/data/query as a TOP-LEVEL doc key, so this arm reads a field
# already inside bytes the paged read above already fetched: ZERO extra requests,
# zero new transport, nothing to rate-limit.
#
# THE THREE SHAPES DO NOT SHARE A KEY, AND THAT IS THE WHOLE FINDING.
#
#   SHAPE A — REVERTED-TO-OPEN AFTER EXPIRY. Key: lifecycle_status == `open`
#   AND claim.worker is null AND claim.previous_worker is set AND
#   claim.expired_at is set AND there is NO claim.released_at AND NO
#   claim.closed_at. That is the TTL sweeper's exact fingerprint: a release
#   writes released_at, a close writes closed_at, and ONLY a lapse nulls worker
#   while preserving previous_worker. The row is now a RE-OPEN LIE — the board
#   offers work that was already done. `claim.now.text` is reported as a
#   sub-count, because a lapsed row that carries a now-line is one whose worker
#   was demonstrably mid-flight.
#
#   SHAPE B — IN_PROGRESS HELD BY A FINISHED WORKER, AND IT IS THE REASON THIS
#   ARM HAS TWO KEYS. A shape-B row DOES NOT CARRY expired_at, BY CONSTRUCTION:
#   the lease is still held and the REAP is what writes that field. A check
#   keyed on expired_at therefore passes VACUOUSLY on shape B, 100% of the time,
#   forever — the precise vacuous green this whole instrument exists to make
#   impossible, relocated into its own fix. Shape B's only honest key is
#   lifecycle_status == `in_progress` AND (the census's own named instant minus
#   claim.ts_iso) > the lease TTL (LEASE_TTL_SECONDS below: 2700s, overridable
#   by BARKPARK_TASK_LEASE_TTL_SECONDS, sweeper cron `* * * * *`). Shape B
#   self-heals INTO shape A within <= TTL+60s, so a live board simply has no
#   shape-B rows most instants — which is why the selftest INJECTS a synthetic
#   stale in_progress row rather than waiting for one. An arm that has never
#   fired is not an arm.
#
#   SHAPE C — OPEN WITH A CLAIM THAT WAS NEVER CLEARED. Key: lifecycle_status ==
#   `open` AND claim.worker is set AND claim.closed_at is set: a reopened row
#   still wearing the finished claim. A worker-keyed check reads it as HELD; an
#   expiry-keyed check ignores it entirely. Reported on its own line, never
#   folded into A or B, because its remedy is a third thing.
#
# THREE SHAPES, THREE REMEDIES, AND THE OUTPUT SAYS WHICH: A is a re-open lie
# (re-claim and close it on the evidence already on the row); B needs
# `bp task release` (it cannot self-heal while the lease is held); C needs the
# stale claim CLEARED. A single "lapsed: N" counter would name none of them.
#
# FAIL CLOSED ON A HELD ROW WHOSE LEASE CANNOT BE READ. An `in_progress` row
# carrying a claim with a worker but a missing or unreadable `claim.ts_iso`
# cannot be placed on either side of the TTL, and a row the arm cannot place is
# never silently counted as fresh — exit 2, exactly as clause 5 does for
# `_updatedAt` and clause 4(a) does for `_createdAt`.
#
# DECLARE THE LENS, AND DERIVE IT. /v1/data/query answers with
# perspective: published, so a lapsed DRAFT row is INVISIBLE to this arm and
# VISIBLE to `bp task ls --all` — the two disagree BY CONSTRUCTION, and one of
# the six fully-complete-but-open rows measured live on 2026-08-02 was a
# `drafts.` row. The perspective is read back off `result.perspective` and
# PRINTED rather than asserted in a comment: a lens nobody can read back is a
# claim.
#
# CLAUSE 8 — THE DENOMINATOR, AND THE REFUSAL BESIDE IT (wave 47)
#
# The open-PDS denominator had FIVE circulating answers (344 / 354 / 374 / 379 /
# 405). Settled by measurement, and one inherited premise REFUTED: `parent_id` is
# NOT mixed-keyed — 0 of 4,592 non-null values resolve as a UUID id and 4,537 as
# the slug, so the "344 UUID closure" was a DEPTH-1 TRUNCATION (a walk pushing
# `id` onto the frontier matches no parent_id and halts at level 1), never a
# lens. This census inherits no such hole: build_closure keys on the corpus's own
# `_id` — the space parent_id lives in — walks transitively and asserts a
# fixpoint.
#
# ONE FIELD: `lifecycle_status == "open"`, CASE-EXACT. NOT `disposition` (216
# live rows carry none, and a disposition-keyed denominator drops all of them).
# NOT "live / non-terminal" (that folds in `considering`, which by the task-funnel
# doctrine PRECEDES open — a considering row is not a claim that a defect is
# live). The number is DERIVED on every run and printed with its lens, its
# instant and the command that re-derives it. NOTHING pins it: it was 374 at
# 2026-08-04T12:35Z and the wave that measured it was filing rows as it read.
#
# AND THE COUNT NAMES WHAT IT CANNOT SEE. A denominator printed alone is a claim
# about a population nobody looked outside of, so the census prints a BLIND-SPOT
# block with NAMES, never a count:
#   (1) rows carrying the epic's slug prefix whose parent chain never reaches the
#       root — unreachable by ANY closure anchored there, at any depth, under any
#       key. Measured 2026-08-04: exactly one is open,
#       `pds-bl-merge-gated-criteria-carry-the-flag`, parented to a DIFFERENT
#       epic, and its subject is the merge-gated criteria class itself.
#   (2) a SECOND paged read at `perspective=drafts`, SPLIT by the published twin:
#       no twin = HIDDEN WORK (joins the honest total); a TERMINAL twin = a
#       PHANTOM, an unpublished edit shadow, and adding it OVERCOUNTS — this is
#       precisely how 379 was reached where 376 was honest.
# The drafts lens has an UNREAD state that is an ABSENCE and NEVER a zero: a
# tokenless or public-read caller is silently pinned to `published` by
# AnonPerspective, and counting that answer as "no drafts exist" would
# manufacture a clean board out of a permission the caller does not have.
#
# STATED AND NOT FIXED: the read pages by explicit offsets over `_createdAt:asc`,
# so a row created mid-page is invisible to it — and to any independent walk
# reading through the same pager. Two such walks agreeing does not rule it out.
#
# READ-ONLY. This instrument never writes, never creates, never publishes.
# Charter PDS-D334 (a bare patch writes the DRAFT and the published route
# serves the PRE-WRITE value for a variable 5-40s) is therefore not in play,
# and cannot be brought into play by a flag.
#
# NOT WIRED INTO CI. It is an instrument. Arming a gate on it is a separate
# decision the round has to make on its own evidence.
#
# EXIT CODES
#   0  census produced, coherent, and (if asked) the round-done predicate holds
#   1  --assert-round-done predicate is FALSE — the round is not done
#   2  FAIL CLOSED: transport, shape, pagination, lens or population failure.
#      Nothing is reported as a board. This is the exit code that a silent
#      undercount used to be able to dodge.
#   3  usage error
#   4  SNAPSHOT INCOHERENT: the board moved inside the named window. Re-run.
#
# USAGE
#   scripts/pds-ledger-census.sh [--root SLUG] [--page-limit N] [--pace SECS]
#                                [--retries N] [--lens closure|children]
#                                [--assert-round-done] [--json]
#                                [--anchor-from-paper WAVE-PAPER-SLUG]
#                                [--anchor-unbound] [--no-anchor]
#                                [--fixture-dir DIR] [--server URL]
#   bash scripts/pds-ledger-census_test.sh    # the mutation fixtures
#
# --fixture-dir DIR replaces the network with canned HTTP responses
# (DIR/page-<i>.http, first line "HTTP <status>", remainder the body; and
# DIR/paper-<slug>.http for the anchor read). It is the selftest's transport and
# the only reason the selftest can prove this instrument REDS rather than merely
# prove it runs. --anchor <ISO-8601> is the selftest's clock and is REFUSED
# outside --fixture-dir; a certifying run derives its anchor or has none.

set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "pds-ledger-census: python3 is required (stdlib only, no new deps)" >&2
  exit 3
fi

exec python3 -I - "$@" <<'PYEOF'
import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timezone

# --- ratified constants -------------------------------------------------------

# The PDS epic root. Every count in this census is relative to it.
DEFAULT_ROOT = "task-2ac1f95237c4a8e5"

# THE FIELD THAT BINDS THE ANCHOR TO THE ROUND. The epic root row names its own
# wave Paper here, and /v1/data/query flattens content.* to the top level (the
# settled key path, above), so this is read straight off the root row the corpus
# already carries. ONE constant: if the ledger ever renames the field, this line
# is the whole change -- and a rename that this line did not follow is reported
# as `unverifiable`, never as a pass.
ROUND_ANCHOR_FIELD = "wave_paper"

# The canonical case for the OPEN disposition. `OPEN` (67 rows on 2026-07-30)
# is off-vocabulary against it. ONE constant: if a later round ratifies the
# other case, this line is the whole change.
#
# WAVE-24 REVIEW CORRECTION (2026-07-30). This was `OPEN` as the wave brief
# instructed. The brief predates the same wave's D337 verb: `Tasks.Stage` now
# owns the triple and NORMALISES the term with String.trim/1 + String.downcase/1
# (`stage.ex` @dispositions ~w(open parked closed)), and it is the ONLY
# sanctioned writer. An uppercase canon is therefore UNREACHABLE by the only
# door that can write it — every governed row would count as off-vocabulary and
# `--assert-round-done` could never pass, on any board, forever. The writer is
# the normaliser, so the census follows the writer. Lowercase also matches the
# 27 `parked` template exemplars (PDS-D332) and the `lifecycle_status` idiom,
# so the round rewrites 67 rows rather than 71.
CANONICAL_OPEN = "open"

# The disposition that means "adjudicated closed". CLAUSE 6 matches THIS value
# CASE-EXACT and nothing else: `CLOSED` is off-vocabulary, so it is unrecognised,
# so it is treated as LIVE and left to clause 3. Treating anything unrecognised
# as closed is how a rule sweeps a neighbour epic's 26 prose-dispositioned rows
# out of its own queue (PDS-D373).
CLOSED_DISPOSITION = "closed"
DISPOSITION_VOCABULARY = (CANONICAL_OPEN, CLOSED_DISPOSITION, "parked")

# lifecycle_status values that mean the row is finished. Everything else --
# including `blocked`, which appears only in the closure and never at level 1 --
# counts as live.
TERMINAL_LIFECYCLE = ("done", "cancelled", "canceled")

# DISPLAY ONLY. A disposition_reason that MENTIONS a reopen trigger in prose.
# This regex scores decoration, so it is quarantined here: it feeds the
# `prose-only REOPEN mention` display counter and NOTHING else. The done
# condition's clause 4(c) reads the structured `reopen_trigger` field alone --
# see structured_trigger() -- because PDS-D336(b) condemns scoring prose.
REOPEN_TRIGGER_RE = re.compile(r"\b(RE-?OPEN|REACTIVATE)\b\s*(TRIGGER)?\s*[:\-]", re.I)

# The disposition value that means "parked", matched case-insensitively ONLY
# here: counting is case-exact everywhere else (that split is the finding), but
# a row must not be able to dodge the trigger requirement by shouting PARKED.
PARKED_DISPOSITION = "parked"

# CLAUSE 7's ONE TUNABLE: the task lease TTL, in seconds. `Tasks` reaps a claim
# that has not been renewed inside this window, so "held longer than this" is
# the ONLY honest key for shape B — expired_at is written BY the reap and is
# therefore absent on every shape-B row, forever. The env var is the same one
# the server reads, so an instance running a non-default TTL is measured against
# ITS lease and not against this file's opinion of one.
DEFAULT_LEASE_TTL_SECONDS = 2700
LEASE_TTL_ENV = "BARKPARK_TASK_LEASE_TTL_SECONDS"

# The lifecycle values clause 7 keys on. Both are LIVE (neither is in
# TERMINAL_LIFECYCLE), and they are CASE-EXACT like every other value read here.
LIFECYCLE_OPEN = "open"
LIFECYCLE_IN_PROGRESS = "in_progress"

# THE DENOMINATOR'S LENS, IN ONE PLACE. Every "N of the open PDS rows" claim
# divides by the count of closure rows whose `lifecycle_status` is EXACTLY this
# value. The alternatives were measured and refused (wave 47):
#   - `disposition`-keyed: 216 live rows carry NO disposition, so a
#     disposition-keyed denominator silently drops them.
#   - "live / non-terminal": folds in `considering` and `blocked`, and by the
#     task-funnel doctrine `considering` PRECEDES open -- a considering row is
#     not a claim that a defect is live.
# The number itself is NEVER written down here. It was 374 through this lens at
# 2026-08-04T12:35Z and the wave that measured it also files rows, so a literal
# would be stale before it was committed -- which is the exact undescended
# assertion this epic exists to refuse. It is derived on every run, printed with
# the instant it was taken and with the command that re-derives it.
DENOMINATOR_FIELD = "lifecycle_status"
REDERIVE_COMMAND = "bash scripts/pds-ledger-census.sh"

# THE BLIND-SPOT ARM'S ONE HEURISTIC, NAMED AS ONE. A row that belongs to this
# epic by NAME but hangs off another epic's parent is unreachable by any closure
# anchored at the root, at any depth, under any key -- so the closure cannot see
# it and must say so. The key is a SLUG PREFIX, which is a naming convention and
# not a structural fact: an epic row named without it is invisible to this arm
# too, and the output says that rather than implying coverage it does not have.
EPIC_SLUG_PREFIX = "pds-"

# THE SECOND LENS. `/v1/data/query?perspective=drafts` serves draft rows under a
# `drafts.`-prefixed `_id`. A published-only read cannot see a row that was
# never published -- not as a zero, as an ABSENCE -- so the census reads the
# drafts lens too and reports what it finds there SEPARATELY. It is never summed
# into the denominator: a draft whose published twin is terminal is an edit
# shadow, not hidden work (measured wave 47: 3 of the 5 in-scope draft-open rows
# are exactly that).
DRAFT_ID_PREFIX = "drafts."
DRAFT_PERSPECTIVE = "drafts"

# The API's page cap. Asking for more is answered with a silently smaller page.
DEFAULT_PAGE_LIMIT = 1000

# THE TOTAL ORDER EVERY PAGE IS REQUESTED IN. `_createdAt:asc` is the only
# correct spelling and it is pinned here, in one constant, so the two traps
# documented in the header (`order=doc_id`, silently ignored at HTTP 200; and
# `order=doc_id:asc`, an all-NULL content key) cannot be reached by a typo that
# nothing would notice. It is reported in the census output and in `--json` as
# `page_order`, because a paging discipline nobody can read back is a claim.
PAGE_ORDER = "_createdAt:asc"
DEFAULT_PACE_SECONDS = 0.15
DEFAULT_RETRIES = 4
MAX_PAGES = 200

EXIT_OK = 0
EXIT_ROUND_NOT_DONE = 1
EXIT_FAIL_CLOSED = 2
EXIT_USAGE = 3
EXIT_INCOHERENT = 4


class LensAbsent(Exception):
    """The SECOND lens could not be read AT ALL, and that is not a zero.

    Raised only where a source can honestly not offer the drafts perspective (a
    fixture that cans no drafts pages; a token the endpoint answers in the
    published perspective anyway). It is never raised for a transport failure --
    a 429 or a 500 on the drafts read fails closed exactly like one on the
    published read, because a smoothed-over error is the defect this file
    exists to refuse.
    """


def die(code, msg, detail=None):
    label = {
        EXIT_FAIL_CLOSED: "FAIL CLOSED",
        EXIT_USAGE: "USAGE",
        EXIT_INCOHERENT: "SNAPSHOT INCOHERENT",
    }.get(code, "FAILED")
    print("pds-ledger-census: %s: %s" % (label, msg), file=sys.stderr)
    if detail:
        for line in detail:
            print("  %s" % line, file=sys.stderr)
    sys.exit(code)


# --- transport ----------------------------------------------------------------
#
# Clause 3 lives here: the caller gets (status, body_bytes) and NOTHING else.
# There is no code path by which a body can be interpreted before its status
# has been judged.


class HttpTransport(object):
    def __init__(self, server, token):
        self.server = server.rstrip("/")
        self.token = token

    def describe(self):
        return self.server

    def get(self, path, query, page_index, attempt, kind="page"):
        # `kind` is the fixture transport's file key. Over HTTP the lens rides
        # in the query string the caller already built, so there is nothing to
        # branch on here -- and nothing to get out of sync with it.
        return self._request("%s%s?%s" % (self.server, path, query))

    def get_doc(self, path, slug):
        """The anchor read. Same status-first discipline, no retry budget: an
        anchor that could not be resolved is a fail, never a default."""
        return self._request("%s%s" % (self.server, path))

    def _request(self, url):
        req = urllib.request.Request(url, headers={
            "Authorization": "Bearer %s" % self.token,
            "Accept": "application/json",
        })
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()
        except urllib.error.URLError as exc:
            die(EXIT_FAIL_CLOSED, "network failure reaching %s: %s" % (url, exc.reason))


class FixtureTransport(object):
    """Canned HTTP responses: DIR/page-<i>.http, first line `HTTP <status>`.

    Responses are keyed by PAGE INDEX, not by request count, because a retry
    re-requests the SAME page -- a transport that advanced on retry would model
    a server that answers a different page each time you ask, which is not the
    server. DIR/page-<i>-attempt-<n>.http overrides page <i> on attempt n, so a
    fixture can serve a 429 first and the real page on the retry.

    This is the selftest's transport. It exercises the SAME status-scoring,
    shape-asserting and paging code the live run uses -- a fixture that bypassed
    them would prove nothing.
    """

    def __init__(self, directory):
        self.dir = directory

    def describe(self):
        return "fixture://%s" % self.dir

    def get(self, path, query, page_index, attempt, kind="page"):
        path_i = os.path.join(self.dir, "%s-%d-attempt-%d.http" % (kind, page_index, attempt))
        if not os.path.exists(path_i):
            path_i = os.path.join(self.dir, "%s-%d.http" % (kind, page_index))
        if not os.path.exists(path_i):
            # A fixture that cans NO page of a secondary lens is a source that
            # does not offer that lens -- an ABSENCE, reported as one. A fixture
            # that cans page 0 and then stops is still a TRUNCATED READ and
            # still fails closed below: the softening applies to the first page
            # of a non-default lens and to nothing else.
            if kind != "page" and page_index == 0:
                raise LensAbsent("fixture cans no %s-0.http" % kind)
            die(EXIT_FAIL_CLOSED,
                "fixture exhausted: no %s (the read wanted another page and the "
                "source stopped answering -- that is a truncated read, not a "
                "smaller board)" % os.path.basename(path_i))
        return self._read(path_i)

    def get_doc(self, path, slug):
        """The anchor read, canned as DIR/paper-<slug>.http. A fixture with no
        such file models a Paper the server does not serve -- which must fail
        closed, not default."""
        path_i = os.path.join(self.dir, "paper-%s.http" % slug)
        if not os.path.exists(path_i):
            die(EXIT_FAIL_CLOSED,
                "fixture has no %s: the anchor Paper could not be resolved, and an "
                "unresolvable anchor is never a default" % os.path.basename(path_i))
        return self._read(path_i)

    def _read(self, path_i):
        with open(path_i, "rb") as fh:
            raw = fh.read()
        head, _, body = raw.partition(b"\n")
        head = head.decode("utf-8", "replace").strip()
        if not head.upper().startswith("HTTP "):
            die(EXIT_USAGE, "malformed fixture %s: first line must be 'HTTP <status>'" % path_i)
        try:
            status = int(head.split()[1])
        except (IndexError, ValueError):
            die(EXIT_USAGE, "malformed fixture %s: unparsable status in %r" % (path_i, head))
        return status, body


# --- paged, shape-asserted read ----------------------------------------------


def fetch_page(transport, dataset, doctype, page_index, offset, limit, pace, retries,
               perspective_param=None, kind="page"):
    # The order is NOT optional. Explicit offsets over the server's default
    # `desc: updated_at` page a MUTATING key and can skip a row with no error.
    query = "limit=%d&offset=%d&order=%s" % (limit, offset, PAGE_ORDER)
    if perspective_param:
        query += "&perspective=%s" % perspective_param
    path = "/v1/data/query/%s/%s" % (dataset, doctype)
    attempt = 0
    while True:
        status, body = transport.get(path, query, page_index, attempt, kind)

        # CLAUSE 3, first half: the status decides, before the body is looked at.
        if status == 429:
            if attempt >= retries:
                die(EXIT_FAIL_CLOSED,
                    "HTTP 429 rate limited at offset %d after %d retries -- refusing "
                    "to treat a rate-limited response as an empty page" % (offset, attempt),
                    ["body: %s" % body[:200].decode("utf-8", "replace"),
                     "the body above is VALID JSON; a 'did it parse?' test reads it as data"])
            attempt += 1
            backoff = pace * (2 ** attempt) + 0.5
            print("pds-ledger-census: 429 at offset %d, backing off %.2fs (retry %d/%d)"
                  % (offset, backoff, attempt, retries), file=sys.stderr)
            time.sleep(backoff)
            continue
        if status < 200 or status >= 300:
            die(EXIT_FAIL_CLOSED,
                "HTTP %d at offset %d -- a non-2xx is never a leaf and never an "
                "empty page" % (status, offset),
                ["body: %s" % body[:300].decode("utf-8", "replace")])

        # CLAUSE 3, second half: 2xx is not enough, and neither is parseable JSON.
        try:
            payload = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            die(EXIT_FAIL_CLOSED, "HTTP %d but unparseable body at offset %d: %s" % (status, offset, exc))
        if not isinstance(payload, dict):
            die(EXIT_FAIL_CLOSED,
                "HTTP %d but body is %s, not an object, at offset %d"
                % (status, type(payload).__name__, offset))
        if "result" not in payload or not isinstance(payload["result"], dict):
            die(EXIT_FAIL_CLOSED,
                "HTTP %d but no `result` object at offset %d -- this is the shape a "
                "/v1/tasks-style {\"ok\":false,\"reason\":...} failure takes, and it "
                "parses cleanly" % (status, offset),
                ["keys: %s" % sorted(payload.keys())[:12]])
        result = payload["result"]
        for key, kind in (("count", int), ("offset", int), ("limit", int), ("documents", list)):
            if key not in result or not isinstance(result[key], kind):
                die(EXIT_FAIL_CLOSED,
                    "HTTP %d but result.%s is missing or not %s at offset %d"
                    % (status, key, kind.__name__, offset),
                    ["result keys: %s" % sorted(result.keys())[:12]])

        docs = result["documents"]

        # CLAUSE 1: the server must have honoured the page it was ASKED for.
        if result["limit"] != limit:
            die(EXIT_FAIL_CLOSED,
                "server silently capped the page: asked limit=%d, echoed limit=%d at "
                "offset %d. An unpaginated read trusting its own request would report a "
                "SMALLER board and exit 0." % (limit, result["limit"], offset))
        if result["offset"] != offset:
            die(EXIT_FAIL_CLOSED,
                "server answered a different page: asked offset=%d, echoed offset=%d"
                % (offset, result["offset"]))
        if result["count"] != len(docs):
            die(EXIT_FAIL_CLOSED,
                "truncated page at offset %d: result.count=%d but %d documents were "
                "delivered" % (offset, result["count"], len(docs)))
        if len(docs) > limit:
            die(EXIT_FAIL_CLOSED,
                "incoherent page at offset %d: %d documents for limit=%d"
                % (offset, len(docs), limit))
        for doc in docs:
            if not isinstance(doc, dict) or not doc.get("_id"):
                die(EXIT_FAIL_CLOSED, "page at offset %d carries a row with no _id" % offset)

        time.sleep(pace)
        # CLAUSE 7's LENS, DERIVED. `result.perspective` is what the endpoint
        # says it answered with; it is reported, never assumed. A page that does
        # not say is reported as `<unset>` rather than assumed published.
        perspective = result.get("perspective")
        if not isinstance(perspective, str) or not perspective.strip():
            perspective = "<unset>"
        return docs, perspective.strip()


def read_corpus(transport, dataset, doctype, limit, pace, retries,
                perspective_param=None, kind="page", require_rows=True):
    """CLAUSE 1 + CLAUSE 4: explicit offsets, serial, paced, short page ends it."""
    by_id = {}
    pages = []
    offset = 0
    duplicates = []
    perspectives = []
    for page_index in range(MAX_PAGES):
        docs, perspective = fetch_page(
            transport, dataset, doctype, page_index, offset, limit, pace, retries,
            perspective_param, kind)
        pages.append(len(docs))
        if perspective not in perspectives:
            perspectives.append(perspective)
        for doc in docs:
            doc_id = doc["_id"]
            if doc_id in by_id:
                duplicates.append(doc_id)
            by_id[doc_id] = doc
        if len(docs) < limit:
            break
        offset += limit
    else:
        die(EXIT_FAIL_CLOSED,
            "read did not terminate after %d pages of %d -- refusing to report a "
            "partial board" % (MAX_PAGES, limit))
    if not by_id and require_rows:
        die(EXIT_FAIL_CLOSED,
            "empty population: zero %s rows. A census with nothing in it has not "
            "passed, it has failed to run." % doctype)
    return by_id, pages, duplicates, perspectives


def read_drafts_lens(transport, dataset, doctype, limit, pace, retries):
    """THE SECOND LENS, WITH AN HONEST UNREAD STATE.

    Returns (rows_by_id, unread_reason). Exactly one of them is set. The lens is
    UNREAD -- never zero -- when the source cans no drafts page at all, or when
    it answers a perspective it was not asked for (a tokenless or public-read
    caller is silently PINNED to `published` by AnonPerspective, and a run that
    counted that response as "no drafts exist" would manufacture a clean board
    out of a permission it does not have). Every other failure fails closed
    inside fetch_page, unchanged.
    """
    try:
        rows, _pages, _dupes, perspectives = read_corpus(
            transport, dataset, doctype, limit, pace, retries,
            perspective_param=DRAFT_PERSPECTIVE, kind="drafts-page", require_rows=False)
    except LensAbsent as absent:
        return None, "source offers no drafts perspective (%s)" % absent
    answered = [p for p in perspectives if p != DRAFT_PERSPECTIVE]
    if answered:
        return None, ("source answered perspective:%s for a perspective=%s read -- the "
                      "lens was IGNORED, so the never-published class is UNMEASURED, "
                      "not zero" % ("+".join(answered), DRAFT_PERSPECTIVE))
    return rows, None


# --- closure ------------------------------------------------------------------


def build_closure(corpus, root, lens):
    """CLAUSE 2. `closure` is the transitive descendant set over parent_id.

    `children` is the one-level lens, present ONLY so the selftest can inject it
    and watch the fixpoint assertion below refuse it.
    """
    kids = defaultdict(list)
    for doc_id, doc in corpus.items():
        parent = doc.get("parent_id")
        if parent:
            kids[parent].append(doc_id)

    closure = []
    seen = set()
    depth_of = {}
    frontier = [(child, 1) for child in sorted(kids.get(root, []))]
    while frontier:
        node, depth = frontier.pop(0)
        if node in seen:
            continue
        seen.add(node)
        closure.append(node)
        depth_of[node] = depth
        if lens == "children":
            continue  # the undercounting lens, on purpose
        for child in sorted(kids.get(node, [])):
            if child not in seen:
                frontier.append((child, depth + 1))

    # THE FIXPOINT ASSERTION. Lens-independent, and the thing a classification
    # string cannot satisfy: if any row in the fully-paged corpus has a parent
    # inside the closure but is itself outside it, the walk did not finish.
    escaped = sorted(
        doc_id for doc_id, doc in corpus.items()
        if doc.get("parent_id") in seen and doc_id not in seen
    )
    if escaped:
        die(EXIT_FAIL_CLOSED,
            "closure is NOT closed under parent_id: %d row(s) have a parent inside "
            "the closure and sit outside it. The walk stopped early (a one-level "
            "`.children` lens does this on its first grandchild)." % len(escaped),
            ["lens=%s" % lens] + ["escaped: %s (parent %s)" % (e, corpus[e].get("parent_id"))
                                  for e in escaped[:8]])
    return closure, depth_of


# --- census -------------------------------------------------------------------


def reason_hash(text):
    return hashlib.sha256(" ".join(text.split()).encode("utf-8")).hexdigest()[:16]


def disposition_of(row):
    """The row's disposition, trimmed. Case is PRESERVED -- the split is data."""
    value = row.get("disposition")
    return value.strip() if isinstance(value, str) else ""


def reason_of(row):
    value = row.get("disposition_reason")
    return value.strip() if isinstance(value, str) else ""


def structured_trigger(row):
    """CLAUSE 4(c)'s ONLY source of truth: the `reopen_trigger` FIELD.

    Never REOPEN_TRIGGER_RE, never the reason text. A trigger a script cannot
    read is not a trigger, and counting prose as one is the decoration PDS-D336(b)
    condemns by name.
    """
    value = row.get("reopen_trigger")
    return value.strip() if isinstance(value, str) else ""


def claim_of(row):
    """CLAUSE 7's ONLY source: the top-level `claim` object /v1/data/query
    serves beside the row. A row with no claim has never been held and is no
    shape at all; a `claim` that is not an object is not read as one."""
    value = row.get("claim")
    return value if isinstance(value, dict) else None


def claim_field(claim, key):
    """A claim field as a TRIMMED string. `null`, absent and empty are the SAME
    thing here on purpose: shape A's whole key is which of these fields the
    sweeper left behind, and `"worker": null` versus no `worker` key at all is a
    serialisation detail, never a difference in what happened to the row."""
    value = claim.get(key)
    return value.strip() if isinstance(value, str) else ""


def claim_work_evidence(claim):
    """`claim.now.text` — the worker's own now-line. A lapsed row carrying one is
    a row whose worker was demonstrably mid-flight when the lease was reaped,
    which is what makes shape A a LIE and not merely a vacancy."""
    now = claim.get("now")
    if not isinstance(now, dict):
        return False
    text = now.get("text")
    return isinstance(text, str) and bool(text.strip())


def lease_ttl_seconds():
    """The lease TTL, from the SAME env var the server reads, or the default.

    An unreadable value is a USAGE error, never a silent fallback: a TTL that
    quietly reverts to 2700 on an instance running 300 would measure shape B
    against a lease that does not exist.
    """
    raw = os.environ.get(LEASE_TTL_ENV)
    if raw is None or not raw.strip():
        return DEFAULT_LEASE_TTL_SECONDS, "default"
    try:
        value = int(raw.strip())
    except ValueError:
        die(EXIT_USAGE, "%s=%r is not an integer number of seconds -- refusing to "
                        "fall back to %d, which would measure shape B against a "
                        "lease this instance does not run"
                        % (LEASE_TTL_ENV, raw, DEFAULT_LEASE_TTL_SECONDS))
    if value < 1:
        die(EXIT_USAGE, "%s=%d must be >= 1" % (LEASE_TTL_ENV, value))
    return value, LEASE_TTL_ENV


def parse_instant(value):
    if not isinstance(value, str):
        return None
    raw = value.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def resolve_anchor_from_paper(transport, dataset, slug):
    """THE ROUND ANCHOR, DERIVED. The wave Paper's `_createdAt` IS the instant
    the round was born, and it is the only anchor a certifying run may use.

    Fails closed on every step -- a non-2xx, a body that is not the asserted
    shape, a missing or unreadable `_createdAt`. There is deliberately NO
    fallback: an anchor at now() excuses every row the round just filed, which
    is the exact vacuous green clause 4 exists to make impossible.
    """
    path = "/v1/data/doc/%s/paper/%s" % (dataset, slug)
    status, body = transport.get_doc(path, slug)
    if status < 200 or status >= 300:
        die(EXIT_FAIL_CLOSED,
            "HTTP %d resolving the anchor Paper `%s` -- refusing to fall back to "
            "now(), which would excuse every row this round filed" % (status, slug),
            ["GET %s" % path,
             "body: %s" % body[:300].decode("utf-8", "replace")])
    try:
        payload = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        die(EXIT_FAIL_CLOSED, "HTTP %d but unparseable body resolving anchor Paper `%s`: %s"
            % (status, slug, exc))
    result = payload.get("result") if isinstance(payload, dict) else None
    if not isinstance(result, dict):
        die(EXIT_FAIL_CLOSED,
            "HTTP %d but no `result` object resolving anchor Paper `%s` -- this is "
            "the shape a cleanly-parsing failure envelope takes" % (status, slug))
    raw = result.get("_createdAt")
    born = parse_instant(raw)
    if born is None:
        die(EXIT_FAIL_CLOSED,
            "anchor Paper `%s` has a missing or unreadable _createdAt %r -- an "
            "anchor that cannot be read is not an anchor" % (slug, raw))
    return born, raw


def declared_wave_paper(root_row):
    """THE ROUND'S OWN NAME FOR ITS PAPER, read off the epic root row.

    Absent, non-string and blank are the SAME thing here: a root that does not
    name a Paper binds nothing, and that state is REPORTED (`unverifiable`)
    rather than silently treated as agreement.
    """
    value = root_row.get(ROUND_ANCHOR_FIELD)
    return value.strip() if isinstance(value, str) else ""


def resolve_round_anchor(transport, dataset, root, root_row, args):
    """THE ANCHOR, BOUND TO THE ROUND IT CERTIFIES (the wave-26 residual).

    Returns (anchor, source, slug, binding, declared). `binding` is the whole
    point and it is never inferred by a reader: one of

        "bound"         the slug IS the root's `wave_paper`
        "override"      it is not, and --anchor-unbound said so out loud
        "unverifiable"  the root names no Paper, so nothing could be checked
        "fixture-clock" --anchor, reachable only under --fixture-dir
        None            no anchor at all (the wave-25 clause, unchanged)

    THE REFUSAL IS THE FIX. An earlier wave's Paper is an EARLIER instant, and
    every row born between the two anchors moves from `bare` (a 4(a) failure) to
    `residue` (a deferral). That is a greener predicate bought by moving the
    boundary, and it is exactly what an unbound argv anchor could do silently.
    """
    declared = declared_wave_paper(root_row)

    if args.anchor:
        anchor = parse_instant(args.anchor)
        if anchor is None:
            die(EXIT_USAGE, "--anchor %r is not an ISO-8601 instant" % args.anchor)
        return anchor, "--anchor (fixture clock)", None, "fixture-clock", declared

    if args.anchor_from_paper:
        slug = args.anchor_from_paper
        if declared and slug != declared:
            if not args.anchor_unbound:
                die(EXIT_USAGE,
                    "--anchor-from-paper `%s` does not match the round being certified: "
                    "the epic root %s declares `%s: %s`." % (slug, root, ROUND_ANCHOR_FIELD, declared),
                    ["an EARLIER wave's Paper is an EARLIER anchor, so more rows fall AFTER "
                     "it and are deferred as residue -- a greener 4(a) reached by MOVING THE "
                     "BOUNDARY rather than by adjudicating the rows.",
                     "drop the flag (the anchor is then derived from the root's %s), or pass "
                     "--anchor-unbound, which accepts the divergence and prints it."
                     % ROUND_ANCHOR_FIELD])
            binding = "override"
        elif declared:
            binding = "bound"
        else:
            binding = "unverifiable"
        born, raw = resolve_anchor_from_paper(transport, dataset, slug)
        return born, "paper/%s _createdAt %s" % (slug, raw), slug, binding, declared

    # THE DEFAULT. No flag: the round's own Paper, named by the round itself.
    if declared and not args.no_anchor:
        born, raw = resolve_anchor_from_paper(transport, dataset, declared)
        return (born,
                "epic %s %s=%s -> paper/%s _createdAt %s"
                % (root, ROUND_ANCHOR_FIELD, declared, declared, raw),
                declared, "bound", declared)

    return None, None, None, None, declared


def anchor_binding_line(report):
    """The binding, in one human line. A run that anchors must say WHY it was
    entitled to that anchor, or the residue below it is a number nobody can
    check."""
    binding = report.get("round_anchor_binding")
    slug = report.get("round_anchor_slug")
    declared = report.get("round_anchor_declared")
    if binding == "bound":
        return ("BOUND to the round: the epic root declares `%s: %s` and the anchor is "
                "derived from it" % (ROUND_ANCHOR_FIELD, declared))
    if binding == "override":
        return ("ANCHOR UNBOUND (--anchor-unbound): anchored on `%s` while the epic root "
                "declares `%s: %s`. The round boundary was MOVED by argv -- every deferral "
                "below is owed that caveat." % (slug, ROUND_ANCHOR_FIELD, declared))
    if binding == "unverifiable":
        return ("UNVERIFIABLE: the epic root declares no `%s`, so NOTHING binds `%s` to the "
                "round being certified" % (ROUND_ANCHOR_FIELD, slug))
    if binding == "fixture-clock":
        return "SELFTEST CLOCK: --anchor, reachable only under --fixture-dir"
    return "none"


def lapse_shapes(rows, started, lease_ttl):
    """CLAUSE 7 (PDS-D638): THE LEDGER LAPSE, IN THREE SHAPES THAT DO NOT SHARE
    A KEY. Read straight off the `claim` object the paged read already fetched.

    SHAPE B IS THE REASON THERE ARE TWO KEYS AND NOT ONE. It is keyed on the
    HELD LEASE'S AGE and NEVER on `claim.expired_at`, because expired_at is
    written BY the reap: no shape-B row can carry it, so an expired_at-keyed
    check would pass vacuously on shape B 100% of the time, forever. That is
    the exact vacuous green this instrument exists to make impossible, and it
    would have been shipped INSIDE the fix for it.

    ONE FUNCTION, TWO LENSES. The published closure and the drafts lens are
    scored by THIS code and no other, so the per-shape delta between them is a
    property of the LENS and never of two hand-copied key sets that drifted.
    """
    lapse_a = []
    lapse_a_work = []
    lapse_b = []
    lapse_b_overdue = {}
    lapse_c = []
    for row in rows:
        claim = claim_of(row)
        if claim is None:
            continue
        row_lifecycle = row.get("lifecycle_status") or ""
        worker = claim_field(claim, "worker")
        if (row_lifecycle == LIFECYCLE_OPEN
                and not worker
                and claim_field(claim, "previous_worker")
                and claim_field(claim, "expired_at")
                and not claim_field(claim, "released_at")
                and not claim_field(claim, "closed_at")):
            # SHAPE A. The TTL sweeper's exact fingerprint: a release writes
            # released_at, a close writes closed_at, only a lapse nulls worker
            # while preserving previous_worker.
            lapse_a.append(row["_id"])
            if claim_work_evidence(claim):
                lapse_a_work.append(row["_id"])
        if row_lifecycle == LIFECYCLE_IN_PROGRESS and worker:
            # SHAPE B. NOT expired_at -- see above. The clock is the census's
            # OWN named instant, so the age descends from the same window
            # clause 5 asserts coherence over.
            raw = claim.get("ts_iso")
            held_since = parse_instant(raw)
            if held_since is None:
                die(EXIT_FAIL_CLOSED,
                    "row %s is `%s` and HELD by %r but its claim.ts_iso is missing "
                    "or unreadable (%r) -- the lease cannot be placed on either "
                    "side of the %ds TTL, and a row the arm cannot place is never "
                    "counted as fresh"
                    % (row["_id"], LIFECYCLE_IN_PROGRESS, worker, raw, lease_ttl))
            age = (started - held_since).total_seconds()
            if age > lease_ttl:
                lapse_b.append(row["_id"])
                lapse_b_overdue[row["_id"]] = round(age - lease_ttl, 2)
        if row_lifecycle == LIFECYCLE_OPEN and worker and claim_field(claim, "closed_at"):
            # SHAPE C. Reported on its own line and NEVER folded: a worker-keyed
            # check reads it as held, an expiry-keyed check cannot see it at all,
            # and its remedy is a third thing.
            lapse_c.append(row["_id"])
    return {
        "shape_a": sorted(lapse_a),
        "shape_a_work_evidence": sorted(lapse_a_work),
        "shape_b": sorted(lapse_b),
        "shape_b_overdue_seconds": lapse_b_overdue,
        "shape_c": sorted(lapse_c),
    }


def blind_spots(corpus, closure, root, drafts, drafts_unread, started, lease_ttl):
    """WHAT THE DENOMINATOR STRUCTURALLY CANNOT SEE -- BY NAME, NEVER AS A COUNT.

    A census that prints one number and nothing else is a claim about a
    population it never looked outside of. Two mechanical arms, no transcription:

      (1) OUTSIDE THE CLOSURE. Rows whose slug carries the epic prefix and whose
          parent chain does NOT reach the root. No closure anchored at the root
          can reach them at ANY depth, under any key -- so they are not a
          deeper walk away, they are unreachable. Terminal ones are listed
          apart: a done row outside the closure is bookkeeping, a LIVE one is
          work this epic owns and cannot see.

      (2) THE DRAFTS LENS. Draft rows in scope of the root that are `open`,
          split by what their PUBLISHED twin says, because the two halves are
          not the same kind of thing:
            - NO published twin -> genuinely never published. HIDDEN WORK. It
              is added to the honest total.
            - twin is TERMINAL -> a PHANTOM: an unpublished edit shadow of a
              row that is finished. Adding it OVERCOUNTS (measured 2026-08-04:
              3 of 5, and adding them turns 376 into 379).
            - twin is LIVE -> already inside the denominator; the draft is an
              edit in flight, not a second row.

    The scope rule for (2) is the same parent_id key clause 2 walks: a draft is
    in scope when its parent is the root or a closure member, or when its own
    base slug is already in the closure.
    """
    closure_set = set(closure)
    scope = closure_set | {root}

    outside_live = []
    outside_terminal = []
    for doc_id, doc in sorted(corpus.items()):
        if doc_id in closure_set or doc_id == root:
            continue
        if not doc_id.startswith(EPIC_SLUG_PREFIX):
            continue
        lifecycle = doc.get("lifecycle_status") or "<unset>"
        entry = {"id": doc_id, "lifecycle_status": lifecycle,
                 "parent_id": doc.get("parent_id")}
        (outside_terminal if lifecycle in TERMINAL_LIFECYCLE else outside_live).append(entry)

    report = {
        "epic_slug_prefix": EPIC_SLUG_PREFIX,
        "outside_closure_live": outside_live,
        "outside_closure_terminal": [e["id"] for e in outside_terminal],
        "drafts_lens": "unread" if drafts is None else "read",
        "drafts_unread_reason": drafts_unread,
        "never_published": [],
        "phantoms": [],
        "draft_shadows_of_live": [],
        "drafts_in_scope": [],
        "lapse_delta": None,
    }
    if drafts is None:
        return report

    in_scope = []
    for doc_id, doc in sorted(drafts.items()):
        if not doc_id.startswith(DRAFT_ID_PREFIX):
            continue
        base = doc_id[len(DRAFT_ID_PREFIX):]
        if doc.get("parent_id") in scope or base in scope:
            in_scope.append((doc_id, base, doc))
    report["drafts_in_scope"] = [d for d, _b, _r in in_scope]

    for doc_id, base, doc in in_scope:
        if (doc.get("lifecycle_status") or "") != LIFECYCLE_OPEN:
            continue
        twin = corpus.get(base)
        if twin is None:
            report["never_published"].append({"id": doc_id, "twin": None})
        elif (twin.get("lifecycle_status") or "") in TERMINAL_LIFECYCLE:
            report["phantoms"].append(
                {"id": doc_id, "twin": twin.get("lifecycle_status")})
        else:
            report["draft_shadows_of_live"].append(
                {"id": doc_id, "twin": twin.get("lifecycle_status")})

    # CLAUSE 7's CAVEAT, MEASURED INSTEAD OF ASSERTED. The same lapse_shapes()
    # that scored the published closure, re-run over the in-scope draft rows.
    # A shape whose count is 0 on BOTH lenses is UNDISCRIMINATED -- its delta is
    # not evidence that the lens agrees, only that neither read found anything.
    draft_rows = [row for _d, _b, row in in_scope]
    report["lapse_delta"] = lapse_shapes(draft_rows, started, lease_ttl)
    return report


def census(corpus, closure, depth_of, started, finished, duplicates, anchor=None,
           lease_ttl=DEFAULT_LEASE_TTL_SECONDS):
    rows = [corpus[i] for i in closure]
    lifecycle = Counter((r.get("lifecycle_status") or "<unset>") for r in rows)
    live = [r for r in rows if (r.get("lifecycle_status") or "") not in TERMINAL_LIFECYCLE]
    dispositions = Counter()
    for row in rows:
        value = row.get("disposition")
        dispositions[value if isinstance(value, str) and value else "<unset>"] += 1

    reasons = []
    triggers_structured = 0
    triggers_prose_only = 0
    for row in rows:
        structured = structured_trigger(row)
        if structured:
            triggers_structured += 1
        reason = reason_of(row)
        if reason:
            reasons.append(reason)
            # NEVER an `or` with the structured field, and never summed with it:
            # this counts DECORATION, so it is reported beside the real number.
            if not structured and REOPEN_TRIGGER_RE.search(reason):
                triggers_prose_only += 1
    hashes = {reason_hash(r) for r in reasons}

    # CLAUSE 4: live coverage. Row-ID LISTS, not counts -- a shard consumes the
    # worklist, and a count nobody can turn back into rows is not a worklist.
    #
    # 4(a) IS THE ONE ROUND-ANCHORED LINE, and this is the ONE place the anchor
    # enters (PDS-D364/D365). A row born AFTER the round started cannot have been
    # adjudicated by it, so it is the NEXT round's inbox -- named, never merely
    # counted. Everything else here, including 4(b) and 4(c), stays whole-live: a
    # row that HAS a disposition owes a reason regardless of when it was born.
    # With no anchor, `residue` is empty and 4(a) is exactly what wave 25 shipped.
    live_bare_rows = [r for r in live if not disposition_of(r)]
    live_bare_residue = []
    if anchor is not None:
        in_round = []
        for row in live_bare_rows:
            raw = row.get("_createdAt")
            born = parse_instant(raw)
            if born is None:
                # FAIL CLOSED, exactly as clause 5 does for _updatedAt: a row the
                # predicate cannot place on either side of the anchor must never
                # be silently excused into the residue.
                die(EXIT_FAIL_CLOSED,
                    "live row %s has a missing or unreadable _createdAt %r -- the "
                    "round-anchored predicate cannot place it before or after the "
                    "anchor, and a row it cannot place is never excused" % (row["_id"], raw))
            (in_round if born <= anchor else live_bare_residue).append(row)
        live_bare_rows = in_round
    live_bare = sorted(r["_id"] for r in live_bare_rows)
    live_bare_residue = sorted(r["_id"] for r in live_bare_residue)
    live_adjudicated = [r for r in live if disposition_of(r)]
    live_adjudicated_no_reason = sorted(r["_id"] for r in live_adjudicated if not reason_of(r))
    live_parked = [r for r in live if disposition_of(r).lower() == PARKED_DISPOSITION]
    live_park_no_trigger = sorted(r["_id"] for r in live_parked if not structured_trigger(r))

    # CLAUSE 6 (PDS-D372/D373): the row is CLAIMABLE and it is adjudicated
    # CLOSED. Clause 4(a) counts it as satisfied and `bp task ready` hands it to
    # a worker; the two organs disagree and nothing looks. CLOSED-ONLY (a live
    # park is a park, and clause 4(c) already owns it) and CASE-EXACT against the
    # normalised vocabulary (an unrecognised disposition is LIVE, and clause 3's
    # business). A ROW-ID LIST, because a shard consumes the worklist.
    live_contradiction = sorted(
        r["_id"] for r in live if disposition_of(r) == CLOSED_DISPOSITION)

    # CLAUSE 7 (PDS-D638). ONE implementation of the three keys, called here for
    # the published closure and AGAIN for the drafts lens (see blind_spots) --
    # a second hand-written copy of these keys is how a "the drafts read finds
    # more" claim gets to be true of a different rule than the one it is
    # compared against.
    lapse = lapse_shapes(rows, started, lease_ttl)
    lapse_a = lapse["shape_a"]
    lapse_a_work = lapse["shape_a_work_evidence"]
    lapse_b = lapse["shape_b"]
    lapse_b_overdue = lapse["shape_b_overdue_seconds"]
    lapse_c = lapse["shape_c"]

    off_vocab = Counter()
    off_vocab_samples = defaultdict(list)
    for row in rows:
        value = row.get("disposition")
        if isinstance(value, str) and value and value not in DISPOSITION_VOCABULARY:
            off_vocab[value] += 1
            if len(off_vocab_samples[value]) < 3:
                off_vocab_samples[value].append(row["_id"])

    # CLAUSE 5: a row that moved inside the window makes this an average.
    drifted = []
    for row in rows:
        raw = row.get("_updatedAt")
        if raw is None:
            die(EXIT_FAIL_CLOSED,
                "row %s carries no _updatedAt -- coherence of the named window "
                "cannot be asserted, so nothing here is a snapshot" % row["_id"])
        moved = parse_instant(raw)
        if moved is None:
            die(EXIT_FAIL_CLOSED,
                "row %s has an unreadable _updatedAt %r -- an unparsable timestamp "
                "must never be silently read as 'did not move'" % (row["_id"], raw))
        if started <= moved <= finished:
            drifted.append((row["_id"], raw))

    return {
        "instant": {
            "started": started.isoformat().replace("+00:00", "Z"),
            "finished": finished.isoformat().replace("+00:00", "Z"),
            "seconds": round((finished - started).total_seconds(), 2),
        },
        "closure_size": len(rows),
        "max_depth": max(depth_of.values()) if depth_of else 0,
        "live": len(live),
        # THE DENOMINATOR, DERIVED. One field, one value, case-exact -- and it
        # is a COUNT of the rows above, never a number this file remembers.
        "open_denominator": lifecycle.get(LIFECYCLE_OPEN, 0),
        "open_denominator_field": DENOMINATOR_FIELD,
        "open_denominator_value": LIFECYCLE_OPEN,
        "lifecycle": dict(lifecycle),
        "dispositions": dict(dispositions),
        "reasons_non_empty": len(reasons),
        "reason_hashes_distinct": len(hashes),
        "reopen_triggers_structured": triggers_structured,
        "reopen_triggers_prose_only": triggers_prose_only,
        "live_adjudicated": len(live_adjudicated),
        "live_parked": len(live_parked),
        "live_bare": live_bare,
        "live_bare_residue": live_bare_residue,
        "live_adjudicated_no_reason": live_adjudicated_no_reason,
        "live_park_no_trigger": live_park_no_trigger,
        "live_contradiction": live_contradiction,
        "lapse_shape_a": sorted(lapse_a),
        "lapse_shape_a_work_evidence": sorted(lapse_a_work),
        "lapse_shape_b": sorted(lapse_b),
        "lapse_shape_b_overdue_seconds": lapse_b_overdue,
        "lapse_shape_c": sorted(lapse_c),
        "lease_ttl_seconds": lease_ttl,
        "off_vocabulary": dict(off_vocab),
        "off_vocabulary_samples": {k: v for k, v in off_vocab_samples.items()},
        "off_vocabulary_total": sum(off_vocab.values()),
        "drifted": drifted,
        "duplicates": sorted(set(duplicates)),
    }


def _eg(ids, limit=3):
    """A count nobody can turn back into rows is not a worklist."""
    if not ids:
        return ""
    tail = ", ..." if len(ids) > limit else ""
    return "   e.g. %s%s" % (", ".join(ids[:limit]), tail)


def render_blind_spots(report, root):
    """THE REFUSAL: what this denominator cannot see, BY NAME.

    A count and no names is the same failure the rest of this file refuses --
    a number nobody can turn back into rows. Every id here is derived from the
    corpus on this run; none of them is written down in this file.
    """
    blind = report.get("blind_spots") or {}
    outside_live = blind.get("outside_closure_live") or []
    outside_terminal = blind.get("outside_closure_terminal") or []
    never = blind.get("never_published") or []
    phantoms = blind.get("phantoms") or []
    shadows = blind.get("draft_shadows_of_live") or []
    unread = blind.get("drafts_lens") != "read"

    # `LIVE`, NEVER `open`, IS THE WORD FOR ARM 1. A row outside the closure is
    # kept when its lifecycle is non-terminal, which is a WIDER set than the
    # denominator's own case-exact `open` -- it also holds `considering`,
    # `blocked` and `in_progress`. Calling all of them "open rows the
    # denominator cannot see" would over-claim in exactly the direction this
    # epic files against: `considering` PRECEDES open and is excluded from the
    # denominator ON PURPOSE, so it is not a row the denominator MISSED. Both
    # numbers are therefore derived and printed, and every row prints its own
    # lifecycle beside it.
    outside_open = [e for e in outside_live
                    if (e.get("lifecycle_status") or "") == LIFECYCLE_OPEN]

    out = []
    out.append("BLIND SPOTS -- live rows this denominator CANNOT see, by name (not a count)")
    if unread:
        out.append("  total       %d NAMED (%d of them `%s`) + the drafts lens UNREAD "
                   "(never-published class UNMEASURED)"
                   % (len(outside_live), len(outside_open), LIFECYCLE_OPEN))
    else:
        out.append("  total       %d live row(s) named below and counted by NO closure anchored "
                   "at %s -- %d of them `%s`, the denominator's own lens"
                   % (len(outside_live) + len(never), root,
                      len(outside_open) + len(never), LIFECYCLE_OPEN))
    out.append("  (1) OUTSIDE THE CLOSURE  %5d   slug carries `%s`, parent chain never reaches the root"
               % (len(outside_live), blind.get("epic_slug_prefix", EPIC_SLUG_PREFIX)))
    out.append("      unreachable at ANY depth, under any key -- a deeper walk does not find these")
    for entry in outside_live:
        out.append("      %s   (%s, parent %s)"
                   % (entry["id"], entry["lifecycle_status"], entry["parent_id"]))
    if not outside_live:
        out.append("      (none)")
    out.append("      + %d terminal row(s) outside the closure -- bookkeeping, not hidden work%s"
               % (len(outside_terminal), _eg(outside_terminal)))
    out.append("      LIMIT: keyed on a SLUG PREFIX, which is a naming convention and not a")
    out.append("      structural fact. An epic row named without `%s` is invisible to this arm too."
               % blind.get("epic_slug_prefix", EPIC_SLUG_PREFIX))
    if unread:
        out.append("  (2) NEVER PUBLISHED      UNREAD   %s" % (blind.get("drafts_unread_reason") or ""))
        out.append("      This is an ABSENCE, not a zero: the honest total is UNMEASURED on this run.")
        return out
    out.append("  (2) NEVER PUBLISHED      %5d   `open` draft, NO published twin -- HIDDEN WORK, added"
               % len(never))
    for entry in never:
        out.append("      %s   (no published twin)" % entry["id"])
    if not never:
        out.append("      (none)")
    out.append("  (3) PHANTOMS             %5d   `open` draft whose PUBLISHED twin is TERMINAL --"
               % len(phantoms))
    out.append("      an EDIT SHADOW, never hidden work. Adding these to the denominator OVERCOUNTS.")
    for entry in phantoms:
        out.append("      %s   (published twin: %s)" % (entry["id"], entry["twin"]))
    if not phantoms:
        out.append("      (none)")
    if shadows:
        out.append("  (4) DRAFT OVER A LIVE ROW %4d   the published twin is already IN the denominator"
                   % len(shadows))
        for entry in shadows:
            out.append("      %s   (published twin: %s)" % (entry["id"], entry["twin"]))
    out.append("  KNOWN AND UNFIXED: the read pages with explicit offsets over %s, so a row created"
               % report["page_order"])
    out.append("  mid-page is invisible to it -- and to any independent walk reading through the same")
    out.append("  pager. Two such walks AGREEING does not rule it out.")
    return out


def render(report, corpus_size, pages, page_limit, source, root, lens):
    out = []
    out.append("PDS LEDGER CENSUS")
    out.append("  instant     %s -> %s  (%.2fs)"
               % (report["instant"]["started"], report["instant"]["finished"],
                  report["instant"]["seconds"]))
    out.append("  source      %s" % source)
    out.append("  root        %s" % root)
    if report.get("round_anchor"):
        out.append("  round       born %s  (anchor: %s)"
                   % (report["round_anchor"], report["round_anchor_source"]))
        out.append("  anchor bind %s" % anchor_binding_line(report))
    out.append("  paging      %d page(s) of limit %d -> corpus %d rows  (page sizes: %s)"
               % (len(pages), page_limit, corpus_size, ", ".join(str(p) for p in pages)))
    out.append("  page order  order=%s   (explicit offsets over a MUTATING key can skip a row silently)"
               % report["page_order"])
    out.append("  closure     %d descendants over parent_id (lens=%s, max depth %d)"
               % (report["closure_size"], lens, report["max_depth"]))
    out.append("  live        %d  (terminal: %s)" % (report["live"], ", ".join(TERMINAL_LIFECYCLE)))
    # THE GUARD THIS INSTRUMENT ACTUALLY HAS, PRINTED, so a reader never assumes
    # the one it does not. MEASURED, not asserted: `echo scripts/pds-ledger-census.sh
    # | bash scripts/elixir-path-escape-check.sh --match test` prints `false` while
    # the same command prints `true` for scripts/pds-door-census.sh -- the required
    # Elixir gate does not dispatch on this path, so nothing in CI runs the checks
    # below on a PR that only touches this file.
    out.append("  guard       LOCAL-ONLY: `bash scripts/pds-ledger-census_test.sh`. The REQUIRED Elixir")
    out.append("              gate does NOT dispatch this path (elixir-path-escape-check --match test")
    out.append("              answers `false` for this script and `true` for scripts/pds-door-census.sh),")
    out.append("              so every number below is guarded by a check CI never runs. Run it yourself.")
    out.append("")
    out.append("lifecycle_status (closure, case-exact)")
    for key, count in sorted(report["lifecycle"].items(), key=lambda kv: (-kv[1], kv[0])):
        out.append("  %-16s %5d" % (key, count))
    out.append("")
    # THE DENOMINATOR, WITH ITS LENS NAMED AND ITS INSTANT ATTACHED. Every "N of
    # the open PDS rows" claim divides by THIS number, so it is printed with the
    # rule that produced it, the moment it was taken, and the command that takes
    # it again. It is never written down: this board moves while the wave that
    # reads it files rows.
    blind = report.get("blind_spots") or {}
    honest_extra = len(blind.get("never_published") or [])
    phantom_n = len(blind.get("phantoms") or [])
    out.append("open denominator (THE number every `N of the open PDS rows` claim divides by)")
    out.append("  open rows in the closure         %5d   lens: published + %s == `%s` (case-exact)"
               % (report["open_denominator"], report["open_denominator_field"],
                  report["open_denominator_value"]))
    out.append("              closure: transitive descendants of %s over parent_id, keyed on the SLUG" % root)
    out.append("              NOT disposition-keyed (live rows carry none, and those would vanish)")
    out.append("              NOT live/non-terminal (%d folds in `considering`, which PRECEDES open)"
               % report["live"])
    out.append("  taken at    %s   (this board moves; the number is derived, never pinned)"
               % report["instant"]["started"])
    out.append("  re-derive   %s" % REDERIVE_COMMAND)
    if blind.get("drafts_lens") == "read":
        out.append("  honest total                     %5d   = %d + %d never-published open row(s) below"
                   % (report["open_denominator"] + honest_extra,
                      report["open_denominator"], honest_extra))
        out.append("  OVERCOUNT if phantoms added      %5d   %d phantom(s) are edit shadows, NOT work -- see below"
                   % (report["open_denominator"] + honest_extra + phantom_n, phantom_n))
    else:
        out.append("  honest total                     UNMEASURED -- the drafts lens is UNREAD (see blind spots)")
    out.append("")
    out.append("disposition (closure, CASE-EXACT -- `%s` and `%s` are different values)"
               % (CANONICAL_OPEN, CANONICAL_OPEN.upper()))
    for key, count in sorted(report["dispositions"].items(), key=lambda kv: (-kv[1], kv[0])):
        out.append("  %-16s %5d" % (key, count))
    out.append("")
    out.append("disposition_reason")
    out.append("  non-empty                   %5d" % report["reasons_non_empty"])
    out.append("  distinct reason hashes      %5d" % report["reason_hashes_distinct"])
    out.append("  carrying a reopen trigger   %5d   (structured `reopen_trigger` field ONLY)"
               % report["reopen_triggers_structured"])
    out.append("  prose-only REOPEN mention   %5d   (DECORATION -- NEVER summed with the line above)"
               % report["reopen_triggers_prose_only"])
    out.append("")
    out.append("live coverage (LIVE rows only -- the round's own worklist)")
    out.append("  live rows                          %5d" % report["live"])
    out.append("  live rows with NO disposition      %5d%s"
               % (len(report["live_bare"]), _eg(report["live_bare"])))
    if report.get("round_anchor"):
        out.append("  ^ born after the anchor (RESIDUE)  %5d%s"
                   % (len(report["live_bare_residue"]), _eg(report["live_bare_residue"])))
    out.append("  live adjudicated with NO reason    %5d   (of %d adjudicated)%s"
               % (len(report["live_adjudicated_no_reason"]), report["live_adjudicated"],
                  _eg(report["live_adjudicated_no_reason"])))
    out.append("  live parked with NO reopen_trigger %5d   (of %d parked)%s"
               % (len(report["live_park_no_trigger"]), report["live_parked"],
                  _eg(report["live_park_no_trigger"])))
    out.append("  live AND dispositioned `%s`    %5d   (CLAIMABLE and adjudicated shut)%s"
               % (CLOSED_DISPOSITION, len(report["live_contradiction"]),
                  _eg(report["live_contradiction"])))
    out.append("")
    # CLAUSE 7. THREE SHAPES, THREE KEYS, THREE REMEDIES — and the lens they
    # were read through, printed, because a lens nobody can read back is a claim.
    out.append("claim lapse (three shapes, three KEYS, three REMEDIES -- clause 7)")
    # THE CAVEAT, AMENDED (wave 47) -- NOT retired. It was honest and it pointed
    # the WRONG WAY. Measured 2026-08-04 by running THIS file's lapse_shapes()
    # over both lenses: shape A 24 published -> 27 drafts-inclusive, and the +3
    # are EXACTLY the three phantoms (drafts.pds-w29-s3-fake-fails-closed,
    # drafts.pds-w27-census-self-honesty, drafts.pds-bl-tagregistry-guard-no-rung
    # -- each an unpublished edit shadow whose PUBLISHED twin is `done`). So the
    # published read does not UNDERCOUNT shape A; the drafts read MANUFACTURES
    # three false lapses. Shapes B and C were 0 on BOTH lenses and are therefore
    # UNDISCRIMINATED: their delta is not evidence the lenses agree. The live
    # delta is printed below from the current run, never from this comment.
    out.append("  lens        /v1/data/query perspective:%s -- the two lenses DISAGREE by construction"
               % report["lens_perspective"])
    out.append("              (a lapsed `drafts.` row is invisible here and visible to `bp task ls --all`).")
    out.append("              MEASURED 2026-08-04, and the direction is the SURPRISE: shape A 24 -> 27 over a")
    out.append("              drafts-inclusive read, and the +3 are EXACTLY the three PHANTOMS below -- edit")
    out.append("              shadows of `done` rows. The published read does not UNDERCOUNT shape A; the")
    out.append("              drafts read MANUFACTURES three false lapses. Shapes B and C were 0 on BOTH")
    out.append("              lenses: UNDISCRIMINATED, so their deltas prove nothing either way.")
    delta = (report.get("blind_spots") or {}).get("lapse_delta")
    if delta is None:
        out.append("              THIS RUN: drafts lens UNREAD, so the per-shape delta is UNMEASURED, not 0.")
    else:
        out.append("              THIS RUN: drafts-lens delta  A +%d  B +%d  C +%d%s"
                   % (len(delta["shape_a"]), len(delta["shape_b"]), len(delta["shape_c"]),
                      _eg(delta["shape_a"])))
    out.append("  shape A  reverted-to-open after expiry   %5d   (%d carrying work evidence)%s"
               % (len(report["lapse_shape_a"]), len(report["lapse_shape_a_work_evidence"]),
                  _eg(report["lapse_shape_a"])))
    out.append("           key: open + claim.worker null + previous_worker + expired_at, no released_at/closed_at")
    out.append("           REMEDY: the row is a RE-OPEN LIE -- re-claim it and close it on the evidence it carries")
    out.append("  shape B  in_progress held past the lease %5d   (TTL %ds, key: instant - claim.ts_iso)%s"
               % (len(report["lapse_shape_b"]), report["lease_ttl_seconds"],
                  _eg(report["lapse_shape_b"])))
    out.append("           key: in_progress + held longer than the TTL -- NEVER expired_at, which the REAP")
    out.append("           writes, so an expired_at-keyed check passes VACUOUSLY on this shape forever")
    out.append("           REMEDY: `bp task release` -- shape B cannot self-heal while the lease is held")
    out.append("  shape C  open with a claim never cleared %5d%s"
               % (len(report["lapse_shape_c"]), _eg(report["lapse_shape_c"])))
    out.append("           key: open + claim.worker SET + claim.closed_at SET")
    out.append("           REMEDY: clear the stale claim -- a worker-keyed check reads this row as HELD")
    out.append("")
    out.extend(render_blind_spots(report, root))
    out.append("")
    out.append("off-vocabulary disposition values (vocabulary: %s)"
               % ", ".join(DISPOSITION_VOCABULARY))
    if report["off_vocabulary"]:
        for key, count in sorted(report["off_vocabulary"].items(), key=lambda kv: (-kv[1], kv[0])):
            out.append("  %-16s %5d   e.g. %s"
                       % (key, count, ", ".join(report["off_vocabulary_samples"].get(key, []))))
    else:
        out.append("  (none)")
    return "\n".join(out)


def round_done_predicate(report):
    """THE DONE-CONDITION, AS A PURE FUNCTION OF `report`.

    It returns (human_lines, failures) and prints NOTHING. That is the whole
    point: it can therefore be called BEFORE the single emit site, so
    `round_done` / `round_done_failures` ride in the payload while the emit
    stays exactly where it is.

    DO NOT "simplify" this by computing the verdict after the emit. The
    clause-5 incoherence path (exit 4) runs after the emit and still prints a
    valid payload today; a deferred emit turns rc=4 / 985 bytes / jq 0 into
    rc=4 / 0 bytes / jq 4 -- a fresh honesty regression inside the honesty fix.
    """
    lines = []
    failures = []

    distinct = report["reason_hashes_distinct"]
    non_empty = report["reasons_non_empty"]
    off_vocab = report["off_vocabulary_total"]
    lines.append("")
    lines.append("ROUND-DONE PREDICATE")
    lines.append("  distinct reason hashes == non-empty reasons   %d == %d   %s"
                 % (distinct, non_empty, "PASS" if distinct == non_empty else "FAIL"))
    if distinct != non_empty:
        failures.append("%d duplicate reason(s): %d non-empty reasons collapse to %d "
                        "hashes -- boilerplate is not a reason"
                        % (non_empty - distinct, non_empty, distinct))
    lines.append("  non-empty reasons > 0                          %d        %s"
                 % (non_empty, "PASS" if non_empty > 0 else "FAIL"))
    if non_empty == 0:
        failures.append("zero non-empty reasons -- an all-empty board trivially has "
                        "all-distinct reasons; that is not done, it is unstarted")
    lines.append("  off-vocabulary dispositions == 0               %d        %s"
                 % (off_vocab, "PASS" if off_vocab == 0 else "FAIL"))
    if off_vocab:
        failures.append("%d row(s) carry a disposition outside {%s} (canonical OPEN "
                        "case is `%s`)" % (off_vocab, ", ".join(DISPOSITION_VOCABULARY),
                                           CANONICAL_OPEN))

    # CLAUSE 4 -- the ONLY live-scoped clause. Clauses 1-3 above stay
    # closure-scoped on purpose: distinctness and vocabulary are properties
    # of everything ever written. Three sub-lines, each able to say no alone.
    bare = report["live_bare"]
    residue = report["live_bare_residue"]
    no_reason = report["live_adjudicated_no_reason"]
    no_trigger = report["live_park_no_trigger"]
    contradiction = report["live_contradiction"]
    if report["round_anchor"]:
        lines.append("  round anchor                                  %s   (%s)"
                     % (report["round_anchor"], report["round_anchor_source"]))
        lines.append("  round anchor binding                          %s"
                     % anchor_binding_line(report))
    # THE NUMERATOR IS LITERAL. `bare` is the ANCHORED subset, so
    # `live - len(bare)` would count every residue row as carrying a
    # disposition and print "172/172 PASS" over a board where 15 rows carry
    # nothing -- a success claim about rows nobody looked at, which is the
    # exact defect class this epic exists to kill. The residue is subtracted
    # out and reported on its own line below: the denominator still names the
    # WHOLE live board, so deferring can never shrink what 4(a) covers.
    lines.append("  live rows carrying a disposition               %d/%d    %s"
                 % (report["live"] - len(bare) - len(residue), report["live"],
                    "PASS" if not bare else "FAIL"))
    if report["round_anchor"]:
        # A NAMED WORKLIST, NEVER A BARE COUNT: these rows were born after the
        # round started, so they are the NEXT round's inbox -- deferred by
        # exactly one round, and in scope the moment it anchors on its own
        # Paper.
        lines.append("  ^ deferred to the next round (RESIDUE)        %d        %s"
                     % (len(residue), "next-round inbox"))
        for row_id in residue:
            lines.append("      residue: %s" % row_id)
    if bare:
        failures.append("%d LIVE row(s) carry NO disposition -- a live row that says "
                        "nothing is what clauses 1-3 cannot see: %s"
                        % (len(bare), ", ".join(bare[:8]) + (", ..." if len(bare) > 8 else "")))
    lines.append("  live adjudicated rows carrying a reason        %d/%d    %s"
                 % (report["live_adjudicated"] - len(no_reason), report["live_adjudicated"],
                    "PASS" if not no_reason else "FAIL"))
    if no_reason:
        failures.append("%d LIVE adjudicated row(s) carry NO disposition_reason -- a "
                        "verdict with no reason is unprovable: %s"
                        % (len(no_reason),
                           ", ".join(no_reason[:8]) + (", ..." if len(no_reason) > 8 else "")))
    lines.append("  live parked rows carrying a reopen_trigger     %d/%d    %s   (STRUCTURED field, not prose)"
                 % (report["live_parked"] - len(no_trigger), report["live_parked"],
                    "PASS" if not no_trigger else "FAIL"))
    if no_trigger:
        failures.append("%d LIVE parked row(s) carry NO structured reopen_trigger (prose "
                        "that merely mentions REOPEN is decoration, PDS-D336(b)): %s"
                        % (len(no_trigger),
                           ", ".join(no_trigger[:8]) + (", ..." if len(no_trigger) > 8 else "")))

    # CLAUSE 6 -- the contradiction (PDS-D372/D373). Beside clause 4, never
    # inside it: 4 asks whether a live row SAYS anything, 6 asks whether what it
    # says agrees with the queue that is handing it out.
    lines.append("  live rows NOT dispositioned `%s`           %d/%d    %s   (CLAIMABLE and adjudicated shut)"
                 % (CLOSED_DISPOSITION, report["live"] - len(contradiction),
                    report["live"], "PASS" if not contradiction else "FAIL"))
    if contradiction:
        failures.append("%d LIVE row(s) are CLAIMABLE and dispositioned `%s` -- `bp task "
                        "ready` hands out a row the ledger calls shut, and clause 4(a) "
                        "counts it as adjudicated: %s"
                        % (len(contradiction), CLOSED_DISPOSITION,
                           ", ".join(contradiction[:8])
                           + (", ..." if len(contradiction) > 8 else "")))

    # CLAUSE 7 -- the lapse (PDS-D638). THREE LINES, never one: the shapes do
    # not share a key and they do not share a remedy, so a single "lapsed: N"
    # line would name none of them. Each can say no on its own.
    lapse_a = report["lapse_shape_a"]
    lapse_b = report["lapse_shape_b"]
    lapse_c = report["lapse_shape_c"]
    lines.append("  claims NOT lapsed-to-open (shape A)           %d/%d    %s   (re-open lie: %d carry work evidence)"
                 % (report["live"] - len(lapse_a), report["live"],
                    "PASS" if not lapse_a else "FAIL",
                    len(report["lapse_shape_a_work_evidence"])))
    if lapse_a:
        failures.append("%d row(s) are SHAPE A -- reverted to `open` by the TTL sweeper with "
                        "the claim's previous_worker and expired_at still on them (%d carry a "
                        "now-line, so the work was mid-flight). REMEDY: re-claim and close on "
                        "the evidence already there: %s"
                        % (len(lapse_a), len(report["lapse_shape_a_work_evidence"]),
                           ", ".join(lapse_a[:8]) + (", ..." if len(lapse_a) > 8 else "")))
    lines.append("  leases held INSIDE the TTL (shape B)          %d/%d    %s   (TTL %ds, NEVER keyed on expired_at)"
                 % (report["live"] - len(lapse_b), report["live"],
                    "PASS" if not lapse_b else "FAIL", report["lease_ttl_seconds"]))
    if lapse_b:
        failures.append("%d row(s) are SHAPE B -- `%s` and held past the %ds lease with no reap "
                        "(a check keyed on claim.expired_at would pass VACUOUSLY here, forever). "
                        "REMEDY: `bp task release`: %s"
                        % (len(lapse_b), LIFECYCLE_IN_PROGRESS, report["lease_ttl_seconds"],
                           ", ".join(lapse_b[:8]) + (", ..." if len(lapse_b) > 8 else "")))
    lines.append("  open rows with NO stale claim (shape C)       %d/%d    %s   (worker SET and closed_at SET)"
                 % (report["live"] - len(lapse_c), report["live"],
                    "PASS" if not lapse_c else "FAIL"))
    if lapse_c:
        failures.append("%d row(s) are SHAPE C -- `open` while still wearing a finished claim "
                        "(worker SET and closed_at SET); a worker-keyed check reads them as HELD "
                        "and an expiry-keyed check cannot see them at all. REMEDY: clear the "
                        "stale claim: %s"
                        % (len(lapse_c),
                           ", ".join(lapse_c[:8]) + (", ..." if len(lapse_c) > 8 else "")))

    return lines, failures


def main(argv):
    parser = argparse.ArgumentParser(add_help=True, prog="pds-ledger-census.sh")
    parser.add_argument("--root", default=DEFAULT_ROOT)
    parser.add_argument("--dataset", default="production")
    parser.add_argument("--type", dest="doctype", default="task")
    parser.add_argument("--page-limit", type=int, default=DEFAULT_PAGE_LIMIT)
    parser.add_argument("--pace", type=float, default=DEFAULT_PACE_SECONDS)
    parser.add_argument("--retries", type=int, default=DEFAULT_RETRIES)
    parser.add_argument("--lens", choices=("closure", "children"), default="closure",
                        help="closure = transitive over parent_id. `children` is the "
                             "one-level undercounting lens, present only so the "
                             "selftest can inject it.")
    parser.add_argument("--assert-round-done", action="store_true")
    parser.add_argument("--anchor-from-paper", metavar="WAVE-PAPER-SLUG",
                        help="derive the round anchor from the wave Paper's "
                             "_createdAt. Clause 4(a) then asserts only over live "
                             "rows born at or before it; rows born after it are "
                             "named as residue.")
    parser.add_argument("--anchor", metavar="ISO-8601",
                        help="SELFTEST CLOCK ONLY -- refused outside --fixture-dir, "
                             "because a caller-supplied anchor lets a round seal "
                             "itself by argv.")
    parser.add_argument("--anchor-unbound", action="store_true",
                        help="accept an --anchor-from-paper slug that DISAGREES with the "
                             "epic root's %s. The divergence is printed and rides in "
                             "--json as round_anchor_binding=override." % ROUND_ANCHOR_FIELD)
    parser.add_argument("--no-anchor", action="store_true",
                        help="do not derive an anchor from the root's %s. This is the "
                             "STRICTER clause (nothing is deferred), so it can never seal "
                             "a round." % ROUND_ANCHOR_FIELD)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--fixture-dir")
    parser.add_argument("--server")
    parser.add_argument("--token")
    args = parser.parse_args(argv)

    if args.page_limit < 1:
        die(EXIT_USAGE, "--page-limit must be >= 1")
    if args.pace < 0 or args.retries < 0:
        die(EXIT_USAGE, "--pace and --retries must be >= 0")

    # THE ANCHOR GUARD. A raw --anchor is the selftest's clock and nothing else:
    # on the live board `--anchor 2020-01-01T00:00:00Z` flips 4(a) from 157/172
    # FAIL to 172/172 PASS, so a certifying run that could accept one could seal
    # itself by argv.
    if args.anchor and not args.fixture_dir:
        die(EXIT_USAGE,
            "--anchor is refused outside --fixture-dir: a caller-supplied anchor "
            "lets a round seal itself by argv (measured: --anchor 2020-01-01 flips "
            "clause 4(a) from 157/172 FAIL to 172/172 PASS on the live board). Use "
            "--anchor-from-paper <wave-slug>, which derives the instant.")
    if args.anchor and args.anchor_from_paper:
        die(EXIT_USAGE, "--anchor and --anchor-from-paper are mutually exclusive")
    # --no-anchor is an opt-out of the DERIVED anchor, never a modifier of one:
    # a run that asked for both an anchor and no anchor has not said what it
    # wants, and guessing for it is how a boundary moves unnoticed.
    if args.no_anchor and (args.anchor or args.anchor_from_paper):
        die(EXIT_USAGE, "--no-anchor and --anchor/--anchor-from-paper are mutually exclusive")
    # A flag that OVERRIDES NOTHING must not be reachable: it would print an
    # override caveat on a run that never diverged, and a caveat that fires
    # everywhere is one nobody reads.
    if args.anchor_unbound and not args.anchor_from_paper:
        die(EXIT_USAGE, "--anchor-unbound overrides nothing without --anchor-from-paper")

    if args.fixture_dir:
        if not os.path.isdir(args.fixture_dir):
            die(EXIT_USAGE, "--fixture-dir %s is not a directory" % args.fixture_dir)
        transport = FixtureTransport(args.fixture_dir)
    else:
        server = args.server or os.environ.get("BARKPARK_SERVER")
        token = args.token or os.environ.get("BARKPARK_TOKEN")
        if not server or not token:
            config = os.path.expanduser("~/.config/barkpark/config.json")
            if os.path.exists(config):
                with open(config) as fh:
                    data = json.load(fh)
                server = server or data.get("server")
                token = token or data.get("token")
        if not server or not token:
            die(EXIT_USAGE,
                "no server/token: pass --server/--token, set BARKPARK_SERVER/"
                "BARKPARK_TOKEN, or run `bp login`")
        transport = HttpTransport(server, token)

    # CLAUSE 5: the window is named before the first byte is read.
    started = datetime.now(timezone.utc)
    corpus, pages, duplicates, perspectives = read_corpus(
        transport, args.dataset, args.doctype, args.page_limit, args.pace, args.retries)
    finished = datetime.now(timezone.utc)

    if args.root not in corpus:
        die(EXIT_FAIL_CLOSED,
            "root %s is not in the %d-row corpus -- refusing to census an empty "
            "closure under a root that does not exist" % (args.root, len(corpus)))

    # THE ANCHOR IS RESOLVED OUTSIDE THE CLAUSE-5 WINDOW -- on the FAR side of
    # it now, beside the drafts lens, and for the same reason the drafts lens
    # sits there: `finished` is already stamped, so nothing this read does can
    # be mistaken for part of the snapshot clause 5 asserts coherence over. It
    # MOVED here (it used to run before the window) because binding the anchor
    # to the round means reading the epic root's own ROUND_ANCHOR_FIELD, and the
    # root row arrives with the corpus. One resolution site, one binding.
    anchor, anchor_source, anchor_slug, anchor_binding, anchor_declared = resolve_round_anchor(
        transport, args.dataset, args.root, corpus[args.root], args)

    closure, depth_of = build_closure(corpus, args.root, args.lens)
    if not closure:
        die(EXIT_FAIL_CLOSED,
            "root %s has zero descendants in a %d-row corpus" % (args.root, len(corpus)))

    # CLAUSE 7's ONE TUNABLE, resolved from the SAME env var the server reads.
    lease_ttl, lease_ttl_source = lease_ttl_seconds()

    # THE SECOND LENS, READ AFTER the window clause 5 asserts coherence over is
    # CLOSED. It is a different perspective on the same rows, so folding it into
    # that window would make the snapshot an average of two reads -- exactly the
    # thing clause 5 refuses. Nothing it finds enters the denominator; it enters
    # the REFUSAL beside it.
    drafts, drafts_unread = read_drafts_lens(
        transport, args.dataset, args.doctype, args.page_limit, args.pace, args.retries)

    report = census(corpus, closure, depth_of, started, finished, duplicates, anchor,
                    lease_ttl)
    report["blind_spots"] = blind_spots(
        corpus, closure, args.root, drafts, drafts_unread, started, lease_ttl)
    report["lease_ttl_source"] = lease_ttl_source
    # THE LENS IS DERIVED, NOT DECLARED. If the pages disagreed about the
    # perspective they answered with, ALL of them are named -- an averaged lens
    # is the same lie as an averaged snapshot.
    report["lens_perspective"] = "+".join(perspectives) if perspectives else "<unset>"
    report["round_anchor"] = (
        anchor.isoformat().replace("+00:00", "Z") if anchor is not None else None)
    report["round_anchor_source"] = anchor_source
    # THE BINDING RIDES IN THE PAYLOAD. A consumer must be able to ask which
    # round this anchor belongs to without scraping prose -- the slug that was
    # used, the slug the round DECLARES, and which of the two the run was
    # entitled to.
    report["round_anchor_slug"] = anchor_slug
    report["round_anchor_binding"] = anchor_binding
    report["round_anchor_declared"] = anchor_declared or None
    report["root"] = args.root
    report["lens"] = args.lens
    report["corpus_size"] = len(corpus)
    report["pages"] = pages
    report["page_limit"] = args.page_limit
    report["source"] = transport.describe()
    report["page_order"] = PAGE_ORDER

    # THE PREDICATE IS COMPUTED BEFORE THE EMIT, and it is PURE (it prints
    # nothing). That is what lets `round_done` ride in the payload without
    # moving the emit -- and the emit must not move: the clause-5 exit-4 path
    # below runs after it and its payload is exactly the one a failing run needs.
    predicate_lines, round_done_failures = round_done_predicate(report)
    report["round_done"] = not round_done_failures
    report["round_done_failures"] = round_done_failures

    # STDOUT IS THE MACHINE CHANNEL. Under --json this is the ONLY thing written
    # to it; every human line below goes to stderr, so `jq -e .` works on the
    # green path and on the red one alike. Without --json stdout stays the HUMAN
    # channel it has always been, and the predicate block goes there with the
    # report it belongs to.
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render(report, len(corpus), pages, args.page_limit,
                     transport.describe(), args.root, args.lens))

    # CLAUSE 5 verdict: report first, THEN refuse to call an average a snapshot.
    if report["duplicates"]:
        die(EXIT_INCOHERENT,
            "%d row(s) were served on more than one page -- the corpus shifted "
            "under pagination" % len(report["duplicates"]),
            report["duplicates"][:8])
    if report["drifted"]:
        die(EXIT_INCOHERENT,
            "%d row(s) in the closure were updated INSIDE the named window "
            "%s -> %s. This is an average, not a snapshot. Re-run."
            % (len(report["drifted"]), report["instant"]["started"],
               report["instant"]["finished"]),
            ["%s updated %s" % (i, t) for i, t in report["drifted"][:8]])

    # THE HUMAN BLOCK FOLLOWS THE HUMAN STREAM. Under --json stdout is the
    # machine channel and every human line goes to stderr, which is the whole
    # point of the wave-27 fix. Under the DEFAULT render, stdout is ALREADY the
    # human channel (the report above went there), so sending the predicate to
    # stderr would split one human document across two streams and silently
    # empty `census.sh --assert-round-done > report.txt` of the very verdict it
    # was run for. One variable, resolved once, so the two modes cannot drift.
    human = sys.stderr if args.json else sys.stdout

    if args.assert_round_done:
        for line in predicate_lines:
            print(line, file=human)
        if round_done_failures:
            print("", file=human)
            # The refusal itself stays on stderr in BOTH modes: it is a
            # diagnostic, it predates this change, and a caller that redirects
            # stdout to a report file must still see the refusal on its terminal.
            print("VERDICT: ROUND NOT DONE", file=sys.stderr)
            for failure in round_done_failures:
                print("  - %s" % failure, file=sys.stderr)
            sys.exit(EXIT_ROUND_NOT_DONE)
        print("", file=human)
        print("VERDICT: ROUND DONE", file=human)
        return EXIT_OK

    print("", file=human)
    print("VERDICT: census complete and coherent", file=human)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF
