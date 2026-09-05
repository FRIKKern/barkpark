#!/usr/bin/env bash
# Exact live-corpus smoke audit for every published Paper and every reader edge.
# Emits one JSON summary and exits non-zero if any Paper fails.
set -uo pipefail

server="${BP_AUDIT_SERVER:-guerrilla}"
base="${BP_AUDIT_BASE_URL:-https://guerrilla.barkpark.cloud}"
workspace="${BP_AUDIT_WORKSPACE:-default}"
project="${BP_AUDIT_PROJECT:-default}"
dataset="${BP_AUDIT_DATASET:-production}"
bp_bin="${BP_AUDIT_BIN:-bp}"
curl_connect_timeout="${BP_AUDIT_CONNECT_TIMEOUT:-5}"
curl_max_time="${BP_AUDIT_MAX_TIME:-30}"

for required in jq curl go python3 shasum "$bp_bin"; do
  command -v "$required" >/dev/null || {
    jq -n --arg tool "$required" '{ok:false,error:"missing required command",tool:$tool}'
    exit 2
  }
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/bp-paper-audit.XXXXXX")"
trap 'trash "$tmp" >/dev/null 2>&1 || true' EXIT
inventory="$tmp/inventory.json"
inventory_stderr="$tmp/inventory.stderr"
results="$tmp/results.jsonl"
structures="$tmp/structures.jsonl"
touch "$results"
touch "$structures"

if ! go build -o "$tmp/widthcheck" ./internal/pdrender/cmd/widthcheck; then
  jq -n '{ok:false,error:"terminal width checker build failed"}'
  exit 2
fi
if ! go build -o "$tmp/htmlcheck" ./internal/pdrender/cmd/htmlcheck; then
  jq -n '{ok:false,error:"HTML Paper body checker build failed"}'
  exit 2
fi

# The flat query route is the anonymous published-read contract for the Default
# workspace/project. The equivalent explicitly-scoped route intentionally
# requires membership, so forcing -w default -p default makes a clean runner
# look private even though every Paper reader below is public.
inventory_scope=(-s "$server" -d "$dataset")
if [[ "$workspace" != "default" || "$project" != "default" ]]; then
  inventory_scope+=(-w "$workspace" -p "$project")
fi
# The inventory read gets the same narrow transport retry as the reader edges
# below (see fetch_route): one dropped DB connection here would abort the whole
# audit before it audits anything. Retries ONLY on the server's internal_error
# envelope; every other failure aborts exactly as before.
inventory_ok=false
for inventory_delay in 0 0.25 1 4; do
  [[ "$inventory_delay" == 0 ]] || sleep "$inventory_delay"
  if "$bp_bin" "${inventory_scope[@]}" search query '*' --type paper \
    --perspective published --all -o json >"$inventory" 2>"$inventory_stderr"; then
    inventory_ok=true
    break
  fi
  grep -q '"code":"internal_error"' "$inventory_stderr" 2>/dev/null || break
done
if [[ "$inventory_ok" != true ]]; then
  jq -n --arg server "$server" --rawfile detail "$inventory_stderr" \
    '{ok:false,error:"paper inventory query failed",server:$server,detail:($detail|gsub("[[:space:]]+$"; ""))}'
  exit 2
fi

