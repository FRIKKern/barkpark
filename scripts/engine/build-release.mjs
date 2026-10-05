#!/usr/bin/env node
// Build the Barkpark engine folder for this machine: the api/ production release
// with its own Erlang, stamped with the commit it holds. @barkpark/engine runs the
// folder with nothing else installed once a Postgres is added to it.
//
// Usage:
//   node scripts/engine/build-release.mjs [--out <folder>]
//   node scripts/engine/build-release.mjs --add-postgres <engine folder> <postgres folder>
//
// The first form builds the release from the current checkout. It refuses a dirty
// tree, because the folder is stamped with one commit. The second form copies a
// Postgres built by scripts/engine/build-postgres.mjs into the folder as postgres/,
// keeps only the programs the launcher runs, and records it in engine.json.
//
// Layout of an engine folder:
//   engine.json          manifest: commit, platform, arch, Erlang, Elixir, Postgres
//   bin/barkpark         the release launcher (bin/migrate beside it)
//   erts-<version>/      the Erlang runtime the release carries
//   lib/ releases/       compiled applications and boot files
//   postgres/            bin/ lib/ share/ of the bundled Postgres
//
// Lifted from Barkdown's scripts/build-runtime-release.mjs (ee50133b).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const api = path.join(repo, 'api');
export const MANIFEST = 'engine.json';
// What @barkpark/engine runs: initdb and pg_ctl to own the cluster, postgres under
// pg_ctl, psql and createdb to create the database. Nothing else ships.
export const PROGRAMS = ['initdb', 'pg_ctl', 'postgres', 'psql', 'createdb'];

function fail(message, code = 2) { console.error(message); process.exit(code); }

function addPostgres(engineArg, postgresArg) {
  const engine = engineArg && path.resolve(engineArg), postgres = postgresArg && path.resolve(postgresArg);
  const manifestFile = engine && path.join(engine, MANIFEST), pgMark = postgres && path.join(postgres, 'postgres.json');
  if (!engine || !postgres || !fs.existsSync(manifestFile) || !fs.existsSync(pgMark)) {
    fail('Usage: --add-postgres <engine folder built by this script> <postgres folder built by build-postgres.mjs>');
  }
  const target = path.join(engine, 'postgres');
  if (fs.existsSync(target)) fail('This engine folder already carries a Postgres; nothing was overwritten.');
  fs.cpSync(postgres, target, { recursive: true, verbatimSymlinks: true });
  const dropped = fs.readdirSync(path.join(target, 'bin')).filter(name => !PROGRAMS.includes(name));
  for (const name of dropped) fs.rmSync(path.join(target, 'bin', name), { force: true });
  fs.rmSync(path.join(target, 'postgres.json'));
  const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
  manifest.postgres = { ...JSON.parse(fs.readFileSync(pgMark, 'utf8')), programs: PROGRAMS };
  fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + '\n');
  console.log(`Added Postgres ${manifest.postgres.version} to ${engine} (kept: ${PROGRAMS.join(', ')})`);
}

const filesUnder = dir => fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
  const file = path.join(dir, entry.name);
  return entry.isDirectory() ? filesUnder(file) : entry.isFile() ? [file] : [];
});

