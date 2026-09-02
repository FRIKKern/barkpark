#!/usr/bin/env node
//
// preview-census-gate-check.mjs — the files-to-instruments rule for the preview
// fixture corpus. Zero dependencies (`node:fs`, `node:child_process`), because
// the jobs that would run it run with no install step.
//
// THE RULE IT MECHANISES
// ----------------------
// `cloud/priv/static/__preview__/scenarios.mjs` is the ONE fixture corpus, and
// several instruments keep a TWO-WAY census over it: every scenario must be
// accounted for by that instrument, and every account must name a scenario that
// exists. Add a scenario and teach only one of them, and the others refuse —
// but they refuse in the Console gate, on arrival, not in the slice's own gate.
//
// That has now cost two waves. Wave 20 red-lit breakpoint-sweep.mjs; wave 21
// (cch-w21-s3) added `fleet-cruel-content`, correctly taught the sweep's
// residue, ran node --check / __css_check / __app.test / overflow-guard /
// breakpoint-sweep / breakpoint-sweep.test in its DECIDE-authored gate — and
// NOT smoke.mjs, whose census is two-way as well. console-harness.yml exited 1
// with "CENSUS: 1 committed scenario(s) have NO expectation and were never run".
// Nothing in the repo said the rule out loud; it was a habit, and the habit
// failed twice.
//
// So: given a slice's changed-file list (and, when it can get one, the BASE
// version of the corpus), this says which instruments that slice's own gate
// must run. With `--gate` it reads the slice's proposed gate and REDS on any
// instrument the gate omits — which is the whole point: the refusal has to
// arrive before the Console gate, not from it.
//
// WHY THE TRIGGER IS THE CENSUS DELTA AND NOT "the file changed"
// --------------------------------------------------------------
// "scenarios.mjs is in the diff" is the over-broad rule: it would drag the full
// harness into every slice that retunes one fixture's label. MEASURED on
// origin/main@9e04f46: editing one scenario's `label` and nothing else leaves
// smoke.mjs (exit 0), breakpoint-sweep.mjs (exit 0), breakpoint-sweep.test.mjs
// (exit 0) and member-authority-sweep.mjs (exit 0) all green. So the trigger is
// the thing the censuses actually key on:
//   · an ADDED scenario name   — smoke's "NO expectation", the sweep's UNLISTED,
//                                member-authority's PIN_TOTAL_SCENARIOS
//   · a REMOVED scenario name  — smoke's orphan arm, the sweep's STALE arm
//   · a DRIFTED family         — the sweep's DRIFTED arm (measured: moving
//                                `fleet-cruel-content`'s deepLink from #fleet to
//                                #activity exits 2 with DRIFTED, and smoke exits 1)
// `familyOf` is IMPORTED from breakpoint-sweep.mjs, never re-typed here, so the
// family half of the trigger cannot drift away from the instrument that owns it.
//
// WHAT IT DOES NOT CLAIM
// ----------------------
//   · It does not run the instruments. It says WHICH must run.
//   · The owner list is MEASURED, not derived: each entry was confirmed by
//     adding one scenario to the real corpus and recording the instrument's
//     exit code (see OWNERS below). Two instruments in the preview tree were
//     NOT measured — overflow-guard.mjs (browser) and seal-predicate.test.mjs
//     (exceeded a 2-minute budget) — so their absence from the table is an
//     unmeasured absence, not a proof they keep no census.
//   · The table is checked against the tree on EVERY run (`verifyTable`): an
//     owner that vanished, stopped importing the corpus, or lost its census
//     literal is a REFUSAL (exit 3), never a quiet shorter answer.
//   · Without a base version it cannot compute a delta, and then it answers
//     CONSERVATIVELY (require) and says so. A conservative answer is a cost,
//     not a lie.

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import os from "node:os";

const REPO = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const CORPUS = "cloud/priv/static/__preview__/scenarios.mjs";
const SWEEP = "cloud/priv/static/__preview__/breakpoint-sweep.mjs";

