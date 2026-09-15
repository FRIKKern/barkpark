// design/ladder-refusal-conformance.test.mjs — THE CONFORMANCE TABLE for the
// type-ladder derivation's REFUSAL CONTRACT.
// Zero-dep (node:test + node:assert). Run: node design/ladder-refusal-conformance.test.mjs
//
// ============================================================================
// HOW MANY IMPLEMENTATIONS THERE ARE, AND WHY EACH ONE IS THERE
// ============================================================================
// THREE, on origin/main ea2fac0b0d3fc18a207d38e19530f9af0a19773e (2026-09-15).
// The count MOVES — it was TWO on 5ede2b636 — so it is measured, not memorised,
// by the census arm at the bottom of this file, and the roster it checks against
// is design/ladder-refusal-fixture.json's `implementations`. The shape-keyed
// grep the census mechanises, with the control that proves it discriminates:
//
//   $ git grep -n -E 'new Set\(steps\.map\(\(\[, ?size\]\) => size\)\)' origin/main
//   design/emit.mjs                            typeLadderFrom        PR #18275
//   design/validate.mjs                        chromeLadderAscending PR #18322
//   web/__tests__/type-ladder-emitted.test.ts  ladderFrom            PR #18142
//   (No line numbers, deliberately: scripts/new-lineref-check.sh reds a comment
//   that introduces one, and a cited line goes stale the next time the file
//   above it grows. Re-find each site with the grep, or by symbol name.)
//   CONTROL — the same regex over design/tokens.json and design/derive.mjs
//   (the two nearest look-alikes; derive.mjs has neutralLadder/chromeLadder,
//   which are OKLCH COLOUR ladders, not type ladders): 0 hits, rc 1.
//   CONTROL — the regex NARROWS: `new Set(` in those same three files is 2/3/1,
//   i.e. six hits, of which this shape selects three.
//
// A NAME-KEYED GREP DOES NOT WORK HERE and the trap is worth recording:
// `function .*[Ll]adder.*\(` over design/ + web/ returns SIX, three of them
// unrelated (design/derive.mjs neutralLadder + chromeLadder, design/emit.mjs
// webStatusLadderTs). The derivation is a SHAPE, not a name.
//
// ============================================================================
// THE REMEDY IS A CONFORMANCE TABLE OVER DUPLICATED CODE, NOT A SHARED MODULE
// ============================================================================
// Stated explicitly because the obvious remedy is the wrong one, and because the
// next reader will otherwise re-derive the argument the builder of PR #18322
// already measured. There are TWO independent grounds:
//
// (1) THE DEPENDENCY CONTRACT (measured by #18322, restated here, NOT overturned).
//     design/validate.mjs' header contract is "Dependency-free (Node built-ins
//     only) … the W1.1 completeness gate; W1.2 emitters trust it", and
//     design/emit.mjs CALLS typeLadderFrom AT MODULE SCOPE while also reading
//     tokens.json, status-manifest.json, the themes directory and
//     audit-actions.json at load. So `import { typeLadderFrom } from "./emit.mjs"`
//     inside validate.mjs means that on a malformed type.chrome the throw happens
//     INSIDE THE IMPORT and the validator dies with a stack trace instead of
//     printing the numbered problem report that is its entire job — the one input
//     it exists to grade is the one input that would break it. A shared
//     design/type-ladder.mjs that emit.mjs re-exports fixes the module-scope half
//     but not the second ground:
//
// (2) THE THREE ARE NOT ONE FUNCTION. They agree on WHICH inputs must be refused
//     and on nothing else. emit.mjs sorts DESCENDING and THROWS. validate.mjs
//     sorts ASCENDING and RETURNS { err } — it must, because it collects a
//     numbered problem report and a throw on the first problem would hide the
//     rest. The web copy sorts descending, throws, is TypeScript, and sits across
//     a tree boundary with its own path-escape declaration. Folding them into one
//     module forces validate.mjs to either adopt throw semantics (destroying the
//     report) or wrap every call in try/catch (re-creating the divergence one
//     layer up). The direction difference is already adjudicated in validate.mjs'
//     LADDER_VERDICTS as ONE FACT KEPT TWICE, DERIVED.
//
// So the duplication stays and THIS FILE pins what actually has to agree: the
// REFUSAL DECISION — for each malformed family, does this implementation refuse,
// yes or no. That is transport-independent, so it survives (2), and it needs no
// import, so it survives (1).
//
// ============================================================================
// WHAT WAS ACTUALLY EXPOSED, WHICH IS NARROWER THAN "NOTHING FEEDS THEM"
// ============================================================================
// Measured at ea2fac0b0 before this file existed:
//   emit.mjs typeLadderFrom      — 4 refusal arms, driven by check.mjs Part C2. COVERED.
//   web ladderFrom               — 3 refusal arms in its own test: missing family,
//                                  zero-rung, tied. NO NON-OBJECT ARM.
//   validate.mjs chromeLadderAscending — ZERO refusal arms. Nothing anywhere fed it
//                                  a malformed family; the cross-file census added
//                                  by #18322 compares only the LISTS, which are
//                                  identical on a well-formed tokens.json whatever
//                                  the refusal semantics are.
// So two of the three had partial cover from arms that could drift apart, and the
// newest one had none. The fixture closes both: one list of families, no per-site
// list to fall behind.
//
// ============================================================================
// PROVEN ABLE TO FAIL BY MUTATION (2026-09-15, recorded with the mutation)
// ============================================================================
// Five mutations, each asserted LANDED (sha256 before != after) before anything
// was measured and each restored byte-identical (sha256 back to the original).
// Baseline in every case: this file 7/7, the web suite 7/7, check.mjs PASS,
// validate.mjs exit 0.
//
//   M1  delete the tie guard in design/emit.mjs typeLadderFrom
//       -> this file rc 1, 5 pass / 2 fail, message:
//          'IMPLEMENTATION "emit" (design/emit.mjs typeLadderFrom) DIVERGED on
//           ladder-refusal-fixture.json case "tied-size-family": it returned
//           ["a","b"] instead of refusing.'
//       -> design/check.mjs rc 1, Part C2 names the same implementation and case.
//
//   M2  make design/validate.mjs' tie branch `return { order: [] }`
//       -> this file rc 1, 6 pass / 1 fail, naming "validate".
//       AND, IN THE SAME RUN, `node design/validate.mjs` ON THE REAL TREE STILL
//       EXITED 0. That is the whole exposure in one line: the mutation is
//       invisible to every gate that compares only the lists, because on a
//       well-formed tokens.json there is no tie to refuse.
//
//   M3  delete the tie guard in the web copy
//       -> the WEB suite rc 1, 6 pass / 1 fail, naming "web".
//
//   M4  repoint the web driver's read at a different path (enrolment removed
//       rather than the guard relaxed)
//       -> this file rc 1, naming "web" as NO LONGER ENROLLED.
//       THIS ARM CAUGHT A DEFECT IN ITSELF FIRST. The original predicate matched
//       the raw file text, and the comment paragraph above the repointed read
//       still named the fixture, so M4 passed 7/7 — a guard matching its own
//       subject, in the one place a false green is worst. The predicate now
//       strips comments and carries three controls of its own.
//
//   M5  delete one case from the fixture (the gate's own INPUT going blind)
//       -> all three drivers red: this file rc 1, check.mjs rc 1, the web suite
//          rc 1, each naming the shortfall. A conformance table whose fixture can
//          be emptied is theatre.
//
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, cpSync, readFileSync, writeFileSync, rmSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { typeLadderFrom, LADDER_REFUSE } from "./emit.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..");
const FIXTURE_NAME = "ladder-refusal-fixture.json";
const fixture = JSON.parse(readFileSync(join(here, FIXTURE_NAME), "utf8"));
const CASES = fixture.cases;
const ROSTER = fixture.implementations;
const SENTINEL = fixture.sentinel;

