#!/usr/bin/env bash
#
# cloud-path-escape-check.sh — the Cloud skip-shim's path ratchet AND the single
# source of truth for the path set cloud.yml dispatches on.
#
# WHY THIS EXISTS
# ---------------
# cloud.yml used to carry a WORKFLOW-LEVEL `on: … paths:` filter. That shape is
# structurally unrequirable: a workflow-level paths filter emits NO check run at
# all on a non-matching PR, and a required context that is ABSENT reports
# "expected" forever — it deadlocks the merge instead of gating it (honest-gates
# D18, re-measured this wave as D89). So the filter moves DOWN, from the
# workflow trigger to job-level `if:` conditions fed by an always-running
# dispatcher, exactly as elixir.yml does. Then, and only then, can an aggregator
# name over this workflow become a required status check.
#
# A job-level skip is only honest while the declared path set is a SUPERSET of
# everything the gated jobs actually read. The Cloud suite reads outside
# `cloud/**`: it byte-compares a Go fixture and it `Code.require_file`s a repo
# root script. Miss one of those and a PR editing it SKIPS the only gate that
# checks it — and the skip reports GREEN.
#
# So: this script re-derives the escape census from the working tree on every
# run and FAILS when a resolved repo-root read is not covered by the declared
# set below. Adding a new cross-tree read without widening the dispatcher is a
# red, not a silent hole.
#
# HOW AN ESCAPE IS RESOLVED
# -------------------------
# Every relative-path read in cloud/lib and cloud/test is resolved against
# BOTH bases the codebase actually uses:
#   * the file's own directory   — the `Path.expand("../x", __DIR__)` idiom
#   * `cloud/`                   — the `mix test` cwd idiom (File.read!("../x"))
# Anything landing inside cloud/ is not an escape. Anything landing outside
# cloud/ AND existing on disk is a repo-root read the dispatcher must cover.
#
# A "read" is recognised in THREE authoring forms, not one (cch-w53). The census
# used to extract exactly `grep -Eoh '"\.\./[^"]*"'`, which made the ratchet
# evadable BY AUTHORING STYLE ALONE — measured on origin/main:
#
#     Path.expand("../../../internal/provisioner", __DIR__)     -> exit 1,
#         `::error::… UNCOVERED repo-root read: internal/provisioner`
#     Path.join([__DIR__, "..", "..", "..", "internal", "provisioner"])
#         -> exit 0, `OK: every repo-root read … is dispatched on`,
#            census UNCHANGED
#
# The two resolve to the IDENTICAL directory. The second one is the shape this
# whole shim exists to stop: a Cloud test reading a repo-root path the
# dispatcher does not dispatch on, so a PR touching that path SKIPS the only
# suite that checks it and reports green — while the ratchet says OK. And the
# split idiom is LIVE in this tree (billing_client_mirror_test.exs,
# sold_capability_manifest_test.exs, site_read_token_revoke_test.exs,
# notifications/transport_manifest_test.exs), so it is not a hypothetical style.
#
# So all three forms feed ONE resolver:
#   1. `"../…"`  — the double-quoted literal (also covers `~c"../…"`, `~S"../…"`)
#   2. `'../…'`  — the charlist literal; Path/File take charlists, and the
#                  double-quote grep cannot see one. Measured cost on this tree:
#                  zero occurrences, so this arm adds nothing to the census
#                  today and closes the form before it is used.
#   3. a SEGMENT LIST — a run of comma-separated string literals containing a
#      bare `".."` element, re-joined with `/`. `[__DIR__, "..", "..", "x"]`
#      becomes `../../x` and is then resolved exactly like form 1. The run may
#      span newlines (a formatted list puts one segment per line) and ends at
#      the first separator that is NOT a comma — which is what stops
#      `Path.join([__DIR__, ".."]) == "some/other/thing"` from swallowing the
#      right-hand side. A run of one element is dropped: a lone `".."` resolves
#      to the parent of a cloud/ directory, i.e. never outside cloud/.
#
# COST, measured rather than assumed: forms 2 and 3 share ONE awk pass per file,
# so the scan goes from one subprocess per file to two. Over the 388 files in
# cloud/lib + cloud/test that is ~2.5s -> ~4.5s of wall clock on the unfiltered
# `path-escape` job. The census itself is UNCHANGED on this tree — 15 distinct
# repo-root reads before and after, floor still 6, no new declaration and no
# baseline raised. The only new census ROW is a second reader for the already
# EXEMPT docker-compose.yml phantom (billing_client_mirror_test.exs, which
# carries no `"../…"` literal at all and was therefore invisible before).
#
# RESIDUE, named rather than left to be found: a path assembled by CHAINED
# calls — `Path.join(__DIR__, "..") |> Path.join("internal/provisioner")` — is
# still invisible, because the two literals are not comma-adjacent. Closing that
# needs an expression evaluator, not a scanner. The forms above are the ones the
# tree actually uses; a chained read is a new shape and gets a new arm.
#
# The existence filter is what keeps the traversal-attack and 404-fixture
# literals (`"../../etc"`, `"../timeout/index.html"`, `"../up"`) out of the
# census: they are asserted on or served as static assets, never read across the
# tree. It is also why the enumeration walks the WORKING TREE.
#
# The existence filter has ONE cost, and it is paid by a separate arm rather
# than by weakening the filter: a declared producer that is RENAMED stops
# resolving, so its census row leaves in silence. See THE DECLARATION-LIVENESS
# ARM below — every CLOUD_PATHS entry must name something that exists, which is
# the question the census structurally cannot ask.
#
# NOT `git ls-files` (honest-gates D31): a prototype that enumerated via git
# reported "OK: every repo-root read is covered" and exited 0 with the mutation
# fixture sitting on disk UNTRACKED — a textbook vacuous pass of exactly the
# class this ratchet exists to remove. The harness carries an untracked case.
#
# USAGE
#   cloud-path-escape-check.sh                 # the ratchet (CI + the gate)
#   cloud-path-escape-check.sh --selftest      # run the harness
#   cloud-path-escape-check.sh --list-escapes  # print the resolved census
#   cloud-path-escape-check.sh --print-set cloud
#   cloud-path-escape-check.sh --match cloud   # changed paths on stdin
#                                              # -> prints true|false
#
# `--print-set` / `--match` are consumed by the cloud.yml dispatcher, so the
# workflow and this ratchet can never disagree about what the path set is.

