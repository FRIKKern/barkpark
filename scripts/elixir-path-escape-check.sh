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
#   elixir-path-escape-check.sh --print-families # <program>TAB<derived glob>
#   elixir-path-escape-check.sh --print-set compile|test
#   elixir-path-escape-check.sh --match compile|test   # changed paths on stdin
#                                                      # -> prints true|false
#   elixir-path-escape-check.sh --match test --literal # the LITERAL half only
#   elixir-path-escape-check.sh --print-set test --literal
#
# `--literal` answers a DIFFERENT question from the bare form, and the two must
# never be conflated. The bare form answers what the DISPATCHER must run: every
# path in the declared lists PLUS every member of a derived family, because a
# change to any of them can change what an api test reads. `--literal` answers
# who TYPED a path into a list — the snapshot half, the half that can rot and
# that a human is answerable for. A consumer asking "is this declaration dead?"
# must ask the literal form: a family member nobody executes is not a dead
# declaration, it is the derivation working. scripts/pds-door-census.sh is that
# consumer (its leg B), and getting this wrong reclassified 43 ledger-disposed
# instruments as DEAD-DECLARATION in one commit.
#
# `--print-set` / `--match` are consumed by the elixir.yml dispatcher, so the
# workflow and this ratchet can never disagree about what the path sets are.

set -euo pipefail

