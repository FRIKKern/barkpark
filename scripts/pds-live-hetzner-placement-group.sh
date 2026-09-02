#!/usr/bin/env bash
#
# pds-live-hetzner-placement-group.sh — THE PDS EPIC'S FIRST L1.
#
#   MANUAL-RUN-ONLY. This script is NOT a CI tenant. It is deliberately absent
#   from .github/workflows/shell-harnesses.yml, whose tenants are required to be
#   token-free and network-free. This one is neither: it spends a real Hetzner
#   Cloud credential and makes real writes against api.hetzner.cloud.
#
#   scripts/pds-live-hetzner-placement-group.sh --plan             print the ladder, no side effects
#   scripts/pds-live-hetzner-placement-group.sh --preflight        resolve-or-die; name the rung
#   scripts/pds-live-hetzner-placement-group.sh --selftest         prove the preflight can REFUSE (NEEDS A CREDENTIAL)
#   scripts/pds-live-hetzner-placement-group.sh --selftest-offline the CREDENTIAL-FREE arm; this is the CI-able gate
#   scripts/pds-live-hetzner-placement-group.sh --harvest-only     read-only 404 harvest + manifest (NEEDS A CREDENTIAL)
#   scripts/pds-live-hetzner-placement-group.sh --run              the live round trip
#
# THE GATE SPLITS IN TWO — PDS-D439. `--selftest` HARD-REFUSES at exit 3 with no
# credential, so a slice gated on it has a credential-gated green and an exit 3
# is visually indistinguishable from a broken apparatus. `--selftest-offline`
# runs the same MUTATION blocks plus the harvest validators with EVERY
# HCLOUD_*/HETZNER_* variable stripped from its own environment (it re-execs
# itself scrubbed and then COUNTS what is left), and must exit 0. `--harvest-only`
# KEEPS its credential fence on purpose: an unauthenticated GET /v1/servers/…
# returns a 401 JSON envelope, which is exactly the raw material of the
# historical mutation this slice exists to make impossible.
#
# WHY THIS EXISTS
# ---------------
# Twenty-nine waves of post-conditions, fences and receipts, and not one of them
# had been driven against a real server: every proof was a fake, a fixture or a
# static read. This runner is the epic's first L1 — a Barkpark verb making a real
# round trip, its receipt compared against the same API's own SECOND, INDEPENDENT
# answer taken with a different client (curl), not against the fixture that
# generated it.
#
# THE ARTIFACT IS A RUNNER, NOT A TRANSCRIPT, because a proof that cannot re-run
# is a ceremony. A transcript is what this prints; the residue it leaves in the
# repo is internal/cli/testdata/pds_live_hetzner_*.json — real harvested bytes
# that ride CI forever after the credential goes away.
#
# THE PREAMBLE IS THE SLICE
# -------------------------
# The whole value of a live proof rests on a preflight that is ABLE TO REFUSE. A
# runner that degrades to a quiet pass when the credential is missing is one more
# fail-open instrument, and this epic exists to remove those. So:
#
#   · The preflight gates on bp's OWN RESOLUTION — a cheap read verb's exit code
#     AND its receipt SHAPE — never on the presence of an env-var name.
#     internal/hetzner/client.go's ResolveToken has a THIRD rung
#     (TokenFromCLIContext, reading $HCLOUD_CONFIG else <UserConfigDir>/hcloud/
#     cli.toml) that authenticates with BOTH env vars unset. Testing for
#     "$HCLOUD_TOKEN is set" would therefore refuse a perfectly credentialed run
#     on Linux/CI, and — worse — a test for "some token-ish env var is set" would
#     PROCEED on HETZNER_API_TOKEN, a name bp never reads.
#     Measured on macOS 2026-07-31: os.UserConfigDir() resolved to
#     ~/Library/Application Support, so the bare-cli.toml rung was accidentally
#     DEAD there and LIVE wherever UserConfigDir is ~/.config. That hole is now
#     closed — bp tries the Go spelling AND $XDG_CONFIG_HOME (default ~/.config),
#     first readable wins — and state 4 below proves the bare rung WITHOUT
#     HCLOUD_CONFIG. The preflight still does not care which spelling paid; it
#     asks bp.
#   · A refusal is loud and exits 3 (the resolve-or-die of scripts/pds-pull-proof.sh),
#     explicitly NOT the shape of scripts/onramp-live-client-smoke.sh, which
#     prints a friendly no-op and exits 0. There is no fourth outcome and no
#     quiet no-op here: PASS, REFUSE, FAIL.
#     A CLEANUP THAT COULD NOT VERIFY ITSELF IS A FAIL, not a fourth outcome and
#     not a pass with a warning: the run exits NON-ZERO even if every step passed,
#     because "I could not read the project" is not "the project is clean".
#   · EVERY read of the project — the fence's, the cleanup's, the final one — is
#     gated on its receipt SHAPE as well as its exit code. A read that did not
#     answer is never spelled as an empty project.
#   · --selftest proves the refusal in FOUR credential states plus one state per
#     degraded read shape, with every exit code taken WITHOUT A PIPE, and
#     additionally pins the pipe trap itself.
#
# THE FENCE — this project holds FIVE RUNNING PRODUCTION SERVERS, including
# barkpark-cms (89.167.28.206) and guerrilla (157.180.90.121):
#
#   · PLACEMENT GROUPS ONLY. Never a server, network, volume, load balancer,
#     floating IP, certificate or zone — nothing that routes or holds data. A
#     placement group is free, inert and attaches to nothing.
#   · A RESERVED NAME PREFIX ($PG_PREFIX). The run REFUSES TO START if anything
#     in the project already matches it.
#   · CLEANUP ON EVERY EXIT PATH, including failures and signals, and the cleanup
#     itself re-reads: the run does not claim a clean project, it observes one.
#
# THE LIMIT, DECLARED IN THE RUN'S OWN OUTPUT (not in a paragraph a reader may
# scroll past): a live run against a CORRECT API proves exactly one direction —
# NO FALSE REFUSAL, that the predicate binds on real bytes and does not red an
# honest verb. It does NOT prove the refusal direction: a real Hetzner will not
# keep handing back a resource it has deleted, so the lying-API arm stays
# fake-proven in hetzner_respost_test.go. Nothing here may be read as "the
# destroy apparatus is proven against production".
#
# Environment (all optional):
#   PDS_LIVE_BP        use this bp binary instead of building one (selftest hook)
#   PDS_LIVE_GO        go binary (default: go); CC defaults to /usr/bin/clang
#   PDS_LIVE_ART       artifact dir (default: /tmp/pds-live-w30.<pid>)
#   PDS_LIVE_HARVEST   dir to write harvested fixture bytes into (default: none)
#   HCLOUD_TOKEN / HCLOUD_CONFIG / HCLOUD_CONTEXT — read by bp, never by name here
#
# Exit: 0 every selected step passed AND the cleanup verified itself by re-read ·
#       1 an assertion FAILED, or the cleanup could not be verified · 3 REFUSED
#       (environment/credential/apparatus/unreadable project) · 2 usage.
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"

HZ_API="${PDS_LIVE_HZ_API:-https://api.hetzner.cloud/v1}"
PG_PREFIX="${PDS_LIVE_PG_PREFIX:-pds-live-w30-}"
ART="${PDS_LIVE_ART:-/tmp/pds-live-w30.$$}"
GO_BIN="${PDS_LIVE_GO:-go}"

mkdir -p "$ART"

# ── vocabulary ───────────────────────────────────────────────────────────────
#
# Three outcomes, and the refusal is a first-class one. "REFUSE" is the word; a
# quiet no-op has no spelling in this script on purpose.

say()    { printf '%s\n' "$*"; }
step()   { printf '\n== %s\n' "$*"; }
ok()     { printf '  PASS    %s\n' "$*"; }
refuse() { printf '\n%s: REFUSE — %s\n' "$SELF" "$*" >&2; exit 3; }
failed() { printf '\n%s: FAIL — %s\n' "$SELF" "$*" >&2; exit 1; }
usage()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 2; }

# jsonq FILE EXPR — evaluate a python expression over the parsed body `d`.
# Exits non-zero if the body is not JSON at all, which is itself an assertion.
jsonq() {
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write("not JSON: %s\n" % e)
    sys.exit(9)
v = eval(sys.argv[2])
print("" if v is None else v)
' "$1" "$2"
}

# ── the bp under proof ───────────────────────────────────────────────────────
#
# BUILT FROM THIS WORKTREE, never the installed binary. /Users/pelle/.local/bin/bp
# was f59aaf717 on 2026-07-31 and contains neither internal/cli/hetzner_respost.go
# nor screenWriteReceipt — a live run through it would exercise pre-fence code and
# prove nothing about the apparatus this epic built. So the runner refuses a tree
# that predates the apparatus rather than measuring the wrong program.

BP=""

# The check is on the SYMBOLS, searched across internal/cli — never on one file
# path holding one spelling. The first draft grepped the literal `func
# hzResDestroyed` inside internal/cli/hetzner_respost.go and survived only by
# accident (hzResDestroyedDeclared shares the prefix). Two renames have since
# happened around it: hzResObserved — the post-read this epic now prefers,
# because hcloud-go v2.44 swallows a 404 into (nil, resp, nil) — landed in a
# DIFFERENT file (hetzner_respost_mutation.go). A path-pinned, spelling-pinned
# check turns any later rename into a loud REFUSE that bricks BOTH L1 runners
# and that nobody connects back to the rename. So: either post-read symbol,
# anywhere under internal/cli, satisfies "this tree has the apparatus".
apparatus_or_refuse() {
  local missing=""
  grep -rEq 'func hzRes(Destroyed|Observed)' "$REPO_ROOT/internal/cli/" 2>/dev/null \
    || missing="$missing hzResDestroyed-or-hzResObserved"
  grep -rq 'screenWriteReceipt' "$REPO_ROOT/internal/cli/" 2>/dev/null \
    || missing="$missing screenWriteReceipt"
  [ -z "$missing" ] || refuse "this tree predates the destroy apparatus (missing:$missing). A live run through pre-fence code proves nothing about the receipt under test."
}

build_bp() {
  if [ -n "${PDS_LIVE_BP:-}" ]; then
    BP="$PDS_LIVE_BP"
    [ -x "$BP" ] || refuse "PDS_LIVE_BP=$BP is not executable"
    return 0
  fi
  apparatus_or_refuse
  [ -d "$REPO_ROOT/cmd/barkpark" ] || refuse "no $REPO_ROOT/cmd/barkpark — note ./cmd/bp DOES NOT EXIST; the binary's package is cmd/barkpark"
  BP="$ART/bp"
  ( cd "$REPO_ROOT" && CC="${CC:-/usr/bin/clang}" "$GO_BIN" build -o "$BP" ./cmd/barkpark ) \
    || refuse "go build ./cmd/barkpark failed — refusing to prove anything with a binary this worktree could not produce"
}

# ── PREFLIGHT: gate on bp's OWN resolution, never on an env-var name ──────────
#
# rc is captured WITHOUT A PIPE. `bp … | head -1 && echo OK` prints OK at rc=0 on
# a command that failed — the pipeline's status is head's. --selftest pins that
# trap with a live demonstration rather than trusting this comment.

RUNG=""

# hz_read FILE [env-prefix…] — the cheap read verb, rc returned, never piped.
#
# It does NOT touch errexit. An early draft restored `set -e` inside the function
# and then `return $rc`, which under errexit terminates the caller mid-preflight —
# the probe that was MEANT to answer "which rung paid" instead killed the run with
# a silent exit 3. Callers own the errexit state; this function only reports.
hz_read() {
  local out="$1"; shift
  if [ "$#" -gt 0 ]; then
    "$@" "$BP" cloud hetzner placement-group list -o json >"$out" 2>&1
  else
    "$BP" cloud hetzner placement-group list -o json >"$out" 2>&1
  fi
}