set -euo pipefail

# ---------------------------------------------------------------------------
# THE DECLARED PATH SET (ONE set — cloud.yml has no compile/test split: both
# jobs compile the same app, and `test` additionally needs Postgres)
# ---------------------------------------------------------------------------
# Glob grammar, deliberately tiny: `dir/**` = that directory and everything
# under it; anything else = one exact file path. No other wildcards.
#
#   cloud/**                the app under gate
#   .github/workflows/**    a change to the shim — or to any workflow the
#                           censuses read — runs the suite
#   scripts/**              likewise for the ratchet itself, and for every
#                           script the caller corpus walks
#
# The two cross-tree entries are MEASURED reads, not guesses (see
# --list-escapes):
#   internal/cli/cloud/providers_capabilities.json
#       cloud/test/…/providers_capabilities_contract_test.exs Path.expand()s the
#       Go fixture and asserts BYTE EQUALITY against the served JSON. Edit the
#       Go side alone and, unfiltered, the contract test never runs.
#   scripts/async_env_seam_scan.exs — RULING KEPT, ENTRY FOLDED into
#       `scripts/**` below. cloud/test/…/async_global_seam_guard_test.exs
#       Code.require_file()s the scanner and drives it. The scanner IS the code
#       under test there, so this is still a MEASURED read; it is no longer a
#       separate line because the directory glob already dispatches on it.
#   internal/cloudclient/** — dr-w10-s4.
#       cloud/test/…/payload_key_set_census_test.exs reads the Go package's
#       `json:"…"` struct tags and censuses them AGAINST the Elixir serializers'
#       emitted key sets, in both directions. The Go side is half the contract,
#       so a Go-only edit is a change to the thing under test: adding a struct
#       field there without an emitter, or deleting one that had an emitter,
#       moves the census — and unfiltered, the census would never run on the PR
#       that moved it. Declared as a DIRECTORY because the census reads the whole
#       package (every non-test .go), not one pinned file.
#   internal/provisioner/** — cch-w53-s2.
#       cloud/test/…/web/claim_payload_manifest_test.exs censuses the claim
#       payloads the control plane RETURNS on the worker-token claim routes
#       against the `json:"…"` tags reachable at each `json.Unmarshal` call site
#       in this package. Go's encoding/json DISCARDS an unmodelled key in
#       silence, and DisallowUnknownFields appears zero times here — so a key
#       the plane ships and the worker has no field for is dropped with no
#       error, no log line and no other failing test. The Go side is half that
#       contract: deleting a JobSpec field, moving a decode site, or changing a
#       field's TYPE moves the census, and unfiltered the census would never run
#       on the PR that moved it. Declared as a DIRECTORY, exactly like
#       internal/cloudclient/** above and for the same reason — the manifest
#       reads the whole package (every non-test .go), not one pinned file, and
#       the tolerated-dialect decode it depends on is an INLINE anonymous struct
#       that no per-file pin would survive a move of. Cost measured over the last
#       60 days: 48 commits touched internal/provisioner, 24 of which already
#       dispatch this set, so 24 newly dispatch it — affordable against the
#       47-of-54 that got `templates/**` REFUSED (D270).
#
# js/packages/create-barkpark-app/templates/** is the VENDORED-TEMPLATE DRIFT
# TRIPWIRE, inherited verbatim from the workflow-level filter this shim
# replaces: cloud/priv/templates/** is a COPY of those templates
# (`make cloud-templates-sync`) guarded by AppFilesDriftTest in the `test` job.
# Editing the SOURCE must run that guard on THIS PR — else the sync is skipped
# and drift lands (the #963→#969 class). It is ALSO a measured escape.
#
# DELIBERATELY NOT DECLARED — api/test/**. scripts/async_env_seam_scan.exs
# derives `default_roots/0` at RUNTIME as [<repo>/cloud/test, <repo>/api/test],
# so an api/test/** edit can in principle change what that scanner reports. It
# is NOT declared, on purpose: an api/test/** trigger would run the whole Cloud
# Elixir suite plus a Postgres service on every api-only PR — the shim would
# cost precisely what it exists to save. That refusal was RE-MEASURED, not
# inherited: see THE WIDENING below, where `api/**` was built, costed at 1438
# newly-dispatching commits over 60 days, and held. The SCANNER is declared
# instead, which covers every change to the scanning logic itself; what remains
# uncovered is a new api/test fixture that the scanner would newly flag. That
# residue is named here rather than left for a reader to discover.
#
# deploy/site-deploy.sh — cch-w27-s2. `sites_deploy_stage_caption_test.exs`
# DERIVES its corpus from the box engine rather than typing it: it reads the
# FATAL line `build_failure_reason()` greps first and asserts the preview fixture
# in `scenarios.mjs` still equals it. That is deliberate (a hand-authored failure
# string is how a rail guard ends up green by construction), and it makes the
# engine a real dependency of the Cloud suite — an edit to that line must re-run
# this suite, or the fixture and its producer drift apart behind a green check.
#
# DELIBERATELY NOT DECLARED — internal/cli/**. dr-w18-s4's empty-audience census
# (`deploy_signal_audience_census_test.exs`) derives each deploy-health signal's
# audience from Go SOURCE, and it reads `internal/cloudclient/**` ONLY, which is
# already declared above. It could have read `internal/cli/cloud_status_cmd.go`
# or `cloud_deploy_census_cmd.go` instead — and that would have been a guard
# publishing a GREEN required context on every PR where it never ran, because the
# dispatcher returns false for `internal/cli/**`. The choice was to keep the
# guard's reads inside the already-declared package rather than widen the set:
# `internal/cli/**` would hand every Go CLI edit the full Postgres-backed Cloud
# suite, and listing individual reader files rots the moment a reader moves. No
# extra rule enforces this — the ratchet below already does: a census read of an
# undeclared repo-root file is an `UNCOVERED repo-root read` and exit 1.
#
# internal/caddyfile/caddyfile.go — cch-w56-s2. `promise_actor_manifest_test.exs`
#     resolves the console's "Custom domains with automatic TLS" promise as
#     `{:external_armed_here, …}`: the renewing actor is Caddy's own binary, and
#     the only thing this tree can prove is that it ARMS it — the rendered
#     Caddyfile carries `on_demand_tls { ask … }`. That assertion is an equality
#     against THIS FILE's bytes, so an edit to it is an edit to the thing under
#     test; undeclared, the row would publish green on the very PR that
#     disarmed the promise. Declared as an EXACT FILE, never `internal/**` or
#     `internal/caddyfile/**` (D270): measured over the last 60 days / 4663
#     commits on main, this file appears in 8 newly-dispatching commits, against
#     145 for `.github/workflows/**` and 76 for `deploy/**`. Directories are
#     unaffordable at that ratio; exact files are nearly free.
#
# templates/astro-search-starter/src/lib/bp.ts — dr-w16-s1.
# templates/search-starter/lib/markers.corpus-status.test.ts — dr-w16-s1.
#     `deploy_ledger_test.exs` reads these TWO repo-root starter files and
#     censuses the deploy markers they PRODUCE against the ledger's parser. They
#     are the producer half of that contract, so an edit to either is a change to
#     the thing under test — unfiltered, the census would never run on the PR
#     that moved it. Declared as EXACT FILES, not `templates/*/**` (D270): the
#     tests read exactly these two files, and the directory glob is the expensive
#     shape. Measured over the last 60 days — 54 commits touched `templates/`; of
#     those, 47 dispatch nothing in this set today and a templates glob would
#     newly hand every one of them the Postgres-backed Cloud `test` job, against
#     5 for the exact files. Declaring what is actually read is both the honest
#     and the cheap answer; widen only when a test starts reading more.
#
# THE CALLER CORPUS — dr-w26-s4. `payload_key_set_census_test.exs`'s caller arm
# scores every `/v1/internal/**` WRITE route against a POSITIVELY declared caller
# corpus: it walks `.github/workflows/deploy.yml`, `scripts`, `internal`,
# `cloud/lib` and `deploy`, and reds when a write route ships with no caller in
# any of them. Those are whole-directory reads, so the honest declaration is a
# whole-directory glob — an exact-file pin rots the moment a caller moves one
# file over, and the arm would then report "caller-less" about a route that IS
# called: a FALSE RED that reads exactly like the true one.
#
#   internal/**  supersedes the four exact `internal/…` entries below. They are
#       KEPT, redundantly, because each carries its own ruling and deleting a
#       ruling to save a line is how a set stops explaining itself. The cost is
#       the real one: this is the `internal/cli/**` widening refused above on
#       CI-cost grounds, and dr-w26-s4 overrules that refusal for the caller arm
#       — internal/cli IS where `bp cloud` calls the worker seam, so refusing it
#       would make the corpus lie about which routes have callers. The refusal
#       was a COST decision; borrowing it as a caller-corpus decision was the
#       category error.
#   deploy/**    likewise supersedes the two `deploy/site-deploy*.sh` entries.
#   cloud/lib/** is REDUNDANT under `cloud/**` and is declared anyway, so that
#       every root the arm walks appears here BY NAME. The arm asserts exactly
#       that, which is what turns this block from a voluntary note into
#       something that can lose: delete a root here and the Cloud suite reds.
#   .github/workflows/deploy.yml — RULING KEPT, ENTRY FOLDED into
#       `.github/workflows/**` below. It is the workflow the arm reads (the
#       recorder seam), and before it was declared at all a deploy.yml-only PR
#       dispatched NOTHING in this set: the recorder could land, or vanish, with
#       no code gate at all. It was declared as an EXACT FILE on the D270 cost
#       argument and because the harness pinned exact-entry semantics THROUGH
#       it; both of those are gone (see THE WIDENING below), and the arm walks
#       the whole `.github/workflows` directory, so the honest declaration is
#       the directory.
#
# internal/cli/cloud/dns.go, internal/cli/cloud/dns_cloud.go —
# dr-w22-bl-internal-cli-trips-zero-required-gates. These two CLI-side DNS
# readers EMIT the step errors that `FailureCopy.@dns_step` classifies, and
# `scripts/cli-dns-step-vocabulary-check.sh` (wired into cloud.yml's UNFILTERED
# `path-escape` job, already in `Cloud gate`'s `needs:`) derives the verb
# vocabulary from their `fmt.Errorf` bytes and asserts it equals the classifier's
# alternation, both directions. That makes them INPUTS to a Cloud-gate
# assertion: rename a verb there and the console starts calling a DOMAIN failure
# a SERVER-CAPACITY one.
#
# THEY ARE REDUNDANT UNDER `internal/**` ABOVE, AND DECLARED ANYWAY, for the
# same reason the four exact `internal/…` entries below are kept: the dispatch
# claim and the ruling that earns it live together, and a set that stops
# explaining itself is one deletion from a hole. THE COST IS ZERO, MEASURED, not
# asserted: `internal/**` (dr-w26-s4) already matches every path under
# internal/, so these two lines newly dispatch NOTHING. Over the last 60 days 3
# commits touched these two files, and all 3 already dispatched `cloud=true`
# through `internal/**`. If `internal/**` is ever narrowed, these lines are what
# keeps the vocabulary pin's own inputs dispatched — which is the case they are
# really written for.
#
# EXACT FILES, never `internal/cli/cloud/**` (D270). The guard reads the two
# files that emit a `hetzner dns …` / `hcloud zone rrset …` prefix and nothing
# else in that package; the directory glob would bill the CLI epic for edits the
# vocabulary pin cannot see, and the guard's own `--list` prints the census that
# says which files those are.
#
# cloud/priv/audit-actions.json — cch-w69-s1. The audit verb table, REDUNDANT
# under `cloud/**` and declared anyway, by name, because it used to live at
# design/audit-actions.json as a declared cross-tree read: audit_event.ex
# compile-time-read it from cloud/lib, which this ratchet COVERED (dispatch-wise)
# while the control-plane image — built from cloud/ alone — could never contain
# it, and every cp deploy failed at `mix compile` (D841/D842). The move into
# cloud/priv is what fixed that, this line keeps the table's dispatch story
# explicit, and the cloud/lib-reader arm below is what makes the design/-era
# shape FATAL rather than covered.
#
# THE WIDENING — dr-w26-s4-followup-widen-escape-harness. Two directory globs
# replace what used to be four exact files plus a written-down hole:
#
#   scripts/**            THE CALLER CORPUS walks the whole `scripts` directory.
#   .github/workflows/**  …and the whole `.github/workflows` directory.
#       Represented by exact files, both roots dispatched only on the handful of
#       paths that happened to be named: a caller added in a NEW scripts/ file,
#       or in a workflow other than deploy.yml, did not itself re-run the arm
#       that scores it. The direction was safe (a LATE red, never a false green)
#       and it was still a hole — the corpus walks a DIRECTORY, so the honest
#       declaration is a directory glob. An exact-file pin also rots the moment a
#       caller moves one file over, and the arm then reports "caller-less" about
#       a route that IS called: a FALSE RED that reads exactly like the true one.
#       What used to block this: the harness pinned exact-entry prefix semantics
#       THROUGH `scripts/async_env_seam_scan.exs.orig` and
#       `.github/workflows/cloud.yml.bak`, so either glob turned case 6 red. Those
#       probes now run on a synthetic set under `docs/prefix-probe/` that no
#       widening can reach, which is what unblocked this line.
#
# THE COST OF THIS HALF, measured on this tree rather than assumed: over the last
# 60 days / 5008 commits on main, these two globs newly dispatch 957 commits
# (scripts/** 656, .github/workflows/** 301). D270 costed `.github/workflows/**`
# at 145 newly-dispatching commits per 60 days; re-measured here it is 301, so
# that figure was low by roughly a factor of two and the ratio it argued from
# should not be re-used without re-measuring.
#
# RESIDUE, named rather than left to be found — api/**, web/**, js/** are
# DELIBERATELY NOT DECLARED. `reader_less_instrument_census_test.exs`'s
# `ReaderScan.roots/0` is five trees — internal, cloud/priv/static, web, js, api.
# Two are covered (`internal/**`, and cloud/priv/static under `cloud/**`); the
# other three are not, so a commit that ADDS a reader in api/, web/ or js/ — the
# ROT direction, the GOOD direction — does not re-run the census that would
# delete the stale row, and the red lands on some later cloud-touching commit.
#
# The three globs WERE built and costed on this tree before being held: they move
# dispatch from 1641 to 3874 of 5008 commits over 60 days, i.e. 33% -> 77% of all
# commits running the Postgres-backed Cloud `test` job, with `api/**` alone
# accounting for 1438 of the 2233 newly-dispatching commits. D270's numbers are
# an order of magnitude under that. Paying it here is the wrong SHAPE, not merely
# the wrong price: the reader census does not need the whole Cloud suite
# dispatched on an api-only PR, it needs ITSELF dispatched. So the remedy is
# re-filed for the gates lane as a job-level path condition on that one test plus
# a census-only tier in this script — re-filed for gates 2026-09-10. Until that
# lands the gap is real, the direction is safe, and the measurement is written
# down here so nobody re-derives it and reaches the same dead end.
CLOUD_PATHS='cloud/**
cloud/lib/**
.github/workflows/**
cloud/priv/audit-actions.json
deploy/**
deploy/site-deploy.sh
deploy/site-deploy-node.sh
internal/**
internal/caddyfile/caddyfile.go
internal/cli/cloud/dns.go
internal/cli/cloud/dns_cloud.go
internal/cli/cloud/providers_capabilities.json
internal/cloudclient/**
internal/provisioner/**
api/test/support/totp_test_helper.ex
api/lib/barkpark_web/controllers/site_deploy_controller.ex
api/test/support/fixtures/box_capacity_refusal.json
js/packages/create-barkpark-app/templates/**
scripts/**
templates/**
templates/astro-search-starter/src/lib/bp.ts
templates/search-starter/lib/markers.corpus-status.test.ts'

# EXEMPT — census rows that resolve to a real repo-root file but are NOT a
# repo-root DEPENDENCY. Two shapes qualify, and nothing else does:
#   1. the read is unreachable from the default `mix test` lane (an excluded tag);
#   2. the row is an artefact of the SECOND resolution base. Every literal is
#      resolved against both the file's own dir AND `cloud/`, because both idioms
#      are in use; for a literal anchored explicitly to `__DIR__` the `cloud/`
#      resolution is not a read that can happen, and if it happens to land on an
#      existing repo-root file it is a phantom.
# Each line is `<path><TAB><why>`; an entry without a reason is a bug. Keep this
# list at zero-growth: the honest fix for a new cross-tree read is to declare it
# above, not to exempt it — and a shape-2 exemption is only honest while the
# literal's REAL target is itself covered by the declared set.
CLOUD_ESCAPE_EXEMPT='docker-compose.yml	shape 2 — notifications_platform_admin_env_test.exs:189 reads Path.join(__DIR__, "../../docker-compose.yml"), and billing_client_mirror_test.exs reads the same file in the SEGMENT-LIST form [__DIR__, "..", "..", "docker-compose.yml"] (visible since cch-w53). Both are cloud/docker-compose.yml, covered by cloud/**. The repo-root file of the same name is reached only by the `cloud/` cwd base, and that base does not apply to a __DIR__-anchored read.'

# The census floor — a LOWER BOUND, not a headcount. It was set from a
# population of 6 resolved repo-root reads (the population only grows): the
# two cross-tree reads above, the vendored-template directory, the one EXEMPT
# phantom above, (cch-w27-s2) the box engine `deploy/site-deploy.sh` that
# `sites_deploy_stage_caption_test.exs` derives its failure corpus from, and
# (dr-w10-s4) `internal/cloudclient/` that `payload_key_set_census_test.exs`
# reads the decoder half of the payload contract from; the floor is 6.
# Its job is to catch a NEUTERED SCANNER:
# a regex or find that silently stopped matching would otherwise report "0
# uncovered reads" and exit 0 — clean-looking, and completely blind.
#
# It is set CLOSE to the population, not far under it, because the population is
# small: a floor of 1 here would let two thirds of the scanner die unnoticed. It
# was originally set EQUAL to the then-population of 6, and that equality is
# history, not a rule — as producer reads are declared the population grows past
# it and the floor stays put.
#
# THE FIXTURE USED TO CAP THIS NUMBER, and no longer does
# (dr-w16-bl-widen-escape-fixture-then-raise-floor). dr-w16-s1 measured that the
# harness's synthetic fixture emitted only FIVE covered reads, so raising the
# floor to 7 turned a clean "158 passed, 0 failed" into "152 passed, 6 failed"
# on the fixture-tree cases — the floor could not follow the population, and at
# 6 against a population of 20 the scanner could have lost FOURTEEN of twenty
# reads with this check still passing. The fixture now DERIVES its population
# from `--print-set cloud` (one materialised path and one covered read per
# declared cross-tree entry, forms alternating quoted/segment-list), which puts
# it at 22 and makes it grow with CLOUD_PATHS instead of pinning the floor.
#
# So the floor is now the MEASURED population, 20, re-measured on this tree by
# `--list-escapes | cut -f1 | sort -u | wc -l` and not remembered from a comment.
# The ORDER matters and cannot be reversed: widen the fixture, then raise the
# floor in the same commit. Raising it first reds the harness for a reason that
# has nothing to do with the tree.
#
# It stays a LOWER BOUND, not a headcount: the population only grows as producer
# reads are declared, and a legitimate new escape does not have to raise it. But
# it is now set CLOSE enough that losing a single row is a red rather than
# slack. The harness's own fixture sits at 22, two above, so a fixture case that
# reds on the floor is telling you the SCANNER lost reads — which is exactly the
# discrimination case 12's not_floor() arms are built on.
#
# It is a CONSTANT on purpose. An env-var override would be a one-line CI bypass
# of the only check that can tell "clean" from "blind", and the harness asserts
# that setting CLOUD_ESCAPE_MIN changes nothing.
CLOUD_ESCAPE_MIN=20

# CLOUD_PATH_ESCAPE_ROOT retargets the scan at a synthetic fixture tree; the
# harness is its only caller. It cannot weaken a real run — pointing it at the
# repo gives the identical verdict.
REPO_ROOT="${CLOUD_PATH_ESCAPE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

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
# other polarity of a future caller, skipping it). Ported verbatim from
# scripts/elixir-path-escape-check.sh, where the harness caught exactly that.
assert_set_name() {
  case "$1" in
    cloud) ;;
    *)
      echo "cloud-path-escape-check: unknown path set '$1' (want cloud)" >&2
      exit 2
      ;;
  esac
}

set_globs() {
  assert_set_name "$1"
  case "$1" in
    cloud) printf '%s\n' "$CLOUD_PATHS" ;;
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
    echo "cloud-path-escape-check: path set '$1' resolved to an empty pattern" >&2
    exit 2
  fi
  printf '%s' "$out"
}

# SEGMENT-LIST READS (cch-w53) — the same directory, authored differently.
# Prints one synthesised `../…`-style literal per line for each run of
# comma-separated string literals that contains a bare `".."` element. See
# "HOW AN ESCAPE IS RESOLVED" at the top for why this exists and what it costs.
#
# Line-oriented on purpose: slurping a whole file and walking it with
# match()/substr() is quadratic, and cloud/lib/barkpark_cloud/web/router.ex is
# ~12k lines. The `gap` accumulator carries the between-token text ACROSS the
# newline, so a run survives a formatted list and still breaks on any separator
# that is not a comma.
# The charlist form rides the SAME awk rather than a second `grep -Eoh`: this
# runs once per file over 388 files, and a third subprocess each costs about a
# second and a half of an unfiltered CI job for nothing. The single-quote regex
# is built with sprintf("%c", 39) so the whole program stays single-quotable in
# bash.
alt_form_literals() {
  awk '
    BEGIN { q = sprintf("%c", 39); clre = q "\\.\\./[^" q "]*" q }
    function flush() {
      if (dotdot && n >= 2) print run
      run = ""; n = 0; dotdot = 0
    }
    {
      rest = $0
      while (match(rest, /"[^"]*"/)) {
        gap = gap substr(rest, 1, RSTART - 1)
        tok = substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
        if (n > 0 && gap !~ /^[ \t\r\n]*,[ \t\r\n]*$/) flush()
        run = (n == 0) ? tok : run "/" tok
        n++
        if (tok == "..") dotdot = 1
        gap = ""
      }
      gap = gap rest "\n"

      # form 2, independent of the run state above: a charlist literal.
      tail = $0
      while (match(tail, clre)) {
        print substr(tail, RSTART + 1, RLENGTH - 2)
        tail = substr(tail, RSTART + RLENGTH)
      }
    }
    END { flush() }
  ' "$1"
}

# ---------------------------------------------------------------------------
# the census
# ---------------------------------------------------------------------------
# Prints one resolved repo-root path per line, `<path><TAB><source-file>`.
list_escapes() {
  local f lit base resolved d lits sources
  # WORKING TREE enumeration (D31) — `find`, never `git ls-files`. An untracked
  # .exs on disk is code the suite will run, so it is code this ratchet must see.
  sources="$(cd -- "$REPO_ROOT" && find cloud/lib cloud/test -type f \( -name '*.ex' -o -name '*.exs' \) 2>/dev/null | LC_ALL=C sort)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # THREE authoring forms, ONE resolver (cch-w53) — see the header. Collected
    # into one variable rather than piped, so nothing downstream can take
    # SIGPIPE and no arm can go quietly empty behind a pipefail.
    lits="$(
      grep -Eoh '"\.\./[^"]*"' "$REPO_ROOT/$f" || true
      alt_form_literals "$REPO_ROOT/$f"
    )"
    [ -n "$lits" ] || continue
    while IFS= read -r lit; do
      lit="${lit%\"}"
      lit="${lit#\"}"
      lit="${lit%\'}"
      lit="${lit#\'}"
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
      d="$(dirname -- "$f")"
      for base in "$d" "cloud"; do
        resolved="$(norm_path "$base/$lit")"
        [ -n "$resolved" ] || continue
        # inside cloud/ is not an escape
        case "$resolved" in cloud | cloud/*) continue ;; esac
        # Only reads that can actually happen: a literal resolving to nothing on
        # disk is a traversal fixture or a static 404 path, not a dependency.
        [ -e "$REPO_ROOT/$resolved" ] || continue
        printf '%s\t%s\n' "$resolved" "${f#./}"
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
  done <<<"$CLOUD_ESCAPE_EXEMPT"
  return 1
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

mode="${1:---check}"

case "$mode" in
  --print-set)
    assert_set_name "${2:?--print-set needs cloud}"
    set_globs "$2"
    exit 0
    ;;

  --match)
    # changed paths on stdin -> `true` if ANY of them is in the named set.
    # This is what cloud.yml dispatches on, so the workflow and the ratchet
    # can never disagree about what the path set contains.
    want="${2:?--match needs cloud}"
    assert_set_name "$want"
    ere="$(set_ere "$want")"
    if grep -Eq -- "$ere"; then
      echo "true"
    else
      echo "false"
    fi
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
    exec bash "$(dirname -- "${BASH_SOURCE[0]}")/cloud-path-escape-check.test.sh"
    ;;

  --check) ;;

  *)
    echo "cloud-path-escape-check: unknown argument '$mode'" >&2
    echo "usage: $0 [--check|--selftest|--list-escapes|--print-set SET|--match SET]" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# --check: the ratchet
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# THE DECLARATION-LIVENESS ARM (dr-w16-bl-escape-census-is-existence-filtered)
# ---------------------------------------------------------------------------
# The census is EXISTENCE-FILTERED by design: list_escapes drops any literal
# whose resolved path is not on disk, because that is what keeps the traversal
# fixtures (`"../../etc"`, `"../up"`) and the 404 static paths out of it. The
# price of that filter is paid HERE, not there: RENAME a declared producer file
# and its literal stops resolving, the read leaves the census in silence, and
# every other arm still says OK.
#
#   * the coverage arm only ever asks "is this census row declared?" — a row
#     that VANISHED is never asked about;
#   * the floor only catches a scanner that dies WHOLESALE. Measured on this
#     tree the floor was 6 against a population of 20, so fourteen rows could
#     disappear one at a time and the floor still passed. Raising the floor to
#     the population (the same wave's other half) narrows that to zero slack —
#     but it still cannot tell you WHICH row went, or that a DECLARATION died;
#   * and the CLOUD_PATHS entry that named the renamed file becomes dead text —
#     it dispatches on a path nothing in the repo has any more, so the suite
#     that actually reads the NEW name is no longer dispatched by it.
#
# So the declaration is checked in the OTHER direction: every entry in
# CLOUD_PATHS must name something that exists. An exact entry must be a real
# path; a `dir/**` entry must be a real directory. That is the check the census
# structurally cannot make — the census can only see what is still there.
#
# It runs FIRST, before the census is even taken, for two reasons: a dead
# declaration EXPLAINS a shrunken census, so reporting the floor first would
# hand a reader the symptom instead of the cause; and the arm's verdict is then
# independent of how many reads the tree happens to hold, which is what lets the
# harness prove it against a fixture without also having to clear the floor.
#
# It resolves against the DECLARATION's own repository — the parent of this
# script — NOT against $REPO_ROOT. CLOUD_PATH_ESCAPE_ROOT retargets the CENSUS
# (which cloud/ tree to scan); CLOUD_PATHS is fixed text inside this file making
# a claim about the tree this file lives in, and checking that claim against a
# synthetic fixture would be checking it against something it never described.
# The harness proves the arm the honest way instead: it runs a COPY of this
# script from inside a fixture repo, so the copy's own parent IS the fixture.
DECL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dead_declarations=0
while IFS= read -r g; do
  [ -n "$g" ] || continue
  case "$g" in
    */'**')
      [ -d "$DECL_ROOT/${g%/**}" ] && continue
      dead_declarations=$((dead_declarations + 1))
      echo "::error::cloud-path-escape-check: DEAD DECLARATION: '$g' names a directory that does not exist" >&2
      ;;
    *)
      [ -e "$DECL_ROOT/$g" ] && continue
      dead_declarations=$((dead_declarations + 1))
      echo "::error::cloud-path-escape-check: DEAD DECLARATION: '$g' names a path that does not exist" >&2
      ;;
  esac
