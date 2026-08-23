#!/usr/bin/env bash
# pds-secret-scan.sh — the VALUE-based secret scan for bp-export-v1 bundles
# (PDS wave 2; charter decisions PDS-D24/D25/D26 under the PDS-D20 anti-vacuity
# doctrine).
#
# THE QUESTION IT ANSWERS: "is this bundle provably stripped?" — with an answer
# a broken build could not also produce.
#
# WHY VALUE-BASED, NOT COLUMN-NAME-BASED. A scan shaped like
# `… WHERE column_name LIKE '%secret%'` scores clean on an EMPTY bundle, on a
# TRUNCATED bundle, and on a bundle whose secrets were renamed — it measures the
# schema, not the bytes. This scan takes known secret VALUES as ammo and greps
# for those exact bytes across every member of an extracted bundle tar, and
# (optionally) across a target Postgres DB via a per-table
# `WHERE t::text ~ <alternation>`. If the value is in there, the scan fires.
#
# THE VALUE SHAPE HAS ITS OWN VACUITY, AND IT REFUSES INSTEAD. A value scan
# over ZERO bytes is exactly as clean as the column scan it replaces: an empty
# or manifest-only bundle, an unreachable DB, and a zero-table schema all have
# nothing to fire on. Each of those is a REFUSED-TO-MEASURE exit 2 here, never
# a CLEAN — and control steps 4-5 prove both refusal arms actually fire.
#
# THE AMMO — what was ruled OUT, and why (each checked live; do not re-litigate):
#   * webhook_deliveries.payload_snapshot — RULED OUT (PDS-D24). Guerrilla's
#     10,544 delivery rows are 100% source_kind=document with payload_snapshot
#     NULL. Structurally, `media` is the only kind that embeds a secret in the
#     snapshot, and `create_media_delivery/1` sets NO endpoint_id, so the E2
#     INNER JOIN (`JOIN webhooks w ON w.id = t.endpoint_id`) excludes those rows
#     from EVERY bundle in EVERY profile. A control anchored there scores zero
#     on the FULL bundle too — it silently stops being a control.
#   * secrets / secrets_audit — one row DB-wide with workspace_id IS NULL,
#     structurally excluded from every workspace-scoped export by the tenant wall.
#   * api_tokens — hashed at rest. access_grants — 2 revoked synthetic rows
#     (kept as a secondary PII signal, not as the discriminator).
#
#   THE ONE REAL DISCRIMINATOR is `webhooks.secret`: a plain Ecto :string, 8 rows
#   on guerrilla, 8 distinct 43-char plaintext values, workspace-attributed, E1
#   (guaranteed present in a FULL bundle) and `:deny` in the dev partition
#   (guaranteed absent from a DEV bundle). The control is anchored there.
#
# HONEST MECHANISM LANGUAGE (PDS-D25). `@dev_scrub` is genuinely `%{}` — the dev
# partition ships ZERO field-level scrubs. A clean dev scan proves the TABLE IS
# ABSENT (`:deny`), never that a field was "scrubbed". This script never prints
# the word "scrubbed" about the dev profile; it prints "mechanism = table DENY".
#
# Usage:
#   scripts/pds-secret-scan.sh scan --bundle <tar> [--db <conninfo>] \
#       [--value <v>]... [--ammo-file <f>] [--extra-patterns <f>] \
#       [--ammo-from-db <conninfo>] [--profile full|dev|personal-local] [--reveal]
#   scripts/pds-secret-scan.sh control [--pg <maintenance conninfo>] [--keep]
#   scripts/pds-secret-scan.sh --help
#
# Exit codes:
#   0  scan clean (no ammo value found) / control PASSED
#   1  HITS — at least one ammo value found in the bundle or the target DB
#   2  usage or environment error, or REFUSED TO MEASURE (no ammo, missing
#      psql/tar, unreadable/empty/table-less bundle, unreachable DB, zero-table
#      schema) — an empty corpus never reads as 0 CLEAN
#   3  control mode did not behave as a control must (did not FIRE on the full
#      bundle, or did not come back CLEAN on the deny-shaped bundle)
#
# bash 3.2 compatible (macOS system bash). Read-only against any DB you point it
# at in scan mode; `control` creates and drops its OWN throwaway local database.
set -euo pipefail

