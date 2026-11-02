import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { makeBuild, pickBuild } from "./builds.mjs";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "../../../../..");
const git = (...args) => execFileSync("git", args, { cwd: REPO, encoding: "utf8" }).trim();
const noGit = () => assert.fail("this build needs no git");
const leftovers = () => readdirSync(tmpdir()).filter((name) => name.startsWith("tg-build-")).length;
const before = leftovers();

assert.deepEqual(pickBuild("1.19", { repo: REPO, git: noGit }), { label: "contract 1.19", sha: "648bfeeb44" }, "a contract is the tree R2.2 recorded it from");
assert.throws(() => pickBuild("1.99", { repo: REPO, git: noGit }), /^Error: no recorded tree for contract 1\.99; recorded: 1\.14, 1\.15, 1\.16, 1\.17, 1\.18, 1\.19$/);
for (const bad of ["x", "1.19.0", "0", "-3", "25044a", "", "1.19 "])
  assert.throws(() => pickBuild(bad, { repo: REPO, git: noGit }), /^Error: a build is main, a PR number or a contract like 1\.19, got /, JSON.stringify(bad));

const HEAD_25044 = "cebb1356c442dcead429139234577210e0c65c52";
function remote(have) {
  const calls = [];
  const run = (...args) => {
    calls.push(args.join(" "));
    if (args[0] === "ls-remote") return args[2] === "refs/pull/25044/head" ? `${HEAD_25044}\trefs/pull/25044/head` : "";
    if (args[0] === "cat-file" && !have) throw new Error("missing");
    return "";
  };
  return { calls, run };
}
const known = remote(true);
assert.deepEqual(pickBuild("25044", { repo: REPO, git: known.run }), { label: "PR #25044", sha: HEAD_25044 });
assert.deepEqual(known.calls, ["ls-remote origin refs/pull/25044/head", `cat-file -e ${HEAD_25044}^{commit}`], "a head already here is not fetched");
const fresh = remote(false);
pickBuild("25044", { repo: REPO, git: fresh.run });
assert.equal(fresh.calls.at(-1), `fetch -q --no-write-fetch-head origin ${HEAD_25044}`, "a missing head is fetched by sha, with no ref and no FETCH_HEAD");
assert.throws(() => pickBuild("24700", { repo: REPO, git: remote(true).run }), /^Error: no PR #24700 on origin$/);

const head = git("rev-parse", "HEAD");
const committed = Number(git("log", "-1", "--format=%ct", "HEAD")) * 1000;
const version = git("show", "HEAD:api/assets/paper-editor/src/contract.js").match(/CONTRACT_VERSION = "([^"]+)"/)[1];
const built = makeBuild({ label: "HEAD", sha: head }, { repo: REPO });
const root = join(built.dir, "../../../..");
try {
  assert.deepEqual([built.label, built.sha], ["HEAD", head.slice(0, 10)]);
  for (const name of ["bp-paper-editor.bundle.js", "bp-paper-editor.css", "bp-paper-editor-shell.css"]) assert.ok(existsSync(join(built.dir, name)), `${name} is in the build`);
  const bundle = join(built.dir, "bp-paper-editor.bundle.js");
  assert.ok(readFileSync(bundle, "utf8").includes(`"${version}"`), `the bundle carries contract ${version}`);
  assert.ok(statSync(bundle).mtimeMs > committed, "the bundle was built here, not just unpacked from the commit");
  assert.ok(statSync(join(root, "api/assets/paper-editor/node_modules")).isDirectory(), "the tree borrows this checkout's node_modules");
} finally {
  built.remove();
}
assert.equal(existsSync(root), false, "remove() deletes the whole tree");

assert.throws(() => makeBuild({ label: "nothing", sha: "0".repeat(40) }, { repo: REPO }), /^Error: git archive 0{40}: fatal: /);
const empty = mkdtempSync(join(tmpdir(), "tg-empty-"));
try {
  assert.throws(() => makeBuild({ label: "HEAD", sha: head }, { repo: REPO, modules: empty }), /^Error: npm run build for HEAD at [0-9a-f]{10} failed:\n[\s\S]*esbuild/);
} finally {
  rmSync(empty, { recursive: true, force: true });
}
assert.equal(leftovers(), before, "a failed build leaves no tree behind");

console.log("PASS  testing-ground builds: a PR head by sha, a recorded contract tree, built from git archive and removed after");
