#!/usr/bin/env bash
# crown-reconcile.sh — the crown stops self-certifying.
#
# WHAT WAS BROKEN
#
# Every verdict this repository produces about `platform_deliveries` is produced
# INSIDE the delivering run. `record-delivery` (deploy.yml) sets `delivered=true`
# from the rc of its own POST, and `report-recorder-failure` fires only when THAT
# run's POST failed. Both are structurally blind to the two shapes that matter:
#
#   * a run whose `if:` gated the recorder off — no POST, so no rc, so no scream
#   * a run that never reached the recorder job at all
#
# Both leave a DELIVERED SHA WITH NO ROW, and nothing anywhere says so. Measured
# 2026-08-09: barkpark.cloud was serving a95bc7ca9747cb3d90a361c4d54eb2c068a24e32
# and `GET /v1/deliveries?sha=a95bc7ca9…` answered `count: 0`. The crown had no
# record of the commit production was actually running.
#
# THIS SCRIPT IS THE FIRST THING IN THE REPO THAT READS THE ACTIONS API AND THE
# CROWN TOGETHER. It asks three questions and each one can lose:
#
#   BEHIND    a DELIVERING deploy.yml run in the window — one whose control-plane
#             or instance leg concluded success, WHATEVER the run's overall
#             conclusion — delivered a head sha the crown has no row for. The run
#             happened; the record does not exist.
#   WRONG     a crown row inside the window was written by no DELIVERING run —
#             no run in the window put code on a box through either leg for it.
#             The record exists; the delivery does not.
#   SERVING   the sha barkpark.cloud reports it is SERVING has no `cp` row. This
#             is the a95bc7ca9 case, and it is the sharpest of the three: the
#             box is running code the platform's own record has never heard of.
#
# WHY SHA-DRIVEN AND NOT WINDOW-DRIVEN
#
# `PlatformDelivery.list/1` accepts ONLY `:sha` and `:limit` (platform_delivery.ex)
# and `GET /v1/deliveries` passes through only those two (router.ex). "Rows over a
# pinned window" is NOT expressible today, and this slice adds no migration and no
# route change. So the runs drive: enumerate successful runs, then ask the crown
# one sha at a time. An unknown sha is an honest empty list, and that empty IS the
# BEHIND verdict.
#
# WHY DOCS-ONLY RUNS ARE NOT COUNTED
#
# deploy.yml's `changes` job path-filters, so a docs-only merge succeeds with BOTH
# deploy legs skipped — it delivered nothing and must produce no row. Counting it
# would manufacture a BEHIND on every docs merge and drown the real ones. A run is
# a DELIVERING run here only when its `control-plane` or `instance` job concluded
# `success`; that is read per run from the jobs API, never assumed.
#
# AND THE LEGS OWN THE POPULATION, NOT THE RUN'S CONCLUSION. This filtered the run
# page to `.conclusion == "success"` BEFORE it ever looked at a leg, so a deploy
# whose instance leg succeeded and whose control-plane leg failed — overall
# conclusion `failure`, and it PUT CODE ON A BOX — was absent from the delivering
# set, and the recorder's own true row was called WRONG. Measured live: run
# 33816988316 (jobs: instance success, control-plane failure, `record-delivery`
# success) wrote row b11be4f43, and crown-reconcile answered `wrong=7/100` on every
# main push from 08:34Z 2026-09-03. The population is now every COMPLETED run on
# the page, judged by its legs; the run's own conclusion is not consulted.
#
# CARRIED ROWS ARE NOT WRONG. ~36% of merged shas have no run of their own and
# ride a later sha's range; the recorder marks those `carried: true`. A carried
# row naming a sha with no run of its own is CORRECT, so only NON-carried rows can
# be WRONG. A row whose `carried` is absent was never measured — it is printed as
# UNCLASSIFIED and is never counted clean.
#
# THE ALIBI IS `delivering_run_id`, NOT THE HEAD SHA (charter D496).
#
# This axis first alibied a non-carried row by looking for its sha among the
# delivering runs' HEAD shas, and that premise was inverted four minutes before
# this script merged: the recorder now writes the sha the BOX WAS SERVING as the
# primary `carried=false` row and stores the run's own trigger sha as `carried=true`.
# When a deploy's `git pull` races past its trigger sha — two merges 13s apart,
# coalesced into one run — the served sha structurally CANNOT appear in a set built
# from head shas, and a correct row was accused of being a ghost (measured live:
# `wrong=1/28` naming 8e83b709a, a row that was right).
#
# So a non-carried row is legitimate iff its `delivering_run_id` is in the
# delivering set — the recorder's own statement of which run wrote it, already on
# both read paths (PlatformDelivery.to_json/1 and the SQL fallback's SELECT above),
# so no migration and no route change. The head-sha comparison survives ONLY as the
# fallback for a row that carries no `delivering_run_id` at all, which is how rows
# written before that field existed are still judged rather than waved through.
#
# PREDATES-WRITER IS A NAMED CLASS, NOT A NARROWED WINDOW (charter D496).
#
# `record-delivery` — the only thing that writes `platform_deliveries` from inside
# a run — came into existence at RECORDER_BIRTH_ISO below (PR #11167, merge
# 67f4a6ab2). A delivering run created BEFORE that instant had nothing that could
# have recorded it, so calling it BEHIND is an accusation with no defendant. It is
# reported in its OWN class, with its own count and the birth instant printed, and
# it is excluded from the BEHIND denominator. It is deliberately NOT hidden by
# shrinking the window: an exemption has to be a printed denominator, never a
# quieter one. If EVERY delivering run in the window predates the writer there is
# no denominator left, and that is a warning (rc 2), never a green.
#
# CREDENTIALS: NONE ARE ADDED. Two read paths, in this order, and the one that
# answered is printed:
#
#   1. CROWN_API_TOKEN in the environment (a read-ability PAT) — the local /
#      operator path, used to prove this script on live data by hand.
#   2. CP_HOST + DEPLOY_SSH_KEY — the CI path, and the same one deploy.yml's
#      recorder already documents: SSH the control plane, discover the container
#      BY IMAGE TAG (never by name: blue/green renames it), read the token out of
#      the running container, issue the read from the box.
#
#      The route's reader tier is `require_user_or_pat_or_worker` +
#      `require_ability("read")` since PR #14979, and WORKER_TOKEN is exactly the
#      WORKER principal that tier admits — so a 401/403 to that bearer is a
#      REGRESSION of that fix, not a tier mismatch. THERE IS ONE READER PER
#      TRANSPORT AND NO SUBSTITUTE. This used to fall back to reading
#      `platform_deliveries` straight out of the control plane's postgres
#      container, and because that detour ALWAYS fired it rendered a dead route
#      as a `note:` and never once as a verdict (run 31311887504: 22 downgrades,
#      one per sha, all green). The detour is DELETED. A 401/403 now prints
#      CR_ERROR=http_<code>_worker_principal, names the route, the principal and
#      #14979, counts as a read that did not happen, and the run exits 2 saying
#      so. A read that cannot happen is rc 2, never a green.
#
# AN EXPLICITLY-EMPTY PAT IS A CONFIGURATION FAULT, A MISSING ONE IS NOT
# (charter D530).
#
# A MISSING CROWN_API_TOKEN is the CI path: it falls through to the SSH reader
# above and returns 0, and making it fatal would break the only reader that
# actually runs on a schedule today. But `CROWN_API_TOKEN=` — the variable SET
# and EMPTY — is a different statement: a reader was explicitly asked for and is
# not there. Both printed `reader=ssh`, IDENTICALLY, so an operator who exported
# an empty token was silently downgraded to a reader they did not choose. Set
# but empty is now rc 3, with its own sentence; unset still falls through.
#
# WHICH READER ANSWERED IS A VERDICT FIELD, NOT A `note:` (charter D531).
#
# `reader=ssh` names the TRANSPORT, and the transport is not the reader: a live
# run printed the 401 downgrade TEN times as a `note:` on stderr, behind a header
# that said only `reader=ssh`. The reader that ANSWERED is counted per read and
# printed as its own line beside the verdict, and it rides the VERDICT sentence
# itself. Since the postgres detour was deleted (#14979) the only reader an SSH
# transport can name is `route` — so the field's other job is to print the
# REFUSALS: a 401/403 to the WORKER principal is counted, named, and cannot be
# answered by a substitute.
#
# A GRACE IS A DEFERRAL, SO IT MUST LEAVE A DEBT BEHIND (charter D511).
#
# The serving check grants a grace to a serving sha whose process is younger than
# SERVING_GRACE_SECONDS: a deploy may still be in flight and its recorder may not
# have posted yet. That grace used to persist NOTHING, and the check only ever
# reads the sha the box is serving RIGHT NOW, so the deferral had no deferred
# re-read. Measured 2026-08-09: 4c8314c94's deploy run 31316124617 was CANCELLED
# with zero jobs — no row could ever exist for it — yet barkpark.cloud served it
# 13:34Z–13:42Z. Four consecutive runs graced it (ages -3s / 53s / 105s / 200s),
# then the box moved to 02475d0ec and the accusation became UNMAKEABLE. Any sha
# replaced inside 1200s was structurally unaccusable, which at today's merge
# cadence is most of them.
#
# So a granted grace now writes `<sha> <first-seen-epoch>` to a RE-ASK LIST that
# survives the run (--state-file / CROWN_STATE_FILE; $WORK is rm -rf'd by the
# cleanup trap, so the list cannot live there). The boundary, stated explicitly:
#
#   * ENTERING the list: the ONLY writer is the serving grace. A sha the box
#     serves, with no `cp` row, whose process is younger than the grace.
#   * WHILE ON the list: every later run re-asks the crown about that sha,
#     WHETHER OR NOT the box still serves it. Still no row → GRACED-UNRECORDED,
#     exit 1. The grace is charged against FIRST-SEEN, not against process age,
#     so one sha gets ONE grace window of SERVING_GRACE_SECONDS in total and
#     never a fresh one per run.
#   * CLEAN RETIREMENT: a `cp` row appearing for that sha. That is the only exit
#     that means the system worked.
#   * DIRTY RETIREMENT: REASK_MAX_SECONDS with no row. The sha has already been
#     accused on every run in between, so ageing off ends an unbounded list
#     rather than forgiving anything — and it is printed as an unreadable
#     condition, never as silence.
#   * NO LIST AT ALL (nothing carries the state file between runs): the re-read
#     degrades to within-run only. That is a real hole, and it is the workflow's
#     job to point CROWN_STATE_FILE at a path that persists.
#
# THE RE-ASK LIST STATES ITSELF, BECAUSE AN ABSENT LIST LOOKED EXACTLY LIKE AN
# EMPTY ONE (charter D533).
#
# `state_load` used to open with `[ -f "$STATE_FILE" ] || return 0` — a bare
# silent early return — and the workflow set CROWN_STATE_FILE NOWHERE, so every
# scheduled run wrote the list to a fresh ubuntu-latest VM that was then
# destroyed. GRACED-UNRECORDED was STRUCTURALLY UNABLE TO FIRE in production,
# and nothing said so: measured 2026-08-09 on this script's own base fixture, an
# ABSENT state file and a PRESENT-but-header-only one produced output with the
# SAME md5 (4b4399a7f447f078b11943d574892e3e), both ending in `RECONCILED: …
# and no earlier grace is still owed a row` — an ASSERTION about a memory the
# run did not have.
#
# So the list now states itself on EVERY run, in ONE line, over four states:
#
#   UNCONFIGURED   no path at all → already a reason(), so rc 2. Unchanged.
#   ABSENT         a path, no file. A REASON: the memory was DESTROYED between
#                  runs, and a grace granted on a previous run cannot be
#                  re-asked. NOT counted clean.
#   ABSENT-FIRST-RUN
#                  a path, no file, and the CALLER has PROVEN the persistent
#                  store has never held a list (CROWN_STATE_FIRST_RUN=1). There
#                  is no memory to have lost, so there is nothing to re-ask and
#                  nothing to accuse. NOT a fault. See below — this claim is the
#                  caller's, and only a caller that actually looked may make it.
#   PRESENT-EMPTY  the file exists and holds nothing. NOT a fault — it is the
#                  affirmative statement that nothing is owed.
#   PRESENT        N entries loaded.
#
# A FIRST RUN IS NOT A DESTROYED MEMORY, AND ONLY THE CALLER CAN TELL THEM APART
# (charter D545).
#
# This script sees exactly one thing: a local path with no file behind it. That
# byte-identical absence is produced by THREE different worlds — the store has
# never been written (a genuine first run), the store was written and then lost,
# and the transport that would have fetched it failed. Calling all three
# DESTROYED pages on the first run past every harness fix, by construction, over
# a file that has never existed; calling all three FIRST RUN launders the two
# that matter. Neither reading is available from here.
#
# The caller CAN tell them apart, because the caller holds the store. So the
# statement is the caller's and it is explicit: CROWN_STATE_FIRST_RUN=1 means
# "I reached the persistent store, and it holds no list yet". The workflow sets
# it ONLY from a remote existence test that SUCCEEDED — a fetch that failed
# leaves it unset, so transport silence still lands in ABSENT and still pages.
#
# A GRACE IS A DEFERRAL, AND A DEFERRAL IS NOT A SILENCE (charter D545).
#
# rc 2 used to mean four unrelated things at once: an empty population, a window
# whose every run predates the recorder, a genuine unreadable condition — and the
# SERVING GRACE, whose own printed sentence calls itself a DEFERRAL. Measured
# over crown-reconcile.yml's entire history: rc=2 fired SIX times, FIVE of them
# the benign in-flight grace (four of those the same sha in four consecutive
# minutes) and ZERO of them a real crown mismatch. An alarm that is wrong five
# times in six gets muted, and a muted alarm is a dead gate.
#
# So the grace no longer sets UNREADABLE. It goes through defer(), which counts
# and names it exactly as reason() does but keeps it out of the silence, and it
# exits 4 — NOT YET DUE — which the workflow renders as a ::warning and a green
# step. NOTHING IS FORGIVEN BY THIS: the grace still writes the sha to the
# re-ask list, and the next run that still finds no row fires GRACED-UNRECORDED
# and exits 1. The accusation is deferred by one run, which is what "deferred"
# has always meant here. An unreadable condition in the SAME run still wins: 2
# is checked before 4, so a deferral can never launder a silence.
#
# and `state_save` closes symmetrically with `wrote M entry(ies)`. `wrote M>0`
# followed by the next run's `loaded 0` is the eviction signature, readable with
# no new instrument. D (dropped) is counted SEPARATELY from N so a corrupted
# list cannot masquerade as a short one.
#
# WHERE THE LIST LIVES IS THE WORKFLOW'S DECISION, AND IT IS NOT actions/cache.
# `actions/cache` evicts after 7 days SILENTLY, and a cache miss is
# indistinguishable from an empty list — which is the exact defect above. The
# workflow instead fetches and writes the list back over the SSH it already
# holds, to /var/lib/crown-reconcile/ on CP_HOST, and names that location to
# this script through CROWN_STATE_STORAGE so the printed line says WHERE the
# memory was supposed to be, not just which local path was read.
#
# WHY A CLOCK IN THE FUTURE IS A FAULT AND NOT A KINDNESS
#
# `age` used to be an unguarded subtraction, so run 31316144030 printed "only -3s
# old" and granted the grace. A serving_since AHEAD of now means the two clocks
# disagree, and a guard that reads a disagreement as "probably in flight" has
# chosen the comforting direction. A negative age is now its own printed fault
# and the missing row is accused, not excused.
#
# THE SILENCE NAMES ITSELF
#
# Every `UNREADABLE=1` site goes through reason(), which both warns and appends
# to a list the exit-2 sentence enumerates. It previously printed three counters
# for eight sites — all four graced runs above printed `0 sha(s) unreadable, 0
# run(s) with no job list, 0 row(s) with carried never measured` while exiting 2.
# The reason for the silence must be inside the sentence that announces it.
#
# AN EMPTY WINDOW ON A VERIFIED CROWN IS A DEFERRAL, NOT A PAGE (charter D597).
#
# The empty-population arm used to exit 2 unconditionally, and rc 2 pages. A
# repo that simply stops merging for a day empties the 24h window BY
# CONSTRUCTION, so the reconciler reds every 6 hours forever: measured
# 2026-08-15T18:28Z..08-17, SIX consecutive scheduled runs, every one "COULD
# NOT VERIFY: the population was EMPTY", #11217 at 41 comments. An alarm that
# pages on quiescence is the rc-4 lesson again — paging here is what mutes the
# alarm for the one case that is not.
#
# So an empty window may read GREEN — as a NAMED deferral (QUIET WINDOW), with
# its own ::warning, never as RECONCILED — and ONLY when ALL THREE hold:
#
#   (1) the serving-sha check RAN and VERIFIED that the sha the box is serving
#       has its cp row — production runs a commit the record knows;
#   (2) the re-ask list was PRESENT-EMPTY — read, and affirmatively owing
#       nothing. A graced deferral still owed a row must NOT go green, and a
#       list that is ABSENT or unread proves nothing;
#   (3) ZERO ledger rows sit inside the window. Rows-exist-but-no-runs STAYS
#       rc 2: a row with no run is an accusation source, not quiescence.
#
# Any OTHER silence still outranks quiescence: the only reason() the arm
# tolerates is the reverse direction's own no-alibi refusal, which an empty
# window fires by construction — and that refusal line is printed INSIDE the
# deferral text, because quiescence-green must not imply the reverse direction
# was checked.
#
# STATED RESIDUAL, not code: a repo quiet for 60 days trips GitHub's
# scheduled-workflow auto-disable, and a quiescence-green run produces no
# failure heartbeat that would notice the schedule going dark.
#
# EXIT CODES  0 = reconciled — every delivering run has its row, every row has its
#                 run, and the serving sha is recorded. ALSO 0: a QUIET WINDOW —
#                 zero delivering runs, zero in-window rows, serving sha verified
#                 recorded, re-ask list PRESENT-EMPTY — announced as a named
#                 deferral with its own ::warning, never as RECONCILED
#             1 = BEHIND or WRONG (or SERVING-UNRECORDED, or GRACED-UNRECORDED
#                 — a sha an earlier run graced and nothing ever recorded), WITH
#                 COUNTS
#             2 = could not read, or the population was empty (including a window
#                 whose every delivering run PREDATES the recorder) — a WARNING
#                 that is never counted clean. A rate with no denominator is
#                 refused. An empty population escapes to the QUIET WINDOW
#                 deferral (rc 0) ONLY under the three conditions above;
#                 anything short of all three stays here.
#                 An ABSENT re-ask list is one of these conditions: a memory
#                 that was destroyed cannot re-ask, so it is a named silence.
#                 A DECLARED first run (CROWN_STATE_FIRST_RUN=1) is not.
#             3 = CONFIGURATION fault only (no jq/gh, no credential, bad flag,
#                 or CROWN_API_TOKEN set but EMPTY — a reader asked for and not
#                 supplied. UNSET is not a fault: it falls through to SSH.)
#             4 = NOT YET DUE. Everything that could be read reconciled, nothing
#                 is accused, and a DEFERRAL is open — today that is the serving
#                 grace, whose accusation the next run collects. It is a
#                 ::warning, not a page, and it is NOT a green either: the
#                 sentence names every deferral that fired. rc 2 outranks it, so
#                 a deferral never launders a silence.
#
# USAGE
#   scripts/crown-reconcile.sh --repo FRIKKern/barkpark
#   scripts/crown-reconcile.sh --window-hours 6
#   scripts/crown-reconcile.sh --state-file /var/lib/crown/graced.txt
#   scripts/crown-reconcile.sh --runs-fixture r.json --jobs-fixture j.json \
#       --crown-fixture c.json --health-fixture h.json --now 2026-08-09T12:00:00Z
#   … --commits-fixture m.json   # [{sha, files:[…]}] — the DEAD-TRIGGER check
#
# The fixture flags make every classification hermetically provable; see
# scripts/crown-reconcile.test.sh, which breaks the comparison five ways and
# requires a red for each.
#
# TRANSPORT: no JSON payload is ever handed to jq as an argv word. Linux caps a
# single argv string at 131,072 bytes independently of ARG_MAX and a run listing
# crosses it. Every list travels by `--slurpfile` or stdin (charter D486).
#
# THE TWO SIDES ARE SAMPLED APART IN TIME, SO THEY NEEDED A WATERMARK
# (task-7a85d1b5f471af8f).
#
# This verdict compares TWO SNAPSHOTS OF TWO DIFFERENT SYSTEMS, and it used to
# compare them as if they were simultaneous. They never are:
#
#   T0  fetch_runs() takes ONE page of deploy.yml runs.
#   ..  run_delivers() asks the jobs API once per examined run — 65 runs on a
#       live window, so this leg alone is minutes, not seconds.
#   T1  crown_read() takes the row page.
#
# A row written between T0 and T1 names a `delivering_run_id` that was NOT YET
# TERMINAL when the run list was taken — the run was mid-flight, or had not been
# created at all — so it structurally CANNOT be in a delivering set built from the
# page's COMPLETED runs. The row is fine, the run is fine, and the verdict
# called it WRONG. The reconciler was accusing its own concurrent writers.
#
# MEASURED TWICE, ON TWO DIFFERENT AXES:
#
#   * run 31339252774 (main 45e2611552): deploy run 31339172372 ran 22:21:09 to
#     22:24:42; this script snapshotted its run list at 22:23:04 WHILE that
#     deploy was in progress; the row was written 22:24:39 naming that run; the
#     verdict concluded 22:25:21 `wrong=1/100`. The two sides were ~95s apart.
#   * run 32726853411 (main 4d35c5ab08): `behind=0/65` — NOT ONE delivering run
#     was missing a row, so nothing was lost — while `wrong=2/100` named the
#     SAME sha twice, delivered by runs 32726835915 and 32726853417, both
#     numerically ADJACENT to the reconciler's own run id. Two runs that started
#     alongside this one, and the window closed before their rows existed.
#
# A TOLERANCE WAS THE WRONG FIX, AND IS REFUSED. Gracing "recent" rows, or
# widening the wide window, hides a torn read AND the real corruption that wears
# the same output. The comparison is made CONSISTENT instead, by taking a
# WATERMARK — the state of the run list at the instant it was sampled — and
# judging a row only if its writer was already TERMINAL at that instant:
#
#   RUNLIST_EPOCH   the wall clock the instant fetch_runs() returned.
#   NONTERMINAL     every run id on that page whose `status != "completed"`.
#                   Read from the page, not inferred: we SAW these running.
#   MAX_RUN_ID      the largest deploy.yml run id on the page. Actions run ids
#                   are allocated in creation order, so an id above this one did
#                   not exist when we looked. This handle is CLOCK-FREE.
#
# A row is WRITTEN-IN-FLIGHT — excluded from BOTH sides, printed in its own
# class with its own count, exactly like PREDATES-WRITER — when either holds:
#
#   (i)  run-keyed, and clock-free: its `delivering_run_id` is on the page with
#        a non-terminal status. No clock is consulted; the page says the run was
#        still running. This alone is sufficient.
#   (ii) time-keyed, and therefore CORROBORATED: the row's own `first_seen_at`
#        is at or after RUNLIST_EPOCH (less SERVING_SKEW_EPSILON_SECONDS, the
#        same measured host-jitter epsilon the serving arm uses) AND the row
#        either names no run at all or names a run id ABOVE MAX_RUN_ID. Time
#        alone is never enough — a clock disagreement must not excuse a row.
#
# THE OTHER SIDE IS ALREADY CONSISTENT, and it is stated rather than assumed: a
# non-terminal run is excluded from the delivering set by the `.conclusion ==
# "success"` filter that builds it, from the same page, at the same instant. So
# the exclusion is symmetric by construction. BEHIND is torn in the SAFE
# direction and stays as it is: it reads the crown FRESH, per sha, AFTER the run
# list, so its rows can only be MORE complete than the snapshot — a run whose
# row lands during the gap is found, not accused.
#
# THIS IS A DEFERRAL AND IT LEAVES NO DEBT BEHIND ON PURPOSE (contrast D511).
# The serving grace needs a persistent re-ask list because it reads only what
# the box serves RIGHT NOW, so a deferred accusation becomes unmakeable the
# moment the box moves on. This one does not: the row is still in the crown, and
# on the next run — six hours later, or the next push — the run is terminal and
# is judged NORMALLY. A run that was cancelled, or failed, or never delivered,
# is then on the page as `completed` with a non-success conclusion, is not in
# the delivering set, and its row is WRONG. Excluding it here costs ONE run of
# latency and forgives nothing. Putting it on the re-ask list would be worse
# than useless: that list is keyed on "a sha with NO row", and this row EXISTS —
# it would retire clean on its first re-ask and launder the accusation.
#
# A HUNG RUN IS NOT AN ALIBI, AND THE EXCLUSION IS CAPPED (dr-w34, restated).
#
# Arm (i) defers for as long as GitHub reports the run non-terminal, and that is
# exactly the unbounded shape the SERVING arm was already caught in
# (dr-w34-fu-inflight-deferral-is-unbounded). So it carries the SAME cap, the
# same measured constant, charged the same way: SERVING_INFLIGHT_CAP_SECONDS,
# derived from the observed maximum deploy duration and not from a feeling. A
# row whose writing run has been non-terminal for longer than that is ACCUSED —
# printed as WRITTEN-IN-FLIGHT-EXPIRED beside the WRONG that follows it, naming
# the hung run — rather than deferred a third and fourth time.
#
# Arm (ii) needs no cap and it is worth saying why rather than leaving it to
# look like an oversight: it only fires on a row written at or after the
# watermark, so the row it excuses is at most one run's own duration old, by
# construction. There is no window there to grow.
#
# TRUNCATION CANNOT BE ALLOWED TO MANUFACTURE A GHOST (task-7a85d1b5f471af8f).
#
# The run page is ONE page of 100 and it is regularly truncated — the live run
# above printed "the 100-run page filled without reaching the window start". A
# truncated page produces false verdicts in BOTH directions, and only one of
# them was expressible before:
#
#   * FALSE RED: a row whose delivering run fell off the BOTTOM of the page has
#     no alibi source, and read WRONG. That is not a ghost, it is a run we could
#     not see. A row naming a run id BELOW the page's minimum, on a page that is
#     known truncated, is now an UNREADABLE condition by name (rc 2, which still
#     pages) instead of an accusation — "could not judge" is the true statement.
#   * FALSE CLEAN: a genuinely BEHIND run that fell off the page is never
#     examined at all, so it cannot be counted. The population already prints as
#     `N+` for exactly this reason; the residual is now SAID beside it rather
#     than left for a reader to infer from a plus sign.
#
# THE RUN LISTING PAGES TO THE WINDOW START (task-300fe0d74442acf3).
#
# Both of the above were mitigations for a truncation that was never necessary.
# `per_page=100` with no `page=` was ONE page read as if it were the 24h window,
# and it was short on 7 of 24 active days in the 30-day sample (2026-09-02: 246
# runs). fetch_runs now pages — newest-first, stopping at the first short page or
# at the first page reaching back past the WIDE cutoff, capped at RUNS_PAGE_CAP
# pages — so the ordinary busy day is a COUNT and the two mitigations above fire
# only when the cap or a dead page really did cut the listing short. The cost is
# one extra request on a day with more than 100 runs.
#
# THE POPULATION NAMES CANCELLED RUNS IN BOTH DIRECTIONS. `run_delivers` does not
# consult a run's own conclusion, which is correct — a run whose only failing leg
# is the other one still put code on a box — but it left cancelled runs counted
# ANONYMOUSLY under a parenthetical that says "a docs-only merge skips both".
# CANCELLED_NONDELIVERING (a superseded push) and CANCELLED_DELIVERING (delivered
# and then cancelled, so the record-delivery job died with it) are now printed by
# name off the conclusion already on the page.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REPO="${GITHUB_REPOSITORY:-FRIKKern/barkpark}"
WINDOW_HOURS=24
# The reverse direction reads a bounded page of the newest rows. The route clamps
# `limit` itself; this is the ask, not a promise about what comes back.
ROW_LIMIT=100
# Runs are fetched over a WIDER window than they are examined over, so a row whose
# delivering run was created just before the window start is not mis-called WRONG.
GRACE_HOURS=6
# A serving sha whose process started less than this many seconds ago may simply
# be a deploy still in flight whose recorder has not posted yet. Younger than this
# is a WARNING; older is a RED.
SERVING_GRACE_SECONDS=1200
# How far a serving_since may sit AHEAD of now before the disagreement is called
# a clock fault rather than inter-host jitter. DERIVED FROM TWO LIVE MEASUREMENTS,
# not felt: run 31332764821 reported 3s ahead on an NTP-healthy plane (ordinary
# jitter between the box and the runner, and it will recur), and run 31334953628
# reported 54s ahead because a deploy was genuinely IN FLIGHT. So the value must
# EXCEED 3 and must never REACH 54 — the 54s shape belongs to the in-flight arm
# below, which names the running run, not to a widened epsilon that would swallow
# it silently. scripts/crown-reconcile.test.sh reads this constant back out and
# asserts the BAND 4 <= EPS < 54, so a later widening reds.
SERVING_SKEW_EPSILON_SECONDS=15
# How long an `in_progress` deploy.yml run for the served sha may keep DEFERRING
# the missing-row accusation (charged against the sha's FIRST-SEEN instant, like
# the grace above). Without a cap the in-flight arm re-defers for as long as
# GitHub reports the run in_progress, so a HUNG run bought amnesty bounded only
# by GitHub's own ~6h default job timeout — a bound this script never stated
# (dr-w34-fu-inflight-deferral-is-unbounded). MEASURED, not felt: across the 50
# most recent successful deploy.yml runs (runs API, read 2026-08-23), duration
# was median 501s, p90 1175s, max 6495s. The cap must EXCEED that observed max —
# a slow-but-real deploy is this arm's whole purpose — and fall far below the
# ~21600s a hung job may sit in_progress by default. 10800s is ~1.66x the
# observed maximum. Past it, the run stops being an alibi: the sha is accused
# (SERVING-INFLIGHT-EXPIRED + SERVING-UNRECORDED, exit 1), naming the hung run.
SERVING_INFLIGHT_CAP_SECONDS=10800
# How long a graced sha stays on the RE-ASK LIST. It is accused on every run in
# between, so this bounds the LIST, not the accusation. See the boundary above.
REASK_MAX_SECONDS=86400
# The re-ask list itself. It MUST outlive the run — $WORK is deleted by the
# cleanup trap — so it defaults outside the working directory and the caller is
# expected to point it somewhere that persists between runs.
STATE_FILE="${CROWN_STATE_FILE:-${TMPDIR:-/tmp}/crown-reconcile-graced.txt}"
# WHERE that path is supposed to persist, in words, for the printed line. The
# caller knows this and the script cannot: a path under $RUNNER_TEMP is a
# destroyed VM unless something ships it off the box. Unset, it is derived
# below, and a path that lives in a temp directory says so rather than implying
# a memory it does not have.
STATE_STORAGE="${CROWN_STATE_STORAGE:-}"
# The CALLER's statement that the persistent store has never held a list. Only a
# caller that actually reached the store may say this — the workflow sets it from
# a remote existence test that SUCCEEDED, and leaves it unset when the fetch
# failed, so transport silence keeps landing in ABSENT. Any value other than the
# literal 1 is read as "not claimed": a typo must not become a first run.
STATE_FIRST_RUN="${CROWN_STATE_FIRST_RUN:-}"
# The instant `record-delivery` first existed: PR #11167, merge commit 67f4a6ab2.
# Re-derivable by hand, which is why the commit is named beside it:
#   TZ=UTC git show -s --format='%H %cd %s' --date=iso-strict 67f4a6ab2
# A delivering run created before this could not have been recorded by anything.
RECORDER_BIRTH_ISO="2026-08-09T09:39:44Z"
RECORDER_BIRTH_PR="#11167"
RECORDER_BIRTH_COMMIT="67f4a6ab2"
API_BASE="${CROWN_API_BASE:-https://api.barkpark.cloud}"
HEALTH_URL="${CROWN_HEALTH_URL:-https://barkpark.cloud/health}"

