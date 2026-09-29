#!/usr/bin/env node
// scripts/export-template-repo.test.mjs — the gate over scripts/export-template-repo.mjs
// (dwb-2). Runs the exporter into temp dirs and asserts what a standalone
// template repository must be, OFFLINE:
//
//   * two exports of the same commit are byte-identical (paths, bytes, modes),
//     and a control export that SHOULD differ does — so the comparison can see;
//   * the manifest validates against the schema vendored in the tree, and that
//     vendored schema is byte-identical to templates/barkpark.template.schema.json;
//   * vercel.json exists and agrees with the manifest's framework and the
//     package.json build script, with no root-directory needed;
//   * no relative reference in the tree resolves outside it, no symlinks, no
//     monorepo path spelled out;
//   * no `workspace:` (or other non-registry) dependency specifier remains;
//   * the provenance stamp names the commit exported and its digest recomputes.
//
// WHAT IT CANNOT ASSERT: that the tree installs and builds. That needs the npm
// registry, and it is RED today for a reason outside the exporter — the
// published @barkpark/react and @barkpark/nextjs lack exports the starters
// import (templates/STANDALONE-REPOS.md, "Before the first push").
//
// Wired into the REQUIRED `Cloud gate` by
// cloud/test/barkpark_cloud/templates/standalone_export_test.exs, which pins
// this file's exact pass count.
//
// Run: node scripts/export-template-repo.test.mjs
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const EXPORTER = path.join(ROOT, "scripts", "export-template-repo.mjs");
const EXPECTED = { "blog-starter": "template-blog", "website-starter": "template-website" };
const VERCEL_PRESET = { nextjs: "nextjs", astro: "astro" };
const BUILD_CLI = { nextjs: "next build", astro: "astro build" };

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "export-template-repo-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const HEAD = execFileSync("git", ["-C", ROOT, "rev-parse", "HEAD"]).toString().trim();

function exportTo(dir, args) {
  const r = spawnSync("node", [EXPORTER, ...args, "--out", dir], { encoding: "utf8" });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr };
}

/** Map<rel, {sha, mode, symlink}> for every entry under dir. */
function snapshot(dir) {
  const out = new Map();
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
      const p = path.join(d, e.name);
      const rel = path.relative(dir, p).split(path.sep).join("/");
      if (e.isSymbolicLink()) out.set(rel, { symlink: true });
      else if (e.isDirectory()) walk(p);
      else {
        const st = fs.statSync(p);
        out.set(rel, {
          sha: createHash("sha256").update(fs.readFileSync(p)).digest("hex"),
          mode: st.mode & 0o777,
        });
      }
    }
  };
  walk(dir);
  return out;
}

const A = path.join(TMP, "a");
const B = path.join(TMP, "b");
const runA = exportTo(A, ["--all"]);
const runB = exportTo(B, ["--all"]);

// ── CONTROL 0: the exports ran and produced the population ───────────────────
test("both --all exports exit 0 and write exactly the expected repositories", () => {
  assert.equal(runA.status, 0, `export A failed: ${runA.stderr}`);
  assert.equal(runB.status, 0, `export B failed: ${runB.stderr}`);
  assert.deepEqual(fs.readdirSync(A).sort(), Object.values(EXPECTED).sort());
  for (const repo of Object.values(EXPECTED)) {
    const n = snapshot(path.join(A, repo)).size;
    console.log(`# ${repo}: ${n} files`);
    assert.ok(n >= 20, `${repo} has only ${n} files — the composition went empty`);
  }
});

// ── DETERMINISM ──────────────────────────────────────────────────────────────
test("two exports of the same commit are byte-identical (paths, bytes, modes)", () => {
  const sa = snapshot(A);
  const sb = snapshot(B);
  assert.ok(sa.size > 0);
  assert.deepEqual([...sa.entries()], [...sb.entries()]);
});

test("CONTROL: an export that should differ does — the comparison can see", () => {
  const c = path.join(TMP, "c");
  const r = exportTo(c, ["--template", "blog-starter", "--repo-url", "https://github.com/example-org/template-blog"]);
  assert.equal(r.status, 0, r.stderr);
  const sa = snapshot(path.join(A, "template-blog"));
  const sc = snapshot(c);
  const differing = [...sa.keys()].filter((k) => JSON.stringify(sa.get(k)) !== JSON.stringify(sc.get(k))).sort();
  assert.deepEqual(differing, ["TEMPLATE-SOURCE.json", "barkpark.template.json"]);
  const m = JSON.parse(fs.readFileSync(path.join(c, "barkpark.template.json"), "utf8"));
  assert.equal(m.repo, "https://github.com/example-org/template-blog");
});