// ── THE TABLE ────────────────────────────────────────────────────────────────
// Every row was MEASURED, not assumed: a single scenario ("probe-failfirst-
// scenario", #overview, no expectation and no residue entry) was added to the
// real corpus on origin/main@9e04f46 and each instrument run bare. `exit` and
// `saysWhat` are what it actually printed.
export const CENSUS_OWNERS = [
  {
    censused: CORPUS,
    export: "SCENARIOS",
    owners: [
      {
        path: "cloud/priv/static/__preview__/smoke.mjs",
        run: "node cloud/priv/static/__preview__/smoke.mjs",
        literal: "EXPECTATIONS",
        exit: 1,
        saysWhat: 'CENSUS: N committed scenario(s) have NO expectation and were never run',
        why: "assertCensus() is two-way: every scenario needs an EXPECTATIONS entry and every entry needs a scenario. This is the one wave 21 omitted.",
      },
      {
        path: SWEEP,
        run: "node cloud/priv/static/__preview__/breakpoint-sweep.mjs",
        literal: "SCENARIO_RESIDUE",
        exit: 2,
        saysWhat: 'UNLISTED scenario "…" — no cell renders it and SCENARIO_RESIDUE does not carry it',
        why: "scenarioReport() reconciles the corpus against CELLS + SCENARIO_RESIDUE with four fatal refusals: unlisted, stale, promoted, drift. This is the one wave 20 red-lit.",
      },
      {
        path: "cloud/priv/static/__preview__/breakpoint-sweep.test.mjs",
        run: "node --test cloud/priv/static/__preview__/breakpoint-sweep.test.mjs",
        literal: "scenarioReport",
        exit: 1,
        saysWhat: '5 failing tests, incl. "the census reconciles: N scenarios …" and "A 101st SCENARIO IS REFUSED BY NAME"',
        why: "the sweep's header census arm re-counts the prose numbers from the derived report, so a corpus that moved reds the test file as well as the sweep.",
      },
      {
        path: "cloud/priv/static/__preview__/member-authority-sweep.mjs",
        run: "node cloud/priv/static/__preview__/member-authority-sweep.mjs",
        literal: "PIN_TOTAL_SCENARIOS",
        exit: 1,
        saysWhat: "the committed corpus grew to N scenario(s), pinned at M",
        why: "PIN_TOTAL_SCENARIOS is a committed count over the same corpus — a third census the row did not name, found by measuring rather than by reading the row.",
      },
    ],
  },
];

// ── the table is checked against the tree, every run ─────────────────────────
// A table nobody re-earns rots into a list of paths. Each owner must still
// exist, still import the corpus, and still carry the literal that IS its
// census. Any miss is a REFUSAL — a shorter required-list would be a silent
// downgrade of the very rule this file ships.
export function verifyTable(table = CENSUS_OWNERS, root = REPO) {
  const problems = [];
  for (const entry of table) {
    if (!fs.existsSync(path.join(root, entry.censused))) {
      problems.push(`censused file missing: ${entry.censused}`);
      continue;
    }
    const corpusBase = "./" + path.basename(entry.censused);
    for (const o of entry.owners) {
      const abs = path.join(root, o.path);
      if (!fs.existsSync(abs)) {
        problems.push(`owner missing from the tree: ${o.path}`);
        continue;
      }
      const src = fs.readFileSync(abs, "utf8");
      if (!src.includes(corpusBase) && !src.includes(entry.censused)) {
        problems.push(`owner no longer reads ${entry.censused}: ${o.path}`);
      }
      if (!src.includes(o.literal)) {
        problems.push(`owner lost its census literal \`${o.literal}\`: ${o.path}`);
      }
    }
  }
  return { ok: problems.length === 0, problems };
}

// ── the header arm — how option (c) is made falsifiable ──────────────────────
// A comment cannot red on the change it warns about. It CAN red on its own
// deletion, once a committed check reads it. This is that reader: the corpus's
// own header must state the rule and name every owner by path, so a builder who
// never opens the charter is told by the file they are editing.
export const HEADER_MARKER = "TWO-WAY CENSUS RULE";

export function headerOf(file, root = REPO) {
  const src = fs.readFileSync(path.join(root, file), "utf8");
  const lines = src.split("\n");
  const out = [];
  for (const l of lines) {
    if (l.startsWith("//") || l.trim() === "") out.push(l);
    else break;
  }
  return out.join("\n");
}

