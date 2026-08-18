// level.mjs — the pure authority-level grammar over the `rerun` command string.
//
// The load-bearing inversion (charter D1/D2): authority level is DERIVED by
// this program from the shape of the ONE literal shell command that re-derives
// a fact — and can never be raised by what the author claims. The `evidence`
// narrative is L6 BY CONSTRUCTION: nothing in this module ever reads it. A
// prose-scanning extractor was built first and measured against 60
// hand-labelled real evidence strings: L1/L2 precision 0.67 — it stamped L1 on
// a string beginning "OPEN — requires a run against the deployed build" and on
// a local source read whose file merely CONTAINED an https:// literal. Markers
// fire on MENTION; this grammar levels only the INVOCATION.
//
// The ladder (ratified in /papers/survey-once-build-forever):
//   L1  running system   — ssh to a host, curl to a non-loopback host
//   L2  origin/main      — git show <remote-ref>:<path>, gh api
//   L3  local checkout   — local read, scoped grep, local test, node <script>
//   L4  generated artifact — a read whose target is a known emitted path
//   L5  charters / docs  — never derived here; reading a doc locally is
//                          mechanically L3 (the ladder keeps the slot)
//   L6  no command       — or a command the grammar cannot classify
//
// The derived level is a CEILING (D2). A missing command DEMOTES to L6, never
// rejects (D3) — the honest path must stay the cheap one. What this grammar
// certifies is RE-DERIVABILITY of a fact from its command — never that the
// author actually ran it; authorship is outside its jurisdiction (D4).
//
// Pure, dependency-free, no side effect on import. ESM named exports only.

// Ordered ladder. Lower rank = higher authority. Exported so callers compare
// via rank, never by string arithmetic.
export const LEVELS = Object.freeze({
  L1: 1,
  L2: 2,
  L3: 3,
  L4: 4,
  L5: 5,
  L6: 6,
});

// --- host classification -----------------------------------------------------

// Loopback hosts a curl can hit without leaving the laptop. A loopback curl is
// a read of the LOCAL running dev system — a claim about the local checkout,
// so it derives L3, never L1.
const LOOPBACK_HOST = /^(localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|::1)$/i;

