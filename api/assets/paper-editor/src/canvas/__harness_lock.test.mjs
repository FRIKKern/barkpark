// __harness_lock.test.mjs — the browser-free half of the canvas-harness gate.
//
// It lives apart from __harness_generic_run.mjs on purpose. That file needs
// Chromium and a static server, so by this package's own convention (see
// __test_chain_census.mjs: "Runner entrypoints such as __smoke.mjs /
// __narrow_render.mjs do not match") it is a runner entrypoint, opt-in, outside
// `npm test`. These two assertions need nothing but the filesystem, so they run
// on every machine, in CI, on every PR:
//
//   1. __harness.html is BYTE-LOCKED. Its hardcoded three-block RUN and its S1
//      assertions are the continuous-canvas regression. __harness_generic.html
//      exists precisely so nobody has to generalize them away; without a lock,
//      "just parameterize the existing one" is a one-line diff nobody notices.
//   2. the committed real-paper fixture is a real capture — versioned, with the
//      slug and rev it came from. Provenance IS the evidence; a fixture someone
//      hand-typed proves nothing about a published paper.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../../../../..");
const HARNESS_DIR = "api/assets/paper-editor/src/canvas";

let failures = 0;
const check = (name, fn) => {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
};

// If this pin reds, either the S1 harness was edited (revert it, or move the
// change into __harness_generic.html) or the edit is deliberate and the
// reviewer updates this constant IN THE SAME PR, with a reason.
const S1_HARNESS_SHA256 =
  "4ee15511d3566c4c26e75754e248edf3885d20965676a9f8062d60ba71980fb4";

check("__harness.html is byte-locked (S1 assertions unchanged)", () => {
  const path = join(REPO, HARNESS_DIR, "__harness.html");
  const actual = createHash("sha256").update(readFileSync(path)).digest("hex");
  if (actual !== S1_HARNESS_SHA256) {
    throw new Error(
      `${HARNESS_DIR}/__harness.html changed.\n` +
        `      pinned  ${S1_HARNESS_SHA256}\n` +
        `      actual  ${actual}\n` +
        "      The S1 harness is load-bearing for the continuous-canvas regression.\n" +
        "      Parameterized work belongs in __harness_generic.html. If this edit is\n" +
        "      deliberate, update S1_HARNESS_SHA256 in this file and say why.",
    );
  }
});

// A sha256 over a file nobody reads would pass for free if the file were
// missing or empty, so the S1 RUN literal is asserted separately: the lock is
// about those three blocks, and this says so in terms a reader recognises.
check("__harness.html still carries its hardcoded three-block S1 RUN", () => {
  const src = readFileSync(join(REPO, HARNESS_DIR, "__harness.html"), "utf8");
  for (const needle of ["const RUN = [", '"b-h"', '"b-p"', '"b-l"', "el.blocks = RUN;"]) {
    if (!src.includes(needle)) {
      throw new Error(`the S1 harness no longer contains ${JSON.stringify(needle)}`);
    }
  }
});

check("the committed fixture is a versioned capture of a published paper", () => {
  const f = JSON.parse(
    readFileSync(join(REPO, HARNESS_DIR, "__fixtures/paper-mechanical-spacing-doctrine.json"), "utf8"),
  );
  if (f.version !== 1) throw new Error(`version is ${JSON.stringify(f.version)}, expected 1`);
  if (!Array.isArray(f.blocks) || f.blocks.length === 0) throw new Error("blocks is not a non-empty array");
  if (!f.capture || !f.capture.paper_slug || !f.capture.paper_rev) {
    throw new Error("capture.paper_slug / capture.paper_rev missing — the provenance IS the evidence");
  }
  const types = new Set(f.blocks.map((b) => b.type));
  if (types.size < 5) {
    throw new Error(`only ${types.size} distinct block types — too tame to be a real-paper proof`);
  }
  console.log(
    `      ${f.blocks.length} blocks, ${types.size} block types, ` +
      `paper ${f.capture.paper_slug} @ rev ${f.capture.paper_rev}`,
  );
});

console.log(failures === 0 ? "\nOK  __harness_lock.test.mjs" : `\n${failures} FAILING  __harness_lock.test.mjs`);
process.exit(failures === 0 ? 0 : 1);
