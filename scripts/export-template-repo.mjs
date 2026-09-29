#!/usr/bin/env node
// scripts/export-template-repo.mjs — turn a monorepo starter into the tree of a
// STANDALONE template repository (dwb-2: template-blog, template-website).
//
// WHY. The deploy flow's git-clone path (Vercel "clone", the deploy worker)
// needs a repository whose ROOT is the app. The starters live in this monorepo
// in pieces, so a clone of the monorepo root cannot deploy them
// (task-32e385b29e75c102). This script composes the pieces into one
// self-contained tree; templates/STANDALONE-REPOS.md is the runbook that
// publishes it.
//
// WHAT A TREE IS MADE OF, per template:
//   1. js/packages/create-barkpark-app/templates/_shared/   laid down first
//   2. js/packages/create-barkpark-app/templates/<slug>/    over it (starter wins)
//      — the same composition scaffold.ts and scripts/sync-starter-templates.mjs
//      use, with `.tmpl` files rendered and `_gitignore` renamed `.gitignore`.
//   3. templates/<slug>/ (barkpark.template.json + its JSON schema + mutations
//      seed) — the SERVER-bootstrappable manifest the Go provisioner catalog
//      embeds. It REPLACES the create-barkpark-app manifest, whose script seed
//      cannot run server-side (templates/MANIFEST.md). Its `$schema` is
//      rewritten to a vendored copy of templates/barkpark.template.schema.json,
//      so nothing in the tree points outside it.
//   4. vercel.json, derived from the manifest's framework and the package.json
//      build script, so a Vercel clone builds with no root-directory setting.
//   5. TEMPLATE-SOURCE.json, the provenance stamp: the monorepo commit the tree
//      came from and a digest of every other file in it.
//   6. LICENSE from the monorepo root.
//
// READS COMMITTED STATE, NEVER THE WORKING TREE. Every source file is read with
// `git cat-file` at --rev (default HEAD), so the stamped commit is the commit
// the bytes came from — an uncommitted edit cannot ride into a tree stamped
// with a sha that does not contain it.
//
// DETERMINISTIC. Same --rev in, byte-identical tree out: no timestamps, sorted
// iteration, fixed JSON formatting. The output dir must be absent or empty.
//
// DEPENDENCIES ARE NOT REWRITTEN. The starters' package.json already names
// published registry ranges. Any `workspace:`, `file:`, `link:`, `portal:` or
// git specifier is REFUSED rather than guessed at, because the export runs
// offline and cannot know which published version to pin.
//
// NO LOCKFILE. Producing one needs the registry (network) and is not
// byte-reproducible, so the exported tree ships none; the Vercel install
// resolves the ranges at build time. templates/STANDALONE-REPOS.md states what
// that means for pinning.
//
// Usage:
//   node scripts/export-template-repo.mjs --template blog-starter --out <dir>
//        [--rev <git-rev>] [--repo-url https://github.com/<org>/template-blog]
//   node scripts/export-template-repo.mjs --all --out <dir> [--rev …]
//        (writes <dir>/template-blog and <dir>/template-website; --repo-url is
//         refused with --all because each repo has its own URL)
//
// Node built-ins + git only.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** starter slug -> standalone repository name. The two dwb-2 publishes. */
export const TEMPLATES = {
  "blog-starter": "template-blog",
  "website-starter": "template-website",
};

const CBA_TEMPLATES = "js/packages/create-barkpark-app/templates";
const SHARED = "_shared"; // mirrors SHARED_TEMPLATE_DIR in create-barkpark-app/src/constants.ts
const SCHEMA_SRC = "templates/barkpark.template.schema.json";
const SCHEMA_DEST = "barkpark.template.schema.json";
const STAMP = "TEMPLATE-SOURCE.json";
const SOURCE_REPO = "https://github.com/FRIKKern/barkpark";

/** framework -> the Vercel framework preset. A framework absent here is refused. */
const VERCEL_FRAMEWORK = { nextjs: "nextjs", astro: "astro" };

const BAD_SPECIFIER = /^(workspace:|file:|link:|portal:|git\+|git:|github:|https?:)/;

function die(msg) {
  process.stderr.write(`export-template-repo: ${msg}\n`);
  process.exit(1);
}

function git(args, opts = {}) {
  return execFileSync("git", ["-C", REPO_ROOT, ...args], {
    maxBuffer: 64 * 1024 * 1024,
    ...opts,
  });
}