// The fixture must not be able to go blind either: a fixture that lost its cases
// would leave every loop below iterating nothing and this whole file would pass
// vacuously — the exact defect it exists to prevent, re-entered through the fix.
test("the fixture itself declares something to measure", () => {
  assert.equal(SENTINEL, LADDER_REFUSE,
    `${FIXTURE_NAME} declares sentinel ${JSON.stringify(SENTINEL)} but design/emit.mjs exports LADDER_REFUSE=${JSON.stringify(LADDER_REFUSE)}`);
  assert.ok(CASES.length >= 4, `${FIXTURE_NAME} carries only ${CASES.length} malformed case(s); the four families are missing / non-object / zero-rung / tied`);
  assert.ok(ROSTER.length >= 3, `${FIXTURE_NAME} rosters only ${ROSTER.length} implementation(s)`);
  for (const id of ["missing-family", "non-object-family", "zero-rung-family", "tied-size-family"])
    assert.ok(CASES.some((c) => c.id === id), `${FIXTURE_NAME} has no case "${id}"`);
});

/** Build a whole tokens-shaped doc whose type.chrome is this case's family. */
function docFor(c) {
  return c.kind === "omit" ? { type: {} } : { type: { chrome: c.family } };
}

// ---------------------------------------------------------------------------
// ARM 1 — design/emit.mjs typeLadderFrom, in-process.
// ---------------------------------------------------------------------------
test("emit: typeLadderFrom REFUSES every malformed family in the fixture", () => {
  for (const c of CASES) {
    let refused = null;
    let got;
    try {
      got = typeLadderFrom(docFor(c), "chrome");
    } catch (e) {
      refused = String(e && e.message);
    }
    assert.ok(
      refused !== null,
      `IMPLEMENTATION "emit" (design/emit.mjs typeLadderFrom) DIVERGED on ${FIXTURE_NAME} case "${c.id}": it returned ${JSON.stringify(got)} instead of refusing. ${c.why}`,
    );
    assert.ok(
      refused.includes(SENTINEL),
      `IMPLEMENTATION "emit" refused case "${c.id}" without the sentinel "${SENTINEL}": ${refused}`,
    );
  }
});

