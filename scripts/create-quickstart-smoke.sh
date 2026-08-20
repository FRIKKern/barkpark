#!/usr/bin/env bash
# create-quickstart-smoke.sh — the committed proof that the AGENT-ONRAMPS.md
# CREATE quickstart actually works for a FRESH user (agent-onramps epic, wave 4,
# task ao-w4-create-quickstart-smoke). The copy-paste "one step" promise silently
# rots for a clean install: against a fresh clean-profile instance the docs'
# AUTH+CREATE arc used to fail (bp seed `of:[]` unmarshal bug + the publish wall's
# label_spine/unknown_tag on the task+paper blocks — charter D24). This harness
# boots an EPHEMERAL clean-profile server, runs the exact CREATE arc against it,
# and asserts every phase — so a re-break reds a gate instead of stranding a new
# user.
#
# WHY a bash harness (not a Go test): the arc only exists across real processes —
# a clean-profile phx.server minting a real admin token, a schema apply, a seed,
# a walled task+paper publish over HTTP. A unit test proves the seed PARSE
# (internal/cli/seed_cmd_test.go); only this proves the whole wiring boots and
# publishes on a genuinely empty database.
#
# UNLIKE cmux-smoke.sh / media-smoke.sh (manual-only, they write the LIVE
# guerrilla ledger), this touches NOTHING shared: it stands up its OWN throwaway
# Postgres database on a THROWAWAY port and drops both on exit. That is why it is
# CI-safe and gets its own workflow (.github/workflows/create-quickstart-smoke.yml,
# a postgres:15 service) — new ephemeral-local CI territory.
#
#   Invocation (from anywhere; it cd's to the repo root itself):
#     ./scripts/create-quickstart-smoke.sh
#   Requires: go, mix (Elixir), python3, curl, lsof on PATH, and a reachable
#   local Postgres accepting postgres/postgres @ localhost:5432 (dev.exs default;
#   the CI workflow supplies it). It BUILDS bp from THIS worktree (never a PATH
#   bp) so the seed fix under test is the one exercised.
#
# GATE (ao-w4-create-quickstart-smoke): `bash -n scripts/create-quickstart-smoke.sh`
# then `bash scripts/create-quickstart-smoke.sh` must end in a PASS summary with
# 0 failures.

set -euo pipefail

# Hand bp a CLOSED stdin, not the pipe a CI runner gives a `run:` step.
#
# bp guards against silently swallowing piped input: `--file <path>` with data on
# stdin is a hard error ("piped stdin is unused; pass --file - to consume it"),
# which is right. But the check is `stdin is not a char device` — and an EMPTY
# pipe satisfies that just as a pipe carrying data does. GitHub Actions hands each
# step a pipe, so `bp schema apply --file …` dies on the guard with no data in
# sight, and this harness reds on a false positive it exists to rule out.
#
# This script never pipes into bp (12 invocations, zero `--file -`), so /dev/null
# — a char device — is both honest and the shape a non-interactive harness should
# have had all along. The underlying CLI bug (an empty pipe must not read as
# "unused piped input"; it burns every user who runs bp from CI, cron, or a
# Makefile recipe) is filed separately as bp-cli-empty-pipe-false-positive.
exec 0</dev/null
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# --- resolve the toolchain or REFUSE (idp-interop.sh stance: no silent skip) -----
for tool in go mix python3 curl lsof; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "REFUSE: '$tool' not found on PATH — this harness boots a real ephemeral" >&2
    echo "        Barkpark and cannot run without it." >&2
    exit 1
  }
done

# --- pass/fail counters (media-smoke.sh / cmux-smoke.sh style) --------------------
pass=0
fail=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1"; fail=$((fail + 1)); }
die() { echo "FATAL: $1" >&2; exit 1; }

# jval "<json>" a.b.c → the dotted value ('' when any hop is absent/null)
jval() {
  printf '%s' "$1" | python3 -c '
import json,sys
try:
    v=json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v,dict) else None
print("" if v is None else v)
' "$2"
}

