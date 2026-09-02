// binding.mjs — the pure, READ-TIME grammar that answers WHICH TREE a stored
// recipe's answer is about.
//
//   import { classifyBinding, classifyAll } from "./binding.mjs";
//   classifyBinding("cd /Volumes/SATECHI/github/barkpark && git show origin/main:x | wc -l")
//     → { binding_class: "shared-ref", anchor: "origin/main", rule: "REMOTE-TRACKING-REF", … }
//
// Reads no file, spawns nothing, reads no clock. Every verdict is a function of
// the command string alone.
//
// ── WHY THIS IS NOT A PATH SCREEN (charter D73) ──────────────────────────────
//
// A FIXED PAST READING, NOT A LIVE COUNT. Every figure in this section was
// measured over the store as it stood at 60ef35bd06 (2026-07-21): 62 rows. The
// ledger is an append-only shared write target that grows without touching this
// file, so the snapshot is named once here and every count below is read
// against it — restating any of them with today's total would just reset the
// same clock (charter D23/D37/D52, and D102's ruling on live denominators).
//
// At 60ef35bd06 (2026-07-21), 46 of those 62 stored rows (74.2%) hard-coded an
// absolute checkout path, and the obvious fix — refuse absolute paths at mint
// time — INVERTED its own signal. Classifying the same 62 rows by WHICH REF THE
// COMMAND ACTUALLY READS gave the opposite of the path-shape picture:
//
//   `cd /Volumes/… && git show origin/main:internal/cli/tasks_next_cmd.go | wc -l`
//        → 314 lines in the primary checkout, in a linked worktree, and in a
//          fresh /tmp worktree. refs/remotes/* lives only in the shared .git and
//          is absent from .git/worktrees/<name>/. The `cd` is INERT.
//   `git ls-tree HEAD --name-only tooling/grip/ledger/`
//        → 1 file in the primary, 4 in a fresh worktree. No absolute path in it.
//   `grep -c needs_worktree <relative path>`
//        → 5 vs 6. No absolute path in it either.
//
// A path-shape screen would REFUSE the 44 rows that answer identically from any
// worktree and ADMIT the 9 whose answer is decided by cwd. PATH SHAPE DOES NOT
// PREDICT PORTABILITY; REF IDENTITY DOES. So a `cd <path> &&` prefix — and its
// twin `git -C <path>` — never decides the class here. It is stripped, recorded
// as `cd_prefix`, and the REST is classified.
//
// ── THE FIVE CLASSES, MOST PORTABLE FIRST (D73) ──────────────────────────────
//
//   content-addressed    a SHA-pinned read. Resolves identically in any clone on
//                        any box that has the object. THE MIRROR INVERSION a
//                        3-way split gets backwards: a naive grammar with no SHA
//                        rule drops every SHA-pinned read into its else branch
//                        and labels the single most portable form "answers about
//                        YOUR tree".
//   shared-ref           origin/…, upstream/…, refs/remotes/…. Shared among
//                        WORKTREES of one .git — NOT across clones (D75, below).
//   per-worktree         HEAD, a bare local read, and the index-bound family
//                        ls-files / status / diff. The index lives at
//                        .git/worktrees/<name>/index. Proven divergent inside one
//                        tree: `git ls-files tooling/grip/ledger/` returns 2 where
//                        `git ls-tree HEAD --name-only tooling/grip/ledger/`
//                        returns 1. ls-files landing in the right bucket via an
//                        else branch is right by accident, so it gets its own rule.
//   cwd-bound            a bare filesystem read on a RELATIVE path. The answer is
//                        decided by the process's cwd.
//   foreign-tree-pinned  an ABSOLUTE path into a named checkout, or a read over
//                        ssh to a named box. Answers about THAT tree from
//                        anywhere — which is why the 2 rows pinning the EPHEMERAL
//                        .claude/worktrees/spill-janitor-wt/ are WORSE than the 44
//                        pinning the primary checkout, not better.
//
// ── portable_scope NEVER SAYS "anywhere" FOR shared-ref (D75) ────────────────
//
// A clone's refs/remotes/origin/* mirrors the SOURCE's refs/heads/*, never the
// source's own refs/remotes/*, so a clone silently inherits the source's
// staleness. Measured: source refs/heads/main a96aacce6, source
// refs/remotes/origin/main 515f14fdd, clone refs/remotes/origin/main a96aacce6 —
// 41 commits apart, 69 files differing. The same shared-ref recipe then answers
// `level.mjs` = 339 lines in the clone and 615 in the primary, BOTH exit 0.
// `--depth 1` changes nothing; a single-ref CI checkout has no origin/main at
// all and exits 128. Every CI checkout is a clone. So shared-ref's honest scope
// is "any worktree of this clone" and the phrase is a constant in this module.
//
// ── exit_masked IS A FIRST-CLASS OUTPUT, AND D76's MECHANISM IS CORRECTED ────
//
// D76 ruled that, at 60ef35bd06 (2026-07-21), 49 of the 62 stored rows masked
// their failure, and described them as "rows ending in `| wc -l` or `| grep
// -c`". The COUNT reproduced exactly against that snapshot.
// The MECHANISM does not, and the correction is the same shape as D73's own:
//
//   22 rows end in `| wc -l`   → git exits 128, pipeline prints "0", EXITS 0.
//   22 rows end in `| grep -c` → git exits 128, pipeline prints "0", exits 1.
//    5 rows end in `| grep -n` → git exits 128, pipeline prints nothing, exits 1.
//   ── 49 rows pipe a tree read into a filter. 44 end in a counter, not 49.
//
// Measured, not argued (`git show origin/main:nope.txt 2>/dev/null | …`): wc -l
// masks BOTH the status and the value; grep -c masks the VALUE only (its own
// rc 1 survives) yet still prints a plausible "0"; grep -n masks neither the
// status nor a quantity, but turns an infrastructure failure into an ABSENCE
// that is byte-identical to a legitimate no-match. All three are indistinguishable
// from a real negative answer at the reading end, which is what `exit_masked`
// means here — so the boolean covers all 49 and `exit_mask_rule` carries the
// severity D76's single bit hides. `set -o pipefail` anywhere in the command
// clears the flag; at 60ef35bd06 (2026-07-21), 0 of the 62 rows carried it.
//
// ── WHAT THIS MODULE DELIBERATELY IS NOT (D74) ───────────────────────────────
//
// It is READ-TIME. It is not a stored field: RECIPE_FIELDS is frozen to six keys
// and admitRecipe REJECTS unknown ones, so `binding_class` on a row returns
// UNKNOWN-FIELD. It is not a screen on the write seam: a refusal there is
// all-or-nothing (one refused row in a batch of four writes ZERO files), which is
// the worst possible home for a discriminator still under debate. It grandfathers
// the 46 rows by LABELLING them, never by editing history — the store is
// structurally immutable (wx/O_EXCL, no update verb, no supersede).
//
// ── KNOWN BOUNDS, STATED RATHER THAN HIDDEN ─────────────────────────────────
//
//  1. NOT EVERY COMMAND READS A TREE. `curl`, `bp`, `psql` read a running system
//     or a network service; D73's five classes have no slot for that. Those take
//     the cwd-bound FLOOR under the named rule NETWORK-READ-NO-TREE, and the
//     reason says so in words. Read the rule, not the class. Filed as
//     tgw6-binding-non-tree-class.
//  2. ANYTHING WRITTEN INSIDE QUOTES IS INVISIBLE — refs and path operands
//     alike. Token scanning runs over a quote-masked copy, so
//     `git show 'origin/main:x'` reads as bare-git-local and
//     `find "/Users/pelle/Library/…"` reads as a relative find. That is the
//     correct trade on the corpus measured at 60ef35bd06 (2026-07-21), not a
//     guess: 0 of 62 stored rows and 0 of the 104 git-bearing proofs quoted a
//     ref, and 0 of 62 stored rows quoted an absolute path in that snapshot.
//     14 of the 652 proofs did quote an absolute path, and in most of those it
//     is a grep PATTERN or the body of a `python3 -c` program,
//     where masking is the RIGHT answer — unmasked, `git worktree list | grep
//     '/Volumes/SATECHI/github/barkpark'` would be read as a foreign-tree pin.
//     The residual loss is the handful of genuinely quoted operands.
//  3. THE CLASS OF A COMPOUND IS ITS FLOOR. `a && b` is only as portable as its
//     least portable read, and `reason` names how many statements were folded.
//
// ── THE PUBLISHED ELSE-SHARE FIGURE, AND WHAT DEFENDS IT (D102) ─────────────
//
// The epic publishes one number about this module: it answers from an ELSE
// branch 4.8% of the time where a naive 3-way rule answers from one 89.0% of
// the time. Re-derived over fixtures/evidence-corpus.json, blob
// f0d6b6cbdb50490889e4489ef782eaca7737e86c:
//
//   31 of 652 = 4.8%   this grammar, else-branch arrivals
//   580 of 652 = 89.0% the naive 3-way rule the tests run beside it
//
// THE FIGURE IS NEVER QUOTED BARE. binding.test.mjs recomputes both on every run
// and prints them with THIS FILE'S blob sha beside them, so the pairing of a
// number with the classifier that produced it is a live output rather than a
// comment someone forgot to update. A figure copied out of here without that sha
// is a present-tense claim about whatever the classifier is today.
//
// WHAT DEFENDS IT — because the 4.8% was, until this file grew `else_branch`,
// a number no test could fail on. The guard was `assert.ok(defaultShare < 0.2)`
// over a count derived from the rule REGISTRY, and pointing an else arm at an
// already-registered rule marked `is_default: false` collapsed it 31 → 2 and
// "improved" the published figure to 0.3% without classifying one command
// differently. Two things changed:
//
//   * the count is stamped by the ARM (elseBranchVerdict is the only constructor
//     that sets `else_branch`), so it cannot be moved by editing a string; and
//   * it is bounded from BOTH sides at the measured value, because every way of
//     gaming this figure moves it DOWN and a ceiling alone waves that through.
//
// So a genuine improvement here is a DELIBERATE edit: lower the floor, name the
// rule that earned it, and re-derive this paragraph at the new sha.

