import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const REPLAY = "api/test/fixtures/portable_doc/old_client_replay";
const TREE = ["api/assets/paper-editor", "api/assets/paper-surface", "api/priv/static/assets"];

const gitIn = (repo) => (...args) => execFileSync("git", args, { cwd: repo, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();

function recordedContracts(repo) {
  return readdirSync(join(repo, REPLAY)).filter((name) => name.endsWith(".json")).map((name) => name.slice(0, -5)).sort((a, b) => a.localeCompare(b, "en", { numeric: true }));
}

function contractCommit(repo, version) {
  const file = join(repo, REPLAY, `${version}.json`);
  if (!existsSync(file)) throw new Error(`no recorded tree for contract ${version}; recorded: ${recordedContracts(repo).join(", ")}`);
  return JSON.parse(readFileSync(file, "utf8")).commit;
}

function prHead(git, number) {
  const sha = git("ls-remote", "origin", `refs/pull/${number}/head`).split("\t")[0];
  if (!sha) throw new Error(`no PR #${number} on origin`);
  try {
    git("cat-file", "-e", `${sha}^{commit}`);
  } catch {
    git("fetch", "-q", "--no-write-fetch-head", "origin", sha);
  }
  return sha;
}

export function pickBuild(which, { repo, git = gitIn(repo) }) {
  if (/^[1-9]\d*$/.test(which)) return { label: `PR #${which}`, sha: prHead(git, which) };
  if (/^\d+\.\d+$/.test(which)) return { label: `contract ${which}`, sha: contractCommit(repo, which) };
  throw new Error(`a build is main, a PR number or a contract like 1.19, got ${which}`);
}

export function makeBuild({ label, sha }, { repo, modules = join(repo, "api/assets/paper-editor/node_modules") }) {
  const root = mkdtempSync(join(tmpdir(), "tg-build-"));
  const remove = () => rmSync(root, { recursive: true, force: true });
  try {
    const tar = spawnSync("git", ["archive", sha, ...TREE], { cwd: repo, maxBuffer: 1 << 30 });
    if (tar.status !== 0) throw new Error(`git archive ${sha}: ${tar.stderr.toString().trim()}`);
    const untar = spawnSync("tar", ["-x", "-C", root], { input: tar.stdout });
    if (untar.status !== 0) throw new Error(`tar: ${untar.stderr.toString().trim()}`);
    const editor = join(root, TREE[0]);
    symlinkSync(modules, join(editor, "node_modules"));
    const built = spawnSync("npm", ["run", "build"], { cwd: editor, encoding: "utf8", timeout: 120000 });
    if (built.status !== 0) throw new Error(`npm run build for ${label} at ${sha.slice(0, 10)} failed:\n${`${built.stdout}${built.stderr}`.trim().split("\n").slice(-20).join("\n")}`);
  } catch (error) {
    remove();
    throw error;
  }
  return { label, sha: sha.slice(0, 10), dir: join(root, TREE[2]), remove };
}