# shape_ok FILE — the receipt SHAPE, which is the half an exit code cannot carry.
# A stub answering {"ok":true} at rc=0 fails here, and must.
shape_ok() {
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and isinstance(d.get("placement_groups"), list) else 1)
' "$1"
}

preflight() {
  build_bp

  local probe="$ART/preflight.json" rc=0
  set +e
  hz_read "$probe"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf '  bp said: %s\n' "$(head -c 400 "$probe")" >&2
    refuse "bp could not resolve a Hetzner credential of its own (\`bp cloud hetzner placement-group list\` exited $rc, taken without a pipe). Set HCLOUD_TOKEN, or point HCLOUD_CONFIG at an hcloud cli.toml with an active context. This runner does not test for an env-var NAME — it asks bp."
  fi
  if ! shape_ok "$probe"; then
    printf '  bp said: %s\n' "$(head -c 400 "$probe")" >&2
    refuse "bp exited 0 but its receipt is not a placement-group listing — AN EXIT CODE ALONE IS NOT SUCCESS, which is this epic's whole law. Refusing to drive a live write through a binary whose read receipt has the wrong shape."
  fi

  # WHICH RUNG PAID — measured, not guessed. Re-probe with HCLOUD_TOKEN removed:
  # if that still resolves, the on-disk hcloud CLI context is what authenticated.
  local probe2="$ART/preflight-norung2.json" rc2=0
  set +e
  hz_read "$probe2" env -u HCLOUD_TOKEN
  rc2=$?
  set -e
  if [ "$rc2" -eq 0 ] && shape_ok "$probe2"; then
    RUNG="hcloud-cli-context (\$HCLOUD_CONFIG else <UserConfigDir> else \$XDG_CONFIG_HOME|~/.config, then /hcloud/cli.toml)"
  else
    RUNG="env:HCLOUD_TOKEN"
  fi

  ok "bp resolved a credential of its own: rc=0 AND the receipt is a placement_groups list"
  say "  CREDENTIAL RUNG THAT PAID: $RUNG"
  say "  (the rung is derived by re-probing without HCLOUD_TOKEN, not by reading env-var names)"
}

# ── the independent oracle ───────────────────────────────────────────────────
#
# A second client, the same API. This is the only thing that makes the run a
# proof rather than a screenshot of bp agreeing with itself. It needs the raw
# token, so it descends the SAME ladder bp does — and the value is never printed,
# never written to an artifact, and never lands in a fixture.

# default_hcloud_config — where bp looks for hcloud's cli.toml when HCLOUD_CONFIG
# is unset, in bp's own order: the Go os.UserConfigDir() spelling first, then
# $XDG_CONFIG_HOME (default ~/.config), FIRST READABLE WINS. It is ONE function
# because two spellings of it drift: an earlier draft hard-coded ~/.config here
# and Darwin's ~/Library/Application Support in the oracle, so --selftest state 4
# looked for the file in a place macOS never writes it and reported the third
# rung UNPROVEN on a host that has it.
#
# The Darwin entry alone was ALSO wrong, and in the same direction as the bug
# this runner measured: os.UserConfigDir() answers ~/Library/Application Support
# there, but the hcloud CLI writes ~/.config/hcloud/cli.toml on every platform.
# So on macOS this oracle found nothing, --selftest refused at exit 3 before its
# first state, and the third rung was untestable on the very hosts where it was
# broken. Two spellings, mirroring internal/hetzner's hcloudConfigCandidates.
default_hcloud_config() {
  local candidates=()
  if [ "$(uname -s)" = "Darwin" ]; then
    candidates+=("$HOME/Library/Application Support/hcloud/cli.toml")
  fi
  candidates+=("${XDG_CONFIG_HOME:-$HOME/.config}/hcloud/cli.toml")
  local c
  for c in "${candidates[@]}"; do
    if [ -r "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  printf '%s\n' "${candidates[0]}"
}

ORACLE_TOKEN=""
resolve_oracle_token() {
  if [ -n "${HCLOUD_TOKEN:-}" ]; then
    ORACLE_TOKEN="$HCLOUD_TOKEN"
    return 0
  fi
  local cfg="${HCLOUD_CONFIG:-}"
  [ -n "$cfg" ] || cfg="$(default_hcloud_config)"
  [ -r "$cfg" ] || return 1
  ORACLE_TOKEN="$(CTX="${HCLOUD_CONTEXT:-}" python3 - "$cfg" <<'PY' || true
import os, re, sys
active, want = "", os.environ.get("CTX", "").strip()
ctxs, cur, section = [], {}, ""
for raw in open(sys.argv[1]):
    line = raw.strip()
    if line.startswith("[[") and line.endswith("]]"):
        if cur: ctxs.append(cur)
        section = line[2:-2].strip(); cur = {}
        continue
    if line.startswith("[") and line.endswith("]"):
        if cur: ctxs.append(cur); cur = {}
        section = line[1:-1].strip()
        continue
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"(.*)"\s*$', line)
    if not m: continue
    k, v = m.group(1), m.group(2)
    if section == "" and k == "active_context": active = v
    elif section == "contexts": cur[k] = v
if cur: ctxs.append(cur)
want = want or active
for c in ctxs:
    if c.get("name") == want and c.get("token"):
        print(c["token"]); break
PY
)"
  [ -n "$ORACLE_TOKEN" ]
}

# oracle GET-PATH OUTFILE -> prints the TAB-delimited machine record
#   <http_code> TAB <content_type> TAB <size_download>
#
# THE SEPARATOR IS A TAB, NOT A SPACE, and that is a bug fix rather than a style
# choice: `%{content_type}` is a parameterised header value, so on any response
# carrying `application/json; charset=utf-8` a space-delimited record shifts every
# field right and `awk '{print $3}'` yields the literal string "charset=utf-8"
# where a byte count belongs. That is not hypothetical — PDS-D429 measured the
# wave-30 harvest narration printing "the SERVER 404 (charset=utf-8 bytes)".
# Content types cannot contain a TAB, so this record is unambiguous, and it is
# the SAME text that lands verbatim in the manifest's `record` field: the
# manifest's http_status/content_type/bytes are then DERIVED from a machine
# record instead of typed by whoever wrote the JSON.
oracle() {
  local path="$1" body="$2" meta
  meta="$(curl -sS --max-time 60 -o "$body" \
            -w '%{http_code}\t%{content_type}\t%{size_download}' \
            -H "Authorization: Bearer $ORACLE_TOKEN" "$HZ_API$path")"
  printf '%s\n' "$meta"
}

# hz_field N RECORD — the Nth TAB field of a machine record, cut never awk.
hz_field() { printf '%s\n' "$2" | cut -f"$1"; }

# ── THE HARVEST — READ-ONLY, and the deposit is the part that can lie ────────
#
# `--harvest-only` issues ONE authenticated GET per flat hcloud kind against an
# id that cannot exist. It creates nothing, deletes nothing, attaches nothing to
# anything, arms no cleanup trap and needs no reserved-prefix fence: there is no
# blast radius to fence. It DOES keep the credential fence (PDS-D429/D439) —
# without one, every GET returns a 401 JSON envelope of exactly the shape a 404
# fixture has, and the run would commit nine 401 bodies as 404 fixtures.
#
# THE KIND -> SEGMENT TABLE IS DERIVED AND PINNED — PDS-D443. The flat shape is
# NOT `/v1/<kind>/<id>`: four of the nine kinds need hyphen -> underscore. The
# rule `replace("-","_") + "s"` reproduces all nine of hcloud-go v2.44's opPath
# segments with no irregulars, so the rule is what the runner USES — and the
# table below is the PIN, so a future kind where the rule breaks reds loudly
# instead of harvesting a wrong path and filing it under the right kind name.

HZ_FLAT_KINDS="certificate firewall floating-ip load-balancer network placement-group primary-ip volume zone"
HZ_FLAT_SEGMENTS="certificates firewalls floating_ips load_balancers networks placement_groups primary_ips volumes zones"
HZ_MISSING_ID="${PDS_LIVE_MISSING_ID:-999999999}"

# THE ONE REFUSED KIND, REFUSED BY NAME AND ON A STRUCTURAL GROUND — PDS-D443.
HZ_REFUSED_KIND="record"
HZ_REFUSED_GROUND="hcloud-go v2.44 has NO /records collection at all; records exist only under /zones/<zone>/rrsets/<name>/<type>. A flat probe would therefore 404 on a MISSING ZONE and be filed under kind=record — a fabricated fixture. A genuine rrset 404 needs a real zone, which routes data and is outside this runner's fence. NOT TO BE CONFLATED: record is still PAYABLE by a post-read (get_rrset_by_name_and_type / get_rrset_by_id both 404-swallow into the gone-read shape); this refusal is about HARVESTING a body, never about paying a receipt."

# hz_segment KIND — the derivation, one place.
hz_segment() { printf '%s\n' "$(printf '%s' "$1" | tr '-' '_')s"; }

# hz_segment_table_ok — the PIN. Every pinned segment must equal the derivation,
# and the two lists must be the same length. This is what turns a future
# irregular kind into a red instead of a silent wrong-path harvest.
hz_segment_table_ok() {
  local kinds segs k s derived bad=0 n=0 m=0
  # shellcheck disable=SC2086
  set -- $HZ_FLAT_SEGMENTS
  segs="$*"
  for k in $HZ_FLAT_KINDS; do n=$((n + 1)); done
  for s in $segs; do m=$((m + 1)); done
  if [ "$n" != "$m" ]; then
    printf '  the pinned kind list (%s) and segment list (%s) are different lengths\n' "$n" "$m" >&2
    return 1
  fi
  local i=0
  for k in $HZ_FLAT_KINDS; do
    i=$((i + 1))
    s="$(printf '%s\n' "$segs" | tr ' ' '\n' | sed -n "${i}p")"
    derived="$(hz_segment "$k")"
    if [ "$s" != "$derived" ]; then
      printf '  %s: pinned segment %s but the rule derives %s\n' "$k" "$s" "$derived" >&2
      bad=1
    fi
  done
  [ "$bad" = "0" ]
}

# hz_error_code FILE — the body's top-level error.code, or rc 1 if the body is
# not JSON or carries none. Used by the deposit guard; never by the harvest,
# which records what came and lets the test judge.
hz_error_code() {
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
e = d.get("error") if isinstance(d, dict) else None
c = e.get("code") if isinstance(e, dict) else None
if not c:
    sys.exit(1)
print(c)
' "$1"
}

# deposit_or_refuse LABEL RECORD BODY DEST — THE FIXED DEPOSIT.
#
# Until wave 32 the SERVER-404 leg of --run was a bare `cp` with no check at all:
# driven against a stub answering 200 text/html it deposited an HTML page as
# pds_live_hetzner_server_404.json AT EXIT 0. That is one of three deposits, not
# three of three — the placement-group 200 and 404 legs already sit behind real
# assertions on status, content-type and error.code — but one unguarded deposit
# is enough to commit whatever arrived. --selftest-offline DEMONSTRATES the
# fail-open on the old code path FIRST and then drives this function through the
# same three lies, each of which must refuse with its own sentence and write
# nothing.
#
# This guard belongs to the legs that ASSERT a 404. The --harvest-only mode does
# NOT use it: there the disposition is data (see harvest_issue).
deposit_or_refuse() {
  local label="$1" rec="$2" body="$3" dest="$4" st ct code
  st="$(hz_field 1 "$rec")"
  ct="$(hz_field 2 "$rec")"
  if [ "$st" != "404" ]; then
    printf '  DEPOSIT REFUSED (%s): the response was HTTP %s, not 404. NOTHING WRITTEN — a body this leg asserts is a 404 may not be banked as one on the strength of having arrived.\n' "$label" "$st" >&2
    return 1
  fi
  case "$ct" in
    application/json*) : ;;
    *)
      printf '  DEPOSIT REFUSED (%s): content-type is "%s", not application/json. NOTHING WRITTEN — PDS-D401 is precisely the claim that the 404 is a JSON body; depositing a text/plain or text/html one would make the fixture assert its own premise away.\n' "$label" "$ct" >&2
      return 1
      ;;
  esac
  code="$(hz_error_code "$body" 2>/dev/null || true)"
  if [ -z "$code" ]; then
    printf '  DEPOSIT REFUSED (%s): the body carries no top-level error.code. NOTHING WRITTEN — error.code is the exact field hcloud-go errorFromBody reads, so a body without one cannot evidence the gone arm.\n' "$label" >&2
    return 1
  fi
  cp "$body" "$dest"
  printf '  deposited %s (HTTP %s %s, error.code=%s)\n' "$(basename "$dest")" "$st" "$ct" "$code" >&2
  return 0
}

