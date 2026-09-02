#!/usr/bin/env elixir
# pds-elixir-receipt-census.exs — the FIRST census of the Elixir success surface.
#
# THE LAW (PDS wave 22): no Barkpark verb may report success on an exit code alone.
# THE OWNING DOC:        docs/decisions/success-claim-census.md (canonical-for: success-claim-census)
#
# WHAT THIS IS. A build-free AST census of every `ok: true` / `"ok" => true` success
# claim under api/lib. It runs under plain `elixir` with NO mix project and NO compile
# (`Code.string_to_quoted/2` only), so it never boots the app — deliberately, because
# `mix phx.server` OOMs on this host.
#
# WHAT IT COSTS THE GATE — AND THE CLAIM THAT USED TO STAND HERE. This header read, up to
# wave 46: "THIS FILE — not the `scripts/pds-*` CLASS — is in neither Elixir path set
# (scripts/elixir-path-escape-check.sh), so it costs no Elixir gate minute." That sentence
# had ALREADY been narrowed once — from the `scripts/pds-*` CLASS to this one FILE, after
# the class-wide version was caught being false — and the NARROWED version was false too:
# `scripts/pds-elixir-receipt-census.exs` is declared in ELIXIR_TEST_ONLY_PATHS at
# scripts/elixir-path-escape-check.sh:100 (the block opens :89), put there by #9333 so a
# PR touching only this instrument still DISPATCHES the Elixir suite. It costs gate
# minutes, it is SUPPOSED to, and narrowing a false claim is not the same as checking it.
# A receipt that misstates its own gating is the defect this census exists to name — and
# it was naming itself.
#
# THE PRICE, FROM A METER (PDS-D605: user CPU, never wall clock).
# api/test/barkpark/pds_elixir_census_test.exs shells THREE arms on the required `Elixir
# gate`: plain (rc 0), a one-token `tl/1` mutant (rc 1), an unknown-flag refusal (rc 2).
# `/usr/bin/time -p` around a SHELL (so the rc survives and the shell's children are
# charged), two trials, load1 stamped either side — 1,70 → 1,97, a WORKING host, not an
# idle one, which is part of the reading and not a footnote:
#   plain    user 11,48 / 11,67 s · sys 0,94 / 0,91 s · real 12,12 / 12,07 s
#   mutant   user 11,29 / 11,37 s · sys 1,13 / 0,84 s · real 13,70 / 11,77 s
#   refusal  user  2,85 /  3,10 s · sys 0,40 / 0,42 s · real  2,95 /  3,20 s
#   PER RUN OF THE RIDER: 28,09 s and 28,31 s of CPU, charged to a gate this file said it
#   did not touch. The refusal is NOT free — `elixir` compiles this whole script before it
#   can reject a flag, which is most of that 3 s.
# EVERY EARLIER MAGNITUDE FOR THESE ARMS IS REFUTED, including the one the wave-46 brief
# carried: not 51-67 s and not 33,05-35,26 s for the three arms; not 5,4-6,2 s and not
# 3,85-4,11 s for the refusal; the mutant's WALL is ~12-14 s, not 73,91 s and not
# 16,20-16,48 s. Four separate recorded prices for one unchanged instrument is the whole
# argument: RE-TAKE THE MEASUREMENT, NEVER TRANSCRIBE ONE — not from a charter, not from
# a brief, not from this comment. What survives is the METHOD line above, not the digits.
#
# WHAT THIS IS NOT. It is NOT a gate. It ships no floor over the population, because
# the ruling stands (PDS-D454): Elixir stays honest-and-unguarded until the write-routed
# sites are bucketed. What it DOES fail on is its own integrity — a truncated corpus, a
# lens that loses occurrences, a partition that does not add up, or a delegate chain it
# can no longer follow. Those exit non-zero. IT IS STILL NOT A FLOOR OVER THE POPULATION
# — D454 stands, no site count has to be under a threshold to pass — but since wave 47 it
# is not silent about its own numbers either: the eight population rows are pinned to a
# baseline RE-DERIVED BY RUN at wave 47 (@rederived, PDS-D678), and a row that moves off it
# exits 1 on D448-DRIFT-REFUSES instead of printing DRIFT at exit 0 forever. The repair is
# to RE-DERIVE and amend the baseline with its lens in the same commit, never to re-type it.
#
# THE LENS, STATED (PDS-D448a). This census is AST-based and depends on NO regex engine
# and, specifically, on NO word-boundary support: on this host Apple git 2.39.5's POSIX
# ERE has no `\b`, so `git grep -E '\bok: true'` returns 0 matches and exits 1 SILENTLY
# while `git grep -P`, BSD `grep -rE` and `rg` all return 97 on the identical corpus.
# Every textual count below is plain substring matching (`:binary.matches/2`).
#
# MEASURING ENGINE (printed again at runtime from the live VM):
#   Elixir 1.19.5 · Erlang/OTP 28 (erts 16.3.1) · darwin arm64 · git 2.39.5 (Apple)
#
# USAGE — ARGV IS STRICT. An argument this list does not name exits 2 without measuring
# anything, because a census that silently swallows a flag reports a number for a lens
# nobody asked for (PDS-D493: `--selftest` used to run the ordinary census and exit 0).
#   elixir scripts/pds-elixir-receipt-census.exs            # full corpus census
#   elixir scripts/pds-elixir-receipt-census.exs --sites    # + every emitted site, one per line
#   elixir scripts/pds-elixir-receipt-census.exs --files-from FILE   # corpus-refusal rehearsal
#   elixir scripts/pds-elixir-receipt-census.exs --keys     # STDOUT: the register key, TSV, one line per emitted site
#   elixir scripts/pds-elixir-receipt-census.exs --selftest # mutate this file over a synthetic corpus; prove the arms can go RED
#
# EXIT: 0 all integrity checks pass · 1 an integrity check failed · 2 corpus refused OR
#       an unknown argument. NEVER PIPE THIS SCRIPT WHEN READING ITS EXIT CODE — `cmd |
#       tail` reports tail's status, which is how the exit-2 refusal was once logged RC 0.

defmodule PDS.Census do
  # ------------------------------------------------------------- the blind spot
  #
  # DECLARED ABOVE @moduledoc ON PURPOSE. A module attribute is read at DEFINITION
  # time, so the doc string can only interpolate a list that already exists; moving
  # this below @moduledoc would silently document an empty blind spot.
  #
  # ONE SOURCE OF TRUTH, REFERENCED TWICE — @moduledoc just below, and banner/0's
  # printed output. That is the whole point of PDS-D633: the obligation is that the
  # sentence survives a COPY-PASTE OF THE NUMBERS. Prose next to a figure is dropped
  # by whoever quotes the figure; two hand-typed copies drift the first time one is
  # edited. A list referenced twice can do neither.
  @blind_spot [
    "AN OS METER AROUND THIS SCRIPT MEASURES THE PARENT BEAM AND NOTHING ELSE.",
    "`--selftest` fans out to CHILD BEAMs (System.cmd/3, one per case) and the",
    "wrapper sees none of their cycles. MEASURED, LIKE FOR LIKE, ON ONE NAMED RUN",
    "(PDS-D633's 33-case `--selftest`): `/usr/bin/time -p` reported user 6.05 s for",
    "the whole fan-out — ILLUSTRATIVE, that run only. Against it stands ONE plain",
    "census metered inside its own BEAM, which is the `user cpu` figure printed at",
    "the END of THIS run. THIS LIST CANNOT NAME THAT FIGURE and no longer pretends",
    "to: a module attribute is read before the census runs, and every hand-typed",
    "copy has drifted — 8687 / 12615 / 13199 / 15970 / 17640 / 19815 ms across",
    "recorded runs, a 2.3x SPREAD, so the `~15 s` that sat here could not have been",
    "right for more than one of them. The wrapper's figure for all thirty-three",
    "children came in under HALF the price of ONE of them, and nine of the cases",
    "census this same corpus, so NINE TIMES this run's own `user cpu` is a FLOOR on",
    "what those 6.05 s conceal — DERIVED on the `user cpu` line below (kept on that",
    "one line so the count of volatile lines stays at ONE), never typed here.",
    "DO NOT QUOTE A RATIO: real/user was 113x on that run and 236x on an earlier",
    "one, because `real` counts waiting — the load-independent statement is the",
    "DIRECTION, and it runs the ONE WAY A PRICE COLUMN MUST NOT: it makes an",
    "expensive instrument look gate-able.",
    "There is no outer-meter fallback when the thing wrapped is a BEAM",
    "that fans out; a leaf-metered price is the sum over the children, per child.",
    "The `user cpu` figure below is BEAM-INTERNAL and covers THIS process only —",
    "for the plain census, which spawns nobody, that is the whole price."
  ]

  @moduledoc """
  A build-free AST census of the `api/lib` success surface. See the header comment
  above `defmodule` for the lens, the exits, and what this is NOT (it is not a gate).

  ## Price, and the blind spot in measuring it

  #{Enum.map_join(@blind_spot, "\n  ", & &1)}
  """

  # ---------------------------------------------------------------- constants

  # Recorded by PDS-D448 (wave 33 survey). THE HISTORICAL RECORD, KEPT VERBATIM — it is
  # what wave 33 measured with wave 33's lens, and report_split/1 and report_depth_sweep/2
  # both quote it to say TRUE things about that lens. Nothing here is edited when a number
  # moves; the comparison the census enforces lives in @rederived below.
  @recorded %{
    textual: 103,
    ast: 95,
    phantom: 8,
    consumer: 4,
    emitted: 91,
    write: 64,
    read: 17,
    unrouted: 10
  }

  # THE BASELINE THE CENSUS REFUSES TO DIFFER FROM (PDS-D678, wave 47). For four waves the
  # block below printed `advisory — printed, never enforced` while FIVE of these eight rows
  # read DRIFT on every run, including `unrouted` off by 130 %. An instrument that measures
  # its own charter as false and cannot red is a gate whose green costs nothing. Both legal
  # endings were taken, per row and in this order: RE-DERIVE-AND-AMEND, then REFUSE.
  #
  # RE-DERIVED AT WAVE 47 (5 rows) — the wave-33 literal did not descend from this tree
  # under this lens, so the literal was re-taken by run, never transcribed:
  #
  #   textual   103 -> 104   same lens, the tree moved. `ok: true` occurrences by
  #                          :binary.matches/2 over the 804-file corpus; the partition
  #                          LENS-LOSES-NOTHING (104 == ast 95 + phantom 9) holds on it.
  #   phantom     8 ->   9   the same move seen from the other side: textual 104 minus the
  #                          95 AST-literal pairs. One new prose/`@doc` occurrence.
  #   write      64 ->  54   NOT tree drift — A DIFFERENT LENS, and the census already
  #   read       17 ->  14   measures why. `transaction` was removed from @write_verbs
  #   unrouted   10 ->  23   (PDS wave 34: it opens a transaction, it moves no row) and the
  #                          clause-collapse fix landed; report_depth_sweep/2 prints
  #                          54/14/23 at depth 6 and IDENTICALLY at 7,8,9,10,12 — the route
  #                          relation's closure. 64/17/10 is at no depth in that table. It
  #                          is what a deeper (or hand-followed) route sees; both are
  #                          honest, and QUOTING EITHER WITHOUT ITS LENS IS THE LIE
  #                          (PDS-D448a). So the lens is stated with the number, here and
  #                          in the printed block.
  #
  # INHERITED UNCHANGED (3 rows): ast 95, consumer 4, emitted 91 read `==` in the same run
  # that produced the five re-derivations and are copied across untouched. A block widened
  # until everything matches is a green that costs nothing (the fourth law) — so the arm
  # derives the inherited/re-derived split from @recorded at runtime and PRINTS it, and
  # nothing above may be edited to make a red go away.
  #
  # THE LENS AND THE ENGINE THIS BASELINE WAS TAKEN WITH (PDS-D448a):
  #   lens    build-free AST (`Code.string_to_quoted`), substring counts via
  #           :binary.matches/2 (no regex engine, no `\b`), route depth @max_depth = 6,
  #           @write_verbs without `transaction`, corpus `api/lib/**/*.ex` = 804 files
  #   engine  Elixir 1.19.5 · Erlang/OTP 28 (erts 16.3.1) · darwin arm64 (printed live by
  #           report_engine/0 on every run, so a re-derivation on another engine says so)
  #   command elixir scripts/pds-elixir-receipt-census.exs   (run from the repo root)
  #   at      2026-08-04, tree 49345a98c, rc=0, `CENSUS OK`
  #
  # AND THEN: REFUSE. All eight rows are ARMED — D448-DRIFT-REFUSES in the integrity block
  # exits 1 on any mismatch, so the next drift cannot ship green. THE REPAIR IS NOT "EDIT
  # THE NUMBER": re-run the command above, and amend the row here WITH the lens, the engine
  # and the run that produced it, in the SAME commit as the change that moved it.
  # RE-DERIVED AT THE BPML W3 WAVE (4 rows) — the tree moved, same lens: the
  # working-copy sync endpoint adds two `ok: true` receipt sites (sync_apply/6
  # unchanged-leg, sync_persist/6 applied-leg) and one POST route.
  #
  #   textual   104 -> 106   two new occurrences; LENS-LOSES-NOTHING holds
  #                          (106 == ast 97 + phantom 9).
  #   ast        95 ->  97   the same two, as AST-literal pairs.
  #   emitted    91 ->  93   both sites emit on the wire.
  #   write      54 ->  56   POST /papers/:slug/sync joins the routed-write set.
  #
  # INHERITED UNCHANGED: phantom 9, consumer 4, read 14, unrouted 23 read `==`
  # in the same run. Lens unchanged (build-free AST, :binary.matches/2, depth 6,
  # @write_verbs without `transaction`); engine of this re-derivation:
  # Elixir 1.20.0 · Erlang/OTP 29 (erts 17.0.1) · aarch64-apple-darwin25 —
  # a NEWER engine than the wave-47 baseline's, printed live by report_engine/0.
  # command `elixir scripts/pds-elixir-receipt-census.exs` from the repo root,
  # 2026-08-14, in the SAME commit as the sync endpoint that moved the rows.
  # RE-DERIVED AT THE CREATE-ON-PUSH WAVE (4 rows, rides #11934) — the tree moved,
  # same lens: the create-on-push arm (sync_create/6 → sync_create_persist/6, the
  # `ok: true, created: true` birth receipt after Content.upsert_paper) adds ONE
  # `ok: true` receipt site on a route already in the write set.
  #
  #   textual   106 -> 107   one new occurrence; LENS-LOSES-NOTHING holds
  #                          (107 == ast 98 + phantom 9).
  #   ast        97 ->  98   the same one, as an AST-literal pair.
  #   emitted    93 ->  94   the created receipt emits on the wire.
  #   write      56 ->  57   sync_create_persist/6 routes off POST /papers/:slug/sync
  #                          (already a routed write) — the depth-6 relation now
  #                          reaches its Content.upsert_paper write.
  #
  # INHERITED UNCHANGED: phantom 9, consumer 4, read 14, unrouted 23 read `==`
  # in the same run. Lens unchanged (build-free AST, :binary.matches/2, depth 6,
  # @write_verbs without `transaction`, corpus api/lib/**/*.ex = 814 files); engine
  # of this re-derivation: Elixir 1.19.5 · Erlang/OTP 28 (erts 16.3.1) ·
  # aarch64-apple-darwin24.6.0, printed live by report_engine/0. command
  # `elixir scripts/pds-elixir-receipt-census.exs` from the repo root, 2026-08-17,
  # in the SAME commit as the create-on-push arm that moved the rows.
  # RE-DERIVED AT THE CORRECTION-RECEIPT WAVE (4 rows, rides #9600) — the tree
  # moved, same lens: SearchController.correction/2 stopped spelling the literal
  # `ok: true` and now renders `ok: status != :error` beside a `status:`
  # discriminator, because record_correction/3 answers FIVE causally different
  # outcomes that all carried `promoted: false, distinct_sessions: 0`. The
  # receipt got MORE honest and the site left this lens's population, which is
  # the lens working: it keys on the literal, and there is no longer a literal.
  #
  #   textual   107 -> 106  the `ok: true` occurrence is gone; LENS-LOSES-NOTHING
  #                         holds (106 == ast 97 + phantom 9).
  #   ast        98 ->  97  the same one, as an AST-literal pair.
  #   emitted    94 ->  93  the site no longer emits a literal on the wire.
  #   write      57 ->  56  POST /v1/data/search/:dataset/correction leaves the
  #                         literal write set. It does NOT leave the ROUTED-WRITE
  #                         population — both of its route arrivals are disposed
  #                         `status_only_receipt` in @routed_excluded below, which
  #                         is the class for exactly this shape.
  #
  # RE-DERIVED AT THE SELF-SERVICE PASSWORD-CHANGE WAVE (4 rows, rides #9530) —
  # the tree moved, same lens: PATCH /v1/auth/password adds ONE `ok: true`
  # receipt site (AuthController.change_password/2, the success arm after
  # Accounts.update_user_password/3) on a NEW routed-write route.
  #
  #   textual   107 -> 108   one new occurrence; LENS-LOSES-NOTHING holds
  #                          (108 == ast 99 + phantom 9).
  #   ast        98 ->  99   the same one, as an AST-literal pair.
  #   emitted    94 ->  95   the site emits on the wire.
  #   write      57 ->  58   patch /v1/auth/password joins the routed-write set;
  #                          the depth-6 relation reaches update_user_password/3's
  #                          Repo write. Its ROUTED-WRITE arrival is disposed by
  #                          the register row authored for it, not by an
  #                          @routed_excluded entry — a judged site needs no
  #                          exclusion.
  #
  # INHERITED UNCHANGED: phantom 9, consumer 4, read 14, unrouted 23 read `==`
  # in the same run. Lens unchanged (build-free AST, :binary.matches/2, depth 6,
  # @write_verbs without `transaction`, corpus api/lib/**/*.ex = 815 files);
  # engine of this re-derivation: Elixir 1.19.5 · Erlang/OTP 28 (erts 16.3.1) ·
  # aarch64-apple-darwin24.6.0, printed live by report_engine/0. command
  # `elixir scripts/pds-elixir-receipt-census.exs` from the repo root, 2026-08-20,
  # in the SAME commit as the correction receipt that moved the rows.
  # RE-DERIVED BY RUN, never re-typed (PDS-D448a): the four moved rows below are the
  # output of `elixir scripts/pds-elixir-receipt-census.exs` from the repo root on the
  # tree this commit ships, amended in the SAME commit as the change that moved them.
  #
  # WHAT MOVED IT: jf-backlog-apptoken-revoke-upstream added ONE routed-write receipt —
  # AppTokenController.delete_by_id/2's `ok: true` success arm, the emission that makes
  # the new admin revoke-by-id auditable instead of an UNDISPOSED ARRIVAL. One emission
  # moves four rows: textual and ast-literal count the occurrence, `emitted` counts the
  # site, and `read` counts the route's sibling GET /v1/auth/app-tokens arriving in the
  # read-routed population. `phantom` is unchanged at 9 BY CONSTRUCTION — the receipt's
  # own comment deliberately does not spell the needle, so it names no emitter.
  # RE-DERIVED BY RUN, never re-typed (PDS-D448a): the two moved rows below are the
  # output of `elixir scripts/pds-elixir-receipt-census.exs` from the repo root on the
  # tree this commit ships, amended in the SAME commit as the change that moved them.
  # Lens unchanged (build-free AST, :binary.matches/2, depth 6, @write_verbs without
  # `transaction`, corpus api/lib/**/*.ex = 827 files, CORPUS-INTACT this run); engine
  # of this re-derivation: Elixir 1.19.5 . Erlang/OTP 28 (erts 16.3.1) .
  # aarch64-apple-darwin24.6.0, printed live by report_engine/0, 2026-09-01.
  #
  # WHAT MOVED IT: task-ef3eb91bf7f87d4c scoped the `auth: :ingest` sheets doors to the
  # caller's workspace. ONE emitter changed CLASS and NONE entered or left the
  # population -- textual, ast, phantom, consumer, emitted and write all read `==` in
  # the same run, which is the tell: no new success claim was written, an existing one
  # simply started reaching a Repo verb.
  #
  #   read       15 -> 16   Barkpark.Plugins.Sheets.Web.OpsController.apply_ops/2's
  #                         `ok: true` arm. Its new authorize_sheet/3 tenant gate calls
  #                         Content.get_document/4, so the depth-6 relation now reaches
  #                         a READ verb where it previously reached none: the ops door
  #                         used to hand the slug straight to Session.apply_ops/4, a
  #                         GenServer hop this lens cannot follow.
  #   unrouted   23 -> 22   the SAME site, leaving. read + unrouted is 38 before and
  #                         after; a pair moving in opposite directions by exactly one
  #                         is a RECLASSIFICATION, never an arrival.
  #
  # ISOLATED BY RUN, not by reading the diff. Reverting ONLY
  # api/lib/barkpark/plugins/sheets/web/ops_controller.ex to its pre-change bytes and
  # re-running the census printed all eight rows `==` again, D448-DRIFT-REFUSES PASS.
  # The PR's two other edited controllers move NOTHING: export_controller.ex holds no
  # `ok: true` literal at all (it sends bytes, so it is not in this lens's population
  # and its threaded scope cannot show up here), and import_controller.ex's receipt was
  # already write-routed through Content.upsert_document/4 -- adding scope opts to a
  # call that already reached a write verb changes no class. Naming the two doors that
  # did NOT move is the half a diff-reader skips.
  @rederived %{
    textual: 108,
    ast: 99,
    phantom: 9,
    consumer: 4,
    emitted: 95,
    write: 57,
    read: 16,
    unrouted: 22
  }

  # THE ROW THE TWO D448 SELFTEST CASES INJECT, BUILT THE WAY drift/4 BUILDS IT — including
  # its column padding — from @rederived and NOTHING TYPED. Both cases perturb
  # `unrouted` by exactly one, so `baseline` is @rederived.unrouted + 1 (this file's own
  # injected number, safe to assert) and `derived` is whatever the tree says (NEVER
  # asserted). Pinning that second half is what left D448-REFUSAL-IS-THE-ARM dead-red for
  # two waves while `textual` moved 104 -> 106 -> 107 -> 108, every move an honest
  # re-derivation and not one of them a defect.
  @drift_row_injected "unrouted       baseline " <>
                        String.pad_leading(to_string(@rederived.unrouted + 1), 4) <> "  derived"

  # Route-bearing sentinels. A carriers-only corpus (the files that literally hold an
  # `ok: true`) parses fine and reports write=0 with no error — PDS-D449a. These files
  # carry no `ok: true` themselves, so their absence PROVES the corpus is truncated.
  #
  # THE CARRIER COUNT IS DERIVED, NEVER TYPED (PDS wave 35). This comment said "the 27
  # files"; the measured value is 26 files carrying an AST-literal pair and 28 carrying a
  # textual occurrence — false under BOTH readings, and a hardcoded population inside the
  # instrument that measures the population is the exact defect this epic keeps filing.
  # report_lens/5 now prints both, live.
  @sentinels [
    "api/lib/barkpark/tasks.ex",
    "api/lib/barkpark/tasks/close.ex",
    "api/lib/barkpark/repo.ex"
  ]
  @corpus_floor 600

  # `transaction` IS NOT A WRITE VERB (PDS wave 34). Repo.transaction/1 OPENS a
  # transaction; it moves no row. The universal Barkpark shape is
  #   Repo.transaction(fn -> Repo.query!("SELECT pg_advisory_xact_lock(...)")
  #                          Repo.get(Document, id)   # the PRE-write load
  # so the opener scored WRITE at line N while the lock scored READ at N+1 and the
  # pre-write load at N+3 — and post_read?/2 is pure line arithmetic. That single
  # token manufactured 17 of 17 POST-READs on wave 33's shipped lens. Every verb
  # left in this list moves a row.
  @write_verbs ~w(insert insert! update update! delete delete! insert_all update_all
                  delete_all insert_or_update insert_or_update!)a
  @read_verbs ~w(all one one! get get! get_by get_by! aggregate exists? preload
                 stream reload reload!)a
  @repo_mods [:Repo, :Multi]

  # DEPTH 6 IS THE CLOSURE OF THE ROUTE RELATION, NOT A TASTE. Sweeping the budget,
  # write/read/unrouted reads 23/11/57 · 29/23/39 · 39/15/37 · 43/23/25 · 53/15/23 ·
  # 54/14/23 for depths 1..6 and then 54/14/23 IDENTICALLY at 7,8,9,10,12,15,20,30 —
  # the bfs seen-set makes the reachable set a finite closure and the route set is
  # monotone in the budget. The SHAPE relation does NOT close until 12 (POST-READ 6
  # here, 15/21/23/23/24 at 7/8/9/10/12), and every unit past 6 buys POST-READ
  # inflation via cross-row certifiers, so above 6 this knob is a COMPLIANCE DIAL,
  # not a lens. Printed at runtime by report_depth_sweep/2 so it cannot be read as
  # taste. (The brief's 42/14/35 was the A+B+C lens WITHOUT the clause-collapse fix.)
  @max_depth 6
  @sweep [1, 2, 3, 4, 5, 6]

  # DEPTHS PAST THE CENSUS DEPTH, MEASURED RATHER THAN ASSERTED. The claim "the route
  # closes at 6 but the shape relation does not" is only worth printing if the run can
  # still see it fail, so the sweep keeps going past @max_depth and the prose reads its
  # sentences off these rows. 12 is where wave 34 found the shape relation flat.
  @beyond [7, 8, 9, 10, 12]

  @shapes ~w(POST-READ CAS-CONFIRMED-ECHO PURE-ECHO CATCH-ALL-TO-SUCCESS WRONG-ROW
             DISCARDED-POST-READ)

  # ------------------------------------------------------- routed population (L4)
  #
  # THE POPULATION A COMPLETENESS ARM IS ABOUT (PDS wave 38). REGISTER-COMPLETE proves
  # "every emitted site carries a row, both directions" over a population THE LENS
  # DEFINES BY A STRING — the sites that literally spell `ok: true`. SCIM's three write
  # routes emit success with NO `ok` KEY AT ALL (`send_resp(conn, 204, "")` at
  # scim_users_controller.ex, behind `pipeline :scim` → RequireScimToken, a real
  # non-admin IdP write path), so they are STRUCTURALLY outside that claim and a green
  # REGISTER-COMPLETE says exactly nothing about them. A green gate over a population the
  # lens defines is a vacuous green wearing the LENS instead of the CORPUS.
  #
  # SO THE OUTSIDE POPULATION IS DERIVED FROM THE ROUTER — the one structure that already
  # enumerates every reachable write — and EVERY MEMBER CARRIES A DISPOSITION.
  #
  # VOCABULARY: ROUTED-WRITE / DISPOSED (PDS-D552). The census already owns
  # write-routed / read-routed / unrouted in the DRIFT rows, and those mean REPO-VERB
  # REACHABILITY over emitted sites. Two different populations behind one word inside one
  # instrument makes both unreadable, and the drift arms compare on those names.
  #
  # THE KEY IS THE QUAD {method, path, module, action}, AND IT IS MUTATION-PROVEN
  # (PDS-D539). Planting a synthetic write route onto an ALREADY-DISPOSED pair moves a
  # {module, action} key from N to N — the arrival is STRUCTURALLY INVISIBLE, and a new
  # route to an existing controller action is the single most likely real-world change.
  # The quad moves N to N+1 and the arm fires. The selftest fixture carries TWO routes to
  # ONE pair for exactly this reason, so the key is asked to discriminate on every run.
  #
  # BUILD-FREE, LIKE EVERYTHING ELSE HERE (PDS-D540). Derived from the AST of router.ex
  # unioned with the plugin route specs — never from a compiled Phoenix route table. This
  # script boots no app (7-14 s against ~7 min on a cold _build), and Phoenix 1.8.9's
  # route map carries no `pipe_through` key anyway. Two shapes force the AST regardless:
  # several route calls in router.ex are MULTILINE, so a single-line grep undercounts them
  # silently, and `Barkpark.Plugins.OnixEdit.register_routes/1` DELEGATES to
  # `OnixEdit.Routes.all/0`, so a literal-tuple grep over plugins/*.ex returns ZERO routes
  # for onixedit. Both are resolved below.
  @router_path "api/lib/barkpark_web/router.ex"
  @plugin_dir "api/lib/barkpark/plugins/"
  @routed_write_methods ~w(post put patch delete)a
  @routed_live_method :live

  # ROUTE-GENERATING MACROS. `plugin_routes/1` this lens RESOLVES (it reads the plugin
  # specs and mounts them); everything else it can only NAME. A macro whose expansion
  # lives in a dependency is a blind shape by construction for a script that never
  # compiles, and a lens that does not print its own blind shapes is propaganda.
  @routed_macros [:plugin_routes, :live_dashboard, :forward, :resources]
  @routed_resolved_macro :plugin_routes

  # DISPOSITION CLASSES — written prose, dated, one per class rather than one per row.
  # A class is what a human decided about a SHAPE; the rows below pin WHICH members that
  # decision covers, and the quad is what makes an arrival visible.
  @routed_exclusion_classes %{
    liveview_handle_event:
      "2026-08-02 (PDS wave 38): a LiveView route names {Module, :action-or-nil} and its writes live in handle_event/3, so there is no {Controller, action} pair for the receipt register to key on. EXCLUDED because this lens structurally cannot judge it — printed with its count so the exclusion is a fact and not a silence.",
    status_only_receipt:
      "2026-08-02 (PDS wave 40, correcting wave 38): the routed action reaches no `ok: true` / `\"ok\" => true` receipt THIS LENS keys on, and carries no roster anchor. THAT IS THE WHOLE CLAIM. Wave 38 also wrote that such a row \"claims success by STATUS alone\", and wave 40 MEASURED that: it is false for most of this class's own members, which do render the stored row and simply do not spell the key the lens greps for. That clause is RETIRED here; what each row's receipt actually does is the DERIVATION PARTITION printed below, class by class, with the producing call named for every row. THIS IS STILL THE POPULATION HOLE wave 38 named: SCIM's three IdP write routes land here. The register's completeness claim never covered these; now they are COUNTED, and now they are PARTITIONED.",
    # `action_not_in_corpus` IS RETIRED (PDS wave 40). It held exactly two rows, both
    # Sheets routes whose module reads `"?"` only because register_routes/1 binds the
    # controller to a LOCAL VARIABLE — the defs were in the corpus the whole time, so the
    # class's own prose ("resolves to no def under api/lib") was checkably untrue of every
    # member it had. inline_alias_bindings/1 resolves them; both rows are now JUDGED and
    # the class has no members. A disposition class whose prose no longer describes
    # anything is deleted rather than kept warm for a member that may never arrive.
    selftest_fixture:
      "2026-08-02 (PDS wave 38): a synthetic member that exists ONLY in the --selftest corpus (module Barkpark.Filler.M1, written by write_corpus!/2 and absent from the real tree). Carried on purpose: without a committed row the row->member direction of ROUTED-POPULATION-COMPLETE has nothing to go red on, and the TWO rows share one {module, action} pair so the quad key is asked to discriminate on every selftest run."
  }

  # THE DISPOSITION TABLE. `{method, path, module, action, class}` — committed data, the
  # same shape as @register and @roster, generated from the live derivation and then read
  # back. Rows whose module this corpus does not carry are OUT OF SCOPE, never a red: a
  # disposition naming a module nobody can open judges nothing either way.
  @routed_excluded [
    # THE FOUR MEMBER-ADMIN ARRIVALS (workspace roster surface). Each returns a
    # DB-derived body — the persisted membership row, or the `revoked_at` the
    # update stamped — but none emits the `ok: true` / `"ok" => true` literal
    # THIS LENS keys on, and none carries a roster anchor, which is exactly what
    # `status_only_receipt` names. Classified by the arriving change, not judged
    # by it: the register/roster verdicts are the census owner's to derive.
    {:post, "/w/:workspace_slug/p/:project_slug/v1/members", "BarkparkWeb.MemberController", :create, :status_only_receipt},
    {:patch, "/w/:workspace_slug/p/:project_slug/v1/members/:principal_ref", "BarkparkWeb.MemberController", :update, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/members/:principal_ref", "BarkparkWeb.MemberController", :delete, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/tokens/:id", "BarkparkWeb.MemberController", :revoke_token, :status_only_receipt},
    {:post, "/v1/selftest-fixture-close", "Barkpark.Filler.M1", :noop, :selftest_fixture},
    {:post, "/v1/selftest-departure-anchor", "Barkpark.Filler.M1", :noop, :selftest_fixture},
    # THE LIVE ROUTE THE WAVE-42 FIXTURE ADDS. MANDATORY, not decorative: `live` is a
    # ROUTED-WRITE method, so without this row every --selftest run exits 1 on
    # `FAIL ROUTED-POPULATION-COMPLETE … UNDISPOSED ARRIVAL live /studio/fixture`. That
    # is the disposition table refusing an arrival, NOT guard_corpus!/1 (which never
    # refuses on this), and it fires whether or not the named module is written.
    {:live, "/studio/fixture", "Barkpark.Filler.FixtureLive", nil, :selftest_fixture},
    # THE FOUR PLUGIN-MOUNT ARRIVALS THE WAVE-43 FIXTURE ADDS. Three are MOUNTED (the
    # fixture plugin's three live specs, joined onto their auth bucket's callsite) and one
    # is the literal sessionless route for the module the `?` spec cannot name. Same
    # contract as the row above: `live` is a ROUTED-WRITE method, so each is an arrival
    # ROUTED-POPULATION-COMPLETE reds on until it is disposed — and each names a module
    # (or, for the declining spec, a non-module `?`) that the REAL tree does not carry, so
    # all four are OUT OF SCOPE there rather than orphans.
    {:live, "/plugins/ops-live", "Barkpark.Filler.PluginOpsLive", :index, :selftest_fixture},
    {:live, "/plugins/api-live", "Barkpark.Filler.PluginLooseLive", :index, :selftest_fixture},
    {:live, "/plugins/var-live", "?", :index, :selftest_fixture},
    {:live, "/plugins/loose-var", "Barkpark.Filler.PluginVarLive", nil, :selftest_fixture},
    # THE SIX ECHO FIXTURE ROWS (PDS wave 40). Classed `status_only_receipt` ON PURPOSE:
    # that is the class the derivation partition reads, and these six exist so the
    # partition's request_echo verdict can be observed firing — and, on the `:repaired`
    # corpus, observed NOT firing. Barkpark.Filler.EchoController exists ONLY in the
    # selftest corpora, so in the real tree these rows name a module this corpus does not
    # carry and are OUT OF SCOPE, never a red (the same contract the two rows above ride).
    {:delete, "/v1/echo/asset/:id", "Barkpark.Filler.EchoController", :delete_asset, :status_only_receipt},
    {:delete, "/v1/echo/document/:id", "Barkpark.Filler.EchoController", :delete_document, :status_only_receipt},
    {:delete, "/v1/echo/schema/:name", "Barkpark.Filler.EchoController", :delete_schema, :status_only_receipt},
    {:delete, "/v1/echo/share-link/:id", "Barkpark.Filler.EchoController", :revoke_share_link, :status_only_receipt},
    {:delete, "/v1/echo/share-token/:token_id", "Barkpark.Filler.EchoController", :revoke_share_token, :status_only_receipt},
    {:delete, "/v1/echo/webhook/:id", "Barkpark.Filler.EchoController", :delete_webhook, :status_only_receipt},
    {:delete, "/api/documents/:type/:id", "BarkparkWeb.LegacyController", :delete, :status_only_receipt},
    {:delete, "/api/workspaces/:workspace_slug", "BarkparkWeb.WorkspaceController", :delete, :status_only_receipt},
    {:delete, "/media/:id", "BarkparkWeb.MediaController", :delete, :status_only_receipt},
    {:delete, "/v1/access/:id", "BarkparkWeb.AccessController", :revoke, :status_only_receipt},
    {:delete, "/v1/auth/app-tokens", "BarkparkWeb.AppTokenController", :delete, :status_only_receipt},
    {:delete, "/v1/auth/app-tokens/current", "BarkparkWeb.AppTokenController", :delete_current, :status_only_receipt},
    {:delete, "/v1/fleet/support-tokens/:token_id", "BarkparkWeb.FleetSupportTokenController", :delete, :status_only_receipt},
    {:delete, "/v1/media/:dataset/:id", "BarkparkWeb.V1.MediaController", :delete, :status_only_receipt},
    {:delete, "/v1/media/:dataset/collections/:id/members/:asset_id", "BarkparkWeb.V1.MediaCollectionsController", :remove_member, :status_only_receipt},
    {:delete, "/v1/media/:dataset/collections/:id/share", "BarkparkWeb.V1.MediaCollectionsController", :revoke_share, :status_only_receipt},
    {:delete, "/v1/plugins/tickets/keys/:id", "BarkparkWeb.TicketKeysController", :delete, :status_only_receipt},
    {:delete, "/v1/schemas/:dataset/:name", "BarkparkWeb.SchemaController", :delete, :status_only_receipt},
    {:delete, "/v1/shares", "BarkparkWeb.ShareController", :delete, :status_only_receipt},
    {:delete, "/v1/shares/links/:id", "BarkparkWeb.ShareLinkController", :revoke, :status_only_receipt},
    {:delete, "/v1/shares/tokens/:token_id", "BarkparkWeb.ShareController", :revoke_token, :status_only_receipt},
    {:delete, "/v1/webhooks/:dataset/:id", "BarkparkWeb.WebhookController", :delete, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/:id", "BarkparkWeb.V1.MediaController", :delete, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/collections/:id/members/:asset_id", "BarkparkWeb.V1.MediaCollectionsController", :remove_member, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/collections/:id/share", "BarkparkWeb.V1.MediaCollectionsController", :revoke_share, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/plugins/tickets/keys/:id", "BarkparkWeb.TicketKeysController", :delete, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/schemas/:dataset/:name", "BarkparkWeb.SchemaController", :delete, :status_only_receipt},
    {:delete, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id", "BarkparkWeb.WebhookController", :delete, :status_only_receipt},
    {:delete, "/w/:workspace_slug/v1/chat-hosts/:id", "BarkparkWeb.ChatHostController", :revoke, :status_only_receipt},
    {:live, "/admin/fleet", "Barkpark.Plugins.Tasks.Web.FleetLive", :index, :liveview_handle_event},
    {:live, "/admin/github", "Barkpark.Plugins.Github.Web.OpsLive", :index, :liveview_handle_event},
    {:live, "/admin/onixedit/bokbasen", "Barkpark.Plugins.OnixEdit.Web.BokbasenLive", :index, :liveview_handle_event},
    {:live, "/admin/onixedit/staleness", "Barkpark.Plugins.OnixEdit.Web.StalenessLive", :index, :liveview_handle_event},
    {:live, "/admin/projects", "Barkpark.Plugins.Tasks.Web.BoardLive", :index, :liveview_handle_event},
    {:live, "/admin/pulse", "Barkpark.Plugins.Pulse.Web.DashboardLive", :index, :liveview_handle_event},
    {:live, "/d/:dataset/papers/:slug", "BarkparkWeb.BulldocsLive", :index, :liveview_handle_event},
    {:live, "/finder", "BarkparkWeb.FinderLive", :index, :liveview_handle_event},
    {:live, "/papers/:slug", "BarkparkWeb.BulldocsLive", :index, :liveview_handle_event},
    {:live, "/quiz/host/:pin", "BarkparkWeb.QuizHostLive", :index, :liveview_handle_event},
    {:live, "/quiz/play/:pin", "BarkparkWeb.QuizPlayLive", :index, :liveview_handle_event},
    {:live, "/sheets/:slug", "BarkparkWeb.SheetsReaderLive", :index, :liveview_handle_event},
    {:live, "/studio/chat", "BarkparkWeb.Studio.ChatLive", nil, :liveview_handle_event},
    {:live, "/studio/chat/:session_id", "BarkparkWeb.Studio.ChatLive", nil, :liveview_handle_event},
    {:live, "/studio/onixedit/ping", "Barkpark.Plugins.OnixEdit.PingLive", :index, :liveview_handle_event},
    {:live, "/studio/org-admin", "BarkparkWeb.Studio.OrgAdminLive", nil, :liveview_handle_event},
    {:live, "/studio/styleguide", "BarkparkWeb.Studio.StyleguideLive", nil, :liveview_handle_event},
    {:live, "/studio/styleguide/swatch", "BarkparkWeb.Studio.SwatchLive", nil, :liveview_handle_event},
    {:live, "/studio/tickets", "Barkpark.Plugins.Tickets.InboxLive", :index, :liveview_handle_event},
    {:live, "/studio/tmux", "BarkparkWeb.Studio.TmuxLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/fleet", "Barkpark.Plugins.Tasks.Web.FleetLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/github", "Barkpark.Plugins.Github.Web.OpsLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/onixedit/bokbasen", "Barkpark.Plugins.OnixEdit.Web.BokbasenLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/onixedit/staleness", "Barkpark.Plugins.OnixEdit.Web.StalenessLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/projects", "Barkpark.Plugins.Tasks.Web.BoardLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/admin/pulse", "Barkpark.Plugins.Pulse.Web.DashboardLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio", "BarkparkWeb.Studio.StudioLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/*path", "BarkparkWeb.Studio.StudioLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/_plugins", "BarkparkWeb.Admin.PluginsLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/_plugins/:plugin/settings", "BarkparkWeb.Admin.PluginSettingsLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/api-tester", "BarkparkWeb.Studio.ApiTesterLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/media", "BarkparkWeb.Studio.MediaLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/papers/:slug", "BarkparkWeb.BulldocsLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/chat", "BarkparkWeb.Studio.ChatLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/chat-hosts", "BarkparkWeb.Studio.ChatHostsLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/chat/:session_id", "BarkparkWeb.Studio.ChatLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/connectors", "BarkparkWeb.Studio.ConnectorsLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/onixedit/ping", "Barkpark.Plugins.OnixEdit.PingLive", :index, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/settings", "BarkparkWeb.Studio.SettingsLive", nil, :liveview_handle_event},
    {:live, "/w/:workspace_slug/p/:project_slug/studio/tickets", "Barkpark.Plugins.Tickets.InboxLive", :index, :liveview_handle_event},
    {:patch, "/scim/v2/Groups/:id", "BarkparkWeb.ScimGroupsController", :update, :status_only_receipt},
    {:patch, "/scim/v2/Users/:id", "BarkparkWeb.ScimUsersController", :update, :status_only_receipt},
    {:patch, "/v1/chat/sessions/:id", "BarkparkWeb.ChatController", :update, :status_only_receipt},
    {:patch, "/v1/media/:dataset/:id", "BarkparkWeb.V1.MediaController", :update, :status_only_receipt},
    {:patch, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/:id", "BarkparkWeb.V1.MediaController", :update, :status_only_receipt},
    {:post, "/api/documents/:type", "BarkparkWeb.LegacyController", :create, :status_only_receipt},
    # BPML validate-all dry-run (masterplan W0): a POST that deliberately moves NO
    # state — it renders {valid, violations}, a receipt richer than `ok: true` but
    # not the spelling this lens keys on, and there is no stored row a test could
    # read back because nothing is stored. Exactly the class prose's case.
    {:post, "/v1/plugins/bulldocs/papers/validate", "BarkparkWeb.BulldocsIngestController",
     :validate, :status_only_receipt},
    # BPML working-copy sync (masterplan W3): renders real `ok: true` receipts, but
    # they live in sync_apply/6 → sync_persist/6 — one and two helpers below the
    # routed action, past the register's stated ONE-HOP relation. The class prose's
    # literal case: the receipt exists and "does not spell the key [where] the lens
    # greps". The sync cycle IS read back end-to-end in
    # bulldocs_bpml_api_test.exs ("pull, edit the file, push, converge").
    {:post, "/v1/plugins/bulldocs/papers/:slug/sync", "BarkparkWeb.BulldocsIngestController",
     :sync, :status_only_receipt},
    {:post, "/api/playground", "BarkparkWeb.PlaygroundController", :provision, :status_only_receipt},
    {:post, "/api/workspaces", "BarkparkWeb.WorkspaceController", :create, :status_only_receipt},
    {:post, "/api/workspaces/:workspace_slug/import", "BarkparkWeb.WorkspaceController", :import, :status_only_receipt},
    {:post, "/api/workspaces/:workspace_slug/projects", "BarkparkWeb.WorkspaceController", :create_project, :status_only_receipt},
    {:post, "/auth/reset/:token", "BarkparkWeb.SessionController", :reset_submit, :status_only_receipt},
    {:post, "/login", "BarkparkWeb.SessionController", :create, :status_only_receipt},
    {:post, "/login/account", "BarkparkWeb.SessionController", :account, :status_only_receipt},
    {:post, "/login/magic", "BarkparkWeb.SessionController", :magic_request, :status_only_receipt},
    {:post, "/login/mfa", "BarkparkWeb.SessionController", :mfa, :status_only_receipt},
    {:post, "/login/reset", "BarkparkWeb.SessionController", :reset_request, :status_only_receipt},
    {:post, "/media/upload", "BarkparkWeb.MediaController", :upload, :status_only_receipt},
    {:post, "/scim/v2/Groups", "BarkparkWeb.ScimGroupsController", :create, :status_only_receipt},
    {:post, "/scim/v2/Users", "BarkparkWeb.ScimUsersController", :create, :status_only_receipt},
    {:post, "/v1/access", "BarkparkWeb.AccessController", :mint, :status_only_receipt},
    {:post, "/v1/access/claim", "BarkparkWeb.AccessController", :claim, :status_only_receipt},
    {:post, "/v1/admin/rollback", "BarkparkWeb.SelfUpdateController", :rollback, :status_only_receipt},
    {:post, "/v1/admin/site-deploy", "BarkparkWeb.SiteDeployController", :trigger, :status_only_receipt},
    {:post, "/v1/auth/app-tokens", "BarkparkWeb.AppTokenController", :create, :status_only_receipt},
    {:post, "/v1/auth/login", "BarkparkWeb.AuthController", :login, :status_only_receipt},
    {:post, "/v1/auth/login-tickets", "BarkparkWeb.LoginTicketController", :create, :status_only_receipt},
    {:post, "/v1/auth/magic-login", "BarkparkWeb.AuthController", :magic_login, :status_only_receipt},
    {:post, "/v1/auth/mfa/enroll", "BarkparkWeb.AuthController", :mfa_enroll, :status_only_receipt},
    {:post, "/v1/auth/register", "BarkparkWeb.AuthController", :register, :status_only_receipt},
    {:post, "/v1/auth/saml/:org_slug/slo", "BarkparkWeb.SamlController", :slo, :status_only_receipt},
    {:post, "/v1/auth/sso/route", "BarkparkWeb.SsoRoutingController", :route, :status_only_receipt},
    {:post, "/v1/auth/tokens", "BarkparkWeb.AuthController", :create_token, :status_only_receipt},
    {:post, "/v1/auth/webauthn/login", "BarkparkWeb.WebauthnController", :login, :status_only_receipt},
    {:post, "/v1/auth/webauthn/login/challenge", "BarkparkWeb.WebauthnController", :login_challenge, :status_only_receipt},
    {:post, "/v1/auth/webauthn/register/challenge", "BarkparkWeb.WebauthnController", :register_challenge, :status_only_receipt},
    {:post, "/v1/auth/webauthn/step-up/challenge", "BarkparkWeb.WebauthnController", :step_up_challenge, :status_only_receipt},
    {:post, "/v1/chat-host/enroll", "BarkparkWeb.ChatHostController", :enroll, :status_only_receipt},
    {:post, "/v1/chat-host/heartbeat", "BarkparkWeb.ChatHostController", :heartbeat, :status_only_receipt},
    {:post, "/v1/chat-host/rotate", "BarkparkWeb.ChatHostController", :rotate, :status_only_receipt},
    {:post, "/v1/chat/sessions", "BarkparkWeb.ChatController", :create, :status_only_receipt},
    {:post, "/v1/chat/sessions/:id/archive", "BarkparkWeb.ChatController", :archive, :status_only_receipt},
    {:post, "/v1/chat/sessions/:id/state", "BarkparkWeb.ChatHostController", :report_state, :status_only_receipt},
    {:post, "/v1/chat/sessions/:id/unarchive", "BarkparkWeb.ChatController", :unarchive, :status_only_receipt},
    {:post, "/v1/cycles/:epic_id/:wave_id/assignments", "BarkparkWeb.CycleFleetController", :create_assignment, :status_only_receipt},
    {:post, "/v1/cycles/:epic_id/:wave_id/assignments/:assignment_id/results", "BarkparkWeb.CycleFleetController", :create_result, :status_only_receipt},
    {:post, "/v1/cycles/:epic_id/:wave_id/open", "BarkparkWeb.CycleFleetController", :open, :status_only_receipt},
    {:post, "/v1/cycles/:epic_id/:wave_id/seal", "BarkparkWeb.CycleFleetController", :seal, :status_only_receipt},
    {:post, "/v1/data/mutate/:dataset", "BarkparkWeb.MutateController", :mutate, :status_only_receipt},
    {:post, "/v1/data/revision/:dataset/:id/restore", "BarkparkWeb.HistoryController", :restore, :status_only_receipt},
    {:post, "/v1/data/search/:dataset/correction", "BarkparkWeb.SearchController", :correction, :status_only_receipt},
    {:post, "/v1/data/search/:dataset/synonyms", "BarkparkWeb.SearchController", :create_search_synonym, :status_only_receipt},
    {:post, "/v1/data/search/:dataset/synonyms/promote", "BarkparkWeb.SearchController", :promote_search_synonym, :status_only_receipt},
    {:post, "/v1/fleet/support-tokens", "BarkparkWeb.FleetSupportTokenController", :create, :status_only_receipt},
    {:post, "/v1/media/:dataset/:id/checkout", "BarkparkWeb.V1.MediaController", :checkout, :status_only_receipt},
    {:post, "/v1/media/:dataset/:id/undo-checkout", "BarkparkWeb.V1.MediaController", :undo_checkout, :status_only_receipt},
    {:post, "/v1/media/:dataset/collections/:id/members", "BarkparkWeb.V1.MediaCollectionsController", :add_member, :status_only_receipt},
    {:post, "/v1/media/:dataset/collections/:id/share", "BarkparkWeb.V1.MediaCollectionsController", :share, :status_only_receipt},
    {:post, "/v1/media/:dataset/processing/:id/callback", "BarkparkWeb.V1.MediaProcessingController", :callback, :status_only_receipt},
    {:post, "/v1/media/:dataset/search/synonyms", "BarkparkWeb.V1.MediaController", :create_search_synonym, :status_only_receipt},
    {:post, "/v1/media/:dataset/search/synonyms/promote", "BarkparkWeb.V1.MediaController", :promote_search_synonym, :status_only_receipt},
    {:post, "/v1/media/:dataset/upload", "BarkparkWeb.V1.MediaController", :upload, :status_only_receipt},
    {:post, "/v1/plugins/tickets/keys", "BarkparkWeb.TicketKeysController", :create, :status_only_receipt},
    {:post, "/v1/plugins/tickets/keys/:id/pause", "BarkparkWeb.TicketKeysController", :pause, :status_only_receipt},
    {:post, "/v1/plugins/tickets/keys/:id/rotate", "BarkparkWeb.TicketKeysController", :rotate, :status_only_receipt},
    {:post, "/v1/plugins/tickets/keys/:id/unpause", "BarkparkWeb.TicketKeysController", :unpause, :status_only_receipt},
    {:post, "/v1/schemas/:dataset", "BarkparkWeb.SchemaController", :upsert, :status_only_receipt},
    {:post, "/v1/shares", "BarkparkWeb.ShareController", :create, :status_only_receipt},
    {:post, "/v1/shares/links", "BarkparkWeb.ShareLinkController", :mint, :status_only_receipt},
    {:post, "/v1/shares/tokens", "BarkparkWeb.ShareController", :mint_token, :status_only_receipt},
    {:post, "/v1/status/incidents", "BarkparkWeb.StatusController", :create_incident, :status_only_receipt},
    {:post, "/v1/status/incidents/:id/resolve", "BarkparkWeb.StatusController", :resolve_incident, :status_only_receipt},
    {:post, "/v1/tickets/:id/attachments", "BarkparkWeb.TicketsAttachmentsController", :create, :status_only_receipt},
    {:post, "/v1/webhooks/:dataset", "BarkparkWeb.WebhookController", :create, :status_only_receipt},
    {:post, "/v1/webhooks/:dataset/:id/deliveries/:event_id/replay", "BarkparkWeb.WebhookController", :replay, :status_only_receipt},
    {:post, "/v1/webhooks/:dataset/:id/reenable", "BarkparkWeb.WebhookController", :reenable, :status_only_receipt},
    {:post, "/v1/webhooks/:dataset/:id/rotate", "BarkparkWeb.WebhookController", :rotate, :status_only_receipt},
    {:post, "/v1/webhooks/:dataset/:id/test-send", "BarkparkWeb.WebhookController", :test_send, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/chat/tokens", "BarkparkWeb.ChatTokenController", :create, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/assignments", "BarkparkWeb.CycleFleetController", :create_assignment, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/assignments/:assignment_id/results", "BarkparkWeb.CycleFleetController", :create_result, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/open", "BarkparkWeb.CycleFleetController", :open, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/promote", "BarkparkWeb.CycleFleetController", :promote, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/quarantine", "BarkparkWeb.CycleFleetController", :quarantine, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/release-gates/:release_gate_id/activate", "BarkparkWeb.CycleFleetController", :activate_release_gate, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/release-gates/:release_gate_id/papers/:role/stage", "BarkparkWeb.CycleFleetController", :stage_release_paper, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/release-gates/open", "BarkparkWeb.CycleFleetController", :admit_open_release_gate, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/rollback", "BarkparkWeb.CycleFleetController", :rollback, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/seal", "BarkparkWeb.CycleFleetController", :seal, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset", "BarkparkWeb.MutateController", :mutate, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/data/revision/:dataset/:id/restore", "BarkparkWeb.HistoryController", :restore, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/data/search/:dataset/correction", "BarkparkWeb.SearchController", :correction, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/data/search/:dataset/synonyms", "BarkparkWeb.SearchController", :create_search_synonym, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/:id/checkout", "BarkparkWeb.V1.MediaController", :checkout, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/:id/undo-checkout", "BarkparkWeb.V1.MediaController", :undo_checkout, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/collections/:id/members", "BarkparkWeb.V1.MediaCollectionsController", :add_member, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/collections/:id/share", "BarkparkWeb.V1.MediaCollectionsController", :share, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/search/synonyms", "BarkparkWeb.V1.MediaController", :create_search_synonym, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/media/:dataset/upload", "BarkparkWeb.V1.MediaController", :upload, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/plugins/tickets/keys", "BarkparkWeb.TicketKeysController", :create, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/plugins/tickets/keys/:id/pause", "BarkparkWeb.TicketKeysController", :pause, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/plugins/tickets/keys/:id/rotate", "BarkparkWeb.TicketKeysController", :rotate, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/plugins/tickets/keys/:id/unpause", "BarkparkWeb.TicketKeysController", :unpause, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/schemas/:dataset", "BarkparkWeb.SchemaController", :upsert, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/tokens", "BarkparkWeb.TokenController", :create, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset", "BarkparkWeb.WebhookController", :create, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id/deliveries/:event_id/replay", "BarkparkWeb.WebhookController", :replay, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id/reenable", "BarkparkWeb.WebhookController", :reenable, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id/rotate", "BarkparkWeb.WebhookController", :rotate, :status_only_receipt},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id/test-send", "BarkparkWeb.WebhookController", :test_send, :status_only_receipt},
    {:post, "/w/:workspace_slug/v1/chat-hosts/enrollments", "BarkparkWeb.ChatHostController", :create_enrollment, :status_only_receipt},
    {:put, "/api/workspaces/:workspace_slug/media/blob/*path", "BarkparkWeb.MediaController", :put_blob, :status_only_receipt},
    {:put, "/scim/v2/Groups/:id", "BarkparkWeb.ScimGroupsController", :replace, :status_only_receipt},
    {:put, "/scim/v2/Users/:id", "BarkparkWeb.ScimUsersController", :replace, :status_only_receipt},
    {:put, "/v1/data/search/:dataset/settings", "BarkparkWeb.SearchController", :update_search_settings, :status_only_receipt},
    {:put, "/v1/media/:dataset/search/settings", "BarkparkWeb.V1.MediaController", :update_search_settings, :status_only_receipt},
    {:put, "/v1/webhooks/:dataset/:id", "BarkparkWeb.WebhookController", :update, :status_only_receipt},
    {:put, "/w/:workspace_slug/p/:project_slug/v1/webhooks/:dataset/:id", "BarkparkWeb.WebhookController", :update, :status_only_receipt}
  ]

  # ------------------------------------------------------------- declared register
  #
  # COMMITTED DATA, NOT A SUPPRESSION SWITCH (PDS wave 35). A site lands here only with a
  # BASIS the reader can open — a line span in the source that says, in prose, that the
  # receipt deliberately does not track an outcome. The field value is `declared`, the
  # spelling already shipping in `internal/cli/hetzner_respost.go:197`
  # (`hzKeyConfirmation: "declared"` beside `hzKeyConfirmBasis`), because a confirmation
  # level that exists in one surface must not be re-invented with a new name in another.
  #
  # WHAT THE REGISTER IS FOR. Exactly one row suppresses anything today
  # (github_webhook_controller.ex:87, the one site the CATCH-ALL-TO-SUCCESS arm fires on
  # whose body NAMES its outcome). The other four are DOCUMENTATION: they record that a
  # human read the code and found the receipt honest, so the next lens that starts firing
  # on them meets a written basis instead of an argument.
  #
  # `route_claim` IS ORTHOGONAL TO `class`, DELIBERATELY. route_tag/1 and evidence/3 read
  # `site.write?` / `site.depth` and NEVER the shape, so no value in the shape vocabulary
  # can retract a false route bracket. A site whose route bracket is wrong says so here.
  @declared [
    %{
      key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.request_reset/2", "37852989", "17468236"},
      basis_spans: [{501, 501}],
      basis_token: "never reveal whether the email is registered",
      class: "NO-OP-ACK",
      confirmation: "declared",
      basis:
        "inline comment :483 — \"Always 200 — never reveal whether the email is registered.\" " <>
          "RE-ANCHORED off :439 on the self-service-PAT-mint lane (PR #14245): that PR inserts " <>
          "the PAT workspace-binding code above this def, pushing every line below down by 44 — " <>
          "the span slid, the comment did not move relative to the def. RE-ANCHORED again off " <>
          ":483 on the PAT admin-mint cap lane (PR #14933): the workspace-binding resolver above " <>
          "this def grew by 18 lines — +18, the comment still sits on the def's first body line.",
      why:
        "anti-enumeration. Route WRITE d1 — and the receipt asserts nothing ABOUT that write, " <>
          "which is precisely why it is honest. (It is NOT a \"no write\" site: request_reset " <>
          "does write a reset token when the address resolves.)"
    },
    %{
      key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.request_magic_link/2", "15394828", "17468236"},
      basis_spans: [{516, 521}],
      basis_token: "anti-enumeration",
      class: "NO-OP-ACK",
      confirmation: "declared",
      basis:
        "@doc :498-503, the anti-enumeration sentence at :499-502 (the token `anti-enumeration` on :501). " <>
          "RE-ANCHORED off #{448} on the withheld-census-baseline lane (api-controller-silent-withholds/" <>
          "trace-skipped-notifications, PR #13902): that PR inserts a NotificationWithhold.record/2 " <>
          "else-branch above request_reset/2's json/2 call, pushing every line below down by 6 — the " <>
          "span slid, the sentence did not move relative to the def. RE-ANCHORED again off :454-459 " <>
          "on the self-service-PAT-mint lane (PR #14245): +44 lines inserted above the span. " <>
          "RE-ANCHORED again off :498-503 on the PAT admin-mint cap lane (PR #14933): +18 lines " <>
          "inserted above (the token `anti-enumeration` now on :519).",
      why:
        "anti-enumeration, request_magic_link/2. THE SPAN IS THE FIX: charter PDS-D465 cites " <>
          ":406-410, which is the sentence's tail fragment, the closing triple-quote and the def " <>
          "line — no anti-enumeration text in it; PDS-D453b cites :410-417, which is pure code. " <>
          "Both are phantom bases. This row SUPPRESSES NOTHING — the site's ok:true sits at :523, " <>
          "after the case closes at :521, so no clause contains it and no shipping configuration " <>
          "of the arm can fire on it. It is registered as documentation of a control the lens " <>
          "wrongly accused for two waves."
    },
    %{
      key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.receive/2", "115025520", "17468236"},
      basis_spans: [{74, 78}],
      basis_token: "always answers 2xx unless intake genuinely",
      class: "NO-OP-ACK",
      confirmation: "declared",
      basis: "@doc :74-78 — \"always answers 2xx unless intake genuinely fails\"",
      why:
        "the `\"ping\"` clause head is a literal match, not a failure-discarding head, so the arm " <>
          "never fires here. A ping ack claims nothing beyond having been reached."
    },
    %{
      key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.receive/2", "115025520", "105570378"},
      basis_spans: [{74, 78}, {87, 87}],
      basis_token: "ignored:",
      class: "CATCH-ALL-TO-SUCCESS",
      confirmation: "declared",
      basis: "the response body itself — `ignored: \"event\"` on :87, plus @doc :74-78",
      why:
        "THE ONE ROW THAT ACTUALLY SUPPRESSES. The arm fires here (head `_other`, body renders " <>
          "ok: true, site contained), and it is right to: this IS a catch-all routed to success. " <>
          "It is declared because the body NAMES the outcome — the caller is told the event was " <>
          "ignored, so the receipt does not pass an unhandled event off as handled work."
    },
    %{
      key: {"api/lib/barkpark_web/controllers/bulldocs_form_controller.ex",
            "BarkparkWeb.BulldocsFormController.submit/2", "123699679", "17468236"},
      basis_spans: [{22, 24}, {53, 53}],
      basis_token: "the trap stays invisible",
      class: "HONEYPOT",
      confirmation: "declared",
      route_claim: "ROUTE-MISCREDIT",
      basis:
        "@moduledoc :22-24 (\"bots that fill it get a vacuous 201 (no write) so the trap stays " <>
          "invisible\") and the ONE-LINE inline comment at :53 — not the :52-54 arm span",
      why:
        "declared TWICE, and the only site in the corpus whose honesty depends on the receipt " <>
          "being indistinguishable from the happy one. The `{:honeypot}` head is a literal match, " <>
          "so the arm does not fire. ROUTE-MISCREDIT: the census brackets this `[WRITE d5]` " <>
          "because submit/2 routes to a write on its SUCCESS path — crediting a write to the one " <>
          "arm that provably makes none. The bracket is disputed here because it cannot be " <>
          "retracted from the shape vocabulary: route_tag/1 and evidence/3 read write?/depth only."
    }
  ]

  # ------------------------------------------------------------- judgment register
  #
  # THE JUDGMENT LEDGER (PDS wave 37, task pds-w34-hand-bucket-register). One row per
  # EMITTED success claim, keyed on {path, module.name/arity, head_hash, expr_fp} — CLASS
  # AND LINE BOTH EXCLUDED. It is NOT a bucketing exercise and it asserts NO distribution:
  # REGISTER-COMPLETE checks completeness and integrity, never how the verdicts fall, so
  # no reclassification can red the build.
  #
  # DERIVED AT 501fb9670, off this script's OWN `--keys` emission (91 rows / 91 distinct).
  # Every key here was READ from that TSV, never transcribed by hand.
  #
  # THE KEY LADDER, MEASURED AT THAT SHA — so nobody "simplifies" the key to three fields:
  #     {path, mfa} = 75 distinct · +head_hash = 76 · +expr_fp = 91 · expr_fp ALONE = 67
  # `expr_fp` IS THE LOAD-BEARING FIELD. One fingerprint (17468236, the bare success map
  # with no discriminating key) covers 12 rows across 7 files; inside
  # github_webhook_controller.ex, path+expr_fp alone collapses 14 rows to 12. `head_hash`
  # buys exactly ONE row (75 -> 76) and is CARRIED FOR STABILITY, NOT UNIQUENESS: it
  # survives an edit inside a clause body that re-fingerprints the expression, so a row
  # demoted by basis-stale can still be found. gh:86 and gh:87 share {path, mfa,
  # head_hash} and are separated by expr_fp ALONE.
  #
  # WHAT head_hash CANNOT DISCRIMINATE (scope stated, or a reader believes it is near
  # unique on its own — it is not, and it does not need to be): across all 17,620 defs it
  # collides in exactly 3 buckets WITHIN a {path, module.name/arity} group, and 0 times
  # within the 75 site-owning groups. Only ONE of the three is a benign bodiless
  # declaration head; the other TWO are DISTINCT functions inside two `defimpl Inspect,
  # for: ...` blocks (plugins/github/errors.ex :94/:138, plugins/indx/errors.ex :118/:137)
  # that this walker cannot tell apart. Corpus-wide — ignoring path and mfa — it is 912
  # groups over 2,543 defs under this normaliser (the wave brief recorded 913/2,544 under
  # another spelling; that figure does not survive a spelling change and is not quotable
  # across one).
  #
  # CHURN, MEASURED across the three merges that landed into this sha: 5 orphaned / 5
  # arrived / 86 common, and it was a PURE RE-KEY — the {path, mfa} multiset was
  # byte-identical and only expr_fp moved. Expect ~5.5% of rows to re-key per code slice
  # touching two controllers. `--keys` is C-locale sorted by {path, line}; a consumer that
  # pipes it through `sort` without LC_ALL=C reorders it.
  #
  # THE SENTINEL PREDICATE, NAMED: sentinel-ok@repo-write,def+defp,tail-disjoint /
  # total-meta-drop/phash2-term/v1 / 501fb9670. The 21 function-tail / 11 clause-local
  # figures reproduce ONLY under that four-knob predicate (def+defp clauses with a
  # do-block, a Repo-WRITE verb list, tail = last expression of a __block__, clause-local
  # DISJOINT from function-tail). Dropping the write predicate gives 257/247; public def
  # only gives 15/4; any Repo.* gives 23/18; non-disjoint gives 13.
  #
  # CAS IS A STRICT SUBSET OF POST-READ AT THIS LENS AND THIS SHA — the difference
  # CAS-minus-POST-READ is EMPTY, and POST-READ-minus-CAS is the single site
  # oidc_controller.ex:82. All 14 CAS sites reach POST-READ via ARM 1 (`select:`), zero
  # via ARM 2, and the same function supplies both halves (Internal.fenced_content_write/4
  # x13, BlockOps.fenced_paper_update/4 x1). RECORDED WITH ITS LENS AND SHA, NEVER AS A
  # STANDING INVARIANT: a CAS spelling with no `select:` is describable
  # (pds-bl-cas-int-tuple-spelling-blind) and would break it.
  #
  # -- THE THREE VERDICTS. There are exactly three, and nothing else is admitted.
  #   PROVEN    a committed differential asserts `receipt == stored row`
  #   REFUTED   measured divergent
  #   UNJUDGED  named, WITH THE REASON — thirty honest UNJUDGED beat seventy-four
  #             confident guesses, which is what dissolves the shadowed-bucket problem
  #             instead of trading one shadowed bucket for another.
  #
  # -- THE OPENING BALANCE, STATED SO IT CANNOT BE ROUNDED UP (PDS-D526/D527).
  #   8 rows  PROVEN / end-to-end            mutation-attested; the row carries the line
  #   7 rows  PROVEN / end-to-end-unmutated  ALREADY CONJUNCTIVE in the committed suite,
  #                                          BUT ITS FALSIFIER WAS NEVER EXERCISED — the
  #                                          conjunction was READ, not made to fail
  #   1 tag   PROVEN inside an UNJUDGED row  github_webhook_controller.ex:194's
  #                                          `:already_stamped` tag only (see below)
  # PDS-D526 opened this at 18 (9 + 9). IT CLOSED AT 16, AND THE TWO MISSING ROWS WERE
  # TAKEN BY THIS WAVE'S OWN FALSIFIER, NOT BY AN ARGUMENT: BASIS-FALSIFIERS refused
  # bulldocs_ingest_controller.ex:630 and :715, whose cited tests drive the route and never
  # read the paper back. Both now read UNJUDGED / unjudged_other with the refusal written
  # in the row. THAT IS THE LEDGER WORKING — a wave that could only ever ratify its own
  # brief would be paperwork. Below the line, and NOT part of it: the rows carrying
  # `side_effect_existence_only`, which PDS-D499 maps to UNJUDGED — the cited Repo read
  # asserts an audit row EXISTS, never that the printed field equals the stored one.
  # THE COUNT IS NOT TRANSCRIBED HERE. It is derived at print time from @register (the
  # BASIS DISTRIBUTION block, and the "Below the line" sentence the integrity report
  # prints from `by_basis`) — a hand-typed integer in this comment went stale inside this
  # very wave, because bulldocs_ingest_controller.ex:164 was demoted to `unjudged_other`
  # on the advisory line AFTER the tally was written. The two that remain of the wave's
  # own "weaker still" rows are tasks_controller.ex:1352 and auth_controller.ex:329
  # (which proves session death through a SECOND ENDPOINT); :164's demotion is printed in
  # full in the UNJUDGED-OTHER block.
  #
  # -- THE BASIS VOCABULARY IS CLOSED, AND EACH VALUE CARRIES ITS OWN CHECK. An essay in
  # a reason field is unfalsifiable paperwork; a vocabulary token is a claim a machine can
  # refuse. PROSE IS PERMITTED ON EXACTLY ONE VALUE — `unjudged_other`, where it is
  # REQUIRED, counted, printed, and never reds. @basis_vocab below is the authority.
  # THIS WAVE ADDS FOUR VALUES to PDS-D499's eleven, each mechanically falsifiable:
  #   end_to_end_unmutated   — the distinct token for a conjunction read but not exercised
  #   declared_basis         — the five @declared rows; DECLARED-BASIS-INTACT is its check
  #   partial_tag_coverage   — one emitted site, several rendered receipts (below)
  #   unexamined             — no differential has been READ for this row. It is not a
  #                            euphemism for "probably fine": it is the honest floor, and
  #                            it is what 33 of these 91 rows say.
  #
  # -- MULTI-TAG SITES (PDS-D527). github_webhook_controller.ex:194's clause head is
  # `{:ok, tag, doc_id} when tag in [...]` — ONE emitted site, THREE rendered receipts,
  # and only `:already_stamped` is proven end-to-end. Such a row carries a `tags:`
  # sub-list and THE ROW'S OWN VERDICT IS THE WEAKEST OF THEM. IT IS NOT SPLIT INTO THREE
  # ROWS: three rows would name one emitted site three times and RED REGISTER-COMPLETE's
  # row->site direction, the arm this wave is judged on.
  #
  # -- WHAT THE KEY MIGRATION KILLED, AND WHAT IT DELIBERATELY DID NOT. With one blank
  # line inserted above github_webhook_controller.ex:87 (`perl -i -pe 'print "\n" if
  # $. == 80'` — NOT `sed -i '' '398i\'`, which is a macOS no-op and proves nothing), the
  # {path,line}-keyed spelling prints `1 undeclared of 1 fired` — A FALSE ACCUSATION
  # against a committed basis, at exit 0 — while this one still prints `0 undeclared of 1
  # fired` with only the printed anchor tracking to :88. REGISTER-COMPLETE and
  # DECLARED-ROWS-RESOLVE both stay green through it, because neither joins on a line.
  # DECLARED-BASIS-INTACT correctly REDS, and that is not a residual line dependency worth
  # engineering away: a basis span NAMES PROSE IN A FILE, so it is line-anchored by
  # nature, and the FAIL line carries the row and its recorded span so the fix is one edit.
  # SO THE MUTATION ABOVE ENDS AT RC 1 AND A FAILED CENSUS, AND THAT IS THE PASS.
  # Expected result of a clean re-run, in full, because a reader who sees only the two
  # green arms named above will read the red as a regression this migration caused:
  #   RC 1 · REGISTER-COMPLETE PASS · DECLARED-ROWS-RESOLVE PASS · DECLARED-BASIS-INTACT FAIL
  #     1 declared basis has DRIFTED off its recorded span: github_webhook_controller.ex
  #      BarkparkWeb.GithubWebhookController.receive/2 [CATCH-ALL-TO-SUCCESS] recorded span
  #      :74-78,:87-87 no longer carries the token `ignored:`
  # MEASURED, not predicted — that block is the observed FAIL line, and the baseline it is
  # measured against is this file green at RC 0 with all three arms PASS.
  # Seeing exactly that is a REPRODUCTION of the migration proof, never a refutation of it.
  # The arm was introduced by the same PR as the migration, so the red is this wave's own
  # new instrument firing on the mutation this wave prescribes. Restore the span and it
  # greens; there is nothing to fix in the key.
  #
  # -- NO SCRIPT EVER WRITES A VERDICT. Arms check; they never assign. The one apparent
  # exception is `basis_stale`, and it is not one: a row whose recorded head_hash/expr_fp
  # no longer match is REPORTED as demoted at print time, and the committed row is left
  # exactly as its author wrote it, so the demotion is visible as a diff-free fact rather
  # than an edit nobody reviewed.
  #
  # -- WHAT THE MODULE-LINKAGE CHECK WOULD HAVE COST (PDS-D525). "The cited test
  # references the site's MODULE" reads like the obvious falsifier and it is a FALSE one:
  # `pds_group_c_receipt_differential_test.exs` contains the string `Controller` ZERO
  # times, because conn-driven tests name a URL, not a module — the predicate refuses ALL
  # of this wave's committed PROVEN differentials. Route linkage replaces it and is
  # ADVISORY, never redding, because it is UNCHECKABLE for the 14 github_webhook rows
  # (`GithubWebhookController` appears zero times in router.ex; the routes are
  # macro-generated) and reading the literal alone manufactured three FALSE contradictions
  # against genuine PROVEN rows whose route lives in an enclosing `scope`.
  #
  # -- HOME. In-file, beside @declared, at COMPACT row density (~4.4 lines/row). The
  # 19-lines-per-row @declared shape would have added ~1,730 lines and doubled this
  # script. PROSE LIVES IN THE WAVE PAPER, not here — except `unjudged_other`, where it is
  # required. `.sobelow-skips` is FORBIDDEN as a home: PDS-D141 forbids PDS PRs from
  # editing it, it is this repo's own worked example of a line-keyed register rotting
  # silently, and a judgment register whose rows silence the instrument inverts this
  # epic's law.

  # THE VOCABULARY IS THE AUTHORITY, AND IT IS DATA. {verdict class, falsifier, tier} —
  # `:reds` values are checked by the L2 basis falsifiers and go RED; `:advisory` values
  # print a counted CONTRADICTION line at exit 0, because their falsifier is either
  # undecidable as written or measured to manufacture false accusations.
  @basis_vocab %{
    end_to_end:
      {"PROVEN", "the cited test drives the site's route AND reads the stored row back", :reds},
    end_to_end_unmutated:
      {"PROVEN", "the cited test drives the site's route AND reads the stored row back (mutation NEVER exercised)", :reds},
    two_hop_composed:
      {"UNJUDGED",
       "the cited block or its resolved same-file helpers carry a NAMED persistence-read token (@repo_tokens: `Repo.` · `Content.get_document(` · `Conflicts.list(`)",
       :reds},
    stub_mapping_only:
      {"UNJUDGED", "the cited test has no injection seam, or DOES read Repo", :reds},
    context_differential_only:
      {"UNJUDGED", "the cited test builds a conn", :reds},
    side_effect_existence_only:
      {"UNJUDGED", "the Repo read compares a printed field, not existence", :advisory},
    shape_assertion_only:
      {"UNJUDGED", "the assertion can fail on a wrong payload (implementable ONLY as a denylist of weak predicates — is_list/is_map/is_binary/bare truthiness — so it is advisory, and this name promises more than its code delivers)", :advisory},
    payload_is_the_postcondition:
      {"UNJUDGED", "any emitted value traces to params[...] or a fn head", :advisory},
    request_param_echo:
      {"UNJUDGED", "no emitted value traces to a request parameter", :advisory},
    no_observer:
      {"UNJUDGED", "any test references the site's module OR its route path", :reds},
    basis_stale:
      {"UNJUDGED", "the current head_hash+expr_fp equal the recorded pair", :reds},
    partial_tag_coverage:
      {"UNJUDGED", "every tag in the sub-list carries the same verdict as the row", :advisory},
    declared_basis:
      {"UNJUDGED", "the @declared row's basis span no longer carries its token (DECLARED-BASIS-INTACT)", :advisory},
    unexamined:
      {"UNJUDGED", "a committed test cites this site's route AND reads Repo back", :advisory},
    not_a_receipt:
      {"UNJUDGED", "the site renders a body or a status that makes a claim about work done", :advisory},
    unjudged_other:
      {"UNJUDGED", "PROSE REQUIRED; counted and PRINTED in the integrity block; NEVER reds", :advisory}
  }

  # ---------------------------------------------------------- population roster
  #
  # THE BLIND-SPOT BLOCK USED TO BE THREE SUBSTRING TOTALS (PDS-D524). A total names
  # nobody; this names EIGHT sites outside the `ok: true` lens that report success without
  # a read, each with a verdict from the SAME vocabulary the register uses. It is DISJOINT
  # from the 91 BY SITE, and the distinction matters: zero register keys live in
  # scim_groups / scim_users / session_controller / chat_controller / chat_host_controller,
  # and the ONE shared FILE is pulse_controller.ex, where the register holds create/2 (:58)
  # and this roster names preflight/2 (:93) — a different function. Re-derived here rather
  # than asserted: `cut -f1 keys.tsv | sort -u | grep -E 'scim|session|chat|pulse'` returns
  # pulse_controller.ex and nothing else.
  #
  # EVERY ROW IS ANCHORED ON A LITERAL, NEVER A LINE NUMBER, and the arm asserts
  # EXISTENCE, NEVER A COUNT. Measured over 80 api/lib commits across 9 days the three
  # substring totals moved 7 times (~once per 11 commits, twice on ONE day) and the movers
  # were a papers fence, a credential-scope security fix and a chat-wire feature — a count
  # arm would have redded on unrelated work every week. The roster literals had ZERO drift
  # across all 80.
  #
  # THE TEN "CLASS D" DELETE/REVOKE ECHO SITES ARE NOT ROSTERED (PDS-D523). Every one
  # bottoms out in Repo.delete(_, stale_error_field: :id), Repo.update/1 on one fetched
  # row, or Repo.rollback — they are FALSE ACCUSATIONS, and a roster that carries them
  # would be the over-claiming this census exists to find, pointed the other way.
  #
  # THOSE TWO ROWS WENT STALE EXACTLY AS PREDICTED, AND THE ARM THAT CATCHES IT NOW EXISTS
  # (PDS wave 39). The previous text of this block ended "So the ANCHOR arm cannot catch
  # the staleness; nothing here can." The first half still holds — ROSTER-ANCHORS-EXIST
  # asserts the LITERAL still occurs, and fbc6b80a1 (#8993) repaired both callees while
  # both literals survived byte-for-byte, so that arm printed PASS over two verdicts that
  # had become FALSE. The second half is now wrong, and ROSTER-VERDICT-FRESH is what makes
  # it wrong: every row records the ENCLOSING def it was judged against, as `anchor_mfa`
  # (module.name/arity) and `def_fp` (the same total-meta-drop/phash2 fingerprint the
  # register keys on, taken over that def's head+body). Either one moving DEMOTES the row
  # to UNJUDGED AT PRINT TIME and reds the arm. Nothing here rewrites a verdict in this
  # file — no script ever writes a verdict — so the demotion arrives as a diff-free fact
  # and a human re-derives the row.
  #
  # BOTH GRANULARITIES, BECAUSE EACH IS BLIND WHERE THE OTHER SEES. `def_fp` catches the
  # case that OCCURRED — the body changed under a stable name — and is blind to a
  # body-identical RENAME. `anchor_mfa` catches the rename and is blind to a body edit
  # under a stable name. Neither alone is the arm.
  #
  # THE TWO REFUTED ROWS BELOW WERE RE-DERIVED AGAINST MERGED MAIN in the same wave that
  # shipped the arm, and both are now PROVEN: the callees were widened to report their own
  # outcome and both callers answer over it. The verdicts and notes recorded here are
  # therefore derived at 974d412ca, not at 501fb9670. The rest of the roster is unchanged.
  @roster [
    %{path: "api/lib/barkpark_web/controllers/scim_groups_controller.ex",
      literal: "Scim.delete_group(org, group)",
      anchor_mfa: "BarkparkWeb.ScimGroupsController.delete/2", def_fp: "48311107",
      verdict: "PROVEN", basis: :end_to_end,
      note: "RE-DERIVED at 974d412ca (was REFUTED at 501fb9670, and that verdict outlived its defect by a whole wave). Scim.delete_group/2 (scim.ex:502-516) now returns {:error, :not_found} when Repo.delete_all removed nothing, so {:ok, 0} is UNREACHABLE, and the caller cases on the tag rather than discarding it: {:ok, _n} -> 204, {:error, :not_found} -> a SCIM 404. Driven and read back: scim_groups_controller_test.exs:215 deletes the row out from under the request through a repo telemetry handler, then asserts the 404 AND `refute Repo.get(Group, gid)`."},
    %{path: "api/lib/barkpark_web/controllers/scim_users_controller.ex",
      literal: "Scim.deprovision_user(org, user, hard: true)",
      anchor_mfa: "BarkparkWeb.ScimUsersController.delete/2", def_fp: "19495067",
      verdict: "PROVEN", basis: :end_to_end_unmutated,
      note: "the match is `{:ok, _} =` over a raising Repo.delete! inside a transaction, so a failed deprovision cannot reach the 204."},
    %{path: "api/lib/barkpark_web/controllers/session_controller.ex",
      literal: "Barkpark.Accounts.revoke_user_session_token(token)",
      anchor_mfa: "BarkparkWeb.SessionController.delete/2", def_fp: "94722031",
      verdict: "PROVEN", basis: :end_to_end,
      note: "RE-DERIVED at 974d412ca (was REFUTED at 501fb9670). revoke_user_session_token/1 (accounts.ex:336-347) carries @spec :: {:ok, non_neg_integer()} and returns the Repo.update_all count, the caller binds `{:ok, n} =` and the flash forks on it — sign_out_flash(0) is \"You were already signed out.\" Driven and read back: session_controller_test.exs:129 posts /logout twice and certifies the first flash against the STORED UserSession row's revoked_at, then that the second sign-out leaves that timestamp untouched."},
    %{path: "api/lib/barkpark_web/controllers/chat_controller.ex",
      literal: "StudioChat.update_approval_status(id, request_id, status)",
      anchor_mfa: "BarkparkWeb.ChatController.approval/2", def_fp: "121603508",
      verdict: "UNJUDGED", basis: :unjudged_other,
      note: "both arms of update_approval_status fold to :ok, and answer_approval's result is discarded with `_ =`."},
    %{path: "api/lib/barkpark_web/controllers/chat_controller.ex",
      literal: "persist_user_turn(id, content)",
      anchor_mfa: "BarkparkWeb.ChatController.create_message/2", def_fp: "83487517",
      verdict: "UNJUDGED", basis: :declared_basis,
      note: "a fail-soft persist, declared in the clause comment above it — the send is already on its way, so a persist miss must not turn a live send into an error."},
    %{path: "api/lib/barkpark_web/controllers/chat_controller.ex",
      literal: "json(%{request_id: request_id})",
      anchor_mfa: "BarkparkWeb.ChatController.interrupt/2", def_fp: "23665871",
      verdict: "UNJUDGED", basis: :declared_basis,
      note: "the request_id: nil no-op, declared in the @doc."},
    %{path: "api/lib/barkpark_web/controllers/chat_host_controller.ex",
      literal: "{:ok, :accepted} -> conn |> put_status(:accepted) |> json(",
      anchor_mfa: "BarkparkWeb.ChatHostController.event/2", def_fp: "62380347",
      verdict: "UNJUDGED", basis: :stub_mapping_only,
      note: "re-renders the callee's :accepted tag faithfully; the tag's truth against any stored row is a separate question this row does not answer."},
    %{path: "api/lib/barkpark_web/controllers/pulse_controller.ex",
      literal: "def preflight(conn, _params), do: send_resp(conn, 204,",
      anchor_mfa: "BarkparkWeb.PulseController.preflight/2", def_fp: "131930615",
      verdict: "UNJUDGED", basis: :not_a_receipt,
      note: "a CORS preflight 204 claims nothing about work done. CARRIED ON PURPOSE, so the roster's own completeness is checkable: a roster of only the guilty is indistinguishable from a roster nobody finished."}
  ]

  @register [
    # barkpark/plugins/sheets/web/import_controller.ex:64
    %{key: {"api/lib/barkpark/plugins/sheets/web/import_controller.ex",
            "Barkpark.Plugins.Sheets.Web.ImportController.create/2", "51320322", "13286890"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark/plugins/sheets/web/ops_controller.ex:71
    %{key: {"api/lib/barkpark/plugins/sheets/web/ops_controller.ex",
            "Barkpark.Plugins.Sheets.Web.OpsController.apply_ops/2", "36006285", "87176703"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/app_token_controller.ex:215 — the admin revoke-by-id
    # receipt (jf-backlog-apptoken-revoke-upstream). PROVEN/end_to_end is earned, not
    # asserted: app_token_admin_revoke_test.exs drives DELETE /v1/auth/app-tokens/:id
    # AND reads the store back through Auth.verify_token/1, which enforces revocation in
    # its WHERE clause. Mutation-exercised — making revoke_app_token_by_id/1 a no-op reds
    # "revoking by id actually stops the token authenticating".
    %{key: {"api/lib/barkpark_web/controllers/app_token_controller.ex",
            "BarkparkWeb.AppTokenController.delete_by_id/2", "15384850", "117712781"},
      verdict: "PROVEN", basis: :end_to_end,
      evidence: "api/test/barkpark_web/controllers/app_token_admin_revoke_test.exs:162"},
    # barkpark_web/controllers/auth_controller.ex:177
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.erase/2", "14672314", "70062513"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/auth_controller.ex:214
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.change_password/2", "44848654", "17468236"},
      verdict: "UNJUDGED", basis: :unjudged_other,
      note:
        "AUTHORED, not inherited: PATCH /v1/auth/password is a new door on the existing " <>
        "Accounts.update_user_password/3 primitive. NOT DEMOTED FOR WEAKNESS — the cited " <>
        "suite (auth_password_test.exs:30) is a genuine behavioural end-to-end: it drives " <>
        "the route, then certifies the post-condition through a SECOND route, asserting the " <>
        "old password 401s on /v1/auth/login while the new one 201s, and that the acting " <>
        "session is revoked. What it does not do is read the stored row, and end_to_end's " <>
        "falsifier is spelled as a @repo_tokens hit in the cited block or its same-file " <>
        "helpers, so that basis would be REFUSED here and claiming it would be a lie about " <>
        "the lens, not about the test. The honest sentence: the receipt-vs-STORED-ROW " <>
        "question is unjudged; the receipt-vs-OBSERVABLE-BEHAVIOUR question is answered and " <>
        "answered well. Upgrading this row to end_to_end needs one Repo read of " <>
        "hashed_password beside the existing assertions, not a better argument."},
    # barkpark_web/controllers/auth_controller.ex:329
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.revoke_session/2", "14482306", "17656195"},
      verdict: "UNJUDGED", basis: :side_effect_existence_only, evidence: "api/test/barkpark_web/controllers/auth_controller_test.exs:369"},
    # barkpark_web/controllers/auth_controller.ex:351
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.logout/2", "893943", "17468236"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/auth_controller.ex:351
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.logout/2", "893943", "101485070"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/auth_controller.ex:379
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.verify_email/2", "13273957", "17468236"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/auth_controller.ex:399
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.request_reset/2", "37852989", "17468236"},
      verdict: "UNJUDGED", basis: :declared_basis},
    # barkpark_web/controllers/auth_controller.ex:417
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.request_magic_link/2", "15394828", "17468236"},
      verdict: "UNJUDGED", basis: :declared_basis},
    # barkpark_web/controllers/auth_controller.ex:463
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.reset/2", "117976982", "93237454"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/controllers/pds_w36_revoke_all_receipt_test.exs:64",
      attestation:
        "mutation: hardcode sessionsRevoked — `mix test api/test/barkpark_web/controllers/pds_w36_revoke_all_receipt_test.exs:64` reds on Repo.aggregate",
    },
    # barkpark_web/controllers/auth_controller.ex:528
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.mfa_verify/2", "16615157", "38279071"},
      verdict: "UNJUDGED", basis: :side_effect_existence_only, evidence: "api/test/barkpark_web/controllers/auth_controller_test.exs:463"},
    # barkpark_web/controllers/auth_controller.ex:567
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.mfa_disable/2", "103479204", "17468236"},
      verdict: "UNJUDGED", basis: :side_effect_existence_only, evidence: "api/test/barkpark_web/controllers/auth_controller_test.exs:463"},
    # barkpark_web/controllers/auth_controller.ex:600
    %{key: {"api/lib/barkpark_web/controllers/auth_controller.ex",
            "BarkparkWeb.AuthController.mfa_step_up/2", "85508749", "111398976"},
      verdict: "UNJUDGED", basis: :side_effect_existence_only, evidence: "api/test/barkpark_web/controllers/auth_controller_test.exs:463"},
    # barkpark_web/controllers/bulldocs_form_controller.ex:50
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_form_controller.ex",
            "BarkparkWeb.BulldocsFormController.submit/2", "123699679", "127244318"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/bulldocs_form_controller.ex:54
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_form_controller.ex",
            "BarkparkWeb.BulldocsFormController.submit/2", "123699679", "17468236"},
      verdict: "UNJUDGED", basis: :declared_basis},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:164
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.ingest_blocks/4", "1989150", "124223564"},
      verdict: "UNJUDGED", basis: :unjudged_other,
      note:
        "DEMOTED ON THE ADVISORY LINE. side_effect_existence_only claims a Repo read that asserts EXISTENCE; the cited positive control (bulldocs_ingest_controller_test.exs:319) reads nothing back at all, so it cannot even assert that."},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:244
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.ingest_html/4", "19560303", "124223564"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/bulldocs_ingest_controller_test.exs:97"},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:321
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.ingest_session/2", "11366553", "107043790"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:431
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.apply_session_op/2", "38576492", "88664755"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:502
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.append_session_event/2", "51520286", "61088078"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:551
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.touch_session_conversation/2", "104647366", "61088078"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex — the batch receipt.
    # BPML wave: the batch clause of apply_op/2 split into apply_op_batch/4 (clause
    # grouping under --warnings-as-errors) — the SAME receipt at a new def, so this
    # row re-keys; verdict and note carry over unchanged.
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.apply_op_batch/4", "93603959", "10224315"},
      verdict: "UNJUDGED", basis: :unjudged_other,
      note:
        "DEMOTED BY THIS WAVE'S OWN FALSIFIER, not by argument. The brief ruled it end_to_end_unmutated; the arm refused the citation (bulldocs_ingest_controller_test.exs:595 drives the batch route but never reads the paper back), so the receipt-vs-stored-row question is unjudged."},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:715
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.apply_op/2", "85655901", "15024779"},
      verdict: "UNJUDGED", basis: :unjudged_other,
      note:
        "DEMOTED BY THIS WAVE'S OWN FALSIFIER, not by argument. Same shape as its batch sibling: bulldocs_ingest_controller_test.exs:397 drives the single-op route and asserts the returned fragment, and nothing reads the stored paper back."},
    # barkpark_web/controllers/bulldocs_ingest_controller.ex:814
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.propose/2", "78347098", "122622379"},
      verdict: "UNJUDGED", basis: :unexamined},
    # BPML working-copy sync (masterplan W3) — the UNCHANGED receipt: `ok: true,
    # unchanged: true` claims nothing was written, and no test re-reads the row to
    # prove the nothing. Unjudged until one does.
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.sync_apply/6", "123013536", "126012198"},
      verdict: "UNJUDGED", basis: :unexamined},
    # BPML working-copy sync — the APPLIED receipt.
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.sync_persist/6", "94329464", "19447210"},
      verdict: "UNJUDGED", basis: :unjudged_other,
      note:
        "DEMOTED BY THE FALSIFIER'S OWN LENS, same shape as its apply_op siblings. The cycle test (bulldocs_bpml_api_test.exs:221) pushes, then re-PULLS the paper over the public HTTP read path and asserts the stored document byte-equals the receipt's canonical BPML — a real read-back the arm cannot see, because it keys on a `Repo.` read in the cited block. The row says what the lens can stand behind."},
    # BPML create-on-push (masterplan W3 / charter D41, rides #11934) — the CREATED
    # receipt: `ok: true, created: true` after Content.upsert_paper births the paper
    # through the full publish wall on an absent slug.
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex",
            "BarkparkWeb.BulldocsIngestController.sync_create_persist/6", "68602513", "127789733"},
      verdict: "UNJUDGED", basis: :unjudged_other,
      note:
        "A RECEIPT, not a phantom, but UNJUDGED by this lens — same shape as its sync_persist/6 sibling. The create test (bulldocs_ingest_controller_test.exs:1382) drives the create-on-push sync route AND reads the stored row back with `Content.get_paper(slug)`, asserting the persisted title, blocks, description and tags — a genuine receipt-vs-stored-row differential. But `Content.get_paper(` is not in @repo_tokens (`Repo.` · `Content.get_document(` · `Conflicts.list(`), so end_to_end's falsifier cannot see the second hop; the row says what the lens can stand behind, not more."},
    # barkpark_web/controllers/bulldocs_intents_controller.ex:50
    %{key: {"api/lib/barkpark_web/controllers/bulldocs_intents_controller.ex",
            "BarkparkWeb.BulldocsIntentsController.mark_processed/2", "120960553", "126280052"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/github_adopt_controller.ex:66
    %{key: {"api/lib/barkpark_web/controllers/github_adopt_controller.ex",
            "BarkparkWeb.GithubAdoptController.adopt/2", "109355155", "85172196"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/github_adopt_controller.ex:69
    %{key: {"api/lib/barkpark_web/controllers/github_adopt_controller.ex",
            "BarkparkWeb.GithubAdoptController.adopt/2", "109355155", "81072"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/github_status_controller.ex:65
    %{key: {"api/lib/barkpark_web/controllers/github_status_controller.ex",
            "BarkparkWeb.GithubStatusController.status/2", "63059312", "64996178"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/github_webhook_controller.ex:86
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.receive/2", "115025520", "17468236"},
      verdict: "UNJUDGED", basis: :declared_basis},
    # barkpark_web/controllers/github_webhook_controller.ex:87
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.receive/2", "115025520", "105570378"},
      verdict: "UNJUDGED", basis: :declared_basis},
    # barkpark_web/controllers/github_webhook_controller.ex:111
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_inbound/2", "26011363", "124460091"},
      verdict: "UNJUDGED", basis: :two_hop_composed, evidence: "api/test/barkpark/plugins/github/inbound_events_test.exs:201"},
    # barkpark_web/controllers/github_webhook_controller.ex:115
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_inbound/2", "26011363", "96836141"},
      verdict: "UNJUDGED", basis: :two_hop_composed, evidence: "api/test/barkpark/plugins/github/inbound_events_test.exs:201"},
    # barkpark_web/controllers/github_webhook_controller.ex:120
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_inbound/2", "26011363", "39153928"},
      verdict: "UNJUDGED", basis: :two_hop_composed, evidence: "api/test/barkpark/plugins/github/inbound_events_test.exs:235"},
    # barkpark_web/controllers/github_webhook_controller.ex:145
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_intake/2", "108173332", "38180227"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/github_webhook_integration_test.exs:165"},
    # barkpark_web/controllers/github_webhook_controller.ex:150
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_intake/2", "108173332", "96836141"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:112"},
    # barkpark_web/controllers/github_webhook_controller.ex:154
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_intake/2", "108173332", "39153928"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:122"},
    # barkpark_web/controllers/github_webhook_controller.ex:161
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_intake/2", "108173332", "109773520"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:75"},
    # barkpark_web/controllers/github_webhook_controller.ex:189
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_pull_request/2", "15231052", "46526763"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/controllers/github_webhook_integration_test.exs:209",
      attestation:
        "mutation: render stamped: without the merge write — `mix test api/test/barkpark_web/controllers/github_webhook_integration_test.exs:209` reds on Repo.get!",
    },
    # barkpark_web/controllers/github_webhook_controller.ex:194
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_pull_request/2", "15231052", "107251666"},
      verdict: "UNJUDGED", basis: :partial_tag_coverage, evidence: "api/test/barkpark_web/controllers/github_webhook_integration_test.exs:244",
      tags: [
        %{tag: :already_stamped, verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/controllers/github_webhook_integration_test.exs:244"},
        %{tag: :no_marker, verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:75"},
        %{tag: :no_guardable_marker, verdict: "UNJUDGED", basis: :no_observer, evidence: ""},
      ],
    },
    # barkpark_web/controllers/github_webhook_controller.ex:200
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_pull_request/2", "15231052", "28623217"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:75"},
    # barkpark_web/controllers/github_webhook_controller.ex:205
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_pull_request/2", "15231052", "62383269"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:75"},
    # barkpark_web/controllers/github_webhook_controller.ex:209
    %{key: {"api/lib/barkpark_web/controllers/github_webhook_controller.ex",
            "BarkparkWeb.GithubWebhookController.handle_pull_request/2", "15231052", "1432007"},
      verdict: "UNJUDGED", basis: :stub_mapping_only, evidence: "api/test/barkpark_web/controllers/github_webhook_controller_test.exs:75"},
    # barkpark_web/controllers/oidc_controller.ex:82
    %{key: {"api/lib/barkpark_web/controllers/oidc_controller.ex",
            "BarkparkWeb.OidcController.callback/2", "55913437", "73996638"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/plugin_settings_controller.ex:53
    %{key: {"api/lib/barkpark_web/controllers/plugin_settings_controller.ex",
            "BarkparkWeb.PluginSettingsController.update/2", "52263610", "17468236"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:251",
      attestation:
        "mutation: drop one key from the stored settings map — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:251` reds",
    },
    # barkpark_web/controllers/plugin_settings_controller.ex:65
    %{key: {"api/lib/barkpark_web/controllers/plugin_settings_controller.ex",
            "BarkparkWeb.PluginSettingsController.delete/2", "52373358", "17468236"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:272",
      attestation:
        "mutation: 200 without deleting the row — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:272` reds",
    },
    # barkpark_web/controllers/pulse_controller.ex:58
    %{key: {"api/lib/barkpark_web/controllers/pulse_controller.ex",
            "BarkparkWeb.PulseController.create/2", "89312836", "32961015"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/query_controller.ex:199
    %{key: {"api/lib/barkpark_web/controllers/query_controller.ex",
            "BarkparkWeb.QueryController.counts/2", "9322375", "98818316"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/saml_controller.ex:66
    %{key: {"api/lib/barkpark_web/controllers/saml_controller.ex",
            "BarkparkWeb.SamlController.acs/2", "32993266", "73996638"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/saml_controller_test.exs:117"},
    # barkpark_web/controllers/search_controller.ex:190
    %{key: {"api/lib/barkpark_web/controllers/search_controller.ex",
            "BarkparkWeb.SearchController.reindex/2", "43259676", "54848977"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/search_controller.ex:316
    %{key: {"api/lib/barkpark_web/controllers/search_controller.ex",
            "BarkparkWeb.SearchController.delete_search_synonym/2", "57054890", "120063507"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:67",
      attestation:
        "mutation: flip `Synonyms.delete/4` to return {:ok, 0} without deleting — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:67` reds on the Repo read",
    },
    # barkpark_web/controllers/search_controller.ex:337
    %{key: {"api/lib/barkpark_web/controllers/search_controller.ex",
            "BarkparkWeb.SearchController.search_interaction/2", "79721084", "115364326"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/integration/v1_data_search_suggestions_test.exs:84"},
    # barkpark_web/controllers/search_controller.ex:340
    %{key: {"api/lib/barkpark_web/controllers/search_controller.ex",
            "BarkparkWeb.SearchController.search_interaction/2", "79721084", "95315838"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/secret_controller.ex:67
    %{key: {"api/lib/barkpark_web/controllers/secret_controller.ex",
            "BarkparkWeb.SecretController.update/2", "4060754", "17468236"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:195",
      attestation:
        "mutation: store the PREVIOUS ciphertext — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:195` reds on the decode-back",
    },
    # barkpark_web/controllers/secret_controller.ex:80
    %{key: {"api/lib/barkpark_web/controllers/secret_controller.ex",
            "BarkparkWeb.SecretController.delete/2", "115609568", "17468236"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:145",
      attestation:
        "mutation: skip the audit insert — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:145` reds on the audit row",
    },
    # barkpark_web/controllers/self_update_controller.ex:24
    %{key: {"api/lib/barkpark_web/controllers/self_update_controller.ex",
            "BarkparkWeb.SelfUpdateController.trigger/2", "84801527", "68291924"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/site_deploy_controller.ex:81
    %{key: {"api/lib/barkpark_web/controllers/site_deploy_controller.ex",
            "BarkparkWeb.SiteDeployController.start/2", "126876520", "52242951"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/social_controller.ex:66
    %{key: {"api/lib/barkpark_web/controllers/social_controller.ex",
            "BarkparkWeb.SocialController.callback/2", "9871709", "73996638"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/tasks_controller.ex:83
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.task_list_response/3", "83021484", "1576835"},
      verdict: "UNJUDGED", basis: :unjudged_other,
      note:
        "wave 36 measured this receipt divergent and pds-w36-help-seal-fix repaired it; no committed differential naming task_list_response/3 resolves in the tree at this sha, so the REPAIR is unjudged here rather than credited. UPGRADE-ON-MERGE (wave 37 review, 2026-08-02): that slice lands api/test/barkpark_web/controllers/pds_w36_help_seal_probe_test.exs, whose PROBE A and PROBE D were re-verified RED by this reviewer against a faithful revert of the seal hoist. It cites the ROUTE, never the function name, so this note's wording stays literally true after the merge and no arm will red — re-derive the row to end_to_end by hand when the branch lands.",
    },
    # barkpark_web/controllers/tasks_controller.ex:170
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.prime/2", "40556915", "123654328"},
      verdict: "UNJUDGED", basis: :request_param_echo},
    # barkpark_web/controllers/tasks_controller.ex:224
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.events/2", "114887844", "12538138"},
      verdict: "UNJUDGED", basis: :request_param_echo},
    # barkpark_web/controllers/tasks_controller.ex:316
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.claim/2", "130674472", "21159066"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/tasks_controller_test.exs:2798"},
    # barkpark_web/controllers/tasks_controller.ex:371
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.show/2", "107047617", "14030995"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:435
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.claim_by_id/2", "59151065", "67476"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_test.exs:105"},
    # barkpark_web/controllers/tasks_controller.ex:558
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.release/2", "64399052", "86587931"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/tasks_controller_test.exs:741"},
    # barkpark_web/controllers/tasks_controller.ex:587
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.close_response/3", "102889179", "17778956"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_test.exs:149"},
    # barkpark_web/controllers/tasks_controller.ex:652
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.stage/2", "86501420", "84462998"},
      verdict: "PROVEN", basis: :end_to_end_unmutated, evidence: "api/test/barkpark_web/controllers/tasks_controller_test.exs:3510"},
    # barkpark_web/controllers/tasks_controller.ex:788
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.stamp/2", "53080965", "119279425"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_test.exs:126"},
    # barkpark_web/controllers/tasks_controller.ex:861
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.pulse/2", "62712851", "71420310"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_remainder_test.exs:169"},
    # barkpark_web/controllers/tasks_controller.ex:961
    # RE-KEYED, NOT RE-JUDGED. edges/2 now parses `kind` and delegates the
    # unchanged success body to edges_for_kind/3, so the emitting def moved and
    # the head hash moved with it (29434876 -> 41908878). The receipt EXPRESSION
    # is byte-identical — its fingerprint 113319186 is unchanged — so the
    # verdict and basis carry over untouched. The 400 arm emits no `ok: true`
    # and is therefore not a site this lens sees.
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.edges_for_kind/3", "41908878", "113319186"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:952
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.graph_show/2", "68876245", "14314567"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:984
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.graph_tasks/2", "6484558", "37641606"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:1008
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.graph_orphans/2", "87006539", "21591304"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:1015
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.graph_dangling/2", "113055363", "33214619"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:1142
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.derive_graph_corpus/2", "95387037", "94052887"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tasks_controller.ex:1289
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.add_edge/2", "32780970", "67314930"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_test.exs:165"},
    # barkpark_web/controllers/tasks_controller.ex:1327
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.relabel/2", "7475620", "84462998"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_remainder_test.exs:209"},
    # barkpark_web/controllers/tasks_controller.ex:1352
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.papers/2", "102968637", "84462998"},
      verdict: "UNJUDGED", basis: :side_effect_existence_only, evidence: "api/test/barkpark_web/controllers/tasks_controller_test.exs:1984"},
    # barkpark_web/controllers/tasks_controller.ex:1379
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.sessions/2", "36243778", "84462998"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_remainder_test.exs:234"},
    # barkpark_web/controllers/tasks_controller.ex:1422
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.move/2", "90153949", "84462998"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_remainder_test.exs:194"},
    # barkpark_web/controllers/tasks_controller.ex:1655
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.fleet_beat/2", "8622444", "8757049"},
      verdict: "UNJUDGED", basis: :context_differential_only, evidence: "api/test/barkpark/tasks/receipt_honesty_remainder_test.exs:266"},
    # barkpark_web/controllers/tasks_controller.ex:1696
    %{key: {"api/lib/barkpark_web/controllers/tasks_controller.ex",
            "BarkparkWeb.TasksController.fleet_roster/2", "116314994", "118018566"},
      verdict: "UNJUDGED", basis: :payload_is_the_postcondition},
    # barkpark_web/controllers/tickets_controller.ex:93
    %{key: {"api/lib/barkpark_web/controllers/tickets_controller.ex",
            "BarkparkWeb.TicketsController.index_own/2", "13011616", "113191402"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/tickets_controller.ex:169
    %{key: {"api/lib/barkpark_web/controllers/tickets_controller.ex",
            "BarkparkWeb.TicketsController.inbox/2", "102026838", "113191402"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/tickets_controller.ex:263
    %{key: {"api/lib/barkpark_web/controllers/tickets_controller.ex",
            "BarkparkWeb.TicketsController.render_ticket/3", "77961612", "114383917"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/v1/media_controller.ex:188
    %{key: {"api/lib/barkpark_web/controllers/v1/media_controller.ex",
            "BarkparkWeb.V1.MediaController.delete_search_synonym/2", "57054890", "20252134"},
      verdict: "PROVEN", basis: :end_to_end, evidence: "api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:82",
      attestation:
        "mutation: return the media surface's receipt without the delete — `mix test api/test/barkpark_web/contract/pds_group_c_receipt_differential_test.exs:82` reds",
    },
    # barkpark_web/controllers/v1/media_controller.ex:228
    %{key: {"api/lib/barkpark_web/controllers/v1/media_controller.ex",
            "BarkparkWeb.V1.MediaController.search_interaction/2", "79721084", "115364326"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/v1/media_controller.ex:231
    %{key: {"api/lib/barkpark_web/controllers/v1/media_controller.ex",
            "BarkparkWeb.V1.MediaController.search_interaction/2", "79721084", "95315838"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/webauthn_controller.ex:64
    %{key: {"api/lib/barkpark_web/controllers/webauthn_controller.ex",
            "BarkparkWeb.WebauthnController.register/2", "48289311", "78521592"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/webauthn_controller.ex:170
    %{key: {"api/lib/barkpark_web/controllers/webauthn_controller.ex",
            "BarkparkWeb.WebauthnController.step_up/2", "118230159", "123849466"},
      verdict: "UNJUDGED", basis: :unexamined},
    # barkpark_web/controllers/webauthn_controller.ex:212
    %{key: {"api/lib/barkpark_web/controllers/webauthn_controller.ex",
            "BarkparkWeb.WebauthnController.delete/2", "99456611", "17468236"},
      verdict: "UNJUDGED", basis: :unexamined}
  ]


  # ---------------------------------------------------------------- entrypoint

  def main(argv) do
    case parse_args(argv) do
      {:error, msgs} -> refuse_args(msgs)
      %{selftest?: true} -> selftest()
      %{keys?: true} = opts -> keys_run(opts)
      opts -> census(opts)
    end
  end

  # ARGV-STRICT. Every accepted spelling is named here and everything else is an error —
  # not a warning, not a shrug. `--files-from` is the one flag that takes a value, so its
  # value is consumed here and never re-read as a flag.
  defp parse_args(argv),
    do: parse_args(argv, %{sites?: false, keys?: false, selftest?: false, files_from: nil}, [])

  defp parse_args([], opts, []), do: opts
  defp parse_args([], _opts, bad), do: {:error, Enum.reverse(bad)}
  defp parse_args(["--sites" | rest], o, bad), do: parse_args(rest, %{o | sites?: true}, bad)
  defp parse_args(["--keys" | rest], o, bad), do: parse_args(rest, %{o | keys?: true}, bad)
  defp parse_args(["--selftest" | rest], o, bad), do: parse_args(rest, %{o | selftest?: true}, bad)

  defp parse_args(["--files-from", path | rest], o, bad),
    do: parse_args(rest, %{o | files_from: path}, bad)

  defp parse_args(["--files-from"], _o, bad),
    do: {:error, Enum.reverse(["--files-from needs a FILE path and was given none" | bad])}

  defp parse_args([other | rest], o, bad),
    do: parse_args(rest, o, ["unknown argument #{inspect(other)}" | bad])

  defp refuse_args(msgs) do
    p("")
    p("REFUSED: UNKNOWN ARGUMENT")
    Enum.each(msgs, &p("  " <> &1))
    p("")
    p("  accepted: --sites · --files-from FILE · --keys · --selftest")
    p("  A swallowed flag is a census measuring a lens nobody asked for. Exit 2.")
    System.halt(2)
  end

  defp census(opts) do
    # USER CPU, NOT WALL CLOCK (PDS-D605). D605 forbids a wall-clock figure standing in
    # for a price, and its own evidence is THIS census — so the census printing one was
    # the instrument contradicting the finding it supplies. `:erlang.statistics(:runtime)`
    # is the in-BEAM user-CPU meter, sound to <1% against an OS delta (PDS-D633) and, per
    # the blind spot above, scoped to this process. The FIRST element is total runtime
    # since VM start; the second is time-since-last-call, which is GLOBAL STATE — reading
    # a delta of the first perturbs nothing a later caller depends on.
    {cpu0, _since_last} = :erlang.statistics(:runtime)
    show_sites? = opts.sites?
    files = corpus(opts)

    banner()
    guard_corpus!(files)

    parsed = Enum.map(files, &parse_file/1)
    index = build_index(parsed)

    sites = Enum.flat_map(parsed, & &1.sites)
    textual = Enum.sum(Enum.map(parsed, & &1.textual_count))
    {ast_sites, phantoms} = split_phantoms(parsed, sites)
    {consumers, emitted} = Enum.split_with(ast_sites, & &1.pattern?)

    routed = Enum.map(emitted, &route(&1, index))
    classified = Enum.map(routed, &classify(&1, index))

    report_lens(textual, ast_sites, phantoms, consumers, emitted)
    report_carriers(parsed, ast_sites)
    report_split(classified)
    report_depth_sweep(emitted, index)
    report_shapes(classified)
    report_declared_register(classified)
    report_judgment_register(classified)
    falsifiers = if register_scope(classified) == :real, do: report_basis_falsifiers(classified), else: :skipped
    if show_sites?, do: report_each_site(classified)
    routed = report_routed_population(routed_derivation(parsed), classified, parsed, index)
    report_lens_can_miss(routed)
    report_blind_spots(parsed)
    delegate = report_delegate_probe(index)

    {cpu1, _since_last} = :erlang.statistics(:runtime)
    ms = cpu1 - cpu0

    integrity(files, textual, ast_sites, phantoms, consumers, emitted, classified, delegate, ms,
      parsed, falsifiers, routed)
  end

  # THE GLOB IS RELATIVE TO CWD, DELIBERATELY. `--selftest` censuses a synthetic tree by
  # running this same file with `cd:` set to a tmp dir — the sentinels at the top of this
  # module are relative literals for the same reason. (The `--files-from` seam does NOT
  # work for fixtures: guard_corpus!/1 runs before parse_file/1 and ORs the corpus floor
  # with the sentinel check on one cond arm, so no fixture list is both small enough to
  # mutate and large enough to pass.)
  defp corpus(%{files_from: nil}), do: Path.wildcard("api/lib/**/*.ex") |> Enum.sort()

  defp corpus(%{files_from: path}),
    do: path |> File.read!() |> String.split("\n", trim: true)

  defp banner do
    {otp, erts} = {System.otp_release(), :erlang.system_info(:version)}

    p("PDS ELIXIR RECEIPT CENSUS — the api/lib success surface, first look")
    p(String.duplicate("=", 78))
    p("engine      Elixir #{System.version()} · Erlang/OTP #{otp} (erts #{erts}) · #{:erlang.system_info(:system_architecture)}")
    p("lens        AST (Code.string_to_quoted/2, literal_encoder) — no regex, NO \\b dependency")
    p("            PDS-D448a: git grep -E '\\bok: true' returns 0 and exits 1 SILENTLY on this host.")
    p("            Every textual count here is :binary.matches/2 substring matching.")
    p("law         no Barkpark verb may report success on an exit code alone (PDS wave 22)")
    p("gate        NONE. This prints a population; it does not police one (PDS-D454).")

    # THE PRINTED HALF OF PDS-D633, FROM THE SAME LIST @moduledoc CARRIES. It is printed
    # rather than only documented because a green ExUnit case prints NOTHING: a rider that
    # asserts the sentence exists cannot put the sentence in front of whoever reads a run.
    [head | rest] = @blind_spot
    p("blind spot  #{head}")
    Enum.each(rest, &p("            " <> &1))
    p("")
  end

  # ---------------------------------------------------------------- corpus guard

  # `announce?` is false for --keys ONLY, whose stdout is machine-read TSV and must carry
  # nothing else. The REFUSAL is never quiet: a truncated corpus still exits 2 and says so.
  defp guard_corpus!(files, announce? \\ true) do
    set = MapSet.new(files)
    missing = Enum.reject(@sentinels, &MapSet.member?(set, &1))

    cond do
      files == [] ->
        refuse(["corpus is EMPTY — nothing to census"])

      missing != [] or length(files) < @corpus_floor ->
        refuse(
          [
            "#{length(files)} file(s); the api/lib corpus is #{@corpus_floor}+ and MUST carry every route-bearing module"
          ] ++
            Enum.map(missing, &"MISSING route-bearing sentinel: #{&1}") ++
            [
              "A corpus holding only the files that CARRY `ok: true` parses cleanly and reports",
              "write=0 for every site, with no error and no warning (PDS-D449a). That green is a lie:",
              "the write verbs live in the callees, which such a corpus does not contain."
            ]
        )

      announce? ->
        p("corpus      #{length(files)} .ex files under api/lib · sentinels present: #{Enum.join(@sentinels, ", ")}")
        p("")

      true ->
        :ok
    end
  end

  defp refuse(lines) do
    p("")
    p("REFUSED: TRUNCATED CORPUS")
    Enum.each(lines, &p("  " <> &1))
    p("")
    p("The census does not report zeros it cannot stand behind. Exit 2.")
    System.halt(2)
  end

  # ---------------------------------------------------------------- parsing

  defp parse_file(path) do
    src = File.read!(path)
    lines = String.split(src, "\n")

    textual =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} ->
        List.duplicate({n, :atom}, count(line, "ok: true")) ++
          List.duplicate({n, :string}, count(line, "\"ok\" => true"))
      end)

    opts = [
      literal_encoder: &{:ok, {:__block__, &2, [&1]}},
      token_metadata: true,
      columns: true,
      emit_warnings: false,
      unescape: false
    ]

    ast =
      case Code.string_to_quoted(src, opts) do
        {:ok, ast} -> ast
        {:error, _} -> :parse_error
      end

    {defs, sites, imports} =
      case ast do
        :parse_error -> {[], [], []}
        ast -> {collect_defs(ast, path), collect_sites(ast, path), collect_imports(ast)}
      end

    %{
      path: path,
      src: src,
      textual: textual,
      textual_count: length(textual),
      parse_error?: ast == :parse_error,
      imports: imports,
      defs: attribute(defs, sites) |> elem(0),
      sites: attribute(defs, sites) |> elem(1)
    }
  end

  defp count(hay, needle), do: length(:binary.matches(hay, needle))

  # -- site collection (pairs, with pattern context) --------------------------

  # THE CONTAINER IS RETAINED (PDS-D498). Wave 35's walker recorded {path, line, pattern?,
  # key} and threw the enclosing node away, so `expr_fp` — the half of the register key
  # that survives a line shift — was not computable at all. `expr` is the innermost
  # enclosing AST node that is NOT the pair itself: for `json(conn, %{ok: true, id: id})`
  # it is the `%{}` node, which is what distinguishes two receipts in one function.
  defp collect_sites(ast, path) do
    {_, acc} = pairs(ast, false, [], nil)

    acc
    |> Enum.map(fn {line, pat?, kind, expr} ->
      %{path: path, line: line, pattern?: pat?, key: kind, def: nil, expr: expr}
    end)
    |> Enum.sort_by(& &1.line)
  end

  defp pairs(node, pat?, acc, box) do
    case node do
      {:=, _, [lhs, rhs]} ->
        acc = pairs(lhs, true, acc, node) |> elem(1)
        pairs(rhs, pat?, acc, node)

      {:<-, _, [lhs, rhs]} ->
        acc = pairs(lhs, true, acc, node) |> elem(1)
        pairs(rhs, pat?, acc, node)

      {:->, _, [heads, body]} ->
        acc = pairs(heads, true, acc, node) |> elem(1)
        pairs(body, false, acc, node)

      {op, _, [head, body]} when op in [:def, :defp, :defmacro, :defmacrop] ->
        acc = pairs(head, true, acc, node) |> elem(1)
        pairs(body, false, acc, node)

      {op, _, [head]} when op in [:def, :defp, :defmacro, :defmacrop] ->
        pairs(head, true, acc, node)

      {left, right} ->
        acc =
          case pair_site(left, right) do
            nil -> acc
            {line, kind} -> [{line, pat?, kind, box} | acc]
          end

        acc = pairs(left, pat?, acc, box) |> elem(1)
        pairs(right, pat?, acc, box)

      list when is_list(list) ->
        {node, Enum.reduce(list, acc, fn el, a -> pairs(el, pat?, a, box) |> elem(1) end)}

      {f, _, args} ->
        acc = pairs(f, pat?, acc, node) |> elem(1)
        {node, if(is_list(args), do: pairs(args, pat?, acc, node) |> elem(1), else: acc)}

      _ ->
        {node, acc}
    end
    |> case do
      {_, _} = ok -> ok
      acc when is_list(acc) -> {node, acc}
    end
  end

  defp pair_site(left, right) do
    with {:lit, key, meta} <- lit(left),
         {:lit, true, _} <- lit(right) do
      # A bare 2-tuple `{:ok, true}` and a keyword pair `ok: true` quote IDENTICALLY.
      # Only the key's metadata separates them: `format: :keyword` for `ok:`, `assoc:`
      # for `"ok" =>`. Without this, ~100 ordinary `{:ok, true}` tuples enter the census.
      case {key, meta[:format], meta[:assoc]} do
        {:ok, :keyword, _} -> {meta[:line], :atom}
        {"ok", _, [_ | _]} -> {meta[:line], :string}
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp lit({:__block__, meta, [v]}) when is_atom(v) or is_binary(v) or is_number(v),
    do: {:lit, v, meta}

  defp lit(_), do: :no

  # -- def collection ---------------------------------------------------------

  defp collect_defs(ast, path), do: defs(ast, [], path, [])

  defp defs(node, mod, path, acc) do
    case node do
      {:defmodule, _, [{:__aliases__, _, segs}, body]} ->
        defs(body, mod ++ segs, path, acc)

      {op, meta, [head | rest]} when op in [:def, :defp, :defmacro, :defmacrop] ->
        {name, req, arity, hmeta} = head_sig(head)
        body = List.first(rest)

        rec = %{
          module: mod,
          name: name,
          arity: arity,
          req: req,
          path: path,
          line: meta[:line] || hmeta[:line] || 0,
          last: max_line(node, meta[:line] || 0),
          delegate: nil,
          body: body,
          head: head
        }

        [rec | acc]

      {:defdelegate, meta, [head, opts]} ->
        {name, req, arity, _} = head_sig(head)
        target = kw(opts, :to)
        as = kw(opts, :as)

        rec = %{
          module: mod,
          name: name,
          arity: arity,
          req: req,
          path: path,
          line: meta[:line] || 0,
          last: meta[:line] || 0,
          delegate: {target, as || name},
          body: nil,
          head: head
        }

        [rec | acc]

      list when is_list(list) ->
        Enum.reduce(list, acc, &defs(&1, mod, path, &2))

      {a, b} ->
        acc |> then(&defs(a, mod, path, &1)) |> then(&defs(b, mod, path, &1))

      {_f, _, args} when is_list(args) ->
        Enum.reduce(args, acc, &defs(&1, mod, path, &2))

      _ ->
        acc
    end
  end

  # -- import collection ------------------------------------------------------
  #
  # WHY THIS EXISTS (PDS wave 34). raw_calls/1 emits an IMPORTED call as {:local, f},
  # and callees/2 resolves {:local, f} only inside the CALLING module — so an imported
  # helper is not merely mis-attributed, it is STRUCTURALLY INVISIBLE to the call
  # graph. The corpus's one honest `select:`-inside-the-update writer,
  # Barkpark.Tasks.Internal.fenced_content_write/4 (internal.ex:50, `select: d` at
  # :54), is reached ONLY by `import Barkpark.Tasks.Internal, only: [...]`, so wave
  # 33's lens could never name it. Each entry is {calling_module_segs, fun_name,
  # imported_module_segs}.
  defp collect_imports(ast), do: imports(ast, [], [])

  defp imports(node, mod, acc) do
    case node do
      {:defmodule, _, [{:__aliases__, _, segs}, body]} ->
        imports(body, mod ++ segs, acc)

      {:import, _, [{:__aliases__, _, target} | opts]} ->
        Enum.reduce(import_only_names(opts), acc, &[{mod, &1, target} | &2])

      list when is_list(list) ->
        Enum.reduce(list, acc, &imports(&1, mod, &2))

      {a, b} ->
        acc |> then(&imports(a, mod, &1)) |> then(&imports(b, mod, &1))

      {_f, _, args} when is_list(args) ->
        Enum.reduce(args, acc, &imports(&1, mod, &2))

      _ ->
        acc
    end
  end

  # Only `only: [f: a]` is honoured. A bare `import Mod` or an `except:` list would
  # make the graph guess at which names came from where; this census does not guess.
  defp import_only_names(opts) do
    {_, only} =
      Macro.prewalk(opts, nil, fn
        {k, v} = n, acc ->
          case lit(k) do
            {:lit, :only, _} -> {n, acc || v}
            _ -> {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    case only do
      nil -> []
      node -> fun_arity_names(node)
    end
  end

  defp fun_arity_names(node) do
    {_, names} =
      Macro.prewalk(node, [], fn
        {k, v} = n, acc ->
          case {lit(k), lit(v)} do
            {{:lit, f, _}, {:lit, a, _}} when is_atom(f) and is_integer(a) -> {n, [f | acc]}
            _ -> {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    Enum.uniq(names)
  end

  # THE ARITY KEY IS A RANGE, NOT A SCALAR (PDS-D491). `def f(a, b \\ nil)` is callable
  # at 1 AND at 2, so a head declares `required..total`, not one number. The scalar
  # spelling was measured and is a REGRESSION — it drops every edge into a defaulted
  # head and routes 50/13/28 where the range spelling routes what this file prints.
  defp head_sig({:when, _, [h | _]}), do: head_sig(h)

  defp head_sig({name, meta, args}) when is_atom(name) and is_list(args),
    do: {name, required_arity(args), length(args), meta}

  defp head_sig({name, meta, _}) when is_atom(name), do: {name, 0, 0, meta}
  defp head_sig(_), do: {:__unknown__, 0, 0, []}

  defp required_arity(args) do
    Enum.count(args, fn
      {:\\, _, [_, _]} -> false
      _ -> true
    end)
  end

  defp kw(opts, key) do
    opts = if is_list(opts), do: opts, else: []

    Enum.find_value(opts, fn {k, v} ->
      case lit(k) do
        {:lit, ^key, _} -> alias_or_atom(v)
        _ -> nil
      end
    end)
  end

  defp alias_or_atom({:__aliases__, _, segs}), do: segs

  defp alias_or_atom(other) do
    case lit(other) do
      {:lit, v, _} when is_atom(v) -> v
      _ -> nil
    end
  end

  defp max_line(node, seed) do
    {_, m} =
      Macro.prewalk(node, seed, fn
        {_, meta, _} = n, acc when is_list(meta) ->
          l = Keyword.get(meta, :line, 0)
          e = get_in(meta, [:end, :line]) || get_in(meta, [:closing, :line]) || 0
          {n, Enum.max([acc, l, e])}

        n, acc ->
          {n, acc}
      end)

    m
  end

  # attribute each site to the innermost def containing its line
  defp attribute(defs, sites) do
    sites =
      Enum.map(sites, fn s ->
        owner =
          defs
          |> Enum.filter(&(&1.line <= s.line and s.line <= &1.last))
          |> Enum.sort_by(&(&1.last - &1.line))
          |> List.first()

        # KEEP THE OWNING CLAUSE, not just its {module, name, arity} key. Wave 33's
        # lens found the innermost containing def here and then threw the clause
        # away, and resolve_exact/2 re-resolved the key to the FIRST def of that
        # arity — 15 of 91 sites came back owned by a clause that does not contain
        # their line. The line pins the clause.
        %{s | def: owner && {owner.module, owner.name, owner.arity, owner.line}}
      end)

    {defs, sites}
  end

  # ---------------------------------------------------------------- index

  defp build_index(parsed) do
    all =
      parsed
      |> Enum.flat_map(& &1.defs)
      |> propagate_defaults()
      |> Enum.map(&Map.put(&1, :calls, raw_calls(&1)))

    by_key = Enum.group_by(all, fn d -> {d.module, d.name} end)
    by_module = Enum.group_by(all, & &1.module)

    # reverse edge, by called NAME — a receipt assembled in a helper is still a claim
    # about the caller's write (tasks_controller close/2 -> close_response/3).
    callers_by_name =
      all
      |> Enum.flat_map(fn d ->
        d.calls
        |> Enum.map(fn
          {:local, f, _a} -> {f, d}
          {:remote, _segs, f, _a} -> {f, d}
        end)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    # {calling_module, imported_fun} -> [imported_module_segs]
    imports =
      parsed
      |> Enum.flat_map(& &1.imports)
      |> Enum.group_by(fn {mod, f, _t} -> {mod, f} end, fn {_m, _f, t} -> t end)

    %{
      defs: all,
      by_key: by_key,
      by_module: by_module,
      modules: Map.keys(by_module),
      callers_by_name: callers_by_name,
      imports: imports
    }
  end

  # A BODILESS HEADER DECLARES DEFAULTS ITS SIBLING CLAUSE DOES NOT. `def f(a, b \\ nil)`
  # with no body, followed by `def f(a, b) do ... end`, is ONE function callable at 1..2 —
  # but only the header carries the `\\`, so per-clause `required` reads 1 and 2. The
  # minimum over every clause sharing {module, name, total_arity} is the function's real
  # required arity; without this propagation the body-carrying clause refuses the 1-arg
  # call and the edge is silently lost.
  defp propagate_defaults(defs) do
    mins =
      defs
      |> Enum.group_by(&{&1.module, &1.name, &1.arity}, & &1.req)
      |> Map.new(fn {k, reqs} -> {k, Enum.min(reqs)} end)

    Enum.map(defs, &%{&1 | req: Map.get(mins, {&1.module, &1.name, &1.arity}, &1.req)})
  end

  # THE KEY IS {module, fun, required..total}. `arity == nil` means "any" — the only
  # callers that pass nil are the ones with no call site to read an arity off.
  defp accepts?(_d, nil), do: true
  defp accepts?(d, arity), do: arity >= d.req and arity <= d.arity

  defp at_arity(cands, arity), do: Enum.filter(cands, &accepts?(&1, arity))

  defp resolve(index, mod_segs, name, arity) do
    (Map.get(index.by_key, {mod_segs, name}) ||
       (index.modules
        |> Enum.filter(&suffix?(&1, mod_segs))
        |> Enum.flat_map(&Map.get(index.by_key, {&1, name}, []))))
    |> at_arity(arity)
  end

  defp suffix?(full, segs) do
    n = length(segs)
    length(full) >= n and Enum.take(full, -n) == segs
  end

  # ---------------------------------------------------------------- routing

  defp route(site, index, max \\ @max_depth) do
    start = site.def && resolve_exact(index, site.def)

    {verbs, depth, chain} =
      case start do
        nil -> {%{}, nil, []}
        d -> bfs([{d, 0, [label(d)]}], index, MapSet.new(), %{}, nil, [], max)
      end

    # UP ONE, THEN DOWN. A receipt assembled in a private helper claims the CALLER's
    # write (tasks_controller.ex:587 lives in close_response/3, which touches no Repo
    # verb — the write is Tasks.close/3 in close/2, one frame up). One hop up only:
    # expanding callers transitively would reach the whole tree and mean nothing.
    {via, via_verbs} =
      if start && not Map.has_key?(verbs, :write) do
        start
        |> callers(index)
        |> Enum.reduce_while({nil, %{}}, fn c, acc ->
          {v, _, _} = bfs([{c, 1, [label(c)]}], index, MapSet.new(), %{}, nil, [], max)
          if Map.has_key?(v, :write), do: {:halt, {label(c), v}}, else: {:cont, acc}
        end)
      else
        {nil, %{}}
      end

    verbs =
      Map.merge(via_verbs, verbs, fn
        :visited, a, b -> a ++ b
        _k, a, b -> a ++ b
      end)

    Map.merge(site, %{
      verbs: verbs,
      write?: Map.has_key?(verbs, :write),
      read?: Map.has_key?(verbs, :read),
      depth: depth,
      via_caller: via,
      chain: chain,
      owner: start
    })
  end

  # callers of a def, matched on the called NAME and (for remote calls) an alias whose
  # tail matches the owning module — the same suffix rule the downward resolver uses.
  defp callers(d, index) do
    index.callers_by_name
    |> Map.get(d.name, [])
    |> Enum.filter(fn c ->
      Enum.any?(c.calls, fn
        {:local, f, a} -> f == d.name and c.module == d.module and accepts?(d, a)
        {:remote, segs, f, a} -> f == d.name and suffix?(d.module, segs) and accepts?(d, a)
      end)
    end)
    |> Enum.reject(&(&1.module == d.module and &1.name == d.name))
    |> Enum.take(12)
  end

  # ARITY FIRST, THEN THE LINE PIN. The key is {module, fun, required..total}; within the
  # clauses that accept this arity the LINE picks the exact clause, because a
  # {module, name, arity} triple names a FUNCTION and a receipt lives in ONE CLAUSE of it
  # (wave 33 threw the line away here and mis-owned 15 of 91 sites — see CLAUSE-COLLAPSE).
  defp resolve_exact(index, {mod, name, arity, line}) do
    cands = Map.get(index.by_key, {mod, name}) || []
    at = at_arity(cands, arity)

    Enum.find(at, &(&1.line == line)) ||
      List.first(at) ||
      Enum.find(cands, &(&1.line == line)) ||
      List.first(cands)
  end

  defp bfs([], _index, _seen, verbs, depth, chain, _max), do: {verbs, depth, chain}

  defp bfs([{d, depth, path} | rest], index, seen, verbs, found_at, chain, max) do
    key = {d.module, d.name, d.arity}

    if MapSet.member?(seen, key) do
      bfs(rest, index, seen, verbs, found_at, chain, max)
    else
      seen = MapSet.put(seen, key)
      hits = verb_hits(d)
      # every function the route actually entered — the evidence the shape test reads
      verbs = Map.update(verbs, :visited, [d], &[d | &1])

      verbs =
        Enum.reduce(hits, verbs, fn {kind, verb, line}, acc ->
          Map.update(acc, kind, [{verb, line, d.path, depth}], &[{verb, line, d.path, depth} | &1])
        end)

      {found_at, chain} =
        if found_at == nil and Map.has_key?(verbs, :write),
          do: {depth, path},
          else: {found_at, chain}

      # A defdelegate is a RENAME, not a call: it holds no logic that could make the
      # claim true or false, so following one costs no depth. Charging it a hop is how
      # a 24-entry facade like Barkpark.Tasks eats the whole budget and reports false.
      step = if d.delegate, do: 0, else: 1

      next =
        if depth + step > max do
          []
        else
          d
          |> callees(index)
          |> Enum.map(&{&1, depth + step, path ++ [label(&1)]})
        end

      bfs(rest ++ next, index, seen, verbs, found_at, chain, max)
    end
  end

  defp label(d), do: "#{Enum.join(d.module, ".")}.#{d.name}/#{d.arity}"

  defp verb_hits(%{delegate: {_, _}}), do: []

  defp verb_hits(%{body: nil}), do: []

  defp verb_hits(%{body: body}) do
    {_, hits} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segs}, f]}, meta, args} = n, acc when is_list(args) ->
          last = List.last(segs)

          cond do
            last in @repo_mods and f in @write_verbs ->
              {n, [{:write, :"#{last}.#{f}", meta[:line]} | acc]}

            last in @repo_mods and f in @read_verbs ->
              {n, [{:read, :"#{last}.#{f}", meta[:line]} | acc]}

            # Repo.query/query! IS NOT A READ HERE (PDS wave 34). Every Repo.query
            # site of consequence in this corpus is `SELECT pg_advisory_xact_lock(..)`
            # — a lock acquisition, not a read of the row a receipt is about. Scored
            # as a read it was worth 6 false POST-READs on its own. An advisory-lock
            # allowlist measures identically and is more code; the clause is gone.

            true ->
              {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    hits
  end

  # callees: defdelegate target, or every local/remote call resolvable in the corpus
  defp callees(%{delegate: {target, as}} = d, index) when is_list(target),
    do: resolve(index, target, as, d.arity)

  defp callees(%{delegate: {_, _}}, _index), do: []

  defp callees(%{body: nil}, _index), do: []

  defp callees(%{module: mod} = d, index) do
    (d[:calls] || raw_calls(d))
    |> Enum.flat_map(fn
      # A {:local, f, a} with no def of that name AND ARITY in the calling module is
      # either undefined or IMPORTED — and an imported call is a real edge, so follow it.
      {:local, f, a} ->
        case at_arity(Map.get(index.by_key, {mod, f}, []), a) do
          [] -> imported_defs(index, mod, f, a)
          defs -> defs
        end

      {:remote, segs, f, a} ->
        resolve(index, segs, f, a)
    end)
    |> Enum.uniq_by(&{&1.module, &1.name, &1.arity})
  end

  defp imported_defs(index, mod, f, arity) do
    index.imports
    |> Map.get({mod, f}, [])
    |> Enum.flat_map(&resolve(index, &1, f, arity))
  end

  defp raw_calls(%{body: nil}), do: []

  defp raw_calls(%{body: body}) do
    {_, calls} =
      body
      |> expand_pipes()
      |> Macro.prewalk([], fn
        {{:., _, [{:__aliases__, _, segs}, f]}, _, args} = n, acc
        when is_atom(f) and is_list(args) ->
          {n, [{:remote, segs, f, length(args)} | acc]}

        {f, _, args} = n, acc when is_atom(f) and is_list(args) ->
          if Macro.special_form?(f, length(args)) or Macro.operator?(f, length(args)) do
            {n, acc}
          else
            {n, [{:local, f, length(args)} | acc]}
          end

        n, acc ->
          {n, acc}
      end)

    Enum.uniq(calls)
  end

  # PIPE EXPANSION IS PART OF THE ARITY KEY (PDS-D491). `conn |> json(body)` quotes as
  # json/1 and calls json/2; reading the arity straight off the node would refuse the
  # real callee at exactly the places this corpus pipes most (controllers, contexts).
  # prewalk re-enters the rewritten node, so `a |> b() |> c()` unwinds fully.
  defp expand_pipes(body) do
    Macro.prewalk(body, fn
      {:|>, _, [lhs, {{:., _, _} = dot, meta, args}]} when is_list(args) ->
        {dot, meta, [lhs | args]}

      {:|>, _, [lhs, {f, meta, args}]} when is_atom(f) and is_list(args) ->
        {f, meta, [lhs | args]}

      n ->
        n
    end)
  end

  # ---------------------------------------------------------------- classify

  defp classify(site, index) do
    owner = site.owner
    shape = shape_of(site, owner, index)
    Map.put(site, :shape, shape)
  end

  defp shape_of(_site, nil, _index), do: {"UNCLASSIFIED", "no enclosing function resolved"}

  defp shape_of(site, owner, _index) do
    # The shape lives in the ROUTE, not only in the emitting function: the write and the
    # post-read that would back it are usually three frames down from the receipt.
    visited = Map.get(site.verbs, :visited, [owner])
    hits = verb_hits(owner)
    local_writes = for {:write, v, l} <- hits, do: {v, l}
    local_reads = for {:read, v, l} <- hits, do: {v, l}

    # Only the functions that ACTUALLY WRITE (plus the one that prints the receipt) can
    # supply a post-read. Accepting evidence from any function the route touched would
    # let an unrelated read three modules away certify the claim — over-claiming
    # compliance is the disease this census exists to find.
    candidates = Enum.filter(visited, &writes?/1) ++ [owner]

    selecting = Enum.find(candidates, &has_select_in_update?(&1.body))
    reading_after = Enum.find(candidates, &post_read_in?/1)
    cas = Enum.find(candidates, &cas_confirmed?/1)

    cond do
      site.write? and selecting ->
        {"POST-READ",
         "ARM 1 ADMISSIBLE (not proven): #{label(selecting)} writes with `select:` INSIDE the update query — the row is measured after the change (`returning:` is silently ignored by update_all, auth.ex:139-141, and is NOT this). This does NOT prove the selected row reaches the printed value"}

      site.write? and reading_after ->
        {"POST-READ",
         "ARM 2 ADMISSIBLE (weaker, line-order only): #{label(reading_after)} reads back after its own write — necessary, NOT sufficient"}

      site.write? and cas ->
        {"CAS-CONFIRMED-ECHO",
         "#{label(cas)} matches its update_all result against a literal row count — the claim dies if 0 rows moved"}

      span = catch_all_span(site, owner) ->
        {"CATCH-ALL-TO-SUCCESS",
         "the receipt is emitted INSIDE a failure-discarding clause at :#{elem(span, 0)}-#{elem(span, 1)} (head `#{elem(span, 2)}`) whose body renders `ok: true` — every outcome the earlier clauses did not name, including every failure, is answered with success"}

      true ->
        {"UNCLASSIFIED", evidence(site, local_writes, local_reads)}
    end
  end

  defp writes?(d), do: Enum.any?(verb_hits(d), fn {k, _, _} -> k == :write end)

  defp post_read_in?(d) do
    hits = verb_hits(d)
    post_read?(for({:write, v, l} <- hits, do: {v, l}), for({:read, v, l} <- hits, do: {v, l}))
  end

  defp evidence(site, writes, reads) do
    parts =
      [
        if(site.write?, do: "write-routed at depth #{site.depth}", else: nil),
        if(site.read? and not site.write?, do: "read-routed only", else: nil),
        if(!site.write? and !site.read?, do: "no Repo verb within depth #{@max_depth}", else: nil),
        if(writes != [], do: "local writes: #{Enum.map_join(writes, ",", &elem(&1, 0))}", else: nil),
        if(reads != [], do: "local reads: #{Enum.map_join(reads, ",", &elem(&1, 0))}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "; ")
  end

  defp post_read?([], _), do: false
  defp post_read?(_, []), do: false

  defp post_read?(writes, reads) do
    w = writes |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)
    r = reads |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)
    w != [] and r != [] and Enum.max(r) > Enum.min(w)
  end

  # `returning:` is a BLIND lens — Ecto silently ignores it on update_all (auth.ex:139-141).
  # The honest idiom is `select:` INSIDE the update query.
  #
  # KNOWN RESIDUAL UNSOUNDNESS, NAMED AND NOT FIXED HERE (PDS wave 34). This prewalks the
  # WHOLE function body for ANY `from(..., select: ...)`; it does not require the `select:`
  # to be on the query that is UPDATED. move.ex:230 is a plain READ query carrying a
  # `select:` inside a non-writing function, so it costs nothing today — but the predicate
  # is unsound by construction, which is exactly why every POST-READ it admits is printed
  # as ADMISSIBLE and never as proven. Filed as its own row.
  defp has_select_in_update?(nil), do: false

  defp has_select_in_update?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:from, _, args} = n, acc when is_list(args) ->
          {n, acc or kw_present?(args, :select)}

        n, acc ->
          {n, acc}
      end)

    found
  end

  defp kw_present?(args, key) do
    Enum.any?(List.flatten(args), fn
      {k, _} ->
        case lit(k) do
          {:lit, ^key, _} -> true
          _ -> false
        end

      _ ->
        false
    end)
  end

  defp cas_confirmed?(%{body: nil}), do: false

  defp cas_confirmed?(%{body: body} = d) do
    updates? = Enum.any?(verb_hits(d), fn {k, v, _} -> k == :write and v == :"Repo.update_all" end)
    updates? and int_tuple_match?(body)
  end

  defp int_tuple_match?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:{}, _, [a, _]} = n, acc -> {n, acc or int_lit?(a)}
        {a, _} = n, acc -> {n, acc or int_lit?(a)}
        n, acc -> {n, acc}
      end)

    found
  end

  defp int_lit?(node) do
    case lit(node) do
      {:lit, v, _} when is_integer(v) -> true
      _ -> false
    end
  end

  # ------------------------------------------------------- CATCH-ALL-TO-SUCCESS
  #
  # THIS ARM REPLACED A FALL-THROUGH (PDS wave 35). Its predecessor, UNREACHABLE-ERROR,
  # tested `not error_arm?(owner.body)` — no write guard, no positive evidence, and it sat
  # directly above the UNCLASSIFIED default, so it absorbed every site the earlier arms had
  # not claimed and read 26. Hand measurement says 3. Among the 23 it invented was
  # auth_controller.ex:417, the charter's OWN declared-honest anti-enumeration control: a
  # lens that accuses its own control is not measuring, it is asserting.
  #
  # THE TEST IS NOW POSITIVE, and it is a CONJUNCTION OF THREE, none of which may be
  # dropped on the grounds that it is individually inert:
  #
  #   1. A FAILURE-DISCARDING CLAUSE HEAD — one head argument, a variable whose name starts
  #      with `_`. WIDE on purpose: bare `_` AND `_other`, `_err`, `_reason`. A literal or
  #      structural head (`{:ok, id}`, `{:honeypot}`, `"ping"`) NAMES what it matched and is
  #      therefore not discarding.
  #   2. THE CLAUSE BODY RENDERS AN `ok: true` LITERAL PAIR.
  #   3. CONTAINMENT — the receipt's own line falls inside that clause's span.
  #
  # WHY NO `site.write?` GUARD (PDS-D476a, measured, not argued). Under a NARROW head (bare
  # `_` only) a write guard is inert, 2 -> 2. Under the SHIPPED wide head it collapses the
  # arm 3 -> 2 and deletes exactly github_webhook_controller.ex:87, whose route is unrouted —
  # the one site widening the head buys. Wide-head-plus-write-guard IS narrow-head, the
  # UNCLASSIFIED denominator silently moves 74 -> 75, and the declared register's CATCH-ALL
  # row stops corresponding to anything the arm suppresses, with no diff that looks like a
  # bucket change. A shape test that reads the route is not a shape test.
  #
  # WHY renders_ok_true?/1 SURVIVES BEING A TAUTOLOGY (PDS-D476b). Given containment it can
  # never be false: collect_sites/2 only emits a site ON an `ok: true` pair line, so a
  # contained site IS the pair. It stays because the two are inert only GIVEN EACH OTHER —
  # drop both and the arm fires on 11 and re-accuses auth_controller.ex:417. Deleting a
  # conjunct because it is currently redundant is how a fall-through grows back.
  defp catch_all_span(_site, %{body: nil}), do: nil

  defp catch_all_span(site, %{body: body}) do
    body
    |> discarding_success_clauses()
    |> Enum.find(fn {lo, hi, _head} -> lo <= site.line and site.line <= hi end)
  end

  defp discarding_success_clauses(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {:->, meta, [heads, clause_body]} = n, acc ->
          with {:discarding, name} <- discarding_head(heads),
               true <- renders_ok_true?(clause_body) do
            lo = meta[:line] || 0
            {n, [{lo, max_line(clause_body, lo), name} | acc]}
          else
            _ -> {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    Enum.sort(acc)
  end

  # ONE head argument, and it is a variable named `_...`. A guarded head (`_x when ...`)
  # narrows what it matches, so it is not a catch-all and is not unwrapped here.
  defp discarding_head([{name, _meta, ctx}]) when is_atom(name) and is_atom(ctx) do
    str = Atom.to_string(name)
    if String.starts_with?(str, "_"), do: {:discarding, str}, else: :no
  end

  defp discarding_head(_), do: :no

  defp renders_ok_true?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {left, right} = n, acc -> {n, acc or pair_site(left, right) != nil}
        n, acc -> {n, acc}
      end)

    found
  end

  # ------------------------------------------------------- declared register lookup
  #
  # KEYED ON THE FOUR-FIELD SITE KEY, NEVER {path, line} (PDS-D521). The line-keyed
  # spelling SILENTLY RESURRECTED A FINDING: one blank line inserted seven lines above
  # github_webhook_controller.ex:87 took `0 undeclared of 1 fired` -> `1 undeclared of 1
  # fired` — a false accusation against a committed basis — and flipped this register's
  # own status line to a FALSE sentence, at exit 0 in both runs. The line is now printed
  # (tracked live off the resolved site) and never matched on.
  defp declared_for(%{path: _} = site) do
    key = site_key(site)
    Enum.find(@declared, &(&1.key == key))
  end

  defp declared_for(_), do: nil

  # ---------------------------------------------------------------- register key
  #
  # WHAT --keys IS FOR. The hand-bucket register names sites; a register keyed on
  # `path:line` orphans every row the moment somebody inserts a line above one. The key
  # printed here is {path, module.name/arity, head_hash, expr_fp} — NO LINE NUMBER — so a
  # clause inserted above a registered site produces neither an orphan nor an arrival.
  #
  # THE NORMALISER IS THE TOTAL METADATA DROP (PDS-D498): `{f, _meta, a} -> {f, [], a}` on
  # every node, then `:erlang.phash2` OF THE TERM. It is NOT PDS-D477's partial drop of 11
  # known metadata keys followed by a phash2 of an `inspect` STRING. The two are
  # partition-identical inside every one of this corpus's {path, mfa} groups, so nothing is
  # lost — but the total drop is immune to an Elixir minor emitting a NEW metadata key,
  # which under a partial drop silently re-keys every row. THE TWO SPELLINGS PRODUCE
  # DIFFERENT INTEGERS FOR THE SAME SITE (capabilities.ex visible?/2 is 83655895 under the
  # partial drop and 52289869 under this one) — never transcribe a hash across normalisers.
  #
  # EDITING drop_meta/1, head_hash/1 OR expr_fp/1 IS A RE-KEY MIGRATION, not a refactor:
  # every register row keyed under the old spelling orphans at once. Bump @key_normaliser
  # in the same commit so the register can see which spelling produced its integers.
  #
  # WHAT head_hash CANNOT DISCRIMINATE — DERIVED UNDER THIS NORMALISER, not transcribed.
  # Across all 17,620 defs it collides in exactly 3 buckets (6 defs) WITHIN a
  # {path, module.name/arity} group, and 0 times within the 75 site-owning groups. Only
  # ONE of the three is the benign bodiless header (plugins/capabilities.ex visible?/2
  # :144/:155, where :144 is the header and :155 the last clause); the other TWO are two
  # DISTINCT functions inside two `defimpl Inspect, for: ...` blocks
  # (plugins/github/errors.ex :94/:138, plugins/indx/errors.ex :118/:137) that this walker
  # cannot tell apart, because it reads the head and defimpl reuses it verbatim.
  #
  # CORPUS-WIDE — ignoring path and mfa — it is 912 groups over 2,543 defs (`def all()` is
  # byte-identical in 7 modules; the widest groups are init/1 at 53 defs and call/2 at 39).
  # THE PATH AND THE MFA ARE CARRYING THAT LOAD, which is why the key is a 4-tuple and not
  # a hash. NOTE: the wave brief recorded 913 over 2,544 for this figure — re-derived here
  # it is 912 over 2,543. The corpus-wide partition is NOT covered by the two normalisers'
  # within-group partition identity, so that number does not survive a spelling change and
  # is not quotable across one. capabilities.ex visible?/2 hashes 52289869 here.
  @key_normaliser "total-meta-drop/phash2-term/v1"

  defp drop_meta(ast) do
    Macro.prewalk(ast, fn
      {f, meta, a} when is_list(meta) -> {f, [], a}
      n -> n
    end)
  end

  defp fp(nil), do: "-"
  defp fp(node), do: node |> drop_meta() |> :erlang.phash2() |> to_string()

  defp head_hash(%{owner: %{head: head}}), do: fp(head)
  defp head_hash(_), do: "-"

  defp expr_fp(%{expr: expr}), do: fp(expr)
  # THE `_` FALLBACK MATCHES head_hash/1 AND key_mfa/1 (PDS-D521). Without it, site_key/1
  # raises FunctionClauseError on any map that is not a collected site — which is exactly
  # what a register lookup does when a caller hands it a def record by mistake.
  defp expr_fp(_), do: "-"

  defp key_mfa(%{owner: owner}) when not is_nil(owner), do: label(owner)
  defp key_mfa(_), do: "?"

  # THE ONE SPELLING OF THE KEY. Every register — @declared and @register — joins on this
  # and on nothing else. Line and CLASS are both excluded: a class in the key means every
  # honest lens correction re-keys and orphans rows, which is the ratchet eating itself.
  defp site_key(s), do: {s.path, key_mfa(s), head_hash(s), expr_fp(s)}

  # STDOUT IS TSV AND NOTHING ELSE — one line per emitted site, so a consumer can read it
  # with `cut` and a `wc -l` against it means what it says. The one-line summary goes to
  # STDERR for the same reason.
  defp keys_run(opts) do
    files = corpus(opts)
    guard_corpus!(files, false)

    parsed = Enum.map(files, &parse_file/1)
    index = build_index(parsed)
    sites = Enum.flat_map(parsed, & &1.sites)
    {ast_sites, _phantoms} = split_phantoms(parsed, sites)
    {_consumers, emitted} = Enum.split_with(ast_sites, & &1.pattern?)
    routed = Enum.map(emitted, &route(&1, index))

    routed
    |> Enum.sort_by(&{&1.path, &1.line})
    |> Enum.each(fn s ->
      {path, mfa, hh, fp} = site_key(s)
      IO.puts(Enum.join([path, mfa, hh, fp], "\t"))
    end)

    IO.puts(
      :stderr,
      "keys #{length(routed)} · emitted #{length(emitted)} · normaliser #{@key_normaliser}"
    )

    System.halt(0)
  end

  # ---------------------------------------------------------------- reporting

  defp split_phantoms(parsed, sites) do
    ast_sites = sites

    ast_by_file =
      ast_sites
      |> Enum.group_by(& &1.path)
      |> Map.new(fn {p, l} -> {p, Enum.frequencies(Enum.map(l, & &1.line))} end)

    phantoms =
      Enum.flat_map(parsed, fn f ->
        seen = Map.get(ast_by_file, f.path, %{})

        f.textual
        |> Enum.frequencies()
        |> Enum.flat_map(fn {{line, _kind}, n} ->
          have = Map.get(seen, line, 0)
          extra = n - have

          if extra > 0 do
            List.duplicate(%{path: f.path, line: line, why: phantom_why(f, line)}, extra)
          else
            []
          end
        end)
      end)

    {ast_sites, phantoms}
  end

  # a textual `ok: true` the AST does not carry as an `:ok`/`"ok"` pair is either a
  # DIFFERENT KEY (`db_ok: true`) or prose inside a @doc/comment/string.
  defp phantom_why(f, line) do
    text = f.src |> String.split("\n") |> Enum.at(line - 1, "")

    cond do
      String.contains?(text, "_ok: true") ->
        key =
          text
          |> String.split("ok: true")
          |> List.first()
          |> String.split(~r/[^A-Za-z0-9_]/)
          |> List.last()

        "WRONG KEY — `#{key}ok: true` is not `ok: true`"

      String.contains?(text, "#") ->
        "prose in a comment"

      true ->
        "prose in a @doc/@moduledoc/string (no AST pair on this line)"
    end
  end

  defp report_lens(textual, ast_sites, phantoms, consumers, emitted) do
    p("THE POPULATION (derived here, not inherited)")
    p(String.duplicate("-", 78))
    row("textual occurrences", textual, nil, :textual)
    row("  AST-literal pairs", length(ast_sites), nil, :ast)
    row("  phantoms", length(phantoms), nil, :phantom)

    Enum.each(Enum.sort_by(phantoms, &{&1.path, &1.line}), fn ph ->
      p("      #{short(ph.path)}:#{ph.line} — #{ph.why}")
    end)

    row("  consumers (pattern position, NOT emitters)", length(consumers), nil, :consumer)

    Enum.each(Enum.sort_by(consumers, &{&1.path, &1.line}), fn c ->
      p("      #{short(c.path)}:#{c.line} — matches a REMOTE response, does not make a claim")
    end)

    row("EMITTED success claims", length(emitted), nil, :emitted)
    p("")
  end

  # CARRIER FILES, DERIVED — the number the @sentinels comment used to hardcode as 27.
  # BOTH readings are printed because they differ and neither is the obvious one: a file
  # can carry a textual occurrence that is pure prose (the phantom set) and so hold no AST
  # pair at all. A single integer here would be a lens with its lens filed off.
  defp report_carriers(parsed, ast_sites) do
    textual_files = Enum.count(parsed, &(&1.textual_count > 0))
    ast_files = ast_sites |> Enum.map(& &1.path) |> Enum.uniq() |> length()

    p("  carrier files          #{ast_files} hold an AST-literal pair · #{textual_files} hold a textual occurrence")
    p("  A CARRIERS-ONLY CORPUS IS THE TRAP (PDS-D449a): those #{ast_files} files parse cleanly and")
    p("  report write=0 for every site, with no error and no warning. The write verbs live in")
    p("  the #{length(parsed) - textual_files} files that carry no receipt at all.")
    p("")
  end

  defp report_split(classified) do
    w = Enum.count(classified, & &1.write?)
    r = Enum.count(classified, &(not &1.write? and &1.read?))
    u = Enum.count(classified, &(not &1.write? and not &1.read?))

    p("WHAT EACH CLAIM IS ABOUT (route-following through defdelegate, depth #{@max_depth})")
    p(String.duplicate("-", 78))
    row("write-routed  (claims a state change)", w, nil, :write)
    row("read-routed   (claims a read)", r, nil, :read)
    row("unrouted      (no Repo verb reached)", u, nil, :unrouted)
    p("")
    p("  #{w} IS A FLOOR, NEVER A CEILING. The #{u} unrouted sites are unrouted because this")
    p("  lens gave up at depth #{@max_depth} or could not resolve an alias — not because they")
    p("  touch no state. PDS-D448 judged them almost certainly writes. Read the write count")
    p("  as \"at least #{w} success claims are about a state change\".")
    p("")
    report_clause_collapse(classified)
  end

  # ATTRIBUTION INTEGRITY, PRINTED. Every site must be owned by a def clause whose line
  # range CONTAINS it. Wave 33's lens read 15 of 91 here — it found the innermost clause
  # and then re-resolved the {module, name, arity} key to the FIRST clause of that arity
  # (bulldocs_ingest_controller.ex:630, inside the batch clause of apply_op/2 at :604,
  # came back owned by the single-op clause at :693). A site owned by a clause that does
  # not contain it makes every downstream evidence claim about the wrong code.
  # THE FAIL-OPEN IS CLOSED (PDS wave 36). This function used to filter `& &1.owner` FIRST
  # and only then reject the sites whose owner does not contain them — so a site the
  # resolver could not own AT ALL (owner == nil) was neither collapsed nor counted, and the
  # number printed here read 0 while attribution had failed outright. An unowned site is
  # the WORST attribution failure available, not the absence of one; it is counted here.
  defp report_clause_collapse(classified) do
    {owned, unowned} = Enum.split_with(classified, & &1.owner)
    mis_owned = Enum.reject(owned, &(&1.owner.line <= &1.line and &1.line <= &1.owner.last))
    n = length(mis_owned) + length(unowned)

    p("  CLAUSE-COLLAPSE  #{n} of #{length(classified)} sites NOT attributed to a def clause that")
    p("  contains their line — #{length(mis_owned)} owned by a clause that does not contain them, #{length(unowned)} owned")
    p("  by no clause at all (0 is correct; wave 33's shipped lens read 15).")

    Enum.each(Enum.sort_by(mis_owned, &{&1.path, &1.line}), fn s ->
      p("      #{short(s.path)}:#{s.line} — owned by #{label(s.owner)} at :#{s.owner.line}-#{s.owner.last}")
    end)

    Enum.each(Enum.sort_by(unowned, &{&1.path, &1.line}), fn s ->
      p("      #{short(s.path)}:#{s.line} — NO OWNING CLAUSE RESOLVED; every evidence line about this site is about nothing")
    end)

    p("")
    n
  end

  # WHY THE FLOOR IS A FLOOR, shown rather than asserted. The write count is a function
  # of the depth budget, not a property of the code: a controller that calls a context
  # that calls a query builder that calls Repo is 4 hops, and depth 3 cannot see it.
  defp report_depth_sweep(emitted, index) do
    p("THE FLOOR MOVES WITH THE LENS (depth sensitivity — the drift vs PDS-D448 explained)")
    p(String.duplicate("-", 78))

    rows = Enum.map(@sweep ++ @beyond, &sweep_row(emitted, index, &1))
    {inside, beyond} = Enum.split_with(rows, &(&1.depth <= @max_depth))

    Enum.each(inside, fn r ->
      mark = if r.depth == @max_depth, do: "  <- the census depth", else: ""

      p("  depth #{r.depth}   write #{pad(r.write)}   read #{pad(r.read)}   unrouted #{pad(r.unrouted)}   POST-READ #{pad(r.post_read)}#{mark}")
    end)

    Enum.each(beyond, fn r ->
      p("  depth #{String.pad_trailing(to_string(r.depth), 2)}  write #{pad(r.write)}   read #{pad(r.read)}   unrouted #{pad(r.unrouted)}   POST-READ #{pad(r.post_read)}   (past the census depth)")
    end)

    p("")
    p("  WHY #{@max_depth} AND NOT MORE. EVERY NUMBER IN THIS PARAGRAPH IS READ OFF THE TABLE ABOVE")
    p("  (PDS wave 35 — this paragraph used to hardcode a write sweep that its own table")
    p("  refuted at depths 2 and 3, and a POST-READ figure less than half the one printed")
    p("  above it. A lens whose commentary disagrees with its own measurement is the defect")
    p("  this epic keeps filing; the false numbers are not reprinted here, only replaced.)")
    p("")
    at_max = Enum.find(rows, &(&1.depth == @max_depth))
    p("  THE ROUTE RELATION CLOSES AT #{@max_depth}. Write-routed climbs #{Enum.map_join(inside, "/", &to_string(&1.write))} across depths")
    p("  #{List.first(@sweep)}..#{@max_depth}, and then write #{at_max.write} / read #{at_max.read} / unrouted #{at_max.unrouted} is #{closure_word(rows, at_max)} at depths")
    p("  #{Enum.map_join(@beyond, ", ", &to_string/1)} — the bfs seen-set makes the reachable set a finite closure, and the")
    p("  route set is MONOTONE in the budget by construction (a larger budget explores a")
    p("  superset), so nothing is lost by stopping at the closure.")
    p("  THE SHAPE RELATION DOES NOT CLOSE THERE. POST-READ reads #{at_max.post_read} at depth #{@max_depth} and")
    p("  #{Enum.map_join(beyond, "/", &to_string(&1.post_read))} at depths #{Enum.map_join(@beyond, "/", &to_string/1)} — #{launder_phrase(rows, at_max)}. Those extra")
    p("  certifications are CROSS-ROW: at depth 7, six of them come from")
    p("  Barkpark.Webhooks.record_endpoint_failure/2 — a real `select:` on a WEBHOOK FAILURE")
    p("  COUNTER vouching for a session-revoke receipt (auth_controller.ex:329) and for")
    p("  WebAuthn registration. A read of an unrelated row is not a post-read.")
    p("  ABOVE #{@max_depth} THIS KNOB IS A COMPLIANCE DIAL, NOT A LENS. #{@max_depth} is where the route stops")
    p("  growing and the evidence has not yet started lying.")
    p("")
    p("  PDS-D448 recorded write=#{@recorded.write} read=#{@recorded.read} unrouted=#{@recorded.unrouted}. That is NOT this lens at")
    p("  depth #{@max_depth}; it is what a deeper (or hand-followed) route sees. Both are honest and")
    p("  neither is a ceiling — which is the point. A success-claim census reports the")
    p("  budget it measured with, or its integer means nothing.")
    p("")
  end

  defp sweep_row(emitted, index, d) do
    routed = Enum.map(emitted, &route(&1, index, d))
    shaped = Enum.map(routed, &classify(&1, index))

    %{
      depth: d,
      write: Enum.count(routed, & &1.write?),
      read: Enum.count(routed, &(not &1.write? and &1.read?)),
      unrouted: Enum.count(routed, &(not &1.write? and not &1.read?)),
      post_read: Enum.count(shaped, fn s -> elem(s.shape, 0) == "POST-READ" end)
    }
  end

  defp pad(n), do: String.pad_leading(to_string(n), 3)

  defp closure_word(rows, at_max) do
    beyond = Enum.filter(rows, &(&1.depth > @max_depth))

    if Enum.all?(beyond, &(&1.write == at_max.write and &1.read == at_max.read)),
      do: "IDENTICAL",
      else: "NOT identical (the closure claim no longer holds — read the table)"
  end

  defp launder_phrase(rows, at_max) do
    next = Enum.find(rows, &(&1.depth == List.first(@beyond)))

    case next && next.post_read - at_max.post_read do
      nil -> "the extra depth is not measured here"
      n when n > 0 -> "#{n} SITES LAUNDER IN AT DEPTH #{next.depth} ALONE"
      0 -> "depth #{next.depth} launders nothing in"
      n -> "depth #{next.depth} LOSES #{abs(n)} — read the table, not this sentence"
    end
  end

  defp report_shapes(classified) do
    counts = Enum.frequencies(Enum.map(classified, fn s -> elem(s.shape, 0) end))

    p("SHAPE (PDS-D453 taxonomy — six shapes, or UNCLASSIFIED; never a guess)")
    p(String.duplicate("-", 78))
    p("  READ THE POST-READ COUNT AS A CEILING, not a clean bill of health. Its evidence is")
    p("  line order — a Repo READ below a Repo WRITE inside the writing function — which is")
    p("  NECESSARY and NOT SUFFICIENT: this lens cannot prove the read is OF THE ROW that")
    p("  was written. `select:` inside the update query is the one spelling it CAN prove.")
    p("  Wave 34 confirms each one by hand; a POST-READ here is a candidate, not a verdict.")
    p("")
    p("  EVERY POST-READ BELOW IS ADMISSIBLE, NONE IS PROVEN HONEST. Even ARM 1")
    p("  (has_select_in_update?/1) only proves the update query CARRIES a `select:`; it does")
    p("  NOT prove the caller SPENDS the selected row on the value it prints. That exact")
    p("  failure mode is live in this corpus — BlockOps.fenced_paper_update/4 selects the")
    p("  saved row and its caller prints a PRE-WRITE rev. Nothing here excludes it.")
    p("")

    Enum.each(@shapes, fn sh ->
      n = Map.get(counts, sh, 0)
      note = if n == 0, do: shape_zero_note(sh), else: ""
      p(String.pad_trailing("  " <> sh, 30) <> String.pad_leading(to_string(n), 4) <> "  " <> note)
    end)

    n = Map.get(counts, "UNCLASSIFIED", 0)
    p(String.pad_trailing("  UNCLASSIFIED", 30) <> String.pad_leading(to_string(n), 4) <>
        "  the lens holds evidence but no verdict — wave 34 buckets these by hand")
    p("")
    post_read_roll(classified)
    catch_all_findings(classified)
  end

  # THE FINDINGS BLOCK. A shape count is not a finding — a NAMED site with no written basis
  # is. Every CATCH-ALL-TO-SUCCESS site that is not in the declared register is printed
  # here; a declared one is listed below it as SUPPRESSED, with its basis, so the reader can
  # see what was withheld and go read the same lines the register cites.
  defp catch_all_findings(classified) do
    all =
      classified
      |> Enum.filter(fn s -> elem(s.shape, 0) == "CATCH-ALL-TO-SUCCESS" end)
      |> Enum.sort_by(&{&1.path, &1.line})

    {declared, findings} = Enum.split_with(all, &declared_for/1)

    p("  CATCH-ALL-TO-SUCCESS FINDINGS  #{length(findings)} undeclared of #{length(all)} fired")

    if findings == [] do
      p("      none — every catch-all-to-success site carries a written basis")
    else
      Enum.each(findings, fn s ->
        p("      FINDING  #{short(s.path)}:#{s.line}  fn #{label(s.owner)}")
        p("               #{elem(s.shape, 1)}")
        p("               NO DECLARED BASIS. The caller cannot tell this receipt from the one")
        p("               the named clause above it emits, and nothing in the body says so.")
      end)
    end

    Enum.each(declared, fn s ->
      d = declared_for(s)
      p("      SUPPRESSED  #{short(s.path)}:#{s.line}  [#{d.class}, #{d.confirmation}]")
      p("                  basis: #{d.basis}")
    end)

    p("")
  end

  # THE REGISTER, PRINTED IN FULL — including the rows that suppress nothing. A register
  # that only shows up when it fires is indistinguishable from a mute list; this one is
  # readable on every run, so a row whose site the lens no longer reaches is visible as
  # documentation rather than quietly doing nothing.
  defp report_declared_register(classified) do
    fired =
      classified
      |> Enum.filter(fn s -> elem(s.shape, 0) != "UNCLASSIFIED" end)
      |> MapSet.new(&{&1.path, &1.line})

    p("DECLARED REGISTER (committed data — `declared`, the confirmation level already")
    p("shipping in internal/cli/hetzner_respost.go:197, never a new spelling)")
    p(String.duplicate("-", 78))

    by_key = Map.new(classified, &{site_key(&1), &1})

    Enum.each(@declared, fn d ->
      site = Map.get(by_key, d.key)

      # THE STATUS LINE SAYS WHAT IS ACTUALLY WITHHELD. A declared row never suppresses
      # the SHAPE — the arm still fires and the site still prints CATCH-ALL-TO-SUCCESS in
      # the roll. What it withholds is the FINDING. Writing "suppresses a fired shape"
      # would be this epic's own offence: a printed sentence that overstates what the
      # machine did.
      status =
        cond do
          site == nil ->
            "ORPHAN — this row's four-field key matches NO emitted site in this corpus (DECLARED-ROWS-RESOLVE says so above)"

          MapSet.member?(fired, {site.path, site.line}) ->
            "WITHHOLDS A FINDING — an arm fires here; the shape still prints, the finding does not"

          true ->
            "documents only — no arm fires here"
        end

      anchor = if site, do: ":#{site.line}", else: " (unresolved)"
      p("  #{short(declared_path(d))}#{anchor}  #{d.class} / #{d.confirmation}#{route_claim_tag(d)}")
      wrap("basis:  " <> d.basis, "      ", "        ")
      wrap("status: " <> status, "      ", "        ")
      wrap(d.why, "      ")
      p("")
    end)
  end

  defp route_claim_tag(%{route_claim: claim}), do: "  ·  route_claim #{claim}"
  defp route_claim_tag(_), do: ""

  defp declared_path(%{key: {path, _, _, _}}), do: path

  defp wrap(text, indent, hang \\ "") do
    width = 74 - String.length(indent)

    text
    |> String.split(" ")
    |> Enum.reduce({[], ""}, fn word, {lines, cur} ->
      cand = if cur == "", do: word, else: cur <> " " <> word

      cond do
        # A single word longer than the column cannot be broken — emit it long rather
        # than pushing an EMPTY line, which is what the naive form did.
        cur == "" -> {lines, cand}
        String.length(cand) > width -> {[cur | lines], word}
        true -> {lines, cand}
      end
    end)
    |> then(fn {lines, cur} -> Enum.reverse([cur | lines]) end)
    |> Enum.with_index()
    |> Enum.each(fn {line, i} -> p(indent <> if(i == 0, do: "", else: hang) <> line) end)
  end

  # ------------------------------------------------------- judgment register report
  #
  # THE DISTRIBUTION IS PRINTED AND NEVER ASSERTED. Nothing below can red the build; the
  # arms that can live in integrity/10, and they check COMPLETENESS and INTEGRITY only.
  # THE THREE RESOLUTION STATES, AND WHY `:stale` IS NOT AN ORPHAN. Churn is measured at
  # ~5.5% of rows per code slice touching two controllers, and it is a PURE RE-KEY — the
  # {path, mfa} multiset holds and only expr_fp moves. A row whose four-field key no
  # longer matches but whose {path, mfa} still names exactly ONE unclaimed emitted site is
  # DEMOTED to UNJUDGED / basis-stale and REPORTED; it does not red the build, because a
  # ratchet that reds on every honest edit gets switched off. A row with no {path, mfa}
  # match, or an ambiguous one inside a multi-site group, is an ORPHAN and REDS: the
  # register would otherwise silently re-point a bought judgment at a different receipt.
  #
  # THE COMMITTED ROW IS NEVER EDITED BY THIS. The demotion is a print-time report, so a
  # reader sees the stale basis and the author's original judgment side by side.
  defp resolve_register(classified) do
    live = Map.new(classified, &{site_key(&1), &1})
    exact = MapSet.new(for r <- @register, Map.has_key?(live, r.key), do: r.key)
    by_mfa = Enum.group_by(classified, &{&1.path, key_mfa(&1)})

    {rows, _taken} =
      Enum.map_reduce(@register, MapSet.new(), fn r, taken ->
        case Map.get(live, r.key) do
          nil ->
            {path, mfa, _, _} = r.key

            cands =
              by_mfa
              |> Map.get({path, mfa}, [])
              |> Enum.reject(
                &(MapSet.member?(exact, site_key(&1)) or MapSet.member?(taken, site_key(&1)))
              )

            case cands do
              [s] -> {{r, :stale, s}, MapSet.put(taken, site_key(s))}
              _ -> {{r, :orphan, nil}, taken}
            end

          s ->
            {{r, :live, s}, taken}
        end
      end)

    rows
  end

  defp report_judgment_register(classified) do
    resolved = resolve_register(classified)

    rows =
      Enum.map(resolved, fn {r, status, site} ->
        r |> Map.put(:resolved, site) |> Map.put(:status, status)
      end)

    scope = register_scope(classified)

    p("JUDGMENT REGISTER (committed data — one row per emitted site, keyed on")
    p("{path, module.name/arity, head_hash, expr_fp}; CLASS and LINE both EXCLUDED)")
    p(String.duplicate("-", 78))

    if scope == :scoped_out do
      p("  SCOPED OUT — this corpus holds none of the #{length(@register)} registered paths, so the")
      p("  register is neither checked nor reported here. This is NOT a pass: the synthetic")
      p("  selftest fixture resolves zero rows by construction.")
      p("")
    else
      # A DEMOTED ROW COUNTS AS UNJUDGED / basis_stale IN THE DISTRIBUTION, not as the
      # verdict its author committed — otherwise the register would keep reporting a
      # PROVEN it can no longer stand behind.
      effective =
        Enum.map(rows, fn r ->
          if r.status == :stale, do: %{r | verdict: "UNJUDGED", basis: :basis_stale}, else: r
        end)

      by_verdict = Enum.frequencies(Enum.map(effective, & &1.verdict))
      by_basis = Enum.frequencies(Enum.map(effective, & &1.basis))
      other = Map.get(by_basis, :unjudged_other, 0)
      stale = Enum.filter(rows, &(&1.status == :stale))

      p("  rows #{length(@register)} · resolved to a live site #{Enum.count(rows, & &1.resolved)} · derived at 501fb9670")
      p("  VERDICTS   #{Enum.map_join(["PROVEN", "REFUTED", "UNJUDGED"], " · ", &"#{&1} #{Map.get(by_verdict, &1, 0)}")}")
      p("  PROVEN IS NOT ONE TIER: #{Map.get(by_basis, :end_to_end, 0)} end_to_end (mutation-attested) + #{Map.get(by_basis, :end_to_end_unmutated, 0)} end_to_end_unmutated")
      p("  (the conjunction was READ, its falsifier NEVER exercised). Below the line and NOT")
      p("  part of it: #{Map.get(by_basis, :side_effect_existence_only, 0)} side_effect_existence_only, which PDS-D499 maps to UNJUDGED.")
      p("  unjudged_other (PROSE REQUIRED, counted, NEVER reds): #{other}")
      p("")
      p("  BASIS DISTRIBUTION (printed, never asserted — a reclassification cannot red this)")

      by_basis
      |> Enum.sort_by(fn {b, n} -> {-n, b} end)
      |> Enum.each(fn {b, n} ->
        {cls, _falsifier, tier} = Map.get(@basis_vocab, b, {"?", "?", :advisory})
        p("      #{String.pad_trailing(to_string(b), 30)} #{String.pad_leading(to_string(n), 3)}  #{cls} · #{tier}")
      end)

      p("")
      report_register_stale(stale)
      report_register_tags(rows)
      report_register_prose(rows)
    end
  end

  defp report_register_stale([]), do: :ok

  defp report_register_stale(stale) do
    p("  BASIS-STALE DEMOTIONS (#{length(stale)}) — reported, NOT written back, and NOT a red build")

    Enum.each(stale, fn r ->
      {path, mfa, hh, fp} = r.key
      now = site_key(r.resolved)

      p("      #{short(path)}:#{r.resolved.line}  #{mfa}")
      p("        recorded #{hh}/#{fp} · current #{elem(now, 2)}/#{elem(now, 3)}")
      p("        #{r.verdict} / #{r.basis}  ->  UNJUDGED / basis_stale (the basis it was judged on has moved)")
    end)

    p("")
  end

  defp report_register_tags(rows) do
    tagged = Enum.filter(rows, &Map.has_key?(&1, :tags))

    Enum.each(tagged, fn r ->
      anchor = if r.resolved, do: ":#{r.resolved.line}", else: " (unresolved)"
      proven = Enum.count(r.tags, &(&1.verdict == "PROVEN"))

      p("  MULTI-TAG  #{short(elem(r.key, 0))}#{anchor}  ONE emitted site, #{length(r.tags)} rendered receipts")
      p("             row verdict #{r.verdict} / #{r.basis} — the WEAKEST of its tags (#{proven} of #{length(r.tags)} proven)")

      Enum.each(r.tags, fn t ->
        p("               #{String.pad_trailing(inspect(t.tag), 24)} #{String.pad_trailing(t.verdict, 9)} #{t.basis}")
      end)

      p("")
    end)
  end

  defp report_register_prose(rows) do
    prose = Enum.filter(rows, &(&1.basis == :unjudged_other))

    Enum.each(prose, fn r ->
      anchor = if r.resolved, do: ":#{r.resolved.line}", else: " (unresolved)"
      p("  UNJUDGED-OTHER  #{short(elem(r.key, 0))}#{anchor}")
      wrap(r.note, "      ", "  ")
      p("")
    end)
  end

  # THE SCOPE PREDICATE. The selftest's synthetic fixture holds none of these paths, so an
  # unconditional arm would red the selftest on its own commit. A corpus holding SOME of
  # them is the real corpus with a file missing — that is an orphan, and it reds.
  defp register_scope(classified) do
    live = MapSet.new(classified, & &1.path)
    if Enum.any?(@register, &MapSet.member?(live, elem(&1.key, 0))), do: :real, else: :scoped_out
  end

  # The POST-READ survivors, named with the arm that admitted them. A count alone lets a
  # later wave quote "N post-reads" as compliance; the roll makes the arm — and therefore
  # the strength of the evidence — impossible to quote without.
  defp post_read_roll(classified) do
    survivors =
      classified
      |> Enum.filter(fn s -> elem(s.shape, 0) == "POST-READ" end)
      |> Enum.sort_by(&{&1.path, &1.line})

    if survivors != [] do
      p("  POST-READ SURVIVORS, BY ARM (admissible, never proven)")

      Enum.each(survivors, fn s ->
        arm = if String.starts_with?(elem(s.shape, 1), "ARM 1"), do: "ARM 1 select:", else: "ARM 2 line-order"
        p("      #{short(s.path)}:#{s.line}  [#{arm}]  fn #{label(s.owner)}")
      end)

      p("")
    end
  end

  defp shape_zero_note("WRONG-ROW"),
    do: "0 DETECTED — this lens cannot see it; it needs the row identity, not the verb"

  defp shape_zero_note("DISCARDED-POST-READ"),
    do: "0 DETECTED — needs dataflow from the read to the printed value"

  defp shape_zero_note("PURE-ECHO"),
    do: "0 DETECTED — not separable from UNCLASSIFIED without dataflow; not guessed"

  defp shape_zero_note(_), do: ""

  defp report_each_site(classified) do
    p("EVERY EMITTED SITE")
    p(String.duplicate("-", 78))

    classified
    |> Enum.sort_by(&{&1.path, &1.line})
    |> Enum.each(fn s ->
      {shape, why} = s.shape

      declared = if declared_for(s), do: " DECLARED", else: ""

      p("#{short(s.path)}:#{s.line}  [#{route_tag(s)}] #{shape}#{declared}")
      p("    fn #{s.owner && label(s.owner) || "?"} — #{why}")
    end)

    p("")
  end

  # THE ROUTE BRACKET IS DISPUTABLE, AND ONLY HERE (PDS wave 35). This function reads
  # `write?`/`depth` and NEVER the shape, so no class value can retract a route it got
  # wrong — bulldocs_form_controller.ex:54, the honeypot arm that by design writes nothing,
  # printed a bare `[WRITE d5]` because its ENCLOSING function routes to a write on the
  # success path. A declared row carrying `route_claim` marks the bracket disputed at the
  # one place that prints it.
  defp route_tag(s) do
    base =
      cond do
        s.write? and s.via_caller -> "WRITE via caller #{s.via_caller}"
        s.write? -> "WRITE d#{s.depth}"
        s.read? -> "READ"
        true -> "UNROUTED"
      end

    case declared_for(s) do
      %{route_claim: claim} -> "#{base} DISPUTED — #{claim}"
      _ -> base
    end
  end

  # ----------------------------------------------------- routed population (L4a-d)

  # THE WHOLE DERIVATION, IN ONE PASS OVER THE SOURCES THE CENSUS ALREADY READ. Returns
  # :no_router when this corpus carries no router.ex — the ROUTER-PRESENCE predicate the
  # two new arms hang on, so a synthetic or truncated corpus contributes NO arm rather
  # than a PASS nobody earned.
  defp routed_derivation(parsed) do
    with %{src: src} <- Enum.find(parsed, &(&1.path == @router_path)),
         {:ok, ast} <- Code.string_to_quoted(src) do
      literal = router_literal_routes(ast)
      mounts = router_mount_sites(ast)
      specs = plugin_route_specs(parsed)

      mounted =
        for {prefix, bucket} <- mounts,
            s <- specs,
            auth_in_scope?(s.auth, bucket),
            do: {s.method, prefix <> s.path, s.module, s.action}

      # `scope "/" do post("/login", ...) end` composes to "//login". Phoenix normalises
      # that away, so the key must too — otherwise the disposition table reads as a set of
      # URLs nobody can find in the router and a reviewer cannot check a single row.
      routes =
        (literal ++ mounted)
        |> Enum.map(fn {m, path, mod, a} -> {m, normalize_route_path(path), mod, a} end)
        |> Enum.uniq()

      %{
        routes: routes,
        population: Enum.filter(routes, &routed_member?/1),
        mounts: mounts,
        specs: specs,
        macro_sites: router_macro_sites(ast),
        textual_macro: count(src, "#{@routed_resolved_macro}(")
      }
    else
      _ -> :no_router
    end
  end

  # ROUTED-WRITE. A member is a route that can MOVE STATE: the four write methods, plus
  # every LiveView mount — a LiveView's handle_event/3 writes are routed from here too,
  # and dropping them silently is the exact move this slice exists to refuse. They are
  # disposed EXCLUDED, with a count, rather than never counted.
  defp routed_member?({m, _p, _mod, _a}),
    do: m in @routed_write_methods or m == @routed_live_method

  # -- the router AST ---------------------------------------------------------
  #
  # SCOPE STATE IS {path prefix, alias segments} AND BOTH NEST. `scope "/v1", BarkparkWeb
  # do get("/x", FooController, :y) end` is GET /v1/x -> BarkparkWeb.FooController.y, and
  # reading the literal alone (as an earlier route-linkage probe did) manufactures false
  # findings on every scoped controller in the file.
  defp router_literal_routes(ast), do: Enum.reverse(router_walk(ast, {"", []}, []))

  @route_verbs ~w(get post put patch delete options head live)a

  defp router_walk({:scope, _, args}, {prefix, aliases}, acc) do
    {p, al, body} = scope_parts(args)
    router_walk(body, {prefix <> p, aliases ++ al}, acc)
  end

  defp router_walk({verb, _, args}, {prefix, aliases} = ctx, acc) when verb in @route_verbs do
    case args do
      [path, mod, action | _] when is_binary(path) ->
        [{verb, prefix <> path, alias_string(aliases, mod), action_atom(action)} | acc]

      # `live "/x", FooLive` — Phoenix's 2-arity form, action nil. Dropping it undercounts
      # the LiveView class by a third.
      [path, mod] when is_binary(path) and verb == @routed_live_method ->
        [{verb, prefix <> path, alias_string(aliases, mod), nil} | acc]

      _ ->
        router_descend(args, ctx, acc)
    end
  end

  defp router_walk({_, _, args}, ctx, acc) when is_list(args), do: router_descend(args, ctx, acc)
  defp router_walk({a, b}, ctx, acc), do: router_walk(b, ctx, router_walk(a, ctx, acc))
  defp router_walk(l, ctx, acc) when is_list(l), do: router_descend(l, ctx, acc)
  defp router_walk(_, _, acc), do: acc

  defp router_descend(nodes, ctx, acc), do: Enum.reduce(nodes, acc, &router_walk(&1, ctx, &2))

  # THE MOUNT SITES, WITH THE SCOPE THEY SIT IN. `plugin_routes(scope: :api)` inside
  # `scope "/v1/plugins"` mounts every plugin spec tagged `auth: :api` under that prefix.
  defp router_mount_sites(ast), do: Enum.reverse(mount_walk(ast, "", []))

  defp mount_walk({:scope, _, args}, prefix, acc) do
    {p, _al, body} = scope_parts(args)
    mount_walk(body, prefix <> p, acc)
  end

  defp mount_walk({@routed_resolved_macro, _, [opts]}, prefix, acc) when is_list(opts),
    # kw_lit/2, NOT the census's kw/2: kw/2 reads the literal_encoder-wrapped form that
    # parse_file/1 produces, and this walk parses router.ex PLAIN. Reading a bare `:scope`
    # key through kw/2 returns nil, every mount silently defaults to :admin, and the
    # mounted population loses ~84 routes without a single error.
    do: [{prefix, kw_lit(opts, :scope) || :admin} | acc]

  defp mount_walk({_, _, args}, prefix, acc) when is_list(args),
    do: Enum.reduce(args, acc, &mount_walk(&1, prefix, &2))

  defp mount_walk({a, b}, prefix, acc), do: mount_walk(b, prefix, mount_walk(a, prefix, acc))
  defp mount_walk(l, prefix, acc) when is_list(l), do: Enum.reduce(l, acc, &mount_walk(&1, prefix, &2))
  defp mount_walk(_, _, acc), do: acc

  # DELIBERATELY A SECOND WALK, NOT A FILTER OVER mount_walk/3. LENS-CAN-MISS asserts that
  # the blind-shape DETECTOR is alive; if killing it also killed the mount resolution, the
  # mutation would red ROUTED-POPULATION-COMPLETE as collateral and the selftest could not
  # tell which arm caught it. Separate functions, surgical mutation.
  defp router_macro_sites(ast), do: Enum.reverse(macro_walk(ast, []))

  defp macro_walk({name, meta, args}, acc) when name in @routed_macros and is_list(args),
    do: [{name, length(args), meta[:line] || 0} | Enum.reduce(args, acc, &macro_walk/2)]

  defp macro_walk({_, _, args}, acc) when is_list(args), do: Enum.reduce(args, acc, &macro_walk/2)
  defp macro_walk({a, b}, acc), do: macro_walk(b, macro_walk(a, acc))
  defp macro_walk(l, acc) when is_list(l), do: Enum.reduce(l, acc, &macro_walk/2)
  defp macro_walk(_, acc), do: acc

  defp scope_parts(args) do
    {body, rest} =
      case List.last(args) do
        [{{:__block__, _, [:do]}, b}] -> {b, Enum.drop(args, -1)}
        [{:do, b}] -> {b, Enum.drop(args, -1)}
        _ -> {nil, args}
      end

    {Enum.find_value(rest, "", &string_lit/1),
     Enum.find_value(rest, [], fn
       {:__aliases__, _, segs} -> segs
       _ -> nil
     end), body}
  end

  defp normalize_route_path(path) do
    case path |> String.split("/", trim: true) |> Enum.join("/") do
      "" -> "/"
      p -> "/" <> p
    end
  end

  defp string_lit({:__block__, _, [s]}) when is_binary(s), do: s
  defp string_lit(s) when is_binary(s), do: s
  defp string_lit(_), do: nil

  defp alias_string(prefix, {:__aliases__, _, segs}), do: Enum.join(prefix ++ segs, ".")
  defp alias_string(_, a) when is_atom(a), do: to_string(a)
  defp alias_string(_, _), do: "?"

  defp action_atom({:__block__, _, [a]}) when is_atom(a), do: a
  defp action_atom(a) when is_atom(a), do: a
  defp action_atom(_), do: :__dynamic__

  # -- the plugin specs -------------------------------------------------------
  #
  # THE DELEGATION IS RESOLVED, NOT GREPPED (PDS-D540). `OnixEdit.register_routes/1` is
  # `do: Routes.all()`. A literal-tuple grep over plugins/*.ex returns FOUR ROUTES SHORT
  # and says nothing about it; here the callback body that holds no literal tuple is
  # followed to the def it names, by SUFFIX match on the alias segments (the same trick
  # resolve/4 uses), and that def's tuples are collected instead.
  defp plugin_route_specs(parsed) do
    plugin_files = Enum.filter(parsed, &String.starts_with?(&1.path, @plugin_dir))
    bodies = Map.new(plugin_files, &{&1.path, plugin_defs(&1)})
    all_defs = bodies |> Map.values() |> Enum.concat()

    all_defs
    |> Enum.filter(fn {_mod, name, _arity, _body} -> name == :register_routes end)
    |> Enum.flat_map(fn {_mod, _n, _a, body} ->
      body = inline_alias_bindings(body)

      case route_specs(body) do
        [] -> follow_route_delegation(body, all_defs)
        specs -> specs
      end
    end)
    |> Enum.uniq()
  end

  # A ROUTE MODULE BOUND TO A LOCAL VARIABLE IS STILL A ROUTE MODULE (PDS wave 40).
  # `Barkpark.Plugins.Sheets.register_routes/1` opens with
  # `import_controller = Barkpark.Plugins.Sheets.Web.ImportController` and then spells the
  # route tuples with the VARIABLE. alias_string/2 sees `{:import_controller, _, nil}`,
  # which is neither an `__aliases__` node nor an atom, and returns `"?"` — so two live
  # write routes landed in `action_not_in_corpus` under prose ("resolves to no `def` under
  # api/lib") that is checkably untrue: the defs are right there.
  #
  # NARROWED TO TOP-LEVEL BINDINGS, ON PURPOSE, AND THE NARROWING IS THE POINT. A
  # scope-blind substitution ("collect every `var = SomeAlias` anywhere in the body") is
  # INDISTINGUISHABLE from this one on today's corpus and WRONG: a name rebound inside a
  # `fn`, a `case` clause or a comprehension does not hold the outer alias at the tuple's
  # line, and substituting anyway would print a module the reader cannot find. So:
  #
  #   1. only the do-block's OWN statements bind (a nested `=` binds nothing here), and
  #   2. a source-order fold RETIRES a name the moment anything rebinds it — at top level
  #      to a non-alias, or ANYWHERE deeper at all.
  #
  # A name this pass retires is not guessed: the tuple keeps `"?"` and the row DECLINES.
  # Declining is a smaller lie than inlining a binding that may not hold, and the selftest
  # plants exactly that nested rebind to prove the two behaviours differ.
  defp inline_alias_bindings(body) do
    stmts = block_stmts(body)

    top =
      Enum.reduce(stmts, %{}, fn
        {:=, _, [{name, _, ctx}, rhs]}, acc when is_atom(name) and is_atom(ctx) ->
          case rhs do
            {:__aliases__, _, segs} -> Map.put(acc, name, segs)
            _ -> Map.delete(acc, name)
          end

        _, acc ->
          acc
      end)

    # RETIRE ON ANY REBIND, WHEREVER IT LIVES. bind_counts/1 counts every `=` whose left
    # side is this bare name; a top-level alias binding contributes exactly 1, so anything
    # above 1 means the name is rebound somewhere this pass does not model, and the name
    # leaves the substitution set rather than being applied on faith.
    counts = bind_counts(body)
    safe = for {name, segs} <- top, Map.get(counts, name, 0) == 1, into: %{}, do: {name, segs}

    if safe == %{} do
      body
    else
      Macro.prewalk(body, fn
        {name, meta, ctx} = n when is_atom(name) and is_atom(ctx) ->
          case Map.fetch(safe, name) do
            {:ok, segs} -> {:__aliases__, meta, segs}
            :error -> n
          end

        n ->
          n
      end)
    end
  end

  # plugin_defs/1 stores a def's SECOND argument, which is the `[do: block]` keyword list
  # Elixir quotes a do-block into — not the block. Unwrapping it here is what makes
  # "top level" mean the statements the reader sees at the head of `register_routes/1`.
  defp block_stmts([{key, block}]) when is_list(block) or is_tuple(block) do
    if do_key?(key), do: block_stmts(block), else: []
  end

  defp block_stmts({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp block_stmts(nil), do: []
  defp block_stmts(other) when is_list(other), do: []
  defp block_stmts(other), do: [other]

  defp do_key?(:do), do: true
  defp do_key?({:__block__, _, [:do]}), do: true
  defp do_key?(_), do: false

  defp bind_counts(body) do
    {_, acc} =
      Macro.prewalk(body, %{}, fn
        {:=, _, [{name, _, ctx}, _rhs]} = n, acc when is_atom(name) and is_atom(ctx) ->
          {n, Map.update(acc, name, 1, &(&1 + 1))}

        n, acc ->
          {n, acc}
      end)

    acc
  end

  defp plugin_defs(%{path: path, src: src}) do
    case Code.string_to_quoted(src) do
      {:ok, ast} -> plugin_def_walk(ast, [], path, [])
      _ -> []
    end
  end

  defp plugin_def_walk({:defmodule, _, [{:__aliases__, _, segs}, body]}, mod, path, acc),
    do: plugin_def_walk(body, mod ++ segs, path, acc)

  defp plugin_def_walk({op, _, [head, body]}, mod, path, acc) when op in [:def, :defp] do
    {name, _req, arity, _} = head_sig(head)
    [{mod, name, arity, body} | plugin_def_walk(body, mod, path, acc)]
  end

  defp plugin_def_walk({_, _, args}, mod, path, acc) when is_list(args),
    do: Enum.reduce(args, acc, &plugin_def_walk(&1, mod, path, &2))

  defp plugin_def_walk({a, b}, mod, path, acc),
    do: plugin_def_walk(b, mod, path, plugin_def_walk(a, mod, path, acc))

  defp plugin_def_walk(l, mod, path, acc) when is_list(l),
    do: Enum.reduce(l, acc, &plugin_def_walk(&1, mod, path, &2))

  defp plugin_def_walk(_, _, _, acc), do: acc

  defp follow_route_delegation(body, all_defs) do
    body
    |> remote_calls()
    |> Enum.flat_map(fn {segs, fun, arity} ->
      all_defs
      |> Enum.filter(fn {mod, name, ar, _b} -> name == fun and ar == arity and suffix?(mod, segs) end)
      |> Enum.flat_map(fn {_m, _n, _a, b} -> route_specs(b) end)
    end)
  end

  defp remote_calls(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segs}, f]}, _, args} = n, acc when is_atom(f) and is_list(args) ->
          {n, [{segs, f, length(args)} | acc]}

        n, acc ->
          {n, acc}
      end)

    Enum.uniq(acc)
  end

  # A ROUTE SPEC IS A 4- OR 5-TUPLE {method, path, Module, action[, opts]}. The 4-tuple
  # form carries no opts and therefore the DEFAULT `auth: :admin` — read straight off
  # BarkparkWeb.Router.Plugins.route_in_scope?/2, which is the code that actually mounts
  # them, so this derivation and the compiler agree by construction rather than by hope.
  defp route_specs(node), do: node |> specs_walk([]) |> Enum.reverse()

  defp specs_walk({:{}, _, [m, path, mod, action]}, acc) do
    case {action_atom(m), string_lit(path)} do
      {m, p} when is_atom(m) and is_binary(p) and m != :__dynamic__ ->
        [%{method: m, path: p, module: alias_string([], mod), action: action_atom(action), auth: :admin} | acc]

      _ ->
        acc
    end
  end

  defp specs_walk({:{}, _, [m, path, mod, action, opts]}, acc) do
    case {action_atom(m), string_lit(path)} do
      {m, p} when is_atom(m) and is_binary(p) and m != :__dynamic__ ->
        [%{method: m, path: p, module: alias_string([], mod), action: action_atom(action),
           auth: kw_lit(opts, :auth) || :admin} | acc]

      _ ->
        acc
    end
  end

  defp specs_walk({_, _, args}, acc) when is_list(args), do: Enum.reduce(args, acc, &specs_walk/2)
  defp specs_walk({a, b}, acc), do: specs_walk(b, specs_walk(a, acc))
  defp specs_walk(l, acc) when is_list(l), do: Enum.reduce(l, acc, &specs_walk/2)
  defp specs_walk(_, acc), do: acc

  defp kw_lit(opts, key) when is_list(opts) do
    Enum.find_value(opts, fn
      {k, v} -> if action_atom(k) == key, do: action_atom(v)
      _ -> nil
    end)
  end

  defp kw_lit(_, _), do: nil

  # `:public` is the CALLSITE name and `:none` the SPEC-SIDE spelling of the same bucket
  # (BarkparkWeb.Router.Plugins.auth_matches_scope?/2). Missing it drops every public
  # plugin route silently.
  defp auth_in_scope?(:none, :public), do: true
  defp auth_in_scope?(auth, scope), do: auth == scope

  # -- disposition ------------------------------------------------------------
  #
  # PRECEDENCE, EXACTLY ONCE: JUDGED > ROSTERED > EXCLUDED > UNDISPOSED. JUDGED and
  # ROSTERED are DERIVED every run (a receipt that moves keeps its judgement); EXCLUDED is
  # committed data pinned to the QUAD, which is what makes an arriving route visible.
  #
  # THE JUDGED RELATION IS ONE HOP, AND SAYING SO IS THE POINT. A receipt in the action's
  # own span counts, and so does one in a def the action CALLS LOCALLY (close/2 renders
  # through close_response/3). A receipt two helpers deep reads as EXCLUDED here — that is
  # a stated limit of this relation, not a hidden one.
  defp dispose_routed(population, classified, parsed, index) do
    receipts = receipt_functions(classified)
    rostered = roster_functions(parsed)
    module_files = module_file_index(parsed)
    committed = Map.new(@routed_excluded, fn {m, p, mod, a, c} -> {{m, p, mod, a}, c} end)

    disposed =
      Enum.map(population, fn {_m, _p, mod, action} = key ->
        cond do
          reaches?(index, mod, action, receipts) -> {key, :judged, nil}
          reaches?(index, mod, action, rostered) -> {key, :rostered, nil}
          Map.has_key?(committed, key) -> {key, :excluded, Map.fetch!(committed, key)}
          true -> {key, :undisposed, nil}
        end
      end)

    live = MapSet.new(population)

    orphans =
      for {m, p, mod, a, c} <- @routed_excluded,
          not MapSet.member?(live, {m, p, mod, a}),
          Map.has_key?(module_files, mod),
          do: {{m, p, mod, a}, c}

    dupes =
      @routed_excluded
      |> Enum.frequencies_by(fn {m, p, mod, a, _c} -> {m, p, mod, a} end)
      |> Enum.filter(fn {_k, n} -> n > 1 end)
      |> Enum.map(&elem(&1, 0))

    # ---- THE JUDGMENT-COVERAGE LADDER, TAKEN EXACTLY ONCE, HERE -------------------
    #
    # THE TOP RUNG IS A UNION AND MUST NEVER BE A SUM. leg_a and leg_b are two
    # INDEPENDENT predicates over the SAME population — a member can reach a PROVEN
    # register def AND a PROVEN roster def, and adding the legs would count it twice.
    # DO NOT COPY THE SHAPE OF THE `sum` LINE IN THE DISPOSITION BLOCK BELOW: that bare
    # four-term plus is sound ONLY because the cond above assigns EXACTLY ONE label per
    # member, so its four classes are disjoint BY CONSTRUCTION. Nothing makes these two
    # legs disjoint. OVERLAP is 0 on today's tree, which means the addition and the
    # union print the SAME 23 — the number is no evidence at all, and the injection
    # mutants (selftest LADDER-UNION-NOT-SUM) are the only thing that can tell them
    # apart. The count is taken HERE, once; the report only reads it.
    leg_a = members_reaching(population, index, receipt_functions(classified, :proven, [:live, :stale]))
    leg_b = members_reaching(population, index, roster_functions(parsed, :proven))
    proven_backed = MapSet.union(leg_a, leg_b)

    verdicted =
      MapSet.union(
        members_reaching(
          population,
          index,
          receipt_functions(classified, {:in, ["PROVEN", "REFUTED"]}, [:live, :stale])
        ),
        members_reaching(population, index, roster_functions(parsed, {:in, ["PROVEN", "REFUTED"]}))
      )

    # THE TWO ZEROES, DERIVED RATHER THAN ASSUMED — both printed, because an arm nobody
    # can see failing is an arm nobody knows is asleep.
    loose_judged = members_reaching(population, index, receipts)
    loose_rostered = members_reaching(population, index, rostered)
    fresh_only_defs = receipt_functions(classified, :proven, [:live])
    proven_defs = receipt_functions(classified, :proven, [:live, :stale])

    ladder = %{
      # COUNTED, NOT ADDED, even here where the cond guarantees disjointness — one
      # traversal over the labels asks nothing of the reader.
      judged_coverage: Enum.count(disposed, &(elem(&1, 1) in [:judged, :rostered])),
      leg_a: MapSet.size(leg_a),
      leg_b: MapSet.size(leg_b),
      naive_sum: MapSet.size(leg_a) + MapSet.size(leg_b),
      proven_backed: Enum.count(proven_backed),
      overlap: MapSet.size(MapSet.intersection(leg_a, leg_b)),
      verdicted: Enum.count(verdicted),
      # precedence suppression: how many members the cond's JUDGED > ROSTERED order
      # hides from the printed ROSTERED count, and how many EXCLUDED hides from JUDGED.
      suppressed_rostered: MapSet.size(loose_rostered) - Enum.count(disposed, &(elem(&1, 1) == :rostered)),
      suppressed_judged: MapSet.size(loose_judged) - Enum.count(disposed, &(elem(&1, 1) == :judged)),
      proven_defs: MapSet.size(proven_defs),
      proven_defs_live_only: MapSet.size(fresh_only_defs),
      # THE WRONG ANSWER THAT SHARES THE RIGHT ANSWER'S VALUE, derived rather than
      # asserted — and derived as a UNION here too, because a plus is what got this
      # slice written.
      def_union: MapSet.size(MapSet.union(proven_defs, roster_functions(parsed, :any)))
    }

    %{
      ladder: ladder,
      rows: disposed,
      judged: Enum.count(disposed, &(elem(&1, 1) == :judged)),
      rostered: Enum.count(disposed, &(elem(&1, 1) == :rostered)),
      excluded: Enum.count(disposed, &(elem(&1, 1) == :excluded)),
      undisposed: for({k, :undisposed, _} <- disposed, do: k),
      orphans: orphans,
      dupes: dupes,
      classes: Enum.frequencies(for {_k, :excluded, c} <- disposed, do: c)
    }
  end

  # {module string, function name} of every def that OWNS a register-covered emitted site.
  #
  # BOTH LEGS TOOK A VERDICT ARGUMENT IN WAVE 45, AND NEITHER HAD ONE BEFORE. This
  # comprehension bound the register row to `_row` and filtered on FRESHNESS ALONE, so
  # "the register judged it" meant "the register has a ROW for it" — including a row
  # whose committed verdict is UNJUDGED. Its sibling roster_functions/1 carried no
  # verdict test either. DISPOSITION still asks the loose question on purpose (`:any`):
  # JUDGED means "this lens can see a receipt and a register row keys it", and narrowing
  # THAT would silently re-label judged members EXCLUDED. `:proven` is the ladder's leg,
  # which asks the strictly harder question the ladder's top rung is named after.
  defp receipt_functions(classified), do: receipt_functions(classified, :any, [:live, :stale])

  defp receipt_functions(classified, verdicts, statuses) do
    for {row, status, site} <- resolve_register(classified),
        status in statuses,
        verdict_admits?(verdicts, row.verdict),
        %{def: {mod, name, _ar, _ln}} <- [site],
        into: MapSet.new(),
        do: {Enum.join(mod, "."), name}
  end

  # The roster names LITERALS, not functions. Resolve each literal to the def that
  # contains it, so a routed action can be disposed ROSTERED by the same anchor the
  # ROSTER-ANCHORS-EXIST arm already keeps honest.
  defp roster_functions(parsed), do: roster_functions(parsed, :any)

  defp roster_functions(parsed, verdicts) do
    by_path = Map.new(parsed, &{&1.path, &1})

    for r <- @roster,
        verdict_admits?(verdicts, r.verdict),
        f = Map.get(by_path, r.path),
        f != nil,
        {:ok, line} <- [roster_anchor(%{r.path => f.src}, r)],
        d <- f.defs,
        d.line <= line and line <= d.last,
        into: MapSet.new(),
        do: {Enum.join(d.module, "."), d.name}
  end

  # THE COUNT-FREE DISCRIMINATOR. The selftest asserts arm names and refusal prose and
  # NEVER a bucket count, so the injection proof cannot be shipped as "expect 24" — an
  # honest register edit would red it. It is shipped as this TOKEN instead: it flips the
  # moment the naive addition and the union stop agreeing, which is precisely the
  # condition an implementation that ADDED the legs could never produce.
  defp union_verdict(%{naive_sum: n, proven_backed: u}) when n == u,
    do: "[naive == UNION — no member is reached by both legs on this tree, so the number ALONE proves nothing about which computation produced it]"

  defp union_verdict(%{naive_sum: n, proven_backed: u}),
    do: "[naive > UNION — the addition would OVERCOUNT by #{n - u} member(s); the union held]"

  # ONE verdict predicate for both legs, because two spellings of "is it PROVEN" is how
  # the legs drift apart under the next edit.
  defp verdict_admits?(:any, _v), do: true
  defp verdict_admits?(:proven, v), do: v == "PROVEN"
  defp verdict_admits?({:in, list}, v), do: v in list

  # The members of the population that REACH any def in `targets` — no precedence, no
  # suppression. A LADDER RUNG IS A SET OF MEMBERS, NOT A PARTITION CLASS: two rungs may
  # overlap, which is exactly why the top rung is a union and never a sum.
  defp members_reaching(population, index, targets) do
    for {_m, _p, mod, action} = key <- population,
        reaches?(index, mod, action, targets),
        into: MapSet.new(),
        do: key
  end

  defp module_file_index(parsed) do
    for f <- parsed, d <- f.defs, into: %{}, do: {Enum.join(d.module, "."), f.path}
  end

  # Direct hit, or ONE local hop out of the action's own body.
  defp reaches?(index, module, action, targets) do
    MapSet.member?(targets, {module, action}) or
      index
      |> action_defs(module, action)
      |> Enum.any?(fn d ->
        Enum.any?(d.calls, fn
          {:local, f, _ar} -> MapSet.member?(targets, {module, f})
          _ -> false
        end)
      end)
  end

  defp action_defs(index, module, action) do
    segs = module |> String.split(".") |> Enum.map(&String.to_atom/1)
    Map.get(index.by_key, {segs, action}, [])
  end

  # ------------------------------------- derivation partition (PDS wave 40)
  #
  # THE CLASS PROSE MADE TWO CLAIMS AND ONLY ONE OF THEM WAS TRUE. Wave 38 wrote
  # `status_only_receipt` as (A) "the routed action reaches no `ok: true` receipt this
  # lens can see" AND (B) "it claims success by STATUS alone". Clause A is a property of
  # THIS LENS and holds for every member by construction. Clause B is a claim about the
  # CODE, and this pass measures it: most of these rows DO render the stored row, they
  # simply do not spell the key the lens greps for. A gate whose largest exclusion class
  # is described by a sentence false of two thirds of its members is the same vacuity
  # this epic has now chased through the lens (w37), the key (w38) and the bucket (w39),
  # wearing a fourth costume — so clause B is retired and replaced by the partition here.
  #
  # WHAT IT MAY AND MAY NOT TOUCH. This classifier RE-LABELS EXCLUDED SUB-CLASSES AND
  # NOTHING ELSE. It never feeds receipt_functions/1 or roster_functions/1, and
  # dispose_routed/4's cond is untouched, so a WRONG classifier here costs a MISLEADING
  # LABEL and cannot cost a FALSE GREEN on coverage — the blast radius is capped by
  # construction rather than by care.
  #
  # THE CLASS SET IS FIVE DECIDED CLASSES PLUS A RESIDUAL, NEVER A BINARY. A
  # store_derived/request_echo split mis-accuses three real families this corpus carries:
  # a receipt that renders a FRESH STORE READ after discarding the write's own return
  # (CycleFleetController.{open,seal,promote,quarantine,rollback} render a `projection`;
  # V1.MediaProcessingController.callback renders a `get_file` result) is neither honest
  # store-derivation nor an echo; a receipt whose body is a LITERAL describes the store by
  # value ZERO and the request by ZERO; and a redirect/flash whose text is a CONSTANT
  # gated on an `{:ok, _}` whose payload is thrown away is a third shape again.
  @derivation_class :status_only_receipt

  # PRECEDENCE FOR A MULTI-CLAUSE ACTION: the most informative verdict any clause earns
  # is the row's verdict. An action with one clause that renders the stored row and
  # another that renders a literal DOES describe the store somewhere, and calling the
  # whole row literal_only would understate it.
  @derivation_order [
    :store_derived,
    :reread_receipt,
    :request_echo,
    :control_flow_gated_literal,
    :literal_only,
    :residual_helper_assembled,
    :residual_onehop_unattributed,
    :residual_undecided
  ]

  @derivation_residual [
    :residual_helper_assembled,
    :residual_onehop_unattributed,
    :residual_undecided
  ]

  @derivation_prose %{
    store_derived:
      "the receipt renders a value bound out of an `{:ok, _}` payload whose producing call is NOT read-shaped — the response describes the row the write returned. Clause B of the wave-38 prose is FALSE of these rows.",
    reread_receipt:
      "the receipt renders an `{:ok, _}` payload from a READ-shaped call (get_/fetch_/list_/projection/...). The write's own return was discarded and the store was asked again; honest about the store, but one round trip away from the write it claims.",
    request_echo:
      "the receipt renders values bound in the action's own HEAD — request params. It describes what the CALLER SENT, not what the store holds: the species #9114 found six of on DELETE verbs, where a lying receipt costs a person the most.",
    control_flow_gated_literal:
      "the body is a CONSTANT (a redirect or a flash whose text carries no bound value) reached only inside an `{:ok, _}` branch whose payload is discarded. Describing the store by value: ZERO. Describing the request: ZERO. Neither derived nor an echo — success is asserted by CONTROL FLOW.",
    literal_only:
      "the response body carries no bound value at all and no discarded `{:ok, _}` gate this pass could attribute — a 204/empty-body or a fixed literal. This IS wave 38's clause B, and this class is how many rows actually deserved it.",
    residual_helper_assembled:
      "RESIDUAL, NOT DECIDED: the action's own body contains no response call — the receipt is assembled inside a helper. Bindings join across the hop and this pass declines to follow them rather than guess.",
    residual_onehop_unattributed:
      "RESIDUAL, NOT DECIDED: a response call exists and renders bound values, but none of them trace to an `{:ok, _}` payload OR to the action's head — they are bound by an intermediate this pass does not attribute.",
    residual_undecided:
      "RESIDUAL, NOT DECIDED: no response call and no local helper call in the action's own body (a defdelegate, a macro-generated action, or a clause whose whole body this pass cannot read)."
  }

  # The response emitters this pass reads. NOT a receipt-detection relation — those live
  # in collect_sites/2 and are untouched — just the places a controller hands bytes back.
  @derivation_render_fns [:json, :text, :html, :send_resp, :redirect, :render, :put_flash]

  # READ-SHAPED PRODUCER NAMES. THIS IS A STRING TEST AND IT IS PRINTED AS ONE: every row
  # below prints the producing call NAME it was classified on, so a reader can check the
  # verdict against the source instead of trusting a list they cannot see.
  @derivation_reread_stems ~w(get fetch load list read find lookup show query projection
                              current preview)

  defp derivation_partition(disp, index) do
    for {{_m, _p, mod, action} = key, :excluded, class} <- disp.rows,
        class == @derivation_class,
        do: Map.put(derive_row(mod, action, index), :key, key)
  end

  # THE ROW IS A MIN OVER ITS CLAUSES, AND THAT MIN IS A MASK (PDS wave 41). Any decided
  # class outranks any residual one, so a two-clause action with one store_derived clause
  # and one helper-assembled clause PRINTS store_derived and its residual clause is
  # invisible in every count on the page. The min_by below is UNCHANGED — the precedence
  # FIX is filed separately (pds-bl-w41-clause-precedence-mask) because it moves printed
  # classes. What changes here is that the row now CARRIES its clause verdicts, both the
  # local one and the post-hop one, so the mask can be COUNTED instead of inferred.
  defp derive_row(mod, action, index) do
    case action_defs(index, mod, action) do
      [] ->
        %{
          class: :residual_undecided,
          producer: "-",
          clauses: 0,
          scope_read: :no_body,
          why: "the routed action resolves to no def this pass can open",
          clause_results: []
        }

      defs ->
        results = Enum.map(defs, &derive_def(&1, index))

        results
        |> Enum.min_by(&derivation_rank(&1.class))
        |> Map.put(:clauses, length(defs))
        |> Map.put(:clause_results, Enum.map(results, &Map.take(&1, [:id, :class, :pre_class, :hop, :why])))
    end
  end

  defp derivation_rank(class), do: Enum.find_index(@derivation_order, &(&1 == class)) || 99

  defp derive_def(d, index), do: derive_def(d, index, nil)

  defp derive_def(%{body: nil} = d, _index, _subst),
    do: %{
      class: :residual_undecided,
      pre_class: :residual_undecided,
      producer: "-",
      scope_read: :no_body,
      why: "defdelegate — no body to read",
      id: clause_id(d),
      hop: nil
    }

  defp derive_def(d, index, subst) do
    body = expand_pipes(d.body)
    {oks_own, discarded} = ok_walk(body)
    head_own = dvars(d.head)

    # THE HOP SUBSTITUTES THE CALLER'S ARGUMENTS, IT DOES NOT REUSE THE CALLEE'S HEAD.
    # `subst` is nil for an action's own clause and carries {oks, head, params} when this
    # def is being read as a ONE-HOP callee: a parameter bound to a caller expression that
    # came out of an `{:ok, _}` payload is a STORE value inside the callee, and a parameter
    # bound to a caller HEAD var is a request echo. Reusing the callee's own head instead
    # would print request_echo for EVERY helper that names its response value in a
    # parameter — flatly wrong the first time that parameter IS a write return.
    #
    # AND THE SUBSTITUTION READS THE ARGUMENT'S TOP-LEVEL SHAPE, not its flattened names
    # (PDS wave 42). Until wave 42 the four TicketKeys rows classed request_echo because
    # `stamp_response(conn, Keys.pause(id, …))` contributed the CALL'S OWN ARGUMENT NAMES —
    # so the head var `id` landed in the parameter pattern `{:ok, key}` and the join
    # accused a value that descends from the write. hop_arg_shape/1 now attributes the
    # call's RETURN. `AuthController.register` was named alongside them in that prose and
    # never sat on this mechanism at all: it passes the plain head var `email` and renders
    # `%{user: %{email: email}}`, so its request_echo was TRUE before this fix and stays
    # true after it — which is why it is the control the fix is checked against.
    {oks, head} = apply_hop_subst(oks_own, head_own, subst)

    # READ THE SUCCESS BRANCH, NOT THE WHOLE BODY, WHENEVER THERE IS ONE. A controller's
    # error branches render CHANGESETS and re-render FORMS out of the request, so unioning
    # them with the success payload made every gated flash read as a request echo — a
    # measured mis-verdict, not a hypothetical one: SessionController.reset_submit landed
    # in request_echo on the `token: token` its FAILURE branch re-renders. When no clause
    # pattern is `{:ok, _}` (the straight-line `{:ok, row} = ...` style) the whole body is
    # the success path and is read as such.
    scopes = success_scopes(body)
    scoped = Enum.flat_map(scopes, &response_emissions/1)
    fallback? = scopes == [] or scoped == []
    emits = if fallback?, do: response_emissions(body), else: scoped

    payload_vars =
      Enum.reduce(emits, MapSet.new(), fn {_kind, expr}, acc ->
        MapSet.union(acc, dvars(expr))
      end)

    used = for v <- payload_vars, Map.has_key?(oks, v), do: Map.fetch!(oks, v)
    gate = names(discarded)

    # WHICH REGION DECIDED THIS CLAUSE IS RECORDED, NOT ASSERTED (PDS wave 40 review).
    # The blind-shape block used to state "the whole def body is read", which stopped
    # being true the moment success_scopes/1 landed — committed prose outliving its own
    # code is the exact species this epic hunts, so the region is stamped per clause here
    # and the two counts are DERIVED into the printed blind shape instead of described.
    scope_read = if fallback?, do: :whole_body, else: :success_branch

    local =
      cond do
        emits == [] ->
          if local_helper_call?(d),
            do: %{class: :residual_helper_assembled, producer: "-", why: "no response call in this clause"},
            else: %{class: :residual_undecided, producer: "-", why: "no response call, no local helper call"}

        used != [] ->
          producers = names(used)

          if Enum.all?(producers, &derivation_reread_name?/1),
            do: %{class: :reread_receipt, producer: Enum.join(producers, "+"), why: "read-shaped producer"},
            else: %{class: :store_derived, producer: Enum.join(producers, "+"), why: "write-shaped producer"}

        MapSet.size(payload_vars) == 0 ->
          gated? = Enum.any?(emits, fn {k, _} -> k in [:redirect, :put_flash] end) and gate != []

          if gated?,
            do: %{class: :control_flow_gated_literal, producer: Enum.join(gate, "+"), why: "constant behind a discarded {:ok, _}"},
            else: %{class: :literal_only, producer: gate_or_dash(gate), why: "no bound value in the body"}

        not MapSet.disjoint?(payload_vars, head) ->
          %{class: :request_echo, producer: gate_or_dash(gate), why: "renders a value bound in the action's HEAD"}

        true ->
          %{class: :residual_onehop_unattributed, producer: gate_or_dash(gate), why: "bound values trace to neither an {:ok, _} payload nor the head"}
      end
      |> Map.merge(%{scope_read: scope_read, id: clause_id(d), hop: nil})
      |> then(&Map.put(&1, :pre_class, &1.class))

    # ONE HOP, AND NEVER TWO: a clause reached AS a hop target carries a subst and is
    # classified where it stands. That is what makes `Auth.login` -> `issue_session/3` ->
    # `SessionIssuer.issue/3` stay residual instead of quietly becoming a two-hop join.
    if subst == nil and local.class == :residual_helper_assembled,
      do: onehop_join(d, index, body, oks, head, local),
      else: local
  end

  # A CLAUSE IDENTITY, DERIVED IN-RUN AND NEVER PERSISTED. {module, name, path, line} is
  # stable for the length of ONE run and meaningless across commits, which is exactly the
  # lifetime it is used for: de-duplicating the clause counts below, where one def clause
  # is reached by TWO routed quads (V1.MediaController.upload) and would otherwise be
  # counted twice in a population that calls itself DISTINCT.
  defp clause_id(d), do: {Enum.join(d.module, "."), d.name, d.path, d.line}

  defp apply_hop_subst(oks, head, nil), do: {oks, head}

  defp apply_hop_subst(oks, head, s),
    do: {Map.merge(s.oks, oks), head |> MapSet.difference(s.params) |> MapSet.union(s.head)}

  # -- the one-hop join (PDS wave 41) -----------------------------------------
  #
  # WHY THIS IS NOT PDS-D573 REOPENED. D573 cut a one-hop DEPTH widening after two
  # refutations, and both of those asked whether an `ok: true` EMITTER exists downstream —
  # a question about COVERAGE, and the answer stayed no. This asks a different predicate
  # over the same edge: does the VALUE this receipt renders descend from the write return?
  # It changes no coverage number and cannot: the join runs INSIDE the derivation
  # partition, over rows dispose_routed/4 has already EXCLUDED, and its only output is a
  # label. A wrong join here costs a misleading class, never a false green.
  #
  # LOCAL **OR** REMOTE-RESOLVED, and the difference is measured, not stylistic:
  # `WebauthnController.login`'s only converting target is the REMOTE SessionIssuer.issue/3,
  # so a local-only rule scores one lower and would have called that row unattributable.
  #
  # THE TIE-BREAK IS MIN-BY @derivation_order OVER EVERY EMITTING CANDIDATE. Several of
  # these clauses call three helpers that all respond; taking the first, the last, or
  # demanding a unique target each measures a different and smaller number.
  #
  # A HOP MAY DECIDE A CLAUSE OR LEAVE IT EXACTLY AS IT WAS — it may NEVER move a clause
  # from one residual class to another. That is the shape criterion (C) exists to catch: a
  # residual class that shrinks while nothing gets decided is a smaller accusation, not a
  # better one.
  #
  # A CLAUSE THAT EMITS NOTHING IS NOT A CANDIDATE. These two classes are precisely the
  # "no response call in this def" verdicts, so a target wearing one is a SECOND hop.
  @derivation_mute [:residual_helper_assembled, :residual_undecided]

  defp onehop_join(d, index, body, oks, head, local) do
    substs =
      body
      |> hop_calls()
      |> Enum.flat_map(&hop_defs(d, index, &1))
      |> Enum.reject(fn {callee, _args} -> callee.module == d.module and callee.name == d.name end)
      |> Enum.uniq_by(fn {callee, args} -> {clause_id(callee), length(args)} end)
      |> Enum.map(fn {callee, args} -> {callee, hop_subst(callee, args, oks, head)} end)

    minted = Enum.reduce(substs, 0, fn {_callee, s}, n -> n + s.minted end)
    opaque = Enum.reduce(substs, 0, fn {_callee, s}, n -> n + s.opaque end)
    field = Enum.reduce(substs, 0, fn {_callee, s}, n -> n + s.field end)

    cands =
      Enum.map(substs, fn {callee, s} ->
        {hop_label(callee), derive_def(callee, index, s), s.minted}
      end)

    {emitting, mute} = Enum.split_with(cands, &(elem(&1, 1).class not in @derivation_mute))

    decided =
      Enum.filter(emitting, &(derivation_rank(elem(&1, 1).class) <= derivation_rank(:literal_only)))

    case decided do
      [] ->
        %{
          local
          | why: hop_refusal(emitting, mute),
            hop: %{
              decided: nil,
              target: nil,
              candidates: length(cands),
              minted: minted,
              minted_decided: 0,
              opaque: opaque,
              field: field
            }
        }

      _ ->
        {label, best, best_minted} = Enum.min_by(decided, &derivation_rank(elem(&1, 1).class))

        %{
          local
          | class: best.class,
            producer: best.producer,
            why: "ONE HOP into #{label} — #{best.why} (this clause's own body has no response call)",
            hop: %{
              decided: best.class,
              target: label,
              candidates: length(cands),
              minted: minted,
              minted_decided: best_minted,
              opaque: opaque,
              field: field
            }
        }
    end
  end

  # THE REFUSAL IS PRINTED AND FALSIFIABLE, never a shrug. Every candidate the join reached
  # is named with the verdict that disqualified it, so a reader can open the callee and
  # take the claim apart.
  defp hop_refusal([], []), do: "no response call in this clause, and NO hop target resolves in this corpus"

  defp hop_refusal(emitting, mute) do
    parts =
      (Enum.map(mute, fn {l, _, _} -> "#{l} [emits nothing — a SECOND hop]" end) ++
         Enum.map(emitting, fn {l, r, _} -> "#{l} [emits, but classes #{r.class}: #{r.why}]" end))
      |> Enum.uniq()

    "no response call in this clause; the ONE-HOP join decides nothing over #{length(parts)} target(s): " <>
      Enum.join(parts, " · ")
  end

  defp hop_label(callee), do: "#{List.last(callee.module)}.#{callee.name}/#{callee.arity}"

  # LIKE raw_calls/1, BUT IT KEEPS THE ARGUMENT EXPRESSIONS. raw_calls/1 throws them away
  # for an arity, and the arity alone cannot say whether the value a helper renders came
  # out of the caller's write.
  defp hop_calls(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segs}, f]}, _, args} = n, acc when is_atom(f) and is_list(args) ->
          {n, [{:remote, segs, f, args} | acc]}

        {f, _, args} = n, acc when is_atom(f) and is_list(args) ->
          if Macro.special_form?(f, length(args)) or Macro.operator?(f, length(args)) or
               f in @derivation_render_fns do
            {n, acc}
          else
            {n, [{:local, f, args} | acc]}
          end

        n, acc ->
          {n, acc}
      end)

    Enum.reverse(acc)
  end

  # THE SAME RESOLUTION callees/2 USES, kept side by side with it on purpose: an imported
  # helper emits as {:local, f} and is STRUCTURALLY INVISIBLE without the import fallback.
  defp hop_defs(d, index, {:local, f, args}) do
    case at_arity(Map.get(index.by_key, {d.module, f}, []), length(args)) do
      [] -> imported_defs(index, d.module, f, length(args))
      defs -> defs
    end
    |> Enum.map(&{&1, args})
  end

  defp hop_defs(_d, index, {:remote, segs, f, args}),
    do: index |> resolve(segs, f, length(args)) |> Enum.map(&{&1, args})

  # THE ARGUMENT'S TOP-LEVEL SHAPE DECIDES WHAT IT CONTRIBUTES (PDS wave 42, PDS-D617).
  # dvars/1 is a Macro.prewalk that FLATTENS any node to a name set, so the argument
  # `Keys.pause(id, current_workspace_id(conn))` contributed `id` — a HEAD name — and the
  # callee clause classed request_echo on a value that in truth DESCENDS FROM THE WRITE.
  # The names INSIDE a call are its inputs; what the parameter binds is its RETURN. So:
  #
  #   {:call, f}  — the argument IS a call: attribute `f`, its own producing call.
  #   :opaque     — `Access.get` / `container[key]`: a subscript contributes NOTHING.
  #                 Without this, `params["totp_code"]` attributes producer `:get` and a
  #                 request param arrives dressed as a store binding — the same lie one
  #                 shape over.
  #   {:vars, s}  — everything else keeps the name-set behaviour, and FIELD ACCESS recurses
  #                 into its LHS (`cred.user_id` contributes `cred`, never producer
  #                 `:user_id`), because a field read is not a call at all.
  #
  # THE TEST IS ON THE TOP-LEVEL NODE, never "the argument CONTAINS a call" — AND THE
  # COARSE RULE WAS RUN RATHER THAN ARGUED ABOUT (PDS wave 42). A prewalk that attributes
  # the first call found ANYWHERE inside the argument — inside a map literal, inside a `fn`
  # body, inside `Accounts.get_user(cred.user_id)` — takes the MINTED-argument count from
  # 27 to 81 and puts a mint on 5 winning substitutions instead of 4. It moves no printed
  # class over THIS corpus, which is the danger stated exactly: it is a silent 3x
  # enlargement of the guessing surface, and the enlargement decides a row the first time
  # a payload names one of those parameters. The top-level test attributes what the
  # parameter actually BINDS; containment attributes something the expression merely
  # mentions, which is the same category error as the defect being repaired here.
  defp hop_arg_shape({{:., _, [Access, :get]}, _, [_ | _]}), do: :opaque

  defp hop_arg_shape({{:., _, [{:__aliases__, _, [:Access]}, :get]}, _, [_ | _]}), do: :opaque

  defp hop_arg_shape({{:., _, [{:__aliases__, _, _}, f]}, _, args})
       when is_atom(f) and is_list(args),
       do: {:call, f}

  defp hop_arg_shape({{:., _, [lhs, f]}, _, []}) when is_atom(f), do: hop_arg_shape(lhs)

  defp hop_arg_shape({{:., _, [_lhs, f]}, _, args}) when is_atom(f) and is_list(args),
    do: {:call, f}

  defp hop_arg_shape({f, _, args} = n) when is_atom(f) and is_list(args) do
    if Macro.special_form?(f, length(args)) or Macro.operator?(f, length(args)) or
         f in @derivation_render_fns,
       do: {:vars, dvars(n)},
       else: {:call, f}
  end

  defp hop_arg_shape(n), do: {:vars, dvars(n)}

  # THE TWO HARDENED SHAPES ARE COUNTED, because neither DECIDES a row in this corpus and a
  # guard whose effect is invisible is indistinguishable from one that was never written.
  # Attributing them would print producer `user_id` for `cred.user_id` and producer `get`
  # for `params["totp_code"]` — a request param dressed as a store binding — so the count
  # is the standing evidence that the shapes were excluded on purpose.
  defp hop_arg_field_access?({{:., _, [{:__aliases__, _, _}, _f]}, _, []}), do: false
  defp hop_arg_field_access?({{:., _, [_lhs, f]}, _, []}) when is_atom(f), do: true
  defp hop_arg_field_access?(_), do: false

  # A CALL ARGUMENT WHOSE OWN INPUTS TRACE NOWHERE IS A MINTED VALUE, and it is COUNTED
  # rather than given a class of its own (PDS-D618). Attributing the call name is right for
  # `Keys.pause(id, …)`, whose inputs trace to the head; it is a GUESS for a call whose
  # inputs trace to neither an `{:ok, _}` payload nor the head. None of those positions
  # decides a row today, so the count is printed on every run and the day one does decide a
  # row, the number moves in public instead of the verdict changing in silence.
  defp hop_arg_minted(arg, oks, head) do
    avars = dvars(arg)

    if Enum.find_value(avars, &Map.get(oks, &1)) == nil and MapSet.disjoint?(avars, head),
      do: 1,
      else: 0
  end

  defp hop_subst(callee, args, oks, head) do
    callee.head
    |> head_params()
    |> Enum.zip(args)
    |> Enum.reduce(
      %{oks: %{}, head: MapSet.new(), params: MapSet.new(), minted: 0, opaque: 0, field: 0},
      fn {param, arg}, acc ->
        hop_subst_arg(acc, param, arg, oks, head)
      end
    )
  end

  defp hop_subst_arg(acc, param, arg, oks, head) do
    pvars = dvars(param)
    acc = %{acc | params: MapSet.union(acc.params, pvars)}
    acc = if hop_arg_field_access?(arg), do: %{acc | field: acc.field + 1}, else: acc

    case hop_arg_shape(arg) do
      :opaque ->
        %{acc | opaque: acc.opaque + 1}

      {:call, producer} ->
        %{
          acc
          | oks: Enum.reduce(pvars, acc.oks, &Map.put(&2, &1, producer)),
            minted: acc.minted + hop_arg_minted(arg, oks, head)
        }

      {:vars, avars} ->
        case Enum.find_value(avars, &Map.get(oks, &1)) do
          nil ->
            if MapSet.disjoint?(avars, head),
              do: acc,
              else: %{acc | head: MapSet.union(acc.head, pvars)}

          producer ->
            %{acc | oks: Enum.reduce(pvars, acc.oks, &Map.put(&2, &1, producer))}
        end
    end
  end

  defp head_params({:when, _, [h | _]}), do: head_params(h)
  defp head_params({name, _, args}) when is_atom(name) and is_list(args), do: args
  defp head_params(_), do: []

  defp names(atoms), do: atoms |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()
  defp gate_or_dash([]), do: "-"
  defp gate_or_dash(gate), do: "(gate " <> Enum.join(gate, "+") <> ")"

  defp derivation_reread_name?(s) do
    Enum.any?(@derivation_reread_stems, &(s == &1 or String.starts_with?(s, &1 <> "_")))
  end

  defp local_helper_call?(d) do
    Enum.any?(raw_calls(d), fn
      {:local, f, _ar} -> f not in @derivation_render_fns
      _ -> false
    end)
  end

  # -- the two AST probes the partition rests on ------------------------------
  #
  # ok_walk/1 harvests every var bound inside an `{:ok, _}` PATTERN — from `=`, from `<-`
  # (so a `with` chain is read) and from `case` clause heads WITH THE SCRUTINEE
  # ATTRIBUTED, which is the whole reason reread_receipt is separable from store_derived.
  # A pattern whose payload binds NOTHING (`{:ok, _}`, `{:ok, _wave}`) is recorded on the
  # other side of the pair: it is a success GATE whose value was thrown away.
  defp ok_walk(body) do
    {_, {binds, disc}} =
      Macro.prewalk(body, {%{}, []}, fn
        {op, _, [lhs, rhs]} = n, acc when op in [:=, :<-] ->
          {n, note_ok(lhs, producer_name(rhs), acc)}

        {:case, _, [scrut, kw]} = n, acc when is_list(kw) ->
          {n, Enum.reduce(case_ok_patterns(kw), acc, &note_ok(&1, producer_name(scrut), &2))}

        n, acc ->
          {n, acc}
      end)

    {binds, Enum.reverse(disc)}
  end

  defp note_ok(lhs, producer, {binds, disc} = acc) do
    case ok_payload(lhs) do
      :no ->
        acc

      {:payload, inner} ->
        vs = dvars(inner)

        if MapSet.size(vs) == 0 do
          {binds, [producer | disc]}
        else
          {Enum.reduce(vs, binds, &Map.put_new(&2, &1, producer)), disc}
        end
    end
  end

  defp ok_payload({:when, _, [pat | _]}), do: ok_payload(pat)

  # THE LITERAL ENCODER WRAPS TWO-TUPLES TOO, AND MISSING THAT COSTS THE WHOLE PASS.
  # parse_file/1 parses with `literal_encoder:`, which encodes a 2-tuple as
  # `{:__block__, meta, [{a, b}]}` — not as the bare tuple. A first cut of this pass
  # matched only the bare form, found ZERO `{:ok, _}` bindings in the entire corpus, and
  # printed a partition with store_derived 0 and residual 101 that looked plausible and
  # was measuring nothing. Both shapes are read here.
  defp ok_payload({:__block__, _, [inner]}) when is_tuple(inner), do: ok_payload(inner)
  defp ok_payload({a, b}), do: if(ok_atom?(a), do: {:payload, b}, else: :no)

  # AND SO DOES TUPLE ARITY (PDS wave 41). A THREE-element ok tuple is not a tuple at all
  # in quoted form — `{:ok, written, receipt}` is `{:{}, meta, [:ok, written, receipt]}` —
  # so the two clauses above see NOTHING and every n-ary success binding in the corpus was
  # invisible. MediaController.put_blob (`{:ok, written, receipt} <- Media.put_blob(...)`,
  # rendering `written`, `receipt` and `byte_size(body)`) sat in the residual band PURELY
  # ON ARITY: a genuinely store-derived receipt the lens could not see. The whole payload
  # LIST is handed back — every element of an n-ary ok tuple is part of what succeeded.
  defp ok_payload({:{}, _, [a | rest]}) when rest != [],
    do: if(ok_atom?(a), do: {:payload, rest}, else: :no)

  defp ok_payload(_), do: :no

  defp ok_atom?(:ok), do: true
  defp ok_atom?({:__block__, _, [:ok]}), do: true
  defp ok_atom?(_), do: false

  # THE `{:ok, _}` BRANCHES, AS BODIES. A `case` clause whose head is an ok-pattern, and a
  # `with` whose chain carries one, both name a region of code reached ONLY on success.
  defp success_scopes(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {:case, _, [_scrut, kw]} = n, acc when is_list(kw) ->
          {n, ok_clause_bodies(kw) ++ acc}

        {:with, _, args} = n, acc when is_list(args) ->
          gated? =
            Enum.any?(args, fn
              {:<-, _, [lhs, _rhs]} -> ok_payload(lhs) != :no
              _ -> false
            end)

          {n, if(gated?, do: with_do_bodies(args) ++ acc, else: acc)}

        n, acc ->
          {n, acc}
      end)

    acc
  end

  defp ok_clause_bodies(kw) do
    for {k, clauses} <- kw,
        do_key?(k),
        is_list(clauses),
        {:->, _, [[pat], cbody]} <- clauses,
        ok_payload(pat) != :no,
        do: cbody
  end

  defp with_do_bodies(args) do
    case List.last(args) do
      kw when is_list(kw) -> for {k, b} <- kw, do_key?(k), do: b
      _ -> []
    end
  end

  defp case_ok_patterns(kw) do
    for {k, clauses} <- kw,
        do_key?(k),
        is_list(clauses),
        {:->, _, [[pat], _cbody]} <- clauses,
        do: pat
  end

  defp producer_name({:|>, _, [_l, r]}), do: producer_name(r)
  defp producer_name({:__block__, _, [inner]}), do: producer_name(inner)
  defp producer_name({{:., _, [_m, f]}, _, _}) when is_atom(f), do: f
  defp producer_name({f, _, args}) when is_atom(f) and is_list(args), do: f
  defp producer_name(_), do: :__opaque__

  # THE RESPONSE BODY, NOT THE RESPONSE. `redirect(conn, to: url)` contributes NO payload
  # on purpose: the bytes a person reads back are the flash and the destination page, and
  # neither describes the row that moved. Recording the `to:` expression would let a
  # redirect to `~p"/docs/#{id}"` read as store-derived on an id the CALLER supplied.
  defp response_emissions(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {f, _, [_c, payload]} = n, acc when f in [:json, :text, :html] ->
          {n, [{f, payload} | acc]}

        {:send_resp, _, [_c, _s, payload]} = n, acc ->
          {n, [{:send_resp, payload} | acc]}

        {:redirect, _, [_c, _opts]} = n, acc ->
          {n, [{:redirect, nil} | acc]}

        {:put_flash, _, [_c, _kind, msg]} = n, acc ->
          {n, [{:put_flash, msg} | acc]}

        {:render, _, [_c, _t, assigns]} = n, acc ->
          {n, [{:render, assigns} | acc]}

        {:render, _, [_c, _t]} = n, acc ->
          {n, [{:render, nil} | acc]}

        {{:., _, [_m, f]}, _, [_c, payload]} = n, acc when f in [:json, :text, :html] ->
          {n, [{f, payload} | acc]}

        n, acc ->
          {n, acc}
      end)

    Enum.reverse(acc)
  end

  # A NAME SET, AND THE BLIND SHAPE THAT COMES WITH IT (printed below): shadowing is not
  # modelled. `_`-prefixed names and `conn` are excluded — `conn` threads through every
  # response call and would make every row look bound.
  defp dvars(node) do
    {_, acc} =
      Macro.prewalk(node, MapSet.new(), fn
        {name, _, ctx} = n, acc when is_atom(name) and is_atom(ctx) ->
          s = Atom.to_string(name)

          if String.starts_with?(s, "_") or name == :conn,
            do: {n, acc},
            else: {n, MapSet.put(acc, name)}

        n, acc ->
          {n, acc}
      end)

    acc
  end

  # -- report -----------------------------------------------------------------

  defp report_routed_population(:no_router, _classified, _parsed, _index) do
    p("ROUTED-WRITE POPULATION — SKIPPED (this corpus carries no #{@router_path})")
    p(String.duplicate("-", 78))
    p("  NOT A PASS. Without the router there is no population to dispose, so the two")
    p("  arms below contribute nothing rather than a green nobody earned.")
    p("")
    :no_router
  end

  defp report_routed_population(d, classified, parsed, index) do
    disp = dispose_routed(d.population, classified, parsed, index)
    lives = Enum.filter(d.population, fn {m, _, _, _} -> m == @routed_live_method end)
    live_mods = lives |> Enum.map(fn {_, _, mod, _} -> mod end) |> Enum.uniq() |> length()
    pairs = d.population |> Enum.map(fn {_, _, mod, a} -> {mod, a} end) |> Enum.uniq() |> length()

    p("ROUTED-WRITE POPULATION — the denominator REGISTER-COMPLETE does not have")
    p(String.duplicate("-", 78))
    p("  key         {method, path, module, action}  (the QUAD; a {module, action} key")
    p("              collapses this population #{length(d.population)} -> #{pairs} and cannot see an arriving")
    p("              route to an action it already disposed)")
    p("  derived     #{length(d.routes)} routed entries from #{@router_path} AST + #{length(d.specs)} plugin spec(s)")
    p("              mounted at #{length(d.mounts)} #{@routed_resolved_macro}/1 callsite(s)")
    p("  ROUTED-WRITE #{length(d.population)} member(s) — methods #{Enum.map_join(@routed_write_methods, "/", &to_string/1)} plus every LiveView mount")

    p("")
    p("  DISPOSITION — every member exactly once")
    p("    JUDGED    #{pad(disp.judged)}  reaches a receipt this lens emitted AND the register judged")
    p("    ROSTERED  #{pad(disp.rostered)}  reaches a hand-named roster site outside the lens")
    p("    EXCLUDED  #{pad(disp.excluded)}  committed disposition row, by class:")

    Enum.each(Enum.sort(disp.classes), fn {class, n} ->
      p("      #{String.pad_trailing(to_string(class), 22)} #{pad(n)}")
      wrap(Map.get(@routed_exclusion_classes, class, "(no prose — see @routed_exclusion_classes)"), "               ")
    end)

    p("    UNDISPOSED #{pad(length(disp.undisposed))}  <- ROUTED-POPULATION-COMPLETE reds on this")
    p("    sum       #{pad(disp.judged + disp.rostered + disp.excluded + length(disp.undisposed))}  == population #{length(d.population)}")

    p("")
    lad = disp.ladder
    p("  JUDGMENT-COVERAGE LADDER — four rungs, each a subset of the one above BY")
    p("  CONSTRUCTION, and NOT asserted as one: rungs 3 and 4 filter the SAME reach")
    p("  relation the disposition uses, over a strictly narrower def set, so a printed")
    p("  subset check here could not fail — a green costing nothing to produce.")
    p("    THE UNIT IS MEMBERS AND SAYING SO IS LOAD-BEARING: #{lad.proven_backed} is ALSO the size of a")
    p("    DIFFERENT AND WRONG SET — |#{lad.proven_defs} proven register def(s) u every roster def| = #{lad.def_union} —")
    p("    which credits the roster's UNJUDGED rows to the top rung. A rung printed")
    p("    without its unit is ambiguous between that answer and this one, so every rung")
    p("    below says MEMBERS: members of the ROUTED-WRITE population, routed quads.")
    p("    1 population        #{pad(length(d.population))} MEMBERS  every routed-write quad")
    p("    2 judged-coverage   #{pad(lad.judged_coverage)} MEMBERS  disposed JUDGED or ROSTERED")
    p("    3 VERDICTED         #{pad(lad.verdicted)} MEMBERS  reaches a def whose register/roster row carries")
    p("                            an EXPLICIT verdict (PROVEN or REFUTED, not UNJUDGED)")
    p("    4 PROVEN-BACKED     #{pad(lad.proven_backed)} MEMBERS  reaches a def whose row is verdicted PROVEN")

    if lad.verdicted == lad.proven_backed do
      p("      RUNGS 3 AND 4 COINCIDE ON THIS TREE and that is a fact about the data, not")
      p("      about the rungs: zero rows carry REFUTED right now, in the register or the")
      p("      roster. The day one does, rung 3 rises above rung 4 and this line stops.")
    end

    p("    UNION, NEVER ADDITION: |A| #{lad.leg_a} + |B| #{lad.leg_b} = #{lad.naive_sum} naive; UNION #{lad.proven_backed}; OVERLAP #{lad.overlap}")
    p("      #{union_verdict(lad)}")
    wrap(
      "leg A is the members reaching a PROVEN register def, leg B the members reaching a " <>
        "PROVEN roster def. They are INDEPENDENT predicates over one population, so the top " <>
        "rung is Enum.count over ONE MapSet.union taken once in dispose_routed/4 — never " <>
        "leg_a + leg_b, and never the shape of the DISPOSITION `sum` line above, whose bare " <>
        "plus is sound only because the cond there assigns exactly one label per member. " <>
        "OVERLAP is #{lad.overlap} today, so the addition and the union print the SAME number and this " <>
        "line is the ONLY place a reader can see that they are not the same computation. " <>
        "The discriminator that can go RED is the selftest case LADDER-UNION-NOT-SUM, which " <>
        "injects a leg-B member into leg A and requires naive_sum to exceed a held UNION.",
      "      "
    )

    p("    THE ZEROES, PRINTED RATHER THAN IMPLIED — two arms that are NOT exercised today:")
    p("      precedence suppression removes #{lad.suppressed_rostered} member(s) from ROSTERED and")
    p("        #{lad.suppressed_judged} from JUDGED — the loose roster-reaching and receipt-reaching sets")
    p("        equal the printed counts, so the cond's JUDGED > ROSTERED order hides nothing")
    p("        on this tree and the ladder's legs are unaffected by it either way.")
    p("      the freshness arm is a NO-OP: #{lad.proven_defs_live_only} proven register def(s) at status :live and")
    p("        #{lad.proven_defs} at :live+:stale — the same set, because no PROVEN register row is stale")
    p("        right now. NOTHING BELOW IS EVIDENCE THAT THE :stale ARM WORKS.")

    p("")
    deriv = derivation_partition(disp, index)
    report_derivation_partition(deriv, Map.get(disp.classes, @derivation_class, 0))

    p("  EXCLUDED CLASS, PRINTED RATHER THAN ASSUMED: LiveView")
    p("    #{length(lives)} route entr(y/ies) over #{live_mods} distinct module(s). Every one is a MOUNT, not a")
    p("    {Controller, action} pair — the writes live in handle_event/3, which carries no")
    p("    routed action name at all. An arm silent about what it structurally cannot key")
    p("    inherits the exact vacuity it replaces, so the count is printed on every run.")
    p("")
    lv = report_liveview_population(lives, parsed, index)

    d |> Map.put(:disposition, disp) |> Map.put(:derivation, deriv) |> Map.put(:liveview, lv)
  end

  # THE PARTITION, PRINTED IN FULL. Every row prints the producing call NAME it was
  # classified on — a write-verb list that decides a verdict in silence is a string test
  # nobody can audit, so this one is spelled out row by row and can be checked against
  # the source by hand.
  defp report_derivation_partition(rows, class_total) do
    freqs = Enum.frequencies_by(rows, & &1.class)
    residual = Enum.reduce(@derivation_residual, 0, &(&2 + Map.get(freqs, &1, 0)))
    pairs = rows |> Enum.map(fn %{key: {_, _, mod, a}} -> {mod, a} end) |> Enum.uniq() |> length()

    scope_counts =
      rows
      |> Enum.frequencies_by(&Map.get(&1, :scope_read, :whole_body))
      |> then(&Map.merge(%{success_branch: 0, whole_body: 0, no_body: 0}, &1))

    # THE MINTED-ARGUMENT EXPOSURE, COUNTED OVER THE SAME CLAUSE SET THE JOIN ATTEMPTED
    # (uniq by clause id, so a def reached by two routed quads is counted once).
    hops = rows |> Enum.flat_map(&Map.get(&1, :clause_results, [])) |> Enum.uniq_by(& &1.id)
    minted = Enum.reduce(hops, 0, &(&2 + hop_stat(&1, :minted)))
    minted_deciding = Enum.reduce(hops, 0, &(&2 + hop_stat(&1, :minted_decided)))
    opaque_args = Enum.reduce(hops, 0, &(&2 + hop_stat(&1, :opaque)))
    field_args = Enum.reduce(hops, 0, &(&2 + hop_stat(&1, :field)))

    p("  DERIVATION PARTITION of the #{class_total} #{@derivation_class} row(s) — what the")
    p("  receipt ACTUALLY renders, DERIVED this run over #{pairs} distinct {module, action} pair(s)")
    p("  ------------------------------------------------------------------------")
    p("  Clause A of the class prose (\"reaches no `ok: true` receipt this lens can see\")")
    p("  holds for every row by construction. Clause B (\"claims success by STATUS alone\")")
    p("  is a claim about the CODE, and this is the measurement of it:")
    p("")

    Enum.each(@derivation_order, fn class ->
      n = Map.get(freqs, class, 0)
      p("    #{String.pad_trailing(to_string(class), 28)} #{pad(n)}")
      wrap(Map.fetch!(@derivation_prose, class), "                                 ")
    end)

    p("")
    p("    sum#{String.duplicate(" ", 26)} #{pad(Enum.sum(Map.values(freqs)))}  == #{@derivation_class} #{class_total}")
    p("    RESIDUAL (never folded into a decided class) #{pad(residual)}")
    p("")

    report_derivation_mask(rows)

    Enum.each(@derivation_order, fn class ->
      case Enum.filter(rows, &(&1.class == class)) do
        [] ->
          :ok

        members ->
          p("    #{class} — all #{length(members)}, each with the producing call it was classified on:")

          Enum.each(Enum.sort_by(members, fn %{key: {m, path, mod, a}} -> {mod, a, m, path} end), fn r ->
            {m, path, mod, action} = r.key
            p("      #{String.pad_trailing(to_string(m), 6)} #{path}")
            p("             #{mod}.#{action}  ·  via #{r.producer}  ·  #{r.clauses} clause(s)  ·  #{r.why}")
          end)

          p("")
      end
    end)

    report_onehop_join(rows)

    p("  WHAT THIS PARTITION CANNOT SEE (its own blind shapes, printed with it)")
    p("    · SHADOWING IS NOT MODELLED. dvars/1 is a NAME SET, so a name rebound between")
    p("      its `{:ok, _}` binding and the render still reads as store-derived here.")
    p("    · THE DENOMINATOR IS AN UPPER BOUND. The JUDGED relation upstream is ONE HOP")
    p("      (dispose_routed/4 says so): a receipt two helpers deep reads as EXCLUDED and")
    p("      lands in this partition rather than in JUDGED, so some rows below are not")
    p("      status-only at all — they are judged receipts the relation could not reach.")
    p("    · reread_receipt IS DECIDED BY THE PRODUCING CALL NAME, which is a string test.")
    p("      Every row above prints that name, so the verdict is auditable prose rather")
    p("      than a silent filter — check any row against its source and this pass loses.")
    p("    · WHICH REGION DECIDED THE ROW IS MEASURED, NOT ASSUMED. success_scopes/1 reads")
    p("      the `{:ok, _}` BRANCH where one carries a response call — #{scope_counts.success_branch} row(s) here.")
    p("      The other #{scope_counts.whole_body} fall back to the WHOLE def body (no attributable success scope),")
    p("      where an ERROR-branch payload can decide the verdict; #{scope_counts.no_body} row(s) have no body at")
    p("      all. And a def with two unrelated success scopes contributes BOTH — the union")
    p("      is taken, never proven benign.")
    p("    · A VALUE THE PLUG ALREADY LOADED IS INVISIBLE. dvars/1 drops `conn`, so a")
    p("      receipt built from `conn.assigns[:document]` — a store value fetched before")
    p("      the action ran — contributes no var and can read as literal_only.")
    p("    · A REDIRECT'S `to:` IS NOT A PAYLOAD. Recording it would let a redirect built")
    p("      from a caller-supplied id read as store-derived.")
    p("    · A HOP ARGUMENT THAT IS A CALL IS ATTRIBUTED ON ITS OWN RETURN, AND FOR SOME OF")
    p("      THEM THAT IS A GUESS. hop_arg_shape/1 reads the argument's TOP-LEVEL shape, so")
    p("      `stamp_response(conn, Keys.pause(id, ...))` now attributes producer `pause`")
    p("      instead of substituting the head var `id` into the parameter pattern")
    p("      `{:ok, key}` — that substitution is what made the TicketKeys rows class")
    p("      request_echo on a value that descends from the write. But #{minted} hop argument")
    p("      position(s) are calls whose OWN inputs trace to NEITHER an `{:ok, _}` payload")
    p("      NOR the head: their producer is MINTED from the call name alone, on no")
    p("      provenance at all. #{minted_deciding} of them sit on the substitution the join CHOSE, so")
    p("      that many are one parameter away from deciding a printed class. This is a")
    p("      COUNTED exposure rather than a class of its own (PDS-D618): the numbers are")
    p("      printed every run, so the day a mint decides a row it moves in public.")
    p("    · FIELD ACCESS AND SUBSCRIPTS ARE NOT CALLS, and are excluded BY SHAPE rather")
    p("      than by name — #{field_args} field-access and #{opaque_args} subscript hop argument position(s)")
    p("      this run. `cred.user_id` recurses into `cred`, and `params[\"totp_code\"]`")
    p("      contributes nothing at all. Attributing them would print producer `user_id`")
    p("      and producer `get` — a request param dressed as a store binding, which is the")
    p("      same over-accusation one shape over from the one just repaired. NEITHER count")
    p("      decides a row in this corpus, which is exactly why it is printed: a guard")
    p("      whose effect is invisible reads the same as one nobody wrote.")
    p("    · THE JOIN IS ONE HOP AND STOPS THERE. A helper that responds through a second")
    p("      helper stays residual by design, and its target is NAMED above as `emits")
    p("      nothing — a SECOND hop`, so the refusal can be checked instead of assumed.")
    p("")
  end

  # THE PRECEDENCE MASK, COUNTED RATHER THAN INFERRED (PDS wave 41).
  #
  # WHY A ROW COUNT CANNOT SEE THIS AT ALL. derive_row/3 takes the MIN over its clauses'
  # classes and every decided class outranks every residual one, so an action with one
  # store_derived clause and one helper-assembled clause prints store_derived and its
  # residual clause vanishes from the class list, from the RESIDUAL total, and from any
  # before/after comparison drawn over printed rows. The residual population is therefore
  # a CLAUSE population, and it is counted here as one — de-duplicated on the in-run clause
  # id, because one def clause can be reached by two routed quads.
  #
  # AND IT IS THE ONLY CHECK THAT CATCHES A CLASS SHRINKING WITHOUT DECIDING ANYTHING. The
  # one-hop join may DECIDE a residual clause or leave it exactly where it was; it may not
  # move one residual class into another. The two deltas below are printed side by side so
  # that invariant is arithmetic on the page rather than a promise in a comment.
  defp report_derivation_mask(rows) do
    clauses = rows |> Enum.flat_map(&Map.get(&1, :clause_results, [])) |> Enum.uniq_by(& &1.id)
    pre = derivation_mask(rows, clauses, :pre_class)
    post = derivation_mask(rows, clauses, :class)

    p("  THE PRECEDENCE MASK, PRINTED BOTH SIDES — clause-keyed over #{length(clauses)} distinct clause(s)")
    p("                                                    BEFORE HOP   AFTER HOP")
    p("    decided row(s) carrying a RESIDUAL clause         #{pad(pre.masked)}        #{pad(post.masked)}")
    p("    row(s) TOUCHING a residual clause                 #{pad(pre.touching)}        #{pad(post.touching)}")
    p("    distinct RESIDUAL clause(s)                       #{pad(pre.residual)}        #{pad(post.residual)}")
    p("    distinct DECIDED clause(s)                        #{pad(pre.decided)}        #{pad(post.decided)}")
    p("")

    p("    #{pre.residual - post.residual} residual clause(s) left the band and #{post.decided - pre.decided} decided clause(s) arrived — EQUAL, which is the whole")
    p("    check: a join that shrank a residual class WITHOUT deciding anything would show")
    p("    these two numbers apart, and a row count could not show it at all.")
    p("    The masked count moved #{pre.masked} -> #{post.masked} (#{mask_delta(post.masked - pre.masked)}). It RISES when the hop decides the")
    p("    clause a row was PRINTING while a second clause of that row stays residual — the")
    p("    row joins a decided class and its residual clause becomes newly masked, which is")
    p("    a disclosure rather than a regression. It is derived here either way.")
    p("")
  end

  defp mask_delta(0), do: "unchanged"
  defp mask_delta(n) when n > 0, do: "+#{n}"
  defp mask_delta(n), do: "#{n}"

  defp derivation_mask(rows, clauses, key) do
    residual? = fn c -> Map.fetch!(c, key) in @derivation_residual end
    touch? = fn r -> Enum.any?(Map.get(r, :clause_results, []), residual?) end
    residual = Enum.count(clauses, residual?)

    %{
      residual: residual,
      decided: length(clauses) - residual,
      touching: Enum.count(rows, touch?),
      masked: Enum.count(rows, &(row_class(&1, key) not in @derivation_residual and touch?.(&1)))
    }
  end

  defp hop_stat(%{hop: hop}, key) when is_map(hop), do: Map.get(hop, key, 0)
  defp hop_stat(_, _), do: 0

  defp row_class(%{clause_results: [_ | _] = cs}, key),
    do: cs |> Enum.min_by(&derivation_rank(Map.fetch!(&1, key))) |> Map.fetch!(key)

  defp row_class(r, _key), do: r.class

  # THE JOIN'S YIELD, AND EVERY REFUSAL IT MADE. A join that printed only its wins would be
  # the same instrument this epic keeps filing: the clauses it could NOT decide are listed
  # by name with the mechanism that stopped each one, so every line here can be opened and
  # taken apart. A measured ZERO with a falsifiable reason is a finding.
  defp report_onehop_join(rows) do
    attempted =
      rows
      |> Enum.flat_map(&Map.get(&1, :clause_results, []))
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(&(&1.pre_class == :residual_helper_assembled))

    {won, lost} = Enum.split_with(attempted, &(&1.class != &1.pre_class))
    breakdown = won |> Enum.frequencies_by(& &1.class) |> Enum.sort_by(fn {c, _} -> derivation_rank(c) end)

    p("  THE ONE-HOP JOIN over the helper-assembled band — LOCAL **or** REMOTE-resolved,")
    p("  tie-broken MIN-BY @derivation_order over EVERY emitting candidate")
    p("    clause(s) attempted   #{pad(length(attempted))}  (every clause whose own body carries no response call)")

    p("    DECIDED by the hop    #{pad(length(won))}  #{if breakdown == [], do: "-", else: Enum.map_join(breakdown, ", ", fn {c, n} -> "#{c} #{n}" end)}")

    p("    STILL RESIDUAL        #{pad(length(lost))}  each with the mechanism that stopped it, below")
    p("")
    p("    IT ASKS A DIFFERENT QUESTION FROM PDS-D573, over the same edge. D573's two")
    p("    refutations asked whether an `ok: true` EMITTER exists downstream — a coverage")
    p("    question, and the answer stayed no. This asks whether the VALUE the receipt")
    p("    renders DESCENDS from the write return, which is the wave-40 law in one hop.")
    p("")

    Enum.each(Enum.sort_by(lost, fn %{id: {mod, name, path, _}} -> {mod, name, path} end), fn c ->
      {mod, name, path, _line} = c.id
      p("      #{mod}.#{name}  ·  #{short(path)}")
      wrap(c.why, "             ")
    end)

    p("")
  end

  # -------------------------------------------- the LiveView WRITE population (L5)
  #
  # THE MOUNT COUNT IS NOT THE POPULATION (PDS wave 41). The block above prints how many
  # ROUTE ENTRIES mount a LiveView, and that is the honest count of a thing nobody writes
  # through: a mount performs no write. The writes live in `handle_event/3`, and until
  # wave 41 the census had no denominator for them at all — so an exclusion whose count
  # was printed was still an exclusion whose SIZE was unknown, which is the same silence
  # one indirection out.
  #
  # EVERYTHING BELOW IS DERIVED IN-PROCESS THROUGH THIS CENSUS'S OWN RESOLVER
  # (parse_file -> build_index -> bfs/verb_hits/callees). Membership is an AST shape — a
  # def named `handle_event` at arity 3 — never a name regex, and never a `live_session`
  # NAME (`:plugin_public` is EMPTY in this tree, so a name-keyed population silently
  # drops the anonymous rows). Routed-ness is reachability from a ROUTE: the module the
  # router names, joined to the module the def lives in.
  #
  # NO ARM READS ANY NUMBER THIS BLOCK PRINTS. It is a denominator for the NEXT wave to
  # judge against, and a print-only surface cannot manufacture a green.
  #
  # WHY EVERY FIGURE CARRIES A DENOMINATOR AND A DEPTH. The write-reaching numerators are
  # IDENTICAL over the routed 235 and the full 322 at every depth measured, because every
  # component clause is write-FALSE everywhere. Only the FRACTION tells the two lenses
  # apart, so a bare integer here would be unfalsifiable BY CONSTRUCTION — no run output
  # could ever catch it. That is why `n / d @depth` is the only shape used below.
  @lv_sweep [1, 2, 3, 4, 5, 6, 7, 8]
  @lv_beyond [9, 10, 12, 14]

  # THE PROCESS BOUNDARY, NAMED AS A SHAPE. `GenServer.call/2,3` leaves the caller's call
  # graph: callees/2 resolves no edge across it, so bfs/7 stops and the write on the far
  # side is invisible to every column above. Matched on the ALIAS TAIL, the same rule
  # @repo_mods rides.
  @lv_boundary_mod :GenServer
  @lv_boundary_funs [:call, :cast, :multi_call]

  defp report_liveview_population(lives, parsed, index) do
    route_mods = lives |> Enum.map(fn {_, _, mod, _} -> mod end) |> MapSet.new()
    pop = Enum.filter(index.defs, &(&1.name == :handle_event and &1.arity == 3))
    tele = Enum.filter(index.defs, &(&1.name == :handle_event and &1.arity == 4))

    p("  THE LIVEVIEW WRITE POPULATION — DERIVED THIS RUN, NEVER TRANSCRIBED (wave 41)")
    p("  ------------------------------------------------------------------------")

    case pop do
      [] ->
        p("    0 / #{length(index.defs)} corpus def(s) are handle_event/3 in this corpus — NOT A PASS, and")
        p("    not a claim about the real tree either. A population of zero is printed so")
        p("    the absence is a measurement, not a block that quietly did not run.")
        p("")
        :none

      _ ->
        lv_report(pop, tele, route_mods, parsed, index)
    end
  end

  defp lv_report(pop, tele, route_mods, parsed, index) do
    routed? = &MapSet.member?(route_mods, lv_mod(&1))
    {routed, comp} = Enum.split_with(pop, routed?)
    n = length(pop)
    nr = length(routed)
    nc = length(comp)
    raw = n + length(tele)

    files = pop |> Enum.map(& &1.path) |> Enum.uniq()
    mods = pop |> Enum.map(&lv_mod/1) |> Enum.uniq()
    comp_files = comp |> Enum.map(& &1.path) |> Enum.uniq()
    empty_mods = Enum.reject(route_mods, fn m -> Enum.any?(pop, &(lv_mod(&1) == m)) end)

    nm = length(index.modules)

    p("    POPULATION  #{n} / #{length(index.defs)} corpus def(s), over #{length(files)} / #{length(parsed)} corpus file(s)")
    p("                in #{length(mods)} / #{nm} corpus module(s)")
    p("      ROUTED     #{nr} / #{n} (#{lv_pct(nr, n)}) — clauses in the #{MapSet.size(route_mods)} / #{nm} module(s) the")
    p("                 live route(s) name")
    p("      COMPONENT  #{nc} / #{n} (#{lv_pct(nc, n)}) — LiveComponent clauses in #{length(comp_files)} / #{length(files)} file(s), no")
    p("                 route of their own, so no {method, path} key can ever reach them")
    p("      THE NAME-KEYED COUNT IS THE DENOMINATOR #{raw}, NOT THE POPULATION: #{n} / #{raw} are")
    p("      arity 3, and #{length(tele)} / #{raw} are handle_event/4 telemetry callback(s) over")
    p("      #{tele |> Enum.map(& &1.path) |> Enum.uniq() |> length()} / #{length(parsed)} file(s) — #{Enum.count(tele, &(&1.path in files))} / #{length(tele)} of them in a file that carries a")
    p("      handle_event/3 clause at all. The split is by ARITY off the def table: a")
    p("      grep cannot see an arity and does not, which is how a name-keyed")
    p("      derivation lands #{length(tele)} / #{raw} too high.")
    p("      #{length(empty_mods)} / #{MapSet.size(route_mods)} routed module(s) carry ZERO handle_event/3 clause(s), which is why")
    p("      the mount count cannot stand in for this one in either direction.")
    p("")

    rows =
      Enum.map(@lv_sweep ++ @lv_beyond, fn depth ->
        hits = Enum.filter(pop, &elem(lv_bfs(&1, index, depth), 0))
        %{depth: depth, full: length(hits), routed: Enum.count(hits, routed?)}
      end)

    last = List.last(rows)
    closes = Enum.find(rows, last, &(&1.full == last.full))
    at_max = Enum.find(rows, last, &(&1.depth == @max_depth))
    monotone? = rows |> Enum.map(& &1.full) |> then(&(&1 == Enum.sort(&1)))

    p("    WRITE-REACHING BY DEPTH — EVERY ROW A FLOOR, BOTH REASONS PRINTED BELOW")
    p("      depth   routed             full")

    Enum.each(rows, fn r ->
      mark =
        cond do
          r.depth == @max_depth -> "   <- @max_depth, the census budget"
          r.depth == closes.depth -> "   <- the relation CLOSES here"
          r.depth > @max_depth -> "   (past the census depth)"
          true -> ""
        end

      p("      #{String.pad_leading(to_string(r.depth), 2)}   #{pad(r.routed)} / #{nr} #{lv_cell(r.routed, nr)}  #{pad(r.full)} / #{n} #{lv_cell(r.full, n)}#{mark}")
    end)

    p("")
    p("      THE RELATION CLOSES AT #{closes.depth} — #{last.full} / #{n} @#{closes.depth} and FLAT at #{last.full} / #{n} through depths")
    p("      #{Enum.map_join(Enum.filter(rows, &(&1.depth > closes.depth)), ", ", &to_string(&1.depth))}. Measured PAST closure on purpose: a closure claim that stops")
    p("      at the closure has not observed the thing it asserts. Monotone in the budget:")
    p("      #{if monotone?, do: "YES", else: "NO — the sweep FELL somewhere; read the table, not this line"}.")
    at7 = Enum.find(rows, at_max, &(&1.depth == 7))
    p("      A TRANSCRIBED FIGURE IS REFUTED HERE: this run reads #{at7.routed} / #{nr} @7, so a note")
    p("      carrying #{last.full} / #{nr} @7 is off by #{last.full - at7.routed} / #{nr} and was copied, not measured.")
    p("      @max_depth is #{@max_depth} and is NOT changed by this block: #{at_max.routed} / #{nr} @#{@max_depth} is what the")
    p("      census's own budget sees; #{closes.full} / #{nr} @#{closes.depth} is what the relation closes at. BOTH")
    p("      are printed, because a lens that prints one of them is choosing an answer.")
    p("      FLOOR, REASON 1 — THE DEPTH BUDGET. #{at_max.routed} / #{nr} @#{@max_depth} rises to #{closes.routed} / #{nr} @#{closes.depth}.")
    p("      FLOOR, REASON 2 — THE KEY. bfs/7's seen-set and callees/2's uniq_by are BOTH")
    p("      {module, name, arity}, so exactly ONE clause per callee key is ever entered. A")
    p("      write living in a SECOND clause of an already-visited key is invisible at")
    p("      EVERY depth, and no budget buys it back. Neither reason is an estimate.")
    p("      THE SWEEP IS DENOMINATOR-BLIND: the routed and full NUMERATORS are identical")
    p("      at every depth above (all #{nc} / #{nc} component clauses are write-FALSE at every")
    p("      depth), so only the FRACTION tells the two lenses apart — #{lv_pct(at_max.routed, nr)} vs #{lv_pct(at_max.full, n)} @#{@max_depth}.")
    p("      A bare integer here could not be caught by any run output. Hence none is bare.")
    p("")

    lv_report_boundary(routed, comp, nr, nc, closes.depth, index)
    lv_report_keys(routed, pop, nr, n)
    lv_report_hooks(comp, n, nc, index)
    lv_report_hole(route_mods, comp, parsed, closes.depth, index)
    lv_verdict(pop, comp, route_mods, parsed, index)
  end

  # THE PROCESS BOUNDARY — THREE FIGURES, THREE UNITS, AND THE SUM IS THE ERROR.
  defp lv_report_boundary(routed, comp, nr, nc, closes, index) do
    deep = List.last(@lv_beyond)

    routed_cross =
      fn depth ->
        Enum.filter(routed, fn c ->
          {w, vis} = lv_bfs(c, index, depth)
          not w and lv_crosses?(vis)
        end)
      end

    rc_max = routed_cross.(@max_depth)
    rc_close = routed_cross.(closes)

    comp_vis = Enum.map(comp, fn c -> {c, elem(lv_bfs(c, index, deep), 1)} end)
    comp_cross = Enum.filter(comp_vis, fn {_, vis} -> lv_crosses?(vis) end)
    cross_files = comp_cross |> Enum.map(fn {c, _} -> c.path end) |> Enum.uniq()

    hc = Enum.filter(index.defs, &(&1.name == :handle_call and &1.arity == 3))

    hc_by_tag =
      hc
      |> Enum.flat_map(fn d -> lv_tagged(lv_tag(List.first(lv_args(d.head))), d) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    joins =
      Enum.map(comp_cross, fn {_, vis} ->
        vis |> lv_tags() |> Enum.filter(&Map.has_key?(hc_by_tag, &1))
      end)

    joined = Enum.count(joins, &(&1 != []))
    tags = joins |> List.flatten() |> Enum.uniq()

    p("    THE PROCESS BOUNDARY — THREE FIGURES IN THREE UNITS, AND THE SUM IS THE ERROR")
    p("      A #{@lv_boundary_mod}.#{hd(@lv_boundary_funs)}/2,3 leaves the caller's call graph: callees/2 resolves no")
    p("      edge across it, so every write column above stops at the send. Three separate")
    p("      figures, and adding them is a UNIT ERROR — different denominators, different")
    p("      depth regimes, and one of them does not count clauses at all:")
    p("        #{length(comp_cross)} / #{nc} @any  component clause(s) crossing a boundary, in")
    p("                       #{length(cross_files)} / #{length(Enum.uniq(Enum.map(comp, & &1.path)))} component file(s). Depth-invariant: they cross at")
    p("                       every budget measured.")
    p("        #{length(rc_close)} / #{nr} @#{closes}   routed clause(s) that cross a boundary and are NOT")
    p("                       write-reaching (#{length(rc_max)} / #{nr} @#{@max_depth}). These sit in NO write column")
    p("                       above — the third term a two-way sum drops on the floor.")
    p("        #{length(tags)} / #{map_size(hc_by_tag)}        handle_call/3 LITERAL TAG(S) the crossing clauses join")
    p("                       to, out of every literal-tagged handle_call/3 in the corpus:")

    Enum.each(tags, fn t ->
      Enum.each(Map.fetch!(hc_by_tag, t), fn d ->
        prof =
          Enum.map_join([4, @max_depth, closes, 10, 12], " ", fn depth ->
            "#{depth}:#{if elem(lv_bfs(d, index, depth), 0), do: "W", else: "-"}"
          end)

        p("                       #{inspect(t)} -> #{label(d)}")
        p("                         write-reach by depth  #{prof}")
      end)
    end)

    p("      THE JOIN IS MADE ON THE LITERAL TAG, NEVER ON THE OPAQUE HOP. #{joined} / #{length(comp_cross)} of the")
    p("      crossing clauses carry a LITERAL tuple tag somewhere in the def set the bfs")
    p("      entered, and that tag matches a handle_call/3 head. The def that actually")
    p("      calls #{@lv_boundary_mod} takes its message as a PARAMETER, so a join attempted there")
    p("      matches nothing: joining at the opaque hop credits 0 / #{nc}, joining blindly")
    p("      credits #{length(comp_cross)} / #{nc} at the WRONG depth, and the measured answer is #{length(comp_cross)} / #{nc}")
    p("      reaching a handle_call clause itself write-reaching only from the depth in the")
    p("      row above. A WAVE-40 FIGURE IS RETIRED HERE: any single number that adds a")
    p("      depth-#{@max_depth} count over the routed #{nr} to a depth-invariant count over the #{nc}")
    p("      is not a bigger truth, it is two denominators in a trench coat.")
    p("")
  end

  # THE CLAUSE HEAD THAT NAMES NO EVENT. A bare variable head matches EVERY event, so any
  # per-event allowlist keyed on the head is blind to it — printed in BOTH units because
  # the routed lens and the repo-wide lens disagree by exactly the component clauses.
  defp lv_report_keys(routed, pop, nr, n) do
    kr = Enum.frequencies_by(routed, &lv_key_class/1)
    ka = Enum.frequencies_by(pop, &lv_key_class/1)
    br = Map.get(kr, :bare_var, 0)
    ba = Map.get(ka, :bare_var, 0)

    p("    NON-LITERAL EVENT KEYS — the clause head names no event at all")
    p("      #{br} / #{nr} routed (#{lv_pct(br, nr)})  ·  #{ba} / #{n} repo-wide (#{lv_pct(ba, n)}) — the difference is")
    p("      #{ba - br} / #{n - nr} component clause(s), so the two units are not interchangeable here.")
    # THE SHAPE DENOMINATOR IS THE NON-LITERAL POPULATION, NOT THE BARE-VAR COUNT.
    # bare_var + other + none — they coincide on this tree only because `other` and
    # `none` are both zero, and a denominator that is right by coincidence is the
    # exact failure this block exists to name (fixed at wave-41 review).
    nonlit = Map.get(ka, :bare_var, 0) + Map.get(ka, :other, 0) + Map.get(ka, :none, 0)
    p("      SHAPE, MEASURED over the #{nonlit} / #{n} non-literal head(s): #{ba} / #{nonlit} are BARE")
    p("      VARIABLE heads, #{Map.get(ka, :other, 0)} / #{nonlit} are concatenations or computed keys, and")
    p("      #{Map.get(ka, :none, 0)} / #{nonlit} have no first argument at all. A bare head")
    p("      matches EVERY event that reaches it, so a per-event allowlist keyed on the")
    p("      head sees none of these — they are the shape a name-keyed gate cannot hold.")
    p("      (Literal heads: #{Map.get(ka, :literal, 0)} / #{n}.)")
    p("")
  end

  # UNGATEABLE-BY-HOOK. Counted here, fixed elsewhere: a component's handle_event never
  # passes through a socket-level attach_hook, so the hook count and the population are
  # printed together rather than either being assumed from the other.
  defp lv_report_hooks(comp, n, nc, index) do
    hooks = lv_hooks(index)
    ev = Enum.filter(hooks, &(elem(&1, 1) == :handle_event))
    hook_mods = ev |> Enum.map(fn {d, _} -> lv_mod(d) end) |> Enum.uniq()

    p("    UNGATEABLE-BY-HOOK — a fourth column, new in wave 41")
    p("      #{nc} / #{n} clause(s) are LiveComponent-targeted and therefore outside EVERY")
    p("      socket-level attach_hook in this corpus. THE HOOK INVENTORY IS DERIVED TOO,")
    p("      through expand_pipes/1: a piped `|> attach_hook(...)` carries THREE args in")
    p("      the AST, so a matcher that only knows the four-arg shape undercounts silently.")
    p("        of the #{length(hooks)} attach_hook callsite(s) in the corpus, #{length(ev)} / #{length(hooks)} are at the")
    p("        :handle_event stage, across #{length(hook_mods)} / #{length(index.modules)} corpus module(s).")
    p("      A component event is delivered to the COMPONENT, so 0 / #{length(ev)} of those")
    p("      socket-stage hooks run for #{nc} / #{n} of it. COUNTED HERE, NOT FIXED")
    p("      HERE — a census that repairs its own denominator cannot be read afterwards.")
    wrap("component file(s): " <> (comp |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.map_join(", ", &short/1)), "      ", "  ")
    p("")
  end

  # A NAMED HOLE. handle_info/2 and handle_params/3 are writes NOBODY CLICKED — timers,
  # PubSub deliveries, live patches — and nothing in this census disposes them. Named with
  # its own denominator so the silence is a fact on every run rather than an omission.
  defp lv_report_hole(route_mods, comp, parsed, closes, index) do
    paths =
      index.defs
      |> Enum.filter(&MapSet.member?(route_mods, lv_mod(&1)))
      |> Enum.map(& &1.path)
      |> Enum.concat(Enum.map(comp, & &1.path))
      |> MapSet.new()

    hole =
      Enum.filter(index.defs, fn d ->
        ((d.name == :handle_info and d.arity == 2) or (d.name == :handle_params and d.arity == 3)) and
          MapSet.member?(paths, d.path)
      end)

    h = length(hole)
    files = hole |> Enum.map(& &1.path) |> Enum.uniq() |> length()
    w_max = Enum.count(hole, &elem(lv_bfs(&1, index, @max_depth), 0))
    w_close = Enum.count(hole, &elem(lv_bfs(&1, index, closes), 0))

    p("    A NAMED HOLE, WITH ITS OWN DENOMINATOR: handle_info/2 + handle_params/3")
    p("      #{h} / #{length(index.defs)} corpus def(s), over #{files} / #{MapSet.size(paths)} live file(s) (#{MapSet.size(paths)} / #{length(parsed)} corpus file(s)")
    p("      carry a live module or a LiveComponent). Write-reaching #{w_max} / #{h} @#{@max_depth} and")
    p("      #{w_close} / #{h} @#{closes} — #{w_close - w_max} / #{h} clause(s) bigger at closure than at the census")
    p("      depth, on a surface no column above counts at all. These are writes a USER")
    p("      NEVER CLICKED: a timer, a PubSub delivery, a live patch. NOTHING in this")
    p("      census disposes them, and the count is printed so that sentence is")
    p("      checkable rather than merely admitted.")
    p("")
  end

  # -- the LiveView population's own primitives (all read the census resolver) --

  defp lv_mod(d), do: Enum.join(d.module, ".")

  defp lv_pct(_n, 0), do: "n/a"
  defp lv_pct(n, d), do: "#{:erlang.float_to_binary(n / d * 100, decimals: 1)}%"

  defp lv_cell(n, d), do: String.pad_leading("(" <> lv_pct(n, d) <> ")", 8)

  defp lv_bfs(d, index, max) do
    {verbs, _found, _chain} = bfs([{d, 0, [label(d)]}], index, MapSet.new(), %{}, nil, [], max)
    {Map.has_key?(verbs, :write), Map.get(verbs, :visited, [])}
  end

  defp lv_args({:when, _, [h | _]}), do: lv_args(h)
  defp lv_args({name, _, args}) when is_atom(name) and is_list(args), do: args
  defp lv_args(_), do: []

  defp lv_key_class(d) do
    case List.first(lv_args(d.head)) do
      {:__block__, _, [v]} when is_binary(v) or is_atom(v) -> :literal
      v when is_binary(v) or is_atom(v) -> :literal
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> :bare_var
      nil -> :none
      _ -> :other
    end
  end

  defp lv_tag({:{}, _, [{:__block__, _, [t]} | _]}) when is_atom(t), do: t
  defp lv_tag({{:__block__, _, [t]}, _}) when is_atom(t), do: t
  defp lv_tag(_), do: nil

  defp lv_tagged(nil, _d), do: []
  defp lv_tagged(t, d), do: [{t, d}]

  defp lv_crosses?(defs) do
    Enum.any?(defs, fn d ->
      Enum.any?(d[:calls] || raw_calls(d), fn
        {:remote, segs, f, _a} -> List.last(segs) == @lv_boundary_mod and f in @lv_boundary_funs
        _ -> false
      end)
    end)
  end

  defp lv_tags(defs) do
    defs
    |> Enum.flat_map(fn
      %{body: nil} ->
        []

      %{body: body} ->
        {_, acc} =
          body
          |> expand_pipes()
          |> Macro.prewalk([], fn
            {_f, _m, args} = node, acc when is_list(args) ->
              {node, Enum.reduce(args, acc, fn a, s -> lv_tagged(lv_tag(a), :_) ++ s end)}

            node, acc ->
              {node, acc}
          end)

        Enum.map(acc, &elem(&1, 0))
    end)
    |> Enum.uniq()
  end

  defp lv_hooks(index) do
    Enum.flat_map(index.defs, fn
      %{body: nil} ->
        []

      d ->
        {_, acc} =
          d.body
          |> expand_pipes()
          |> Macro.prewalk([], fn
            {{:., _, [_m, :attach_hook]}, _, [_s, _n, stage, _f]} = node, acc ->
              {node, [{d, lv_stage(stage)} | acc]}

            {:attach_hook, _, [_s, _n, stage, _f]} = node, acc ->
              {node, [{d, lv_stage(stage)} | acc]}

            node, acc ->
              {node, acc}
          end)

        acc
    end)
  end

  defp lv_stage({:__block__, _, [a]}) when is_atom(a), do: a
  defp lv_stage(a) when is_atom(a), do: a
  defp lv_stage(_), do: :__opaque__


  # ═══════════════════════════════════════════════════════════════════════════
  # WAVE 42 — THREE COLUMNS OVER THE 322, AND WHY EACH KEY IS THE ONE IT IS
  #
  # Wave 41 gave this surface a DENOMINATOR. A denominator is not a verdict, and the
  # obvious verdict is the wrong one twice over, so both wrong keys are named here:
  #
  #   REACH is keyed on {module, live_session}, NEVER on module. One module can be
  #   routed in TWO live_sessions with DIFFERENT on_mount chains (that is not a
  #   hypothetical — it is measured and printed below), so a module-keyed column
  #   silently averages two different authorization postures into one.
  #
  #   DENIES is keyed on DENY-BY-DEFAULT, never on `{:halt, _}`. Every :handle_event
  #   hook on this tree halts somewhere, so the halt key has ZERO discriminating power
  #   and prints 100%. The structural difference between HANDLING an event and DENYING
  #   one is WHICH PATH halts: a handler halts on a path selected BY THE EVENT NAME
  #   (a literal clause head, or a guard over a name list); a gate halts on its
  #   DEFAULT path — the events it does not name. That is a derivation over the AST's
  #   selector shape, not a word list over function names.
  #
  #   ATTACH-CERTAINTY asks whether the deny gate is attached UNCONDITIONALLY. A gate
  #   attached inside a runtime branch covers a clause only on the branch that runs,
  #   and the honest static answer for such a gate is MAY-attach, never covered.
  #
  # THE RESIDUAL IS NARROWED BY DERIVATION, NEVER BY PROXY (PDS-D572, folded in wave 43).
  # Wave 42 printed the residual whole on the reason that a module routed only through
  # the plugin-mount macro "carries no derivable on_mount chain". That was a fact about
  # THIS FILE'S WALK, not about the tree: for a callsite INSIDE a live_session the chain
  # is two hops away in data the census already reads (spec.auth -> callsite.scope ->
  # the live_session literal), and lv_session_index/1 now takes those two hops. What
  # stays in the residual is what is genuinely undecidable — a spec mounted at a callsite
  # outside every live_session, and a spec whose module resolves to `?`. Those clauses
  # are not "reachable" and not "unreachable"; a column that resolved THEM by proxy would
  # still have invented the answer it was asked for.
  @lv_reach_order [
    :unreachable_component_lifecycle,
    :unreachable_no_hook_in_chain,
    :reachable_unconditional,
    :reachable_conditional
  ]
  @lv_reach_residual :residual_no_derivable_chain
  @lv_event_stage :handle_event
  # The ONE plugin auth bucket whose route the mount macro does not emit bare — see
  # lv_session_index/1, where the mirror and its safe-staleness direction are stated.
  # DECLARED HERE, WITH THE OTHER REACH ATTRIBUTES, BECAUSE A MODULE ATTRIBUTE IS READ AT
  # DEFINITION TIME: declared next to its user it read `nil` in lv_print_reach/6 above it
  # and printed `auth: nil` in a line whose whole job is to name the bucket.
  @lvs_macro_wrapped_auth :public_root

  defp lv_verdict(pop, comp, route_mods, parsed, index) do
    sidx = lv_session_index(parsed)
    sessions = sidx.sessions
    sites = lv_hook_sites(index)
    ev = Enum.filter(sites, &(&1.stage == @lv_event_stage))

    # THE HOOK INVENTORY, BY MODULE, WITH BOTH PROPERTIES DERIVED PER SITE.
    by_mod =
      ev
      |> Enum.group_by(& &1.mod)
      |> Map.new(fn {m, ss} ->
        {m,
         %{
           attach_uncond?: Enum.any?(ss, & &1.uncond?),
           deny?: Enum.any?(ss, & &1.deny?),
           deny_uncond?: Enum.any?(ss, &(&1.deny? and &1.uncond?)),
           halts?: Enum.any?(ss, & &1.halts?)
         }}
      end)

    comp_set = MapSet.new(comp, &lv_key(&1))

    rows =
      Enum.map(pop, fn d ->
        mod = lv_mod(d)
        sess = Map.get(sessions, mod, [])
        chains = Enum.map(sess, &lv_chain_verdict(&1, by_mod))

        class =
          cond do
            MapSet.member?(comp_set, lv_key(d)) -> :unreachable_component_lifecycle
            not MapSet.member?(route_mods, mod) -> :unreachable_component_lifecycle
            sess == [] -> @lv_reach_residual
            Enum.all?(chains, &(&1.attach == :none)) -> :unreachable_no_hook_in_chain
            Enum.all?(chains, &(&1.attach == :uncond)) -> :reachable_unconditional
            true -> :reachable_conditional
          end

        %{
          def: d,
          mod: mod,
          class: class,
          sessions: Enum.map(sess, & &1.session),
          # FAIL-CLOSED ACROSS SESSIONS: a clause routed in two sessions is credited
          # only where EVERY session's chain carries the property. `Enum.all?` over an
          # empty list is true, so the residual and component classes are excluded from
          # every numerator below rather than silently credited.
          deny?: chains != [] and Enum.all?(chains, & &1.deny?),
          deny_uncond?: chains != [] and Enum.all?(chains, & &1.deny_uncond?),
          halts?: chains != [] and Enum.all?(chains, & &1.halts?),
          delegation?: lv_delegation?(d)
        }
      end)

    freqs = Enum.frequencies_by(rows, & &1.class)
    n = length(pop)
    reachable = Enum.filter(rows, &(&1.class in [:reachable_unconditional, :reachable_conditional]))
    nrch = length(reachable)
    multi = Enum.filter(rows, &(length(&1.sessions) > 1))
    theorem = lv_component_theorem(parsed)
    proxy_mods = pop |> Enum.map(&lv_mod/1) |> Enum.uniq() |> Enum.reject(&MapSet.member?(route_mods, &1))
    disagree = lv_sym_diff(theorem.with_clauses, proxy_mods)
    deleg = Enum.count(rows, & &1.delegation?)

    lv_print_reach(rows, freqs, n, sessions, multi, sidx)
    lv_print_denies(reachable, nrch, n)
    lv_print_attach(reachable, nrch, ev, by_mod)
    lv_print_component(theorem, proxy_mods, disagree, n)
    lv_print_derivation_denominator(deleg, n)

    %{
      population: n,
      freqs: freqs,
      order: @lv_reach_order,
      residual: Map.get(freqs, @lv_reach_residual, 0),
      sum: Enum.sum(Map.values(freqs)),
      stray: freqs |> Map.keys() |> Enum.reject(&(&1 in [@lv_reach_residual | @lv_reach_order])),
      reachable: nrch,
      denies: Enum.count(reachable, & &1.deny?),
      halt_keyed: Enum.count(reachable, & &1.halts?),
      attach_certain: Enum.count(reachable, & &1.deny_uncond?),
      multi_session: length(multi),
      component_disagreement: length(disagree),
      delegations: deleg
    }
  end

  defp lv_key(d), do: {d.path, d.module, d.name, d.arity, d.line}

  defp lv_chain_verdict(%{hooks: hooks}, by_mod) do
    h = Enum.map(hooks, &Map.get(by_mod, &1, %{}))

    %{
      attach:
        cond do
          Enum.any?(h, &Map.get(&1, :attach_uncond?, false)) -> :uncond
          Enum.any?(h, &Map.get(&1, :halts?, false)) -> :cond
          h == [] -> :none
          Enum.any?(h, &(map_size(&1) > 0)) -> :cond
          true -> :none
        end,
      deny?: Enum.any?(h, &Map.get(&1, :deny?, false)),
      deny_uncond?: Enum.any?(h, &Map.get(&1, :deny_uncond?, false)),
      halts?: Enum.any?(h, &Map.get(&1, :halts?, false))
    }
  end

  # -- REACH ------------------------------------------------------------------

  defp lv_print_reach(rows, freqs, n, sessions, multi, sidx) do
    p("    REACH — CAN A SOCKET-LEVEL HOOK REACH THIS CLAUSE AT ALL? (wave 42, folded 43)")
    p("      Keyed on {module, live_session}. #{map_size(sessions)} routed module(s) resolve to a")
    p("      live_session with an on_mount chain THIS RUN READS OUT OF #{@router_path}.")
    p("      #{sidx.mount_sites - sidx.sessionless_sites} / #{sidx.mount_sites} #{@routed_resolved_macro}/1 callsite(s) sit INSIDE a live_session, so a")
    p("      plugin-mounted module resolves its chain through its OWN spec's auth: (wave 43).")
    p("      #{sidx.macro_wrapped} live spec(s) carry auth: #{inspect(@lvs_macro_wrapped_auth)}, which the mount macro wraps in a")
    p("      live_session of its OWN carrying root_layout: and NO on_mount — a chain that is")
    p("      derivably EMPTY rather than unreadable, so those clauses are DECIDED, not residual.")

    Enum.each(@lv_reach_order, fn c ->
      p("        #{String.pad_trailing(to_string(c), 32)} #{pad(Map.get(freqs, c, 0))} / #{n}")
    end)

    p("        #{String.pad_trailing("RESIDUAL " <> to_string(@lv_reach_residual), 32)} #{pad(Map.get(freqs, @lv_reach_residual, 0))} / #{n}  <- UNDECIDABLE, NEVER FOLDED")
    p("        #{String.pad_trailing("sum", 32)} #{pad(Enum.sum(Map.values(freqs)))} == population #{n}")
    wrap(
      "the RESIDUAL is clauses whose plugin mount callsite sits OUTSIDE any live_session: " <>
        "#{sidx.sessionless_sites} of the #{sidx.mount_sites} #{@routed_resolved_macro}/1 callsite(s) in #{short(@router_path)} carry no enclosing " <>
        "live_session (#{sidx.sessionless_buckets} distinct auth bucket(s)), so a spec mounted ONLY there has no " <>
        "on_mount chain to read anywhere in the router. They are UNDECIDED, not " <>
        "unreachable. A spec whose module this lens cannot name (`?`) declines the join " <>
        "for the same reason. What is NOT in the residual any more is a spec mounted " <>
        "inside a live_session: wave 43 joins its own auth: to its own callsite's scope: " <>
        "and reads the chain that is right there.",
      "        "
    )

    # THE `?` CLAUSE ABOVE IS THE ONLY UNQUANTIFIED SIBLING IN THAT SENTENCE, so it
    # carries its bound HERE, in the output (PDS-D633: a number from a meter lives in
    # the meter's own printed output, never in prose a copy-paste can drop).
    p("        declined_live=#{sidx.declined_live}  <- live spec(s) whose module reads `?` and DECLINE the join,")
    p("        a BOUND on the sentence above rather than a restatement of it. Printing it")
    p("        at 0 is the point: nothing here announced when it stopped being 0, so the")
    p("        sentence could describe an EMPTY SET for a whole wave with no line of this")
    p("        report changing. It is a bound, never a pass — see the count itself.")

    p("      THE MULTI-SESSION KEY IS LOAD-BEARING, NOT DECORATIVE: #{length(multi)} / #{n} clause(s)")
    p("      are routed in MORE THAN ONE live_session, so a module-keyed column would")
    p("      decide them once and be wrong on one of the two mounts.")

    multi
    |> Enum.group_by(& &1.mod, & &1.sessions)
    |> Enum.sort()
    |> Enum.each(fn {m, ss} ->
      p("        #{short_mod(m)} — #{length(ss)} clause(s) in live_session(s) #{ss |> List.first() |> Enum.map_join(", ", &inspect/1)}")
    end)

    p("      REACH IS A PROPERTY OF THE MECHANISM, NOT OF TODAY'S TREE: reachable_conditional")
    p("      reads #{Map.get(freqs, :reachable_conditional, 0)} / #{n} on THIS run because every live_session that attaches at")
    p("      #{inspect(@lv_event_stage)} attaches unconditionally. A column collapsed to two values on the")
    p("      strength of that zero is wrong the day a session lands with a branched attach.")
    p("")
    rows
  end

  # -- DENIES -----------------------------------------------------------------

  defp lv_print_denies(reachable, nrch, n) do
    honest = Enum.count(reachable, & &1.deny?)
    naive = Enum.count(reachable, & &1.halts?)

    p("    DENIES — KEYED ON DENY-BY-DEFAULT, AND THE NAIVE KEY PRINTED AS A NAMED TRAP")
    p("      THE TRAP, NAMED SO IT CANNOT BE MISTAKEN FOR THE ANSWER:")
    p("        #{pad(naive)} / #{nrch}  clause(s) whose chain carries a hook that returns {:halt, _}")
    p("                     ANYWHERE. This is #{lv_pct(naive, nrch)} and it is NOT a gating figure:")
    p("                     a hook halts to say I HANDLED THIS EVENT just as readily as")
    p("                     to say NO. A column that prints this has no discriminating")
    p("                     power on this tree at all.")
    p("      THE HONEST KEY — WHICH PATH HALTS:")
    p("        #{pad(honest)} / #{nrch}  clause(s) whose EVERY live_session chain carries a hook that")
    p("                     halts on its DEFAULT path — the events it does NOT name. A")
    p("                     halt under a literal clause head, or under a guard over a")
    p("                     name list, is event HANDLING and is not counted.")
    p("      The two keys differ by #{naive - honest} / #{nrch} clause(s). Over the whole population that")
    p("      is #{honest} / #{n} deny-by-default versus #{naive} / #{n} on the halt key.")
    p("      NOT A NAME LIST. The classifier reads the SELECTOR of the branch each halt")
    p("      sits under — clause-head literal, name-list guard, or default — and nothing")
    p("      about what any function is called.")
    p("")
  end

  # -- ATTACH-CERTAINTY -------------------------------------------------------

  defp lv_print_attach(reachable, nrch, ev, by_mod) do
    certain = Enum.count(reachable, & &1.deny_uncond?)
    deny_mods = by_mod |> Enum.filter(fn {_, v} -> v.deny? end) |> Enum.map(&elem(&1, 0))
    uncond = Enum.count(ev, & &1.uncond?)

    p("    ATTACH-CERTAINTY — IS THE GATE THERE ON EVERY MOUNT, OR ONLY ON A BRANCH?")
    p("      #{pad(certain)} / #{nrch}  reachable clause(s) covered by a deny-by-default gate that is")
    p("                   attached UNCONDITIONALLY. #{uncond} / #{length(ev)} #{inspect(@lv_event_stage)} attach site(s) in")
    p("                   this corpus sit outside every branch, and #{length(deny_mods)} module(s) carry a")
    p("                   deny-by-default gate at all:")

    Enum.each(Enum.sort(deny_mods), fn m ->
      v = Map.fetch!(by_mod, m)
      p("                     #{short_mod(m)} — deny-by-default, attached #{if v.deny_uncond?, do: "UNCONDITIONALLY", else: "inside a runtime branch"}")
    end)

    p("      A GATE ATTACHED ON A BRANCH IS A MAY-ATTACH, AND MAY-ATTACH IS NOT COVERAGE.")
    p("      The larger deny-by-default figure in the column above is an UPPER BOUND on")
    p("      what runs, never a coverage number: it counts chains that CAN attach a gate,")
    p("      and this row counts the ones that always do. A gate whose only callsite is")
    p("      inside a mount body is invisible to #{@router_path} entirely, so a")
    p("      router-derived predicate would miss it in BOTH directions.")
    p("")
  end

  # -- THE COMPONENT PARTITION, COMPUTED TWICE --------------------------------

  defp lv_print_component(theorem, proxy_mods, disagree, n) do
    p("    THE COMPONENT PARTITION, COMPUTED BOTH WAYS AND THE DISAGREEMENT PRINTED")
    p("      THEOREM   #{length(theorem.with_clauses)} module(s) whose OWN top-level body carries")
    p("                `use Phoenix.LiveComponent` (directly or through the project's")
    p("                `:live_component` spelling) AND at least one handle_event/3.")
    p("                #{length(theorem.modules)} module(s) match the use-walk in all; the walk reads only")
    p("                TOP-LEVEL statements, so the module that DEFINES the macro inside")
    p("                a `quote` is not one of them — it would otherwise false-positive")
    p("                on itself, and it agrees today only because it carries no")
    p("                handle_event/3 at all.")
    p("      PROXY     #{length(proxy_mods)} module(s) carrying handle_event/3 that no live route names.")
    p("      DISAGREEMENT #{length(disagree)} module(s)#{if disagree == [], do: " — the two lenses partition the #{n} identically.", else: ":"}")
    Enum.each(disagree, &p("        #{short_mod(&1)}"))
    p("      Two lenses that agree are two lenses, not one fact twice: the proxy is a")
    p("      statement about the ROUTER and the theorem is a statement about the")
    p("      MODULE, and only one of them survives a component that gains a route.")
    p("")
  end

  # -- THE DERIVATION DENOMINATOR, UNJUDGED -----------------------------------

  defp lv_print_derivation_denominator(deleg, n) do
    p("    THE DERIVATION DENOMINATOR, PRINTED UNJUDGED (PDS-D621)")
    p("      #{deleg} / #{n} clause(s) have a body that is EXACTLY ONE remote call and emit")
    p("      nothing themselves. THE REASON THIS IS NOT A COLUMN: an anchor placed on")
    p("      emission would swap those #{deleg} for the #{deleg} defs they delegate to and hide the")
    p("      swap inside an unchanged denominator of #{n}. A numerator and a denominator")
    p("      that answer different questions make a fraction that answers neither, so")
    p("      the figure is printed as a SIZE and judged nowhere.")
    p("")
  end

  # -- the live_session walk (a SECOND walk over router.ex, on purpose) --------
  #
  # routed_derivation/1's walk carries {path prefix, alias segments} and throws the
  # live_session away — it is keyed on {method, path, module, action}, which cannot
  # hold a session name. Widening it would move every downstream figure; this walk
  # carries {aliases, session, on_mount chain} and reads NOTHING else.
  # THE FOLD (PDS wave 43). Wave 42 printed the residual and refused to fold it, on a
  # stated reason: a module routed ONLY through the plugin mount "carries no derivable
  # on_mount chain". That reason was true of THIS WALK and false of the tree. The chain
  # is derivable in TWO HOPS over data this census already reads:
  #
  #   hop 1  the spec's OWN `auth:` — plugin_route_specs/1 carries it per spec.
  #   hop 2  the mount callsite's OWN `scope:` and the live_session literal it sits in —
  #          the same router.ex node mount_walk/3 already reads for the prefix.
  #
  # and the two are joined by auth_in_scope?/2, which is the census's existing mirror of
  # BarkparkWeb.Router.Plugins' own mapping. NOTHING IS RESOLVED BY PROXY: the route's own
  # auth: selects the callsite, and the callsite's enclosing on_mount is read as a literal.
  # A module mounted at a callsite that sits OUTSIDE every live_session still resolves to
  # NO session and stays in the residual — which is what keeps the residual falsifiable
  # rather than zero by construction.
  #
  # THE ONE MACRO-SIDE WRAP, MIRRORED THE WAY auth_in_scope?/2 MIRRORS THE MAPPING.
  # `:public_root` is the single bucket whose route the mount macro does NOT emit bare:
  # BarkparkWeb.Router.Plugins.emit_route_ast/1 wraps each such route in a live_session of
  # its OWN carrying the spec's `root_layout:` AND NOTHING ELSE — no `on_mount` key exists
  # in that quote to read. So the chain is not unreadable there, it is derivably EMPTY,
  # and an empty chain is a DECIDED class (unreachable_no_hook_in_chain), never the
  # residual. NARROW ON PURPOSE: every other bucket emits `live/4` bare, so its chain is
  # whatever the ROUTER LITERAL wraps the callsite in — and if that is nothing, the clause
  # stays undecided. The day the macro gains a second wrapping bucket this mirror goes
  # stale in the SAFE direction: the new bucket reads sessionless and lands back in the
  # residual, which is a shrinking claim, never an invented one.
  defp lv_session_index(parsed) do
    with %{src: src} <- Enum.find(parsed, &(&1.path == @router_path)),
         {:ok, ast} <- Code.string_to_quoted(src) do
      walked = lvs_walk(ast, {[], nil, []}, [])
      {sites, literal} = Enum.split_with(walked, &Map.has_key?(&1, :plugin_scope))

      sessions =
        (literal ++ lvs_mounted(sites, parsed))
        |> Enum.filter(&(&1.session != nil))
        |> Enum.uniq()
        |> Enum.group_by(& &1.module)

      sessionless = Enum.filter(sites, &(&1.session == nil))

      %{
        sessions: sessions,
        mount_sites: length(sites),
        sessionless_sites: length(sessionless),
        sessionless_buckets: sessionless |> Enum.map(& &1.plugin_scope) |> Enum.uniq() |> length(),
        macro_wrapped: parsed |> lvs_specs() |> Enum.count(&(&1.auth == @lvs_macro_wrapped_auth)),
        declined_live: lvs_declined_live(parsed)
      }
    else
      _ ->
        %{
          sessions: %{},
          mount_sites: 0,
          sessionless_sites: 0,
          sessionless_buckets: 0,
          macro_wrapped: 0,
          declined_live: 0
        }
    end
  end

  # THE BOUND ON THE `?` DECLINE (PDS-D661, wave 45). The residual prose claimed a spec
  # whose module this lens cannot name declines the join, and NOTHING counted the
  # declines — an unquantified claim sitting beside five quantified siblings. It is
  # DERIVED THROUGH lvs_joinable?/1 rather than through a second `mod != "?"` test, so
  # the number cannot drift from the predicate it describes (and the selftest mutant
  # that neuters that predicate moves this count too).
  defp lvs_declined_live(parsed) do
    live_specs = parsed |> plugin_route_specs() |> Enum.filter(&(&1.method == @routed_live_method))
    length(live_specs) - Enum.count(live_specs, &lvs_joinable?/1)
  end

  defp lvs_specs(parsed), do: parsed |> plugin_route_specs() |> Enum.filter(&lvs_joinable?/1)

  defp lvs_mounted(sites, parsed) do
    specs = lvs_specs(parsed)

    for site <- sites,
        s <- specs,
        auth_in_scope?(s.auth, site.plugin_scope),
        do: lvs_mount_entry(s, site)
  end

  defp lvs_mount_entry(%{auth: @lvs_macro_wrapped_auth} = s, _site),
    do: %{module: s.module, session: lvs_macro_session(s), hooks: []}

  defp lvs_mount_entry(s, site), do: %{module: s.module, session: site.session, hooks: site.hooks}

  # The macro names that session `plugin_root_<path slug>_<phash2 of the module atom>`.
  # The hash half is a COLLISION DEVICE over module atoms this lens holds as strings, so
  # it is dropped rather than faked: the path slug already makes one name per route, which
  # is the only property the {module, live_session} key asks of it.
  defp lvs_macro_session(%{path: path}) do
    slug = path |> String.replace(~r/[^A-Za-z0-9]+/, "_") |> String.trim("_")
    String.to_atom("plugin_root_#{slug}")
  end

  # A SPEC WHOSE MODULE THIS LENS CANNOT NAME DECLINES — it never joins. `alias_string/2`
  # answers `"?"` for a route module inline_alias_bindings/1 could not resolve (a name
  # rebound somewhere this pass does not model), and joining on `"?"` would credit a
  # live_session to a module NOBODY CAN OPEN — a printed verdict over an unnamed subject,
  # which is exactly the invention the residual exists to refuse. The selftest mutates
  # this predicate to `true` and watches the routed-module count grow by the phantom.
  defp lvs_joinable?(%{method: @routed_live_method, module: mod}), do: mod != "?"
  defp lvs_joinable?(_), do: false

  defp lvs_walk({:scope, _, args}, {al, s, h}, acc) do
    {_p, a2, body} = scope_parts(args)
    lvs_walk(body, {al ++ a2, s, h}, acc)
  end

  defp lvs_walk({:live_session, _, args}, {al, _s, _h}, acc) when is_list(args) do
    {name, opts} = lvs_parts(args)
    lvs_walk(Keyword.get(opts, :do), {al, name, lvs_on_mount(opts)}, acc)
  end

  defp lvs_walk({@routed_live_method, _, [path, mod | _]}, {al, s, h}, acc)
       when is_binary(path),
       do: [%{module: alias_string(al, mod), session: s, hooks: h} | acc]

  # THE MOUNT CALLSITE, RECORDED WITH THE CONTEXT IT SITS IN — the one clause wave 42 was
  # missing. `live_session :plugin_ops do plugin_routes(scope: :ops) end` quotes to a
  # `{:plugin_routes, _, [[scope: :ops]]}` node holding no `live/3`, so the generic clause
  # below descended into it and recorded NOTHING; every clause in every module mounted
  # there then met `sess == []` and landed in the residual. `|| :admin` is not a fallback
  # of convenience — it is mount_walk/3's default, spelled the same way on purpose so the
  # two walks cannot disagree about which bucket an option-less callsite mounts.
  defp lvs_walk({@routed_resolved_macro, _, [opts]}, {_al, s, h}, acc) when is_list(opts),
    do: [%{plugin_scope: kw_lit(opts, :scope) || :admin, session: s, hooks: h} | acc]

  defp lvs_walk({_, _, args}, ctx, acc) when is_list(args),
    do: Enum.reduce(args, acc, &lvs_walk(&1, ctx, &2))

  defp lvs_walk({a, b}, ctx, acc), do: lvs_walk(b, ctx, lvs_walk(a, ctx, acc))
  defp lvs_walk(l, ctx, acc) when is_list(l), do: Enum.reduce(l, acc, &lvs_walk(&1, ctx, &2))
  defp lvs_walk(_, _, acc), do: acc

  # EVERY KEYWORD LIST IN THE CALL, CONCATENATED — never `Enum.find/3`. Elixir does NOT
  # merge a `do` block into a preceding option list when the options are a separate
  # argument: `live_session :s, on_mount: [...], layout: {...} do … end` parses as
  # [:s, [on_mount: …, layout: …], [do: …]]. A walk that reads the FIRST keyword list
  # finds no `:do`, descends into nil, and reports ZERO routed live_sessions with every
  # count still summing — the silent-empty failure this whole census exists to refuse
  # (measured: it printed 235 / 322 RESIDUAL and a green arm).
  defp lvs_parts([name | rest]) do
    {lvs_atom(name), rest |> Enum.filter(&(is_list(&1) and Keyword.keyword?(&1))) |> Enum.concat()}
  end

  defp lvs_parts(_), do: {nil, []}

  defp lvs_atom({:__block__, _, [a]}) when is_atom(a), do: a
  defp lvs_atom(a) when is_atom(a), do: a
  defp lvs_atom(_), do: nil

  defp lvs_on_mount(opts) when is_list(opts) do
    opts
    |> Keyword.get(:on_mount, [])
    |> List.wrap()
    |> Enum.map(fn
      {{:__aliases__, _, _} = m, _act} -> alias_string([], m)
      {:__aliases__, _, _} = m -> alias_string([], m)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp lvs_on_mount(_), do: []

  # -- the hook sites, with BOTH properties derived ---------------------------

  defp lv_hook_sites(index) do
    Enum.flat_map(index.defs, fn
      %{body: nil} -> []
      d -> d.body |> expand_pipes() |> lvh_walk(false, d, index, [])
    end)
  end

  defp lvh_walk(node, c?, d, index, acc) do
    acc =
      case node do
        {{:., _, [_m, :attach_hook]}, _, [_s, _n, stage, f]} -> [lvh_site(d, stage, f, c?, index) | acc]
        {:attach_hook, _, [_s, _n, stage, f]} -> [lvh_site(d, stage, f, c?, index) | acc]
        _ -> acc
      end

    c2 = c? or lvh_branch?(node)

    case node do
      {a, b} ->
        acc |> then(&lvh_walk(a, c2, d, index, &1)) |> then(&lvh_walk(b, c2, d, index, &1))

      {f, _, args} when is_list(args) ->
        Enum.reduce([f | args], acc, &lvh_walk(&1, c2, d, index, &2))

      l when is_list(l) ->
        Enum.reduce(l, acc, &lvh_walk(&1, c2, d, index, &2))

      _ ->
        acc
    end
  end

  defp lvh_branch?({op, _, args}) when op in [:if, :unless, :case, :cond, :with] and is_list(args),
    do: true

  defp lvh_branch?(_), do: false

  defp lvh_site(d, stage, fun, c?, index) do
    clauses = lv_hook_clauses(fun, d, index)

    %{
      mod: lv_mod(d),
      stage: lv_stage(stage),
      uncond?: not c?,
      halts?: Enum.any?(clauses, fn {sel, body} -> lvd_walk(body, sel, false) end),
      deny?: Enum.any?(clauses, fn {sel, body} -> lvd_walk(body, sel, true) end)
    }
  end

  # THE HOOK FUNCTION, RESOLVED TO {selector, body} CLAUSES. Two shapes ship on this
  # tree — a local capture and an inline `fn` — and an unresolvable third contributes
  # NO clause rather than a verdict nobody derived.
  defp lv_hook_clauses({:&, _, [{:/, _, [{name, _, ctx}, ar]}]}, d, index)
       when is_atom(name) and is_atom(ctx) do
    a = lvs_int(ar)

    index.defs
    |> Enum.filter(&(&1.module == d.module and &1.name == name and &1.arity == a))
    |> Enum.map(&{lv_sel_head(&1.head), &1.body})
  end

  defp lv_hook_clauses({:fn, _, clauses}, _d, _index) do
    Enum.flat_map(clauses, fn
      {:->, _, [heads, body]} -> [{lv_sel_pat(List.first(heads)), body}]
      _ -> []
    end)
  end

  defp lv_hook_clauses(_, _, _), do: []

  defp lvs_int({:__block__, _, [i]}) when is_integer(i), do: i
  defp lvs_int(i) when is_integer(i), do: i
  defp lvs_int(_), do: -1

  # THE SELECTOR OF A BRANCH: what decided that this path runs. A literal event name in
  # the head, or a guard over a name list, is a NAMED selector — the branch runs only
  # for events it spells out. Anything else is the DEFAULT path.
  defp lv_sel_head({:when, _, [h, guard]}) do
    if lv_guard_names?(guard), do: :named, else: lv_sel_pat(List.first(lv_args(h)))
  end

  defp lv_sel_head(h), do: lv_sel_pat(List.first(lv_args(h)))

  defp lv_sel_pat({:__block__, _, [v]}) when is_binary(v), do: :named
  defp lv_sel_pat({:__block__, _, [v]}) when is_atom(v) and v not in [true, false, nil], do: :named
  defp lv_sel_pat(v) when is_binary(v), do: :named
  defp lv_sel_pat(v) when is_atom(v) and v not in [true, false, nil], do: :named
  defp lv_sel_pat(_), do: :default

  defp lv_guard_names?({:in, _, _}), do: true

  defp lv_guard_names?({_, _, args}) when is_list(args), do: Enum.any?(args, &lv_guard_names?/1)
  defp lv_guard_names?({a, b}), do: lv_guard_names?(a) or lv_guard_names?(b)
  defp lv_guard_names?(l) when is_list(l), do: Enum.any?(l, &lv_guard_names?/1)
  defp lv_guard_names?(_), do: false

  # `default_only?` false answers the NAIVE question (does this halt at all), true
  # answers the honest one (does it halt on a path the event name did not select).
  # ONE walk, one flag: two walks would be two chances to disagree with each other.
  defp lvd_walk(node, sel, default_only?) do
    if lv_halt?(node) do
      not default_only? or sel == :default
    else
      case node do
        {:->, _, [heads, body]} ->
          lvd_walk(body, lv_sel_pat(List.first(heads)), default_only?)

        {a, b} ->
          lvd_walk(a, sel, default_only?) or lvd_walk(b, sel, default_only?)

        {f, _, args} when is_list(args) ->
          Enum.any?([f | args], &lvd_walk(&1, sel, default_only?))

        l when is_list(l) ->
          Enum.any?(l, &lvd_walk(&1, sel, default_only?))

        _ ->
          false
      end
    end
  end

  defp lv_halt?({{:__block__, _, [:halt]}, _}), do: true
  defp lv_halt?({:halt, _}), do: true
  defp lv_halt?(_), do: false

  # -- the component THEOREM, and the module that must not match itself -------

  defp lv_component_theorem(parsed) do
    mods =
      parsed
      |> Enum.filter(&(:binary.match(&1.src, "LiveComponent") != :nomatch or
                         :binary.match(&1.src, ":live_component") != :nomatch))
      |> Enum.flat_map(&lv_use_walk/1)

    with_clauses =
      Enum.filter(mods, fn m ->
        Enum.any?(parsed, fn f ->
          Enum.any?(f.defs, &(lv_mod(&1) == m and &1.name == :handle_event and &1.arity == 3))
        end)
      end)

    %{modules: mods, with_clauses: with_clauses}
  end

  defp lv_use_walk(%{src: src}) do
    case Code.string_to_quoted(src) do
      {:ok, ast} -> lvu_walk(ast, [], [])
      _ -> []
    end
  end

  defp lvu_walk({:defmodule, _, [{:__aliases__, _, segs}, body]}, mod, acc) do
    m = mod ++ segs
    inner = lvu_body(body)
    acc = if Enum.any?(inner, &lvu_component?/1), do: [Enum.join(m, ".") | acc], else: acc
    Enum.reduce(inner, acc, &lvu_walk(&1, m, &2))
  end

  defp lvu_walk(_, _, acc), do: acc

  defp lvu_body(body) do
    case body do
      [{:do, {:__block__, _, stmts}}] -> stmts
      [{:do, one}] -> [one]
      _ -> []
    end
  end

  # THE TOP-LEVEL RESTRICTION IS THE WHOLE POINT. `use Phoenix.LiveComponent` inside a
  # `quote` block is the DEFINITION of the project's own `:live_component` spelling, not
  # a use of it — lvu_body/1 returns only the module's own statements, so the definer is
  # never a member of its own class.
  defp lvu_component?({:use, _, [{:__aliases__, _, [:Phoenix, :LiveComponent]} | _]}), do: true

  defp lvu_component?({:use, _, [{:__aliases__, _, _}, {:__block__, _, [:live_component]}]}),
    do: true

  defp lvu_component?({:use, _, [{:__aliases__, _, _}, :live_component]}), do: true
  defp lvu_component?(_), do: false

  defp lv_sym_diff(a, b) do
    sa = MapSet.new(a)
    sb = MapSet.new(b)
    sa |> MapSet.symmetric_difference(sb) |> Enum.sort()
  end

  defp lv_delegation?(d) do
    case lv_do(d.body) do
      {{:., _, [{:__aliases__, _, _}, f]}, _, args} when is_atom(f) and is_list(args) -> true
      _ -> false
    end
  end

  defp lv_do(nil), do: nil

  defp lv_do(body) when is_list(body) do
    Enum.find_value(body, fn
      {{:__block__, _, [:do]}, e} -> e
      {:do, e} -> e
      _ -> nil
    end)
  end

  defp lv_do(e), do: e

  defp short_mod(m), do: m |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

  # -- THE ARM. The block stops being print-only here (wave 42).
  #
  # A RELATION, NEVER A CLASS COUNT. It asserts that every clause in the population is
  # disposed EXACTLY ONCE across the declared classes, residual included — so an honest
  # reclassification (a live_session gaining a hook, a component gaining a route) moves
  # two counts and can never red it, while a clause that falls out of the taxonomy reds
  # BY NAME instead of shrinking a denominator nobody was watching.
  defp liveview_checks(%{liveview: %{} = lv}) do
    ok? = lv.sum == lv.population and lv.stray == []

    why =
      if ok? do
        "#{lv.population} handle_event/3 clause(s) disposed EXACTLY ONCE across #{map_size(lv.freqs)} REACH class(es) — " <>
          (lv.order
           |> Enum.map(fn c -> "#{c} #{Map.get(lv.freqs, c, 0)}" end)
           |> Enum.join(", ")) <>
          " · RESIDUAL #{lv.residual} printed with its count — mount callsites outside every live_session, never folded · DENIES #{lv.denies} / #{lv.reachable} deny-by-default against #{lv.halt_keyed} / #{lv.reachable} on the naive halt key · ATTACH-CERTAINTY #{lv.attach_certain} / #{lv.reachable}"
      else
        "the REACH partition sums to #{lv.sum} over a population of #{lv.population}" <>
          if lv.stray == [], do: "", else: " · class(es) outside the declared taxonomy: #{inspect(lv.stray)}"
      end

    [{"LIVEVIEW-REACH-CLOSES", ok?, why}]
  end

  defp liveview_checks(_), do: []

  # WHAT THE ROUTE LENS ITSELF CANNOT SEE. The blind shapes are NAMED with their line, and
  # the resolved-macro count is DERIVED from the AST — a plain `grep -c` over router.ex
  # counts comment prose as callsites, which is the transcription error this epic exists
  # to kill, printed side by side so the difference is on the record.
  defp report_lens_can_miss(:no_router), do: :ok

  defp report_lens_can_miss(d) do
    {resolved, blind} = Enum.split_with(d.macro_sites, &(elem(&1, 0) == @routed_resolved_macro))

    p("WHAT THE ROUTE LENS CANNOT EXPAND (blind shapes, named and counted)")
    p(String.duplicate("-", 78))
    p("  #{length(resolved)}  #{@routed_resolved_macro}/1 callsite(s) — RESOLVED here (a plain substring count over")
    p("     router.ex says #{d.textual_macro}; the difference is comment prose, which the AST does not count)")

    if blind == [] do
      p("  0  route-generating macro callsite(s) this lens cannot expand")
    else
      p("  #{length(blind)}  route-generating macro callsite(s) this lens CANNOT expand — the routes they")
      p("     emit are absent from the population above, and that absence is stated here:")

      Enum.each(blind, fn {name, arity, line} ->
        p("       #{name}/#{arity} at #{short(@router_path)}:#{line} — expanded by a dependency this")
        p("         build-free lens never compiles, so its routes are UNCOUNTED, not judged")
      end)
    end

    p("")
  end

  # -- the two arms -----------------------------------------------------------
  #
  # THEY LIVE IN THE UNCONDITIONAL CHECKS LIST, NEVER INSIDE register_checks/2 (PDS-D541).
  # register_scope/1 returns :scoped_out unless a live corpus path matches one of
  # @register's controller paths, and router.ex is not one of them — an arm added there is
  # UNMUTATABLE: a probe hardcoded false in that branch still printed SELFTEST OK. Each arm
  # carries its OWN router-presence predicate instead.
  defp routed_checks(:no_router), do: []

  defp routed_checks(d) do
    disp = d.disposition
    {resolved, blind} = Enum.split_with(d.macro_sites, &(elem(&1, 0) == @routed_resolved_macro))
    ok? = disp.undisposed == [] and disp.orphans == [] and disp.dupes == []
    pairs = d.population |> Enum.map(fn {_, _, mod, a} -> {mod, a} end) |> Enum.uniq() |> length()

    complete_why =
      if ok? do
        "#{length(d.population)} ROUTED-WRITE member(s) <-> #{disp.judged} judged + #{disp.rostered} rostered + #{disp.excluded} excluded, both directions, no duplicate key"
      else
        Enum.join(
          [
            "#{length(disp.undisposed)} ROUTED-WRITE member(s) carry NO disposition",
            "#{length(disp.orphans)} disposition row(s) name NO live routed member",
            "#{length(disp.dupes)} disposition key(s) carry more than one row",
            "the quad key sees #{length(d.population)} member(s) where a {module, action} key sees #{pairs} — an arrival onto an already-disposed pair is INVISIBLE under the pair key"
          ] ++
            Enum.map(Enum.take(disp.undisposed, 4), fn {m, p, mod, a} ->
              "UNDISPOSED ARRIVAL #{m} #{p} -> #{mod}.#{a}"
            end) ++
            Enum.map(Enum.take(disp.orphans, 4), fn {{m, p, mod, a}, c} ->
              "ORPHANED DISPOSITION #{m} #{p} -> #{mod}.#{a} [#{c}]"
            end) ++
            Enum.map(Enum.take(disp.dupes, 4), fn {m, p, mod, a} ->
              "DUPLICATE DISPOSITION #{m} #{p} -> #{mod}.#{a}"
            end),
          " · "
        )
      end

    lens_why =
      if resolved == [] do
        "the blind-shape detector found ZERO #{@routed_resolved_macro}/1 callsite(s) in a router.ex that a plain substring count reads #{d.textual_macro} time(s) — the lens can no longer name what it cannot expand, so every population figure above is over an unknown denominator"
      else
        "#{length(resolved)} #{@routed_resolved_macro}/1 callsite(s) resolved (substring count #{d.textual_macro}; the rest is comment prose) · #{length(blind)} unexpandable macro callsite(s) NAMED: " <>
          if blind == [],
            do: "none",
            else: Enum.map_join(blind, ", ", fn {n, a, l} -> "#{n}/#{a}:#{l}" end)
      end

    [
      {"ROUTED-POPULATION-COMPLETE", ok?, complete_why},
      {"LENS-CAN-MISS", resolved != [], lens_why}
    ] ++ derivation_checks(d) ++ liveview_checks(d)
  end

  # A RELATION, NEVER A THRESHOLD (PDS wave 40). This arm asserts that the partition
  # DISPOSES ITS OWN CLASS EXACTLY ONCE — the sum of the eight classes equals the
  # `status_only_receipt` count the same run derived. Both sides move together on any
  # honest lens correction, so it cannot red on churn; it reds only when a row falls out
  # of the taxonomy or is counted twice, which is the failure a partition can actually
  # have. It pins NO class count: pinning `store_derived == 60` would red the build every
  # time a controller was repaired, which is the defect this epic files, not the guard.
  defp derivation_checks(d) do
    rows = Map.get(d, :derivation, [])
    total = Map.get(d.disposition.classes, @derivation_class, 0)
    freqs = Enum.frequencies_by(rows, & &1.class)
    sum = Enum.sum(Map.values(freqs))
    stray = freqs |> Map.keys() |> Enum.reject(&(&1 in @derivation_order))
    residual = Enum.reduce(@derivation_residual, 0, &(&2 + Map.get(freqs, &1, 0)))

    why =
      if sum == total and stray == [] do
        "#{total} #{@derivation_class} row(s) disposed EXACTLY ONCE across #{map_size(freqs)} class(es) — " <>
          (freqs
           |> Enum.sort_by(fn {c, _} -> derivation_rank(c) end)
           |> Enum.map_join(", ", fn {c, n} -> "#{c} #{n}" end)) <>
          " · RESIDUAL #{residual} printed with its count, never folded into a decided class"
      else
        "the partition sums to #{sum} over a #{@derivation_class} class of #{total}" <>
          if stray == [], do: "", else: " · class(es) outside the declared taxonomy: #{inspect(stray)}"
      end

    [{"DERIVATION-PARTITION-TOTAL", sum == total and stray == [], why}]
  end

  # ---------------------------------------------------------------- blind spots

  defp report_blind_spots(parsed) do
    json = sum_occ(parsed, "json(conn,")
    send_resp = sum_occ(parsed, "send_resp(conn, 2")

    put2xx =
      Enum.sum(
        for f <- parsed do
          Enum.sum(
            for pat <- ["put_status(:ok", "put_status(:created", "put_status(:accepted",
                        "put_status(:no_content", "put_status(20"],
                do: count(f.src, pat)
          )
        end
      )

    p("WHAT THIS LENS CANNOT SEE (a census that hides its blind spots is propaganda)")
    p(String.duplicate("-", 78))
    p("  #{json}  json(conn, ...) responses — a 200 with no `ok` key claims success by STATUS alone")
    p("  #{put2xx}  put_status(2xx) sites — same claim, wearing a status code")
    p("  #{send_resp}  send_resp(conn, 2xx) sites — same again, with no body to inspect")
    p("  ALSO INVISIBLE: `mix ecto.migrations` reporting `up` (PDS-D311) — it reads a")
    p("  bookkeeping row, never the object the migration claims to have produced.")
    p("  Re-derive these three without this script (plain substrings, no \\b needed):")
    p("    git grep -c 'json(conn,' -- 'api/lib/**/*.ex' | awk -F: '{s+=$2} END{print s}'")
    p("    git grep -c 'send_resp(conn, 2' -- 'api/lib/**/*.ex' | awk -F: '{s+=$2} END{print s}'")
    p("")
    report_roster(parsed)
  end

  # THE ROSTER, PRINTED WITH ITS ANCHORS RESOLVED LIVE. The line beside each row is
  # DERIVED from the literal on every run, never transcribed — that is the whole point of
  # anchoring on a literal.
  defp report_roster(parsed) do
    p("  THE POPULATION ROSTER — #{length(@roster)} NAMED sites outside this lens that report success")
    p("  without a read. A total names nobody; these are named, each with a verdict from")
    p("  the SAME vocabulary the register uses, and each anchored on a LITERAL.")

    Enum.each(roster_freshness(parsed), fn {r, res} ->
      case res do
        %{state: :fresh, line: line, mfa: mfa} ->
          p("      #{String.pad_trailing(r.verdict, 9)} #{short(r.path)}:#{line}  [#{r.basis}]  #{mfa}")
          wrap(r.note, "               ")

        # DEMOTED AT PRINT TIME, NEVER REWRITTEN IN THE FILE. Same discipline as
        # `basis_stale` on the register (PDS-D527): the committed row stays exactly as its
        # author wrote it, so the demotion is a diff-free fact a human re-derives — no
        # script assigns a verdict.
        %{state: :stale, line: line, moved: moved} ->
          p("      UNJUDGED  #{short(r.path)}:#{line}  [#{r.basis}]  VERDICT UNRE-DERIVED")
          p("               recorded #{r.verdict}, demoted here because #{Enum.join(moved, " and ")}")
          wrap(r.note, "               ")

        %{state: :unresolved, why: why} ->
          p("      UNJUDGED  #{short(r.path)}  ANCHOR UNRESOLVED — #{why} — see ROSTER-VERDICT-FRESH")

        %{state: :absent} ->
          p("      #{String.pad_trailing(r.verdict, 9)} #{short(r.path)}  ANCHOR MISSING — see ROSTER-ANCHORS-EXIST")
      end
    end)

    p("")
  end

  # EXISTENCE, NEVER A COUNT. The three totals above moved 7 times in 9 days on unrelated
  # work; an arm over them would have been switched off inside a fortnight. A literal that
  # has left its file is a real, actionable fact — the roster row now describes nothing.
  defp roster_anchor(src, r) do
    lines = src |> Map.get(r.path, "") |> String.split("\n")

    case Enum.find_index(lines, &String.contains?(&1, r.literal)) do
      nil -> :missing
      i -> {:ok, i + 1}
    end
  end

  defp roster_check(parsed) do
    src = Map.new(parsed, &{&1.path, &1.src})
    missing = Enum.filter(@roster, &(roster_anchor(src, &1) == :missing))

    why =
      if missing == [] do
        "all #{length(@roster)} roster literal(s) still occur in their named file (EXISTENCE, never a count)"
      else
        "#{length(missing)} roster literal(s) have LEFT their file — the row now describes nothing: " <>
          Enum.map_join(missing, " · ", &"#{short(&1.path)} #{inspect(&1.literal)}")
      end

    {"ROSTER-ANCHORS-EXIST", missing == [], why}
  end

  # -- ROSTER-VERDICT-FRESH ---------------------------------------------------
  #
  # A VERDICT THAT OUTLIVES ITS DEFECT IS THE OVER-CLAIM THIS CENSUS EXISTS TO FIND,
  # POINTED AT THE CENSUS. Two @roster rows were verdicted REFUTED at 501fb9670; fbc6b80a1
  # repaired both callees; both LITERALS survived byte-for-byte, so ROSTER-ANCHORS-EXIST
  # printed PASS and the whole report was BYTE-IDENTICAL either side of the repair except
  # two derived line numbers and the wall clock. The instrument could not tell a repaired
  # tree from an unrepaired one, and its ENTIRE accusatory surface was those two rows.
  #
  # THE FIX IS A FIELD, NOT AN ARM. Freshness cannot be checked against a fact that is not
  # recorded: the sha these verdicts were derived at lived only in a comment. Each row now
  # carries `anchor_mfa` and `def_fp` for the def that ENCLOSES its literal, and this arm
  # re-derives both every run. It is the same shape the register already uses for
  # `basis_stale` — recorded key vs current key, demote at print time, never edit.
  #
  # THE RESOLUTION IS THE NARROWEST ENCLOSING def. roster_functions/1 takes EVERY def
  # whose span contains the anchor because a superset only widens a disposition; a
  # FINGERPRINT must be unambiguous, so ties go to the smallest span.
  defp roster_freshness(parsed) do
    by_path = Map.new(parsed, &{&1.path, &1})
    Enum.map(@roster, fn r -> {r, roster_resolution(Map.get(by_path, r.path), r)} end)
  end

  # ABSENT IS NOT UNRESOLVED, AND THE SPLIT IS DELIBERATE. A file or literal that has left
  # the corpus is ROSTER-ANCHORS-EXIST's finding, and two arms redding on one fact reads as
  # two regressions. UNRESOLVED is the case only this arm can see: the literal is right
  # there, and it sits inside no def at all.
  defp roster_resolution(nil, _r), do: %{state: :absent}

  defp roster_resolution(f, r) do
    case roster_anchor(%{r.path => f.src}, r) do
      :missing ->
        %{state: :absent}

      {:ok, line} ->
        case roster_enclosing_def(f, line) do
          nil ->
            %{state: :unresolved, why: "#{short(r.path)}:#{line} lies inside no def this lens can see"}

          d ->
            roster_compare(r, d, line)
        end
    end
  end

  defp roster_enclosing_def(f, line) do
    f.defs
    |> Enum.filter(&(&1.line <= line and line <= &1.last))
    |> Enum.min_by(&(&1.last - &1.line), fn -> nil end)
  end

  # THE SAME NORMALISER THE REGISTER KEY USES (@key_normaliser), over head AND body: a
  # meta-dropped phash2 of the term, so a def that only MOVED fingerprints identically and
  # the arm stays silent on unrelated churn. Editing fp/1 or drop_meta/1 re-keys these
  # eight rows exactly as it re-keys the register's 91.
  defp roster_def_fp(d), do: fp({d.head, d.body})

  defp roster_compare(r, d, line) do
    mfa = label(d)
    dfp = roster_def_fp(d)

    moved =
      [
        if(r.anchor_mfa != mfa, do: "anchor_mfa moved #{r.anchor_mfa} -> #{mfa}"),
        if(r.def_fp != dfp, do: "def_fp moved #{r.def_fp} -> #{dfp}")
      ]
      |> Enum.reject(&is_nil/1)

    state = if moved == [], do: :fresh, else: :stale
    %{state: state, line: line, mfa: mfa, fp: dfp, moved: moved}
  end

  # IT LIVES IN THE UNCONDITIONAL CHECKS LIST, WITH ITS OWN SCOPE CALL — never as a fifth
  # element of register_checks/2 (PDS-D541). The predicate is the same one, because the
  # roster names files that live in the real corpus and none of them exist in the
  # selftest's synthetic tree. THAT is why the mutants for this arm run over the REPO
  # corpus (`corpus: :repo`) rather than the fixture: an arm proven only where it is
  # scoped out is proven nowhere, which is the exact trap D541 named.
  defp roster_freshness_checks(classified, parsed) do
    case register_scope(classified) do
      :scoped_out -> []
      :real -> [roster_freshness_check(parsed)]
    end
  end

  defp roster_freshness_check(parsed) do
    rows = roster_freshness(parsed)
    stale = for {r, %{state: :stale} = res} <- rows, do: {r, res}
    unresolved = for {r, %{state: :unresolved} = res} <- rows, do: {r, res}
    fresh = Enum.count(rows, fn {_r, res} -> res.state == :fresh end)
    absent = Enum.count(rows, fn {_r, res} -> res.state == :absent end)

    # 0-OF-8 IS NOT A PASS. An arm that certifies an empty set is the vacuous green this
    # epic exists to refuse, and it is the exact failure mode a broken resolver produces.
    vacuous? = fresh == 0 and stale == [] and unresolved == []

    why =
      cond do
        vacuous? ->
          "NOT ONE of #{length(@roster)} roster row(s) resolved to a def, so this arm certified an EMPTY SET — the resolver, not the roster, is what failed"

        stale != [] or unresolved != [] ->
          named =
            Enum.map(stale, fn {r, res} ->
              "STALE VERDICT #{r.verdict} #{short(r.path)}:#{res.line} — #{Enum.join(res.moved, " · ")}"
            end) ++
              Enum.map(unresolved, fn {_r, res} -> "UNRESOLVED ANCHOR #{res.why}" end)

          "#{length(stale)} stale + #{length(unresolved)} unresolved of #{length(@roster)} roster row(s) — " <>
            Enum.join(Enum.take(named, 4), " || ") <>
            if(length(named) > 4, do: " || (+#{length(named) - 4} more, all listed in the roster block above)", else: "") <>
            " — each was judged against a def that no longer exists in that shape, so it is DEMOTED TO UNJUDGED in the roster block above and a human owes it a re-derivation; this arm never edits a verdict"

        true ->
          "#{fresh} roster verdict(s) still name the def they were derived against — anchor_mfa AND def_fp both re-derived this run, never transcribed" <>
            if(absent > 0, do: " (#{absent} row(s) absent from this corpus — ROSTER-ANCHORS-EXIST owns those)", else: "") <>
            ". BLIND SHAPE, STATED: both granularities are SAME-FILE. `git show --stat fbc6b80a1` — the repair that made two of these rows stale — also touched scim.ex and accounts.ex, and a future repair confined to a CALLEE moves no byte inside the roster row's own def, so this arm would print PASS through it"
      end

    {"ROSTER-VERDICT-FRESH", not vacuous? and stale == [] and unresolved == [], why}
  end

  defp sum_occ(parsed, needle), do: Enum.sum(Enum.map(parsed, &count(&1.src, needle)))

  # ---------------------------------------------------------------- delegate probe

  # PDS-D449a trap 2: Barkpark.Tasks is a 24-entry defdelegate facade, and `defdelegate`
  # is not `def` — a naive write detector reports 24 of 25 sites false. This probe is the
  # ONLY thing in the script that can go red on a code change: it asserts the facade still
  # resolves through to a real write verb.
  defp report_delegate_probe(index) do
    facade = Map.get(index.by_module, [:Barkpark, :Tasks], [])
    delegates = Enum.filter(facade, & &1.delegate)
    close = Enum.find(delegates, &(&1.name == :close))

    {verbs, depth, chain} =
      case close do
        nil -> {%{}, nil, []}
        d -> bfs([{d, 0, [label(d)]}], index, MapSet.new(), %{}, nil, [], @max_depth)
      end

    write? = Map.has_key?(verbs, :write)

    p("DELEGATE PROBE — Barkpark.Tasks (the facade that makes naive detectors lie)")
    p(String.duplicate("-", 78))
    p("  defdelegate entries on Barkpark.Tasks: #{length(delegates)}")
    p("    (`git grep -c defdelegate api/lib/barkpark/tasks.ex` says 24 — three of those are")
    p("     the word `defdelegated` in comments. The AST counts declarations, not prose.)")

    if close do
      hops =
        case chain do
          [_ | rest] when rest != [] -> Enum.join(rest, " -> ")
          _ -> "(no write reached — the chain ends without one)"
        end

      p("  Barkpark.Tasks.close/#{close.arity} -> delegate -> #{hops}")

      verbs
      |> Map.get(:write, [])
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.each(fn {v, l, path, d} -> p("    write verb #{v} at #{short(path)}:#{l} (depth #{d})") end)
    end

    p("  reaches a write verb: #{write?}")
    p("")

    %{delegates: length(delegates), close_write?: write?, close_depth: depth}
  end

  # ---------------------------------------------------------------- selftest
  #
  # A SELFTEST THAT HAS NEVER BEEN OBSERVED RED IS NOT A SELFTEST. This one mutates THIS
  # FILE, one anchored edit at a time, and requires the mutant to go red on the arm the
  # mutation kills. Every case that carries a mutation also requires its anchor to occur
  # EXACTLY ONCE — an anchor a refactor moved would otherwise leave a case that runs the
  # unmutated script and passes vacuously.
  #
  # THE SEAM IS CWD INJECTION. corpus/1 globs `api/lib/**/*.ex` relative to the working
  # directory and @sentinels are relative literals, so a synthetic tree in a tmp dir is
  # censused verbatim by running this same file with `cd:` set to it. The `--files-from`
  # seam does NOT work for fixtures: guard_corpus!/1 runs before parse_file/1 and ORs the
  # corpus floor with the sentinel check on ONE cond arm, so no fixture list is both small
  # enough to mutate and large enough to pass.
  #
  # PDS-D511, RESTATED HONESTLY (PDS wave 37). It is often quoted as "the selftest was
  # disarmed". It was not: it disarmed EMITTERS-PARTITION, ONE ARM OF NINE, and the other
  # eight kept going red on their own mutants throughout. The wave-37 finding is a
  # different and larger one — KEYS-ONE-LINE-PER-SITE was never armed AT ALL, because the
  # relation it asserted is true by construction (see judge_selftest_case/5 below).
  #
  # IT ASSERTS NO BUCKET COUNT — not one. Exit codes, arm names, refusal prose, and one
  # RELATION (keys lines == emitted, both read off the same invocation). A selftest that
  # pinned POST-READ or the unclassified denominator would red the build on every honest
  # lens correction, which is the defect this epic keeps filing, not the guard. PDS-D467b:
  # CORPUS-INTACT is structurally unreachable in normal operation — guard_corpus!/1 exits 2
  # on exactly the condition that arm tests — so it is proven by BYPASSING the guard.
  @self_source Path.expand(__ENV__.file)
  @pair_atom "ok:" <> " true"
  @selftest_filler 620

  @selftest_cases [
    %{
      name: "BASELINE-GREEN",
      corpus: :full,
      argv: [],
      mut: nil,
      exit: 0,
      expect: ["CENSUS OK"],
      proves: "the synthetic corpus censuses clean, so every red below is the mutation"
    },
    %{
      name: "ARGV-STRICT",
      corpus: :full,
      argv: ["--nonsense-flag"],
      mut: nil,
      exit: 2,
      expect: ["REFUSED: UNKNOWN ARGUMENT", "unknown argument"],
      proves: "an unnamed flag refuses instead of running an unrequested lens (PDS-D493)"
    },
    %{
      name: "CORPUS-REFUSAL",
      corpus: :tiny,
      argv: [],
      mut: nil,
      exit: 2,
      expect: ["REFUSED: TRUNCATED CORPUS"],
      proves: "a corpus under the floor exits 2 rather than reporting zeros it cannot stand behind"
    },
    %{
      name: "CORPUS-INTACT (guard bypassed)",
      corpus: :tiny,
      argv: [],
      # EVERY ANCHOR IS SPELLED IN TWO FRAGMENTS JOINED AT COMPILE TIME. Written whole, the
      # anchor would occur twice in this file — here and at the line it targets — and the
      # exactly-once check in apply_mutation/2 would reject its own case list.
      mut: {"stand behind. Exit 2.\")\n    System." <> "halt(2)", "stand behind. Exit 2.\")\n    :bypassed_by_selftest"},
      exit: 1,
      expect: ["FAIL  CORPUS-INTACT", "is BELOW the"],
      proves: "the arm itself can go red once the guard that shadows it is removed"
    },
    %{
      name: "LENS-LOSES-NOTHING",
      corpus: :full,
      argv: [],
      mut: {"if extra" <> " > 0 do", "if false do"},
      exit: 1,
      expect: ["FAIL  LENS-LOSES-NOTHING", "the lens LOSES"],
      proves: "a textual occurrence the lens can neither parse nor explain reds the run"
    },
    %{
      name: "EMITTERS-PARTITION",
      corpus: :full,
      argv: [],
      mut:
        {"{consumers, emitted} = Enum.split_with(ast_sites" <> ", & &1.pattern?)",
         "{consumers, emitted} = Enum.split_with(tl(ast_sites), & &1.pattern?)"},
      exit: 1,
      expect: ["FAIL  EMITTERS-PARTITION", "is NOT the AST population"],
      proves: "an emitted site dropped between the AST and the split reds the run"
    },
    %{
      name: "CLASSIFICATION-TOTAL",
      corpus: :full,
      argv: [],
      mut:
        {"classified = Enum.map(routed" <> ", &classify(&1, index))",
         "classified = tl(Enum.map(routed, &classify(&1, index)))"},
      exit: 1,
      expect: ["FAIL  CLASSIFICATION-TOTAL", "fell out of the taxonomy entirely"],
      proves: "a site that leaves the taxonomy reds the run instead of shrinking a denominator"
    },
    %{
      name: "DELEGATE-REACHES-WRITE",
      corpus: :full,
      argv: [],
      mut: {"do: resolve(index, target, as" <> ", d.arity)", "do: []"},
      exit: 1,
      expect: ["FAIL  DELEGATE-REACHES-WRITE", "reaches NO write verb"],
      proves: "a route that can no longer follow a defdelegate reds the run (PDS-D449a trap 2)"
    },
    %{
      name: "KEYS-ONE-LINE-PER-SITE",
      corpus: :full,
      argv: ["--keys"],
      mut: nil,
      exit: 0,
      expect: {:keys, :holds},
      proves: "--keys prints one DISTINCT TSV line per emitted site, and the count survives an independent re-derivation"
    },
    # THE THREE MUTANTS THAT PROVE THE FLOOR IS NOT VACUOUS (PDS-D519). Each kills the
    # keys emission a DIFFERENT way, and each names the sub-check that must catch it —
    # a mutant caught by the WRONG sub-check is a FAIL here, not a pass.
    %{
      name: "KEYS-FLOOR-NOT-VACUOUS",
      corpus: :full,
      argv: ["--keys"],
      mut:
        {"{_consumers, emitted} = Enum.split_with(ast_sites" <> ", & &1.pattern?)",
         "{_consumers, emitted} = {ast_sites, []}"},
      exit: 0,
      expect: {:keys, {:reds, "VACUOUS"}},
      proves: "an emission zeroed inside keys_run/1 reds, instead of certifying 0 == 0 == 0"
    },
    %{
      name: "KEYS-PARTIAL-DROP",
      corpus: :full,
      argv: ["--keys"],
      mut:
        {"{_consumers, emitted} = Enum.split_with(ast_sites" <> ", & &1.pattern?)",
         "{_consumers, emitted} = (fn {c, e} -> {c, Enum.drop(e, 1)} end).(Enum.split_with(ast_sites, & &1.pattern?))"},
      exit: 0,
      expect: {:keys, {:reds, "independently derived emitted"}},
      proves: "a ONE-ROW drop reds — measured to slip past a `tsv > 0` floor, which agrees with itself at the reduced number"
    },
    %{
      name: "KEY-DISCRIMINATES",
      corpus: :full,
      argv: ["--keys"],
      mut:
        {"IO.puts(Enum.join([path, mfa, hh" <> ", fp], \"\\t\"))",
         "IO.puts(Enum.join([path, mfa, hh], \"\\t\"))"},
      exit: 0,
      expect: {:keys, {:reds, "does not DISCRIMINATE"}},
      proves: "dropping expr_fp from the key collapses two sites in one clause to one row — the register would silently lose a site"
    },
    # THE ROUTED-POPULATION ARMS (PDS wave 38). Both directions, plus the blind-shape
    # detector.
    #
    # WHY THE ARRIVAL IS PLANTED IN THE DERIVATION AND NOT IN THE FIXTURE ROUTER. The two
    # corpora are written ONCE by selftest/0 with the UNMUTATED write_corpus!/2 and then
    # censused by the mutant; a mutation to the fixture heredoc changes a function the
    # mutant never calls and the case passes vacuously at exit 0 (measured — it is how the
    # first draft of these two cases went green while asserting nothing). The route is
    # therefore planted into the derived population itself, one synthetic quad onto
    # Barkpark.Filler.M1.noop — a pair the fixture's TWO committed rows already dispose,
    # so the arrival is exactly the shape a {module, action} key cannot see.
    %{
      name: "ROUTED-ARRIVAL-REDS",
      corpus: :full,
      argv: [],
      mut:
        {"(literal ++ mounted)" <> "\n        |> Enum.map",
         "(literal ++ mounted ++ [{:post, \"/v1/selftest-planted\", \"Barkpark.Filler.M1\", :noop}])\n        |> Enum.map"},
      exit: 1,
      expect: ["FAIL  ROUTED-POPULATION-COMPLETE", "UNDISPOSED ARRIVAL", "/v1/selftest-planted"],
      proves: "a write route ARRIVING onto an ALREADY-DISPOSED {module, action} pair reds by name — the quad key sees it where a {module, action} key cannot, because the pair count does not move at all"
    },
    %{
      name: "ROUTED-DEPARTURE-REDS",
      corpus: :full,
      argv: [],
      mut:
        {"{:post, \"/v1/selftest-departure-anchor\", \"Barkpark.Filler.M1\", :noop, :selftest_fixture}" <> ",",
         "{:post, \"/v1/selftest-departure-anchor\", \"Barkpark.Filler.M1\", :noop, :selftest_fixture},\n    {:post, \"/v1/selftest-never-routed\", \"Barkpark.Filler.M1\", :noop, :selftest_fixture},"},
      exit: 1,
      expect: ["FAIL  ROUTED-POPULATION-COMPLETE", "ORPHANED DISPOSITION", "/v1/selftest-never-routed"],
      proves: "a committed disposition that names NO live routed member reds too — one direction alone is half an arm, and a row judging nothing is the shape a stale table takes"
    },
    %{
      name: "LENS-CAN-MISS-ARMED",
      corpus: :full,
      argv: [],
      mut: {"macro_sites: router_macro_sites(ast)" <> ",", "macro_sites: [],"},
      exit: 1,
      expect: ["FAIL  LENS-CAN-MISS", "blind-shape detector found ZERO"],
      proves: "killing the blind-shape detector reds LENS-CAN-MISS BY NAME, not a neighbour — the population figures would otherwise sit over an unknown denominator"
    },
    %{
      name: "LENS-CAN-MISS-NAMES-BLIND",
      corpus: :full,
      argv: [],
      mut: nil,
      exit: 0,
      expect: ["PASS  LENS-CAN-MISS", "live_dashboard/2", "CANNOT expand"],
      proves: "a route-generating macro the lens cannot expand is NAMED with its line, so the routes it emits are stated absent rather than silently missing"
    },
    # THE DERIVATION PARTITION (PDS wave 40), PROVEN BY A CORPUS PAIR RATHER THAN A DIFF.
    #
    # The mutation axis here is the FIXTURE, not this file: `:full` carries the six
    # pre-#9114 receipt bodies and `:repaired` carries the same six actions rendering the
    # stored row. That is deliberate and it is the ONE shape where a fixture mutation is
    # not vacuous — the two corpora are written by write_corpus!/3 BEFORE the case runs
    # and are the very input under test, where a heredoc edit reached by no mutant would
    # be a function the child never calls (measured, and recorded above the routed cases).
    #
    # AND IT FIRES BOTH WAYS. Presence alone would pass for a classifier that shouted
    # "echo" at every delete verb it met; `refute:` is what makes the repaired corpus a
    # real half of the proof rather than a second copy of the first.
    %{
      name: "PARTITION-NAMES-REQUEST-ECHO",
      corpus: :full,
      argv: [],
      mut: nil,
      exit: 0,
      expect: [
        "request_echo — all 6",
        "EchoController.delete_schema",
        "EchoController.delete_document",
        "EchoController.delete_asset",
        "EchoController.revoke_share_token",
        "EchoController.revoke_share_link",
        "EchoController.delete_webhook"
      ],
      refute: ["store_derived — all 6"],
      proves: "the classifier NAMES all six of the receipt bodies #9114 found answering with the request instead of the store — the species that costs a person most on a delete or revoke verb"
    },
    %{
      name: "PARTITION-ECHO-REPAIRED-CLEAN",
      corpus: :repaired,
      argv: [],
      mut: nil,
      exit: 0,
      expect: ["store_derived — all 6", "EchoController.delete_schema", "via delete"],
      refute: ["request_echo — all 6", "request_echo — all 5", "request_echo — all 1"],
      proves: "the SAME six actions, repaired to render the stored row, are named request_echo ZERO times — so the verdict is a derivation over the receipt's value expression, not a string test on the verb"
    },
    # THE HOP-ARGUMENT SHAPE DISPATCH (PDS wave 42), ARMED AGAINST ITS OWN REPAIR.
    #
    # Its corpus is the REPO, and it has to be: the four rows the repair moves are
    # TicketKeysController.pause/unpause, which live in api/lib and not in any fixture
    # heredoc. The mutation collapses the top-level {:call, _} dispatch back to the
    # flattened NAME SET this wave repaired, and the child then re-prints the exact false
    # verdict that shipped on main — the four routed TicketKeys rows accused of echoing the
    # request, when `stamp_response(conn, Keys.pause(id, ...))` binds the write's return.
    #
    # IT ASSERTS NO BUCKET COUNT IT DOES NOT HAVE TO. "request_echo — all 8" and
    # "request_echo — all 4" are the two SIDES of one relabel, and only a relabel of these
    # four rows can move between them; an honest lens correction elsewhere in the class
    # changes both strings together and this case is written to red only when the mutation
    # fails to restore the defect (the anchor moved) or the repair silently stops working.
    %{
      name: "HOP-ARG-SHAPE-ARMED",
      corpus: :repo,
      argv: [],
      mut:
        {"case hop_arg_" <> "shape(arg) do",
         "case (case hop_arg_" <> "shape(arg) do {:call, _} -> {:vars, dvars(arg)}; o -> o end) do"},
      exit: 0,
      expect: [
        "request_echo — all 8",
        "TicketKeysController.pause",
        "renders a value bound in the action's HEAD (this clause's own body has no response call)"
      ],
      refute: ["request_echo — all 4", "via pause"],
      proves: "collapsing the hop argument's TOP-LEVEL shape back to a flattened name set restores the over-accusation this wave repaired — four routed TicketKeys rows accused of echoing the request on a value that came out of Keys.pause/2 — so the repaired verdict is DERIVED from the dispatch and not a constant the roster happens to print"
    },
    %{
      name: "PARTITION-TOTAL-ARMED",
      corpus: :full,
      argv: [],
      mut: {"rows = Map.get(d, :deriv" <> "ation, [])", "rows = tl(Map.get(d, :derivation, []))"},
      exit: 1,
      expect: ["FAIL  DERIVATION-PARTITION-TOTAL", "the partition sums to"],
      proves: "a row that falls out of the partition reds BY NAME instead of shrinking a denominator — the arm asserts a RELATION (sum == the class it partitions), never a class count, so an honest reclassification can never red it"
    },
    # THE FRESHNESS ARM (PDS wave 39), AND WHY ITS CORPUS IS THE REPO ITSELF.
    #
    # ROSTER-VERDICT-FRESH is scoped to the real corpus by register_scope/1 — the roster
    # names eight files that exist only in api/lib, and the synthetic tree holds none of
    # them. Mutating this arm and running it over the FIXTURE would run a check that
    # returned [] before the mutation and [] after it, and print SELFTEST OK: the exact
    # unmutatability D541 named. So these four cases census the REPO (`corpus: :repo`),
    # which is where the arm is in scope, and the baseline below is what makes the three
    # reds attributable to their mutations.
    #
    # EVERY MUTATION EDITS A COMMITTED @roster ROW OR THE ARM'S OWN RESOLVER — never the
    # fixture heredoc, which write_corpus!/2 writes UNMUTATED before the mutant runs (a
    # fixture mutation is a function the mutant never calls, and passes vacuously at
    # exit 0; measured, and recorded above the routed cases).
    %{
      name: "REPO-BASELINE-GREEN",
      corpus: :repo,
      argv: [],
      mut: nil,
      exit: 0,
      expect: ["CENSUS OK", "PASS  ROSTER-VERDICT-FRESH", "PASS  D448-DRIFT-REFUSES"],
      proves: "the arm is GREEN on the unmodified repo, so each red below is its mutation and not a tree that was already failing (the population baseline rides this same case: it is in scope over the repo corpus and nowhere else)"
    },
    %{
      name: "ROSTER-DEF-FP-MOVED",
      corpus: :repo,
      argv: [],
      # The case that OCCURRED: fbc6b80a1 changed two def BODIES under stable names.
      # Perturbing the RECORDED fingerprint is the same divergence seen from the other
      # side — recorded pair vs re-derived pair — and it is the only side a selftest can
      # edit without touching api/lib.
      mut: {"def_fp: " <> "\"131930615\"", "def_fp: \"131930615-perturbed\""},
      exit: 1,
      expect: ["FAIL  ROSTER-VERDICT-FRESH", "def_fp moved", "pulse_controller.ex"],
      proves: "a roster verdict whose def CHANGED under a stable name reds by name and is demoted to UNJUDGED at print time — the staleness that shipped through a whole wave with every arm printing PASS"
    },
    %{
      name: "ROSTER-ANCHOR-MFA-MOVED",
      corpus: :repo,
      argv: [],
      # The case that will occur NEXT: a def RENAMED with its body byte-identical. def_fp
      # is blind to it by construction — the fingerprint is over head+body, and this
      # mutation moves neither — so this case is what proves the second granularity is
      # load-bearing rather than decorative.
      mut:
        {"anchor_mfa: " <> "\"BarkparkWeb.PulseController.preflight/2\"",
         "anchor_mfa: \"BarkparkWeb.PulseController.cors_preflight/2\""},
      exit: 1,
      expect: ["FAIL  ROSTER-VERDICT-FRESH", "anchor_mfa moved", "cors_preflight/2"],
      proves: "a roster verdict whose def was RENAMED under an identical body reds too — def_fp cannot see this one, so neither granularity alone is the arm"
    },
    %{
      name: "ROSTER-FRESH-NOT-VACUOUS",
      corpus: :repo,
      argv: [],
      # THE 0-OF-8 SHAPE. A resolver that finds no def makes every comparison unreachable,
      # which is how a freshness arm certifies an empty set at exit 0 — the LENS-CAN-MISS
      # -ARMED failure mode, wearing this arm's name.
      mut:
        {"|> Enum.min_by(&(&1.last - &1.line)" <> ", fn -> nil end)", "|> then(fn _ -> nil end)"},
      exit: 1,
      expect: ["FAIL  ROSTER-VERDICT-FRESH", "0 stale + 8 unresolved of 8", "UNRESOLVED ANCHOR"],
      proves: "a resolver that resolves NOTHING reds on a stated unresolved COUNT instead of passing 0-of-8 — an arm that certifies an empty set is the vacuous green this epic refuses"
    },
    # THE ONE-HOP JOIN (PDS wave 41), AND WHY ITS CORPUS IS THE REPO. The join's whole
    # subject is a HOP between two real defs, and the synthetic tree's controllers respond
    # in their own bodies — a fixture would exercise the code and prove nothing about it.
    # Neither case pins a COUNT: the first asserts one named conversion and one named
    # refusal, the second asserts that BOTH move when the resolution is killed.
    %{
      name: "ONEHOP-DECIDES-AND-REFUSES",
      corpus: :repo,
      argv: [],
      mut: nil,
      exit: 0,
      expect: [
        "ONE HOP into SessionIssuer.issue/3",
        "AuthController.issue_session/3 [emits nothing — a SECOND hop]",
        "THE PRECEDENCE MASK, PRINTED BOTH SIDES"
      ],
      # THE OVER-NAMING HALF. A join that followed TWO hops would print the wrapper itself
      # as the deciding target, and no list of expected substrings can state that absence.
      refute: ["ONE HOP into AuthController.issue_session/3"],
      proves: "the join converts across a REMOTE target (WebauthnController.login -> SessionIssuer.issue/3, which a local-only rule scores one lower) AND refuses the two-hop wrapper BY NAME rather than silently — a refusal a reader can open and take apart"
    },
    %{
      name: "ONEHOP-YIELD-NOT-CONSTANT",
      corpus: :repo,
      argv: [],
      # Kill the candidate RESOLUTION, not the printing: the block still runs, so a printed
      # yield that survives this mutation is a constant rather than a measurement.
      mut: {"|> Enum.flat_map(&hop_de" <> "fs(d, index, &1))", "|> Enum.flat_map(fn _ -> [] end)"},
      exit: 0,
      expect: ["NO hop target resolves in this corpus", "THE ONE-HOP JOIN over the helper-assembled band"],
      refute: ["ONE HOP into SessionIssuer.issue/3"],
      proves: "with the hop resolution dead every attempted clause prints the empty-candidate refusal and every conversion disappears — so the yield printed above is DERIVED from the join, and the arms stay green through it, which is the point: this pass RE-LABELS and can never cost a false green"
    },
    # THE LIVEVIEW BLOCK STOPS BEING PRINT-ONLY (PDS wave 42, discharging the pin task).
    #
    # EVERY ASSERTION BELOW IS A FRACTION, NEVER A BARE NUMERATOR. Measured on the real
    # tree: the routed and repo-wide numerators are IDENTICAL at every depth (13/34/40/
    # 47/61/62/63/66), so a numerator-only assertion cannot tell the two lenses apart at
    # any budget. The fixture reproduces that property by construction — its one
    # component clause is write-FALSE at every depth — so the same trap is live here.
    %{
      name: "LIVEVIEW-DEPTH-FRACTION",
      corpus: :full,
      argv: [],
      mut: nil,
      exit: 0,
      expect: [
        "0 / 4   (0.0%)    0 / 5   (0.0%)   <- @max_depth, the census budget",
        "1 / 4  (25.0%)    1 / 5  (20.0%)   <- the relation CLOSES here",
        "5 == population 5",
        "2 / 2  clause(s) whose EVERY live_session chain",
        "2 / 2  reachable clause(s) covered by a deny-by-default gate",
        "PASS  LIVEVIEW-REACH-CLOSES"
      ],
      proves: "the routed fixture LiveView's write sits ONE HOP past @max_depth, so the sweep prints FALSE at the budget and TRUE at closure — and BOTH cells are asserted as fractions, numerator AND denominator, over a routed 1 and a population 2 that a bare integer could not distinguish"
    },
    %{
      name: "LIVEVIEW-DEPTH-NOT-CONSTANT",
      corpus: :full,
      argv: [],
      # MOVE THE WRITE ONE HOP, WITHOUT TOUCHING THE FIXTURE. write_corpus!/3 writes the
      # corpus UNMUTATED before any mutant runs, so a fixture edit is a function the
      # mutant never calls and passes vacuously. Charging the entry clause one hop less
      # is the same displacement seen from the lens side.
      # THE ANCHOR CARRIES ITS BINDING. The bare `bfs([{d, 0, …` spelling occurs THREE
      # times in this file — apply_mutation/2 refuses an ambiguous anchor rather than
      # mutating the first one it meets, which is the guard working.
      mut: {"{verbs, _found, _chain} = bfs([{d, 0" <> ", [label(d)]}], index, MapSet.new(), %{}, nil, [], max)",
            "{verbs, _found, _chain} = bfs([{d, -1, [label(d)]}], index, MapSet.new(), %{}, nil, [], max)"},
      exit: 0,
      expect: ["1 / 4  (25.0%)    1 / 5  (20.0%)   <- @max_depth, the census budget"],
      refute: ["0 / 4   (0.0%)    0 / 5   (0.0%)   <- @max_depth, the census budget"],
      proves: "the printed FRACTION at the budget moves from 0 / 1 to 1 / 1 when the write moves one hop — so it is a measurement of the tree and not a constant the block prints either way"
    },
    %{
      name: "LIVEVIEW-WRITE-FLAG-ARMED",
      corpus: :full,
      argv: [],
      # THE OTHER DIRECTION, AND THE ONE THAT WAS MEASURED VACUOUS. Forcing the write
      # flag false made every LiveView depth cell read 0 and the census STILL exited 0
      # with CENSUS OK — nothing in the selftest could see it. It can now.
      mut: {"{Map.has_key?(verbs, :write)" <> ", Map.get(verbs, :visited, [])}",
            "{false, Map.get(verbs, :visited, [])}"},
      exit: 0,
      expect: ["0 / 4   (0.0%)    0 / 5   (0.0%)   <- @max_depth, the census budget"],
      refute: ["1 / 4  (25.0%)    1 / 5  (20.0%)"],
      proves: "a write flag forced false empties every depth cell and the case REDS on the missing 1 / 4 — the exact mutation that used to survive at exit 0 with every arm printing PASS"
    },
    %{
      name: "LIVEVIEW-REACH-CLOSES-ARMED",
      corpus: :full,
      argv: [],
      # A CLASS THAT LEAVES THE TAXONOMY. The arm asserts a RELATION (every clause
      # disposed exactly once, residual included), never a class count, so an honest
      # reclassification moves two numbers and cannot red it — this can.
      # THE REPLACEMENT IS SPLIT TOO. Written whole it would CONTAIN the anchor, so the
      # anchor would occur twice — once at the line it targets and once inside this very
      # tuple — and apply_mutation/2 would refuse it as ambiguous.
      mut: {"MapSet.member?(comp_set, lv_key(d)) -> :unreachable_component" <> "_lifecycle",
            "MapSet.member?(comp_set, lv_key(d)) -> :unreachable_component" <> "_lifecycle" <> "_STRAY"},
      exit: 1,
      expect: ["FAIL  LIVEVIEW-REACH-CLOSES", "outside the declared taxonomy"],
      proves: "a REACH class that falls out of the declared taxonomy reds BY NAME instead of quietly shrinking a denominator — the arm that makes this block catchable at all"
    },
    # THE WAVE-43 FOLD, EXERCISED BY THE CORPUS RATHER THAN BY THE REAL TREE. The three
    # cases below are the substitution the folded class has to descend from: the fixture
    # plugin's three live specs meet a mount callsite inside a live_session, a callsite
    # outside every live_session, and a module name this lens cannot resolve — and each
    # shape is asserted as a FRACTION over the same population of 5, so a fold that
    # decided everything and a fold that decided nothing are both visible here.
    %{
      name: "LIVEVIEW-PLUGIN-MOUNT-FOLDS",
      corpus: :full,
      argv: [],
      mut: nil,
      exit: 0,
      expect: [
        "1 / 3 plugin_routes/1 callsite(s) sit INSIDE a live_session",
        "Keyed on {module, live_session}. 2 routed module(s) resolve to a",
        "reachable_unconditional            2 / 5",
        "RESIDUAL residual_no_derivable_chain   2 / 5",
        "sum                                5 == population 5"
      ],
      proves: "a plugin spec mounted INSIDE a live_session resolves the chain at its own callsite and lands DECIDED (reachable_unconditional 2 / 5), while the spec mounted at the sessionless callsite stays UNDECIDED — the residual is narrowed by derivation on this corpus and is NOT zero by construction. THE SECOND RESIDUAL CLAUSE IS NOT THE `?` SPEC'S DOING, and wave 45 corrected this sentence for saying so: the `?` spec (route /var-live) contributes no clause to ANY class, and the clause that sits in the residual belongs to PluginVarLive, put into route_mods by the COMPENSATING LITERAL ROUTE live(\"/loose-var\", PluginVarLive) in the fixture router. Deleting that route moves exactly that one clause (RESIDUAL 2 / 5 -> 1 / 5), which is what makes the compensation total and this fraction meaningful"
    },
    %{
      name: "LIVEVIEW-PLUGIN-MOUNT-NOT-CONSTANT",
      corpus: :full,
      argv: [],
      # KILL THE EMISSION, KEEP THE CLAUSE. The walk still matches the mount node and
      # still descends; it simply records nothing — which is EXACTLY the wave-42 shape
      # this slice repaired, reproduced on demand. If the decided class survived this,
      # it would be coming from somewhere other than the callsite.
      mut: {"do: [%{plugin_scope: kw_lit(opts, :scope)" <> " || :admin, session: s, hooks: h} | acc]",
            "do: acc"},
      exit: 0,
      expect: ["RESIDUAL residual_no_derivable_chain   3 / 5", "reachable_unconditional            1 / 5"],
      refute: ["RESIDUAL residual_no_derivable_chain   2 / 5"],
      proves: "with the mount callsite unrecorded the plugin LiveView falls straight back into the residual (2 / 5 -> 3 / 5) — so the DECIDED class above is produced by this clause and not by a module-name pattern or a sibling route"
    },
    %{
      name: "LIVEVIEW-PLUGIN-VAR-DECLINES",
      corpus: :full,
      argv: [],
      # LET THE UNNAMEABLE SPEC JOIN. The fixture plugin binds one route module to a name
      # inline_alias_bindings/1 retires, so the spec's module reads `?`; with the guard
      # neutered that phantom is credited a live_session and the routed-module count grows
      # by a module NOBODY CAN OPEN. The count is the observable, and it moves.
      mut: {"defp lvs_joinable?(%{method: @routed_live_method, module: mod}), do: mod != " <> "\"?\"",
            "defp lvs_joinable?(%{method: @routed_live_method, module: mod}), do: mod != " <> "\"!\""},
      exit: 0,
      expect: ["Keyed on {module, live_session}. 3 routed module(s) resolve to a"],
      refute: ["Keyed on {module, live_session}. 2 routed module(s) resolve to a"],
      proves: "the `?` decline is load-bearing: without it the fold credits a live_session to a spec whose module this lens cannot name, and the printed routed-module count goes 2 -> 3 on a corpus whose openable routed modules never changed"
    },
    # THE LADDER'S TOP RUNG, AND THE ONLY DISCRIMINATOR THAT EXISTS FOR IT (wave 45).
    # OVERLAP is 0 on today's tree, so `leg_a + leg_b` and Enum.count(MapSet.union(..))
    # BOTH print the same integer: an implementation that ADDED the legs would be green,
    # right, and wrong, until the first member reached by both a PROVEN register def and
    # a PROVEN roster def arrives. This case MANUFACTURES that member by injecting a
    # leg-B def into leg A, and then asserts the RELATION rather than the count — an
    # addition can never print `naive > UNION`, and an honest register edit can never
    # red this, because no bucket number appears in either list.
    %{
      name: "LADDER-UNION-NOT-SUM",
      corpus: :repo,
      argv: [],
      # THE ANCHOR IS SPLIT so this tuple does not match ITSELF — apply_mutation/2 refuses
      # an ambiguous anchor, and a mut literal that occurs twice is exactly that.
      mut:
        {"leg_a = members_reaching(population, index, " <>
           "receipt_functions(classified, :proven, [:live, :stale]))",
         "leg_a = members_reaching(population, index, MapSet.union(" <>
           "receipt_functions(classified, :proven, [:live, :stale]), " <>
           "MapSet.new([{\"BarkparkWeb.ScimGroupsController\", :delete}])))"},
      exit: 0,
      expect: ["naive > UNION — the addition would OVERCOUNT by"],
      refute: ["[naive == UNION"],
      proves: "PROVEN-BACKED is ONE Enum.count over ONE MapSet.union and not leg_a + leg_b: a def already carried by leg B is injected into leg A, so the legs now share member(s), the naive addition rises above the union and the union HOLDS. Replace that union with an addition and this case reds, because the addition can only ever print `naive == UNION`"
    },
    # THE POPULATION BASELINE STOPS BEING ADVISORY (PDS-D678, wave 47), AND THE CORPUS IS
    # THE REPO FOR THE SAME REASON THE ROSTER CASES USE IT: baseline_checks/2 is scoped by
    # register_scope/1, so over the synthetic tree the arm is not in the checks list at all
    # and a mutant there would run a check that returned [] before and [] after — the
    # unmutatability PDS-D541 named, wearing a new arm's name.
    #
    # IT ASSERTS ONLY THE COUNT IT INJECTED ITSELF. The mutation moves the BASELINE (a
    # literal in this file), so the injected `@rederived.unrouted + 1` is THIS CASE'S OWN
    # number and pinning it is safe. THE DIGIT ITSELF IS NOT WRITTEN HERE, and it used to
    # be: this comment read "`24`" while the baseline sat at 23, and the wave that moved
    # `unrouted` off 23 left that digit describing nothing. A prose figure beside a derived
    # one is the defect this whole file polices; it was carrying an instance of it. THE DERIVED SIDE IS THE TREE'S AND IS DELIBERATELY LEFT UNPINNED — the
    # expectation stops at the word `derived` — because pinning what follows it is the one
    # thing the banner forbids, and pinning it is what left the sibling arm below dead-red
    # for two waves. An honest lens correction moves `derived` and this case does not
    # notice, which is the point. THE ANCHOR IS DERIVED TOO (@drift_row_injected, beside
    # @rederived): a pinned anchor would not lie, but it would refuse with MUTATION ANCHOR
    # GONE the first time `unrouted` moved — loud rather than wrong, and still a red this
    # arm has no business printing.
    # The FAIL sentence carries the re-derivation command so the repair is one run.
    %{
      name: "D448-BASELINE-REFUSES",
      corpus: :repo,
      argv: [],
      mut: {"unrouted: " <> Integer.to_string(@rederived.unrouted),
            "unrouted: " <> Integer.to_string(@rederived.unrouted + 1)},
      exit: 1,
      expect: [
        "FAIL  D448-DRIFT-REFUSES",
        "1 population row(s) DRIFTED off the wave-47 baseline: unrouted baseline " <>
          "#{@rederived.unrouted + 1} derived #{@rederived.unrouted}",
        "RE-DERIVE, never re-type",
        @drift_row_injected
      ],
      proves: "a population row that no longer descends from the tree EXITS 1 by name instead of printing DRIFT at exit 0 forever — the four-wave-old advisory block, armed. The mutation perturbs the RECORDED side, which is the only side a selftest can move without touching api/lib"
    },
    %{
      name: "D448-REFUSAL-IS-THE-ARM",
      corpus: :repo,
      argv: [],
      # THE SAME PERTURBATION, WITH THE ENFORCEMENT REMOVED — and it takes BOTH mutations
      # to say that. Moving the baseline is what PRODUCES a DRIFT row; removing the arm is
      # what lets that row print at exit 0. DISARMING ALONE PERTURBS NOTHING: every row
      # reads `==`, no DRIFT is printed, and the run differs from an unmutated one only by
      # the missing PASS line — which is how this case spent two waves asserting a state it
      # never produced. The pair below is applied left to right by apply_mutation/2, each
      # half under the same exactly-once anchor refusal.
      #
      # NO NUMBER IS TYPED HERE AT ALL. Both the anchor and the asserted `baseline` come
      # from @rederived.unrouted + 1 — this case's OWN injected value — and the `derived`
      # side is left unasserted, so an honest re-derivation of any population moves all of
      # them together and can never red this case. That is the banner's rule, obeyed. The
      # row cannot read `==` with a baseline one off the derived value, so the prefix alone
      # witnesses the DRIFT without naming the tree's figure.
      mut: [
        {"unrouted: " <> Integer.to_string(@rederived.unrouted),
         "unrouted: " <> Integer.to_string(@rederived.unrouted + 1)},
        {"++ baseline_checks(drift_rows, " <> "classified)", "++ []"}
      ],
      exit: 0,
      expect: ["CENSUS OK", @drift_row_injected],
      refute: ["D448-DRIFT-REFUSES"],
      proves: "with the arm removed the census returns to its pre-wave-47 behaviour — a row whose baseline no longer descends from the tree PRINTS ITS DRIFT AND EXITS 0 ANYWAY — so the red the case above produces is produced by baseline_checks/2 and not by a neighbouring check the mutation happened to disturb. The two cases differ by exactly one mutation: the sibling moves the baseline and exits 1, this moves the same baseline AND drops the arm and exits 0"
    }
  ]

  defp selftest do
    p("PDS CENSUS SELFTEST — can this instrument be made to go RED?")
    p(String.duplicate("=", 78))
    p("  Mutates this file over a synthetic corpus (CWD injection) — and, for the arms")
    p("  the synthetic corpus scopes OUT, over the REPO corpus read-only — requiring each")
    p("  mutant to red on the arm it kills. Asserts exit codes, arm names and refusal")
    p("  prose — NEVER a bucket count, so an honest lens correction can never red it.")
    p("")

    src = File.read!(@self_source)
    # THE OS PID IS LOAD-BEARING (PDS-D542). System.unique_integer/1 is VM-LOCAL: eight
    # concurrent VMs joined onto one shared TMPDIR produced the IDENTICAL root FIVE times,
    # and File.rm_rf!(root) below then deletes a concurrent run's corpus mid-flight. The
    # dangerous shape is not the crash — at a small stagger it prints SELFTEST FAILED
    # naming FAIL KEY-DISCRIMINATES, a vacuous RED wearing a real arm's name, which reads
    # as a substantive regression in key-discrimination logic. mkdir_p! would repair only
    # the crash and leave that shape alive; the OS pid makes the root globally unique.
    root =
      Path.join(
        System.tmp_dir!(),
        "pds-census-selftest-#{System.pid()}-#{System.unique_integer([:positive])}"
      )
    # THE THIRD CORPUS IS THE REPO ITSELF, AND IT IS READ-ONLY. Nothing below writes to
    # it — the mutants are written into `root` and merely RUN with cwd here. It exists
    # because ROSTER-VERDICT-FRESH is scoped to the corpus its eight rows name, so the
    # synthetic tree scopes it OUT and a mutant there would prove nothing (PDS-D541).
    # THE FOURTH CORPUS IS THE THIRD ONE REPAIRED. `:full` carries the six pre-#9114 echo
    # receipts, `:repaired` carries the same six actions rendering the stored row: one
    # difference, six rows, and the classifier has to move all six or the pair fails.
    dirs = %{
      full: Path.join(root, "full"),
      tiny: Path.join(root, "tiny"),
      repaired: Path.join(root, "repaired"),
      repo: File.cwd!()
    }

    write_corpus!(dirs.full, @selftest_filler, :pre_9114)
    write_corpus!(dirs.tiny, 0)
    write_corpus!(dirs.repaired, @selftest_filler, :repaired)

    results = Enum.map(@selftest_cases, &run_selftest_case(&1, src, dirs, root))
    File.rm_rf!(root)

    Enum.each(results, fn r ->
      p("  #{if r.ok?, do: "PASS", else: "FAIL"}  #{String.pad_trailing(r.name, 32)} #{r.why}")
      unless r.ok?, do: p("        proves: #{r.proves}")
    end)

    p("")
    failed = Enum.reject(results, & &1.ok?)

    if failed == [] do
      p("SELFTEST OK — #{length(results)} cases, #{Enum.count(@selftest_cases, & &1.mut)} of them mutants that went red as required.")
      System.halt(0)
    else
      p("SELFTEST FAILED — #{length(failed)} case(s) did not behave as required. Read the FAIL lines.")
      System.halt(1)
    end
  end

  defp run_selftest_case(c, src, dirs, root) do
    base = %{name: c.name, proves: c.proves}

    with {:ok, mutated} <- apply_mutation(src, c.mut) do
      script = Path.join(root, "case-#{:erlang.phash2(c.name)}.exs")
      File.write!(script, mutated)
      dir = Map.fetch!(dirs, c.corpus)

      # NEVER PIPED: System.cmd hands back the child's own status, which is the whole
      # point — `cmd | tail` reports tail's status and once logged an exit-2 refusal as 0.
      {out, code} = System.cmd("elixir", [script | c.argv], cd: dir, stderr_to_stdout: true)

      judge_selftest_case(base, c, out, code, {script, dir})
    else
      {:error, why} -> Map.merge(base, %{ok?: false, why: why})
    end
  end

  # ------------------------------------------------------------- the keys floor
  #
  # WHY THIS IS FOUR CHECKS AND NOT ONE RELATION (PDS-D519). The shipped arm asserted
  # `length(routed) == length(emitted)`, which keys_run/1 makes TRUE BY CONSTRUCTION —
  # it maps over `emitted`. Forcing the emission to [] made `--keys` print zero lines
  # over the real 804-file corpus while `--selftest` still printed SELFTEST OK at RC 0.
  # A `tsv > 0` floor alone does not repair it either: a one-row drop passes, because
  # keys, emitted and tsv all agree at the reduced number. The four checks below are
  # ordered so the FAIL sentence names WHICH ONE fired, and the last one is the only
  # genuinely independent path — a SECOND invocation of the same binary over the same
  # corpus, deriving `emitted` through the census's own reporting instead of keys_run/1.
  defp judge_selftest_case(base, %{expect: {:keys, mode}} = c, out, code, ctx) do
    case {mode, keys_floor_verdict(out, code, c.exit, ctx)} do
      {:holds, :ok} ->
        Map.merge(base, %{
          ok?: true,
          why: "exit 0 · TSV == keys == emitted == the census's OWN derived emitted · every key distinct · floor non-vacuous"
        })

      {:holds, {:red, why}} ->
        Map.merge(base, %{ok?: false, why: why})

      {{:reds, frag}, {:red, why}} ->
        if String.contains?(why, frag) do
          Map.merge(base, %{ok?: true, why: "went RED as required — #{why}"})
        else
          Map.merge(base, %{
            ok?: false,
            why: "went red on the WRONG sub-check (#{why}) — expected one naming #{inspect(frag)}"
          })
        end

      {{:reds, frag}, :ok} ->
        Map.merge(base, %{
          ok?: false,
          why: "THE MUTANT PASSED THE KEYS FLOOR — nothing here would catch it; expected a red naming #{inspect(frag)}"
        })
    end
  end

  # `refute:` EXISTS BECAUSE A PRESENCE-ONLY ASSERTION CANNOT SEE AN OVER-NAMING (PDS
  # wave 40). A classifier that names SIX request echoes on a corpus carrying six is only
  # half-proven: the other half is that it names NONE on the repaired corpus, and no list
  # of expected substrings can state that. Absent from a case, it is [] and changes
  # nothing about how every case before this wave is judged.
  defp judge_selftest_case(base, c, out, code, _ctx) do
    missing = Enum.reject(c.expect, &String.contains?(out, &1))
    present = Enum.filter(Map.get(c, :refute, []), &String.contains?(out, &1))

    cond do
      code != c.exit ->
        Map.merge(base, %{ok?: false, why: "exit #{code}, expected #{c.exit}"})

      missing != [] ->
        Map.merge(base, %{
          ok?: false,
          why: "exit #{code} as required but never printed #{inspect(missing)}"
        })

      present != [] ->
        Map.merge(base, %{
          ok?: false,
          why: "exit #{code} as required but printed what it must NOT: #{inspect(present)}"
        })

      true ->
        Map.merge(base, %{ok?: true, why: "exit #{c.exit} · printed #{inspect(hd(c.expect))}"})
    end
  end

  defp keys_floor_verdict(out, code, want_exit, {script, dir}) do
    lines = String.split(out, "\n", trim: true)
    tsv = Enum.filter(lines, &String.contains?(&1, "\t"))
    n = length(tsv)
    distinct = length(Enum.uniq(tsv))

    summary =
      Enum.find_value(lines, fn l ->
        case Regex.run(~r/^keys (\d+) · emitted (\d+)/, l) do
          [_, k, e] -> {String.to_integer(k), String.to_integer(e)}
          _ -> nil
        end
      end)

    cond do
      code != want_exit ->
        {:red, "exit #{code}, expected #{want_exit}"}

      summary == nil ->
        {:red, "--keys printed no summary line to stderr"}

      n == 0 ->
        {:red,
         "ZERO-FLOOR: --keys printed 0 TSV line(s). The one-line-per-site relation is VACUOUS at zero — 0 == 0 == 0 certifies nothing, and the register reads its rows off this emission"}

      elem(summary, 0) != n or elem(summary, 1) != n ->
        {:red,
         "ONE-LINE-PER-SITE: TSV lines #{n} != keys #{elem(summary, 0)} / emitted #{elem(summary, 1)}"}

      distinct != n ->
        {:red,
         "KEY-DISCRIMINATES: the key does not DISCRIMINATE: #{n} site(s) collapsed to #{distinct} distinct key(s)"}

      true ->
        independent_rederivation(n, script, dir)
    end
  end

  # THE SECOND PATH. Runs the SAME (possibly mutated) script with `argv []` in the SAME
  # fixture and reads `emitted` off the ordinary census report — a figure keys_run/1 does
  # not produce and cannot influence. FAILS CLOSED: an unparsable figure is a red, never
  # a shrug, because "the re-derivation could not read a number" and "the numbers agree"
  # must never print the same verdict.
  defp independent_rederivation(n, script, dir) do
    {out, _code} = System.cmd("elixir", [script], cd: dir, stderr_to_stdout: true)

    case Regex.run(~r/EMITTED success claims\s+(\d+)/, out) do
      [_, e] ->
        e = String.to_integer(e)

        if e == n do
          :ok
        else
          {:red,
           "INDEPENDENT-REDERIVATION: --keys printed #{n} TSV line(s) but the census run over the SAME corpus independently derived emitted #{e}"}
        end

      _ ->
        {:red,
         "INDEPENDENT-REDERIVATION: the census run over the same corpus printed no parsable `EMITTED success claims` figure — failing CLOSED rather than passing on an unread number"}
    end
  end

  # AN ANCHOR THAT DOES NOT OCCUR EXACTLY ONCE IS A DEAD CASE, NOT A PASS. A refactor that
  # moves the mutated line must break the selftest loudly rather than leave it running the
  # unmutated script and reporting green.
  defp apply_mutation(src, nil), do: {:ok, src}

  # A LIST APPLIES EVERY PAIR, EACH UNDER THE SAME EXACTLY-ONCE REFUSAL BELOW. One case
  # needs a TWO-PART perturbation — move a baseline AND disarm the check that reads it —
  # and a single pair can only ever do half of that, which is precisely how
  # D448-REFUSAL-IS-THE-ARM came to assert a state it never produced. Applied left to
  # right; the first anchor that is gone or ambiguous fails the WHOLE mutation, so a
  # half-applied mutant is never run and never reported.
  defp apply_mutation(src, muts) when is_list(muts) do
    Enum.reduce_while(muts, {:ok, src}, fn m, {:ok, acc} ->
      case apply_mutation(acc, m) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp apply_mutation(src, {from, to}) do
    case length(:binary.matches(src, from)) do
      1 -> {:ok, String.replace(src, from, to)}
      0 -> {:error, "MUTATION ANCHOR GONE — #{inspect(String.slice(from, 0, 48))} no longer occurs"}
      n -> {:error, "MUTATION ANCHOR AMBIGUOUS — #{inspect(String.slice(from, 0, 48))} occurs #{n} times"}
    end
  end

  # THE SYNTHETIC CORPUS. Small on purpose: it carries one emitter, one consumer, one
  # phantom, one defdelegate facade that reaches a write verb, and enough filler to clear
  # the corpus floor. The receipt text is assembled from fragments so that no literal
  # success pair appears in THIS file's own source.
  defp write_corpus!(dir, filler), do: write_corpus!(dir, filler, :pre_9114)

  defp write_corpus!(dir, filler, echo) do
    w = fn rel, body ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end

    w.("api/lib/barkpark/tasks.ex", """
    defmodule Barkpark.Tasks do
      @moduledoc "the defdelegate facade that makes naive write detectors lie"
      defdelegate close(id, worker, epoch), to: Barkpark.Tasks.Close
      defdelegate reopen(id), to: Barkpark.Tasks.Close
    end
    """)

    w.("api/lib/barkpark/tasks/close.ex", """
    defmodule Barkpark.Tasks.Close do
      # a phantom: the words #{@pair_atom} in prose, which the AST does not carry as a pair
      def close(id, worker, epoch) do
        {n, _} = Repo.update_all(id, set: [worker: worker, epoch: epoch])
        receipt(id, n)
      end

      def reopen(id), do: Repo.update(id)

      # TWO EMITTED SITES IN ONE CLAUSE (PDS-D519). Identical {path, module.name/arity,
      # head_hash} — one clause, one head — and DIFFERENT expr_fp, because the two `%{}`
      # nodes differ. Without this the fixture holds one emitted site, every key is
      # trivially distinct, and KEY-DISCRIMINATES cannot fail on a fixture that never
      # asks the key to discriminate anything.
      def receipt(id, n) do
        if n > 0 do
          %{#{@pair_atom}, id: id, moved: n}
        else
          %{#{@pair_atom}, id: id}
        end
      end

      def consume(resp) do
        %{#{@pair_atom}} = resp
        :ok
      end
    end
    """)

    # THE FIXTURE ROUTER (PDS wave 38). Two write routes onto ONE {module, action} pair,
    # so the quad key is asked to DISCRIMINATE on every selftest run; a route-generating
    # macro this lens resolves (plugin_routes) and one it cannot (live_dashboard), so
    # LENS-CAN-MISS has both a resolved site and a blind site to name. Both routes point
    # at Barkpark.Filler.M1, a module that exists ONLY here — in the real tree the two
    # committed :selftest_fixture disposition rows name a module the corpus does not
    # carry and are OUT OF SCOPE, never a red.
    w.("api/lib/barkpark_web/router.ex", """
    defmodule BarkparkWeb.Router do
      live_dashboard("/dashboard", metrics: BarkparkWeb.Telemetry)

      # THE LIVE ROUTE (PDS wave 42). Without a `live(...)` line here `route_mods` is
      # EMPTY and the ROUTED/COMPONENT split of the LiveView population is degenerate
      # BY CONSTRUCTION — every clause lands COMPONENT, every REACH class but one reads
      # zero, and the three columns below it certify a partition nobody exercised. It is
      # wrapped in a live_session with an on_mount chain so the REACH lens has a chain
      # to read; the committed :selftest_fixture disposition row is what keeps
      # ROUTED-POPULATION-COMPLETE green on the arrival this route IS.
      scope "/studio", Barkpark.Filler do
        live_session :selftest_session,
          on_mount: [{Barkpark.Filler.FixtureHook, :default}] do
          live("/fixture", FixtureLive)
        end
      end

      # THE PLUGIN-MOUNT HALF (PDS wave 43). BOTH SHAPES, ON PURPOSE: one
      # plugin_routes/1 callsite INSIDE a live_session (its specs resolve a chain and
      # land in a DECIDED class) and one OUTSIDE every live_session (its specs resolve
      # nothing and stay in the RESIDUAL). Without the second the residual would be zero
      # on this corpus by construction and the selftest could not tell a fold from a
      # rubber stamp. The third route is LITERAL and sessionless: it routes the module
      # the plugin's own `?` spec fails to name, so that module is IN route_mods and its
      # clause can be watched staying undecided while the `?` spec declines to join.
      scope "/plugins", Barkpark.Filler do
        live_session :selftest_plugin_session,
          on_mount: [{Barkpark.Filler.FixtureHook, :default}] do
          plugin_routes(scope: :ops)
        end

        plugin_routes(scope: :api)
        live("/loose-var", PluginVarLive)
      end

      scope "/v1" do
        plugin_routes(scope: :admin)
        post("/selftest-fixture-close", Barkpark.Filler.M1, :noop)
        post("/selftest-departure-anchor", Barkpark.Filler.M1, :noop)
        delete("/echo/schema/:name", Barkpark.Filler.EchoController, :delete_schema)
        delete("/echo/document/:id", Barkpark.Filler.EchoController, :delete_document)
        delete("/echo/asset/:id", Barkpark.Filler.EchoController, :delete_asset)
        delete("/echo/share-token/:token_id", Barkpark.Filler.EchoController, :revoke_share_token)
        delete("/echo/share-link/:id", Barkpark.Filler.EchoController, :revoke_share_link)
        delete("/echo/webhook/:id", Barkpark.Filler.EchoController, :delete_webhook)
      end
    end
    """)

    # THE SIX PRE-#9114 RECEIPT BODIES, AS A FIXTURE, AND WHY THEY ARE NOT READ FROM GIT.
    # #9114 found six DELETE/revoke receipts answering with the REQUEST rather than the
    # STORE. Reading them back with `git show` would be the obvious mutant and is the
    # wrong one: this census invokes git NOWHERE and is normally run over
    # `git archive HEAD api/lib scripts`, so a git dependency would need a gate of its
    # own, and an arm proven only where it is scoped out is proven nowhere. So the six
    # bodies are CARRIED here verbatim in shape, and the SAME six actions are written a
    # second time REPAIRED into the `:repaired` corpus. The classifier must name all six
    # on one and NONE on the other — presence proves it can see the species, `refute:`
    # proves it is not simply shouting "echo" at every delete verb it meets.
    w.("api/lib/barkpark/filler/echo_store.ex", """
    defmodule Barkpark.Filler.EchoStore do
      def delete(id), do: {:ok, %{id: id, name: id, deleted: true}}
      def revoke(id), do: {:ok, %{id: id, revoked: true}}
    end
    """)

    w.("api/lib/barkpark/filler/echo_controller.ex", echo_controller_source(echo))

    # THE LIVEVIEW FIXTURE (PDS wave 42), IN THREE COUPLED FILES. The routed LiveView's
    # write sits EXACTLY ONE HOP BEYOND the census budget — handle_event is depth 0 and
    # hop7/2 is depth 7, one past @max_depth — so the depth sweep prints a FALSE cell and a
    # TRUE one past it, and both are asserted as FRACTIONS. A bare numerator could not
    # tell the routed lens from the repo-wide one: they are identical at every depth by
    # construction, here and on the real tree.
    w.("api/lib/barkpark/filler/fixture_live.ex", """
    defmodule Barkpark.Filler.FixtureLive do
      use Phoenix.LiveView

      def handle_event("fixture-save", params, socket), do: hop1(params, socket)

      defp hop1(p, s), do: hop2(p, s)
      defp hop2(p, s), do: hop3(p, s)
      defp hop3(p, s), do: hop4(p, s)
      defp hop4(p, s), do: hop5(p, s)
      defp hop5(p, s), do: hop6(p, s)
      defp hop6(p, s), do: hop7(p, s)
      defp hop7(p, _s), do: Barkpark.Repo.update(p)
    end
    """)

    # THE COMPONENT HALF. `use Phoenix.LiveComponent` at the module's OWN top level, with
    # a handle_event/3 of its own — so the component THEOREM and the route PROXY each
    # have a member to find, and their disagreement is measured rather than assumed.
    w.("api/lib/barkpark/filler/fixture_component.ex", """
    defmodule Barkpark.Filler.FixtureComponent do
      use Phoenix.LiveComponent

      def handle_event("fixture-comp", _params, socket), do: {:noreply, socket}
    end
    """)

    # THE HOOK HALF. Attached UNCONDITIONALLY and denying on its DEFAULT path, so the
    # REACH, DENIES and ATTACH-CERTAINTY columns each read a non-zero numerator on this
    # corpus. A gate that halted only under literal heads would exercise the trap key
    # and never the honest one.
    w.("api/lib/barkpark/filler/fixture_hook.ex", """
    defmodule Barkpark.Filler.FixtureHook do
      import Phoenix.LiveView, only: [attach_hook: 4]

      def on_mount(:default, _params, _session, socket) do
        {:cont, attach_hook(socket, :fixture_gate, :handle_event, &gate/3)}
      end

      defp gate("fixture-read", _params, socket), do: {:cont, socket}
      defp gate(_event, _params, socket), do: {:halt, socket}
    end
    """)

    # THE PLUGIN HALF (PDS wave 43) — THE FIRST FIXTURE FILE UNDER @plugin_dir. Until
    # this file existed plugin_route_specs/1 returned [] on the synthetic corpus, so the
    # wave-43 mount clause emitted NOTHING under --selftest and the fold was structurally
    # unexercised: a class that never descends from a substitution is not proven by the
    # green run that carried it. Three live specs, one per shape the join must tell apart:
    #
    #   auth: :ops     mounted at a callsite INSIDE live_session :selftest_plugin_session
    #                  -> a DECIDED class, through the spec's own auth:.
    #   auth: :api     mounted at a callsite OUTSIDE every live_session
    #                  -> RESIDUAL, which is what keeps the residual falsifiable here.
    #   auth: :ops     spelled with a name inline_alias_bindings/1 RETIRES (bound at top
    #                  level AND rebound inside a fn, so bind_counts/1 reads 2) -> the
    #                  module resolves to `?` and the spec DECLINES the join rather than
    #                  crediting live_session :selftest_plugin_session to a module nobody
    #                  can open. The module it would have named is routed LITERALLY and
    #                  sessionlessly in the fixture router, so the decline is observable
    #                  as that module staying in the residual.
    w.("api/lib/barkpark/plugins/filler_plugin.ex", """
    defmodule Barkpark.Plugins.FillerPlugin do
      def register_routes(_ctx) do
        ops_mod = Barkpark.Filler.PluginOpsLive
        var_mod = Barkpark.Filler.PluginVarLive
        _rebound = Enum.map([], fn m -> var_mod = m end)

        [
          {:live, "/ops-live", ops_mod, :index, auth: :ops},
          {:live, "/api-live", Barkpark.Filler.PluginLooseLive, :index, auth: :api},
          {:live, "/var-live", var_mod, :index, auth: :ops}
        ]
      end
    end
    """)

    Enum.each(["PluginOpsLive", "PluginLooseLive", "PluginVarLive"], fn m ->
      w.("api/lib/barkpark/filler/#{Macro.underscore(m)}.ex", """
      defmodule Barkpark.Filler.#{m} do
        use Phoenix.LiveView

        def handle_event("#{Macro.underscore(m)}-save", _params, socket), do: {:noreply, socket}
      end
      """)
    end)

    w.("api/lib/barkpark/repo.ex", """
    defmodule Barkpark.Repo do
      def update_all(q, opts), do: {0, [q | opts]}
      def update(q), do: {:ok, q}
    end
    """)

    Enum.each(1..filler//1, fn i ->
      w.("api/lib/barkpark/filler/m#{i}.ex", """
      defmodule Barkpark.Filler.M#{i} do
        def noop(x), do: x
      end
      """)
    end)
  end

  # THE RECEIPT DESCRIBES THE REQUEST: every emitted value is a name bound in the action's
  # own HEAD, and the write's `{:ok, _}` payload is thrown away. A person deleting id X is
  # told "deleted X" whether or not row X was ever there.
  defp echo_controller_source(:pre_9114) do
    """
    defmodule Barkpark.Filler.EchoController do
      def delete_schema(conn, %{"name" => name}) do
        {:ok, _} = Barkpark.Filler.EchoStore.delete(name)
        json(conn, %{deleted: name})
      end

      def delete_document(conn, %{"id" => doc_id}) do
        {:ok, _} = Barkpark.Filler.EchoStore.delete(doc_id)
        json(conn, %{deleted: doc_id})
      end

      def delete_asset(conn, %{"id" => id}) do
        {:ok, _} = Barkpark.Filler.EchoStore.delete(id)
        json(conn, %{deleted: id})
      end

      def revoke_share_token(conn, %{"token_id" => token_id}) do
        {:ok, _} = Barkpark.Filler.EchoStore.revoke(token_id)
        json(conn, %{revoked: true, token_id: token_id})
      end

      def revoke_share_link(conn, %{"id" => id}) do
        {:ok, _} = Barkpark.Filler.EchoStore.revoke(id)
        json(conn, %{revoked: true, id: id})
      end

      def delete_webhook(conn, %{"id" => id}) do
        {:ok, _} = Barkpark.Filler.EchoStore.delete(id)
        json(conn, %{deleted: id})
      end
    end
    """
  end

  # THE REPAIRED SHAPE #9114 SHIPPED: the same six actions, same six routes, same six
  # verbs — the receipt now renders the row the write RETURNED. If the classifier reads
  # `delete` as an echo by name rather than by derivation, this corpus is where it says so.
  defp echo_controller_source(:repaired) do
    """
    defmodule Barkpark.Filler.EchoController do
      def delete_schema(conn, %{"name" => name}) do
        {:ok, row} = Barkpark.Filler.EchoStore.delete(name)
        json(conn, %{deleted: row.name})
      end

      def delete_document(conn, %{"id" => doc_id}) do
        {:ok, row} = Barkpark.Filler.EchoStore.delete(doc_id)
        json(conn, %{deleted: row.id})
      end

      def delete_asset(conn, %{"id" => id}) do
        {:ok, row} = Barkpark.Filler.EchoStore.delete(id)
        json(conn, %{deleted: row.id})
      end

      def revoke_share_token(conn, %{"token_id" => token_id}) do
        {:ok, row} = Barkpark.Filler.EchoStore.revoke(token_id)
        json(conn, %{revoked: row.revoked, token_id: row.id})
      end

      def revoke_share_link(conn, %{"id" => id}) do
        {:ok, row} = Barkpark.Filler.EchoStore.revoke(id)
        json(conn, %{revoked: row.revoked, id: row.id})
      end

      def delete_webhook(conn, %{"id" => id}) do
        {:ok, row} = Barkpark.Filler.EchoStore.delete(id)
        json(conn, %{deleted: row.id})
      end
    end
    """
  end

  # ---------------------------------------------------------------- integrity

  defp integrity(files, textual, ast_sites, phantoms, consumers, emitted, classified, delegate, ms, parsed, falsifiers, routed) do
    classified_n = Enum.count(classified, fn s -> elem(s.shape, 0) != "UNCLASSIFIED" end)
    unclassified_n = Enum.count(classified, fn s -> elem(s.shape, 0) == "UNCLASSIFIED" end)

    # THE EIGHT POPULATION ROWS, DERIVED ONCE AND READ TWICE — by the arm that refuses a
    # drift and by the block that prints them. Two lists would be two lenses wearing one
    # name, which is the defect this file exists to refuse.
    drift_rows = [
      {"textual", textual, :textual},
      {"ast-literal", length(ast_sites), :ast},
      {"phantom", length(phantoms), :phantom},
      {"consumer", length(consumers), :consumer},
      {"emitted", length(emitted), :emitted},
      {"write-routed", Enum.count(classified, & &1.write?), :write},
      {"read-routed", Enum.count(classified, &(not &1.write? and &1.read?)), :read},
      {"unrouted", Enum.count(classified, &(not &1.write? and not &1.read?)), :unrouted}
    ]

    # EVERY ARM RENDERS ITS OWN FAIL SENTENCE. One `why` for both branches is how a RED
    # line prints a true-reading sentence — the shipped form printed `FAIL CORPUS-INTACT 3
    # files >= 600`, which is a lie wearing the word FAIL. DELEGATE-REACHES-WRITE already
    # carried the false-branch shape; it is now the rule, not the exception. The relation
    # in the PASS prose is the one the arm asserts; the FAIL prose says what happened.
    checks = [
      {"CORPUS-INTACT", length(files) >= @corpus_floor,
       if length(files) >= @corpus_floor do
         "#{length(files)} files >= #{@corpus_floor}"
       else
         "#{length(files)} files is BELOW the #{@corpus_floor} floor — the corpus is truncated and every zero below it is unearned (normally unreachable: guard_corpus!/1 exits 2 on this same condition first)"
       end},
      {"LENS-LOSES-NOTHING", textual == length(ast_sites) + length(phantoms),
       if textual == length(ast_sites) + length(phantoms) do
         "textual #{textual} == ast #{length(ast_sites)} + phantom #{length(phantoms)}"
       else
         "textual #{textual} != ast #{length(ast_sites)} + phantom #{length(phantoms)} — the lens LOSES #{textual - length(ast_sites) - length(phantoms)} occurrence(s) it can neither parse nor explain"
       end},
      {"EMITTERS-PARTITION", length(ast_sites) == length(consumers) + length(emitted),
       if length(ast_sites) == length(consumers) + length(emitted) do
         "ast #{length(ast_sites)} == consumer #{length(consumers)} + emitted #{length(emitted)}"
       else
         "ast #{length(ast_sites)} != consumer #{length(consumers)} + emitted #{length(emitted)} — the emitter/consumer split drops #{length(ast_sites) - length(consumers) - length(emitted)} site(s); the emitted population is NOT the AST population"
       end},
      {"CLASSIFICATION-TOTAL", classified_n + unclassified_n == length(emitted),
       if classified_n + unclassified_n == length(emitted) do
         "classified #{classified_n} + unclassified #{unclassified_n} == emitted #{length(emitted)}"
       else
         "classified #{classified_n} + unclassified #{unclassified_n} != emitted #{length(emitted)} — #{length(emitted) - classified_n - unclassified_n} emitted site(s) fell out of the taxonomy entirely; every shape count below is over the wrong denominator"
       end},
      {"DELEGATE-REACHES-WRITE", delegate.close_write?,
       # On FAIL close_depth is nil, and "at depth " with nothing after it reads
       # like a truncated line rather than a finding — say what actually happened.
       if delegate.close_write? do
         "Barkpark.Tasks.close (defdelegate, #{delegate.delegates} on the facade) reaches a write verb at depth #{delegate.close_depth}"
       else
         "Barkpark.Tasks.close (defdelegate, #{delegate.delegates} on the facade) reaches NO write verb within the route budget — the facade probe is blind"
       end}
    ] ++
        routed_checks(routed) ++
        register_checks(classified, parsed) ++
        roster_freshness_checks(classified, parsed) ++
        falsifier_check(falsifiers) ++ baseline_checks(drift_rows, classified)

    p("INTEGRITY (these can go RED — the population numbers cannot; they are not a gate)")
    p(String.duplicate("-", 78))

    Enum.each(checks, fn {name, ok?, why} ->
      p("  #{if ok?, do: "PASS", else: "FAIL"}  #{String.pad_trailing(name, 24)} #{why}")
    end)

    p("")
    p("DRIFT vs THE WAVE-47 RE-DERIVED BASELINE (ARMED — a DRIFT line here exits 1)")
    p(String.duplicate("-", 78))
    p("  lens: build-free AST, substring counts (no regex engine), route depth #{@max_depth},")
    p("  `transaction` NOT a write verb · engine printed above · re-derive with")
    p("  `elixir scripts/pds-elixir-receipt-census.exs` from the repo root and amend")
    p("  @rederived WITH the lens and the engine in the same commit (PDS-D448a, PDS-D678).")
    p("  #{length(rederived_rows())} row(s) re-derived at wave 47, #{map_size(@rederived) - length(rederived_rows())} inherited from PDS-D448's wave-33 figures.")
    p("")
    Enum.each(drift_rows, fn {label, got, key} -> drift(label, got, key) end)
    p("")
    # STILL EXACTLY ONE LINE, AND IT SAYS SO. PDS-D605's fixture recipe reads this census
    # as "byte-identical except the volatile line", and it named that line by its old
    # `wall clock` label — which this run no longer prints. The line names ITSELF volatile
    # so the recipe can be re-derived from the output instead of transcribed from D605.
    #
    # THE `--selftest` FLOOR RIDES THIS SAME LINE ON PURPOSE. It is 9 x `ms`, so it is
    # volatile too — and a SECOND volatile line would silently invalidate D605's
    # "byte-identical except the volatile line" recipe. Deriving it here instead of
    # hand-typing it into @blind_spot is the substance of PDS-D633; keeping it on this
    # line is what stops that fix from breaking a neighbouring one.
    p("user cpu  #{ms} ms  (THE ONE VOLATILE LINE — build-free: no mix project, no compile, no app boot; BEAM-internal, this process only, see `blind spot` above · DERIVED: 9 x #{ms} = #{9 * ms} ms is the FLOOR on the child-BEAM cycles an outer meter around `--selftest` cannot see)")

    if Enum.all?(checks, &elem(&1, 1)) do
      p("CENSUS OK")
      System.halt(0)
    else
      p("CENSUS FAILED — an integrity check went red. Read the FAIL line above.")
      System.halt(1)
    end
  end

  # ----------------------------------------------------------- basis falsifiers
  #
  # THE VOCABULARY IS ONLY WORTH ANYTHING IF A SCRIPT CAN REFUSE A TOKEN (PDS-D525). Each
  # value in @basis_vocab names a falsifier; this reads the committed test tree and fires
  # the ones it can DECIDE. It is TIERED AS MEASURED, not as hoped:
  #
  #   REDS          end_to_end (and end_to_end_unmutated, the same predicate minus the
  #                 mutation) · stub_mapping_only, THE "DOES read Repo" HALF ONLY ·
  #                 context_differential_only · two_hop_composed (PDS wave 39 — promoted
  #                 WITH the widened @repo_tokens probe, mutation-proven, and the tier is
  #                 read from @basis_vocab rather than hardcoded, which is what makes the
  #                 promotion real) · basis_stale (a direct --keys join, built FIRST
  #                 because that wave's own slices re-key rows) · no_observer, the
  #                 MODULE-SUBSTRING half only, which needs no test-tree index.
  #                 THE PRINTED COUNT IS THE **ARMED** COUNT, NOT THIS LIST'S LENGTH:
  #                 basis_stale has no predicate and no_observer no top-level rows, so the
  #                 run prints what can actually refuse (armed_redding_values/0).
  #   ADVISORY      everything else, printed as a counted CONTRADICTION line at exit 0 —
  #                 the DRIFT pattern this census already uses.
  #
  # A CITED PATH THAT DOES NOT EXIST REDS. It is never silently skipped: a citation to a
  # file nobody can open is the paperwork this ledger exists to refuse.
  #
  # THE PREDICATE THE WISH ASKED FOR IS A FALSE FALSIFIER AND IS NOT BUILT. "The cited
  # test references the site's MODULE" refuses ALL of this wave's committed PROVEN
  # differentials, because pds_group_c_receipt_differential_test.exs contains the string
  # `Controller` ZERO times — conn-driven tests name a URL, not a module — and it GREENS a
  # cross-wired citation. Route linkage replaces it and is ADVISORY, never redding:
  # PluginSettings/Secret route literals are all-dynamic (the URL lives in the enclosing
  # `scope`, and reading the literal alone manufactured 3 FALSE contradictions on genuine
  # PROVEN rows) and `GithubWebhookController` appears ZERO times in router.ex because the
  # routes are macro-generated, so linkage is UNCHECKABLE for all 14 webhook rows.
  #
  # `shape_assertion_only`'s falsifier is UNDECIDABLE as written and is implementable only
  # as a denylist of weak predicates (is_list/is_map/is_binary/bare truthiness). It is
  # advisory, and @basis_vocab says so in the falsifier text rather than shipping an arm
  # whose name promises more than its code delivers.
  #
  # HELPER RESOLUTION IS MANDATORY, AND THE HELPER-NAME REGEX IS [\w!?]+ (both cost the
  # prototype an iteration). The decisive `Repo.` / `build_conn` token routinely lives in
  # a helper — `stored/1`, `deliver/3`, `stub_intake/1`, `assert_receipt_is_stored!/2` —
  # never in the cited block; and `\w+` truncates `assert_receipt_is_stored!` at the `!`
  # and FALSELY REFUSES four genuine rows.
  # THE PROBE WAS THE SUBSTRING `Repo.`, AND ITS LIMIT WAS MEASURED. A test that reads
  # Postgres through a CONTEXT MODULE carries no such token — inbound_events_test.exs's
  # `link_state/2` goes through `Content.get_document/4` and `detached_conflicts/1` through
  # `Conflicts.list/1`. That is why `two_hop_composed` was ADVISORY, and on the bare probe
  # promoting it would have redded at 3 refusals, ALL THREE FALSE.
  #
  # SO THE PROBE IS NOW AN ENUMERATED ALLOWLIST OF NAMED PERSISTENCE-READING FUNCTIONS,
  # AND A SHAPE REGEX IS FORBIDDEN (PDS wave 39). Widening by SHAPE — "any module-qualified
  # `get`/`list`" — is the obvious edit and it is measured WRONG: that shape admits
  # `Keyword.get(`, which manufactures FALSE refusals against `stub_mapping_only`, whose
  # falsifier is INVERTED (a store read REFUTES the basis, so every token added to this
  # list is a new way to ACCUSE a stub row). The list is therefore NAMES, one per real
  # persistence-reading context function, each added only with its measured effect on
  # EVERY dispatched basis.
  #
  # THE ZERO-COLLATERAL RESULT IS A CITATION ACCIDENT, NOT A PROPERTY OF THE TOKENS.
  # `Content.get_document(` / `Conflicts.list(` occur in 71 test files under api/test;
  # the widening is harmless today only because all 6 top-level `stub_mapping_only` rows
  # cite ONE stub-only file (github_webhook_controller_test.exs, `Repo.` count 0, and
  # neither widened token present). Re-cite any of them at one of the other 71 files and
  # the widening starts manufacturing refusals. @stub_citation_allowlist below is the
  # ARRIVAL TRIPWIRE for exactly that — it reds on the arrival, never on a count.
  @test_root "api/test"
  @conn_tokens ["build_conn", "json_response", "conn |>", "|> post(", "|> get(",
                "|> put(", "|> delete(", "%{conn:", "conn: conn", "authed("]
  @repo_tokens ["Repo.", "Content.get_document(", "Conflicts.list("]

  # THE FILES THE INVERTED-FALSIFIER ROWS ARE MEASURED SAFE AT. Not a count of rows, not a
  # count of files: the SET of paths `stub_mapping_only` rows cite today. A row that
  # arrives citing anything else has left the measured ground and REDS, because the
  # zero-collateral claim above was measured over this set and nothing wider.
  @stub_citation_allowlist ["api/test/barkpark_web/controllers/github_webhook_controller_test.exs"]

  # THE BASES check_row_basis/2 ACTUALLY DISPATCHES THROUGH THE CITATION ARM. Held as ONE
  # list because `armed_redding_values/0` reads it: a hand-copy would let the printed
  # "N redding value(s)" drift from the code that does the refusing, which is the exact
  # defect this wave is fixing one line down.
  @cited_bases [:end_to_end, :end_to_end_unmutated, :stub_mapping_only,
                :context_differential_only, :side_effect_existence_only, :two_hop_composed]

  defp basis_falsifiers(classified) do
    if File.dir?(@test_root) do
      cache = %{}

      {findings, _cache} =
        classified
        |> resolve_register()
        |> Enum.reduce({[], cache}, fn {r, status, _site}, {acc, c} ->
          case status do
            :live -> {f, c} = check_row_basis(r, c)
              {acc ++ f, c}

            _ ->
              {acc, c}
          end
        end)

      {:ran, findings}
    else
      :no_test_tree
    end
  end

  defp check_row_basis(r, cache) do
    ev = Map.get(r, :evidence, "")
    tier_of_basis = elem(Map.get(@basis_vocab, r.basis, {"?", "?", :advisory}), 2)

    cond do
      r.basis == :no_observer ->
        {no_observer_findings(r), cache}

      r.basis in @cited_bases ->
        cited_findings(r, ev, tier_of_basis, cache)

      true ->
        {[], cache}
    end
  end

  defp cited_findings(r, "", tier, cache),
    do: {[finding(r, tier, "carries no citation, and its falsifier needs one")], cache}

  defp cited_findings(r, ev, tier, cache) do
    case String.split(ev, ":") do
      [path, line] ->
        if File.exists?(path) do
          {text, cache} = cited_text(path, String.to_integer(line), cache)
          {judge_citation(r, ev, tier, text), cache}
        else
          # ALWAYS A RED, whatever the basis's tier: an unopenable citation is not a weak
          # judgment, it is no judgment at all.
          {[finding(r, :reds, "cites #{ev}, and that PATH DOES NOT EXIST")], cache}
        end

      _ ->
        {[finding(r, :reds, "cites #{inspect(ev)}, which is not a `path:line`")], cache}
    end
  end

  defp judge_citation(r, ev, tier, text) do
    conn? = Enum.any?(@conn_tokens, &String.contains?(text, &1))
    repo? = Enum.any?(@repo_tokens, &String.contains?(text, &1))

    case r.basis do
      b when b in [:end_to_end, :end_to_end_unmutated] ->
        cond do
          not conn? -> [finding(r, tier, "#{ev} drives no route (no conn token in the cited block or its helpers)")]
          not repo? -> [finding(r, tier, "#{ev} never reads the stored row back (no `Repo.` in the cited block or its helpers)")]
          true -> []
        end

      :stub_mapping_only ->
        # ONLY THE REPO HALF REDS. The seam half ("has no injection seam") is advisory:
        # a seam can be a put_env, a Mox, a passed fun or a config key, and a denylist of
        # spellings would refuse honest rows.
        #
        # THE ARRIVAL TRIPWIRE FIRST. This falsifier is INVERTED — a store read REFUTES
        # the basis — so it is the one arm @repo_tokens can hurt, and its safety was
        # measured only over @stub_citation_allowlist. A citation that arrives from
        # anywhere else REDS rather than silently spending an unmeasured probe.
        cited_file = ev |> String.split(":") |> List.first()

        cond do
          cited_file not in @stub_citation_allowlist ->
            [finding(r, :reds, "cites #{ev}, OUTSIDE the measured-safe citation set for `stub_mapping_only` (#{Enum.join(@stub_citation_allowlist, ", ")}). This falsifier is INVERTED — a store read refutes it — and @repo_tokens' zero-collateral was measured only over that set. RE-MEASURE the widened probe against this file, then widen the allowlist.")]

          repo? ->
            [finding(r, tier, "#{ev} DOES read Repo — `stub_mapping_only` understates what the suite proves")]

          true ->
            []
        end

      :context_differential_only ->
        if conn?,
          do: [finding(r, tier, "#{ev} BUILDS A CONN — the controller->wire hop is covered, so this is not context-differential-only")],
          else: []

      :side_effect_existence_only ->
        if not repo?,
          do: [finding(r, :advisory, "#{ev} reads no Repo at all, so it cannot even assert existence")],
          else: []

      # THE TIER IS READ FROM THE VOCABULARY, NEVER HARDCODED HERE. A hardcoded
      # `:advisory` made the @basis_vocab tier column DECORATIVE for this value: flipping
      # it to :reds printed a promotion and passed a planted defect through at rc=0. The
      # tier flip and this line are ONE change; neither is a promotion on its own.
      :two_hop_composed ->
        if not repo?,
          do: [finding(r, tier, "#{ev} reads no persisted state — no #{Enum.map_join(@repo_tokens, " / ", &"`#{&1}`")} in the cited block or its helpers, so the second hop is not visible")],
          else: []

      _ ->
        []
    end
  end

  # THE MODULE HALF ONLY. `no_observer` claims NOTHING in the test tree names this site;
  # one substring hit refutes it, and that needs no index and no route.
  defp no_observer_findings(r) do
    mod = r.key |> elem(1) |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

    hit =
      Path.wildcard(@test_root <> "/**/*.exs")
      |> Enum.find(&String.contains?(File.read!(&1), mod))

    if hit,
      do: [finding(r, :reds, "`no_observer` is refuted — #{mod} is named in #{hit}")],
      else: []
  end

  defp finding(r, tier, why), do: %{key: r.key, basis: r.basis, tier: tier, why: why}

  # THE CITED BLOCK PLUS ITS HELPERS, ONE LEVEL DEEP. The block runs from the cited line to
  # the `end` at its own indentation (capped, because a runaway scan would swallow the file
  # and green everything).
  defp cited_text(path, line, cache) do
    lines = Map.get_lazy(cache, path, fn -> path |> File.read!() |> String.split("\n") end)
    cache = Map.put(cache, path, lines)
    block = block_at(lines, line)

    helpers =
      ~r/([\w!?]+)\(/
      |> Regex.scan(block)
      |> Enum.map(&List.last/1)
      |> Enum.uniq()
      |> Enum.flat_map(&helper_body(lines, &1))
      |> Enum.join("\n")

    {block <> "\n" <> helpers, cache}
  end

  defp block_at(lines, line) do
    start = max(line - 1, 0)
    head = Enum.at(lines, start, "")
    indent = String.length(head) - String.length(String.trim_leading(head))

    lines
    |> Enum.drop(start)
    |> Enum.take(200)
    |> Enum.reduce_while([], fn l, acc ->
      closed? =
        acc != [] and String.trim(l) == "end" and
          String.length(l) - String.length(String.trim_leading(l)) == indent

      if closed?, do: {:halt, [l | acc]}, else: {:cont, [l | acc]}
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # `[\w!?]+`, NEVER `\w+`: `\w+` truncates assert_receipt_is_stored! at the bang and the
  # def is then never found, which falsely refuses four genuine rows.
  defp helper_body(lines, name) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {l, _n} -> Regex.match?(~r/^\s*defp?\s+#{Regex.escape(name)}\(/, l) end)
    |> Enum.map(fn {_l, n} -> block_at(lines, n) end)
  end

  # THE PRINTED COUNT WAS THE VOCABULARY COLUMN, NOT THE INSTRUMENT (PDS-D544). The old
  # line counted @basis_vocab entries tiered :reds — 6 — while only FOUR of them could
  # refuse anything: `basis_stale` has NO PREDICATE at all (check_row_basis/2 never
  # dispatches it; it is assigned dynamically inside the DISTRIBUTION renderer) and
  # `no_observer` carries ZERO top-level rows (its one occurrence is a nested `tags:`
  # sub-tag, and sub-tags are not walked). A number that counts the vocabulary is a claim
  # about the table; this counts what is armed, which is a claim about the run.
  defp armed_redding_values do
    rows = @register |> Enum.map(& &1.basis) |> Enum.frequencies()

    @basis_vocab
    |> Enum.filter(fn {_k, {_c, _f, t}} -> t == :reds end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], []}, fn {k, _v}, {armed, inert} ->
      dispatched? = k == :no_observer or k in @cited_bases
      n = Map.get(rows, k, 0)

      cond do
        not dispatched? ->
          {armed,
           inert ++
             [{k,
               "NO PREDICATE — check_row_basis/2 never dispatches it, so it falls to the bare `true -> {[], cache}` clause and cannot refuse anything"}]}

        n == 0 ->
          {armed,
           inert ++
             [{k,
               "0 top-level @register rows (a nested `tags:` sub-tag is not walked), so its predicate is never handed an input"}]}

        true ->
          {armed ++ [{k, n}], inert}
      end
    end)
  end

  defp report_basis_falsifiers(classified) do
    p("BASIS FALSIFIERS (PDS-D525 — a vocabulary token is only a claim if a script can")
    p("refuse it; tiered AS MEASURED, so an undecidable falsifier is advisory, not a lie)")
    p(String.duplicate("-", 78))

    case basis_falsifiers(classified) do
      :no_test_tree ->
        p("  SKIPPED — this corpus carries no #{@test_root}/ tree, so no citation can be opened.")
        p("  THIS IS NOT A PASS. The census is normally run over `git archive HEAD api/lib")
        p("  scripts`, which excludes the tests on purpose; run it from a full checkout to")
        p("  arm these arms. Within a present test tree, a citation that cannot be opened REDS.")
        p("")
        :skipped

      {:ran, findings} ->
        {red, advisory} = Enum.split_with(findings, &(&1.tier == :reds))
        {armed, tiered_but_inert} = armed_redding_values()

        p("  checked #{Enum.count(@register)} row(s) against #{length(armed)} ARMED redding value(s) · #{length(red)} refusal(s) · #{length(advisory)} advisory contradiction(s)")
        p("      ARMED = tiered :reds AND dispatched by check_row_basis/2 AND carrying >0 top-level")
        p("      @register rows: #{Enum.map_join(armed, ", ", fn {k, n} -> "#{k} (#{n})" end)}")

        if tiered_but_inert != [] do
          p("      TIERED :reds BUT INERT, counted here rather than counted IN (PDS-D544):")

          Enum.each(tiered_but_inert, fn {k, why} ->
            p("        #{k} — #{why}")
          end)
        end

        Enum.each(red, fn f ->
          p("      REFUSED  #{short(elem(f.key, 0))} #{elem(f.key, 1)}  [#{f.basis}]")
          wrap(f.why, "               ")
        end)

        Enum.each(advisory, fn f ->
          p("      CONTRADICTION  #{short(elem(f.key, 0))} #{elem(f.key, 1)}  [#{f.basis}] #{f.why}")
        end)

        if findings == [], do: p("      none — every decidable falsifier holds")
        p("")
        {:ran, red}
    end
  end

  # ---------------------------------------------------------- register integrity
  #
  # THREE ARMS, ALL SCOPED TO THE REAL CORPUS. They assert COMPLETENESS and INTEGRITY and
  # never a verdict distribution — a reclassification cannot red this build, which is the
  # whole reason the ratchet is safe to leave armed.
  # A SKIPPED SCOPE CONTRIBUTES NO ARM AT ALL, rather than a PASS nobody earned.
  defp falsifier_check(:skipped), do: []

  defp falsifier_check({:ran, red}) do
    why =
      if red == [] do
        "every decidable falsifier holds across the register's cited basis tokens"
      else
        "#{length(red)} basis token(s) REFUSED by their own falsifier: " <>
          Enum.map_join(Enum.take(red, 4), " · ", &"#{short(elem(&1.key, 0))} [#{&1.basis}] #{&1.why}")
      end

    [{"BASIS-FALSIFIERS", red == [], why}]
  end

  defp register_checks(classified, parsed) do
    case register_scope(classified) do
      :scoped_out -> []
      :real ->
        [
          register_complete(classified),
          declared_rows_resolve(classified),
          declared_basis_intact(parsed),
          roster_check(parsed)
        ]
    end
  end

  # BOTH DIRECTIONS, AND THE FAIL SENTENCE NAMES THE OFFENDER. site->row catches an
  # emitted claim nobody has judged; row->site catches a row judging nothing (the shape a
  # split multi-tag row would take). One direction alone is half a register.
  defp register_complete(classified) do
    resolved = resolve_register(classified)
    site_keys = Enum.map(classified, &site_key/1)
    row_keys = Enum.map(@register, & &1.key)
    row_freq = Enum.frequencies(row_keys)

    covered = MapSet.new(for {_r, st, s} <- resolved, st in [:live, :stale], do: site_key(s))
    demoted = Enum.count(resolved, fn {_r, st, _s} -> st == :stale end)

    unjudged = Enum.reject(site_keys, &MapSet.member?(covered, &1))
    orphaned = for {r, :orphan, _s} <- resolved, do: r.key
    dupes = for {k, n} <- row_freq, n > 1, do: k

    ok? = unjudged == [] and orphaned == [] and dupes == []

    why =
      if ok? do
        "#{length(row_keys)} row(s) <-> #{length(site_keys)} emitted site(s), both directions, no duplicate key" <>
          if(demoted > 0, do: " (#{demoted} demoted to basis_stale — reported, never a red)", else: "")
      else
        Enum.join(
          [
            "#{length(unjudged)} emitted site(s) carry NO register row",
            "#{length(orphaned)} register row(s) name NO emitted site",
            "#{length(dupes)} key(s) carry more than one row"
          ] ++
            Enum.map(Enum.take(unjudged, 4), &"UNJUDGED SITE #{short(elem(&1, 0))} #{elem(&1, 1)} #{elem(&1, 2)}/#{elem(&1, 3)}") ++
            Enum.map(Enum.take(orphaned, 4), &"ORPHANED ROW #{short(elem(&1, 0))} #{elem(&1, 1)} #{elem(&1, 2)}/#{elem(&1, 3)}") ++
            Enum.map(Enum.take(dupes, 4), &"DUPLICATE ROW #{short(elem(&1, 0))} #{elem(&1, 1)}"),
          " · "
        )
      end

    {"REGISTER-COMPLETE", ok?, why}
  end

  # NOT "the row's line still carries a success pair" (PDS-D521): the pair occurs on 11
  # lines of auth_controller.ex, so a line shift can land a row on a DIFFERENT site and
  # pass silently, and the FAIL line becomes an eleven-candidate re-derivation instead of
  # a one-edit fix. The row must match an EMITTED AST SITE.
  defp declared_rows_resolve(classified) do
    live = MapSet.new(classified, &site_key/1)
    orphans = Enum.reject(@declared, &MapSet.member?(live, &1.key))

    why =
      if orphans == [] do
        "all #{length(@declared)} declared row(s) resolve to an emitted site"
      else
        "#{length(orphans)} declared row(s) resolve to NO emitted site — a declared basis is suppressing nothing and nobody would know: " <>
          Enum.map_join(orphans, " · ", fn d ->
            {path, mfa, hh, fp} = d.key
            "ORPHAN #{short(path)} #{mfa} #{hh}/#{fp} [#{d.class}]"
          end)
      end

    {"DECLARED-ROWS-RESOLVE", orphans == [], why}
  end

  # THE BASIS ITSELF MUST STILL BE THERE. Each declared row records the SPAN(S) its prose
  # lives in and one TOKEN that must occur inside one of them. Comparison is DOWNCASED on
  # both sides: bulldocs_form's basis is written "so the trap stays invisible" at :24 and
  # "# The trap stays invisible:" at :53, and a case-sensitive test silently loses one.
  # THE FAIL LINE NAMES THE ROW AND ITS RECORDED SPAN, so the fix is one edit and not a
  # re-derivation of where the sentence went.
  defp declared_basis_intact(parsed) do
    src = Map.new(parsed, &{&1.path, String.split(&1.src, "\n")})

    drifted =
      Enum.reject(@declared, fn d ->
        lines = Map.get(src, declared_path(d), [])
        token = String.downcase(d.basis_token)

        Enum.any?(d.basis_spans, fn {lo, hi} ->
          lines
          |> Enum.slice((lo - 1)..(hi - 1)//1)
          |> Enum.any?(&String.contains?(String.downcase(&1), token))
        end)
      end)

    why =
      if drifted == [] do
        "all #{length(@declared)} basis token(s) still occur inside their recorded span(s)"
      else
        "#{length(drifted)} declared basis has DRIFTED off its recorded span: " <>
          Enum.map_join(drifted, " · ", fn d ->
            spans = Enum.map_join(d.basis_spans, ",", fn {lo, hi} -> ":#{lo}-#{hi}" end)
            "#{short(declared_path(d))} #{elem(d.key, 1)} [#{d.class}] recorded span #{spans} no longer carries #{inspect(d.basis_token)}"
          end)
      end

    {"DECLARED-BASIS-INTACT", drifted == [], why}
  end

  defp drift(label, got, key) do
    want = @rederived[key]
    tag = if got == want, do: "==", else: "DRIFT"
    # `baseline`, NEVER `recorded`: `recorded` is @recorded — PDS-D448's wave-33 figures, which
    # `row/4` below still quotes by that name. This block compares against @rederived, and one
    # word naming two different constants in one output is the pointer defect this epic files.
    p("  #{String.pad_trailing(label, 14)} baseline #{String.pad_leading(to_string(want), 4)}  derived #{String.pad_leading(to_string(got), 4)}  #{tag}")
  end

  # WHICH ROWS WAVE 47 RE-DERIVED, DERIVED — never a sentence saying "five". The split is
  # @rederived against the wave-33 record, so widening one to match the other SHRINKS this
  # number in the printed block instead of hiding in prose (the fourth law, made visible).
  defp rederived_rows, do: for({k, v} <- @rederived, v != @recorded[k], do: k)

  # THE REFUSAL (PDS-D678). Scoped to the real corpus by the same predicate the register
  # arms use: the selftest's synthetic tree carries a filler population that matches no
  # baseline, so an unconditional arm would red the selftest on its own commit. That is
  # why the cases proving this arm CAN go red census the REPO (`corpus: :repo`) — an arm
  # proven only where it is scoped out is proven nowhere (PDS-D541).
  defp baseline_checks(drift_rows, classified) do
    case register_scope(classified) do
      :scoped_out -> []
      :real -> [baseline_check(drift_rows)]
    end
  end

  defp baseline_check(drift_rows) do
    drifted = Enum.filter(drift_rows, fn {_label, got, key} -> got != @rederived[key] end)
    n_rederived = length(rederived_rows())

    why =
      if drifted == [] do
        "#{length(drift_rows)} population row(s) equal the wave-47 re-derived baseline — #{n_rederived} re-derived at wave 47, #{length(drift_rows) - n_rederived} inherited unchanged from PDS-D448. EVERY ROW ARMED: the block below can no longer print DRIFT at exit 0"
      else
        "#{length(drifted)} population row(s) DRIFTED off the wave-47 baseline: " <>
          Enum.map_join(drifted, " · ", fn {label, got, key} ->
            "#{label} baseline #{@rederived[key]} derived #{got}"
          end) <>
          " — RE-DERIVE, never re-type: run `elixir scripts/pds-elixir-receipt-census.exs` from the repo root and amend @rederived WITH the lens, the engine and the run in the SAME commit as the change that moved it (PDS-D448a). Editing the literal blind buys a green that costs nothing"
      end

    {"D448-DRIFT-REFUSES", drifted == [], why}
  end

  defp row(label, got, _raw, key) do
    want = @recorded[key]
    tag = if got == want, do: "", else: "  (PDS-D448 recorded #{want})"
    p(String.pad_trailing("  " <> label, 48) <> String.pad_leading(to_string(got), 4) <> tag)
  end

  defp short(path), do: String.replace_prefix(path, "api/lib/", "")

  defp p(s), do: IO.puts(s)
end

PDS.Census.main(System.argv())
