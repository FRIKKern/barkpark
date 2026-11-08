import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { besideMain, buildEnv, makeBuild, pickBuild, stageOldBuild } from "../paper-editor/src/testing-ground/builds.mjs";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const git = (...args) => execFileSync("git", args, { cwd: REPO, encoding: "utf8" }).trim();
const noGit = () => assert.fail("this build needs no git");
const leftovers = () => readdirSync(tmpdir()).filter((name) => name.startsWith("tg-build-")).length;
const before = leftovers();
for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => process.exit({ SIGINT: 130, SIGTERM: 143 }[signal]));

assert.deepEqual(pickBuild("1.19", { repo: REPO, git: noGit }), { label: "contract 1.19", sha: "648bfeeb44" }, "a contract is the tree R2.2 recorded it from");
assert.throws(() => pickBuild("1.99", { repo: REPO, git: noGit }), /^Error: no recorded tree for contract 1\.99; recorded: 1\.14, 1\.15, 1\.16, 1\.17, 1\.18, 1\.19$/);
for (const [names, opened] of [
  [[], ["main"]],
  [["main"], ["main"]],
  [["25044"], ["main", "25044"]],
  [["main", "25044"], ["main", "25044"]],
  [["1.19", "25044"], ["1.19", "25044"]],
]) assert.deepEqual(besideMain(names), opened, `npm run try ${names.join(" ")} opens ${opened.join(" beside ")}`);
for (const bad of ["x", "1.19.0", "0", "-3", "25044a", "", "1.19 "])
  assert.throws(() => pickBuild(bad, { repo: REPO, git: noGit }), /^Error: a build is main, a PR number or a contract like 1\.19, got /, JSON.stringify(bad));

