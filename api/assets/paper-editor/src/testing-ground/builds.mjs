import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const REPLAY = "api/test/fixtures/portable_doc/old_client_replay";
const PACKAGE = "api/assets/paper-editor";
const OWNED_BUILD = `${PACKAGE}/scripts/build-local.mjs`;
// A commit from before the package owned its build needs these to build at all, and
// writes into the last one. Only that commit's own disposable archive is ever read.
const OLD_TREE = [PACKAGE, "api/assets/paper-surface", "api/priv/static/assets"];
const READER = "api/lib/barkpark/portable_doc/render";
const OUTPUTS = ["bp-paper-editor.bundle.js", "bp-paper-editor.css", "bp-paper-code.js", "bp-paper-surface.css", "bp-paper-editor-shell.css", "bp-paper-mermaid.js", "contract.js"];

const live = new Set();
process.on("exit", () => { for (const root of live) rmSync(root, { recursive: true, force: true }); });

const gitIn = (repo) => (...args) => execFileSync("git", args, { cwd: repo, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();

function recordedContracts(repo) {
  return readdirSync(join(repo, REPLAY)).map((name) => name.replace(/\.json$/, "")).sort();
}

function contractCommit(repo, version) {
  const file = join(repo, REPLAY, `${version}.json`);
  if (!existsSync(file)) throw new Error(`no recorded tree for contract ${version}; recorded: ${recordedContracts(repo).join(", ")}`);
  return JSON.parse(readFileSync(file, "utf8")).commit;
}

function prHead(git, number) {
  const sha = git("ls-remote", "origin", `refs/pull/${number}/head`).split("\t")[0];
  if (!sha) throw new Error(`no PR #${number} on origin`);
  const branches = git("ls-remote", "origin", "refs/heads/*").split("\n").map((line) => line.split("\t")[0]);
  if (!branches.includes(sha)) throw new Error(`PR #${number} is not a branch on origin; npm run try builds only those`);
  try {
    git("cat-file", "-e", `${sha}^{commit}`);
  } catch {
    git("fetch", "-q", "--no-write-fetch-head", "origin", sha);
  }
  return sha;
}

export const buildEnv = (env) => Object.fromEntries(["PATH", "HOME", "TMPDIR"].map((name) => [name, env[name]]));

export const besideMain = (names) => (names.length === 1 && names[0] !== "main" ? ["main", ...names] : names.length ? names : ["main"]);

export function pickBuild(which, { repo, git = gitIn(repo) }) {
  if (/^[1-9]\d*$/.test(which)) return { label: `PR #${which}`, sha: prHead(git, which) };
  if (/^\d+\.\d+$/.test(which)) return { label: `contract ${which}`, sha: contractCommit(repo, which) };
  throw new Error(`a build is main, a PR number or a contract like 1.19, got ${which}`);
}

const hasPath = (repo, sha, path) => spawnSync("git", ["cat-file", "-e", `${sha}:${path}`], { cwd: repo }).status === 0;

// An old commit's `npm run build` wrote into its own archived host folder. Give it
// the same seven-file dist/ every other build has.
export function stageOldBuild(root) {
  const dist = join(root, PACKAGE, "dist");
  mkdirSync(dist, { recursive: true });
  for (const name of OUTPUTS) {
    copyFileSync(name === "contract.js" ? join(root, PACKAGE, "src/contract.js") : join(root, OLD_TREE[2], name), join(dist, name));
  }
}

export function makeBuild({ label, sha }, { repo, modules = join(repo, PACKAGE, "node_modules") }) {
  const root = mkdtempSync(join(tmpdir(), "tg-build-"));
  live.add(root);
  const remove = () => {
    rmSync(root, { recursive: true, force: true });
    live.delete(root);
  };
  try {
    const owned = hasPath(repo, sha, OWNED_BUILD);
    const tree = owned ? [PACKAGE] : [...OLD_TREE, ...(hasPath(repo, sha, READER) ? [READER] : [])];
    const tar = spawnSync("git", ["archive", sha, ...tree], { cwd: repo, maxBuffer: 1 << 30 });
    if (tar.status !== 0) throw new Error(`git archive ${sha}: ${tar.stderr.toString().trim()}`);
    execFileSync("tar", ["-x", "-C", root], { input: tar.stdout, stdio: ["pipe", "ignore", "pipe"] });
    const editor = join(root, PACKAGE);
    cpSync(modules, join(editor, "node_modules"), { recursive: true, verbatimSymlinks: true });
    const built = spawnSync("npm", ["run", "build"], { cwd: editor, encoding: "utf8", timeout: 120000, env: buildEnv(process.env) });
    if (built.status !== 0) throw new Error(`npm run build for ${label} at ${sha.slice(0, 10)} failed:\n${`${built.stdout}${built.stderr}`.trim().split("\n").slice(-20).join("\n")}`);
    if (!owned) stageOldBuild(root);
  } catch (error) {
    remove();
    throw error;
  }
  return { label, sha: sha.slice(0, 10), dir: join(root, PACKAGE, "dist"), remove };
}