SELF="$(basename "$0")"

# ── output helpers ───────────────────────────────────────────────────────────
say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 2; }
rule() { printf -- '─%.0s' $(seq 1 72); printf '\n'; }

usage() {
  # Print the whole header, however long it grows: a fixed '2,60p' silently
  # truncated the usage text every time the header gained a line.
  sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

# Mask an ammo value for logs: length + first 4 bytes + a sha256 fingerprint.
# A CI log should never carry the plaintext, but the operator still needs to
# know WHICH value fired.
mask() {
  local v="$1" fp
  if command -v shasum >/dev/null 2>&1; then
    fp="$(printf '%s' "$v" | shasum -a 256 | cut -c1-8)"
  else
    fp="$(printf '%s' "$v" | sha256sum | cut -c1-8)"
  fi
  printf '%s…(%d bytes, sha256:%s)' "$(printf '%s' "$v" | cut -c1-4)" "${#v}" "$fp"
}

# A value-taking flag with nothing after it USED to fall through `${2:-}` and
# then die on `shift 2` — which under `set -e` exits 1 with no output at all.
# Exit 1 is the HIT code: a typo'd invocation would read as "secrets found"
# while nothing was ever scanned. Refuse loudly with the usage code instead.
need_val() { # "$@" as seen at the flag
  [ $# -ge 2 ] || die "$1 needs a value"
}

show() { # respects --reveal
  if [ "$REVEAL" = "1" ]; then printf '%s' "$1"; else mask "$1"; fi
}

# ── the two stated limits (always printed; they BOUND the claim) ─────────────
print_limits() {
  say ""
  say "LIMITS — these bound the claim this scan can support:"
  say "  1. VERBATIM-VALUE-BASED ONLY. It matches the exact bytes it was given."
  say "     It does NOT detect derived material — base64/hex re-encodings, prefix"
  say "     slices, HMACs, hashes, or values inside compressed members."
  say "  2. ABSENCE-OF-GIVEN-VALUES ONLY. A clean result proves the target is free"
  say "     of the values you ENUMERATED — never that it is free of secrets nobody"
  say "     enumerated."
}

# ── ammo ─────────────────────────────────────────────────────────────────────
# Ammo lives in a temp file, one `label<TAB>value` line per value.
AMMO_FILE=""
MIN_AMMO_LEN=8   # anti-vacuity: a 1-byte "secret" would hit everything and a
                 # short one would hit nothing meaningful; both make the scan a lie.

ammo_add() { # label value
  local label="$1" value="$2"
  [ -n "$value" ] || return 0
  if [ "${#value}" -lt "$MIN_AMMO_LEN" ]; then
    warn "$SELF: refusing ammo '$label' — $((${#value})) bytes is under the $MIN_AMMO_LEN-byte floor (a short value makes the scan meaningless)"
    return 1
  fi
  printf '%s\t%s\n' "$label" "$value" >> "$AMMO_FILE"
}

ammo_add_file() { # label-prefix path
  local prefix="$1" path="$2" n=0 line
  [ -r "$path" ] || die "cannot read ammo file: $path"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    n=$((n + 1))
    ammo_add "$prefix#$n" "$line" || true
  done < "$path"
}

ammo_add_from_db() { # conninfo — pull the live discriminators, read-only
  local conn="$1" v n=0
  command -v psql >/dev/null 2>&1 || die "--ammo-from-db needs psql on PATH"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    n=$((n + 1))
    ammo_add "webhooks.secret#$n" "$v" || true
  done < <(psql "$conn" -At -c \
    "SELECT secret FROM public.webhooks WHERE secret IS NOT NULL AND secret <> ''" 2>/dev/null || true)
  n=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    n=$((n + 1))
    ammo_add "access_grants.grantee_email#$n" "$v" || true
  done < <(psql "$conn" -At -c \
    "SELECT grantee_email FROM public.access_grants WHERE grantee_email IS NOT NULL AND grantee_email <> ''" 2>/dev/null || true)
}

ammo_count() { [ -s "$AMMO_FILE" ] && wc -l < "$AMMO_FILE" | tr -d ' ' || echo 0; }

# ── the bundle scan: raw bytes, every member ────────────────────────────────
# Returns the hit count via the global HITS; prints one line per hit.
scan_bundle() { # tar-path
  local bundle="$1" dir member label value n rel first table_members
  [ -r "$bundle" ] || die "cannot read bundle: $bundle"
  dir="$(mktemp -d "${TMPDIR:-/tmp}/pds-scan.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $dir"

  tar -xf "$bundle" -C "$dir" || die "not a readable tar: $bundle"

  local members=0
  table_members=0
  say "bundle: $bundle"
  while IFS= read -r member; do
    members=$((members + 1))
    rel="${member#"$dir"/}"
    case "$rel" in tables/*) table_members=$((table_members + 1)) ;; esac
    while IFS="$(printf '\t')" read -r label value; do
      n="$(grep -a -c -F -e "$value" -- "$member" 2>/dev/null || true)"
      n="${n:-0}"
      if [ "$n" -gt 0 ]; then
        first="$(grep -a -n -m1 -F -e "$value" -- "$member" 2>/dev/null | cut -d: -f1)"
        HITS=$((HITS + 1))
        say "  HIT  member=$rel  ammo=$label  value=$(show "$value")  lines=$n  first_line=${first:-?}"
      fi
    done < "$AMMO_FILE"
  done < <(find "$dir" -type f | sort)

  # PDS-D20 anti-vacuity, aimed at this scan's OWN blind spot: a value scan
  # over zero bytes is vacuously clean. An empty tar has no members; a
  # truncated or manifest-only container has no tables/ member; in both cases
  # the ammo loop never ran, so a CLEAN verdict would be a true green about
  # nothing. Refuse to measure (exit 2) instead of printing it.
  if [ "$members" -eq 0 ]; then
    die "bundle contains ZERO members — an empty or truncated tar. A scan over nothing proves nothing; refusing to print CLEAN."
  fi
  if [ "$table_members" -eq 0 ]; then
    die "bundle carries no tables/ member ($members member(s) total, e.g. manifest-only) — none of the bytes this scan exists to check are present; refusing to print CLEAN."
  fi

  say "  members scanned: $members ($table_members under tables/)   ammo values: $(ammo_count)"
}

# ── the target-DB scan: per-table `t::text ~ <alternation>` ──────────────────
regex_escape() { # POSIX-ERE-escape a literal value
  printf '%s' "$1" | sed 's/[][\\^$.|?*+(){}]/\\&/g'
}
sql_quote() { printf '%s' "$1" | sed "s/'/''/g"; }

scan_db() { # conninfo
  local conn="$1" alt="" label value table count tables=0 errf reason
  command -v psql >/dev/null 2>&1 || die "--db needs psql on PATH"
  errf="$(mktemp "${TMPDIR:-/tmp}/pds-scan-err.XXXXXX")"
  TMP_FILES="$TMP_FILES $errf"

  while IFS="$(printf '\t')" read -r label value; do
    if [ -z "$alt" ]; then alt="$(regex_escape "$value")"
    else alt="$alt|$(regex_escape "$value")"; fi
  done < "$AMMO_FILE"
  [ -n "$alt" ] || die "no ammo to scan the DB with"
  alt="($alt)"

  say "target DB: $(printf '%s' "$conn" | sed 's/password=[^ ]*/password=***/')"

  # Enumerate FIRST, capturing psql's own exit status. The old shape piped the
  # enumeration through `2>/dev/null || true`, which converted an unreachable
  # DB, a bad conninfo, or a permission failure into an EMPTY table list — and
  # an empty corpus scans vacuously CLEAN. A failed enumeration is a refusal in
  # its own right, distinct from a reachable-but-empty schema.
  local tlist
  tlist="$(mktemp "${TMPDIR:-/tmp}/pds-scan-tables.XXXXXX")"
  TMP_FILES="$TMP_FILES $tlist"
  if ! psql "$conn" -At -c \
    "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p') ORDER BY 1" \
    >"$tlist" 2>"$errf"; then
    die "cannot enumerate schema public — psql failed: $(head -1 "$errf" 2>/dev/null | cut -c1-200). An unreachable or unqueryable DB is an empty corpus; refusing to print CLEAN."
  fi

  while IFS= read -r table; do
    [ -n "$table" ] || continue
    tables=$((tables + 1))
    count="$(psql "$conn" -At -c \
      "SELECT count(*) FROM public.\"$table\" t WHERE t::text ~ '$(sql_quote "$alt")'" 2>"$errf" || echo "")"
    if [ -z "$count" ]; then
      # Say WHY it was skipped — a permission-invisible table must be named as
      # such, never blamed on a missing text cast (that false reason is exactly
      # the class this instrument exists to kill).
      if grep -q 'permission denied' "$errf" 2>/dev/null; then
        reason="permission denied — the connecting role cannot read it"
      else
        reason="$(head -1 "$errf" 2>/dev/null | cut -c1-160)"
        [ -n "$reason" ] || reason="query returned nothing"
      fi
      say "  skip table=$table (not scannable — $reason; counted as UNSCANNED)"
      UNSCANNED=$((UNSCANNED + 1))
      continue
    fi
    if [ "$count" -gt 0 ]; then
      HITS=$((HITS + 1))
      say "  HIT  table=$table  rows_matching_ammo=$count"
    fi
  done < "$tlist"

  # pg_class, NOT information_schema.tables: information_schema filters by the
  # CONNECTING ROLE's privileges, so a table the role holds no privilege on
  # drops out of the enumeration entirely and the scan reports "tables
  # scanned: 0 · RESULT: CLEAN" with no disclosure — with the secret still in
  # the database (run-proven with a REVOKE ALL role). pg_class names every
  # ordinary and partitioned table regardless of privilege; a table the role
  # cannot read then lands in the UNSCANNED branch above WITH its reason.
  if [ "$tables" -eq 0 ]; then
    die "schema public holds ZERO base tables — the DB answered but there is nothing to scan. A scan over nothing proves nothing; refusing to print CLEAN."
  fi

  say "  tables scanned: $tables   ammo values: $(ammo_count)"
}

# ── mechanism sentence (PDS-D25 honesty) ────────────────────────────────────
mechanism_line() { # profile clean?
  case "$1" in
    dev)
      say "dev profile: $HITS hits — mechanism = table DENY (webhooks and access_grants"
      say "  are :deny in the dev partition, so the members are ABSENT). No field-level"
      say "  scrub is configured — @dev_scrub is empty — so nothing here was scrubbed."
      ;;
    personal-local)
      say "personal-local profile: $HITS hits — this profile is FULL fidelity; a clean"
      say "  result here means only that the enumerated values were not present."
      ;;
    full)
      say "full profile: $HITS hits — full fidelity carries every E1 table verbatim,"
      say "  including webhooks.secret. Hits are EXPECTED here; zero hits means the"
      say "  ammo was wrong, not that the bundle is clean."
      ;;
    *) : ;;
  esac
}