# =================================================================================
# 1. Ephemeral identity: a throwaway port (NEVER 4000 — concurrent worktrees hold
#    it), a uniquely-named dev database (dropped on exit — a developer's real
#    barkpark_dev is NEVER reused), and a known admin token injected into the
#    clean seed. The BARKPARK_PLUGINS whitelist keeps tasks+bulldocs (the arc
#    needs task-create + paper-publish) and drops onixedit so the ~40s codelist
#    boot-seed never runs.
# =================================================================================
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
[ "$PORT" != "4000" ] || die "refusing to run on port 4000 (the shared dev port)."
EPHEMERAL_DB="bp_qs_smoke_$$_$(python3 -c 'import random;print(random.randint(1000,9999))')"
ADMIN_TOKEN="bp_admin_$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
WORK="$(mktemp -d)"
SERVER_LOG="$WORK/server.log"
BP_BIN="$WORK/bp"
API_URL="http://127.0.0.1:$PORT"

echo "=== CREATE-quickstart smoke ==="
echo "  port=$PORT  db=$EPHEMERAL_DB  root=$REPO_ROOT"

# The boot/DB env every mix invocation below shares. PHX_SERVER is added ONLY for
# the background server (so the ecto/seed mix runs don't bind the port).
export MIX_ENV=dev
# CC: the golden-rule clang override matters on macOS (bare `cc` is a Claude
# wrapper). Honor a caller-set CC (the CI job sets it); otherwise default to
# /usr/bin/clang, which is what the local gate uses.
export CC="${CC:-/usr/bin/clang}"
export BARKPARK_DEV_DATABASE="$EPHEMERAL_DB"
export BARKPARK_SEED_PROFILE=clean
export BARKPARK_SEED_ADMIN_TOKEN="$ADMIN_TOKEN"
export BARKPARK_PLUGINS="tasks,bulldocs"
export PORT

SERVER_PID=""
cleanup() {
  local rc=$?
  set +e
  # Kill only OUR server: the recorded launcher PID plus whatever still binds our
  # throwaway port (mix → beam is a small tree; the port is the unambiguous key).
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  local pids
  pids="$(lsof -ti "tcp:$PORT" 2>/dev/null)"
  [ -n "$pids" ] && kill $pids 2>/dev/null
  sleep 1
  pids="$(lsof -ti "tcp:$PORT" 2>/dev/null)"
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null
  # Drop the ephemeral database (server is down, so no connection blocks it).
  ( cd "$REPO_ROOT/api" && MIX_ENV=dev BARKPARK_DEV_DATABASE="$EPHEMERAL_DB" \
      mix ecto.drop --force --quiet >/dev/null 2>&1 )
  rm -rf "$WORK"
  return $rc
}
trap cleanup EXIT

# =================================================================================
# 2. Build bp from THIS worktree — the seed fix under test must be the one run
#    (a PATH bp would be the OLD, unfixed binary).
# =================================================================================
echo ""
echo "--- build bp from source (the fixed binary under test) ---"
if go build -o "$BP_BIN" ./cmd/barkpark >"$WORK/build.log" 2>&1; then
  ok "go build ./cmd/barkpark -> $BP_BIN"
else
  cat "$WORK/build.log" >&2
  die "go build failed — cannot exercise the fixed seed."
fi
BP="$BP_BIN"

# =================================================================================
# 3. Boot the ephemeral clean-profile server: create + migrate the throwaway DB,
#    run the clean seed (mints the admin token from BARKPARK_SEED_ADMIN_TOKEN),
#    then start phx.server on the throwaway port and health-poll /api/schemas.
# =================================================================================
echo ""
echo "--- boot ephemeral clean-profile instance ---"
cd "$REPO_ROOT/api"
mix deps.get >"$WORK/deps.log" 2>&1 || { cat "$WORK/deps.log" >&2; die "mix deps.get failed."; }
mix compile >"$WORK/compile.log" 2>&1 || { cat "$WORK/compile.log" >&2; die "mix compile failed."; }
mix ecto.create --quiet >"$WORK/ecto.log" 2>&1 || { cat "$WORK/ecto.log" >&2; die "mix ecto.create failed (is Postgres reachable @ localhost:5432 postgres/postgres?)."; }
mix ecto.migrate --quiet >>"$WORK/ecto.log" 2>&1 || { cat "$WORK/ecto.log" >&2; die "mix ecto.migrate failed."; }
mix run priv/repo/seeds.exs >"$WORK/seed.log" 2>&1 || { cat "$WORK/seed.log" >&2; die "clean seed failed."; }
ok "created + migrated + clean-seeded $EPHEMERAL_DB"

