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
#   BEHIND    a successful DELIVERING deploy.yml run in the window delivered a
#             head sha the crown has no row for. The run happened; the record
#             does not exist.
#   WRONG     a crown row inside the window names a sha that no successful
#             delivering run delivered. The record exists; the run does not.
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
# CARRIED ROWS ARE NOT WRONG. ~36% of merged shas have no run of their own and
# ride a later sha's range; the recorder marks those `carried: true`. A carried
# row naming a sha with no run of its own is CORRECT, so only NON-carried rows can
# be WRONG. A row whose `carried` is absent was never measured — it is printed as
# UNCLASSIFIED and is never counted clean.
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
#      The route's reader tier is `require_user_or_pat` + `require_ability("read")`
#      while WORKER_TOKEN is the WORKER principal, so that GET can answer 401/403.
#      When it does, this falls back to reading `platform_deliveries` directly out
#      of the control plane's own postgres container — the same crown, the same
#      box, the same SSH, no new secret and no route change — and says out loud
#      which reader produced the answer. A read that cannot happen is rc 2, never
#      a green.
#
# EXIT CODES  0 = reconciled — every delivering run has its row, every row has its
#                 run, and the serving sha is recorded
#             1 = BEHIND or WRONG (or SERVING-UNRECORDED), WITH COUNTS
#             2 = could not read, or the population was empty — a WARNING that is
#                 never counted clean. A rate with no denominator is refused.
#             3 = CONFIGURATION fault only (no jq/gh, no credential, bad flag)
#
# USAGE
#   scripts/crown-reconcile.sh --repo FRIKKern/barkpark
#   scripts/crown-reconcile.sh --window-hours 6
#   scripts/crown-reconcile.sh --runs-fixture r.json --jobs-fixture j.json \
#       --crown-fixture c.json --health-fixture h.json --now 2026-08-09T12:00:00Z
#
# The fixture flags make every classification hermetically provable; see
# scripts/crown-reconcile.test.sh, which breaks the comparison five ways and
# requires a red for each.
#
# TRANSPORT: no JSON payload is ever handed to jq as an argv word. Linux caps a
# single argv string at 131,072 bytes independently of ARG_MAX and a run listing
# crosses it. Every list travels by `--slurpfile` or stdin (charter D486).

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
API_BASE="${CROWN_API_BASE:-https://api.barkpark.cloud}"
HEALTH_URL="${CROWN_HEALTH_URL:-https://barkpark.cloud/health}"

RUNS_FIXTURE=""
JOBS_FIXTURE=""
CROWN_FIXTURE=""
HEALTH_FIXTURE=""
NOW_OVERRIDE=""

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
    --now) NOW_OVERRIDE="${2:-}"; shift 2 ;;
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

# ── clocks ───────────────────────────────────────────────────────────────────
epoch_of() { # <iso8601> -> seconds, or empty
  local iso="$1" plain
  [ -n "$iso" ] || return 1
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
CUTOFF_EPOCH=$((NOW_EPOCH - WINDOW_HOURS * 3600))
WIDE_EPOCH=$((CUTOFF_EPOCH - GRACE_HOURS * 3600))
iso_of() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }
CUTOFF_ISO="$(iso_of "$CUTOFF_EPOCH")"
NOW_ISO="$(iso_of "$NOW_EPOCH")"

# ── the two readers ──────────────────────────────────────────────────────────
READER=""
SSH=""
select_reader() {
  if [ "$FIXTURE_MODE" = "1" ]; then
    READER="fixture"
    return 0
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
CID="$(docker ps -q --filter ancestor=cloud-control_plane:latest | head -1)"
if [ -z "$CID" ]; then echo "CR_ERROR=no_control_plane_container"; exit 0; fi
WT="$(docker exec "$CID" printenv WORKER_TOKEN)"
if [ -z "$WT" ]; then echo "CR_ERROR=empty_worker_token"; exit 0; fi
CODE="$(curl -s -o /tmp/cr-body.json -w '%{http_code}' --max-time 30 -H "authorization: Bearer $WT" "https://barkpark.cloud/v1/deliveries?$QS")"
echo "CR_HTTP=$CODE"
if [ "$CODE" = "200" ]; then
  echo "CR_VIA=route"
  echo "CR_BODY=$(tr -d '\n' < /tmp/cr-body.json)"
  rm -f /tmp/cr-body.json
  exit 0
fi
# The reader route is user-or-PAT; WORKER_TOKEN is the worker principal, so a
# 401/403 here is a TIER MISMATCH, not a broken box. Read the same rows straight
# out of the control plane's own postgres container instead — same crown, same
# SSH, no new credential.
if [ "$CODE" != "401" ] && [ "$CODE" != "403" ]; then
  echo "CR_ERROR=http_$CODE"
  rm -f /tmp/cr-body.json
  exit 0
fi
DBID="$(docker ps -q --filter ancestor=postgres:15-alpine | head -1)"
if [ -z "$DBID" ]; then echo "CR_ERROR=no_db_container"; exit 0; fi
PU="$(docker exec "$DBID" printenv POSTGRES_USER)"
PD="$(docker exec "$DBID" printenv POSTGRES_DB)"
if [ -z "$PU" ] || [ -z "$PD" ]; then echo "CR_ERROR=no_db_env"; exit 0; fi
SHA=""
LIM="100"
for kv in $(echo "$QS" | tr '&' ' '); do
  case "$kv" in
    sha=*) SHA="${kv#sha=}" ;;
    limit=*) LIM="${kv#limit=}" ;;
  esac