# ---------------------------------------------------------------------------
# THE DECLARED PATH SETS (charter D31 — TWO sets, deliberately)
# ---------------------------------------------------------------------------
# Glob grammar, deliberately tiny: `dir/**` = that directory and everything
# under it; a `*` inside a segment matches any run of non-`/` characters
# (`scripts/pds-*.sh`); anything else = one exact file path. No other wildcards.
#
# THE `*` FORM IS NOT FOR HAND-WRITING. Nothing in the two lists below uses it:
# it exists so DERIVED FAMILIES (see derived_family_globs, far below) can be
# expressed at all. A hand-written `scripts/*` would be the over-inclusion the
# templates/** and tooling/** notes refuse; a derived `scripts/pds-*.sh` is the
# consuming script's OWN enumeration read back out of it.
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
#   tooling/pds/pre-gate-papers.json is the SECOND @external_resource that
#   escapes api/, and it is here for the same reason design/** is: it is read at
#   COMPILE time by api/lib/barkpark/content/papers/pre_gate_register.ex (the
#   2026-09-02 grandfather register — a runtime read would miss in every release,
#   which is why it is embedded), so editing it recompiles that module and
#   changes what the reader renders. Declared as an EXACT FILE, never
#   `tooling/**`: that tree is the repo's largest and churns constantly, and the
#   over-inclusion would cost the shim exactly what it exists to save (the same
#   judgement the templates/** note below records). The register is edited only
#   when a Paper heals, so the full-suite cost is rare and bounded.
#   cloud/priv/secret-scrub.exs is the THIRD @external_resource that escapes
#   api/, and the first one read from BOTH trees: it is the single
#   secret-pattern set, compiled by api/lib/barkpark/sites/build_log_scrub.ex
#   (the box's recorded-build-log WRITE boundary) AND by
#   cloud/lib/barkpark_cloud/failure_copy.ex (the control plane's display
#   boundary), because two OTP apps that cannot depend on each other may not each
#   carry their own copy of a redaction table — a copy drifts in SILENCE, a
#   redacted token and a leaked one being indistinguishable until someone reads
#   the bytes. Editing it changes what BOTH scrubbers redact, so a PR touching it
#   must compile and test this tree rather than skip it. Declared as an EXACT
#   FILE, never `cloud/**`: that tree has its own gate (cloud.yml, via
#   scripts/cloud-path-escape-check.sh), and dispatching the whole Elixir suite
#   on it would be the over-inclusion the tooling/** note above refuses.
ELIXIR_COMPILE_PATHS='api/**
VERSION
cloud/priv/secret-scrub.exs
design/**
tooling/pds/pre-gate-papers.json
tooling/pds/disposition-owner-registry.json
.github/workflows/elixir.yml
scripts/elixir-path-escape-check.sh
scripts/elixir-path-escape-check.test.sh
scripts/elixir-impacted-tests.sh
scripts/elixir-impacted-tests.test.sh
scripts/elixir-main-red-attribution.sh
scripts/elixir-main-red-attribution.test.sh
scripts/gate-announces-skips.test.sh
scripts/prod-build-cache-guard.sh'

# TEST-ONLY set — fixture/mirror trees read by tests but never compiled against.
# Each entry is a MEASURED read, not a guess; see --list-escapes for the census.
#
# Deliberately NOT here, both measured over-inclusions (charter D31):
#   * repo-root templates/**  — the bare TREE stays out. A copy-paste of
#     go-tests.yml's entry, where it IS load-bearing, would run the full Elixir
#     suite on every template edit. ONE exact file under it is now declared
#     (the search-starter isBarkparkError stub, below); the tree is not.
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
#   web/components/**  <- api/test/barkpark_web/live/sheets_cf_live_matrix_receipt_test.exs
#   web/lib/**            transpiles web/components/sheet-grid.tsx with the repo's own
#   web/node_modules/**   TypeScript and renderToStaticMarkup's it (#15435). Declared as the
#                         three EXACT subdirs the test names, never the bare `web` tree: a
#                         change to web/app/** cannot break it, so it must not run the suite.
#
#   THE TWO isBarkparkError MIRROR ENTRIES, both read by
#   api/test/barkpark/js_core_error_predicate_mirror_test.exs:
#     js/packages/core/src/errors.ts
#     templates/search-starter/lib/__test-stub-barkpark-core.mjs
#   Declared for BOTH of this list's effects, and the second is the point. The
#   stub is a hand-copied port of core's runtime predicate; the template's own
#   node --test runs under search-starter-smoke (never fires on a js/ PR) and
#   core's vitest runs under js-tests (never fires on a templates/ PR), so
#   neither venue can see the mirror move. Declaring BOTH exact files puts them
#   in the DISPATCH set, so a PR editing EITHER side runs this required suite —
#   one door watched and the other open is not a lock. Two exact files, never
#   `js/**` or `templates/**`: the trees would be far more CI than this buys.
#   THE THREE bp-graph.js MIRROR ENTRIES, read by
#   api/test/barkpark_web/static/bp_graph_escape_lock_test.exs (task-e3cf9937e4762bb0):
#     web/public/bp-graph.js
#     templates/search-starter/public/bp-graph.js
#     templates/astro-search-starter/public/bp-graph.js
#   The graph widget ships as FOUR byte-identical copies; api/priv/static/assets
#   holds the canonical one and the other three are what actually serve the
#   page. The test asserts the four-copy identity AND that every innerHTML sink
#   in the canonical copy escapes its server strings. Its only prior locks —
#   web/__tests__/graph-xss.test.ts and scripts/check-bp-graph-drift.sh via
#   bp-graph-drift.yml — are both ADVISORY, so the escape could be stripped and
#   merged past the required set.
#   Declared for BOTH of this list's effects, and the second is again the point:
#   without these three rows a PR that edits ONLY a mirror skips the Elixir
#   suite, and the identity assertion never runs on the one PR that breaks it.
#   Three EXACT files, never `web/**` or `templates/**` (see the note above on
#   why the bare templates tree stays out). The widget is a generated artifact
#   touched only when the graph is rebuilt, so the full-suite cost is rare.
#   The reads are written INLINE at the read site — `Path.join(@repo_root,
#   "web/public/bp-graph.js")`. That USED TO BE load-bearing: with the same
#   three paths held in a module attribute and joined from it, the census
#   resolved 50 reads, printed OK, and dispatched on none of them, because a
#   path constant one binding away from its `Path.join` was a blind spot of
#   every door below. SHAPE 8 (`-rootattr`, task-5a00c588a808f523 /
#   task-c605ea24bbe5066c) closed that door — re-measured on 974d3d2cb, the
#   attribute form now reds exactly as the inline form does — so the inline
#   spelling stays because it reads better, not because this census needs it.
#   api/test/barkpark_web/static/bp_graph_escape_lock_test.exs still carries
#   the old comment saying inline is REQUIRED; that sentence is now history and
#   the api lane owns correcting it.
#   THE scaffy-duels METER ENTRIES (2026-09-11, pds-w49-meter-ci-decision) are
#   the wiring half of METER.md §6's decision. `tooling/scaffy-duels/meter.py` is
#   the executable half of the cost standard; it was fast, self-proving and
#   CORRECT, and it still drifted 24 -> 34 envelopes unnoticed because ZERO of 43
#   workflow files ever called it. The blocking route is this list plus
#   api/test/barkpark/pds_meter_rider_test.exs, which shells the instrument and
#   rides the already-required `Elixir gate`; a workflow with a workflow-level
#   `on: paths:` filter is REFUSED as the venue (required-checks.json S4 — such a
#   workflow can never be required, so it would be an advisory lane wearing a
#   gate's name).
#   THREE EXACT FILES AND ONE TREE, never `tooling/**` or `tooling/scaffy-duels/**`:
#   METER.md carries the population marker and the §3 literals `verify` asserts,
#   meter.py is the instrument, tally_wf.py is the mirrored rate table
#   `--self-test` proves identical. `results/**` is the ONE tree, and it is a
#   tree on purpose: it is the corpus the assertions are taken over, its own
#   .gitignore calls the registered results "the benchmark's data of record", and
#   an ADDED envelope — the exact change that rotted the doc — has no filename
#   this list could have named in advance. It is 34 committed envelopes / ~255 KB
#   that move only when a duel is recorded, so the full-suite cost is rare and
#   bounded, which is the same judgement the templates/** note above records.
#   THE DOC BYTE-CAP ENTRIES (2026-09-13, task-4c9c1682f5ba5c7a) are the 36 doc
#   paths NOT ALREADY MATCHED here, plus the cap table itself. 36 is not the
#   whole table: the CAPS table holds 39 rows (CAPS_ROWS_EXPECTED=39), and the
#   other three -- api/CLAUDE.md, docs/api-v1.md and docs/api/error-codes.md --
#   are already covered by pre-existing entries, verified by querying the
#   matcher rather than by reading this list. Coverage is COMPLETE at 39/39; do
#   not read the 36 as three docs forgotten. They are here because the caps in
#   scripts/check-doc-budgets.sh had NO BLOCKING READER. Their only enforcer is
#   the `Doc budgets + anchors` job, which required-checks.json holds out as
#   "S4 PATHS-FILTERED: doc-gates.yml only runs on matching paths, so on other
#   PRs this name is ABSENT - a required absent context never reports". So a
#   capped doc went 43 B OVER on main (docs/setup/TASK-SYSTEM.md, 16043 B against
#   a 16000 B cap, via merged #17878 -> #17984 -> #17979) and nothing refused any
#   of the three. The blocking route is the one the meter rider above already
#   takes: api/test/barkpark/doc_budget_cap_test.exs reads the cap table and
#   rides the already-required `Elixir gate`, touching no byte of .github/.
#   check-doc-budgets.sh is TEST_ONLY, not COMPILE, because the test reads it at
#   runtime with File.read!/1 and it is not an @external_resource -- the compile
#   set would assert a recompile dependency that does not exist, and a
#   compile-time resource filed as test-only would let an edit skip the compile
#   lane and green vacuously. THE 36 DOC PATHS ARE THE POINT, not padding:
#   mix-test carries `if: needs.changes.outputs.test == 'true'` and a skipped job
#   counts as PASSING for a required context, so without them a PR that edits
#   only a capped doc SKIPS this suite and the cap is enforced on every PR except
#   the ones that can break it. EXACT FILES, never `docs/**`: that tree churns
#   constantly and the over-inclusion is what the templates/** and tooling/**
#   notes above refuse. The two lists cannot silently drift apart either -- the
#   test's third arm asserts every capped path is matched by a dispatched glob,
#   so a new cap row landing without its path here REDS the Elixir gate.
#   THE UNDECLARED-INDEX CENSUS (2026-09-17, task-a5dc3c755ee33c92) is
#   deploy/db-undeclared-index-census.sh, the DETECTION half of the read-only-
#   sweep control (charter D614). It landed wired to no workflow at all, which
#   is the same shape as the self-attested control it replaces. Its rider is
#   api/test/barkpark/db_undeclared_index_census_test.exs, riding the already-
#   required `Elixir gate`; this entry is the other leg, and neither leg is
#   worth anything alone. Without it a PR touching ONLY the census computes
#   changes.outputs.test == 'false', mix-test is LEGITIMATELY skipped, and the
#   required context goes green on the one PR that changed the detector.
#   TEST_ONLY, not COMPILE: the rider shells it as a subprocess at runtime, so
#   the compile set would assert a recompile dependency that does not exist.
#
#   THE LIVE-VS-SELFTEST DECISION, RECORDED BESIDE THE GATE IT GOVERNS: the
#   GATED ARM IS `--selftest` ONLY. CI NEVER RUNS `--check`. The live arm reads
#   pg_indexes on a credentialed production database, which no ordinary runner
#   has; a gate that needs a credential it lacks either fails OPEN or flakes,
#   and a flapping guard is defeatable by retry. The hermetic arm is not a
#   stand-in for the live read and is not named as one -- it covers the PARSER,
#   which is where both of this detector's shipped defects lived (a
#   CREATE INDEX quoted in a @moduledoc entering the manifest; a `name:` on a
#   continuation line missed, making the live repair read UNDECLARED). So:
#   nothing in CI ever reads pg_indexes. A stray hand-created index on prod is
#   caught by `--check` run out of band on a credentialed box, never here. The
#   rider's @moduledoc states the same decision at the other end.
ELIXIR_TEST_ONLY_PATHS='.codex/skills/epic-cycle/scripts/**
CLAUDE.md
js/CLAUDE.md
AGENTS.md
docs/INDEX.md
docs/contracts/bokbasen.md
docs/contracts/onix-field-map.md
docs/contracts/webhook-realtime.md
docs/contracts/paper-corpus-layers.md
docs/contracts/schema-v2.md
docs/contracts/portable-doc-inline.md
docs/contracts/tenancy.md
docs/contracts/task-claim-lifecycle.md
docs/contracts/close-packet.md
docs/contracts/cloud-object-authz.md
docs/contracts/canonical-impl-markers.md
docs/contracts/sheets-engine.md
docs/contracts/document-graph-and-history.md
docs/contracts/media-http-envelope.md
README.md
docs/ops/PROD_OPS.md
docs/ops/merge-gates.md
docs/ops/branch-protection-and-overrides.md
docs/auth.md
docs/auth-user-sessions.md
docs/setup/QUICKSTART.md
docs/setup/TASK-SYSTEM.md
docs/cheatsheets/bp.md
docs/cheatsheets/tui.md
docs/cheatsheets/tasks.md
docs/cheatsheets/http-api.md
docs/cheatsheets/papers.md
docs/setup/AGENTS-MD.md
docs/setup/AGENT-ONRAMPS.md
docs/decisions/success-claim-census.md
scripts/deploy-reliability-exit-2026-08-10.md
scripts/deploy-reliability-exit-2026-08-17.md
scripts/check-doc-budgets.sh
.github/unreachable-assert-message.allow
.github/workflows/deploy.yml
api/assets/sheet-grid/**
apps/mobile/src/papers/portabledoc/blocks/sheet.tsx
cloud/test/**
cmd/barkpark/testdata/**
deploy/db-undeclared-index-census.sh
deploy/site-deploy-node.sh
deploy/site-deploy.sh
docs/api-v1.md
js/packages/react/src/client.ts
docs/api/error-codes.md
docs/openapi.json
internal/chat/testdata/**
internal/cli/tasks_history_events.go
internal/cli/tasks_history_events_test.go
internal/pdrender/testdata/**
internal/provisioner/catalog/templates/**
internal/taskboard/**
internal/wasmimages/imagemap.go
js/packages/core/src/errors.ts
js/packages/react/src/blocks/sheet.ts
js/packages/react/tests/fixtures/**
scripts/async_env_seam_scan.exs
scripts/check-deployyml-filters.sh
scripts/pds-door-census.sh
scripts/pds-elixir-receipt-census.exs
scripts/pds-live-hetzner-placement-group.sh
scripts/pds-published-artifact-door.sh
scripts/pds-pull-proof_test.sh
scripts/pds-published-artifact-door_test.sh
scripts/pds-record-parity.test.sh
scripts/pds-status-only-residue.exs
scripts/pds-window-sentinel_test.sh
scripts/test-env-leak-allowlist.txt
scripts/test-env-leak-gate.sh
scripts/test-env-leak-gate.test.sh
scripts/unreachable-assert-message-check.sh
templates/astro-search-starter/public/bp-graph.js
templates/search-starter/lib/__test-stub-barkpark-core.mjs
templates/search-starter/public/bp-graph.js
tooling/scaffy-duels/METER.md
tooling/scaffy-duels/meter.py
tooling/scaffy-duels/results/**
tooling/scaffy-duels/tally_wf.py
web/__tests__/**
web/components/**
web/lib/**
web/node_modules/**
web/public/assets/bp-paper-editor.css
web/public/bp-graph.js
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
# SHAPE 8 — ATTRIBUTE-INDIRECTED literal — is closed after those, and it is
# the first one found by an escape that ALREADY EXISTED rather than by a probe
# matrix: `@mirrors ["web/public/bp-graph.js", …]` bound once, then
# `Path.join(@repo_root, m)` — or `Path.expand("../../../" <> rel, __DIR__)` —
# at the read site. Every door above needs the literal AT the call site, so one
# binding of indirection removed the read from the census outright. MEASURED on
# 974d3d2cb with the control run FIRST: an inline probe read of the undeclared
# repo-root `Makefile` took the census 66 -> 67, `test-root` 8 -> 9 and redded
# `UNCOVERED repo-root read: Makefile` at rc=1; the SAME read with the filename
# in an attribute resolved 66, `test-root` 8, and printed the OK line at rc=0.
# Tagged `-rootattr`, armed only by an indirect join site, and proven by harness
# case 3k — whose four arms include a NON-ZERO `test-rootattr` count (so the
# door cannot green behind another door's red) and a quiet-tree arm (so it
# cannot become a false-RED machine). Closing it surfaced NO new undeclared
# read: the clean census stayed at 66 and the OK line stayed true, the same
# prospective-value result every shape before it gave.
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
#   * AN INDIRECTION THE FILE DOES NOT HOLD AS AN ATTRIBUTE — shape 8 resolves
#     a variable-joined read by resolving that file's DATA attributes against
#     the base. A path that arrives from a function return, from a list
#     literal written inline at the call site, from another module, or from
#     the test's own setup block is still invisible. Declare such a read by
#     hand in the sets above; harness case 6 is what guards a declared entry
#     no census row protects.
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
# checkout, never guessed.
#
# `lib-root` USED TO GET NO ROW, and the note here said the inventory check
# below would catch the day api/lib started using the idiom. That day came
# (task-2ab4f5f0a07e887a): `Barkpark.BuildInfo` reads the checked-in repo-root
# `VERSION` file at compile time through `Path.join(@repo_root, "VERSION")`, the
# scanner tagged it `lib-root`, and the run died with `idiom 'lib-root' has no
# entry` — the inventory check firing exactly as designed. Measured population
# on this tree: 1.
#
# ITS FLOOR IS 0, NOT 1, and that is a deliberate, measured concession rather
# than the ~50% rule applied badly. A floor of 1 was tried first: the real tree
# passed and the HARNESS went 284/0 -> 246/40, because
# scripts/elixir-path-escape-check.test.sh points ELIXIR_PATH_ESCAPE_ROOT at
# synthetic fixture trees that carry no api/lib root-anchored read at all, so
# every fixture case redded on the floor instead of on the behaviour it was
# staging. A floor that reds on 40 cases it has no opinion about is noise, not
# enforcement. So this row joins the ten below on the same terms: it exists to
# satisfy the idiom inventory, it buys no blindness detection, and the door's
# protection lives in the harness's own rootanchor fixtures. Raise it to ~50%
# once api/lib's population is large enough that the fixtures' zero stops being
# the binding constraint.
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
# THE TWELVE FLOOR-0 ROWS ARE NOT DEAD WEIGHT, and they are not a laundered
# baseline. `test-rootpipe` and `test-rootlist` are the two join forms added
# alongside `test-root`; `test-rootinterp`, `test-rootbase`, `test-rootmulti`,
# `test-rootconcat`, `test-rootchain`, `test-rootexec`, `test-sigildir` and
# `test-sigilcwd` are the shapes closed after them (the RESIDUE note above
# numbers them 1, 4, 6, 3, 7, 2 and 5); `test-rootattr` and `lib-rootattr` are
# shape 8. Shape 8 gets a row for BOTH trees, unlike the ten, for the reason
# the `lib-root` paragraph above records at first hand: a shape arriving in
# api/lib without a row kills the run on `idiom has no entry` instead of NAMING
# the escape, and a floor-0 row costs nothing to carry.
# All twelve are LIVE IDIOMS in api/lib +
# api/test — the script's grammar genuinely supports them — but no current
# call site resolves OUTSIDE api/ through any of them, so their measured
# population on a clean tree is 0. A floor of 0 is the only honest number: a
# positive floor would red every clean checkout (the `lib-root` reasoning
# above), while OMITTING the rows makes the inventory check fire "idiom has no
# floor" the moment any of them first matches — which reds for the
# SCANNER instead of naming the escape, masking the very finding the door
# exists to report. Measured: with the `test-rootpipe` row absent, a planted
# pipe-form escape produced `::error:: idiom 'test-rootpipe' has no entry` and
# never printed the UNCOVERED line at all.
#
# What a floor of 0 does NOT buy is blindness detection: with population 0
# there is nothing to shrink from, so deleting any of these grep doors would
# not red this table. That protection lives in the HARNESS instead — a
# fixture per shape in scripts/elixir-path-escape-check.test.sh, where
# disarming a shape's grep reds the matching case. When any of their live
# population rises above 0, raise its floor to ~50% of the measured population
# and say so here.
ELIXIR_ESCAPE_IDIOM_MIN='test-cwd	8
test-dir	8
lib-cwd	5
lib-dir	5
lib-root	0
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
test-sigilcwd	0
lib-rootattr	0
test-rootattr	0'

# ---------------------------------------------------------------------------
# THE ZERO-CENSUS PROOF — a floor of 0 proves NOTHING, so prove the door
# ---------------------------------------------------------------------------
# The floor table above buys blindness detection only for idioms with a live
# population: a door whose count falls below its floor reds. TWELVE of the rows
# have floor 0 and population 0, and for those the floor is inert by
# construction — `0 < 0` is false however broken the door is. That is the fault
# task-c605ea24bbe5066c names: the census line `idiom test-rootconcat: 0
# read(s) (floor 0)` CANNOT DISTINGUISH "nobody in this repo writes that form"
# from "this door's grep stopped matching anything at all", and the script
# printed `OK: every repo-root read … is dispatched on.` over both. A guard
# that cannot tell its own blindness from the world's cleanliness is not
# reporting a measurement, it is reporting a coincidence.
#
# So every idiom whose LIVE census is 0 is proven on a SYNTHETIC case before
# --check is allowed to succeed: the fixture below is written into a throwaway
# tree, the scanner is re-run against it through ELIXIR_PATH_ESCAPE_ROOT (the
# same door, the same greps, no mutation and no second implementation), and the
# idiom's tag MUST come back. If it does not, the door is blind and the run
# reds by name.
#
# THIS IS A PREDICATE, NOT A LIST. The set it proves is derived every run from
# the live census — `got == 0` — so an idiom that goes quiet tomorrow is
# proven tomorrow without anyone remembering to add it, and an idiom that gains
# a real population stops paying for a proof it no longer needs. The only
# enumeration is the FIXTURE REGISTRY, and the predicate polices that too: a
# zero-census idiom with NO fixture REFUSES rather than passing, so adding a
# door without a fixture cannot ship as silent coverage. That is the difference
# from "add the missing idiom to the list" — the rule, not the roster, is what
# fires.
#
# WHY NOT ONLY THE HARNESS: elixir-path-escape-check.test.sh has an arm for
# eleven of the twelve (cases 3c-3k) — `lib-rootattr` had none anywhere, which
# is exactly what an off-to-the-side enumeration of arms does over time. The
# mapping "idiom -> the arm that proves it" lived in nobody's head and in no
# code. Here it is a field lookup the run itself performs.
#
# `<idiom><TAB><fixture path under the synthetic root><TAB><source, \n-escaped>`
# Every fixture reads a DISTINCT probe target under `probe/` so a tag can never
# be credited to another fixture's read.
ELIXIR_ESCAPE_IDIOM_FIXTURE='test-rootpipe	api/test/barkpark/probe_rootpipe_test.exs	  @repo_root Path.expand("../../..", __DIR__)\n  def r, do: @repo_root |> Path.join("probe/rootpipe.json") |> File.read!()
test-rootlist	api/test/barkpark/probe_rootlist_test.exs	  @repo_root Path.expand("../../..", __DIR__)\n  def r, do: File.read!(Path.join([@repo_root, "probe/rootlist.json"]))
test-rootinterp	api/test/barkpark/probe_rootinterp_test.exs	  @repo_root Path.expand("../../..#{""}", __DIR__)\n  @bad Path.join(@repo_root, "probe/rootinterp.json")
test-rootbase	api/test/barkpark/probe_rootbase_test.exs	  @repo_root Path.expand("../../..", __DIR__)\n  @bad Path.expand("probe/rootbase.json", @repo_root)
test-rootmulti	api/test/barkpark/probe_rootmulti_test.exs	  @repo_root Path.expand("../../..", __DIR__)\n  def r do\n    Path.join(\n      @repo_root,\n      "probe/rootmulti.json"\n    )\n  end
test-rootconcat	api/test/barkpark/probe_rootconcat_test.exs	  @repo_root Path.expand("../../..", __DIR__)\n  @bad Path.join(@repo_root, "probe" <> "/rootconcat.json")
test-rootchain	api/test/barkpark/probe_rootchain_test.exs	  @repo_root Path.expand("../../..", __DIR__)\n  @sub Path.join(@repo_root, "probe")\n  @bad Path.join(@sub, "rootchain.json")
test-rootexec	api/test/barkpark/probe_rootexec_test.exs	  @repo_root Path.expand("../../..", __DIR__)\n  def r do\n    System.cmd("cat", ["probe/rootexec.json"], cd: @repo_root)\n  end
test-sigildir	api/test/barkpark/probe_sigildir_test.exs	  @a Path.expand(~s(../../../probe/sigildir.json), __DIR__)
test-sigilcwd	api/test/barkpark/probe_sigilcwd_test.exs	  @a Path.expand(~S{../../probe/sigilcwd.json}, __DIR__)
test-rootattr	api/test/barkpark/probe_rootattr_test.exs	  @repo_root Path.expand("../../..", __DIR__)\n  @mirrors [\n    "probe/testrootattr.json"\n  ]\n  def read_all, do: Enum.map(@mirrors, fn m -> File.read!(Path.join(@repo_root, m)) end)
lib-rootattr	api/lib/barkpark/probe_rootattr.ex	  @repo_root Path.expand("../../..", __DIR__)\n  @mirrors [\n    "probe/librootattr.json"\n  ]\n  def read_all, do: Enum.map(@mirrors, fn m -> File.read!(Path.join(@repo_root, m)) end)
lib-root	api/lib/barkpark/probe_root.ex	  @repo_root Path.expand("../../..", __DIR__)\n  @bad Path.join(@repo_root, "probe/libroot.json")
test-root	api/test/barkpark/probe_root_test.exs	  @repo_root Path.expand("../../..", __DIR__)\n  @bad Path.join(@repo_root, "probe/testroot.json")'

# Print the fixture source for one idiom, or nothing if it has none.
idiom_fixture_row() {
  printf '%s\n' "$ELIXIR_ESCAPE_IDIOM_FIXTURE" | awk -F'\t' -v k="$1" '$1 == k { print; exit }'
}

# Plant every named idiom's fixture in a throwaway tree, run THIS scanner
# against it, and print `<idiom><TAB>SEEN|BLIND|NO-FIXTURE`.
#
# The proof runs the production door, not a copy: `--list-escapes` with
# ELIXIR_PATH_ESCAPE_ROOT is the same list_escapes the census uses. A door
# deleted from list_escapes therefore reds here as well as in the harness.
prove_idioms() {
  local want row fx_path fx_src rows tmp rc
  want="$1"
  [ -n "$want" ] || return 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/elixir-path-escape-proof.XXXXXX")"
  mkdir -p "$tmp/api/lib/barkpark" "$tmp/api/test/barkpark" "$tmp/probe"
  while IFS= read -r idiom; do
    [ -n "$idiom" ] || continue
    row="$(idiom_fixture_row "$idiom")"
    if [ -z "$row" ]; then
      printf '%s\tNO-FIXTURE\n' "$idiom"
      continue
    fi
    fx_path="${row#*	}"
    fx_src="${fx_path#*	}"
    fx_path="${fx_path%%	*}"
    mkdir -p "$tmp/$(dirname -- "$fx_path")"
    printf '%b\n' "$fx_src" >"$tmp/$fx_path"
  done <<EOF
$want
EOF
  # The probe targets must EXIST: several doors drop a resolved path that is
  # not a file on disk, so a proof against an empty tree would report every
  # door blind and teach nothing.
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    : >"$tmp/probe/$t"
  done <<'EOF'
rootpipe.json
rootlist.json
rootinterp.json
rootbase.json
rootmulti.json
rootconcat.json
rootchain.json
rootexec.json
sigildir.json
sigilcwd.json
testrootattr.json
librootattr.json
libroot.json
testroot.json
EOF
  # Full ROWS, not just the tag column. A tag is credited to an idiom only when
  # it arrives ATTRIBUTED TO THAT IDIOM'S OWN FIXTURE FILE: several fixtures are
  # tagged by more than one door (a sigil literal resolves under both bases), so
  # a bare tag match would let one fixture certify a door it never exercised —
  # the vacuous pass this proof exists to refuse.
  rows="$(ELIXIR_PATH_ESCAPE_ROOT="$tmp" bash "${BASH_SOURCE[0]}" --list-escapes 2>/dev/null)" || rc=$?
  while IFS= read -r idiom; do
    [ -n "$idiom" ] || continue
    row="$(idiom_fixture_row "$idiom")"
    if [ -z "$row" ]; then
      continue
    fi
    fx_path="${row#*	}"
    fx_path="${fx_path%%	*}"
    if awk -F'\t' -v k="$idiom" -v f="$fx_path" '$3 == k && $2 == f { hit = 1 } END { exit !hit }' <<<"$rows"; then
      printf '%s\tSEEN\n' "$idiom"
    else
      printf '%s\tBLIND\n' "$idiom"
    fi
  done <<EOF
$want
EOF
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# THE UNSEEN-FORM ARM — an honest "I cannot resolve this" beats a silent OK
# ---------------------------------------------------------------------------
# Every door above resolves a path by finding a STRING LITERAL in the source.
# A read whose path expression carries no literal at the read site —
# `Path.expand(rel, __DIR__)`, or `Path.expand("../../../" <> rel, __DIR__)` —
# is not a read this scanner resolved and then declared safe; it is a read this
# scanner never saw. The original incident (task-c605ea24bbe5066c) was exactly
# that shape, and the script's output was indistinguishable from a clean tree.
#
# So the sites are ENUMERATED AND PRINTED, every run, whatever the verdict. The
# `OK:` line below is scoped to what the scanner could resolve, and a site with
# no static binding anywhere in its own file — nothing the doors can reach —
# REFUSES rather than passing.
#
# `<file><TAB><line><TAB><operand><TAB><backing>` where backing is the in-file
# construct that ties the operand to literals the doors DO see:
#   list      `for rel <- ["a", "b"]`     / `Enum.map(["a"], fn rel ->`
#   attr      `@mirrors [...]` + the operand bound off it (the shape-8 door)
#   literal   `rel = "…"`
#   param     `defp f(rel, …)` — the call sites carry the literals
#   NONE      nothing: the scanner cannot see this read, and says so.
unresolvable_sites() {
  local hits f ln expr operand backing base
  hits="$(cd -- "$REPO_ROOT" && grep -rEn \
    -e 'Path\.(expand|absname)\([[:space:]]*[a-z_][A-Za-z0-9_]*[[:space:]]*,' \
    -e 'Path\.(expand|absname|join)\([^)]*<>[[:space:]]*[a-z_@][A-Za-z0-9_]*' \
    --include='*.ex' --include='*.exs' api/lib api/test 2>/dev/null | LC_ALL=C sort)"
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    f="${hit%%:*}"
    ln="${hit#*:}"
    expr="${ln#*:}"
    ln="${ln%%:*}"
    # the operand: the identifier the path expression leans on.
    # NO TRUNCATING READER. `head` closes the pipe at N, so the upstream grep
    # dies of SIGPIPE and this substitution yields 141 under pipefail -- no
    # buffer overrun needed. scripts/pipefail-sigpipe-scan.sh rates a head
    # reader HIGH unless the producer is provably bounded, and "$expr" is not.
    # `grep -m1` stops in the PRODUCER, so there is no reader to close it.
    operand="$(printf '%s\n' "$expr" | grep -m1 -Eo 'Path\.(expand|absname)\([[:space:]]*[a-z_][A-Za-z0-9_]*|<>[[:space:]]*[a-z_@][A-Za-z0-9_]*')"
    operand="${operand##*[ (>]}"
    [ -n "$operand" ] || continue
    backing=NONE
    if grep -Eq "(for|<-)[[:space:]]*${operand}[[:space:]]*<-[[:space:]]*\[|fn[[:space:]]+${operand}[[:space:]]*->" "$REPO_ROOT/$f" 2>/dev/null; then
      backing=list
    fi
    if [ "$backing" = NONE ] && grep -Eq "${operand}[[:space:]]*<-[[:space:]]*@[a-z_]|Enum\.[a-z_]+\(@[a-z_]+,[[:space:]]*fn[[:space:]]+${operand}" "$REPO_ROOT/$f" 2>/dev/null; then
      backing=attr
    fi
    if [ "$backing" = NONE ] && grep -Eq "^[[:space:]]*${operand}[[:space:]]*=[[:space:]]*[\"~]" "$REPO_ROOT/$f" 2>/dev/null; then
      backing=literal
    fi
    if [ "$backing" = NONE ] && grep -Eq "^[[:space:]]*defp?[[:space:]]+[a-z_][A-Za-z0-9_!?]*\([^)]*\<${operand}\>" "$REPO_ROOT/$f" 2>/dev/null; then
      backing=param
    fi
    # THE BASE half. This arm's subject is repo-root ESCAPES, and an escape is
    # resolved against one of two bases (see HOW AN ESCAPE IS RESOLVED): the
    # file's own directory (`__DIR__`) or an anchor attribute. A site whose
    # BASE is itself a runtime value — `Path.expand(p, caller_dir)` in
    # plugin.ex's `__using__`, where `p` arrives from the CALLING module's
    # opts — cannot be located at all, but it is also not a statement about
    # repo-root reads. It is REPORTED (silence is the defect) and does not
    # refuse: a required gate that reds for the wrong reason costs more than
    # one that misses, and this file's own case 3j says so.
    case "$expr" in
      *__DIR__*) base=anchored ;;
      *', @'*) base=anchored ;;
      *) base=dynamic ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$ln" "$operand" "$backing" "$base"
  done <<EOF
$hits
EOF
}

# ELIXIR_PATH_ESCAPE_ROOT retargets the scan at a synthetic fixture tree; the
# harness is its only caller. It cannot weaken a real run — pointing it at the
# repo gives the identical verdict.
REPO_ROOT="${ELIXIR_PATH_ESCAPE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# normalize a slash path: resolve `.` and `..` lexically, drop empty segments.
# String-only (no arrays) so it behaves identically on bash 3.2 (macOS) and 5.x.
# Two entry points, ONE implementation. `norm_path_v` writes its answer to the
# global `NP`; `norm_path` prints it. The census resolves one path per matched
# literal — 562 calls on this tree — and `resolved="$(norm_path …)"` is a FORK
# apiece for a function that never leaves bash. Every call site inside
# `list_escapes` uses the `_v` form; `norm_path` stays for readers and for any
# caller that wants a value in a pipeline.
norm_path_v() {
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
  NP="${out#/}"
}

norm_path() {
  norm_path_v "$1"
  printf '%s' "$NP"
}

# glob (dir/**, a `*` inside a segment, or an exact path) -> anchored ERE
#
# The THREE forms, and why the middle one exists at all: `dir/**` is a tree,
# an exact path is a file, and `a/b-*.ext` is a FAMILY — the shape a consuming
# program enumerates from the tree and that no list of today's members can
# stand in for (task-ac7392fa242a09ef: nine `scripts/pds-*` files were named
# individually here while scripts/pds-door-census.sh enumerates the GLOB, so
# the tenth file dispatched `test=false` and the required gate greened over a
# skipped suite while the same test reddened main).
#
# `**` is substituted through a placeholder rather than directly: a naive
# `s/\*\*/.*/` followed by `s/\*/[^\/]*/` would re-rewrite the `*` it just
# emitted and turn `.*` into `.[^/]*`.
glob_to_ere() {
  local g="$1" body
  case "$g" in
    */'**')
      body="${g%/**}"
      printf '^%s(/|$)' "$(printf '%s' "$body" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g')"
      ;;
    *'*'*)
      printf '^%s$' "$(printf '%s' "$g" |
        sed -e 's/[][\\.^$+?(){}|]/\\&/g' \
            -e 's/\*\*/@@ELIXIRDSTAR@@/g' \
            -e 's,\*,[^/]*,g' \
            -e 's,@@ELIXIRDSTAR@@,.*,g')"
      ;;
    *)
      printf '^%s$' "$(printf '%s' "$g" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g')"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# DERIVED FAMILIES — the half of the test set that is READ, not written
# ---------------------------------------------------------------------------
# WHY (task-ac7392fa242a09ef, SELECTOR GAP #2, measured on 97271476d).
#
# The two lists above are resolved LITERALS: the census reads
# `"../../../scripts/pds-door-census.sh"` out of
# api/test/barkpark/pds_door_census_test.exs and demands that exact path be
# declared. That is correct as far as it goes and it stops one layer short of
# the truth, because the declared script then enumerates a GLOB of its own:
#
#     scripts/pds-door-census.sh:554
#       for g in 'scripts/pds-*.sh' 'scripts/pds-*.exs' 'tooling/pds/*.mjs'
#
# So the api test's real input is the FAMILY, and nine of its members happened
# to be named in ELIXIR_TEST_ONLY_PATHS one at a time. deploy #19577 added the
# tenth (scripts/pds-secret-scan.sh + scripts/pds-secret-scan_test.sh), which
# no entry matched: the dispatcher computed `test=false`, mix-test SKIPPED, the
# required `Elixir gate` reported SUCCESS over zero tests (run 35532446963),
# and then api/test/barkpark/pds_door_census_test.exs reddened main's push arm
# at 19:36Z for the change the PR gate had just greened. An enumeration is a
# snapshot; the consumer's rule is a glob.
#
# THE RULE, and it is a rule rather than a list: every program ALREADY DECLARED
# in the sets above is read back, and every path family it ENUMERATES FROM THE
# TREE becomes a declared glob. The base case is the literal census — a script
# an api test shells cannot stay undeclared, because --check reds on it — so
# this is a one-step transitive closure over a set the ratchet already forces
# to be complete, not a second hand-list to keep in sync. Add an eleventh
# scripts/pds-* file and nothing here changes: the glob already covers it,
# INCLUDING before the file exists on disk, which is the whole point (the
# dispatcher answers about a path set, not about a directory listing).
#
# ENUMERATES FROM THE TREE is the discriminator, and it is what keeps this from
# swallowing the repo. A glob is credited only when it appears on a line that
# also carries an enumeration verb — `for x in`, `ls`, `Path.wildcard`,
# `compgen -G`, `glob.glob`, `globSync`, `readdir` — and never from a comment.
# Measured on 97271476d, the unfiltered form credited `scripts/**` (out of this
# very file's own prose) and `deploy/**`, `api/**`, `cloud/**`, `internal/**`
# out of scripts/check-deployyml-filters.sh, which does not enumerate them at
# all: it string-compares deploy.yml's path filters. The verb filter drops all
# of those and leaves five families from four programs:
#
#     scripts/check-doc-budgets.sh           docs/cards/*.md
#     scripts/pds-door-census.sh             scripts/pds-*.sh
#     scripts/pds-door-census.sh             scripts/pds-*.exs
#     scripts/pds-door-census.sh             tooling/pds/*.mjs
#     scripts/pds-elixir-receipt-census.exs  api/lib/**/*.ex
#     scripts/pds-live-hetzner-placement-group.sh  internal/cli/hetzner_*.go
#
# A LAST-SEGMENT GUARD refuses a family whose final segment is a bare `*`
# (`scripts/*`, `docs/*`): that is a tree, it is spelled `dir/**`, and deciding
# to dispatch the whole Elixir suite on every edit under a top-level directory
# is a judgement a human makes in the lists above, never one this extractor
# makes silently.
#
# IT CANNOT SILENTLY GO EMPTY — the two failure directions are separated
# because they are not the same failure:
#   * SOURCES present, ZERO families derived. The extractor has gone blind (a
#     regex rotted, the verb list stopped matching). Everything refuses, exit 2.
#     This is the case a `|| true` would have turned into a green.
#   * ZERO sources present. The family root is not a Barkpark checkout — the
#     dispatcher's PIN ROOT is literally an empty directory holding one file
#     (elixir.yml: `mkdir -p "$pinroot/scripts"`), and the harness's fixture
#     repos are the same shape. Refusing here would exit 2 inside the
#     dispatcher and DEADLOCK every PR, which is the documented failure the pin
#     block itself refuses to cause. So `--match test` FAILS CLOSED — it
#     answers `true`, runs the suite, and says on stderr why — while `--check`,
#     which only ever runs against the real checkout from elixir.yml's
#     unfiltered path-escape job, refuses outright.
# Fail-closed is the only safe polarity here: the bug being fixed is a SKIP.
#
# THE FAMILY ROOT IS THE WORKING TREE, not $REPO_ROOT. $REPO_ROOT is the
# CENSUS root and the harness retargets it at synthetic fixtures; the declared
# sets are a property of the repo, so re-deriving them against a fixture would
# make every fixture case answer about a tree with no programs in it.
ELIXIR_FAMILY_ROOT="${ELIXIR_FAMILY_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -n "$ELIXIR_FAMILY_ROOT" ] || ELIXIR_FAMILY_ROOT="$REPO_ROOT"