# harvest_issue KIND DEST_DIR RECORDS — ISSUE, RECORD WHAT CAME, DEPOSIT
# UNCONDITIONALLY, JUDGE AFTERWARDS.
#
# PDS-D443: `zone` is the one kind whose failure mode is unknowable offline —
# ZoneClient.GetByID strconv's the int into an id-OR-NAME lookup and 999999999 is
# not a valid DNS name, and D417 already measured a 114-byte zone 404 whose
# message is 39 characters where "zone not found" is 14. An assert-404-then-write
# harvest would either fabricate or lose that. So this function never asserts:
# it writes the REAL status, content-type and byte count into the machine record
# and lets the Go arms judge. A non-404 disposition is EVIDENCE, not failure.
harvest_issue() {
  local kind="$1" dir="$2" records="$3" seg path body rec st ct by file
  seg="$(hz_segment "$kind")"
  path="/$seg/$HZ_MISSING_ID"
  file="pds_live_hetzner_$(printf '%s' "$kind" | tr '-' '_')_404.json"
  body="$dir/$file"
  rec="$(oracle "$path" "$body")"
  st="$(hz_field 1 "$rec")"
  ct="$(hz_field 2 "$rec")"
  by="$(hz_field 3 "$rec")"
  printf '%s\t%s\tGET /v1%s\t%s\t%s\t%s\t%s\n' "$kind" "$seg" "$path" "$file" "$st" "$ct" "$by" >>"$records"
  printf '  %-16s %-18s HTTP %-4s %-28s %s bytes\n' "$kind" "$seg" "$st" "$ct" "$by" >&2
}

# emit_manifest OUT RECORDS FIXTURE_DIR — THE MANIFEST IS SCRIPT-WRITTEN.
#
# Every number in it is DERIVED: http_status, content_type and bytes come from
# the verbatim TAB-delimited `curl -w` record this run captured, and each body's
# sha256 is computed from the bytes on disk. That is NON-ACCIDENTABILITY, NOT
# UNFORGEABILITY — PDS-D440 measured a real 401 body committed as
# http_status:200 with a fully-verifying marker passing every digest arm, because
# status and content-type are TRANSPORT facts absent from the committed bytes.
# What catches that is the COHERENCE arm in the Go test, not this marker. The
# marker's job is that nobody TYPES a number into the manifest.
#
# DIGESTS ARE HYPHEN-CHUNKED IN 8-CHARACTER GROUPS — PDS-D441. The credential
# scanner globs the manifest itself and reds any 32+ character unbroken
# alphanumeric run, so a bare sha256 REDS an honest manifest. The regex is NOT
# widened and NO field whitelist is added: a fake 64-character token parked in a
# whitelisted sha256 slot would pass a whitelist while the unchanged byte scanner
# reds it.
#
# It is DETERMINISTIC: run it twice over the same fixtures and records and the
# bytes are identical. --selftest-offline relies on that to prove the COMMITTED
# manifest is what this emitter produces, rather than something hand-typed.
emit_manifest() {
  HZ_FLAT_KINDS="$HZ_FLAT_KINDS" HZ_REFUSED_KIND="$HZ_REFUSED_KIND" \
  HZ_REFUSED_GROUND="$HZ_REFUSED_GROUND" HZ_API_URL="$HZ_API" HZ_SELF="$SELF" \
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib, json, os, re, sys

out_path, records_path, fixture_dir = sys.argv[1], sys.argv[2], sys.argv[3]

def chunk(h):
    # 8-character groups, hyphen-separated: never a 32+ unbroken run.
    return "-".join(h[i:i + 8] for i in range(0, len(h), 8))

prev = {}
prev_top = {}
if os.path.exists(out_path):
    try:
        prev_top = json.load(open(out_path))
        prev = {f["file"]: f for f in prev_top.get("fixtures", [])}
    except Exception:
        prev, prev_top = {}, {}

harvested = {}
if os.path.exists(records_path):
    for line in open(records_path):
        line = line.rstrip("\n")
        if not line:
            continue
        kind, seg, request, fname, status, ctype, nbytes = line.split("\t")
        harvested[fname] = {
            "kind": kind, "segment": seg, "request": request, "file": fname,
            "status": status, "ctype": ctype, "bytes": nbytes,
        }

rows = []
for fname in sorted(os.listdir(fixture_dir)):
    if not (fname.startswith("pds_live_hetzner_") and fname.endswith(".json")):
        continue
    # The manifest is not one of its own fixtures. Without this the emitter is
    # not even deterministic — the row would digest the file being written.
    if fname == os.path.basename(out_path):
        continue
    raw = open(os.path.join(fixture_dir, fname), "rb").read()
    sha = chunk(hashlib.sha256(raw).hexdigest())
    h = harvested.get(fname)
    old = prev.get(fname, {})
    if h:
        row = {
            "file": fname,
            "kind": h["kind"],
            "segment": h["segment"],
            "request": h["request"],
            "http_status": int(h["status"]),
            "content_type": h["ctype"],
            "bytes": int(h["bytes"]),
            "record": "\t".join([h["status"], h["ctype"], h["bytes"]]),
            "provenance": "harvest-only",
            "sha256_chunked": sha,
        }
    else:
        # A pre-machine-record row. Its bytes and sha256 are still DERIVED (from
        # disk); its status and content-type are the wave-30 run's transcription,
        # and `provenance` says so rather than letting them pass as machine facts.
        seg = old.get("segment", "")
        if not seg:
            m2 = re.search(r"/v1/([a-z_]+)/", old.get("request", ""))
            seg = m2.group(1) if m2 else ""
        row = {
            "file": fname,
            "kind": old.get("kind", ""),
            "segment": seg,
            "request": old.get("request", ""),
            "http_status": old.get("http_status", 0),
            "content_type": old.get("content_type", ""),
            "bytes": len(raw),
            "record": old.get("record", ""),
            "provenance": old.get("provenance", "wave-30-run"),
            "sha256_chunked": sha,
        }
    try:
        body = json.loads(raw)
        code = ((body.get("error") or {}).get("code") or "") if isinstance(body, dict) else ""
    except Exception:
        code = ""
    if code:
        row["error_code"] = code
    note = old.get("note", "")
    if note:
        row["note"] = note
    if old.get("message_token_override"):
        row["message_token_override"] = old["message_token_override"]
        row["message_token_reason"] = old.get("message_token_reason", "")
    rows.append(row)

chain_src = "\n".join(
    "|".join([r["file"], str(r["http_status"]), r["content_type"], str(r["bytes"]), r["sha256_chunked"]])
    for r in rows
)
chain = chunk(hashlib.sha256(chain_src.encode()).hexdigest())

flat = os.environ["HZ_FLAT_KINDS"].split()
covered = sorted({r["kind"] for r in rows if r["kind"] in flat})
pending = sorted(k for k in flat if k not in covered)

doc = {
    "_readme": [
        "SCRIPT-EMITTED. Do not hand-edit: regenerate with %s --manifest-emit." % os.environ["HZ_SELF"],
        "Every http_status/content_type/bytes below is DERIVED from the verbatim TAB-delimited curl -w",
        "record captured when the body was fetched; every sha256 is computed from the bytes on disk and",
        "is hyphen-chunked in 8-character groups so the committed-credential scanner (which reds any 32+",
        "character unbroken alphanumeric run, this manifest included) stays UNWIDENED.",
        "THE MARKER IS NON-ACCIDENTABILITY, NOT UNFORGEABILITY: status and content-type are TRANSPORT",
        "facts absent from the committed bytes, so an honestly-computed digest over a MISLABELLED row",
        "still verifies. What catches a mislabelled row is the coherence arm in",
        "internal/cli/hetzner_live_fixtures_test.go, not anything in this file.",
        "Rows with provenance wave-30-run predate the machine record: their bytes and sha256 are derived",
        "from disk, their status and content-type are the wave-30 run's human transcription.",
    ],
    "emitted_by": "scripts/%s --manifest-emit" % os.environ["HZ_SELF"],
    "harvested_at": prev_top.get("harvested_at", ""),
    "harvested_by": prev_top.get("harvested_by", ""),
    "api": prev_top.get("api", os.environ["HZ_API_URL"]),
    "kind_coverage": {
        "flat_kinds": flat,
        "harvested": covered,
        "pending": pending,
        "note": "flat_kinds is the hcloud subset of the receipt ledger whose 404 lives at a flat collection path. The segment is derived as replace(kind,'-','_')+'s' and pinned in the runner.",
    },
    "refusals": [
        {
            "kind": os.environ["HZ_REFUSED_KIND"],
            "refused_by": "scripts/%s --harvest-only" % os.environ["HZ_SELF"],
            "ground": os.environ["HZ_REFUSED_GROUND"],
        }
    ],
    "chain": chain,
    "fixtures": rows,
}
with open(out_path, "w") as fh:
    json.dump(doc, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
}

# ── the two project reads: SHAPE-CHECKED, and a failed read is not an answer ──
#
# EVERY read in this runner passes through shape_ok, not just the preflight's.
# Until wave 31 it was applied at exactly two places (both inside preflight) and
# the two functions BELOW — which the fence, the cleanup and the final assertion
# all judge the project by — checked only hz_read's exit code. Consequences,
# reproduced with a stub bp before this was written:
#   · the FENCE failed closed on rc!=0 and on non-JSON but fail-OPEN on valid
#     JSON without a placement_groups key — `d.get(...) or []` yields no names,
#     so it printed the all-clear and would have CREATED in the live project;
#   · cleanup printed "cleanup verified by re-read: zero groups match …" in all
#     three degraded shapes while a planted orphan survived, and exited 0.
# The distinction the return code now carries: 1 = the read FAILED, 2 = the read
# succeeded but its receipt is NOT a placement-group listing. Both mean the same
# thing to a caller — YOU DO NOT KNOW WHAT IS IN THE PROJECT — and neither may
# ever be read as "empty".

# reserved_names — names in the live project matching the reserved prefix.
# rc 0 = answered (the names, possibly none) · 1 = read failed · 2 = wrong shape.
reserved_names() {
  local f="$ART/list.$$.json"
  hz_read "$f" || return 1
  shape_ok "$f" || return 2
  PREFIX="$PG_PREFIX" python3 -c '
import sys, json, os
d = json.load(open(sys.argv[1]))
p = os.environ["PREFIX"]
for g in d.get("placement_groups") or []:
    n = str(g.get("name") or "")
    if n.startswith(p):
        print(n)
' "$f"
}

# pg_count — same contract, same three return codes.
pg_count() {
  local f="$ART/count.$$.json"
  hz_read "$f" || return 1
  shape_ok "$f" || return 2
  jsonq "$f" 'len(d.get("placement_groups") or [])'
}

# read_failure_reason RC — the sentence that names WHICH half went wrong.
read_failure_reason() {
  case "$1" in
    2) printf '%s' "bp exited 0 but its receipt is not a placement_groups listing — AN EXIT CODE ALONE IS NOT SUCCESS" ;;
    *) printf '%s' "the \`bp cloud hetzner placement-group list\` read exited non-zero (see the artifact dir $ART for what bp said)" ;;
  esac
}

