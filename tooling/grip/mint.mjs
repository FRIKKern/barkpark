// mint.mjs — turn a survey/verify FACT into a storable ledger RECIPE.
//
// The two schemas share NO field. A fact carries exactly {claim, evidence,
// rerun}; a ledger row's RECIPE_FIELDS is a frozen six-key allowlist
// {subject, quantity, rerun, derived_level, deps, observed_at}. Fed raw to
// admitRecipe, every fact quadruple-rejects: UNKNOWN-FIELD on `claim`,
// UNKNOWN-FIELD on `evidence`, MISSING-SUBJECT, MISSING-QUANTITY. So this is a
// TRANSFORMER, never a pass-through: it MINTS subject and quantity out of the
// rerun command and DROPS claim and evidence.
//
// WHY THE COMMAND AND NOT THE PROSE (charter D32, re-measured on this wave's
// 119 rerun-bearing facts). A subject minted from claim prose gives 119
// distinct keys for 119 facts — perfectly injective, which means the fold's
// (subject, quantity) key can never collide, RIVAL-METHOD can never fire, and
// nothing in the index is ever a LEAD to anything else. A dead index that
// looks full. The rerun's path token gives 51 distinct keys for the same 119
// facts: it CLUSTERS, which is the entire point of an index.
//
// FOUR MEASURED DEFECTS a literal reading of D32 walks straight into, each
// with a test in test/mint.test.mjs:
//   1. REPO ROOT. Nearly every rerun opens `cd <repo root> && …`. A naive
//      "first token containing a slash" mints the repo ROOT for 35 of 119
//      facts — one garbage key that inflates shared-coverage. Strip repo AND
//      worktree roots, and when the strip leaves nothing, KEEP SCANNING.
//   2. REVSPECS. `origin/main` and `loop-epic/<branch>` are slash-bearing and
//      are not paths. They mint as false subjects unless excluded by name.
//   3. TRAILING SLASH. `tooling/grip/` and `tooling/grip` are one subject and
//      must not become two keys.
//   4. GREP ANCHORS AND QUOTES. `'^tooling/grip/harvest.mjs'` mints a key that
//      can never collide with the clean one — a silent index-splitter.
//
// FOUR MORE, measured on the frozen 652-proof corpus in wave 5 and fixed here:
//   5. THE TRAVERSAL GUARD WAS UNTESTED. `t.includes("..")` had no test in
//      either direction, and defect 6 relaxes exactly that line. An untested
//      guard is indistinguishable from a deleted one, so it is pinned first.
//   6. THE GO PACKAGE WILDCARD. `./internal/cli/...` minted NOTHING: stripRoots
//      leaves `internal/cli/...` and the traversal guard fires on the ELLIPSIS.
//      Go was the worst family in the corpus at 24.2% path-token yield (8/33),
//      and 25 of its 33 commands carry the glob. level.mjs already special-cases
//      this exact idiom as "a Go package wildcard, NOT an elision"; pathToken
//      never learned it. Stripping a TRAILING `/...` lifts go to 90.9%.
//   7. TOP-LEVEL DIRECTORIES MINTED NOTHING. `api/`, `js/`, `web/`, `docs/`,
//      `deploy/`, `scaffy/` are single-segment and extensionless, so they failed
//      the separatorless check and fell back to `cmd:<head>` — which D45
//      EXCLUDES from leads. The repo's own subsystem names, precisely the coarse
//      terms an agent types, could never be subjects. The fix is NOT to accept
//      bare words (`test`, `install` are verbs, and the mint holds no repo
//      listing to tell them apart) but to accept the ones that WORE a path
//      marker: a trailing `/`, a `./` prefix, or a `/...` package glob.
//   8. THE QUANTITY MINTED THE FLAG, NOT THE PROPERTY. `grep -c 'needs_worktree'`
//      and `grep -c 'isolation'` both minted `grep:-c`, so the fold announced
//      that two recipes "re-derive the same quantity" when they answer different
//      questions — a FABRICATED RIVAL-METHOD. Worse, `git show P | wc -l` and
//      `git show P | grep -c x` both minted `git:show`, flagging a line count as
//      a rival of a match count. Over the corpus, 58 keys absorbed 261 rows
//      (40%). Two facts about a property fix it: it is produced by the LAST
//      measuring stage of a pipeline (the earlier stages only supply bytes), and
//      a match count is a count OF a pattern, so the pattern belongs in the key.
//      NOT a licence to make every quantity unique: a unique quantity kills
//      RIVAL-METHOD (D32/D33) exactly as a prose-derived subject would, and the
//      test file carries a CONTROL — `wc -l F` and `cat F | wc -l` are different
//      methods for one property and MUST still collide.
//
// AND ONE MORE, surfaced by the wave-11 regression floor and fixed here:
//   9. THE `cd` MOVED THE ROOT AND THE SUBJECT DID NOT MOVE WITH IT. Defect 1
//      strips a checkout root, which is right — but `cd <checkout>/api && mix
//      test test/x_test.exs` moves the cwd to a SUBDIRECTORY, and the mint went
//      on reading `test/x_test.exs` as if it were repo-rooted. In a repo-rooted
//      store that key resolves to nothing: the row indexes a path that does not
//      exist. See `cdRootOffset` for the one shape this reads and the two it
//      deliberately refuses.
//
// Nothing in the repo already does this. record.mjs/level.mjs's findRefs and
// classifyRef need a literal `.ext:digits` suffix and score 0 on bare rerun
// commands; doc-truth's matchPath inspects only the FIRST whitespace token,
// which on a shell rerun is always the interpreter (`cd`, `node`, `git`).

