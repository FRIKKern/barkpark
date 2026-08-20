#!/usr/bin/env node
// cloud-sandbox-runner.mjs — the Cloud execution-profile shim (Connectors epic,
// Wave 11 / P1 crux; charter D108/D111/D112).
//
// The Elixir Studio-chat Session spawns THIS as the turn subprocess when
// `:execution_profile` is `:cloud` (see claude_chat.ex `command/2` →
// `{sandbox_runner(), cloud_build_args/2}`). It rides the SAME
// `{exe,args,env,cwd} → NDJSON` contract as the host `claude` CLI: stdin carries
// the stream-json user turn, stdout carries the stream-json result verbatim, exit
// code is claude's. The DIFFERENCE is WHERE claude runs: inside an isolated
// Vercel Sandbox (Firecracker microVM) with NO host access, instead of on the host.
//
// Invocation (the shim's OWN argv, produced by cloud_build_args/2):
//
//     cloud-sandbox-runner --workspace <workspace_id> [--mcp-config-b64 <b64>] -- <claude args...>
//
// Everything after `--` is the claude command line to run INSIDE the sandbox
// (the D109 argv: --input-format/--output-format stream-json, --include-partial-
// messages, --verbose, --permission-mode <mode>; never a bypass flag, never a
// HOST mcp path). The optional `--mcp-config-b64` (D127) carries the workspace's
// connector-scoped `{"mcpServers":…}` as base64: the shim decodes it to an in-VM
// /tmp file and appends `--mcp-config <file> --strict-mcp-config` to the claude
// exec — knob 3's tools reach the locked-down turn, host built-ins stay denied.
// When the payload carries a top-level `bpConnectorTicket` (Wave 25, D213-D216),
// the shim first fetches each entry's FINISHED auth headers from the bridge's
// loopback tool-headers route and delivers the credential-bearing config via
// `vercel sandbox copy` instead of the argv embed — see resolveMcpConfig().
//
// Flow (D108 — interactive stdin into a sandbox is IMPOSSIBLE, so this is a
// one-shot turn whose first user frame the shim buffers from its OWN local stdin):
//
//   1. Buffer the FIRST complete `{"type":"user",…}` frame from stdin.
//   2. Acquire a concurrency slot (env-clamped), then `vercel sandbox create`
//      with a MANDATORY `--timeout`, `--scope guerrilla` (Pro team — the default
//      Hobby scope's quota overrun PAUSES creation 30 days), tags
//      `purpose=cloud-turn` + `workspace=<id>` (reaper-sweepable), and the D5/D24
//      isolation shape (`--network-policy deny-all --allowed-domain
//      api.anthropic.com`). Snapshot via `$CLOUD_SANDBOX_SNAPSHOT` or a fallback
//      plain node24 + one-time `npm i -g @anthropic-ai/claude-code`.
//   3. Inject the buffered frame base64-embedded to `/tmp/turn.jsonl` inside the
//      sandbox (base64 dodges heredoc/quoting hazards).
//   4. One-shot `claude <claude args> < /tmp/turn.jsonl` with an ISOLATED HOME +
//      clean cwd (D112 — a dirty HOME/cwd leaks SessionStart hook frames into the
//      customer NDJSON). ANTHROPIC_API_KEY is injected from the SHIM's OWN env
//      only (D110 — never Barkpark.Secrets, never the connector seal). Stream
//      stdout NDJSON verbatim; exit with claude's code.
//   5. Teardown (D111 — an Elixir Port has NO OS relationship to a remote microVM;
//      nothing tears it down for free): the SIGTERM/SIGINT/exit traps and the
//      post-turn `finally` tear the sandbox down, VERB by mode (D137) — flag-less
//      `vercel sandbox remove` (disposable one-shot; stopped sandboxes accrue
//      snapshot storage) vs `--keep-sandbox` `vercel sandbox stop` (auto-snapshots
//      so the next turn's exec auto-resumes /tmp — session continuity). `--timeout`
//      is the guaranteed backstop, per-turn under stop-after-turn (D138).
//
// SESSION LIFECYCLE (D137/D138 — a multi-turn Barkpark Chat Session's `:cloud`
// turns): turn 1 CREATES in `--keep-sandbox` mode and emits a `bp_sandbox` sideband
// frame with the new id (the Recorder persists it as the session binding); turn N
// passes `--sandbox-id <id> --keep-sandbox` to REUSE that sandbox (skip create,
// exec straight in — it auto-resumes). Continuity lives in the SESSION binding +
// the sandbox filesystem, NOT an interactive subprocess (impossible — D108).
//
// Mid-turn control frames (interrupt/set_permission_mode/control_response) are
// logged to stderr and DROPPED — one turn per cloud session this increment
// (interactive multi-turn needs a PTY: named follow-on).
//
// Dependency-free: only Node built-ins + the `vercel` CLI (NOT the SDK this
// increment — the CLI is what D10/D23 proved under frikk's auth). No live sandbox
// is created by importing this file; creation happens only on a real turn.

import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, writeFileSync, readFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