done <<EOF
$(set_globs cloud)
EOF

if [ "$dead_declarations" -gt 0 ]; then
  cat >&2 <<'MSG'

A CLOUD_PATHS entry names a path that is not in the tree. The usual cause is a
RENAME: the declared producer moved, the Cloud test that reads it now resolves
to nothing, its census row disappeared without a red (the census is
existence-filtered), and this declaration now dispatches on a path no file has.

Fix: point the declaration at the file's new name — and check that whatever read
it (the reason the ruling above it was written) still reads it. If the read is
genuinely gone, delete the declaration AND its ruling in the same edit.
MSG
  exit 1
fi

census="$(list_escapes | sort -u || true)"
paths="$(printf '%s\n' "$census" | cut -f1 | sort -u | sed '/^$/d')"
count="$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l | tr -d ' ')"

echo "cloud-path-escape-check: scanning \$REPO_ROOT=$REPO_ROOT"
echo "cloud-path-escape-check: $count distinct repo-root read(s) resolved from cloud/lib + cloud/test"

# FAIL-CLOSED on a neutered scanner. "Nothing found" is never good news here.
#
# BUT THE RED HAS TWO CAUSES AND THIS BRANCH CANNOT SEE WHICH
# (dr-w17-bl-escape-floor-cannot-lose-in-either-direction). A population under
# the floor is EITHER a scanner that went blind on an unchanged tree OR a
# cross-tree read that was legitimately DELETED — a retired producer-reading
# test drops the population with nothing wrong anywhere. The message below must
# therefore name BOTH, and must not tell an operator with a perfectly clean repo
# to go hunt a bug in list_escapes. The harness pins that (case 5).
if [ "$count" -lt "$CLOUD_ESCAPE_MIN" ]; then
  echo "::error::cloud-path-escape-check: only $count repo-root read(s) found, floor is $CLOUD_ESCAPE_MIN." >&2
  echo "  TWO CAUSES PRODUCE THIS RED, and this check cannot tell them apart. Do not" >&2
  echo "  assume the first one just because it is the one the floor was built for:" >&2
  echo "  1. THE SCANNER IS NEUTERED. A grep or find inside list_escapes stopped" >&2
  echo "     matching, so reads that still exist are no longer seen. The tree is" >&2
  echo "     unchanged and the instrument went blind. Read list_escapes first." >&2
  echo "  2. A CROSS-TREE READ WAS DELETED. A producer-reading test was retired, a" >&2
  echo "     fixture removed, a declaration dropped — and the population really is" >&2
  echo "     smaller. THAT IS LEGITIMATE and the repo is fine. The remedy is to lower" >&2
  echo "     CLOUD_ESCAPE_MIN to the new population in the SAME commit that removed" >&2
  echo "     the read, naming which read went. It is never to work around this error." >&2
  echo "  TELL THEM APART: run --list-escapes and diff it against the last green run." >&2
  echo "  Rows that vanished while their readers still exist => cause 1. Rows whose" >&2
  echo "  readers are gone from the tree => cause 2." >&2
  echo "  The floor is a LOWER BOUND. It is not the population, and being under it is" >&2
  echo "  not by itself proof that anything is broken." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# the cloud/lib reader arm (cch-w69-s1) — a DISTINCT failing arm, not coverage
