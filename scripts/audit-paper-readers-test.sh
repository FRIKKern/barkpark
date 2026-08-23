#!/usr/bin/env bash
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bp-paper-audit-test.XXXXXX")"
trap 'trash "$tmp" >/dev/null 2>&1 || true' EXIT

cat >"$tmp/fake-bp" <<'FAKE_BP'
#!/usr/bin/env bash
# Per-verb invocation counters for the transport-retry fixtures.
bp_count() {
  local key="$1" file count
  [[ -n "${BP_FIXTURE_COUNT_DIR:-}" ]] || { printf 1; return; }
  file="$BP_FIXTURE_COUNT_DIR/bp_$key"
  count=$(( $(cat "$file" 2>/dev/null || printf 0) + 1 ))
  printf '%s' "$count" >"$file"
  printf '%s' "$count"
}
if [[ " $* " == *" search query "* ]]; then
  if [[ -n "${BP_FIXTURE_INVENTORY_ARGS_FILE:-}" ]]; then
    printf '%s\n' "$*" >"$BP_FIXTURE_INVENTORY_ARGS_FILE"
  fi
  if [[ "${BP_FIXTURE_INVENTORY_FLAKY:-}" == "1" && "$(bp_count inventory)" -le 2 ]]; then
    printf '%s\n' '{"error":{"code":"internal_error","message":"server error (fixture)"},"ok":false}' >&2
    exit 8
  fi
  if [[ "${BP_FIXTURE_EMPTY:-}" == "1" ]]; then
    printf '%s\n' '{"documents":[]}'
  else
    printf '%s\n' '{"documents":[{"_id":"blocks-paper"},{"id":"html-paper"}]}'
  fi
  exit 0
fi
if [[ " $* " == *" paper view "* && " $* " == *" --profile none "* ]]; then
  if [[ "${BP_FIXTURE_CLI_FLAKY:-}" == "1" && "$(bp_count cli)" -le 2 ]]; then
    printf '%s\n' '{"error":{"code":"internal_error","message":"server error (fixture)"},"ok":false}' >&2
    exit 8
  fi
  if [[ "${BP_FIXTURE_WIDE:-}" == "1" ]]; then
    printf '%081d\n' 0
    exit 0
  fi
  if [[ "${BP_FIXTURE_PUNCTUATION_BODY:-}" == "1" ]]; then
    printf '/\n'
    exit 0
  fi
  printf 'readable\n'
  exit 0
fi
exit 9
FAKE_BP

cat >"$tmp/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
out=""
url=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-H|--connect-timeout|--max-time) shift 2 ;;
    -L|-sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
# Per-URL invocation counter, used by the transport-retry fixtures and by the
# no-retry assertions (a 4xx must be fetched exactly once).
count=1
if [[ -n "${BP_FIXTURE_COUNT_DIR:-}" ]]; then
  key="$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')"
  count_file="$BP_FIXTURE_COUNT_DIR/$key"
  count=$(( $(cat "$count_file" 2>/dev/null || printf 0) + 1 ))
  printf '%s' "$count" >"$count_file"
fi
# Transport flake: the server's per-request internal_error 500 (dropped DB
# connection). FLAKY heals on the third try; PERSISTENT never does.
if [[ "${BP_FIXTURE_FLAKY_500:-}" == "1" && "$count" -le 2 ]] ||
  [[ "${BP_FIXTURE_PERSISTENT_500:-}" == "1" ]]; then
  printf '%s' '{"error":{"code":"internal_error","hint":"Retry shortly","message":"server error (fixture)"},"ok":false}' >"$out"
  printf '500'
  exit 0
fi
if [[ "$url" == */source ]]; then
  if [[ "$url" == *html-paper* ]]; then
    printf '%s' '{"source":{"kind":"html","html":"<p>legacy</p>"}}' >"$out"
  elif [[ "${BP_FIXTURE_STRUCTURAL:-}" == "1" ]]; then
    printf '%s' '{"_rev":"rev-1","source":{"kind":"blocks","blocks":[{"type":"list","items":[{"content":[{"type":"text","value":"invisible"}]}]}]}}' >"$out"
  else
    printf '%s' '{"source":{"kind":"blocks","blocks":[]}}' >"$out"
  fi
elif [[ "$url" == */email ]]; then
  if [[ "${BP_FIXTURE_STALLED:-}" == "1" ]]; then
    printf '000'
    exit 28
  elif [[ "${BP_FIXTURE_EMPTY_BODY:-}" == "1" ]]; then
    printf '%s' '<!doctype html><body class="bp-paper-surface"></body>' >"$out"
  elif [[ "${BP_FIXTURE_PUNCTUATION_BODY:-}" == "1" ]]; then
    printf '%s' '<!doctype html><body class="bp-paper-surface"><p>/</p></body>' >"$out"
  else
    if [[ "${BP_FIXTURE_BAD_EMAIL_LINK:-}" == "1" ]]; then
      printf '%s' '<!doctype html><body class="bp-paper-surface"><p>mail</p><a href="./relative">bad</a></body>' >"$out"
    else
      printf '%s' '<!doctype html><body class="bp-paper-surface"><p>mail</p><a href="https://fixture.invalid/papers/next">next</a></body>' >"$out"
    fi
  fi
