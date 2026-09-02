#!/usr/bin/env bash
#
# console-path-escape-check.sh — the console skip-shim's path ratchet AND the
# single source of truth for the path set console-harness.yml dispatches on.
#
# WHY THIS EXISTS (Cloud Console Hardening wave 9, M1)
# ---------------------------------------------------
# console-harness.yml used to carry workflow-level `on: … paths:` keys. Measured
# on live GitHub (honest-gates D18): a paths-filtered workflow emits NO check run
# at all, so a required context pointing at it sits "is expected." forever and
# the PR is BLOCKED with no red to fix. PR #7805's docs-only head f1c33790
# rendered 13 check runs and not one console-harness name. So the workflow now
# runs on every head and makes its path decision at JOB level, behind an
# always-running dispatcher — exactly the shape elixir.yml carries.
#
# That is only honest while the declared path set is a SUPERSET of everything
# the console harness actually reads. It reads well outside cloud/priv/static:
# the seal-predicate tests pass `--repo <the real repo root>`, so the predicate
# readFileSync's .github/workflows/cloud.yml, SPAWNS design/emit-fence.test.mjs,
# and existsSync's five cloud/test/barkpark_cloud/web/*_test.exs files. Measured
# when wave 9 cut this: deleting cloud.yml's `paths:` key reds 7 seal-predicate
# tests, moving emit-fence.test.mjs reds 1, moving one measured_by file reds 6 —
# and NONE of those three families was declared in the old filters.
#
# NO DENOMINATOR HERE, ON PURPOSE. Those three counts used to be written "7 of
# 31 / 1 of 31 / 6 of 31"; seal-predicate.test.mjs carries 75 `test(` calls now,
# so the denominator was wrong by more than a factor of two and had been for
# several waves. It is the same rotting integer this file already banned from
# its own error message — cite the derivation, not the number
# (`grep -c 'test(' cloud/priv/static/__preview__/seal-predicate.test.mjs`).
#
# So: this script re-derives the read census from the working tree on every run
# and FAILS when a resolved repo-root read is not covered by the declared set
# below. Adding a new cross-tree read without widening the dispatcher is a red,
# not a silent hole.
#
# HOW A READ IS RESOLVED
# ----------------------
# SIX IDIOMS, each tagged in the census so it can carry its own floor. They are
# spelled out in `file_lits`; the shapes are:
#
#   literal-join  `path.join(REPO_ROOT, "…")` / `join(REPO, '…')`
#   ident-join    `join(<anyIdentifier>, "…")` — the same call shape with a root
#                 variable this file does not get to name (the frontier file
#                 spells it `repoRoot`, camelCase).
#   data-table    seal-predicate.mjs never writes its reads as literals at the
#                 read site: it interpolates them out of KNOWN_DEFECTS rows
#                 (`${REPO}/${d.guard}`, `${REPO}/${d.measured_in_ci.workflow}`).
#                 A scanner that only looked at read sites would see a template
#                 and report the tree clean — the exact blind pass this ratchet
#                 exists to prevent. So the census WALKS THE TABLE.
#   measured-by   the same table's `measured_by: [ … ]` arrays, walked line-wise
#                 because they wrap.
#   template      a bare `` `${REPO}/some/path` `` with no comma and no quotes.
#   walk-up       a `"../…"` literal, resolved against the reading file's own
#                 directory.
#
# AND THE SOURCE SET IS TWO LEVELS, NOT ONE. `find cloud/priv/static` alone made
# a read expressed one call frame down — inside a file the harness SPAWNS —
# structurally invisible; see the recursion note in `list_escapes`.
#
# Anything landing inside cloud/priv/static is the harness's own tree, not an
# escape. Anything outside it that exists on disk AS A REGULAR FILE is a
# repo-root read the dispatcher must cover (a directory literal is a walk root,
# not a read — the ruling is in `scan_files`).
#
# The existence filter is what keeps the mutation fixtures out of the census
# (seal-predicate.test.mjs carries a deliberately-nonexistent
# `…_test_DELETED.exs` entry): they are asserted on, never read.
#
# NOT `git ls-files` (charter D31): a prototype that enumerated via git reported
# "OK: every repo-root read is covered" and exited 0 with the mutation fixture
# sitting on disk UNTRACKED — a textbook vacuous pass of exactly the class this
# epic exists to remove. The harness carries an untracked case.
#
# USAGE
#   console-path-escape-check.sh                 # the ratchet (CI + the gate)
#   console-path-escape-check.sh --selftest      # run the harness
#   console-path-escape-check.sh --list-escapes  # print the resolved census
#   console-path-escape-check.sh --print-floors  # print the per-idiom floors
#   console-path-escape-check.sh --print-set console
#   console-path-escape-check.sh --match console      # changed paths on stdin
#                                                     # -> prints true|false
#
# `--print-set` / `--match` are consumed by the console-harness.yml dispatcher,
# so the workflow and this ratchet can never disagree about what the path set is.