# ---------------------------------------------------------------------------
# The coverage arm below answers "does cloud.yml dispatch on this read?" — and
# that question is the WRONG one for a reader under cloud/lib/, which is why
# this arm runs FIRST: a covered-and-declared read must still die here, and an
# undeclared one must red as THIS failure, not as a missing-declaration red that
# invites declaring it. cloud/lib is compiled
# INTO the control-plane image, and that image builds from cloud/ alone
# (cloud/docker-compose.yml `build: .`; the Dockerfile COPYs only mix.exs
# mix.lock config lib priv). A repo-root read from cloud/lib therefore compiles
# clean locally and in CI, can be fully DECLARED here — and still detonates at
# image-build `mix compile`, where the file does not exist. Exactly that shipped
# in #11723: audit_event.ex compile-time-read design/audit-actions.json, the
# path was in CLOUD_PATHS, everything was green, and every cp deploy failed with
# `could not read file "/design/audit-actions.json"` (D841/D842).
#
# So: any census row whose READER is under cloud/lib/ is FATAL, covered or not,
# exempt or not. There is no legitimate instance of this shape — the fix is
# always to move the file under cloud/ (cloud/priv rides the image's `COPY priv`
# layer) or to stop reading it from compiled code. cloud/test readers stay the
# coverage ratchet's business: tests never run inside the image.
in_image_violations=0
while IFS='	' read -r p src; do
  [ -n "$p" ] || continue
  case "$src" in
    cloud/lib/*)
      in_image_violations=$((in_image_violations + 1))
      echo "::error::cloud-path-escape-check: IN-IMAGE READER ESCAPES THE BUILD CONTEXT: $src reads $p" >&2
      ;;
  esac
done <<<"$census"

if [ "$in_image_violations" -gt 0 ]; then
  cat >&2 <<'MSG'

A file under cloud/lib/ reads outside cloud/. cloud/lib is COMPILED INTO the
control-plane image, and the image is built from cloud/ alone — the file above
cannot exist in-container, so this compiles green everywhere except the deploy,
where `mix compile` dies (the #11723 / D841 failure class). Declaring the path
in CLOUD_PATHS does not help: dispatch coverage cannot put a file inside a
docker build context.

Fix: move the file under cloud/ (cloud/priv/ rides the Dockerfile's `COPY priv`
layer), or stop reading it from compiled code.
MSG
  exit 1
fi

cloud_ere="$(set_ere cloud)"
uncovered=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # here-string, NOT `printf '%s\n' "$p" | grep -Eq` (honest-gates D37). `grep
  # -q` exits on the first match; under this script's own `set -o pipefail` the
  # write side then takes SIGPIPE, the pipeline returns 141, and the `if` falls
  # to its FALSE branch — a COVERED repo-root read reported UNCOVERED, a
  # BLOCKING red on the required Cloud gate for a reason foreign to what this
  # ratchet measures. Only the 64 KiB pipe buffer kept it quiet: one short path
  # is written before grep can exit. Luck, not correctness.
  if grep -Eq -- "$cloud_ere" <<<"$p"; then
    continue
  fi
  if is_exempt "$p"; then
    echo "  exempt: $p"
    continue
  fi
  uncovered=$((uncovered + 1))
  echo "::error::cloud-path-escape-check: UNCOVERED repo-root read: $p" >&2
  printf '%s\n' "$census" | awk -F'\t' -v p="$p" '$1 == p { print "    read from: " $2 }' | sort -u >&2
done <<<"$paths"

if [ "$uncovered" -gt 0 ]; then
  cat >&2 <<'MSG'

The Cloud suite reads path(s) that cloud.yml's dispatcher does NOT dispatch on.
A PR touching one of them would SKIP the suite and report green.

Fix: add the path to CLOUD_PATHS at the top of this script — cloud.yml reads its
set from here, so declaring it once is enough. Exempt it only if the reading
test is excluded from the default lane, and say so in the exemption's reason.
MSG
  exit 1
fi

echo "OK: every repo-root read from cloud/lib + cloud/test is dispatched on."
echo "OK: no cloud/lib reader escapes the image build context."
