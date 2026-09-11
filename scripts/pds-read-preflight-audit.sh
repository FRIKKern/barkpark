#!/usr/bin/env bash
# pds-read-preflight-audit.sh — the census, and the ratchet, for the fail-open
# class named by pds-w30-anonymous-read-preflight-audit.
#
# THE CLASS, IN ONE SENTENCE
# --------------------------
# guerrilla answers PUBLISHED READS to a caller with no Authorization header at
# all, so any preflight that establishes "we have credentials" by taking a read
# and checking its exit code + shape PROCEEDS with no write credential, and only
# discovers it at the first mutation.
#
# THE MECHANISM, MEASURED 2026-09-11 AGAINST https://guerrilla.barkpark.cloud
# --------------------------------------------------------------------------
# It is worse than "the server is generous", and the difference decides the fix.
# The server is NOT generous to a wrong credential — it is generous to NO
# credential, and `bp` manufactures that state out of a wrong one:
#
#   raw HTTP, GET /v1/data/query/production/task?limit=1
#     (no Authorization header)            -> HTTP 200, documents
#     Authorization: Bearer not-a-real-token -> HTTP 401 unauthorized
#     Authorization: Bearer deadbeefdeadbeef -> HTTP 401 unauthorized
#   raw HTTP, POST /v1/data/mutate/production, no header -> HTTP 401  (writes ARE gated)
#   raw HTTP, GET  /v1/tasks/<id>,            no header -> HTTP 401  (task layer IS gated)
#
#   bp, with BARKPARK_TOKEN=not-a-real-token, traced through a logging proxy:
#     GET /v1/capabilities?views=1&chat=1        auth='Bearer not-a-real-token' -> 200
#     GET /v1/data/query/production/task?limit=1 auth=None                      -> 200
#     `bp doc ls task --limit 1 -o json` => rc=0 and a full, well-shaped listing.
#
# bp DROPS the bearer on the data-query read. A garbage token that the server
# would have refused never reaches it, so the read succeeds ANONYMOUSLY and
# exits 0. No read receipt — not its rc, not its shape, not its row count — can
# therefore distinguish "authenticated" from "not authenticated at all".
#
# THIS SUPERSEDES the row's 2026-08-24 attempt note, which recorded
# `Bearer deadbeef -> HTTP 200 count=1`. That is no longer reproducible at the
# HTTP layer: an invalid bearer now 401s. The fail-open survives only through a
# client that omits the header, which is exactly what bp does.
#
# THE FIX PATTERN
# ---------------
# Ask bp who it thinks it is, and judge the SHAPE, never the exit code:
#
#     tier="$(bp whoami -o json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("auth_tier",""))')"
#     case "$tier" in write|admin|root) : ;; *) refuse "no writing principal (auth_tier=$tier)";; esac
#
# `bp whoami` EXITS 0 for an anonymous caller too — it reports auth_tier="none"
# with token_present=true and token_source="default" (the built-in
# `barkpark-dev-token`). The exit code carries no information; the tier carries
# all of it. scripts/pds-live-bp-write-receipt.sh is the reference implementation.
#
# WHAT THIS SCRIPT DOES
# ---------------------
#   census   (default) derive the candidate set by PREDICATE — every script under
#            scripts/ that issues a write at a command position — and print each
#            one's registered disposition. A candidate with no disposition is a
#            FAILURE: that is the ratchet. A snapshot list would go stale the
#            first time someone adds a script; a predicate cannot.
#   prove    run the live control pair against the configured server: an
#            anonymous published READ that must answer 200, beside an anonymous
#            WRITE that must answer 401/403. NO TOKEN IS EVER SENT OR SPENT.
#
# USAGE
#   bash scripts/pds-read-preflight-audit.sh [census]
#   bash scripts/pds-read-preflight-audit.sh prove [--server URL]
#
# EXIT STATUS
#   0  census clean / proof held
#   1  a candidate carries no disposition, or the proof did not hold
#   2  could not measure (no python3, no curl, unreadable tree)

