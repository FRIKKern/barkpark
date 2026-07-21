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
// Nothing in the repo already does this. record.mjs/level.mjs's findRefs and
// classifyRef need a literal `.ext:digits` suffix and score 0 on bare rerun
// commands; doc-truth's matchPath inspects only the FIRST whitespace token,
// which on a shell rerun is always the interpreter (`cd`, `node`, `git`).

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

/**
 * The repo path this token names, or null if it does not name one.
 * Exported so the defects can be tested one at a time.
 */
export function pathToken(rawToken) {
  let t = unwrap(rawToken);
  if (t === "" || t.startsWith("-")) return null;

  // `git show origin/main:tooling/grip/ledger.mjs` — the ref is not the
  // subject, the path after the colon is.
  const colon = t.indexOf(":");
  if (colon > 0) {
    const head = t.slice(0, colon);
    const tail = t.slice(colon + 1);
    if (REF_SEGMENTS.has(head.split("/")[0]) && tail !== "") t = tail;
  }

  t = stripRoots(t);
  if (t === "") return null;                                  // defect 1
  if (REF_SEGMENTS.has(t.split("/")[0])) return null;         // defect 2
  if (t.includes("..") || t.includes("~") || t.includes("*")) return null;
  if (!PATH_SHAPED.test(t)) return null;
  if (!t.includes("/") && !FILE_EXT.test(t)) return null;
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

/**
 * The command's normalised verb phrase: head plus the first sub-verb or flag.
 * `git ls-tree …` → `git:ls-tree`; `wc -l file` → `wc:-l`;
 * `node tooling/grip/ledger.mjs --selftest` → `node:--selftest`.
 *
 * Coarse and COLLIDABLE is correct here. quantity is the second half of the
 * conflict key, and minting it from claim prose makes the whole key injective
 * again — the exact failure D32 rejects for subject.
 */
export function quantityPhrase(rerun) {
  const toks = tokens(rerun);
  const { head, index } = headAt(toks);
  if (head === "") return "";
  for (let i = index + 1; i < toks.length; i += 1) {
    const t = unwrap(toks[i]);
    if (OPERATORS.has(t)) break;
    if (t.startsWith("--") || /^-[A-Za-z]/.test(t)) return `${head}:${t.split("=")[0]}`;
    if (/^[a-z][a-z0-9-]*$/.test(t)) return `${head}:${t}`;
  }
  return head;
}

/**
 * mintRecipe(fact, { observed_at }) →
 *   { ok: true, recipe, subject_source: "path-token" | "fallback" }
 * | { ok: false, reason }
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
  const paths = [];
  for (const t of toks) {
    const p = pathToken(t);
    if (p !== null && !paths.includes(p)) paths.push(p);
  }

  const { head } = headAt(toks);
  const subject = paths[0] ?? (head === "" ? "" : `cmd:${head}`);
  if (subject === "") return { ok: false, reason: "NO-SUBJECT" };

  const quantity = quantityPhrase(rerun);
  if (quantity === "") return { ok: false, reason: "NO-QUANTITY" };

  const recipe = { subject, quantity, rerun, deps: paths, observed_at };
  return { ok: true, recipe, subject_source: paths.length > 0 ? "path-token" : "fallback" };
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