# ── subcommand: scan ─────────────────────────────────────────────────────────
cmd_scan() {
  local bundle="" db="" profile="" from_db=""
  AMMO_FILE="$(mktemp "${TMPDIR:-/tmp}/pds-ammo.XXXXXX")"
  TMP_FILES="$TMP_FILES $AMMO_FILE"

  while [ $# -gt 0 ]; do
    case "$1" in
      --bundle)          need_val "$@"; bundle="$2"; shift 2 ;;
      --db)              need_val "$@"; db="$2"; shift 2 ;;
      --value)           need_val "$@"; ammo_add "value#$(( $(ammo_count) + 1 ))" "$2" || true; shift 2 ;;
      --ammo-file)       need_val "$@"; ammo_add_file "ammo" "$2"; shift 2 ;;
      --extra-patterns)  need_val "$@"; ammo_add_file "extra" "$2"; shift 2 ;;
      --ammo-from-db)    need_val "$@"; from_db="$2"; shift 2 ;;
      --profile)         need_val "$@"; profile="$2"; shift 2 ;;
      --reveal)          REVEAL=1; shift ;;
      -h|--help)         usage 0 ;;
      *) die "unknown flag for scan: $1" ;;
    esac
  done

  [ -n "$from_db" ] && ammo_add_from_db "$from_db"
  [ -n "$bundle" ] || [ -n "$db" ] || die "scan needs --bundle and/or --db"
  [ "$(ammo_count)" -gt 0 ] || die "no ammo — pass --value / --ammo-file / --ammo-from-db (a scan with no ammo is not a scan)"

  rule
  say "PDS value-based secret scan — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  rule
  [ -n "$bundle" ] && scan_bundle "$bundle"
  [ -n "$db" ] && scan_db "$db"
  rule
  if [ "$HITS" -gt 0 ]; then
    say "RESULT: $HITS HIT(S) — enumerated secret values are present in the target."
  else
    say "RESULT: CLEAN — 0 hits for $(ammo_count) enumerated value(s)."
  fi
  [ "$UNSCANNED" -gt 0 ] && say "NOTE: $UNSCANNED table(s) were UNSCANNED (see skip lines above) — not proven clean."
  mechanism_line "$profile"
  print_limits
  [ "$HITS" -gt 0 ] && return 1
  return 0
}

