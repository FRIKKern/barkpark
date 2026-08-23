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
  // `merge(?!-base)` — the ONLY carve-out in this list, and it is narrow by
  // construction. `\bmerge\b` matched inside `merge-base`, so
  // `git merge-base --is-ancestor A B` was refused UNSAFE-RERUN: the epic's own
  // D40 merge-by-content rule and every stranded-branch ancestry check could not
  // be re-run by its own instrument (11 of 652 corpus commands, 1.7%).
  // `git merge-base` only READS — it prints a commit id and writes no ref, no
  // index and no working tree. The lookahead is anchored to the exact five
  // characters that follow, so `git merge`, `git merge --abort` and
  // `git merge origin/main` all stay refused (proven in rerun.test.mjs §6c).
  // `mergetool` is listed explicitly, and it is a TIGHTENING, not part of the
  // carve-out: the pre-change `\bmerge\b` never matched it either (no word
  // boundary between "merge" and "tool"), so `git mergetool` classified SAFE on
  // main and this module would have launched an interactive tree-rewriting
  // session. Found by writing the protective test for the carve-out. Ordered
  // before `merge` so the alternation reaches it.
  // GIT'S GLOBAL OPTIONS SIT BETWEEN `git` AND ITS VERB, and the rule demanded
  // the verb IMMEDIATELY after `git`. So `git -C /tmp/repo push origin main`,
  // `git -C /tmp/repo commit -m x` and `git --no-pager reset --hard origin/main`
  // all classified SAFE — verified against origin/main's own module on
  // 2026-07-21 — and this file would then have EXECUTED them. A false
  // PERMISSION on a command about to run, and the `-C <path>` form is exactly
  // how an agent addresses ANOTHER worktree. Consuming the global options first
  // closes it. This narrows the gate; nothing here widens it.
  // SEPARATED-VALUE GLOBALS, second pass (wave 11): the first pass consumed
  // only `-c`/`-C` <value> pairs; the SEVEN long globals that also eat their
  // next token when written with a space (`--git-dir <path>`, not
  // `--git-dir=<path>`) left the value standing between the globals and the
  // verb, so `git --git-dir log push` classified SAFE — measured against
  // origin/main's own module on 2026-08-23: 84 of the 108 cells in the
  // nine-globals × twelve-verbs matrix laundered. This module EXECUTES what
  // it admits (runRerun gates on classifySafety alone), so the pair branch
  // now carries the same nine value-taking globals as screen.mjs's
  // GIT_VALUE_GLOBALS (PR #12180 fixed only the screen half). Attached `=`
  // forms still ride the generic `-{1,2}[\w-]+(?:=\S+)?` branch, and a
  // valueless global (`--no-pager`) must NOT eat the verb, so only the nine
  // sit in the pair branch. Another narrowing; nothing here widens.
  [/\bgit\s+(?:(?:(?:-[cC]|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--attr-source|--config-env)\s+\S+|-{1,2}[\w-]+(?:=\S+)?)\s+)*(push|commit|checkout|switch|reset|rebase|mergetool|merge(?!-base)|clean|apply|am|tag|stash)\b/, "git write verb"],
  [/\b(npm|pnpm|yarn)\s+(publish|install|add|remove)\b/, "package mutation"],
  [/--write\b/, "--write"],
  [/--fix\b/, "--fix"],
  [/\bmutate\b/, "mutate"],
  [/\bpublish\b/, "publish"],
  [/\b(DROP|DELETE|INSERT|UPDATE|TRUNCATE|ALTER)\s/i, "SQL write"],
  // The verbs above are SHELL verbs, so an interpreter's inline program wrote
  // freely through its host language's API: `node -e 'require("fs").rmSync(…)'`
  // and `python3 -c 'import os; os.remove(…)'` were both classified safe BEFORE
  // this file gained quote awareness (verified against the pre-change module).
  // Quoted code is scanned raw, so naming the APIs closes it. Same caveat as
  // INTERPRETER_SHAPES below: a denylist of mutating APIs cannot be complete.
  [/\b(rmSync|unlinkSync|rmdirSync|writeFileSync|appendFileSync|renameSync|truncateSync)\b/, "fs mutation API"],
  [/\b(shutil\.rmtree|os\.(remove|unlink|rmdir|rename|truncate))\b/, "fs mutation API"],
  // Elixir/Erlang — this repo's primary runtime, so an `elixir -e` / `iex -e`
  // rerun is a realistic shape here in a way `perl -e` is not. `File.rm!` has
  // no trailing space, so the shell-verb `\brm\s` rule never saw it.
  [/\bFile\.(rm|rm_rf|rm!|rm_rf!|write|write!|mkdir|mkdir_p|cp|cp_r|rename|touch)\b!?/, "Elixir File mutation API"],
  [/\bRepo\.(insert|update|delete|insert_all|update_all|delete_all)\b!?/, "Ecto Repo write"],
  [/\b(file|filelib)\s*:\s*(delete|write_file|make_dir|del_dir|rename)\b/, "Erlang file mutation API"],
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

