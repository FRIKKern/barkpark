#!/usr/bin/env bash
#
# elixir-path-escape-check.sh — the Elixir skip-shim's path ratchet AND the
# single source of truth for the path sets elixir.yml dispatches on.
#
# WHY THIS EXISTS (Honest Gates charter D31)
# ------------------------------------------
# elixir.yml no longer runs its expensive jobs on every PR: a dispatcher job
# computes the changed-path set and job-level `if:` conditions skip the suite
# on PRs that cannot affect it. That is only honest while the declared path
# sets are a SUPERSET of everything the suite actually reads. The Elixir suite
# reads well outside `api/**` — the machine-derived census is what
# `--list-escapes | cut -f1 | sort -u | wc -l` prints on the working tree, NOT a
# number written here (it said 24 for several waves while the tree measured 29;
# a rotting integer inside the guard that exists to catch rot is this epic's own
# D41 lesson pointed at itself) — and the obvious hand-written filter list
# misses three whole families
# (internal/taskboard/**, internal/chat/testdata/**,
# .codex/skills/epic-cycle/scripts/**). A missed family means a PR that edits
# the Go glyph table skips the ONLY gate that enforces GUI<->TUI parity, and
# the skip reports GREEN.
#
# So: this script re-derives the escape census from the working tree on every
# run and FAILS when a resolved repo-root read is not covered by the declared
# sets below. Adding a new cross-tree read without widening the dispatcher is a
# red, not a silent hole.
#
# HOW AN ESCAPE IS RESOLVED
# -------------------------
# Every `"../…"` string literal in api/lib and api/test is resolved against
# BOTH bases the codebase actually uses:
#   * the file's own directory   — the `Path.expand("../x", __DIR__)` idiom
#   * `api/`                     — the `mix test` cwd idiom (File.read!("../x"))
# Anything landing inside api/ is not an escape. Anything landing outside api/
# AND existing on disk is a repo-root read that the dispatcher must cover.
#
# A THIRD shape is resolved separately, because no `"../…"` literal reveals it:
# the ROOT ANCHOR — `@repo_root Path.expand("../../../..", __DIR__)` bound once
# and then `Path.join(@repo_root, "deploy/site-deploy.sh")` at each read site.
# The anchor literal alone resolves to the empty string and used to be dropped,
# so the joined filename was never seen. See the `-root` door in list_escapes.
#
# MUTATION PROOF that the `-root` door is real, recorded because a guard nobody
# has watched fail is not enforcement. Probe (removed after measuring):
#
#   mkdir -p api/test/probe
#   printf 'defmodule P do\n  use ExUnit.Case\n  @root Path.expand("../../..", __DIR__)\n  test "x" do\n    assert is_binary(File.read!(Path.join(@root, "CLAUDE.md")))\n  end\nend\n' > api/test/probe/p_test.exs
#   bash scripts/elixir-path-escape-check.sh; echo rc=$?
#
# BEFORE (origin/main @ 2b8605d082, probe on disk): "29 distinct repo-root
# read(s)", "OK: every repo-root read from api/lib + api/test is dispatched
# on.", rc=0 — a FALSE OK inside the REQUIRED Elixir gate, with an undeclared
# read sitting right there.
# AFTER (this file): "34 distinct", "idiom test-root: 5 read(s) (floor 2)",
# "::error:: UNCOVERED repo-root read: CLAUDE.md / read from:
# api/test/probe/p_test.exs", rc=1.
# The harness carries the same mutation as a permanent case (case 3b), and
# disarming the door's `printf` takes the harness from 137/0 to 125/12.
#
# The existence filter is what keeps the traversal-attack fixtures
# (`"../etc/passwd"`, `"../up"`, `"../x"`) out of the census: they are asserted
# on, never read. It is also why the enumeration walks the WORKING TREE.
#
# NOT `git ls-files` (charter D31): a prototype that enumerated via git
# reported "OK: every repo-root read is covered" and exited 0 with the mutation
# fixture sitting on disk UNTRACKED — a textbook vacuous pass of exactly the
# class this epic exists to remove. The harness carries an untracked case.
#
# USAGE
#   elixir-path-escape-check.sh                 # the ratchet (CI + the gate)
#   elixir-path-escape-check.sh --selftest      # run the harness
#   elixir-path-escape-check.sh --list-escapes  # print the resolved census
#   elixir-path-escape-check.sh --print-floors  # print the per-idiom floors
#   elixir-path-escape-check.sh --print-set compile|test
#   elixir-path-escape-check.sh --match compile|test   # changed paths on stdin
#                                                      # -> prints true|false
#
# `--print-set` / `--match` are consumed by the elixir.yml dispatcher, so the
# workflow and this ratchet can never disagree about what the path sets are.

set -euo pipefail

