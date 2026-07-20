#!/usr/bin/env node
// rerun.mjs — THE EXECUTOR HALF of the source-of-truth grip gate.
//
// Given a literal rerun command, ACTUALLY RUN IT and return a structured result
// an adjudicator can rule on. This module deliberately does NOT import level.mjs:
// executing a command and ranking an authority level are separate concerns, and
// fusing them is how a level-skip becomes invisible.
//
//   import { runRerun, admitsPassClaim, admitsAbsenceClaim } from "./rerun.mjs";
//
// THE DEFECT THIS EXISTS TO NOT REPEAT — tooling/doc-truth/verify-docs.mjs:883-897
// (`verifyCommand`) checks only whether the *binary resolves on PATH*:
//
//     if (onPath(head)) return tag(claim, "confirmed", "low", `tool resolves on PATH`);
//
// so it "confirmed" four guaranteed-to-fail commands — `git show
// origin/main:api/THIS_FILE_DOES_NOT_EXIST.ex`, `curl http://127.0.0.1:1/...`,
// `curl https://barkpark.cloud/v1/does-not-exist`, `mix test --only
// nonexistent_tag_xyz` — because curl, git and mix exist. PATH-resolution is not
// execution. Everything below executes.
//
// Dependency-free. ESM, node: builtins only. No side effect on import.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

// ── verdicts ─────────────────────────────────────────────────────────────────
// Deliberately NOT a pass/fail boolean. The whole point of D5/D6 is that the
// interesting states live between "pass" and "fail", and collapsing them is what
// lets an outage forge a pass-shaped absence claim.
export const VERDICT = {
  OK: "OK",                                   // ran, reached the right thing
  FAILED: "FAILED",                           // ran, and genuinely refutes the claim
  WRONG_ROUTE: "REACHABLE-WRONG-ROUTE",       // the world is UP, your route is wrong
  UNREACHABLE: "HOST-UNREACHABLE",            // the world is DOWN — says nothing about the route
  UNAVAILABLE: "UNAVAILABLE",                 // the probe could not run here at all
  NULL_READ: "NULL-READ",                     // the read came back empty/broken — NOT an absence
  UNSAFE_RERUN: "UNSAFE-RERUN",               // write-shaped; refused BEFORE execution
  ASYNC_DEFERRED: "ASYNC-DEFERRED",           // too costly to re-run inline
};

export const SCOPE = { SYNC: "SYNC-ADMISSIBLE", ASYNC: "ASYNC-DEFERRED" };

// Hard ceiling for an inline re-run. Measured sync costs on 2026-07-20:
// git show 94-337ms, scoped grep 149ms, curl prod 264-633ms. 2s clears all of
// them with headroom; anything slower is ASYNC-DEFERRED, never a failure.
export const SYNC_TIMEOUT_MS = 2000;

// ── (a) SAFETY — refuse write-shaped commands BEFORE executing ───────────────
// Ordered denylist. Each entry is evidence-driven, not vibes: we refuse on the
// command's SHAPE, because a "read-only" comment is provably not evidence —
// tooling/research-coverage/coverage.mjs documents `scan` as "(read-only)" at
// line 8 and writes coverage-report.json at line 75. Comments do not bind.
const WRITE_SHAPES = [
  [/\brm\s/, "rm"],
  [/\bmv\s/, "mv"],
  [/\btrash\s/, "trash"],
  [/\bdd\s/, "dd"],
  [/\b(mkdir|touch|chmod|chown|ln)\s/, "filesystem mutation"],
  [/\btee\b/, "tee"],
  [/\bsed\s+-[a-z]*i\b/, "sed -i"],
  [/\bgit\s+(push|commit|checkout|switch|reset|rebase|merge|clean|apply|am|tag|stash)\b/, "git write verb"],
  [/\b(npm|pnpm|yarn)\s+(publish|install|add|remove)\b/, "package mutation"],
  [/--write\b/, "--write"],
  [/--fix\b/, "--fix"],
  [/\bmutate\b/, "mutate"],
  [/\bpublish\b/, "publish"],
  [/\b(DROP|DELETE|INSERT|UPDATE|TRUNCATE|ALTER)\s/i, "SQL write"],
  [/\bcurl\b[^|]*\s-X\s*(POST|PUT|PATCH|DELETE)/i, "curl write method"],
  [/\bcurl\b[^|]*\s(-d|--data|--data-raw|--data-binary|-F|--form|-T|--upload-file)\b/, "curl request body"],
  [/\bbp\s+\w+\s+(create|publish|patch|delete|close|claim|stamp|pulse|set)\b/, "bp write verb"],
];