PHX_SERVER=true mix phx.server >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
cd "$REPO_ROOT"

# Health-poll: /api/schemas returns 200 once the endpoint is up.
booted=0
for _ in $(seq 1 90); do
  if curl -fsS "$API_URL/api/schemas" >/dev/null 2>&1; then booted=1; break; fi
  # Fail fast if the server process died during boot.
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$SERVER_LOG" >&2
    die "phx.server exited during boot."
  fi
  sleep 1
done
if [ "$booted" = "1" ]; then
  ok "phx.server up — GET /api/schemas 200 on $API_URL"
else
  cat "$SERVER_LOG" >&2
  die "server never became healthy on $API_URL/api/schemas."
fi

# =================================================================================
# 4. Point bp at the ephemeral server via the environment layer (no config file
#    written — env sits above ~/.config/barkpark, exactly the AUTH doc's Connect
#    path). Then run the CREATE arc and assert every phase.
# =================================================================================
export BARKPARK_API_URL="$API_URL"
export BARKPARK_API_TOKEN="$ADMIN_TOKEN"
unset BARKPARK_SERVER 2>/dev/null || true

echo ""
echo "--- CREATE arc: capabilities -> schema -> seed -> tags -> task -> paper ---"

# CAPABILITIES — the whole surface in one call.
CAPS="$("$BP" capabilities -o json 2>/dev/null)"
[ -n "$CAPS" ] && printf '%s' "$CAPS" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && ok "bp capabilities -o json returns a parseable manifest" \
  || bad "bp capabilities did not return valid JSON"

# SCHEMA APPLY — a minimal two-field type, upserted as-is.
cat > "$WORK/note.schema.json" <<'JSON'
{"name":"note","title":"Note","fields":[
  {"name":"title","title":"Title","type":"string"},
  {"name":"body","title":"Body","type":"text"}
]}
JSON
if "$BP" schema apply --file "$WORK/note.schema.json" >"$WORK/schema.log" 2>&1; then
  ok "bp schema apply --file (note type upserted)"
else
  cat "$WORK/schema.log" >&2
  bad "bp schema apply failed"
fi

# SEED — the fixed generator fabricates a schema-valid draft. This is the seed
# `of:[]` fix exercised end-to-end (the parse of EVERY registered schema must
# succeed before a single doc is written).
SEED_OUT="$("$BP" seed note --count 1 -o json 2>"$WORK/seed_cmd.err")"
SEED_ID="$(printf '%s' "$SEED_OUT" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print((d.get("ids") or ["seed-note-1"])[0])' 2>/dev/null || echo seed-note-1)"
if [ "$(jval "$SEED_OUT" ok)" = "True" ]; then
  ok "bp seed note --count 1 -> ok (seed of:[] fix holds; id=$SEED_ID)"
else
  cat "$WORK/seed_cmd.err" >&2
  echo "  seed stdout: $SEED_OUT" >&2
  bad "bp seed note failed"
fi
# Prove the seeded doc PERSISTED and round-trips through a read: publish one seed
# (same deterministic id) and confirm it on the default published perspective.
# (The doc's `--perspective raw` draft view depends on CLI perspective-forwarding,
# a separate concern — this persistence check is perspective-independent.)
"$BP" seed note --count 1 --publish >"$WORK/seedpub.log" 2>&1 || true
if "$BP" doc ls note -o json >"$WORK/docls.json" 2>"$WORK/docls.err" \
   && [ "$(jval "$(cat "$WORK/docls.json")" count)" != "0" ] \
   && [ -n "$(jval "$(cat "$WORK/docls.json")" count)" ]; then
  ok "seeded note round-trips: bp seed note --publish then bp doc ls note shows it (count $(jval "$(cat "$WORK/docls.json")" count))"