done
case "$LIM" in ''|*[!0-9]*) LIM=100 ;; esac
case "$SHA" in ''|*[!0-9a-f]*) WHERE="" ;; *) WHERE="WHERE sha = '$SHA'" ;; esac
SQL="SELECT coalesce(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT sha, target, carried, delivering_run_id, to_char(first_seen_at, 'YYYY-MM-DD\"T\"HH24:MI:SSZ') AS first_seen_at FROM platform_deliveries $WHERE ORDER BY first_seen_at DESC LIMIT $LIM) t"
ROWS="$(docker exec "$DBID" psql -U "$PU" -d "$PD" -tAc "$SQL" 2>/dev/null)"
if [ -z "$ROWS" ]; then echo "CR_ERROR=sql_read_failed"; exit 0; fi
echo "CR_VIA=sql"
echo "CR_BODY={\"deliveries\":$ROWS}"
REMOTE
}

# crown_read <query-string> <out-file> -> 0 read / 2 could not read
crown_read() {
  local qs="$1" out="$2" body http via
  case "$READER" in
    fixture)
      [ -f "$CROWN_FIXTURE" ] || { warn "  crown fixture is unreadable: ${CROWN_FIXTURE:-<none>}"; return 2; }
      jq 'if type == "array" then {deliveries: .} else error("not an array") end' "$CROWN_FIXTURE" > "$out" 2>/dev/null \
        || { warn "  crown fixture is not a JSON array of rows"; return 2; }
      return 0
      ;;
    pat)
      http="$(curl -s -o "$WORK/body.json" -w '%{http_code}' --max-time 30 \
        -H "authorization: Bearer $CROWN_API_TOKEN" "$API_BASE/v1/deliveries?$qs")"
      if [ "$http" != "200" ]; then
        warn "  the crown answered HTTP ${http:-<none>} for ?$qs"
        return 2
      fi
      cp "$WORK/body.json" "$out"
      return 0
      ;;
    ssh)
      body="$($SSH "root@${CP_HOST}" "bash -s '$qs'" < "$WORK/remote.sh" 2>&1)"
      if [ $? -ne 0 ]; then
        warn "  the control plane was not reachable over SSH for ?$qs"
        return 2
      fi
      via="$(printf '%s\n' "$body" | sed -n 's/^CR_VIA=//p')"
      http="$(printf '%s\n' "$body" | sed -n 's/^CR_HTTP=//p')"
      printf '%s\n' "$body" | sed -n 's/^CR_BODY=//p' > "$out"
      if [ ! -s "$out" ]; then
        warn "  the crown could not be read on the box for ?$qs: $(printf '%s\n' "$body" | sed -n 's/^CR_ERROR=//p')"
        return 2
      fi
      [ "$via" = "sql" ] && warn "  note: the route answered HTTP $http to the WORKER principal — read via the control plane's postgres container instead"
      return 0
      ;;
  esac
  return 2
}

# ── the runs ─────────────────────────────────────────────────────────────────
fetch_runs() { # -> writes $WORK/runs-raw.json, 0 ok / 2 could not read
  if [ "$FIXTURE_MODE" = "1" ]; then
    [ -f "$RUNS_FIXTURE" ] || { warn "  runs fixture is unreadable: $RUNS_FIXTURE"; return 2; }
    cp "$RUNS_FIXTURE" "$WORK/runs-raw.json"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || { warn "CONFIG: gh is required to enumerate deploy.yml runs"; return 3; }
  if ! gh api "repos/$REPO/actions/workflows/deploy.yml/runs?branch=main&status=success&per_page=100" \
    > "$WORK/runs-raw.json" 2>"$WORK/runs-err.txt"; then
    warn "  could not list deploy.yml runs: $(head -1 "$WORK/runs-err.txt")"
    return 2
  fi
  return 0
}