import { classifyBinding } from "./binding.mjs";

// Roots to strip off an absolute token. The worktree pattern is tried first
// because it is the longer match and a worktree path also contains the
// checkout pattern. Both are matched against the token with a trailing slash
// appended, so a BARE root (`cd /…/barkpark`) strips to the empty string and
// is skipped rather than becoming subject #1.
const ROOT_PATTERNS = [
  /^.*?\/\.claude\/worktrees\/[^/]+\//,
  /^.*?\/github\/barkpark\//,
];

// Slash-bearing tokens that are refs, not paths (defect 2). Matched on the
// FIRST path segment, so `loop-epic/anything` and `origin/main` both go.
const REF_SEGMENTS = new Set(["origin", "upstream", "refs", "remotes", "HEAD", "loop-epic"]);

// A token that survived stripping still has to LOOK like a repo path: a
// relative path with no shell punctuation left in it.
const PATH_SHAPED = /^[A-Za-z0-9._][A-Za-z0-9._/-]*$/;

// A SEPARATORLESS token needs a real file extension to count as a path, and
// the check has to be an allowlist rather than "ends in a dot-word". Found by
// this slice's own test: `grep -c 'Date.now' …` quoted a dotted IDENTIFIER,
// and a generic /\.[A-Za-z0-9]+$/ minted `Date.now` as a subject — a bare
// symbol name sitting in the index next to real files. Same family as the four
// measured defects: the write succeeds and the key is quietly wrong.
const FILE_EXT = /\.(mjs|cjs|js|jsx|ts|tsx|ex|exs|heex|eex|json|md|ya?ml|toml|sh|bash|zsh|go|rs|py|rb|css|scss|html|sql|txt|lock|env|svg|png|ico)$/i;

// Shell operators between commands.
const OPERATORS = new Set(["&&", "||", "|", ";", "&"]);

// Prefixes that wrap the real command. `cd` additionally swallows the single
// argument after it — that argument is a directory, never a head.
const WRAPPERS = new Set(["sudo", "env", "time", "nohup", "exec"]);