# ── the fence — ONE implementation, called by --run and driven by --selftest ──
#
# --selftest drives THIS function through a stub bp rather than restating it, so
# the selftest proves the production path instead of mirroring it.
fence_or_refuse() {
  local existing frc=0
  set +e
  existing="$(reserved_names)"
  frc=$?
  set -e
  [ "$frc" -eq 0 ] || refuse "the fence read did not answer: $(read_failure_reason "$frc"). Refusing to create anything in a project whose contents could not be read — an unreadable project is NOT an empty one."
  if [ -n "$existing" ]; then
    refuse "the reserved prefix \"$PG_PREFIX\" already matches: $existing. Either a previous run leaked or something else owns the name — refusing to start rather than adopt a resource this run did not create."
  fi
}

# ── cleanup: EVERY exit path, and it re-reads rather than claiming ───────────
#
# The re-read has THREE possible answers, not two: clean, dirty, and COULD NOT
# TELL. The third one used to be spelled as the first (`$(reserved_names || true)`
# collapses a failed read to the empty string, which reads as "nothing left").
# It is now its own outcome, it says so on stderr with the hand-check command,
# and it forces a NON-ZERO exit so a leaking run cannot exit 0.
#
# SIGNALS, MEASURED (bash 3.2.57(1)-release, Darwin arm64, 2026-08-01): with
# `trap … EXIT INT TERM`, killing the script with TERM, HUP and QUIT each ran the
# handler; SIGKILL ran nothing. HUP and QUIT are listed below anyway as cheap
# portability insurance — that is NOT a fix, because they already worked here.
# SIGKILL is the only true signal gap and it is deliberately NOT fixed: it CANNOT
# be. Its blast radius is measured instead — see the trap site in run().

CLEANUP_ARMED=0
CLEANUP_UNVERIFIED=0

# cleanup_unverified WHY — the third answer, spelled out loudly, once.
cleanup_unverified() {
  printf '  CLEANUP UNVERIFIED — the re-read FAILED (%s); reserved-prefix groups MAY survive. Check by hand: bp cloud hetzner placement-group list\n' "$1" >&2
  CLEANUP_UNVERIFIED=1
}

# cleanup_delete NAME — delete one leftover and READ ITS RECEIPT. The receipt is
# the whole point of the apparatus this runner exists to prove; discarding it
# with `>/dev/null 2>&1 || true` silenced the epic's own refusal machinery
# inside the epic's own instrument.
cleanup_delete() {
  local n="$1" delr="$ART/cleanup-delete.$$.json" drc=0 gone=""
  set +e
  "$BP" cloud hetzner placement-group delete "$n" --yes -o json >"$delr" 2>&1
  drc=$?
  gone="$(jsonq "$delr" 'd.get("confirmed_gone")' 2>/dev/null)"
  set -e
  if [ "$drc" -ne 0 ]; then
    printf '  delete of %s exited %s — the receipt REFUSED the claim (that is the apparatus working; the group may still exist): %s\n' \
      "$n" "$drc" "$(head -c 300 "$delr" | tr '\n' ' ')" >&2
    cleanup_unverified "a delete refused"
    return 1
  fi
  if [ "$gone" != "True" ]; then
    printf '  delete of %s exited 0 but its receipt does NOT carry confirmed_gone=true (got %s) — an exit code alone is not success: %s\n' \
      "$n" "${gone:-<absent>}" "$(head -c 300 "$delr" | tr '\n' ' ')" >&2
    cleanup_unverified "a delete receipt did not confirm the group was gone"
    return 1
  fi
  printf '  deleted %s (receipt: confirmed_gone=true)\n' "$n" >&2
  return 0
}

cleanup() {
  local rc=$?
  if [ "$CLEANUP_ARMED" = "1" ]; then
    local leftovers crc=0
    set +e
    leftovers="$(reserved_names)"
    crc=$?
    set -e
    if [ "$crc" -ne 0 ]; then
      printf '\n== cleanup (exit rc=%s): the project could NOT be read\n' "$rc" >&2
      cleanup_unverified "$(read_failure_reason "$crc")"
    elif [ -n "$leftovers" ]; then
      printf '\n== cleanup (exit rc=%s): reserved-prefix groups still present\n' "$rc" >&2
      local n
      for n in $leftovers; do
        printf '  deleting %s\n' "$n" >&2
        cleanup_delete "$n" || true
      done
      set +e
      leftovers="$(reserved_names)"
      crc=$?
      set -e
      if [ "$crc" -ne 0 ]; then
        cleanup_unverified "$(read_failure_reason "$crc")"
      elif [ -n "$leftovers" ]; then
        printf '  CLEANUP INCOMPLETE — still present: %s. Delete by hand: bp cloud hetzner placement-group delete <name> --yes\n' "$leftovers" >&2
        CLEANUP_UNVERIFIED=1
      else
        printf '  cleanup verified by re-read: zero groups match %s\n' "$PG_PREFIX" >&2
      fi
    fi
  fi
  # A run that could not verify its own cleanup is a FAIL, never a pass. There
  # is no fourth outcome in this script: PASS, REFUSE, FAIL.
  if [ "$CLEANUP_UNVERIFIED" = "1" ] && [ "$rc" -eq 0 ]; then
    rc=1
  fi
  exit $rc
}

# ── the census: THE TARGET COUNT IS DERIVED, NEVER QUOTED ────────────────────
#
# Two different "nines" are in circulation and a builder who quotes either files
# a wrong count. PDS-D429's nine is the UNHARVESTED set — it INCLUDES `record`
# and EXCLUDES placement-group. The flat-shape nine EXCLUDES `record` and
# INCLUDES placement-group. They overlap in eight kinds, and eight is the target.
# So this function derives every step from the tree instead of restating it:
# the ledger's kinds from the census test's own pinned list, the S3 kinds from
# which files carry their receipts, and the harvested set from the manifest.
harvest_census() {
  MANIFEST="${1:-$REPO_ROOT/internal/cli/testdata/pds_live_hetzner_fixtures.json}" \
  FLAT="$HZ_FLAT_KINDS" REFUSED="$HZ_REFUSED_KIND" ROOT="$REPO_ROOT" \
  python3 -c '
import json, os, re, glob

root = os.environ["ROOT"]
flat = os.environ["FLAT"].split()
refused = os.environ["REFUSED"]

# 1. THE LEDGER KINDS — parsed from the census test s own pinned list, so this
#    number moves when the ledger does.
src = open(os.path.join(root, "internal/cli/hetzner_res_census_test.go")).read()
m = re.search(r"var hzResLedgerKinds = \[\]string\{(.*?)\}", src, re.S)
ledger = sorted(set(re.findall(r"\"([a-z0-9-]+)\"", m.group(1))))

# 2. THE S3 KINDS — derived from co-location, not from a memorised list: a kind
#    is S3 when every file emitting a receipt for it is a file that talks to the
#    S3 client. backup is S3 (its receipt id is an object key), not an hcloud
#    snapshot, and that is the trap this derivation exists to avoid.
s3_files, kind_files = set(), {}
for path in glob.glob(os.path.join(root, "internal/cli/hetzner_*.go")):
    if path.endswith("_test.go"):
        continue
    text = open(path).read()
    if "hzS3Client" in text:
        s3_files.add(path)
    for line in text.splitlines():
        if not re.search(r"hz(ResDone|ResObserved|ClassCreate)\(", line):
            continue
        for k in ledger:
            if "\"%s\"" % k in line:
                kind_files.setdefault(k, set()).add(path)
s3 = sorted(k for k in ledger if kind_files.get(k) and kind_files[k] <= s3_files)
hcloud = [k for k in ledger if k not in s3]

# 3. THE HARVESTED SET — read from the manifest, not asserted.
covered = []
try:
    doc = json.load(open(os.environ["MANIFEST"]))
    covered = sorted({f.get("kind") for f in doc.get("fixtures", []) if f.get("kind") in flat})
except Exception:
    covered = []
target = [k for k in flat if k not in covered]

print("  ledger kinds (parsed from the census pin) : %d  %s" % (len(ledger), " ".join(ledger)))
print("  minus S3 kinds (derived by co-location)   : %d  %s" % (len(s3), " ".join(s3)))
print("  = hcloud kinds                            : %d  %s" % (len(hcloud), " ".join(hcloud)))
print("  minus %-36s: %d  %s" % ("the refused kind (%s)" % refused, len([k for k in hcloud if k != refused]), " ".join(k for k in hcloud if k != refused)))
print("  = FLAT-SHAPE kinds (pinned in the runner) : %d  %s" % (len(flat), " ".join(flat)))
print("  already committed as a fixture            : %d  %s" % (len(covered), " ".join(covered) or "-"))
print("  => HARVEST TARGET                         : %d  %s" % (len(target), " ".join(target)))
print("")
print("  THE TWO NINES, RECONCILED: PDS-D429 s nine is the UNHARVESTED set (it includes %s and excludes" % refused)
print("  %s); the flat-shape nine excludes %s and includes %s. They overlap in %d kinds, and %d is the target." % (
    " ".join(covered) or "the harvested kinds", refused, " ".join(covered) or "the harvested kinds", len(target), len(target)))
if len(hcloud) != len(flat) + 1:
    raise SystemExit("DERIVATION BROKE: %d hcloud kinds but %d pinned flat kinds + 1 refused" % (len(hcloud), len(flat)))
'
}

# ── --harvest-only: the cheapest L1 this epic will ever buy ──────────────────
#
# READ-ONLY. One GET per flat kind at an id that cannot exist. No create, no
# delete, nothing attached to anything — so no reserved-prefix fence and no
# cleanup trap, because there is no blast radius to fence. The CREDENTIAL fence
# stays (PDS-D429/D439): an unauthenticated GET returns a 401 JSON envelope, and
# banking eight of those as 404 fixtures is exactly the historical mutation.
harvest_only() {
  step "HARVEST-ONLY — read-only: GET /v1/<segment>/$HZ_MISSING_ID per flat hcloud kind"
  hz_segment_table_ok || failed "the pinned kind->segment table disagrees with the derivation replace(kind,'-','_')+'s'. A wrong path 404s exactly like a right one, so the harvest stops rather than file a body under a kind it did not come from."
  ok "kind->segment: the derivation replace(kind,'-','_')+'s' reproduces every pinned segment"

  step "THE TARGET COUNT, DERIVED FROM THE TREE"
  harvest_census

  step "RECORDED REFUSAL"
  say "  REFUSED BY NAME: $HZ_REFUSED_KIND"
  say "  GROUND: $HZ_REFUSED_GROUND"
  say "  This refusal is written into the manifest's refusals[] — a skipped kind that"
  say "  leaves no trace is indistinguishable from a kind nobody thought of."

  step "CREDENTIAL FENCE"
  resolve_oracle_token || refuse "--harvest-only needs the raw token. This mode makes NO WRITES, so the fence is not about blast radius: an UNAUTHENTICATED GET /v1/servers/$HZ_MISSING_ID answers 401 with a JSON envelope carrying error.code — the same shape a 404 fixture has — and a harvest without a credential would commit eight 401 bodies as 404 evidence. Set HCLOUD_TOKEN or HCLOUD_CONFIG."
  local pbody="$ART/harvest-probe.json" prec pst
  prec="$(oracle "/$(hz_segment placement-group)?per_page=1" "$pbody")"
  pst="$(hz_field 1 "$prec")"
  [ "$pst" = "200" ] || refuse "the credential resolved but does not AUTHENTICATE: a collection read answered HTTP $pst, not 200. A token that is merely PRESENT would make every kind below answer 401, and every one of those bodies would look like a 404 fixture. Refusing before the first deposit."
  ok "the token authenticates: a collection read answered HTTP 200 (the token itself is never printed)"

  local dir="${PDS_LIVE_HARVEST:-$REPO_ROOT/internal/cli/testdata}"
  local records="$ART/harvest-records.tsv"
  : >"$records"
  mkdir -p "$dir"

  step "ISSUE, RECORD WHAT CAME, DEPOSIT UNCONDITIONALLY — the judging happens in the Go arms"
  say "  Nothing below asserts a 404 before writing. A non-404 disposition is RECORDED,"
  say "  which is evidence; \`zone\` in particular is an id-OR-NAME lookup and its answer"
  say "  to a numeric miss is not knowable offline."
  local kind skipped=""
  for kind in $HZ_FLAT_KINDS; do
    local existing="$dir/pds_live_hetzner_$(printf '%s' "$kind" | tr '-' '_')_404.json"
    if [ -e "$existing" ] && [ -z "${PDS_LIVE_REHARVEST:-}" ]; then
      skipped="$skipped $kind"
      continue
    fi
    harvest_issue "$kind" "$dir" "$records"
  done
  [ -z "$skipped" ] || say "  NOT RE-ISSUED (a fixture is already committed):$skipped — the committed placement-group 404 came from a resource this apparatus itself created and deleted, which is a STRONGER provenance than a never-existed id. Set PDS_LIVE_REHARVEST=1 to overwrite."

  step "MANIFEST"
  emit_manifest "$dir/pds_live_hetzner_fixtures.json" "$records" "$dir"
  ok "manifest emitted by this script from the machine records: $dir/pds_live_hetzner_fixtures.json"
  say "  Every http_status/content_type/bytes in it is DERIVED from a verbatim curl -w"
  say "  record. That is non-accidentability, NOT unforgeability — the coherence arm in"
  say "  internal/cli/hetzner_live_fixtures_test.go is what catches a mislabelled row."
  say ""
  say "  WHAT THIS MODE DID NOT DO: it created nothing and deleted nothing, so it says"
  say "  nothing about any verb's receipt. It harvests the BYTES the gone-predicate"
  say "  reasons about, for kinds nobody had measured."
}