set -uo pipefail

ROOT="${PDS_AUDIT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS_DIR="$ROOT/scripts"
SERVER_DEFAULT="https://guerrilla.barkpark.cloud"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die2() { printf 'CANNOT MEASURE: %s\n' "$*" >&2; exit 2; }

# ── THE REGISTRY ─────────────────────────────────────────────────────────────
# One line per audited script:  <path>|<disposition>|<preflight, verbatim>|<why>
#
# Dispositions:
#   UPGRADED   the preflight now asserts a WRITING auth_tier off `bp whoami`.
#   HARMLESS   the preflight cannot be answered anonymously, and the reason is
#              a MEASUREMENT, not an argument.
#   NO-PREFLIGHT  the script does not establish credentials with a read at all:
#              it writes, and lets the write's own 401/403 refuse it. This is
#              fail-CLOSED and needs no change.
#   LOCAL-WRITE   the "write" is to the local filesystem, not to a ledger.
#   FIXTURE    the write verb appears only inside a PLANTED fixture the script
#              greps for; it is never executed.
#
# A `|` in a quoted preflight is escaped as \x7c by the writer of this table.
registry() {
cat <<'REG'
scripts/pds-live-bp-write-receipt.sh|UPGRADED|bp_read "$probe" ... then: tier="$(auth_tier "$who")"; if ! writer_tier "$tier"; then refuse "bp resolved NO writing principal (auth_tier=...)"|The reference implementation. The read probe is kept for its SHAPE check and is explicitly documented as fail-open on its own; the refusal is made by whoami's auth_tier.
scripts/pds-crown-stamp.sh|UPGRADED|"$BP_BIN" task get "$task_id" -o json >"$out" 2>/dev/null \x7c\x7c die "bp task get $task_id failed - nothing was written"|Writes with `bp task stamp ... --yes`. The `bp task get` preflight is NOT anonymously answerable (measured: with no credential bp exits 2, "command \"task\" exists but is hidden at your auth tier (tier=none)"; raw GET /v1/tasks/<id> anonymous -> 401), but it cannot tell a READ tier from a WRITE tier, so a whoami auth_tier assertion was added ahead of it.
scripts/pds-ledger-census.sh|HARMLESS|server, token, credential = resolve_credential(...); if not server or not token: die(EXIT_USAGE, "no server/token: pass --server/--token, set BARKPARK_SERVER/BARKPARK_TOKEN, or run `bp login`")|Clause 11's readback arm issues a real `bp task stamp`, and its preflight is an HTTP published read. HttpTransport ALWAYS attaches the resolved bearer and the script dies EXIT_USAGE when no token resolves, so the anonymous door is unreachable from here: a wrong token 401s and refuse_unauthenticated exits 5. Measured: Bearer not-a-real-token on GET /v1/data/query/production/task -> HTTP 401.
scripts/onramp-live-client-smoke.sh|LOCAL-WRITE|if ! command -v "$BP_BIN" >/dev/null 2>&1; then echo "REFUSE: bp binary not found ..."; exit 1; fi|`bp onramp claude-code --write` writes .mcp.json into a scratch directory; nothing in this harness writes to a ledger. Its only credential branch is the JSON-RPC handshake, which is fail-CLOSED (it drives `task_ready` through `bp mcp serve`, and the task layer 401s an anonymous caller). Its real defect was a SILENT skip: the skipped handshake was counted as neither pass nor fail, so the summary printed "N passed, 0 failed" for a run that never tested it. The skip is now counted and named in the summary.
scripts/cmux-smoke.sh|NO-PREFLIGHT|BP_BIN="${BP:-bp}"; if ! command -v "$BP_BIN" >/dev/null 2>&1; then echo "REFUSE: bp binary not found ..."; exit 1; fi|Issues REAL ledger writes (`bp task create --publish --yes`, `bp doc patch task`, `bp task close`), but its only preflight is a `command -v` PATH check - it never takes a read and calls that a credential. The first write is the first judgement, which is fail-closed.
scripts/docs-anchors-check.sh|FIXTURE|printf ... 'bp task close x w 1 done "s"'|The only bp write verb in this file is planted text inside a fixture the tripwire greps FOR. Nothing is executed against any server.
scripts/pdf-p1-refire.sh|NO-PREFLIGHT|(none - the control-plane POST is the first judgement)|Provisions through the control plane with tokens read from the environment / ~/.config/barkpark/config.json and judges each POST's own status. No read stands in for a credential.
scripts/pds-pull-proof.sh|NO-PREFLIGHT|(none - the POST is itself the assertion)|Its single POST is a probe of /api/workspaces/<ws>/import that EXPECTS a refusal and reports the status; it is an assertion, not a privileged write behind a preflight.
scripts/create-quickstart-smoke.sh|NO-PREFLIGHT|"$BP" capabilities -o json ... && ok "bp capabilities -o json returns a parseable manifest"|Every write goes to an EPHEMERAL server this script boots, with a token it mints itself; there is no shared ledger and no standing credential to fail open on.
scripts/task-lease-renew.sh|NO-PREFLIGHT|(none - the script POSTs and judges the POST)|POSTs /v1/tasks/:doc_id/renew directly and treats 401/403 as terminal (die_auth names BARKPARK_TASK_TOKEN). Nothing is read first to "prove" the credential.
scripts/landed-mark.sh|NO-PREFLIGHT|401\x7c403) die_auth "$RC_CODE" "GET /v1/tasks/${id}"|Its reads are on /v1/tasks/<id>, which is 401 to an anonymous caller (measured), and every 401/403 is routed to die_auth. Fail-closed on both halves.
scripts/demo-living-values.sh|UPGRADED|R=$(bp_curl_body -s "${AUTH[@]}" "$BP_SERVER/v1/capabilities" \x7c grep -o '"auth_tier":"[a-z]*"' \x7c head -1); check "API" "server reachable + token accepted (admin tier)" '"auth_tier":"admin"' "$R"|Already the correct shape, and independently useful as a second reference: /v1/capabilities answers 200 to a garbage bearer, so its rc proves nothing - the assertion is on auth_tier.
scripts/media-smoke.sh|NO-PREFLIGHT|(none - the first call is the upload POST)|Writes first; a missing credential surfaces as the write's own failure.
scripts/pdf-kill-listener-proof.sh|NO-PREFLIGHT|(none - the first ledger call is the POST /v1/fleet/beat itself)|Posts fleet heartbeats with the token attached and reads the roster afterwards; no read is used to establish that a credential exists.
scripts/pdf-efficiency-proof.sh|NO-PREFLIGHT|(none - no read establishes the credential)|Writes ride bp_curl with the token attached; there is no read-shaped credential gate.
scripts/pdf-mvp0-journey-proof.sh|NO-PREFLIGHT|if [ "${CP_ANON:-000}" != "401" ]; then abort 0 "env:cp-fleet-supports-shape" ...|Inverts the class deliberately: it ASSERTS the anonymous refusal before it writes, and aborts when a door answers anything but 401.
scripts/bp-vercel-quick-setup.sh|NO-PREFLIGHT|wc="$(bp_curl_code -s -o /dev/null -X POST "$SCOPED/v1/data/mutate/$DATASET" ...)"; ok "read token sees $rc published doc(s); write returns HTTP $wc (want 403)"|Asserts the WRITE's status directly rather than inferring authority from a read.
REG
}

