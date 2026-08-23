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
#     a timeout, and any OTHER 500 body are never retried — they stay exactly
#     as loud as before;
#   - at most 3 retries (0.25s / 1s / 4s backoff), then the last answer stands,
#     so a PERSISTENT 500 still fails the paper.
retryable_500() {
  local code="$1" body="$2"
  [[ "$code" == "500" ]] || return 1
  grep -q '"code":"internal_error"' "$body" 2>/dev/null && return 0
  grep -q '500 · Internal Server Error' "$body" 2>/dev/null && return 0
  return 1
}

fetch_route() {
  # fetch_route <outfile> <url> [extra curl args…] — echoes the final HTTP code.
  local out="$1" url="$2" code delay
  shift 2
  code="$(curl -L -sS --connect-timeout "$curl_connect_timeout" --max-time "$curl_max_time" "$@" -o "$out" -w '%{http_code}' "$url" || true)"
  for delay in 0.25 1 4; do
    retryable_500 "$code" "$out" || break
    sleep "$delay"
    : >"$out"
    code="$(curl -L -sS --connect-timeout "$curl_connect_timeout" --max-time "$curl_max_time" "$@" -o "$out" -w '%{http_code}' "$url" || true)"
  done
  printf '%s' "$code"
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
  gui_code="$(fetch_route "$tmp/gui" "$public_url")"
  email_code="$(fetch_route "$tmp/email" "$public_url/email")"
  source_code="$(fetch_route "$tmp/source" "$public_url/source" -H 'accept: */*')"

  [[ "$gui_code" =~ ^[0-9]{3}$ ]] || gui_code=0
  [[ "$email_code" =~ ^[0-9]{3}$ ]] || email_code=0
  [[ "$source_code" =~ ^[0-9]{3}$ ]] || source_code=0
  [[ "$gui_code" == "000" ]] && gui_code=0
  [[ "$email_code" == "000" ]] && email_code=0
  [[ "$source_code" == "000" ]] && source_code=0

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
  cli_reader_ok=false
  for cli_delay in 0 0.25 1 4; do
    [[ "$cli_delay" == 0 ]] || sleep "$cli_delay"
    if "$bp_bin" -s "$server" -w "$workspace" -p "$project" -d "$dataset" \
      paper view "$public_url" --profile none >"$tmp/cli" 2>"$tmp/cli.err"; then
      [[ -s "$tmp/cli" ]] && cli_reader_ok=true
      break
    fi
    grep -q '"code":"internal_error"' "$tmp/cli.err" 2>/dev/null || break
  done

  tui_metrics="$("$tmp/widthcheck" "$tmp/cli" 80)"
  tui_max_display_width="$(jq -r '.max_display_width' <<<"$tui_metrics")"
  tui_overflow_lines="$(jq -r '.overflow_lines' <<<"$tui_metrics")"
  cli_ok=false
  if [[ "$cli_reader_ok" == true && "$tui_overflow_lines" == "0" ]]; then
    cli_ok=true
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
    --argjson email_code "$email_code" \
    --argjson source_code "$source_code" \
    --argjson email_bytes "$email_bytes" \
    --argjson source_ok "$source_ok" \
    --argjson cli_ok "$cli_ok" \
    --argjson gui_content "$gui_content" \
    --argjson email_content "$email_content" \
    --argjson tui_max_display_width "$tui_max_display_width" \
    --argjson tui_overflow_lines "$tui_overflow_lines" \
    --argjson ok "$ok" \
    '{id:$id,ok:$ok,gui:{status:$gui_code,content:$gui_content},email:{status:$email_code,bytes:$email_bytes,content:$email_content},source:{status:$source_code,kind:$source_kind,valid:$source_ok},cli:{ok:$cli_ok},tui:{max_display_width:$tui_max_display_width,overflow_lines:$tui_overflow_lines}}' \
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