RUNS_FIXTURE=""
JOBS_FIXTURE=""
CROWN_FIXTURE=""
HEALTH_FIXTURE=""
COMMITS_FIXTURE=""
NOW_OVERRIDE=""
# THE GAP BETWEEN THE TWO SAMPLES, PINNED — FIXTURES ONLY, AND REFUSED LIVE.
# The whole defect is that the run list and the crown are read at different
# instants, so a harness has to be able to WIDEN that gap on demand: `--now` is
# the crown-read instant, and this is the run-list instant. It is a TEST handle
# and nothing else — accepting it on a live run would hand an operator a dial
# that excuses rows by hand, which is the tolerance this fix exists to refuse.
# Live runs always take the watermark from the real clock, at the real instant.
RUNLIST_AT_OVERRIDE=""

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t crown-reconcile)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

say() { echo "$*"; }
warn() { echo "$*" >&2; }

usage() { sed -n '1,/^set -uo pipefail$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --window-hours) WINDOW_HOURS="${2:-}"; shift 2 ;;
    --grace-hours) GRACE_HOURS="${2:-}"; shift 2 ;;
    --limit) ROW_LIMIT="${2:-}"; shift 2 ;;
    --runs-fixture) RUNS_FIXTURE="${2:-}"; shift 2 ;;
    --jobs-fixture) JOBS_FIXTURE="${2:-}"; shift 2 ;;
    --crown-fixture) CROWN_FIXTURE="${2:-}"; shift 2 ;;
    --health-fixture) HEALTH_FIXTURE="${2:-}"; shift 2 ;;
    --commits-fixture) COMMITS_FIXTURE="${2:-}"; shift 2 ;;
    --now) NOW_OVERRIDE="${2:-}"; shift 2 ;;
    --runlist-at) RUNLIST_AT_OVERRIDE="${2:-}"; shift 2 ;;
    --state-file) STATE_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) warn "unknown flag: $1"; exit 3 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { warn "CONFIG: jq is required"; exit 3; }

