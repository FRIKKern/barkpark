#!/usr/bin/env node
//
// CLOSED-ROW / TREE DISAGREEMENT SWEEP — does a CLOSED row's disposition assert a
// change origin/main does not carry?
// (search vocabulary: closed row sweep, tree-behind-ledger, disposition evidence,
//  stale close, wrong close, false-done, reversed polarity, closed population audit.)
//
// WHY THIS FILE EXISTS. scripts/false-open-sweep.mjs asks the ledger-behind-tree
// question: an OPEN row whose work already merged. That direction is self-correcting —
// a stale open row gets re-verified the moment somebody picks it up. This file asks the
// OTHER direction, the one nothing re-reads:
//
//   A ROW THAT READS STALE GETS RE-VERIFIED. A ROW THAT READS CLOSED GETS NOTHING.
//
// A closed row is invisible to `bp task ready`, invisible to every triage sweep that
// starts from the ready queue, and invisible to the already-fixed check, which only ever
// runs against OPEN rows. If its close_reason asserts a change the tree does not carry,
// the defect it describes is now protected by the record that says it was handled.
// Filed as task-14b17a62a03599a1.
//
// RULE 1, INHERITED FROM THE SIBLING: EVERY EMPTY IS A REFUSAL, NEVER A CLEAN REPORT.
// Zero rows read, an unparseable line, a sample that could not be drawn, a git rev that
// does not resolve — each exits non-zero and says so. There is no path here that prints
// "no disagreements" over a population it never read.
//
// RULE 2: THIS TOOL WRITES NOTHING. No `bp task` write verb, no reopen, no stamp. It
// prints a verdict per row and a human disposes. A DISAGREE is a LEAD, not a ruling:
// a close can be correct for a reason its body does not carry (the change was
// SUPERSEDED, ACCEPTED, or FOLDED into another slice — see the worked example below).
//
// THE POPULATION. A row is CLOSED here when lifecycle_status is done or cancelled, OR
// content.disposition is "closed". Measured 2026-09-12: 7851 of 9509 type:task rows.
//
// THE DETECTOR — three arms over close_reason + disposition_reason, the only two fields
// a closer writes prose into.
//
//   ARM P — FILE PATHS. A repo-relative path with a known extension. The tree is asked
//     `git cat-file -e <rev>:<path>`. Absent => DISAGREE-path: the disposition names a
//     file main does not have.
//
//   ARM S — SYMBOLS. An Elixir MFA (`Barkpark.Tasks.Criteria.merge_gated?/1`) or a
//     backticked identifier. The bare function/identifier name is searched with
//     `git grep -F` at the rev. Absent => DISAGREE-symbol.
//
//   ARM C — COMMIT SHAS. A 7-40 hex token carrying at least one letter AND one digit
//     (a bare digit run is a PR number or a date, not a sha). Resolved with
//     `git rev-parse <sha>^{commit}`, then `git merge-base --is-ancestor <sha> <rev>`.
//     Resolves-but-not-an-ancestor => DISAGREE-sha: the close cites a commit that never
//     reached main (a stacked PR merged into its parent, a branch that was never merged,
//     a squash that rewrote the sha). DOES NOT RESOLVE => UNRESOLVABLE, printed and
//     NOT counted as a finding: a squash-merge destroys the branch sha, so absence of
//     the object is expected and proves nothing.
//
// THE BLIND SPOT, WHICH THE REPORT ALSO PRINTS: a close_reason that names no path, no
// symbol and no sha CANNOT BE CHECKED THIS WAY. It is counted as UNCHECKABLE and is the
// single largest bucket (3007 of 7851 = 38.3% at the 2026-09-12 census). The
// disagreement rate this tool reports is therefore a rate over the CHECKABLE subset,
// and a FLOOR on the true rate, never an estimate of it. Only re-deriving each close
// from source finds the rest.
//
// THE BLIND SPOT IS NOW RULED ON, and the ruling lives where a close gets WRITTEN, not
// here: internal/cli/tasks_close_evidence_contract.go (task-dfa5723c433382b3), surfaced
// on `bp task close --help` and as an advisory beside a landed close. In short — a
// reason is CHECKABLE when it names one un-elided repo path, one discriminating symbol,
// or one ancestor commit sha, which is exactly what the three arms below read; and the
// rows ALREADY closed without one are recorded as PERMANENTLY UNCHECKABLE rather than
// migrated, because an anchor back-filled by a later reader would turn an honest blind
// spot into a false AGREE. THE UNCHECKABLE COUNT THIS TOOL PRINTS IS THAT RECORD, and it
// re-derives itself on every run instead of rotting in a doc. Measured at origin/main
// c2b5efe91 on 2026-09-13: 2740 UNCHECKABLE of 8023 closed rows (34.1%), the 9587-document
// `bp export --type task` population. THE SAME RUN, BEFORE AND AFTER THE EXTRACTION
// REPAIRS BELOW: UNCHECKABLE 2740 -> 2740 and checkable 5283 -> 5283 (nothing left the
// denominator), DISAGREE 20 -> 11, all 9 departures landing in AGREE and named in the
// commit. The old-rev positive control on the same population — only --rev differing,
// 736646f38 of 2026-07-01 — went 978/5283 = 18.5% -> 948/5283 = 17.9%, so the separation
// from main WIDENED from 46x to 90x. A repair that had bought silence would have shrunk
// that arm, and this is where you check that it did not.
//
// THE SECOND BLIND SPOT: a named artifact that IS present proves only that the NAME
// survives, not that the asserted BEHAVIOUR did. pds-bl-w47-stamp-tripwire-false-positive
// is the worked example and the positive control: its close_reason names
// `api/lib/barkpark/plugins/tasks.ex` and `Criteria.merge_gated?`, both present, so this
// tool scores it AGREE — and that verdict is CORRECT (the close was a policy ruling, and
// internal/cli/tasks_stamp_cmd.go:711 still carries the unanchored substring test on
// purpose, as a frozen legacy-server fallback). An AGREE here means "nothing this
// instrument can see disagrees", never "the close was right".
//
// SELECTION. Recency-weighted without replacement, deterministic in --seed: a row closed
// today has had the least time to be contradicted, so it is the most likely to disagree.
// Weight = exp(-ageDays / --half-life), drawn by Efraimidis-Spirakis (key = u^(1/w),
// take the top N), so the same --seed + --sample over the same input is byte-reproducible.
//
// USAGE
//   node scripts/closed-row-tree-disagreement-sweep.mjs --selftest
//   bp export --type task > /tmp/tasks.ndjson     # exits 1 with a partial-export
//                                                 # warning; the row count is what
//                                                 # matters, and this tool prints it
//   node scripts/closed-row-tree-disagreement-sweep.mjs \
//       --input /tmp/tasks.ndjson --sample 120 --seed 1 \
//       --include pds-bl-w47-stamp-tripwire-false-positive
//
//   --input <path>     NDJSON of type:task documents (required outside --selftest)
//   --sample <n>       rows to draw (default 100); 0 or "all" sweeps the whole population
//   --seed <n>         PRNG seed (default 1)
//   --half-life <d>    recency weighting half-life in days (default 14)
//   --rev <rev>        git rev to check against (default origin/main)
//   --include <id>     force this doc_id into the sample (repeatable) — the positive
//                      control hook: a sweep that cannot adjudicate a row you KNOW is in
//                      the population is broken, and this is how you make it prove it
//   --repo <path>      repo root for the git calls (default: cwd)
//
// EXIT CODES: 0 clean run (findings or not) · 1 usage · 2 refusal (empty/unparseable
// input, unresolvable rev, empty sample) · 3 selftest failure.