set -euo pipefail

# ---------------------------------------------------------------------------
# THE DECLARED PATH SET (ONE set — the console has no compile/test split)
# ---------------------------------------------------------------------------
# Glob grammar, deliberately tiny: `dir/**` = that directory and everything
# under it; anything else = one exact file path. No other wildcards.
#
# Every entry is a MEASURED read (see --list-escapes for the census), except the
# last three, which are the shim's own files: a change to the workflow or to
# this ratchet must always run the jobs it gates.
#
# NOTE the two internal/ entries are EXACT FILES, never internal/*/testdata/**:
# those directories carry hundreds of unrelated pdrender/taskboard goldens, and
# the console harness reads exactly two of them
# (cloud/priv/static/__app.test.mjs:5369-5370). Over-inclusion costs the shim
# precisely what it exists to save; the ratchet below is what makes the narrow
# declaration safe — a new read reds instead of skipping.
#
# `.github/required-checks.json` is declared AHEAD of the read that needs it, and
# that is deliberate. The sibling slice `cch-w9-cloud-gate-shim-rung2` makes the
# seal predicate's rung-2 leg A read `${REPO}/.github/required-checks.json`; the
# console harness runs the predicate's tests, so an edit to that file changes
# what those tests conclude. Neither slice's own tree shows the pair — this half
# declares a path it does not yet read, the other half writes a read it does not
# dispatch on — which is exactly how the two would have merged into a live hole
# with both ratchets reporting OK. Declaring it here is also what keeps main
# GREEN whichever of the two lands first.
#
# THE TWO `deploy/` ENTRIES ARE THE CORPUS-DERIVATION METHOD PAYING ITS DISPATCH
# BILL. Wave 25 stopped authoring cruel strings and started DERIVING them from
# the code that emits them, so `__app.test.mjs` now reads the two site-deploy
# shell scripts to re-derive the step vocabulary it asserts on. That makes those
# scripts INPUTS to a console assertion: edit one, and what the console tests
# conclude changes. Undeclared, the harness would not re-run on such an edit and
# the derived value would go quietly stale — the exact "green by construction"
# shape this epic exists to kill, arriving through the door the epic just opened.
# This ratchet caught it on the slice that introduced it, which is the ratchet
# working. Declaring here covers BOTH halves at once: `--match console` is what
# console-harness.yml's `changes` dispatcher runs, so one list drives dispatch
# and coverage and the two cannot drift apart.
#
# `internal/agent/report.go` IS A CROSS-FENCE READ, AND THE FENCE IS TOLD
# (wave 51 s2). The console's Timeline empty state quotes the on-box agent
# verbatim — "the on-box agent reports 'no backup probe wired'" — and
# __app.test.mjs pins that quote against the file that actually emits it
# (report.go:596), so the emitter is an INPUT to a console assertion: reword the
# Go literal and what the console tests conclude changes. Undeclared, the
# harness would not re-run on that edit and the console would keep quoting a
# string the agent no longer produces, with a green Console gate — the exact
# green-by-construction shape this ratchet exists to kill.
#
# THE COST IS REAL, NAMED, AND OWED TO ANOTHER EPIC IN WRITING: internal/agent/
# is inside the deploy-reliability fence, and this line means a
# deploy-reliability PR touching report.go now fires the blocking Console gate.
# That is the intended non-vacuity, not a side effect. It is ONE EXACT FILE and
# never `internal/agent/**`: the harness reads exactly this file, and widening
# it to the directory would bill that epic for edits the console cannot see.
# The companion arm-C walk of `internal/` and `cmd/` is a WALK ROOT, not a read
# (the ruling is in scan_files), so it correctly adds nothing here.
#
# `cloud/lib/**` IS THE WHOLE DIRECTORY, AND IT HAS TO BE (wave 30 S1). The
# bidirectional notification census in `__app.test.mjs` walks EVERY `.ex` file
# under `cloud/lib` to find the call sites that dispatch an alert — its universe
# is "the control plane", not a file list, because the defect it catches is a
# producer that does not exist ANYWHERE. Declaring the directory is therefore the
# narrowest HONEST declaration: name one file and adding a producer in a second
# file would neither re-run the harness nor be covered, which is the exact
# green-by-construction shape this ratchet exists to kill. The cost is real and
# accepted — the console harness now runs on any control-plane edit — and it is
# the same bill the `deploy/` entries above pay for the same reason. The
# `auto_deploy_worker.ex` line is left standing: it is subsumed here, but it
# documents its own read at the point that made it.
#
# THE `design/emit.mjs` ARTIFACTS ARE DECLARED HERE, BECAUSE NO SCANNER DOOR CAN
# EVER SEE THEM (backlog cch-w30-bl-artifacts-paths-ungated). Every idiom in
# `file_lits` extracts STRING LITERALS. `design/emit-fence.test.mjs` — declared
# above, and SPAWNED by the seal predicate whose tests the console harness runs
# — builds its throwaway tree with `copyFileSync(join(repoRoot, rel), dst)` over
# a set it IMPORTS: `ARTIFACTS.map((a) => a.path)`, plus the mirror module's
# `SURFACE_PATH` and `BUNDLE_PATH`. There is no literal at the read site, and
# the frontier recursion in `list_escapes` is bounded at depth one BY
# DECLARATION, so `design/emit.mjs` (two frames out) is never opened either.
# `--list-escapes` therefore names none of these paths and never will. Same
# blindness class as the elixir ratchet's `cloud/test/**` entry: a read that has
# to be DECLARED because it can never be MEASURED.
#
# MEASURED on origin/main before these entries existed, one path standing in for
# the family: append a comment line to `web/lib/tokens.gen.ts` and
# `node design/emit-fence.test.mjs` goes from `# pass 9 / # fail 0` to
# `# pass 6 / # fail 3`, while
# `printf 'web/lib/tokens.gen.ts' | … --match console` printed `false`. The
# Console gate SPAWNS that guard and would have SKIPPED the very PR that reds
# it — a required context reporting green over a harness that never looked. The
# only other catcher is `Doc budgets + anchors`, which matches the file through
# its `**/*.ts` glob but carries an S4 exclusion row in
# `.github/required-checks.json` and cannot block a merge. Nothing that can stop
# a merge was watching.
#
# DERIVED, NOT TRANSCRIBED — the list below is the output of these two greps,
# and the harness re-runs BOTH against the real tree:
#
#   awk '/^export const ARTIFACTS = \[/,/^\];/' design/emit.mjs \
#     | grep -Eoh 'path: "[^"]*"' | sed -E 's/^path: "//; s/"$//' | sort -u
#
#   grep -Eoh '^export const (SURFACE_PATH|BUNDLE_PATH) = "[^"]*"' \
#     design/paper-editor-mirror.mjs | sed -E 's/.*"([^"]*)"$/\1/'
#
# minus the three ARTIFACTS rows that already ride `cloud/priv/static/**`
# (app.css, app.js, styleguide.html) and the mirror's `SURFACE_PATH`, which is
# itself an ARTIFACTS row. `BUNDLE_PATH` is NOT an ARTIFACTS row and is declared
# on its own measurement: emit's post-step re-derives the mirror from the
# just-emitted surface, and a line spliced INSIDE that file's generated region
# takes the guard to the same `# pass 6 / # fail 3`. A bare append at EOF does
# not (`# pass 9 / # fail 0`) — the mirror attributes on the marked region, not
# the whole file — which is why this is one exact file and not `api/assets/**`.
#
# The selftest asserts every derived path dispatches `true`, so an artifact
# added to the emitter without a line here reds the harness; and it reds on a
# derivation that resolves ZERO paths, so a regex that stops matching cannot
# pass vacuously the way an unguarded loop over an empty list would.
#
# THE COST, NAMED AND ACCEPTED. These are EXACT FILES, never `api/**` or
# `web/**`. Seven of them (the `.gen.ts`, `tokens_gen.go`, `chrome_gen.go`,
# `tokens_gen.ex` rows) are WHOLE-FILE generated artifacts: nothing but a token
# regeneration or the hand-edit this guard exists to refuse ever touches them,
# so their dispatch bill is near zero. The other nine are hand-written surfaces
# that CARRY a generated region — the Studio and /papers layouts, the two
# controller HTML modules, the status controller, the /sheets reader, the web
# demo's globals.css, paper-surface.css and the paper-editor bundle — and those
# DO bill an ordinary Studio/controller/web PR for a console harness run. That
# is the intended non-vacuity, the same bill `cloud/lib/**` and the two
# `deploy/` entries above pay for the same reason. The alternative is a required
# context that greens over a guard the change just broke.
CONSOLE_PATHS='cloud/priv/static/**
internal/taskboard/testdata/styleguide_lifecycle.txt
internal/pdrender/testdata/styleguide_tokens.txt
internal/agent/report.go
.github/workflows/cloud.yml
design/emit-fence.test.mjs
cloud/priv/audit-actions.json
cloud/test/barkpark_cloud/web/**
.github/required-checks.json
.github/workflows/console-harness.yml
deploy/lib/site-deploy-common.sh
deploy/site-deploy-node.sh
internal/builder/builder.go
cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex
cloud/lib/**
api/assets/paper-surface/paper-surface.css
api/assets/paper-editor/src/styles.css
api/lib/barkpark_web/layouts/root.html.heex
api/lib/barkpark_web/layouts/bulldocs.html.heex
api/lib/barkpark_web/layouts/sheets.html.heex
api/lib/barkpark_web/controllers/session_html.ex
api/lib/barkpark_web/controllers/error_html.ex
api/lib/barkpark_web/controllers/status_controller.ex
api/lib/barkpark/portable_doc/render/tokens_gen.ex
api/lib/barkpark_web/studio/tokens_gen.ex
internal/taskboard/tokens_gen.go
internal/pdrender/tokens_gen.go
internal/semrole/tokens_gen.go
internal/semrole/chrome_gen.go
web/app/globals.css
web/lib/tokens.gen.ts
scripts/console-path-escape-check.sh
scripts/console-path-escape-check.test.sh'

# EXEMPT — reads that resolve to a real file but are NOT reachable from the
# console harness's default lane. Each line is `<path><TAB><why>`; an entry
# without a reason is a bug. Keep this list at zero-growth: the honest fix for a
# new cross-tree read is to declare it above, not to exempt it.
CONSOLE_ESCAPE_EXEMPT=''

# THE CENSUS FLOOR, PER IDIOM — and the "per idiom" is the whole point.
#
# This used to be ONE whole-population number (`CONSOLE_ESCAPE_MIN=4`) over a
# SIX-idiom scanner, and a whole-population floor cannot fire on the failure its
# own comment names. Measured on origin/main at 467f7e283: neutering EXACTLY the
# data-table walk — the `(guard|workflow)` grep and the `measured_by` awk
# trigger, the precise regression the floor existed for — collapsed the census
# 15 -> 9 and STILL EXITED 0. A 40% blinding passed green, because the surviving
# idioms alone cleared 4. The harness could not catch it either: its floor case
# only ever exercised a TOTAL collapse (a one-read fixture), so it certified a
# floor that could not fire.
#
# So each idiom now carries its OWN lower bound, and one idiom going to zero
# reds on its own. Bounds are LOWER BOUNDS, never equalities: an exact pin taxes
# every slice that adds a read (the lesson filed as
# `pds-bl-census-exact-pins-tax-growth`), while a floor only ever taxes
# SHRINKING, which is exactly the direction that means "blind".
#
# ONLY REGULAR-FILE ROWS REACH THIS TABLE — see the `[ -f ]` ruling in
# scan_files. That is load-bearing for the floor specifically: a naive per-idiom
# floor is satisfiable by a row that names no file. Measured: blind the
# literal-join regex to dotted filenames and that family collapses 6 -> 1 with
# the survivor being the DIRECTORY `cloud/lib` — bound held, scanner blind.
#
# Live population when these bounds were set (`--list-escapes | cut -f1,3 |
# sort -u`, 14 distinct paths): literal-join 5, ident-join 5, measured-by 5,
# data-table 2, template 2, walk-up 1.
#   * literal-join / ident-join / measured-by are bounded at 3 of 5 — real
#     headroom, since a slice that retires one read should not have to touch
#     this table.
#   * data-table and template are bounded at 1 of 2. Both are small by nature
#     (one KNOWN_DEFECTS table, one rung-2 read) and both are exactly the
#     interpolated shapes a regex change silently kills.
#   * WALK-UP IS BOUNDED AT 1 OF 1, ITS FULL POPULATION, DELIBERATELY. Its one
#     live read is `new URL("../../lib/barkpark_cloud/web/router.ex", …)` at
#     __app.test.mjs:13503. Nobody reaches out of cloud/priv/static this way on
#     purpose, so this idiom going to zero is far more likely to be a broken
#     regex than a deliberate refactor. The price is honest and named: rewriting
#     that ONE line into another idiom reds this gate. That red is correct in
#     shape and cheap to clear — lower the bound here in the same commit that
#     moved the read.
#
# The table is also the IDIOM INVENTORY: a tag emitted by file_lits that is not
# listed here is an error, so adding a seventh idiom cannot quietly ship without
# a floor.
#
# It is a CONSTANT on purpose. An env-var override would be a one-line CI bypass
# of the only check that can tell "clean" from "blind", and the harness asserts
# that setting CONSOLE_ESCAPE_IDIOM_MIN changes nothing.
CONSOLE_ESCAPE_IDIOM_MIN='literal-join	3
ident-join	3
measured-by	3
data-table	1
template	1
walk-up	1'

# The harness's own tree. Reads landing here are not escapes.
CONSOLE_HOME='cloud/priv/static'

# CONSOLE_PATH_ESCAPE_ROOT retargets the scan at a synthetic fixture tree; the
# harness is its only caller. It cannot weaken a real run — pointing it at the
# repo gives the identical verdict.
REPO_ROOT="${CONSOLE_PATH_ESCAPE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

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
# answer `true` for everything, silently running the whole harness on every PR
# (or, on the other polarity of a future caller, skipping it everywhere).
assert_set_name() {
  case "$1" in
    console) ;;
    *)
      echo "console-path-escape-check: unknown path set '$1' (want console)" >&2
      exit 2
      ;;
  esac
}

set_globs() {
  assert_set_name "$1"
  case "$1" in
    console) printf '%s\n' "$CONSOLE_PATHS" ;;
  esac
}

# One alternation ERE for the whole set. Returned as a single string (not a
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
    echo "console-path-escape-check: path set '$1' resolved to an empty pattern" >&2
    exit 2
  fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# the census
# ---------------------------------------------------------------------------
# Every extractor's output is TAGGED with the idiom that produced it, and the
# tag rides all the way to the printed row. Two things depend on it and neither
# works without it:
#   * the BARE-WORD rule below (only a provably repo-rooted idiom may admit a
#     literal that carries no `/`), and
#   * the PER-IDIOM FLOOR (an aggregate floor cannot tell "one idiom went
#     blind" from "the tree shrank").
tag_lits() {
  sed -E "s/.*['\"]([^'\"]*)['\"][[:space:]]*\$/\1/" | awk -v k="$1" '{ print k "\t" $0 }'
}

# All the literals one file carries, as `<idiom><TAB><literal>` lines.
file_lits() {
  local p="$REPO_ROOT/$1"
  #  (1) the literal idiom: path.join(REPO_ROOT, "…") / join(REPO, '…')
  { grep -Eoh "(REPO_ROOT|REPO)[[:space:]]*,[[:space:]]*['\"][^'\"]*['\"]" "$p" || true; } \
    | tag_lits literal-join
  #  (1b) THE GENERIC JOIN IDIOM: `join(<anyIdentifier>, "…")`. (1) is spelled
  #      against ONE naming convention — `(REPO_ROOT|REPO)`, case-sensitive —
  #      so the scanner's vocabulary was coupled to how cloud/priv/static
  #      happens to name its root variable. Measured: design/emit-fence.test.mjs
  #      names it `repoRoot` (camelCase), and `path.join(repoRootLocal, "…")`
  #      dropped into a DIRECTLY scanned file was invisible with everything else
  #      in place. The base identifier is not knowable statically, so this idiom
  #      is deliberately over-inclusive on the read side and paid for on the
  #      filter side: it may NOT admit bare words (see the bare-word rule), and
  #      whatever it does resolve still has to exist on disk as a regular file.
  { grep -Eoh "join[[:space:]]*\([[:space:]]*[A-Za-z_\$][A-Za-z0-9_\$]*[[:space:]]*,[[:space:]]*['\"][^'\"]*['\"]" "$p" || true; } \
    | tag_lits ident-join
  #  (2) the DATA TABLE: guard: '…' | workflow: '…'
  { grep -Eoh "(guard|workflow)[[:space:]]*:[[:space:]]*['\"][^'\"]*['\"]" "$p" || true; } \
    | tag_lits data-table
  #  (2b) THE TEMPLATE-LITERAL IDIOM: `${REPO}/some/path`. Not a variant of
  #      (1) — that one matches a `join(REPO, "…")` CALL, and this one is a
  #      backtick string with no comma and no quotes anywhere near it, so
  #      the (1) grep cannot see it. seal-predicate.mjs reads
  #      `${REPO}/.github/required-checks.json` in exactly this shape (its
  #      rung-2 leg A), and the two are written by DIFFERENT slices, which
  #      is precisely how a census goes quietly blind: each half looks
  #      complete on its own branch. The static prefix is emitted bare —
  #      the quoted-literal sed in tag_lits leaves a line it cannot match alone.
  { grep -Eoh '\$\{(REPO_ROOT|REPO)\}/[^`'"'"'"[:space:],)]*' "$p" \
      | sed -E 's/^\$\{(REPO_ROOT|REPO)\}\///' || true; } \
    | tag_lits template
  #  (3) the walk-up idiom: any `"../…"` literal, resolved against the
  #      reading file's own directory. Nothing in the tree uses it today
  #      (the idioms above are how the harness is written), but it is
  #      the obvious next way to reach out of cloud/priv/static, and a
  #      census that only saw yesterday's idioms is one refactor from
  #      blind.
  { grep -Eoh "['\"]\.\./[^'\"]*['\"]" "$p" || true; } | tag_lits walk-up
  #  (4) measured_by: [ … ] — an ARRAY, frequently spanning several lines.
  #      Walked with a tiny state machine so a row whose entries are wrapped
  #      (seal-predicate.mjs:173-176) is not silently half-read. The state
  #      machine prints WHOLE LINES, so it also drags in prose that happens to
  #      sit inside the array; that is why it may not admit bare words either.
  { awk '
      /measured_by[[:space:]]*:/ { inarr = 1 }
      inarr { print }
      inarr && /]/ { inarr = 0 }
    ' "$p" | grep -Eoh "['\"][^'\"]*['\"]" || true; } | tag_lits measured-by
}

# Scan a newline-separated list of repo-relative files.
# Prints `<resolved-path><TAB><source-file><TAB><idiom>` per resolved read.
scan_files() {
  local f lit resolved tagged idiom line d
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$REPO_ROOT/$f" ] || continue
    tagged="$(file_lits "$f")"
    [ -n "$tagged" ] || continue
    while IFS= read -r line; do
      idiom="${line%%	*}"
      lit="${line#*	}"
      # `"…/#{x}"`-style splices and wildcards: keep the static prefix only.
      lit="${lit%%\$\{*}"
      case "$lit" in
        *'*'*)
          lit="${lit%%\**}"
          lit="${lit%/}"
          ;;
      esac
      [ -n "$lit" ] || continue
      case "$lit" in
        # An absolute path is not a repo-relative read, and a literal carrying a
        # space is prose, not a path.
        /* | *' '*) continue ;;
        */*) ;;
        *)
          # THE BARE-WORD RULE. A literal with no `/` used to be dropped
          # outright, which made a read of ANY repo-root top-level file —
          # Makefile, README.md, mix.lock, package.json — structurally
          # unrepresentable: the census could not have named it if it tried.
          # Measured on origin/main: `path.join(REPO_ROOT, "Makefile")` dropped
          # into a DIRECTLY scanned file, with Makefile present at 17536 bytes,
          # left the run at 15 reads / RC=0 and a census count of 0 for it.
          #
          # Bare words are admitted ONLY from the idioms whose base is provably
          # the repo root in the source text itself — `join(REPO_ROOT, …)`,
          # `${REPO}/…`, and the data table (whose values are interpolated as
          # `${REPO}/${d.guard}` by construction). They are NOT admitted from
          # `ident-join` (the base is an unknown identifier — usually a temp dir,
          # so `join(dir, "index.html")` is not a repo read) nor from
          # `measured-by` (its line-wise array walk over-captures prose).
          case "$idiom" in
            literal-join | template | data-table) ;;
            *) continue ;;
          esac
          # `.git` IS NOT A READ, AND ADMITTING IT WOULD MAKE THIS RATCHET
          # ANSWER DIFFERENTLY IN CI AND LOCALLY. It is a DIRECTORY in a normal
          # clone (dropped by the regular-file filter below) but a regular FILE
          # in a git worktree, which is exactly where this gate's local runs
          # happen — so it would red on a developer's machine and pass in
          # Actions. It is VCS metadata, never a dispatchable input.
          case "$lit" in .git | .git/*) continue ;; esac
          ;;
      esac
      # A walk-up literal is relative to the file that carries it; a bare
      # repo-relative literal (the data table's idiom) is already anchored.
      case "$lit" in
        ../* | ./*)
          d="$(dirname -- "$f")"
          resolved="$(norm_path "$d/$lit")"
          ;;
        *) resolved="$(norm_path "$lit")" ;;
      esac
      [ -n "$resolved" ] || continue
      # inside the harness's own tree is not an escape
      case "$resolved" in "$CONSOLE_HOME" | "$CONSOLE_HOME"/*) continue ;; esac
      # ONLY REGULAR FILES — and this is a RULING, not a tightening for its own
      # sake. It used to be `[ -e ]`, which admitted DIRECTORY rows, and a
      # directory row is a walk ROOT, not a read: `cloud/lib` enters from
      # __app.test.mjs's notification census, which walks every `.ex` beneath it.
      # Two things go wrong if such a row counts.
      #   (a) IT MAKES THE PER-IDIOM FLOOR SATISFIABLE BY A ROW THAT NAMES NO
      #       FILE. Measured: blinding the literal-join regex to dotted
      #       filenames collapses that family 6 -> 1, and the survivor is
      #       `cloud/lib` — the floor holds while the scanner sees zero files.
      #       A floor a blind scanner can satisfy is not a floor.
      #   (b) IT REDS THE RATCHET ON `design`. design/emit-fence.test.mjs:61 is
      #       `cpSync(join(repoRoot, "design"), …)`, and the generic join idiom
      #       above resolves it the moment the recursion opens that file.
      #       `--match console` answers FALSE for `design`, because the declared
      #       set names the exact file `design/emit-fence.test.mjs`, not
      #       `design/**`. THE RULING: it is a directory copy, not a file read;
      #       the file inside `design` the harness actually depends on is
      #       `design/emit-fence.test.mjs`, which is separately declared AND
      #       separately in the census via the data table. Widening dispatch to
      #       `design/**` would buy nothing and cost every design edit a console
      #       harness run.
      # Coverage loses nothing by this: a directory's files that are genuinely
      # read appear as their own file rows (cloud/lib survives in the census as
      # router.ex and auto_deploy_worker.ex), so deleting `cloud/lib/**` from
      # the declared set still reds.
      # A literal resolving to nothing on disk stays out for the original
      # reason: it is a mutation fixture, asserted on, never read.
      [ -f "$REPO_ROOT/$resolved" ] || continue
      printf '%s\t%s\t%s\n' "$resolved" "${f#./}" "$idiom"
    done <<EOF
$tagged
EOF
  done <<EOF
$1
EOF
}

# Prints `<path><TAB><source-file><TAB><idiom>` per resolved repo-root read.
list_escapes() {
  local sources rows frontier more
  # WORKING TREE enumeration (D31) — `find`, never `git ls-files`. An untracked
  # .mjs on disk is code the harness will run, so it is code this ratchet must
  # see.
  sources="$(cd -- "$REPO_ROOT" && find "$CONSOLE_HOME" -type f \( -name '*.mjs' -o -name '*.js' \) 2>/dev/null | LC_ALL=C sort)"
  rows="$(scan_files "$sources")"
  # ── BOUNDED ONE-LEVEL RECURSION ───────────────────────────────────────────
  # The source set above is `find cloud/priv/static`, so a read expressed one
  # call frame down — inside a file the harness SPAWNS but that does not live in
  # the harness's own tree — was structurally invisible. Measured on
  # origin/main with the ONLY variable being which file carried it: the
  # identical `join(REPO_ROOT, "api/mix.exs")` gave 15 reads / RC=0 / unnamed
  # inside design/emit-fence.test.mjs (declared in CONSOLE_PATHS, never
  # scanned) and 16 / `UNCOVERED repo-root read: api/mix.exs` / RC=1 inside the
  # directly-scanned cloud/priv/static/__app.test.mjs.
  #
  # So: the `.mjs`/`.js` files the FIRST pass already resolved are opened, and
  # the same extraction runs on them. DEPTH IS EXACTLY ONE and that is a
  # deliberate bound, not a TODO — the frontier is one file today
  # (design/emit-fence.test.mjs, reached through the data table's `guard:`), an
  # unbounded crawl would walk the whole repo through node_modules-shaped edges,
  # and a second level cannot be dispatched on anyway without also declaring
  # every file it names. A read two frames down is out of this census's reach BY
  # DECLARATION; it is not an oversight.
  frontier="$(printf '%s\n' "$rows" | cut -f1 | { grep -E '\.(mjs|js)$' || true; } | LC_ALL=C sort -u)"
  if [ -n "$frontier" ]; then
    more="$(scan_files "$frontier")"
    if [ -n "$more" ]; then rows="$(printf '%s\n%s' "$rows" "$more")"; fi
  fi
  printf '%s\n' "$rows" | sed '/^$/d'
}

is_exempt() {
  local p="$1" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line%%	*}" = "$p" ] && return 0
  done <<<"$CONSOLE_ESCAPE_EXEMPT"
  return 1
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

mode="${1:---check}"

case "$mode" in
  --print-set)
    assert_set_name "${2:?--print-set needs console}"
    set_globs "$2"
    exit 0
    ;;

  --match)
    # changed paths on stdin -> `true` if ANY of them is in the named set.
    # This is what console-harness.yml dispatches on, so the workflow and the
    # ratchet can never disagree about what the path set contains.
    want="${2:?--match needs console}"
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
    # rots — the same D41 lesson that took the population number out of the
    # runtime error message below.
    printf '%s\n' "$CONSOLE_ESCAPE_IDIOM_MIN"
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
    exec bash "$(dirname -- "${BASH_SOURCE[0]}")/console-path-escape-check.test.sh"
    ;;

  --check) ;;

  *)
    echo "console-path-escape-check: unknown argument '$mode'" >&2
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

echo "console-path-escape-check: scanning \$REPO_ROOT=$REPO_ROOT"
echo "console-path-escape-check: $count distinct repo-root read(s) resolved from $CONSOLE_HOME"

# FAIL-CLOSED on a neutered scanner, ONE IDIOM AT A TIME. "Nothing found" is
# never good news here, and neither is "nothing found THROUGH ONE DOOR" —
# that is precisely what an aggregate floor cannot see.
by_idiom="$(printf '%s\n' "$census" | cut -f1,3 | sed '/^$/d' | sort -u)"
thin=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  idiom="${row%%	*}"
  floor="${row##*	}"
  got="$(printf '%s\n' "$by_idiom" | awk -F'\t' -v k="$idiom" '$2 == k' | wc -l | tr -d ' ')"
  echo "console-path-escape-check:   idiom $idiom: $got read(s) (floor $floor)"
  if [ "$got" -lt "$floor" ]; then
    thin=$((thin + 1))
    echo "::error::console-path-escape-check: idiom '$idiom' resolved only $got repo-root read(s), floor is $floor." >&2
  fi
done <<EOF
$CONSOLE_ESCAPE_IDIOM_MIN
EOF

# The table is the idiom inventory: a tag the scanner emits but the floor table
# does not list would ship with NO floor at all — a new door, unguarded.
while IFS= read -r idiom; do
  [ -n "$idiom" ] || continue
  if ! printf '%s\n' "$CONSOLE_ESCAPE_IDIOM_MIN" | awk -F'\t' -v k="$idiom" '$1 == k { f = 1 } END { exit !f }'; then
    thin=$((thin + 1))
    echo "::error::console-path-escape-check: idiom '$idiom' has no entry in CONSOLE_ESCAPE_IDIOM_MIN — a scanner door with no floor." >&2
  fi
done <<EOF
$(printf '%s\n' "$by_idiom" | cut -f2 | sort -u)
EOF

if [ "$thin" -gt 0 ]; then
  # NO POPULATION NUMBER HERE. This message used to read "the measured
  # population is <N>"; N was stale by 6 the next time anyone read it, because every
  # slice that adds a declared read moves it. A rotting integer inside the
  # guard that exists to catch rot is the epic's own D41 lesson pointed at
  # itself — cite the derivation, never the number.
  echo "  The SCANNER is broken, not the repo clean — the live population is the" >&2
  echo "  per-idiom breakdown printed just above." >&2
  echo "  Check that idiom's grep/awk in file_lits before touching the floor." >&2
  exit 1
fi

console_ere="$(set_ere console)"
uncovered=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s\n' "$p" | grep -Eq -- "$console_ere"; then
    continue
  fi
  if is_exempt "$p"; then
    echo "  exempt: $p"
    continue
  fi
  uncovered=$((uncovered + 1))
  echo "::error::console-path-escape-check: UNCOVERED repo-root read: $p" >&2
  printf '%s\n' "$census" | awk -F'\t' -v p="$p" '$1 == p { print "    read from: " $2 }' | sort -u >&2
done <<<"$paths"

if [ "$uncovered" -gt 0 ]; then
  cat >&2 <<'MSG'

The console harness reads path(s) that console-harness.yml's dispatcher does
NOT dispatch on. A PR touching one of them would SKIP the harness and report a
green Console gate.

Fix: add the path to CONSOLE_PATHS at the top of this script —
console-harness.yml reads its set from here, so declaring it once is enough.
Exempt it only if the reading code is unreachable from the harness's default
lane, and say so in the exemption's reason.
MSG
  exit 1
fi

echo "OK: every repo-root read from $CONSOLE_HOME is dispatched on."