export function verifyHeader(table = CENSUS_OWNERS, root = REPO) {
  const problems = [];
  for (const entry of table) {
    const head = headerOf(entry.censused, root);
    if (!head.includes(HEADER_MARKER)) {
      problems.push(`${entry.censused} header does not state the rule (marker "${HEADER_MARKER}")`);
    }
    for (const o of entry.owners) {
      if (!head.includes(o.path)) problems.push(`${entry.censused} header does not name ${o.path}`);
    }
  }
  return { ok: problems.length === 0, problems };
}

// ── reading a corpus ─────────────────────────────────────────────────────────
let _familyOf = null;
async function familyOf() {
  if (_familyOf) return _familyOf;
  const mod = await import(pathToFileURL(path.join(REPO, SWEEP)).href);
  if (typeof mod.familyOf !== "function") {
    throw new Error(`${SWEEP} no longer exports familyOf — the family half of the trigger has no owner`);
  }
  _familyOf = mod.familyOf;
  return _familyOf;
}

// name -> family, read by IMPORTING the corpus (it is pure data, no side effects).
export async function censusOf(absFile, exportName = "SCENARIOS") {
  const mod = await import(pathToFileURL(absFile).href + `?t=${Date.now()}${Math.random()}`);
  const scen = mod[exportName];
  if (!scen || typeof scen !== "object") {
    throw new Error(`${absFile} exports no ${exportName}`);
  }
  const fam = await familyOf();
  const m = new Map();
  for (const [name, s] of Object.entries(scen)) m.set(name, fam(s));
  return m;
}

export function censusDelta(before, after) {
  const added = [...after.keys()].filter((n) => !before.has(n)).sort();
  const removed = [...before.keys()].filter((n) => !after.has(n)).sort();
  const drifted = [...after.keys()]
    .filter((n) => before.has(n) && before.get(n) !== after.get(n))
    .sort()
    .map((n) => ({ name: n, was: before.get(n), now: after.get(n) }));
  return { added, removed, drifted, moved: added.length + removed.length + drifted.length > 0 };
}

// ── the verdict ──────────────────────────────────────────────────────────────
// delta === null means "no base available" -> conservative REQUIRE, flagged.
export function requiredFor({ changedFiles, delta, table = CENSUS_OWNERS }) {
  const files = new Set(changedFiles.map((f) => f.trim()).filter(Boolean));
  const required = [];
  const skipped = [];
  for (const entry of table) {
    if (!files.has(entry.censused)) continue;
    if (delta && !delta.moved) {
      skipped.push({
        censused: entry.censused,
        reason: "the corpus changed but its census did not move — no scenario added, removed, or moved family",
      });
      continue;
    }
    for (const o of entry.owners) {
      required.push({
        ...o,
        censused: entry.censused,
        basis: delta
          ? [
              delta.added.length ? `added: ${delta.added.join(", ")}` : null,
              delta.removed.length ? `removed: ${delta.removed.join(", ")}` : null,
              delta.drifted.length ? `family drift: ${delta.drifted.map((d) => `${d.name} ${d.was}→${d.now}`).join(", ")}` : null,
            ].filter(Boolean).join(" · ")
          : "CONSERVATIVE — no base version available, so the census delta could not be computed",
      });
    }
  }
  return { required, skipped, conservative: !delta };
}

// A gate "covers" an instrument when its text names the instrument's path. That
// is deliberately loose: it accepts `node <path>`, a `--test <path>` form, or a
// step that shells out to a wrapper naming the path. It cannot prove the gate
// RUNS it; it proves the gate KNOWS about it, which is the omission that cost
// two waves.
export function gateCoverage(gateText, required) {
  const missing = required.filter((o) => !gateText.includes(o.path));
  return { missing, ok: missing.length === 0 };
}

// ── plumbing ────────────────────────────────────────────────────────────────
function gitShowToTemp(ref, file) {
  const buf = execFileSync("git", ["-C", REPO, "show", `${ref}:${file}`], { maxBuffer: 1 << 28 });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "preview-census-"));
  const p = path.join(dir, path.basename(file));
  fs.writeFileSync(p, buf);
  return p;
}

function changedFromGit(ref) {
  const out = execFileSync("git", ["-C", REPO, "diff", "--name-only", `${ref}...HEAD`], { encoding: "utf8" });
  return out.split("\n").map((s) => s.trim()).filter(Boolean);
}