const HEAD_25044 = "cebb1356c442dcead429139234577210e0c65c52";
function remote(have, branch = true) {
  const calls = [];
  const run = (...args) => {
    calls.push(args.join(" "));
    if (args[0] === "ls-remote" && args[2] === "refs/heads/*") return `${"1".repeat(40)}\trefs/heads/main${branch ? `\n${HEAD_25044}\trefs/heads/pd/enter` : ""}`;
    if (args[0] === "ls-remote") return args[2] === "refs/pull/25044/head" ? `${HEAD_25044}\trefs/pull/25044/head` : "";
    if (args[0] === "cat-file" && !have) throw new Error("missing");
    return "";
  };
  return { calls, run };
}
const known = remote(true);
assert.deepEqual(pickBuild("25044", { repo: REPO, git: known.run }), { label: "PR #25044", sha: HEAD_25044 });
assert.deepEqual(known.calls, ["ls-remote origin refs/pull/25044/head", "ls-remote origin refs/heads/*", `cat-file -e ${HEAD_25044}^{commit}`], "a head already here is not fetched");
const fresh = remote(false);
pickBuild("25044", { repo: REPO, git: fresh.run });
assert.equal(fresh.calls.at(-1), `fetch -q --no-write-fetch-head origin ${HEAD_25044}`, "a missing head is fetched by sha, with no ref and no FETCH_HEAD");
assert.throws(() => pickBuild("24700", { repo: REPO, git: remote(true).run }), /^Error: no PR #24700 on origin$/);
const stranger = remote(false, false);
assert.throws(() => pickBuild("25044", { repo: REPO, git: stranger.run }), /^Error: PR #25044 is not a branch on origin; npm run try builds only those$/);
assert.deepEqual(stranger.calls, ["ls-remote origin refs/pull/25044/head", "ls-remote origin refs/heads/*"], "a PR head on no branch of origin is neither fetched nor built");
assert.deepEqual(buildEnv({ PATH: "/bin", HOME: "/h", TMPDIR: "/t", BARKPARK_TG_TOKEN: "planted", NODE_OPTIONS: "--require=x" }), { PATH: "/bin", HOME: "/h", TMPDIR: "/t" }, "a build gets PATH, HOME and TMPDIR only");

const head = git("rev-parse", "HEAD");
const committed = Number(git("log", "-1", "--format=%ct", "HEAD")) * 1000;
const version = git("show", "HEAD:api/assets/paper-editor/src/contract.js").match(/CONTRACT_VERSION = "([^"]+)"/)[1];
const SEVEN = ["bp-paper-code.js", "bp-paper-editor-shell.css", "bp-paper-editor.bundle.js", "bp-paper-editor.css", "bp-paper-mermaid.js", "bp-paper-surface.css", "contract.js"];
const hostBundle = join(REPO, "api/priv/static/assets/bp-paper-editor.bundle.js");
const hostBundleBefore = readFileSync(hostBundle);
const built = makeBuild({ label: "HEAD", sha: head }, { repo: REPO });
const root = join(built.dir, "../../../..");
try {
  assert.deepEqual([built.label, built.sha], ["HEAD", head.slice(0, 10)]);
  assert.ok(built.dir.endsWith("/api/assets/paper-editor/dist"), `a build is the package's own dist: ${built.dir}`);
  assert.deepEqual(readdirSync(built.dir).sort(), SEVEN, "a build is exactly the seven package outputs");
  assert.deepEqual(readdirSync(root), ["api"], "a package-owned commit archives only the package");
  assert.deepEqual(readdirSync(join(root, "api")), ["assets"], "a package-owned commit archives only the package");
  assert.deepEqual(readdirSync(join(root, "api/assets")), ["paper-editor"], "a package-owned commit archives only the package");
  assert.ok(hostBundleBefore.equals(readFileSync(hostBundle)), "a build writes nothing into this checkout's host assets");
  const bundle = join(built.dir, "bp-paper-editor.bundle.js");
  assert.ok(readFileSync(bundle, "utf8").includes(`"${version}"`), `the bundle carries contract ${version}`);
  assert.ok(statSync(bundle).mtimeMs > committed, "the bundle was built here, not just unpacked from the commit");
  assert.ok(lstatSync(join(root, "api/assets/paper-editor/node_modules")).isDirectory(), "the tree builds with its own copy of node_modules, so a build cannot write this checkout's");
} finally {
  built.remove();
}
assert.equal(existsSync(root), false, "remove() deletes the whole tree");

// A recorded contract's own archive built into its own host folder. Staging it reads
// only that disposable tree and gives the same seven files.
const oldTree = mkdtempSync(join(tmpdir(), "tg-old-"));
try {
  const hostAssets = join(oldTree, "api/priv/static/assets");
  const oldSource = join(oldTree, "api/assets/paper-editor/src");
  mkdirSync(hostAssets, { recursive: true });
  mkdirSync(oldSource, { recursive: true });
  for (const name of SEVEN.filter((n) => n !== "contract.js")) writeFileSync(join(hostAssets, name), `old ${name}`);
  writeFileSync(join(oldSource, "contract.js"), "old contract");
  stageOldBuild(oldTree);
  const stagedDir = join(oldTree, "api/assets/paper-editor/dist");
  assert.deepEqual(readdirSync(stagedDir).sort(), SEVEN, "an old build is staged as the same seven files");
  assert.equal(readFileSync(join(stagedDir, "bp-paper-surface.css"), "utf8"), "old bp-paper-surface.css");
  assert.equal(readFileSync(join(stagedDir, "contract.js"), "utf8"), "old contract");
  rmSync(join(hostAssets, "bp-paper-code.js"));
  assert.throws(() => stageOldBuild(oldTree), /ENOENT/, "an old build missing an output fails instead of serving a partial tree");
} finally {
  rmSync(oldTree, { recursive: true, force: true });
}

assert.throws(() => makeBuild({ label: "nothing", sha: "0".repeat(40) }, { repo: REPO }), /^Error: git archive 0{40}: fatal: /);
const empty = mkdtempSync(join(tmpdir(), "tg-empty-"));
try {
  assert.throws(() => makeBuild({ label: "HEAD", sha: head }, { repo: REPO, modules: empty }), /^Error: npm run build for HEAD at [0-9a-f]{10} failed:\n[\s\S]*esbuild/);
} finally {
  rmSync(empty, { recursive: true, force: true });
}
assert.equal(leftovers(), before, "a failed build leaves no tree behind");

const holder = `const { makeBuild } = await import(${JSON.stringify(new URL("../paper-editor/src/testing-ground/builds.mjs", import.meta.url).href)});
for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => process.exit({ SIGINT: 130, SIGTERM: 143 }[signal]));
makeBuild({ label: "HEAD", sha: ${JSON.stringify(head)} }, { repo: ${JSON.stringify(REPO)} });
console.log("built");
setInterval(() => {}, 1000);`;
const killed = spawn(process.execPath, ["--input-type=module", "-e", holder], { stdio: ["ignore", "pipe", "inherit"] });
await new Promise((resolve, reject) => {
  killed.stdout.on("data", (d) => String(d).includes("built") && resolve());
  killed.on("exit", (code) => reject(new Error(`the holder exited ${code} before it built`)));
});
assert.equal(leftovers(), before + 1, "the waiting child holds one tree");
killed.kill("SIGTERM");
await new Promise((resolve) => killed.on("exit", resolve));
assert.equal(leftovers(), before, "a run stopped by SIGTERM removes its tree");

console.log("PASS  testing-ground builds: a PR head by sha, a recorded contract tree, seven files in the archive's own dist, built from git archive, removed after, on a throw and on SIGTERM");