import { looksLikeProse } from "./level.mjs";

// --- the class ladder --------------------------------------------------------

// Ordered MOST PORTABLE FIRST. The index IS the portability rank, and the class
// of a compound command is the max index across its statements (the floor).
export const BINDING_CLASSES = Object.freeze([
  "content-addressed",
  "shared-ref",
  "per-worktree",
  "cwd-bound",
  "foreign-tree-pinned",
]);

// The honest one-phrase scope per class. "anywhere" appears nowhere in this
// table and must never be added to the shared-ref row (D75).
export const PORTABLE_SCOPES = Object.freeze({
  "content-addressed": "any clone",
  "shared-ref": "any worktree of this clone",
  "per-worktree": "this worktree",
  "cwd-bound": "this cwd",
  "foreign-tree-pinned": "one named checkout",
});

function rankOf(bindingClass) {
  const rank = BINDING_CLASSES.indexOf(bindingClass);
  return rank === -1 ? BINDING_CLASSES.length : rank;
}

// --- the rule registry -------------------------------------------------------
//
// EVERY verdict names the rule that fired, and the else branches are named
// DEFAULT-* so a reviewer can separate "right by rule" from "right by accident".
// That separation is not decoration: on the 652-proof corpus a trivial
// always-cwd-bound classifier scores 12.7% error, so an accuracy number with no
// rule attribution proves nothing about the grammar.
export const BINDING_RULES = Object.freeze([
  { rule: "NO-COMMAND", class: null, is_default: false, what: "empty, non-string, or prose — no command to classify" },
  { rule: "SHA-PIN-REVISION", class: "content-addressed", is_default: false, what: "a git read pinned to an abbreviated or full object id" },
  { rule: "REMOTE-TRACKING-REF", class: "shared-ref", is_default: false, what: "origin/…, upstream/…, refs/remotes/…, @{u}" },
  { rule: "GIT-REMOTE-SERVER-OP", class: "shared-ref", is_default: false, what: "fetch / ls-remote — reads the remote this clone names" },
  { rule: "FORGE-API-READ", class: "shared-ref", is_default: false, what: "gh api / gh pr — reads the forge behind this clone's remote" },
  { rule: "INDEX-BOUND-FAMILY", class: "per-worktree", is_default: false, what: "ls-files / status / diff / stash — the index at .git/worktrees/<name>/index" },
  { rule: "WORKTREE-HEAD-REF", class: "per-worktree", is_default: false, what: "HEAD, HEAD~n, ORIG_HEAD, @{n} — HEAD is per-worktree" },
  { rule: "LOCAL-BRANCH-REF", class: "per-worktree", is_default: false, what: "refs/heads/… or a bare local branch — this clone's own claim" },
  { rule: "WORKTREE-CONTENT-SCAN", class: "per-worktree", is_default: false, what: "git grep with no ref — scans the working tree" },
  { rule: "BARE-GIT-LOCAL-STATE", class: "per-worktree", is_default: true, what: "a git read naming no ref at all — DEFAULT within the git family" },
  { rule: "ABS-PATH-EPHEMERAL-WORKTREE", class: "foreign-tree-pinned", is_default: false, what: "an absolute path into a worktree that will be pruned" },
  { rule: "ABS-PATH-SCRATCH", class: "foreign-tree-pinned", is_default: false, what: "an absolute path into scratch space (/tmp, /var/folders) — one box, and usually already gone" },
  { rule: "ABS-PATH-PINNED", class: "foreign-tree-pinned", is_default: false, what: "an absolute path into one named checkout on one box" },
  { rule: "REMOTE-HOST-READ", class: "foreign-tree-pinned", is_default: false, what: "ssh — the read happens on another box entirely" },
  { rule: "RELATIVE-PATH-READ", class: "cwd-bound", is_default: false, what: "grep / wc / ls / cat / find on a relative path" },
  { rule: "TOOLCHAIN-CWD-ROOTED", class: "cwd-bound", is_default: false, what: "go / npm / node / mix / python — resolves against the cwd project" },
  { rule: "NETWORK-READ-NO-TREE", class: "cwd-bound", is_default: false, what: "curl / bp / psql — reads a running system; NO class in D73 fits, this is a floor" },
  { rule: "DEFAULT-CWD-BOUND", class: "cwd-bound", is_default: true, what: "no rule fired — the ELSE branch" },
]);

