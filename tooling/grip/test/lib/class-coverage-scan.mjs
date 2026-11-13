// class-coverage-scan.mjs — the mention scan the class-coverage suite shares,
// and the self-slice that keeps the suite's own declarations out of its corpus.
//
// The single class-coverage suite was split by subject into the files in SUITE
// below (task-ff9bcdb1cbe00405). Part (A) and part (E) both run the mention
// scan, so it lives here. It sits in lib/ and not in test/ itself because the
// scan reads every .mjs file in test/ as corpus: prose here would count as
// coverage. The code moved unchanged except where it named the old file.

import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const GRIP = resolve(HERE, "..", "..");

// The files the single class-coverage suite was split into, in its old order.
// SELF holds the old header and part (A): declarations, never corpus. CONTROLS
// opens with the part (B) banner. The part (E) file came after the banner.
const SELF = "class-coverage-tripwire.test.mjs";
const CONTROLS = "class-coverage-controls.test.mjs";
export const SUITE = [SELF, CONTROLS, "class-coverage-firing.test.mjs"];

// Everything in the suite from this banner onward — the rest of CONTROLS and
// all of the part (E) file — is a CONTROL and counts as corpus; everything
// before it is commentary and does not. `lastIndexOf` picks the banner in
// CONTROLS, which has it once.
const CONTROLS_BANNER = "(B) THE CONTROLS";