import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

const ARGV = process.argv.slice(2);
function flag(name, dflt = null) {
  const i = ARGV.indexOf(`--${name}`);
  if (i === -1) return dflt;
  return ARGV[i + 1] ?? dflt;
}
function flagAll(name) {
  const out = [];
  for (let i = 0; i < ARGV.length; i++) if (ARGV[i] === `--${name}`) out.push(ARGV[i + 1]);
  return out.filter(Boolean);
}
function has(name) { return ARGV.includes(`--${name}`); }

function refuse(msg) {
  console.error(`REFUSED: ${msg}`);
  process.exit(2);
}

// ---------------------------------------------------------------- extraction

const RE_PATH = /(?:\.?[A-Za-z0-9_.\-]+\/)+[A-Za-z0-9_.\-]+\.(?:go|ex|exs|heex|sh|mjs|js|ts|tsx|json|yml|yaml|md|sql)\b/g;
const ARTIFACT_SEGMENTS = new Set(["node_modules", "dist", "_build", "deps", "coverage", "build", ".turbo"]);

// ELIDED PATHS. A closer writing prose abbreviates the middle of a long path:
// "api/lib/.../deploy_runner.ex". The path regex matches the whole token, git cannot
// resolve it, and the row scores DISAGREE for a citation that named a real file. SIX of
// the 27 raw findings in the 2026-09-13 FULL pass (n=7972) were this one class. An
// elided path is UNCHECKABLE BY CONSTRUCTION — the segments it dropped are the ones
// that would resolve it — so it is demoted to advisory, never counted.
export function isElidedPath(p) {
  return (p || "").split("/").some((sg) => /^\.{2,}$/.test(sg));
}

// PROSE FRAGMENTS THAT LOOK LIKE PATHS. A closer writing "7 section-11
// docs/auth.md-versus-router.ex pipeline mismatches" has hyphenated TWO filenames into
// one token; RE_PATH's basename class accepts `-` and `.`, so it swallows the whole
// phrase and git is asked for a file nobody ever named. The signature is SYNTACTIC and
// needs no vocabulary: a known extension immediately followed by a hyphen INSIDE the
// token. One of the 15,255 paths at origin/main c2b5efe91 carries the signature
// (`.go-format-drift-ceiling`) and RE_PATH cannot emit it: it has no `/` and no trailing
// extension, so it never reaches this filter. task-f7b4e355c8ceb074 was the specimen.
const RE_INNER_EXT = /\.(?:go|ex|exs|heex|sh|mjs|js|ts|tsx|json|yml|yaml|md|sql)-/;
export function isProseFragmentPath(p) {
  return RE_INNER_EXT.test(p || "");
}

// MOVED PATHS, THE PURE CORE. Kept out here, and exported, so --selftest can hold it to
// a fixture tree: the UNIQUENESS clause is the safety property, and a clause no test can
// see is a clause a later edit can delete for free.
//
// THE RULE: same basename, and one segment list is a SUBSEQUENCE of the other (segments
// INSERTED or REMOVED, never reordered or SUBSTITUTED), and exactly ONE tree path
// qualifies. Both halves are load-bearing and each is mutation-pinned below.
export function resolveMovedPath(cited, treePaths) {
  const segs = (cited || "").split("/");
  if (segs.length < 2) return null;
  const base = segs[segs.length - 1];
  const isSub = (a, b) => { let i = 0; for (const x of b) if (i < a.length && a[i] === x) i++; return i === a.length; };
  const cands = (treePaths || []).filter((t) => {
    if (t.slice(t.lastIndexOf("/") + 1) !== base) return false;
    const ts = t.split("/");
    return isSub(segs, ts) || isSub(ts, segs);
  });
  return cands.length === 1 ? cands[0] : null;
}

// GIT PATHSPECS. `git cat-file -e origin/main:scripts/format-drift-ceiling.sh -> ABSENT`
// and `remains reachable at git show 6c24833a4:scripts/pdf-support-proof.sh` both name an
// absent path IN ORDER TO REPORT THE RESULT OF A COMMAND, not to assert the tree carries
// it. The tell is again SYNTACTIC, not lexical — the occurrence is preceded by `<rev>:` —
// so this demotion does not depend on a list of English absence-words the way
// RETRACTION_MARKERS does. Demoted only when EVERY occurrence of the path in the reason is
// a pathspec: a path also asserted plainly somewhere else still counts.
// Specimens: hg-w1-format-drift-ceiling, pdf-wc-support-proof.
export function quotedAsGitPathspec(text, needle) {
  const t = text || "";
  if (!needle) return false;
  let i = t.indexOf(needle), seen = 0;
  while (i !== -1) {
    seen++;
    const before = t.slice(0, i);
    if (!/[A-Za-z0-9_./^~^{}-]+:$/.test(before)) return false;
    i = t.indexOf(needle, i + needle.length);
  }
  return seen > 0;
}

// GENERIC SYMBOLS. The MFA arm reads the function name out of `UserSocket.id/1` and
// searches for `id`, which either matches everything or, with -w and the wrong casing,
// nothing. A name this short discriminates nothing: it cannot support a DISAGREE either
// way. task-d67f007715c96828 was the whole DISAGREE-sym count in the FULL pass, and its
// close_reason cites a module that IS on main. Symbols under 4 chars, plus a denylist of
// ubiquitous Elixir/Go callbacks, are dropped before ARM S runs.
const GENERIC_SYMBOLS = new Set(["id", "get", "put", "new", "run", "call", "init", "key", "all", "one", "add", "set", "map", "url", "ok", "do", "up", "down", "start", "stop", "name", "type", "list", "show", "main", "test", "path", "text", "data"]);
export function isGenericSymbol(sym) {
  const s = (sym || "").trim();
  return s.length < 4 || GENERIC_SYMBOLS.has(s.toLowerCase());
}
const RETRACTION_MARKERS = ["filing wrong", "does not exist", "correction", "the file is", "wrong path", "retract", "i was wrong", "no such file", "mis-cited", "miscited",
  // CANCEL-SHAPED: a row cancelled BECAUSE the artifact is gone names the absent path as
  // its whole point. tgw10-bl-stranded-unique-commons-row is the specimen.
  "premise expired", "no longer holds", "no longer exists", "nothing remains", "is still absent", "returns zero hits",
  // SELF-DECLARED-UNCOMMITTED: the closer names the path to say WHERE THE REPRO LIVES —
  // "Probes are on branch killswitch-probe … uncommitted", "untracked
  // .claude/workflows/felix-audit-wave-paper.json". A stale close never volunteers that
  // its artifact is not committed, so these fail SAFE: a marker this list is MISSING
  // costs an extra lead, never a missed one. Specimens: task-785908d0a0ccb6bb,
  // spd-bl-primary-checkout-diverged, dr-w13-s6-publish-clock-first-caller.
  // NOTE: "is gone from" and "-> absent" USED to live here. They are TREE ASSERTIONS, not
  // evidence, and they are now handled by assertsAbsentAt() below — see the doctrine note
  // there for why a demotion was the wrong disposal for them.
  "uncommitted", "untracked", "never landed"];
export function retractedNear(text, needle) {
  const i = (text || "").indexOf(needle);
  if (i === -1) return false;
  const w = (text.slice(Math.max(0, i - 260), i + needle.length + 260)).toLowerCase();
  return RETRACTION_MARKERS.some((m) => w.includes(m));
}