# ── --plan ───────────────────────────────────────────────────────────────────

plan() {
  cat <<PLAN
$SELF — MANUAL-RUN-ONLY live proof. No side effects in --plan.

  0  preflight   build bp from THIS worktree (go build ./cmd/barkpark; ./cmd/bp
                 does not exist) and refuse a tree without hzResDestroyed /
                 screenWriteReceipt. Then gate on bp's OWN resolution: a cheap
                 read verb's rc (taken without a pipe) AND its receipt shape.
                 Name the rung that paid. REFUSE (exit 3) otherwise.
  1  fence       list placement groups; REFUSE to start if any name already
                 begins with "$PG_PREFIX". Record the baseline count.
  2  create      bp cloud hetzner placement-group create --name ${PG_PREFIX}<stamp> --type spread
  3  observe     bp cloud hetzner placement-group get <resolved id>
  4  ORACLE      curl GET $HZ_API/placement_groups/<id> with a DIFFERENT client;
                 assert 200 and that id/name/type equal bp's receipt.
  5  delete      bp cloud hetzner placement-group delete <id> --yes; assert the
                 receipt carries confirmed_gone=true (hzResDestroyed's clean arm).
  6  gone        curl the same id again; assert 404, application/json, error.code
                 = not_found. Measure the byte count; harvest the body.
  7  zero        independent list read: zero reserved-prefix groups, count back
                 to the baseline. Runs on EVERY exit path via the cleanup trap.
                 A re-read that FAILS or comes back the wrong shape is neither
                 "clean" nor ignorable: it prints CLEANUP UNVERIFIED and the run
                 exits NON-ZERO.
  8  limit       print which direction this run proved and which it did NOT.

  --selftest runs 0 in four credential states, plus four mutation self-tests —
  the last of which drives the fence and the cleanup through a stub bp in ten
  states (three degraded read shapes x two paths, two refusing deletes, and two
  HEALTHY positive controls — one on the verified re-read, one on the delete
  receipt). IT MAKES NO WRITES, BUT IT DOES NEED A CREDENTIAL: two of its four
  credential states are PROCEED states and would pass vacuously with none, so it
  refuses at exit 3 without one. An earlier version of this paragraph claimed it
  "needs no network"; that was measured false and PDS-D439 retired the claim.

  --selftest-offline is the CREDENTIAL-FREE arm and the CI-able gate. It scrubs
  every HCLOUD_*/HETZNER_* variable out of its own environment, re-execs, COUNTS
  what survived (must be zero), and then runs the four mutation blocks plus the
  harvest validators: the deposit fail-open reproduced on the OLD code path
  first, the fixed deposit refusing three separate lies, the kind->segment
  derivation against its pin, and a proof that the committed manifest is
  byte-identical to what this script's emitter produces.

  --harvest-only is READ-ONLY: one GET per flat hcloud kind at an id that cannot
  exist. It creates nothing, arms no cleanup trap, needs no reserved-prefix
  fence — and KEEPS the credential fence, because an unauthenticated GET answers
  401 with a JSON envelope shaped exactly like a 404 fixture.
PLAN
}

# ── --selftest: prove the preflight can REFUSE ───────────────────────────────
#
# Four states, every exit code taken WITHOUT A PIPE. States 1 and 2 point HOME at
# an EMPTY directory so the on-disk rung genuinely has nothing to find — the
# result is then a property of bp, not of whether this host happens to be a Mac.

ST_FAIL=0
DR_STUB=""
DR_EMPTY=""
DR_N=0

# write_degraded_stub PATH — a stub bp for the DEGRADED-READ states.
#
# It answers the first $STUB_HONEST_READS list reads honestly (one
# reserved-prefix group present) and degrades every read after that — which is
# exactly the shape of a 429 or a proxy error arriving BETWEEN the delete and
# the verify. Its deletes emit a real receipt, so the whole cleanup path is
# driven end to end with no credential, no network and not one live write.
write_degraded_stub() {
  cat >"$1" <<'STUB'
#!/bin/sh
C="${STUB_STATE:-/dev/null}"
n=$(cat "$C" 2>/dev/null || echo 0)
case "$*" in
  *"placement-group list"*)
    n=$((n+1)); echo "$n" >"$C"
    if [ "$n" -le "${STUB_HONEST_READS:-1}" ]; then
      printf '{"placement_groups":[{"id":42,"name":"%sORPHAN","type":"spread"}]}\n' "$STUB_PREFIX"
      exit 0
    fi
    case "${STUB_MODE:-clean}" in
      nonjson) echo '<html>504 Gateway Time-out</html>'; exit 0 ;;
      nokey)   echo '{"ok":true}'; exit 0 ;;
      rcfail)  echo 'bp: hetzner: rate limited (429)' >&2; exit 1 ;;
      *)       echo '{"placement_groups":[]}'; exit 0 ;;
    esac
    ;;
  *"placement-group delete"*)
    case "${STUB_DELETE:-confirm}" in
      refuse)    echo '{"ok":false,"error":"placement group still present after delete"}'; exit 1 ;;
      noconfirm) echo '{"ok":true,"action":"delete"}'; exit 0 ;;
      *)         echo '{"ok":true,"action":"delete","confirmed_gone":true}'; exit 0 ;;
    esac
    ;;
esac
exit 0
STUB
  chmod +x "$1"
}

# dr_case LABEL PROBE WANT-RC NEEDLE STUB-ENV… — drive ONE production path
# (fence_or_refuse or the cleanup trap) through the degraded stub. WANT-RC is a
# number or the word "nonzero". Exit codes taken WITHOUT A PIPE, as everywhere.
dr_case() {
  local label="$1" probe="$2" want="$3" needle="$4"; shift 4
  DR_N=$((DR_N + 1))
  local out="$ART/degraded.$DR_N.out" rc=0
  set +e
  env -i "PATH=$PATH" "HOME=$DR_EMPTY" "PDS_LIVE_BP=$DR_STUB" "PDS_LIVE_ART=$ART" \
      "STUB_STATE=$ART/degraded.$DR_N.counter" "STUB_PREFIX=$PG_PREFIX" "$@" \
      "$0" --selftest-probe "$probe" >"$out" 2>&1
  rc=$?
  set -e
  local verdict="PASS"
  case "$want" in
    nonzero) [ "$rc" -ne 0 ] || verdict="FAIL" ;;
    *)       [ "$rc" = "$want" ] || verdict="FAIL" ;;
  esac
  grep -q "$needle" "$out" || verdict="FAIL"
  [ "$verdict" = "PASS" ] || ST_FAIL=1
  printf '  %-6s %-58s rc=%s (want %s)\n' "$verdict" "$label" "$rc" "$want"
  printf '         %s\n' "$(grep -F "$needle" "$out" | head -1 | sed 's/^ *//' | cut -c1-130)"
  return 0
}

st_case() { # label expect-rc env… -- (runs $0 --preflight)
  local label="$1" want="$2"; shift 2
  local out="$ART/selftest.$$.out" rc=0
  set +e
  env "$@" "$0" --preflight >"$out" 2>&1
  rc=$?
  set -e
  local verdict="PASS"
  [ "$rc" = "$want" ] || { verdict="FAIL"; ST_FAIL=1; }
  printf '  %-6s %-58s rc=%s (want %s)\n' "$verdict" "$label" "$rc" "$want"
  printf '         %s\n' "$(grep -Eo 'REFUSE — [^.]*\.|CREDENTIAL RUNG THAT PAID: .*' "$out" | head -1 | cut -c1-120)"
  ST_LAST_OUT="$out"
  return 0
}