# One line of a program credits the globs on it only if it enumerates.
ELIXIR_FAMILY_ENUM_VERBS='for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]|(^|[[:space:]])ls[[:space:]]|Path\.wildcard|compgen[[:space:]]+-G|glob\.glob|globSync|readdir'
# A family must be rooted in a real top-level tree of this repo.
ELIXIR_FAMILY_ROOTS='scripts|tooling|deploy|design|docs|web|js|internal|cmd|templates|api|cloud|apps|config'

# Prints the programs the derivation reads — declared exact-file entries that
# exist in the working tree and are source text. Sorted, deduped.
derived_family_sources() {
  local g
  {
    printf '%s\n%s\n' "$ELIXIR_COMPILE_PATHS" "$ELIXIR_TEST_ONLY_PATHS"
  } | while IFS= read -r g; do
    [ -n "$g" ] || continue
    case "$g" in
      *'*'*) continue ;;                       # a tree entry enumerates nothing
      *.sh | *.exs | *.ex | *.py | *.mjs | *.js) ;;
      *) continue ;;
    esac
    [ -f "$ELIXIR_FAMILY_ROOT/$g" ] || continue
    # NEVER THIS FILE OR ITS HARNESS. A program cannot be a source of its own
    # declarations: the globs in the lists above and in this prose are the
    # DECLARATION, not an enumeration, and crediting them made the unfiltered
    # extractor swallow `scripts/**` out of this very comment block. It is also
    # what tells a checkout from the dispatcher's PIN ROOT, which holds exactly
    # this one file and would otherwise look like a tree with one program in it.
    case "${g##*/}" in
      elixir-path-escape-check.sh | elixir-path-escape-check.test.sh) continue ;;
    esac
    printf '%s\n' "$g"
  done | LC_ALL=C sort -u
}

