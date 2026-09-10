// spellings.mjs — PDS-D390. THE FOUR FORBIDDEN SPELLINGS, EACH REFUSED WITH A
// NAMED LEGAL SUBSTITUTE.
//
// WHY THIS LAYER EXISTS AT ALL, GIVEN grip ALREADY HAS A SCREEN. Measured on
// this host against grip's shipped `screenCommand` (2026-07-31, zero grip bytes
// changed):
//
//   git -C /tmp show origin/main:README.md   REFUSED — "git sub-verb \"/tmp\"
//                                            is not on the read-only allowlist"
//   git -C log push origin main              **ADMITTED**
//
// That is not a near-miss. grip's git rule reads the token AFTER `-C` as the
// sub-verb, so a caller who spells the path as a verb name walks a `push`
// straight through a read-only screen. It is simultaneously an OVER-refusal
// (the honest `git -C <dir> show` read) and an UNDER-refusal (the write). PDS
// does not patch it — tooling/grip belongs to the truth-grip epic and is not
// sealed — so PDS refuses the whole `git -C` shape one layer up, in its OWN
// tree, and says what to write instead.
//
// The other three are refused by grip too, but for reasons that do not tell an
// author what to do:
//   test -f <p>              → "unknown command head \"test\"" (true, useless)
//   … $( … ) …               → "shell metacharacter: command substitution"
//   git merge-base --is-ancestor A B
//                            → "write shape: git write verb" — grip's write
//                              scan matches the PREFIX `merge` inside
//                              `merge-base`. The refusal is CORRECT-BY-ACCIDENT
//                              and its stated reason is false. PDS will not
//                              patch another epic's module to fix a message, so
//                              it states the true reason itself.
//
// EVERY REFUSAL NAMES A SUBSTITUTE THAT WAS MEASURED POLARISED ON THIS HOST.
// A refusal with no legal alternative is how an honest author is pushed back
// into prose — which is the failure this whole slice exists to reverse.
//
// Pure. No I/O, no execution, never terminates the process. ESM named exports only.

// A substitute is only listed here after it was RUN and seen to change rc — AND
// seen to survive grip's silence rule, which is a second, sharper filter.
//
// MEASURED 2026-07-31, AND IT COST TWO SPELLINGS. The two predicates the wave
// brief named as "legal and proven polarised" ARE polarised at the shell:
//
//   git cat-file -e origin/main:<path>              rc 0 present / 128 absent
//   git rev-list --count A..B | grep -qx 0          rc 0 true    /   1 false
//
// and grip's SCREEN admits both. But grip's `classifySilence` then rules both
// NULL-READ — "the fetch exited 0 but returned no bytes", "grep exited 0
// (match) yet produced no output" — because each of them answers with the exit
// code and DELIBERATELY prints nothing, and grip's rule that a silent success
// is a broken read has no exception for a predicate that is silent by design.
// So the two best-polarised spellings in the grammar arrive at the verdict
// layer saying nothing at all.
//
// PDS DOES NOT PATCH grip FOR THIS (the fence is absolute, and the fix belongs
// to the epic that owns rerun.mjs — filed as pds-w28-bl-grip-silent-predicate-
// null-read). It changes the ADVICE instead: the substitutes below are the
// spellings that keep the polarity AND print, so they survive end to end.
//
//   git cat-file -t origin/main:<path>   "blob" rc 0  /  rc 128 "does not exist
//                                        in 'origin/main'" → grip PATH-GONE →
//                                        FAILED, which is a real absence answer
//   … | grep -x 0                        prints "0" rc 0 / no match rc 1
export const LEGAL_SUBSTITUTES = Object.freeze({
  ANCESTRY: "git rev-list --count origin/main..<sha> | grep -x 0",
  EXISTENCE: "git cat-file -t origin/main:<path>",
  CONTENT: "git grep -n <token> origin/main -- <path>",
});