case "$WINDOW_HOURS" in ''|*[!0-9]*) warn "CONFIG: --window-hours must be a whole number of hours, got '$WINDOW_HOURS'"; exit 3 ;; esac
case "$GRACE_HOURS" in ''|*[!0-9]*) warn "CONFIG: --grace-hours must be a whole number of hours, got '$GRACE_HOURS'"; exit 3 ;; esac
case "$ROW_LIMIT" in ''|*[!0-9]*) warn "CONFIG: --limit must be a whole number, got '$ROW_LIMIT'"; exit 3 ;; esac

FIXTURE_MODE=0
[ -n "$RUNS_FIXTURE" ] && FIXTURE_MODE=1

if [ -n "$RUNLIST_AT_OVERRIDE" ] && [ "$FIXTURE_MODE" != "1" ]; then
  warn "CONFIG: --runlist-at is a FIXTURE-ONLY handle for widening the gap between the run-list sample and the crown sample. A live run takes its watermark from the real clock at the real instant, and must not be handed one; pinning it by hand would be a tolerance, not a consistent read."
  exit 3
fi

# ── clocks ───────────────────────────────────────────────────────────────────
epoch_of() { # <iso8601> -> seconds, or empty
  local iso="$1" plain
  [ -n "$iso" ] || return 1
  # ISO-8601 ONLY, shape-checked BEFORE date(1) sees it. GNU date -d also
  # accepts a relative grammar — `yesterday`, `now`, `2 hours ago` — so on a
  # Linux runner `--now yesterday` PARSED and silently shifted the whole
  # comparison window by a day, while BSD date on a mac refused it. The verdict
  # must not depend on which date(1) the runner has, and a window this script
  # cannot state is a window it must refuse.
  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ;;
    *) return 1 ;;
  esac
  date -u -d "$iso" +%s 2>/dev/null && return 0
  # BSD/macOS date, where the harness usually runs. Fractional seconds and the
  # trailing Z are stripped first; `%%.*` alone would mangle an instant that has
  # no fraction into `...ZZ`.
  plain="${iso%Z}"
  plain="${plain%%.*}"
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "$plain" +%s 2>/dev/null && return 0
  return 1
}

if [ -n "$NOW_OVERRIDE" ]; then
  NOW_EPOCH="$(epoch_of "$NOW_OVERRIDE")" || { warn "CONFIG: --now is not an ISO-8601 instant: $NOW_OVERRIDE"; exit 3; }
else
  NOW_EPOCH="$(date -u +%s)"
fi
RECORDER_BIRTH_EPOCH="$(epoch_of "$RECORDER_BIRTH_ISO")" || { warn "CONFIG: RECORDER_BIRTH_ISO is not an ISO-8601 instant: $RECORDER_BIRTH_ISO"; exit 3; }
CUTOFF_EPOCH=$((NOW_EPOCH - WINDOW_HOURS * 3600))
WIDE_EPOCH=$((CUTOFF_EPOCH - GRACE_HOURS * 3600))
iso_of() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }
CUTOFF_ISO="$(iso_of "$CUTOFF_EPOCH")"
NOW_ISO="$(iso_of "$NOW_EPOCH")"

# ── THE DATED, SELF-EXPIRING WAIVER FOR ONE SHA ──────────────────────────────
#
# WHY IT EXISTS. PR #16471 closed a crown-recorder gap: rows_for's half-open
# range could drop a delivered sha PERMANENTLY once the next deploy's `prev`
# moved past it. That fix is FORWARD-ONLY — it stops the NEXT drop and cannot
# manufacture the row that was already lost — so exactly ONE pre-fix specimen
# survives it: 28f8e109c58c285f3fd60d6645b4df20467c05e6, graced 2026-09-06
# 08:32:19Z and never recorded. Every crown-reconcile run on main since the
# merge has fired GRACED-UNRECORDED on that one sha and nothing else.
#
# WHO OWNS THE REAL REMEDY. Not this file. The honest fix is a backfill POST to
# /v1/internal/platform-deliveries, which needs a live WORKER_TOKEN and a write
# to the control-plane box — both owner-only by standing rule. It is queued with
# the owner as task-9c8fccd9e8a77773. This waiver buys the hours until then; it
# does not settle the debt, and it is not a licence to skip it.
#
# WHAT HAPPENS AT EXPIRY. Nothing has to happen. Past WAIVER_EXPIRES_ISO the
# predicate below is false and the sha is accused again exactly as it is today —
# no config change, no cleanup PR, no allowlist that quietly outlives its excuse.
# The instant is pinned to the sha's own 86400s REASK_MAX_SECONDS retirement
# (first seen 08:32:19Z 2026-09-06, so it ages off the re-ask list ~08:32:19Z
# 2026-09-07): the waiver CANNOT outlive the condition it excuses, because the
# condition retires within seconds of it.
#
# IT IS LOUD. A waived sha still prints — by sha, with its expiry and the seconds
# left — so nobody reads a silent green.
WAIVED_SHA="28f8e109c58c285f3fd60d6645b4df20467c05e6"
WAIVER_EXPIRES_ISO="2026-09-07T08:32:00Z"
# THE PLATFORM TRAP THIS PARSE IS GUARDED AGAINST. `date -u -d ""` returns rc 1
# on BSD/macOS and rc 0 WITH TODAY'S MIDNIGHT on GNU/Linux, and GNU also accepts
# a relative grammar ("next year", "+1 day") that BSD refuses outright. A
# malformed constant here would therefore be INERT on a mac and a real — possibly
# far-future — instant on the CI runner: the difference between "expired" and
# "waived forever", decided by which date(1) the machine happens to have. So the
# literal is SHAPE-CHECKED before any date(1) sees it, at the STRICTER contract
# (exactly YYYY-MM-DDTHH:MM:SSZ — no fraction, no offset, no relative grammar),
# and anything that fails the shape, fails the parse, or lands non-numeric leaves
# the expiry at 0, which makes the waiver INERT on every platform. It fails
# CLOSED: the accusation is the default, and the waiver is what must be earned.
case "$WAIVER_EXPIRES_ISO" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
    WAIVER_EXPIRES_EPOCH="$(epoch_of "$WAIVER_EXPIRES_ISO" 2>/dev/null || true)" ;;
  *)
    WAIVER_EXPIRES_EPOCH="" ;;
esac
case "$WAIVER_EXPIRES_EPOCH" in
  ''|*[!0-9]*) WAIVER_EXPIRES_EPOCH=0 ;;
esac
if [ "$WAIVER_EXPIRES_EPOCH" = "0" ]; then
  warn "WAIVER INERT: the dated waiver's expiry constant ($WAIVER_EXPIRES_ISO) is not an unambiguous UTC instant, so nothing is waived and $WAIVED_SHA is judged normally."
fi
# TRUE only for that ONE sha, and only before that ONE instant. String equality,
# never a prefix or a pattern: it can suppress nothing else, and no sha it was
# not written for can inherit its silence.
waived_now() { # <sha> -> 0 if this exact sha is waived AND the waiver is still live
  [ "$1" = "$WAIVED_SHA" ] || return 1
  [ "$WAIVER_EXPIRES_EPOCH" -gt 0 ] || return 1
  [ "$NOW_EPOCH" -lt "$WAIVER_EXPIRES_EPOCH" ] || return 1
  return 0
}

# ── the named silences ───────────────────────────────────────────────────────
# The ONLY way UNREADABLE is set. A condition that mutes part of the comparison
# has to say which one it was, in the exit-2 sentence itself and not only in a
# warning a reader may never scroll back to.
UNREADABLE=0
REASONS_FILE=""
reason() { # <sentence>
  UNREADABLE=1
  warn "  $*"
  [ -n "$REASONS_FILE" ] && printf '%s\n' "$*" >> "$REASONS_FILE"
  return 0
}

# ── the named deferrals ──────────────────────────────────────────────────────
# A DEFERRAL is not a silence. It says "the comparison ran, it found nothing to
# accuse YET, and the accusation is owed to a LATER run" — which is only honest
# because the debt is written to the re-ask list before this process exits. It
# is counted and named exactly like a reason(), and deliberately does NOT touch
# UNREADABLE: folding it into the silence is what made the crown alarm wrong
# five times in six and one code away from being muted.
DEFERRED=0
DEFERRALS_FILE=""
defer() { # <sentence>
  DEFERRED=$((DEFERRED + 1))
  warn "  $*"
  [ -n "$DEFERRALS_FILE" ] && printf '%s\n' "$*" >> "$DEFERRALS_FILE"
  return 0
}

# ── the re-ask list ──────────────────────────────────────────────────────────
# Line format: `<sha> <first-seen-epoch>`, one per line, `#` comments ignored.
# Deliberately NOT json: this file is written and read by this script alone, and
# a line-oriented format needs no jq at all, so no payload can reach an argv word
# (charter D486).