else
  if [[ "${BP_FIXTURE_EMPTY_BODY:-}" == "1" ]]; then
    printf '%s' '<!doctype html><article id="paper-body"></article>' >"$out"
  elif [[ "${BP_FIXTURE_PUNCTUATION_BODY:-}" == "1" ]]; then
    printf '%s' '<!doctype html><article id="paper-body"><p>/</p></article>' >"$out"
  else
    printf '%s' '<!doctype html><article id="paper-body"><p>reader</p></article>' >"$out"
  fi
  # The GUI route answers non-200 while still serving a perfectly well-formed,
  # meaningful body. This is the shape that actually happened in production:
  # content checks alone say "looks fine", and only the status gate catches it.
  if [[ "${BP_FIXTURE_GUI_422:-}" == "1" ]]; then
    printf '422'
    exit 0
  fi
fi
printf '200'
FAKE_CURL

chmod +x "$tmp/fake-bp" "$tmp/curl"
PATH="$tmp:$PATH" BP_FIXTURE_INVENTORY_ARGS_FILE="$tmp/inventory-args" \
  BP_AUDIT_BIN="$tmp/fake-bp" BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/result.json"

inventory_args="$(<"$tmp/inventory-args")"
if [[ " $inventory_args " == *" -w "* || " $inventory_args " == *" -p "* ]]; then
  printf 'default public inventory unexpectedly used the authenticated scoped route: %s\n' \
    "$inventory_args" >&2
  exit 1
fi
if [[ " $inventory_args " != *" -s guerrilla "* || " $inventory_args " != *" -d production "* ]]; then
  printf 'default public inventory lost its explicit server/dataset: %s\n' "$inventory_args" >&2
  exit 1
fi

jq -e '
  .ok and .inventory == 2 and .audited == 2 and .passed == 2 and .failed == 0 and
  .structure.papers_scanned == 1 and .structure.violations == 0 and
  .inventory_ids == ["blocks-paper", "html-paper"] and
  (.inventory_digest | test("^[0-9a-f]{64}$")) and
  (.results | length == 2) and
  all(.results[];
    .tui.max_display_width <= 80 and .tui.overflow_lines == 0 and
    .gui.content.body_found and .gui.content.meaningful and
    .email.content.body_found and .email.content.meaningful and
    .email.content.links_valid and .email.content.invalid_links == 0
  )
' \
  "$tmp/result.json" >/dev/null

if PATH="$tmp:$PATH" BP_FIXTURE_WIDE=1 BP_AUDIT_BIN="$tmp/fake-bp" \
  BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/wide-result.json"; then
  printf 'wide TUI output unexpectedly passed\n' >&2
  exit 1
fi

jq -e '
  .ok == false and .failed == 2 and
  all(.failures[]; .tui.max_display_width == 81 and .tui.overflow_lines == 1)
' "$tmp/wide-result.json" >/dev/null

if PATH="$tmp:$PATH" BP_FIXTURE_EMPTY_BODY=1 BP_AUDIT_BIN="$tmp/fake-bp" \
  BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/empty-body-result.json"; then
  printf 'empty GUI/email Paper bodies unexpectedly passed\n' >&2
  exit 1
fi

jq -e '
  .ok == false and .failed == 2 and
  all(.failures[];
    (.gui.content.body_found and (.gui.content.meaningful | not)) and
    (.email.content.body_found and (.email.content.meaningful | not))
  )
' "$tmp/empty-body-result.json" >/dev/null

if PATH="$tmp:$PATH" BP_FIXTURE_PUNCTUATION_BODY=1 BP_AUDIT_BIN="$tmp/fake-bp" \
  BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/punctuation-body-result.json"; then
  printf 'punctuation-only GUI/email Paper bodies unexpectedly passed\n' >&2
  exit 1
fi

jq -e '
  .ok == false and .failed == 2 and
  all(.failures[];
    (.gui.content.visible_chars == 1 and (.gui.content.meaningful | not)) and
    (.email.content.visible_chars == 1 and (.email.content.meaningful | not))
  )
' "$tmp/punctuation-body-result.json" >/dev/null

if PATH="$tmp:$PATH" BP_FIXTURE_BAD_EMAIL_LINK=1 BP_AUDIT_BIN="$tmp/fake-bp" \
  BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/bad-link-result.json"; then
  printf 'relative email link unexpectedly passed\n' >&2
  exit 1
fi

jq -e '
  .ok == false and .failed == 2 and
  all(.failures[]; .email.content.links_valid == false and .email.content.invalid_links == 1)
' "$tmp/bad-link-result.json" >/dev/null

if PATH="$tmp:$PATH" BP_FIXTURE_STRUCTURAL=1 BP_AUDIT_BIN="$tmp/fake-bp" \
  BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/structural-result.json"; then
  printf 'structurally invisible block content unexpectedly passed\n' >&2
  exit 1
fi