// ── Config (env, all overridable; safe defaults) ──────────────────────────────
const VERCEL_BIN = process.env.CLOUD_SANDBOX_VERCEL_BIN || "vercel";
const SCOPE = process.env.CLOUD_SANDBOX_SCOPE || "guerrilla";
const SNAPSHOT = process.env.CLOUD_SANDBOX_SNAPSHOT || ""; // empty ⇒ fallback boot+install
const RUNTIME = process.env.CLOUD_SANDBOX_RUNTIME || "node24";
const TIMEOUT = process.env.CLOUD_SANDBOX_TIMEOUT || "10m"; // MANDATORY create backstop
const ALLOWED_DOMAIN = process.env.CLOUD_SANDBOX_ALLOWED_DOMAIN || "api.anthropic.com";
const NETWORK_POLICY = process.env.CLOUD_SANDBOX_NETWORK_POLICY || "deny-all";
// ── Pinned claude CLI version (D176/D180) ─────────────────────────────────────
//
// The sandbox npm-installs `claude` FRESH on every fallback boot (and bakes it into
// the production snapshot), so the RUNNING version is not guaranteed — yet knob-5's
// unattended permission semantics were probed against a SPECIFIC version
// (cloud_policy.ex:57). We pin that version at BOTH ends: (1) version-suffix the npm
// install so provisioning installs exactly it, and (2) probe + compare the actual
// in-sandbox version at the END of createSandbox so a drift (a stale snapshot, a
// registry-served newer build) surfaces LOUDLY instead of silently invalidating the
// observed semantics. The pin lives in `cloud-claude-pinned-version.txt` NEXT TO
// this shim — a SEPARATE file from `scripts/claude-pinned-version.txt` (the
// self-hosted HOST-CLI pin: different surface, different value, different proof lane).
function readPinnedClaudeVersion() {
  try {
    const v = readFileSync(join(HERE, "cloud-claude-pinned-version.txt"), "utf8").trim();
    return v || null;
  } catch {
    return null; // absent/unreadable ⇒ unpinned (install unversioned, skip the assert)
  }
}
const PINNED_CLAUDE_VERSION = process.env.CLOUD_SANDBOX_CLAUDE_VERSION || readPinnedClaudeVersion();
// A drift is a WARNING by default (the version is "observed, not contractual" —
// cloud_policy.ex:57, so a benign patch bump must not abort live turns); set
// CLOUD_SANDBOX_CLAUDE_VERSION_STRICT=1 to make it a HARD FAIL (createSandbox throws,
// the turn never dispatches) where the operator wants version drift to fail closed.
const VERSION_STRICT = /^(1|true|yes)$/i.test(process.env.CLOUD_SANDBOX_CLAUDE_VERSION_STRICT || "");
// The npm package spec the fallback boot installs. Pinned to the exact version when
// one is configured (`@anthropic-ai/claude-code@<pin>`), so the install itself is
// reproducible; an explicit CLOUD_SANDBOX_CLAUDE_INSTALL overrides the whole spec.
const CLAUDE_INSTALL =
  process.env.CLOUD_SANDBOX_CLAUDE_INSTALL ||
  (PINNED_CLAUDE_VERSION
    ? `@anthropic-ai/claude-code@${PINNED_CLAUDE_VERSION}`
    : "@anthropic-ai/claude-code");
// Snapshot-retention expiry for keep-mode stop-snapshots (D138). Only ever passed
// when the pinned vercel CLI advertises `--snapshot-expiration` (probed, not
// guessed — see snapshotRetentionFlags()); otherwise the accrual is documented and
// swept by the backlogged reaper (connectors-cloud-sandbox-reaper).
const SNAPSHOT_EXPIRATION = process.env.CLOUD_SANDBOX_SNAPSHOT_EXPIRATION || "30d";
// Env-clamped concurrency (D111 item 6) — kept well under the Hobby 10-concurrent
// ceiling; the Pro `guerrilla` scope is higher but the clamp is a safety valve.
const MAX_CONCURRENCY = clampInt(process.env.CLOUD_SANDBOX_MAX_CONCURRENCY, 6, 1, 50);
const SLOT_WAIT_MS = clampInt(process.env.CLOUD_SANDBOX_SLOT_WAIT_MS, 120_000, 0, 600_000);
// In-sandbox isolation paths (D112) — never an operator checkout.
const SANDBOX_HOME = process.env.CLOUD_SANDBOX_HOME || "/tmp/bp-cloud-home";
const SANDBOX_CWD = process.env.CLOUD_SANDBOX_CWD || "/tmp/bp-cloud-cwd";
const TURN_FILE = "/tmp/turn.jsonl";
// The in-VM MCP config file the shim materializes from `--mcp-config-b64` (D127)
// and points claude at with `--mcp-config … --strict-mcp-config`. Never a host
// path — a host-written `--mcp-config` path hard-fails in-sandbox (D109).
const MCP_CONFIG_FILE = "/tmp/bp-cloud-mcp.json";
// ── The connector-credential fetch (Wave 25, D213-D216) ───────────────────────
//
// D126 made the MCP descriptors CREDENTIAL-LESS; W25 finishes them HOST-SIDE:
// when the decoded `--mcp-config-b64` payload carries a top-level
// `bpConnectorTicket` (the Elixir wire contract — exact key, never renamed), the
// shim POSTs `{"ticket":…}` per `mcpServers` entry to the bridge's EXISTING D71
// loopback route (`…/connect/tool-headers/<provider>` — provider in the PATH,
// ticket in the BODY) and merges the FINISHED header object verbatim into that
// entry's `headers`. The shim NEVER sees `credential_ref` and never re-derives a
// bearer — `bearerFromCredentialRef` (connectors/src/http/connect.ts) stays the
// sole W9 dual-shape owner. Any fetch failure/refusal aborts the turn BEFORE any
// vercel invocation with the FIXED string below: stderr tails broadcast verbatim
// to ChatLive, so no response/config/credential bytes may ride Error.message.
const BRIDGE_URL = process.env.CLOUD_SANDBOX_BRIDGE_URL || "http://127.0.0.1:4020/connectors";
const ERR_CREDENTIAL_FETCH =
  "connector credential fetch refused — cloud turn aborted before any sandbox dispatch";

function clampInt(raw, dflt, lo, hi) {
  const n = Number.parseInt(raw ?? "", 10);
  if (!Number.isFinite(n)) return dflt;
  return Math.min(hi, Math.max(lo, n));
}

