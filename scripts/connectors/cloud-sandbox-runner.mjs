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
//     cloud-sandbox-runner --workspace <workspace_id> -- <claude args...>
//
// Everything after `--` is the claude command line to run INSIDE the sandbox
// (the D109 argv: --input-format/--output-format stream-json, --include-partial-
// messages, --verbose, --permission-mode <mode>; never a bypass flag, no mcp args).
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
//      nothing tears it down for free): stdin-EOF watcher AND SIGTERM/SIGINT/exit
//      trap both `vercel sandbox remove` (REMOVE, never stop — stopped sandboxes
//      accrue snapshot storage). `--timeout` is the guaranteed backstop.
//
// Mid-turn control frames (interrupt/set_permission_mode/control_response) are
// logged to stderr and DROPPED — one turn per cloud session this increment
// (interactive multi-turn needs a PTY: named follow-on).
//
// Dependency-free: only Node built-ins + the `vercel` CLI (NOT the SDK this
// increment — the CLI is what D10/D23 proved under frikk's auth). No live sandbox
// is created by importing this file; creation happens only on a real turn.

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync, readFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// ── Config (env, all overridable; safe defaults) ──────────────────────────────
const VERCEL_BIN = process.env.CLOUD_SANDBOX_VERCEL_BIN || "vercel";
const SCOPE = process.env.CLOUD_SANDBOX_SCOPE || "guerrilla";
const SNAPSHOT = process.env.CLOUD_SANDBOX_SNAPSHOT || ""; // empty ⇒ fallback boot+install
const RUNTIME = process.env.CLOUD_SANDBOX_RUNTIME || "node24";
const TIMEOUT = process.env.CLOUD_SANDBOX_TIMEOUT || "10m"; // MANDATORY create backstop
const ALLOWED_DOMAIN = process.env.CLOUD_SANDBOX_ALLOWED_DOMAIN || "api.anthropic.com";
const NETWORK_POLICY = process.env.CLOUD_SANDBOX_NETWORK_POLICY || "deny-all";
const CLAUDE_INSTALL = process.env.CLOUD_SANDBOX_CLAUDE_INSTALL || "@anthropic-ai/claude-code";
// Env-clamped concurrency (D111 item 6) — kept well under the Hobby 10-concurrent
// ceiling; the Pro `guerrilla` scope is higher but the clamp is a safety valve.
const MAX_CONCURRENCY = clampInt(process.env.CLOUD_SANDBOX_MAX_CONCURRENCY, 6, 1, 50);
const SLOT_WAIT_MS = clampInt(process.env.CLOUD_SANDBOX_SLOT_WAIT_MS, 120_000, 0, 600_000);
// In-sandbox isolation paths (D112) — never an operator checkout.
const SANDBOX_HOME = process.env.CLOUD_SANDBOX_HOME || "/tmp/bp-cloud-home";
const SANDBOX_CWD = process.env.CLOUD_SANDBOX_CWD || "/tmp/bp-cloud-cwd";
const TURN_FILE = "/tmp/turn.jsonl";

function clampInt(raw, dflt, lo, hi) {
  const n = Number.parseInt(raw ?? "", 10);
  if (!Number.isFinite(n)) return dflt;
  return Math.min(hi, Math.max(lo, n));
}

function log(msg) {
  // Diagnostics go to STDERR — stdout stays pure NDJSON (D112).
  process.stderr.write(`[cloud-sandbox-runner] ${msg}\n`);
}

// ── argv parse: `--workspace <id> -- <claude args...>` ────────────────────────
function parseArgv(argv) {
  let workspace = null;
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
    } else {
      // Unknown pre-`--` flag — ignore rather than crash a live turn.
      log(`ignoring unrecognized shim arg: ${a}`);
    }
  }
  for (; i < argv.length; i++) claudeArgs.push(argv[i]);
  return { workspace, claudeArgs };
}