# ---------------------------------------------------------------------------
# THE DECLARED PATH SETS (charter D31 — TWO sets, deliberately)
# ---------------------------------------------------------------------------
# Glob grammar, deliberately tiny: `dir/**` = that directory and everything
# under it; anything else = one exact file path. No other wildcards.
#
# COMPILE set — paths that can change what the compiler produces. Gates the
# prod-compile job and the perf bench (and, being a subset of the test set,
# implies the test job too).
#   design/** is here, not in the test-only set: design/status-manifest.json is
#   an @external_resource of api/lib/barkpark/portable_doc/render/status_vocab.ex:20,
#   so editing it recompiles that module. design/tokens.json rides the same tree.
#   This file and elixir.yml are here so a change to the shim itself always runs
#   the full suite it is gating. gate-announces-skips.test.sh joins them for the
#   same reason: it is executed by elixir.yml's unfiltered `path-escape` job, so
#   a change to it is a change to what this required context asserts.
#   prod-build-cache-guard.sh joins them for the strongest version of that
#   reason: mix-prod-compile EXECUTES it, and its verdict decides whether that
#   required gate compiles against a restored dependency tree or rebuilds from
#   scratch. A PR that edited only the guard would otherwise change what the
#   prod-compile gate does while skipping the prod-compile gate.
ELIXIR_COMPILE_PATHS='api/**
design/**
.github/workflows/elixir.yml
scripts/elixir-path-escape-check.sh
scripts/elixir-path-escape-check.test.sh
scripts/gate-announces-skips.test.sh
scripts/prod-build-cache-guard.sh'

# TEST-ONLY set — fixture/mirror trees read by tests but never compiled against.
# Each entry is a MEASURED read, not a guess; see --list-escapes for the census.
#
# Deliberately NOT here, both measured over-inclusions (charter D31):
#   * repo-root templates/**  — no Elixir test reads it. That entry is a
#     copy-paste from go-tests.yml, where it IS load-bearing. The only
#     "templates" the suite reads is internal/provisioner/catalog/templates/**.
#   * scripts/claude-pinned-version.txt — reachable only from
#     api/test/barkpark_web/studio/claude_chat_real_binary_test.exs, whose
#     :real_binary tag is excluded in api/test/test_helper.exs. See EXEMPT below.
# Over-inclusion costs the shim exactly what it exists to save, so both stay out.
#
# NOTE the two docs/ entries are EXACT FILES, never docs/**: docs-only PRs
# skipping the Elixir suite is half the point of this shim.
#
# THE FOUR `deploy/` + workflow ENTRIES BELOW ARE THE ROOT-ANCHOR DOOR'S FIRST
# HARVEST. They were read by the default `mix test` lane for weeks while this
# ratchet printed OK, because the `-root` idiom did not exist yet (see the
# comment on that door in list_escapes). Declaring them is what makes the OK
# line TRUE rather than lucky — and it is NOT free: every `deploy/**` PR now
# runs the full Elixir suite, which the workflow's own note prices at
# 9m31s-16m29s. That is what the honesty costs. Do not optimise it back out
# without deleting the reads: the two tests below are the ONLY guards on the
# `@stage_names` doctrine and on `deploy.yml`'s `scripts/connectors/**` filter
# that can block a merge at all.
#   deploy/site-deploy.sh, deploy/site-deploy-node.sh
#       <- api/test/barkpark/sites/deploy_runner_stage_names_test.exs
#   .github/workflows/deploy.yml, scripts/check-deployyml-filters.sh
#       <- api/test/barkpark/sites/deployyml_connectors_pathfilter_test.exs
#
# THE TWO `web/public/bp-paper-editor.*` ENTRIES: the vendored Web Component
# artifacts, read by api/test/barkpark/paper_editor_vendor_drift_test.exs. They
# are here for BOTH of this list's effects, and the second one is the point.
# Declaring them makes the ratchet honest about the read — but it also puts
# them in the DISPATCH set, so a PR that edits only the vendored web copy now
# runs the Elixir suite and trips the tripwire. Without that, the guard would
# only ever see the api side move, and the web copy could still be edited alone
# — one door watched, the other open. Priced like the deploy/ entries above:
# these two artifacts are touched only when the editor is rebuilt (58 commits
# in the repo's life), so the full-suite cost is rare and bounded.
#   web/public/bp-paper-editor.bundle.js, web/public/assets/bp-paper-editor.css
#       <- api/test/barkpark/paper_editor_vendor_drift_test.exs
#
# THE `cloud/test/**` ENTRY IS THE ONLY DECLARED READ THIS SCRIPT'S OWN CENSUS
# CANNOT SEE, which is why it needs a paragraph here instead of a row in
# --list-escapes. DERIVED FROM WHAT THE SCANNER READS, not from a hunch:
#   scripts/async_env_seam_scan.exs:63-65
#     def default_roots do
#       [Path.join(repo_root(), "cloud/test"), Path.join(repo_root(), "api/test")]
#     end
#   ...and :77  `files = Path.wildcard(Path.join(root, "**/*_test.exs"))`.
#   Called with those defaults by api/test/barkpark/async_global_seam_guard_test.exs,
#   which asserts `count > 0` for BOTH roots and `offenders == []`. So a
#   cloud/test file that gains `async: true` + `Application.put_env` REDS the
#   api suite — a suite a cloud/test-only PR was skipping.
#
# WHY THE CENSUS MISSES IT — the blindness class, recorded so the next reader
# does not go hunting for a scanner bug. Every door in list_escapes resolves
# `"../…"` literals found IN api/lib + api/test. The path here is a runtime
# `Path.join(repo_root(), "cloud/test")` inside a THIRD file that the api test
# merely `Code.require_file`s; the only literal at the api-test site is
# `"../../../scripts/async_env_seam_scan.exs"`, which the census DOES resolve
# and which is declared below — the transitive read one hop further is
# invisible. MEASURED on a clean tree before this entry existed:
# `--list-escapes | cut -f1 | sort -u` printed 38 paths and `grep -c cloud/`
# over them printed 0, while
# `printf 'cloud/test/barkpark_cloud/accounts_test.exs' | … --match test`
# printed `false` (and `--match compile` `false`). A gate that can RED on a
# path it does not DISPATCH on, certified green by its own ratchet, is the
# exact hole this file exists to catch — pointed at itself.
#
# THE CHOICE IS REAL AND IT IS MADE HERE, with its cost. The other direction
# is to make the seam scanner scan only its OWN tree from each side, which
# REMOVES the coupling instead of declaring it. Rejected: the api-side guard's
# own moduledoc states why it covers both roots — "either tree's suite can be
# run alone in CI, and a ratchet that only fires when somebody happens to run
# the OTHER project is not a ratchet" — so narrowing it deletes live coverage
# to buy CI minutes, and would need its own mutation proof on a
# required-adjacent guard. Declaring pays the minutes instead, MEASURED rather
# than waved at: 443 of this repo's 6937 commits touch cloud/test without
# touching any other declared Elixir path, so ~6.4% of commits now
# additionally run the full api suite, which this workflow prices at
# 9m31s-16m29s. That is the most expensive entry in this list by frequency,
# and it is the honest one.
#
# THE GLOB IS `cloud/test/**`, NOT the scanner's `cloud/test/**/*_test.exs`:
# this file's grammar (`dir/**` or an exact path, nothing else) has no such
# form, and the declared set must be a SUPERSET — over-triggering on
# cloud/test/support/** is the correct direction to err, and narrowing it by
# listing individual files would rot on the next cloud test added.
#   cloud/test/**  <- scripts/async_env_seam_scan.exs default_roots/0
#                     <- api/test/barkpark/async_global_seam_guard_test.exs
#   api/assets/sheet-grid/**  <- api/test/barkpark_web/live/studio/sheet_grid/js_harness_test.exs
#                                System.cmd("node", [__*.test.mjs], cd: api/assets/sheet-grid) (#15196);
#                                redundant with api/** in the compile set, declared per task-509410 crit 4.
ELIXIR_TEST_ONLY_PATHS='.codex/skills/epic-cycle/scripts/**
.github/unreachable-assert-message.allow
.github/workflows/deploy.yml
api/assets/sheet-grid/**
apps/mobile/src/papers/portabledoc/blocks/sheet.tsx
cloud/test/**
cmd/barkpark/testdata/**
deploy/site-deploy-node.sh
deploy/site-deploy.sh
docs/api-v1.md
docs/api/error-codes.md
docs/openapi.json
internal/chat/testdata/**
internal/pdrender/testdata/**
internal/provisioner/catalog/templates/**
internal/taskboard/**
js/packages/react/src/blocks/sheet.ts
js/packages/react/tests/fixtures/**
scripts/async_env_seam_scan.exs
scripts/check-deployyml-filters.sh
scripts/pds-door-census.sh
scripts/pds-elixir-receipt-census.exs
scripts/pds-published-artifact-door.sh
scripts/pds-published-artifact-door_test.sh
scripts/pds-record-parity.test.sh
scripts/pds-status-only-residue.exs
scripts/pds-window-sentinel_test.sh
scripts/test-env-leak-allowlist.txt
scripts/test-env-leak-gate.sh
scripts/test-env-leak-gate.test.sh
scripts/unreachable-assert-message-check.sh
web/__tests__/**
web/public/assets/bp-paper-editor.css
web/public/bp-paper-editor.bundle.js'

# EXEMPT — escapes that resolve to a real file but are NOT reachable from the
# default `mix test` lane. Each line is `<path><TAB><why>`; an entry without a
# reason is a bug. Keep this list at zero-growth: the honest fix for a new
# cross-tree read is to declare it above, not to exempt it.
ELIXIR_ESCAPE_EXEMPT='scripts/claude-pinned-version.txt	read only by claude_chat_real_binary_test.exs, whose :real_binary tag is excluded in api/test/test_helper.exs'

# THE CENSUS FLOOR, PER IDIOM — and the "per idiom" is the whole point.
#
# This used to be ONE whole-population number (`ELIXIR_ESCAPE_MIN=8`) over a
# scanner with FOUR independent doors, and a whole-population floor cannot fire
# on the failure its own comment names. Measured on origin/main: deleting
# `api/test` from the `find` in list_escapes — one word, 62% of the scanner's
# coverage, the exact "a find that silently stops matching" case the floor was
# written for — collapsed the census 29 -> 11 and STILL PRINTED `OK` AND EXITED
# 0, inside the REQUIRED Elixir gate. The surviving api/lib reads alone cleared
# 8. The harness could not catch it either: its floor case only ever exercised a
# TOTAL collapse (a one-read fixture), so it certified a floor that could not
# fire. This is the same defect, and the same remedy, as
# `cch-w30-s3-escape-ratchet-transitive-and-per-idiom-floor` next door in
# scripts/console-path-escape-check.sh; the shape here is ported from it.
#
# THE DOORS are the axes the scanner actually has, and each is exactly one line
# away from being deleted:
#   * the SOURCE TREE — `find api/lib api/test` in list_escapes. Tagged `lib-`
#     / `test-`. Dropping either argument blinds that half.
#   * the RESOLUTION BASE — `for base in "$d" "api"` in list_escapes, the two
#     bases documented under HOW AN ESCAPE IS RESOLVED above. Tagged `-dir`
#     (the `Path.expand("../x", __DIR__)` idiom) / `-cwd` (the `mix test` cwd
#     idiom, `File.read!("../x")`). Dropping either base blinds that half.
#     The SIGIL spelling of the same two bases — `~s(../x)`, `~S{…}`,
#     `~c[…]`, `~C<…>` — rides the same loop under `-sigildir` /
#     `-sigilcwd`: same bases, a different lexer, so a regex that stops
#     tolerating sigils reds on its own rows instead of disappearing into
#     `-dir`'s population.
#   * the ROOT ANCHOR — the anchor+`Path.join` scan in list_escapes, in THREE
#     join forms, tagged separately: `-root` (`Path.join(a, "lit")`),
#     `-rootpipe` (`a |> Path.join("lit")`) and `-rootlist`
#     (`Path.join([a, "lit"])`); plus `-rootinterp`, `-rootbase`,
#     `-rootmulti`, `-rootconcat`, `-rootchain` and `-rootexec`, one tag per
#     closed shape (see RESIDUE). THIS COMMENT SAID "THE FOUR DOORS" AND WAS
#     WRONG: for weeks the root-anchor idiom was a FIFTH door nobody counted,
#     and it hid four live undeclared reads while `--check` exited 0. It was
#     then WRONG A SECOND TIME in a subtler way — the door was added with only
#     its single-`Path.join` form, so the pipe and list forms of the SAME idiom
#     stayed invisible while the tag reported healthy. Hence one tag per form:
#     a door that reports at full strength while seeing one of three shapes is
#     the fault this table exists to make impossible, not a smaller version of
#     it. The floor table below is the inventory that keeps a further form or
#     door from being added silently.
# So one door going to zero reds ON ITS OWN, which is the property an aggregate
# count structurally cannot have.
#
# RESIDUE — the census is a LOWER BOUND, and saying so is the point.
#
# THE SPLIT, MEASURED rather than asserted. A 14-shape probe matrix was planted
# in api/test — one file per Elixir idiom, each reading the undeclared repo-root
# file CLAUDE.md, so a shape the scanner SEES reds and a shape it MISSES stays
# silent — and run against the scanner as it stood on origin/main. Result:
#
#     credited:  5 door tags, each reported at full strength, plus a RESIDUE
#                note naming exactly 3 known-blind shapes -> reads as 5 of 8
#     detected:  4 of the 14 shapes cleanly
#
# Nine shapes were invisible, and SIX of those nine were not named anywhere —
# the residue note undercounted its own blindness by a factor of three. That is
# the same fault as the door count itself: the number of checks a scanner runs
# is not the number of shapes it can see.
#
# Two of the nine were closed first — the pipe form `<anchor> |>
# Path.join("lit")` and the list form `Path.join([<anchor>, "lit", …])`, both
# live idioms in api/lib + api/test, each with its own tag and its own harness
# case (3c). Closing them surfaced NO new undeclared read on a clean tree:
# measured, the census stayed at 36 and the OK line stayed true.
#
# THREE MORE were then closed, kept under their original probe numbers (1/4/6)
# for continuity with the shapes still open underneath at the time:
#   1. INTERPOLATED anchor `Path.expand("../#{x}", __DIR__)` — tagged
#      `-rootinterp`. The anchor's literal is no longer required to be pure
#      dots-and-slashes; an interpolated tail is dropped the same way the
#      literal doors already drop one, and the door gets its own tag rather
#      than folding into `-root` so a regex that stops tolerating the splice
#      reds on its own floor, not on `-root`'s.
#   4. NON-__DIR__ BASE `Path.expand("lit", @root)` / `Path.absname("lit",
#      @root)` — tagged `-rootbase`. The anchor sits in the SECOND argument,
#      so none of the three join-form doors (all of which look for the anchor
#      BEFORE the comma) ever matched it; this is a fourth, separately-tagged
#      door over the same per-anchor resolution.
#   6. MULTI-LINE join a `Path.join(` whose anchor and literal sit on the
#      lines AFTER the opener — tagged `-rootmulti`. Every other door here is
#      line-based; this one reads the opener plus a small window of following
#      lines instead. LIVE today at api/lib/barkpark/plugins/tickets/
#      attachments.ex:253 and api/lib/barkpark/plugins/onixedit/export/
#      validator.ex:93 — both anchor on `System.tmp_dir!()`, which this script
#      never binds via `Path.expand(…, __DIR__)`, so the door correctly
#      resolves neither site to a new undeclared read; only an anchor this
#      script actually tracks can surface one.
# All three surfaced NO new undeclared read on a clean tree, the same as the
# pipe/list forms before them — the value is prospective: the next
# `deploy/**` read written in any of these closed shapes is caught the day it
# lands instead of after it has hidden a skipped suite for weeks.
#
# THE LAST FOUR are now closed too, under the same probe numbers (2/3/5/7):
#   2. EXECUTION CWD           `System.cmd(bin, [args], cd: @root)` — tagged
#      `-rootexec`. A SEPARATE CLASS: the read never forms a path literal
#      that anything resolves; the child process resolves its own arguments
#      against the cwd it was handed. Inside a window from the call opener,
#      if `cd:` names an anchor this script tracks, every double-quoted
#      literal in that window is resolved against the anchor's directory and
#      filtered by existence — which is what keeps `"--check"` and `"-lc"`
#      out. LIVE today in api/test/barkpark/pds_door_census_test.exs and
#      pds_elixir_census_test.exs; both pass their command
#      and its arguments as VARIABLES, not literals, so the door correctly
#      resolves neither site to a new read. Seen, not flagged.
#   3. CONCATENATED literal    `Path.join(@root, "CLAUDE" <> ".md")` — tagged
#      `-rootconcat`. The `-root` grep stops at the first closing quote, so
#      it saw `CLAUDE` and the existence filter then dropped it silently.
#      This door concatenates every quoted piece of the `<>` chain, and the
#      chain's truncated prefix is suppressed on `-root` so the two doors
#      cannot both report the same site (once correctly, once as a false red).
#   5. SIGIL literal           `~s(../x)`, `~S{…}`, `~c[…]`, `~C<…>` — tagged
#      `-sigildir` / `-sigilcwd`. Every literal grep here required a DOUBLE
#      QUOTE, so `~s"…"` was the only sigil form ever seen; the six
#      non-quote delimiters are what this adds, on both resolution bases.
#   7. CHAINED anchor          `@sub Path.join(@root, "docs")` then
#      `Path.join(@sub, "lit")` — tagged `-rootchain`. A PRECISION fault
#      rather than a blindness, and the one shape here that could red the
#      REQUIRED gate for the wrong reason: the scanner resolved the
#      intermediate `docs` and never `docs/api-v1.md`, which IS declared, so
#      a chained read landing on a DECLARED file emitted `::error:: UNCOVERED
#      repo-root read: docs`. The door resolves the chain to the real file
#      AND drops the intermediate row — but ONLY when the same file actually
#      joins off that binding. `@dir Path.join(@root, "internal/chat/
#      testdata")` with nothing chained off it keeps the row it has today:
#      that is a real directory read, and dropping it would trade a false red
#      for a false OK.
# Measured on a clean tree: the census stayed at 38 distinct reads and the OK
# line stayed true — the same "no new undeclared read" result every earlier
# shape gave. The value is prospective, not retroactive.
#
# STILL BLIND — the honest boundary, and it is NOT "none". The 14-shape probe
# matrix this note is derived from enumerates the idioms someone thought to
# write down; it is not a proof of completeness, and three separate waves have
# now discovered that its own count of its blindness was too low. Everything
# below is a KNOWN limit of the shapes above, each one measured, not guessed:
#   * a RUNTIME-COMPUTED literal — `Path.join(@root, System.get_env("X"))`,
#     `Enum.join([…])`, a literal built by a function — resolves to nothing
#     static and no grep-based scanner can see it. This is the class boundary
#     of the whole approach, not a gap in one door.
#   * a splice that is not a SUFFIX — the anchor and literal doors drop
#     `#{…}` and keep the static PREFIX, so `Path.expand("../#{x}/../..",
#     __DIR__)` resolves the anchor to `api/test` rather than the repo root
#     and everything joined off it is missed. Deliberate and conservative:
#     the alternative resolves a path the code never reads.
#   * an anchor bound anywhere but `Path.expand(<dots>, __DIR__)` —
#     `System.tmp_dir!()`, `File.cwd!()`, `Application.app_dir/1`, an anchor
#     passed in as a function argument. Widening the anchor regex to any
#     literal was MEASURED at 96 anchors instead of 7 on this tree and does
#     not finish inside a CI timeout; see the note on that regex below.
#   * WINDOW DEPTH — shapes 6 and 2 read 5 and 6 lines after their opener. A
#     `Path.join(` or a `cd:` further down than that is missed.
#   * `-sigil*` covers six delimiters; `~s|…|` inside another `|` context and
#     the heredoc sigils are not lexed.
#
# Read this list as the honest boundary of what the OK line above means. The
# OK line asserts that every read THIS SCANNER CAN SEE is dispatched on. It
# does not assert that every read exists in the census.
#
# Bounds are LOWER BOUNDS, never equalities. An exact pin taxes every slice that
# ADDS a read (the lesson filed as `pds-bl-census-exact-pins-tax-growth`, and
# the reason this file must not simply pin 29); a floor only ever taxes
# SHRINKING, which is the one direction that means "blind". That matters more
# here than anywhere: api/lib + api/test is the hottest tree in the repo, so an
# equality — or a whole-population pin — would red on ordinary green work.
#
# Live population when these bounds were set (`--list-escapes | cut -f1,3 |
# sort -u`, 33 distinct paths): test-cwd 27, test-dir 24, lib-cwd 11,
# lib-dir 10, test-root 4 — all five DERIVED BY RUNNING the scanner on a clean
# checkout, never guessed. `lib-root` gets no row because the scanner emits no
# such tag today: a floor on an unpopulated idiom would red on a clean tree, and
# the inventory check below is what catches the day api/lib starts using it.
# Each bound sits near 40-50% of its live population: retiring
# several cross-tree reads must never require touching this table, while a
# blinded door — which takes its idiom to ZERO, not to 60% — reds immediately.
# Cross-tree reads are deliberate and rare, so they do not churn the way
# ordinary test files do; the headroom is priced for deletion, not for noise.
#
# The table is also the IDIOM INVENTORY: a tag emitted by list_escapes that is
# not listed here is an error, so adding a fifth door cannot quietly ship
# without a floor.
#
# It is a CONSTANT on purpose. An env-var override would be a one-line CI
# bypass of the only check that can tell "clean" from "blind", and the harness
# asserts that setting ELIXIR_ESCAPE_IDIOM_MIN changes nothing.
#
# THE TEN FLOOR-0 ROWS ARE NOT DEAD WEIGHT, and they are not a laundered
# baseline. `test-rootpipe` and `test-rootlist` are the two join forms added
# alongside `test-root`; `test-rootinterp`, `test-rootbase`, `test-rootmulti`,
# `test-rootconcat`, `test-rootchain`, `test-rootexec`, `test-sigildir` and
# `test-sigilcwd` are the shapes closed after them (the RESIDUE note above
# numbers them 1, 4, 6, 3, 7, 2 and 5). All ten are LIVE IDIOMS in api/lib +
# api/test — the script's grammar genuinely supports them — but no current
# call site resolves OUTSIDE api/ through any of the ten, so their measured
# population on a clean tree is 0. A floor of 0 is the only honest number: a
# positive floor would red every clean checkout (the `lib-root` reasoning
# above), while OMITTING the rows makes the inventory check fire "idiom has no
# floor" the moment any of the ten first matches — which reds for the
# SCANNER instead of naming the escape, masking the very finding the door
# exists to report. Measured: with the `test-rootpipe` row absent, a planted
# pipe-form escape produced `::error:: idiom 'test-rootpipe' has no entry` and
# never printed the UNCOVERED line at all.
#
# What a floor of 0 does NOT buy is blindness detection: with population 0
# there is nothing to shrink from, so deleting any of the ten grep doors would
# not red this table. That protection lives in the HARNESS instead — a
# fixture per shape in scripts/elixir-path-escape-check.test.sh, where
# disarming a shape's grep reds the matching case. When any of the ten's live
# population rises above 0, raise its floor to ~50% of the measured population
# and say so here.
ELIXIR_ESCAPE_IDIOM_MIN='test-cwd	8
test-dir	8
lib-cwd	5
lib-dir	5
test-root	2
test-rootpipe	0
test-rootlist	0
test-rootinterp	0
test-rootbase	0
test-rootmulti	0
test-rootconcat	0
test-rootchain	0
test-rootexec	0
test-sigildir	0
test-sigilcwd	0'

# ELIXIR_PATH_ESCAPE_ROOT retargets the scan at a synthetic fixture tree; the
# harness is its only caller. It cannot weaken a real run — pointing it at the
# repo gives the identical verdict.
REPO_ROOT="${ELIXIR_PATH_ESCAPE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# normalize a slash path: resolve `.` and `..` lexically, drop empty segments.
# String-only (no arrays) so it behaves identically on bash 3.2 (macOS) and 5.x.
norm_path() {
  local rest="$1" seg out=""
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      '' | '.') ;;
      '..') out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  printf '%s' "${out#/}"
}

# glob (dir/** or an exact path) -> anchored ERE
glob_to_ere() {
  local g="$1" body
  case "$g" in
    */'**')
      body="${g%/**}"
      printf '^%s(/|$)' "$(printf '%s' "$body" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g')"
      ;;
    *)
      printf '^%s$' "$(printf '%s' "$g" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g')"
      ;;
  esac
}