# the four mutation blocks - SHARED by --selftest and --selftest-offline.
#
# They need no credential and no network, which is exactly why PDS-D439 could
# split the gate: --selftest-offline runs THESE, not a restatement of them, so
# the credential-free arm can never drift away from the credentialed one.
mutation_blocks() {
  local empty="$1"
  step "MUTATION 1 — a stub bp that exits 0 printing {\"ok\":true} must be REFUSED"
  local stub="$ART/stub-bp"
  printf '#!/bin/sh\necho %s\nexit 0\n' "'{\"ok\":true}'" >"$stub"
  chmod +x "$stub"
  local out="$ART/stub.out" rc=0
  set +e
  env -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$stub" "PDS_LIVE_ART=$ART" "$0" --preflight >"$out" 2>&1
  rc=$?
  set -e
  if [ "$rc" = "3" ] && grep -q 'AN EXIT CODE ALONE IS NOT SUCCESS' "$out"; then
    ok "stub refused: rc=3, and the reason names the law"
  else
    printf '  FAIL   stub bp was NOT refused (rc=%s) — the preflight is gating on the exit code alone\n' "$rc"
    ST_FAIL=1
  fi

  step "MUTATION 2 — the pipe trap, pinned by demonstration and not by comment"
  local failing="$ART/failing-bp"
  printf '#!/bin/sh\necho "boom" >&2\nexit 4\n' >"$failing"
  chmod +x "$failing"
  local piped unpiped
  piped="$(bash -c '"$1" whatever 2>/dev/null | head -1 >/dev/null && echo OK; echo "rc=$?"' _ "$failing")"
  set +e
  "$failing" whatever >/dev/null 2>&1
  unpiped=$?
  set -e
  say "  piped   : bp … | head -1 && echo OK   ->  $(printf '%s' "$piped" | tr '\n' ' ')"
  say "  unpiped : bp …                        ->  rc=$unpiped"
  if printf '%s' "$piped" | grep -q 'OK' && [ "$unpiped" = "4" ]; then
    ok "the trap is real: the pipeline printed OK at rc=0 for a command that exited $unpiped. Every rc in this runner is taken unpiped."
  else
    printf '  FAIL   the pipe-trap demonstration did not reproduce (piped=%s unpiped=%s)\n' "$piped" "$unpiped"
    ST_FAIL=1
  fi

  step "MUTATION 3 — a tree that PREDATES the apparatus must be refused, not measured"
  # The installed /Users/pelle/.local/bin/bp was f59aaf717 on 2026-07-31 and holds
  # neither hetzner_respost.go nor screenWriteReceipt. Rather than assert that from
  # a comment, this stages the same condition: a tree whose internal/cli carries a
  # command file but no apparatus, and the runner must refuse to build from it.
  local pre="$ART/pre-apparatus"
  rm -rf "$pre"
  mkdir -p "$pre/scripts" "$pre/internal/cli" "$pre/cmd/barkpark"
  cp "$0" "$pre/scripts/$SELF"
  printf 'package cli\n\n// pre-apparatus stand-in: a hetzner command file with no post-read.\n' \
    >"$pre/internal/cli/hetzner_lb_cmd.go"
  printf 'package main\n\nfunc main() {}\n' >"$pre/cmd/barkpark/main.go"
  local pout="$ART/pre.out" prc=0
  set +e
  env -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_ART=$ART/pre-art" "$pre/scripts/$SELF" --preflight >"$pout" 2>&1
  prc=$?
  set -e
  if [ "$prc" = "3" ] && grep -q 'predates the destroy apparatus' "$pout"; then
    ok "pre-apparatus tree refused: rc=3, and the reason names the missing files ($(grep -o 'missing:[^)]*' "$pout" | head -1))"
  else
    printf '  FAIL   a tree without hzResDestroyed/screenWriteReceipt was NOT refused (rc=%s)\n' "$prc"
    ST_FAIL=1
  fi

  step "MUTATION 4 — A DEGRADED READ IS A REFUSAL, NEVER AN ALL-CLEAR"
  # Before wave 31 every row below was a LIE, reproduced from the merged script
  # with this same stub: the three fence rows printed "FENCE PASSED
  # (existing=<empty>)" or died unlabelled, and all three cleanup rows printed
  # "cleanup verified by re-read: zero groups match" at exit 0 while the planted
  # orphan survived. The rows drive fence_or_refuse() and cleanup() THEMSELVES —
  # the functions --run uses — not a restatement of them.
  DR_STUB="$ART/degraded-bp"
  DR_EMPTY="$empty"
  write_degraded_stub "$DR_STUB"

  say "  fence: the read that decides whether it is safe to CREATE in this project"
  dr_case "1. fence, list exits non-zero"            fence 3 "REFUSE" \
    "STUB_MODE=rcfail"  "STUB_HONEST_READS=0"
  dr_case "2. fence, list returns non-JSON at rc=0"  fence 3 "AN EXIT CODE ALONE IS NOT SUCCESS" \
    "STUB_MODE=nonjson" "STUB_HONEST_READS=0"
  dr_case "3. fence, valid JSON, NO placement_groups key" fence 3 "AN EXIT CODE ALONE IS NOT SUCCESS" \
    "STUB_MODE=nokey"   "STUB_HONEST_READS=0"

  say "  cleanup: the re-read that decides whether the project was left clean"
  dr_case "4. cleanup re-read exits non-zero"        cleanup nonzero "CLEANUP UNVERIFIED" \
    "STUB_MODE=rcfail"  "STUB_HONEST_READS=1"
  dr_case "5. cleanup re-read returns non-JSON"      cleanup nonzero "CLEANUP UNVERIFIED" \
    "STUB_MODE=nonjson" "STUB_HONEST_READS=1"
  dr_case "6. cleanup re-read has no placement_groups key" cleanup nonzero "CLEANUP UNVERIFIED" \
    "STUB_MODE=nokey"   "STUB_HONEST_READS=1"
  dr_case "7. delete REFUSES (receipt says still present)" cleanup nonzero "REFUSED the claim" \
    "STUB_MODE=clean"   "STUB_HONEST_READS=9" "STUB_DELETE=refuse"
  dr_case "8. delete exits 0 WITHOUT confirmed_gone"  cleanup nonzero "does NOT carry confirmed_gone=true" \
    "STUB_MODE=clean"   "STUB_HONEST_READS=9" "STUB_DELETE=noconfirm"

  say "  the positive control — WITHOUT IT the eight rows above would all pass on a"
  say "  script that simply refused everything, which is the same vacuity inverted:"
  dr_case "9. healthy: orphan deleted, re-read clean -> PASS at rc=0" cleanup 0 "cleanup verified by re-read" \
    "STUB_MODE=clean"   "STUB_HONEST_READS=1" "STUB_DELETE=confirm"
  # …and row 9 alone does NOT prove the delete ran: this stub answers by READ
  # COUNT, so the second read comes back clean whether or not anything was
  # deleted. Row 10 is the same healthy state asserted on the DELETE receipt, so
  # a cleanup that silently stopped deleting could not pass the control.
  dr_case "10. healthy: the delete receipt CONFIRMED the group was gone" cleanup 0 "receipt: confirmed_gone=true" \
    "STUB_MODE=clean"   "STUB_HONEST_READS=1" "STUB_DELETE=confirm"

}

selftest() {
  build_bp
  local empty="$ART/empty-home"
  mkdir -p "$empty"

  # A correct token for states 2 and 3, taken from whichever rung this host has.
  # Never printed, never written to an artifact.
  resolve_oracle_token || refuse "--selftest needs one WORKING credential to prove the PROCEED states (2 states of 4 are refusals and would pass with none, which is exactly the vacuous green this epic exists to kill). Set HCLOUD_TOKEN or HCLOUD_CONFIG."

  step "FOUR CREDENTIAL STATES — exit codes taken without a pipe (3 = REFUSE, 0 = proceed)"
  st_case "1. no HCLOUD_TOKEN, no HETZNER_API_TOKEN, empty HOME" 3 \
    -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$BP" "PDS_LIVE_ART=$ART"
  st_case "2. HETZNER_API_TOKEN set to a CORRECT token (bp never reads it)" 3 \
    -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$BP" "PDS_LIVE_ART=$ART" "HETZNER_API_TOKEN=$ORACLE_TOKEN"
  st_case "3. HCLOUD_TOKEN correct" 0 \
    -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$BP" "PDS_LIVE_ART=$ART" "HCLOUD_TOKEN=$ORACLE_TOKEN"
  # State 4 is the BARE rung: no HCLOUD_CONFIG, no env token, just the real HOME
  # and the cli.toml the hcloud CLI wrote there. Handing it HCLOUD_CONFIG would
  # have proved only that the override works — which state 4 used to do, and
  # which is exactly why the macOS hole survived measurement for so long.
  local cfg
  cfg="$(default_hcloud_config)"
  if [ -r "$cfg" ]; then
    st_case "4. bare cli.toml rung: no HCLOUD_CONFIG, no env token" 0 \
      -i "PATH=$PATH" "HOME=$HOME" "PDS_LIVE_BP=$BP" "PDS_LIVE_ART=$ART"
    grep -q 'hcloud-cli-context' "$ST_LAST_OUT" \
      || { printf '  FAIL   state 4 proceeded but did not NAME the cli-context rung\n'; ST_FAIL=1; }
    printf '         (the file bp found unaided: %s)\n' "$cfg"
  else
    printf '  FAIL   state 4 needs an hcloud cli.toml at %s (this host has none, so the third rung is UNPROVEN here — that is a gap, not a pass)\n' "$cfg"
    ST_FAIL=1
  fi

  mutation_blocks "$empty"

  step "SELFTEST VERDICT"
  if [ "$ST_FAIL" = "0" ]; then
    ok "the preflight refuses when it should and proceeds when it should, and names the rung that paid"
    say ""
    say "  NOTE ON SCOPE: --selftest proves the PREFLIGHT. It makes no writes and is"
    say "  not the live proof. Run --run for that."
    return 0
  fi
  failed "one or more preflight self-tests did not hold — do not run --run against a live project with a preflight that cannot refuse"
}

# ── --selftest-offline: THE CREDENTIAL-FREE GATE ─────────────────────────────
#
# PDS-D439. --selftest hard-refuses at exit 3 with no credential, so a slice
# gated on it has a credential-gated green — and exit 3 looks exactly like a
# broken apparatus. This arm is the CI-able one: it scrubs every
# HCLOUD_*/HETZNER_* variable out of its own environment, re-execs itself, and
# COUNTS what survived. A run with a token in the ambient environment therefore
# proves the same thing as a run without one, which is the only way the claim
# "this work is credential-free" can be checked rather than asserted.

OFF_FAIL=0
off_ok()   { printf '  PASS    %s\n' "$*"; }
off_fail() { printf '  FAIL    %s\n' "$*"; OFF_FAIL=1; }

# STUB_PORT / STUB_SPEC — a localhost HTTP server the deposit paths are driven
# against. No credential, no network beyond 127.0.0.1.
STUB_PORT=""
STUB_SPEC=""
STUB_PID=""

