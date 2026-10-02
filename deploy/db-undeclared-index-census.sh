#!/usr/bin/env bash
# deploy/db-undeclared-index-census.sh
#
# WHAT IT IS. The mechanical reader for charter D614: it asks a live database
# which indexes it carries, derives from the migration tree which indexes are
# DECLARED, and reds on any object the tree does not declare. It is the check
# that would have caught `tmp_dep_site_live` — an index hand-CREATEd on
# cloud-db-1 during a read-only sweep and left behind — without anyone having to
# read a sweeper's self-report.
#
# WHY IT EXISTS AT ALL. Wave 10 had already WRITTEN the rule down ("created
# CONCURRENTLY and its presence or removal verified by reading pg_indexes
# afterwards") and had VERIFIED compliance. Wave 11 broke it hours later. The
# rule did not fail for lack of clarity; it failed because its only reader was
# the actor it constrained. This program is a reader that is not the actor.
#
# IT NEVER WRITES. Read verbs only. The live arm issues exactly one SELECT
# against pg_indexes; there is no DDL anywhere in this file, and selftest arm
# (g) greps this file for write verbs and reds if one appears.
#
# IT REFUSES RATHER THAN FLATTERS. If the live read fails, returns nothing, or
# `psql` is absent, the run exits 2 CANNOT READ and prints no table. A failed
# read answering "0 undeclared indexes" is the exact fraud this tool exists to
# refuse.
#
# ARMS
#   --manifest                 offline; prints the DECLARED set + BLIND SPOT line
#   --check [psql args...]     live; diffs pg_indexes against the manifest
#   --selftest                 hermetic; stub psql + fixture migrations, no network
#
# EXIT  0 clean · 1 undeclared object present · 2 cannot read · 3 usage
#
# BLIND SPOTS, stated so the number never flatters itself:
#   * an index created by a migration and DROPped by a later one stays in the
#     manifest, so a stale survivor of a reverted migration reads CLEAN here;
#   * expression indexes (`["lower(name)"]`) have a name this parser does not
#     derive — they are counted on the BLIND SPOT line, never silently dropped;
#   * `%_pkey` is treated as implicitly declared (Postgres mints it from the
#     table's primary key, no migration names it).
#   NOT a blind spot, because it is now a REFUSAL: a derive loop that reads
#   FEWER migration files than the enumeration handed it exits 2 SHORT DERIVE
#   naming both numbers, rather than emitting a short manifest whose every
#   missing name becomes a FALSE UNDECLARED.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION_ROOTS=("api/priv/repo/migrations" "cloud/priv/repo/migrations")

BLIND_COUNT=0

