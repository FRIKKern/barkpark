#!/usr/bin/env node
//
// console-slice-gate.mjs — a console slice's gate, COMPOSED from its changed
// files and then CHECKED against the gate the slice proposes to run.
//
// THE RED THIS EXISTS FOR
// -----------------------
// Wave 17 shipped cch-w16-s6, which added `@media (max-width: 830px)` to
// cloud/priv/static/app.css. Its DECIDE-authored gate ran __css_check +
// cssom-parity + __app.test + smoke + a baseline grep, and was fully green.
// None of those derives an AXIS from app.css. breakpoint-sweep.mjs's Leg A
// does — and on the builder's own bytes it exited 2:
//
//     UNCOVERED breakpoint 830px — the boundary walk is missing 829, 830, 831
//
// Leg A is wired into console-harness.yml, so the merge would have reded on a
// rule this epic itself wrote. The reviewer fixed it in place; the CLASS — a
// hand-authored slice gate that is not checked to be a SUPERSET of what the
// merge gate runs over the touched paths — was left open. This file closes it.
//
// WHY THIS IS NOT A SECOND COPY OF tooling/gate-map
// -------------------------------------------------
// tooling/gate-map/gate-map.mjs already derives "which committed instruments
// READ this path" from each instrument's scan sites, every run, with no
// snapshot. It is imported here, never re-typed. What it did not do:
//
//   1. IT COULD NOT SEE LEG A. gate-map reads scan sites out of source TEXT:
//      a readdir, a glob, a `find`, a `git ls-files`, a repo-relative literal.
//      breakpoint-sweep.mjs reached its stylesheet through
//      `process.env.BREAKPOINT_SWEEP_CSS || path.join(ROOT, "app.css")` and
//      spelled the repo-relative path NOWHERE. MEASURED on origin/main
//      a917280fb: `gate-map --for cloud/priv/static/app.css` listed 16
//      instruments and NOT the sweep. The composer built for exactly this class
//      of miss was blind to its own headline case. That is fixed at the source
//      (breakpoint-sweep.mjs now declares CSS_SOURCE/HTML_SOURCE in code, with
//      a refusal if the default read ever stops matching), and the REQUIRED_EDGES
//      ratchet below refuses if that edge ever disappears again.
//   2. IT LISTS AND RUNS; IT DOES NOT REFUSE A GATE. `--for` prints, `--run`
//      executes. Neither reads the gate a slice is ABOUT to be dispatched with.
//      A composed gate nobody compares the proposal against is a document.
//      `--gate` here is the refusal: an axis-blind gate exits 1 by name.
//   3. ONE TRANSITIVE HOP. app.css is read by breakpoint-sweep.mjs; the sweep's
//      own unit suite imports the sweep and re-counts the derived axis, so it
//      reds on the same change (wave 17: 5 failing tests). gate-map's map is
//      one hop — file -> instrument — so the suite never appeared. The hop here
//      is derived from gate-map's OWN file-edges, not from a list of test files.
//
// SIBLING ROWS THIS MECHANISM PAYS
//   · cch-w17-bl-css-slice-gate-must-include-leg-a — app.css => Leg A (+ suite).
//   · cchi-w37-bl-slice-gate-omits-the-surface-s-shipped-gates — a slice editing
//     cloud/priv/static/__binding_census.mjs shipped gate-green while
//     __css_check's E11 (banned `app.js:<line>` citations) would have reded the
//     Console gate. __css_check READS THE DIRECTORY, so the same `--gate`
//     refusal names it. Both rows are one rule: the slice gate must be a
//     superset of what the merge gate runs over the touched paths.
//
// WHAT IT DOES NOT CLAIM
//   · It does not prove the gate RUNS an instrument, only that the gate NAMES
//     it. Naming is the omission that cost wave 16, wave 17 and cchi-w37.
//   · Over-inclusion is deliberate. gate-map's extraction is conservative and
//     so is this: a required instrument you did not need costs runtime; a
//     missing one is the red this file exists for.
//
// USAGE
//   node scripts/console-slice-gate.mjs <changed files…>
//   node scripts/console-slice-gate.mjs --files-from <list.txt|->  <…>
//   node scripts/console-slice-gate.mjs <files…> --gate <gate.txt|->
//   node scripts/console-slice-gate.mjs <files…> --run     # fail-fast
//
// EXIT VOCABULARY
//   0  the composed gate is satisfied (or was only printed)
//   1  a FINDING: the proposed gate omits a required instrument, or --run reds
//   2  bad invocation
//   3  REFUSAL: the derivation or a required edge is broken, so any answer
//      would be a guess

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  REPO,
  NEEDS_ARGV,
  verifyDerivation,
  requiredFor as gateMapRequiredFor,
} from "../tooling/gate-map/gate-map.mjs";