// ── Explicit env allowlist for the LOCAL `vercel` CLI child (D121) ─────────────
//
// The shim is spawned by the Elixir Port and inherits its FULL env — which
// includes the minted per-session `BARKPARK_API_TOKEN` and the operator's
// `ANTHROPIC_API_KEY`. A full ambient inherit would leak BOTH into the local
// `vercel` process (capture-proven pre-fix: a planted HOST_SECRET and the minted
// BARKPARK_API_TOKEN appeared verbatim in the vercel child's env). `vercel` needs
// only its OWN auth env — `VERCEL_AUTH_TOKEN`/`VERCEL_OIDC_TOKEN` and the org/
// project ids (all `VERCEL_*`-prefixed) — plus HOME/PATH/TMPDIR to run. So every
// local `vercel` spawn gets an EXPLICIT allowlist and nothing else.
//
// `ANTHROPIC_API_KEY` is deliberately NOT on the allowlist: the shim reads it from
// its OWN env in `runTurn()` to build the single `--env ANTHROPIC_API_KEY=…` pair
// that `vercel sandbox exec` forwards into the sandbox — the key crosses the remote
// boundary as an EXPLICIT `--env` flag, never as an ambient var of the local child.
// `BARKPARK_*` never crosses at all.
const VERCEL_ENV_PASS = ["HOME", "PATH", "TMPDIR"];

function vercelChildEnv() {
  const env = {};
  for (const k of VERCEL_ENV_PASS) {
    if (process.env[k] !== undefined) env[k] = process.env[k];
  }
  // Prefix-allow every VERCEL_*-namespaced var: VERCEL_AUTH_TOKEN/VERCEL_OIDC_TOKEN
  // are the CLI's auth env (confirmed from `vercel --help`); org/project id vars are
  // unconfirmed by name, so the whole namespace is allowed rather than leaked-by-
  // omission. Nothing outside HOME/PATH/TMPDIR/VERCEL_* reaches the vercel child.
  for (const [k, v] of Object.entries(process.env)) {
    if (k.startsWith("VERCEL_")) env[k] = v;
  }
  return env;
}

function log(msg) {
  // Diagnostics go to STDERR — stdout stays pure NDJSON (D112).
  process.stderr.write(`[cloud-sandbox-runner] ${msg}\n`);
}

// ── Error-message sanitizer (W30, D213) ─────────────────────────────────────────
//
// The shim's stderr tail (last ~8KB/20 lines) is broadcast VERBATIM to every
// connected viewer's ChatLive (claude_chat.ex:1267/1668-1689 → recorder.ex:585-594
// → chat_live.ex:4512, a String.trim passthrough into a visible system message).
// Three call sites fold the LOCAL vercel child's raw stderr (`res.err`) into a
// thrown Error.message — sandbox create, the npm-install fallback, and the claude
// version probe — and the version-probe path ALSO `log()`s that same message on the
// non-strict WARNING branch. Today none carries credential material, but the path is
// one refactor from leaking (D213 forbids folding response/config/credential bytes
// into Error.message). This belt sanitizes at MESSAGE CONSTRUCTION so BOTH the throw
// and the log() path are covered: it redacts env-assignment / bearer-token /
// base64-blob shapes and bounds the length. Fail-safe by construction — a non-string
// coerces to "", and any regex miss is still bounded by the length clamp, so the belt
// never WIDENS what reaches the wire, only narrows it. The diagnostic that matters
// (the vercel exit code) always survives; only secret-shaped payload is stripped.
const SANITIZED_ERR_MAX = 300;
function sanitizeErr(raw) {
  let s = typeof raw === "string" ? raw : raw == null ? "" : String(raw);
  s = s
    // Bearer tokens: `Authorization: Bearer <v>` / `bearer <v>` — redact the value.
    .replace(/\b(bearer)\s+\S+/gi, "$1 [redacted]")
    // Env-assignment: FOO_BAR=<v> (an UPPERCASE env-style key) — redact the value.
    .replace(/\b([A-Z][A-Z0-9_]{2,})=\S+/g, "$1=[redacted]")
    // Long base64 / opaque token blobs (sk-… keys, JWT segments, raw base64).
    .replace(/[A-Za-z0-9_\-+/]{24,}={0,2}/g, "[redacted]");
  s = s.replace(/\s+/g, " ").trim();
  if (s.length > SANITIZED_ERR_MAX) s = s.slice(0, SANITIZED_ERR_MAX) + "…[truncated]";
  return s;
}

// ── argv parse: ────────────────────────────────────────────────────────────────
//   `--workspace <id> [--mcp-config-b64 <b64>] [--sandbox-id <id>] [--keep-sandbox] -- <claude args...>`
//
// `--mcp-config-b64` (connectors D127) is a SHIM-OWN flag — it MUST be parsed
// here in the pre-`--` loop; anything after `--` is handed to claude verbatim.
// Its value is base64(`{"mcpServers":…}`), the workspace's connector-scoped MCP
// servers that runTurn materializes to a /tmp file IN the sandbox and points
// claude at with `--mcp-config … --strict-mcp-config` (never a host path).
//
// Session-scoped sandbox lifecycle (connectors D137/D138) — two ADDITIVE pre-`--`
// flags a multi-turn Barkpark Chat Session's `:cloud` turns carry:
//   `--sandbox-id <id>`  — REUSE an existing session-bound sandbox: skip
//     createSandbox(), exec straight into <id> (it auto-resumes from its
//     stop-snapshot, /tmp intact on the persisted xfs root). Turn N.
//   `--keep-sandbox`     — teardown STOPS the sandbox (`vercel sandbox stop`)
//     instead of REMOVING it, so the next turn can auto-resume; and a keep-mode
//     CREATE emits one `bp_sandbox` sideband frame carrying the new id.
// Both are back-compat by construction: a flag-less invocation is byte-identical
// to the pre-D137 shape (the W11/W12 proof scripts drive the shim flag-less and
// must not notice), and unknown pre-`--` flags were already ignored below.
//
// Per-connector egress widening (Wave 29, D238/D240) — one more ADDITIVE
// pre-`--` flag:
//   `--egress-host <host>` — REPEATABLE; each occurrence accumulates one host
//     DECLARED by an INSTALLED connector (a property of the connector TYPE,
//     emitted by the Elixir side). createSandbox() unions these with the
//     ALLOWED_DOMAIN base into repeated `--allowed-domain` pairs on the
//     SNAPSHOT create path. Flag-less stays byte-identical (deny-all-except-
//     anthropic preserved); an unknown connector emits no flag ⇒ no widening.
function parseArgv(argv) {
  let workspace = null;
  let mcpConfigB64 = null;
  let sandboxId = null;
  let keepSandbox = false;
  const egressHosts = [];
  const claudeArgs = [];
  let i = 0;
  for (; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--") {
      i++;
      break;
    }
    if (a === "--workspace") {
      workspace = argv[++i];
    } else if (a === "--mcp-config-b64") {
      mcpConfigB64 = argv[++i];
    } else if (a === "--sandbox-id") {
      sandboxId = argv[++i];
    } else if (a === "--egress-host") {
      egressHosts.push(argv[++i]);
    } else if (a === "--keep-sandbox") {
      keepSandbox = true;
    } else {
      // Unknown pre-`--` flag — ignore rather than crash a live turn.
      log(`ignoring unrecognized shim arg: ${a}`);
    }
  }
  for (; i < argv.length; i++) claudeArgs.push(argv[i]);
  return { workspace, mcpConfigB64, sandboxId, keepSandbox, egressHosts, claudeArgs };
}