# The two-stage derivation, kept out of a subshell so its STATE is readable.
# `derived_family_globs` is called from inside `$(set_globs test)`, which is a
# subshell — anything it assigned would be lost — so the state lives in
# globals computed ONCE by `family_derive`, before any mode runs.
ELIXIR_FAMILY_SOURCES=""
ELIXIR_FAMILY_SOURCE_N=0
ELIXIR_FAMILY_GLOBS=""
ELIXIR_FAMILY_BLIND=""

family_derive() {
  local src
  ELIXIR_FAMILY_SOURCES="$(derived_family_sources)"
  ELIXIR_FAMILY_SOURCE_N="$(printf '%s\n' "$ELIXIR_FAMILY_SOURCES" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$ELIXIR_FAMILY_SOURCE_N" -eq 0 ]; then
    ELIXIR_FAMILY_GLOBS=""
    ELIXIR_FAMILY_BLIND=root
    return 0
  fi
  ELIXIR_FAMILY_GLOBS="$(
    while IFS= read -r src; do
      [ -n "$src" ] || continue
      grep -v '^[[:space:]]*#' "$ELIXIR_FAMILY_ROOT/$src" |
        grep -E "$ELIXIR_FAMILY_ENUM_VERBS" |
        grep -oE "($ELIXIR_FAMILY_ROOTS)/[A-Za-z0-9_./*-]*\*[A-Za-z0-9_./*-]*" || true
    done <<EOF