start_stub_server() {
  local py="$ART/stub-server.py" portfile="$ART/stub-port"
  STUB_SPEC="$ART/stub-spec"
  cat >"$py" <<'PY'
import http.server, sys
spec, portfile = sys.argv[1], sys.argv[2]

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        status, ctype, bodyfile = open(spec).read().split("\n")[:3]
        body = open(bodyfile, "rb").read()
        self.send_response(int(status))
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(portfile, "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY
  printf '404\napplication/json\n/dev/null\n' >"$STUB_SPEC"
  rm -f "$portfile"
  python3 "$py" "$STUB_SPEC" "$portfile" &
  STUB_PID=$!
  local i=0
  while [ ! -s "$portfile" ] && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
  STUB_PORT="$(cat "$portfile" 2>/dev/null || true)"
  [ -n "$STUB_PORT" ] || failed "the localhost stub server did not come up"
  trap 'kill "$STUB_PID" 2>/dev/null || true' EXIT
}

# stub_says STATUS CONTENT-TYPE BODY-TEXT — what the next request gets back.
stub_says() {
  local bodyfile="$ART/stub-body"
  printf '%s' "$3" >"$bodyfile"
  printf '%s\n%s\n%s\n' "$1" "$2" "$bodyfile" >"$STUB_SPEC"
}

selftest_offline() {
  # ── the scrub, and then the COUNT ──────────────────────────────────────────
  if [ -z "${PDS_LIVE_OFFLINE_SCRUBBED:-}" ]; then
    # grep + cut, NOT `sed -n 's/\(A\|B\)/…/p'`: BSD sed (macOS, which is where
    # this runner lives) has no BRE alternation, so that spelling silently
    # matched nothing for HETZNER_API_TOKEN and the count arm below caught it.
    local v unsets=""
    for v in $(env | grep -E '^(HCLOUD|HETZNER)[A-Z0-9_]*=' | cut -d= -f1); do
      unsets="$unsets -u $v"
    done
    # shellcheck disable=SC2086
    exec env $unsets PDS_LIVE_OFFLINE_SCRUBBED=1 "$0" --selftest-offline
  fi

  step "CREDENTIAL-FREE BY CONSTRUCTION, AND THEN COUNTED"
  local leaked
  leaked="$(env | grep -cE '^(HCLOUD|HETZNER)[A-Z0-9_]*=' || true)"
  say "  hetzner/hcloud variables in this process environment: $leaked"
  if [ "$leaked" = "0" ]; then
    off_ok "every HCLOUD_*/HETZNER_* variable was stripped before this arm ran — the green below cannot be a credentialed green"
  else
    off_fail "$leaked hetzner/hcloud variable(s) survived the scrub"
  fi
  say "  (this arm re-execs itself scrubbed, so it proves the same thing whether or"
  say "   not the invoking shell holds a token. \`env -u HCLOUD_TOKEN -u HCLOUD_CONFIG"
  say "   -u HCLOUD_CONTEXT -u HETZNER_API_TOKEN $SELF --selftest-offline\` is the"
  say "   same run with the scrub done twice.)"

  local empty="$ART/empty-home"
  mkdir -p "$empty"
  mutation_blocks "$empty"
  [ "$ST_FAIL" = "0" ] || off_fail "one or more of the four mutation blocks did not hold"

  # ── the deposit ────────────────────────────────────────────────────────────
  start_stub_server
  HZ_API="http://127.0.0.1:$STUB_PORT/v1"
  # A placeholder that never leaves 127.0.0.1. It is not a credential and this
  # arm would fail if it were: the scrub above counted zero.
  ORACLE_TOKEN="offline-stub-not-a-credential"
  local dep="$ART/deposit"
  mkdir -p "$dep"

  step "DEPOSIT, STATE 0 — THE FAIL-OPEN AS IT SHIPPED, REPRODUCED BEFORE ANYTHING RELIES ON THE FIX"
  say "  The wave-30 server-404 leg was exactly two lines:"
  say "      smeta=\"\$(oracle \"/servers/999999999\" \"\$sbody\")\""
  say "      cp \"\$sbody\" \"\$PDS_LIVE_HARVEST/pds_live_hetzner_server_404.json\""
  say "  — no status check, no content-type check, no error.code check. Below is that"
  say "  path verbatim, against a stub answering 200 text/html."
  say "  SCOPE, STATED HONESTLY: this is ONE of the three deposits in --run, not three"
  say "  of three. The placement-group 200 and 404 legs already sit behind real"
  say "  assertions on status, content-type and error.code. One unguarded deposit is"
  say "  enough to bank whatever arrived, which is why it is worth a demonstration."
  stub_says 200 "text/html; charset=utf-8" '<html><body>504 Gateway Time-out</body></html>'
  local sbody="$ART/stub-fetch.body" old_dest="$dep/pds_live_hetzner_server_404.json" oldrec
  rm -f "$old_dest"
  oldrec="$(oracle "/servers/$HZ_MISSING_ID" "$sbody")"
  cp "$sbody" "$old_dest"
  local orc=$?
  if [ "$orc" = "0" ] && [ -s "$old_dest" ] && grep -q '<html' "$old_dest"; then
    off_ok "REPRODUCED: HTTP $(hz_field 1 "$oldrec") $(hz_field 2 "$oldrec") — an HTML page is now sitting at $(basename "$old_dest") at exit 0. That is the hole, measured, not argued."
  else
    off_fail "the fail-open did not reproduce (rc=$orc) — if the old path no longer deposits, this demonstration is stale and the fix's premise is unproven"
  fi

  step "DEPOSIT, FIXED — THREE LIES, THREE DISTINCT REFUSALS, NOTHING WRITTEN"
  local dest="$dep/fixed_404.json" rec rc
  dep_case() { # LABEL STATUS CTYPE BODY NEEDLE
    local label="$1" st="$2" ct="$3" body="$4" needle="$5"
    rm -f "$dest"
    stub_says "$st" "$ct" "$body"
    rec="$(oracle "/servers/$HZ_MISSING_ID" "$sbody")"
    set +e
    deposit_or_refuse "$label" "$rec" "$sbody" "$dest" 2>"$ART/dep.$label.err"
    rc=$?
    set -e
    if [ "$rc" = "0" ]; then
      off_fail "$label: the deposit ACCEPTED a $st $ct body"
      return 0
    fi
    if [ -e "$dest" ]; then
      off_fail "$label: the deposit refused but a file was written anyway"
      return 0
    fi
    if ! grep -q "$needle" "$ART/dep.$label.err"; then
      off_fail "$label: refused, but not for the stated reason (wanted a message naming: $needle)"
      return 0
    fi
    off_ok "$label: REFUSED, nothing written — $(sed 's/^ *//' "$ART/dep.$label.err" | head -1 | cut -c1-120)"
  }
  dep_case "not-404"        200 "text/html; charset=utf-8" '<html>hi</html>'                 "not 404"
  dep_case "not-json"       404 "text/plain; charset=utf-8" 'server not found'               "not application/json"
  dep_case "no-error-code"  404 "application/json"          '{"ok":true,"message":"gone"}'   "no top-level error.code"

  say "  and the positive control — WITHOUT IT the three rows above would pass on a"
  say "  deposit that simply refused everything, which is the same vacuity inverted:"
  rm -f "$dest"
  stub_says 404 "application/json" '{"error":{"code":"not_found","message":"volume not found","details":{}}}'
  rec="$(oracle "/volumes/$HZ_MISSING_ID" "$sbody")"
  set +e
  deposit_or_refuse "healthy" "$rec" "$sbody" "$dest" 2>"$ART/dep.healthy.err"
  rc=$?
  set -e
  if [ "$rc" = "0" ] && [ -s "$dest" ]; then
    off_ok "healthy: a real-shaped 404 IS deposited (the guard refuses lies, not everything)"
  else
    off_fail "healthy: an honest 404 was refused (rc=$rc) — the guard is too tight to harvest with"
  fi

  # ── the kind -> segment table ──────────────────────────────────────────────
  step "THE KIND->SEGMENT TABLE — DERIVED, AND THE PIN CAN RED"
  if hz_segment_table_ok; then
    off_ok "replace(kind,'-','_')+'s' reproduces every pinned segment: $HZ_FLAT_SEGMENTS"
  else
    off_fail "the pinned segments disagree with the derivation"
  fi
  set +e
  ( HZ_FLAT_SEGMENTS="certificates firewalls floating-ips load_balancers networks placement_groups primary_ips volumes zones" hz_segment_table_ok ) 2>/dev/null
  rc=$?
  set -e
  if [ "$rc" != "0" ]; then
    off_ok "MUTATION: a pin of floating-ips (the pre-underscore spelling, which is what a hand-written table gets wrong) REDS"
  else
    off_fail "MUTATION: a wrong pinned segment did NOT red — the pin is decorative"
  fi

  # ── the census ─────────────────────────────────────────────────────────────
  step "THE HARVEST TARGET — DERIVED FROM THE TREE, NOT QUOTED"
  local census="$ART/census.out"
  set +e
  harvest_census >"$census" 2>&1
  rc=$?
  set -e
  cat "$census"
  if [ "$rc" = "0" ] && grep -q 'HARVEST TARGET' "$census"; then
    off_ok "the count is derived (ledger kinds parsed from the census pin, S3 kinds derived by co-location, harvested set read from the manifest)"
  else
    off_fail "the census derivation did not complete (rc=$rc)"
  fi

  step "THE RECORDED REFUSAL"
  local mani="$REPO_ROOT/internal/cli/testdata/pds_live_hetzner_fixtures.json"
  set +e
  MANI="$mani" REFUSED="$HZ_REFUSED_KIND" FLAT="$HZ_FLAT_KINDS" python3 -c '
import json, os, sys
d = json.load(open(os.environ["MANI"]))
k = os.environ["REFUSED"]
if k in os.environ["FLAT"].split():
    sys.exit("the refused kind is still in the flat harvest list")
rs = [r for r in d.get("refusals", []) if r.get("kind") == k]
if not rs:
    sys.exit("%s is not recorded as a refusal in the manifest — a silent omission" % k)
if len(rs[0].get("ground", "")) < 80:
    sys.exit("%s is refused without a stated ground" % k)
print("  refusals[]: %s — %s" % (k, rs[0]["ground"][:110] + "..."))
'
  rc=$?
  set -e
  [ "$rc" = "0" ] && off_ok "$HZ_REFUSED_KIND is refused BY NAME with its structural ground recorded in the manifest" \
                  || off_fail "the refusal of $HZ_REFUSED_KIND is not recorded in the manifest"

  # ── the manifest emitter ───────────────────────────────────────────────────
  step "THE COMMITTED MANIFEST IS WHAT THIS SCRIPT EMITS — reproduced, not asserted"
  local repro="$ART/repro"
  rm -rf "$repro"; mkdir -p "$repro"
  cp "$REPO_ROOT"/internal/cli/testdata/pds_live_hetzner_*.json "$repro/"
  emit_manifest "$repro/pds_live_hetzner_fixtures.json" "/dev/null" "$repro"
  if diff -u "$mani" "$repro/pds_live_hetzner_fixtures.json" >"$ART/manifest.diff" 2>&1; then
    off_ok "re-emitting the manifest over the committed fixtures reproduces it byte for byte — it was written by this script, not typed"
  else
    off_fail "the committed manifest is NOT what the emitter produces (see $ART/manifest.diff): $(head -5 "$ART/manifest.diff" | tr '\n' ' ')"
  fi

  step "THE EMITTER'S NUMBERS ARE DERIVED — proven end to end against the stub"
  local hdir="$ART/harvest" hrec="$ART/harvest.tsv"
  rm -rf "$hdir"; mkdir -p "$hdir"; : >"$hrec"
  stub_says 404 "application/json; charset=utf-8" '{"error":{"code":"not_found","message":"volume not found"}}'
  harvest_issue volume "$hdir" "$hrec" 2>/dev/null
  stub_says 451 "text/html" '<html>nope</html>'
  harvest_issue zone "$hdir" "$hrec" 2>/dev/null
  emit_manifest "$hdir/pds_live_hetzner_fixtures.json" "$hrec" "$hdir"
  set +e
  M="$hdir/pds_live_hetzner_fixtures.json" python3 -c '
import json, os, re, sys
d = json.load(open(os.environ["M"]))
rows = {f["kind"]: f for f in d["fixtures"]}
v, z = rows["volume"], rows["zone"]
assert v["http_status"] == 404 and v["content_type"].startswith("application/json"), v
assert v["record"].split("\t") == ["404", v["content_type"], str(v["bytes"])], v["record"]
assert v["request"] == "GET /v1/volumes/999999999", v["request"]
# THE ZONE ROW IS THE POINT: a non-404 disposition is RECORDED, not asserted away.
assert z["http_status"] == 451 and z["content_type"].startswith("text/html"), z
assert "error_code" not in z, z
raw = open(os.path.join(os.path.dirname(os.environ["M"]), z["file"]), "rb").read()
assert z["bytes"] == len(raw), (z["bytes"], len(raw))
blob = open(os.environ["M"]).read()
runs = [m for m in re.findall(r"[A-Za-z0-9]{32,}", blob)]
assert not runs, runs[:1]
assert re.fullmatch(r"([0-9a-f]{8}-){7}[0-9a-f]{8}", v["sha256_chunked"]), v["sha256_chunked"]
print("  volume: %s %s %s bytes, record=%r" % (v["http_status"], v["content_type"], v["bytes"], v["record"]))
print("  zone  : %s %s %s bytes — RECORDED, not judged" % (z["http_status"], z["content_type"], z["bytes"]))
'
  rc=$?
  set -e
  [ "$rc" = "0" ] && off_ok "http_status/content_type/bytes are derived from the verbatim curl record; digests are hyphen-chunked in 8-char groups; a non-404 disposition is recorded rather than dropped" \
                  || off_fail "the emitter's derivation did not hold"

  step "OFFLINE VERDICT"
  if [ "$OFF_FAIL" = "0" ] && [ "$ST_FAIL" = "0" ]; then
    ok "the credential-free arm holds: 0 hetzner/hcloud variables, 4 mutation blocks, the deposit fail-open reproduced and closed, the segment pin able to red, the target count derived, and the committed manifest reproduced by its own emitter"
    say ""
    say "  WHAT THIS ARM DOES NOT PROVE. It touches no real API, so it says nothing"
    say "  about what api.hetzner.cloud actually answers for the eight unharvested"
    say "  kinds. That is --harvest-only's job and it needs a credential."
    return 0
  fi
  failed "the credential-free arm did not hold — see the FAIL rows above"
}

# ── --run: the live round trip ───────────────────────────────────────────────

run() {
  step "0 PREFLIGHT"
  preflight
  resolve_oracle_token || refuse "the INDEPENDENT oracle needs the raw token (curl cannot ask bp for it). bp resolved one but this script could not descend the same ladder — refusing to run a 'proof' in which bp is its own witness."
  ok "an independent oracle client is available (curl -> $HZ_API), so bp will not be its own witness"

  step "1 FENCE"
  local baseline brc=0
  fence_or_refuse
  set +e
  baseline="$(pg_count)"
  brc=$?
  set -e
  [ "$brc" -eq 0 ] || refuse "the baseline count read did not answer: $(read_failure_reason "$brc"). Refusing to create anything without a baseline to return the project to."
  CLEANUP_ARMED=1
  trap cleanup EXIT INT TERM HUP QUIT
  ok "zero placement groups match \"$PG_PREFIX\"; project baseline = $baseline group(s); cleanup trap armed on EXIT/INT/TERM/HUP/QUIT"
  say "  SIGKILL IS NOT TRAPPABLE and is not pretended to be. A kill -9 here leaks at"
  say "  most ONE placement group — free, inert, attached to nothing, routing nothing."
  say "  IT CANNOT ACCUMULATE: the fence above REFUSES TO START (exit 3) on any name"
  say "  matching \"$PG_PREFIX\", so the next run hard-stops until a human deletes it."
  say "  Deleting by NAME (not by id) is what makes that reap possible at all — a"
  say "  create whose receipt is unparseable never yields an id, so id-only deletion"
  say "  was REJECTED as a regression, not adopted as a tightening."
  say "  THE ONE LIMIT OF THAT GUARANTEE, STATED: it holds while the prefix holds. A"
  say "  run started with a DIFFERENT PDS_LIVE_PG_PREFIX cannot see an orphan left"
  say "  under the old one, so overriding the prefix retires the reap for that name."
  say "  FENCE: placement groups ONLY. This project holds five running production servers; nothing this runner touches routes traffic or holds data."

  step "2 CREATE (the real verb, the real API)"
  local name receipt rc=0
  name="$PG_PREFIX$(date -u +%Y%m%dT%H%M%SZ)-$$"
  receipt="$ART/create.json"
  set +e
  "$BP" cloud hetzner placement-group create --name "$name" --type spread -o json >"$receipt" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$receipt" >&2; failed "create exited $rc"; }
  local id rname
  id="$(jsonq "$receipt" 'd["placement_group"]["id"]')"   || failed "create receipt has no placement_group.id: $(cat "$receipt")"
  rname="$(jsonq "$receipt" 'd["placement_group"]["name"]')"
  [ -n "$id" ] || failed "create receipt carried an empty id"
  ok "bp receipt: ok=$(jsonq "$receipt" 'd.get("ok")') action=$(jsonq "$receipt" 'd.get("action")') id=$id name=$rname type=$(jsonq "$receipt" 'd.get("type")')"

  step "3 OBSERVE (bp's own read-back)"
  local getr="$ART/get.json"
  set +e
  "$BP" cloud hetzner placement-group get "$id" -o json >"$getr" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$getr" >&2; failed "get exited $rc"; }
  ok "bp get id=$(jsonq "$getr" 'd["placement_group"]["id"]') name=$(jsonq "$getr" 'd["placement_group"]["name"]')"

  step "4 ORACLE — an INDEPENDENT client asks the same API the same question"
  local obody="$ART/oracle-200.json" ometa ocode octype obytes
  ometa="$(oracle "/placement_groups/$id" "$obody")"
  ocode="$(hz_field 1 "$ometa")"
  octype="$(hz_field 2 "$ometa")"
  obytes="$(hz_field 3 "$ometa")"
  [ "$ocode" = "200" ] || { cat "$obody" >&2; failed "the oracle read of placement group $id answered HTTP $ocode, not 200"; }
  local oid oname otype
  oid="$(jsonq "$obody" 'd["placement_group"]["id"]')"
  oname="$(jsonq "$obody" 'd["placement_group"]["name"]')"
  otype="$(jsonq "$obody" 'd["placement_group"]["type"]')"
  [ "$oid" = "$id" ]      || failed "ORACLE DISAGREES on id: bp said $id, the API says $oid"
  [ "$oname" = "$rname" ] || failed "ORACLE DISAGREES on name: bp said $rname, the API says $oname"
  ok "HTTP $ocode $octype $obytes bytes; id/name/type match bp's receipt ($oid / $oname / $otype)"
  say "  THIS is the line that makes the run a proof: the receipt was checked against the server's own SECOND answer, taken by a different client, not against the fixture that generated it."
  if [ -n "${PDS_LIVE_HARVEST:-}" ]; then
    mkdir -p "$PDS_LIVE_HARVEST"
    cp "$obody" "$PDS_LIVE_HARVEST/pds_live_hetzner_placement_group_200.json"
    say "  harvested: $PDS_LIVE_HARVEST/pds_live_hetzner_placement_group_200.json ($obytes bytes)"
  fi

  step "5 DELETE (hzResDestroyed's confirming read fires against the real API)"
  local delr="$ART/delete.json"
  set +e
  "$BP" cloud hetzner placement-group delete "$id" --yes -o json >"$delr" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$delr" >&2; failed "delete exited $rc — the receipt refused the claim (that is the apparatus working; the resource may still exist)"; }
  local gone
  gone="$(jsonq "$delr" 'd.get("confirmed_gone")')"
  [ "$gone" = "True" ] || { cat "$delr" >&2; failed "the delete receipt did not carry confirmed_gone=true (got '$gone') — this run cannot claim the clean arm fired"; }
  ok "bp receipt: ok=$(jsonq "$delr" 'd.get("ok")') action=delete confirmed_gone=true — hzResDestroyed's (nil,nil) arm fired against a REAL 404, not a fixture"

  step "6 THE GONE PREDICATE'S GROUND TRUTH — the real 404, measured"
  local gbody="$ART/oracle-404.json" gmeta gcode gtype gbytes
  gmeta="$(oracle "/placement_groups/$id" "$gbody")"
  gcode="$(hz_field 1 "$gmeta")"
  gtype="$(hz_field 2 "$gmeta")"
  gbytes="$(hz_field 3 "$gmeta")"
  [ "$gcode" = "404" ] || failed "the deleted group answered HTTP $gcode, not 404"
  case "$gtype" in
    application/json*) : ;;
    *) failed "the 404 content-type is $gtype, not application/json — PDS-D401's load-bearing production assumption does NOT hold, and hcloud-go's errorFromBody would return a transport error instead of the clean gone arm" ;;
  esac
  local gcodefield
  gcodefield="$(jsonq "$gbody" 'd["error"]["code"]')"
  [ "$gcodefield" = "not_found" ] || failed "the 404 body's error.code is '$gcodefield', not not_found"
  ok "HTTP 404 $gtype $gbytes bytes error.code=not_found — PDS-D401 confirmed at L1 for the placement-group kind"
  say "  body: $(cat "$gbody")"
  if [ -n "${PDS_LIVE_HARVEST:-}" ]; then
    cp "$gbody" "$PDS_LIVE_HARVEST/pds_live_hetzner_placement_group_404.json"
    # THE SERVER LEG WAS THE ONE UNGUARDED DEPOSIT IN THIS RUNNER — a bare `cp`
    # of whatever arrived, with neither the status nor the content-type checked.
    # It now goes through deposit_or_refuse, which --selftest-offline drives
    # through three separate lies. A refused deposit is not fatal to the run: the
    # placement-group proof above stands on its own, and this leg is a bonus.
    local sbody="$ART/oracle-404-server.json" smeta
    smeta="$(oracle "/servers/$HZ_MISSING_ID" "$sbody")"
    if deposit_or_refuse "server-404" "$smeta" "$sbody" "$PDS_LIVE_HARVEST/pds_live_hetzner_server_404.json"; then
      say "  harvested: the placement-group 404 ($gbytes bytes) and the SERVER 404 ($(hz_field 3 "$smeta") bytes) — different kinds, different lengths, so no assertion may pin a universal byte count"
    else
      say "  the SERVER 404 leg deposited NOTHING (see the refusal above). The placement-group residue is unaffected."
    fi
  fi

  step "7 THE PROJECT IS LEFT AS IT WAS — observed, not claimed"
  local after leftovers lrc=0 arc=0
  set +e
  leftovers="$(reserved_names)"
  lrc=$?
  after="$(pg_count)"
  arc=$?
  set -e
  [ "$lrc" -eq 0 ] || failed "the final read did not answer: $(read_failure_reason "$lrc"). This run CANNOT claim it left the project as it found it — the cleanup trap is still armed and will say so."
  [ "$arc" -eq 0 ] || failed "the final count read did not answer: $(read_failure_reason "$arc")."
  [ -z "$leftovers" ] || failed "reserved-prefix groups survive the run: $leftovers"
  [ "$after" = "$baseline" ] || failed "the project holds $after placement group(s), baseline was $baseline"
  CLEANUP_ARMED=0
  ok "independent list read: zero groups match \"$PG_PREFIX\"; count back to the baseline ($after)"

  step "8 WHAT THIS RUN PROVED, AND WHAT IT DID NOT"
  cat <<'LIMIT'
  PROVED (direction: NO FALSE REFUSAL). A real Barkpark verb made a real round
  trip against api.hetzner.cloud; its receipt agreed with the same API's own
  independent second answer; and hzResDestroyed's confirming read bound on REAL
  404 bytes — clean JSON, error.code=not_found — and did not red an honest
  destroy. Until this run, PDS-D401's "production always returns a JSON 404" was
  an assumption the whole apparatus rested on.

  NOT PROVED (direction: THE REFUSAL). This run did NOT show the receipt refusing
  a lying API. A correct Hetzner will not keep handing back a resource it has
  deleted, so the hzResStillThere arm cannot be staged live at all; it stays
  proven only by the LYING-FAKE cases in internal/cli/hetzner_respost_test.go.
  Nor is the object-storage "declared" arm touched here.

  NOT REACHABLE AT ALL from the CLI: the 204 carve-out. `bp chat approve` exits
  rc=2, so that path cannot be driven from this surface by any live run.

  Anyone quoting this transcript as "the destroy apparatus is proven against
  production" is over-reading it by exactly one direction.