// scheme://host[:port] extractor — first URL-shaped token in the command.
// The host alternation takes a BRACKETED IPv6 literal first: a naive
// [^/\s:'"]+ stops at the first colon and captures a bare "[" from
// http://[::1]:4000, which fails the loopback test and FALSELY PROMOTES a
// local dev-server read to L1 — this module's own failure mode. Brackets are
// stripped by normalizeHost so ::1 meets LOOPBACK_HOST in one canonical form.
const URL_TOKEN = /\b[a-z][a-z0-9+.-]*:\/\/(\[[0-9A-Fa-f:.]+\]|[^/\s:'"]+)/gi;

function normalizeHost(host) {
  return host.startsWith("[") && host.endsWith("]") ? host.slice(1, -1) : host;
}

// --- generated-artifact paths (L4) -------------------------------------------

// A read whose TARGET is one of these is a read of an emitted artifact, not of
// source: it derives L4. Exported so later slices (the adjudicator, the
// executor) share one list instead of forking it.
//
// DERIVED FROM THE EMITTERS, NOT GUESSED. The list below is the census of what
// the repo's generators actually write:
//   * design/emit.mjs — its exported ARTIFACTS array (18 entries) plus the
//     paper-editor mirror post-step.
//   * the tooling/ emitters — every `writeFileSync` site under tooling/, with
//     each output constant resolved to its real path.
// The previous list was wrong in BOTH directions and this fixes both.
//
// THE MARKER-SPLICE BOUNDARY (the rule that decides membership).
// design/emit.mjs writes an artifact in one of two shapes, and only ONE of them
// is a generated file:
//   (a) WHOLE FILE — kinds "go" / "ts" / "elixir": build() returns the entire
//       file body and emit overwrites it. internal/*/tokens_gen.go,
//       internal/semrole/chrome_gen.go, web/lib/tokens.gen.ts,
//       api/lib/**/tokens_gen.ex. Nothing hand-authored survives a regen, so a
//       read of one of these is an ARTIFACT read → L4.
//   (b) MARKER SPLICE — kinds "css" / "html": build() returns a block that is
//       spliced between BEGIN/END GENERATED markers inside an OTHERWISE
//       HAND-AUTHORED file — api/lib/barkpark_web/layouts/root.html.heex,
//       web/app/globals.css, cloud/priv/static/app.css,
//       api/lib/barkpark_web/controllers/session_html.ex, and the rest.
// A MARKER-SPLICED FILE IS **NOT** A GENERATED ARTIFACT AND MUST NEVER MATCH
// HERE. It is partly source: the file's identity, structure and the great
// majority of its bytes are hand-written, and a read of it is overwhelmingly
// likely to be a read of that hand-written part. Levelling it L4 would DEFLATE
// the authority of an honest source read — the mirror-image bug of the
// inflation this list exists to stop, and a new bug of our own. The splice
// targets are therefore deliberately absent below, and the near-miss tests in
// test/level.test.mjs pin that absence so a future widening cannot silently
// swallow them.
//
// REMOVED: /(^|\/)design\/(dist|out|generated|emitted)\//. It matched NOTHING
// real — design/emit.mjs has never written into such a directory (see the two
// shapes above), so every regenerable token file derived L3, i.e. SOURCE-
// checkout authority for a file that is not source. That is authority
// INFLATION, the exact failure this epic exists to stop.
//
// Suffix sets are deliberately NARROW — exactly the extensions the census
// found (`_gen.go`, `_gen.ex`, `.gen.ts`). A new emitter extension is a
// deliberate edit here plus its pair of tests, never a speculative alternation.
export const GENERATED_ARTIFACT_PATTERNS = Object.freeze([
  // --- hand-placed, already correct ---
  /(^|\/)docs\/openapi\.json$/,
  /\.golden\.json$/, // api/test/support/fixtures/*.golden.json — verified real

  // --- design/emit.mjs, shape (a): WHOLE-FILE emits ---
  // internal/{taskboard,pdrender,semrole}/tokens_gen.go, internal/semrole/chrome_gen.go
  /(^|\/)[^/\s]*_gen\.go$/,
  // api/lib/barkpark/portable_doc/render/tokens_gen.ex, api/lib/barkpark_web/studio/tokens_gen.ex
  /(^|\/)[^/\s]*_gen\.ex$/,
  // web/lib/tokens.gen.ts
  /(^|\/)[^/\s]*\.gen\.ts$/,

  // --- tooling/ emitters: the report family ---
  // Widened past .json: quality/consistency/combined/status/fit also emit the
  // .html rendering and combined/ emits the .csv, all from the same run.
  /(^|\/)tooling\/[^/\s]+\/[^/\s]+-report\.(?:json|html|csv)$/,

  // --- tooling/ emitters: named single-file outputs ---
  // Each resolved from its emitter's output constant. Enumerated rather than
  // globbed because tooling/<seg>/ ALSO holds hand-authored config and
  // fixtures (blast-radius/config.json, consistency/config.json,
  // cody/bindings.json, doc-truth/doc-refs.json) which must keep deriving L3.
  /(^|\/)tooling\/blast-radius\/(?:index|last-impact|verdict-cache)\.json$/,
  /(^|\/)tooling\/symbol-graph\/symbols\.json$/,
  /(^|\/)tooling\/map\/manifest\.json$/,
  /(^|\/)tooling\/file-importance\/(?:file-signals|file-batches)\.json$/,
  /(^|\/)tooling\/file-importance\/importance-chart\.(?:csv|html)$/,
  /(^|\/)tooling\/consistency\/verdict-cache\.json$/,
  /(^|\/)tooling\/fit\/scoring-config\.json$/,
  /(^|\/)tooling\/research-coverage\/research-ledger\.json$/,
  /(^|\/)tooling\/barkpark-sync\/(?:nodes\.json|codebase-graph\.html)$/,
  /(^|\/)tooling\/concept-map\/boundary-baseline\.json$/,

  // --- tooling/ emitters: the fan-out directories, TWO levels deep ---
  // batches/ and results/ are rmSync'd and rebuilt on every run
  // (intentions, usefulness, consistency, research-coverage, file-importance),
  // review-batches/ by intentions/review.mjs, dossiers/ by blast-radius.
  /(^|\/)tooling\/[^/\s]+\/(?:batches|review-batches|results|dossiers)\/[^/\s]+\.json$/,

  // KNOWN, DELIBERATE OMISSION — tooling/grip/fixtures/evidence-corpus.json.
  // harvest.mjs writes it, so by the census rule above it IS an emitted
  // artifact and belongs on this list. It is held out on purpose, and the
  // reason is worth stating rather than leaving as a silent gap:
  //
  // L4 sits BELOW L3 on the ladder, so adding it would make checkCeiling start
  // REJECTING the in-flight L3 claims of every slice that cites a read of the
  // frozen corpus — this wave's own siblings included. That is a real cost paid
  // to avoid a mid-wave break, NOT a judgment that the file is source. It is
  // filed as tgw2-l4-grip-corpus-selfref and should be added once the wave that
  // depends on those L3 citations has merged.
  //
  // The same question hangs over tooling/concept-map/boundary-baseline.json,
  // which IS listed above: it is regenerable, but it is also checked in and
  // read as a reference. The two are ruled differently today and that
  // inconsistency is known, not overlooked.

  // --- tooling/ emitters: the scalar hand-off files ---
  // batch-count.txt / review-count.txt / issues-stale.txt / taxonomy-input.txt
  // are written by the same runs that build the batches they describe.
  /(^|\/)tooling\/[^/\s]+\/(?:batch-count|review-count|issues-stale|taxonomy-input)\.txt$/,
]);

function isGeneratedArtifactPath(token) {
  return GENERATED_ARTIFACT_PATTERNS.some((re) => re.test(token));
}

// --- command-shape predicates ------------------------------------------------

// ssh: ALLOW FLAGS between `ssh` and the `user@host` — an adjacency regex
// false-demoted a genuine `ssh -o BatchMode=yes … root@…` read during
// verification. The ratified pattern is /\bssh\b[^\n]*@/ (charter D2). The
// zero-false-demotion bar on honest flag-bearing invocations outranks the
// residual promotion risk of an `@` elsewhere on the line.
const SSH_READ = /\bssh\b[^\n]*@/;

// git show against a REMOTE ref (origin/…, upstream/…, refs/remotes/…) is an
// L2 read of what the remote actually holds. `git show HEAD:…` or a local
// branch is a read of the local checkout's object store — L3.
const GIT_SHOW_REMOTE = /\bgit\s+show\s+(?:['"]?)(?:refs\/remotes\/|origin\/|upstream\/)\S*:/;
const GH_API = /\bgh\s+api\b/;

// Local readers / scoped search / local runs — the L3 family. Head-token
// oriented: we look at the first command word (after env assignments and
// harmless wrappers) plus a few whole-line runners.
//
// EXPORTED so the suite can pin what is NOT here. `cd`, `for` and `env` are
// deliberately absent: a navigation or looping wrapper is not a read, and
// filing one at L3 would make `cd /opt && curl https://prod/health` derive the
// LOCAL CHECKOUT's authority for a command that provably reaches production.
// Compounds are handled by walking the segments (see splitSegments), never by
// blessing a wrapper's head.
export const L3_HEADS = new Set([
  "cat", "head", "tail", "less", "more", "sed", "awk", "cut", "sort", "uniq",
  "wc", "ls", "stat", "file", "diff", "jq", "grep", "rg", "ag", "find",
  "node", "go", "mix", "npm", "pnpm", "yarn", "make", "elixir", "python",
  "python3", "bash", "sh", "zsh", "git", "tree", "shasum", "md5", "openssl",
]);

// Strip leading env assignments (`FOO=bar cmd`) and harmless prefix wrappers
// so `timeout 10 grep …` still levels on `grep`.
const PREFIX_WRAPPERS = new Set(["timeout", "time", "env", "nice", "xargs", "sudo"]);

// Shell keywords that can OPEN a segment once a compound is split on `;`.
// `for pr in 1 2 3; do gh pr view $pr; done` splits into three segments and the
// middle one starts with the bare keyword `do`. Skipping it finds `gh`, which
// is the token that actually carries authority. These are NOT L3 heads — they
// classify nothing on their own.
const SEGMENT_KEYWORDS = new Set(["do", "then", "else", "elif", "!"]);

// Heads that MOVE but never READ. A segment headed by one of these contributes
// NO level at all — it is a wrapper, and the compound's authority comes from
// its sibling segments. This is the honest half of "add cd to L3_HEADS": the
// head is found past the wrapper without the wrapper inheriting a level.
const NAVIGATION_HEADS = new Set(["cd", "pushd", "popd", "for", "while", "until", "if", "case", "done", "fi", "esac", "export", "set", "source", "."]);

function headToken(command) {
  const tokens = command.trim().split(/\s+/).filter(Boolean);
  let i = 0;
  while (i < tokens.length) {
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) { i += 1; continue; }
    const raw = tokens[i];
    const bare = raw.replace(/^.*\//, ""); // basename for /usr/bin/grep
    if (SEGMENT_KEYWORDS.has(bare)) { i += 1; continue; }
    if (PREFIX_WRAPPERS.has(bare)) {
      i += 1;
      // `timeout 10 cmd` — skip a numeric duration argument
      if (i < tokens.length && /^\d+[smh]?$/.test(tokens[i])) i += 1;
      continue;
    }
    return { head: bare, raw, rest: tokens.slice(i + 1) };
  }
  return { head: "", raw: "", rest: [] };
}

// --- quote masking -----------------------------------------------------------

// A SAME-LENGTH mask in which the CONTENT of every quoted span becomes `x`.
// Offsets are preserved so a caller can slice the ORIGINAL string by positions
// found in the mask. Everything structural — segment splitting, the prose
// floor — reads the mask, so `grep -n 'a && b' file` is one segment and the
// https:// literal inside `grep -n 'https://…' src.ts` is inert. That literal
// is the exact string on which the refuted prose scanner stamped L1.
function maskQuoted(command) {
  let out = "";
  let quote = null;
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote) {
      out += ch === quote ? ch : ch === "\n" ? "\n" : "x";
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') { quote = ch; out += ch; continue; }
    out += ch;
  }
  return out;
}

// --- segment walking ---------------------------------------------------------

// Split a compound on its UNQUOTED control operators. Positions come from the
// mask; the slices come from the original, so a segment keeps its real bytes.
const SEGMENT_OPERATOR = /(\|\||&&|;;|;|\||\n)/g;

function splitSegments(command, mask) {
  const cuts = [];
  SEGMENT_OPERATOR.lastIndex = 0;
  let m;
  while ((m = SEGMENT_OPERATOR.exec(mask)) !== null) {
    cuts.push([m.index, m.index + m[0].length]);
  }
  const segments = [];
  let from = 0;
  for (const [start, end] of cuts) {
    segments.push([from, start]);
    from = end;
  }
  segments.push([from, command.length]);
  return segments
    .map(([a, b]) => ({ raw: command.slice(a, b), mask: mask.slice(a, b) }))
    .filter((s) => s.raw.trim() !== "");
}

// Trim subshell/group punctuation and redirections that survive the split, so
// `(cd x` and `tail -1)` still find their head.
function trimSegment(text) {
  return text.replace(/^[\s(){}]+/, "").replace(/[\s(){}]+$/, "").trim();
}

// Non-loopback URL anywhere in the command (curl/wget/http reads).
function firstRemoteUrlHost(command) {
  URL_TOKEN.lastIndex = 0;
  let m;
  while ((m = URL_TOKEN.exec(command)) !== null) {
    const host = normalizeHost(m[1]);
    if (!LOOPBACK_HOST.test(host)) return host;
  }
  return null;
}

// --- the remote-API heads (L2) -----------------------------------------------

// `bp` and `gh` are REMOTE-API clients, not local tools. `bp` talks to the
// configured content server (~/.config/barkpark/config.json — guerrilla, in
// practice) and `gh` talks to api.github.com. Filing either at L3 "local
// checkout" would be a two-level SKIP that labels volatile remote state as
// checkout-stable; filing them at L1 would be a promotion they have not
// earned — they are not an ssh into a box nor a read of served bytes. They sit
// exactly where `gh api` already sat: L2.
//
// The one carve-out mirrors the loopback-curl rule: `bp -s http://localhost:4001`
// reads the LOCAL dev server, which is a property of the checkout — L3.
const REMOTE_API_HEADS = new Set(["bp", "gh"]);

// The `bp scaffy` carve-out: five verbs are PURE LOCAL and touch no server.
// scaffy_cmd.go's own header states it (verbatim): "PURE LOCAL like make/style:
// no network, no auth, no manifest — this file never touches the server." Its
// engine (internal/scaffy: Parse/Lint/ValidateFile/Format/Run/Remove and the
// git-mining discover pass) reads and writes the cwd tree only. So a URL-free
// `bp scaffy validate|fmt|run|remove|discover …` re-derives its fact from the
// LOCAL CHECKOUT — L3 — exactly like `mix test` or `node <script>`, and filing
// it at the remote-API L2 is a one-level authority INFLATION: checkCeiling
// accepts an author's L2 claim on a fact only the local tree can settle.
//
// The boundary is the whole judgment, re-derived from the two source files, not
// assumed: `pull` and `ls --remote` live in scaffy_remote_cmd.go, carry a
// `Server` and hit `<server>/v1/data/query/<dataset>/command` — they stay L2.
// The demotion therefore requires BOTH (a) a local verb AND (b) NO url token in
// the command: a non-loopback `-s https://…` reaches the L2 branch below, and a
// loopback `-s http://localhost…` is already caught by hasOnlyLoopbackTargets
// (L3). Only the URL-FREE local-verb invocation is demoted here.
const LOCAL_SCAFFY_VERBS = new Set(["validate", "fmt", "run", "remove", "discover"]);

function isLocalScaffyInvocation(command) {
  URL_TOKEN.lastIndex = 0;
  if (URL_TOKEN.exec(command) !== null) return false; // any url ⇒ not the URL-free local shape
  const tokens = command.trim().split(/\s+/).filter(Boolean);
  const si = tokens.indexOf("scaffy");
  if (si === -1) return false;
  // The verb is the first non-flag token after `scaffy` (`ls --remote` → `ls`,
  // `discover --since X` → `discover`, `fmt --check f` → `fmt`).
  for (let i = si + 1; i < tokens.length; i += 1) {
    if (tokens[i].startsWith("-")) continue;
    return LOCAL_SCAFFY_VERBS.has(tokens[i]);
  }
  return false;
}

function hasOnlyLoopbackTargets(command) {
  URL_TOKEN.lastIndex = 0;
  let seen = false;
  let m;
  while ((m = URL_TOKEN.exec(command)) !== null) {
    seen = true;
    if (!LOOPBACK_HOST.test(normalizeHost(m[1]))) return false;
  }
  return seen;
}

// --- the parseability floor --------------------------------------------------

// 13.3% of the frozen corpus's rerun strings are PROSE, not commands. The
// grammar inspects a head token and never asks whether the string PARSES, so
// any prose beginning with — or containing — a blessed token inherits that
// token's authority: `bp sites -o json | python3 (count)` would otherwise
// derive L2 off `bp`, and `cd api && (Edit: add agent_state to the base map)
// && CC=clang mix test …` would derive L3 off `mix` even though the run is not
// reproducible without a human edit. A recipe that cannot be re-run is not a
// recipe.
//
// STRUCTURAL, PURE, CLOCK-FREE: no child_process, no filesystem, no clock. It
// cannot ask a shell to parse the string, so it looks for shapes prose has and
// commands do not.
//
// BIASED TOWARD DEMOTING (D3). A false positive costs an L6 demotion, which the
// charter already establishes as the safe error direction; a false negative
// costs a promotion of unrunnable prose, which is the failure this exists to
// stop. Where the two trade off, demote.

// Heads a real invocation may plausibly start with. Deliberately MODEST — this
// is the allowlist that SUPPRESSES a demotion, so every entry is a chance to
// miss prose. Growth here should be evidence-driven, from real commands the
// floor was measured to over-demote.
const KNOWN_HEADS = new Set([
  ...L3_HEADS,
  ...PREFIX_WRAPPERS,
  ...NAVIGATION_HEADS,
  ...REMOTE_API_HEADS,
  "curl", "wget", "ssh", "scp", "rsync", "npx", "echo", "printf", "cp", "mv",
  "rm", "ln", "mkdir", "touch", "chmod", "chown", "tar", "kill", "pgrep",
  "pkill", "systemctl", "psql", "dig", "docker", "sleep", "date", "which",
  "command", "type", "test", "true", "false", "tee", "tr", "base64", "xxd",
  "uptime", "df", "du", "ps", "claude", "defaults", "open", "diskutil", "pip",
  "pip3", "cargo", "gofmt", "prettier", "eslint", "tsc", "vitest", "jest",
]);

// `<rev>`, `<remove workspace_id from connector_installs CREATE>`,
// `diff -rq <tracked testdata> <scratch testdata>` — an angle-bracket PAIR is a
// template slot, never a redirection (`2>&1`, `> out`, `< /dev/null` never
// close). Process substitution `<(…)` is excluded by the character class.
//
// The brackets must HUG their content. Without that, `sort < in.txt > out.txt`
// — one segment carrying both an input and an output redirect — reads as a
// pair around " in.txt " and is falsely floored to L6. A template slot never
// has whitespace just inside its brackets; a redirect pair almost always does.
const PLACEHOLDER_ANGLE = /<[^<>()\s][^<>()\n]{0,78}[^<>()\s]>|<[^<>()\s]>/;
// `bp onramp windsurf --write [--force]` — an optional-flag slot. Narrow on
// purpose: `[::1]` and glob classes like `[0-9]` must not match.
const PLACEHOLDER_BRACKET = /\[--/;
// A standalone `...` / `…` is an elision. `./internal/cli/...` is a Go package
// wildcard and is NOT standalone, so it is untouched.
const ELISION = /(^|\s)(\.\.\.|…)(\s|$)/;
// `grep/read api/lib/…/template.ex around lines 200-219` — a slash-joined verb
// phrase in HEAD position. A real head is `./x`, `/usr/bin/x`, or a bare name;
// a bare `a/b` head with no dot is two verbs, not a program.
const SLASH_JOINED_HEAD = /^[A-Za-z][A-Za-z-]*\/[A-Za-z][A-Za-z-]*(\/[A-Za-z][A-Za-z-]*)*$/;
// `gh pr view 4631/4632/4633`, `gh run view 295…/295…` — a slash-joined run of
// numbers is shorthand for several commands, so it is not one command.
const SLASH_JOINED_NUMBERS = /(^|\s)\d+(\/\d+)+(\s|$)/;

// An unquoted parenthetical whose first word is not a plausible command head is
// an aside: `(count)`, `(restore honest footer)`, `(15 per PREDICTED class, so
// per-class precision is unbiased)`. A real subshell — `(cd __preview__ && node
// smoke.mjs)` — opens on a known head and is left alone. A function-call paren
// (`count(…)`) is attached to a word character and never examined.
//
// A BACKSLASH-ESCAPED paren is not a group at all — it is a literal argument
// passed to a program, and `find . \( -name a -o -name b \)` is the shape that
// matters: `-name` is not a plausible command head, so the escaped group read
// as prose and floored a perfectly good `find` from L3 to L6. Zero occurrences
// in the 651-command corpus, so the distribution measurement was blind to it,
// exactly as it was blind to the `sort < in > out` cry-wolf the builder found
// by hand. A corpus is a lower bound on cry-wolf, never a proof of its absence.
const PAREN_GROUP = /(^|[^$\w\\])\(([^()\n]{0,240})\)/g;

function parentheticalIsProse(mask) {
  PAREN_GROUP.lastIndex = 0;
  let m;
  while ((m = PAREN_GROUP.exec(mask)) !== null) {
    const inner = m[2].trim();
    if (inner === "") continue;
    const { head } = headToken(inner);
    if (!KNOWN_HEADS.has(head)) return true;
  }
  return false;
}

// A SEGMENT is prose when it has several words, an unrecognisable head that is
// not path-shaped, and none of the marks an invocation leaves behind — a flag,
// a path argument, an assignment, a redirection. `edit studio_chat.ex:892-893
// Map.take +[…]` and `flip PROBE-A to refute` are prose by this test;
// `frobnicate --all --please` is not (it carries flags), and stays L6 by the
// ordinary unknown-head route.
function segmentIsProse(segment) {
  const tokens = trimSegment(segment.mask).split(/\s+/).filter(Boolean);
  if (tokens.length < 3) return false;
  const { head, raw } = headToken(trimSegment(segment.mask));
  if (!head) return false;
  // `probe: add migration_lock: false to Ecto.Migrator.up/down` — a head ending
  // in a colon is a NOTE LABEL. No program is invoked by that name, and the
  // suppressors below (it carries a slash!) would otherwise wave it through.
  if (head.endsWith(":")) return true;
  if (KNOWN_HEADS.has(head)) return false;
  if (/[./]/.test(raw)) return false;                       // ./run.sh, a.out, api/x
  if (tokens.some((t) => /^-{1,2}[A-Za-z]/.test(t))) return false; // carries flags
  if (tokens.some((t) => t.includes("/"))) return false;    // carries a path
  if (tokens.some((t) => t.includes("=") || t.includes(">") || t.includes("<"))) return false;
  return true;
}

// looksLikeProse(command, mask) → boolean. Exported for the suite and for any
// caller that wants to explain a demotion rather than just apply it.
export function looksLikeProse(command, mask = maskQuoted(String(command ?? ""))) {
  if (PLACEHOLDER_ANGLE.test(mask)) return true;
  if (PLACEHOLDER_BRACKET.test(mask)) return true;
  if (ELISION.test(mask)) return true;
  if (SLASH_JOINED_NUMBERS.test(mask)) return true;
  if (parentheticalIsProse(mask)) return true;
  const segments = splitSegments(command, mask);
  for (const segment of segments) {
    const { raw } = headToken(trimSegment(segment.mask));
    if (raw && SLASH_JOINED_HEAD.test(raw)) return true;
    if (segmentIsProse(segment)) return true;
  }
  return false;
}

// --- deriveLevel -------------------------------------------------------------

// Only reader-shaped heads can reach L4 — `node design/emit.mjs` REGENERATES an
// artifact (a local run, L3), it does not read one.
const READER_HEADS = new Set(["cat", "head", "tail", "less", "more", "jq", "grep", "rg", "sed", "awk", "wc", "diff"]);

// The level of ONE segment of a compound, or null when the segment classifies
// nothing (a `cd`, a loop keyword, an unknown head).
function segmentLevel(text, maskText = text) {
  const command = trimSegment(text);
  if (command === "") return null;
  // Mention-immunity: the blessed remote tokens are read from the QUOTE-MASKED
  // segment, exactly as curl/wget is head-gated. `grep -rn "ssh root@host" doc.md`
  // MENTIONS a production command; it does not run one.
  const masked = trimSegment(maskText);
  const { head, raw, rest } = headToken(command);
  // A READER head can never itself BE an ssh/gh/git-show invocation, so a
  // blessed token under one is always a mention — including the unquoted
  // `grep -rn ssh root@host docs/`, which quote-masking alone cannot see.
  // …but a process/command substitution under a reader head is a REAL
  // invocation, not a mention: `diff <(git show origin/main:x) x` genuinely
  // reads origin. The corpus contains exactly that shape, and demoting it
  // would break the standing zero-false-demotion bar.
  const mentionOnly = READER_HEADS.has(head) && !/[<>$]\(/.test(masked);
  // …and a segment HEADED BY the command itself is never a mention of it: its
  // own quoted arguments belong to it. `ssh "root@host" uptime` and
  // `git show 'origin/main:api/mix.exs'` quote a DESTINATION, they do not name
  // a command inside prose — and reading those through the mask demoted a live
  // production read L1→L6 and an origin read L2→L3, the exact false-demotion
  // direction this change is barred from moving. `headToken` already unwraps
  // PREFIX_WRAPPERS, so `timeout 30 ssh "root@h" …` is covered too. Masking
  // still governs every OTHER head, which is what keeps `echo "ssh root@host"`
  // at L6.
  const probe = (name) => (head === name ? command : masked);

  // L1 — a running system was touched.
  if (!mentionOnly && SSH_READ.test(probe("ssh"))) return "L1";
  if (head === "curl" || head === "wget") {
    // The URL is read from the ORIGINAL segment, quotes and all: `curl 'https://…'`
    // is a real remote target. The head gate is what keeps a MENTIONED url —
    // `grep -n 'https://…' src.ts` — from ever reaching this branch.
    return firstRemoteUrlHost(command) ? "L1" : "L3"; // no remote URL ⇒ loopback/local
  }
  if (!head) return null;

  // L2 — origin/main, or another remote read through a remote-API client.
  if (!mentionOnly && (GIT_SHOW_REMOTE.test(probe("git")) || GH_API.test(probe("gh")))) return "L2";
  if (REMOTE_API_HEADS.has(head)) {
    if (hasOnlyLoopbackTargets(command)) return "L3";
    // A URL-free local `bp scaffy` verb touches only the cwd tree — L3.
    if (head === "bp" && isLocalScaffyInvocation(command)) return "L3";
    return "L2";
  }

  // L4 — the read's TARGET is a known generated artifact. Checked before the
  // generic L3 family: `cat docs/openapi.json` is an artifact read, not source.
  if (READER_HEADS.has(head) && rest.some((t) => isGeneratedArtifactPath(t.replace(/^['"]|['"]$/g, "")))) {
    return "L4";
  }

  // L3 — local checkout: reads, scoped grep, local tests, node <script>.
  if (L3_HEADS.has(head)) return "L3";
  if (/^\.{0,2}\//.test(raw)) return "L3"; // ./script.sh, ../bin/tool, /path/tool

  if (NAVIGATION_HEADS.has(head)) return null; // a wrapper reads nothing
  return null;
}

// deriveLevel(rerun) → "L1" | "L2" | "L3" | "L4" | "L6"
//
// PURE over the command string alone. It never receives — and must never be
// handed — the evidence prose, the claim, or any narrative field. Unknown
// shapes DEMOTE to L6 (D3); nothing here throws on honest input.
//
// A COMPOUND IS WALKED, NOT SNIFFED AT THE HEAD. Every unquoted segment is
// levelled on its own and the STRONGEST wins, because the derived level is a
// CEILING on what the compound could have observed: `cd /opt && curl
// https://prod/health` reaches production, and `curl https://prod/x | jq .`
// must not be demoted to L3 by its pipe consumer — the suite's standing bar is
// ZERO false demotions of honest L1/L2 commands. What keeps strongest-wins from
// becoming a promotion engine is the parseability floor above: unrunnable prose
// never reaches the walk at all.
export function deriveLevel(rerun) {
  if (typeof rerun !== "string" || rerun.trim() === "") return "L6";
  const command = rerun.trim();
  const mask = maskQuoted(command);

  // The floor runs FIRST. A string that is not a command cannot derive a level
  // above L6 no matter which blessed tokens it happens to contain.
  if (looksLikeProse(command, mask)) return "L6";

  let best = null;
  let sawArtifactRead = false;
  for (const segment of splitSegments(command, mask)) {
    const level = segmentLevel(segment.raw, segment.mask);
    if (level === null) continue;
    if (level === "L4") { sawArtifactRead = true; continue; }
    if (best === null || LEVELS[level] < LEVELS[best]) best = level;
  }

  // L4 is a statement about the read's TARGET, not a rung competing with L1-L3,
  // and it sits BELOW L3 on the ladder. So a pipeline that reads an artifact
  // and hands it to a local consumer — `cat docs/openapi.json | jq .` — is an
  // artifact read, not a source read; but an artifact read beside a remote one
  // never caps that remote read.
  if (sawArtifactRead && (best === null || best === "L3")) return "L4";

  // Unclassifiable — demoted, never rejected (D3).
  return best ?? "L6";
}

// --- checkCeiling ------------------------------------------------------------

// The derived level is a CEILING. A claim ABOVE it (numerically lower rank —
// higher authority) is a LEVEL-SKIP and is REJECTED, naming both levels.
// Equal or below is accepted: an author may honestly under-claim.
export function checkCeiling(claimed, derived) {
  const claimedRank = LEVELS[claimed];
  const derivedRank = LEVELS[derived];
  if (claimedRank === undefined) {
    return { ok: false, reason: "UNKNOWN-LEVEL", message: `UNKNOWN-LEVEL: claimed level ${JSON.stringify(claimed)} is not on the ladder ${Object.keys(LEVELS).join(" ")}`, claimed, derived };
  }
  if (derivedRank === undefined) {
    return { ok: false, reason: "UNKNOWN-LEVEL", message: `UNKNOWN-LEVEL: derived level ${JSON.stringify(derived)} is not on the ladder ${Object.keys(LEVELS).join(" ")}`, claimed, derived };
  }
  if (claimedRank < derivedRank) {
    return {
      ok: false,
      reason: "LEVEL-SKIP",
      message: `LEVEL-SKIP: claimed ${claimed} above derived ${derived} — the rerun command re-derives this fact at ${derived}; a ${claimed} claim needs a ${claimed}-shaped command`,
      claimed,
      derived,
    };
  }
  return { ok: true, claimed, derived, level: claimed };
}

// --- classifyRef -------------------------------------------------------------

// A path:line reference MUST carry a directory component. A bare
// `notifications.ex:389-397` sent a verifier to api/lib and returned empty —
// the real file was cloud/lib/barkpark_cloud/notifications.ex. Ambiguity in a
// reference is a wrong value waiting to be read.
const PATH_LINE_REF = /^(?<path>[^:\s]+):(?<start>\d+)(?:-(?<end>\d+))?$/;

export function classifyRef(ref) {
  if (typeof ref !== "string" || ref.trim() === "") {
    return { ok: false, reason: "NOT-A-REF", message: "NOT-A-REF: empty or non-string reference", ref };
  }
  const m = PATH_LINE_REF.exec(ref.trim());
  if (!m) {
    return { ok: false, reason: "NOT-A-REF", message: `NOT-A-REF: ${JSON.stringify(ref)} is not <path>:<line>[-<line>]`, ref };
  }
  const { path, start, end } = m.groups;
  if (!path.includes("/")) {
    return {
      ok: false,
      reason: "PATHLESS-REF",
      message: `PATHLESS-REF: ${JSON.stringify(ref)} has no directory component — a bare filename resolves against whichever tree the reader happens to stand in`,
      ref,
    };
  }
  return { ok: true, path, lines: { start: Number(start), end: end ? Number(end) : Number(start) } };
}

// --- isDiscretePredicate -----------------------------------------------------

// D7: only DISCRETE predicates are admissible. A continuous measurement (a
// float with a time unit — duration, latency) drifts run to run: one L1 curl
// returned a stable code=200 while t_total moved 0.116 / 0.135 / 0.118 across
// three runs. Such a quantity is admissible only when the claim declares a
// PREDICATE over it (a threshold comparison), which collapses the
// distribution to a boolean. Callers flag a false return as
// INADMISSIBLE-CONTINUOUS.
const CONTINUOUS_MEASUREMENT = /\b\d+\.\d+\s*(?:s|ms|us|µs|ns|sec|secs|seconds|millis|milliseconds|minutes?)\b/i;
const BARE_FLOAT_TIMEY = /\bt_(?:total|connect|ttfb|pretransfer|starttransfer)\b[^\n]*?\b\d+\.\d+\b|\b\d+\.\d+\b[^\n]*?\bt_(?:total|connect|ttfb|pretransfer|starttransfer)\b/i;
const THRESHOLD_PREDICATE = /(?:<=|>=|<|>|\bunder\b|\bover\b|\bbelow\b|\babove\b|\bat\s+most\b|\bat\s+least\b|\bwithin\b)/i;

export function isDiscretePredicate(claim) {
  if (typeof claim !== "string" || claim.trim() === "") return true; // nothing continuous declared
  const continuous = CONTINUOUS_MEASUREMENT.test(claim) || BARE_FLOAT_TIMEY.test(claim);
  if (!continuous) return true;
  return THRESHOLD_PREDICATE.test(claim);
}
