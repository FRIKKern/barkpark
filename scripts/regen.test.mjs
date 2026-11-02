import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { parseArgs } from "./regen.mjs";
import { report } from "./reach.mjs";

function fixture(t, steps) {
  const dir = mkdtempSync(join(tmpdir(), "regen-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, "scripts"));
  for (const name of ["regen.mjs", "reach.mjs"]) copyFileSync(new URL(name, import.meta.url), join(dir, "scripts", name));
  writeFileSync(join(dir, "scripts/derived-files.mjs"), `
    export const STEPS = ${JSON.stringify(steps.map((s) => ({ after: [], gates: [], ...s })))};
    export const ordered = (steps = STEPS) => steps;
    export const reached = () => STEPS;
    export const step = (name) => { const s = STEPS.find(s => s.name === name); if (!s) throw Error('unknown step'); return s; };
  `);
  writeFileSync(join(dir, "tracked.txt"), "original\n");
  const git = (...args) => execFileSync("git", ["-c", "core.hooksPath=/dev/null", ...args], { cwd: dir, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  git("init", "--quiet");
  git("add", ".");
  git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture");
  return { dir, git, run: (script, ...args) => spawnSync(process.execPath, [`scripts/${script}.mjs`, ...args], { cwd: dir, encoding: "utf8" }) };
}

test("regen rejects missing, conflicting and repeated option values", () => {
  for (const args of [["--base"], ["--only"], ["--base", "--check"], ["--only", ""], ["--base", "HEAD", "--only", "x"], ["--base", "HEAD", "--base", "HEAD"], ["--wat"]]) {
    assert.throws(() => parseArgs(args), args.join(" "));
  }
  assert.deepEqual(parseArgs(["--check", "--only", "a", "--only", "b"]), { check: true, base: null, only: ["a", "b"] });
});

test("regen CLI refuses missing base before any generator runs", (t) => {
  const f = fixture(t, [{ name: "one", write: "touch marker" }]);
  assert.equal(f.run("regen", "--base").status, 2);
  assert.ok(!existsSync(join(f.dir, "marker")));
});

test("reach passes a base as a Git argument without shell expansion", (t) => {
  const f = fixture(t, []);
  assert.equal(f.run("reach", "HEAD; touch injected").status, 2);
  assert.ok(!existsSync(join(f.dir, "injected")));
  assert.equal(f.run("reach", "HEAD", "ignored").status, 2);
  assert.equal(f.run("reach", "HEAD").status, 0);
});

test("regen stops before downstream generators after failure", (t) => {
  const f = fixture(t, [{ name: "one", write: "exit 9" }, { name: "two", after: ["one"], write: "touch downstream" }]);
  assert.equal(f.run("regen").status, 1);
  assert.ok(!existsSync(join(f.dir, "downstream")));
});

test("check restores tracked files and unusual generated names after failure", (t) => {
  const f = fixture(t, [{ name: "one", write: `printf changed > tracked.txt; touch "quote'file"; touch 'line
break'; exit 9` }]);
  assert.equal(f.run("regen", "--check").status, 1);
  assert.equal(readFileSync(join(f.dir, "tracked.txt"), "utf8"), "original\n");
  assert.equal(f.git("status", "--porcelain"), "");
});

test("check refuses a dirty tree without changing staged or unstaged edits", (t) => {
  const f = fixture(t, [{ name: "one", write: "printf generated > tracked.txt" }]);
  writeFileSync(join(f.dir, "tracked.txt"), "staged\n");
  f.git("add", "tracked.txt");
  writeFileSync(join(f.dir, "tracked.txt"), "unstaged\n");
  assert.equal(f.run("regen", "--check").status, 2);
  assert.equal(readFileSync(join(f.dir, "tracked.txt"), "utf8"), "unstaged\n");
  assert.equal(f.git("show", ":tracked.txt"), "staged\n");
});

test("reach prints each reached step's complete prerequisite command", () => {
  const text = report("HEAD", ["internal/pdrender/render.go", "js/packages/react/src/blocks/Toc.tsx"]);
  assert.match(text, /make wasm && node cmd\/pdrender-wasm\/conformance.mjs/);
  assert.match(text, /pnpm --filter @barkpark\/core build && pnpm --filter @barkpark\/react exec vitest/);
  assert.match(text, /pnpm --filter @barkpark\/react build && cd apps\/mobile/);
});