# A run DELIVERS only when control-plane or instance concluded success.
run_delivers() { # <run-id> -> 0 delivers / 1 does not / 2 could not read
  local id="$1" out="$WORK/jobs-$id.json"
  if [ "$FIXTURE_MODE" = "1" ]; then
    [ -f "$JOBS_FIXTURE" ] || return 2
    jq --arg id "$id" '.[$id] // empty' "$JOBS_FIXTURE" > "$out" 2>/dev/null
    [ -s "$out" ] || return 2
  else
    if ! gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" --jq '.jobs' > "$out" 2>/dev/null; then
      return 2
    fi
  fi
  local hits
  hits="$(jq '[.[] | select((.name == "control-plane" or .name == "instance") and .conclusion == "success")] | length' "$out" 2>/dev/null)"
  [ -n "$hits" ] || return 2
  [ "$hits" -gt 0 ] && return 0
  return 1
}

# ── run ──────────────────────────────────────────────────────────────────────
select_reader || exit 3
[ "$READER" = "ssh" ] && write_remote_reader

say "crown-reconcile — repo=$REPO reader=$READER window=${WINDOW_HOURS}h ($CUTOFF_ISO .. $NOW_ISO)"

UNREADABLE=0

fetch_runs
rc=$?
[ "$rc" = "3" ] && exit 3
if [ "$rc" != "0" ]; then
  say ""
  say "COULD NOT READ: the deploy.yml run list did not answer. Nothing was compared, and this is NOT a clean run."
  exit 2
fi

# Two populations: the EXAMINED window, and a wider one used only so a row near
# the boundary is not mis-called WRONG.
jq --argjson cut "$CUTOFF_EPOCH" --argjson wide "$WIDE_EPOCH" \
  '[.workflow_runs[]
    | select(.conclusion == "success")
    | {id: (.id | tostring), sha: .head_sha, created: .created_at, at: (.created_at | fromdateiso8601)}]
   | {examined: [.[] | select(.at >= $cut)], wide: [.[] | select(.at >= $wide)]}' \
  "$WORK/runs-raw.json" > "$WORK/runs.json" 2>/dev/null
if [ ! -s "$WORK/runs.json" ]; then
  say ""
  say "COULD NOT READ: the run list did not parse as an Actions runs payload. Nothing was compared."
  exit 2
fi

SUCCESS_COUNT="$(jq '.examined | length' "$WORK/runs.json")"
# One page of 100 is the bound. The population is a FLOOR only when that page
# BOTH filled AND failed to reach back past the cutoff — a filled page whose
# oldest run predates the window has seen the whole window and is exact. Printed
# as `N+`, never rounded down silently.
PAGE_ROWS="$(jq '.workflow_runs | length' "$WORK/runs-raw.json" 2>/dev/null || echo 0)"
PAGE_OLDEST="$(jq -r '[.workflow_runs[] | .created_at | fromdateiso8601] | min // 0' "$WORK/runs-raw.json" 2>/dev/null || echo 0)"
if [ "${PAGE_ROWS:-0}" -ge 100 ] && [ "${PAGE_OLDEST:-0}" -gt "$CUTOFF_EPOCH" ]; then
  warn "  note: the 100-run page filled without reaching the window start — the population below is a FLOOR, printed as N+"
  FLOOR="+"
else
  FLOOR=""
fi

# Which of those actually delivered?
: > "$WORK/delivering.txt"
JOBS_UNREADABLE=0
NONDELIVERING=0
while IFS=' ' read -r id sha; do
  [ -n "$id" ] || continue
  run_delivers "$id"
  case $? in
    0) printf '%s %s\n' "$id" "$sha" >> "$WORK/delivering.txt" ;;
    1) NONDELIVERING=$((NONDELIVERING + 1)) ;;
    *) JOBS_UNREADABLE=$((JOBS_UNREADABLE + 1)); UNREADABLE=1
       warn "  run $id: its job list could not be read — it is NOT counted as reconciled" ;;
  esac
done < <(jq -r '.examined[] | "\(.id) \(.sha)"' "$WORK/runs.json")

DELIVERING="$(awk 'NF' "$WORK/delivering.txt" | wc -l | tr -d ' ')"