else
  cat "$WORK/seedpub.log" "$WORK/docls.err" >&2 2>/dev/null
  echo "  doc ls: $(head -c 400 "$WORK/docls.json" 2>/dev/null)" >&2
  bad "seeded note did not round-trip (publish + bp doc ls note)"
fi

# TAG REGISTRATION — a fresh instance registers NO tags; the walled task+paper
# publishes below 422 unknown_tag without these. Registering a tag = publishing a
# type:tag doc whose id is the tag string (tag docs are not walled).
tag_ok=1
for tag in docs search; do
  "$BP" doc create tag --yes --set _id="$tag" --set title="${tag}" >"$WORK/tag_${tag}.log" 2>&1 || tag_ok=0
  "$BP" doc publish tag "$tag" --yes >>"$WORK/tag_${tag}.log" 2>&1 || tag_ok=0
done
if [ "$tag_ok" = "1" ] && "$BP" doc ls tag -o json >"$WORK/tagls.json" 2>/dev/null \
   && grep -q '"docs"' "$WORK/tagls.json" && grep -q '"search"' "$WORK/tagls.json"; then
  ok "registered type:tag docs docs+search (publish wall prerequisite)"
else
  cat "$WORK"/tag_*.log >&2 2>/dev/null
  bad "tag registration failed — walled publishes below would 422 unknown_tag"
fi

# TASK PUBLISH — the walled task needs a description (>=20 chars) + registered
# weighted tags with distinct strengths. A missing description would 422
# label_spine; an unregistered tag would 422 unknown_tag.
if "$BP" task create "Draft the launch note" --publish \
     --set 'priority:=1' \
     --set description="Write and publish the product launch note as a first agent-authored task." \
     --set 'tags:=[{"tag":"docs","strength":80,"rationale":"launch-note authoring is documentation work"},{"tag":"search","strength":40,"rationale":"the note should be findable via FTS once published"}]' \
     --set 'acceptance_criteria:=[{"criterion":"note published","met":false,"evidence":""}]' \
     >"$WORK/task.log" 2>&1; then
  ok "bp task create --publish cleared the wall (description + registered tags)"
else
  cat "$WORK/task.log" >&2
  bad "bp task create --publish failed (label_spine / unknown_tag?)"
fi
"$BP" task ready >/dev/null 2>&1 && ok "bp task ready lists work" || bad "bp task ready failed"

# PAPER PUBLISH — the ingest payload carries a description + registered weighted
# tags at the file's top level; bp bulldocs publish --file forwards them into the
# ingest params the wall reads.
cat > "$WORK/paper.json" <<'JSON'
{"slug":"hello",
 "description":"My first Barkpark paper, authored end-to-end by an agent.",
 "tags":[{"tag":"docs","strength":80,"rationale":"a hello-world paper is documentation content"},
         {"tag":"search","strength":40,"rationale":"the paper should surface in full-text search"}],
 "blocks":[
  {"id":"t1","type":"heading","level":1,"text":"Hello"},
  {"id":"p1","type":"paragraph","content":[{"type":"text","value":"My first paper, from an agent."}]}
]}
JSON
if "$BP" bulldocs publish hello --file "$WORK/paper.json" >"$WORK/paper.log" 2>&1; then
  ok "bp bulldocs publish --file cleared the wall (forwarded tags + description)"
else
  cat "$WORK/paper.log" >&2
  bad "bp bulldocs publish failed (label_spine / unknown_tag?)"
fi
if "$BP" paper view hello >"$WORK/paperview.log" 2>&1 && grep -qi 'my first paper' "$WORK/paperview.log"; then
  ok "bp paper view hello renders the published paper"
else
  cat "$WORK/paperview.log" >&2
  bad "bp paper view hello did not render the paper"
fi

# =================================================================================
echo ""
echo "=== CREATE-quickstart smoke: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