# Validate BEFORE any command substitution. An `exit 2` raised inside `$(...)`
# only kills the subshell: set_ere would then return an EMPTY pattern, and an
# empty ERE matches every line — so a typo'd set name would have made `--match`
# answer `true` for everything, silently running the full suite (or, on the
# other polarity of a future caller, skipping it). The harness caught exactly
# that; this check is the fix.
assert_set_name() {
  case "$1" in
    compile | test) ;;
    *)
      echo "elixir-path-escape-check: unknown path set '$1' (want compile|test)" >&2
      exit 2
      ;;
  esac
}

set_globs() {
  assert_set_name "$1"
  case "$1" in
    compile) printf '%s\n' "$ELIXIR_COMPILE_PATHS" ;;
    test) printf '%s\n%s\n' "$ELIXIR_COMPILE_PATHS" "$ELIXIR_TEST_ONLY_PATHS" ;;
  esac
}

# One alternation ERE for a whole set. Returned as a single string (not a
# -f pattern file) so nothing here needs process substitution: bash 3.2, which
# is what macOS ships and therefore what the local gate runs, segfaults on
# `< <(...)` inside a command substitution.
set_ere() {
  local g out=""
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if [ -n "$out" ]; then out="$out|"; fi
    out="$out$(glob_to_ere "$g")"
  done <<EOF
$(set_globs "$1")
EOF
  # Belt and braces: an empty ERE matches EVERY line. Never return one.
  if [ -z "$out" ]; then
    echo "elixir-path-escape-check: path set '$1' resolved to an empty pattern" >&2
    exit 2
  fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# the census
# ---------------------------------------------------------------------------
# Prints one resolved repo-root path per line, as
# `<path><TAB><source-file><TAB><idiom>`.
#
# Every row is TAGGED with the door that produced it — `<tree>-<base>`, the two
# axes described at ELIXIR_ESCAPE_IDIOM_MIN. The tag is what makes the per-idiom
# floor possible: an aggregate count cannot tell "one door went blind" from "the
# repo retired a few reads", and that is precisely the mutation that used to
# pass green here.
list_escapes() {
  local f lit base resolved d lits sources tree idiom
  local anchors a name alit adir joins j jlit
  local anchor_interp idiom_tag based b blit openers ol win mjoins
  local anchor_pairs ap aname aadir
  local concats cj clit crest suppress sup skip
  local chains ch subname sublit subdir cjoins
  local sigil orow omatch el xlits xl
  # WORKING TREE enumeration (D31) — `find`, never `git ls-files`. An untracked
  # .exs on disk is code the suite will run, so it is code this ratchet must see.
  sources="$(cd -- "$REPO_ROOT" && find api/lib api/test -type f \( -name '*.ex' -o -name '*.exs' \) 2>/dev/null | LC_ALL=C sort)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    d="$(dirname -- "$f")"
    # The SOURCE-TREE half of the tag. `other` is deliberately absent from
    # ELIXIR_ESCAPE_IDIOM_MIN: the `find` above walks exactly api/lib and
    # api/test, so a row tagged `other-*` means somebody widened the find
    # without declaring a floor for the new door — the inventory check in
    # --check reds on it rather than letting it ship unguarded.
    case "$f" in
      api/lib/*) tree="lib" ;;
      api/test/*) tree="test" ;;
      *) tree="other" ;;
    esac

    # ---- THE ROOT-ANCHOR DOOR (tagged `-root`) ----------------------------
    # `@repo_root Path.expand("../../../..", __DIR__)` bound once, then
    # `Path.join(@repo_root, "deploy/site-deploy.sh")` at each read site.
    #
    # The LITERAL doors below are STRUCTURALLY BLIND to this shape: they grep
    # `"../…"` literals, so the only thing they ever see is the anchor
    # `"../../../.."` — which norm_path reduces to the EMPTY STRING, and the
    # `[ -n "$resolved" ] || continue` guard then discards. The joined filename
    # is never looked at. That made this a FIFTH door the "THE FOUR DOORS"
    # comment above never counted, and it hid four live undeclared reads
    # (deploy/site-deploy.sh, deploy/site-deploy-node.sh,
    # .github/workflows/deploy.yml, scripts/check-deployyml-filters.sh) while
    # this script printed `OK: every repo-root read … is dispatched on.` at
    # rc=0 on a byte-clean tree, INSIDE THE REQUIRED Elixir gate. A false OK in
    # a required gate is worse than no gate: every reader downstream acts on it.
    #
    # Resolution has exactly ONE base by construction — `Path.expand(…,
    # __DIR__)` names its own base — so this door is `<tree>-root`, not a
    # `-dir`/`-cwd` pair.
    # The literal argument used to be restricted to `[./]+` — pure dots and
    # slashes — which is what every anchor ACTUALLY binds on a clean tree.
    # Widened to ALSO allow exactly one `#{…}` splice among the dots and
    # slashes, for SHAPE 1 below: the literal doors already drop a splice and
    # keep the static prefix, but the anchor door never did, so an
    # interpolated anchor literal simply failed this regex and the whole
    # anchor — and everything joined off it — went dark. Deliberately NOT
    # widened to an unrestricted `[^"]*`: that shape matched 96 anchors on
    # this tree instead of 7, because it also swallows one-off single-file
    # bindings like `@x Path.expand("../priv/foo.ex", __DIR__)` that are not
    # navigation anchors at all — scanning the whole file for three join
    # forms plus two more doors per such binding is both semantically wrong
    # (most are a finished read, not something later joined onto) and, at 89
    # extra anchors, the difference between this check finishing in ~1 minute
    # and not finishing inside a CI timeout.
    anchors="$(grep -Eoh '(@[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+|[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=[[:space:]]*)Path\.expand\("[./]*(\#\{[^}]*\})?[./]*",[[:space:]]*__DIR__\)' "$REPO_ROOT/$f" || true)"
    anchor_pairs=""
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      name="${a%%Path.expand*}"
      name="${name%%=*}"
      name="${name//[[:space:]]/}"
      name="${name#@}"
      [ -n "$name" ] || continue
      alit="${a#*\"}"
      alit="${alit%%\"*}"
      # ---- SHAPE 1: INTERPOLATED ANCHOR (tagged `-rootinterp`) -------------
      # `Path.expand("../#{x}", __DIR__)`. Tagged SEPARATELY from `-root` /
      # `-rootpipe` / `-rootlist` rather than folded into them: those three
      # doors are proven by case 3c to catch a plain anchor losing a join
      # form, but a regex that stops tolerating interpolation in the ANCHOR
      # itself would silently shrink right back to zero matches on an
      # interpolated anchor while `-root` stayed fully populated from the
      # plain anchors elsewhere in the tree — the exact "one door goes blind,
      # the aggregate doesn't notice" fault this whole floor table exists to
      # refuse. Drop the splice and keep the static prefix, same as the
      # literal doors below.
      anchor_interp=0
      case "$alit" in *'#{'*) anchor_interp=1 ;; esac
      alit="${alit%%\#\{*}"
      adir="$(norm_path "$d/$alit")"
      # SHAPE 6 (after this whole anchor loop) needs every anchor's
      # (name, resolved-directory) pair, regardless of which join form — if
      # any — matched it here, so collect them as they're computed.
      anchor_pairs="$anchor_pairs$name	$adir
"
      # ---- SHAPE 3: CONCATENATED LITERAL (tagged `-rootconcat`) -----------
      # `Path.join(@root, "CLAUDE" <> ".md")`. The `-root` grep below stops at
      # the FIRST closing quote, so it sees `CLAUDE` and never `CLAUDE.md` —
      # which the existence filter then drops, silently. Concatenate every
      # double-quoted piece of the `<>` chain instead.
      #
      # The chain's first piece is added to `suppress` so the `-root` door does
      # NOT also emit its truncated prefix: `Path.join(@root, "docs" <> "/x")`
      # would otherwise report a repo-root read of `docs` — the SAME precision
      # fault shape 7 names below, arriving through a different door. One
      # suppress list serves both.
      #
      # Tagged separately from `-root` for the reason the whole table exists: a
      # regex that stops tolerating `<>` must red on its own floor, not hide
      # behind `-root`'s population.
      concats="$(grep -Eoh 'Path\.join\(@?'"$name"',[[:space:]]*"[^"]*"([[:space:]]*<>[[:space:]]*"[^"]*")+' "$REPO_ROOT/$f" || true)"
      suppress=""
      while IFS= read -r cj; do
        [ -n "$cj" ] || continue
        crest="${cj#*,}"
        crest="${crest#*\"}"
        suppress="$suppress${crest%%\"*}
"
      done <<EOF
$concats
EOF

      # ---- SHAPE 7: CHAINED ANCHOR (tagged `-rootchain`) ------------------
      # `@sub Path.join(@root, "docs")` bound once, then `Path.join(@sub,
      # "api-v1.md")` at the read site. This is a PRECISION fault, not a
      # blindness: the `-root` door resolves the INTERMEDIATE directory and
      # emits `::error:: UNCOVERED repo-root read: docs` while the real target
      # `docs/api-v1.md` IS declared in ELIXIR_TEST_ONLY_PATHS. A false RED in
      # a required gate costs more operator trust than a false OK costs
      # coverage, so this door does BOTH halves: it resolves the chain to the
      # real file, and it suppresses the intermediate row.
      #
      # The suppression is NARROW on purpose. A binding is only treated as a
      # navigation anchor — and its own row dropped — when the SAME FILE
      # actually joins off it. `@dir Path.join(@root, "internal/chat/testdata")`
      # with nothing chained off it stays exactly the row it is today: that is
      # a real directory read, and dropping it would trade a false red for a
      # false OK.
      chains="$(grep -Eoh '(@[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+|[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=[[:space:]]*)Path\.join\(@?'"$name"',[[:space:]]*"[^"]*"\)' "$REPO_ROOT/$f" || true)"
      while IFS= read -r ch; do
        [ -n "$ch" ] || continue
        subname="${ch%%Path.join*}"
        subname="${subname%%=*}"
        subname="${subname//[[:space:]]/}"
        subname="${subname#@}"
        [ -n "$subname" ] || continue
        [ "$subname" != "$name" ] || continue
        sublit="${ch#*\"}"
        sublit="${sublit%%\"*}"
        [ -n "$sublit" ] || continue
        # only a binding something is actually JOINED OFF is an anchor
        grep -Eq '(Path\.join\(\[?[[:space:]]*@?'"$subname"',)|(@?'"$subname"'[[:space:]]*\|>[[:space:]]*Path\.join\()' "$REPO_ROOT/$f" || continue
        subdir="$(norm_path "$adir/$sublit")"
        [ -n "$subdir" ] || continue
        suppress="$suppress$sublit
"
        # the chained anchor joins EXACTLY like a plain one; shape 6's
        # window scan gets it too, via anchor_pairs.
        anchor_pairs="$anchor_pairs$subname	$subdir
"
        cjoins="$(grep -Eoh 'Path\.join\(@?'"$subname"',[[:space:]]*"[^"]*"' "$REPO_ROOT/$f" || true)
$(grep -Eoh '@?'"$subname"'[[:space:]]*\|>[[:space:]]*Path\.join\("[^"]*"' "$REPO_ROOT/$f" || true)
$(grep -Eoh 'Path\.join\(\[[[:space:]]*@?'"$subname"',[[:space:]]*"[^"]*"' "$REPO_ROOT/$f" || true)"
        while IFS= read -r j; do
          [ -n "$j" ] || continue
          jlit="${j#*\"}"
          jlit="${jlit%%\"*}"
          jlit="${jlit%%\#\{*}"
          case "$jlit" in
            *'*'*)
              jlit="${jlit%%\**}"
              jlit="${jlit%/}"
              ;;
          esac
          [ -n "$jlit" ] || continue
          resolved="$(norm_path "$subdir/$jlit")"
          [ -n "$resolved" ] || continue
          case "$resolved" in api | api/*) continue ;; esac
          [ -e "$REPO_ROOT/$resolved" ] || continue
          printf '%s\t%s\t%s\n' "$resolved" "${f#./}" "$tree-rootchain"
        done <<EOF
$cjoins
EOF
      done <<EOF
$chains
EOF

      # THREE JOIN FORMS, each grepped and TAGGED SEPARATELY:
      #   `-root`     `Path.join(<anchor>, "lit")`
      #   `-rootpipe` `<anchor> |> Path.join("lit")`
      #   `-rootlist` `Path.join([<anchor>, "lit", …])`
      #
      # They are three tags and not one on purpose. Folding them into a single
      # `-root` count would rebuild the exact fault this door was added to fix:
      # an aggregate cannot tell "one form went blind" from "the repo retired a
      # few reads", so deleting the pipe grep would leave `test-root` merrily
      # above its floor. THE NUMBER OF CHECKS A DOOR RUNS IS NOT THE NUMBER OF
      # SHAPES IT SEES — one tag per shape is what makes the floor table an
      # honest inventory rather than a count of doors.
      #
      # MEASURED, not guessed: the pipe and list forms were found live in
      # api/lib + api/test by the 14-shape probe matrix recorded under RESIDUE.
      # The single-`Path.join` form alone saw 4 of those 14 shapes cleanly.
      #
      # The list form keeps only the FIRST literal segment of
      # `Path.join([root, "a", "b"])`. That is deliberate and conservative: the
      # prefix is what the existence filter can confirm, and it matches how the
      # wildcard trim below already degrades a glob to its static prefix.
      for form in root rootpipe rootlist; do
        case "$form" in
          root)
            joins="$(grep -Eoh 'Path\.join\(@?'"$name"',[[:space:]]*"[^"]*"' "$REPO_ROOT/$f" || true)"
            ;;
          rootpipe)
            joins="$(grep -Eoh '@?'"$name"'[[:space:]]*\|>[[:space:]]*Path\.join\("[^"]*"' "$REPO_ROOT/$f" || true)"
            ;;
          rootlist)
            joins="$(grep -Eoh 'Path\.join\(\[[[:space:]]*@?'"$name"',[[:space:]]*"[^"]*"' "$REPO_ROOT/$f" || true)"
            ;;
        esac
        if [ "$anchor_interp" -eq 1 ]; then idiom_tag="$tree-rootinterp"; else idiom_tag="$tree-$form"; fi
        while IFS= read -r j; do
          [ -n "$j" ] || continue
          jlit="${j#*\"}"
          jlit="${jlit%%\"*}"
          jlit="${jlit%%\#\{*}"
          case "$jlit" in
            *'*'*)
              jlit="${jlit%%\**}"
              jlit="${jlit%/}"
              ;;
          esac
          [ -n "$jlit" ] || continue
          # A literal a MORE PRECISE door already resolved through (shape 3's
          # `<>` chain, shape 7's chained anchor) must not ALSO be reported
          # here as its own truncated read — that is the false RED both of
          # those shapes exist to remove. Only the plain `-root` form can be
          # truncated this way; the pipe and list forms never bind an anchor.
          if [ "$form" = "root" ] && [ -n "$suppress" ]; then
            skip=0
            while IFS= read -r sup; do
              [ -n "$sup" ] || continue
              [ "$sup" = "$jlit" ] && skip=1
            done <<EOF
$suppress
EOF
            [ "$skip" -eq 0 ] || continue
          fi
          resolved="$(norm_path "$adir/$jlit")"
          [ -n "$resolved" ] || continue
          # inside api/ is not an escape
          case "$resolved" in api | api/*) continue ;; esac
          # Only reads that can actually happen.
          [ -e "$REPO_ROOT/$resolved" ] || continue
          printf '%s\t%s\t%s\n' "$resolved" "${f#./}" "$idiom_tag"
        done <<EOF
$joins
EOF
      done

      # SHAPE 3's rows, emitted after the join forms so `suppress` (built
      # above, consumed above) and this loop cannot disagree about order.
      while IFS= read -r cj; do
        [ -n "$cj" ] || continue
        # Concatenate every double-quoted piece of the `<>` chain, in order.
        clit=""
        crest="${cj#*,}"
        while :; do
          case "$crest" in *'"'*) ;; *) break ;; esac
          crest="${crest#*\"}"
          clit="$clit${crest%%\"*}"
          crest="${crest#*\"}"
        done
        clit="${clit%%\#\{*}"
        case "$clit" in
          *'*'*)
            clit="${clit%%\**}"
            clit="${clit%/}"
            ;;
        esac
        [ -n "$clit" ] || continue
        resolved="$(norm_path "$adir/$clit")"
        [ -n "$resolved" ] || continue
        case "$resolved" in api | api/*) continue ;; esac
        [ -e "$REPO_ROOT/$resolved" ] || continue
        printf '%s\t%s\t%s\n' "$resolved" "${f#./}" "$tree-rootconcat"
      done <<EOF
$concats
EOF

      # ---- SHAPE 4: NON-__DIR__ BASE (tagged `-rootbase`) -------------------
      # `Path.expand("lit", @root)` / `Path.absname("lit", @root)` — the
      # anchor is the SECOND argument here, not the first, so no `"../…"`
      # literal appears anywhere at the read site and none of the three join
      # forms above — all of which look for the anchor BEFORE the comma —
      # ever match it. Resolution is identical to the join forms (the literal
      # against the anchor's own directory); only the call shape differs, so
      # it earns its own door rather than a fourth arm of the `form` loop.
      based="$(grep -Eoh '(Path\.expand|Path\.absname)\("[^"]*",[[:space:]]*@?'"$name"'\)' "$REPO_ROOT/$f" || true)"
      while IFS= read -r b; do
        [ -n "$b" ] || continue
        blit="${b#*\"}"
        blit="${blit%%\"*}"
        blit="${blit%%\#\{*}"
        case "$blit" in
          *'*'*)
            blit="${blit%%\**}"
            blit="${blit%/}"
            ;;
        esac
        [ -n "$blit" ] || continue
        resolved="$(norm_path "$adir/$blit")"
        [ -n "$resolved" ] || continue
        case "$resolved" in api | api/*) continue ;; esac
        [ -e "$REPO_ROOT/$resolved" ] || continue
        printf '%s\t%s\t%s\n' "$resolved" "${f#./}" "$tree-rootbase"
      done <<EOF
$based
EOF
    done <<EOF
$anchors
EOF

    # ---- SHAPE 6: MULTI-LINE JOIN (tagged `-rootmulti`) ---------------------
    # A `Path.join(` whose anchor and literal sit on the lines AFTER the
    # opener — every door above is line-based, so none of them ever see it.
    # This is the one door that reads a WINDOW rather than a single line.
    #
    # Runs UNCONDITIONALLY per file — not nested under a found anchor like the
    # doors above — so a bare `Path.join(` opener is SEEN in every file that
    # has one, including the two live sites named in the task
    # (api/lib/barkpark/plugins/tickets/attachments.ex:253 and
    # api/lib/barkpark/plugins/onixedit/export/validator.ex:93). Seeing the
    # opener is not the same as resolving it: both of those anchor on
    # `System.tmp_dir!()`, which is not a name this script ever binds via
    # `Path.expand(…, __DIR__)`, so the window-match against `anchor_pairs`
    # below correctly finds nothing for either site — seen, not flagged,
    # exactly as the task requires.
    #
    # ONE grep serves shapes 6 AND 2 (`System.cmd(…, cd: <anchor>)`, below):
    # both are window scans anchored on an opener line, and this script pays
    # its whole runtime in per-file grep processes — the header's own note
    # prices a widened anchor regex as "the difference between this check
    # finishing in ~1 minute and not finishing inside a CI timeout". Measured:
    # a separate grep per shape took the real-tree run 73s -> 117s; folded
    # into this alternation it is back at ~76s. `-no` keeps `LINE:MATCH`, and
    # the match text is what routes each hit to its own door.
    openers="$(grep -noE '^[[:space:]]*Path\.join\([[:space:]]*$|System\.(cmd|shell)\(' "$REPO_ROOT/$f" || true)"
    while IFS= read -r orow; do
      [ -n "$orow" ] || continue
      ol="${orow%%:*}"
      omatch="${orow#*:}"
      case "$omatch" in System.*) continue ;; esac
      win="$(sed -n "$((ol + 1)),$((ol + 5))p" "$REPO_ROOT/$f" | tr '\n' ' ')"
      while IFS= read -r ap; do
        [ -n "$ap" ] || continue
        aname="${ap%%	*}"
        aadir="${ap#*	}"
        [ -n "$aname" ] || continue
        # here-string, not `printf | grep` (charter D37): under `set -o
        # pipefail` a grep that stops reading before printf finishes writing
        # takes SIGPIPE and the pipeline returns 141. `grep -Eoh` reads to EOF
        # so this site cannot fire today, but the idiom is the one the harness
        # purged and a later `-q`/`-m1` would arm it silently.
        mjoins="$(grep -Eoh '@?'"$aname"'[[:space:]]*,[[:space:]]*"[^"]*"' <<<"$win" || true)"
        while IFS= read -r j; do
          [ -n "$j" ] || continue
          jlit="${j#*\"}"
          jlit="${jlit%%\"*}"
          jlit="${jlit%%\#\{*}"
          case "$jlit" in
            *'*'*)
              jlit="${jlit%%\**}"
              jlit="${jlit%/}"
              ;;
          esac
          [ -n "$jlit" ] || continue
          resolved="$(norm_path "$aadir/$jlit")"
          [ -n "$resolved" ] || continue
          case "$resolved" in api | api/*) continue ;; esac
          [ -e "$REPO_ROOT/$resolved" ] || continue
          printf '%s\t%s\t%s\n' "$resolved" "${f#./}" "$tree-rootmulti"
        done <<EOF
$mjoins
EOF
      done <<EOF
$anchor_pairs
EOF
    done <<EOF
$openers
EOF

    # ---- SHAPE 2: EXECUTION CWD (tagged `-rootexec`) ----------------------
    # `System.cmd(bin, [args], cd: @root)` / `System.shell(cmd, cd: @root)`.
    # A SEPARATE CLASS from every door above: the read never forms a path
    # literal that resolves against anything — the child process resolves its
    # own arguments against the cwd the parent handed it. No `"../…"` appears,
    # no `Path.join` appears, so nothing above can see it AT ALL.
    #
    # Resolution: inside a window starting at the call opener, if `cd:` names
    # an anchor this script tracks, every double-quoted literal in that window
    # is a candidate cwd-relative path and is resolved against the anchor's
    # directory. The existence filter is what makes that safe — `"--check"`,
    # `"-lc"`, `"bash"` resolve to nothing on disk and are dropped exactly the
    # way the traversal-attack fixtures are.
    #
    # Runs per FILE and reads a WINDOW, like shape 6: the `cd:` option is
    # routinely on a line of its own several lines below the opener (measured
    # live in api/test/barkpark/pds_elixir_census_test.exs).
    #
    # The `case "$win" in *'cd:'*` pre-filter is not decoration: without it
    # this door pays an anchor-loop and a grep for every `System.cmd(` in the
    # tree, and this script already has to finish inside a CI timeout.
    while IFS= read -r orow; do
      [ -n "$orow" ] || continue
      el="${orow%%:*}"
      omatch="${orow#*:}"
      case "$omatch" in System.*) ;; *) continue ;; esac
      win="$(sed -n "$el,$((el + 6))p" "$REPO_ROOT/$f" | tr '\n' ' ')"
      case "$win" in *'cd:'*) ;; *) continue ;; esac
      while IFS= read -r ap; do
        [ -n "$ap" ] || continue
        aname="${ap%%	*}"
        aadir="${ap#*	}"
        [ -n "$aname" ] || continue
        # `[^a-zA-Z0-9_]|$` and not `\b`: BSD grep (macOS, which is what the
        # local gate runs) does not honour GNU's `\b`, and a word boundary that
        # silently never matches would make this door report zero forever.
        grep -Eq 'cd:[[:space:]]*@?'"$aname"'([^a-zA-Z0-9_]|$)' <<<"$win" || continue
        xlits="$(grep -Eoh '"[^"]*"' <<<"$win" || true)"
        while IFS= read -r xl; do
          [ -n "$xl" ] || continue
          xl="${xl#\"}"
          xl="${xl%\"}"
          xl="${xl%%\#\{*}"
          case "$xl" in
            *'*'*)
              xl="${xl%%\**}"
              xl="${xl%/}"
              ;;
          esac
          [ -n "$xl" ] || continue
          # an absolute argument is not resolved against the cwd at all
          case "$xl" in /*) continue ;; esac
          resolved="$(norm_path "$aadir/$xl")"
          [ -n "$resolved" ] || continue
          case "$resolved" in api | api/*) continue ;; esac
          [ -e "$REPO_ROOT/$resolved" ] || continue
          printf '%s\t%s\t%s\n' "$resolved" "${f#./}" "$tree-rootexec"
        done <<EOF
$xlits
EOF
      done <<EOF
$anchor_pairs
EOF
    done <<EOF
$openers
EOF

    # ---- SHAPE 5: SIGIL LITERALS (tagged `-sigildir` / `-sigilcwd`) --------
    # `~s(../../../x)`, `~S{…}`, `~c[…]`, `~C<…>`. The literal doors below grep
    # `"\.\./…"` — every one of them REQUIRES a double quote — so a sigil form
    # of the exact same read is invisible to them. `~s"…"` and `~S"…"` are the
    # one sigil form they already catch, because the delimiter IS a double
    # quote; the six non-quote delimiters below are the gap.
    #
    # Resolved against BOTH bases, same as the literal doors, and tagged along
    # the same axis (`-sigildir` / `-sigilcwd`) rather than fused into one
    # `-sigil`: the base axis is a door that can go blind on its own, and the
    # whole floor table exists because a fused count cannot see that happen.
    # SHAPE 5's six delimiters ride the literal doors' OWN grep, for the
    # per-file process cost the note on the opener scan above prices. A hit
    # starting with `~` is a sigil, everything else is a double-quoted
    # literal; the `case` below is what routes it.
    lits="$(grep -Eoh '"\.\./[^"]*"|~[sScC]\(\.\./[^)]*\)|~[sScC]\{\.\./[^}]*\}|~[sScC]\[\.\./[^]]*\]|~[sScC]<\.\./[^>]*>|~[sScC]/\.\./[^/]*/|~[sScC]\|\.\./[^|]*\|' "$REPO_ROOT/$f" || true)"
    [ -n "$lits" ] || continue
    while IFS= read -r lit; do
      # `~s(../x)` / `~S{…}` / `~c[…]` / `~C<…>` — SHAPE 5. Every supported
      # delimiter is ONE character, so the literal is the match minus
      # `~X<open>` and minus the closing delimiter. Tagged on the same
      # base axis as the quoted form (`-sigildir` / `-sigilcwd`) and never
      # fused into one `-sigil`: a base going blind must red on its own row.
      sigil=0
      case "$lit" in
        '~'*)
          sigil=1
          lit="${lit:3}"
          lit="${lit%?}"
          ;;
      esac
      lit="${lit%\"}"
      lit="${lit#\"}"
      # `"../#{Path.basename(x)}"` — keep the static prefix, drop the splice.
      lit="${lit%%\#\{*}"
      # `"…/src/**/*.js"` — keep the longest wildcard-free prefix.
      case "$lit" in
        *'*'*)
          lit="${lit%%\**}"
          lit="${lit%/}"
          ;;
      esac
      [ -n "$lit" ] || continue
      # THE RESOLUTION-BASE half. Both bases are real idioms in this codebase
      # (see HOW AN ESCAPE IS RESOLVED above), so both are separately floored.
      for base in "$d" "api"; do
        if [ "$base" = "api" ]; then
          if [ "$sigil" -eq 1 ]; then idiom="$tree-sigilcwd"; else idiom="$tree-cwd"; fi
        else
          if [ "$sigil" -eq 1 ]; then idiom="$tree-sigildir"; else idiom="$tree-dir"; fi
        fi
        resolved="$(norm_path "$base/$lit")"
        [ -n "$resolved" ] || continue
        # inside api/ is not an escape
        case "$resolved" in api | api/*) continue ;; esac
        # Only reads that can actually happen: a literal resolving to nothing on
        # disk is a traversal-attack fixture, not a dependency.
        [ -e "$REPO_ROOT/$resolved" ] || continue
        printf '%s\t%s\t%s\n' "$resolved" "${f#./}" "$idiom"
      done
    done <<EOF
$lits
EOF
  done <<EOF
$sources
EOF
}

is_exempt() {
  local p="$1" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line%%	*}" = "$p" ] && return 0
  done <<<"$ELIXIR_ESCAPE_EXEMPT"
  return 1
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

mode="${1:---check}"

case "$mode" in
  --print-set)
    assert_set_name "${2:?--print-set needs compile|test}"
    set_globs "$2"
    exit 0
    ;;

  --match)
    # changed paths on stdin -> `true` if ANY of them is in the named set.
    # This is what elixir.yml dispatches on, so the workflow and the ratchet
    # can never disagree about what a path set contains.
    want="${2:?--match needs compile|test}"
    assert_set_name "$want"
    ere="$(set_ere "$want")"
    if grep -Eq -- "$ere"; then
      echo "true"
    else
      echo "false"
    fi
    exit 0
    ;;

  --print-floors)
    # `<idiom><TAB><lower bound>`. Exists so the harness can DERIVE what a
    # healthy population looks like instead of hard-coding an integer that
    # rots — the same lesson that took the population number out of case 1's
    # assertion and out of the runtime error message below.
    printf '%s\n' "$ELIXIR_ESCAPE_IDIOM_MIN"
    exit 0
    ;;

  --list-escapes)
    # Collected first, then printed: piping the function directly segfaults
    # bash 3.2 (macOS) when its body carries process substitutions.
    escapes="$(list_escapes)"
    printf '%s\n' "$escapes" | sort -u
    exit 0
    ;;

  --selftest)
    exec bash "$(dirname -- "${BASH_SOURCE[0]}")/elixir-path-escape-check.test.sh"
    ;;

  --check) ;;

  *)
    echo "elixir-path-escape-check: unknown argument '$mode'" >&2
    echo "usage: $0 [--check|--selftest|--list-escapes|--print-floors|--print-set SET|--match SET]" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# --check: the ratchet
# ---------------------------------------------------------------------------
census="$(list_escapes | sort -u || true)"
paths="$(printf '%s\n' "$census" | cut -f1 | sort -u | sed '/^$/d')"
count="$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l | tr -d ' ')"

echo "elixir-path-escape-check: scanning \$REPO_ROOT=$REPO_ROOT"
echo "elixir-path-escape-check: $count distinct repo-root read(s) resolved from api/lib + api/test"

# FAIL-CLOSED on a neutered scanner, ONE DOOR AT A TIME. "Nothing found" is
# never good news here, and neither is "nothing found THROUGH ONE DOOR" — that
# is precisely what an aggregate floor cannot see, and precisely how deleting
# `api/test` from the find used to exit 0.
by_idiom="$(printf '%s\n' "$census" | cut -f1,3 | sed '/^$/d' | sort -u)"
thin=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  idiom="${row%%	*}"
  floor="${row##*	}"
  got="$(printf '%s\n' "$by_idiom" | awk -F'\t' -v k="$idiom" '$2 == k' | wc -l | tr -d ' ')"
  echo "elixir-path-escape-check:   idiom $idiom: $got read(s) (floor $floor)"
  if [ "$got" -lt "$floor" ]; then
    thin=$((thin + 1))
    echo "::error::elixir-path-escape-check: idiom '$idiom' resolved only $got repo-root read(s), floor is $floor." >&2
  fi
done <<EOF
$ELIXIR_ESCAPE_IDIOM_MIN
EOF

# The table is the door inventory: a tag the scanner emits but the floor table
# does not list would ship with NO floor at all — a new door, unguarded.
while IFS= read -r idiom; do
  [ -n "$idiom" ] || continue
  if ! printf '%s\n' "$ELIXIR_ESCAPE_IDIOM_MIN" | awk -F'\t' -v k="$idiom" '$1 == k { f = 1 } END { exit !f }'; then
    thin=$((thin + 1))
    echo "::error::elixir-path-escape-check: idiom '$idiom' has no entry in ELIXIR_ESCAPE_IDIOM_MIN — a scanner door with no floor." >&2
  fi
done <<EOF
$(printf '%s\n' "$by_idiom" | cut -f2 | sort -u)
EOF

if [ "$thin" -gt 0 ]; then
  # NO POPULATION NUMBER HERE. This message used to read "the measured
  # population is 24" while the tree measured 29 — a stale integer inside the
  # guard that exists to catch staleness. Cite the derivation, never the number.
  echo "  The SCANNER is broken, not the repo clean — the live population is the" >&2
  echo "  per-idiom breakdown printed just above." >&2
  echo "  Check that door's find/grep in list_escapes before touching the floor." >&2
  exit 1
fi

test_ere="$(set_ere test)"
uncovered=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # here-string, NOT `printf '%s\n' "$p" | grep -Eq` (charter D37). `grep -q`
  # exits on the first match; under this script's `set -o pipefail` the write
  # side then takes SIGPIPE and the pipeline returns 141, so the `if` takes the
  # FALSE branch and a COVERED path is reported UNCOVERED — a BLOCKING red for
  # a reason foreign to what this ratchet measures. Only the 64KiB pipe buffer
  # kept it quiet: a payload that fits is written before grep can exit. That is
  # luck, not correctness, and the mutation proof in the PR shows the old form
  # at 200/200 false UNCOVERED verdicts once the payload exceeds the buffer.
  if grep -Eq -- "$test_ere" <<<"$p"; then
    continue
  fi
  if is_exempt "$p"; then
    echo "  exempt: $p"
    continue
  fi
  uncovered=$((uncovered + 1))
  echo "::error::elixir-path-escape-check: UNCOVERED repo-root read: $p" >&2
  printf '%s\n' "$census" | awk -F'\t' -v p="$p" '$1 == p { print "    read from: " $2 }' | sort -u >&2
done <<<"$paths"

if [ "$uncovered" -gt 0 ]; then
  cat >&2 <<'MSG'

The Elixir suite reads path(s) that elixir.yml's dispatcher does NOT dispatch
on. A PR touching one of them would SKIP the suite and report green.

Fix: add the path to ELIXIR_TEST_ONLY_PATHS (or ELIXIR_COMPILE_PATHS if it can
change compiler output) at the top of this script — elixir.yml reads its sets
from here, so declaring it once is enough. Exempt it only if the reading test
is excluded from the default lane, and say so in the exemption's reason.
MSG
  exit 1
fi

echo "OK: every repo-root read from api/lib + api/test is dispatched on."