// LAYER ONE — a SHOUTY class identifier is a fully-uppercase, hyphen-joined
// STRING LITERAL. Restricting to literals (rather than any word in the file)
// keeps prose in comments — "DEFAULT-*", "the D73 rule" — out of the universe,
// so the tripwire counts things the code can actually return.
const SHOUTY_LITERAL = /(["'`])((?:[A-Z0-9]+-)+[A-Z0-9]+)\1/g;

// LAYER TWO — an enum VALUE. The shape is deliberately narrow at BOTH ends: the
// KEY must be UPPER_SNAKE (so binding.mjs's PORTABLE_SCOPES, keyed by prose
// class names, contributes nothing) and the VALUE must be a fully-uppercase
// word or hyphen/underscore-joined phrase (so ANCESTRY's lowercase rungs and
// LEVELS' integers contribute nothing). One word is now enough: this is the
// half that sees ADMITTED, DEMOTED, REJECTED, FAILED, UNAVAILABLE, CONFLICT and
// UNMINTABLE, and it never looks at a free literal.
const ENUM_KEY = /^[A-Z][A-Z0-9_]*$/;
const ENUM_VALUE = /^[A-Z][A-Z0-9]*(?:[-_][A-Z0-9]+)*$/;

// The sweep runs OUT OF PROCESS. harvest.mjs runs its fixture gate at import and
// can `process.exit` on a bad argv — importing the tree in-process would let one
// module kill the whole test file. The child writes its state after EVERY module
// so a death is attributable: whatever is `pending` in the file is what killed
// it, and the parent re-runs with that module skipped.
const ENUM_SWEEP = `
import { readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const src = process.env.GRIP_ENUM_SRC;
const out = process.env.GRIP_ENUM_OUT;
const skip = new Set(JSON.parse(process.env.GRIP_ENUM_SKIP || "[]"));
const KEY = ${ENUM_KEY.toString()};
const VALUE = ${ENUM_VALUE.toString()};
const state = { pending: null, unreadable: [...skip], values: {} };
const flush = () => writeFileSync(out, JSON.stringify(state), "utf8");
const isEnumObject = (v) =>
  v !== null && typeof v === "object" && !Array.isArray(v) &&
  (Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null);
flush();
for (const name of readdirSync(src).filter((n) => n.endsWith(".mjs")).sort()) {
  if (skip.has(name)) continue;
  state.pending = name;
  flush();
  let mod = null;
  try { mod = await import(pathToFileURL(join(src, name)).href); }
  catch { state.unreadable.push(name); }
  for (const [enumName, value] of Object.entries(mod || {})) {
    if (!isEnumObject(value)) continue;
    for (const [key, member] of Object.entries(value)) {
      if (!KEY.test(key)) continue;
      if (typeof member !== "string" || !VALUE.test(member)) continue;
      (state.values[member] ||= []).push({ module: name, enumName, key });
    }
  }
  state.pending = null;
  flush();
}
flush();
`;

const ENUM_CACHE = new Map();

/**
 * sweepEnumUniverse(srcDir) → { values: Map<class, origin[]>, unreadable: [] }
 *
 * `origin` is { module, enumName, key } — the enum member that HOLDS the class,
 * which is what lets the coverage check accept `OUTCOME.TOOL_ERROR` as a mention
 * of TOOL-ERROR without accepting the bare word TOOL_ERROR anywhere else.
 * Cached per directory: the sweep costs one child process, not one per test.
 */
export function sweepEnumUniverse(srcDir = GRIP) {
  const cached = ENUM_CACHE.get(srcDir);
  if (cached) return cached;

  const workdir = mkdtempSync(join(tmpdir(), "grip-enumsweep-"));
  const out = join(workdir, "sweep.json");
  const unreadable = [];
  let state = { pending: null, unreadable: [], values: {} };
  try {
    writeFileSync(out, JSON.stringify(state), "utf8");
    // Bounded by the module count: each retry retires exactly one killer.
    const budget = readdirSync(srcDir).filter((n) => n.endsWith(".mjs")).length + 1;
    for (let attempt = 0; attempt < budget; attempt++) {
      spawnSync(process.execPath, ["--input-type=module", "-e", ENUM_SWEEP], {
        stdio: "ignore",
        timeout: 60_000, // a hung module must not hang the suite; it becomes an unreadable module instead
        env: { ...process.env, GRIP_ENUM_SRC: srcDir, GRIP_ENUM_OUT: out, GRIP_ENUM_SKIP: JSON.stringify(unreadable) },
      });
      state = JSON.parse(readFileSync(out, "utf8"));
      if (!state.pending) break;
      unreadable.push(state.pending); // it died on this one — retire it and retry
    }
  } finally {
    rmSync(workdir, { recursive: true, force: true });
  }

  const result = {
    values: new Map(Object.entries(state.values)),
    unreadable: [...new Set([...(state.unreadable || []), ...unreadable])].sort(),
  };
  ENUM_CACHE.set(srcDir, result);
  return result;
}

/**
 * The corpus contribution of one test file. The suite contributes only its
 * controls — see the "does not count its own declarations" bullet in the header
 * of SELF.
 */
export function corpusTextOf(name, raw) {
  if (name === SELF) return "";
  if (name !== CONTROLS) return raw;
  const at = raw.lastIndexOf(CONTROLS_BANNER);
  return at === -1 ? "" : raw.slice(at);
}

/**
 * Is `id` named by the corpus? Three spellings, and for a one-word class only
 * the last two — `corpus.includes("FAILED")` would be satisfied by the substring
 * inside WRITE-FAILED, which is how a loose scan grades an absent class covered.
 */
function isMentioned(corpus, id, origins) {
  if (id.includes("-")) {
    if (corpus.includes(id)) return true; // the hyphen spelling, as written in the module
    if (new RegExp(`\\b${id.replace(/-/g, "_")}\\b`).test(corpus)) return true; // the UPPER_SNAKE enum key
  }
  if (new RegExp(`(["'\`])${id}\\1`).test(corpus)) return true; // the value as a quoted literal
  return origins.some(({ enumName, key }) => new RegExp(`\\b${enumName}\\.${key}\\b`).test(corpus)); // ENUM.KEY
}

/**
 * scanClassCoverage({ srcDir, testDir, excludeTests }) → {
 *   modules, testFiles, literalUniverse, enumUniverse, unreadable,
 *   universe, hyphenOnly, dual, uncontrolled
 * }
 *
 * GLOBS `srcDir` — never a hand-listed set. `universe` is the UNION of the two
 * layers. `dual` is the uncontrolled set of the LITERAL layer under both
 * spellings, and `hyphenOnly` what the filed method would have said; both are
 * kept so the three methods can be printed side by side. `uncontrolled` is the
 * committed expectation — the union layer's flagged set. Exported so a scratch
 * copy of the tree can be scanned without editing this one.
 */
export function scanClassCoverage({ srcDir = GRIP, testDir = join(GRIP, "test"), excludeTests = [] } = {}) {
  const modules = readdirSync(srcDir).filter((name) => name.endsWith(".mjs")).sort();
  const literalUniverse = new Map();
  for (const name of modules) {
    const lines = readFileSync(join(srcDir, name), "utf8").split("\n");
    lines.forEach((line, i) => {
      SHOUTY_LITERAL.lastIndex = 0;
      let m;
      while ((m = SHOUTY_LITERAL.exec(line)) !== null) {
        if (!literalUniverse.has(m[2])) literalUniverse.set(m[2], `${name}:${i + 1}`);
      }
    });
  }

  const { values: enumUniverse, unreadable } = sweepEnumUniverse(srcDir);
  const universe = new Map(literalUniverse);
  for (const [id, origins] of enumUniverse) {
    if (!universe.has(id)) universe.set(id, `${origins[0].module} ${origins[0].enumName}.${origins[0].key}`);
  }

  const testFiles = readdirSync(testDir)
    .filter((name) => name.endsWith(".mjs") && !excludeTests.includes(name))
    .sort();
  const corpus = testFiles.map((name) => corpusTextOf(name, readFileSync(join(testDir, name), "utf8"))).join("\n");

  const hyphenOnly = [];
  const dual = [];
  const uncontrolled = [];
  for (const [id, where] of universe) {
    const origins = enumUniverse.get(id) ?? [];
    if (literalUniverse.has(id)) {
      const mentionedHyphen = corpus.includes(id);
      const mentionedSnake = new RegExp(`\\b${id.replace(/-/g, "_")}\\b`).test(corpus);
      if (!mentionedHyphen) hyphenOnly.push({ id, where });
      if (!mentionedHyphen && !mentionedSnake) dual.push({ id, where });
    }
    if (!isMentioned(corpus, id, origins)) uncontrolled.push({ id, where });
  }
  return { modules, testFiles, literalUniverse, enumUniverse, unreadable, universe, hyphenOnly, dual, uncontrolled };
}