LIMIT
  say ""
  ok "LIVE PROOF COMPLETE — credential rung: $RUNG"
}

# --selftest-probe fence|cleanup — INTERNAL, spawned only by --selftest. It runs
# ONE production path (the real fence_or_refuse, the real cleanup trap) against
# $PDS_LIVE_BP, so the degraded-read states prove the code --run executes rather
# than a copy of it that could drift away from it silently.
selftest_probe() {
  [ -n "${PDS_LIVE_BP:-}" ] || usage "--selftest-probe is internal to --selftest and requires PDS_LIVE_BP"
  BP="$PDS_LIVE_BP"
  case "${1:-}" in
    fence)
      fence_or_refuse
      say "  FENCE PASSED (existing=<empty>) -> the run would now CREATE in this project"
      ;;
    cleanup)
      CLEANUP_ARMED=1
      trap cleanup EXIT INT TERM HUP QUIT
      exit 0
      ;;
    *) usage "--selftest-probe wants 'fence' or 'cleanup'" ;;
  esac
}

case "${1:---run}" in
  --plan)             plan ;;
  --preflight)        preflight ;;
  --selftest)         selftest ;;
  --selftest-offline) selftest_offline ;;
  --selftest-probe)   selftest_probe "${2:-}" ;;
  --harvest-only)     harvest_only ;;
  # --manifest-emit [DIR] — regenerate the manifest from the fixtures on disk.
  # It is how the committed manifest is produced, and --selftest-offline proves
  # the committed bytes are exactly what it emits.
  --manifest-emit)
    HZ_MANIFEST_DIR="${2:-$REPO_ROOT/internal/cli/testdata}"
    emit_manifest "$HZ_MANIFEST_DIR/pds_live_hetzner_fixtures.json" "${3:-/dev/null}" "$HZ_MANIFEST_DIR"
    say "emitted $HZ_MANIFEST_DIR/pds_live_hetzner_fixtures.json"
    ;;
  --run)              run ;;
  -h|--help)          plan ;;
  *)                  usage "unknown argument '$1' (want --plan | --preflight | --selftest | --selftest-offline | --harvest-only | --manifest-emit | --run)" ;;
esac