# The wide set of delivering head shas, for the reverse direction. Runs outside
# the examined window are included here only as an ALIBI for a row, never as a
# population this verdict reports a rate over.
: > "$WORK/wide-shas.txt"
while IFS=' ' read -r id sha; do
  [ -n "$id" ] || continue
  run_delivers "$id" && printf '%s\n' "$sha" >> "$WORK/wide-shas.txt"
done < <(jq -r '.wide[] | "\(.id) \(.sha)"' "$WORK/runs.json")

say ""
say "POPULATION: ${SUCCESS_COUNT}${FLOOR} successful deploy.yml run(s) on main in the window; ${DELIVERING} of them DELIVERED (a control-plane or instance leg concluded success), ${NONDELIVERING} delivered nothing (both legs skipped — docs-only merges), ${JOBS_UNREADABLE} unreadable."

# ── BEHIND: a delivering run whose head sha the crown has no row for ─────────
BEHIND=0
BEHIND_UNREADABLE=0
: > "$WORK/behind.txt"
while IFS=' ' read -r id sha; do
  [ -n "$sha" ] || continue
  if crown_read "sha=$sha" "$WORK/rows-$sha.json"; then
    n="$(jq --arg sha "$sha" '[.deliveries[] | select(.sha == $sha)] | length' "$WORK/rows-$sha.json" 2>/dev/null)"
    [ -n "$n" ] || n=0
    if [ "$n" -eq 0 ]; then
      BEHIND=$((BEHIND + 1))
      printf '%s %s\n' "$sha" "$id" >> "$WORK/behind.txt"
    fi
  else
    BEHIND_UNREADABLE=$((BEHIND_UNREADABLE + 1))
    UNREADABLE=1
  fi
done < "$WORK/delivering.txt"

# ── WRONG: a row inside the window naming a sha no delivering run delivered ──
WRONG=0
UNCLASSIFIED=0
ROWS_EXAMINED=0
: > "$WORK/wrong.txt"
sort -u "$WORK/wide-shas.txt" > "$WORK/wide-shas-sorted.txt"
WIDE_SHAS="$(awk 'NF' "$WORK/wide-shas-sorted.txt" | wc -l | tr -d ' ')"
if [ "$WIDE_SHAS" -eq 0 ]; then
  # Without a single delivering run in the widened window there is no ALIBI
  # source, and every row would be accused of being a ghost. That is the
  # comforting-direction mistake inverted — loud, but manufactured. Refuse.
  UNREADABLE=1
  warn "  no delivering run in the widened window — the reverse direction has no alibi source and was NOT checked"
