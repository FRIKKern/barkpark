#!/usr/bin/env bash
# Re-seed drifted scaffy commands into the served catalog.
#
# WHY THIS IS A FILE AND NOT INLINE WORKFLOW SHELL. This logic lived inside
# .github/workflows/scaffy-catalog-drift.yml and had executed 0 times in the
# workflow's first 12 runs: every red took the credential guard above it and
# every green skipped the step. ~60 lines of unexecuted shell were one repo
# secret away from becoming an unattended cron writer against production
# content, and "first execution = first evidence" is not a plan. Inline
# workflow shell cannot be exercised without a real run; a file can, so
# repair-selftest.sh drives this script against a local fixture on EVERY run
# of the gate. Keep the logic here — moving it back inline re-creates the
# untestable shape.
#
# CONTRACT (env in, exit code out):
#   SERVER              base URL, no trailing slash, e.g. https://guerrilla.barkpark.cloud
#   BARKPARK_SEED_TOKEN bearer token with permissions ["write"]
#   DRIFTED_IDS_FILE    newline-separated command ids to re-seed (blank lines ignored)
#   PAYLOAD_DIR         directory of <id>.json payloads from `go run ./scaffy/seed`
#   WORK_DIR            scratch directory for request/response bodies
#
#   exit 0  every drifted id accepted by the server
#   exit 1  a payload was missing, or a mutation was refused
#   exit 2  usage error — a required variable is unset or a path does not exist
#
# WHAT IT DOES NOT DO. It does not decide whether repair is authorized (the
# workflow gates that before calling), and it does not re-run the audit. The
# repair only counts once `seed --check` comes back green, and that verdict
# stays with the caller so this script has exactly one job.
#
# E3 unknown_tag WALL. /v1/data/mutate refuses a document carrying a tag that
# has no registered tag doc (422 + unknown_tag). On that specific refusal this
# script registers the payload's tag docs and retries the command ONCE — see
# scaffy/seed/README.md §unknown_tag. Any other non-2xx is fatal.

set -uo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

usage() {
  echo "::error::repair.sh: $*" >&2
  exit 2
}

[ -n "${SERVER:-}" ] || usage "SERVER is unset"
[ -n "${BARKPARK_SEED_TOKEN:-}" ] || usage "BARKPARK_SEED_TOKEN is unset"
[ -n "${DRIFTED_IDS_FILE:-}" ] || usage "DRIFTED_IDS_FILE is unset"
[ -n "${PAYLOAD_DIR:-}" ] || usage "PAYLOAD_DIR is unset"
[ -n "${WORK_DIR:-}" ] || usage "WORK_DIR is unset"
[ -f "$DRIFTED_IDS_FILE" ] || usage "DRIFTED_IDS_FILE does not exist: $DRIFTED_IDS_FILE"
[ -d "$PAYLOAD_DIR" ] || usage "PAYLOAD_DIR does not exist: $PAYLOAD_DIR"
mkdir -p "$WORK_DIR" || usage "cannot create WORK_DIR: $WORK_DIR"

# REFUSE AN EMPTY RUN. A repair that re-seeds nothing and reports success is
# the "gate satisfiable by emptiness" shape: the caller only invokes this on a
# DRIFT verdict, so an empty id list means the handoff between the audit and
# this script lost its payload. That is a defect, not a clean run.
if ! grep -q '[^[:space:]]' "$DRIFTED_IDS_FILE"; then
  fail "no drifted ids in $DRIFTED_IDS_FILE — repair was invoked on a DRIFT verdict with an empty id list; the audit handoff is broken. Refusing to report success over zero work."
fi

# post <body-file>: response body -> $WORK_DIR/resp.json, prints the HTTP
# status code (empty on transport failure).
post() {
  curl -sS -o "$WORK_DIR/resp.json" -w '%{http_code}' \
    -X POST "$SERVER/v1/data/mutate/production" \
    -H "Authorization: Bearer $BARKPARK_SEED_TOKEN" \
    -H "Content-Type: application/json" \
    --data @"$1"
}

seeded=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  payload="$PAYLOAD_DIR/$id.json"
  [ -f "$payload" ] || fail "drifted id '$id' has no derived payload at $payload — cannot re-seed it."

  # ONE atomic batch per id: createOrReplace + publish together.
  jq --arg id "$id" \
    '{mutations: [{createOrReplace: (. + {_type: "command"})}, {publish: {id: $id, type: "command"}}]}' \
    "$payload" > "$WORK_DIR/body.json" || fail "could not build the mutation body for '$id'."

  http="$(post "$WORK_DIR/body.json")" || true

  if [ "$http" = "422" ] && grep -q 'unknown_tag' "$WORK_DIR/resp.json"; then
    echo "unknown_tag on $id — registering its tag docs, then one retry (E3 wall)"
    for tag in $(jq -r '.tags[].tag' "$payload"); do
      jq -n --arg t "$tag" \
        '{mutations: [{createOrReplace: {_id: $t, _type: "tag", title: $t, description: "Tag used by the scaffy command catalog; registered by the scaffy-catalog-drift repair arm."}}, {publish: {id: $t, type: "tag"}}]}' \
        > "$WORK_DIR/tag-body.json" || fail "could not build the tag body for '$tag'."
      thttp="$(post "$WORK_DIR/tag-body.json")" || true
      case "$thttp" in
        2??) echo "registered tag doc '$tag' (HTTP $thttp)" ;;
        *) fail "tag-doc registration for '$tag' failed (HTTP ${thttp:-transport-error}): $(cat "$WORK_DIR/resp.json" 2>/dev/null)" ;;
      esac
    done
    http="$(post "$WORK_DIR/body.json")" || true
  fi

  case "$http" in
    2??) echo "re-seeded $id (HTTP $http)"; seeded=$((seeded + 1)) ;;
    *) fail "re-seed of '$id' failed (HTTP ${http:-transport-error}): $(cat "$WORK_DIR/resp.json" 2>/dev/null)" ;;
  esac
done < "$DRIFTED_IDS_FILE"

# A loop that read no ids would fall through here reporting success over zero
# work. The blank-file guard above catches the empty-file case; this catches a
# file of only-whitespace lines that survived it.
[ "$seeded" -gt 0 ] || fail "re-seeded 0 commands — refusing to report success over zero work."

echo "repair.sh: re-seeded $seeded command(s) into $SERVER"