// Redirections that WRITE. `>/dev/null` and `2>&1` discard and are allowed;
// anything else redirecting into a path creates or truncates a file.
const WRITE_REDIRECT = /(^|[^0-9&])>>?\s*(?!\/dev\/(null|stderr|stdout)\b)(?!&)\S/;

// Commands measured to write despite documenting themselves as read-only. This
// list is the ONLY defensible way to catch a liar: it is grounded in a read of
// the implementation, not in what the tool says about itself.
const KNOWN_WRITERS = [
  // coverage.mjs:8 says "(read-only)"; coverage.mjs:75 writeFileSync(coverage-report.json)
  [/research-coverage\/coverage\.mjs\s+scan\b/, "coverage.mjs scan writes coverage-report.json (coverage.mjs:75) despite the '(read-only)' comment at :8"],
];

/**
 * Classify a command as safe to re-run, or refuse it. Pure; no execution.
 * @returns {{safe: boolean, reason: string}}
 */
export function classifySafety(command) {
  const cmd = String(command || "").trim();
  if (!cmd) return { safe: false, reason: "empty command" };

  for (const [re, why] of KNOWN_WRITERS) {
    if (re.test(cmd)) return { safe: false, reason: `known writer: ${why}` };
  }
  for (const [re, why] of WRITE_SHAPES) {
    if (re.test(cmd)) return { safe: false, reason: `write-shaped verb: ${why}` };
  }
  if (WRITE_REDIRECT.test(cmd)) {
    return { safe: false, reason: "write-shaped verb: output redirection to a file" };
  }
  return { safe: true, reason: "no write shape detected" };
}

// ── (b) SCOPE + BUILD WARMTH classifier ──────────────────────────────────────
// The rule is NOT "scope decides, not tool" alone. BUILD WARMTH is a third
// input: a targeted single-file `mix test` costs ~4s against a warm
// api/_build/test but 81.74s on a fresh worktree's FIRST run, because Elixir
// compiles all ~800 files before it can run one test. So an Elixir command is
// ASYNC-DEFERRED unless the build for its env is already warm.

const ELIXIR = /\b(mix|iex)\b/;

// Measured ASYNC costs on 2026-07-20: doc-truth corpus acceptance 39.3s,
// coverage scan 28.7s, CI `mix test` 605s.
const HEAVY_SHAPES = [
  [/doc-truth\/acceptance[\w-]*\.mjs/, "corpus-wide acceptance ≈39.3s"],
  [/research-coverage\/coverage\.mjs/, "coverage scan ≈28.7s"],
  [/\bdocker\b/, "docker"],
  [/\bmake\b/, "make wraps arbitrary cost"],
  [/\bgh\s+(run|workflow)\b/, "CI round-trip"],
];

/** Which MIX_ENV a command will build against. */
export function mixEnvOf(command) {
  const m = /MIX_ENV=(\w+)/.exec(command);
  if (m) return m[1];
  return /\bmix\s+test\b/.test(command) ? "test" : "dev";
}

/** Is the Elixir build warm for this env? Pure filesystem probe, no execution. */
export function isBuildWarm(command, root = process.cwd()) {
  return existsSync(join(root, "api", "_build", mixEnvOf(command), "lib", "barkpark"));
}

/**
 * SYNC-ADMISSIBLE (safe to re-run inline) vs ASYNC-DEFERRED (must be queued).
 * @returns {{scope: string, reason: string}}
 */
export function classifyScope(command, root = process.cwd()) {
  const cmd = String(command || "");

  if (ELIXIR.test(cmd)) {
    const env = mixEnvOf(cmd);
    if (!isBuildWarm(cmd, root)) {
      return { scope: SCOPE.ASYNC, reason: `Elixir on a COLD build: api/_build/${env}/lib/barkpark absent (first run compiles ~800 files, measured 81.74s)` };
    }
    return { scope: SCOPE.SYNC, reason: `Elixir on a WARM api/_build/${env} build (measured ≈4s targeted)` };
  }
  for (const [re, why] of HEAVY_SHAPES) {
    if (re.test(cmd)) return { scope: SCOPE.ASYNC, reason: `known heavy: ${why}` };
  }
  // An unscoped full-tree grep is a corpus walk, not a lookup.
  if (/\b(grep|rg)\b/.test(cmd) && /\s-[a-zA-Z]*r/.test(cmd) && !/\s(\.\/|[\w.-]+\/)/.test(cmd)) {
    return { scope: SCOPE.ASYNC, reason: "unscoped recursive grep walks the whole corpus" };
  }
  return { scope: SCOPE.SYNC, reason: "bounded lookup" };
}