$ELIXIR_FAMILY_SOURCES
EOF
  )"
  # Strip trailing punctuation a prose line leaves behind (`scripts/pds-*.`
  # out of `scripts/pds-*.{sh,exs}`), drop the bare-`*` last segment — that is
  # a tree, spelled `dir/**`, and never this extractor's call — then dedupe.
  ELIXIR_FAMILY_GLOBS="$(
    printf '%s\n' "$ELIXIR_FAMILY_GLOBS" |
      sed -e 's/[.:,;]$//' -e '/^$/d' |
      grep -Ev '/\*$' |
      LC_ALL=C sort -u || true
  )"
  if [ -z "$ELIXIR_FAMILY_GLOBS" ]; then
    ELIXIR_FAMILY_BLIND=extractor
  else
    ELIXIR_FAMILY_BLIND=
  fi
}

derived_family_globs() {
  [ -z "$ELIXIR_FAMILY_GLOBS" ] || printf '%s\n' "$ELIXIR_FAMILY_GLOBS"
}

# The enumeration-verb lines of one program, as a STRING. Callers then ask
# `grep -qF … <<<"$lines"` rather than ending a pipeline in `grep -q` (house
# D37: -q exits on the first match, the writer takes SIGPIPE, pipefail promotes
# 141 and the match that DID occur reads as a miss).
family_enum_lines() {
  grep -v '^[[:space:]]*#' "$ELIXIR_FAMILY_ROOT/$1" |
    grep -E "$ELIXIR_FAMILY_ENUM_VERBS" || true
}