// ── REFUSALS ─────────────────────────────────────────────────────────────────
test("the exporter refuses a non-empty output dir, a malformed --repo-url, and --repo-url with --all", () => {
  const r1 = exportTo(A, ["--template", "blog-starter"]);
  assert.notEqual(r1.status, 0);
  assert.match(r1.stderr, /not empty/);
  const r2 = exportTo(path.join(TMP, "d"), ["--template", "blog-starter", "--repo-url", "http://x/y/"]);
  assert.notEqual(r2.status, 0);
  assert.match(r2.stderr, /repo-url/);
  const r3 = exportTo(path.join(TMP, "e"), ["--all", "--repo-url", "https://github.com/o/r"]);
  assert.notEqual(r3.status, 0);
  assert.match(r3.stderr, /one at a time/);
});

// ── A minimal reader for the keywords the manifest schema uses ───────────────
// Unknown keywords are a HARD error, so a widened schema announces that this
// reader can no longer read it instead of validating less.
const KNOWN = new Set([
  "$schema", "$id", "title", "description", "default", "type", "const", "enum", "pattern",
  "minLength", "minItems", "required", "properties", "additionalProperties", "items", "allOf", "if", "then",
]);
const typeOf = (v) => (Array.isArray(v) ? "array" : v === null ? "null" : typeof v);
function validate(schema, value, at, errs = []) {
  for (const k of Object.keys(schema)) if (!KNOWN.has(k)) errs.push(`${at}: unsupported schema keyword "${k}"`);
  if (schema.type && typeOf(value) !== schema.type) {
    errs.push(`${at}: expected ${schema.type}, got ${typeOf(value)}`);
    return errs;
  }
  if ("const" in schema && value !== schema.const) errs.push(`${at}: expected const ${JSON.stringify(schema.const)}`);
  if (schema.enum && !schema.enum.includes(value)) errs.push(`${at}: ${JSON.stringify(value)} not in enum`);
  if (schema.pattern && typeof value === "string" && !new RegExp(schema.pattern).test(value)) errs.push(`${at}: pattern`);
  if (schema.minLength !== undefined && typeof value === "string" && value.length < schema.minLength) errs.push(`${at}: minLength`);
  if (schema.minItems !== undefined && Array.isArray(value) && value.length < schema.minItems) errs.push(`${at}: minItems`);
  if (Array.isArray(value) && schema.items) value.forEach((v, i) => validate(schema.items, v, `${at}[${i}]`, errs));
  if (typeOf(value) === "object") {
    for (const req of schema.required ?? []) if (!(req in value)) errs.push(`${at}: missing "${req}"`);
    const props = schema.properties ?? {};
    for (const [k, v] of Object.entries(value)) {
      if (props[k]) validate(props[k], v, `${at}.${k}`, errs);
      else if (schema.additionalProperties === false && schema.properties) errs.push(`${at}: unknown property "${k}"`);
    }
  }
  for (const sub of schema.allOf ?? []) {
    if (sub.if) {
      if (validate(sub.if, value, at, []).length === 0) validate(sub.then ?? {}, value, at, errs);
    } else validate(sub, value, at, errs);
  }
  return errs;
}

test("CONTROL: the validator reds a manifest that breaks the schema", () => {
  const schema = JSON.parse(fs.readFileSync(path.join(ROOT, "templates", "barkpark.template.schema.json"), "utf8"));
  const errs = validate(schema, { manifestVersion: "1", name: "Bad Name", framework: "rails", extra: 1 }, "m");
  assert.ok(errs.length >= 4, errs.join("\n"));
});