// The native code in the release (ERTS, NIFs) must not reach into the build machine.
// macOS: Erlang's crypto NIF links the OpenSSL it was built against, which on a
// Homebrew Erlang is /opt/homebrew/opt/openssl@3. That library is copied beside the
// NIF and addressed relative to it, so the release runs on a Mac without Homebrew.
// Any other library outside the system fails the build.
// Linux: shared libraries come from the system (glibc, and OpenSSL 3 for crypto);
// the list is recorded in engine.json and anything not found fails the build.
// Returns the system libraries the release needs beyond the C library.
export function selfContain(out) {
  const binaries = filesUnder(out).filter(file => {
    const head = Buffer.alloc(4), fd = fs.openSync(file, 'r');
    try { fs.readSync(fd, head, 0, 4, 0); } finally { fs.closeSync(fd); }
    const magic = head.readUInt32BE(0);
    return process.platform === 'darwin' ? [0xcffaedfe, 0xfeedfacf, 0xcafebabe].includes(magic) : magic === 0x7f454c46;
  });
  const needed = new Set();
  if (process.platform === 'darwin') {
    const allowed = new Set(['libcrypto.3.dylib', 'libssl.3.dylib']);
    const deps = file => {
      const id = (() => { try { return execFileSync('otool', ['-D', file], { encoding: 'utf8' }).split('\n')[1]?.trim(); } catch { return undefined; } })();
      return execFileSync('otool', ['-L', file], { encoding: 'utf8' }).split('\n').slice(1).map(line => line.trim().split(' ')[0]).filter(dep => dep && dep !== id);
    };
    const foreign = [];
    for (const file of binaries) {
      for (const dep of deps(file)) {
        if (dep.startsWith('/usr/lib/') || dep.startsWith('/System/') || dep.startsWith('@')) continue;
        const name = path.basename(dep);
        if (!allowed.has(name)) { foreign.push(`${path.relative(out, file)} -> ${dep}`); continue; }
        const copy = path.join(path.dirname(file), name);
        if (!fs.existsSync(copy)) {
          fs.copyFileSync(fs.realpathSync(dep), copy);
          fs.chmodSync(copy, 0o755);
          execFileSync('install_name_tool', ['-id', '@loader_path/' + name, copy], { stdio: 'pipe' });
          for (const inner of deps(copy)) if (!(inner.startsWith('/usr/lib/') || inner.startsWith('/System/') || inner.startsWith('@'))) foreign.push(`${path.relative(out, copy)} -> ${inner}`);
          execFileSync('codesign', ['--force', '--sign', '-', copy], { stdio: 'ignore' });
        }
        execFileSync('install_name_tool', ['-change', dep, '@loader_path/' + name, file], { stdio: 'pipe' });
        execFileSync('codesign', ['--force', '--sign', '-', file], { stdio: 'ignore' });
        needed.add(`${name} (bundled from ${dep})`);
      }
    }
    if (foreign.length) fail('The release depends on libraries outside the system and the release:\n' + foreign.join('\n'), 1);
  } else {
    const missing = [];
    for (const file of binaries) {
      let text = '';
      try { text = execFileSync('ldd', [file], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }); } catch { continue; }
      for (const line of text.split('\n').map(l => l.trim()).filter(l => l && !l.includes('statically linked'))) {
        const name = line.split(' ')[0];
        if (line.includes('not found')) missing.push(`${path.relative(out, file)} -> ${name}`);
        else if (!/^(linux-vdso|\/lib|ld-linux|libc\.|libm\.|libdl\.|libpthread\.|librt\.)/.test(name) && !line.includes(out)) needed.add(name);
      }
    }
    if (missing.length) fail('The release needs libraries this machine does not have:\n' + missing.join('\n'), 1);
  }
  return [...needed].sort();
}

function buildRelease(outArg) {
  if (process.platform === 'win32') fail('The engine release is built on macOS and Linux only for now.');
  const git = args => execFileSync('git', args, { cwd: repo, encoding: 'utf8' }).trim();
  const commit = git(['rev-parse', 'HEAD']);
  if (git(['status', '--porcelain', '--untracked-files=no'])) fail('The checkout has uncommitted changes. An engine folder is stamped with one commit; commit or stash first.');
  const out = path.resolve(outArg || path.join(api, '_build', 'engine', `barkpark-${commit.slice(0, 9)}-${process.platform}-${process.arch}`));
  if (fs.existsSync(out) && fs.readdirSync(out).length) fail('The output folder is not empty; nothing was overwritten: ' + out);
  // A build path of its own keeps this away from _build/prod, which is the live
  // release on a prod box. --force recompiles the barkpark app so the commit that
  // Barkpark.BuildInfo reads at compile time is this one; deps stay cached.
  const env = {
    ...process.env, MIX_ENV: 'prod', MIX_BUILD_PATH: path.join(api, '_build', 'engine-prod'),
    BARKPARK_BUILD_COMMIT: commit.slice(0, 9), BARKPARK_BUILD_DATE: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
    CMAKE_POLICY_VERSION_MINIMUM: process.env.CMAKE_POLICY_VERSION_MINIMUM || '3.5',
  };
  const mix = args => execFileSync('mix', args, { cwd: api, env, stdio: ['ignore', 'inherit', 'inherit'] });
  mix(['deps.get', '--only', 'prod']);
  mix(['compile', '--force']);
  mix(['release', 'barkpark', '--overwrite', '--path', out]);
  const erts = fs.readdirSync(out).find(name => name.startsWith('erts-')) || null;
  if (!erts) fail('The release has no erts- folder; check include_erts in api/mix.exs.', 1);
  const sharedLibraries = selfContain(out);
  const otp = execFileSync('erl', ['-noshell', '-eval', 'io:put_chars(erlang:system_info(otp_release)), halt().'], { encoding: 'utf8' }).trim();
  const elixir = execFileSync('elixir', ['-e', 'IO.write(System.version())'], { encoding: 'utf8' }).trim();
  const manifest = {
    version: 1, commit, builtAt: new Date().toISOString(), platform: process.platform, arch: process.arch,
    osRelease: os.release(), erts: erts.slice('erts-'.length), otp, elixir, sharedLibraries, postgres: null,
  };
  fs.writeFileSync(path.join(out, MANIFEST), JSON.stringify(manifest, null, 2) + '\n');
  console.log(`Built Barkpark ${commit.slice(0, 9)} (OTP ${otp}, ${erts}) at ${out}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2);
  if (argv[0] === '--add-postgres') addPostgres(argv[1], argv[2]);
  else if (argv.length === 0 || (argv[0] === '--out' && argv[1] && argv.length === 2)) buildRelease(argv[1]);
  else fail('Usage: node scripts/engine/build-release.mjs [--out <folder>]\n       node scripts/engine/build-release.mjs --add-postgres <engine folder> <postgres folder>');
}