// The polarised-but-SILENT spellings. Legal, screened, and discarded downstream
// as NULL-READ. Named so an author who reaches for one is told why it went
// quiet instead of being left to read "null read" and conclude the tool is broken.
export const SILENT_PREDICATES = Object.freeze([
  "git cat-file -e origin/main:<path>",
  "git rev-list --count origin/main..<sha> | grep -qx 0",
]);

// `git branch --contains <sha>` and `git rev-list --count <sha>..origin/main`
// LOOK like ancestry predicates and are not: both exit 0 for an ancestor AND a
// non-ancestor, so neither can ever red. They are listed as traps, never as
// substitutes.
export const NOT_PREDICATES = Object.freeze([
  "git branch --contains <sha>",
  "git rev-list --count <sha>..origin/main",
]);

/** Tokens of a segment with leading VAR=value assignments stripped. */
function tokens(segment) {
  const all = String(segment).trim().split(/\s+/).filter(Boolean);
  let i = 0;
  while (i < all.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(all[i])) i++;
  return all.slice(i);
}

/**
 * Does this command RETARGET THE REPOSITORY, in any spelling?
 *
 * Scans every pipeline/list segment, and inside a git segment walks the tokens
 * that sit BEFORE the sub-verb — that is where the redirect flags actually
 * live. Caught: `-C <path>`, the glued `-C<path>`, `--git-dir` and
 * `--work-tree` in both the spaced and the `=`-glued form. The scan stops at
 * the first non-option token so a legitimate `git show -C` (a diff
 * copy-detection flag, not a chdir) is NOT swept in: over-refusing there would
 * cost the census honest reads for nothing.
 *
 * `--git-dir` / `--work-tree` WERE MISSING UNTIL pds-w28-bl-two-rerun-screens-
 * drift. The Elixir WRITE seam (Barkpark.Tasks.Stage, :repo_redirect) refused
 * all three from the start; this reader refused only `-C`, so the two screens
 * for one law disagreed on two of the three redirect spellings and nothing
 * re-derived it. THE READER MOVED, because the writer's reading is the correct
 * one — `--git-dir` retargets the repository exactly as `-C` does, and a screen
 * that refuses the obvious spelling while admitting its synonym is not a screen.
 * Pinned in fixtures/rerun-spellings.json.
 */
function hasRepoRedirect(command) {
  for (const seg of String(command).split(/\||;|&&|\|\|/)) {
    const t = tokens(seg);
    if (t.length === 0) continue;
    if (t[0].split("/").pop() !== "git") continue;
    for (let i = 1; i < t.length; i++) {
      const tok = t[i];
      if (!tok.startsWith("-")) break; // reached the sub-verb
      if (tok === "-C" || (tok.startsWith("-C") && tok.length > 2)) return true;
      if (/^--(git-dir|work-tree)(=|$)/.test(tok)) return true;
      if (tok === "-c") i++; // `-c k=v` consumes its value
    }
  }
  return false;
}

/**
 * Does this command assert about the local CHECKOUT via `test` / `[`?
 *
 * ANY argument counts, not only a `-flag`. The `-flag` requirement was this
 * reader's third disagreement with the Elixir write seam (whose regex is
 * `(?:test|\[)\s` — a head followed by whitespace, full stop): `test x = x`
 * walked straight through here, and it is the shape a tautology hides in, since
 * it says nothing about origin/main OR about the checkout. THE READER MOVED,
 * for the same reason as the redirect arm: the stricter reading is the true one.
 *
 * A bare `test` with no argument at all is NOT refused — that is not a
 * predicate, it is a typo, and the writer's `\s` does not match it either.
 * Pinned in fixtures/rerun-spellings.json.
 */
function hasFilesystemPredicate(command) {
  for (const seg of String(command).split(/\||;|&&|\|\|/)) {
    const t = tokens(seg);
    if (t.length < 2) continue;
    const head = t[0].split("/").pop();
    if (head === "test" || head === "[") return true;
  }
  return false;
}