test("emit: the POSITIVE CONTROL — the real tokens.json still derives a ladder", () => {
  const tokens = JSON.parse(readFileSync(join(here, "tokens.json"), "utf8"));
  const ladder = typeLadderFrom(tokens, "chrome");
  assert.ok(ladder.length >= 4,
    `derived only ${ladder.length} chrome rung(s) from the real tokens.json — the arm above would refuse everything and prove nothing`);
});

// ---------------------------------------------------------------------------
// ARM 2 — design/validate.mjs chromeLadderAscending, through the REAL CLI.
//
// It cannot be imported: validate.mjs is a script that reads tokens.json and
// calls process.exit at module scope, and chromeLadderAscending is deliberately
// not exported (ground (1) above). Its observable refusal IS the CLI's exit code
// and problem report, so that is what is driven — exactly the shape
// design/validate-life-fence.test.mjs already uses for the lifecycle half, and
// it touches validate.mjs' dependency contract not at all.
// ---------------------------------------------------------------------------
function runValidateWithChrome(mutate) {
  const dir = mkdtempSync(join(tmpdir(), "bp-ladder-refusal-"));
  try {
    cpSync(here, dir, { recursive: true });
    const tp = join(dir, "tokens.json");
    const t = JSON.parse(readFileSync(tp, "utf8"));
    mutate(t);
    writeFileSync(tp, JSON.stringify(t, null, 2) + "\n");
    const r = spawnSync(process.execPath, [join(dir, "validate.mjs")], { encoding: "utf8" });
    const out = `${r.stdout}${r.stderr}`;
    // The LADDER_PAIR_FLOOR assertion in validate.mjs also carries the sentinel,
    // so the sentinel ALONE does not discriminate. A ladder refusal is a line
    // that carries the sentinel AND names type.chrome; the control below proves
    // that pair returns 0 on an unmutated tree.
    const ladderLines = out.split("\n").filter((l) => l.includes(SENTINEL) && l.includes("type.chrome"));
    return { status: r.status, out, ladderLines };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("validate: chromeLadderAscending REFUSES every malformed family in the fixture", () => {
  for (const c of CASES) {
    const { status, out, ladderLines } = runValidateWithChrome((t) => {
      if (c.kind === "omit") delete t.type.chrome;
      else t.type.chrome = c.family;
    });
    assert.notEqual(
      status, 0,
      `IMPLEMENTATION "validate" (design/validate.mjs chromeLadderAscending) DIVERGED on ${FIXTURE_NAME} case "${c.id}": the validator exited 0. ${c.why}\n${out}`,
    );
    assert.ok(
      ladderLines.length >= 1,
      `IMPLEMENTATION "validate" DIVERGED on ${FIXTURE_NAME} case "${c.id}": it exited ${status} but printed no "${SENTINEL}" line naming type.chrome, so the ladder derivation went blind and something ELSE failed the run. ${c.why}\n${out}`,
    );
  }
});

test("validate: the CONTROL — an unmutated copy exits 0 and prints no ladder refusal", () => {
  const { status, out, ladderLines } = runValidateWithChrome(() => {});
  assert.equal(status, 0, `expected exit 0 on an unmutated copy, got ${status}\n${out}`);
  assert.equal(ladderLines.length, 0,
    `the unmutated copy printed a ladder refusal, so the arm above measures the copy step, not the mutation\n${out}`);
});

// ---------------------------------------------------------------------------
// ARM 3 — ENROLMENT. The web implementation is TypeScript; the doc-gates design
// job runs Node 20, which cannot execute it, so its driver lives in the web
// suite and reads THIS fixture. What this arm holds is that it is still enrolled:
// a web driver deleted or unhooked from the fixture reds here, naming "web".
// This is a source census, and it is only as good as its control — so the same
// predicate is run against a file that must NOT satisfy it.
// ---------------------------------------------------------------------------
// THE PREDICATE READS CODE, NOT PROSE, AND THAT WAS MEASURED THE HARD WAY. The
// first version of this arm was `src.includes(FIXTURE_NAME)` over the raw file.
// Repointing the web driver's readFileSync at a different path left it GREEN,
// because the paragraph of comment ABOVE that line still names the fixture — a
// grep matching its own subject, in the one place where a false green is worst.
// So comments are stripped first, and the stripper has its own control below.
function stripComments(src) {
  let out = "";
  let i = 0;
  const n = src.length;
  let quote = null; // '"' | "'" | "`" when inside a string/template
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (quote) {
      if (c === "\\") { out += c + (d ?? ""); i += 2; continue; }
      if (c === quote) quote = null;
      out += c; i += 1; continue;
    }
    if (c === "/" && d === "/") { while (i < n && src[i] !== "\n") i += 1; continue; }
    if (c === "/" && d === "*") { i += 2; while (i < n && !(src[i] === "*" && src[i + 1] === "/")) i += 1; i += 2; continue; }
    if (c === '"' || c === "'" || c === "`") { quote = c; out += c; i += 1; continue; }
    out += c; i += 1;
  }
  return out;
}

const FIXTURE_REL_FROM_WEB = "../../design/" + FIXTURE_NAME;

function enrolsCode(sourcePath) {
  const code = stripComments(readFileSync(join(repoRoot, sourcePath), "utf8"));
  return code.includes(FIXTURE_REL_FROM_WEB) && /\.cases\b/.test(code);
}

test("web: the web driver is still enrolled against this fixture", () => {
  const web = ROSTER.find((i) => i.id === "web");
  assert.ok(web, `${FIXTURE_NAME} no longer rosters the "web" implementation`);

  // CONTROL A — THE STRIPPER ACTUALLY STRIPS. A stripper that returned its input
  // unchanged would restore the prose-matching bug this arm exists to avoid, and
  // would do it silently. This sentence appears ONLY inside a comment in the web
  // file, so it must survive the raw read and NOT survive the strip.
  const rawWeb = readFileSync(join(repoRoot, web.file), "utf8");
  const PROSE_ONLY = "THE WEB ARM OF THE LADDER-REFUSAL CONFORMANCE TABLE";
  assert.ok(rawWeb.includes(PROSE_ONLY),
    `${web.file} no longer carries the marker sentence this arm's stripper control keys on; update the control rather than deleting it`);
  assert.equal(stripComments(rawWeb).includes(PROSE_ONLY), false,
    "stripComments left a comment-only sentence behind — the enrolment predicate is reading prose again and a repointed read would pass unnoticed");

  // CONTROL B — THE STRIPPER DOES NOT EAT CODE. A stripper that over-stripped
  // would red this arm on a perfectly enrolled file.
  assert.ok(stripComments(rawWeb).includes("readFileSync"),
    "stripComments removed executable code — the enrolment verdict below would be a false red");

  assert.ok(
    enrolsCode(web.file),
    `IMPLEMENTATION "web" (${web.file} ${web.symbol}) IS NO LONGER ENROLLED: no executable line in it reads ${FIXTURE_REL_FROM_WEB} and iterates its cases, so the refusal contract is pinned for ${ROSTER.length - 1} of ${ROSTER.length} implementations and the web copy can relax its tie-refusal unobserved.`,
  );

  // CONTROL C — the predicate discriminates between files. design/emit.mjs is an
  // implementation and does NOT enrol (it is driven from here instead), so a
  // predicate that said "yes" to everything would be caught.
  assert.equal(enrolsCode("design/emit.mjs"), false,
    "the enrolment predicate returned true for design/emit.mjs, which does not read the fixture — it is matching everything and proves nothing");
});

// ---------------------------------------------------------------------------
// ARM 4 — THE CENSUS. The count MOVES; a fourth copy must not arrive unenrolled.
// Keyed on the SHAPE (the tie-refusal line), not on a name: a name-keyed sweep
// over these two trees returns six, three of them colour ladders.
// ---------------------------------------------------------------------------
// Assembled from two halves so THIS file's own source does not contain the
// literal it searches for — a census that matches itself counts one too many and
// hides the direction it was built to catch.
const TIE_SHAPE = "new Set(steps.map((" + "[, size]) => size))";

function censusFiles() {
  const hits = [];
  const roots = [
    { dir: join(repoRoot, "design"), rel: "design", exts: [".mjs"] },
    { dir: join(repoRoot, "web", "__tests__"), rel: "web/__tests__", exts: [".ts"] },
  ];
  for (const root of roots) {
    for (const name of readdirSync(root.dir)) {
      if (!root.exts.some((e) => name.endsWith(e))) continue;
      const rel = `${root.rel}/${name}`;
      if (readFileSync(join(root.dir, name), "utf8").includes(TIE_SHAPE)) hits.push(rel);
    }
  }
  return hits.sort();
}

test("census: every derivation in the tree is on the roster, and this file is not one of them", () => {
  const found = censusFiles();
  // SELF-MATCH CONTROL. A census whose regex matches its own source over-counts
  // by one and the extra hit looks exactly like a real fourth copy.
  assert.ok(
    !found.includes("design/ladder-refusal-conformance.test.mjs"),
    "the census matched its own source; TIE_SHAPE has been reassembled into a contiguous literal and the count is one too high",
  );
  // FLOOR. A census that stopped matching would find nothing and this arm would
  // agree with an empty roster.
  assert.ok(found.length >= 3,
    `the census found only ${found.length} derivation site(s) [${found.join(", ")}] — the shape it keys on has been reformatted away and its silence is not evidence that no copy exists`);
  const rostered = ROSTER.map((i) => i.file).sort();
  assert.deepEqual(
    found, rostered,
    `the ladder-derivation census and ${FIXTURE_NAME}'s roster disagree.\n  in the tree: [${found.join(", ")}]\n  on the roster: [${rostered.join(", ")}]\n` +
    "A site in the tree and not on the roster is a copy of the refusal contract that nothing drives. A site on the roster and not in the tree was derived away — retire the row and say where it went.",
  );
});
