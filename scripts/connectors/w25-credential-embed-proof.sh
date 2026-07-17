#!/usr/bin/env bash
# w25-credential-embed-proof.sh — the Connectors Wave-25 credential config-embed
# proof (D213-D216). BLACK-BOX, hermetic, provisions NO real sandbox and opens NO
# real credential.
#
# D126 made the cloud MCP descriptors CREDENTIAL-LESS: the in-sandbox claude got a
# github/linear MCP server entry with NO token. Wave 25 closes that at the shim:
# the decoded `--mcp-config-b64` payload may carry a top-level `bpConnectorTicket`
# (the E-slice wire contract); for each `mcpServers` entry the shim POSTs
# `{"ticket":…}` to the bridge's EXISTING loopback `tool-headers/<provider>` route
# (D71 — provider in the PATH, ticket in the BODY) and merges the FINISHED
# `{"Authorization":"Bearer <v>"}` verbatim into that entry's headers. The shim
# never sees `credential_ref` and never re-derives a bearer. The credential-bearing
# config is delivered via `vercel sandbox copy` from a 0600 host tmpfile (D215 —
# content rides the API body; only the PATH is argv), never via the argv-b64 embed
# (which would provably leak the credential in base64 form to ps/logs).
#
# Same technique as w12-shim-confinement-proof.sh: `CLOUD_SANDBOX_VERCEL_BIN`
# points the REAL cloud-sandbox-runner.mjs at a generated FAKE `vercel` that
# records every invocation's argv (NUL-delimited) + env, snapshots the SOURCE
# content + mode of every `sandbox copy`, and echoes an id on `sandbox create`.
# PLUS a stub loopback bridge (node http.createServer on an ephemeral port,
# pointed at via CLOUD_SANDBOX_BRIDGE_URL) that serves a canned Authorization for
# the matching workspace ticket and the opaque 404 for anything else. No real
# Vercel, no real bridge, no GNU timeout (absent on darwin — the shim
# self-terminates against the fake).
#
# Assertions (charter D216, (a)-(g)):
#   (a) the credential is ABSENT from EVERY captured vercel argv + env — in RAW
#       form AND via decode-every-base64-token-then-grep-raw (the naive
#       0/1/2-pad phase-shift is PROVEN INEFFECTIVE — never used here). The
#       ticket is likewise absent from every vercel-child argv.
#   (b) the turn exec still carries EXACTLY one --env pair (ANTHROPIC_API_KEY).
#   (c) the copied config has headers.Authorization per provider and NO
#       bpConnectorTicket; the in-VM script keeps `--mcp-config
#       /tmp/bp-cloud-mcp.json --strict-mcp-config` but SKIPS the mcp
#       printf|base64 embed line; the copy source tmpfile is mode 0600.
#   (d) a cross-workspace ticket ⇒ stub 404 ⇒ nonzero shim exit + ZERO vercel
#       invocations (fail-closed BEFORE any sandbox dispatch).
#   (e) create→reuse freshness: the fetch fires on BOTH branches — two runs
#       against two DISTINCT stub credentials each deliver their OWN credential.
#   (f) the 0600 host tmpfile is ABSENT post-run (unlinked in finally).
#   (g) the refusal stderr is FIXED STRINGS only — no credential, ticket, or
#       response bytes (stderr tails reach ChatLive verbatim).
#   (+) ticket-less payloads stay BYTE-IDENTICAL to the pre-W25 argv-b64 embed
#       path: no copy, no fetch, the in-VM printf|base64 line intact.
#
# RED-FIRST: against the pre-W25 runner this proof FAILS at (c) — the
# credential-bearing config never rides a copy, the ticket rides the in-VM embed.
#
# See .claude/workflows/bp-connectors-charter.md (Wave 25, D213-D216) and the wave
# paper connectors-wave-25-2026-07-17. Sibling idioms: w12-shim-confinement-proof.sh,
# w14-session-sandbox-proof.sh.
#
# Usage:
#   scripts/connectors/w25-credential-embed-proof.sh --check   # lint the shim + print the plan, run NO subprocess
#   scripts/connectors/w25-credential-embed-proof.sh           # hermetic black-box run (fake vercel + stub bridge)
set -uo pipefail
export LC_ALL=C