/** Every quoted relative specifier in a text file, as written. */
function relativeRefs(text) {
  const refs = [];
  const re = /["'`](\.{1,2}\/[^"'`\s]*)["'`]/g;
  let m;
  while ((m = re.exec(text))) refs.push(m[1]);
  return refs;
}
const TEXT = /\.(ts|tsx|js|jsx|mjs|cjs|json|css|md|yml|yaml|example)$|^\.gitignore$/;

test("CONTROL: the escape reader sees a reference that leaves the tree", () => {
  const refs = relativeRefs(`import x from '../../../../templates/x'\n"$schema": "../barkpark.template.schema.json"`);
  assert.deepEqual(refs, ["../../../../templates/x", "../barkpark.template.schema.json"]);
});

const schemaSrc = execFileSync("git", ["-C", ROOT, "show", "HEAD:templates/barkpark.template.schema.json"]);

for (const [slug, repo] of Object.entries(EXPECTED)) {
  const dir = path.join(A, repo);
  const read = (rel) => fs.readFileSync(path.join(dir, rel), "utf8");

  test(`${repo}: barkpark.template.json validates against the vendored schema, which is the monorepo's`, () => {
    const manifest = JSON.parse(read("barkpark.template.json"));
    assert.equal(manifest.$schema, "./barkpark.template.schema.json");
    const vendored = fs.readFileSync(path.join(dir, "barkpark.template.schema.json"));
    assert.ok(vendored.equals(schemaSrc), "vendored schema drifted from templates/barkpark.template.schema.json");
    const errs = validate(JSON.parse(vendored.toString("utf8")), manifest, repo);
    assert.deepEqual(errs, []);
    assert.equal(manifest.name, slug, "the manifest name stays the catalog slug");
    assert.equal(manifest.repo, undefined, "an export without --repo-url must not invent a repo");
    for (const p of [...manifest.schemas, ...(manifest.seed ? [manifest.seed.path] : [])]) {
      assert.ok(fs.statSync(path.join(dir, p)).isFile(), `${p} named by the manifest is missing`);
    }
  });

  test(`${repo}: vercel.json agrees with the manifest framework and the package.json build script`, () => {
    const manifest = JSON.parse(read("barkpark.template.json"));
    const vercel = JSON.parse(read("vercel.json"));
    const pkg = JSON.parse(read("package.json"));
    assert.equal(vercel.framework, VERCEL_PRESET[manifest.framework]);
    assert.equal(vercel.buildCommand, "npm run build");
    assert.equal(vercel.installCommand, "npm install");
    assert.equal(pkg.scripts.build, BUILD_CLI[manifest.framework]);
    assert.equal(pkg.name, repo);
    for (const k of ["rootDirectory", "root", "outputDirectory"]) {
      assert.equal(vercel[k], undefined, `vercel.json must not carry ${k}: the repo root IS the app`);
    }
  });

  test(`${repo}: no dependency specifier is workspace:, file:, link:, or a git/url source`, () => {
    const pkg = JSON.parse(read("package.json"));
    const bad = [];
    for (const f of ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"]) {
      for (const [n, s] of Object.entries(pkg[f] ?? {})) {
        if (/^(workspace:|file:|link:|portal:|git\+|git:|github:|https?:)/.test(s)) bad.push(`${f}.${n}=${s}`);
      }
    }
    assert.ok(Object.keys(pkg.dependencies ?? {}).length > 0, "no dependencies read — vacuous");
    assert.deepEqual(bad, []);
    assert.equal(/"workspace:/.test(read("package.json")), false);
  });

  test(`${repo}: nothing resolves outside the tree, no symlinks, no monorepo paths`, () => {
    const snap = snapshot(dir);
    const escapes = [];
    let scanned = 0;
    for (const [rel, info] of snap) {
      assert.ok(!info.symlink, `${rel} is a symlink`);
      if (!TEXT.test(path.posix.basename(rel))) continue;
      const text = read(rel);
      scanned++;
      for (const ref of relativeRefs(text)) {
        const target = path.posix.normalize(path.posix.join(path.posix.dirname(rel), ref));
        if (target === ".." || target.startsWith("../")) escapes.push(`${rel}: ${ref}`);
      }
      // The provenance stamp names its source paths ON PURPOSE (it is a record,
      // not a reference); every other file must not know the monorepo exists.
      const needles = rel === "TEMPLATE-SOURCE.json" ? [ROOT] : ["js/packages/", "create-barkpark-app/templates", ROOT];
      for (const needle of needles) {
        if (text.includes(needle)) escapes.push(`${rel}: spells out ${needle}`);
      }
      if (/\{\{\s*(projectName|packageName|pmCommand)\s*\}\}/.test(text)) escapes.push(`${rel}: unrendered placeholder`);
    }
    for (const rel of snap.keys()) {
      if (rel.endsWith(".tmpl") || path.posix.basename(rel) === "_gitignore") escapes.push(`${rel}: uncomposed source name`);
    }
    assert.ok(scanned >= 20, `only ${scanned} text files scanned — vacuous`);
    assert.deepEqual(escapes, []);
    assert.ok(snap.has(".gitignore") && snap.has("LICENSE"));
  });

  test(`${repo}: TEMPLATE-SOURCE.json names the exported commit and its digest recomputes`, () => {
    const stamp = JSON.parse(read("TEMPLATE-SOURCE.json"));
    assert.equal(stamp.source_commit, HEAD);
    assert.equal(stamp.template, slug);
    assert.equal(stamp.repository, repo);
    const snap = snapshot(dir);
    snap.delete("TEMPLATE-SOURCE.json");
    const h = createHash("sha256");
    for (const rel of [...snap.keys()].sort()) {
      const { sha, mode } = snap.get(rel);
      h.update(`${mode === 0o755 ? "100755" : "100644"} ${rel}\0${sha}\n`);
    }
    assert.equal(stamp.tree_digest, `sha256:${h.digest("hex")}`);
    assert.equal(stamp.files, snap.size);
  });
}
