#!/usr/bin/env node
// Pack the two kinds of npm package an app installs to run Barkpark:
//
//   node scripts/engine/pack.mjs platform --engine <engine folder> --out <folder> [--version <v>]
//   node scripts/engine/pack.mjs launcher --out <folder> [--version <v>]
//
// `platform` turns an engine folder into @barkpark/engine-<platform>-<arch>, which
// carries the folder as engine/ and declares its os and cpu, so npm installs only the
// one matching the machine.
//
// `launcher` packs js/packages/engine (build it first) as @barkpark/engine with the
// platform packages as optionalDependencies. They are added here and not in the
// workspace package.json: pnpm cannot lock a dependency the registry does not have
// yet, so listing them there breaks every frozen install until they are published.
//
// Each form writes the package folder and its tarball into --out and prints them as
// JSON. The version defaults to js/packages/engine's, so the pair always matches.
//
// npm packs no symbolic links and no empty folders, so every link in the engine
// folder (Postgres keeps its shared libraries behind version links) is copied as the
// file it points to, and an empty folder gets a .keep file.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const launcherDir = path.join(repo, 'js', 'packages', 'engine');
// Keep in step with PLATFORMS in js/packages/engine/src/release.ts.
export const PLATFORMS = ['darwin-arm64', 'linux-x64', 'linux-arm64'];
const USAGE = 'usage: node scripts/engine/pack.mjs platform --engine <engine folder> --out <folder> [--version <v>]\n       node scripts/engine/pack.mjs launcher --out <folder> [--version <v>]';

function fail(message, code = 2) { console.error(message); process.exit(code); } // pipe-exit-ok: one stderr line before anything is written to stdout

function args(argv) {
  const [form, ...rest] = argv;
  const allowed = form === 'platform' ? ['--engine', '--out', '--version'] : form === 'launcher' ? ['--out', '--version'] : null;
  if (!allowed) fail(USAGE);
  const out = { form };
  for (let i = 0; i < rest.length; i += 2) {
    const key = rest[i], value = rest[i + 1];
    if (!allowed.includes(key) || value === undefined) fail(USAGE);
    out[key.slice(2)] = value;
  }
  if (!out.out || (form === 'platform' && !out.engine)) fail(USAGE);
  return out;
}

export function platformManifest(manifest, version) {
  const target = `${manifest.platform}-${manifest.arch}`;
  return {
    name: `@barkpark/engine-${target}`,
    version,
    description: `The Barkpark engine folder for ${target}: a Barkpark release with its own Erlang and Postgres. Installed by @barkpark/engine; not used directly.`,
    license: 'Apache-2.0',
    repository: { type: 'git', url: 'git+https://github.com/FRIKKern/barkpark.git', directory: 'scripts/engine' },
    os: [manifest.platform],
    cpu: [manifest.arch],
    files: ['engine'],
    barkpark: { commit: manifest.commit },
  };
}

// The workspace manifest minus what only the workspace needs, plus the platform packages.
export function launcherManifest(source, version) {
  const { private: _private, scripts: _scripts, devDependencies: _dev, ...kept } = source;
  return {
    ...kept,
    version,
    optionalDependencies: Object.fromEntries(PLATFORMS.map(target => [`@barkpark/engine-${target}`, version])),
  };
}

// fs.cpSync's dereference follows only the top-level source, not links inside it,
// so copy by hand: stat follows every link, and each file keeps its mode. A link
// that points nowhere fails the pack.
export function copyResolved(from, to) {
  const stat = fs.statSync(from);
  if (stat.isDirectory()) {
    fs.mkdirSync(to, { recursive: true });
    const names = fs.readdirSync(from);
    // npm packs no empty folders either; a marker keeps one the release may expect.
    if (names.length === 0) fs.writeFileSync(path.join(to, '.keep'), '');
    for (const name of names) copyResolved(path.join(from, name), path.join(to, name));
  } else if (stat.isFile()) {
    fs.copyFileSync(from, to);
    fs.chmodSync(to, stat.mode & 0o777);
  } else {
    fail(`${from} is neither a file nor a folder; an engine folder holds only those.`);
  }
}

function npmPack(folder, out) {
  return path.join(out, execFileSync('npm', ['pack', '--silent', '--pack-destination', out], { cwd: folder, encoding: 'utf8' }).trim().split('\n').pop());
}

function packPlatform(opts, version) {
  const engine = path.resolve(opts.engine), out = path.resolve(opts.out);
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(path.join(engine, 'engine.json'), 'utf8'));
  } catch {
    fail(`${engine} has no readable engine.json; build it with scripts/engine/build-release.mjs.`);
  }
  if (!manifest.postgres) fail(`${engine} carries no Postgres. Add one with scripts/engine/build-release.mjs --add-postgres.`);
  const target = `${manifest.platform}-${manifest.arch}`;
  if (!PLATFORMS.includes(target)) fail(`No platform package is defined for ${target}; the platforms are ${PLATFORMS.join(', ')}.`);

  const pkg = path.join(out, `engine-${target}`);
  fs.rmSync(pkg, { recursive: true, force: true });
  fs.mkdirSync(pkg, { recursive: true });
  copyResolved(engine, path.join(pkg, 'engine'));
  fs.writeFileSync(path.join(pkg, 'package.json'), `${JSON.stringify(platformManifest(manifest, version), null, 2)}\n`);
  fs.writeFileSync(path.join(pkg, 'README.md'), `# @barkpark/engine-${target}\n\nThe Barkpark engine folder for ${target}, built from commit ${manifest.commit}. Install \`@barkpark/engine\` instead; it depends on this package and finds the folder itself.\n`);
  fs.copyFileSync(path.join(repo, 'LICENSE'), path.join(pkg, 'LICENSE'));
  return { package: `@barkpark/engine-${target}`, version, folder: pkg, tarball: npmPack(pkg, out) };
}

function packLauncher(opts, version, source) {
  const out = path.resolve(opts.out);
  if (!fs.existsSync(path.join(launcherDir, 'dist', 'index.mjs'))) fail(`${launcherDir}/dist is missing; run pnpm build in js/packages/engine first.`);
  const pkg = path.join(out, 'engine');
  fs.rmSync(pkg, { recursive: true, force: true });
  fs.mkdirSync(pkg, { recursive: true });
  for (const file of source.files) fs.cpSync(path.join(launcherDir, file), path.join(pkg, file), { recursive: true });
  fs.writeFileSync(path.join(pkg, 'package.json'), `${JSON.stringify(launcherManifest(source, version), null, 2)}\n`);
  fs.copyFileSync(path.join(repo, 'LICENSE'), path.join(pkg, 'LICENSE'));
  return { package: '@barkpark/engine', version, folder: pkg, tarball: npmPack(pkg, out) };
}

function main() {
  const opts = args(process.argv.slice(2));
  const source = JSON.parse(fs.readFileSync(path.join(launcherDir, 'package.json'), 'utf8'));
  const version = opts.version ?? source.version;
  fs.mkdirSync(path.resolve(opts.out), { recursive: true });
  const result = opts.form === 'platform' ? packPlatform(opts, version) : packLauncher(opts, version, source);
  console.log(JSON.stringify(result));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