# A member of a family that CANNOT be on disk. This is what proves the
# dispatcher answers about the rule and not about a directory listing: the
# whole incident was a file that did not exist when the set was last written.
family_probe_member() {
  printf '%s' "$1" | sed -e 's,\*\*,zz-elixir-family-probe,g' -e 's,\*,zz-elixir-family-probe,g'
}

# Validate BEFORE any command substitution. An `exit 2` raised inside `$(...)`
# only kills the subshell: set_ere would then return an EMPTY pattern, and an
# empty ERE matches every line — so a typo'd set name would have made `--match`
# answer `true` for everything, silently running the full suite (or, on the
# other polarity of a future caller, skipping it). The harness caught exactly
# that; this check is the fix.
# A third positional that is neither absent nor `--literal` is a REFUSAL, never
# a silently-ignored token: the two halves answer different questions and a
# caller that meant one and got the other is the whole hazard this flag exists
# to remove.
half_arg() {
  case "${1:-}" in
    '') printf 'whole' ;;
    --literal) printf 'literal' ;;
    *)
      echo "elixir-path-escape-check: unknown flag '$1' (want --literal)" >&2
      exit 2
      ;;
  esac
}

assert_set_name() {
  case "$1" in
    compile | test) ;;
    *)
      echo "elixir-path-escape-check: unknown path set '$1' (want compile|test)" >&2
      exit 2
      ;;
  esac
}