# ── THE PREDICATE ────────────────────────────────────────────────────────────
# A candidate is a script under scripts/ that issues a write AT A COMMAND
# POSITION. The "command position" qualifier is the whole difference between a
# census and a grep: scripts/pr-task-gate.sh, scripts/branch-owner.sh and
# scripts/docs-anchors-check.sh all contain the literal text `bp task close` and
# `bp task stamp` inside operator-facing MESSAGES, and none of them writes.
#
# Two families are matched:
#   (a) a bp write verb invoked as a command   - `bp task stamp`, `"$BP" doc create`
#   (b) an HTTP write to a ledger route        - curl -X POST .../v1/data/mutate|/v1/tasks/...
# A line whose first non-blank character is `#` is never a candidate.
candidates() {
  local f rel stripped
  stripped="$(mktemp)" || die2 "mktemp failed"
  # A PIPELINE IS NOT SAFE HERE. Under `set -o pipefail`, `grep -v … | grep -q …`
  # returns 141 whenever the -q side matches early enough to SIGPIPE the -v side,
  # and 141 is indistinguishable from "no match" to the `if`. That silently DROPPED
  # candidates, and it dropped DIFFERENT ones from run to run because whether the
  # upstream grep has finished writing depends on the file's size. Measured here on
  # 2026-09-11: two consecutive censuses over the same tree disagreed, 12 rows vs 10.
  # So the comment-stripped body goes to a FILE and every match is a plain, single
  # command whose exit status means only what it says.
  while IFS= read -r f; do
    rel="${f#"$ROOT"/}"
    grep -vE '^[[:space:]]*#' "$f" >"$stripped" 2>/dev/null
    if grep -qE '(^[[:space:]]*|[;&][[:space:]]+|\|\|[[:space:]]+|&&[[:space:]]+|\$\(|`)("?\$\{?[A-Z_]*BP[A-Z_]*\}?"?|bp)[[:space:]]+(task[[:space:]]+(stamp|close|create|claim|pulse|release|stage|next|landed|reopen)|doc[[:space:]]+(create|patch|publish|unpublish|delete)|paper[[:space:]]+(create|publish)|bulldocs[[:space:]]+publish|seed|schema[[:space:]]+apply|onramp[[:space:]]+[a-z-]+[[:space:]]+--write)' "$stripped"; then
      printf '%s\n' "$rel"; continue
    fi
    if grep -qE '\-X[[:space:]]*"?(POST|PATCH|PUT|DELETE)' "$stripped" \
       && grep -qE '/v1/(data/mutate|tasks/|media/|plugins/bulldocs|schemas/|auth/login-tickets|fleet/)' "$stripped"; then
      printf '%s\n' "$rel"
    fi
    # This file is excluded from its own census on purpose: registry() is a
    # quoted heredoc that QUOTES write verbs verbatim, so the predicate — which
    # can strip comments but not heredoc bodies — would match the audit on its
    # own evidence. It issues no write of any kind; `prove` sends no token.
  done < <(find "$SCRIPTS_DIR" -type f -name '*.sh' ! -name '*_test.sh' ! -name '*.test.sh' \
             ! -name 'pds-read-preflight-audit.sh' | sort)
  rm -f "$stripped"
}