function unwrap(token) {
  let t = token.trim();
  // quotes (defect 4) — leading/trailing, including the shell's own escaping
  t = t.replace(/^['"`]+/, "").replace(/['"`]+$/, "");
  // grep anchors (defect 4) and regex tails
  t = t.replace(/^\^+/, "").replace(/\$+$/, "");
  // trailing shell/prose punctuation
  t = t.replace(/[,;)]+$/, "").replace(/^[(]+/, "");
  return t;
}

// An absolute token minus every root we know about. Returns "" when the token
// WAS a root — the caller must keep scanning (defect 1).
function stripRoots(token) {
  const probe = token.endsWith("/") ? token : `${token}/`;
  for (const re of ROOT_PATTERNS) {
    const m = probe.match(re);
    if (m) return probe.slice(m[0].length).replace(/\/+$/, "");
  }
  // defect 3 (trailing slash) and its twin, the `./` prefix — `tooling/grip/`,
  // `tooling/grip` and `./tooling/grip` are ONE subject or the index splits
  // three ways on punctuation alone.
  return token.replace(/^(?:\.\/)+/, "").replace(/\/+$/, "");
}

// A Go package wildcard SUFFIX (defect 6). Anchored at the end and requiring a
// separator, so `./internal/cli/...` yields a directory while a bare `./...`
// yields nothing to extract and stays null.
const GO_PKG_SUFFIX = /\/\.\.\.$/;

// The marks that make a single-segment token a DIRECTORY rather than a bare
// word (defect 7): a trailing slash, a leading `./`, or a package glob. Read
// off the token BEFORE stripRoots, which erases all three.
function wearsPathMarker(t) {
  return t.endsWith("/") || /^\.\//.test(t) || GO_PKG_SUFFIX.test(t);
}

/**
 * The repo path this token names, or null if it does not name one.
 * Exported so the defects can be tested one at a time.
 *
 * `cdOffset` is the repo-root-relative directory a leading `cd` moved into
 * (see `cdRootOffset`). When it is set, a token the SHELL would resolve
 * against that cwd is carried back to the repo root — defect 9 below.
 */
export function pathToken(rawToken, { cdOffset = null } = {}) {
  let t = unwrap(rawToken);
  if (t === "" || t.startsWith("-")) return null;

  // Read BEFORE any rewriting: an absolute token is resolved by the FILESYSTEM,
  // so no `cd` can change what it names, and stripRoots already anchors it to
  // the repo root. Carrying an offset onto it would double the prefix.
  const absolute = t.startsWith("/");

  // `git show origin/main:tooling/grip/ledger.mjs` — the ref is not the
  // subject, the path after the colon is.
  let refQualified = false;
  const colon = t.indexOf(":");
  if (colon > 0) {
    const head = t.slice(0, colon);
    const tail = t.slice(colon + 1);
    if (REF_SEGMENTS.has(head.split("/")[0]) && tail !== "") { t = tail; refQualified = true; }
  }

  const marked = wearsPathMarker(t);                          // defect 7

  t = stripRoots(t);
  // defect 6 — a Go package wildcard is a DIRECTORY, not a traversal. Stripped
  // AFTER the roots (so `<repo>/internal/cli/...` normalises to the same key)
  // and BEFORE the `..` guard (which is what was rejecting it). Suffix-only: an
  // ellipsis anywhere else in the path is still refused below.
  t = t.replace(GO_PKG_SUFFIX, "");
  if (t === "") return null;                                  // defect 1
  if (REF_SEGMENTS.has(t.split("/")[0])) return null;         // defect 2
  if (t.includes("..") || t.includes("~") || t.includes("*")) return null;
  if (!PATH_SHAPED.test(t)) return null;
  // defect 7 — a separatorless token is a path when it carries a real file
  // extension OR when it WORE a directory marker. A bare word carries neither
  // and stays null: the mint has no repo listing and must not guess.
  //
  // THE PRICE OF THAT, MEASURED RATHER THAN ASSUMED. Enumerating every
  // single-segment subject this yields over the frozen 652-proof corpus returns
  // 42, of which exactly six are extensionless and therefore new here: `api`,
  // `cloud`, `internal` and `lib`, `src`, `sizer`. The first three are the
  // repo's real top-level names and are exactly the coarse terms defect 7
  // exists to recover. The last three are RELATIVE names — they reach the mint
  // from a `cd api && … lib/`-shaped command, so `lib` conflates `api/lib`
  // with every other `lib/` in the tree.
  //
  // That conflation is ACCEPTED, not overlooked, and the reasoning is the same
  // sentence as above: separating them needs a repo listing, and a mint that
  // holds one guesses. It is also strictly better than what it replaced — the
  // alternative was `cmd:<head>`, which is coarser still AND excluded from
  // leads by D45, i.e. no lead at all. The bound a reader needs is that a
  // single-segment subject is a NAME, never a location.
  if (!t.includes("/") && !FILE_EXT.test(t) && !marked) return null;

  // defect 9 (tgw11) — the `cd` that MOVED THE ROOT. See `cdRootOffset`. Three
  // token shapes are exempt and each for its own reason:
  //   • ABSOLUTE — resolved by the filesystem, already root-anchored above.
  //   • REF-QUALIFIED — in `git show <rev>:<path>`, a `<path>` that does not
  //     begin `./` is relative to the REPO ROOT, not to the cwd, so git itself
  //     already answers root-relative and a carry would fabricate a directory.
  //   • no offset — no leading `cd`, or one this mint refuses to read (below).
  if (cdOffset && !absolute && !refQualified) return `${cdOffset}/${t}`;
  return t;
}

function tokens(rerun) {
  return String(rerun ?? "").trim().split(/\s+/).filter(Boolean);
}

// The head of the command that actually does the work, and the index it sat
// at. `cd <dir> && node …` is a `node` command, not a `cd` command — and this
// is exactly where doc-truth's matchPath fails on grip-shaped reruns: it reads
// only token 0, which here is always `cd`.
function headAt(toks) {
  let i = 0;
  while (i < toks.length) {
    const t = unwrap(toks[i]);
    if (t === "" || OPERATORS.has(t) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) { i += 1; continue; }
    if (t === "cd") { i += 2; continue; }          // `cd` swallows its directory
    if (WRAPPERS.has(t)) { i += 1; continue; }
    // An interpreter invoked by path (`./scripts/x.sh`, `/usr/bin/clang`) is
    // still a head; the basename is the verb.
    return { head: t.includes("/") ? t.slice(t.lastIndexOf("/") + 1) : t, index: i };
  }
  return { head: "", index: -1 };
}

// Commands that RESHAPE bytes without deriving a property (defect 8). When one
// of these ends a pipeline the measurement happened upstream, so the stage scan
// walks back past it — unless it is the whole command, where `head -20 f` IS
// what the operator asked for.
const FORMATTERS = new Set(["head", "tail", "cat", "less", "more", "tee", "column", "sort", "tr", "xargs", "pbcopy", "fold", "cut", "rev", "nl"]);

// Tools whose answer is a count/list OF A PATTERN, so the pattern is half the
// property (defect 8).
const MATCHERS = new Set(["grep", "egrep", "fgrep", "rg", "ag", "ack"]);

// Long spellings of grep flags that name the same property as the short one. A
// key that splits on spelling alone splits one rival into two (defect 8).
const MATCHER_FLAG_ALIASES = new Map([
  ["--count", "-c"],
  ["--line-number", "-n"],
  ["--files-with-matches", "-l"],
  ["--files-without-match", "-L"],
  ["--recursive", "-r"],
  ["--ignore-case", "-i"],
  ["--invert-match", "-v"],
  ["--word-regexp", "-w"],
  ["--only-matching", "-o"],
  ["--fixed-strings", "-F"],
  ["--extended-regexp", "-E"],
]);

// Matcher flags that consume the NEXT token as a value, so that token is not
// the pattern. `-e`/`--regexp` are the exception: their value IS the pattern.
const MATCHER_VALUE_FLAGS = new Set(["-A", "-B", "-C", "-m", "-f", "-d", "-t", "-g", "--after-context", "--before-context", "--context", "--max-count", "--file", "--include", "--exclude", "--exclude-dir", "--type", "--glob", "--devices"]);
const MATCHER_PATTERN_FLAGS = new Set(["-e", "--regexp"]);

/**
 * Split a command on PIPE boundaries only, respecting quotes and escapes, and
 * never splitting on `||` — a `|` inside `grep -c 'a|b'` is an alternation and
 * a `||` is a logical operator, neither of them a stage boundary.
 */
function pipelineStages(rerun) {
  const s = String(rerun ?? "");
  const out = [];
  let cur = "";
  let quote = null;
  for (let i = 0; i < s.length; i += 1) {
    const ch = s[i];
    if (quote) {
      cur += ch;
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "\\") { cur += ch + (s[i + 1] ?? ""); i += 1; continue; }
    if (ch === "'" || ch === '"' || ch === "`") { quote = ch; cur += ch; continue; }
    if (ch === "|") {
      if (s[i + 1] === "|") { cur += "||"; i += 1; continue; }
      out.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  out.push(cur);
  return out;
}

/** Whitespace tokens with quoting respected — a quoted pattern stays ONE token. */
function shellSplit(str) {
  const s = String(str ?? "");
  const out = [];
  let cur = "";
  let quote = null;
  let started = false;
  for (let i = 0; i < s.length; i += 1) {
    const ch = s[i];
    if (quote) {
      if (ch === quote) { quote = null; continue; }
      cur += ch;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === "`") { quote = ch; started = true; continue; }
    if (ch === "\\") { cur += s[i + 1] ?? ""; i += 1; started = true; continue; }
    if (/\s/.test(ch)) {
      if (started || cur !== "") out.push(cur);
      cur = "";
      started = false;
      continue;
    }
    cur += ch;
    started = true;
  }
  if (started || cur !== "") out.push(cur);
  return out;
}

/**
 * The pipeline stage that produces the NUMBER — the last one that is not a pure
 * formatter. `git show P | wc -l` measures with `wc`, not with `git show`.
 */
function measuringStage(rerun) {
  const stages = pipelineStages(rerun);
  for (let i = stages.length - 1; i >= 0; i -= 1) {
    const stage = stages[i].trim();
    if (stage === "") continue;
    const { head } = headAt(tokens(stage));
    if (head === "") continue;
    if (i > 0 && FORMATTERS.has(head)) continue;
    return stage;
  }
  return String(rerun ?? "").trim();
}

// The pattern a matcher is counting, normalised: quotes already removed by
// shellSplit, whitespace collapsed, and bounded so one long regex cannot become
// the whole key. Anchors are KEPT — unlike the subject (defect 4), `^import`
// and `import` are different questions.
function matcherPattern(stage) {
  // Re-headed in ARGV space: a quoted pattern is one shellSplit token but
  // several whitespace tokens, so the two index spaces cannot be shared.
  const args = shellSplit(stage);
  const { index: headIndex } = headAt(args);
  if (headIndex < 0) return null;
  for (let i = headIndex + 1; i < args.length; i += 1) {
    const a = args[i];
    if (MATCHER_PATTERN_FLAGS.has(a)) {
      const p = args[i + 1];
      return p === undefined ? null : normalisePattern(p);
    }
    if (a.startsWith("--") && a.includes("=")) continue;
    if (MATCHER_VALUE_FLAGS.has(a)) { i += 1; continue; }
    if (a.startsWith("-") && a !== "-") continue;
    return normalisePattern(a);
  }
  return null;
}

function normalisePattern(raw) {
  const p = String(raw).trim().replace(/\s+/g, " ");
  if (p === "") return null;
  return p.length > 40 ? p.slice(0, 40) : p;
}

/**
 * The property the command derives: the measuring stage's verb phrase — head
 * plus the first sub-verb or flag — and, for a matcher, the pattern it counts.
 * `git ls-tree …` → `git:ls-tree`; `wc -l file` → `wc:-l`;
 * `node tooling/grip/ledger.mjs --selftest` → `node:--selftest`;
 * `grep -c 'isolation' f` → `grep:-c:isolation`.
 *
 * Coarse and COLLIDABLE is still correct here — a quantity unique per command
 * kills RIVAL-METHOD exactly as a prose-derived subject would (D32/D33). What
 * changed is only that it collides on the PROPERTY rather than on the flag.
 */
export function quantityPhrase(rerun) {
  const stage = measuringStage(rerun);
  const toks = tokens(stage);
  const { head, index } = headAt(toks);
  if (head === "") return "";

  const isMatcher = MATCHERS.has(head);
  let phrase = head;
  for (let i = index + 1; i < toks.length; i += 1) {
    const t = unwrap(toks[i]);
    if (OPERATORS.has(t)) break;
    if (t.startsWith("--") || /^-[A-Za-z]/.test(t)) {
      const flag = t.split("=")[0];
      phrase = `${head}:${isMatcher ? MATCHER_FLAG_ALIASES.get(flag) ?? flag : flag}`;
      break;
    }
    // A matcher's first bare argument is its PATTERN, never a sub-verb — it is
    // appended below and must not also be read as the verb phrase.
    if (isMatcher) break;
    if (/^[a-z][a-z0-9-]*$/.test(t)) { phrase = `${head}:${t}`; break; }
  }

  if (!isMatcher) return phrase;
  const pattern = matcherPattern(stage);
  return pattern === null ? phrase : `${phrase}:${pattern}`;
}

// ── binding the recipe to the CALLER's tree (charter D73/D74, slice tgw6) ─────
//
// A rerun harvested as `cd <absolute checkout> && <cmd>` bakes a hard path to ONE
// box into the stored recipe. For most reads that path is load-bearing — a bare
// `wc -l x` answers about whatever tree you stand in, `git show HEAD:x` about
// whichever worktree ran it — so it MUST be kept, or the recipe silently starts
// measuring a different thing. But when the answer is decided by a REF rather
// than by the working tree (`git show <sha>:x`, `git show origin/main:x`), the
// `cd` provably cannot change the result, and storing it pins a PORTABLE recipe
// to a checkout that will be pruned. This strips the leading `cd <absolute> && `
// in exactly that case and only that case.
//
// It does NOT restate the invariance rule — it IMPORTS it. `classifyBinding`
// (binding.mjs) is the single authority on whether the remainder is ref-decided;
// a second regex written here to re-decide content-addressed vs per-worktree is
// precisely the hand-copied-grammar defect this epic exists to abolish. The only
// thing owned locally is the mechanical shape of the prefix being removed.

// The ONLY prefix shape this touches: a leading `cd <target> && `. The target may
// be single- or double-quoted. Everything past the first `&&` is the remainder,
// handed to classifyBinding verbatim and never itself rewritten.
const LEADING_CD = /^cd\s+('[^']*'|"[^"]*"|\S+)\s+&&\s+/;

// ── the `cd` that moved the ROOT (defect 9, tgw11) ───────────────────────────
//
// The strip above is about the STORED RERUN. This is about the SUBJECT, and the
// two are independent: `bindToCaller` decides whether the prefix survives into
// the row, `cdRootOffset` decides what the prefix means for the index.
//
// A rerun of the form `cd <checkout>/api && mix test test/x_test.exs` names a
// file at `api/test/x_test.exs` in a repo-rooted store. The mint read the bare
// token and derived `test/x_test.exs` — a key that resolves to NOTHING from the
// repo root, so the row indexes a path that does not exist and can never be a
// lead to the file it actually measured. The `cd` moved the root; the subject
// did not move with it.
//
// WHAT THIS READS AND WHAT IT REFUSES TO READ. It reads exactly one shape: an
// ABSOLUTE target that `stripRoots` recognises as a known checkout root plus a
// non-empty remainder. Two other shapes are deliberately left alone:
//
//   • a BARE RELATIVE target (`cd api && …`). A relative target means nothing
//     without the cwd it was typed in, and a recipe does not record a cwd. This
//     is not hypothetical: the committed corpus carries `cd barkpark && git
//     grep … -- api/lib`, where the target is the REPOSITORY ITSELF reached
//     from its parent. Carrying it would mint `barkpark/api/lib` — a directory
//     that has never existed. One counter-example in the live store is enough:
//     the mint holds no repo listing and must not guess which relative names
//     are subdirectories (the same sentence defect 7 is built on).
//
//   • a FOREIGN ABSOLUTE target with no recognisable checkout root
//     (`cd /Users/…/Documents/GitHub/barkpark/api && …`, `cd /tmp && …`). The
//     offset is unknowable, so behaviour is UNCHANGED: `stripRoots` leaves the
//     target absolute, `PATH_SHAPED` refuses it, the target mints nothing, and
//     every other token mints exactly as it does today with no prefix carried.
//
// The residual is named rather than hidden: under those two shapes a
// subdirectory-relative subject is still minted, exactly as before this change.

/**
 * The repo-root-relative directory a leading `cd` moved into, or null when the
 * command has no leading `cd`, when the target IS the checkout root (nothing
 * moved), or when the target is a path this mint cannot anchor.
 */
export function cdRootOffset(rerun) {
  const m = String(rerun ?? "").match(LEADING_CD);
  if (!m) return null;
  const target = m[1].replace(/^['"]/, "").replace(/['"]$/, "");
  if (!target.startsWith("/")) return null;   // relative: the cwd is not recorded
  const offset = stripRoots(target);
  if (offset === "" || offset.startsWith("/")) return null;  // the root itself, or foreign
  return offset;
}

/**
 * bindToCaller(rerun) → { rerun, rebound, binding_class, reason }
 *
 * Strips a leading `cd <ABSOLUTE> && ` prefix iff classifyBinding rates the
 * REMAINDER content-addressed or shared-ref. Otherwise the rerun is returned
 * untouched with the reason it was KEPT recorded. Never inspects or alters
 * subject/deps — those are minted from the original command by the caller, which
 * is what makes this transform a provable no-op over the index.
 */
function bindToCaller(rerun) {
  const m = rerun.match(LEADING_CD);
  if (!m) return { rerun, rebound: false, binding_class: null, reason: null };

  const target = m[1].replace(/^['"]/, "").replace(/['"]$/, "");
  // The invariance argument is about an ABSOLUTE checkout pin. A relative `cd api`
  // is a different, narrower case and is left alone here.
  if (!target.startsWith("/")) return { rerun, rebound: false, binding_class: null, reason: null };

  const remainder = rerun.slice(m[0].length);
  const verdict = classifyBinding(remainder);
  const klass = verdict.binding_class;

  if (klass === "content-addressed" || klass === "shared-ref") {
    return {
      rerun: remainder,
      rebound: true,
      binding_class: klass,
      reason: `stripped \`cd ${target} &&\` — classifyBinding rates the remainder ${klass} (${verdict.rule}): the answer is decided by ${verdict.anchor ?? "a ref"} and re-derives identically from ${verdict.portable_scope}, so the cd cannot change it`,
    };
  }
  return {
    rerun,
    rebound: false,
    binding_class: klass,
    reason: `kept \`cd ${target} &&\` — classifyBinding rates the remainder ${klass} (${verdict.rule}): the cwd/tree IS this answer's binding, so stripping it would silently change what the recipe measures`,
  };
}

/**
 * mintRecipe(fact, { observed_at }) →
 *   { ok: true, recipe, subject_source: "path-token" | "fallback", binding }
 * | { ok: false, reason }
 *
 * `binding` is { class, rebound, reason }: the recorded verdict of the caller-tree
 * rebind, kept OFF the recipe itself so RECIPE_FIELDS stays the frozen six-key
 * allowlist (D74) — an extra key on `recipe` would be UNKNOWN-FIELD at admit.
 *
 * `derived_level` is deliberately NOT minted: admitRecipe derives it from the
 * rerun alone, and a supplied value is only ever a ceiling-checked claim (D2).
 * `claim` and `evidence` are DROPPED — they are UNKNOWN-FIELD by design, and
 * a store that carried the prose would be carrying the value.
 */
export function mintRecipe(fact, { observed_at } = {}) {
  const rerun = typeof fact?.rerun === "string" ? fact.rerun.trim() : "";
  if (rerun === "") return { ok: false, reason: "NO-RERUN" };

  const toks = tokens(rerun);
  const cdOffset = cdRootOffset(rerun);        // defect 9
  const paths = [];
  for (const t of toks) {
    const p = pathToken(t, { cdOffset });
    if (p !== null && !paths.includes(p)) paths.push(p);
  }

  const { head } = headAt(toks);
  const subject = paths[0] ?? (head === "" ? "" : `cmd:${head}`);
  if (subject === "") return { ok: false, reason: "NO-SUBJECT" };

  const quantity = quantityPhrase(rerun);
  if (quantity === "") return { ok: false, reason: "NO-QUANTITY" };

  // subject, quantity and deps are all minted from the ORIGINAL command above.
  // Only the STORED rerun is rebound — so the REBIND can never move a row's
  // subject or deps, which is the provable no-op the regression floor asserts.
  // (Defect 9 does move some rows, and does so from the original command too;
  // the floor names that class explicitly rather than relaxing the assertion.)
  const bound = bindToCaller(rerun);

  const recipe = { subject, quantity, rerun: bound.rerun, deps: paths, observed_at };
  return {
    ok: true,
    recipe,
    subject_source: paths.length > 0 ? "path-token" : "fallback",
    binding: { class: bound.binding_class, rebound: bound.rebound, reason: bound.reason },
  };
}

/**
 * mintAll(facts, { observed_at }) → { recipes, skipped, yield }
 *
 * `yield` reports PATH-TOKEN yield and FALLBACK yield as SEPARATE numbers, and
 * the caller must name which one it quotes (D53). The two get conflated in one
 * direction only: quoting the union as coverage. Measured on this wave, the
 * path-token yield is ~76% of rerun-bearing facts; the union with the `cmd:`
 * fallback is 97.5%, but the fallback was designed as a FLOOR that keeps the
 * verb from ever reporting 100% REJECTED — it is not path coverage, and
 * quoting it as such is the very over-claim this epic exists to retire.
 */
export function mintAll(facts, { observed_at } = {}) {
  const list = Array.isArray(facts) ? facts : [];
  const recipes = [];
  const skipped = [];
  let pathToken_ = 0;
  let fallback = 0;

  list.forEach((fact, index) => {
    const minted = mintRecipe(fact, { observed_at });
    if (!minted.ok) {
      skipped.push({ index, reason: minted.reason });
      return;
    }
    recipes.push(minted.recipe);
    if (minted.subject_source === "path-token") pathToken_ += 1;
    else fallback += 1;
  });

  const rerunBearing = pathToken_ + fallback;
  const pct = (n) => (rerunBearing === 0 ? 0 : Math.round((n / rerunBearing) * 1000) / 10);
  return {
    recipes,
    skipped,
    yield: {
      facts: list.length,
      rerun_bearing: rerunBearing,
      path_token: pathToken_,
      path_token_pct: pct(pathToken_),
      fallback,
      fallback_pct: pct(fallback),
      distinct_subjects: new Set(recipes.map((r) => r.subject)).size,
    },
  };
}