function hasCommandSubstitution(command) {
  const s = String(command);
  return s.includes("$(") || s.includes("`");
}

function hasMergeBaseIsAncestor(command) {
  const s = String(command);
  return /\bgit\b[^|;&]*\bmerge-base\b/.test(s) && /--is-ancestor\b/.test(s);
}

// ORDER IS PART OF THE ANSWER. A command can breach more than one rule; the
// first match is reported because the author has to fix that one first, and a
// list of four names is not more actionable than the one that blocks them.
//
// AND ORDER IS WHY A VALUE-SET FIXTURE IS NOT ENOUGH. Wave 28 shipped this
// array with arms 2 and 4 transposed against the Elixir write seam's
// @forbidden_rerun_shapes: `test -f x && git merge-base --is-ancestor a b` was
// :merge_base_ancestor to the writer and TEST-F to the reader — same admit/
// refuse verdict, different named remedy, invisible to any check that compares
// only WHICH commands are refused. This array is now in the writer's order, and
// fixtures/rerun-spellings.json pins multi-breach cases that only pass while
// both orders hold (pds-w28-bl-two-rerun-screens-drift).
const RULES = Object.freeze([
  {
    name: "GIT-DASH-C",
    test: hasRepoRedirect,
    message:
      "`git -C` is refused in ANY spelling: grip's screen reads the token after -C as the git " +
      "sub-verb, so `git -C log push origin main` is ADMITTED by a read-only screen (measured " +
      "2026-07-31) while the honest `git -C <dir> show …` is refused. Write the ref into the " +
      `command instead of moving the process: ${LEGAL_SUBSTITUTES.CONTENT} (or ` +
      `${LEGAL_SUBSTITUTES.EXISTENCE}) — a remote-ref read needs no cwd.`,
  },
  {
    name: "MERGE-BASE-IS-ANCESTOR",
    test: hasMergeBaseIsAncestor,
    message:
      "`git merge-base --is-ancestor` is refused by grip's shipped screen (its write scan matches " +
      "the prefix `merge` inside `merge-base`), and PDS does not patch another epic's module to " +
      `unblock itself. The measured-polarised ancestry predicate is ${LEGAL_SUBSTITUTES.ANCESTRY}. ` +
      `Do NOT reach for ${NOT_PREDICATES.join(" or ")}: both exit 0 for an ancestor AND a ` +
      "non-ancestor, so neither can ever red.",
  },
  {
    name: "COMMAND-SUBSTITUTION",
    test: hasCommandSubstitution,
    message:
      "`$( )` (and backticks) splice a second, unscreened program into the command — the screened " +
      "text is then not the text that runs. Inline the literal value the substitution would have " +
      `produced: ${LEGAL_SUBSTITUTES.ANCESTRY} with the sha written out.`,
  },
  {
    name: "TEST-F",
    test: hasFilesystemPredicate,
    message:
      "`test -f` reads the WORKING TREE at an unknown head, so it derives L6 and can be made " +
      "true by an uncommitted file. Assert against a named ref instead: " +
      `${LEGAL_SUBSTITUTES.EXISTENCE} — measured on this host: exit 0 printing \`blob\` when the path ` +
      "is present, exit 128 `fatal: path '…' does not exist in 'origin/main'` when it is not, which " +
      "grip rules PATH-GONE and therefore a real absence answer.",
  },
]);

export const FORBIDDEN_NAMES = Object.freeze(RULES.map((r) => r.name));

/**
 * forbiddenSpelling(command) → null | { name, message }
 * null means "this layer has nothing to say", NEVER "this command is safe" —
 * grip's screen still decides admission at the execution boundary.
 */
export function forbiddenSpelling(command) {
  const cmd = String(command ?? "");
  if (cmd.trim() === "") return null;
  for (const rule of RULES) {
    if (rule.test(cmd)) return { name: rule.name, message: rule.message };
  }
  return null;
}