// ── THE EDGE RATCHET ─────────────────────────────────────────────────────────
// A FLOOR, not the map. The map is derived every run and is free to grow; these
// are the specific edges whose ABSENCE was a shipped red, so their absence is a
// refusal rather than a shorter answer. Each was measured, and each names the
// row it was measured for.
export const REQUIRED_EDGES = [
  {
    file: "cloud/priv/static/app.css",
    instrument: "cloud/priv/static/__preview__/breakpoint-sweep.mjs",
    row: "cch-w17-bl-css-slice-gate-must-include-leg-a",
    why: "Leg A DERIVES the width axis from app.css's own @media preludes, so a breakpoint the stylesheet grows and BREAKPOINTS does not is exit 2 'UNCOVERED breakpoint …px'. Measured missing from the derived map on origin/main a917280fb.",
  },
  {
    file: "cloud/priv/static/__preview__/breakpoint-sweep.mjs",
    instrument: "cloud/priv/static/__css_check.mjs",
    row: "cchi-w37-bl-slice-gate-omits-the-surface-s-shipped-gates",
    why: "__css_check scans every .js/.mjs/.css directly inside cloud/priv/static and cloud/priv/static/__preview__ for E11 (banned `app.js:<line>` citations) by READING THE DIRECTORY — an import graph cannot find this edge.",
  },
];

export function verifyEdges(map, edges = REQUIRED_EDGES) {
  const problems = [];
  for (const e of edges) {
    const req = gateMapRequiredFor([e.file], map);
    if (!req.some((r) => r.path === e.instrument)) {
      problems.push(
        `the derived map no longer says ${e.instrument} reads ${e.file} — the edge ${e.row} exists for. ${e.why}`,
      );
    }
  }
  return { ok: problems.length === 0, problems };
}

// ── ONE TRANSITIVE HOP ───────────────────────────────────────────────────────
// An instrument that OPENS a required instrument's file is required too: it is
// driven by the thing the change moved. Derived from gate-map's own `file`
// scan sites (which come from `import … from "./x.mjs"`, `import("./x.mjs")`
// and `new URL("./x.mjs", import.meta.url)`), so the hop cannot drift into a
// hand-kept list of suites.
//
// THE HOP IS FENCED TWICE, and both fences were measured, not assumed. Hopping
// off EVERY required instrument, to EVERY file that names it, turns an app.css
// slice's gate from 17 instruments into 44 (measured on this tree): gate-map's
// literal-path extraction fires inside COMMENTS too, so "instrument A mentions
// instrument B" is a common and near-meaningless edge, and a 44-instrument gate
// is one nobody runs — the wave-17 failure wearing the opposite mask. So:
//
//   · the hop SOURCE must be an instrument that OPENS a changed file itself
//     (`kind === "file"`), not one swept in by a directory scan;
//   · the hop TARGET must be a TEST HARNESS — the suite that drives the
//     instrument whose derived axis just moved.
//
// That is the shape wave 17 actually needed: app.css moved, Leg A exited 2, and
// breakpoint-sweep.test.mjs reded 5 tests off the same derivation. Measured on
// this tree the fenced hop adds 4 suites (breakpoint-sweep, cssom-parity,
// exit-vocabulary, font-pin) and stops.
export const TEST_HARNESS = /\.test\.(m|c)?js$|\.test\.sh$/;

export function transitiveHop(required, map, isHarness = TEST_HARNESS) {
  const have = new Set(required.map((r) => r.path));
  const out = [...required];
  const sources = required.filter((r) => r.why.some((w) => w.via.kind === "file"));
  for (const inst of map.instruments) {
    if (have.has(inst.path)) continue;
    if (!isHarness.test(inst.path)) continue;
    for (const r of sources) {
      const hit = inst.scans.find((s) => s.kind === "file" && s.p === r.path);
      if (!hit) continue;
      out.push({
        path: inst.path,
        run: inst.run,
        why: [{ file: r.path, via: { kind: "file", p: r.path, evidence: `${hit.evidence} (one hop: it drives ${r.path})` } }],
        hop: true,
      });
      have.add(inst.path);
      break;
    }
  }
  return out.sort((a, b) => a.path.localeCompare(b.path));
}

export function requiredGate(changedFiles, map) {
  return transitiveHop(gateMapRequiredFor(changedFiles, map), map);
}