// ── POSIX single-quote a shell token (for the in-sandbox bash -lc command) ────
function shq(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

// ── Run a local `vercel` process, capturing stdout (for `sandbox create` id etc.) ─
// EVERY spawn here is the local `vercel` CLI (createSandbox/runTurn/teardown all
// route through this one function), so it is the single choke point where the D121
// env allowlist is enforced: the child sees ONLY `vercelChildEnv()`, never the
// shim's full inherited env.
function run(cmd, args, { capture = false, inheritStdout = false } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, {
      stdio: ["ignore", inheritStdout ? "inherit" : "pipe", "pipe"],
      env: vercelChildEnv(),
    });
    let out = "";
    let err = "";
    if (!inheritStdout && child.stdout) {
      if (capture) child.stdout.on("data", (d) => (out += d));
      else child.stdout.pipe(process.stdout); // verbatim NDJSON passthrough
    }
    if (child.stderr) child.stderr.on("data", (d) => (err += d));
    child.on("error", (e) => resolve({ code: 127, out, err: err + String(e) }));
    child.on("close", (code) => resolve({ code: code ?? 0, out, err }));
  });
}

// ── Concurrency slot: an atomic slot file under tmp, pid-stamped so a crashed
//    shim's stale slot is reclaimed. Fail-closed: no free slot ⇒ never create an
//    unbounded sandbox. ─────────────────────────────────────────────────────────
const SLOT_DIR = join(tmpdir(), "bp-cloud-turn-slots");
let heldSlot = null;

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === "EPERM"; // exists but not ours
  }
}

function tryTakeSlot(i) {
  const p = join(SLOT_DIR, `slot-${i}`);
  try {
    // Atomic create-exclusive: `wx` fails if the slot is already held.
    writeFileSync(p, String(process.pid), { flag: "wx" });
    return p;
  } catch (e) {
    if (e.code !== "EEXIST") return null;
    // Reclaim a dead holder's slot (a crashed shim leaves its slot behind).
    try {
      const owner = Number.parseInt(readFileSync(p, "utf8").trim(), 10);
      if (Number.isFinite(owner) && !pidAlive(owner)) {
        unlinkSync(p);
        return tryTakeSlot(i);
      }
    } catch {
      /* racing reclaim — just report contended */
    }
    return null;
  }
}

async function acquireSlot() {
  if (!existsSync(SLOT_DIR)) mkdirSync(SLOT_DIR, { recursive: true });
  const deadline = Date.now() + SLOT_WAIT_MS;
  for (;;) {
    for (let i = 0; i < MAX_CONCURRENCY; i++) {
      const slot = tryTakeSlot(i);
      if (slot) {
        heldSlot = slot;
        return;
      }
    }
    if (Date.now() >= deadline) {
      throw new Error(
        `all ${MAX_CONCURRENCY} cloud-turn slots busy after ${SLOT_WAIT_MS}ms — refusing to create an unbounded sandbox`,
      );
    }
    await sleep(250);
  }
}