// ── (c) REACHABILITY — keys on the PAIR (code, exit), never the code alone ───
// Measured live 2026-07-20 from this worktree:
//   http://89.167.28.206/api/schemas       code=200 exit=0   reachable, right route
//   http://89.167.28.206/api/health        code=404 exit=0   REACHABLE, WRONG ROUTE
//   https://api.barkpark.cloud/api/schemas code=404 exit=0   reachable, wrong plane
//   http://10.255.255.1/api/schemas        code=000 exit=28  HOST UNREACHABLE
//   http://127.0.0.1:1/nope                code=000 exit=7   HOST UNREACHABLE (refused)
// Collapsing these to "non-200" merges "your route is wrong" with "the world is
// down", which lets an outage forge a pass-shaped absence claim.
const CURL_TRANSPORT_FAILURES = new Set([5, 6, 7, 28, 35, 52, 56]);

/**
 * Rule on an HTTP probe from the (code, exit) PAIR. Pure — the classifier is
 * separable from the network so it can be proven without one.
 * @returns {{verdict: string, reachable: boolean|null}}
 */
export function classifyHttp(code, exit) {
  if (exit !== 0) {
    if (CURL_TRANSPORT_FAILURES.has(exit)) return { verdict: VERDICT.UNREACHABLE, reachable: false };
    return { verdict: VERDICT.UNAVAILABLE, reachable: null }; // curl itself could not run
  }
  // exit 0 means a response came back: the host is UP whatever the status says.
  if (code >= 200 && code < 400) return { verdict: VERDICT.OK, reachable: true };
  return { verdict: VERDICT.WRONG_ROUTE, reachable: true };
}

// ── (d) execution ────────────────────────────────────────────────────────────

