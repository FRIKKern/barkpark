#!/usr/bin/env bash
#
# toplevel-classifier-check.sh — the DEFAULT for an unrecognised top-level path.
#
# WHY THIS EXISTS (task-fb7857b984ff5ff8, honest-gates)
# ----------------------------------------------------
# Every path set in this tree fails OPEN. Re-derived live on origin/main
# ad7f16319 with each ratchet's own `--match`, a head touching only
# `brandnewdir/x.txt` answers:
#
#     cloud=false  console=false  elixir-compile=false  elixir-test=false
#     go=false
#
# Nothing dispatches. Every expensive leaf skips, a skipped job publishes
# `success`, and the four names branch protection watches all go green over a
# diff not one of them read. `gh pr view` then reads mergeStateStatus: CLEAN.
#
# The internal/cli half of this defect (PR #16535) was fixable by DECLARING the
# directory, because it already existed and someone could name it. A directory
# that does not exist yet cannot be named in any path list, so the cure cannot
# be another entry in another allowlist consulted after the fact. It has to be
# a DEFAULT: an unrecognised top-level entry must red.
#
# So this script carries the repo's TOP-LEVEL REGISTRY and refuses a changed
# path whose top-level entry is not in it. Adding a top-level directory becomes
# a deliberate, reviewed act — one line here, with a classification and a
# reason — instead of a silent hole.
#
# NOT BY WIDENING A PATH SET. Nothing here is added to CLOUD_PATHS, to the
# elixir compile/test sets, to console's set, or to go-tests.yml's
# `on.push.paths`. No workflow gains a trigger path and no job gains a
# dispatch condition, so the check-run roster on a diff touching only KNOWN
# directories is byte-for-byte what it was. This rides as a STEP of elixir.yml's
# already-unfiltered `path-escape` job, which costs bash and no extra runner.
#
# THE REGISTRY IS THE CLASSIFICATION, said plainly rather than dressed up as a
# derivation. It cannot be derived from the tree: on the PR that ADDS
# `brandnewdir/`, `git ls-tree HEAD` lists `brandnewdir` — a tree-derived known
# set knows every new directory the instant it appears, which is precisely the
# fail-open shape this file replaces. So the set is written down, and it is
# defended in BOTH directions:
#
#   UNKNOWN  a changed path whose top-level entry is absent from the registry
#            reds, naming the path and how to classify it.
#   STALE    a registry entry that no longer exists on disk reds, so the list
#            cannot rot into a museum of deleted directories that would wave
#            through a re-created name nobody re-reviewed.
#   CLAIM    an entry that claims one of the four ratchets is VERIFIED against
#            that ratchet's own `--match`. A classification is a testable
#            statement here, never a comment: writing `cloud` next to a
#            directory cloud.yml does not dispatch on reds.
#   OVERSTEP an entry classified `none` that appears in the diff is checked the
#            other way — if a path set has since widened to cover it, the
#            registry understates and must be upgraded.
#
# CLAIM GRANULARITY, stated once: a claim means "a file placed DIRECTLY under
# this top-level entry dispatches that suite", probed as `<entry>/__probe__`.
# `cloud` therefore claims `cloud` and not `console`, because console's set is
# `cloud/priv/static/**` — a subtree, not the whole entry. Understating a
# subtree is safe; the OVERSTEP arm only fires on `none`.
#
# EXIT: 0 every changed top-level entry is registered and every claim holds
#       1 an unknown path, a stale entry, or a false claim
#       2 the changed-path set could not be determined — REFUSING, never a pass
#
# USAGE
#   toplevel-classifier-check.sh                   # derive the diff from git
#   toplevel-classifier-check.sh --paths-file F    # changed paths from F
#   toplevel-classifier-check.sh --list            # print the registry
#   toplevel-classifier-check.sh --selftest        # run the mutation harness
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