function releaseSlot() {
  if (heldSlot) {
    try {
      unlinkSync(heldSlot);
    } catch {
      /* already gone */
    }
    heldSlot = null;
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// ── Teardown: tear the sandbox down exactly once ───────────────────────────────
//
// The teardown VERB is mode-dependent (D137):
//   flag-less (default) — `vercel sandbox remove` (D111: REMOVE, never stop; a
//     one-shot turn's sandbox is disposable, and stopped sandboxes accrue
//     snapshot storage). Byte-identical to every pre-D137 exit path.
//   keep mode (`--keep-sandbox`) — `vercel sandbox stop` (auto-snapshots,
//     Persistent=true; the next turn's exec auto-resumes with /tmp intact — D134).
//     NEVER remove: a removed sandbox cannot resume, breaking session continuity.
//
// It is keyed on the SANDBOX existing, NOT on a one-shot latch: in a one-shot turn
// the caller's stdin closes (EOF) right after the first frame — but the stdin-EOF
// handler no longer tears down once a frame is captured (the turn's `finally` owns
// teardown; see readFirstUserFrame). `teardownInFlight` collapses concurrent calls
// (turn-complete + a racing signal trap) onto one `vercel sandbox` invocation.
let sandboxId = null;
let keepMode = false; // set once in main() from `--keep-sandbox`
let sandboxTornDown = false;
let teardownInFlight = null;

function teardownSandbox(reason) {
  if (sandboxTornDown || !sandboxId) return Promise.resolve();
  if (teardownInFlight) return teardownInFlight;
  const id = sandboxId;
  const verb = keepMode ? "stop" : "remove";
  log(`teardown (${reason}): vercel sandbox ${verb} ${id}`);
  teardownInFlight = run(VERCEL_BIN, sbArgs(["sandbox", verb, id]), { capture: true }).then(() => {
    sandboxTornDown = true;
    teardownInFlight = null;
  });
  return teardownInFlight;
}

// ── The bp_sandbox sideband frame (D137) ──────────────────────────────────────
//
// On a keep-mode CREATE the shim emits EXACTLY ONE NDJSON line on stdout BEFORE
// any claude output — the freshly-created sandbox id, so the Elixir Recorder
// (W14-2) can persist it as the session's durable binding (D136) and thread it
// back as `--sandbox-id` on the next turn. The Recorder pattern-matches
// `type:"bp_sandbox"`, stores the id, and SWALLOWS the frame — it is never
// broadcast to SSE/ChatLive nor appended as a message, so the customer NDJSON
// stream stays clean (D112's spirit). A reuse turn (`--sandbox-id`) creates
// nothing, so emits no frame; a flag-less turn emits none either.
function emitSandboxFrame(id) {
  process.stdout.write(
    `${JSON.stringify({ type: "bp_sandbox", subtype: "created", sandbox_id: id })}\n`,
  );
}

// ── Snapshot-retention flags for keep-mode create (D138) ──────────────────────
//
// Every keep-mode `stop` auto-snapshots (~246MB, 30d expiry); `vercel sandbox
// remove` does NOT delete stop-snapshots and stopped sandboxes are invisible to
// `sandbox ls`, so a long session accrues storage. Cap it at the source IF the
// pinned vercel CLI advertises retention flags — PROBED from `sandbox create
// --help` (a LOCAL help print, no API round-trip, no sandbox provisioned) rather
// than guessed by version, so we never pass a flag the CLI would reject. If
// unsupported, the accrual is documented (README) and swept by the backlogged
// reaper (connectors-cloud-sandbox-reaper). Never called on the flag-less or
// reuse paths — only on a keep-mode create.
async function snapshotRetentionFlags() {
  const res = await run(VERCEL_BIN, sbArgs(["sandbox", "create", "--help"]), { capture: true });
  const help = `${res.out || ""}${res.err || ""}`;
  const flags = [];
  if (/--keep-last-snapshots\b/.test(help)) flags.push("--keep-last-snapshots", "1");
  if (/--snapshot-expiration\b/.test(help)) flags.push("--snapshot-expiration", SNAPSHOT_EXPIRATION);
  if (flags.length === 0) {
    log(
      "snapshot-retention flags unsupported by this vercel CLI — stop-snapshots accrue (~246MB, 30d); swept by connectors-cloud-sandbox-reaper",
    );
  } else {
    log(`snapshot-retention flags supported, appending: ${flags.join(" ")}`);
  }
  return flags;
}

// `--scope` pins the Pro team on EVERY vercel invocation (D111 item 5). For
// commands with NO `--` separator (create/remove/ls) it may append; for `exec`
// the scope MUST come BEFORE the `--` or it leaks to the in-sandbox command
// (proven live: a trailing `--scope` on exec is swallowed by the child, so the
// sandbox created under `guerrilla` 404s under the default team). Callers that
// use `--` build the scope in explicitly via `scopeFlag()`.
function sbArgs(base) {
  return [...base, "--scope", SCOPE];
}

function scopeFlag() {
  return ["--scope", SCOPE];
}

// ── stdin: buffer the first `{"type":"user",…}` frame; drop later control frames ─
function readFirstUserFrame() {
  return new Promise((resolve, reject) => {
    let buf = "";
    let resolved = false;

    const onLine = (line) => {
      const trimmed = line.trim();
      if (!trimmed) return;
      let frame;
      try {
        frame = JSON.parse(trimmed);
      } catch {
        log(`dropping non-JSON stdin line`);
        return;
      }
      if (!resolved && frame && frame.type === "user") {
        resolved = true;
        resolve(trimmed);
      } else if (resolved) {
        // Mid-turn control frame — one turn per cloud session this increment.
        log(`dropping mid-turn frame after first user turn: type=${frame?.type}`);
      } else {
        log(`dropping pre-turn frame (awaiting first user turn): type=${frame?.type}`);
      }
    };

    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      buf += chunk;
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        onLine(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
      }
    });
    process.stdin.on("end", () => {
      if (buf.trim()) onLine(buf);
      if (resolved) {
        // The one-shot norm: stdin closes the instant the single user frame is
        // written — BEFORE the turn's sandbox work finishes. Teardown is the
        // turn's `finally` job (stop in keep mode, remove flag-less); a post-frame
        // EOF must NOT abort the in-flight turn. Pre-D137 this was implicitly a
        // no-op only because the CREATE path had not yet set sandboxId when EOF
        // fired — but the reuse path (`--sandbox-id`) sets sandboxId synchronously
        // before the exec, so the guard must be EXPLICIT, not timing-implicit
        // (otherwise EOF would `stop` the reused sandbox mid-turn).
        return;
      }
      // No user frame ever arrived — nothing to run, and no sandbox was ever
      // created, so this teardown is a definitional no-op; it exists to satisfy
      // the reject-on-empty-stdin contract cleanly.
      teardownSandbox("stdin-eof-no-frame").then(() => {
        reject(new Error("stdin closed before any user turn arrived"));
      });
    });
    process.stdin.on("error", (e) => {
      if (!resolved) reject(e);
    });
  });
}