const RULE_INDEX = new Map(BINDING_RULES.map((entry) => [entry.rule, entry]));

// isDefaultRule(rule) → boolean. A rule name is a default/else branch when the
// registry says so. Exported because the share of verdicts arriving this way IS
// the classifier's quality signal, and a caller must not have to string-match.
export function isDefaultRule(rule) {
  const entry = RULE_INDEX.get(rule);
  return entry ? entry.is_default : false;
}

// --- exit-mask severities ----------------------------------------------------

export const EXIT_MASK_RULES = Object.freeze([
  { rule: "MASK-PIPE-EXIT-AND-VALUE", what: "piped into wc — a failed read prints 0 AND exits 0" },
  { rule: "MASK-PIPE-VALUE", what: "piped into grep -c — a failed read prints 0; grep's own rc 1 survives" },
  { rule: "MASK-PIPE-SILENT", what: "piped into a filter — a failed read becomes an absence indistinguishable from a real no-match" },
]);

const MASK_SEVERITY = ["MASK-PIPE-EXIT-AND-VALUE", "MASK-PIPE-VALUE", "MASK-PIPE-SILENT"];

// --- lexing ------------------------------------------------------------------

// A length-preserving copy of the command with every quoted region blanked, so
// that a ref-shaped or HEAD-shaped token inside a grep PATTERN cannot forge a
// verdict. Indices into the mask map 1:1 onto the raw string (bound 2 above).
function maskQuoted(command) {
  const out = [];
  let quote = null;
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote) {
      out.push(ch === quote ? ch : " ");
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      out.push(ch);
      continue;
    }
    out.push(ch);
  }
  return out.join("");
}

// Split a masked command into STATEMENTS on unquoted ; && || and newlines.
// Pipeline bars are NOT statement separators: the segments after a `|` are
// filters over the head's stdout, so only the head of a pipeline reads a tree.
function splitStatements(mask) {
  const spans = [];
  let start = 0;
  for (let i = 0; i < mask.length; i += 1) {
    const two = mask.slice(i, i + 2);
    if (two === "&&" || two === "||") {
      spans.push([start, i]);
      i += 1;
      start = i + 1;
      continue;
    }
    if (mask[i] === ";" || mask[i] === "\n") {
      spans.push([start, i]);
      start = i + 1;
    }
  }
  spans.push([start, mask.length]);
  return spans.filter(([a, b]) => mask.slice(a, b).trim() !== "");
}