ROOT="${TOPLEVEL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── THE REGISTRY ─────────────────────────────────────────────────────────────
# One row per top-level entry: <name> <gates> <reason>
#   <gates>  a comma-separated subset of cloud,console,elixir,go — or `none`.
#            A named ratchet is verified live; `none` asserts the entry
#            dispatches none of the four and is checked when it is touched.
#   <reason> free text, required. What the entry is and who watches it.
# Rows are sorted; duplicates red.
# MUT-ANCHOR-REGISTRY
registry() {
  cat <<'REGISTRY'
.air.toml none air live-reload config for the local Go loop
.claude none agent harness config, workflows and worktree scaffolding
.codex none codex agent skills and epic-cycle scripts
.cursor none cursor editor rules
.demo-content none seed content for demos
.dockerignore none docker build context exclusions
.env.example none documented environment template
.gitattributes none git attribute rules
.githooks none git hooks; post-merge is the single-box deploy
.github none workflows and CI config; doc-gates and the shape ratchets read it
.gitignore none git ignore rules
.go-format-drift-ceiling none the go-format ratchet baseline
.mcp.json none MCP server registration for agents
.omx none omx tooling config
.tool-versions none the asdf production toolchain pin; toolchain-skew-check reads it
.vercelignore none vercel build context exclusions
AGENTS.md none agent-facing router
CHANGELOG.md none release notes
CLAUDE.md none the repo router doc
DESIGN.md none design notes
HYPERQUIZ.md none quiz plugin notes
LICENSE none the licence
Makefile none developer entry points
README.md none human readme
api elixir the Phoenix app; the Elixir suite compiles and tests it
apps none secondary app trees
barkpark.json none project manifest
bin none shipped launcher scripts
changelog none changelog fragments
cloud cloud the cloud control plane; cloud.yml dispatches on it
cmd none Go entry points
connectors none connector definitions
deploy cloud deploy scripts the cloud suite reads
deploy.sh none the legacy single-box deploy entry point
design elixir design fixtures the Elixir suite reads
dev.sh none local dev launcher
docker-compose.yml none the compose stack
docs none agent and human documentation; doc-gates reads it
docs-site none the published documentation site
go.mod go the Go module manifest
go.sum go the Go module checksums
internal cloud Go internals; cloud.yml dispatches on internal/**
js none the JS SDK monorepo
lighthouserc.json none lighthouse CI budget
nixpacks.toml none nixpacks build config
package-lock.json none npm lockfile
package.json none root npm manifest
packages none shared JS packages
pnpm-lock.yaml none pnpm lockfile
pnpm-workspace.yaml none the pnpm workspace definition
run.sh none local run helper
scaffy none scaffy templates and catalog
scripts none the gate and ops scripts
sdk none generated SDK artefacts
templates cloud,go project templates both suites read
tooling none standalone tooling trees
transplant.py none one-off transplant utility
vercel.json none vercel project config
watch.sh none local watch helper
web none the Next.js web demo
REGISTRY
}
# MUT-ANCHOR-REGISTRY-END

registry_names() { registry | awk 'NF {print $1}'; }

toplevel_of() {
  # First path segment. A bare top-level FILE is its own entry.
  printf '%s\n' "${1%%/*}"
}

# The four ratchets, addressed exactly as their own dispatchers address them.
# One declaration per gate name so this file and the workflows cannot drift.
match_gate() {
  local gate="$1" path="$2"
  case "$gate" in
    cloud)   printf '%s\n' "$path" | bash "$SELF_DIR/cloud-path-escape-check.sh" --match cloud ;;
    console) printf '%s\n' "$path" | bash "$SELF_DIR/console-path-escape-check.sh" --match console ;;
    elixir)  printf '%s\n' "$path" | bash "$SELF_DIR/elixir-path-escape-check.sh" --match test ;;
    go)      printf '%s\n' "$path" | bash "$SELF_DIR/go-path-escape-check.sh" --match ;;
    *)       echo "unknown-gate" ;;
  esac
}

how_to_classify() {
  cat <<'HOWTO'
  HOW TO CLASSIFY IT. Add ONE sorted row to the registry in
  scripts/toplevel-classifier-check.sh:

      <top-level-entry> <gates> <reason>

  <gates> is a comma-separated subset of cloud,console,elixir,go naming every
  ratchet a file directly under the entry dispatches, or `none` when it
  dispatches no suite that branch protection watches. Derive it, do not guess:

      printf '<entry>/__probe__\n' | bash scripts/cloud-path-escape-check.sh   --match cloud
      printf '<entry>/__probe__\n' | bash scripts/console-path-escape-check.sh --match console
      printf '<entry>/__probe__\n' | bash scripts/elixir-path-escape-check.sh  --match test
      printf '<entry>/__probe__\n' | bash scripts/go-path-escape-check.sh      --match

  Writing `none` is a legitimate answer and is what most rows say. It is a
  DECLARATION that a diff confined to this entry is checked by nothing branch
  protection watches, made once, in review, by a person — which is the whole
  difference between this and the silence it replaces.
HOWTO
}

# ── the check ────────────────────────────────────────────────────────────────
check() {
  local paths_file="$1" rc=0 name gates reason changed tl seen probe got want

  # STALE + shape, over the whole registry, on every run.
  local dupes
  dupes="$(registry_names | LC_ALL=C sort | uniq -d)"
  if [ -n "$dupes" ]; then
    echo "::error::toplevel-classifier: duplicate registry row(s): $(printf '%s' "$dupes" | tr '\n' ' ')"
    rc=1
  fi
  if [ -n "$(diff <(registry_names) <(registry_names | LC_ALL=C sort))" ]; then
    echo "::error::toplevel-classifier: the registry is not sorted. Sort it, so a duplicate is visible to a reader."
    rc=1
  fi

  local n_rows=0 n_claims=0
  while read -r name gates reason; do
    [ -n "${name:-}" ] || continue
    n_rows=$((n_rows + 1))
    if [ -z "${reason:-}" ]; then
      echo "::error::toplevel-classifier: registry row '${name}' carries no reason. A classification without a reason is an allowlist entry nobody can review."
      rc=1
    fi
    if [ ! -e "$ROOT/$name" ]; then
      echo "::error::toplevel-classifier: STALE registry row '${name}' — it no longer exists in the tree. Delete the row. Leaving it would wave through a re-created name that nobody re-reviewed."
      rc=1
      continue
    fi
    # CLAIM — every named ratchet is verified, every run.
    if [ "$gates" != "none" ]; then
      if [ -d "$ROOT/$name" ]; then probe="$name/__probe__"; else probe="$name"; fi
      local g
      for g in $(printf '%s\n' "$gates" | tr ',' ' '); do
        n_claims=$((n_claims + 1))
        got="$(match_gate "$g" "$probe")"
        if [ "$got" != "true" ]; then
          echo "::error::toplevel-classifier: FALSE CLAIM — registry row '${name}' claims gate '${g}', but '${probe}' through that ratchet's own --match answers '${got}'. Fix the row or widen the ratchet; a classification is a testable statement, never a comment."
          rc=1
        fi
      done
    fi
  done <<EOF
$(registry)
EOF

  if [ "$n_rows" -eq 0 ]; then
    echo "::error::toplevel-classifier: REFUSING — the registry is EMPTY. A clean verdict over an empty known-set is the vacuous pass this check exists to remove." >&2
    return 2
  fi

  changed="$(cat "$paths_file")"
  if [ -z "$changed" ]; then
    echo "toplevel-classifier: the changed-path set is empty — no top-level entry to classify."
    echo "toplevel-classifier: ${n_rows} registry row(s), ${n_claims} verified gate claim(s)."
    return $rc
  fi

  seen=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    tl="$(toplevel_of "$p")"
    case " $seen " in *" $tl "*) continue ;; esac
    seen="$seen $tl"

    gates="$(registry | awk -v n="$tl" '$1 == n {print $2; exit}')"
    if [ -z "$gates" ]; then
      echo "::error::toplevel-classifier: UNRECOGNISED top-level entry '${tl}' (from changed path '${p}'). It is in no path set that any watched context dispatches on, so a diff confined to it would publish four green names over code nothing read."
      how_to_classify
      rc=1
      continue
    fi
    # OVERSTEP — a `none` row that a widened path set has since overtaken.
    if [ "$gates" = "none" ]; then
      if [ -d "$ROOT/$tl" ]; then probe="$tl/__probe__"; else probe="$tl"; fi
      local g2
      for g2 in cloud console elixir go; do
        got="$(match_gate "$g2" "$probe")"
        if [ "$got" = "true" ]; then
          echo "::error::toplevel-classifier: UNDERSTATED — registry row '${tl}' says 'none', but '${probe}' now dispatches '${g2}'. A path set widened under the row; upgrade it to name '${g2}'."
          rc=1
        fi
      done
    fi
    echo "toplevel-classifier: ${tl} -> ${gates}"
  done <<EOF
$changed
EOF

  if [ "$rc" -eq 0 ]; then
    echo "toplevel-classifier: OK — every changed top-level entry is registered; ${n_rows} row(s), ${n_claims} verified gate claim(s)."
  fi
  return $rc
}

derive_changed_paths() {
  # The diff is DERIVED HERE and a failure REFUSES. Piping a diff in from the
  # workflow would turn a broken `git diff` into an empty list, and an empty
  # list is a clean verdict — the exact silence this file exists to end.
  local out base
  if ! base="$(git -C "$ROOT" rev-parse --verify --quiet HEAD^1)" || [ -z "$base" ]; then
    echo "toplevel-classifier: REFUSING — HEAD^1 is unresolvable in $ROOT, so the changed-path set cannot be determined. Check out with fetch-depth 2." >&2
    return 2
  fi
  if ! out="$(git -C "$ROOT" diff --name-only "$base" HEAD)"; then
    echo "toplevel-classifier: REFUSING — git diff failed in $ROOT." >&2
    return 2
  fi
  printf '%s\n' "$out"
}

# ── the harness ──────────────────────────────────────────────────────────────
# Every arm is mutation-proved: the subject is a COPY of this file, the mutation
# is applied by an anchor that must match EXACTLY ONCE, the copy must actually
# differ, and only then is the verdict read. A mutation that did not apply is a
# green that proves nothing.
selftest() {
  local pass=0 fail=0 tmp
  ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
  bad() { fail=$((fail + 1)); echo "  FAIL $*"; }

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tlc.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT

  local SELF="${BASH_SOURCE[0]}"

  # A fixture root: the real ratchets are copied in so `--match` is the REAL
  # matcher, never a stub that would make every claim arm vacuous.
  mk_root() {
    local d="$1"
    mkdir -p "$d/scripts"
    cp "$SELF_DIR/cloud-path-escape-check.sh" "$SELF_DIR/console-path-escape-check.sh" \
       "$SELF_DIR/elixir-path-escape-check.sh" "$SELF_DIR/go-path-escape-check.sh" "$d/scripts/"
    # The cloud/console ratchets read .github/workflows/*.yml for their sets.
    mkdir -p "$d/.github/workflows"
    cp "$ROOT/.github/workflows/cloud.yml" "$ROOT/.github/workflows/console-harness.yml" \
       "$ROOT/.github/workflows/go-tests.yml" "$d/.github/workflows/" 2>/dev/null || true
    cp "$SELF" "$d/scripts/toplevel-classifier-check.sh"
    # Every registered entry must exist, or the STALE arm fires everywhere.
    local n
    for n in $(bash "$SELF" --list | awk 'NF {print $1}'); do
      mkdir -p "$d/$n" 2>/dev/null || true
    done
  }

  # mutate <file> <anchor-ERE> <sed-expr> — asserts the anchor matched EXACTLY
  # once and the file actually changed.
  mutate() {
    local f="$1" anchor="$2" expr="$3" n before
    n="$(grep -cE "$anchor" "$f")"
    if [ "$n" != "1" ]; then bad "mutation anchor '$anchor' matched ${n} times, wanted 1"; return 1; fi
    before="$(cat "$f")"
    sed -i.bak -E "$expr" "$f" && rm -f "$f.bak"
    if [ "$before" = "$(cat "$f")" ]; then bad "mutation '$expr' produced NO diff — the arm would be vacuous"; return 1; fi
    return 0
  }

  run_subject() {
    local d="$1" pf="$2"
    ( TOPLEVEL_ROOT="$d" bash "$d/scripts/toplevel-classifier-check.sh" --paths-file "$pf" 2>&1 )
  }

  # ── 1. an unknown top-level entry REDS, and names the path ────────────────
  local d1="$tmp/d1"; mk_root "$d1"
  printf 'brandnewdir/x.txt\n' > "$tmp/p1"
  local out1 rc1
  out1="$(run_subject "$d1" "$tmp/p1")"; rc1=$?
  if [ "$rc1" -ne 0 ]; then ok "1a an unrecognised top-level entry reds (rc=$rc1)"; else bad "1a an unrecognised top-level entry passed (rc=$rc1)"; fi
  case "$out1" in *"UNRECOGNISED top-level entry 'brandnewdir'"*) ok "1b the refusal names the entry" ;; *) bad "1b the refusal does not name the entry: $out1" ;; esac
  case "$out1" in *"brandnewdir/x.txt"*) ok "1c the refusal names the offending path" ;; *) bad "1c the refusal does not name the path" ;; esac
  case "$out1" in *"HOW TO CLASSIFY IT"*) ok "1d the refusal says how to classify it" ;; *) bad "1d the refusal does not say how to classify it" ;; esac

  # ── 2. a KNOWN entry passes — the guard is not simply always red ──────────
  local d2="$tmp/d2"; mk_root "$d2"
  printf 'docs/x.md\nscripts/y.sh\napi/lib/z.ex\n' > "$tmp/p2"
  local out2 rc2
  out2="$(run_subject "$d2" "$tmp/p2")"; rc2=$?
  if [ "$rc2" -eq 0 ]; then ok "2a a diff over known entries passes (rc=0)"; else bad "2a a known-entry diff reddened: rc=$rc2 / $out2"; fi
  case "$out2" in *"api -> elixir"*) ok "2b a claimed entry reports its gates" ;; *) bad "2b api's classification is missing: $out2" ;; esac

  # ── 3. DELETING a row makes its own directory unknown (the registry is the
  #      thing being consulted, not a coincidence) ────────────────────────────
  local d3="$tmp/d3"; mk_root "$d3"
  if mutate "$d3/scripts/toplevel-classifier-check.sh" '^docs none ' '/^docs none /d'; then
    printf 'docs/x.md\n' > "$tmp/p3"
    local out3 rc3
    out3="$(run_subject "$d3" "$tmp/p3")"; rc3=$?
    if [ "$rc3" -ne 0 ]; then ok "3a deleting the 'docs' row makes docs/ unknown (rc=$rc3)"; else bad "3a deleting the 'docs' row still passed"; fi
    case "$out3" in *"UNRECOGNISED top-level entry 'docs'"*) ok "3b and it is named" ;; *) bad "3b docs was not named: $out3" ;; esac
  fi

  # ── 4. a STALE row (registered, absent from the tree) REDS ────────────────
  local d4="$tmp/d4"; mk_root "$d4"
  rm -rf "$d4/docs-site"
  printf 'README.md\n' > "$tmp/p4"
  local out4 rc4
  out4="$(run_subject "$d4" "$tmp/p4")"; rc4=$?
  if [ "$rc4" -ne 0 ]; then ok "4a a registry row whose entry is gone reds (rc=$rc4)"; else bad "4a a stale row passed"; fi
  case "$out4" in *"STALE registry row 'docs-site'"*) ok "4b the stale row is named" ;; *) bad "4b the stale row is not named: $out4" ;; esac

  # ── 5. a FALSE CLAIM reds — a classification is checked, not believed ─────
  local d5="$tmp/d5"; mk_root "$d5"
  if mutate "$d5/scripts/toplevel-classifier-check.sh" '^docs none ' 's/^docs none /docs elixir /'; then
    printf 'README.md\n' > "$tmp/p5"
    local out5 rc5
    out5="$(run_subject "$d5" "$tmp/p5")"; rc5=$?
    if [ "$rc5" -ne 0 ]; then ok "5a claiming a gate the ratchet denies reds (rc=$rc5)"; else bad "5a a false claim passed"; fi
    case "$out5" in *"FALSE CLAIM"*"'docs'"*) ok "5b the false claim is named" ;; *) bad "5b the false claim is not named: $out5" ;; esac
  fi

  # ── 6. an UNDERSTATED row reds when a path set has widened under it ───────
  #      `internal` really is in CLOUD_PATHS, so downgrading it to `none` is a
  #      registry that lies in the safe direction — and it still must red.
  local d6="$tmp/d6"; mk_root "$d6"
  if mutate "$d6/scripts/toplevel-classifier-check.sh" '^internal cloud ' 's/^internal cloud /internal none /'; then
    printf 'internal/cli/x.go\n' > "$tmp/p6"
    local out6 rc6
    out6="$(run_subject "$d6" "$tmp/p6")"; rc6=$?
    if [ "$rc6" -ne 0 ]; then ok "6a a 'none' row a path set has overtaken reds (rc=$rc6)"; else bad "6a an understated row passed"; fi
    case "$out6" in *"UNDERSTATED"*"'internal'"*) ok "6b the understated row is named" ;; *) bad "6b not named: $out6" ;; esac
  fi

  # ── 7. an EMPTY registry REFUSES (exit 2), never passes vacuously ─────────
  local d7="$tmp/d7"; mk_root "$d7"
  if mutate "$d7/scripts/toplevel-classifier-check.sh" '^# MUT-ANCHOR-REGISTRY$' '/^# MUT-ANCHOR-REGISTRY$/,/^# MUT-ANCHOR-REGISTRY-END$/{/^registry\(\) \{$/!{/^  cat <<.REGISTRY.$/!{/^REGISTRY$/!{/^\}$/!{/^# MUT-ANCHOR-REGISTRY/!d}}}}}'; then
    printf 'docs/x.md\n' > "$tmp/p7"
    local out7 rc7
    out7="$(run_subject "$d7" "$tmp/p7")"; rc7=$?
    if [ "$rc7" -eq 2 ]; then ok "7a an empty registry REFUSES with exit 2"; else bad "7a an empty registry exited $rc7, wanted 2: $out7"; fi
    case "$out7" in *"REFUSING"*"EMPTY"*) ok "7b the refusal says why" ;; *) bad "7b the refusal is unclear: $out7" ;; esac
  fi

  # ── 8. a duplicate row reds ──────────────────────────────────────────────
  local d8="$tmp/d8"; mk_root "$d8"
  if mutate "$d8/scripts/toplevel-classifier-check.sh" '^docs none ' 's/^docs none (.*)$/docs none \1\ndocs none \1/'; then
    printf 'README.md\n' > "$tmp/p8"
    local out8 rc8
    out8="$(run_subject "$d8" "$tmp/p8")"; rc8=$?
    if [ "$rc8" -ne 0 ]; then ok "8a a duplicate registry row reds (rc=$rc8)"; else bad "8a a duplicate row passed"; fi
  fi

  # ── 9. a row with no reason reds ─────────────────────────────────────────
  local d9="$tmp/d9"; mk_root "$d9"
  if mutate "$d9/scripts/toplevel-classifier-check.sh" '^LICENSE none the licence$' 's/^LICENSE none the licence$/LICENSE none/'; then
    printf 'README.md\n' > "$tmp/p9"
    local out9 rc9
    out9="$(run_subject "$d9" "$tmp/p9")"; rc9=$?
    if [ "$rc9" -ne 0 ]; then ok "9a a reasonless row reds (rc=$rc9)"; else bad "9a a reasonless row passed"; fi
    case "$out9" in *"carries no reason"*) ok "9b and says why" ;; *) bad "9b: $out9" ;; esac
  fi

  # ── 10. an undeterminable diff REFUSES rather than passing empty ─────────
  local d10="$tmp/d10"; mk_root "$d10"
  local out10 rc10
  out10="$( TOPLEVEL_ROOT="$d10" bash "$d10/scripts/toplevel-classifier-check.sh" 2>&1 )"; rc10=$?
  if [ "$rc10" -eq 2 ]; then ok "10a an unresolvable HEAD^1 REFUSES with exit 2"; else bad "10a exited $rc10, wanted 2: $out10"; fi
  case "$out10" in *"REFUSING"*) ok "10b and says so" ;; *) bad "10b: $out10" ;; esac

  # ── 11. the LIVE tree: this repo's own registry covers this repo's own tree
  local live_missing live_extra
  live_missing="$(comm -23 <(git -C "$ROOT" ls-tree --name-only HEAD | LC_ALL=C sort) \
                           <(registry_names | LC_ALL=C sort))"
  live_extra="$(comm -13 <(git -C "$ROOT" ls-tree --name-only HEAD | LC_ALL=C sort) \
                         <(registry_names | LC_ALL=C sort))"
  if [ -z "$live_missing" ]; then ok "11a every tracked top-level entry is registered"; else bad "11a unregistered: $(printf '%s' "$live_missing" | tr '\n' ' ')"; fi
  if [ -z "$live_extra" ]; then ok "11b no registry row names a path git does not track"; else bad "11b untracked rows: $(printf '%s' "$live_extra" | tr '\n' ' ')"; fi

  echo
  echo "SELFTEST: ${pass} passed, ${fail} failed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --list) registry; exit 0 ;;
  --selftest) selftest; exit $? ;;
  --paths-file)
    f="${2:?--paths-file needs a file}"
    [ -f "$f" ] || { echo "toplevel-classifier: REFUSING — no such paths file: $f" >&2; exit 2; }
    check "$f"; exit $?
    ;;
  ""|--check)
    tmpf="$(mktemp "${TMPDIR:-/tmp}/tlc-changed.XXXXXX")"
    if ! derive_changed_paths > "$tmpf"; then rm -f "$tmpf"; exit 2; fi
    check "$tmpf"; rc=$?; rm -f "$tmpf"; exit $rc
    ;;
  *)
    echo "usage: $0 [--check|--paths-file FILE|--list|--selftest]" >&2
    exit 2
    ;;
esac