// ── Resolve the MCP config: fetch finished tool headers, pick the transport ───
//
// (Wave 25, D213-D216.) Decides between the TWO delivery modes from the decoded
// `--mcp-config-b64` payload — BEFORE any vercel invocation, in the per-turn
// path (so it fires on BOTH the create and the reuse branch; gating it inside
// createSandbox() is the FORBIDDEN shape — a reused sandbox would run on a stale
// credential):
//
//   `{ mode: "embed", b64 }` — NO top-level `bpConnectorTicket` (or the payload
//     is not JSON): the ORIGINAL b64 rides today's in-VM printf|base64 embed,
//     byte-identical to the pre-W25 shape. Credential-less, so argv is safe.
//   `{ mode: "copy", json }` — the payload carries `bpConnectorTicket`: each
//     `mcpServers` entry's finished headers are fetched from the D71 route and
//     merged verbatim; the ticket is STRIPPED; the now-credential-BEARING config
//     must never ride argv (a b64 embed provably leaks it to ps/logs), so it is
//     delivered via `vercel sandbox copy` of a 0600 host tmpfile (D215).
//
// Throws ONLY the fixed ERR_CREDENTIAL_FETCH string — never response, config,
// or credential bytes (stderr reaches ChatLive verbatim).
async function resolveMcpConfig(mcpConfigB64) {
  if (!mcpConfigB64) return null;
  let config;
  try {
    config = JSON.parse(Buffer.from(mcpConfigB64, "base64").toString("utf8"));
  } catch {
    // Not JSON — a legacy/opaque payload: today's embed path, byte-identical.
    return { mode: "embed", b64: mcpConfigB64 };
  }
  if (
    typeof config !== "object" ||
    config === null ||
    Array.isArray(config) ||
    typeof config.bpConnectorTicket !== "string" ||
    config.bpConnectorTicket === ""
  ) {
    return { mode: "embed", b64: mcpConfigB64 };
  }
  const ticket = config.bpConnectorTicket;
  // Strip the ticket UNCONDITIONALLY: nothing but real headers reaches the
  // sandbox (claude transmits every headers-map key to the MCP endpoint).
  delete config.bpConnectorTicket;
  const servers =
    typeof config.mcpServers === "object" && config.mcpServers !== null
      ? config.mcpServers
      : {};
  const base = BRIDGE_URL.replace(/\/+$/, "");
  for (const [provider, entry] of Object.entries(servers)) {
    if (typeof entry !== "object" || entry === null) continue;
    let headers;
    try {
      // The EXISTING D71 route: provider in the PATH, ticket in the BODY. The
      // reply is the FINISHED header object (e.g. {"Authorization":"Bearer …"})
      // — the bridge owns decryption/refresh; the shim merges bytes verbatim.
      const res = await fetch(`${base}/connect/tool-headers/${provider}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ ticket }),
      });
      if (!res.ok) throw new Error("refused");
      headers = await res.json();
    } catch {
      // Fail closed with the FIXED string — a cross-workspace ticket, a dead
      // bridge, and a malformed reply are all the same refusal to the caller.
      throw new Error(ERR_CREDENTIAL_FETCH);
    }
    if (typeof headers !== "object" || headers === null || Array.isArray(headers)) {
      throw new Error(ERR_CREDENTIAL_FETCH);
    }
    entry.headers = { ...(entry.headers ?? {}), ...headers };
  }
  return { mode: "copy", json: JSON.stringify(config) };
}

// ── Deliver the credential-bearing config via sandbox-copy (D215) ─────────────
//
// stdin into `vercel sandbox exec` is DEAD (proven three ways) and an argv-b64
// embed provably leaks the credential in base64 form — so the config is written
// to a 0600 host tmpfile, copied into the sandbox over the API body (only the
// PATH is argv), and the tmpfile is unlinked in a finally. Same confinement
// pattern as the ANTHROPIC key (D121/D122): the secret crosses in a channel ps
// and logs never see.
async function copyMcpConfigIntoSandbox(id, json) {
  const tmpfile = join(
    tmpdir(),
    `bp-cloud-mcp-${process.pid}-${randomBytes(6).toString("hex")}.json`,
  );
  writeFileSync(tmpfile, json, { mode: 0o600, flag: "wx" });
  try {
    const res = await run(
      VERCEL_BIN,
      sbArgs(["sandbox", "copy", tmpfile, `${id}:${MCP_CONFIG_FILE}`]),
      { capture: true },
    );
    if (res.code !== 0) {
      // Fixed shape, no vercel stderr: the copy carried credential-bearing
      // content, so nothing from this failure may leak into ChatLive.
      throw new Error(`vercel sandbox copy failed (code ${res.code}) — cloud turn aborted`);
    }
  } finally {
    try {
      unlinkSync(tmpfile);
    } catch {
      /* already gone */
    }
  }
}

// ── The in-sandbox one-shot claude command (isolated HOME + clean cwd, D112) ──
//
// When `mcp` is present (the workspace has connector-scoped tools, D127) the
// claude exec gains `--mcp-config <file> --strict-mcp-config` — the shim owns
// ALL mcp argv; the Elixir builder emits none. HOW the config file gets there
// depends on the mode (W25/D215): `embed` base64-embeds it in this script
// (credential-less payloads only — byte-identical to the pre-W25 shape); `copy`
// SKIPS the embed line because `vercel sandbox copy` already materialized the
// credential-BEARING config at MCP_CONFIG_FILE before this script runs. When
// `mcp` is absent the script is BYTE-IDENTICAL to the pre-D127 shape.
function inSandboxScript(claudeArgs, frameB64, mcp) {
  const effectiveArgs = mcp
    ? [...claudeArgs, "--mcp-config", MCP_CONFIG_FILE, "--strict-mcp-config"]
    : claudeArgs;
  const claudeCmd = ["claude", ...effectiveArgs].map(shq).join(" ");
  // base64-decode the buffered frame into the turn file, then run claude reading
  // it as stdin. HOME + cwd are isolated so no operator hook frames leak.
  const lines = [
    `set -e`,
    // The npm GLOBAL bin holds the fallback-installed `claude`; keep it on PATH
    // even after we clamp HOME (login PATH is set before this runs, but the npm
    // prefix prepend is belt-and-suspenders across images).
    `export PATH="$(npm prefix -g 2>/dev/null)/bin:$PATH"`,
    // Isolated HOME + clean cwd (D112) — a dirty HOME/cwd leaks SessionStart hook
    // frames into the customer NDJSON.
    `export HOME=${shq(SANDBOX_HOME)}`,
    `mkdir -p ${shq(SANDBOX_HOME)} ${shq(SANDBOX_CWD)}`,
    `cd ${shq(SANDBOX_CWD)}`,
    `printf '%s' ${shq(frameB64)} | base64 -d > ${shq(TURN_FILE)}`,
  ];
  // Materialize the connector-scoped MCP config in-VM (after the frame line,
  // before the exec) — EMBED mode only: no credential rides it; the servers are
  // HTTP descriptors. Copy mode NEVER embeds — the credential-bearing config
  // was already sandbox-copied to MCP_CONFIG_FILE (argv must never carry it).
  if (mcp && mcp.mode === "embed") {
    lines.push(`printf '%s' ${shq(mcp.b64)} | base64 -d > ${shq(MCP_CONFIG_FILE)}`);
  }
  lines.push(`exec ${claudeCmd} < ${shq(TURN_FILE)}`);
  return lines.join("\n");
}

// ── Assert the in-sandbox claude version matches the pin (D176/D180) ──────────
//
// Runs at the END of createSandbox — the convergence point BOTH provisioning paths
// reach (snapshot: claude pre-baked; fallback: just npm-installed) — so ONE check
// covers both. It probes `claude --version` inside the freshly-provisioned sandbox,
// parses the semver, and compares it to PINNED_CLAUDE_VERSION. A mismatch surfaces
// LOUDLY: a hard fail under VERSION_STRICT (createSandbox throws, the turn never
// dispatches), otherwise an unmistakable stderr WARNING (the version is observed,
// not contractual). It NEVER passes silently on drift.
//
// The probe runs via `bash -c` (NOT `-lc`) with an explicit npm-global PATH prepend:
// `-c` keeps it off the `-lc` turn-locator every fake-vercel proof keys on, while the
// PATH prepend still finds the fallback-installed `claude` binary.
async function assertClaudeVersion(id) {
  if (!PINNED_CLAUDE_VERSION) {
    log("no pinned claude version (cloud-claude-pinned-version.txt absent/empty) — skipping version assertion");
    return;
  }
  const probe = `export PATH="$(npm prefix -g 2>/dev/null)/bin:$PATH"; claude --version`;
  // Scope goes BEFORE the `--` via scopeFlag() (NOT sbArgs — a trailing --scope after
  // the `--` leaks into the in-sandbox command; see sbArgs()'s note). Mirrors runTurn.
  const res = await run(
    VERCEL_BIN,
    ["sandbox", "exec", id, ...scopeFlag(), "--", "bash", "-c", probe],
    { capture: true },
  );
  const raw = `${res.out || ""}`.trim();
  if (res.code !== 0) {
    // Could not run the probe at all — loud, but not a version verdict: warn and let
    // the turn proceed (a probe failure is not itself proof of drift). STRICT still
    // fails closed, since an unverifiable version is as unsafe as a wrong one.
    const msg = `claude-version-probe-failed: could not run 'claude --version' in-sandbox (code ${res.code}: ${sanitizeErr(res.err)}) — cannot confirm the pinned ${PINNED_CLAUDE_VERSION}`;
    if (VERSION_STRICT) throw new Error(msg);
    log(`WARNING: ${msg}`);
    return;
  }
  const m = raw.match(/(\d+\.\d+\.\d+)/);
  const actual = m ? m[1] : null;
  if (actual === PINNED_CLAUDE_VERSION) {
    log(`claude version OK: in-sandbox claude ${actual} matches the pin ${PINNED_CLAUDE_VERSION}`);
    return;
  }
  const seen = actual || `<unparseable: ${JSON.stringify(raw)}>`;
  const msg =
    `claude-version-mismatch: in-sandbox claude ${seen} != pinned ${PINNED_CLAUDE_VERSION} — ` +
    `knob-5 permission semantics were probed on the pin (cloud_policy.ex:57); re-verify before trusting this turn`;
  if (VERSION_STRICT) throw new Error(msg);
  log(`WARNING: ${msg}`);
}

async function createSandbox(workspace, egressHosts = []) {
  const tags = ["--tag", "purpose=cloud-turn", "--tag", `workspace=${workspace}`];
  const timeout = ["--timeout", TIMEOUT];

  // Network egress control (D5/D24). The Firecracker microVM boundary — NO host
  // filesystem/login/process access — is intrinsic to every sandbox; the
  // ALLOWLIST is an ADDITIONAL egress layer. The Vercel CLI treats a custom
  // allowlist as its own policy and REFUSES to combine `--allowed-domain` with
  // `--network-policy` (CLI 54.x): an `--allowed-domain` allowlist already means
  // deny-all-except.
  //
  // The allowlist rides the PRODUCTION SNAPSHOT path (D10 winner — `claude` is
  // pre-baked, so the locked turn needs egress only to the model API). The
  // no-snapshot FALLBACK must `npm i -g` `claude` at boot, which needs the npm
  // registry — so it boots WITHOUT the egress lock (default allow-all). This
  // fallback is the proof/dev convenience D113(c) names ("plain node24 +
  // npm-installed claude"); the real egress lock is a snapshot property, not this
  // path's.
  //
  // Per-connector egress widening (Wave 29, D238/D240/D241/D242): union the
  // connector-declared `--egress-host` values with the ALLOWED_DOMAIN base,
  // dedupe, and emit ONE repeated `--allowed-domain <host>` pair per host.
  // NEVER comma-join (the CLI parses that as ONE malformed domain) and NEVER
  // emit `--network-policy` alongside `--allowed-domain` (the CLI throws — an
  // allowlist already means deny-all-except). With no `--egress-host` flags
  // the shape is byte-identical to the pre-W29 single-base create, so the
  // deny-all-except-anthropic baseline is preserved fail-closed; a connector
  // that declares no egress host simply never widens anything.
  let createArgs;
  if (SNAPSHOT) {
    const hosts = [...new Set([ALLOWED_DOMAIN, ...egressHosts].filter(Boolean))];
    const isolation =
      hosts.length > 0
        ? hosts.flatMap((h) => ["--allowed-domain", h])
        : ["--network-policy", NETWORK_POLICY];
    createArgs = ["sandbox", "create", "--snapshot", SNAPSHOT, ...isolation, ...timeout, ...tags];
  } else {
    createArgs = ["sandbox", "create", "--runtime", RUNTIME, ...timeout, ...tags];
  }

  // Keep-mode create caps the stop-snapshot accrual at the source, IF the CLI
  // supports it (D138 — probed, never guessed; flag-less create appends nothing).
  if (keepMode) {
    createArgs = [...createArgs, ...(await snapshotRetentionFlags())];
  }

  log(`creating sandbox (scope=${SCOPE}, snapshot=${SNAPSHOT || "none/fallback"}) …`);
  const res = await run(VERCEL_BIN, sbArgs(createArgs), { capture: true });
  if (res.code !== 0) {
    throw new Error(`vercel sandbox create failed (code ${res.code}): ${sanitizeErr(res.err)}`);
  }
  const id = res.out.trim().split(/\s+/).pop();
  if (!id) throw new Error(`vercel sandbox create returned no sandbox id`);
  sandboxId = id;
  log(`sandbox created: ${id}`);
  // Keep-mode create publishes the new id as the session's durable binding, ONE
  // sideband NDJSON line on stdout before any claude output (D137). Flag-less
  // create emits nothing — stdout stays byte-identical to the pre-D137 shape.
  if (keepMode) emitSandboxFrame(id);

  if (!SNAPSHOT) {
    log(`fallback boot: npm i -g ${CLAUDE_INSTALL} (no snapshot configured) …`);
    const npm = await run(
      VERCEL_BIN,
      // Scope BEFORE the `--` (see scopeFlag()); everything after `--` is the
      // in-sandbox command.
      ["sandbox", "exec", id, ...scopeFlag(), "--", "npm", "i", "-g", CLAUDE_INSTALL],
      { capture: true },
    );
    if (npm.code !== 0) {
      throw new Error(`in-sandbox claude install failed (code ${npm.code}): ${sanitizeErr(npm.err)}`);
    }
  }
  // Convergence point (D176/D180): whether claude arrived via the snapshot or the
  // fallback npm install, verify the RUNNING version matches the pin before the turn
  // dispatches — a drift surfaces loudly (hard fail under STRICT, else a warning).
  await assertClaudeVersion(id);
  return id;
}

async function runTurn(id, claudeArgs, frame, mcp) {
  const frameB64 = Buffer.from(frame + "\n").toString("base64");
  const script = inSandboxScript(claudeArgs, frameB64, mcp);

  // Inject the key from the SHIM's own env ONLY (D110). A bogus key yields the
  // honest 401 `Invalid API key` result frame — the wire-level proof (D23).
  const envArgs = [];
  if (process.env.ANTHROPIC_API_KEY) {
    envArgs.push("--env", `ANTHROPIC_API_KEY=${process.env.ANTHROPIC_API_KEY}`);
  }

  log(`dispatching one-shot claude turn into ${id} …`);
  const res = await run(
    VERCEL_BIN,
    // Scope + --env are vercel flags → BEFORE the `--`; the bash command follows.
    ["sandbox", "exec", id, ...scopeFlag(), ...envArgs, "--", "bash", "-lc", script],
    { capture: false }, // stdout streams NDJSON verbatim to our stdout
  );
  return res.code;
}

async function main() {
  const { workspace, mcpConfigB64, sandboxId: reuseSandboxId, keepSandbox, egressHosts, claudeArgs } =
    parseArgv(process.argv.slice(2));
  keepMode = keepSandbox; // decides the teardown verb (stop vs remove) in teardownSandbox
  if (!workspace || workspace === "global") {
    log(`FATAL: missing/invalid --workspace (got ${JSON.stringify(workspace)}) — refusing to run an unattributed cloud turn`);
    process.exit(2);
  }

  // Trap every teardown signal (Port.close signals NOTHING — the shim owns this).
  for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) {
    process.on(sig, () => {
      teardownSandbox(sig).then(() => {
        releaseSlot();
        process.exit(130);
      });
    });
  }

  // ── ORDERING LAW (W25/D214): parse → fetch+merge → create/reuse → copy →
  // exec. The credential fetch runs HERE — in the per-turn path, BEFORE any
  // vercel invocation and before a concurrency slot is held — so a refusal
  // (cross-workspace ticket, dead bridge, malformed reply) aborts the turn with
  // ZERO sandbox side effects, and BOTH the create and the reuse branch get a
  // fresh per-turn credential. Never gate this inside createSandbox().
  let mcp = null;
  try {
    mcp = await resolveMcpConfig(mcpConfigB64);
  } catch (e) {
    // e.message is the FIXED refusal string only — safe for the verbatim
    // ChatLive stderr tail.
    log(`FATAL: ${e.message}`);
    process.exit(1);
  }

  let frame;
  try {
    frame = await readFirstUserFrame();
  } catch (e) {
    log(`no turn dispatched: ${e.message}`);
    await teardownSandbox("no-frame");
    releaseSlot();
    process.exit(1);
  }

  let exitCode = 1;
  try {
    await acquireSlot();
    let id;
    if (reuseSandboxId) {
      // Turn N: REUSE the session-bound sandbox (D137). Skip create entirely; the
      // exec auto-resumes it from its stop-snapshot with /tmp intact (D134), so
      // the pinned HOME and claude transcript survive. sandboxId is set HERE (not
      // before readFirstUserFrame resolved) so the stdin-EOF handler already saw
      // it null and stayed a no-op; teardown now targets the reused id.
      id = reuseSandboxId;
      sandboxId = id;
      log(`reusing session sandbox ${id} (skipping create; auto-resumes from stop-snapshot)`);
    } else {
      id = await createSandbox(workspace, egressHosts);
    }
    // Copy mode delivers the credential-BEARING config over the API body
    // (0600 tmpfile → in-VM MCP_CONFIG_FILE, D215) before the exec; embed mode
    // stays inside the in-VM script, byte-identical to the pre-W25 shape.
    if (mcp && mcp.mode === "copy") {
      await copyMcpConfigIntoSandbox(id, mcp.json);
    }
    exitCode = await runTurn(id, claudeArgs, frame, mcp);
  } catch (e) {
    log(`turn failed: ${e.message}`);
    exitCode = 1;
  } finally {
    // Tear the sandbox down now that the turn is done — STOP in keep mode (the
    // next turn auto-resumes), REMOVE flag-less (D137; the stdin-EOF handler is a
    // no-op once the frame is captured). `vercel sandbox exec` does not propagate
    // the in-VM exit code, so the terminal NDJSON `result` frame (is_error) — not
    // this exit code — is the auth-outcome source of truth the Studio classifies.
    await teardownSandbox("turn-complete");
    releaseSlot();
  }
  process.exit(exitCode);
}

main();
