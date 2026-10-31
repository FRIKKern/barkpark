// __path_filter_scan.test.mjs — the scanner behind __path_filter.test.mjs, on a
// synthetic tree. The real tree only exercises the read shapes it happens to
// use today; every shape the scanner claims is pinned here, so dropping an arm
// reds even when no real file uses that shape yet.
//
// Run: node src/__path_filter_scan.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { covers, filterArms, scanner, verdict } from "./__path_filter.test.mjs";

const repo = realpathSync(mkdtempSync(join(tmpdir(), "bp-path-filter-")));
const pkg = join(repo, "fx/assets/ed");
const put = (rel, text = "") => {
  mkdirSync(dirname(join(repo, rel)), { recursive: true });
  writeFileSync(join(repo, rel), text);
};

try {
  for (const f of ["fx/lib/a.ex", "fx/lib/b.ex", "fx/lib/c.ex", "node_modules/dep/index.js"]) put(f);
  put("fx/assets/ed/src/helper.mjs", 'readFileSync(new URL("../../../lib/b.ex", import.meta.url));');

  const { candidates, sinkOf } = scanner({ repo, pkg });
  const sinks = (text, name = "src/t.mjs") => {
    const file = join(pkg, name);
    return candidates(file, text).map((c) => sinkOf(file, c)).filter((h) => h?.sink).map((h) => h.sink);
  };

  const shapes = [
    ["relative literal", 'readFileSync(new URL("../../../lib/a.ex", import.meta.url))', ["fx/lib/a.ex"]],
    ["bare repo path", 'execFileSync("git", ["ls-files", "fx/lib/a.ex"])', ["fx/lib/a.ex"]],
    ["${ROOT}/x template", "readFileSync(`${root}/fx/lib/a.ex`)", ["fx/lib/a.ex"]],
    ["ROOT + \"/x\" concat", 'readFileSync(root + "/fx/lib/a.ex")', ["fx/lib/a.ex"]],
    ["multi-part join", 'readFileSync(join(root, "fx", "lib", "a.ex"))', ["fx/lib/a.ex"]],
    ["join with a non-literal tail is a folder", 'readFileSync(join(root, "fx", "lib", name))', ["fx/lib/"]],
    ["bare template hole is a folder", "readFileSync(`fx/lib/${n}.ex`)", ["fx/lib/"]],
    ["relative template hole is a folder", "readFileSync(new URL(`../../../lib/${n}.ex`, import.meta.url))", ["fx/lib/"]],
    ["a template whose fixed part is a file is not a read", "x(`../../../lib/a.ex/${n}`)", []],
    ["node_modules is not a sink", 'import("../../../../node_modules/dep/index.js")', []],
    ["a repo-root anchor is not a sink", 'const REPO = join(__dirname, "..", "..", "..", "..")', []],
    ["a missing file is not a sink", 'readFileSync(new URL("../../../lib/nope.ex", import.meta.url))', []],
  ];
  for (const [name, text, want] of shapes) assert.deepEqual(sinks(text), want, name);
  assert.deepEqual(sinks("@import url(../../../lib/a.ex);", "src/s.css"), ["fx/lib/a.ex"], "CSS url() without quotes");
  assert.deepEqual(sinks('const p = "./helper.mjs";').length, 0, "an inside file is followed, not a sink");

  const notRead = new Map([["fx/lib/a.ex", "src/data.mjs"]]);
  const bound = scanner({ repo, pkg, notRead, self: join(pkg, "src/self.mjs") });
  const boundSinks = (name) => {
    const file = join(pkg, name);
    return bound.candidates(file, '"fx/lib/a.ex"').map((c) => bound.sinkOf(file, c)).filter((h) => h?.sink).map((h) => h.sink);
  };
  assert.deepEqual(boundSinks("src/data.mjs"), [], "NOT_READ exempts the token in the file it names");
  assert.deepEqual(boundSinks("src/self.mjs"), [], "NOT_READ exempts the file that declares it");
  assert.deepEqual(boundSinks("src/other.mjs"), ["fx/lib/a.ex"], "the same token in another file is a sink");

  put("fx/assets/ed/src/entry.mjs", 'import "./helper.mjs";\nreadFileSync(new URL("../../../lib/a.ex", import.meta.url));');
  put("fx/assets/ed/src/pre.mjs", 'readFileSync(join(root, "fx", "lib", "c.ex"));');
  put("fx/assets/ed/scripts/pack.mjs", 'readFileSync(new URL("../../../lib/a.ex", import.meta.url));');
  const scripts = { pretest: "node src/pre.mjs", test: "node src/entry.mjs", pack: "node scripts/pack.mjs", unused: "node src/nope.mjs" };
  const yml = [
    "on:",
    "  push:",
    "    branches: [main]",
    "    paths:",
    '      - "fx/assets/ed/**"',
    '      - "fx/lib/a.ex"',
    '      - "fx/lib/b.ex"',
    '      - "fx/lib/stale.ex"',
    "  pull_request:",
    "    paths:",
    '      - "fx/assets/ed/**"',
    '      - "fx/lib/a.ex"',
    "jobs:",
    "  build-it:",
    "    steps:",
    "      - run: npm test",
  ].join("\n");
  const arms = filterArms(yml);
  assert.deepEqual(arms, {
    push: ["fx/assets/ed/**", "fx/lib/a.ex", "fx/lib/b.ex", "fx/lib/stale.ex"],
    pull_request: ["fx/assets/ed/**", "fx/lib/a.ex"],
  });
  const walked = scanner({ repo, pkg }).reads(yml, scripts);
  assert.equal(walked.entries, 2, "npm test runs pretest and test, not pack");
  assert.deepEqual([...walked.sinks.keys()].sort(), ["fx/lib/a.ex", "fx/lib/b.ex", "fx/lib/c.ex"], "reads through hooks and imports");
  assert.deepEqual(verdict(arms, walked.sinks, "fx/assets/ed/"), {
    unequal: true,
    missing: ["fx/lib/c.ex  (read by fx/assets/ed/src/pre.mjs)"],
    unused: ["fx/lib/stale.ex"],
  });

  assert.equal(covers(["fx/priv/static/assets/*"], "fx/priv/static/assets/"), true);
  assert.equal(covers(["fx/priv/static/assets/*.css"], "fx/priv/static/assets/"), false);
  assert.equal(covers(["fx/lib/**"], "fx/lib/x/y.ex"), true);
  assert.equal(covers(["fx/lib/*"], "fx/lib/x/y.ex"), false);
  assert.equal(covers(["fx/lib/a.ex"], "fx/lib/b.ex"), false);

  console.log(`ok path filter scanner: ${shapes.length + 5} read shapes, a walk through hooks and imports, and the verdict on a synthetic tree`);
} finally {
  rmSync(repo, { recursive: true, force: true });
}