SCRIPT_NAME="w25-credential-embed-proof.sh"
CHARTER=".claude/workflows/bp-connectors-charter.md"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/cloud-sandbox-runner.mjs"

WORKSPACE="w25-proof-ws"
FAKE_CREATE_ID="sb_fake_w25_credembed"
REUSE_ID="sb_reuse_target_w25"
ANTHROPIC_KEY_VAL="sk-test"
# The tickets: the stub bridge accepts EXACTLY TICKET_A; TICKET_B models a
# sandbox trying to fetch ANOTHER workspace's credential (opaque 404).
TICKET_A="tkt-w25-workspace-a-session"
TICKET_B="tkt-w25-workspace-b-session"
# The planted credentials the stub serves. Long, distinctive, greppable.
CRED_A="w25-secret-credential-alpha-must-never-leak"
CRED_1="w25-secret-credential-first-of-two"
CRED_2="w25-secret-credential-second-of-two"
# The shim's FIXED refusal string (must match cloud-sandbox-runner.mjs verbatim).
FIXED_REFUSAL="connector credential fetch refused — cloud turn aborted before any sandbox dispatch"
# The claude segment every leg passes after `--` (the D109 argv shape).
CLAUDE_ARGS=(--input-format stream-json --output-format stream-json --include-partial-messages --verbose --permission-mode plan)

CHECK_ONLY=0