jq -e '
  .ok == false and .failed == 0 and
  .structure.papers_affected == 1 and
  .structure.violations == 1 and
  .structure.violation_counts.list_item_object_wrapper == 1
' "$tmp/structural-result.json" >/dev/null

if PATH="$tmp:$PATH" BP_FIXTURE_STALLED=1 BP_AUDIT_BIN="$tmp/fake-bp" \
  BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/stalled-result.json"; then
  printf 'failed/stalled email transfer unexpectedly passed\n' >&2
  exit 1
fi

jq -e '
  .ok == false and .failed == 2 and
  all(.failures[]; .email.status == 0 and .email.content.body_found == false)
' "$tmp/stalled-result.json" >/dev/null

# HTTP 422 on the GUI route with an otherwise-perfect body. The audit's status
# handling was proven real against incident history but had no checked-in test,
# so a refactor could have deleted it silently. Note the audit defends this with
# TWO redundant layers — the ok-gate requires gui_code == 200, AND the content
# check only runs when the status is 200 (so gui_content stays all-false
# otherwise). Both must be removed to turn this green; that redundancy is a
# feature, not duplication to tidy away.
if PATH="$tmp:$PATH" BP_FIXTURE_GUI_422=1 BP_AUDIT_BIN="$tmp/fake-bp" \
  BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/gui-422-result.json"; then
  printf 'HTTP 422 on the GUI route unexpectedly passed\n' >&2
  exit 1
fi

jq -e '
  .ok == false and .failed == 2 and
  all(.failures[];
    .gui.status == 422 and
    (.gui.content.body_found | not) and (.gui.content.meaningful | not)
  )
' "$tmp/gui-422-result.json" >/dev/null

if PATH="$tmp:$PATH" BP_FIXTURE_EMPTY=1 BP_AUDIT_BIN="$tmp/fake-bp" \
  BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/empty-result.json"; then
  printf 'empty paper inventory unexpectedly passed\n' >&2
  exit 1
fi

jq -e '.ok == false and .error == "paper inventory must be a non-empty documents array with string ids"' \
  "$tmp/empty-result.json" >/dev/null

# ── Narrow transport retry (dropped-DB-connection 500s) ───────────────────────
# Production measurement 2026-08-23: ~27% of requests answered HTTP 500 with
# the `"code":"internal_error"` envelope — per REQUEST (one BEAM losing
# individual DB connections), so one flake anywhere in 871 papers x 4 edges
# red the whole audit. The audit retries EXACTLY that shape up to 3 times.

# 1. A transient internal_error 500 (heals on the 3rd try) must PASS — on
#    every edge: GUI/email/source curls, the CLI reader, and the inventory.
mkdir "$tmp/counts-flaky"
PATH="$tmp:$PATH" BP_FIXTURE_FLAKY_500=1 BP_FIXTURE_CLI_FLAKY=1 \
  BP_FIXTURE_INVENTORY_FLAKY=1 BP_FIXTURE_COUNT_DIR="$tmp/counts-flaky" \
  BP_AUDIT_BIN="$tmp/fake-bp" BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/flaky-result.json" || {
  printf 'transient internal_error 500s were not retried to green\n' >&2
  exit 1
}
jq -e '.ok and .failed == 0 and all(.results[]; .gui.status == 200 and .cli.ok)' \
  "$tmp/flaky-result.json" >/dev/null

# 2. A PERSISTENT internal_error 500 must still FAIL — the retry gives up and
#    the last answer stands. An audit that retries forever has stopped looking.
if PATH="$tmp:$PATH" BP_FIXTURE_PERSISTENT_500=1 BP_AUDIT_BIN="$tmp/fake-bp" \
  BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/persistent-500-result.json"; then
  printf 'persistent internal_error 500s unexpectedly passed\n' >&2
  exit 1
fi
jq -e '.ok == false and .failed == 2 and all(.failures[]; .gui.status == 500)' \
  "$tmp/persistent-500-result.json" >/dev/null

# 3. NON-transport failures are never retried: the 422 fixture must hit each
#    GUI route exactly once. Retrying a 4xx would be the first step toward an
#    audit that launders real refusals as flakes.
mkdir "$tmp/counts-422"
if PATH="$tmp:$PATH" BP_FIXTURE_GUI_422=1 BP_FIXTURE_COUNT_DIR="$tmp/counts-422" \
  BP_AUDIT_BIN="$tmp/fake-bp" BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >/dev/null; then
  printf 'HTTP 422 on the GUI route unexpectedly passed (retry-count run)\n' >&2
  exit 1
fi
for count_file in "$tmp/counts-422"/https___fixture_invalid_papers_blocks_paper \
  "$tmp/counts-422"/https___fixture_invalid_papers_html_paper; do
  if [[ ! -f "$count_file" ]]; then
    printf 'retry-count fixture never saw the GUI fetch: %s\n' "$count_file" >&2
    exit 1
  fi
  if [[ "$(cat "$count_file")" != "1" ]]; then
    printf 'a 422 GUI response was retried (%s fetches) — retry must stay transport-narrow\n' \
      "$(cat "$count_file")" >&2
    exit 1
  fi
done

printf 'paper reader audit fixture: PASS\n'