// ── POSIX single-quote a shell token (for the in-sandbox bash -lc command) ────
function shq(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

// ── Run a local process, capturing stdout (for `vercel sandbox create` id etc.) ─
function run(cmd, args, { capture = false, inheritStdout = false } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, {
      stdio: ["ignore", inheritStdout ? "inherit" : "pipe", "pipe"],
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

// ── Teardown: remove the sandbox exactly once (D111 — REMOVE, never stop) ──────
//
// The removal is keyed on the SANDBOX existing, NOT on a one-shot `toreDown`
// latch: in a one-shot turn the caller's stdin closes (EOF) the instant the first
// frame is written — BEFORE the sandbox is created — so an EOF-triggered teardown
// must be a NO-OP that leaves the real post-turn teardown free to remove the
// sandbox once it exists. `removeInFlight` collapses concurrent calls onto one
// `vercel sandbox remove`.
let sandboxId = null;
let sandboxRemoved = false;
let removeInFlight = null;

function teardownSandbox(reason) {
  if (sandboxRemoved || !sandboxId) return Promise.resolve();
  if (removeInFlight) return removeInFlight;
  const id = sandboxId;
  log(`teardown (${reason}): vercel sandbox remove ${id}`);
  removeInFlight = run(VERCEL_BIN, sbArgs(["sandbox", "remove", id]), { capture: true }).then(
    () => {
      sandboxRemoved = true;
      removeInFlight = null;
    },
  );
  return removeInFlight;
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
      // EOF is the caller-gone teardown signal (Port.close delivers NOTHING —
      // D111). A NO-OP until a sandbox exists: in a one-shot turn stdin closes
      // the instant the frame is written, long before create, so this must not
      // pre-empt the turn; once a sandbox exists a mid-turn EOF aborts it.
      teardownSandbox("stdin-eof").then(() => {
        if (!resolved) reject(new Error("stdin closed before any user turn arrived"));
      });
    });
    process.stdin.on("error", (e) => {
      if (!resolved) reject(e);
    });
  });
}

// ── The in-sandbox one-shot claude command (isolated HOME + clean cwd, D112) ──
function inSandboxScript(claudeArgs, frameB64) {
  const claudeCmd = ["claude", ...claudeArgs].map(shq).join(" ");
  // base64-decode the buffered frame into the turn file, then run claude reading
  // it as stdin. HOME + cwd are isolated so no operator hook frames leak.
  return [
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
    `exec ${claudeCmd} < ${shq(TURN_FILE)}`,
  ].join("\n");
}

async function createSandbox(workspace) {
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
  let createArgs;
  if (SNAPSHOT) {
    const isolation = ALLOWED_DOMAIN
      ? ["--allowed-domain", ALLOWED_DOMAIN]
      : ["--network-policy", NETWORK_POLICY];
    createArgs = ["sandbox", "create", "--snapshot", SNAPSHOT, ...isolation, ...timeout, ...tags];
  } else {
    createArgs = ["sandbox", "create", "--runtime", RUNTIME, ...timeout, ...tags];
  }

  log(`creating sandbox (scope=${SCOPE}, snapshot=${SNAPSHOT || "none/fallback"}) …`);
  const res = await run(VERCEL_BIN, sbArgs(createArgs), { capture: true });
  if (res.code !== 0) {
    throw new Error(`vercel sandbox create failed (code ${res.code}): ${res.err.trim()}`);
  }
  const id = res.out.trim().split(/\s+/).pop();
  if (!id) throw new Error(`vercel sandbox create returned no sandbox id`);
  sandboxId = id;
  log(`sandbox created: ${id}`);

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
      throw new Error(`in-sandbox claude install failed (code ${npm.code}): ${npm.err.trim()}`);
    }
  }
  return id;
}

async function runTurn(id, claudeArgs, frame) {
  const frameB64 = Buffer.from(frame + "\n").toString("base64");
  const script = inSandboxScript(claudeArgs, frameB64);

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
  const { workspace, claudeArgs } = parseArgv(process.argv.slice(2));
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
    const id = await createSandbox(workspace);
    exitCode = await runTurn(id, claudeArgs, frame);
  } catch (e) {
    log(`turn failed: ${e.message}`);
    exitCode = 1;
  } finally {
    // REMOVE the sandbox now that the turn is done (the EOF handler was a no-op
    // if it fired before create). `vercel sandbox exec` does not propagate the
    // in-VM exit code, so the terminal NDJSON `result` frame (is_error) — not this
    // exit code — is the auth-outcome source of truth the Studio side classifies.
    await teardownSandbox("turn-complete");
    releaseSlot();
  }
  process.exit(exitCode);
}

main();