cmd_census() {
  command -v python3 >/dev/null 2>&1 || die2 "python3 not found"
  [ -d "$SCRIPTS_DIR" ] || die2 "no $SCRIPTS_DIR"

  local reg cand missing=0 n=0
  reg="$(registry)" || die2 "registry unreadable"
  cand="$(candidates)"

  say "=== read-preflight audit — the write-after-preflight census ==="
  say ""
  say "Candidates are DERIVED by predicate (a write at a command position), never listed."
  say ""

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    n=$((n + 1))
    local line disp pre why
    line="$(printf '%s\n' "$reg" | grep -F -- "$rel|" | head -1)"
    if [ -z "$line" ]; then
      warn "UNDISPOSITIONED: $rel issues a write and carries no entry in this file's registry()."
      warn "  Add one line: <path>|<UPGRADED|HARMLESS|NO-PREFLIGHT|LOCAL-WRITE>|<preflight verbatim>|<why>"
      warn "  Quote the preflight it uses to establish credentials, and say what a run with NO"
      warn "  credential would do. If it has none, say so — NO-PREFLIGHT is fail-closed and fine."
      missing=$((missing + 1))
      continue
    fi
    disp="$(printf '%s' "$line" | cut -d'|' -f2)"
    pre="$(printf '%s' "$line" | cut -d'|' -f3 | sed 's/\\x7c/|/g')"
    why="$(printf '%s' "$line" | cut -d'|' -f4- | sed 's/\\x7c/|/g')"
    say "$rel"
    say "  disposition : $disp"
    say "  preflight   : $pre"
    say "  why         : $why"
    say ""
  done <<<"$cand"

  say "candidates: $n   undispositioned: $missing"
  if [ "$missing" -ne 0 ]; then
    warn ""
    warn "FAIL: $missing script(s) write without a registered disposition."
    return 1
  fi
  say "OK: every script that writes carries a disposition."
  return 0
}