// ── THE REFUSAL ──────────────────────────────────────────────────────────────
// A gate "covers" an instrument when its text names the instrument's path. This
// is deliberately loose — it accepts `node <path>`, `node --test <path>`, or a
// wrapper step naming the path — because it is testing for an OMISSION, not
// auditing a command line.
export function gateCoverage(gateText, required) {
  const missing = required.filter((r) => !gateText.includes(r.path));
  return { ok: missing.length === 0, missing };
}

// ── plumbing ─────────────────────────────────────────────────────────────────
function readText(src) {
  return src === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(src, "utf8");
}

function readList(src) {
  return readText(src)
    .split("\n")
    .map((s) => s.trim())
    .filter((s) => s && !s.startsWith("#"));
}

function argOf(argv, name) {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[i + 1] : null;
}

export function main(argv) {
  const has = (f) => argv.includes(f);
  const gateSrc = argOf(argv, "--gate");
  const filesFrom = argOf(argv, "--files-from");

  const consumed = new Set();
  for (const f of ["--gate", "--files-from"]) {
    const i = argv.indexOf(f);
    if (i >= 0) {
      consumed.add(i);
      consumed.add(i + 1);
    }
  }
  const files = filesFrom
    ? readList(filesFrom)
    : argv.filter((a, i) => !a.startsWith("--") && !consumed.has(i));

  if (!files.length) {
    console.error(
      "usage: console-slice-gate.mjs <changed files…> [--files-from <list|->] [--gate <gate.txt|->] [--run]",
    );
    return 2;
  }

  const v = verifyDerivation();
  if (!v.ok) {
    console.error("REFUSED (3): gate-map's derivation is broken — a composed gate would be a guess.");
    for (const p of v.problems) console.error(`  · ${p}`);
    return 3;
  }
  const map = v.map;

  const edges = verifyEdges(map);
  if (!edges.ok) {
    console.error("REFUSED (3): a required edge has vanished from the derived map.");
    for (const p of edges.problems) console.error(`  · ${p}`);
    return 3;
  }

  const required = requiredGate(files, map);
  console.log(`SLICE  ${files.length} changed file(s)`);
  for (const f of files) console.log(`  ${f}`);
  console.log(`GATE   ${required.length} instrument(s) must run over those paths:`);
  for (const r of required) {
    const w = r.why[0];
    const how =
      w.via.kind === "self"
        ? "it IS the edited file"
        : `it ${w.via.kind === "dir" ? "reads the directory" : w.via.kind === "tree" ? "walks the subtree" : "opens"} ${w.via.p}`;
    console.log(`  ${r.run}`);
    console.log(`      because ${how}  (${w.via.evidence})`);
  }

  if (gateSrc) {
    const gateText = readText(gateSrc);
    const cov = gateCoverage(gateText, required);
    if (!cov.ok) {
      console.error(
        `\nGATE REFUSED (1): the proposed gate omits ${cov.missing.length} instrument(s) that read this slice's files.`,
      );
      for (const m of cov.missing) {
        const e = REQUIRED_EDGES.find((x) => x.instrument === m.path);
        console.error(`  · ${m.run}`);
        console.error(`      ${m.why[0].via.evidence}${e ? `  [${e.row}]` : ""}`);
      }
      console.error(
        "  A slice gate must be a SUPERSET of what the merge gate runs over the touched paths. Add them, or the Console gate finds it on arrival.",
      );
      return 1;
    }
    console.log(`\nGATE OK — the proposed gate names all ${required.length} required instrument(s).`);
  }

  if (!has("--run")) return 0;

  // FAIL-FAST. The composed gate over app.css includes browser legs; once an
  // instrument has reded, the gate is red and the remaining minutes buy nothing.
  for (const r of required) {
    const parts = r.run.split(" ");
    console.log(`\n─── ${r.run}`);
    const res = spawnSync(parts[0], parts.slice(1), { cwd: REPO, encoding: "utf8" });
    const out = (res.stdout || "") + (res.stderr || "");
    process.stdout.write(out);
    if (res.status === 0) continue;
    if (res.status === 2 && NEEDS_ARGV.test(out)) {
      console.log(`NEEDS-INVOCATION  ${r.run}  exit 2 — it refused for want of arguments, not for a finding`);
      continue;
    }
    console.log(`\nCOMPOSED GATE RED — ${r.run} exited ${res.status}`);
    return 1;
  }
  console.log(`\nCOMPOSED GATE GREEN — ${required.length} instrument(s)`);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exit(main(process.argv.slice(2)));
}