usage() {
  cat <<EOF
$SCRIPT_NAME — Connectors Wave-25 credential config-embed proof (D213-D216).

  --check    node --check the shim + print the plan; runs NO shim subprocess and
             spawns NO vercel (real or fake) and NO stub bridge.
  --help     this text.

With no flag it runs the HERMETIC black-box proof: a generated fake \`vercel\`
records argv+env per call and snapshots every 'sandbox copy' source, a stub
loopback bridge serves canned tool-headers, and the REAL $SHIM is driven for the
(a)-(g) confinement assertions. NO real Vercel sandbox, NO real credential.

Charter: $CHARTER (Wave 25, D213-D216).
EOF
}

case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  "") CHECK_ONLY=0 ;;
  *)
    echo "ERROR: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

# ── Scratch tree + stub teardown (fires on any exit, incl. error / Ctrl-C). ────
WORK=""
STUB_PID=""
cleanup() {
  local rc=$?
  set +e
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  [ -n "$WORK" ] && rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

lint() {
  echo "==> lint: node --check $SHIM"
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: 'node' not found on PATH." >&2
    exit 1
  fi
  node --check "$SHIM" || { echo "ERROR: shim failed node --check" >&2; exit 1; }
  echo "    OK: shim lints."
}

print_plan() {
  cat <<EOF
$SCRIPT_NAME — PLAN

A full (non --check) run is hermetic — it provisions NO real sandbox:

  1. Generate a fake \`vercel\` that records each invocation's argv (NUL-delimited)
     + env, snapshots the SOURCE content + ls-mode of every 'sandbox copy', and
     echoes '$FAKE_CREATE_ID' on 'sandbox create'.

  2. Start a stub loopback bridge (node http.createServer, ephemeral port) that
     answers POST …/connect/tool-headers/<provider>: ticket '$TICKET_A' ⇒
     200 {"Authorization":"Bearer <cred-from-file>"}; anything else ⇒ the opaque
     404 {"error":"not_found"}.

  3. Drive the REAL shim (CLOUD_SANDBOX_BRIDGE_URL → the stub; snapshot path
     forced so there is no npm-install exec noise) for five legs:

     LEG 1  HAPPY (flag-less create): a ticket-bearing config ⇒ the finished
            Authorization is fetched host-side and delivered ONLY via
            'sandbox copy' of a 0600 tmpfile; assertions (a)(b)(c)(f).
     LEG 2  CROSS-WORKSPACE REFUSAL: ticket '$TICKET_B' ⇒ stub 404 ⇒ nonzero
            exit, ZERO vercel invocations, FIXED-STRING stderr; (d)(g).
     LEG 3  CREATE→REUSE FRESHNESS: a keep-mode create against '$CRED_1', then a
            '--sandbox-id $REUSE_ID' reuse against '$CRED_2' — each copy carries
            its OWN credential (the fetch lives in the per-turn path); (e).
     LEG 4  TICKET-LESS BYTE-IDENTITY: no bpConnectorTicket ⇒ no fetch, no copy,
            the pre-W25 in-VM printf|base64 embed line intact.

  4. Pin the W25 mechanism markers in the shim source (regression tripwires).

No GNU timeout is used; the shim self-terminates against the fake. Scratch tree
and the stub bridge are removed on exit.
EOF
}

# ── Generate the fake `vercel`: records argv+env, snapshots copy sources. ──────
make_fake_vercel() {
  local capdir="$1" path="$2"
  cat >"$path" <<FAKE
#!/usr/bin/env bash
# Fake \`vercel\` for the W25 credential config-embed proof. Records this
# invocation's argv (NUL-delimited) + env, snapshots 'sandbox copy' sources
# (content + ls-mode — the shim unlinks the tmpfile right after), then emulates
# just enough for the shim to proceed.
set -u
capdir="$capdir"
mkdir -p "\$capdir"
# Monotonic per-invocation index via an exclusive-create counter (calls are serial).
n=0
while ! ( set -o noclobber; : >"\$capdir/lock.\$n" ) 2>/dev/null; do
  n=\$((n + 1))
done
# argv: one NUL-terminated record per token (survives the multi-line -lc script).
: >"\$capdir/argv.\$n"
for a in "\$@"; do
  printf '%s\0' "\$a" >>"\$capdir/argv.\$n"
done
# env: one KEY=VALUE per line (values here are single-line test vars).
env >"\$capdir/env.\$n"
# Emulate + snapshot: create echoes an id; copy snapshots its SOURCE file.
is_sandbox=0; is_create=0; is_copy=0
for a in "\$@"; do
  [ "\$a" = "sandbox" ] && is_sandbox=1
  [ "\$a" = "create" ] && is_create=1
  [ "\$a" = "copy" ] && is_copy=1
done
if [ "\$is_sandbox" = 1 ] && [ "\$is_create" = 1 ]; then
  echo "$FAKE_CREATE_ID"
fi
if [ "\$is_sandbox" = 1 ] && [ "\$is_copy" = 1 ]; then
  # argv shape: sandbox copy <src> <dest> [--scope …] — snapshot the src NOW
  # (the shim unlinks it in a finally the moment this process exits).
  src=""
  prev=""
  for a in "\$@"; do
    if [ "\$prev" = "copy" ] && [ -z "\$src" ]; then
      src="\$a"
    fi
    prev="\$a"
  done
  if [ -n "\$src" ] && [ -f "\$src" ]; then
    cp "\$src" "\$capdir/copysrc.\$n"
    ls -l "\$src" | awk '{print \$1}' >"\$capdir/copymode.\$n"
  fi
fi
exit 0
FAKE
  chmod +x "$path"
}

# ── The stub loopback bridge (the D71 tool-headers route, canned). ─────────────
start_stub() {
  local stubdir="$WORK/stub"
  mkdir -p "$stubdir"
  PORT_FILE="$stubdir/port"
  HIT_LOG="$stubdir/hits.ndjson"
  CRED_FILE="$stubdir/cred"
  : >"$HIT_LOG"
  printf '%s' "$CRED_A" >"$CRED_FILE"

  cat >"$stubdir/stub-bridge.mjs" <<'STUB'
// Stub loopback bridge for the W25 proof: the EXISTING D71 route shape —
// provider in the PATH, ticket in the BODY. The matching workspace ticket gets
// a finished Authorization (credential read from CRED_FILE per request, so a
// leg can rotate it); everything else gets the opaque 404.
import { createServer } from "node:http";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";

const expectTicket = process.env.EXPECT_TICKET;
const credFile = process.env.CRED_FILE;
const hitLog = process.env.HIT_LOG;

const server = createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    const match = /\/connect\/tool-headers\/([a-z0-9_-]+)$/.exec(req.url || "");
    let ticket = null;
    try {
      ticket = JSON.parse(body).ticket;
    } catch {
      ticket = null;
    }
    appendFileSync(
      hitLog,
      `${JSON.stringify({ method: req.method, url: req.url, ticket })}\n`,
    );
    if (req.method === "POST" && match && ticket === expectTicket) {
      const cred = readFileSync(credFile, "utf8").trim();
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ Authorization: `Bearer ${cred}` }));
      return;
    }
    res.writeHead(404, { "content-type": "application/json" });
    res.end('{"error":"not_found"}');
  });
});
server.listen(0, "127.0.0.1", () => {
  writeFileSync(process.env.PORT_FILE, String(server.address().port));
});
STUB

  EXPECT_TICKET="$TICKET_A" CRED_FILE="$CRED_FILE" HIT_LOG="$HIT_LOG" PORT_FILE="$PORT_FILE" \
    node "$stubdir/stub-bridge.mjs" &
  STUB_PID=$!
  disown "$STUB_PID" # suppress job-control noise when cleanup kills it
  local i
  for i in $(seq 1 100); do
    [ -s "$PORT_FILE" ] && break
    sleep 0.05
  done
  [ -s "$PORT_FILE" ] || fail "stub bridge never wrote its port (waited ${i}×50ms)"
  STUB_PORT="$(cat "$PORT_FILE")"
  echo "    stub bridge up on 127.0.0.1:$STUB_PORT (accepts ticket '$TICKET_A')."
}

# ── argv predicates over NUL-delimited capture files (w12/w14 idioms). ─────────
read_argv() {
  local f="$1"
  CAP_TOKENS=()
  local tok
  while IFS= read -r -d '' tok; do
    CAP_TOKENS+=("$tok")
  done <"$f"
}

argv_has_all() {
  local f="$1"
  shift
  local t
  for t in "$@"; do
    grep -zxq -e "$t" "$f" || return 1
  done
  return 0
}

count_real_creates() {
  local capdir="$1" n=0 f
  for f in "$capdir"/argv.*; do
    [ -e "$f" ] || continue
    if argv_has_all "$f" sandbox create && ! grep -zxq -e '--help' "$f"; then
      n=$((n + 1))
    fi
  done
  echo "$n"
}

find_turn_capture() {
  local capdir="$1" f
  for f in "$capdir"/argv.*; do
    [ -e "$f" ] || continue
    grep -zxq -e '-lc' "$f" && {
      echo "$f"
      return 0
    }
  done
  return 1
}

# Echo the single copysrc snapshot in a capture dir (fails if zero or >1).
find_one_copysrc() {
  local capdir="$1" found="" f
  for f in "$capdir"/copysrc.*; do
    [ -e "$f" ] || continue
    [ -n "$found" ] && return 2
    found="$f"
  done
  [ -n "$found" ] || return 1
  echo "$found"
}

# ── Drive the REAL shim once. Sets globals CAP / OUT / ERR / TMP / RC. ─────────
# Args: <leg-label> <config-json> [pre-`--` shim flags...]
drive() {
  local label="$1" config="$2"
  shift 2
  local leg="$WORK/$label"
  CAP="$leg/cap"
  OUT="$leg/out"
  ERR="$leg/err"
  TMP="$leg/tmp"
  local fake="$leg/vercel"
  mkdir -p "$CAP" "$TMP"
  make_fake_vercel "$CAP" "$fake"

  local b64
  b64="$(printf '%s' "$config" | base64 | tr -d '\n')"
  local user_frame='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"say ok"}]}}'
  printf '%s\n' "$user_frame" |
    ANTHROPIC_API_KEY="$ANTHROPIC_KEY_VAL" \
      CLOUD_SANDBOX_VERCEL_BIN="$fake" \
      CLOUD_SANDBOX_SNAPSHOT="snap_fake_w25" \
      CLOUD_SANDBOX_BRIDGE_URL="http://127.0.0.1:$STUB_PORT/connectors" \
      TMPDIR="$TMP" \
      node "$SHIM" --workspace "$WORKSPACE" --mcp-config-b64 "$b64" "$@" -- "${CLAUDE_ARGS[@]}" \
      >"$OUT" 2>"$ERR"
  RC=$?
  echo "    ($label) shim exit=$RC, $(find "$CAP" -name 'argv.*' | wc -l | tr -d ' ') vercel invocation(s)."
}

# ── (a) the credential (and ticket) must be invisible to every vercel child. ───
# RAW grep over every argv + env capture, PLUS decode-EVERY-base64-plausible-token
# and grep the DECODED bytes — the naive 0/1/2-pad phase-shift grep is proven
# ineffective and is deliberately NOT used.
assert_confined() {
  local capdir="$1" cred="$2" ticket="$3"
  CAPDIR="$capdir" CRED="$cred" TICKET="$ticket" node -e '
    const { readdirSync, readFileSync } = require("node:fs");
    const dir = process.env.CAPDIR;
    const cred = process.env.CRED;
    const ticket = process.env.TICKET;
    const offenders = [];
    const files = readdirSync(dir).filter(
      (f) => f.startsWith("argv.") || f.startsWith("env."),
    );
    if (files.length === 0) {
      console.error("no argv/env captures to scan");
      process.exit(1);
    }
    for (const f of files) {
      const raw = readFileSync(`${dir}/${f}`, "latin1");
      if (raw.includes(cred)) offenders.push(`${f}: credential RAW`);
      if (ticket && f.startsWith("argv.") && raw.includes(ticket))
        offenders.push(`${f}: ticket RAW in argv`);
      // Decode EVERY base64-plausible token (std and url-safe alphabets) and
      // grep the decoded bytes for the raw credential.
      const tokens = raw.split(/[^A-Za-z0-9+/=_-]+/).filter((t) => t.length >= 8);
      for (const t of tokens) {
        const variants = [t, t.replace(/-/g, "+").replace(/_/g, "/")];
        for (const v of variants) {
          const decoded = Buffer.from(v, "base64").toString("latin1");
          if (decoded.includes(cred)) {
            offenders.push(`${f}: credential under base64 decode`);
            break;
          }
        }
      }
    }
    if (offenders.length > 0) {
      console.error(`credential/ticket visible to a vercel child: ${offenders.join(", ")}`);
      process.exit(1);
    }
  ' || fail "(a) the credential leaked into a vercel child argv/env (raw or base64)"
}

# ── (c) the copied config: finished Authorization in, ticket OUT. ──────────────
assert_copied_config() {
  local src="$1" cred="$2" provider="$3"
  CFG="$(cat "$src")" CRED="$cred" PROVIDER="$provider" node -e '
    const cfg = JSON.parse(process.env.CFG);
    const raw = JSON.stringify(cfg);
    if (raw.includes("bpConnectorTicket")) {
      console.error("bpConnectorTicket survived into the copied config");
      process.exit(1);
    }
    const entry = cfg.mcpServers?.[process.env.PROVIDER];
    if (!entry) {
      console.error(`no mcpServers.${process.env.PROVIDER} entry in the copied config`);
      process.exit(1);
    }
    const auth = entry.headers?.Authorization;
    if (auth !== `Bearer ${process.env.CRED}`) {
      console.error(`headers.Authorization is ${JSON.stringify(auth)}, expected the finished Bearer`);
      process.exit(1);
    }
  ' || fail "(c) copied config is wrong (ticket survived, or the finished Authorization is missing)"
}

run_proof() {
  WORK="$(mktemp -d)"
  start_stub

  local config_a="{\"bpConnectorTicket\":\"$TICKET_A\",\"mcpServers\":{\"github\":{\"type\":\"http\",\"url\":\"https://api.githubcopilot.com/mcp/\"}}}"
  local config_b="{\"bpConnectorTicket\":\"$TICKET_B\",\"mcpServers\":{\"github\":{\"type\":\"http\",\"url\":\"https://api.githubcopilot.com/mcp/\"}}}"
  local config_plain='{"mcpServers":{"github":{"type":"http","url":"https://api.githubcopilot.com/mcp/"}}}'

  # ── LEG 1: HAPPY PATH (flag-less create) ─────────────────────────────────────
  echo "==> LEG 1 (happy): ticket-bearing config ⇒ fetch + copy-transport ..."
  printf '%s' "$CRED_A" >"$CRED_FILE"
  drive leg1 "$config_a"

  # (c) exactly ONE 'sandbox copy', targeting <id>:/tmp/bp-cloud-mcp.json.
  local copysrc
  copysrc="$(find_one_copysrc "$CAP")" || fail "(c) no single 'sandbox copy' invocation captured — the credential-bearing config never rode the copy transport (rc=$?)"
  local copy_argv="${copysrc/copysrc./argv.}"
  argv_has_all "$copy_argv" sandbox copy "$FAKE_CREATE_ID:/tmp/bp-cloud-mcp.json" ||
    fail "(c) the copy does not target $FAKE_CREATE_ID:/tmp/bp-cloud-mcp.json"
  assert_copied_config "$copysrc" "$CRED_A" github
  echo "    PASS (c): one 'sandbox copy' → in-VM /tmp/bp-cloud-mcp.json; finished Authorization in, ticket stripped."

  # (c) the copy source tmpfile was 0600 at copy time.
  local copymode="${copysrc/copysrc./copymode.}"
  [ -e "$copymode" ] || fail "(c) fake vercel captured no copy-source mode"
  case "$(cat "$copymode")" in
    -rw-------*) : ;;
    *) fail "(c) copy-source tmpfile mode is '$(cat "$copymode")', expected 0600 (-rw-------)" ;;
  esac
  echo "    PASS (c): copy-source host tmpfile is mode 0600."

  # (c) the in-VM script keeps the mcp flags but SKIPS the mcp embed line.
  local turn_cap script="" i
  turn_cap="$(find_turn_capture "$CAP")" || fail "(c) no turn exec captured (no '-lc' token)"
  read_argv "$turn_cap"
  local env_pairs=()
  for ((i = 0; i < ${#CAP_TOKENS[@]}; i++)); do
    if [ "${CAP_TOKENS[$i]}" = "--env" ]; then
      env_pairs+=("${CAP_TOKENS[$((i + 1))]}")
    fi
    if [ "${CAP_TOKENS[$i]}" = "-lc" ]; then
      script="${CAP_TOKENS[$((i + 1))]}"
    fi
  done
  [ -n "$script" ] || fail "(c) no bash script captured after the '-lc' token"
  printf '%s' "$script" | grep -q -- "'--mcp-config' '/tmp/bp-cloud-mcp.json' '--strict-mcp-config'" ||
    fail "(c) in-VM claude exec lost --mcp-config /tmp/bp-cloud-mcp.json --strict-mcp-config"
  if printf '%s' "$script" | grep -q "base64 -d > '/tmp/bp-cloud-mcp.json'"; then
    fail "(c) in-VM script still embeds the mcp config via printf|base64 — the credential would ride argv"
  fi
  echo "    PASS (c): --mcp-config /tmp/bp-cloud-mcp.json --strict-mcp-config kept; in-VM mcp embed line SKIPPED."

  # (b) exactly one --env pair, and it is the ANTHROPIC key pin.
  echo "==> (b) exactly-one --env pin intact ..."
  [ "${#env_pairs[@]}" -eq 1 ] || fail "(b) expected EXACTLY one --env pair, got ${#env_pairs[@]}: ${env_pairs[*]:-<none>}"
  [ "${env_pairs[0]}" = "ANTHROPIC_API_KEY=$ANTHROPIC_KEY_VAL" ] ||
    fail "(b) --env pair is '${env_pairs[0]}', expected 'ANTHROPIC_API_KEY=$ANTHROPIC_KEY_VAL'"
  echo "    PASS: EXACTLY [ANTHROPIC_API_KEY=$ANTHROPIC_KEY_VAL]"

  # (a) the credential + ticket are invisible to every vercel child.
  echo "==> (a) credential absent from ALL vercel argv+env — raw AND base64-decoded ..."
  assert_confined "$CAP" "$CRED_A" "$TICKET_A"
  echo "    PASS: credential absent raw + under decode-every-base64-token; ticket absent from argv."

  # (f) the host tmpfile is gone (unlinked in finally).
  echo "==> (f) host tmpfile absent post-run ..."
  if find "$TMP" -name 'bp-cloud-mcp-*' | grep -q .; then
    fail "(f) a bp-cloud-mcp-* tmpfile survived the run — the finally unlink is broken"
  fi
  echo "    PASS: no bp-cloud-mcp-* tmpfile survives under the leg TMPDIR."

  # The stub really served the fetch (one hit, ticket A, provider in the path).
  grep -q "tool-headers/github" "$HIT_LOG" || fail "the shim never fetched tool-headers/github from the stub bridge"
  grep -q "$TICKET_A" "$HIT_LOG" || fail "the fetch did not carry the workspace ticket in the BODY"
  echo "    PASS: stub bridge served the D71 route (provider in path, ticket in body)."

  # ── LEG 2: CROSS-WORKSPACE REFUSAL ──────────────────────────────────────────
  echo "==> LEG 2 (refusal): cross-workspace ticket ⇒ stub 404 ⇒ fail-closed ..."
  drive leg2 "$config_b"
  [ "$RC" -ne 0 ] || fail "(d) cross-workspace refusal must exit NONZERO, got 0"
  if compgen -G "$CAP/argv.*" >/dev/null; then
    fail "(d) shim invoked vercel despite the credential-fetch refusal (found argv captures)"
  fi
  echo "    PASS (d): nonzero exit + ZERO vercel invocations."
  grep -qF "$FIXED_REFUSAL" "$ERR" ||
    fail "(g) refusal stderr lacks the FIXED refusal string"
  for leak in "$CRED_A" "$CRED_1" "$CRED_2" "$TICKET_B" not_found; do
    if grep -qF "$leak" "$ERR"; then
      fail "(g) refusal stderr leaked '$leak' — stderr tails reach ChatLive verbatim"
    fi
  done
  echo "    PASS (g): refusal stderr is the fixed string only (no credential/ticket/response bytes)."

  # ── LEG 3: CREATE→REUSE FRESHNESS (two distinct stub credentials) ───────────
  echo "==> LEG 3 (freshness): the fetch fires on BOTH create and reuse branches ..."
  printf '%s' "$CRED_1" >"$CRED_FILE"
  drive leg3-create "$config_a" --keep-sandbox
  local create_cap="$CAP"
  copysrc="$(find_one_copysrc "$create_cap")" || fail "(e) keep-mode create leg captured no single 'sandbox copy'"
  assert_copied_config "$copysrc" "$CRED_1" github
  [ "$(count_real_creates "$create_cap")" -eq 1 ] || fail "(e) keep-mode create leg expected exactly one real create"

  printf '%s' "$CRED_2" >"$CRED_FILE"
  drive leg3-reuse "$config_a" --sandbox-id "$REUSE_ID" --keep-sandbox
  local reuse_cap="$CAP"
  [ "$(count_real_creates "$reuse_cap")" -eq 0 ] || fail "(e) reuse leg ran a 'sandbox create' — --sandbox-id must skip create"
  copysrc="$(find_one_copysrc "$reuse_cap")" || fail "(e) reuse leg captured no single 'sandbox copy' — the fetch/copy must live in the per-turn path, NOT inside createSandbox()"
  copy_argv="${copysrc/copysrc./argv.}"
  argv_has_all "$copy_argv" sandbox copy "$REUSE_ID:/tmp/bp-cloud-mcp.json" ||
    fail "(e) reuse copy does not target $REUSE_ID:/tmp/bp-cloud-mcp.json"
  assert_copied_config "$copysrc" "$CRED_2" github
  assert_confined "$reuse_cap" "$CRED_2" "$TICKET_A"
  echo "    PASS (e): create leg delivered CRED_1, reuse leg delivered CRED_2 — per-turn freshness on both branches."

  # ── LEG 4: TICKET-LESS BYTE-IDENTITY ────────────────────────────────────────
  echo "==> LEG 4 (byte-identity): ticket-less payload stays on the pre-W25 embed path ..."
  local hits_before hits_after
  hits_before="$(wc -l <"$HIT_LOG" | tr -d ' ')"
  drive leg4 "$config_plain"
  hits_after="$(wc -l <"$HIT_LOG" | tr -d ' ')"
  [ "$hits_before" = "$hits_after" ] || fail "(byte-identity) a ticket-less payload still hit the stub bridge — the fetch must be ticket-gated"
  if compgen -G "$CAP/copysrc.*" >/dev/null; then
    fail "(byte-identity) a ticket-less payload rode the copy transport — must stay argv-b64 embed, byte-identical to today"
  fi
  turn_cap="$(find_turn_capture "$CAP")" || fail "(byte-identity) no turn exec captured"
  read_argv "$turn_cap"
  script=""
  for ((i = 0; i < ${#CAP_TOKENS[@]}; i++)); do
    if [ "${CAP_TOKENS[$i]}" = "-lc" ]; then
      script="${CAP_TOKENS[$((i + 1))]}"
    fi
  done
  printf '%s' "$script" | grep -q "base64 -d > '/tmp/bp-cloud-mcp.json'" ||
    fail "(byte-identity) ticket-less payload lost the in-VM printf|base64 mcp embed line"
  printf '%s' "$script" | grep -q -- "'--mcp-config' '/tmp/bp-cloud-mcp.json' '--strict-mcp-config'" ||
    fail "(byte-identity) ticket-less payload lost the --mcp-config flags"
  echo "    PASS: ticket-less ⇒ no fetch, no copy, in-VM embed line + mcp flags intact."

  # ── Regression tripwires: the W25 mechanism markers in the shim source. ──────
  echo "==> marker pins: the W25 mechanism is present in the shim source ..."
  grep -q 'bpConnectorTicket' "$SHIM" || fail "shim lost the bpConnectorTicket wire contract (W25)"
  grep -q 'tool-headers' "$SHIM" || fail "shim lost the D71 tool-headers fetch (W25)"
  grep -q '"copy"' "$SHIM" || fail "shim lost the sandbox-copy transport (D215)"
  grep -q 'CLOUD_SANDBOX_BRIDGE_URL' "$SHIM" || fail "shim lost the CLOUD_SANDBOX_BRIDGE_URL override"
  echo "    PASS: bpConnectorTicket / tool-headers / sandbox copy / bridge-url markers all present."
}

main() {
  echo "== Connectors Wave-25 credential config-embed proof =="
  echo "== charter: $CHARTER (Wave 25, D213-D216) =="
  lint

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    print_plan
    echo ""
    echo "--check OK: shim linted, plan printed, nothing spawned."
    return 0
  fi

  run_proof
  echo ""
  echo "== PROVEN: the finished Authorization is fetched host-side (D71 route) and"
  echo "==         delivered ONLY via sandbox-copy of a 0600 tmpfile — never argv/env;"
  echo "==         cross-workspace fetch fails closed with zero vercel calls;"
  echo "==         per-turn freshness holds on create AND reuse; ticket-less stays byte-identical. =="
  echo "== The LIVE in-sandbox MCP auth rides the human gate connectors-hg-live-isolated-cloud-turn. =="
}

main