# ── subcommand: control — the load-bearing artifact ─────────────────────────
# A scan that has never fired is not a scan. This mode proves the instrument
# FIRES (full-fidelity bundle carrying a known webhook secret + grantee
# email), comes back CLEAN (the same bundle without the denied members), and
# REFUSES on a corpus of zero (a manifest-only bundle and a dead conninfo must
# both exit 2 — a green over nothing is not a green).
#
# PDS-D31 RAM LAW: this control is seeded LOCALLY and spends NO live guerrilla
# export. A live full export peaks beam.smp at 1.83 GB RSS on a 3.8 GB box; two
# at once would OOM the LIVE content API. The fixture bundle here is built from
# real `COPY (SELECT …) TO STDOUT` bytes over a throwaway local database, in the
# same bp-export-v1 container shape (manifest.json + tables/<name>.copy) the
# engine emits — so the scan is exercised against real COPY bytes, not echoes.
cmd_control() {
  local maint="${PDS_CONTROL_PG:-postgres}" keep=0 broken=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --pg)   need_val "$@"; maint="$2"; shift 2 ;;
      --keep) keep=1; shift ;;
      # Tripwire for the control ITSELF: hand step 1 a deny-shaped bundle so the
      # instrument CANNOT fire, and assert this mode exits 3. A control that
      # cannot fail is not a control either.
      --simulate-broken-instrument) broken=1; shift ;;
      -h|--help) usage 0 ;;
      *) die "unknown flag for control: $1" ;;
    esac
  done
  command -v psql    >/dev/null 2>&1 || die "control needs psql on PATH"
  command -v tar     >/dev/null 2>&1 || die "control needs tar on PATH"
  # The ammo is generated fresh per run so a stale hard-coded value can never be
  # what makes the control pass — which makes openssl a hard prerequisite, not a
  # nicety. Without this check the seed silently becomes an EMPTY secret and the
  # control "passes" against nothing.
  command -v openssl >/dev/null 2>&1 || die "control needs openssl on PATH (it generates the run's ammo)"

  local db="pds_secret_scan_ctl_$$"
  local work; work="$(mktemp -d "${TMPDIR:-/tmp}/pds-control.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $work"

  rule
  say "PDS secret-scan POSITIVE CONTROL — locally seeded, no live export spent"
  say "  throwaway database: $db (created and dropped by this run)"
  rule

  psql "$maint" -q -c "CREATE DATABASE \"$db\"" >/dev/null
  CONTROL_DB="$db"; CONTROL_MAINT="$maint"; CONTROL_KEEP="$keep"

  # Known ammo, generated fresh each run so a stale hard-coded value can never
  # be what makes this pass.
  local secret email
  secret="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-43)"
  email="pds-control-$$@barkpark.invalid"

  psql "$db" -q <<SQL >/dev/null