// Split one statement into pipeline segments on unquoted `|` (never `||`,
// already consumed as a statement separator).
function splitPipeline(text) {
  const parts = [];
  let start = 0;
  for (let i = 0; i < text.length; i += 1) {
    if (text[i] === "|" && text[i + 1] !== "|" && text[i - 1] !== "|") {
      parts.push(text.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(text.slice(start));
  return parts.map((part) => part.trim()).filter((part) => part !== "");
}

function tokens(text) {
  return text.split(/\s+/).filter(Boolean);
}

// The real head program: leading `VAR=value`, `time`, `sudo`, `env` and an
// opening paren are wrappers, not the reader. `CC=/usr/bin/clang go test …`
// appears 43 times in the corpus and its head is `go`, not `CC=/usr/bin/clang`.
const WRAPPER_HEADS = new Set([
  "time", "sudo", "env", "nohup", "exec", "command", "\\",
  // shell-syntax scaffolding around the real read: `for f in …; do git show …;
  // done` splits into three statements and the middle one's head is `do`.
  "do", "then", "else",
]);

// Heads that produce no answer about any tree. They are DROPPED, not defaulted:
// letting `&& echo YES` contribute a DEFAULT-CWD-BOUND verdict demoted 51
// corpus proofs — including `git merge-base --is-ancestor <sha> origin/main &&
// echo YES` — from a real ref verdict to the else branch.
const NON_READ_HEADS = new Set([
  "echo", "printf", "export", "set", "unset", "true", "false", "exit", "return",
  "kill", "pkill", "sleep", "wait", "mkdir", "rm", "mv", "touch", "ln", "chmod",
  "for", "while", "until", "if", "fi", "done", "esac", "case", "elif", "trap",
]);

function headTokens(text) {
  let list = tokens(text.replace(/^[\s(]+/, ""));
  while (list.length > 0) {
    const first = list[0];
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(first) || WRAPPER_HEADS.has(first)) {
      list = list.slice(1);
      continue;
    }
    break;
  }
  return list;
}

function headProgram(text) {
  const head = headTokens(text)[0] ?? "";
  return head.replace(/^.*\//, ""); // /usr/bin/git → git
}

// --- head families -----------------------------------------------------------

const FS_READ_HEADS = new Set([
  "grep", "rg", "ag", "wc", "ls", "cat", "head", "tail", "find", "stat", "file",
  "sed", "awk", "jq", "diff", "du", "sort", "uniq", "cut", "tr", "test", "tree",
  "xargs", "md5", "md5sum", "shasum", "readlink", "basename", "dirname", "comm",
  "cmp", "od", "nl", "less", "more", "column", "yq", "rev",
]);

const TOOLCHAIN_HEADS = new Set([
  "go", "npm", "npx", "pnpm", "yarn", "node", "deno", "bun", "mix", "iex",
  "elixir", "python", "python3", "pip", "pip3", "cargo", "make", "bundle",
  "ruby", "php", "java", "gradle", "mvn", "tsc", "vitest", "jest", "pytest",
  "bash", "sh", "zsh", "vercel", "claude",
]);

const NETWORK_HEADS = new Set([
  "curl", "wget", "http", "httpie", "psql", "mysql", "redis-cli", "bp", "nc",
  "dig", "host", "openclaw", "aws", "hcloud", "doctl", "pelle", "systemctl",
  "journalctl", "docker",
]);

// git subcommands whose answer is the INDEX or the working tree, not a ref.
const INDEX_BOUND_SUBCOMMANDS = new Set(["ls-files", "status", "stash", "add", "restore", "apply", "clean"]);

const GIT_REMOTE_SUBCOMMANDS = new Set(["fetch", "ls-remote", "remote", "pull", "push"]);

function gitSubcommand(text) {
  const list = tokens(text);
  const start = list.findIndex((token) => token.replace(/^.*\//, "") === "git");
  for (let i = start + 1; i < list.length; i += 1) {
    const token = list[i];
    if (token.startsWith("-")) {
      // `git -C <path>` and `git -c k=v` consume a value; -C is stripped upstream.
      if (token === "-C" || token === "-c") i += 1;
      continue;
    }
    return token;
  }
  return "";
}

// --- token scanners ----------------------------------------------------------

// The leading class admits `.` so that a RANGE puts its remote end in reach:
// `git log --oneline d23b3e628..origin/main` is decided by origin/main, and a
// boundary that stops at `..` reads it as a bare SHA pin — the single most
// portable class stamped on a read of a moving ref.
const REMOTE_REF = /(?:^|[\s:=("'.])((?:origin|upstream|fork)\/[A-Za-z0-9._/-]+|refs\/remotes(?:\/[A-Za-z0-9._/-]+)?)/;
const UPSTREAM_SHORTHAND = /@\{u(?:pstream)?\}/;
const HEAD_REF = /(?:^|[\s:=("'])(ORIG_HEAD|FETCH_HEAD|MERGE_HEAD|HEAD(?:[~^][0-9]*)*)(?=$|[\s:.,)'"@])/;
const LOCAL_BRANCH_REF = /(?:^|[\s:=("'])(refs\/heads\/[A-Za-z0-9._/-]+)/;
// A SHA must be 7-40 lowercase hex AND carry at least one a-f letter. The letter
// requirement is load-bearing: `20260629160000_data_keys…` is a migration
// timestamp, not an object id, and an all-digit rule mints content-addressed
// verdicts out of migration filenames.
const SHA_TOKEN = /(?:^|[\s:=("'])([0-9a-f]{7,40})(?=$|[\s:.,)'"])/g;

function findSha(text) {
  SHA_TOKEN.lastIndex = 0;
  let match = SHA_TOKEN.exec(text);
  while (match) {
    const token = match[1];
    if (/[a-f]/.test(token)) return token;
    match = SHA_TOKEN.exec(text);
  }
  return null;
}

// A bare local branch in a revision position — `git merge-base --is-ancestor
// <sha> main`. Restricted to the three names this repo actually uses as
// branches, and never after `--` (a pathspec separator).
const BARE_BRANCHES = new Set(["main", "master", "develop"]);

function findBareBranch(text) {
  const list = tokens(text);
  for (let i = 0; i < list.length; i += 1) {
    if (list[i] === "--") return null;
    if (i === 0) continue;
    if (BARE_BRANCHES.has(list[i]) && !list[i - 1].startsWith("--")) return list[i];
  }
  return null;
}

// Scratch space. A read here names one box and, by the time anyone re-runs it,
// usually names nothing at all.
const SCRATCH_PREFIX = /^\/(?:private\/)?(?:tmp|var\/folders|var\/tmp)\//;
// Executable locations. `/usr/bin/time go test …` pins nothing about a tree —
// it names the binary that ran, which is why the EXECUTABLE token is dropped
// before the scan rather than filtered after it.
const BIN_PREFIX = /^\/(?:usr|bin|sbin|opt\/homebrew|Applications|Library|System|nix)\//;

// Absolute path OPERANDS, with the four shapes that are not tree pins removed
// first: a URL path (http://host/v1/…), a redirect to /dev/null, the command's
// own executable path, and a binary under a system bin dir.
function findAbsolutePath(text) {
  const scrubbed = text
    .replace(/[a-z][a-z0-9+.-]*:\/\/\S+/gi, " ")
    .replace(/2?>\s*\/dev\/null/g, " ")
    .replace(/\/dev\/\S+/g, " ");
  const list = headTokens(scrubbed).slice(1); // operands only, never the head
  for (const token of list) {
    const bare = token.replace(/^[('"<>]+/, "").replace(/[)'",;]+$/, "");
    if (!bare.startsWith("/")) continue;
    if (bare.length < 2) continue;
    if (BIN_PREFIX.test(bare)) continue;
    return bare;
  }
  return null;
}

function absolutePathRule(path) {
  if (/\/(?:\.claude\/)?worktrees\//.test(path)) return "ABS-PATH-EPHEMERAL-WORKTREE";
  if (SCRATCH_PREFIX.test(path)) return "ABS-PATH-SCRATCH";
  return "ABS-PATH-PINNED";
}

function findSshHost(text) {
  for (const token of tokens(text)) {
    if (/^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$/.test(token)) return token;
  }
  return null;
}

// --- cd / -C prefixes --------------------------------------------------------
//
// A `cd <path>` statement and a `git -C <path>` flag say the same thing and are
// handled identically: recorded, then removed. Neither decides a class (D73).
function isCdStatement(text) {
  return /^[\s(]*cd\s+\S/.test(text);
}

// The target is the REST of the cd statement, not its first whitespace token:
// the statement has already been split on `&&`/`;`, so everything after `cd` is
// the destination — and the destination is routinely quoted or a command
// substitution. `cd "$(git rev-parse --show-toplevel)"` (this epic's own gate
// line) tokenises to the garbage fragment `"$(git`, which then renders verbatim
// inside `reason`. Outer matching quotes are stripped; the substitution is kept
// whole, because "the tree this resolved to" is exactly what a reader needs.
function cdTarget(text) {
  const rest = text.replace(/^[\s(]*cd\s+/, "").trim();
  if (rest === "") return null;
  const unquoted = rest.replace(/^(['"])([\s\S]*)\1$/, "$2").trim();
  return unquoted === "" ? null : unquoted;
}

function stripDashC(text) {
  const match = text.match(/(?:^|\s)-C\s+(\S+)/);
  if (!match) return { text, target: null };
  return { text: text.replace(match[0], " "), target: match[1] };
}

// --- the statement classifier ------------------------------------------------

// THE TWO VERDICT CONSTRUCTORS, AND WHY THERE ARE TWO.
//
// `else_branch` is stamped by the CONSTRUCTOR the arm chose, never derived from
// the rule NAME. The distinction is the whole point: `isDefaultRule` answers
// "does the registry say this NAME is a default", which a rename settles, while
// `else_branch` answers "did this verdict come out of an arm reached because
// nothing above it matched", which only moving the arm can change. The
// else-share census counts the second. See classifyAll.
function verdictFor(rule, anchor, reason) {
  const entry = RULE_INDEX.get(rule);
  return { rule, anchor, reason, class: entry ? entry.class : null, else_branch: false };
}

// The ONLY constructor in this module that stamps `else_branch: true`. Every
// call site is an arm reached by exhaustion. Adding a third else arm without
// routing it through here understates the census, which is why the arms are
// counted by the suite rather than trusted.
function elseBranchVerdict(rule, anchor, reason) {
  return { ...verdictFor(rule, anchor, reason), else_branch: true };
}

// classifyStatement(text) → { class, rule, anchor, reason } | null when the
// statement reads nothing (a bare `cd`, a loop keyword, an `echo`).
function classifyStatement(rawText) {
  const text = rawText.trim();
  if (text === "") return null;

  const head = headProgram(text);
  if (head === "") return null;
  if (NON_READ_HEADS.has(head)) return null;

  if (head === "ssh") {
    const host = findSshHost(text) ?? "a remote host";
    return verdictFor(
      "REMOTE-HOST-READ",
      host,
      `the read executes on ${host}, not in any local tree — it answers about ONE named box`,
    );
  }

  if (head === "gh") {
    return verdictFor(
      "FORGE-API-READ",
      "gh",
      "reads the forge API behind the remote this clone names; no local tree is consulted, but the repo is resolved from this checkout's remote",
    );
  }

  if (head === "git") {
    return classifyGitStatement(text);
  }

  // Network reads are settled BEFORE the absolute-path scan: a URL path that
  // survives scrubbing (`… "$BASE/v1/data/mutate/production"`) is not a
  // filesystem pin, and reading it as one mints a foreign-tree verdict out of
  // an HTTP route.
  if (NETWORK_HEADS.has(head)) {
    return verdictFor(
      "NETWORK-READ-NO-TREE",
      null,
      `\`${head}\` reads a running system or a network service, NOT a tree — none of D73's five classes describes that, so cwd-bound is a FLOOR here, not a finding`,
    );
  }

  const absolute = findAbsolutePath(text);
  if (absolute) {
    const rule = absolutePathRule(absolute);
    const reason = {
      "ABS-PATH-EPHEMERAL-WORKTREE": `pinned to ${absolute} — a worktree that will be pruned, so this answers about a tree that may not exist tomorrow`,
      "ABS-PATH-SCRATCH": `pinned to ${absolute} — scratch space on ONE box, written by a run that has ended; there is usually nothing left to re-read`,
      "ABS-PATH-PINNED": `pinned to ${absolute} — answers about THAT location from anywhere, and about nothing else`,
    }[rule];
    return verdictFor(rule, absolute, reason);
  }

  if (FS_READ_HEADS.has(head)) {
    return verdictFor(
      "RELATIVE-PATH-READ",
      null,
      `\`${head}\` reads the filesystem through a relative path — whatever the cwd contains is the answer`,
    );
  }

  if (TOOLCHAIN_HEADS.has(head)) {
    return verdictFor(
      "TOOLCHAIN-CWD-ROOTED",
      null,
      `\`${head}\` resolves its project root from the cwd, so the answer is about whichever checkout it was launched in`,
    );
  }

  return elseBranchVerdict(
    "DEFAULT-CWD-BOUND",
    null,
    `no rule fired for head \`${head}\` — this is the ELSE branch, and the verdict is a floor rather than a finding`,
  );
}

// The git family. Ref signals are collected and the LEAST portable one wins:
// `git rev-parse HEAD origin/main` is per-worktree because HEAD decides it, and
// `git merge-base --is-ancestor <sha> origin/main` is shared-ref because
// origin/main decides it — the SHA in it is not the answer's anchor.
function classifyGitStatement(text) {
  const subcommand = gitSubcommand(text);

  if (GIT_REMOTE_SUBCOMMANDS.has(subcommand)) {
    return verdictFor(
      "GIT-REMOTE-SERVER-OP",
      subcommand,
      `\`git ${subcommand}\` talks to the remote this clone names; its answer does not depend on which worktree ran it`,
    );
  }

  const signals = [];

  // Index / working-tree family. `git diff <rev>..<rev>` is a rev-to-rev read,
  // not an index read, so a range suppresses the diff arm.
  const hasRange = /[0-9A-Za-z_./-]\.\.\.?[0-9A-Za-z_./-]/.test(text);
  if (INDEX_BOUND_SUBCOMMANDS.has(subcommand) || (subcommand === "diff" && !hasRange)) {
    signals.push(
      verdictFor(
        "INDEX-BOUND-FAMILY",
        subcommand,
        `\`git ${subcommand}\` answers from the index and the working tree, and the index lives at .git/worktrees/<name>/index — it is not shared`,
      ),
    );
  }

  const headMatch = text.match(HEAD_REF);
  if (headMatch) {
    signals.push(
      verdictFor(
        "WORKTREE-HEAD-REF",
        headMatch[1],
        `${headMatch[1]} is per-worktree: every linked worktree carries its own, so this answers about the tree that ran it`,
      ),
    );
  }

  const localMatch = text.match(LOCAL_BRANCH_REF);
  const bareBranch = localMatch ? null : findBareBranch(text);
  if (localMatch || bareBranch) {
    const anchor = localMatch ? localMatch[1] : bareBranch;
    signals.push(
      verdictFor(
        "LOCAL-BRANCH-REF",
        anchor,
        `${anchor} is a LOCAL branch — refs/heads/* is shared among worktrees but is this clone's own claim about the remote, and a local checkout has run 200+ commits stale and lied silently`,
      ),
    );
  }

  const remoteMatch = text.match(REMOTE_REF);
  if (remoteMatch || UPSTREAM_SHORTHAND.test(text)) {
    const anchor = remoteMatch ? remoteMatch[1] : "@{u}";
    signals.push(
      verdictFor(
        "REMOTE-TRACKING-REF",
        anchor,
        `${anchor} lives in refs/remotes/*, which sits in the shared .git and is absent from .git/worktrees/<name>/ — identical from every worktree of THIS clone, and stale-inherited by any other clone (D75)`,
      ),
    );
  }

  if (subcommand === "grep" && signals.length === 0) {
    signals.push(
      verdictFor(
        "WORKTREE-CONTENT-SCAN",
        "grep",
        "`git grep` with no ref scans the WORKING TREE, so uncommitted edits are part of the answer",
      ),
    );
  }

  const sha = findSha(text);
  if (sha) {
    signals.push(
      verdictFor(
        "SHA-PIN-REVISION",
        sha,
        `pinned to object ${sha} — the same bytes in any clone on any box that has the object, which makes this the MOST portable form in the ladder (it fails loudly, rc 128, where the object is absent)`,
      ),
    );
  }

  if (signals.length === 0) {
    return elseBranchVerdict(
      "BARE-GIT-LOCAL-STATE",
      null,
      `\`git ${subcommand || "?"}\` names no ref, so git resolves it against THIS worktree's HEAD and config — the DEFAULT branch inside the git family`,
    );
  }

  signals.sort((a, b) => rankOf(b.class) - rankOf(a.class));
  return signals[0];
}

// --- exit masking ------------------------------------------------------------

function maskRuleForTail(segment) {
  const head = headProgram(segment);
  if (head === "wc") return "MASK-PIPE-EXIT-AND-VALUE";
  if (head === "grep" && /(?:^|\s)-[A-Za-z]*c/.test(segment)) return "MASK-PIPE-VALUE";
  return "MASK-PIPE-SILENT";
}

function readsSomething(segment) {
  const head = headProgram(segment);
  return head === "git" || head === "gh" || head === "ssh" || FS_READ_HEADS.has(head) || TOOLCHAIN_HEADS.has(head) || NETWORK_HEADS.has(head);
}

function computeExitMask(statementTexts, wholeMask) {
  if (/pipefail/.test(wholeMask)) {
    return {
      exit_masked: false,
      exit_mask_rule: null,
      note: "`set -o pipefail` is present, so the pipeline reports the READ's failure rather than the filter's",
    };
  }
  let worst = null;
  for (const text of statementTexts) {
    const segments = splitPipeline(text);
    if (segments.length < 2) continue;
    if (!readsSomething(segments[0])) continue;
    const rule = maskRuleForTail(segments[segments.length - 1]);
    if (worst === null || MASK_SEVERITY.indexOf(rule) < MASK_SEVERITY.indexOf(worst)) worst = rule;
  }
  if (worst === null) {
    return {
      exit_masked: false,
      exit_mask_rule: null,
      note: "the read's own exit status reaches the caller — a failure is loud",
    };
  }
  const detail = EXIT_MASK_RULES.find((entry) => entry.rule === worst);
  return { exit_masked: true, exit_mask_rule: worst, note: detail.what };
}

// --- classifyBinding ---------------------------------------------------------

const EMPTY_VERDICT = Object.freeze({
  binding_class: null,
  anchor: null,
  rule: "NO-COMMAND",
  portable_scope: "unknown",
  exit_masked: false,
  exit_mask_rule: null,
  reason: "there is no command to classify — a missing or prose rerun DEMOTES to unknown, it is never rejected and it is never guessed at",
  cd_prefix: null,
  // NO-COMMAND is a guard, not an else arm: it is reached because the input is
  // absent, never because the rules were exhausted on a real command.
  else_branch: false,
});

/**
 * classifyBinding(rerun) → a frozen verdict:
 *
 *   { binding_class, anchor, rule, portable_scope, exit_masked, exit_mask_rule,
 *     reason, cd_prefix }
 *
 * binding_class is one of BINDING_CLASSES for every real command, and null ONLY
 * for a missing/prose input (rule NO-COMMAND). Pure: no fs, no spawn, no clock.
 */
export function classifyBinding(rerun) {
  if (typeof rerun !== "string" || rerun.trim() === "") return EMPTY_VERDICT;
  const command = rerun.trim();
  if (looksLikeProse(command)) return EMPTY_VERDICT;

  const mask = maskQuoted(command);
  const spans = splitStatements(mask);

  let cdPrefix = null;
  const readTexts = [];
  const verdicts = [];

  for (const [from, to] of spans) {
    const rawStatement = command.slice(from, to).trim();
    const maskStatement = mask.slice(from, to).trim();
    if (maskStatement === "") continue;

    if (isCdStatement(maskStatement)) {
      cdPrefix = cdPrefix ?? cdTarget(rawStatement);
      continue;
    }

    let text = rawStatement;
    if (headProgram(maskStatement) === "git") {
      const stripped = stripDashC(rawStatement);
      if (stripped.target) {
        cdPrefix = cdPrefix ?? stripped.target;
        text = stripped.text;
      }
    }

    // Everything downstream reads the MASKED statement. A `|` inside a quoted
    // grep pattern is not a pipeline: scanning the raw text splits
    // `grep -nE "foo|bar" x` into two segments and reports exit_masked on a
    // command with no pipe in it at all — a fabricated warning, which is the
    // one thing a module whose product is honest warnings cannot afford.
    const maskedText = maskQuoted(text);
    readTexts.push(maskedText);
    const readSegment = splitPipeline(maskedText)[0] ?? maskedText;
    const verdict = classifyStatement(readSegment);
    if (verdict) verdicts.push(verdict);
  }

  const mask_info = computeExitMask(readTexts, mask);

  if (verdicts.length === 0) {
    return Object.freeze({
      ...EMPTY_VERDICT,
      rule: "DEFAULT-CWD-BOUND",
      binding_class: "cwd-bound",
      portable_scope: PORTABLE_SCOPES["cwd-bound"],
      exit_masked: mask_info.exit_masked,
      exit_mask_rule: mask_info.exit_mask_rule,
      cd_prefix: cdPrefix,
      else_branch: true,
      reason: "no statement in this command reads anything the grammar recognises — this is the ELSE branch, and the verdict is a floor rather than a finding",
    });
  }

  // The floor: a compound is only as portable as its least portable read.
  //
  // But an ELSE branch never DECIDES a compound in which some other statement
  // matched a rule. A default verdict is a floor, and a floor that outranks a
  // fired rule is not caution, it is a wrong answer wearing caution's uniform:
  // letting one in demoted `git merge-base --is-ancestor <sha> origin/main &&
  // echo YES` to cwd-bound on 51 of the 652 corpus proofs.
  // Keyed on the ARM, not on the rule NAME. Reading `isDefaultRule(rule)` here
  // agreed with the arms on every input, but it agreed by CONVENTION: rename an
  // else arm's rule to one the registry marks `is_default: false` and the floor
  // rule silently starts letting else verdicts outrank rules that fired.
  const fired = verdicts.filter((verdict) => !verdict.else_branch);
  const weighed = fired.length > 0 ? fired : verdicts;
  const dropped = verdicts.length - weighed.length;

  weighed.sort((a, b) => rankOf(b.class) - rankOf(a.class));
  const decided = weighed[0];

  const parts = [decided.reason];
  if (weighed.length > 1) {
    parts.push(
      `${weighed.length} statements read something; the LEAST portable decided (a compound answer is only as portable as its weakest read)`,
    );
  }
  if (dropped > 0) {
    parts.push(
      `${dropped} further statement(s) matched no rule and did NOT decide — an else branch is a floor, never a verdict over a rule that fired`,
    );
  }
  if (cdPrefix) {
    parts.push(
      `a \`cd\`/\`-C\` prefix into ${cdPrefix} was recorded, not weighed — ref identity decides the class, path shape does not (D73)`,
    );
  }
  if (decided.class === "cwd-bound" && cdPrefix) {
    parts.push(`the cwd this answer depends on is supplied by that prefix — see cd_prefix`);
  }
  parts.push(mask_info.note);
  if (mask_info.exit_masked && /2>\s*\/dev\/null/.test(mask)) {
    parts.push("`2>/dev/null` also discards the read's stderr, so the diagnosis is gone too");
  }

  return Object.freeze({
    binding_class: decided.class,
    anchor: decided.anchor,
    rule: decided.rule,
    portable_scope: PORTABLE_SCOPES[decided.class],
    exit_masked: mask_info.exit_masked,
    exit_mask_rule: mask_info.exit_mask_rule,
    reason: parts.join("; "),
    cd_prefix: cdPrefix,
    else_branch: decided.else_branch === true,
  });
}

// --- classifyAll -------------------------------------------------------------

function commandOf(row) {
  if (typeof row === "string") return row;
  if (row && typeof row === "object") {
    if (typeof row.rerun === "string") return row.rerun;
    if (typeof row.command === "string") return row.command;
  }
  return "";
}

/**
 * classifyAll(rows) → a frozen census over strings, ledger rows ({rerun}) or
 * corpus proofs ({command}). Exported so the render slices group once rather
 * than each re-deriving the buckets.
 *
 * TWO READINGS OF ONE NUMBER, AND THE REASON THEY ARE BOTH HERE.
 *
 * `else_branch` is the number that matters: the share of verdicts that arrived
 * via an arm reached by exhaustion, counted off the `else_branch` stamp the arm
 * itself set. A high share means the grammar is absorbing, not discriminating,
 * and an accuracy figure beside it means nothing.
 *
 * `default_rule` is the same quantity read off the REGISTRY — `is_default` keyed
 * by rule NAME. It is kept because a rename is exactly what makes the two
 * disagree, and a disagreement is a defect a suite can see: point an else arm at
 * a rule the registry marks `is_default: false` and `default_rule` collapses
 * while `else_branch` does not move. Anything asserting a bound on this
 * classifier's else share must assert BOTH readings agree, or the bound is
 * satisfiable by editing a string.
 */
export function classifyAll(rows) {
  const list = Array.isArray(rows) ? rows : [];
  const by_class = {};
  for (const name of BINDING_CLASSES) by_class[name] = 0;
  const by_rule = {};
  const by_portable_scope = {};
  const by_exit_mask_rule = {};

  const verdicts = [];
  let unclassified = 0;
  let exit_masked = 0;
  let default_count = 0;
  let else_branch_count = 0;
  let cd_prefixed = 0;

  for (const row of list) {
    const command = commandOf(row);
    const verdict = classifyBinding(command);
    verdicts.push(verdict);

    if (verdict.binding_class === null) unclassified += 1;
    else by_class[verdict.binding_class] += 1;

    by_rule[verdict.rule] = (by_rule[verdict.rule] ?? 0) + 1;
    by_portable_scope[verdict.portable_scope] = (by_portable_scope[verdict.portable_scope] ?? 0) + 1;
    if (verdict.exit_masked) {
      exit_masked += 1;
      by_exit_mask_rule[verdict.exit_mask_rule] = (by_exit_mask_rule[verdict.exit_mask_rule] ?? 0) + 1;
    }
    if (isDefaultRule(verdict.rule)) default_count += 1;
    if (verdict.else_branch) else_branch_count += 1;
    if (verdict.cd_prefix) cd_prefixed += 1;
  }

  const total = list.length;
  const classified = total - unclassified;

  return Object.freeze({
    total,
    classified,
    unclassified,
    by_class: Object.freeze(by_class),
    by_rule: Object.freeze(by_rule),
    by_portable_scope: Object.freeze(by_portable_scope),
    exit_masked,
    by_exit_mask_rule: Object.freeze(by_exit_mask_rule),
    cd_prefixed,
    default_rule: Object.freeze({
      count: default_count,
      share: total === 0 ? 0 : default_count / total,
    }),
    else_branch: Object.freeze({
      count: else_branch_count,
      share: total === 0 ? 0 : else_branch_count / total,
    }),
    verdicts: Object.freeze(verdicts),
  });
}