function readList(src) {
  const text = src === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(src, "utf8");
  return text.split("\n").map((s) => s.trim()).filter(Boolean).filter((s) => !s.startsWith("#"));
}

function argOf(argv, name) {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : null;
}

async function run(argv) {
  const table = verifyTable();
  if (!table.ok) {
    console.error("::error::preview-census-gate-check REFUSES (exit 3): the owner table no longer describes the tree.");
    for (const p of table.problems) console.error(`  · ${p}`);
    return 3;
  }

  const changedFrom = argOf(argv, "--changed-from");
  const filesFrom = argOf(argv, "--files-from");
  const baseFile = argOf(argv, "--base-file");
  const headFile = argOf(argv, "--head-file");
  const gateFile = argOf(argv, "--gate");

  let changedFiles;
  if (filesFrom) changedFiles = readList(filesFrom);
  else if (changedFrom) changedFiles = changedFromGit(changedFrom);
  else changedFiles = argv.filter((a) => !a.startsWith("-") && argv[argv.indexOf(a) - 1] !== "--changed-from" &&
    argv[argv.indexOf(a) - 1] !== "--files-from" && argv[argv.indexOf(a) - 1] !== "--base-file" &&
    argv[argv.indexOf(a) - 1] !== "--head-file" && argv[argv.indexOf(a) - 1] !== "--gate");

  if (!changedFiles.length) {
    console.error("usage: node scripts/preview-census-gate-check.mjs [--changed-from <ref> | --files-from <path|-> | <file>…] [--base-file <p>] [--head-file <p>] [--gate <p>]");
    console.error("       node scripts/preview-census-gate-check.mjs --selftest");
    return 2;
  }

  // The delta, when a base is reachable.
  let delta = null;
  const touchesCorpus = CENSUS_OWNERS.some((e) => changedFiles.includes(e.censused));
  if (touchesCorpus) {
    let basePath = baseFile;
    if (!basePath && changedFrom) {
      try { basePath = gitShowToTemp(changedFrom, CORPUS); } catch { basePath = null; }
    }
    if (basePath) {
      const head = headFile ? path.resolve(headFile) : path.join(REPO, CORPUS);
      delta = censusDelta(await censusOf(path.resolve(basePath)), await censusOf(head));
    }
  }

  const { required, skipped, conservative } = requiredFor({ changedFiles, delta });

  console.log("preview-census-gate-check — which instrument(s) must this slice's own gate run?");
  console.log(`  changed files: ${changedFiles.length}`);
  if (delta) {
    console.log(`  census delta: +${delta.added.length} −${delta.removed.length} ~${delta.drifted.length} family drift`);
  } else if (touchesCorpus) {
    console.log("  census delta: NOT COMPUTED (no base version) — answering conservatively");
  }
  for (const s of skipped) console.log(`  · ${s.censused} changed, but NOT required: ${s.reason}`);

  if (!required.length) {
    console.log("  REQUIRED: none — no censused corpus moved in this slice.");
    return 0;
  }

  console.log(`  REQUIRED: ${required.length} instrument(s) keep a two-way census over ${CORPUS}${conservative ? " (conservative)" : ""}:`);
  for (const o of required) {
    console.log(`    · ${o.run}`);
    console.log(`        exits ${o.exit} when the census moves untaught: ${o.saysWhat}`);
  }
  console.log(`  basis: ${required[0].basis}`);

  if (!gateFile) return 0;

  const cov = gateCoverage(fs.readFileSync(gateFile, "utf8"), required);
  if (cov.ok) {
    console.log(`  GATE OK — ${gateFile} names all ${required.length} required instrument(s).`);
    return 0;
  }
  console.error(`::error::preview-census-gate-check: the gate omits ${cov.missing.length} instrument(s) that keep a two-way census over ${CORPUS}. They will refuse in the Console gate on arrival instead of in this slice's own gate.`);
  for (const m of cov.missing) console.error(`  · MISSING: ${m.run}   (${m.saysWhat})`);
  return 1;
}