CREATE TABLE public.workspaces (id uuid PRIMARY KEY, slug text NOT NULL);
CREATE TABLE public.webhooks (
  id uuid PRIMARY KEY, workspace_id uuid NOT NULL, name text, url text, secret text
);
CREATE TABLE public.access_grants (
  id uuid PRIMARY KEY, workspace_id uuid NOT NULL, grantee_email text, revoked_at timestamptz
);
CREATE TABLE public.documents (
  id uuid PRIMARY KEY, workspace_id uuid NOT NULL, type text, content jsonb
);
INSERT INTO public.workspaces VALUES ('00000000-0000-0000-0000-000000000001'::uuid, 'control-ws');
INSERT INTO public.webhooks VALUES
  ('00000000-0000-0000-0000-0000000000e1'::uuid,
   '00000000-0000-0000-0000-000000000001'::uuid,
   'control hook', 'https://example.invalid/hook', '$(sql_quote "$secret")');
INSERT INTO public.access_grants VALUES
  ('00000000-0000-0000-0000-0000000000a1'::uuid,
   '00000000-0000-0000-0000-000000000001'::uuid,
   '$(sql_quote "$email")', NULL);
INSERT INTO public.documents VALUES
  ('00000000-0000-0000-0000-0000000000d1'::uuid,
   '00000000-0000-0000-0000-000000000001'::uuid,
   'post', '{"title":"a decoy document with no secret in it"}'::jsonb);