const HTTP_URL = /\bhttps?:\/\/[^\s'"|<>]+/;
const SSH_DENIED = /permission denied|no such identity|could not resolve hostname|host key verification failed/i;

function shell(cmd, timeoutMs) {
  const started = Date.now();
  const r = spawnSync("/bin/sh", ["-c", cmd], {
    encoding: "utf8",
    timeout: timeoutMs,
    maxBuffer: 8 * 1024 * 1024,
  });
  return {
    exit: r.status,
    signal: r.signal,
    timedOut: r.error?.code === "ETIMEDOUT" || (r.status === null && r.signal === "SIGTERM"),
    stdout: r.stdout ?? "",
    stderr: r.stderr ?? "",
    ms: Date.now() - started,
    spawnError: r.error && r.error.code !== "ETIMEDOUT" ? String(r.error.code) : null,
  };
}

/**
 * Probe an HTTP URL for the (code, exit) pair. Separate minimal request so the
 * code is measured rather than scraped out of whatever the literal command
 * happened to print. Read-only GET.
 */
export function probeHttp(url, timeoutMs = SYNC_TIMEOUT_MS) {
  const secs = Math.max(1, Math.ceil(timeoutMs / 1000));
  const r = shell(`curl -s -o /dev/null -w '%{http_code}' --max-time ${secs} ${JSON.stringify(url)}`, timeoutMs + 500);
  const code = Number.parseInt(r.stdout.trim(), 10);
  return { code: Number.isNaN(code) ? 0 : code, exit: r.exit ?? -1, ms: r.ms };
}

/**
 * Did this run produce a real read, or nothing at all?
 *
 * D6 — NULL-READ IS ITS OWN VERDICT. An empty stdout, a zero-byte read or a
 * tool-level failure may NEVER be converted into an admissible negative claim
 * ("X is absent"). This is not theoretical: a surveyor reported a fixture as
 * 0 bytes. The file is 2693 bytes in the working tree, 2693 on origin/main and
 * 2693 in every one of 993 worktree copies. There was no 0-byte artifact
 * anywhere to blame — a read returned empty and became a fact.
 *
 * grep is the one tool whose empty output IS a real read: exit 1 means "ran
 * fine, matched nothing", which is a legitimate absence. exit 2 is an error.
 */
function readIsNull(cmd, run) {
  const isGrep = /\b(grep|rg)\b/.test(cmd);
  if (isGrep) {
    if (run.exit === 0 && run.stdout.trim() === "") return "grep exited 0 (match) yet produced no output";
    if (run.exit !== 0 && run.exit !== 1) return `grep errored (exit ${run.exit})`;
    return null; // exit 0 with output, or exit 1 = a genuine no-match
  }
  if (run.exit === 0 && run.stdout.trim() === "") return "command succeeded but produced no output";
  return null;
}

/**
 * Execute a rerun command and return a structured result.
 *
 * `code`, `exit` and `reachable` are SEPARATE fields, never fused into a
 * pass/fail. `reachable` is TRI-STATE: true / false / null (not applicable or
 * unknown) — a boolean would force "unknown" to impersonate "down".
 *
 * @param {string} command  the literal command to re-run
 * @param {{root?: string, timeoutMs?: number}} [opts]
 */
export function runRerun(command, opts = {}) {
  const cmd = String(command || "").trim();
  const root = opts.root ?? process.cwd();
  const timeoutMs = opts.timeoutMs ?? SYNC_TIMEOUT_MS;

  const base = {
    command: cmd,
    verdict: null,
    scope: null,
    code: null,
    exit: null,
    reachable: null,
    ran: false,
    ms: 0,
    stdoutBytes: null,
    stdout: "",
    stderr: "",
    reason: "",
  };

  // 1. SAFETY FIRST — refuse before executing, never after.
  const safety = classifySafety(cmd);
  if (!safety.safe) {
    return decorate({ ...base, verdict: VERDICT.UNSAFE_RERUN, scope: null, reason: safety.reason });
  }

  // 2. SCOPE + WARMTH — never start a run we already know is too expensive.
  const scoped = classifyScope(cmd, root);
  if (scoped.scope === SCOPE.ASYNC) {
    return decorate({ ...base, verdict: VERDICT.ASYNC_DEFERRED, scope: SCOPE.ASYNC, reason: scoped.reason });
  }

  // 3. HTTP PROBE FIRST — rule on the (code, exit) PAIR before running the
  //    literal command. Order matters: a literal `curl` without `--max-time`
  //    against an unroutable host blocks until the sync ceiling and would come
  //    back ASYNC-DEFERRED, i.e. "too expensive" when the truth is "the world
  //    is down". Both are inadmissible so nothing unsafe leaks either way, but
  //    the adjudicator deserves the real reason. The probe carries its own
  //    --max-time, so it always answers.
  const url = HTTP_URL.exec(cmd);
  if (/\bcurl\b/.test(cmd) && url) {
    const probe = probeHttp(url[0], timeoutMs);
    const { verdict, reachable } = classifyHttp(probe.code, probe.exit);
    const httpOut = {
      ...base, scope: SCOPE.SYNC, ran: true, code: probe.code, exit: probe.exit,
      reachable, ms: probe.ms, verdict,
      reason: `code=${probe.code} exit=${probe.exit} — ${verdict}`,
    };
    // Only bother running the literal command when the host actually answered.
    if (reachable) {
      const lit = shell(cmd, timeoutMs);
      httpOut.stdout = lit.stdout;
      httpOut.stderr = lit.stderr;
      httpOut.stdoutBytes = Buffer.byteLength(lit.stdout ?? "", "utf8");
      httpOut.ms += lit.ms;
    } else {
      httpOut.stdoutBytes = 0;
    }
    return decorate(httpOut);
  }

  // 4. EXECUTE. Actually. This is the whole point.
  const run = shell(cmd, timeoutMs);
  const out = {
    ...base,
    scope: SCOPE.SYNC,
    ran: !run.spawnError,
    exit: run.exit,
    ms: run.ms,
    stdout: run.stdout,
    stderr: run.stderr,
    stdoutBytes: Buffer.byteLength(run.stdout, "utf8"),
  };

  // A run that outlived the sync ceiling is DEFERRED, not failed. Timing out is
  // a statement about cost, never about truth.
  if (run.timedOut) {
    return decorate({ ...out, verdict: VERDICT.ASYNC_DEFERRED, scope: SCOPE.ASYNC, exit: null, ran: false,
      reason: `exceeded the ${timeoutMs}ms sync ceiling — deferred, not failed` });
  }
  if (run.spawnError) {
    return decorate({ ...out, verdict: VERDICT.UNAVAILABLE, reason: `could not spawn: ${run.spawnError}` });
  }

  // 5. UNAVAILABLE — the probe cannot run HERE. Never a pass, never a rejection.
  //
  // ssh is ambient HOST state, not repo state: there is no .ssh in the repo, no
  // IdentityFile in .git/config or the Makefile, and no barkpark host in
  // ~/.ssh/config. Measured 2026-07-20: `ssh root@89.167.28.206 true` exits 0
  // from THIS laptop, while the same command is expected to be denied from a
  // machine without the key, and CI has neither. So ssh availability is probed
  // at RUNTIME and never hardcoded — a hardcoded truth here would silently
  // invert the gate's behaviour between environments.
  if (run.exit === 127) {
    return decorate({ ...out, verdict: VERDICT.UNAVAILABLE, reason: "command not found on this host" });
  }
  if (/\bssh\b/.test(cmd) && (run.exit === 255 || SSH_DENIED.test(run.stderr))) {
    return decorate({ ...out, verdict: VERDICT.UNAVAILABLE, reason: "ssh credentials are ambient host state and are absent here" });
  }

  // 6. NULL-READ before any negative verdict, so an empty read can never be
  //    laundered into "X is absent".
  const nullWhy = readIsNull(cmd, run);
  if (nullWhy) {
    return decorate({ ...out, verdict: VERDICT.NULL_READ, reason: nullWhy });
  }

  if (run.exit === 0) {
    return decorate({ ...out, verdict: VERDICT.OK, reason: `exited 0 with ${out.stdoutBytes} bytes of output` });
  }
  // A tool that RAN and answered "no" is a real refutation — this is the branch
  // doc-truth never reached, because it stopped at PATH resolution.
  return decorate({ ...out, verdict: VERDICT.FAILED, reason: `exited ${run.exit}: ${firstLine(out.stderr) || "(no stderr)"}` });
}

function firstLine(s) { return String(s || "").split("\n").find(Boolean)?.trim() ?? ""; }

// ── (e) ADMISSIBILITY — what claim is this result allowed to support? ────────
// The grip layer's entire job. A verdict is not a claim; this is the seam where
// a level-skip would otherwise happen silently.

/** Verdicts that may never support ANY durable claim, positive or negative. */
const INADMISSIBLE = new Set([
  VERDICT.UNAVAILABLE,     // could not run — says nothing either way
  VERDICT.NULL_READ,       // read nothing — says nothing either way
  VERDICT.UNREACHABLE,     // the world was down — says nothing about the route
  VERDICT.ASYNC_DEFERRED,  // never ran inline
  VERDICT.UNSAFE_RERUN,    // refused before execution
]);

/** May this result be cited as a PASS (the claim holds)? */
export function admitsPassClaim(result) {
  return result?.verdict === VERDICT.OK;
}

/**
 * May this result be cited as an ABSENCE / negative claim ("X is not there")?
 *
 * Only a probe that demonstrably RAN and produced a real read may. Notably
 * REACHABLE-WRONG-ROUTE qualifies (the host answered 404: the route really is
 * absent) while HOST-UNREACHABLE does not (the host said nothing at all). That
 * single distinction is what stops an outage from forging a pass-shaped
 * absence claim.
 */
export function admitsAbsenceClaim(result) {
  if (!result || INADMISSIBLE.has(result.verdict)) return false;
  return result.verdict === VERDICT.FAILED || result.verdict === VERDICT.WRONG_ROUTE;
}

/** Throw rather than let an inadmissible result become a durable fact. */
export class GripError extends Error {}

export function assertAbsenceClaim(result, claim = "an absence claim") {
  if (!admitsAbsenceClaim(result)) {
    throw new GripError(
      `REFUSED: ${result?.verdict ?? "no result"} may not support ${claim} — ${result?.reason ?? "no reason recorded"}`
    );
  }
  return result;
}

function decorate(r) {
  r.admits = { pass: admitsPassClaim(r), absence: admitsAbsenceClaim(r) };
  return r;
}