elif crown_read "limit=$ROW_LIMIT" "$WORK/recent.json"; then
  jq --argjson cut "$CUTOFF_EPOCH" \
    '[.deliveries[]
      | select((.first_seen_at // "") != "")
      | . + {at: (try (.first_seen_at | sub("\\.[0-9]+"; "") | sub("Z?$"; "Z") | fromdateiso8601) catch 0)}
      | select(.at >= $cut)]' "$WORK/recent.json" > "$WORK/recent-window.json" 2>/dev/null
  if [ -s "$WORK/recent-window.json" ]; then
    ROWS_EXAMINED="$(jq 'length' "$WORK/recent-window.json")"
    while IFS=' ' read -r sha carried; do
      [ -n "$sha" ] || continue
      if [ "$carried" = "true" ]; then
        continue
      elif [ "$carried" = "null" ]; then
        UNCLASSIFIED=$((UNCLASSIFIED + 1))
        UNREADABLE=1
        warn "  row $sha: 'carried' was never measured — it cannot be ruled correct or wrong, and is NOT counted clean"
        continue
      fi
      if ! grep -qx "$sha" "$WORK/wide-shas-sorted.txt"; then
        WRONG=$((WRONG + 1))
        printf '%s\n' "$sha" >> "$WORK/wrong.txt"
      fi
      # `.carried // "null"` would be WRONG here: jq's `//` treats `false` as
      # empty, so every honestly-measured `carried: false` row would report as
      # unmeasured — the comforting direction. Presence is asked for explicitly.
    done < <(jq -r '.[] | "\(.sha) \(if has("carried") and .carried != null then (.carried | tostring) else "null" end)"' "$WORK/recent-window.json" | sort -u)
  else
    UNREADABLE=1
    warn "  the recent-row page did not parse — the reverse direction was NOT checked"
  fi
else
  UNREADABLE=1
  warn "  the recent-row page could not be read — the reverse direction was NOT checked"
fi

# ── SERVING: what the box says it is running, versus the crown ───────────────
SERVING_RED=0
SERVING_SHA=""
if [ -n "$HEALTH_FIXTURE" ] || [ "$FIXTURE_MODE" != "1" ]; then
  if [ -n "$HEALTH_FIXTURE" ]; then
    if [ -f "$HEALTH_FIXTURE" ]; then cp "$HEALTH_FIXTURE" "$WORK/health.json"; else : > "$WORK/health.json"; fi
  else
    curl -s --max-time 20 "$HEALTH_URL" > "$WORK/health.json" 2>/dev/null
  fi
  SERVING_SHA="$(jq -r '.serving_sha // .git_sha // empty' "$WORK/health.json" 2>/dev/null)"
  if [ -z "$SERVING_SHA" ]; then
    UNREADABLE=1
    warn "  ${HEALTH_URL} did not name a serving sha — the serving check did NOT run"
  else
    since="$(jq -r '.serving_since // empty' "$WORK/health.json" 2>/dev/null)"
    since_epoch="$(epoch_of "$since" 2>/dev/null || echo 0)"
    age=$((NOW_EPOCH - ${since_epoch:-0}))
    if crown_read "sha=$SERVING_SHA" "$WORK/rows-serving.json"; then
      cp_rows="$(jq --arg sha "$SERVING_SHA" '[.deliveries[] | select(.sha == $sha and .target == "cp")] | length' "$WORK/rows-serving.json" 2>/dev/null)"
      [ -n "$cp_rows" ] || cp_rows=0
      if [ "$cp_rows" -eq 0 ]; then
        if [ "${since_epoch:-0}" -gt 0 ] && [ "$age" -lt "$SERVING_GRACE_SECONDS" ]; then
          UNREADABLE=1
          warn "  the serving sha $SERVING_SHA has no cp row, but that process is only ${age}s old — a deploy may still be in flight, so this is a WARNING, not a verdict"
        else
          SERVING_RED=1
        fi
      fi
    else
      UNREADABLE=1
      warn "  the crown could not be asked about the serving sha — the serving check did NOT run"
    fi
  fi
fi

# ── the verdict ──────────────────────────────────────────────────────────────
pct() { # <numerator> <denominator>
  [ "${2:-0}" -gt 0 ] || { printf 'n/a'; return; }
  awk -v n="$1" -v d="$2" 'BEGIN { printf "%.1f%%", (n * 100) / d }'
}

say ""
if [ "$BEHIND" -gt 0 ]; then
  say "BEHIND: ${BEHIND} of ${DELIVERING} delivering run(s) examined ($(pct "$BEHIND" "$DELIVERING")) delivered a sha the crown has NO row for:"
  while IFS=' ' read -r sha id; do
    say "    ${sha}  (run ${id}) — delivered, never recorded"
  done < "$WORK/behind.txt"
fi
if [ "$WRONG" -gt 0 ]; then
  say "WRONG: ${WRONG} of ${ROWS_EXAMINED} crown row(s) examined ($(pct "$WRONG" "$ROWS_EXAMINED")) name a sha no delivering run delivered:"
  while read -r sha; do
    say "    ${sha} — recorded, no delivering run"
  done < "$WORK/wrong.txt"
fi
if [ "$SERVING_RED" -gt 0 ]; then
  say "SERVING-UNRECORDED: barkpark.cloud reports it is SERVING ${SERVING_SHA} and the crown has no cp row for it — production is running a commit its own record has never heard of."
fi

if [ "$BEHIND" -gt 0 ] || [ "$WRONG" -gt 0 ] || [ "$SERVING_RED" -gt 0 ]; then
  say ""
  say "VERDICT: NOT reconciled — behind=${BEHIND}/${DELIVERING} delivering runs, wrong=${WRONG}/${ROWS_EXAMINED} rows, serving-unrecorded=${SERVING_RED}."
  exit 1
fi

if [ "$DELIVERING" -eq 0 ]; then
  say ""
  say "COULD NOT VERIFY: the population was EMPTY — ${SUCCESS_COUNT}${FLOOR} successful run(s) in the window and none of them delivered. A rate with no denominator is refused, so this is a warning, not a green."
  exit 2
fi

if [ "$UNREADABLE" != "0" ]; then
  say ""
  say "COULD NOT FULLY READ: ${BEHIND_UNREADABLE} sha(s) unreadable, ${JOBS_UNREADABLE} run(s) with no job list, ${UNCLASSIFIED} row(s) with carried never measured. Everything that COULD be read reconciled, but this run is NOT clean."
  exit 2
fi

say ""
say "RECONCILED: all ${DELIVERING} delivering run(s) in the window have their row, all ${ROWS_EXAMINED} row(s) in the window have their run, and the serving sha ${SERVING_SHA:-<not checked>} is recorded."
exit 0