# derive_manifest <root-dir> ... -> declared index names on stdout, one per line.
# Writes the unparseable count to the file named by $BLIND_FILE.
derive_manifest() {
  local blind_file="$1"; shift
  local roots=("$@")
  local dir found=0
  local files; files="$(mktemp)"
  : > "$blind_file"
  for dir in "${roots[@]}"; do
    [ -d "$dir" ] || continue
    found=1
    find "$dir" -type f -name '*.exs' >> "$files" 2>/dev/null
  done
  if [ "$found" != 1 ]; then rm -f "$files"; return 9; fi

  # ONE awk pass per file. It does three things a line-at-a-time grep cannot:
  #   * it tracks @moduledoc/@doc triple-quoted blocks and ignores them, because
  #     PROSE IS NOT A DECLARATION — the first cut of this parser pulled
  #     `tmp_dep_site_live` out of the doc comment of the migration that DROPs
  #     it and so declared the one object the census exists to catch (arm j);
  #   * it joins a `create index(` statement across continuation lines until the
  #     parens balance, because the repair this wave landed puts its
  #     `name: :deployments_site_became_live_index` on the THIRD line and a
  #     single-line reader derives the positional name instead — a FALSE
  #     UNDECLARED on production (arm k);
  #   * it keeps unparseable declarations on a BLIND SPOT tally instead of
  #     dropping them silently.
  # COUNT THE LIST BEFORE READING IT. `iterated` below counts ITERATIONS of the
  # derive loop; this counts the PATHS `find` actually put on the list. The two
  # must be equal, and the identity after the loop is the only thing that can
  # tell "derived from 40 of 40 migrations" from "derived from 1 of 40". `awk`,
  # not `wc -l`, so a final line with no trailing newline still counts.
  local enumerated; enumerated="$(awk 'NF { n++ } END { print n+0 }' "$files")"
  local iterated=0

  # `|| [ -n "$f" ]` is not decoration: a plain `while read` DROPS a final line
  # with no trailing newline, and the identity below would then refuse a
  # complete derive as "N-1 of N".
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    iterated=$((iterated + 1))
    # MUT-ANCHOR: derive-loop-body-head
    awk -v blind="$blind_file" '
      function emit(line,   nm, tbl, cols, n, parts, i, c, out) {
        if (match(line, /name:[[:space:]]*:[A-Za-z0-9_]+/)) {
          nm = substr(line, RSTART, RLENGTH); sub(/name:[[:space:]]*:/, "", nm)
          print nm; return
        }
        if (match(line, /\([[:space:]]*:[A-Za-z0-9_]+/)) {
          tbl = substr(line, RSTART, RLENGTH); sub(/\([[:space:]]*:/, "", tbl)
        } else { print "UNPARSEABLE" >> blind; return }
        if (match(line, /\[[^]]*\]/)) { cols = substr(line, RSTART + 1, RLENGTH - 2) }
        else { print "UNPARSEABLE" >> blind; return }
        if (cols ~ /"/) { print "UNPARSEABLE" >> blind; return }
        n = split(cols, parts, ",")
        out = tbl
        for (i = 1; i <= n; i++) {
          c = parts[i]; gsub(/[[:space:]:]/, "", c)
          if (c == "") continue
          if (c !~ /^[A-Za-z0-9_]+$/) { print "UNPARSEABLE" >> blind; return }
          out = out "_" c
        }
        print out "_index"
      }
      function balance(str,   i, ch, d) {
        d = 0
        for (i = 1; i <= length(str); i++) {
          ch = substr(str, i, 1)
          if (ch == "(") d++
          else if (ch == ")") d--
        }
        return d
      }
      BEGIN { in_doc = 0; buf = ""; depth = 0 }
      {
        line = $0
        # @moduledoc / @doc triple-quoted blocks are PROSE
        if (in_doc) { if (line ~ /"""/) in_doc = 0; next }
        if (line ~ /@(module)?doc[[:space:]]+"""/) { in_doc = 1; next }
        sub(/^[[:space:]]*#.*$/, "", line)
        if (line == "") next

        if (depth > 0) {
          buf = buf " " line
          depth += balance(line)
          if (depth <= 0) { emit(buf); buf = ""; depth = 0 }
          next
        }
        if (line ~ /create[[:space:]]+(unique_)?index\(/) {
          buf = line
          depth = balance(line)
          if (depth <= 0) { emit(buf); buf = ""; depth = 0 }
          next
        }
        # raw SQL, anywhere in real code (execute "...", execute """ ... """)
        if (line ~ /CREATE[[:space:]]+(UNIQUE[[:space:]]+)?INDEX/) {
          t = line
          sub(/.*CREATE[[:space:]]+/, "", t)
          sub(/^UNIQUE[[:space:]]+/, "", t)
          sub(/^INDEX[[:space:]]+/, "", t)
          sub(/^CONCURRENTLY[[:space:]]+/, "", t)
          sub(/^IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+/, "", t)
          if (match(t, /^[A-Za-z0-9_]+/)) print substr(t, RSTART, RLENGTH)
          else print "UNPARSEABLE" >> blind
        }
      }
      END { if (depth > 0 && buf != "") print "UNPARSEABLE" >> blind }
    ' "$f"
  done < "$files"
  rm -f "$files"

  # ── THE COUNT IDENTITY ─────────────────────────────────────────────
  # WHY IT EXISTS (task-3853d5a64604d7af). The loop above reads `$files` on
  # fd 0. Any body child that reads stdin — a future `psql`, an `ssh`, a bare
  # `read`, an awk invoked with no file operand — swallows the remaining paths
  # and the loop ENDS EARLY with no error and no non-zero status. Today's body
  # child is `awk PROGRAM "$f"`, a file operand, so it leaves fd 0 alone: this
  # is LATENT, not live. The exposure is that nothing would notice if that
  # stopped being true.
  #
  # THE FAILURE DIRECTION IS WHAT MAKES IT WORSE HERE THAN ELSEWHERE. This loop
  # builds the ALLOW side of the comparison. Unread migrations SHRINK the
  # declared set, so every live index those files declared reads UNDECLARED and
  # `--check` reds a merge over production schema that is entirely correct.
  #
  # AND THE BLIND SPOT TALLY CANNOT SEE IT. That tally counts declarations this
  # parser opened and could not NAME; a file it never OPENED contributes to
  # neither tally, so a short derive leaves the BLIND SPOT number UNCHANGED
  # while the manifest quietly shrinks. Different quantity, different arm.
  # MUT-ANCHOR: derive-count-identity
  if [ "$iterated" -ne "$enumerated" ]; then
    echo "SHORT DERIVE: the derive loop read ${iterated} of ${enumerated} migration file(s) the enumeration handed it. It ended before its file list did (a loop-body child that reads stdin consumes the remaining paths silently). Refusing to emit the declared-index manifest, and therefore any UNDECLARED verdict: a short declared set turns every index the unread migrations declare into a FALSE UNDECLARED, and the BLIND SPOT tally counts declarations it could not PARSE, never files it never READ." >&2
    return 8
  fi
  # MUT-END: derive-count-identity
  return 0
}

print_manifest() {
  local roots=("$@")
  local blind; blind="$(mktemp)"
  local out; out="$(mktemp)"
  local drc=0
  ( cd "$REPO_ROOT" && derive_manifest "$blind" "${roots[@]}" ) > "$out" || drc=$?
  if [ "$drc" = 8 ]; then
    # derive_manifest already named BOTH numbers on stderr. Nothing captured in
    # "$out" is printed: a partial manifest must never leave this function, or
    # the short read becomes a burst of UNDECLARED rows downstream.
    echo "CANNOT READ: the declared-index manifest is INCOMPLETE (see the SHORT DERIVE line above); refusing to print a partial declared set." >&2
    rm -f "$blind" "$out"; return 2
  fi
  if [ "$drc" != 0 ]; then
    echo "CANNOT READ: no migration directory found under $(pwd) — refusing to print an empty manifest." >&2
    rm -f "$blind" "$out"; return 2
  fi
  sort -u "$out" | grep -vE '^$'
  BLIND_COUNT="$(wc -l < "$blind" | tr -d ' ')"
  echo "$BLIND_COUNT" > "${BLIND_SINK:-/dev/null}"
  rm -f "$blind" "$out"
  return 0
}

cmd_manifest() {
  local list; list="$(mktemp)"
  local rc=0
  print_manifest "${MIGRATION_ROOTS[@]}" > "$list" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$list"; return "$rc"; fi
  cat "$list"
  echo "---"
  echo "DECLARED: $(wc -l < "$list" | tr -d ' ') index names from ${#MIGRATION_ROOTS[@]} migration roots"
  echo "BLIND SPOT: ${BLIND_COUNT} create-index declarations this parser could not name (expression or non-literal columns); they are NOT in the set above, so an object matching one of them would read UNDECLARED."
  rm -f "$list"
  return 0
}

cmd_check() {
  local psql_bin="${PSQL:-psql}"
  command -v "$psql_bin" >/dev/null 2>&1 || {
    echo "CANNOT READ: $psql_bin not on PATH. Exiting 2 rather than reporting a comfortable zero." >&2
    return 2
  }
  local live; live="$(mktemp)"
  # THE ONLY DATABASE STATEMENT IN THIS FILE, AND IT IS A SELECT.
  if ! "$psql_bin" "$@" -Atc \
      "SELECT schemaname||'|'||tablename||'|'||indexname FROM pg_indexes WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1" \
      > "$live" 2>"$live.err"; then
    echo "CANNOT READ: the pg_indexes SELECT failed. Exiting 2 rather than reporting a comfortable zero." >&2
    sed -n '1,5p' "$live.err" >&2
    rm -f "$live" "$live.err"; return 2
  fi
  if [ ! -s "$live" ]; then
    echo "CANNOT READ: pg_indexes returned ZERO rows. A database with no indexes at all is not a thing this repo deploys; exiting 2 rather than reporting a comfortable zero." >&2
    rm -f "$live" "$live.err"; return 2
  fi
  local declared; declared="$(mktemp)"
  local rc=0
  print_manifest "${MIGRATION_ROOTS[@]}" > "$declared" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$live" "$live.err" "$declared"; return "$rc"; fi

  local undeclared=0 total=0
  echo "table|index|verdict"
  while IFS='|' read -r _schema tbl idx; do
    [ -n "${idx:-}" ] || continue
    total=$((total + 1))
    case "$idx" in
      *_pkey) continue ;;
    esac
    if grep -qxF "$idx" "$declared"; then continue; fi
    echo "${tbl}|${idx}|UNDECLARED"
    undeclared=$((undeclared + 1))
  done < "$live"
  echo "---"
  echo "LIVE: ${total} indexes read from pg_indexes"
  echo "DECLARED: $(wc -l < "$declared" | tr -d ' ') names derived from the migration tree"
  echo "UNDECLARED: ${undeclared}"
  echo "BLIND SPOT: ${BLIND_COUNT} create-index declarations this parser could not name; a live object matching one of those would appear above as a FALSE undeclared. Read the migration tree before acting on a row."
  rm -f "$live" "$live.err" "$declared"
  [ "$undeclared" = 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# SELFTEST — hermetic. No network, no credential, no real database. Every RED
# arm is paired with a QUIET arm over the SAME fixture, so a detector that
# always fires fails the QUIET arm and one that never fires fails the RED arm.
# ---------------------------------------------------------------------------
cmd_selftest() {
  local pass=0 fail=0
  local tmp; tmp="$(mktemp -d)"

  ok()   { pass=$((pass+1)); echo "  ok   $1"; }
  bad()  { fail=$((fail+1)); echo "  FAIL $1"; }

  mkdir -p "$tmp/repo/deploy" "$tmp/repo/api/priv/repo/migrations" "$tmp/repo/cloud/priv/repo/migrations" "$tmp/bin"
  cp "${BASH_SOURCE[0]}" "$tmp/repo/deploy/db-undeclared-index-census.sh"
  cat > "$tmp/repo/cloud/priv/repo/migrations/20260101000000_fixture.exs" <<'FIX'
defmodule Fixture do
  use Ecto.Migration
  def change do
    create index(:deployments, [:site_id, :inserted_at])
    create unique_index(:sites, [:team_id, :slug], name: :sites_team_slug_unique_idx)
    create index(:barkparks, ["lower(name)"])
    execute("CREATE INDEX documents_search_vector_idx ON documents USING GIN (search_vector)")
  end
end
FIX
  cat > "$tmp/repo/cloud/priv/repo/migrations/20260102000000_prose.exs" <<'PROSE'
defmodule Prose do
  @moduledoc """
  This migration adopts the hand-made index. Its prose quotes the statement that
  created it — `CREATE INDEX tmp_dep_site_live ON deployments (site_id, ...)` —
  and that quotation must NOT make the object declared.
  """
  use Ecto.Migration
  def up do
    execute "DROP INDEX IF EXISTS tmp_dep_site_live"
  end
end
PROSE
  cat > "$tmp/repo/api/priv/repo/migrations/20260103000000_multi.exs" <<'MULTI'
defmodule Multi do
  use Ecto.Migration
  def change do
    create index(:multi, [:a, :b],
                 where: "a is not null",
                 name: :multi_a_b_named_idx
           )
  end
end
MULTI

  # stub psql: prints whatever fixture file $STUB_ROWS names
  cat > "$tmp/bin/psql" <<'STUB'
#!/usr/bin/env bash
if [ "${STUB_MODE:-rows}" = "fail" ]; then echo "connection refused" >&2; exit 2; fi
if [ "${STUB_MODE:-rows}" = "empty" ]; then exit 0; fi
cat "$STUB_ROWS"
STUB
  chmod +x "$tmp/bin/psql"
  local CEN="$tmp/repo/deploy/db-undeclared-index-census.sh"

  # (a) MANIFEST derives the three nameable shapes
  local man; man="$("$CEN" --manifest 2>/dev/null)"
  local a_ok=1
  for want in deployments_site_id_inserted_at_index sites_team_slug_unique_idx documents_search_vector_idx; do
    grep -qxF "$want" <<<"$man" || { a_ok=0; echo "    missing: $want"; }
  done
  [ "$a_ok" = 1 ] && ok "(a) manifest derives derived-name, explicit-name and raw-SQL shapes" \
                   || bad "(a) manifest derives derived-name, explicit-name and raw-SQL shapes"

  # (b) the expression index is COUNTED as a blind spot, not silently dropped
  if grep -q 'BLIND SPOT: 1 ' <<<"$man"; then ok "(b) the expression index is counted on the BLIND SPOT line"
  else bad "(b) the expression index is counted on the BLIND SPOT line (got: $(grep 'BLIND SPOT' <<<"$man"))"; fi

  # (c) RED — a hand-created tmp_* index the tree does not declare must red,
  #     naming it. This is `tmp_dep_site_live` reproduced.
  cat > "$tmp/rows_dirty" <<'ROWS'
public|deployments|deployments_site_id_inserted_at_index
public|deployments|deployments_pkey
public|sites|sites_team_slug_unique_idx
public|documents|documents_search_vector_idx
public|deployments|tmp_dep_site_live
ROWS
  local out rc
  out="$(PATH="$tmp/bin:$PATH" STUB_ROWS="$tmp/rows_dirty" "$CEN" --check 2>&1)"; rc=$?
  if [ "$rc" = 1 ] && grep -q 'tmp_dep_site_live|UNDECLARED' <<<"$out" && grep -q 'UNDECLARED: 1' <<<"$out"; then
    ok "(c) RED: a hand-created undeclared index reds rc=1 and is named"
  else bad "(c) RED: a hand-created undeclared index reds rc=1 and is named (rc=$rc)"; fi

  # (d) QUIET — the SAME fixture with that one row removed must stay rc=0.
  #     Paired with (c): a detector that always fires fails here.
  grep -v tmp_dep_site_live "$tmp/rows_dirty" > "$tmp/rows_clean"
  out="$(PATH="$tmp/bin:$PATH" STUB_ROWS="$tmp/rows_clean" "$CEN" --check 2>&1)"; rc=$?
  if [ "$rc" = 0 ] && grep -q 'UNDECLARED: 0' <<<"$out"; then
    ok "(d) QUIET: the same rows minus the stray index stay rc=0"
  else bad "(d) QUIET: the same rows minus the stray index stay rc=0 (rc=$rc)"; fi

  # (e) a failed read REFUSES (2) rather than answering a comfortable zero
  out="$(PATH="$tmp/bin:$PATH" STUB_MODE=fail STUB_ROWS="$tmp/rows_clean" "$CEN" --check 2>&1)"; rc=$?
  if [ "$rc" = 2 ] && grep -q 'CANNOT READ' <<<"$out" && ! grep -q 'UNDECLARED:' <<<"$out"; then
    ok "(e) a failed pg_indexes read exits 2 CANNOT READ and prints no table"
  else bad "(e) a failed pg_indexes read exits 2 CANNOT READ and prints no table (rc=$rc)"; fi

  # (f) an EMPTY read also refuses — the zero-rows fraud has its own arm
  out="$(PATH="$tmp/bin:$PATH" STUB_MODE=empty STUB_ROWS="$tmp/rows_clean" "$CEN" --check 2>&1)"; rc=$?
  if [ "$rc" = 2 ] && grep -q 'ZERO rows' <<<"$out"; then
    ok "(f) a zero-row pg_indexes read exits 2 rather than reporting 0 undeclared"
  else bad "(f) a zero-row pg_indexes read exits 2 rather than reporting 0 undeclared (rc=$rc)"; fi

  # (g) READONLY: the file contains no DDL/DML verb at statement position.
  #     The needle is assembled at runtime so the guard cannot match its own line.
  local ddl; ddl="$(printf 'CREATE%sINDEX|DROP%sINDEX|INSERT%sINTO|UPDATE%sSET|DELETE%sFROM' ' ' ' ' ' ' ' ' ' ')"
  # Scan only the operative region — everything ABOVE the selftest, which owns
  # the fixtures that legitimately contain SQL text.
  local operative; operative="$tmp/operative.sh"
  sed -n "1,/^cmd_selftest() {/p" "$CEN" > "$operative"
  local hits; hits="$(grep -nEi "(${ddl})" "$operative" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  if [ -z "$hits" ]; then ok "(g) READONLY: no write statement anywhere outside comments and fixtures"
  else bad "(g) READONLY: found $(wc -l <<<"$hits" | tr -d ' ') write-verb line(s)"; echo "$hits"; fi

  # (h) RO-CONTROL for (g): the same grep MUST find a planted write in a copy,
  #     so a broken search cannot read as "clean".
  cp "$operative" "$tmp/planted.sh"
  printf '\nfoo() { psql -c "DROP INDEX tmp_dep_site_live"; }\n' >> "$tmp/planted.sh"
  #     Captured, not piped into a truncating reader: `grep -qv` closes the pipe
  #     on its first match and the producer takes SIGPIPE, so under this script's
  #     `set -uo pipefail` the pipeline's status is 141 and the `if` reads FALSE —
  #     this control would report "broken" at exactly the moment the grep WORKED.
  #     `grep -v` reads all input, so it cannot SIGPIPE; `|| true` absorbs no-match.
  local planted; planted="$(grep -nEi "(${ddl})" "$tmp/planted.sh" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  if [ -n "$planted" ]; then
    ok "(h) RO-CONTROL: the readonly grep finds a planted write in a copy"
  else bad "(h) RO-CONTROL: the readonly grep is broken — it missed a planted write"; fi

  # (i) the manifest REFUSES when no migration root exists, rather than
  #     printing an empty set that would make every live index UNDECLARED.
  mkdir -p "$tmp/bare/deploy"
  cp "$CEN" "$tmp/bare/deploy/db-undeclared-index-census.sh"
  out="$("$tmp/bare/deploy/db-undeclared-index-census.sh" --manifest 2>&1)"; rc=$?
  if [ "$rc" = 2 ] && grep -q 'CANNOT READ' <<<"$out"; then
    ok "(i) an absent migration tree exits 2, never an empty manifest"
  else bad "(i) an absent migration tree exits 2, never an empty manifest (rc=$rc)"; fi

  # (j) PROSE IS NOT A DECLARATION. The fixture above quotes
  #     `CREATE INDEX tmp_dep_site_live` inside a @moduledoc. If that quotation
  #     enters the manifest, arm (c) passes for the wrong reason forever after.
  #     Its control is arm (a): the `execute(...)` statement in the SAME tree
  #     must still be declared, so this is not bought by matching nothing.
  if ! grep -qxF tmp_dep_site_live <<<"$("$CEN" --manifest 2>/dev/null)"; then
    ok "(j) a CREATE INDEX quoted in a doc comment does NOT enter the manifest"
  else bad "(j) a CREATE INDEX quoted in a doc comment leaked into the manifest"; fi

  # (k) A MULTI-LINE `create index(` RESOLVES TO ITS EXPLICIT NAME. The wave-11
  #     repair puts `name:` on the third line; a single-line reader derives the
  #     POSITIONAL name instead and the real index reads UNDECLARED on prod.
  #     Paired: the explicit name must be present AND the positional one absent,
  #     so neither an always-emit nor an always-drop parser passes.
  local man2; man2="$("$CEN" --manifest 2>/dev/null)"
  if grep -qxF multi_a_b_named_idx <<<"$man2" && ! grep -qxF multi_a_b_index <<<"$man2"; then
    ok "(k) a multi-line create index resolves to its explicit name, not the positional one"
  else bad "(k) a multi-line create index resolves to its explicit name, not the positional one"; fi

  # (l) THE ARM FOR (h) ITSELF, BOTH WAYS — and it deliberately does NOT contain
  #     a demonstration of the broken shape. (h) is a control, and a control that
  #     inverts under load is worse than none: piping a file-sized producer into
  #     a truncating quiet reader lets it close the pipe on its first match,
  #     the producer takes SIGPIPE, `set -o pipefail` makes the pipeline 141, and
  #     an `if` on it reads FALSE — reporting "the grep is broken" at exactly the
  #     moment the grep WORKED. It is silent on small inputs and only appears as
  #     the operative region grows, which is the direction this file grows.
  #
  #     A FIRST CUT OF THIS ARM CARRIED A COPY OF THE OLD PIPELINE so it could
  #     show both verdicts side by side. That copy was itself a new high-
  #     confidence finding for the repo's pipefail-SIGPIPE scan — the arm against
  #     the defect reintroduced the defect, and the baseline went 101 -> 102. The
  #     demonstration is therefore left to the scan, which already reds on the
  #     site, and this arm asserts the two things the scan cannot:
  #
  #     REVERT half: the RO-CONTROL site is in the CAPTURE shape. Restoring the
  #     piped shape reds here as well as on the scan.
  #     QUIET half: the shipped shape answers correctly on the sizes this file
  #     actually has, and on both true negatives.
  local l_ddl l_small l_none l_cmt l_ok
  l_ok=1
  #     Checked on the OPERATIVE LINES, not on a prose range: this arm's own
  #     commentary must never be able to satisfy or break it.
  local l_piped l_captured
  l_piped="$(grep -c 'planted\.sh" | grep -qv' "${BASH_SOURCE[0]}" || true)"
  l_captured="$(grep -c 'if \[ -n "\$planted" \]; then' "${BASH_SOURCE[0]}" || true)"
  [ "$l_piped" = 0 ]    || l_ok=0   # REVERT: the truncating reader is back at the site
  [ "$l_captured" = 1 ] || l_ok=0   # and the capture shape is the one present
  l_ddl="$(printf 'CREATE%sINDEX|DROP%sINDEX' ' ' ' ')"
  l_hits() { local h; h="$(grep -nEi "(${l_ddl})" "$1" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
             if [ -n "$h" ]; then echo FOUND; else echo MISSED; fi; }
  l_small="$tmp/arm_small.sh"; printf 'psql -c "DROP INDEX tmp_a";\n' > "$l_small"
  [ "$(l_hits "$l_small")" = FOUND ]  || l_ok=0   # QUIET: a real hit at today's sizes
  l_none="$tmp/arm_none.sh";  printf 'echo hello\n' > "$l_none"
  [ "$(l_hits "$l_none")" = MISSED ]  || l_ok=0   # QUIET: a true negative
  l_cmt="$tmp/arm_cmt.sh";    printf '  # DROP INDEX only in a comment\n' > "$l_cmt"
  [ "$(l_hits "$l_cmt")" = MISSED ]   || l_ok=0   # QUIET: comment-only is not a hit
  if [ "$l_ok" = 1 ]; then
    ok "(l) ARM for (h): the site is in the capture shape, and that shape answers correctly on a hit, a true negative and a comment-only line"
  else bad "(l) ARM for (h): the site is in the capture shape, and that shape answers correctly on a hit, a true negative and a comment-only line"; fi

  # ─────────────────────────────────────────────────────────────────────────
  # (m)(n)(o) THE DERIVE-LOOP COUNT IDENTITY, on its own fixture repo.
  #
  # `derive_manifest` reads its `find` output on fd 0. A body child that reads
  # stdin eats the remaining paths and the loop ends early with NO error and NO
  # non-zero status — the manifest just gets shorter, and a shorter ALLOW set is
  # a burst of FALSE UNDECLAREDs against production schema.
  #
  # The fixture is ordered so the SHORT read is invisible to every pre-existing
  # defence: the expression index (the only BLIND SPOT contributor) lives in the
  # FIRST file read, so a loop that reads 1 of 3 files reports the SAME
  # `BLIND SPOT: 1` as a loop that reads 3 of 3. The tally counts declarations
  # it could not PARSE; a file it never OPENED is in neither tally. That is
  # arm (n), and it is why the identity is a separate quantity.
  local drepo="$tmp/drainrepo"
  mkdir -p "$drepo/deploy" "$drepo/api/priv/repo/migrations" "$drepo/cloud/priv/repo/migrations"
  # api is enumerated FIRST, so this file is the one a short loop does read.
  cat > "$drepo/api/priv/repo/migrations/20260201000000_first.exs" <<'D1'
defmodule D1 do
  use Ecto.Migration
  def change do
    create index(:alpha, [:x])
    create index(:barkparks, ["lower(name)"])
  end
end
D1
  cat > "$drepo/cloud/priv/repo/migrations/20260202000000_second.exs" <<'D2'
defmodule D2 do
  use Ecto.Migration
  def change do
    create index(:beta, [:y])
  end
end
D2
  cat > "$drepo/cloud/priv/repo/migrations/20260203000000_third.exs" <<'D3'
defmodule D3 do
  use Ecto.Migration
  def change do
    create index(:gamma, [:z])
  end
end
D3

  local intact="$drepo/deploy/intact.sh"
  local drain="$drepo/deploy/drain.sh"
  local prefix="$drepo/deploy/prefix.sh"
  cp "$CEN" "$intact"
  # THE PLANTED CHILD: `cat >/dev/null` in the loop body, at the anchor, draining
  # fd 0 on the first iteration. The anchor must be unique and the splice must
  # change the file, or this control would pass while planting nothing.
  # The three anchor literals are ASSEMBLED AT RUNTIME, exactly as arm (g)'s DDL
  # needle is, so this block cannot match ITSELF: a literal spelled here would
  # make `grep -c` read 3-for-1 and would let `sed` rewrite these very lines in
  # the copy it is building.
  local a_head a_id_start a_id_end
  a_head="$(printf 'MUT-ANCHOR:%sderive-loop-body-head' ' ')"
  a_id_start="$(printf 'MUT-ANCHOR:%sderive-count-identity' ' ')"
  a_id_end="$(printf 'MUT-END:%sderive-count-identity' ' ')"
  local n_anchor; n_anchor="$(grep -c "$a_head" "$intact")"
  sed "s|# ${a_head}|cat >/dev/null|" "$intact" > "$drain"
  # And the SAME plant with the identity block cut out — the shipped behaviour
  # BEFORE this fix, kept runnable so arm (n) can read what it used to print.
  sed "/${a_id_start}/,/${a_id_end}/d" "$drain" > "$prefix"
  chmod +x "$intact" "$drain" "$prefix"
  local spliced=1
  [ "$n_anchor" = 1 ]        || spliced=0
  cmp -s "$intact" "$drain"  && spliced=0
  cmp -s "$drain" "$prefix"  && spliced=0

  # (o) POSITIVE CONTROL first: the UNMUTATED script over this fixture derives
  #     all three names, counts 3 of 3, and refuses nothing.
  local o_out o_rc
  o_out="$("$intact" --manifest 2>&1)"; o_rc=$?
  if [ "$o_rc" = 0 ] \
     && grep -qxF alpha_x_index <<<"$o_out" \
     && grep -qxF beta_y_index <<<"$o_out" \
     && grep -qxF gamma_z_index <<<"$o_out" \
     && ! grep -q 'SHORT DERIVE' <<<"$o_out"; then
    ok "(o) QUIET: an unmutated derive over the same fixture emits the FULL manifest and refuses nothing"
  else bad "(o) QUIET: an unmutated derive over the same fixture emits the FULL manifest and refuses nothing (rc=$o_rc)"; fi

  # (m) RED: with the drain planted, the derive loop reads 1 of 3 files. The
  #     identity must refuse, NAME BOTH NUMBERS, and print no manifest at all —
  #     not one name, because every name it would print is an ALLOW entry and
  #     every name it would OMIT becomes an UNDECLARED row downstream.
  local m_out m_rc
  m_out="$("$drain" --manifest 2>&1)"; m_rc=$?
  if [ "$spliced" = 1 ] && [ "$m_rc" = 2 ] \
     && grep -q 'SHORT DERIVE' <<<"$m_out" \
     && grep -q 'read 1 of 3 migration file' <<<"$m_out" \
     && ! grep -qxF alpha_x_index <<<"$m_out" \
     && ! grep -q '^DECLARED:' <<<"$m_out"; then
    ok "(m) RED: a stdin-draining child in the derive loop body makes the count identity refuse, naming 1 of 3, and no manifest is printed"
  else bad "(m) RED: a stdin-draining child in the derive loop body makes the count identity refuse, naming 1 of 3, and no manifest is printed (rc=$m_rc spliced=$spliced)"; echo "$m_out" | sed -n '1,6p'; fi

  # (n) THE DISTINCTION. Same plant, identity CUT — i.e. what this script did
  #     before the fix. It exits 0, prints a manifest SHORT by two names, and
  #     its BLIND SPOT line is BYTE-IDENTICAL to the full run's. The tally that
  #     already existed is blind to this by construction, so the identity is not
  #     a duplicate of it.
  local n_out n_rc n_blind o_blind
  n_out="$("$prefix" --manifest 2>&1)"; n_rc=$?
  n_blind="$(grep '^BLIND SPOT:' <<<"$n_out" || true)"
  o_blind="$(grep '^BLIND SPOT:' <<<"$o_out" || true)"
  if [ "$spliced" = 1 ] && [ "$n_rc" = 0 ] \
     && grep -qxF alpha_x_index <<<"$n_out" \
     && ! grep -qxF beta_y_index <<<"$n_out" \
     && ! grep -qxF gamma_z_index <<<"$n_out" \
     && ! grep -q 'SHORT DERIVE' <<<"$n_out" \
     && [ -n "$o_blind" ] && [ "$n_blind" = "$o_blind" ]; then
    ok "(n) the BLIND SPOT tally does NOT move under that same short read — identical line over 1 of 3 files as over 3 of 3, while the manifest loses two names"
  else bad "(n) the BLIND SPOT tally does NOT move under that same short read (rc=$n_rc spliced=$spliced blind_short=[$n_blind] blind_full=[$o_blind])"; fi

  echo "=== $pass passed, $fail failed ==="
  rm -rf "$tmp"
  [ "$fail" = 0 ] || return 1
  [ "$pass" -ge 15 ] || { echo "REFUSING: fewer arms ran than this selftest declares." >&2; return 1; }
  return 0
}

usage() {
  sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  return 3
}

main() {
  case "${1:-}" in
    --manifest) shift; cmd_manifest "$@" ;;
    --check)    shift; cmd_check "$@" ;;
    --selftest) shift; cmd_selftest ;;
    *)          usage ;;
  esac
}
main "$@"