# $2, when it is the literal string `literal`, suppresses the derived half.
# Any other value (including absent) keeps it. Spelled as an equality test and
# not as a `case` default so a typo'd caller gets the FULL set — the answer that
# over-runs the Elixir job — rather than the narrow one that would skip it.
set_globs() {
  assert_set_name "$1"
  local half="${2:-whole}"
  case "$1" in
    compile) printf '%s\n' "$ELIXIR_COMPILE_PATHS" ;;
    test)
      printf '%s\n%s\n' "$ELIXIR_COMPILE_PATHS" "$ELIXIR_TEST_ONLY_PATHS"
      # THE DERIVED HALF. Test-set only: a family is something a test READS at
      # runtime through a program it shells, never an @external_resource the
      # compiler binds. Appended, never substituted — the exact-file entries
      # the census resolves are the BASE CASE this derivation closes over.
      if [ "$half" != 'literal' ]; then
        derived_family_globs
      fi
      ;;
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
$(set_globs "$1" "${2:-whole}")
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
  local prescan_file p_tab pla pla_eof prest pf ppay ptag
  local indirects ir ilit iname ibases ib attrlits al
  # WORKING TREE enumeration (D31) — `find`, never `git ls-files`. An untracked
  # .exs on disk is code the suite will run, so it is code this ratchet must see.
  sources="$(cd -- "$REPO_ROOT" && find api/lib api/test -type f \( -name '*.ex' -o -name '*.exs' \) 2>/dev/null | LC_ALL=C sort)"

  # ---- THE BATCHED PRE-SCAN ----------------------------------------------
  # Three of this function's greps are PER FILE and unconditional — the anchor
  # scan, the opener scan (shapes 6 + 2 share one grep) and the literal/sigil
  # scan. At 2,227 files on this tree that is ~6,700 grep processes per census,
  # and the `path-escape` job runs six censuses (five harness cases plus
  # `--check`). MEASURED on the last 8 green main pushes, that job took
  # 170/169/162/161/145/139/135/125 s wall.
  #
  # Fork cost is not scan cost: the same three EREs over the same 2,227 files
  # are THREE grep invocations when the file list is handed to grep in bulk.
  # So they run here, once each, tagged `A`/`O`/`L`, and the loop below reads
  # each file's rows out of the merged stream instead of shelling out.
  #
  # WHY THIS IS THE SAME CENSUS, not an approximation:
  #   * the EREs are the ones the three sites used, character for character;
  #   * `-H` restores the filename `-h` used to suppress, and it is the only
  #     thing stripped back off — the payload handed to each door is byte-for-
  #     byte what its own `grep -oh` / `grep -no` produced;
  #   * grep visits files in the order given, so within a tag every file's
  #     rows stay in file order and every file's own rows stay in line order;
  #   * `sort -s` (STABLE) on the filename field alone therefore groups by
  #     file WITHOUT reordering anything inside a group, and the A-then-O-then-L
  #     concatenation order is preserved per file — which is irrelevant to the
  #     output anyway, since each tag lands in its own variable;
  #   * the filename key is sorted `LC_ALL=C`, exactly as `sources` is, so the
  #     merged stream advances in lockstep with the loop below.
  # A file with no rows in any of the three streams emitted nothing before
  # (every door either loops over an empty match set or hits the `[ -n "$lits" ]
  # guard), and contributes nothing here.
  #
  # `xargs -0` rather than one giant argv: the file list is ~130 KB today and
  # ARG_MAX is not a limit this scanner should acquire silently. xargs preserves
  # the order of the list across batches, and `-H` is passed explicitly so a
  # final batch of ONE file still prints its filename.
  p_tab="$(printf '\t')"
  prescan_file="${TMPDIR:-/tmp}/elixir-path-escape-prescan.$$.$RANDOM"
  (
    cd -- "$REPO_ROOT" || exit 1
    {
      printf '%s\n' "$sources" | tr '\n' '\0' |
        xargs -0 grep -EoH '(@[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+|[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=[[:space:]]*)Path\.expand\("[./]*(\#\{[^}]*\})?[./]*",[[:space:]]*__DIR__\)' 2>/dev/null |
        awk -v t=A '{ i = index($0, ":"); print t "\t" substr($0, 1, i - 1) "\t" substr($0, i + 1) }' || true
      printf '%s\n' "$sources" | tr '\n' '\0' |
        xargs -0 grep -EonH '^[[:space:]]*Path\.join\([[:space:]]*$|System\.(cmd|shell)\(' 2>/dev/null |
        awk -v t=O '{ i = index($0, ":"); print t "\t" substr($0, 1, i - 1) "\t" substr($0, i + 1) }' || true
      printf '%s\n' "$sources" | tr '\n' '\0' |
        xargs -0 grep -EoH '"\.\./[^"]*"|~[sScC]\(\.\./[^)]*\)|~[sScC]\{\.\./[^}]*\}|~[sScC]\[\.\./[^]]*\]|~[sScC]<\.\./[^>]*>|~[sScC]/\.\./[^/]*/|~[sScC]\|\.\./[^|]*\|' 2>/dev/null |
        awk -v t=L '{ i = index($0, ":"); print t "\t" substr($0, 1, i - 1) "\t" substr($0, i + 1) }' || true
      printf '%s\n' "$sources" | tr '\n' '\0' |
        xargs -0 grep -EoH 'Path\.join\(\[?[[:space:]]*@?[a-zA-Z_][a-zA-Z0-9_]*,[[:space:]]*[a-z_][a-zA-Z0-9_]*[[:space:]]*[]),]|@[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\|>[[:space:]]*Path\.join\([a-z_][a-zA-Z0-9_]*\)|Path\.expand\("[./]*"[[:space:]]*<>[[:space:]]*[a-z_][a-zA-Z0-9_]*,[[:space:]]*__DIR__\)' 2>/dev/null |
        awk -v t=I '{ i = index($0, ":"); print t "\t" substr($0, 1, i - 1) "\t" substr($0, i + 1) }' || true
    } | LC_ALL=C sort -s -t"$p_tab" -k2,2
  ) >"$prescan_file"

  exec 9<"$prescan_file"
  pla=""
  pla_eof=0
  IFS= read -r pla <&9 || pla_eof=1

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # `dirname` was a fork per file; every path here is under api/lib or
    # api/test, so it always has a slash. The `*` arm keeps the fallback
    # `dirname` gave a bare filename.
    case "$f" in
      */*) d="${f%/*}" ;;
      *) d="." ;;
    esac

    # Drain this file's pre-scan rows. The stream is grouped and ordered like
    # `sources`, so a file with no rows simply does not advance the reader.
    anchors=""
    openers=""
    lits=""
    indirects=""
    while [ "$pla_eof" -eq 0 ]; do
      prest="${pla#*$p_tab}"
      pf="${prest%%$p_tab*}"
      [ "$pf" = "$f" ] || break
      ptag="${pla%%$p_tab*}"
      ppay="${prest#*$p_tab}"
      case "$ptag" in
        A) anchors="$anchors$ppay
" ;;
        O) openers="$openers$ppay
" ;;
        L) lits="$lits$ppay
" ;;
        I) indirects="$indirects$ppay
" ;;
      esac
      IFS= read -r pla <&9 || pla_eof=1
    done
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
      norm_path_v "$d/$alit"
      adir="$NP"
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
        norm_path_v "$adir/$sublit"
        subdir="$NP"
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
          norm_path_v "$subdir/$jlit"
          resolved="$NP"
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
          norm_path_v "$adir/$jlit"
          resolved="$NP"
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
        norm_path_v "$adir/$clit"
        resolved="$NP"
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
        norm_path_v "$adir/$blit"
        resolved="$NP"
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

    # ---- SHAPE 8: ATTRIBUTE-INDIRECTED LITERAL (tagged `-rootattr`) --------
    # `@mirrors ["web/public/bp-graph.js", …]` bound once, then
    # `Path.join(@repo_root, m)` — or `Path.expand("../../../" <> rel,
    # __DIR__)` — at the read site. EVERY door above needs the path literal AT
    # the call site: the three join forms grep `,[[:space:]]*"…"`, the literal
    # doors grep `"../…"`, and a bare `m` is neither. So ONE binding of
    # indirection took a real read out of the census entirely, and the ratchet
    # certified the escape green.
    #
    # MEASURED on 974d3d2cb, control first (task-5a00c588a808f523 /
    # task-c605ea24bbe5066c): a probe test reading the undeclared repo-root
    # `Makefile` INLINE — `Path.join(@root, "Makefile")` — took the census
    # 66 -> 67, `test-root` 8 -> 9, and redded `UNCOVERED repo-root read:
    # Makefile` at rc=1. The SAME read with the filename in `@mirrors` and
    # joined from the loop variable resolved 66, `test-root` 8, and printed
    # `OK: every repo-root read … is dispatched on.` at rc=0. The concat form
    # `Path.expand("../../../" <> rel, __DIR__)` measured identically.
    #
    # Resolution is deliberately DATAFLOW-FREE — this is a grep census, not a
    # compiler, and it does not try to prove which attribute feeds which
    # variable. It resolves the other way round: a file that joins a
    # NON-LITERAL onto a tracked anchor (or onto an inline `"../…" <> var`
    # expand) has its DATA attributes' string literals resolved against that
    # base, and the existence filter keeps the guesses honest — exactly how
    # shape 2's window scan already treats every literal near a `cd:`.
    #
    # THREE NARROWINGS, each priced against what a false RED costs a required
    # gate:
    #   * the door is ARMED ONLY by an indirect join site (`I` in the
    #     pre-scan). No such site in the file, no rows — which is why this
    #     door adds zero reads to the real tree today and `test-rootattr`
    #     joins the floor-0 rows;
    #   * only DATA attributes are read: an attribute whose own definition
    #     calls `Path.` / `File.` / `System.` is skipped, so
    #     `@r1 Path.join(@root, "x")` stays the `-root` door's row and is not
    #     double-tagged here;
    #   * a literal starting `../` is skipped — that is the literal doors'
    #     territory, and resolving it again here would report one read twice.
    #
    # WHAT IT STILL CANNOT SEE, said out loud rather than counted as covered:
    # a path built from a function return, from a list literal written inline
    # at the call site, or from anything the file does not hold as a module
    # attribute. Those remain outside a grep census; declare such a read by
    # hand in ELIXIR_TEST_ONLY_PATHS and let case 6 of the harness guard it.
    if [ -n "$indirects" ]; then
      ibases=""
      while IFS= read -r ir; do
        [ -n "$ir" ] || continue
        iname=""
        case "$ir" in
          Path.expand*)
            # `Path.expand("../../../" <> var, __DIR__)`: the dots ARE the base.
            ilit="${ir#*\"}"
            ilit="${ilit%%\"*}"
            norm_path_v "$d/$ilit"
            # `.` and not "" — a base that resolves to the repo root is a real
            # base, and an empty line is dropped by every reader below.
            ibases="$ibases${NP:-.}
"
            ;;
          *'|>'*)
            iname="${ir%%|>*}"
            iname="${iname//[[:space:]]/}"
            iname="${iname#@}"
            ;;
          *)
            iname="${ir#*(}"
            iname="${iname#\[}"
            iname="${iname%%,*}"
            iname="${iname//[[:space:]]/}"
            iname="${iname#@}"
            ;;
        esac
        [ -n "$iname" ] || continue
        while IFS= read -r ap; do
          [ -n "$ap" ] || continue
          aname="${ap%%	*}"
          [ "$aname" = "$iname" ] || continue
          aadir="${ap#*	}"
          ibases="$ibases${aadir:-.}
"
        done <<EOF
$anchor_pairs
EOF
      done <<EOF
$indirects
EOF
      ibases="$(printf '%s\n' "$ibases" | sed '/^$/d' | LC_ALL=C sort -u)"
      if [ -n "$ibases" ]; then
        # A DATA attribute's block: the definition line, plus the continuation
        # lines of a multi-line list (`@mirrors [` … `]`), which is the shape
        # the finding was measured in. Bracket depth, not a line count.
        attrlits="$(awk '
          !inattr && /^[[:space:]]*@[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]/ {
            if ($0 ~ /Path\.|File\.|System\./) next
            inattr = 1; depth = 0
          }
          inattr {
            line = $0
            o = gsub(/\[/, "[", line)
            c = gsub(/\]/, "]", line)
            depth += o - c
            print
            if (depth <= 0) inattr = 0
          }
        ' "$REPO_ROOT/$f" | grep -Eoh '"[^"]*"' || true)"
        while IFS= read -r al; do
          [ -n "$al" ] || continue
          al="${al#\"}"
          al="${al%\"}"
          case "$al" in
            '' | /* | ../* | *'#{'*) continue ;;
            *'*'*)
              al="${al%%\**}"
              al="${al%/}"
              ;;
          esac
          [ -n "$al" ] || continue
          while IFS= read -r ib; do
            [ -n "$ib" ] || continue
            norm_path_v "$ib/$al"
            resolved="$NP"
            [ -n "$resolved" ] || continue
            case "$resolved" in api | api/*) continue ;; esac
            [ -e "$REPO_ROOT/$resolved" ] || continue
            printf '%s\t%s\t%s\n' "$resolved" "${f#./}" "$tree-rootattr"
          done <<EOF
$ibases
EOF
        done <<EOF
$attrlits
EOF
      fi
    fi

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
          norm_path_v "$aadir/$jlit"
          resolved="$NP"
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
          norm_path_v "$aadir/$xl"
          resolved="$NP"
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
        norm_path_v "$base/$lit"
        resolved="$NP"
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
  exec 9<&-
  rm -f -- "$prescan_file"
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

# Derive ONCE, before any mode reads a path set. Both blind states are named
# here rather than at each use site, so no mode can quietly disagree about what
# "the derivation failed" means.
family_derive

family_blind_note() {
  case "$ELIXIR_FAMILY_BLIND" in
    root)
      echo "elixir-path-escape-check: NO declared program found under ELIXIR_FAMILY_ROOT=$ELIXIR_FAMILY_ROOT — the glob-family derivation cannot run here (a pin root or a fixture tree, not a checkout)." >&2
      ;;
    extractor)
      echo "elixir-path-escape-check: $ELIXIR_FAMILY_SOURCE_N declared program(s) read and ZERO path families derived — the extractor has gone blind." >&2
      ;;
  esac
}

# THE TWO BLIND STATES GET TWO ANSWERS, and the split is the whole contract.
#
#   extractor — programs were read and ZERO families came back. Rot: a regex
#     died, the verb list stopped matching. Never survivable, every mode
#     exits 2. This is the silent-empty the criterion refuses.
#   root — there is no program to read. The family root is not a Barkpark
#     checkout: the harness's fixture repos are this shape and so is the
#     dispatcher's PIN ROOT (elixir.yml: `mkdir -p "$pinroot/scripts"`, one
#     file in it). Exiting 2 here would deadlock every PR from inside the
#     dispatcher, which the pin block explicitly declines to do, and forcing
#     `true` would make every fixture answer `test=true` for a docs-only diff.
#     So: WARN, contribute no derived half, and let `--check` refuse — which
#     is teeth, not a shrug, because `--check` runs from elixir.yml's
#     UNFILTERED `path-escape` job on every PR and against the real checkout.
#     In production `--match` never reaches this state: the dispatcher's cwd is
#     the head checkout even when the SCRIPT comes from the pin root.
if [ "$ELIXIR_FAMILY_BLIND" = extractor ]; then
  family_blind_note
  exit 2
fi
if [ "$ELIXIR_FAMILY_BLIND" = root ] && [ "$mode" != --check ]; then
  family_blind_note
fi

case "$mode" in
  --print-families)
    # `<program><TAB><family>`, re-derived on every run. The harness drives
    # this so its arms can never certify a family nobody enumerates.
    while IFS= read -r __g; do
      [ -n "$__g" ] || continue
      while IFS= read -r __s; do
        [ -n "$__s" ] || continue
        __lines="$(family_enum_lines "$__s")"
        if grep -qF -- "$__g" <<<"$__lines"; then
          printf '%s\t%s\n' "$__s" "$__g"
        fi
      done <<EOF
$ELIXIR_FAMILY_SOURCES
EOF
    done <<EOF
$ELIXIR_FAMILY_GLOBS
EOF
    exit 0
    ;;

  --print-set)
    assert_set_name "${2:?--print-set needs compile|test}"
    # ON ITS OWN LINE, NEVER NESTED IN THE CALL. `half_arg`'s refusal is an
    # `exit 2` from a command substitution, i.e. a SUBSHELL: written inline as
    # an argument its status is discarded, and a bogus flag printed the error to
    # stderr and then answered `false` with rc=0 — a refusal that answers is
    # worse than no refusal at all.
    half="$(half_arg "${3:-}")"
    set_globs "$2" "$half"
    exit 0
    ;;

  --match)
    # changed paths on stdin -> `true` if ANY of them is in the named set.
    # This is what elixir.yml dispatches on, so the workflow and the ratchet
    # can never disagree about what a path set contains.
    want="${2:?--match needs compile|test}"
    assert_set_name "$want"
    half="$(half_arg "${3:-}")"
    ere="$(set_ere "$want" "$half")"
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
    echo "usage: $0 [--check|--selftest|--list-escapes|--print-floors|--print-families|--print-set SET [--literal]|--match SET [--literal]]" >&2
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
zero_idioms=""
while IFS= read -r row; do
  [ -n "$row" ] || continue
  idiom="${row%%	*}"
  floor="${row##*	}"
  got="$(printf '%s\n' "$by_idiom" | awk -F'\t' -v k="$idiom" '$2 == k' | wc -l | tr -d ' ')"
  echo "elixir-path-escape-check:   idiom $idiom: $got read(s) (floor $floor)"
  if [ "$got" -eq 0 ]; then
    # A ZERO population is the one count this table cannot judge: `0 < 0` is
    # false however broken the door is. Collect it for the synthetic proof.
    zero_idioms="$zero_idioms$idiom
"
  fi
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

# ---- THE ZERO-CENSUS PROOF ------------------------------------------------
# `got == 0` is the predicate: whatever the floor says, a door that resolved
# nothing on the live tree has told us nothing about itself. Prove it on a
# synthetic case or refuse. See ELIXIR_ESCAPE_IDIOM_FIXTURE for why this is a
# rule over the live census and not a second roster to keep in sync.
if [ -n "$zero_idioms" ] && [ -n "${ELIXIR_PATH_ESCAPE_ROOT:-}" ]; then
  # SCOPED TO A SELF-SCAN, AND SAID OUT LOUD. The proof is a statement about
  # the SCANNER, so it belongs to the run that scans the scanner's own
  # checkout. Under ELIXIR_PATH_ESCAPE_ROOT the tree is a three-file fixture
  # where nearly every idiom is legitimately zero, and a door the fixture was
  # built to delete must red on the fixture's OWN assertion, not on this one —
  # the harness proves a door load-bearing by deleting it and watching the read
  # go quiet. So the proof steps aside there and SAYS it stepped aside: a check
  # that skips in silence is the fault this file is named after.
  echo "elixir-path-escape-check: zero-census proof SKIPPED — ELIXIR_PATH_ESCAPE_ROOT is set, so this is a fixture scan, not a self-scan. The doors are proven by the run that scans this checkout (and by cases 11a-11c of the harness, which run a COPY of this script as its own checkout)."
elif [ -n "$zero_idioms" ]; then
  echo "elixir-path-escape-check: $(printf '%s\n' "$zero_idioms" | sed '/^$/d' | wc -l | tr -d ' ') idiom(s) resolved ZERO reads on this tree — proving each door on a synthetic case (a floor of 0 cannot)."
  while IFS= read -r prow; do
    [ -n "$prow" ] || continue
    pidiom="${prow%%	*}"
    pverdict="${prow##*	}"
    case "$pverdict" in
      SEEN)
        echo "elixir-path-escape-check:   idiom $pidiom: 0 live read(s), detector PROVEN on a synthetic case"
        ;;
      BLIND)
        thin=$((thin + 1))
        echo "::error::elixir-path-escape-check: idiom '$pidiom' resolved 0 reads on this tree AND did not fire on its own synthetic fixture — this door is BLIND, not idle. Its zero was never coverage." >&2
        ;;
      NO-FIXTURE)
        thin=$((thin + 1))
        echo "::error::elixir-path-escape-check: idiom '$pidiom' resolved 0 reads and has NO entry in ELIXIR_ESCAPE_IDIOM_FIXTURE — nothing distinguishes an unused idiom from a broken detector, so this run REFUSES rather than counting it as coverage. Add a fixture that its door must tag." >&2
        ;;
    esac
  done <<EOF
$(prove_idioms "$zero_idioms")
EOF
fi

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

# ---------------------------------------------------------------------------
# THE FAMILY ARM — a glob-consumed family must be dispatched WHOLE
# ---------------------------------------------------------------------------
# The census arm above proves every LITERAL an api test carries is declared.
# This one proves the layer under it: for every family a declared program
# enumerates from the tree, a member that IS NOT ON DISK must still match the
# test set. A probe member is the only honest way to ask — the incident was a
# file the set predated, and any path already in the tree would let a
# nine-file hand list answer correctly and prove nothing.
#
# MUTATION, both directions, run before this landed:
#   * remove `derived_family_globs` from set_globs and leave the nine
#     `scripts/pds-*` literals as the only coverage ->
#     "::error::... UNDECLARED glob-consumed family: scripts/pds-*.sh", exit 1.
#   * restore it -> "OK: 5 glob-consumed famil(ies) ... dispatched whole.",
#     exit 0.
# The producer (set_globs) and the checker (this loop) read the SAME
# derivation, which is deliberate: the failure mode that would hide — both
# halves deleted together — is caught one layer up by the `extractor` refusal,
# which exits 2 before any mode runs.
if [ "$ELIXIR_FAMILY_BLIND" = root ]; then
  family_blind_note
  echo "::error::elixir-path-escape-check: the ratchet runs against the real checkout; a family root with no declared program in it is a broken invocation, not a tree without families." >&2
  exit 2
fi

fam_uncovered=0
fam_n=0
while IFS= read -r fam; do
  [ -n "$fam" ] || continue
  fam_n=$((fam_n + 1))
  probe="$(family_probe_member "$fam")"
  if grep -Eq -- "$test_ere" <<<"$probe"; then
    continue
  fi
  fam_uncovered=$((fam_uncovered + 1))
  echo "::error::elixir-path-escape-check: UNDECLARED glob-consumed family: $fam" >&2
  echo "    a member that is not on disk ($probe) does NOT match the test path set" >&2
  while IFS= read -r fsrc; do
    [ -n "$fsrc" ] || continue
    fam_lines="$(family_enum_lines "$fsrc")"
    if grep -qF -- "$fam" <<<"$fam_lines"; then
      echo "    enumerated by: $fsrc" >&2
    fi
  done <<EOF
$ELIXIR_FAMILY_SOURCES
EOF
done <<EOF
$ELIXIR_FAMILY_GLOBS
EOF

if [ "$fam_uncovered" -gt 0 ]; then
  cat >&2 <<'MSG'

A program this script already declares enumerates a path FAMILY from the tree,
and the dispatcher does not dispatch on the whole family — only on the members
that happened to be named one at a time. The NEXT member added to that family
skips the Elixir suite and the required gate reports green over zero tests,
which is exactly what run 35532446963 did (task-ac7392fa242a09ef).

Fix: do NOT add the new file to ELIXIR_TEST_ONLY_PATHS. The families are
DERIVED — see derived_family_globs above. Restore the derivation instead.
MSG
  exit 1
fi

echo "elixir-path-escape-check: $fam_n glob-consumed famil(ies) derived from $ELIXIR_FAMILY_SOURCE_N declared program(s), all dispatched whole."

# ---------------------------------------------------------------------------
# THE UNSEEN-FORM ARM — say "I cannot resolve this", never nothing
# ---------------------------------------------------------------------------
# Everything above is a statement about reads the scanner RESOLVED. It has
# never been a statement about reads it could not. A path expression carrying
# no literal at the read site — `Path.expand(rel, __DIR__)`, or the
# `Path.expand("../../../" <> rel, __DIR__)` that opened
# task-c605ea24bbe5066c — produces the same output as a tree with no such site
# at all: silence, then `OK:`. A guard whose "I saw nothing" and "I cannot see"
# print identically is reporting a coincidence.
#
# So every such site is PRINTED, every run, pass or fail, and the `OK:` line is
# scoped to what was resolvable. A site whose operand has no static binding
# anywhere in its own file — nothing any door can reach — REFUSES: an
# unresolvable read reported as OK is the defect this arm exists to end.
unseen="$(unresolvable_sites)"
unseen_n="$(printf '%s\n' "$unseen" | sed '/^$/d' | wc -l | tr -d ' ')"
unseen_blind=0
if [ "$unseen_n" -gt 0 ]; then
  echo "elixir-path-escape-check: $unseen_n path expression(s) carry NO literal at the read site — the scanner CANNOT resolve these directly:"
  while IFS= read -r urow; do
    [ -n "$urow" ] || continue
    uf="${urow%%	*}"
    urest="${urow#*	}"
    uln="${urest%%	*}"
    urest="${urest#*	}"
    uop="${urest%%	*}"
    urest="${urest#*	}"
    uback="${urest%%	*}"
    ubase="${urest##*	}"
    if [ "$uback" = NONE ] && [ "$ubase" = dynamic ]; then
      echo "elixir-path-escape-check:   cannot see directly: $uf:$uln via '$uop' — and its BASE is a runtime value too, so this read has no static location at all. Not a repo-root escape claim either way; reported, not counted."
    elif [ "$uback" = NONE ]; then
      unseen_blind=$((unseen_blind + 1))
      echo "::error::elixir-path-escape-check: CANNOT SEE this read: $uf:$uln builds its path from '$uop', and nothing in that file binds '$uop' to a literal any door can reach. This read is NOT covered by the census above — it was never in it." >&2
    else
      echo "elixir-path-escape-check:   cannot see directly: $uf:$uln via '$uop' — reached instead through its $uback binding (the literals the doors DO see live there, not here)"
    fi
  done <<EOF
$unseen
EOF
fi

if [ "$unseen_blind" -gt 0 ]; then
  cat >&2 <<'MSG'

The Elixir suite reads path(s) this scanner cannot statically resolve, and the
census above says nothing about them. Historically that printed as OK — two
reads of js/packages/react/src/blocks/sheet.ts and
apps/mobile/src/papers/portabledoc/blocks/sheet.tsx sat undispatched-on inside
`OK: every repo-root read … is dispatched on.` (task-c605ea24bbe5066c).

Fix: spell the path out as a literal at the read site, or bind it to a module
attribute list the shape-8 door resolves. Do NOT widen this arm's greps to
make the site disappear — an unresolvable read is a fact about the code, and
the honest output is this refusal.
MSG
  exit 1
fi

echo "OK: every repo-root read from api/lib + api/test that this scanner can RESOLVE is dispatched on; $unseen_n site(s) it cannot resolve are named above."