// ── the self-test ────────────────────────────────────────────────────────────
// Every arm below can LOSE: each crippled variant is a build of this file with
// one load-bearing piece removed, and each must produce the WRONG answer.
async function selftest() {
  const FIX = path.join(REPO, "scripts/fixtures/preview-census-gate");
  const f = (n) => path.join(FIX, n);
  let bad = 0, total = 0;
  const check = (label, ok, detail) => {
    total++;
    console.log(`  ${ok ? "ok" : "FAIL"}  ${label}${detail ? ` — ${detail}` : ""}`);
    if (!ok) bad++;
  };
  console.log("preview-census-gate-check --selftest (fixtures: scripts/fixtures/preview-census-gate)");

  const base = await censusOf(f("base.mjs"));
  const added = await censusOf(f("added.mjs"));
  const removedC = await censusOf(f("removed.mjs"));
  const labelOnly = await censusOf(f("label-only.mjs"));
  const drifted = await censusOf(f("drifted.mjs"));
  const CHANGED = [CORPUS, "cloud/priv/static/app.js"];

  // ── the positive arm ──────────────────────────────────────────────────────
  const rAdd = requiredFor({ changedFiles: CHANGED, delta: censusDelta(base, added) });
  check(
    "a slice that ADDS a scenario is told which instruments its gate must run",
    rAdd.required.length === 4,
    `${rAdd.required.length} required`
  );
  const paths = rAdd.required.map((o) => o.path);
  check(
    "…and BOTH owners the row names are in it, by path",
    paths.includes("cloud/priv/static/__preview__/smoke.mjs") && paths.includes(SWEEP),
    paths.join(", ")
  );
  check(
    "…plus the two the row did NOT name, found by measurement",
    paths.includes("cloud/priv/static/__preview__/breakpoint-sweep.test.mjs") &&
      paths.includes("cloud/priv/static/__preview__/member-authority-sweep.mjs"),
    paths.join(", ")
  );
  check(
    "the basis names the scenario that moved, not just 'the file changed'",
    /added: probe-new-scenario/.test(rAdd.required[0].basis),
    rAdd.required[0].basis
  );

  const rRem = requiredFor({ changedFiles: CHANGED, delta: censusDelta(base, removedC) });
  check("a REMOVED scenario is a census move too (stale residue / orphan expectation)", rRem.required.length === 4,
    `${rRem.required.length} required`);
  const rDrift = requiredFor({ changedFiles: CHANGED, delta: censusDelta(base, drifted) });
  check("a scenario that MOVES FAMILY is a census move (the sweep's DRIFTED arm)", rDrift.required.length === 4,
    rDrift.required.length ? rDrift.required[0].basis : "none");

  // ── the negative arm ──────────────────────────────────────────────────────
  const rLabel = requiredFor({ changedFiles: CHANGED, delta: censusDelta(base, labelOnly) });
  check(
    "an edit to the corpus that adds NO scenario requires NOTHING (measured: all four stay green)",
    rLabel.required.length === 0 && rLabel.skipped.length === 1,
    `${rLabel.required.length} required, skipped: ${rLabel.skipped.map((s) => s.reason).join("")}`
  );
  const rElsewhere = requiredFor({
    changedFiles: ["cloud/priv/static/app.js", "cloud/lib/barkpark_cloud/registry.ex"],
    delta: censusDelta(base, added),
  });
  check(
    "a slice that never touches the corpus is NOT forced into the full harness, even mid-move",
    rElsewhere.required.length === 0,
    `${rElsewhere.required.length} required`
  );

  // ── no base -> conservative, and it SAYS so ───────────────────────────────
  const rNoBase = requiredFor({ changedFiles: CHANGED, delta: null });
  check(
    "with no base version it requires CONSERVATIVELY and labels the answer",
    rNoBase.required.length === 4 && rNoBase.conservative && /CONSERVATIVE/.test(rNoBase.required[0].basis),
    rNoBase.required.length ? rNoBase.required[0].basis : "none"
  );

  // ── the gate arm — this is what reds BEFORE the Console gate ──────────────
  const wave21Gate = [
    "node --check cloud/priv/static/__preview__/scenarios.mjs",
    "node cloud/priv/static/__css_check.mjs",
    "node --test cloud/priv/static/__app.test.mjs",
    "node cloud/priv/static/__preview__/overflow-guard.mjs",
    "node cloud/priv/static/__preview__/breakpoint-sweep.mjs",
    "node --test cloud/priv/static/__preview__/breakpoint-sweep.test.mjs",
  ].join("\n");
  const covW21 = gateCoverage(wave21Gate, rAdd.required);
  check(
    "THE WAVE-21 GATE, replayed: it is REFUSED, and smoke.mjs is named as the omission",
    !covW21.ok && covW21.missing.some((m) => m.path.endsWith("smoke.mjs")),
    `missing ${covW21.missing.map((m) => path.basename(m.path)).join(", ")}`
  );
  const fullGate = wave21Gate + "\n" + rAdd.required.map((o) => o.run).join("\n");
  check(
    "a gate that names every required instrument passes (the rule is satisfiable)",
    gateCoverage(fullGate, rAdd.required).ok
  );
  check(
    "the gate arm does not fire when nothing is required (empty required set ⇒ ok)",
    gateCoverage("", rLabel.required).ok
  );

  // ── the table is re-earned against the tree, and the check can LOSE it ────
  const t = verifyTable();
  check("the shipped owner table still describes the tree", t.ok, t.problems.join("; "));
  const bogusPath = [{ censused: CORPUS, export: "SCENARIOS", owners: [{ path: "cloud/priv/static/__preview__/gone.mjs", literal: "X" }] }];
  check(
    "an owner that vanished is a REFUSAL, not a quietly shorter answer",
    verifyTable(bogusPath).ok === false,
    verifyTable(bogusPath).problems.join("; ")
  );
  const bogusLiteral = [{ censused: CORPUS, export: "SCENARIOS", owners: [{ path: "cloud/priv/static/__preview__/smoke.mjs", literal: "NOT_A_REAL_CENSUS_LITERAL" }] }];
  check(
    "an owner that LOST its census literal is a refusal too (it stopped being an owner)",
    verifyTable(bogusLiteral).ok === false,
    verifyTable(bogusLiteral).problems.join("; ")
  );
  const notAReader = [{ censused: CORPUS, export: "SCENARIOS", owners: [{ path: "cloud/priv/static/__preview__/font-pin.mjs", literal: "EXPECTED_FACES" }] }];
  check(
    "…and so is an 'owner' that does not read the corpus at all",
    notAReader && verifyTable(notAReader).problems.some((p) => /no longer reads/.test(p)),
    verifyTable(notAReader).problems.join("; ")
  );

  // ── the header arm: option (c), made falsifiable ──────────────────────────
  const h = verifyHeader();
  check(
    "the corpus's OWN header states the rule and names every owner by path",
    h.ok,
    h.problems.join("; ")
  );
  const head = headerOf(CORPUS);
  check(
    "…and names the census that enforces it, so the builder can run it before pushing",
    head.includes("node cloud/priv/static/__preview__/smoke.mjs"),
    head.includes("node cloud/priv/static/__preview__/smoke.mjs") ? "" : "the run command is not in the header"
  );
  const strippedHeader = [{ censused: "scripts/preview-census-gate-check.mjs", owners: CENSUS_OWNERS[0].owners }];
  check(
    "the header arm can LOSE — a file without the marker fails it",
    verifyHeader(strippedHeader).ok === false,
    verifyHeader(strippedHeader).problems.slice(0, 1).join("")
  );

  // ── the trigger's family half is IMPORTED, not re-typed ───────────────────
  const fam = await familyOf();
  check(
    "familyOf comes from breakpoint-sweep.mjs itself, so the trigger cannot drift from its owner",
    fam({ deepLink: "#fleet/x" }) === "hash:#fleet" && fam({ pathname: "/new" }) === "path:/new" && fam({}) === "no-deeplink",
    `${fam({ deepLink: "#fleet/x" })} / ${fam({ pathname: "/new" })} / ${fam({})}`
  );

  if (bad) {
    console.error(`::error::preview-census-gate-check: SELF-TEST FAILED (${bad} of ${total} assertion(s)) — the files-to-instruments rule no longer holds.`);
    return 1;
  }
  console.log(`  self-test: ${total}/${total} — the rule fires on a census move, stays quiet otherwise, and refuses when its table rots.`);
  return 0;
}

const argv = process.argv.slice(2);
let code;
try {
  code = argv.includes("--selftest") ? await selftest() : await run(argv);
} catch (e) {
  console.error(`::error::preview-census-gate-check REFUSES (exit 3): ${e.message}`);
  code = 3;
}
process.exit(code);