/** [{mode, path, rel}] for every blob under `prefix` at `sha`, sorted by path. */
function lsTree(sha, prefix) {
  const out = git(["ls-tree", "-r", "-z", "--full-tree", sha, "--", prefix]).toString("utf8");
  const rows = [];
  for (const rec of out.split("\0")) {
    if (!rec) continue;
    const tab = rec.indexOf("\t");
    const [mode, type] = rec.slice(0, tab).split(" ");
    const p = rec.slice(tab + 1);
    if (type !== "blob") die(`${p}: unsupported git object type ${type}`);
    if (mode === "120000") die(`${p}: symlinks are refused (a link can point outside the tree)`);
    rows.push({ mode, path: p, rel: p.slice(prefix.length + 1) });
  }
  return rows.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

function blob(sha, p) {
  return git(["cat-file", "blob", `${sha}:${p}`]);
}

function renderTemplate(input, vars) {
  // Same substitution as create-barkpark-app's renderTemplate(): unknown keys stay.
  return input.replace(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g, (m, key) =>
    Object.prototype.hasOwnProperty.call(vars, key) ? vars[key] : m,
  );
}

function isTextFile(name) {
  // Same predicate as create-barkpark-app's isTextFile().
  return /\.(ts|tsx|js|jsx|mjs|cjs|json|md|mdx|yml|yaml|env|example|gitignore|npmrc|css|html|txt)$/i.test(
    name,
  );
}

function destName(rel) {
  const dir = path.posix.dirname(rel);
  let base = path.posix.basename(rel);
  if (base === "_gitignore") base = ".gitignore";
  else if (base === "_npmrc") base = ".npmrc";
  const tmpl = base.endsWith(".tmpl");
  if (tmpl) base = base.slice(0, -".tmpl".length);
  return { rel: dir === "." ? base : `${dir}/${base}`, tmpl };
}

const json = (v) => JSON.stringify(v, null, 2) + "\n";

/**
 * Compose one standalone tree in memory. Returns Map<rel, {bytes, mode}>.
 * Pure over (sha, slug, repoUrl): the determinism the gate asserts.
 */
export function composeTree({ sha, slug, repoUrl }) {
  const repoName = TEMPLATES[slug];
  if (!repoName) die(`unknown template ${slug} (known: ${Object.keys(TEMPLATES).join(", ")})`);

  const vars = {
    projectName: repoName,
    packageName: repoName,
    // pnpm, because every README line (`<pm> install`, `<pm> seed`) is a valid
    // pnpm command; `npm run install` is not. The Vercel build does not read it.
    pmCommand: "pnpm",
  };

  const files = new Map();
  const put = (rel, bytes, mode = "100644") => files.set(rel, { bytes: Buffer.from(bytes), mode });

  // 1 + 2: _shared, then the starter over it.
  for (const root of [`${CBA_TEMPLATES}/${SHARED}`, `${CBA_TEMPLATES}/${slug}`]) {
    const rows = lsTree(sha, root);
    if (rows.length === 0) die(`${root} is empty or absent at ${sha}`);
    for (const row of rows) {
      const base = path.posix.basename(row.rel);
      if (base === ".gitkeep") continue;
      const d = destName(row.rel);
      let bytes = blob(sha, row.path);
      if (d.tmpl || isTextFile(base)) bytes = Buffer.from(renderTemplate(bytes.toString("utf8"), vars));
      put(d.rel, bytes, row.mode);
    }
  }

  // 3: the server-bootstrappable manifest + what it references.
  const serverRoot = `templates/${slug}`;
  const serverRows = lsTree(sha, serverRoot);
  if (serverRows.length === 0) die(`${serverRoot} is empty or absent at ${sha}`);
  for (const row of serverRows) {
    if (files.has(row.rel) && row.rel !== "barkpark.template.json") {
      die(`${serverRoot}/${row.rel} collides with a create-barkpark-app file of the same path`);
    }
    put(row.rel, blob(sha, row.path), row.mode);
  }
  const manifest = JSON.parse(files.get("barkpark.template.json").bytes.toString("utf8"));
  manifest.$schema = `./${SCHEMA_DEST}`;
  if (repoUrl) manifest.repo = repoUrl;
  put("barkpark.template.json", json(manifest));
  put(SCHEMA_DEST, blob(sha, SCHEMA_SRC));

  // Dependencies: registry specifiers only.
  const pkg = JSON.parse(files.get("package.json").bytes.toString("utf8"));
  for (const field of ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"]) {
    for (const [name, spec] of Object.entries(pkg[field] || {})) {
      if (BAD_SPECIFIER.test(String(spec))) {
        die(`package.json ${field}.${name} = "${spec}" is not a published registry range; pin it at the source`);
      }
    }
  }
  if (pkg.name !== repoName) die(`package.json name "${pkg.name}" did not render to "${repoName}"`);

  // 4: vercel.json from the manifest + package.json, never hand-kept.
  const preset = VERCEL_FRAMEWORK[manifest.framework];
  if (!preset) die(`framework "${manifest.framework}" has no Vercel preset here; add one deliberately`);
  if (!pkg.scripts || !pkg.scripts.build) die("package.json has no build script");
  put(
    "vercel.json",
    json({
      $schema: "https://openapi.vercel.sh/vercel.json",
      framework: preset,
      installCommand: "npm install",
      buildCommand: "npm run build",
    }),
  );

  // 6: LICENSE.
  put("LICENSE", blob(sha, "LICENSE"));

  // 5: the stamp, last, over everything else.
  const rels = [...files.keys()].sort();
  const h = createHash("sha256");
  for (const rel of rels) {
    const { bytes, mode } = files.get(rel);
    h.update(`${mode} ${rel}\0${createHash("sha256").update(bytes).digest("hex")}\n`);
  }
  put(
    STAMP,
    json({
      _readme:
        "Provenance stamp written by scripts/export-template-repo.mjs in the Barkpark monorepo. " +
        "Do not edit this tree by hand: change the monorepo, re-export from a commit, diff, push. " +
        "See templates/STANDALONE-REPOS.md in the source repo.",
      template: slug,
      repository: repoName,
      repository_url: repoUrl || null,
      source_repo: SOURCE_REPO,
      source_commit: sha,
      source_paths: [`${CBA_TEMPLATES}/${SHARED}`, `${CBA_TEMPLATES}/${slug}`, serverRoot, SCHEMA_SRC, "LICENSE"],
      tree_digest: `sha256:${h.digest("hex")}`,
      files: rels.length,
    }),
  );
  return files;
}

function writeTree(files, outDir) {
  if (fs.existsSync(outDir) && fs.readdirSync(outDir).length > 0) {
    die(`${outDir} is not empty; the export writes into an empty directory only`);
  }
  const root = path.resolve(outDir);
  for (const rel of [...files.keys()].sort()) {
    const dest = path.resolve(root, rel);
    if (dest !== root && !dest.startsWith(root + path.sep)) die(`${rel} escapes the output tree`);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const { bytes, mode } = files.get(rel);
    fs.writeFileSync(dest, bytes);
    fs.chmodSync(dest, mode === "100755" ? 0o755 : 0o644);
  }
}

function parseArgs(argv) {
  const a = { rev: "HEAD" };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const val = () => {
      const v = argv[++i];
      if (v === undefined || v.startsWith("--")) die(`${k} needs a value`);
      return v;
    };
    if (k === "--template") a.template = val();
    else if (k === "--out") a.out = val();
    else if (k === "--rev") a.rev = val();
    else if (k === "--repo-url") a.repoUrl = val();
    else if (k === "--all") a.all = true;
    else if (k === "-h" || k === "--help") {
      process.stdout.write(
        "usage: node scripts/export-template-repo.mjs (--template <slug> | --all) --out <dir> [--rev <git-rev>] [--repo-url <url>]\n",
      );
      process.exit(0);
    } else die(`unknown argument ${k}`);
  }
  if (!a.out) die("--out <dir> is required");
  if (!a.all === !a.template) die("pass exactly one of --template <slug> or --all");
  if (a.all && a.repoUrl) die("--repo-url names ONE repository; export templates one at a time to stamp it");
  if (a.repoUrl && !/^https:\/\/[a-zA-Z0-9._~-]+(\/[a-zA-Z0-9._~-]+)+$/.test(a.repoUrl)) {
    die(`--repo-url ${a.repoUrl} is not an https repository URL without a trailing slash`);
  }
  return a;
}

function main() {
  const a = parseArgs(process.argv.slice(2));
  let sha;
  try {
    sha = git(["rev-parse", "--verify", `${a.rev}^{commit}`], { stdio: ["ignore", "pipe", "ignore"] })
      .toString()
      .trim();
  } catch {
    die(`--rev ${a.rev} does not name a commit`);
  }
  if (a.all) {
    for (const [slug, repoName] of Object.entries(TEMPLATES)) {
      const dir = path.join(a.out, repoName);
      writeTree(composeTree({ sha, slug }), dir);
      process.stdout.write(`exported ${slug} @ ${sha} -> ${dir}\n`);
    }
  } else {
    writeTree(composeTree({ sha, slug: a.template, repoUrl: a.repoUrl }), a.out);
    process.stdout.write(`exported ${a.template} @ ${sha} -> ${a.out}\n`);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