SQL

  # Build the FULL-fidelity fixture bundle in the bp-export-v1 container shape.
  local full="$work/full"; mkdir -p "$full/tables"
  cat > "$full/manifest.json" <<JSON
{
  "format": "bp-export-v1",
  "grain": "workspace",
  "profile": "full",
  "note": "locally seeded control fixture — not a live export"
}
JSON
  local t
  for t in workspaces webhooks access_grants documents; do
    psql "$db" -At -c "COPY (SELECT * FROM public.\"$t\") TO STDOUT" > "$full/tables/$t.copy"
  done
  ( cd "$full" && tar -cf "$work/full.tar" manifest.json tables )

  # The DENY-shaped bundle: the same export minus the tables the dev partition
  # marks :deny. This is exactly what "mechanism = table DENY" looks like.
  local dev="$work/dev"; mkdir -p "$dev/tables"
  cp "$full/manifest.json" "$dev/manifest.json"
  for t in workspaces documents; do cp "$full/tables/$t.copy" "$dev/tables/$t.copy"; done
  ( cd "$dev" && tar -cf "$work/dev.tar" manifest.json tables )

  local ammo="$work/ammo.txt"
  printf '%s\n%s\n' "$secret" "$email" > "$ammo"

  local rc_fire rc_clean rc_db_fire rc_empty rc_dead
  say ""
  local step1="$work/full.tar"
  if [ "$broken" -eq 1 ]; then
    step1="$work/dev.tar"
    say "!! --simulate-broken-instrument: step 1 is handed the DENY-shaped bundle;"
    say "   this run MUST end in exit 3."
  fi
  say "STEP 1/5 — FULL-fidelity bundle must FIRE (webhooks.secret + grantee_email present)"
  rule
  set +e
  "$0" scan --bundle "$step1" --ammo-file "$ammo" --profile full
  rc_fire=$?
  set -e

  say ""
  say "STEP 2/5 — target DB must FIRE (per-table t::text ~ alternation)"
  rule
  set +e
  "$0" scan --db "$db" --ammo-file "$ammo" --profile full
  rc_db_fire=$?
  set -e

  say ""
  say "STEP 3/5 — DENY-shaped bundle (webhooks + access_grants members absent) must be CLEAN"
  rule
  set +e
  "$0" scan --bundle "$work/dev.tar" --ammo-file "$ammo" --profile dev
  rc_clean=$?
  set -e

  # Steps 4-5: the ANTI-VACUITY arms. A corpus of zero must REFUSE (exit 2),
  # never read as CLEAN — and each refusal is matched on its MESSAGE too, so a
  # regression that exits 2 for some other reason cannot impersonate it.
  say ""
  say "STEP 4/5 — manifest-only bundle (zero tables/ members) must REFUSE (exit 2)"
  rule
  local empty="$work/empty"; mkdir -p "$empty"
  cp "$full/manifest.json" "$empty/manifest.json"
  ( cd "$empty" && tar -cf "$work/empty.tar" manifest.json )
  set +e
  "$0" scan --bundle "$work/empty.tar" --ammo-file "$ammo" --profile dev >"$work/step4.out" 2>&1
  rc_empty=$?
  set -e
  cat "$work/step4.out"

  say ""
  say "STEP 5/5 — unreachable DB must REFUSE (exit 2), never scan an empty corpus as CLEAN"
  rule
  set +e
  "$0" scan --db "host=nowhere.invalid port=5432 dbname=pds_ctl_dead connect_timeout=3" \
    --ammo-file "$ammo" --profile full >"$work/step5.out" 2>&1
  rc_dead=$?
  set -e
  cat "$work/step5.out"

  rule
  local ok=1
  if [ "$rc_fire" -ne 1 ]; then
    say "CONTROL FAILED: full-fidelity bundle scan exited $rc_fire, expected 1 (a hit)."
    ok=0
  else
    say "control fires on the bundle: exit 1 with the hit named in tables/webhooks.copy"
  fi
  if [ "$rc_db_fire" -ne 1 ]; then
    say "CONTROL FAILED: target-DB scan exited $rc_db_fire, expected 1 (a hit)."
    ok=0
  else
    say "control fires on the target DB: exit 1 with the hit named per table"
  fi
  if [ "$rc_clean" -ne 0 ]; then
    say "CONTROL FAILED: deny-shaped bundle scan exited $rc_clean, expected 0 (clean)."
    ok=0
  else
    say "deny-shaped bundle is CLEAN: exit 0 against the same ammo"
  fi
  if [ "$rc_empty" -ne 2 ] || ! grep -q "refusing to print CLEAN" "$work/step4.out"; then
    say "CONTROL FAILED: manifest-only bundle scan exited $rc_empty, expected a REFUSAL (exit 2 naming the empty corpus)."
    ok=0
  else
    say "manifest-only bundle REFUSES: exit 2 — the vacuous CLEAN is unprintable"
  fi
  if [ "$rc_dead" -ne 2 ] || ! grep -q "cannot enumerate schema public" "$work/step5.out"; then
    say "CONTROL FAILED: dead-conninfo scan exited $rc_dead, expected a REFUSAL (exit 2 from the enumeration's own status)."
    ok=0
  else
    say "unreachable DB REFUSES: exit 2 carried from psql's own failure, not laundered into an empty corpus"
  fi
  rule
  if [ "$ok" -eq 1 ]; then
    say "CONTROL PASSED — the instrument fires on real secret bytes and comes back"
    say "clean when the denied members are absent. Both bundles were built from real"
    say "COPY (SELECT …) TO STDOUT bytes over local database $db; NO live guerrilla"
    say "export was spent (PDS-D31)."
    return 0
  fi
  say "CONTROL DID NOT BEHAVE AS A CONTROL — treating as failure (exit 3)."
  return 3
}

# ── cleanup ──────────────────────────────────────────────────────────────────
TMP_DIRS=""
TMP_FILES=""
CONTROL_DB=""
CONTROL_MAINT=""
CONTROL_KEEP=0
HITS=0
UNSCANNED=0
REVEAL=0

cleanup() {
  local d f
  for d in $TMP_DIRS; do [ -n "$d" ] && rm -rf "$d"; done
  for f in $TMP_FILES; do [ -n "$f" ] && rm -f "$f"; done
  if [ -n "$CONTROL_DB" ] && [ "$CONTROL_KEEP" != "1" ]; then
    psql "${CONTROL_MAINT:-postgres}" -q -c "DROP DATABASE IF EXISTS \"$CONTROL_DB\"" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ── dispatch ────────────────────────────────────────────────────────────────
case "${1:-}" in
  scan)    shift; cmd_scan "$@" ;;
  control) shift; cmd_control "$@" ;;
  -h|--help|"") usage 0 ;;
  *) die "unknown subcommand: ${1:-} (expected: scan | control)" ;;
esac