// ── QUOTE AWARENESS — the shapes above describe SHELL SYNTAX, not TEXT ───────
//
// Every regex above is a claim about what the shell will DO. A `>` or the word
// `publish` sitting inside a quoted argument is DATA the command reads, not
// syntax the shell executes — yet a raw scan cannot tell them apart, so all
// five of these read-only commands were refused UNSAFE-RERUN:
//
//   grep -n "a > b" README.md                    → "output redirection to a file"
//   grep -rn "npm publish instructions" docs/    → "package mutation"
//   git log --grep="publish flow"                → "publish"
//   git show HEAD:notes.md | grep "must mutate"  → "mutate"
//   grep -n "chmod 644 is required" docs/x.md    → "filesystem mutation"
//
// That is D3's failure mode latent in the gate itself: a gate that punishes
// honest work gets routed around within a wave. It already bit wave 1 once
// (specimen 3's `<charter>` placeholder refused before it could run).
//
// THE TRAP INSIDE THE FIX. Blanking quoted spans unconditionally is a SECURITY
// REGRESSION, because for some commands the quoted string is not data — it IS
// the code being executed. `psql -c 'DROP TABLE docs'` and `sh -c 'rm -rf /tmp/y'`
// become falsely safe under naive blanking. So an interpreter shape — a head
// whose quoted argument is a program — is scanned RAW, keeping the pre-existing
// (conservative) behaviour exactly.
//
// THIS DENYLIST IS NECESSARILY INCOMPLETE. It is a heuristic, not a shell
// parser: there is no bounded list of every binary that will execute a string
// handed to it, and a novel interpreter (or a wrapper around a listed one)
// slips past. It errs toward REFUSAL — a shape it fails to recognise as an
// interpreter is merely quote-blanked, and anything it recognises falls back to
// the strictly-stricter raw scan — but it must never be read as a proof of
// safety. The verdict it supports is "no write shape detected", never "this
// command cannot write".
const INTERPRETER_SHAPES = [
  /\b(sh|bash|zsh|dash|ksh)\s+(-[a-zA-Z]+\s+)*-c\b/,   // sh -c '<program>'
  /\bpsql\b[^|]*\s-c\b/,                                // psql -c '<SQL>'
  /\b(mysql|sqlite3)\b[^|]*\s-e\b/,                     // mysql -e '<SQL>'
  /\bnode\s+(-e|--eval)\b/,                             // node -e '<JS>'
  /\bpython[\d.]*\s+-c\b/,                              // python -c '<py>'
  /\b(perl|ruby)\s+-e\b/,                               // perl -e '<code>'
  /\bawk\b/,                                            // awk '{system("…")}'
  /\beval\b/,                                           // eval '<anything>'
  /\bxargs\b[^|]*\s-I\b/,                               // xargs -I{} '<cmd>'
  /\bssh\b[^|]*\s(["'])/,                               // ssh host '<remote cmd>'
  /\b(su|sudo)\s+(-[a-zA-Z]+\s+|\S+\s+)*-c\b/,          // su -c '<program>'
  /\b(watch|nohup|timeout|flock|chroot|nice|ionice)\b/, // wrappers that take a command
  /\b(elixir|iex|erl|mix\s+run)\b[^|]*\s(-e|--eval)\b/, // elixir -e '<code>'
];

// Heads whose -c / -e flag takes DATA, not code: -e is a pattern for grep, an
// expression for sed, and -c is a config assignment for git. These are the
// commands the quote-awareness fix exists to stop refusing, so they must not be
// swept up by the shape rule below.
const DATA_FLAG_HEADS = /^(grep|egrep|fgrep|rg|ag|ack|sed|git|jq|comm|cut|sort|uniq|wc|head|tail|tr|nl)$/;

// THE SHAPE RULE — a denylist of interpreter NAMES can never be complete, and
// the review found four live bypasses proving it: `su -c`, `watch`, `elixir -e`
// and `iex -e` all classified `rm -rf /tmp/y` as SAFE once quoted, because the
// quoted span was blanked and no named shape matched. Each was a command this
// module would then have EXECUTED.
//
// So the last line of defence keys on SHAPE, not on a name: any head that is
// handed a quoted argument through the conventional inline-program flags
// (-c / -e / --eval / --command / --exec) is treated as an interpreter unless
// its head is a known data-flag tool. An unknown binary is assumed to execute
// its quoted string.
//
// THE DIRECTION OF THE ERROR IS THE POINT, and it is now inverted from the
// denylist it backstops. Getting the allowlist wrong costs a FALSE REFUSAL
// (annoying, and visible immediately in the verdict message). Getting a
// denylist wrong costs a FALSE PERMISSION on a command about to be run. A
// security guard must fail toward refusal, so the unbounded set — every binary
// that will execute a string — is the one that gets the conservative default.
const INLINE_PROGRAM_FLAG = /(?:^|[|;&(]\s*)([\w./-]+)(?:\s+[^|;&]*?)?\s(?:-c|-e|--eval|--command|--exec)\s*["']/g;

function headTakesCodeInQuotes(cmd) {
  INLINE_PROGRAM_FLAG.lastIndex = 0;
  for (let m; (m = INLINE_PROGRAM_FLAG.exec(cmd)) !== null; ) {
    const head = m[1].split("/").pop();
    if (!DATA_FLAG_HEADS.test(head)) return true;
  }
  return false;
}

/** Does this command hand its quoted argument to something that EXECUTES it? */
function executesItsQuotedArgument(cmd) {
  return INTERPRETER_SHAPES.some((re) => re.test(cmd)) || headTakesCodeInQuotes(cmd);
}

/**
 * Replace the CONTENTS of every quoted span with spaces, 1:1 (quote characters
 * included), leaving unquoted text — real shell syntax — byte-identical. Offsets
 * are preserved so a reported match still lines up with the original string.
 *
 * Returns null when the scan ends INSIDE an unterminated quote: that is a
 * malformed command, and blanking its tail would hide whatever follows the
 * stray quote. Callers fall back to the raw scan.
 */
export function blankQuotedSpans(command) {
  const cmd = String(command || "");
  let out = "";
  let quote = null;
  for (let i = 0; i < cmd.length; i++) {
    const ch = cmd[i];
    if (quote === "'") {
      // Single quotes are literal in POSIX sh — no escapes inside them.
      out += ch === "'" ? ((quote = null), " ") : " ";
    } else if (quote === '"') {
      if (ch === "\\" && i + 1 < cmd.length) { out += "  "; i++; continue; }
      out += ch === '"' ? ((quote = null), " ") : " ";
    } else if (ch === "'" || ch === '"') {
      quote = ch;
      out += " ";
    } else if (ch === "\\" && i + 1 < cmd.length) {
      // An escaped character outside quotes is literal data (`\>` is a `>`
      // glyph, not a redirect), so neutralise the pair — still 1:1.
      out += "  ";
      i++;
    } else {
      out += ch;
    }
  }
  return quote === null ? out : null;
}

/**
 * Classify a command as safe to re-run, or refuse it. Pure; no execution.
 * @returns {{safe: boolean, reason: string}}
 */
export function classifySafety(command) {
  const cmd = String(command || "").trim();
  if (!cmd) return { safe: false, reason: "empty command" };

  // Scan the SYNTAX, not the text — except where the quoted text IS the syntax.
  const blanked = executesItsQuotedArgument(cmd) ? null : blankQuotedSpans(cmd);
  const scanned = blanked ?? cmd;

  for (const [re, why] of KNOWN_WRITERS) {
    if (re.test(scanned)) return { safe: false, reason: `known writer: ${why}` };
  }
  for (const [re, why] of WRITE_SHAPES) {
    if (re.test(scanned)) return { safe: false, reason: `write-shaped verb: ${why}` };
  }
  if (WRITE_REDIRECT.test(scanned)) {
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

// `cwd` makes opts.root the EXECUTION directory, not just a scope/warmth probe
// path. Before this parameter existed, /bin/sh -c ran wherever the CALLER
// happened to be invoked, so a repo-relative rerun's verdict depended on
// invocation cwd — seal.test.mjs's polarity specimen ruled NULL-READ from a
// tooling/grip cwd and FAILED from the repo root, and seal.mjs's CLI had to
// paper over it by chdir-ing in main() (a fix its library path never got).
function shell(cmd, timeoutMs, cwd) {
  return finishSpawn(Date.now(), spawnSync("/bin/sh", ["-c", cmd], {
    encoding: "utf8",
    timeout: timeoutMs,
    maxBuffer: 8 * 1024 * 1024,
    ...(cwd ? { cwd } : {}),
  }));
}

/**
 * Run one program with an ARGUMENT VECTOR — no shell, no word splitting, no
 * expansion. Every byte of every argv entry reaches the program as inert data.
 *
 * This exists because `shell()` is the wrong primitive for anything carrying
 * caller-supplied text. It is not a hardening layer on top of a gate; it is the
 * absence of the interpreter the gate would otherwise have to out-guess.
 */
function spawnArgv(file, args, timeoutMs) {
  return finishSpawn(Date.now(), spawnSync(file, args, {
    encoding: "utf8",
    timeout: timeoutMs,
    maxBuffer: 8 * 1024 * 1024,
  }));
}

function finishSpawn(started, r) {
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
 *
 * ARGV, NOT A SHELL STRING — and not a tighter URL regex either. `url` is
 * fact-derived untrusted input: it comes out of HTTP_URL scanning a rerun
 * command an author wrote. This once built a `/bin/sh -c` string with the URL
 * double-quoted, and double quotes do NOT stop `$( )`: probing
 * `http://localhost:1/$(echo INJECTED > /tmp/INJMARK)` created the file, with
 * curl itself failing exit 7 — the substitution ran BEFORE curl did, so the
 * request never had to succeed.
 *
 * classifySafety did not save it. It read safe=false only because that payload
 * happened to be `touch`, a WRITE_SHAPES name; the same injection carrying
 * `reboot` reads safe=true. The gate caught a class of PAYLOAD, never the
 * INJECTION — which is exactly the denylist-on-a-sink failure this epic exists
 * to name. Passing an argument vector removes the interpreter instead of
 * out-guessing it, so every metacharacter is inert data to curl.
 */
export function probeHttp(url, timeoutMs = SYNC_TIMEOUT_MS) {
  const secs = Math.max(1, Math.ceil(timeoutMs / 1000));
  const r = spawnArgv(
    "curl",
    ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", String(secs), String(url)],
    timeoutMs + 500,
  );
  const code = Number.parseInt(r.stdout.trim(), 10);
  return { code: Number.isNaN(code) ? 0 : code, exit: r.exit ?? -1, ms: r.ms };
}

// ── (d2) SILENCE — classified by TOOL FAMILY first, exit code second (D50) ───
//
// D6 — NULL-READ IS ITS OWN VERDICT. An empty stdout, a zero-byte read or a
// tool-level failure may NEVER be converted into an admissible negative claim
// ("X is absent"). This is not theoretical: a surveyor reported a fixture as
// 0 bytes. The file is 2693 bytes in the working tree, 2693 on origin/main and
// 2693 in every one of 993 worktree copies. There was no 0-byte artifact
// anywhere to blame — a read returned empty and became a fact.
//
// The pre-family rule protected grep BY NAME and nothing else, which failed in
// BOTH directions and both were reproduced by running the shipped module:
//
//   diff README.md NOPE.mjs   → exit 2, 0 bytes, verdict FAILED, absence=TRUE
//   grep -n zzz NOPE.mjs      → exit 2, 0 bytes, verdict NULL-READ, absence=false
//
// The same tool error — a missing operand — became a manufactured absence claim
// for every tool that is not grep. That is strictly worse than discarding a true
// answer: the D6 failure class, one tool away from where D6 was patched. In the
// other direction a clean `git log --grep=<no such commit>` (rc0, empty) is a
// real EMPTY-SET answer and was discarded as NULL-READ.
//
// THERE IS NO FLAT RULE. grep's rc1 means "no match" (an ABSENCE answer) while
// diff's rc1 means "differences found" — measured at 33,609 bytes of real
// content on this very file. So the tempting one-liner ("any rc1 is a real
// read") INVERTS diff's polarity: it would let a diff that found differences be
// cited as proof that something is missing. Family first, exit code second.
export const FAMILY = Object.freeze({
  MATCHER: "MATCHER",             // grep/rg   rc1 = a genuine no-match
  PREDICATE: "PREDICATE",         // is-ancestor/test  answers with the exit code alone
  DIFFER: "DIFFER",               // diff/cmp  rc1 = DIFFERENCES FOUND, not absence
  QUERY_LISTER: "QUERY-LISTER",   // git log/ls/go vet  rc0+empty = an EMPTY SET
  CONTENT_FETCH: "CONTENT-FETCH", // git show/cat-file  rc128 needs a stderr rule
  UNKNOWN: "UNKNOWN",             // unrecognised — keeps the conservative default
});

// DISPATCH ON THE HEAD TOKEN, never on a loose word match. `git log
// --grep=zzz` contains the substring `grep` and a `\bgrep\b` rule read it as a
// MATCHER — which would have graded a clean commit search (rc0, empty) as
// "grep exited 0 yet printed nothing", i.e. a NULL-READ, the exact discard this
// table exists to end. The head is the first real token: leading `VAR=value`
// assignments are stripped and a path is reduced to its basename, so
// `LC_ALL=C /usr/bin/grep` is still a MATCHER.
const MATCHER_HEADS = new Set(["grep", "egrep", "fgrep", "rg", "ugrep", "ug", "ag", "ack"]);
const LISTER_HEADS = new Set(["ls", "find"]);
const GIT_CONTENT_FETCH = new Set(["show", "cat-file"]);
const GIT_LISTERS = new Set([
  "diff", "log", "ls-tree", "ls-files", "rev-list", "rev-parse",
  "status", "show-ref", "for-each-ref", "blame", "describe", "shortlog",
]);
const GO_LISTERS = new Set(["vet", "build", "list"]);

/** Tokens of a command segment, with env assignments stripped. */
function tokens(segment) {
  const all = segment.trim().split(/\s+/).filter(Boolean);
  let i = 0;
  while (i < all.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(all[i])) i++;
  return all.slice(i);
}

/** git's first NON-option token — `git -C /tmp show` is still a `show`. */
function gitSubcommand(rest) {
  for (let i = 0; i < rest.length; i++) {
    const t = rest[i];
    if (!t.startsWith("-")) return { verb: t, args: rest.slice(i + 1) };
    // `-C <path>` and `-c <k=v>` consume the token after them.
    if (t === "-C" || t === "-c") i++;
  }
  return { verb: "", args: [] };
}

// A pipeline's exit code is its LAST command's, so the family must be read from
// the last stage: `git show HEAD:x | grep -c foo` exits 1 as a grep no-match,
// not as a git failure. `||`, `&&` and `;` are NOT pipes — for `a || b` the exit
// code belongs to a when a succeeds and to b when it does not, so the provenance
// is genuinely ambiguous and the family stays UNKNOWN (the conservative default)
// rather than being guessed.
const AMBIGUOUS_LIST = /\|\||&&|;/;

/** Which tool family's exit-code grammar governs this command? Pure. */
export function classifyFamily(command) {
  const cmd = String(command || "").trim();
  if (!cmd) return FAMILY.UNKNOWN;
  // Scan SYNTAX, not text — a `|` or the word `diff` inside a quoted pattern is
  // data, exactly as in classifySafety. An unterminated quote falls back to raw.
  const blanked = blankQuotedSpans(cmd) ?? cmd;
  if (AMBIGUOUS_LIST.test(blanked)) return FAMILY.UNKNOWN;

  // Find the pipe on the BLANKED text (a quoted `|` is data, not a pipeline),
  // then slice the ORIGINAL at that offset — blanking is 1:1, so the offsets
  // line up. Tokenising the blanked text instead DELETES quoted arguments
  // entirely, and `git -C "<path>" show X` then reads its own subcommand as the
  // argument to -C: the whole command falls to UNKNOWN.
  const pipe = blanked.lastIndexOf("|");
  const parts = tokens(pipe === -1 ? cmd : cmd.slice(pipe + 1));
  if (parts.length === 0) return FAMILY.UNKNOWN;

  const head = parts[0].split("/").pop();
  const rest = parts.slice(1);
  const has = (...flags) => rest.some((t) => flags.some((f) => t === f || t.startsWith(`${f}=`)));

  if (MATCHER_HEADS.has(head)) return FAMILY.MATCHER;
  if (head === "test" || head === "[") return FAMILY.PREDICATE;
  // `cmp -s` answers with its exit code alone; bare `cmp` prints the first
  // difference, so it reads as a DIFFER.
  if (head === "cmp") return has("-s", "--quiet", "--silent") ? FAMILY.PREDICATE : FAMILY.DIFFER;
  if (head === "diff") return FAMILY.DIFFER;
  if (LISTER_HEADS.has(head)) return FAMILY.QUERY_LISTER;

  if (head === "git") {
    const { verb, args } = gitSubcommand(rest);
    const hasArg = (...flags) => args.some((t) => flags.some((f) => t === f || t.startsWith(`${f}=`)));
    if (verb === "merge-base") return hasArg("--is-ancestor") ? FAMILY.PREDICATE : FAMILY.QUERY_LISTER;
    if (GIT_CONTENT_FETCH.has(verb)) return FAMILY.CONTENT_FETCH;
    if (verb === "diff" && hasArg("--quiet", "--exit-code")) return FAMILY.DIFFER;
    if (GIT_LISTERS.has(verb)) return FAMILY.QUERY_LISTER;
    return FAMILY.UNKNOWN;
  }
  if (head === "go") {
    const verb = rest.find((t) => !t.startsWith("-")) ?? "";
    return GO_LISTERS.has(verb) ? FAMILY.QUERY_LISTER : FAMILY.UNKNOWN;
  }
  return FAMILY.UNKNOWN;
}

// FOUR SEMANTICS SHARE EXIT 128, and only one of them is decay. Keying decay on
// the exit code alone lets a worktree that never fetched `origin` report the
// ENTIRE ledger as decayed — an outage forging a decay wave. rc128 is a
// NECESSARY PRECONDITION; the stderr pattern is the discriminator. All four
// wordings were captured from this host's git on 2026-07-21:
//   fatal: path 'x' does not exist in 'HEAD'                    → PATH-GONE
//   fatal: path 'x' exists on disk, but not in 'HEAD'           → PATH-GONE
//   fatal: invalid object name 'no-such-ref'.                   → REF-GONE
//   fatal: not a git repository (or any of the parent …)        → WRONG-CWD
const GIT_PATH_GONE = /does not exist in|exists on disk, but not in/i;
const GIT_REF_GONE = /invalid object name|unknown revision or path not in the working tree|bad revision|ambiguous argument/i;
const GIT_WRONG_CWD = /not a git repository/i;

/**
 * Rule on a completed run's (family, exit, output) triple. Pure — separable from
 * execution so every branch is provable without spawning anything.
 *
 * `absenceEligible: false` marks a result that RAN and answered decisively but
 * whose answer is not an absence — DIFFER's rc1 is "these differ", with content,
 * and citing it as "X is not there" is the polarity inversion this table exists
 * to prevent. It is a SEPARATE channel from the verdict on purpose: the verdict
 * vocabulary is shared with adjudicate.mjs (EXECUTION_MAP), and a new enum name
 * would fail closed to UNKNOWN-VERDICT there — correct, but it would silently
 * make the whole DIFFER family unusable downstream.
 *
 * @returns {{family: string, verdict: string, reason: string, absenceEligible: boolean}}
 */
export function classifySilence(command, run = {}) {
  const family = classifyFamily(command);
  const exit = run.exit;
  const stdout = String(run.stdout ?? "");
  const stderr = String(run.stderr ?? "");
  const empty = stdout.trim() === "";
  const bytes = Buffer.byteLength(stdout, "utf8");
  const ok = (verdict, reason, absenceEligible = true) => ({ family, verdict, reason, absenceEligible });

  switch (family) {
    // grep rc0 must PRINT: "matched" with nothing to show is a broken read.
    case FAMILY.MATCHER:
      if (exit === 0 && empty) return ok(VERDICT.NULL_READ, "grep exited 0 (match) yet produced no output");
      if (exit === 0) return ok(VERDICT.OK, `matched, ${bytes} bytes of output`);
      if (exit === 1) return ok(VERDICT.FAILED, "ran fine and matched nothing — a genuine no-match");
      // ugrep (this host's `grep`) words its rc2 warning differently from GNU
      // grep, so this keys on the EXIT CODE, never on the message.
      return ok(VERDICT.NULL_READ, `the matcher errored (exit ${exit}) — a tool error is not an absence`, false);

    // The exit code IS the answer, so silence is expected and admissible.
    case FAMILY.PREDICATE:
      if (exit === 0) return ok(VERDICT.OK, "the predicate holds (exit 0)");
      if (exit === 1) return ok(VERDICT.FAILED, "the predicate does not hold (exit 1)");
      return ok(VERDICT.NULL_READ, `the predicate errored (exit ${exit}) — neither true nor false`, false);

    // rc1 means DIFFERENCES FOUND — a presence answer carrying content, and the
    // single most dangerous cell in this table to get wrong.
    case FAMILY.DIFFER:
      if (exit === 0) return ok(VERDICT.OK, "identical — no differences (an answer, not an empty read)");
      if (exit === 1) return ok(VERDICT.FAILED, `differences found (${bytes} bytes) — a DIFFERENCE, never an absence`, false);
      return ok(VERDICT.NULL_READ, `the differ errored (exit ${exit}): ${firstLine(stderr) || "(no stderr)"} — it never compared anything`, false);

    // rc0 + empty is the EMPTY SET: a clean `go vet` is the canonical green.
    case FAMILY.QUERY_LISTER:
      if (exit === 0 && empty) return ok(VERDICT.OK, "exited 0 with no rows — an EMPTY SET, which is the answer");
      if (exit === 0) return ok(VERDICT.OK, `exited 0 with ${bytes} bytes of output`);
      return ok(VERDICT.FAILED, `exited ${exit}: ${firstLine(stderr) || "(no stderr)"}`);

    case FAMILY.CONTENT_FETCH:
      if (exit === 0 && empty) return ok(VERDICT.NULL_READ, "the fetch exited 0 but returned no bytes");
      if (exit === 0) return ok(VERDICT.OK, `fetched ${bytes} bytes`);
      if (exit === 128) {
        if (GIT_WRONG_CWD.test(stderr)) {
          return ok(VERDICT.UNAVAILABLE, "not a git repository here — an environment fault, never decay", false);
        }
        if (GIT_REF_GONE.test(stderr)) {
          return ok(VERDICT.UNAVAILABLE, `the ref could not be resolved here (unfetched or renamed): ${firstLine(stderr)} — an environment fault, never decay`, false);
        }
        if (GIT_PATH_GONE.test(stderr)) {
          return ok(VERDICT.FAILED, `the ref resolved and the path is NOT in it: ${firstLine(stderr)}`);
        }
        return ok(VERDICT.UNAVAILABLE, `git exited 128 with an unrecognised reason: ${firstLine(stderr) || "(no stderr)"}`, false);
      }
      return ok(VERDICT.FAILED, `exited ${exit}: ${firstLine(stderr) || "(no stderr)"}`);

    // Unrecognised: keep the pre-existing conservative default exactly. An
    // unknown tool's silence proves nothing, so it stays a NULL-READ.
    default:
      if (exit === 0 && empty) return ok(VERDICT.NULL_READ, "command succeeded but produced no output");
      if (exit === 0) return ok(VERDICT.OK, `exited 0 with ${bytes} bytes of output`);
      return ok(VERDICT.FAILED, `exited ${exit}: ${firstLine(stderr) || "(no stderr)"}`);
  }
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
    family: null,
    // Defaults TRUE so an untouched shape behaves exactly as it did before the
    // family table existed; only a family rule that has PROVEN the answer is not
    // an absence ever sets it false.
    absenceEligible: true,
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
  if (/\b(curl|wget)\b/.test(cmd) && url) {
    const probe = probeHttp(url[0], timeoutMs);
    const { verdict, reachable } = classifyHttp(probe.code, probe.exit);
    const httpOut = {
      ...base, scope: SCOPE.SYNC, ran: true, code: probe.code, exit: probe.exit,
      reachable, ms: probe.ms, verdict,
      literalExit: null,
      reason: `code=${probe.code} exit=${probe.exit} — ${verdict}`,
    };
    // Only bother running the literal command when the host actually answered.
    if (reachable) {
      const lit = shell(cmd, timeoutMs, root);
      httpOut.stdout = lit.stdout;
      httpOut.stderr = lit.stderr;
      httpOut.stdoutBytes = Buffer.byteLength(lit.stdout ?? "", "utf8");
      httpOut.ms += lit.ms;
      httpOut.literalExit = lit.exit;

      // THE PROBE'S AUTHORITY IS NOT THE LITERAL COMMAND'S AUTHORITY.
      // The probe answers ONE question — did the host respond, and on which
      // route. It says nothing about whether the literal command SUCCEEDED. A
      // pipeline like `curl … | grep -q NEEDLE` reaches a live 200 host and
      // still exits nonzero when the needle is absent; ruling on the probe
      // alone reported OK and admits.pass=true for a read that found nothing —
      // the reachability probe's authority laundered onto the command's result,
      // this module's own failure mode. The literal exit therefore governs the
      // verdict whenever the host answered; the probe governs only reachability.
      if (lit.timedOut) {
        httpOut.verdict = VERDICT.ASYNC_DEFERRED;
        httpOut.scope = SCOPE.ASYNC;
        httpOut.ran = false;
        httpOut.reason = `host answered code=${probe.code}, but the literal command exceeded the ${timeoutMs}ms sync ceiling — deferred, not failed`;
      } else {
        // NULL-READ applies only to a PIPED command. An unpiped curl's read is
        // the HTTP response itself, which the probe already measured — and
        // `curl -o /dev/null` deliberately discards stdout, so testing it for
        // emptiness would reject an honest probe (D3: never punish honest work).
        const silence = cmd.includes("|")
          ? classifySilence(cmd, { exit: lit.exit, stdout: lit.stdout, stderr: lit.stderr })
          : null;
        if (silence?.verdict === VERDICT.NULL_READ) {
          httpOut.verdict = VERDICT.NULL_READ;
          httpOut.reason = `host answered code=${probe.code}, but the read was null: ${silence.reason}`;
        } else if (silence && silence.absenceEligible === false) {
          // The filter RAN and answered, but its answer is not an absence.
          httpOut.verdict = silence.verdict;
          httpOut.absenceEligible = false;
          httpOut.reason = `host answered code=${probe.code}; ${silence.reason}`;
        } else if (lit.exit !== 0) {
          httpOut.verdict = VERDICT.FAILED;
          httpOut.reason = `host answered code=${probe.code} (reachable) but the literal command exited ${lit.exit}: ${firstLine(lit.stderr) || "(no stderr)"}`;
        }
      }
    } else {
      httpOut.stdoutBytes = 0;
    }
    return decorate(httpOut);
  }

  // 4. EXECUTE. Actually. This is the whole point.
  const run = shell(cmd, timeoutMs, root);
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

  // 6. FAMILY-DISPATCHED SILENCE (D50). One table rules on every remaining
  //    outcome, so a tool error can never be laundered into an absence claim and
  //    a legitimately silent answer (a clean `go vet`, a byte-identical `diff`,
  //    an ancestry predicate) is no longer discarded as a null read. This is the
  //    branch doc-truth never reached, because it stopped at PATH resolution.
  const silence = classifySilence(cmd, run);
  return decorate({
    ...out,
    verdict: silence.verdict,
    family: silence.family,
    absenceEligible: silence.absenceEligible,
    reason: silence.reason,
  });
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
 *
 * `absenceEligible: false` is the family table's veto (D50): a DIFFER that
 * exited 1 RAN and answered decisively, but its answer is "these differ" with
 * content attached — never "X is not there". Absent the field (a bare
 * `{verdict}` object) the answer is unchanged from before the table existed.
 */
export function admitsAbsenceClaim(result) {
  if (!result || INADMISSIBLE.has(result.verdict)) return false;
  if (result.absenceEligible === false) return false;
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