// ---------------------------------------------------------------- POLARITY
//
// ASK THE TREE, DO NOT TRUST THE PHRASE.
//
// "cloud/lib/barkpark_cloud/publish_clock.ex is GONE from origin/main" is not evidence.
// It is a CLOSER'S ASSERTION ABOUT THE TREE — the one thing a closer is least entitled to
// be believed about, and precisely the claim this instrument exists to check. Demoting it
// on the strength of the phrase (which is what RETRACTION_MARKERS did until this commit)
// is CIRCULAR: the sweep accepted, as grounds for AGREE, exactly the kind of statement it
// was built to verify.
//
// THE DEEPER FAULT THE DEMOTION WAS PAPERING OVER IS POLARITY. The ARM P loop assumes
// every path a close_reason names is asserted PRESENT, so it fires when the path is
// ABSENT. A cancel-shaped reason asserts the OPPOSITE. For those citations the truth
// table is INVERTED:
//
//     reason asserts      tree says      verdict
//     ------------------  -------------  ----------------------------------------
//     present (default)   present        AGREE
//     present (default)   absent         DISAGREE-path        (the classic stale close)
//     ABSENT              absent         AGREE — EARNED, not trusted: git agreed
//     ABSENT              PRESENT        DISAGREE-present     (NEW: a stale cancel)
//
// The bottom row is a detection the instrument could not make AT ALL before this commit,
// and NOT because of the marker: for a present path the ARM P loop `continue`s before
// retractedNear is ever consulted. Deleting the markers would therefore NOT have bought
// this case — only inverting the polarity does. A row that says "X is gone from main"
// while X sits in the tree is a real stale close, and it used to score AGREE in silence.
//
// ADJACENCY, NOT PROXIMITY — AND THIS IS A MEASURED CHOICE, NOT CAUTION. retractedNear's
// +/-260-char window is right for a DEMOTION (a marker it misses costs one extra lead) and
// catastrophic for a PROMOTION to DISAGREE (a marker it over-fires manufactures a finding).
// Measured over the 2026-09-13 closed population (9,609 documents exported, 8,157 closed):
// a +/-90-char window with these markers produced 12 hits, of which NINE were false — the
// marker belonged to a neighbouring clause ("nothing remains for this row to build", "the
// premise is gone from main", a quoted test comment, a grep result about a symbol INSIDE
// the file). Requiring the claim to sit IMMEDIATELY AFTER the citation, separated only by
// quoting punctuation, produced 2 hits and ZERO false positives on the same population.
// So: the marker must FOLLOW the path and must be ADJACENT to it.
//
// Two markers from the wider cancel vocabulary are deliberately NOT here. "nothing
// remains" is boilerplate ("…so nothing remains for this row to build") and appears on 100+
// closed rows. "returns zero hits" asserts a GREP RESULT INSIDE a file, not the file's
// absence — `git grep -n rescue … -- api/lib/barkpark/content/writer.ex returns ZERO hits`
// is a claim ABOUT a file that is very much present. Both would over-fire.
//
// "uncommitted" and "untracked" stay in RETRACTION_MARKERS and are NOT polarity markers.
// They are statements AGAINST the closer's own interest — a stale close never volunteers
// that its artifact was never committed — so they are evidence about the world, not
// assertions about the tree, and they are not the class this arm polices.
const ABSENCE_ASSERTION_MARKERS = ["is gone from", "-> absent", "no longer exists", "is still absent"];
// punctuation a closer may put between the citation and the claim: a closing backtick, a
// quote, whitespace. Anything WORDY in the gap means the claim belongs to another clause.
const RE_ADJACENCY_GAP = /^[`'"\s]*/;
export function assertsAbsentAt(text, needle) {
  const lo = (text || "").toLowerCase(), nl = (needle || "").toLowerCase();
  if (!nl) return null;
  let i = lo.indexOf(nl);
  while (i !== -1) {
    const end = i + nl.length;
    const tail = lo.slice(end).replace(RE_ADJACENCY_GAP, "");
    for (const m of ABSENCE_ASSERTION_MARKERS) if (tail.startsWith(m)) return m;
    i = lo.indexOf(nl, end);
  }
  return null;
}
const RE_MFA = /\b[A-Z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*\.([a-z_][A-Za-z0-9_?!]*)\/\d\b/g;
const RE_BACKTICK = /`([A-Za-z_][A-Za-z0-9_.?!]{3,})`/g;
const RE_HEX = /\b[0-9a-f]{7,40}\b/g;

export function looksLikeSha(tok) {
  if (tok.length < 7 || tok.length > 40) return false;
  return /[a-f]/.test(tok) && /[0-9]/.test(tok);
}

export function extractArtifacts(text) {
  const t = text || "";
  const paths = [...new Set((t.match(RE_PATH) || []))];
  const symbols = new Set();
  for (const m of t.matchAll(RE_MFA)) symbols.add(m[1]);
  for (const m of t.matchAll(RE_BACKTICK)) {
    const s = m[1];
    // a backticked path is already ARM P's; a backticked bare word is ARM S's
    if (!s.includes("/") && !/\.(go|ex|exs|sh|mjs|js|ts|json|yml|yaml|md)$/.test(s)) symbols.add(s);
  }
  const shas = [...new Set((t.match(RE_HEX) || []).filter(looksLikeSha))];
  return { paths, symbols: [...symbols], shas };
}

// ---------------------------------------------------------------- sampling

export function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Efraimidis-Spirakis weighted sampling without replacement: key = u^(1/w).
export function weightedSample(rows, n, seed, weightOf) {
  const rnd = mulberry32(seed);
  const keyed = rows.map((r) => {
    const w = Math.max(weightOf(r), 1e-9);
    const u = Math.max(rnd(), 1e-12);
    return { r, key: Math.pow(u, 1 / w) };
  });
  keyed.sort((a, b) => b.key - a.key);
  return keyed.slice(0, n).map((k) => k.r);
}

// ---------------------------------------------------------------- git

function makeGit(repo, rev) {
  const run = (args) =>
    execFileSync("git", ["-C", repo, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  let revSha;
  try { revSha = run(["rev-parse", `${rev}^{commit}`]).trim(); }
  catch { refuse(`git rev '${rev}' does not resolve in ${repo} — nothing was checked`); }
  const pathCache = new Map(), symCache = new Map(), shaCache = new Map();
  let treePaths = null;
  const tree = () => {
    if (treePaths) return treePaths;
    const all = run(["ls-tree", "-r", "--name-only", revSha]).split("\n").filter(Boolean);
    if (!all.length) refuse(`git ls-tree at ${revSha} returned ZERO paths — the tree could not be read`);
    treePaths = all;
    return treePaths;
  };
  // MOVED PATHS. The suffix arm only forgives segments dropped from the FRONT of a
  // citation. The commonest real drift is a directory inserted or removed in the MIDDLE —
  // studio/components.ex became studio/studio_live/components.ex; controllers/v1/
  // capabilities_controller.ex lost its v1/ segment; cloud/router.ex is shorthand for
  // cloud/lib/barkpark_cloud/web/router.ex. A rename is NOT a stale close: the change the
  // reason asserts is in the tree, under a name the tree moved. So this RESOLVES the
  // citation rather than demoting it — the row stays CHECKABLE and scores AGREE, and the
  // denominator the disagreement rate divides by is unchanged.
  //
  // THE RULE: same basename, and one path's segment list is a SUBSEQUENCE of the other's
  // (segments inserted or removed, never reordered or substituted), and the match is
  // UNIQUE in the tree. Uniqueness is the whole safety property — two router.ex files
  // would resolve to neither. A citation whose basename appears nowhere is untouched and
  // still DISAGREEs, which is the shape a genuinely stale close has.
  let byBase = null;
  function movedTo(p) {
    const segs = p.split("/");
    if (segs.length < 2) return null;
    if (!byBase) {
      byBase = new Map();
      for (const t of tree()) {
        const b = t.slice(t.lastIndexOf("/") + 1);
        if (!byBase.has(b)) byBase.set(b, []);
        byBase.get(b).push(t);
      }
    }
    // the basename index is a lookup shortcut only; resolveMovedPath re-checks the
    // basename itself, so the two can never disagree about what qualifies.
    return resolveMovedPath(p, byBase.get(segs[segs.length - 1]) || []);
  }

  let topLevel = null;
  return {
    revSha,
    isRepoRoot(seg) {
      if (!topLevel) {
        const e = run(["ls-tree", "--name-only", revSha]).split("\n").filter(Boolean);
        if (!e.length) refuse(`git ls-tree at ${revSha} returned ZERO top-level entries`);
        topLevel = new Set(e);
      }
      return topLevel.has(seg);
    },
    // "exact"  the path is in the tree verbatim
    // "suffix" the reason quoted a PARTIAL path (e.g. tasks/landed.ex for
    //          api/lib/barkpark/plugins/tasks/landed.ex) that resolves uniquely
    // "absent" no path in the tree ends with it
    pathState(p) {
      if (pathCache.has(p)) return pathCache.get(p);
      let st = "absent";
      try { run(["cat-file", "-e", `${revSha}:${p}`]); st = "exact"; }
      catch {
        const suf = "/" + p;
        if (tree().some((t) => t.endsWith(suf))) st = "suffix";
        else if (movedTo(p)) st = "moved";
      }
      pathCache.set(p, st); return st;
    },
    movedTo,
    hasSymbol(s) {
      if (symCache.has(s)) return symCache.get(s);
      let ok = true;
      try { run(["grep", "-l", "-F", "-e", s, revSha]); } catch { ok = false; }
      symCache.set(s, ok); return ok;
    },
    // "ancestor" | "orphan" | "unresolvable"
    shaState(s) {
      if (shaCache.has(s)) return shaCache.get(s);
      let st;
      try {
        run(["rev-parse", "-q", "--verify", `${s}^{commit}`]);
        try { run(["merge-base", "--is-ancestor", s, revSha]); st = "ancestor"; }
        catch { st = "orphan"; }
      } catch { st = "unresolvable"; }
      shaCache.set(s, st); return st;
    },
    // PROVENANCE FOR A LEAD, NOT A DEMOTION. Three of the 2026-09-13 artefact classes —
    // DELETION-IS-THE-WORK (the close SHIPPED the removal), CONSOLIDATED-AWAY (a later PR
    // folded the file away and the behaviour survives elsewhere) and HISTORICAL-BLOB —
    // are all "main HAD this and deliberately dropped it". They are NOT demoted: a close
    // that asserts a file main deleted is exactly the shape a genuinely stale close has,
    // and a reader must rule on which one it is. What the instrument owes that reader is
    // the commit, printed beside the lead, so the ruling costs one glance instead of a
    // git archaeology session. Zero findings are lost to this line.
    deletedBy(p) {
      try {
        const out = run(["log", "--diff-filter=D", "--max-count=1", "--format=%h %s", revSha, "--", p]).trim();
        return out || null;
      } catch { return null; }
    },
  };
}

// ---------------------------------------------------------------- adjudication

export function isClosed(d) {
  return d.lifecycle_status === "done" || d.lifecycle_status === "cancelled" || d.disposition === "closed";
}
export function reasonText(d) {
  return [d.close_reason, d.disposition_reason].filter(Boolean).join("\n");
}
export function closedAt(d) {
  return (d.claim && d.claim.closed_at) || d._updatedAt || d._createdAt || null;
}

function adjudicate(d, git) {
  const text = reasonText(d);
  const { paths, symbols, shas } = extractArtifacts(text);
  const advisory = [];

  // ARM P candidates: drop build artefacts (never committed) and paths whose first
  // segment is not a top-level entry of the tree — those are URL routes (/v1/openapi.json)
  // and prose fragments (".ts/.d.ts"), not repo paths. Both classes were 4 of the 8 raw
  // "findings" in the 2026-09-12 n=150 run; every one was an extraction artefact.
  const pathCands = paths.filter((p) => {
    const segs = p.split("/");
    if (segs.some((sg) => ARTIFACT_SEGMENTS.has(sg))) { advisory.push(`artifact-path ${p}`); return false; }
    if (isElidedPath(p)) { advisory.push(`elided-path ${p}`); return false; }
    if (isProseFragmentPath(p)) { advisory.push(`prose-fragment ${p}`); return false; }
    return true;
  });

  if (!pathCands.length && !symbols.length && !shas.length) {
    return { verdict: "UNCHECKABLE", line: "(close_reason names no path, no symbol and no sha — ARM BLIND)", advisory };
  }

  const verifiedAbsences = [];
  for (const p of pathCands) {
    const st = git.pathState(p);
    const present = st === "exact" || st === "suffix" || st === "moved";
    // POLARITY ARM. This citation is asserted ABSENT, so the tree is asked the INVERTED
    // question. Note this runs BEFORE the present-`continue` below: that ordering is the
    // whole new detection, because a present path never reached the demotion at all.
    const claim = assertsAbsentAt(text, p);
    if (claim) {
      if (!present) {
        // EARNED, NOT TRUSTED. git was asked and git agreed with the closer.
        verifiedAbsences.push(p);
        advisory.push(`absence-claim-verified ${p} ("${claim}") — ABSENT at ${git.revSha.slice(0, 9)}, as the reason asserts`);
        continue;
      }
      return {
        verdict: "DISAGREE-present",
        line: `asserts ${p} "${claim}" the tree — but it is PRESENT at ${git.revSha.slice(0, 9)} (${st}${st === "moved" ? ` -> ${git.movedTo(p)}` : ""})`,
        advisory,
      };
    }
    // "moved" is PRESENT, not absent: the tree carries the file under a name that gained
    // or lost a directory segment. Resolving it here is what keeps the row CHECKABLE.
    if (present) continue;
    // THE RETRACTION BLIND SPOT: a close_reason that names an absent path IN ORDER TO
    // CORRECT SOMEBODY is indistinguishable, to any grep, from one that names it because
    // the close is stale. Two of the eight raw findings were exactly this ("Filing wrong:
    // cites api/lib/barkpark/capabilities.ex … the file is …/plugins/capabilities.ex").
    // We demote on a retraction marker within ±260 chars and PRINT it; we never count it.
    if (retractedNear(text, p)) { advisory.push(`retracted-path ${p}`); continue; }
    // NOT A REPO PATH AT ALL. A token that matches neither a file, nor any file's
    // suffix, nor even a top-level directory of the repo is a URL route
    // (`/v1/openapi.json`) or a prose fragment (`ZERO .ts/.d.ts files`) — both were raw
    // "findings" in the n=150 run. A stale close cites something that USED to exist and
    // therefore still roots at a real top-level dir; this class never did.
    if (!git.isRepoRoot(p.split("/")[0])) { advisory.push(`not-a-repo-path ${p}`); continue; }
    if (quotedAsGitPathspec(text, p)) { advisory.push(`git-pathspec ${p} (quoted as <rev>:${p}, a command result, not a tree assertion)`); continue; }
    const del = git.deletedBy(p);
    if (del) advisory.push(`deleted-from-main ${p} by ${del}`);
    return { verdict: "DISAGREE-path", line: `names ${p} — absent at ${git.revSha.slice(0, 9)}${del ? ` (deleted by ${del})` : ""}`, advisory };
  }

  for (const s of symbols) if (isGenericSymbol(s)) advisory.push(`generic-symbol ${s}`);
  const symCands = symbols.filter((s) => !isGenericSymbol(s));
  const missSyms = symCands.filter((s) => !git.hasSymbol(s));
  const liveMissSyms = missSyms.filter((s) => !retractedNear(text, s));
  for (const s of missSyms) if (retractedNear(text, s)) advisory.push(`retracted-symbol ${s}`);
  if (liveMissSyms.length) {
    return { verdict: "DISAGREE-symbol", line: `names symbol ${liveMissSyms[0]} — no match at ${git.revSha.slice(0, 9)}`, advisory };
  }

  // ARM C IS ADVISORY ONLY, AND THIS IS A MEASURED DEMOTION, NOT CAUTION.
  // A sha that resolves locally but is NOT an ancestor of main is the NORMAL shape for a
  // cited PR head: the squash-merge rewrote it, and the fork still has the branch object.
  // task-19dfc803a7ed56fa was the whole DISAGREE-sha count in the n=150 run, and its
  // 5df2cea8c is a PR head the closer quoted while RETRACTING a claim about it. Counting
  // that as a stale close is a manufactured finding, so ARM C reports and never counts.
  for (const s of shas) {
    const st = git.shaState(s);
    if (st === "orphan") advisory.push(`branch-sha ${s} (resolves, not an ancestor — normal for a squashed PR head)`);
    else if (st === "unresolvable") advisory.push(`unresolvable-sha ${s}`);
  }

  const anchorPath = pathCands.find((p) => git.pathState(p) !== "absent");
  // A row whose only anchor is a VERIFIED ABSENCE must not be reported as "present at
  // <sha>" — that line would assert the opposite of what was checked. It agrees because
  // the tree was asked and matched the claim, and the line has to say exactly that.
  if (!anchorPath && verifiedAbsences.length) {
    return {
      verdict: "AGREE",
      line: `absence claim EARNED: ${verifiedAbsences[0]} is ABSENT at ${git.revSha.slice(0, 9)}, as the reason asserts`,
      advisory,
    };
  }
  const anchor =
    anchorPath ? `path ${anchorPath} (${git.pathState(anchorPath)}${git.pathState(anchorPath) === "moved" ? ` -> ${git.movedTo(anchorPath)}` : ""})` :
    symbols[0] ? `symbol ${symbols[0]}` :
    shas[0] ? `sha ${shas[0]} (${git.shaState(shas[0])})` : "(advisory only)";
  return { verdict: "AGREE", line: `${anchor} present at ${git.revSha.slice(0, 9)}`, advisory };
}

// ---------------------------------------------------------------- selftest

function selftest() {
  let fails = 0;
  const eq = (name, got, want) => {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g !== w) { console.error(`FAIL ${name}\n  got  ${g}\n  want ${w}`); fails++; }
    else console.log(`ok   ${name}`);
  };
  eq("sha: hex with letters+digits", looksLikeSha("70ff34f9fd"), true);
  eq("sha: all digits is a PR/date, not a sha", looksLikeSha("202609011"), false);
  eq("sha: all letters is a word", looksLikeSha("deadbeef".replace(/[0-9]/g, "a")), false);
  eq("sha: too short", looksLikeSha("70ff3"), false);

  const a = extractArtifacts(
    "see api/lib/barkpark/tasks/criteria.ex and Barkpark.Tasks.Criteria.merge_gated?/1, PR #13006 70ff34f9fd"
  );
  eq("path extracted", a.paths, ["api/lib/barkpark/tasks/criteria.ex"]);
  eq("mfa function extracted", a.symbols, ["merge_gated?"]);
  eq("sha extracted, PR number rejected", a.shas, ["70ff34f9fd"]);

  const b = extractArtifacts("closed as duplicate of the earlier row, nothing shipped");
  eq("blind spot: nothing extractable", [b.paths.length, b.symbols.length, b.shas.length], [0, 0, 0]);

  // the sample must be deterministic in the seed and must differ across seeds
  const rows = Array.from({ length: 50 }, (_, i) => ({ _id: `r${i}`, w: (i % 5) + 1 }));
  const s1 = weightedSample(rows, 10, 7, (r) => r.w).map((r) => r._id);
  const s1b = weightedSample(rows, 10, 7, (r) => r.w).map((r) => r._id);
  const s2 = weightedSample(rows, 10, 8, (r) => r.w).map((r) => r._id);
  eq("sample is deterministic in the seed", s1, s1b);
  eq("a different seed draws a different sample", s1.join() !== s2.join(), true);
  // recency weighting must actually bias: weight 5 rows should be over-represented
  const heavy = weightedSample(rows, 10, 3, (r) => Math.pow(4, r.w)).filter((r) => r.w >= 4).length;
  eq("weighting biases toward heavy rows (>=7 of 10)", heavy >= 7, true);

  // --- the four artefact classes measured in the 2026-09-12 n=150 raw run.
  // Every one of them was a raw "DISAGREE-path" that a human read and threw out; these
  // assertions are what stop them coming back.
  eq("leading dot survives (.github/required-checks.json was read as github/…)",
     extractArtifacts("see .github/required-checks.json:72").paths, [".github/required-checks.json"]);
  eq("artifact segment is recognised (dist/index.mjs is never committed)",
     "dist".split("/").every((sg) => ARTIFACT_SEGMENTS.has(sg)), true);
  eq("retraction marker demotes a path quoted in order to CORRECT it",
     retractedNear("Filing wrong: cites api/lib/barkpark/capabilities.ex:2652 — the file is api/lib/barkpark/plugins/capabilities.ex",
                   "api/lib/barkpark/capabilities.ex"), true);
  eq("retraction marker demotes a path a closer says DOES NOT EXIST",
     retractedNear("I previously called this row still-live off a grep against cloud/priv/static/__preview__/__css_check.mjs — a path that DOES NOT EXIST on main.",
                   "cloud/priv/static/__preview__/__css_check.mjs"), true);
  eq("cancel-shaped reason demotes the absent artifact it exists to report",
     retractedNear("Premise no longer holds: git cat-file -e origin/main:tooling/grip/ledger/w34-chatlive-belt-semantics.recipe.md fails at 3c25e04af9.",
                   "tooling/grip/ledger/w34-chatlive-belt-semantics.recipe.md"), true);
  eq("a plain citation is NOT demoted",
     retractedNear("the guard lives in scripts/pr-task-gate.sh and is green", "scripts/pr-task-gate.sh"), false);

  // --- the two artefact classes measured in the 2026-09-13 FULL pass (n=7972).
  // Together they were 7 of that pass's 27 raw findings, and every one was adjudicated
  // FALSE by reading the row's own close_reason.
  eq("elided path is demoted (api/lib/.../tenancy.ex named 6 of 27 raw findings)",
     isElidedPath("api/lib/.../tenancy.ex"), true);
  eq("a real path with a dotfile segment is NOT elided",
     isElidedPath(".github/workflows/ci.yml"), false);
  eq("a relative-looking path is NOT elided",
     isElidedPath("api/lib/barkpark/tasks/criteria.ex"), false);
  eq("generic symbol is dropped (UserSocket.id/1 -> `id` was the whole DISAGREE-sym count)",
     isGenericSymbol("id"), true);
  eq("a short-but-listed callback is dropped", isGenericSymbol("init"), true);
  eq("a discriminating symbol survives", isGenericSymbol("merge_gated?"), false);
  eq("the MFA arm still extracts the generic name (the DROP happens in adjudicate)",
     extractArtifacts("UserSocket.id/1 is token-derived").symbols.includes("id"), true);

  // --- THE CLOSE-PROSE CONTRACT (task-dfa5723c433382b3). The ruling's definition of a
  // CHECKABLE close and this instrument's three arms have to be ONE definition, or the
  // contract teaches a rule the sweep does not enforce. These four assert the boundary
  // in both directions on the ruling's own worked examples.
  const anchored = extractArtifacts("fixed in api/lib/barkpark/tasks/close.ex");
  eq("contract: a repo path alone makes a close CHECKABLE",
     [anchored.paths.length > 0, isElidedPath(anchored.paths[0])], [true, false]);
  eq("contract: a backticked discriminating symbol alone makes a close CHECKABLE",
     extractArtifacts("the guard is `merge_gated?` and it is live").symbols.filter((x) => !isGenericSymbol(x)),
     ["merge_gated?"]);
  eq("contract: an ancestor-shaped sha alone makes a close CHECKABLE",
     extractArtifacts("landed as 70ff34f9fd on main").shas, ["70ff34f9fd"]);
  const bare = extractArtifacts("closed as duplicate of the earlier row, nothing shipped");
  eq("contract: a reason naming none of the three is UNCHECKABLE, not AGREE",
     [bare.paths.length, bare.symbols.filter((x) => !isGenericSymbol(x)).length, bare.shas.length],
     [0, 0, 0]);

  // --- the 2026-09-13 artefact classes adjudicated in the SECOND full pass (n=8006 at
  // origin/main c2b5efe91): 20 raw DISAGREE findings, 20 false. These assertions pin the
  // three extraction repairs and, just as importantly, pin the classes NOT repaired.

  // MOVED-PATH. A resolution, not a demotion: the row stays CHECKABLE and scores AGREE.
  // The fixture is the real shape of all four 2026-09-13 specimens, including the
  // AMBIGUOUS one (two components.ex under studio/) that must NOT resolve.
  const TREE = [
    "api/test/barkpark/tenancy/workspace_bundle_test.exs",
    "api/lib/barkpark_web/controllers/capabilities_controller.ex",
    "api/lib/barkpark_web/live/studio/studio_live/components.ex",
    "api/lib/barkpark_web/live/studio/api_tester_live/components.ex",
    "api/lib/barkpark_web/router.ex",
    "cloud/lib/barkpark_cloud/web/router.ex",
    "scripts/pr-task-gate.sh",
  ];
  eq("moved-path: a directory INSERTED mid-path resolves (tenancy/)",
     resolveMovedPath("api/test/barkpark/workspace_bundle_test.exs", TREE),
     "api/test/barkpark/tenancy/workspace_bundle_test.exs");
  eq("moved-path: a directory the citation has and the tree lost resolves too (v1/)",
     resolveMovedPath("api/lib/barkpark_web/controllers/v1/capabilities_controller.ex", TREE),
     "api/lib/barkpark_web/controllers/capabilities_controller.ex");
  eq("moved-path: prose shorthand resolves when one segment disambiguates it (cloud/router.ex)",
     resolveMovedPath("cloud/router.ex", TREE), "cloud/lib/barkpark_cloud/web/router.ex");
  // THE UNIQUENESS CLAUSE, MUTATION-PINNED. Relaxing `cands.length === 1` to `>= 1` makes
  // this return api_tester_live/components.ex and silences a real lead.
  eq("moved-path: TWO candidates resolve to NEITHER — ambiguity stays a DISAGREE",
     resolveMovedPath("api/lib/barkpark_web/live/studio/components.ex", TREE), null);
  // THE SUBSEQUENCE CLAUSE, MUTATION-PINNED. Relaxing the filter to basename-only makes
  // this resolve to tenancy/ and forgives a segment the citation got WRONG, not moved.
  eq("moved-path: a SUBSTITUTED segment does not resolve, even with a unique basename",
     resolveMovedPath("api/test/barkpark/WRONGDIR/workspace_bundle_test.exs", TREE), null);
  eq("moved-path: a basename the tree does not have at all stays absent (the stale-close shape)",
     resolveMovedPath("scripts/this-file-never-existed-anywhere.sh", TREE), null);

  // PROSE-FRAGMENT. Two filenames hyphenated into one token by a closer writing prose.
  eq("prose-fragment: docs/auth.md-versus-router.ex is not a path",
     isProseFragmentPath("docs/auth.md-versus-router.ex"), true);
  eq("prose-fragment: a real hyphenated filename is NOT a fragment",
     isProseFragmentPath("scripts/closed-row-tree-disagreement-sweep.mjs"), false);
  eq("prose-fragment: a real dotted-and-hyphenated filename is NOT a fragment",
     isProseFragmentPath(".github/workflows/shell-harnesses.yml"), false);

  // GIT-PATHSPEC. Syntactic, not lexical: `<rev>:<path>` is a command result.
  eq("git-pathspec: `origin/main:<path>` is a quoted command, not a tree assertion",
     quotedAsGitPathspec("`git cat-file -e origin/main:scripts/format-drift-ceiling.sh` -> ABSENT",
                         "scripts/format-drift-ceiling.sh"), true);
  eq("git-pathspec: a historical blob reference is one too",
     quotedAsGitPathspec("remains reachable at git show 6c24833a4:scripts/pdf-support-proof.sh",
                         "scripts/pdf-support-proof.sh"), true);
  eq("git-pathspec: a path ALSO asserted plainly somewhere else is NOT demoted",
     quotedAsGitPathspec("shipped scripts/pdf-support-proof.sh; see git show 6c24833a4:scripts/pdf-support-proof.sh",
                         "scripts/pdf-support-proof.sh"), false);
  eq("git-pathspec: a plain citation is NOT a pathspec",
     quotedAsGitPathspec("the guard lives in scripts/pr-task-gate.sh", "scripts/pr-task-gate.sh"), false);

  // SELF-DECLARED-UNCOMMITTED / CANCEL-SHAPED. The marker list fails SAFE: a phrase it is
  // MISSING costs an extra lead, never a missed one, which is why extending it is cheap.
  eq("self-declared: `uncommitted` demotes a path whose closer says it is not committed",
     retractedNear("Probes are on branch killswitch-probe (worktree .claude/worktrees/killswitch-probe), uncommitted. api/killswitch_probe.exs is the repro.",
                   "api/killswitch_probe.exs"), true);
  eq("the added markers do NOT demote a plain shipping claim",
     retractedNear("shipped the guard at scripts/pr-task-gate.sh and wired it into CI", "scripts/pr-task-gate.sh"), false);

  // --- POLARITY: THE TREE-ASSERTION CLASS IS ASKED, NOT TRUSTED (task-e3e693ec0be90597).
  // "X is GONE from origin/main" is a closer's assertion ABOUT THE TREE, which is the one
  // claim a closer is least entitled to be believed about. It used to be a demotion
  // marker; demoting it meant the sweep accepted, as grounds for AGREE, exactly the kind
  // of statement it exists to verify. These cases pin the replacement: adjacency-gated
  // detection, then an INVERTED check against git.

  // (1) THE MARKER NO LONGER DEMOTES. This is the retired behaviour, pinned so a later
  // edit cannot quietly restore the circularity by putting the phrase back in the list.
  eq("polarity: `is gone from` is NO LONGER a demotion marker — the tree decides now",
     retractedNear("cloud/lib/barkpark_cloud/publish_clock.ex is GONE from origin/main, removed by a5260f609a (#11083)",
                   "cloud/lib/barkpark_cloud/publish_clock.ex"), false);
  eq("polarity: `-> ABSENT` is NO LONGER a demotion marker either",
     retractedNear("`git cat-file -e origin/main:scripts/format-drift-ceiling.sh` -> ABSENT", "scripts/format-drift-ceiling.sh"), false);

  // (2) DETECTION. The real specimens, verbatim from the two live rows that carry the
  // shape: dr-w13-s6-publish-clock-first-caller and hg-w1-format-drift-ceiling.
  eq("polarity: an absence assertion is DETECTED on the live `is GONE from` specimen",
     assertsAbsentAt("cloud/lib/barkpark_cloud/publish_clock.ex is GONE from origin/main, removed by a5260f609a (#11083)",
                     "cloud/lib/barkpark_cloud/publish_clock.ex"), "is gone from");
  eq("polarity: a closing backtick between citation and claim is still ADJACENT",
     assertsAbsentAt("`git cat-file -e origin/main:scripts/format-drift-ceiling.sh` -> ABSENT; next",
                     "scripts/format-drift-ceiling.sh"), "-> absent");
  eq("polarity: `no longer exists` and `is still absent` are the same claim shape",
     [assertsAbsentAt("scripts/x.sh no longer exists on main", "scripts/x.sh"),
      assertsAbsentAt("scripts/x.sh is still absent at HEAD", "scripts/x.sh")],
     ["no longer exists", "is still absent"]);
  eq("polarity: a plain citation asserts nothing about absence",
     assertsAbsentAt("the guard lives in scripts/pr-task-gate.sh and is green", "scripts/pr-task-gate.sh"), null);

  // (3) ADJACENCY, MUTATION-PINNED. Widening the gap to retractedNear's +/-260 chars makes
  // all four of these fire, and every one of them is FALSE — measured: a +/-90-char window
  // over the 2026-09-13 closed population produced 12 hits of which NINE were this shape.
  // Each of these manufactured a DISAGREE that a human would have to throw out.
  eq("polarity: a marker in a NEIGHBOURING clause does not attach (the premise is gone, not the file)",
     assertsAbsentAt("the premise is gone from main. Control grep on origin/main: cloud/test/barkpark_cloud/payload_key_set_census_test.exs carries ZERO notes",
                     "cloud/test/barkpark_cloud/payload_key_set_census_test.exs"), null);
  eq("polarity: a marker BEFORE the citation does not attach",
     assertsAbsentAt("NO LONGER EXISTS ANYWHERE. The criterion evidence states that the final line of docs/INDEX.md reads",
                     "docs/INDEX.md"), null);
  eq("polarity: the NEXT command's path is not covered by the PREVIOUS command's verdict",
     assertsAbsentAt("`git cat-file -e origin/main:scripts/format-drift-ceiling.sh` -> ABSENT; `git show origin/main:.github/workflows/elixir.yml | grep -n advisory` -> line 198",
                     ".github/workflows/elixir.yml"), null);
  eq("polarity: a line-number suffix breaks adjacency (a quoted test comment is not a claim)",
     assertsAbsentAt("api/test/barkpark/studio_chat/stream_segments_test.exs:459  \"the swallow is gone from the converter\"",
                     "api/test/barkpark/studio_chat/stream_segments_test.exs"), null);

  // (4) THE TWO MARKERS DELIBERATELY EXCLUDED FROM THE POLARITY SET. "nothing remains" is
  // boilerplate on 100+ closed rows; "returns zero hits" asserts a grep result INSIDE a
  // file that is very much present. Both are adjacent in real prose, so only their
  // ABSENCE FROM THE MARKER SET stops them — which is what this pins.
  eq("polarity: `nothing remains` is boilerplate, NOT an absence assertion about the path",
     assertsAbsentAt("Sweep verdict: scripts/absent-context-census.sh nothing remains for this row to build",
                     "scripts/absent-context-census.sh"), null);
  eq("polarity: `returns zero hits` is a claim INSIDE a present file, not about its existence",
     assertsAbsentAt("git grep -n rescue origin/main -- api/lib/barkpark/content/writer.ex returns ZERO hits",
                     "api/lib/barkpark/content/writer.ex"), null);

  // (5) THE INVERTED TRUTH TABLE, END TO END, against a FIXTURE GIT. Absent-and-asserted
  // -absent is AGREE and must say WHY; present-and-asserted-absent is the new DISAGREE.
  // The present arm has NO live specimen in the 2026-09-13 population — it is constructed
  // here, and it is the whole reason this commit exists: before it, a row claiming a file
  // was gone while the file sat in the tree scored AGREE in silence, because ARM P
  // `continue`d on a present path before any demotion was consulted.
  const FAKEGIT = {
    revSha: "abcdef1234567890",
    isRepoRoot: (seg) => ["scripts", "cloud", "api"].includes(seg),
    pathState: (p) => (p === "scripts/pr-task-gate.sh" ? "exact" : "absent"),
    movedTo: () => null,
    hasSymbol: () => true,
    shaState: () => "ancestor",
    deletedBy: () => null,
  };
  const gone = adjudicate({ close_reason: "cancelled: scripts/format-drift-ceiling.sh is gone from origin/main" }, FAKEGIT);
  eq("polarity: asserted ABSENT + tree ABSENT = AGREE, and the line says EARNED not present",
     [gone.verdict, /absence claim EARNED/.test(gone.line), /present at/.test(gone.line)], ["AGREE", true, false]);
  eq("polarity: the earned AGREE records the claim it verified in an advisory",
     gone.advisory.some((a) => a.startsWith("absence-claim-verified scripts/format-drift-ceiling.sh")), true);
  const stillThere = adjudicate({ close_reason: "cancelled: scripts/pr-task-gate.sh is gone from origin/main, nothing to do" }, FAKEGIT);
  eq("polarity: asserted ABSENT + tree PRESENT = DISAGREE-present (the NEW detection)",
     [stillThere.verdict, /PRESENT at/.test(stillThere.line)], ["DISAGREE-present", true]);
  eq("polarity: an ordinary stale close is UNCHANGED — asserted present, tree absent, DISAGREE-path",
     adjudicate({ close_reason: "shipped the guard at scripts/format-drift-ceiling.sh" }, FAKEGIT).verdict, "DISAGREE-path");
  eq("polarity: an ordinary good close is UNCHANGED — asserted present, tree present, AGREE",
     adjudicate({ close_reason: "shipped the guard at scripts/pr-task-gate.sh" }, FAKEGIT).verdict, "AGREE");

  // THE CLASSES DELIBERATELY LEFT AS FINDINGS. Demoting these would buy silence:
  // CONSOLIDATED-AWAY is exactly the shape a genuinely stale close has (the close says
  // present, main says absent), and CROSS-REPO / PLANNED-PATH have no mechanical tell that
  // does not read intent out of prose. They stay DISAGREE and get a provenance advisory.
  eq("not demoted: a cross-repo path has no syntactic tell, so it stays a lead",
     [isProseFragmentPath("scripts/check-measure.mjs"),
      quotedAsGitPathspec("scripts/check-measure.mjs a real blocking CI gate on jarl-website", "scripts/check-measure.mjs"),
      retractedNear("scripts/check-measure.mjs a real blocking CI gate on jarl-website", "scripts/check-measure.mjs")],
     [false, false, false]);
  eq("not demoted: a consolidated-away workflow still DISAGREEs (close says present, main says absent)",
     [isProseFragmentPath(".github/workflows/committed-symlink-gate.yml"),
      retractedNear("scripts/committed-symlink-check.sh, .github/committed-symlinks.allow and .github/workflows/committed-symlink-gate.yml are all present on origin/main",
                    ".github/workflows/committed-symlink-gate.yml")],
     [false, false]);

  eq("isClosed: done", isClosed({ lifecycle_status: "done" }), true);
  eq("isClosed: cancelled", isClosed({ lifecycle_status: "cancelled" }), true);
  eq("isClosed: disposition closed on an open row", isClosed({ lifecycle_status: "open", disposition: "closed" }), true);
  eq("isClosed: plain open", isClosed({ lifecycle_status: "open" }), false);

  if (fails) { console.error(`\nSELFTEST FAILED: ${fails} assertion(s)`); process.exit(3); }
  console.log("\nselftest: all assertions passed");
  process.exit(0);
}

// ---------------------------------------------------------------- main

if (has("selftest")) selftest();

const input = flag("input");
if (!input) { console.error("usage: --input <tasks.ndjson>  (or --selftest)"); process.exit(1); }
if (!existsSync(input)) refuse(`--input ${input} does not exist`);

const repo = flag("repo", process.cwd());
const rev = flag("rev", "origin/main");
const seed = Number(flag("seed", "1"));
const halfLife = Number(flag("half-life", "14"));
const sampleArg = String(flag("sample", "100"));
const includes = flagAll("include");
if (!Number.isFinite(seed) || !Number.isFinite(halfLife) || halfLife <= 0) {
  console.error("usage: --seed and --half-life must be numbers, --half-life > 0"); process.exit(1);
}

const raw = readFileSync(input, "utf8").split("\n").filter((l) => l.trim());
if (!raw.length) refuse(`--input ${input} holds ZERO lines — an empty read is not a clean sweep`);

const docs = [];
raw.forEach((line, i) => {
  let d;
  try { d = JSON.parse(line); }
  catch (e) { refuse(`--input ${input} line ${i + 1} is not JSON (${e.message}) — a partially parsed population is not a population`); }
  docs.push(d);
});

const closed = docs.filter(isClosed);
if (!closed.length) refuse(`ZERO closed rows in ${docs.length} documents — refusing to report a clean sweep over an unread population`);

const now = Date.now();
const ageDays = (d) => {
  const t = closedAt(d);
  const ms = t ? Date.parse(t) : NaN;
  return Number.isFinite(ms) ? Math.max((now - ms) / 86400000, 0) : 3650;
};
const weightOf = (d) => Math.exp(-ageDays(d) / halfLife);

const wantAll = sampleArg === "all" || Number(sampleArg) === 0;
const n = wantAll ? closed.length : Number(sampleArg);
if (!wantAll && (!Number.isFinite(n) || n < 1)) { console.error("usage: --sample must be a positive number, 0, or 'all'"); process.exit(1); }

const byId = new Map(closed.map((d) => [d._id, d]));
const pinned = [];
for (const id of includes) {
  const d = byId.get(id) || byId.get(`drafts.${id}`);
  if (!d) refuse(`--include ${id} is NOT in the closed population of ${input} — the positive control could not be placed, so this run proves nothing`);
  pinned.push(d);
}
const pinnedIds = new Set(pinned.map((d) => d._id));
const drawn = weightedSample(closed.filter((d) => !pinnedIds.has(d._id)), Math.max(n - pinned.length, 0), seed, weightOf);
const sample = [...pinned, ...drawn];
if (!sample.length) refuse("the sample is EMPTY — nothing was checked");

const git = makeGit(repo, rev);

console.log(`# closed-row / tree disagreement sweep`);
console.log(`# input        ${input}  (${docs.length} documents read)`);
console.log(`# population   ${closed.length} CLOSED rows (done | cancelled | disposition:closed)`);
console.log(`# sample       ${sample.length}  seed=${seed}  half-life=${halfLife}d  pinned=${pinned.length}`);
console.log(`# rev          ${rev} = ${git.revSha}`);
console.log(`# repo         ${repo}`);
console.log("");

let advisoryTotal = 0;
const counts = { AGREE: 0, UNCHECKABLE: 0, "DISAGREE-path": 0, "DISAGREE-present": 0, "DISAGREE-symbol": 0, "DISAGREE-sha": 0 };
const findings = [];
for (const d of sample) {
  const { verdict, line, advisory: adv } = adjudicate(d, git);
  counts[verdict] = (counts[verdict] || 0) + 1;
  const pin = pinnedIds.has(d._id) ? " [PINNED]" : "";
  const age = ageDays(d).toFixed(0);
  console.log(`${verdict}\t${d._id}\t(closed ${age}d ago)${pin}\t${line}`);
  for (const a of adv || []) { advisoryTotal++; console.log(`\t  advisory: ${a}`); }
  if (verdict.startsWith("DISAGREE")) findings.push({ id: d._id, verdict, line });
}

const checkable = sample.length - counts.UNCHECKABLE;
const dis = counts["DISAGREE-path"] + counts["DISAGREE-present"] + counts["DISAGREE-symbol"] + counts["DISAGREE-sha"];
console.log("");
console.log(`# ---- counts`);
console.log(`# sampled        ${sample.length}`);
console.log(`# UNCHECKABLE    ${counts.UNCHECKABLE}   (the named blind spot: no path, no symbol, no sha)`);
console.log(`# checkable      ${checkable}`);
console.log(`# AGREE          ${counts.AGREE}`);
console.log(`# DISAGREE-path  ${counts["DISAGREE-path"]}`);
console.log(`# DISAGREE-pres  ${counts["DISAGREE-present"]}   (reason asserts the path is GONE; the tree still carries it — the INVERTED polarity)`);
console.log(`# DISAGREE-sym   ${counts["DISAGREE-symbol"]}`);
console.log(`# DISAGREE-sha   ${counts["DISAGREE-sha"]}   (ARM C is ADVISORY — see the demotion note in adjudicate())`);
console.log(`# advisory notes ${advisoryTotal}   (artifact paths, retracted paths/symbols, branch + unresolvable shas — printed, never counted)`);
console.log(`# rate           ${dis}/${checkable} checkable = ${checkable ? ((100 * dis) / checkable).toFixed(1) : "n/a"}%  (a FLOOR; ${counts.UNCHECKABLE} rows this instrument cannot see)`);
if (findings.length) {
  console.log(`#`);
  console.log(`# ---- leads (a DISAGREE is a LEAD, not a ruling — a close can be right for a reason its body does not carry)`);
  for (const f of findings) console.log(`#   ${f.id}  ${f.verdict}  ${f.line}`);
}
process.exit(0);