# Where the list is SUPPOSED to persist, in words. Derived only when the caller
# did not say, and a temp path is named as the hole it is rather than passed off
# as a memory.
state_storage() {
  if [ -n "$STATE_STORAGE" ]; then printf '%s' "$STATE_STORAGE"; return 0; fi
  [ -n "$STATE_FILE" ] || { printf 'nowhere'; return 0; }
  case "$STATE_FILE" in
    /tmp/*|/var/tmp/*|/private/tmp/*|"${TMPDIR:-/nonexistent-tmpdir}"*)
      printf 'a temp directory — this does NOT survive a run boundary' ;;
    *) printf 'a local path; set CROWN_STATE_STORAGE to say where it persists' ;;
  esac
}

STATE_LOADED=0
STATE_DROPPED=0
STATE_STATE=""
state_load() { # -> $WORK/reask.txt, and ONE printed line, always
  : > "$WORK/reask.txt"
  local sha ts
  STATE_LOADED=0
  STATE_DROPPED=0
  if [ -z "$STATE_FILE" ]; then
    STATE_STATE="UNCONFIGURED"
    reason "no re-ask list path was configured — a grace granted now cannot be re-asked on the next run"
  elif [ ! -f "$STATE_FILE" ] && [ "$STATE_FIRST_RUN" = "1" ]; then
    # The caller reached the persistent store and found no list there. There is
    # no memory to have lost, so there is no grace an earlier run could have
    # granted, so there is nothing to re-ask — and pretending otherwise pages a
    # human about a file that has never existed. NOT a fault, and it still says
    # exactly what it is rather than passing for PRESENT-EMPTY, which would be a
    # claim about a file that was read.
    STATE_STATE="ABSENT-FIRST-RUN"
  elif [ ! -f "$STATE_FILE" ]; then
    # NOT silence, and NOT clean. state_save writes its header unconditionally,
    # so after any run that reached the save the file EXISTS even holding zero
    # entries. Absent WITHOUT the caller's first-run statement therefore means
    # the memory was destroyed between runs — or the transport that would have
    # carried it failed, which is the same loss — and neither can re-ask a grace
    # an earlier run granted.
    STATE_STATE="ABSENT"
    reason "the re-ask list at $STATE_FILE does not exist and the caller did NOT state that the persistent store is empty (CROWN_STATE_FIRST_RUN=1) — the memory was destroyed between runs or the fetch that would have carried it failed, and a grace granted on a previous run cannot be re-asked. NOT counted clean."
  else
    while read -r sha ts _; do
      case "$sha" in ''|'#'*) continue ;; esac
      case "$sha" in *[!0-9a-fA-F]*) STATE_DROPPED=$((STATE_DROPPED + 1)); reason "a re-ask list line did not start with a sha and was dropped: '$sha'"; continue ;; esac
      case "${ts:-}" in ''|*[!0-9]*) STATE_DROPPED=$((STATE_DROPPED + 1)); reason "the re-ask entry for $sha carries no first-seen instant and was dropped"; continue ;; esac
      STATE_LOADED=$((STATE_LOADED + 1))
      printf '%s %s\n' "$sha" "$ts" >> "$WORK/reask.txt"
    done < "$STATE_FILE"
    if [ "$STATE_LOADED" -eq 0 ]; then
      # An affirmative statement, not a fault: the file is there, it was read,
      # and it says nothing is owed.
      STATE_STATE="PRESENT-EMPTY"
    else
      STATE_STATE="PRESENT"
    fi
  fi
  say "RE-ASK LIST: ${STATE_FILE:-<none>} [$(state_storage)] — ${STATE_STATE}; loaded ${STATE_LOADED} entry(ies), dropped ${STATE_DROPPED} malformed line(s)."
  if [ "$STATE_STATE" = "ABSENT-FIRST-RUN" ]; then
    say "  the caller states the persistent store has never held a list, so there is no earlier grace to re-ask — this is a FIRST RUN, not a destroyed memory. A run that could not REACH the store leaves this unstated and is reported as ABSENT."
  fi
  return 0
}

state_first_seen() { # <sha> -> first-seen epoch, or empty
  awk -v s="$1" '$1 == s { print $2; exit }' "$WORK/reask.txt" 2>/dev/null
}

state_save() { # <file of "sha epoch" lines to keep>
  local kept
  kept="$(awk 'NF' "$1" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  if [ -z "$STATE_FILE" ]; then
    # state_load already said UNCONFIGURED and reason()'d it; the symmetric line
    # still prints, because "wrote M, then loaded 0" is the eviction signature
    # and it only reads if BOTH halves are always there.
    say "RE-ASK LIST: wrote 0 entry(ies) to <none> — no path was configured, so ${kept} entry(ies) were DISCARDED."
    return 0
  fi
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
  # WRITE-THEN-MOVE, never a truncating redirect. `> "$STATE_FILE"` truncates
  # BEFORE the first byte is written, so a process killed mid-write leaves a
  # SHORT list — and a short list is indistinguishable from a list that legitimately
  # drained, which is precisely the accusation-losing shape this file exists to
  # prevent. The rename is atomic on the same filesystem, so a reader sees either
  # the whole old list or the whole new one.
  if {
    printf '# crown-reconcile re-ask list — "<sha> <first-seen-epoch>". Written %s.\n' "$NOW_ISO"
    sort -u "$1"
  } > "$STATE_FILE.tmp.$$" 2>/dev/null && mv -f "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null; then
    say "RE-ASK LIST: wrote ${kept} entry(ies) to $STATE_FILE [$(state_storage)]."
  else
    rm -f "$STATE_FILE.tmp.$$" 2>/dev/null
    reason "the re-ask list could not be written to $STATE_FILE — a grace granted now will not be re-asked"
    say "RE-ASK LIST: FAILED to write ${kept} entry(ies) to $STATE_FILE [$(state_storage)]."
  fi
  return 0
}

# ── the two readers ──────────────────────────────────────────────────────────
READER=""
SSH=""
# WHICH reader actually produced rows, counted per read. The transport is known
# before the first read; the reader is not — but since #14979 there is exactly
# ONE reader behind each transport, so a read that the route refuses has no
# substitute and is counted as a REFUSAL, never as a different reader.
READS_ROUTE=0
READS_FIXTURE=0
READS_FAILED=0
READS_REFUSED=0
REFUSED_HTTP=""
select_reader() {
  if [ "$FIXTURE_MODE" = "1" ]; then
    READER="fixture"
    return 0
  fi
  # SET BUT EMPTY is not the same statement as UNSET. Unset means "I did not ask
  # for the PAT reader" and falls through to the SSH reader below — the path CI
  # actually runs, which must keep working. Empty means "I asked for the PAT
  # reader and handed it nothing", and silently answering that with a different
  # reader is the downgrade this guard exists to refuse.
  if [ "${CROWN_API_TOKEN+set}" = "set" ] && [ -z "${CROWN_API_TOKEN}" ]; then
    warn "CONFIG: CROWN_API_TOKEN is SET BUT EMPTY. A reader that was explicitly asked for and is not there is a configuration fault, not a silent downgrade to the CP_HOST + DEPLOY_SSH_KEY reader. UNSET it to choose the SSH reader deliberately, or give it a read-ability PAT."
    return 3
  fi
  if [ -n "${CROWN_API_TOKEN:-}" ]; then
    READER="pat"
    return 0
  fi
  if [ -n "${CP_HOST:-}" ] && [ -n "${DEPLOY_SSH_KEY:-}" ]; then
    install -m 600 /dev/null "$WORK/key" 2>/dev/null || { warn "CONFIG: could not stage the deploy key"; return 3; }
    printf '%s\n' "$DEPLOY_SSH_KEY" > "$WORK/key"
    SSH="ssh -i $WORK/key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$WORK/known -o ConnectTimeout=20"
    READER="ssh"
    return 0
  fi
  warn "CONFIG: no way to read the crown. Set CROWN_API_TOKEN (a read-ability PAT), or CP_HOST + DEPLOY_SSH_KEY for the on-box read deploy.yml already uses."
  return 3
}

# The remote read, written once and shipped over stdin so nothing is interpolated
# into a remote shell string. Emits a single line: CR_BODY=<json envelope>.
write_remote_reader() {
  cat > "$WORK/remote.sh" <<'REMOTE'
set -u
QS="$1"
# THE CONTAINER IS FOUND BY A STABLE IDENTITY, NEVER BY THE IMAGE TAG.
# This used to be `docker ps -q --filter ancestor=cloud-control_plane:latest`.
# That filter matches by IMAGE, and `latest` is the one thing about the control
# plane that MOVES: deploy/cp-deploy.sh:133 retags the serving image to
# `cloud-control_plane:rollback`, `docker compose build` (cp-deploy.sh:452) then
# points `latest` at the NEW image, and only after the health gate does the new
# slot boot (cp-deploy.sh:470). For that whole window the OLD container is still
# the one serving and `ancestor=...:latest` matches NOTHING — the read comes back
# empty and the reconciler, correctly, refuses to call it a green. Three rc-2
# SILENCE runs on 2026-09-06 (34048569972, 34050639617, 34049400499) are exactly
# that window. The reconciler was right; the KEY was wrong.
#
# The stable identity is the CONTAINER NAME PREFIX, which compose derives from
# the project name plus the service name and which no image rebuild touches:
# cloud/docker-compose.yml:196,202 define the services `control_plane_blue` and
# `control_plane_green`, and deploy/cp-deploy.sh:286 builds the very same string
# itself — `"${COMPOSE_PROJECT_NAME:-cloud}-control_plane_${ACTIVE_SLOT}-1"`.
# Matching the SLOT-LESS prefix is what makes this immune to the blue/green
# rename the old comment in deploy.yml warned about: both slots match, and the
# reader wants either — any live control plane carries the same WORKER_TOKEN,
# and the token is all this read needs before it talks to the public route.
#
# AND IT RETRIES, BOUNDED AND OUT LOUD. Even the right key sees nothing in the
# instant between the old slot stopping and the new one being up. The retry is
# capped, every attempt is printed as CR_CP_RETRY=<n>/<max>, and the total is
# printed as CR_CP_ATTEMPTS=<n> so the caller can say how hard it looked. It is
# NOT a way to turn an absence into a pass: after the last attempt an absent
# container is still CR_ERROR=no_control_plane_container and the run still exits
# 2 SILENCE. Fail-closed is the invariant; the retry only removes the FALSE
# absences.
CP_PROJECT="${COMPOSE_PROJECT_NAME:-cloud}"
CP_NAME_FILTER="${CP_PROJECT}-control_plane_"
CP_ATTEMPTS="${CR_CP_ATTEMPTS:-6}"
CP_DELAY="${CR_CP_DELAY:-5}"
CID=""
WT=""
CP_SEEN=0
CP_TRIES=0
while [ "$CP_TRIES" -lt "$CP_ATTEMPTS" ]; do
  CP_TRIES=$((CP_TRIES + 1))
  for c in $(docker ps -q --filter "name=$CP_NAME_FILTER" 2>/dev/null); do
    CP_SEEN=1
    t="$(docker exec "$c" printenv WORKER_TOKEN 2>/dev/null)"
    if [ -n "$t" ]; then CID="$c"; WT="$t"; break; fi
  done
  if [ -n "$CID" ]; then break; fi
  echo "CR_CP_RETRY=$CP_TRIES/$CP_ATTEMPTS"
  if [ "$CP_TRIES" -lt "$CP_ATTEMPTS" ]; then sleep "$CP_DELAY"; fi
done
echo "CR_CP_ATTEMPTS=$CP_TRIES"
if [ -z "$CID" ]; then
  # A container that was THERE but handed back no token is a different fault from
  # no container at all, and the two must not be merged: one is a swap window or
  # a dead box, the other is a mis-provisioned control plane.
  if [ "$CP_SEEN" = "1" ]; then echo "CR_ERROR=empty_worker_token"; else echo "CR_ERROR=no_control_plane_container"; fi
  exit 0
fi
CODE="$(curl -s -o /tmp/cr-body.json -w '%{http_code}' --max-time 30 -H "authorization: Bearer $WT" "https://barkpark.cloud/v1/deliveries?$QS")"
echo "CR_HTTP=$CODE"
if [ "$CODE" = "200" ]; then
  echo "CR_VIA=route"
  echo "CR_BODY=$(tr -d '\n' < /tmp/cr-body.json)"
  rm -f /tmp/cr-body.json
  exit 0
fi
rm -f /tmp/cr-body.json
# A 401/403 HERE IS THE VERDICT, NOT A DETOUR. GET /v1/deliveries takes
# `require_user_or_pat_or_worker` + `require_ability("read")` since PR #14979,
# and WORKER_TOKEN — the only credential deploy.yml's crown step carries, and the
# principal that WRITES these rows — is exactly what that tier admits. So a
# refusal is a REGRESSION of #14979. This used to answer it by reading
# `platform_deliveries` out of the control plane's postgres container, which
# always worked, always fired, and therefore turned a dead route into a `note:`
# behind a green. That branch is DELETED: the refusal is named and the read
# fails, so the next occurrence is a verdict.
if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
  echo "CR_ERROR=http_${CODE}_worker_principal"
  echo "CR_DETAIL=GET /v1/deliveries answered HTTP $CODE to the WORKER principal (WORKER_TOKEN) — the credential deploy.yml's crown step carries and the one that WRITES these rows. PR #14979 admitted that principal to this route, so this is a REGRESSION of that fix, not a tier mismatch, and there is no postgres detour left to hide it."
  exit 0
fi
echo "CR_ERROR=http_$CODE"
REMOTE
}

# crown_read <query-string> <out-file> -> 0 read / 2 could not read
crown_read() {
  local qs="$1" out="$2" body http via err det cpat
  case "$READER" in
    fixture)
      [ -f "$CROWN_FIXTURE" ] || { READS_FAILED=$((READS_FAILED + 1)); warn "  crown fixture is unreadable: ${CROWN_FIXTURE:-<none>}"; return 2; }
      jq 'if type == "array" then {deliveries: .} else error("not an array") end' "$CROWN_FIXTURE" > "$out" 2>/dev/null \
        || { READS_FAILED=$((READS_FAILED + 1)); warn "  crown fixture is not a JSON array of rows"; return 2; }
      READS_FIXTURE=$((READS_FIXTURE + 1))
      return 0
      ;;
    pat)
      http="$(curl -s -o "$WORK/body.json" -w '%{http_code}' --max-time 30 \
        -H "authorization: Bearer $CROWN_API_TOKEN" "$API_BASE/v1/deliveries?$qs")"
      if [ "$http" != "200" ]; then
        READS_FAILED=$((READS_FAILED + 1))
        warn "  the crown answered HTTP ${http:-<none>} for ?$qs"
        return 2
      fi
      cp "$WORK/body.json" "$out"
      READS_ROUTE=$((READS_ROUTE + 1))
      return 0
      ;;
    ssh)
      body="$($SSH "root@${CP_HOST}" "bash -s '$qs'" < "$WORK/remote.sh" 2>&1)"
      if [ $? -ne 0 ]; then
        READS_FAILED=$((READS_FAILED + 1))
        warn "  the control plane was not reachable over SSH for ?$qs"
        return 2
      fi
      via="$(printf '%s\n' "$body" | sed -n 's/^CR_VIA=//p')"
      http="$(printf '%s\n' "$body" | sed -n 's/^CR_HTTP=//p')"
      printf '%s\n' "$body" | sed -n 's/^CR_BODY=//p' > "$out"
      if [ ! -s "$out" ]; then
        READS_FAILED=$((READS_FAILED + 1))
        err="$(printf '%s\n' "$body" | sed -n 's/^CR_ERROR=//p')"
        det="$(printf '%s\n' "$body" | sed -n 's/^CR_DETAIL=//p')"
        # A REFUSAL IS ITS OWN NAMED CONDITION, not a generic unreadable. It goes
        # through reason() from HERE rather than from a call site, because two of
        # the four call sites do not name one, and a 401 that reaches the verdict
        # as an unnamed silence is the shape #14979 was filed against.
        case "${http:-}" in
          401|403)
            READS_REFUSED=$((READS_REFUSED + 1))
            REFUSED_HTTP="$http"
            reason "${det:-GET /v1/deliveries answered HTTP $http to the WORKER principal (WORKER_TOKEN) — PR #14979 admitted that principal to this route, so this is a REGRESSION of that fix, not a tier mismatch} [${err:-http_$http}, ?$qs]"
            ;;
          *)
            cpat="$(printf '%s\n' "$body" | sed -n 's/^CR_CP_ATTEMPTS=//p' | head -1)"
            warn "  the crown could not be read on the box for ?$qs: ${err:-<none>}${cpat:+ (the control-plane container was looked for $cpat time(s) before the absence was named)}"
            ;;
        esac
        return 2
      fi
      # THE ONLY READER BEHIND THIS TRANSPORT IS THE ROUTE. The postgres-container
      # detour is deleted, so a body that claims any other reader is a substitute
      # this script never asked for — refused, not counted as a read.
      if [ "$via" != "route" ]; then
        READS_FAILED=$((READS_FAILED + 1))
        reason "the crown read for ?$qs came back claiming reader '${via:-<none>}' (HTTP ${http:-<none>}) — since PR #14979 the WORKER principal reads GET /v1/deliveries directly and this script has NO substitute reader; a body from anything else is refused, not counted clean"
        return 2
      fi
      READS_ROUTE=$((READS_ROUTE + 1))
      return 0
      ;;
  esac
  return 2
}

# WHICH reader answered, as a field — printed on every path that reaches a
# verdict, and folded into the verdict sentence itself. The transport is in the
# header; this is the reader, and the two are not the same fact.
reader_answered() {
  local names=""
  [ "$READS_FIXTURE" -gt 0 ] && names="fixture"
  [ "$READS_ROUTE" -gt 0 ] && names="${names:+$names+}route"
  printf '%s' "${names:-none}"
}

say_reader() {
  local detail=""
  if [ "$READS_REFUSED" -gt 0 ]; then
    detail=" — the /v1/deliveries route answered HTTP ${REFUSED_HTTP:-<none>} to the WORKER principal (WORKER_TOKEN) on ${READS_REFUSED} read(s); PR #14979 admitted that principal, so this is a REGRESSION of that fix and NOTHING read those rows in its place"
  fi
  say "READER: transport=${READER:-<none>}, answered by $(reader_answered) (route=${READS_ROUTE}, fixture=${READS_FIXTURE}, unreadable=${READS_FAILED}, refused-401/403=${READS_REFUSED})${detail}"
}

# ── the runs ─────────────────────────────────────────────────────────────────
# ONE PAGE OF 100 WAS BEING READ AS "THE WINDOW". It is not. On 7 of 24 active
# days in the 30-day sample the deploy.yml run list on main exceeded 100 rows
# (2026-09-02: 246), and on those days every number below — POPULATION, and the
# BEHIND denominator that hangs off it — was a floor wearing a plus sign. The
# listing now PAGES until it has actually reached back past the window it is
# about, so on an ordinary day the population is a COUNT, and the floor language
# is reserved for the one case that really is one: the page cap was hit first.
RUNS_PAGE_CAP=12
# 1 when the listing reached the window start (a short page, or a page whose
# oldest run predates the wide cutoff); 0 when it stopped early and the numbers
# below are a floor. Set by fetch_runs, read by the FLOOR test.
RUNS_LIST_COMPLETE=1
RUNS_PAGES_READ=0
fetch_runs() { # -> writes $WORK/runs-raw.json, 0 ok / 2 could not read
  if [ "$FIXTURE_MODE" = "1" ]; then
    [ -f "$RUNS_FIXTURE" ] || { warn "  runs fixture is unreadable: $RUNS_FIXTURE"; return 2; }
    cp "$RUNS_FIXTURE" "$WORK/runs-raw.json"
    # A FIXTURE IS ONE FILE AND CANNOT PAGE, so it states for itself whether the
    # listing it stands for reached the window start: `"truncated": true` means
    # the pager gave up before it did. Without that key a fixture is the WHOLE
    # listing, however many rows it holds — which is exactly what pagination
    # buys, and is why a 101-row fixture is now a count and not a floor.
    RUNS_PAGES_READ=1
    if jq -e '.truncated == true' "$WORK/runs-raw.json" >/dev/null 2>&1; then
      RUNS_LIST_COMPLETE=0
    else
      RUNS_LIST_COMPLETE=1
    fi
    return 0
  fi
  command -v gh >/dev/null 2>&1 || { warn "CONFIG: gh is required to enumerate deploy.yml runs"; return 3; }
  # NO `&status=success` HERE, DELIBERATELY. A deploy that is STILL RUNNING is
  # the single most useful thing to know before accusing the sha it is putting
  # on the box, and `status=success` meant those bytes were never fetched at
  # all. The POPULATION is still bounded by construction: the jq that builds
  # .examined/.wide filters `.status == "completed"` itself, so a run that has not
  # finished is never examined and never reaches a jobs lookup.
  local page=1 rows oldest
  : > "$WORK/runs-pages.jsonl"
  RUNS_LIST_COMPLETE=0
  RUNS_PAGES_READ=0
  while [ "$page" -le "$RUNS_PAGE_CAP" ]; do
    if ! gh api "repos/$REPO/actions/workflows/deploy.yml/runs?branch=main&per_page=100&page=$page" \
      > "$WORK/runs-page.json" 2>"$WORK/runs-err.txt"; then
      # A FIRST page that does not answer is the old total failure. A LATER page
      # that does not answer is a SHORTER listing, not a missing one — it is
      # reported as the floor it is rather than thrown away.
      if [ "$page" = "1" ]; then
        warn "  could not list deploy.yml runs: $(head -1 "$WORK/runs-err.txt")"
        return 2
      fi
      warn "  page $page of the deploy.yml run list did not answer ($(head -1 "$WORK/runs-err.txt")) — the listing stops short of the window start and the population below is a FLOOR"
      break
    fi
    RUNS_PAGES_READ=$((RUNS_PAGES_READ + 1))
    rows="$(jq '.workflow_runs | length' "$WORK/runs-page.json" 2>/dev/null || echo 0)"
    case "${rows:-}" in ''|*[!0-9]*) rows=0 ;; esac
    jq -c '.workflow_runs[]?' "$WORK/runs-page.json" >> "$WORK/runs-pages.jsonl" 2>/dev/null
    # A short page IS the end of the list.
    if [ "$rows" -lt 100 ]; then RUNS_LIST_COMPLETE=1; break; fi
    # Runs come back newest-first, so once a page reaches back past the WIDE
    # cutoff — the widest instant any question below asks about — there is
    # nothing older left to want.
    oldest="$(jq -r '[.workflow_runs[] | .created_at | fromdateiso8601] | min // 0' "$WORK/runs-page.json" 2>/dev/null || echo 0)"
    case "${oldest:-}" in ''|*[!0-9]*) oldest=0 ;; esac
    if [ "$oldest" -le "$WIDE_EPOCH" ]; then RUNS_LIST_COMPLETE=1; break; fi
    page=$((page + 1))
  done
  jq -s '{workflow_runs: .}' "$WORK/runs-pages.jsonl" > "$WORK/runs-raw.json" 2>/dev/null
  if [ ! -s "$WORK/runs-raw.json" ]; then
    warn "  the deploy.yml run pages did not re-assemble into a runs payload"
    return 2
  fi
  return 0
}

# Is a deploy.yml run for this exact sha STILL RUNNING right now? Keyed on the
# SERVED sha and nothing else: "some deploy is busy" is not an alibi for the
# particular commit being accused. Answered out of the same run page every other
# question is answered from — no second request, no second credential — which is
# only possible because fetch_runs stopped asking the API for successes only.
serving_run_in_flight() { # <sha> -> prints the run id, 0 in flight / 1 not
  local sha="$1" id
  [ -s "$WORK/runs-raw.json" ] || return 1
  id="$(jq -r --arg sha "$sha" \
    'first(.workflow_runs[]? | select(.head_sha == $sha and .status == "in_progress") | .id | tostring) // empty' \
    "$WORK/runs-raw.json" 2>/dev/null)"
  [ -n "$id" ] || return 1
  printf '%s' "$id"
  return 0
}

# A run DELIVERS only when control-plane or instance concluded success — and the
# run's OWN conclusion is never consulted, because a run whose only failing job is
# the other leg still put code on a box. RUN_LEG_MIXED is set to 1 when this run
# delivered through one leg while the other FAILED: that is the shape that used to
# be filtered out of the population entirely, so it is counted and printed.
RUN_LEG_MIXED=0
run_delivers() { # <run-id> -> 0 delivers / 1 does not / 2 could not read
  local id="$1" out="$WORK/jobs-$id.json"
  RUN_LEG_MIXED=0
  if [ "$FIXTURE_MODE" = "1" ]; then
    [ -f "$JOBS_FIXTURE" ] || return 2
    jq --arg id "$id" '.[$id] // empty' "$JOBS_FIXTURE" > "$out" 2>/dev/null
    [ -s "$out" ] || return 2
  else
    if ! gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" --jq '.jobs' > "$out" 2>/dev/null; then
      return 2
    fi
  fi
  local hits fails
  hits="$(jq '[.[] | select((.name == "control-plane" or .name == "instance") and .conclusion == "success")] | length' "$out" 2>/dev/null)"
  fails="$(jq '[.[] | select((.name == "control-plane" or .name == "instance") and .conclusion == "failure")] | length' "$out" 2>/dev/null)"
  [ -n "$hits" ] || return 2
  case "${fails:-}" in ''|*[!0-9]*) fails=0 ;; esac
  if [ "$hits" -gt 0 ]; then
    [ "$fails" -gt 0 ] && RUN_LEG_MIXED=1
    return 0
  fi
  return 1
}

# ONE READ PER RUN, PER INVOCATION. Every run inside the examined window is asked
# about TWICE — once to build the delivering population, once to build the wider
# ALIBI set below — and the two answers came from two separate jobs-API calls.
# That is what produced the 6-of-24 false WRONG on main: run 33985744753's first
# read succeeded (the POPULATION line of run 34012723514 printed `0 unreadable`,
# so it was IN the 90 that delivered) and its second read did not, which struck
# its id out of the alibi set and made a TRUE row a ghost. The second read buys
# nothing — the answer cannot change inside one invocation — so it is not made.
# This is the CURE; the UNREADABLE-ALIBI class below is the guarantee that holds
# even when the one remaining read is the one that fails.
run_delivers_cached() { # <run-id> -> 0 delivers / 1 does not / 2 could not read
  local id="$1" rc
  local f="$WORK/verdict-$id.rc"
  if [ -f "$f" ]; then
    RUN_LEG_MIXED=0
    rc="$(cat "$f")"
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
    return "$rc"
  fi
  run_delivers "$id"
  rc=$?
  printf '%s' "$rc" > "$f"
  return "$rc"
}

# ── run ──────────────────────────────────────────────────────────────────────
select_reader || exit 3
[ "$READER" = "ssh" ] && write_remote_reader

say "crown-reconcile — repo=$REPO reader-transport=$READER window=${WINDOW_HOURS}h ($CUTOFF_ISO .. $NOW_ISO)"

REASONS_FILE="$WORK/reasons.txt"
: > "$REASONS_FILE"
DEFERRALS_FILE="$WORK/deferrals.txt"
: > "$DEFERRALS_FILE"
state_load

fetch_runs
rc=$?
# ── THE WATERMARK ───────────────────────────────────────────────────────────
# Taken HERE, one statement after the run page landed, because that is the
# instant the run side of this comparison was frozen. Everything below — the
# jobs API leg, and then the crown read — happens strictly after it, and the
# gap is the defect. A live run reads the real clock; a pinned `--now` run has
# no gap by construction (the watermark IS now, so nothing can be newer than
# it), which is exactly the pre-fix behaviour every existing probe measures.
if [ -n "$RUNLIST_AT_OVERRIDE" ]; then
  RUNLIST_EPOCH="$(epoch_of "$RUNLIST_AT_OVERRIDE")" || { warn "CONFIG: --runlist-at is not an ISO-8601 instant: $RUNLIST_AT_OVERRIDE"; exit 3; }
elif [ -n "$NOW_OVERRIDE" ]; then
  RUNLIST_EPOCH="$NOW_EPOCH"
else
  RUNLIST_EPOCH="$(date -u +%s)"
fi
RUNLIST_ISO="$(iso_of "$RUNLIST_EPOCH")"
# The same measured host-jitter epsilon the serving arm derives, reused rather
# than re-invented: two machines' clocks disagree by seconds, and a row must
# never be excluded because of that alone — signal (ii) also demands a run id
# above the page's maximum, so the clock is corroboration, never the whole case.
WATERMARK_FLOOR=$((RUNLIST_EPOCH - SERVING_SKEW_EPSILON_SECONDS))
[ "$rc" = "3" ] && exit 3
if [ "$rc" != "0" ]; then
  say ""
  say "COULD NOT READ: the deploy.yml run list did not answer. Nothing was compared, and this is NOT a clean run."
  say_reader
  exit 2
fi

# Two populations: the EXAMINED window, and a wider one used only so a row near
# the boundary is not mis-called WRONG.
jq --argjson cut "$CUTOFF_EPOCH" --argjson wide "$WIDE_EPOCH" \
  '[.workflow_runs[]
    | select(.status == "completed")
    | {id: (.id | tostring), sha: .head_sha, created: .created_at, at: (.created_at | fromdateiso8601),
       concl: (.conclusion // "none")}]
   | {examined: [.[] | select(.at >= $cut)], wide: [.[] | select(.at >= $wide)]}' \
  "$WORK/runs-raw.json" > "$WORK/runs.json" 2>/dev/null
if [ ! -s "$WORK/runs.json" ]; then
  say ""
  say "COULD NOT READ: the run list did not parse as an Actions runs payload. Nothing was compared."
  say_reader
  exit 2
fi

COMPLETED_COUNT="$(jq '.examined | length' "$WORK/runs.json")"
# THE PAGE CAP IS THE BOUND, NOT ONE PAGE OF 100. fetch_runs now pages until the
# listing reaches back past the window, so a busy day whose run list runs to 246
# rows is a COUNT. The population is a FLOOR only when the pager stopped early
# — cap hit, or a later page that did not answer — AND the rows it did get still
# do not reach the cutoff. Row count alone is no longer evidence of truncation:
# keying on `>= 100` printed `N+` on every busy day the pager had in fact read
# whole. Printed as `N+`, never rounded down silently.
PAGE_ROWS="$(jq '.workflow_runs | length' "$WORK/runs-raw.json" 2>/dev/null || echo 0)"
PAGE_OLDEST="$(jq -r '[.workflow_runs[] | .created_at | fromdateiso8601] | min // 0' "$WORK/runs-raw.json" 2>/dev/null || echo 0)"
if [ "${RUNS_LIST_COMPLETE:-1}" != "1" ] && [ "${PAGE_OLDEST:-0}" -gt "$CUTOFF_EPOCH" ]; then
  warn "  note: the run listing stopped after ${RUNS_PAGES_READ} page(s) (${PAGE_ROWS} run(s)) without reaching the window start — the population below is a FLOOR, printed as N+"
  FLOOR="+"
else
  FLOOR=""
fi

# THE WATERMARK'S TWO CLOCK-FREE HANDLES, read off the SAME page at the SAME
# instant as everything else. `status` is the run's state as of the sample —
# anything but `completed` is a run we watched running — and Actions allocates
# run ids in creation order, so an id above the page maximum names a run that
# did not exist when we looked. Neither handle consults a clock.
: > "$WORK/nonterminal-runs.txt"
jq -r '.workflow_runs[]? | select((.status // "") != "completed") | .id | tostring' \
  "$WORK/runs-raw.json" > "$WORK/nonterminal-runs.txt" 2>/dev/null
MAX_RUN_ID="$(jq -r '[.workflow_runs[]?.id] | max // 0' "$WORK/runs-raw.json" 2>/dev/null || echo 0)"
MIN_RUN_ID="$(jq -r '[.workflow_runs[]?.id] | min // 0' "$WORK/runs-raw.json" 2>/dev/null || echo 0)"
case "${MAX_RUN_ID:-}" in ''|*[!0-9]*) MAX_RUN_ID=0 ;; esac
case "${MIN_RUN_ID:-}" in ''|*[!0-9]*) MIN_RUN_ID=0 ;; esac
NONTERMINAL_RUNS="$(awk 'NF' "$WORK/nonterminal-runs.txt" | wc -l | tr -d ' ')"

# Which of those actually delivered?
: > "$WORK/delivering.txt"
JOBS_UNREADABLE=0
NONDELIVERING=0
MIXED_LEG=0
# CANCELLED IS A CLASS, AND IT POINTS BOTH WAYS. Cancelled runs were never
# omitted from this population — `run_delivers` does not consult the run's own
# conclusion — but they were counted ANONYMOUSLY, and the parenthetical below
# actively mislabelled them: it told the reader that "delivered nothing" means a
# docs-only merge, when most of that class is a SUPERSEDED PUSH cancelled before
# a single job started. The other direction is the dangerous one: a run whose
# instance or control-plane leg concluded success and which was then cancelled
# DELIVERED — it put code on a box — and its record-delivery job was cancelled
# with it, so the crown may hold no row for a delivery that happened. That is the
# exact shape SERVING-UNRECORDED came from. The conclusion is already on the
# page; naming the two costs two counters in a loop that already runs.
CANCELLED_NONDELIVERING=0
CANCELLED_DELIVERING=0
while IFS=' ' read -r id sha at concl; do
  [ -n "$id" ] || continue
  run_delivers_cached "$id"
  case $? in
    0) printf '%s %s %s\n' "$id" "$sha" "$at" >> "$WORK/delivering.txt"
       [ "$RUN_LEG_MIXED" = "1" ] && MIXED_LEG=$((MIXED_LEG + 1))
       [ "$concl" = "cancelled" ] && CANCELLED_DELIVERING=$((CANCELLED_DELIVERING + 1)) ;;
    1) NONDELIVERING=$((NONDELIVERING + 1))
       [ "$concl" = "cancelled" ] && CANCELLED_NONDELIVERING=$((CANCELLED_NONDELIVERING + 1)) ;;
    *) JOBS_UNREADABLE=$((JOBS_UNREADABLE + 1))
       reason "run $id: its job list could not be read — it is NOT counted as reconciled" ;;
  esac
done < <(jq -r '.examined[] | "\(.id) \(.sha) \(.at) \(.concl)"' "$WORK/runs.json")

DELIVERING="$(awk 'NF' "$WORK/delivering.txt" | wc -l | tr -d ' ')"

# The wide set of delivering runs, for the reverse direction — BOTH their ids
# (the alibi a row states for itself) and their head shas (the fallback for a row
# that states none). Runs outside the examined window are included here only as an
# ALIBI for a row, never as a population this verdict reports a rate over.
: > "$WORK/wide-shas.txt"
: > "$WORK/wide-runs.txt"
# THREE ANSWERS, NOT TWO. `if run_delivers "$id"` folded rc 2 — the jobs list
# could not be READ — into rc 1 — the run delivered NOTHING. Those are opposite
# statements: one is a fact about the deploy, the other is a fact about this
# script's own reading. Folding them struck an unreadable run's id out of the
# alibi set with no trace, and the very next block then reported the honest crown
# row that names it as WRONG. An unreadable alibi is now its own set, counted and
# named, and a row it covers is DEFERRED rather than accused.
: > "$WORK/wide-unreadable.txt"
WIDE_UNREADABLE=0
while IFS=' ' read -r id sha; do
  [ -n "$id" ] || continue
  run_delivers_cached "$id"
  case $? in
    0) printf '%s\n' "$sha" >> "$WORK/wide-shas.txt"
       printf '%s\n' "$id" >> "$WORK/wide-runs.txt" ;;
    1) ;;
    *) WIDE_UNREADABLE=$((WIDE_UNREADABLE + 1))
       printf '%s %s\n' "$id" "$sha" >> "$WORK/wide-unreadable.txt" ;;
  esac
done < <(jq -r '.wide[] | "\(.id) \(.sha)"' "$WORK/runs.json")
sort -u -k1,1 "$WORK/wide-unreadable.txt" > "$WORK/wide-unreadable-sorted.txt"
awk 'NF {print $1}' "$WORK/wide-unreadable-sorted.txt" | sort -u > "$WORK/wide-unreadable-runs.txt"
awk 'NF {print $2}' "$WORK/wide-unreadable-sorted.txt" | sort -u > "$WORK/wide-unreadable-shas.txt"

say ""
say "POPULATION: ${COMPLETED_COUNT}${FLOOR} completed deploy.yml run(s) on main in the window — a run DELIVERED when its control-plane OR instance job concluded success, WHATEVER the run's overall conclusion, because a run whose only failing job is the other leg still put code on a box; ${DELIVERING} of them DELIVERED, ${MIXED_LEG} of those delivered with the OTHER leg FAILED, ${NONDELIVERING} delivered nothing (no leg concluded success — a docs-only merge skips both), ${JOBS_UNREADABLE} unreadable."
say "  CANCELLED, NAMED IN BOTH DIRECTIONS: of the ${NONDELIVERING} that delivered nothing, ${CANCELLED_NONDELIVERING} were CANCELLED_NONDELIVERING — a superseded push, not a docs-only merge, and the parenthetical above is wrong about them; and ${CANCELLED_DELIVERING} of the ${DELIVERING} that DELIVERED are CANCELLED_DELIVERING — a leg concluded success and the run was cancelled anyway, so those runs put code on a box while their record-delivery job died with the cancel, and the crown may hold no row for a delivery that happened."
say "WATERMARK: the run list was sampled at ${RUNLIST_ISO} and the crown is read after it — ${NONTERMINAL_RUNS} run(s) on the page were NON-TERMINAL at that instant, page run ids span ${MIN_RUN_ID}..${MAX_RUN_ID}. A row written by a run that was not terminal then is excluded from BOTH sides as WRITTEN-IN-FLIGHT rather than accused, and is judged normally by the next run."
if [ "$FLOOR" = "+" ]; then
  say "  TRUNCATION RESIDUAL, stated rather than left to the plus sign: the run listing was paged ${RUNS_PAGES_READ} time(s) and still stopped short of the window start, so runs older than id ${MIN_RUN_ID} were never examined. A delivering run that fell off the page CANNOT be counted BEHIND by this run — the BEHIND denominator above is a floor, and its silence is a blind spot, not a clean reading."
fi

# ── BEHIND: a delivering run whose head sha the crown has no row for ─────────
BEHIND=0
BEHIND_UNREADABLE=0
PREDATES=0
: > "$WORK/behind.txt"
: > "$WORK/predates.txt"
while IFS=' ' read -r id sha at; do
  [ -n "$sha" ] || continue
  # A run that finished before `record-delivery` existed cannot be BEHIND: there
  # was no writer to be behind. It gets its own printed class, not silence.
  if [ -n "${at:-}" ] && [ "$at" -lt "$RECORDER_BIRTH_EPOCH" ] 2>/dev/null; then
    PREDATES=$((PREDATES + 1))
    printf '%s %s\n' "$sha" "$id" >> "$WORK/predates.txt"
    continue
  fi
  if crown_read "sha=$sha" "$WORK/rows-$sha.json"; then
    n="$(jq --arg sha "$sha" '[.deliveries[] | select(.sha == $sha)] | length' "$WORK/rows-$sha.json" 2>/dev/null)"
    [ -n "$n" ] || n=0
    if [ "$n" -eq 0 ]; then
      BEHIND=$((BEHIND + 1))
      printf '%s %s\n' "$sha" "$id" >> "$WORK/behind.txt"
    fi
  else
    BEHIND_UNREADABLE=$((BEHIND_UNREADABLE + 1))
    reason "the crown could not be asked about $sha (delivered by run $id) — that run is NOT counted as reconciled"
  fi
done < "$WORK/delivering.txt"

# The BEHIND denominator is the delivering runs that a writer actually existed
# for. It is printed beside PREDATES below, so the exemption is a denominator a
# reader can subtract, never a hidden window.
RECONCILABLE=$((DELIVERING - PREDATES))

# ── WRONG: a row inside the window naming a sha no delivering run delivered ──
WRONG=0
UNCLASSIFIED=0
ROWS_EXAMINED=0
# Rows the run-list snapshot cannot speak for. NOT a tolerance and NOT silence:
# each is printed by name with the evidence that put it here, subtracted from
# the WRONG denominator so the rate stays over a population that was actually
# judged, and judged normally by the very next run.
INFLIGHT_ROWS=0
# Rows whose writing run has been non-terminal past the measured cap. A hung run
# stops being an alibi: these are ACCUSED, not deferred again.
INFLIGHT_EXPIRED=0
# Rows a TRUNCATED page makes unjudgeable — their delivering run is older than
# the oldest run we could see, so it can be neither found nor ruled out. These
# go through reason(), so they land in rc 2 and still page.
TRUNC_UNJUDGED=0
# Rows whose stated deliverer's JOB LIST could not be read. Not a tolerance and
# not a WRONG: the alibi was never READ, so it was never absent. Each is printed
# by name with the run it names, subtracted from the WRONG denominator, and put
# through reason() so the run lands in rc 2 (SILENCE) and still pages.
UNREADABLE_ALIBI=0
# The quiescence count, for the QUIET WINDOW arm below (charter D597). Distinct
# from ROWS_EXAMINED on purpose: an in-window row seen down the no-alibi branch
# was COUNTED but never CLASSIFIED — there is no alibi source to judge it
# against — so it must never inflate the WRONG denominator.
QUIET_ROWS=0
QUIET_ROWS_READ=0
# The refusal is a variable so the QUIET WINDOW arm can tolerate EXACTLY this
# sentence and no other — a guard pinned to prose that could drift from the
# reason() call would silently tolerate nothing, or everything.
NOALIBI_REASON="no delivering run in the widened window — the reverse direction has no alibi source and was NOT checked"
: > "$WORK/wrong.txt"
: > "$WORK/unreadable-alibi.txt"
: > "$WORK/inflight.txt"
: > "$WORK/inflight-expired.txt"
sort -u "$WORK/wide-shas.txt" > "$WORK/wide-shas-sorted.txt"
sort -u "$WORK/wide-runs.txt" > "$WORK/wide-runs-sorted.txt"
WIDE_SHAS="$(awk 'NF' "$WORK/wide-shas-sorted.txt" | wc -l | tr -d ' ')"
if [ "$WIDE_SHAS" -eq 0 ]; then
  # Without a single delivering run in the widened window there is no ALIBI
  # source, and every row would be accused of being a ghost. That is the
  # comforting-direction mistake inverted — loud, but manufactured. Refuse.
  reason "$NOALIBI_REASON"
  # The QUIESCENCE question is narrower than the WRONG question and still needs
  # an answer here: "do any rows sit inside the window at all?" needs no alibi
  # source, only a count. A read that fails leaves QUIET_ROWS_READ=0, and the
  # QUIET WINDOW arm below fails CLOSED on it — an uncounted window can never
  # green.
  if crown_read "limit=$ROW_LIMIT" "$WORK/recent.json"; then
    QUIET_ROWS="$(jq --argjson cut "$CUTOFF_EPOCH" \
      '[.deliveries[]
        | select((.first_seen_at // "") != "")
        | . + {at: (try (.first_seen_at | sub("\\.[0-9]+"; "") | sub("Z?$"; "Z") | fromdateiso8601) catch 0)}
        | select(.at >= $cut)] | length' "$WORK/recent.json" 2>/dev/null)"
    case "${QUIET_ROWS:-}" in ''|*[!0-9]*) QUIET_ROWS=0 ;; *) QUIET_ROWS_READ=1 ;; esac
  fi
elif crown_read "limit=$ROW_LIMIT" "$WORK/recent.json"; then
  jq --argjson cut "$CUTOFF_EPOCH" \
    '[.deliveries[]
      | select((.first_seen_at // "") != "")
      | . + {at: (try (.first_seen_at | sub("\\.[0-9]+"; "") | sub("Z?$"; "Z") | fromdateiso8601) catch 0)}
      | select(.at >= $cut)]' "$WORK/recent.json" > "$WORK/recent-window.json" 2>/dev/null
  if [ -s "$WORK/recent-window.json" ]; then
    ROWS_EXAMINED="$(jq 'length' "$WORK/recent-window.json")"
    QUIET_ROWS="$ROWS_EXAMINED"
    QUIET_ROWS_READ=1
    while IFS=' ' read -r sha carried run rowat; do
      [ -n "$sha" ] || continue
      case "${rowat:-}" in ''|*[!0-9]*) rowat=0 ;; esac
      if [ "$carried" = "true" ]; then
        continue
      elif [ "$carried" = "null" ]; then
        UNCLASSIFIED=$((UNCLASSIFIED + 1))
        reason "row $sha: 'carried' was never measured — it cannot be ruled correct or wrong, and is NOT counted clean"
        continue
      fi
      # The alibi the row states for ITSELF, first: the run the recorder says
      # wrote it. The head-sha comparison is reached only when the row states no
      # run at all, because a served sha legitimately differs from every run's
      # head sha whenever a deploy's pull races past its trigger.
      if [ "$run" != "-" ]; then
        grep -qx "$run" "$WORK/wide-runs-sorted.txt" && continue
      else
        grep -qx "$sha" "$WORK/wide-shas-sorted.txt" && continue
      fi
      # ── THE WATERMARK, BEFORE ANY ACCUSATION ────────────────────────────
      # No alibi was found — but "no alibi" is only an accusation if the run
      # list could have carried one. These two arms are the cases where it
      # structurally could not, and each is a FACT READ OFF THE PAGE, never a
      # window widened around an inconvenient row.
      #
      # (i) RUN-KEYED, CLOCK-FREE. The page says this run was still going when
      # we sampled it, so `.conclusion == "success"` could not have matched it
      # no matter what the run eventually does. Sufficient on its own.
      if [ "$run" != "-" ] && grep -qx "$run" "$WORK/nonterminal-runs.txt"; then
        # …CAPPED. A run that has been in_progress longer than the measured
        # deploy maximum is hung, and a hung run is not an alibi — it is
        # deferring the accusation with no end to the deferral. Charged against
        # the ROW's own first-seen instant, so one row gets one window and never
        # a fresh one per run, exactly as the serving grace is charged.
        _inflight_age=$((NOW_EPOCH - rowat))
        if [ "$_inflight_age" -gt "$SERVING_INFLIGHT_CAP_SECONDS" ]; then
          INFLIGHT_EXPIRED=$((INFLIGHT_EXPIRED + 1))
          printf '%s %s %s\n' "$sha" "$run" "$_inflight_age" >> "$WORK/inflight-expired.txt"
        else
          INFLIGHT_ROWS=$((INFLIGHT_ROWS + 1))
          printf '%s %s in-flight\n' "$sha" "$run" >> "$WORK/inflight.txt"
          continue
        fi
      fi
      # (ii) TIME-KEYED, AND CORROBORATED. The row was written at or after the
      # watermark AND its writer did not exist on the page at all — either it
      # names no run, or it names an id above the page maximum, which Actions'
      # creation-ordered ids make a statement about EXISTENCE, not about
      # membership. Time alone never excuses a row: a clock that disagrees must
      # not be able to forgive one, so both halves are required.
      if [ "$rowat" -ge "$WATERMARK_FLOOR" ]; then
        _newer_run=0
        case "$run" in
          -) _newer_run=1 ;;
          ''|*[!0-9]*) _newer_run=0 ;;
          *) [ "$MAX_RUN_ID" -gt 0 ] && [ "$run" -gt "$MAX_RUN_ID" ] && _newer_run=1 ;;
        esac
        if [ "$_newer_run" = "1" ]; then
          INFLIGHT_ROWS=$((INFLIGHT_ROWS + 1))
          printf '%s %s written-after-the-watermark\n' "$sha" "$run" >> "$WORK/inflight.txt"
          continue
        fi
      fi
      # ── A TRUNCATED PAGE CANNOT MANUFACTURE A GHOST ─────────────────────
      # The page is bounded at 100 runs. When it filled without reaching the
      # window start, a row naming a run id BELOW the page minimum names a run
      # that FELL OFF THE PAGE — indistinguishable from one that never existed.
      # Accusing it is a false red the truncation itself produced. This is an
      # UNREADABLE condition by name (rc 2, which still pages), never a WRONG
      # and never a silence.
      if [ "$FLOOR" = "+" ] && [ "$MIN_RUN_ID" -gt 0 ]; then
        case "$run" in
          ''|-|*[!0-9]*) ;;
          *) if [ "$run" -lt "$MIN_RUN_ID" ]; then
               TRUNC_UNJUDGED=$((TRUNC_UNJUDGED + 1))
               reason "row $sha: its delivering run $run is OLDER than the oldest run on the TRUNCATED 100-run page (minimum id $MIN_RUN_ID) — the run it names fell off the page, so it can be neither alibied nor accused, and is NOT counted clean"
               continue
             fi ;;
        esac
      fi
      # ── AN ALIBI THAT WAS NEVER READ IS NOT AN ALIBI THAT IS ABSENT ─────
      # The alibi set above is built by asking the jobs API once per run. When
      # that read FAILS the run is not "a run that delivered nothing" — it is a
      # run this script has no opinion about, and accusing a row that names it
      # is accusing the crown of this script's own read failure. That is the
      # 6-of-24 false WRONG on main (task-a8bb36d8622be137). Disjoint from the
      # three arms above by construction: every id here came off the SAME
      # completed-run page, so it is neither non-terminal, nor above the page
      # maximum, nor below its minimum.
      _cannot_read_alibi=0
      if [ "$run" != "-" ]; then
        grep -qx "$run" "$WORK/wide-unreadable-runs.txt" && _cannot_read_alibi=1
      else
        grep -qx "$sha" "$WORK/wide-unreadable-shas.txt" && _cannot_read_alibi=1
      fi
      if [ "$_cannot_read_alibi" = "1" ]; then
        UNREADABLE_ALIBI=$((UNREADABLE_ALIBI + 1))
        printf '%s %s\n' "$sha" "${run:--}" >> "$WORK/unreadable-alibi.txt"
        if [ "$run" != "-" ]; then
          reason "row $sha: the job list of run $run — the run this row names as its deliverer — could NOT be read, so whether it delivered is UNKNOWN. The row is NOT counted clean and NOT counted as a ghost — an alibi that was never read is not an alibi that is absent."
        else
          reason "row $sha: it names no delivering run, and the job list of the run carrying that head sha could NOT be read, so whether it delivered is UNKNOWN. The row is NOT counted clean and NOT counted as a ghost."
        fi
        continue
      fi
      WRONG=$((WRONG + 1))
      printf '%s %s\n' "$sha" "$run" >> "$WORK/wrong.txt"
      # `.carried // "null"` would be WRONG here: jq's `//` treats `false` as
      # empty, so every honestly-measured `carried: false` row would report as
      # unmeasured — the comforting direction. Presence is asked for explicitly,
      # and `delivering_run_id` is read the same way for the same reason.
    done < <(jq -r '.[] | "\(.sha) \(if has("carried") and .carried != null then (.carried | tostring) else "null" end) \(if has("delivering_run_id") and .delivering_run_id != null and ((.delivering_run_id | tostring) != "") then (.delivering_run_id | tostring) else "-" end) \(.at // 0)"' "$WORK/recent-window.json" | sort -u)
  else
    reason "the recent-row page did not parse — the reverse direction was NOT checked"
  fi
else
  reason "the recent-row page could not be read — the reverse direction was NOT checked"
fi

# ── SERVING: what the box says it is running, versus the crown ───────────────
SERVING_RED=0
# 1 ONLY when the serving check RAN end-to-end and the served sha HAS its cp
# row. Condition (1) of the QUIET WINDOW arm (charter D597): a check that was
# skipped, could not read, or found no row leaves this 0 — quiescence can never
# be asserted over an unverified crown.
SERVING_VERIFIED=0
SERVING_SHA=""
SERVING_SKEW=0
SERVING_SKEW_AHEAD=0
SERVING_INFLIGHT_RUN=""
SERVING_INFLIGHT_EXPIRED=""
SERVING_INFLIGHT_AGE=0
SERVING_SINCE=""
GRACED_THIS_RUN=""
if [ -n "$HEALTH_FIXTURE" ] || [ "$FIXTURE_MODE" != "1" ]; then
  if [ -n "$HEALTH_FIXTURE" ]; then
    if [ -f "$HEALTH_FIXTURE" ]; then cp "$HEALTH_FIXTURE" "$WORK/health.json"; else : > "$WORK/health.json"; fi
  else
    curl -s --max-time 20 "$HEALTH_URL" > "$WORK/health.json" 2>/dev/null
  fi
  SERVING_SHA="$(jq -r '.serving_sha // .git_sha // empty' "$WORK/health.json" 2>/dev/null)"
  if [ -z "$SERVING_SHA" ]; then
    reason "${HEALTH_URL} did not name a serving sha — the serving check did NOT run"
  else
    since="$(jq -r '.serving_since // empty' "$WORK/health.json" 2>/dev/null)"
    SERVING_SINCE="$since"
    since_epoch="$(epoch_of "$since" 2>/dev/null || echo 0)"
    age=$((NOW_EPOCH - ${since_epoch:-0}))
    if crown_read "sha=$SERVING_SHA" "$WORK/rows-serving.json"; then
      cp_rows="$(jq --arg sha "$SERVING_SHA" '[.deliveries[] | select(.sha == $sha and .target == "cp")] | length' "$WORK/rows-serving.json" 2>/dev/null)"
      [ -n "$cp_rows" ] || cp_rows=0
      if [ "$cp_rows" -eq 0 ]; then
        # The grace is charged against the FIRST time this sha was seen serving
        # and unrecorded, not against the process age the box reports now. A sha
        # already on the re-ask list cannot buy a fresh grace by being restarted.
        #
        # `graced_age` bounds the EPSILON and GRACE arms below at
        # SERVING_GRACE_SECONDS, and the IN-FLIGHT arm at its own, longer
        # SERVING_INFLIGHT_CAP_SECONDS (measured derivation at the constant),
        # so none of the three can defer forever. A run still `in_progress`
        # past the cap stops being an alibi and the accusation fires below as
        # SERVING-INFLIGHT-EXPIRED, naming the hung run.
        first_seen="$(state_first_seen "$SERVING_SHA")"
        [ -n "$first_seen" ] || first_seen="$NOW_EPOCH"
        graced_age=$((NOW_EPOCH - first_seen))
        # THE ORDER OF THESE ARMS IS THE BEHAVIOUR: IN-FLIGHT, then EPSILON,
        # then SKEW, then GRACE, then RED. The negative-age skew guard is right
        # about a real clock fault and WRONG about a deploy that is still
        # running, because there the disagreement IS the in-flight signal — a
        # box that came up seconds ago reports a serving_since the runner's
        # clock has not reached. Asked in the other order, the skew arm wins
        # first and the crown pages on a deploy nobody has finished.
        inflight_run="$(serving_run_in_flight "$SERVING_SHA")"
        if [ -n "$inflight_run" ] && [ "$graced_age" -lt "$SERVING_INFLIGHT_CAP_SECONDS" ]; then # MUT:G-INFLIGHT-CAP
          SERVING_INFLIGHT_RUN="$inflight_run"
          # defer(), NOT reason(). Everything was read; the answer is "not yet".
          # The debt goes to the re-ask list with every other deferral, so a
          # deploy that runs and still never records is accused by a later run.
          GRACED_THIS_RUN="$SERVING_SHA"
          defer "SERVING IN FLIGHT: the serving sha $SERVING_SHA has no cp row, but deploy.yml run ${inflight_run} for that exact sha is STILL RUNNING — the recorder has not had its turn, so the accusation is DEFERRED to the next run rather than fired at a deploy in progress (first seen $(iso_of "$first_seen"))"
        elif [ -n "$inflight_run" ]; then
          # The alibi EXPIRED. The run has reported in_progress since beyond
          # SERVING_INFLIGHT_CAP_SECONDS (charged against first-seen): that is
          # a hung run, not a slow deploy, and a hung run must not hold the
          # accusation off for the rest of GitHub's own timeout. Falls to RED
          # with its own named sentence below, never to the skew arm — the
          # disagreement here is explained, and its explanation is the fault.
          SERVING_INFLIGHT_EXPIRED="$inflight_run"
          SERVING_INFLIGHT_AGE="$graced_age"
          SERVING_RED=1
        elif [ "${since_epoch:-0}" -gt 0 ] && [ "$age" -lt 0 ] && [ $((0 - age)) -le "$SERVING_SKEW_EPSILON_SECONDS" ] && [ "$graced_age" -lt "$SERVING_GRACE_SECONDS" ]; then
          # Ordinary inter-host jitter, measured at 3s on an NTP-healthy plane.
          # A few seconds of disagreement between two machines is not a fault,
          # and calling it one turns every fresh deploy into a page. It is still
          # a DEFERRAL, never a pass: the debt is written exactly as the grace's
          # is, so nothing is forgiven — only postponed.
          GRACED_THIS_RUN="$SERVING_SHA"
          defer "SERVING GRACE: the serving sha $SERVING_SHA has no cp row and its serving_since is ${SERVING_SKEW_EPSILON_SECONDS}s-or-less ahead of now ($((0 - age))s) — inter-host jitter, not a clock fault, so the accusation is DEFERRED to the next run rather than dropped (first seen $(iso_of "$first_seen"))"
        elif [ "${since_epoch:-0}" -gt 0 ] && [ "$age" -lt 0 ]; then
          # A serving_since AHEAD of now by more than the epsilon, with no run
          # in flight to explain it, means the clocks disagree. "Probably in
          # flight" is the comforting reading of a disagreement, so this is a
          # FAULT with its own sentence, and the missing row is accused.
          SERVING_SKEW=1
          SERVING_SKEW_AHEAD=$((0 - age))
          SERVING_RED=1
        elif [ "${since_epoch:-0}" -gt 0 ] && [ "$age" -lt "$SERVING_GRACE_SECONDS" ] && [ "$graced_age" -lt "$SERVING_GRACE_SECONDS" ]; then
          GRACED_THIS_RUN="$SERVING_SHA"
          # defer(), NOT reason(). This is not a condition that could not be
          # read — everything was read, and the answer is "not yet". The debt is
          # written to the re-ask list six lines below and collected by the next
          # run as GRACED-UNRECORDED, exit 1.
          defer "SERVING GRACE: the serving sha $SERVING_SHA has no cp row, but that process is only ${age}s old — a deploy may still be in flight, so the accusation is DEFERRED to the next run rather than dropped (first seen $(iso_of "$first_seen"))"
        else
          SERVING_RED=1
        fi
      else
        # The served sha has its cp row: the check ran and the crown answered
        # for the exact commit production is running.
        SERVING_VERIFIED=1
      fi
    else
      reason "the crown could not be asked about the serving sha — the serving check did NOT run"
    fi
  fi
fi

# ── THE DEFERRED RE-READ: every sha a grace was ever granted to ──────────────
# A grace deferred an accusation; this is where the deferral is collected. The
# question is asked of the CROWN, not of the box, so it survives the box moving
# on to another sha — which is precisely what made 4c8314c94 unaccusable.
GRACED_RED=0
WAIVED_COUNT=0
: > "$WORK/graced.txt"
: > "$WORK/reask-keep.txt"
while IFS=' ' read -r gsha gts; do
  [ -n "$gsha" ] || continue
  gage=$((NOW_EPOCH - gts))
  if [ "$gsha" = "$GRACED_THIS_RUN" ]; then
    # Its grace window is still open and this run already said so by name.
    printf '%s %s\n' "$gsha" "$gts" >> "$WORK/reask-keep.txt"
    continue
  fi
  # THE ALIBI THE SERVING ARM ALREADY GRANTS, ASKED ONE LOOP LATER. The SERVING
  # arm defers while `serving_run_in_flight` names a non-terminal run for that
  # exact sha; this loop did not re-ask it, so the moment the box moved on to a
  # newer sha the graced sha lost its alibi and was accused — 373df8e7a, graced
  # 09:58:01, its run 34025636906 in_progress since 09:47:30, fired
  # GRACED-UNRECORDED at 11:00:18. That is a red at a deploy nobody has
  # finished, which is precisely the shape the IN-FLIGHT arm exists to refuse.
  # The box moving on does not finish that run, and the recorder has not had its
  # turn until it does.
  #
  # Bounded by the SAME cap the SERVING arm uses, charged the same way (against
  # first-seen), so a HUNG run stops being an alibi and this can never defer
  # forever; past the cap it falls straight through to the accusation below.
  # `serving_run_in_flight` reads $WORK/runs-raw.json — the deploy.yml run page
  # this script already fetched — so this adds no API call and no credential.
  gflight="$(serving_run_in_flight "$gsha")"
  if [ -n "$gflight" ] && [ "$gage" -lt "$SERVING_INFLIGHT_CAP_SECONDS" ]; then # MUT:G-REASK-INFLIGHT
    defer "GRACE HELD: the graced sha $gsha still has no cp row, but deploy.yml run ${gflight} for that exact sha is STILL RUNNING — the recorder has not had its turn, so the deferred accusation is held rather than fired at a deploy in progress (first seen $(iso_of "$gts"))"
    printf '%s %s\n' "$gsha" "$gts" >> "$WORK/reask-keep.txt"
    continue
  fi
  if [ "$gage" -gt "$REASK_MAX_SECONDS" ]; then
    reason "the graced sha $gsha aged off the re-ask list after ${REASK_MAX_SECONDS}s with no cp row — it was accused on every run in between, and the list is bounded, not forgiving"
    continue
  fi
  if crown_read "sha=$gsha" "$WORK/rows-graced-$gsha.json"; then
    grows="$(jq --arg sha "$gsha" '[.deliveries[] | select(.sha == $sha and .target == "cp")] | length' "$WORK/rows-graced-$gsha.json" 2>/dev/null)"
    [ -n "$grows" ] || grows=0
    if [ "$grows" -gt 0 ]; then
      say "  note: the graced sha $gsha was recorded after all — retired from the re-ask list"
      continue
    fi
    # THE DATED WAIVER, applied at the ONE point the accusation is counted. It
    # is checked AFTER the crown was actually asked — a waived sha that got its
    # row still retires cleanly above — and it keeps the sha on the re-ask list,
    # so the instant the waiver expires this same loop accuses it again.
    if waived_now "$gsha"; then
      WAIVED_COUNT=$((WAIVED_COUNT + 1))
      say "  WAIVED (expires ${WAIVER_EXPIRES_ISO}, $((WAIVER_EXPIRES_EPOCH - NOW_EPOCH))s from now): the graced sha $gsha has no cp row and WOULD be accused. It is the one pre-fix specimen of the forward-only recorder fix (#16471), which cannot backfill a row already lost; the real remedy is the owner-queue backfill, task-9c8fccd9e8a77773. This waiver names that sha literally and suppresses nothing else, and past ${WAIVER_EXPIRES_ISO} it is INERT — the accusation returns with no code change."
      printf '%s %s\n' "$gsha" "$gts" >> "$WORK/reask-keep.txt"
      continue
    fi
    GRACED_RED=$((GRACED_RED + 1))
    printf '%s %s\n' "$gsha" "$gts" >> "$WORK/graced.txt"
    printf '%s %s\n' "$gsha" "$gts" >> "$WORK/reask-keep.txt"
  else
    reason "the crown could not be asked about the graced sha $gsha — it stays on the re-ask list and is NOT counted clean"
    printf '%s %s\n' "$gsha" "$gts" >> "$WORK/reask-keep.txt"
  fi
done < "$WORK/reask.txt"

if [ -n "$GRACED_THIS_RUN" ] && ! grep -q "^$GRACED_THIS_RUN " "$WORK/reask-keep.txt"; then
  printf '%s %s\n' "$GRACED_THIS_RUN" "$NOW_EPOCH" >> "$WORK/reask-keep.txt"
fi
state_save "$WORK/reask-keep.txt"

# ── the verdict ──────────────────────────────────────────────────────────────
pct() { # <numerator> <denominator>
  [ "${2:-0}" -gt 0 ] || { printf 'n/a'; return; }
  awk -v n="$1" -v d="$2" 'BEGIN { printf "%.1f%%", (n * 100) / d }'
}

say ""
say_reader
say ""
if [ "$PREDATES" -gt 0 ]; then
  say "PREDATES-WRITER: ${PREDATES} of ${DELIVERING} delivering run(s) were created before the record-delivery job existed (born ${RECORDER_BIRTH_ISO}, PR ${RECORDER_BIRTH_PR}, merge ${RECORDER_BIRTH_COMMIT}) — nothing could have recorded them, so they are NOT counted BEHIND. They are printed here rather than hidden by a narrower window:"
  while IFS=' ' read -r sha id; do
    say "    ${sha}  (run ${id}) — delivered before any recorder existed"
  done < "$WORK/predates.txt"
  say ""
fi
if [ "$INFLIGHT_ROWS" -gt 0 ]; then
  say "WRITTEN-IN-FLIGHT: ${INFLIGHT_ROWS} of ${ROWS_EXAMINED} crown row(s) in the window were written by a run that was NOT TERMINAL when the run list was sampled (${RUNLIST_ISO}) — the two sides of this comparison are taken minutes apart, and a row that appeared inside that gap has no alibi it could possibly have had. They are EXCLUDED FROM BOTH SIDES and printed here rather than graced away; the next run sees a terminal run and judges them normally, and a run that never delivered is WRONG then:"
  while IFS=' ' read -r sha run why; do
    [ -n "$sha" ] || continue
    case "$why" in
      in-flight) say "    ${sha}  (run ${run}) — that run was on the page as NON-TERMINAL at the watermark; no clock was consulted" ;;
      *) say "    ${sha}  (run ${run}) — written at or after the watermark, by a run above the page maximum id ${MAX_RUN_ID}: it did not exist when the run list was taken" ;;
    esac
  done < "$WORK/inflight.txt"
  say ""
fi
if [ "$INFLIGHT_EXPIRED" -gt 0 ]; then
  say "WRITTEN-IN-FLIGHT-EXPIRED: ${INFLIGHT_EXPIRED} crown row(s) name a run that is STILL non-terminal, and whose row has been waiting past the ${SERVING_INFLIGHT_CAP_SECONDS}s cap (charged against the row's own first-seen instant). A hung run is not an alibi, so these are ACCUSED below rather than deferred again:"
  while IFS=' ' read -r sha run age; do
    [ -n "$sha" ] || continue
    say "    ${sha}  (run ${run}) — that run has reported non-terminal for the ${age}s this row has existed"
  done < "$WORK/inflight-expired.txt"
  say ""
fi
if [ "$TRUNC_UNJUDGED" -gt 0 ]; then
  say "TRUNCATED-UNJUDGEABLE: ${TRUNC_UNJUDGED} crown row(s) name a delivering run older than the oldest run on the truncated page (minimum id ${MIN_RUN_ID}). A run that fell off a bounded page is not a ghost, so they are an UNREADABLE condition by name — counted in neither direction, never counted clean, and this run exits 2."
  say ""
fi
if [ "$WIDE_UNREADABLE" -gt 0 ]; then
  say "ALIBI SET INCOMPLETE: ${WIDE_UNREADABLE} run(s) in the widened alibi window could not have their JOB LIST read. None of them is counted as a run that delivered nothing — a read that did not happen is not a fact about the deploy:"
  while IFS=' ' read -r uid usha; do
    [ -n "$uid" ] || continue
    say "    run ${uid}  (head ${usha}) — its job list could not be read, so this run can neither alibi a row nor be ruled out as its deliverer"
  done < "$WORK/wide-unreadable-sorted.txt"
  say ""
fi
if [ "$UNREADABLE_ALIBI" -gt 0 ]; then
  say "UNREADABLE-ALIBI: ${UNREADABLE_ALIBI} of ${ROWS_EXAMINED} crown row(s) name a deliverer whose job list could NOT be read. They are DEFERRED, not accused — this run exits 2, and the next run, whose read is a fresh one, judges them normally:"
  while IFS=' ' read -r usha urun; do
    [ -n "$usha" ] || continue
    if [ "${urun:--}" = "-" ]; then
      say "    ${usha} — names no run, and the run carrying that head sha could not have its job list read"
    else
      say "    ${usha}  (run ${urun}) — that run's job list could not be read; it is neither an alibi nor a ghost"
    fi
  done < "$WORK/unreadable-alibi.txt"
  say ""
fi
if [ "$BEHIND" -gt 0 ]; then
  say "BEHIND: ${BEHIND} of ${RECONCILABLE} delivering run(s) examined ($(pct "$BEHIND" "$RECONCILABLE")) delivered a sha the crown has NO row for:"
  while IFS=' ' read -r sha id; do
    say "    ${sha}  (run ${id}) — delivered, never recorded"
  done < "$WORK/behind.txt"
fi
# The WRONG rate is a rate over the rows this run actually JUDGED. Rows the
# watermark excluded, and rows a truncated page made unjudgeable, are printed
# above with their own counts — an exemption has to be a denominator a reader
# can subtract, never a quieter one.
JUDGED_ROWS=$((ROWS_EXAMINED - INFLIGHT_ROWS - TRUNC_UNJUDGED - UNREADABLE_ALIBI))
[ "$JUDGED_ROWS" -lt 0 ] && JUDGED_ROWS=0
if [ "$WRONG" -gt 0 ]; then
  say "WRONG: ${WRONG} of ${JUDGED_ROWS} crown row(s) examined ($(pct "$WRONG" "$JUDGED_ROWS")) were written by no delivering run:"
  while IFS=' ' read -r sha run; do
    if [ "${run:--}" = "-" ]; then
      say "    ${sha} — recorded with no delivering run id, and no delivering run has that head sha"
    else
      say "    ${sha} — recorded as delivered by run ${run}, which is not a delivering run in the window"
    fi
  done < "$WORK/wrong.txt"
fi
if [ "$SERVING_SKEW" -gt 0 ]; then
  say "SERVING-CLOCK-SKEW: barkpark.cloud reports serving_since ${SERVING_SINCE:-<none>}, which is ${SERVING_SKEW_AHEAD}s in the FUTURE. A grace granted off a clock that disagrees is not leniency, it is a fault — so the missing row below is ACCUSED rather than excused."
fi
if [ -n "$SERVING_INFLIGHT_EXPIRED" ]; then
  say "SERVING-INFLIGHT-EXPIRED: deploy.yml run ${SERVING_INFLIGHT_EXPIRED} for the serving sha has reported in_progress for ${SERVING_INFLIGHT_AGE}s (first-seen-charged), past the ${SERVING_INFLIGHT_CAP_SECONDS}s cap — a hung run is not an alibi, so the missing row below is ACCUSED rather than deferred again."
fi
if [ "$SERVING_RED" -gt 0 ]; then
  say "SERVING-UNRECORDED: barkpark.cloud reports it is SERVING ${SERVING_SHA} and the crown has no cp row for it — production is running a commit its own record has never heard of."
fi
if [ "$WAIVED_COUNT" -gt 0 ]; then
  say "GRACED-WAIVED: ${WAIVED_COUNT} sha(s) had no cp row and were NOT counted, under the dated waiver in this script that expires ${WAIVER_EXPIRES_ISO} ($((WAIVER_EXPIRES_EPOCH - NOW_EPOCH))s from now). This run is therefore not a clean green on those shas — it is a green that a waiver bought, and the waiver retires itself."
fi
if [ "$GRACED_RED" -gt 0 ]; then
  say "GRACED-UNRECORDED: ${GRACED_RED} sha(s) were granted the serving grace on an earlier run and STILL have no cp row. The grace was a DEFERRAL, and this is the deferred accusation — it fires whether or not the box still serves them:"
  while IFS=' ' read -r gsha gts; do
    say "    ${gsha}  (first seen $(iso_of "$gts"), $((NOW_EPOCH - gts))s ago) — graced, then never recorded"
  done < "$WORK/graced.txt"
fi

if [ "$BEHIND" -gt 0 ] || [ "$WRONG" -gt 0 ] || [ "$SERVING_RED" -gt 0 ] || [ "$GRACED_RED" -gt 0 ]; then
  say ""
  say "VERDICT: NOT reconciled — behind=${BEHIND}/${RECONCILABLE} delivering runs, wrong=${WRONG}/${JUDGED_ROWS} rows, serving-unrecorded=${SERVING_RED}, graced-unrecorded=${GRACED_RED}, predates-writer=${PREDATES}/${DELIVERING}, written-in-flight=${INFLIGHT_ROWS}/${ROWS_EXAMINED}, written-in-flight-expired=${INFLIGHT_EXPIRED}, truncated-unjudgeable=${TRUNC_UNJUDGED}, unreadable-alibi=${UNREADABLE_ALIBI}, reader=$(reader_answered), re-ask-list=${STATE_STATE}."
  exit 1
fi

if [ "$DELIVERING" -eq 0 ]; then
  # ── QUIET WINDOW (charter D597): an empty window on a VERIFIED crown ───────
  # A repo that stops merging empties this window BY CONSTRUCTION, and rc 2
  # here filed every 6 hours forever (6-run streak 2026-08-15..17, #11217 at 41
  # comments). Quiescence reads green ONLY when all four hold: (1) the serving
  # check verified the served sha has its cp row, (2) the re-ask list was
  # PRESENT-EMPTY, (3) zero ledger rows sit inside the window, (4) the push
  # trigger is not suspect — no deploy-path file change on main sits in the
  # window with zero deploy.yml runs (the dead-trigger block below). Any OTHER
  # reason() than the reverse direction's structural no-alibi refusal is a real
  # silence and still outranks quiescence — the refusal itself is unavoidable
  # on an empty window and is repeated inside the deferral text below, because
  # a green here must not imply the reverse direction was checked.
  # ── THE FOURTH QUIESCENCE CONDITION: THE TRIGGER IS ALIVE (dr-w35) ────────
  #
  # BEHIND is RUN-derived — a delivering run whose sha has no row — never
  # repo-head-derived. So if push-triggered deploy.yml stops firing entirely
  # while merges continue, the window is empty of delivering runs, the (stale)
  # serving sha keeps its cp row, the re-ask list is PRESENT-EMPTY, and the
  # three conditions above all hold: quiescence read GREEN while production
  # silently fell behind main. The 60-day auto-disable residual covers the
  # SCHEDULE going dark, not the push trigger.
  #
  # The check, measured not felt: list main commits inside the window and
  # classify each against deploy.yml's OWN on.push path filters (parsed from
  # the checked-out file — one source of truth, no re-typed list). A commit
  # touching those filters MUST have produced a deploy.yml run; docs-only
  # commits legitimately produce none. Refusal fires ONLY when filter-touching
  # commits exist AND the window holds ZERO deploy.yml runs of ANY status —
  # runs present but non-delivering (a deploy.yml-only merge, a failed deploy)
  # mean the TRIGGER is alive, which is all this condition asserts. STATED
  # RESIDUAL: a window whose every relevant run FAILED still quiesces green
  # here; that is a different defect (nothing-delivered, not dead-trigger).
  # A commit list that cannot be read is a reason() — quiescence then refuses
  # through QUIET_OTHER_REASONS, fail-closed and named. The GitHub commit-files
  # payload caps at 300 files per commit; a >300-file commit whose deploy-path
  # file sits past the cap can be misread as irrelevant — stated, not hidden.
  QUIET_RELEVANT_COMMITS=0
  QUIET_WINDOW_RUNS=0
  if [ -n "$RUNS_FIXTURE" ] || [ -f "$WORK/runs-raw.json" ]; then
    QUIET_WINDOW_RUNS="$(jq --argjson cut "$CUTOFF_EPOCH" \
      '[.workflow_runs[]? | select((.created_at | sub("\\.[0-9]+"; "") | sub("Z?$"; "Z") | fromdateiso8601) >= $cut)] | length' \
      "$WORK/runs-raw.json" 2>/dev/null || echo 0)"
    case "${QUIET_WINDOW_RUNS:-}" in ''|*[!0-9]*) QUIET_WINDOW_RUNS=0 ;; esac
  fi
  deploy_path_filters() { # the on.push paths block of deploy.yml, first block only
    awk '
      done { next }
      inp && /^[[:space:]]*-[[:space:]]*"/ { line=$0; sub(/^[^"]*"/, "", line); sub(/".*$/, "", line); print line; next }
      inp && !/^[[:space:]]*#/ && !/^[[:space:]]*$/ { done=1; next }
      /^[[:space:]]*paths:[[:space:]]*$/ { inp=1 }
    ' "$REPO_ROOT/.github/workflows/deploy.yml"
  }
  if [ -n "$COMMITS_FIXTURE" ] || [ "$FIXTURE_MODE" != "1" ]; then
    if [ -n "$COMMITS_FIXTURE" ]; then
      if [ -f "$COMMITS_FIXTURE" ] && jq -e 'type == "array"' "$COMMITS_FIXTURE" >/dev/null 2>&1; then
        cp "$COMMITS_FIXTURE" "$WORK/commits-files.json"
      else
        reason "the main commit list for the window could not be read — the dead-trigger check did NOT run"
      fi
    else
      # LIVE: only reached on a live empty window, so the spend is bounded and
      # rare. List shas since the window start, then each commit's files —
      # capped at 50 commits; a busier window than that with zero runs is a
      # dead trigger many times over and the refusal below fires regardless.
      if gh api "repos/$REPO/commits?sha=main&since=$CUTOFF_ISO&per_page=50" \
           --jq '[.[].sha]' > "$WORK/commit-shas.json" 2>/dev/null; then
        : > "$WORK/commits-files.ndjson"
        commits_files_ok=1
        while IFS= read -r csha; do
          [ -n "$csha" ] || continue
          if ! gh api "repos/$REPO/commits/$csha" \
               --jq '{sha: .sha, files: [.files[]?.filename]}' >> "$WORK/commits-files.ndjson" 2>/dev/null; then
            commits_files_ok=0; break
          fi
        done < <(jq -r '.[]' "$WORK/commit-shas.json" 2>/dev/null)
        if [ "$commits_files_ok" = "1" ]; then
          jq -s '.' "$WORK/commits-files.ndjson" > "$WORK/commits-files.json" 2>/dev/null \
            || reason "the main commit list for the window could not be read — the dead-trigger check did NOT run"
        else
          reason "the main commit list for the window could not be read — the dead-trigger check did NOT run"
        fi
      else
        reason "the main commit list for the window could not be read — the dead-trigger check did NOT run"
      fi
    fi
    if [ -f "$WORK/commits-files.json" ]; then
      # The filter list travels by FILE, never by `awk -v` — BSD awk refuses a
      # -v value containing newlines ("newline in string"), and an empty filter
      # set must be a named refusal rather than a matcher that matches nothing.
      deploy_path_filters > "$WORK/deploy-filters.txt"
      if [ ! -s "$WORK/deploy-filters.txt" ]; then
        reason "deploy.yml's on.push paths block could not be parsed — the dead-trigger check did NOT run"
      else
        jq -r '[.[] | .files[]?] | .[]' "$WORK/commits-files.json" 2>/dev/null > "$WORK/commit-files.txt"
        QUIET_RELEVANT_COMMITS="$(awk '
          NR == FNR { F[++n] = $0; next }
          {
            for (i = 1; i <= n; i++) {
              f = F[i]
              if (f ~ /\/\*\*$/) { pre = substr(f, 1, length(f) - 2); if (index($0, pre) == 1) { hits++; next } }
              else if ($0 == f) { hits++; next }
            }
          }
          END { print hits + 0 }' "$WORK/deploy-filters.txt" "$WORK/commit-files.txt")"
        case "${QUIET_RELEVANT_COMMITS:-}" in ''|*[!0-9]*) QUIET_RELEVANT_COMMITS=0 ;; esac
      fi
    fi
  fi
  QUIET_TRIGGER_DEAD=0
  if [ "$QUIET_RELEVANT_COMMITS" -gt 0 ] && [ "$QUIET_WINDOW_RUNS" -eq 0 ]; then # MUT:G-DEADTRIGGER
    QUIET_TRIGGER_DEAD=1
  fi
  QUIET_OTHER_REASONS="$(grep -vxF "$NOALIBI_REASON" "$REASONS_FILE" 2>/dev/null | awk 'NF' | wc -l | tr -d ' ')"
  if [ "$SERVING_VERIFIED" = "1" ] && [ "$STATE_STATE" = "PRESENT-EMPTY" ] && [ "$QUIET_ROWS_READ" = "1" ] && [ "$QUIET_ROWS" -eq 0 ] && [ "${QUIET_OTHER_REASONS:-1}" -eq 0 ] && [ "$QUIET_TRIGGER_DEAD" -eq 0 ]; then
    say ""
    say "QUIET WINDOW: ${COMPLETED_COUNT}${FLOOR} completed run(s) in the window and none of them delivered — and the crown is VERIFIED as far as an empty window allows: the serving sha ${SERVING_SHA} has its cp row, the re-ask list was PRESENT-EMPTY (nothing graced is still owed a row), ZERO crown row(s) sit inside the window (nothing was delivered and nothing claims to have been), and the push trigger is NOT suspect (no deploy-path file change on main sits in the window without a deploy.yml run). This is a NAMED DEFERRAL, not a reconciliation: the verdict over a real population is deferred to the next run whose window holds one."
    say "  the reverse direction has no alibi source on an empty window and was NOT checked — quiescence-green does not imply the reverse direction was checked."
    say "::warning::QUIET WINDOW — zero delivering deploy.yml runs in the last ${WINDOW_HOURS}h on a verified crown (serving sha recorded, re-ask list PRESENT-EMPTY, zero in-window rows, push trigger not suspect). A deferral, not a silence: paging here is what mutes the alarm for the one case that is not."
    exit 0
  fi
  say ""
  if [ "$QUIET_TRIGGER_DEAD" -eq 1 ]; then
    say "DEAD-TRIGGER SUSPECT: ${QUIET_RELEVANT_COMMITS} file change(s) on main inside the window touch deploy.yml's own on.push path filters, yet the window holds ZERO deploy.yml runs of any status — the push trigger never fired for them, so production is falling behind main. This is exactly the shape quiescence-green could not see (dr-w35): it stays a warning that pages, never a quiet green."
  fi
  if [ "$QUIET_ROWS_READ" = "1" ] && [ "$QUIET_ROWS" -gt 0 ]; then
    # Rows-exist-but-no-runs is NOT quiescence and STAYS rc 2: a row claiming a
    # delivery no run made is an accusation source, unjudgeable without an
    # alibi population.
    say "ROWS WITHOUT RUNS: ${QUIET_ROWS} crown row(s) sit inside the window while NO delivering run does — a row with no run is an accusation source, not quiescence, so this stays a warning."
  fi
  say "COULD NOT VERIFY: the population was EMPTY — ${COMPLETED_COUNT}${FLOOR} completed run(s) in the window and none of them delivered. A rate with no denominator is refused, so this is a warning, not a green."
  exit 2
fi

if [ "$RECONCILABLE" -eq 0 ]; then
  say ""
  say "COULD NOT VERIFY: all ${DELIVERING} delivering run(s) in the window PREDATE the recorder's birth (${RECORDER_BIRTH_ISO}, PR ${RECORDER_BIRTH_PR}) — there is nothing a writer could have recorded, so the BEHIND denominator is zero. A rate with no denominator is refused, so this is a warning, not a green."
  exit 2
fi

# SILENCE OUTRANKS DEFERRAL, always. A run that both granted a grace and failed
# to read something is a run that failed to read something; checking rc 4 first
# would let one benign deferral launder a real silence into a warning.
if [ "$UNREADABLE" != "0" ]; then
  say ""
  REASON_COUNT="$(awk 'NF' "$REASONS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
  say "COULD NOT FULLY READ: ${REASON_COUNT} unreadable condition(s) fired. Everything that COULD be read reconciled, but this run is NOT clean. Each condition, by name:"
  if [ "${REASON_COUNT:-0}" -eq 0 ]; then
    # UNREADABLE was set without going through reason(). The counters this
    # sentence used to print could be all zeros while it exited 2; an unnamed
    # silence is now a stated bug rather than a row of noughts.
    say "    - (unnamed — UNREADABLE was set without a reason, which is a BUG in this script)"
  else
    awk 'NF { c[$0]++; if (!($0 in seen)) { seen[$0] = 1; order[++n] = $0 } }
         END { for (i = 1; i <= n; i++) printf "    - %s%s\n", order[i], (c[order[i]] > 1 ? " (x" c[order[i]] ")" : "") }' "$REASONS_FILE"
  fi
  exit 2
fi

if [ "$DEFERRED" != "0" ]; then
  say ""
  DEFER_COUNT="$(awk 'NF' "$DEFERRALS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
  say "NOT YET DUE: ${DEFER_COUNT} deferred condition(s) fired. Everything was READ, nothing is accused, and every accusation this run held back was written to the re-ask list — the next run that still finds no row fires GRACED-UNRECORDED and exits 1. This is a warning, not a page, and it is not a green either. Each deferral, by name:"
  if [ "${DEFER_COUNT:-0}" -eq 0 ]; then
    # DEFERRED was incremented without going through defer(). Same shape as the
    # unnamed-silence bug above, and stated for the same reason.
    say "    - (unnamed — DEFERRED was incremented without a deferral, which is a BUG in this script)"
  else
    awk 'NF { c[$0]++; if (!($0 in seen)) { seen[$0] = 1; order[++n] = $0 } }
         END { for (i = 1; i <= n; i++) printf "    - %s%s\n", order[i], (c[order[i]] > 1 ? " (x" c[order[i]] ")" : "") }' "$DEFERRALS_FILE"
  fi
  exit 4
fi

say ""
say "RECONCILED: all ${RECONCILABLE} delivering run(s) in the window have their row, all ${JUDGED_ROWS} judged row(s) in the window have their run, the serving sha ${SERVING_SHA:-<not checked>} is recorded, and no earlier grace is still owed a row — read by $(reader_answered), against a re-ask list that was ${STATE_STATE} with ${STATE_LOADED} entry(ies). written-in-flight=${INFLIGHT_ROWS}/${ROWS_EXAMINED} row(s) were excluded from BOTH sides because their writer was not terminal at the watermark ${RUNLIST_ISO}; this green does NOT extend to them, and the next run judges them."
exit 0