if ! jq -e '
  .documents | type == "array" and length > 0 and
  all(.[]; ((._id // .id // .slug) | type == "string" and length > 0))
' "$inventory" >/dev/null 2>&1; then
  jq -n --arg server "$server" '{ok:false,error:"paper inventory must be a non-empty documents array with string ids",server:$server}'
  exit 2
fi

inventory_count="$(jq '.documents | length' "$inventory")"
inventory_ids="$tmp/inventory-ids.json"
jq -c '[.documents[] | (._id // .id // .slug)] | sort' "$inventory" >"$inventory_ids"
inventory_digest="$(shasum -a 256 "$inventory_ids" | awk '{print $1}')"
if [[ -n "${BP_AUDIT_EXPECTED_COUNT:-}" ]]; then
  if ! [[ "$BP_AUDIT_EXPECTED_COUNT" =~ ^[1-9][0-9]*$ ]] || ((inventory_count != BP_AUDIT_EXPECTED_COUNT)); then
    jq -n \
      --argjson inventory "$inventory_count" \
      --arg expected "$BP_AUDIT_EXPECTED_COUNT" \
      '{ok:false,error:"paper inventory count did not match expected count",inventory:$inventory,expected:$expected}'
    exit 2
  fi
fi

# ── Narrow transport retry ────────────────────────────────────────────────────
# The production box drops individual DB connections under memory pressure
# (measured 2026-08-23: ~27% of requests answer HTTP 500 with
# `"code":"internal_error"` / DBConnection.ConnectionError — per REQUEST, not
# per connection: /api/schemas fails at the same rate as any paper route, and
# back-to-back probes alternate which one fails). One such 500 anywhere in
# 871 papers x 4 reader edges reds the whole audit while every paper is fine.
#
# Retry is deliberately NARROW so it can never launder a real failure:
#   - ONLY an HTTP 500 whose body is the server's internal_error shape (the
#     JSON `"code":"internal_error"` envelope, or the generic "500 · Internal
#     Server Error" HTML card, which is the same crash served by the HTML
#     routes) is retried;
#   - a 4xx (422 invalid_blocks/semantic_empty …), a 200 with a hollow body,
#     and any OTHER 500 body are never retried — they stay exactly as loud as
#     before;
#   - at most 3 retries (0.25s / 1s / 4s backoff), then the last answer stands,
#     so a PERSISTENT 500 still fails the paper.
#
# 2026-09-03, scheduled run 33740962470: the audit went red on exactly ONE
# paper (`optical-compression-research-report`) with `gui:{status:0}` while its
# email and source edges answered 200 and its CLI leg was clean — and the same
# URL answered 200 in 0.2s twice by hand minutes later. status 0 is what this
# script writes when curl reports `%{http_code}` 000: the request produced NO
# HTTP answer at all (connection refused/reset, TLS handshake, or the 30s
# --max-time), so there is no verdict to be loud about. The witness could not
# even say WHICH of those it was, because the curl exit code was thrown away by
# `|| true`. Two consequences, and the sentence above about "a timeout … never
# retried" is amended by them:
#   - every HTTP edge now records the curl exit code and a named arm, so the
#     next such red names itself (this is the sibling of the CLI leg's
#     exit/arm/attempts witness, PR #15760, for the same class of red);
#   - a NO-ANSWER transport failure is retried on the same narrow terms as the
#     internal_error 500 — same 3 retries, same backoff, and the LAST answer
#     stands, so a persistent outage still fails the paper. Nothing that
#     carried an HTTP status changed: a 4xx, a hollow 200 and any other 500
#     body are refused exactly as before.
#
# transport_retryable <curl exit code> — true for the codes that mean "no HTTP
# answer was produced", i.e. the request is safe to repeat and there is nothing
# to judge if we don't:
#     7  CURLE_COULDNT_CONNECT   connection refused/reset before any request
#     28 CURLE_OPERATION_TIMEDOUT --connect-timeout or --max-time expired
#     35 CURLE_SSL_CONNECT_ERROR TLS handshake failed
#     52 CURLE_GOT_NOTHING       server closed the connection, empty reply
#     56 CURLE_RECV_ERROR        failure receiving data (reset mid-response)
# Deliberately EXCLUDED, so they stay as loud as they are today:
#     6  couldn't resolve host — a broken base URL / DNS, persistent by nature;
#        retrying would only delay a config fault we must see.
#     18 partial file — a body DID arrive; the content checks are the right
#        judge of a truncated render, not a retry.
#     55 send error — a GET has no body to send, so this points at a local
#        socket fault worth surfacing rather than a server-side blip.
#     60 SSL cert problem, 22, 47 and every other code — a real, reproducible
#        refusal or misconfiguration, never a flake.
transport_retryable() {
  case "$1" in
    7 | 28 | 35 | 52 | 56) return 0 ;;
    *) return 1 ;;
  esac
}

retryable_500() {
  local code="$1" body="$2"
  [[ "$code" == "500" ]] || return 1
  grep -q '"code":"internal_error"' "$body" 2>/dev/null && return 0
  grep -q '500 · Internal Server Error' "$body" 2>/dev/null && return 0
  return 1
}

# Set by fetch_route for the leg it just fetched (a command substitution could
# not carry them out of a subshell, and the exit code is the whole point).
fr_code=0
fr_exit=0
fr_first_exit=0
fr_attempts=0
fr_arm="ok"

fetch_route() {
  # fetch_route <outfile> <url> [extra curl args…]
  # Sets fr_code (normalised HTTP status, 0 when there was no answer), fr_exit
  # (curl's exit code for the LAST attempt — the one whose answer stands),
  # fr_first_exit (attempt 1's, so a green that survived a blip still says what
  # it survived), fr_attempts and fr_arm.
  local out="$1" url="$2" delay
  shift 2
  fr_attempts=1
  fr_code="$(curl -L -sS --connect-timeout "$curl_connect_timeout" --max-time "$curl_max_time" "$@" -o "$out" -w '%{http_code}' "$url")"
  fr_exit=$?
  fr_first_exit=$fr_exit
  for delay in 0.25 1 4; do
    if retryable_500 "$fr_code" "$out"; then
      : # the server's internal_error 500 — the pre-existing narrow retry
    elif ((fr_exit != 0)) && transport_retryable "$fr_exit"; then
      : # no HTTP answer at all — nothing to judge, so ask again
    else
      break
    fi
    sleep "$delay"
    : >"$out"
    fr_attempts=$((fr_attempts + 1))
    fr_code="$(curl -L -sS --connect-timeout "$curl_connect_timeout" --max-time "$curl_max_time" "$@" -o "$out" -w '%{http_code}' "$url")"
    fr_exit=$?
  done
  [[ "$fr_code" =~ ^[0-9]{3}$ ]] || fr_code=0
  [[ "$fr_code" == "000" ]] && fr_code=0
  # Which clause said no. `http` means the server answered and the answer was
  # refused elsewhere (the ok-gate) — not a transport problem.
  if ((fr_exit == 28)); then
    fr_arm="timeout"
  elif ((fr_exit != 0)) || [[ "$fr_code" == 0 ]]; then
    fr_arm="transport_failed"
  elif [[ "$fr_code" == "200" ]]; then
    fr_arm="ok"
  else
    fr_arm="http"
  fi
}

jq -r '.documents[] | (._id // .id // .slug)' "$inventory" | while IFS= read -r id; do
  encoded="$(jq -rn --arg value "$id" '$value|@uri')"
  encoded_ws="$(jq -rn --arg value "$workspace" '$value|@uri')"
  encoded_project="$(jq -rn --arg value "$project" '$value|@uri')"
  encoded_dataset="$(jq -rn --arg value "$dataset" '$value|@uri')"
  if [[ "$workspace" == "default" && "$project" == "default" && "$dataset" == "production" ]]; then
    public_url="$base/papers/$encoded"
  elif [[ "$workspace" == "default" && "$project" == "default" ]]; then
    public_url="$base/d/$encoded_dataset/papers/$encoded"
  else
    public_url="$base/w/$encoded_ws/p/$encoded_project/papers/$encoded"
  fi

  : >"$tmp/gui"
  : >"$tmp/email"
  : >"$tmp/source"
  fetch_route "$tmp/gui" "$public_url"
  gui_code="$fr_code" gui_exit="$fr_exit" gui_first_exit="$fr_first_exit"
  gui_attempts="$fr_attempts" gui_arm="$fr_arm"
  fetch_route "$tmp/email" "$public_url/email"
  email_code="$fr_code" email_exit="$fr_exit" email_first_exit="$fr_first_exit"
  email_attempts="$fr_attempts" email_arm="$fr_arm"
  fetch_route "$tmp/source" "$public_url/source" -H 'accept: */*'
  source_code="$fr_code" source_exit="$fr_exit" source_first_exit="$fr_first_exit"
  source_attempts="$fr_attempts" source_arm="$fr_arm"

  source_ok=false
  source_kind="unavailable"
  if [[ "$source_code" == "200" ]]; then
    source_kind="$(jq -r '.source.kind // "invalid"' "$tmp/source" 2>/dev/null || printf invalid)"
    if [[ "$source_kind" == "blocks" ]]; then
      if jq -e '.source.blocks | type == "array"' "$tmp/source" >/dev/null 2>&1; then
        source_ok=true
        jq -c --arg id "$id" \
          '{_id:$id,_rev:(._rev // "published"),blocks:.source.blocks}' \
          "$tmp/source" >>"$structures"
      fi
    elif [[ "$source_kind" == "html" ]]; then
      jq -e '.source.html | type == "string" and length > 0' "$tmp/source" >/dev/null 2>&1 && source_ok=true
    fi
  fi

  # Same narrow transport retry for the CLI reader edge: retry ONLY when the
  # command failed AND its stderr carries the server's internal_error envelope.
  # A CLI failure for any other reason (bad render, empty body, auth, usage)
  # is never retried.
  # The CLI leg fails three distinguishable ways and the witness used to record
  # only `cli:{ok:false}` for all three — widthcheck on an empty file reports
  # 0/0, so a failed command and an empty render left byte-identical evidence
  # and the 2026-08-28 / 2026-09-02 reds could not be told apart after the fact
  # (both healed on the next run, cause unrecoverable). The fields below are
  # PURELY additive witness: `cli_ok` is computed exactly as before.
  cli_reader_ok=false
  cli_exit=0
  cli_attempts=0
  for cli_delay in 0 0.25 1 4; do
    [[ "$cli_delay" == 0 ]] || sleep "$cli_delay"
    cli_attempts=$((cli_attempts + 1))
    "$bp_bin" -s "$server" -w "$workspace" -p "$project" -d "$dataset" \
      paper view "$public_url" --profile none >"$tmp/cli" 2>"$tmp/cli.err"
    cli_exit=$?
    if ((cli_exit == 0)); then
      [[ -s "$tmp/cli" ]] && cli_reader_ok=true
      break
    fi
    grep -q '"code":"internal_error"' "$tmp/cli.err" 2>/dev/null || break
  done
  cli_stderr="$(head -c 600 "$tmp/cli.err" 2>/dev/null)" || cli_stderr=""

  tui_metrics="$("$tmp/widthcheck" "$tmp/cli" 80)"
  tui_max_display_width="$(jq -r '.max_display_width' <<<"$tui_metrics")"
  tui_overflow_lines="$(jq -r '.overflow_lines' <<<"$tui_metrics")"
  cli_ok=false
  if [[ "$cli_reader_ok" == true && "$tui_overflow_lines" == "0" ]]; then
    cli_ok=true
  fi
  # Which clause said no — reported in the same precedence the gate applies.
  if ((cli_exit != 0)); then
    cli_arm="command_failed"
  elif [[ "$cli_reader_ok" != true ]]; then
    cli_arm="empty_output"
  elif [[ "$cli_ok" != true ]]; then
    cli_arm="tui_overflow"
  else
    cli_arm="ok"
  fi

  email_bytes="$(wc -c <"$tmp/email" | tr -d ' ')"
  gui_content='{"body_found":false,"meaningful":false,"visible_chars":0,"visible_words":0,"heading_count":0,"text_sha256":"","link_count":0,"invalid_links":0,"links_valid":false}'
  email_content="$gui_content"
  if [[ "$gui_code" == "200" ]]; then
    checked_gui_content="$("$tmp/htmlcheck" gui "$tmp/gui" 2>/dev/null)" && gui_content="$checked_gui_content"
  fi
  if [[ "$email_code" == "200" ]]; then
    checked_email_content="$("$tmp/htmlcheck" email "$tmp/email" 2>/dev/null)" && email_content="$checked_email_content"
  fi
  gui_content_ok="$(jq -r '.body_found and .meaningful' <<<"$gui_content")"
  email_content_ok="$(jq -r '.body_found and .meaningful' <<<"$email_content")"
  email_links_ok="$(jq -r '.links_valid' <<<"$email_content")"
  ok=false
  if [[ "$gui_code" == "200" && "$email_code" == "200" && \
    "$gui_content_ok" == true && "$email_content_ok" == true && "$email_links_ok" == true && \
    "$source_ok" == true && "$cli_ok" == true ]]; then
    ok=true
  fi

  jq -nc \
    --arg id "$id" \
    --arg source_kind "$source_kind" \
    --argjson gui_code "$gui_code" \
    --argjson gui_exit "$gui_exit" \
    --argjson gui_first_exit "$gui_first_exit" \
    --arg gui_arm "$gui_arm" \
    --argjson gui_attempts "$gui_attempts" \
    --argjson email_code "$email_code" \
    --argjson email_exit "$email_exit" \
    --argjson email_first_exit "$email_first_exit" \
    --arg email_arm "$email_arm" \
    --argjson email_attempts "$email_attempts" \
    --argjson source_code "$source_code" \
    --argjson source_exit "$source_exit" \
    --argjson source_first_exit "$source_first_exit" \
    --arg source_arm "$source_arm" \
    --argjson source_attempts "$source_attempts" \
    --argjson email_bytes "$email_bytes" \
    --argjson source_ok "$source_ok" \
    --argjson cli_ok "$cli_ok" \
    --argjson cli_exit "$cli_exit" \
    --arg cli_arm "$cli_arm" \
    --argjson cli_attempts "$cli_attempts" \
    --arg cli_stderr "$cli_stderr" \
    --argjson gui_content "$gui_content" \
    --argjson email_content "$email_content" \
    --argjson tui_max_display_width "$tui_max_display_width" \
    --argjson tui_overflow_lines "$tui_overflow_lines" \
    --argjson ok "$ok" \
    '{id:$id,ok:$ok,gui:{status:$gui_code,exit:$gui_exit,first_exit:$gui_first_exit,arm:$gui_arm,attempts:$gui_attempts,content:$gui_content},email:{status:$email_code,exit:$email_exit,first_exit:$email_first_exit,arm:$email_arm,attempts:$email_attempts,bytes:$email_bytes,content:$email_content},source:{status:$source_code,exit:$source_exit,first_exit:$source_first_exit,arm:$source_arm,attempts:$source_attempts,kind:$source_kind,valid:$source_ok},cli:{ok:$cli_ok,exit:$cli_exit,arm:$cli_arm,attempts:$cli_attempts,stderr:$cli_stderr},tui:{max_display_width:$tui_max_display_width,overflow_lines:$tui_overflow_lines}}' \
    >>"$results"
done

structure_input="$tmp/structures.json"
structure_report="$tmp/structure-report.json"
jq -s '.' "$structures" >"$structure_input"
python3 scripts/paper_structure.py --input "$structure_input" --summary-only \
  >"$structure_report" || true

jq -s --arg server "$server" --arg base "$base" --argjson inventory "$inventory_count" \
  --arg inventory_digest "$inventory_digest" --slurpfile inventory_ids "$inventory_ids" \
  --slurpfile structure "$structure_report" '
  {
    ok: (
      length == $inventory and
      all(.[]; .ok) and
      ($structure | length == 1 and .[0].violations == 0)
    ),
    server: $server,
    base_url: $base,
    inventory: $inventory,
    inventory_ids: $inventory_ids[0],
    inventory_digest: $inventory_digest,
    audited: length,
    passed: map(select(.ok)) | length,
    failed: map(select(.ok | not)) | length,
    structure: $structure[0],
    failures: map(select(.ok | not)),
    results: .
  }
' "$results"

jq -s --argjson inventory "$inventory_count" --slurpfile structure "$structure_report" -e \
  'length == $inventory and all(.[]; .ok) and
   ($structure | length == 1 and .[0].violations == 0)' \
  "$results" >/dev/null