# ── THE LIVE PROOF ───────────────────────────────────────────────────────────
# The control pair. NOTHING here sends a token, so no credential is spent and
# no row is touched. A single 200 on the read would be a claim; the 200 BESIDE
# the 401 on the write is the proof, because it rules out "the server is down"
# and "the server answers everything" in the same two commands.
cmd_prove() {
  local server="$SERVER_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --server) server="${2:-}"; shift 2 ;;
      *) warn "unknown flag for prove: $1"; return 2 ;;
    esac
  done
  command -v curl >/dev/null 2>&1 || die2 "curl not found"

  local read_code write_code task_code fails=0
  read_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
      "$server/v1/data/query/production/task?limit=1" 2>/dev/null)" || read_code=000
  write_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
      -X POST -H 'content-type: application/json' -d '{"mutations":[]}' \
      "$server/v1/data/mutate/production" 2>/dev/null)" || write_code=000
  task_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
      "$server/v1/tasks/pds-w30-anonymous-read-preflight-audit" 2>/dev/null)" || task_code=000

  say "=== anonymous-read control pair against $server (no token sent) ==="
  say "  GET  /v1/data/query/production/task?limit=1   -> HTTP $read_code"
  say "  POST /v1/data/mutate/production               -> HTTP $write_code"
  say "  GET  /v1/tasks/<id>                           -> HTTP $task_code"
  say ""

  if [ "$read_code" = "200" ]; then
    say "  READ answers 200 ANONYMOUSLY — a read receipt cannot prove a credential."
  else
    warn "  the anonymous read answered $read_code, not 200."
    warn "  Either the posture changed (good — re-audit) or the server is unreachable."
    fails=$((fails + 1))
  fi
  case "$write_code" in
    401|403) say "  WRITE is gated ($write_code) — the exposure is a READ posture, not an open door." ;;
    000)     warn "  the anonymous write answered 000 — unreachable, so NOTHING was measured."; fails=$((fails + 1)) ;;
    *)       warn "  the anonymous write answered $write_code, not 401/403. THIS IS THE LOUD ONE:"
             warn "  an anonymous caller reached the mutate door. Stop and escalate."
             fails=$((fails + 1)) ;;
  esac
  case "$task_code" in
    401|403) say "  TASK layer is gated ($task_code) — a \`bp task …\` read IS a credential signal." ;;
    *)       warn "  the anonymous task read answered $task_code, not 401/403 — the HARMLESS"
             warn "  disposition on scripts/pds-crown-stamp.sh rests on this. Re-audit."
             fails=$((fails + 1)) ;;
  esac

  say ""
  [ "$fails" -eq 0 ] && { say "PROOF HELD: published reads are anonymous, writes are not."; return 0; }
  warn "PROOF DID NOT HOLD ($fails check(s))."
  return 1
}

main() {
  case "${1:-census}" in
    census|"") shift 2>/dev/null || true; cmd_census ;;
    prove)     shift; cmd_prove "$@" ;;
    -h|--help) sed -n '/^# USAGE/,/^# EXIT STATUS/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) warn "unknown command: $1"; return 2 ;;
  esac
}

main "$@"
