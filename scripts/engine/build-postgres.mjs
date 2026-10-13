#!/usr/bin/env node
// Build a Postgres the engine folder can carry: the official source, checked against
// the published checksum, configured small, with its libraries addressed relative to
// the programs so the folder runs from anywhere on a machine with no Postgres.
// Barkpark's migrations need three standard extensions (citext, pg_trgm, pgcrypto);
// no other contrib module is built.
//
// Usage: node scripts/engine/build-postgres.mjs [--version 15.18] [--out <folder>]
// Then:  node scripts/engine/build-release.mjs --add-postgres <engine folder> <this folder>
//
// macOS: needs the Xcode command line tools and a static OpenSSL 3 (Homebrew's
// openssl@3, or BARKPARK_OPENSSL_PREFIX). OpenSSL is linked statically, so the
// folder needs only system libraries.
// Linux: needs a C toolchain, make, bison, flex, zlib and OpenSSL 3 headers
// (build-essential, bison, flex, zlib1g-dev, libssl-dev on Debian and Ubuntu).
// OpenSSL and zlib are linked dynamically against the system's libssl.so.3,
// libcrypto.so.3 and libz.so.1, the same OpenSSL the release's Erlang crypto uses.
//
// Windows: no build. The folder is cut from EnterpriseDB's binary zip for the same
// version (the build the postgresql.org download page points Windows users at),
// keeping bin/ (programs and the DLLs they load), lib/ and share/. EDB publishes no
// checksum file, so the zip's sha256 is recorded in postgres.json, not verified.
//
// Lifted from Barkdown's scripts/build-runtime-postgres.mjs (ee50133b); the Linux
// and Windows branches are new.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const EXTENSIONS = ['citext', 'pg_trgm', 'pgcrypto'];
function fail(message, code = 2) { console.error(message); process.exit(code); }

const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
if (argv.length % 2 !== 0 || argv.some((a, i) => i % 2 === 0 && !['--version', '--out'].includes(a))) fail('Usage: node scripts/engine/build-postgres.mjs [--version 15.18] [--out <folder>]');
if (!['darwin', 'linux', 'win32'].includes(process.platform)) fail('This script builds Postgres for macOS, Linux and Windows only.');
const version = opt('--version') || '15.18';
if (!/^\d+\.\d+$/.test(version)) fail('The version looks like 15.18.');
const out = path.resolve(opt('--out') || path.join(repo, 'api', '_build', 'engine', `postgres-${version}-${process.platform}-${process.arch}`));
if (fs.existsSync(out) && fs.readdirSync(out).length) fail('The output folder is not empty; nothing was overwritten: ' + out);

const work = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'barkpark-postgres-build-')));
const sh = (command, args, options = {}) => execFileSync(command, args, { stdio: ['ignore', 'inherit', 'inherit'], ...options });

if (process.platform === 'win32') {
  if (process.arch !== 'x64') fail('EnterpriseDB publishes Windows binaries for x64 only.');
  const url = `https://get.enterprisedb.com/postgresql/postgresql-${version}-1-windows-x64-binaries.zip`;
  const zip = path.join(work, 'postgresql.zip');
  sh('curl', ['-fsSL', '--retry', '3', '--max-time', '900', '-o', zip, url]);
  const zipSha256 = crypto.createHash('sha256').update(fs.readFileSync(zip)).digest('hex');
  // Windows 10 and later ship bsdtar as tar.exe, which reads zip archives.
  sh('tar', ['-xf', zip, '-C', work]);
  const pgsql = path.join(work, 'pgsql');
  fs.mkdirSync(out, { recursive: true });
  for (const dir of ['bin', 'lib', 'share']) fs.cpSync(path.join(pgsql, dir), path.join(out, dir), { recursive: true });
  for (const dir of ['share/doc', 'lib/pgxs']) fs.rmSync(path.join(out, dir), { recursive: true, force: true });
  for (const name of fs.readdirSync(path.join(out, 'lib'))) if (/\.(lib|a)$/i.test(name)) fs.rmSync(path.join(out, 'lib', name));
  const missing = [...EXTENSIONS.map(e => `lib/${e}.dll`), ...EXTENSIONS.map(e => `share/extension/${e}.control`), 'bin/postgres.exe', 'bin/initdb.exe', 'bin/pg_ctl.exe'].filter(f => !fs.existsSync(path.join(out, f)));
  if (missing.length) fail(`The EDB zip lacks ${missing.join(', ')}.`, 1);
  fs.copyFileSync(path.join(pgsql, 'server_license.txt'), path.join(out, 'COPYRIGHT'));
  fs.copyFileSync(path.join(pgsql, 'commandlinetools_3rd_party_licenses.txt'), path.join(out, 'THIRD-PARTY-LICENSES.txt'));
  const mark = { version, source: url, zipSha256, extensions: EXTENSIONS, builtAt: new Date().toISOString(), platform: process.platform, arch: process.arch, opensslLinkage: 'bundled DLLs (EDB)' };
  fs.writeFileSync(path.join(out, 'postgres.json'), JSON.stringify(mark, null, 2) + '\n');
  fs.rmSync(work, { recursive: true, force: true });
  console.log(`Cut Postgres ${version} for Windows x64 from ${url} at ${out}`);
  process.exit(0);
}
const base = `https://ftp.postgresql.org/pub/source/v${version}/postgresql-${version}.tar.bz2`;
const tarball = path.join(work, 'postgresql.tar.bz2');
sh('curl', ['-fsSL', '--retry', '3', '--max-time', '600', '-o', tarball, base]);
const published = execFileSync('curl', ['-fsSL', '--retry', '3', '--max-time', '60', base + '.sha256'], { encoding: 'utf8' }).trim().split(/\s+/)[0];
const actual = crypto.createHash('sha256').update(fs.readFileSync(tarball)).digest('hex');
if (!/^[0-9a-f]{64}$/.test(published) || published !== actual) fail(`Checksum mismatch for the Postgres source: published ${published}, downloaded ${actual}`, 1);
sh('tar', ['-xjf', tarball, '-C', work]);
const src = path.join(work, `postgresql-${version}`);
const jobs = String(Math.max(2, os.cpus().length - 1));
const under = dir => fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? under(path.join(dir, entry.name)) : entry.isFile() ? [path.join(dir, entry.name)] : []);
const common = ['--without-icu', '--with-openssl', '--without-zstd', '--without-lz4', '--disable-nls', `--prefix=${out}`];
let opensslVersion, extra = {};

if (process.platform === 'darwin') {
  const openssl = process.env.BARKPARK_OPENSSL_PREFIX || '/opt/homebrew/opt/openssl@3';
  for (const lib of ['lib/libssl.a', 'lib/libcrypto.a', 'include/openssl/ssl.h']) if (!fs.existsSync(path.join(openssl, lib))) fail(`A static OpenSSL 3 is needed at ${openssl} (missing ${lib}); install openssl@3 or set BARKPARK_OPENSSL_PREFIX.`);
  // Only the static archives are visible to the linker, so nothing links the dylibs.
  const staticSsl = path.join(work, 'openssl-static'); fs.mkdirSync(path.join(staticSsl, 'lib'), { recursive: true });
  for (const lib of ['libssl.a', 'libcrypto.a']) fs.copyFileSync(path.join(openssl, 'lib', lib), path.join(staticSsl, 'lib', lib));
  fs.symlinkSync(path.join(openssl, 'include'), path.join(staticSsl, 'include'));
  const deploymentTarget = execFileSync('sw_vers', ['-productVersion'], { encoding: 'utf8' }).trim().split('.')[0] + '.0';
  const env = { ...process.env, PATH: '/usr/bin:/bin:/usr/sbin:/sbin', CFLAGS: '-O2', MACOSX_DEPLOYMENT_TARGET: deploymentTarget };
  sh('./configure', [...common, '--with-libedit-preferred', `--with-includes=${path.join(staticSsl, 'include')}`, `--with-libraries=${path.join(staticSsl, 'lib')}`], { cwd: src, env });
  // libpq checks that it references nothing that exits the process. A statically linked
  // OpenSSL brings atexit and pthread_exit with it; those two are OpenSSL's, not libpq's.
  const makefile = path.join(src, 'src', 'interfaces', 'libpq', 'Makefile'), text = fs.readFileSync(makefile, 'utf8'), guard = 'grep -v __cxa_atexit | grep exit';
  if (!text.includes(guard)) fail('The libpq exit check changed; review the exception before building.', 1);
  fs.writeFileSync(makefile, text.replace(guard, 'grep -v __cxa_atexit | grep -v -w -e _atexit -e _pthread_exit | grep exit'));
  sh('make', ['-j', jobs], { cwd: src, env });
  sh('make', ['install'], { cwd: src, env });
  for (const ext of EXTENSIONS) { sh('make', ['-j', jobs], { cwd: path.join(src, 'contrib', ext), env }); sh('make', ['install'], { cwd: path.join(src, 'contrib', ext), env }); }
  // Address the folder's own libraries relative to each binary, so the folder can move.
  const tool = args => execFileSync('install_name_tool', args, { stdio: ['ignore', 'ignore', 'pipe'] });
  const linked = file => execFileSync('otool', ['-L', file], { encoding: 'utf8' }).split('\n').slice(1).map(line => line.trim().split(' ')[0]).filter(Boolean);
  const libDir = path.join(out, 'lib');
  const modules = under(libDir).filter(file => /\.(dylib|so)$/.test(file));
  for (const file of modules) {
    if (file.endsWith('.dylib')) tool(['-id', '@rpath/' + path.basename(file), file]);
    for (const dep of linked(file)) if (dep.startsWith(libDir + '/')) tool(['-change', dep, '@loader_path/' + path.relative(path.dirname(file), path.join(libDir, path.basename(dep))), file]);
  }
  for (const name of fs.readdirSync(path.join(out, 'bin'))) {
    const file = path.join(out, 'bin', name);
    if (fs.lstatSync(file).isSymbolicLink()) continue;
    for (const dep of linked(file)) if (dep.startsWith(libDir + '/')) tool(['-change', dep, '@loader_path/../lib/' + path.basename(dep), file]);
  }
  // Editing load commands invalidates the signature; Apple silicon refuses unsigned code.
  for (const file of [...modules, ...under(path.join(out, 'bin'))]) execFileSync('codesign', ['--force', '--sign', '-', file], { stdio: 'ignore' });
  opensslVersion = execFileSync(path.join(openssl, 'bin', 'openssl'), ['version'], { encoding: 'utf8' }).trim();
  extra = { deploymentTarget, opensslLinkage: 'static' };
} else {
  const env = { ...process.env, CFLAGS: '-O2' };
  // No readline: psql runs only with -c for the launcher, and readline would be one
  // more system library the folder needs.
  sh('./configure', [...common, '--without-readline'], { cwd: src, env });
  // rpathdir is what Postgres's makefiles place after -Wl,-rpath, inside single quotes,
  // so $ORIGIN reaches the linker unexpanded and each program finds lib/ beside it.
  const rpath = 'rpathdir=$$ORIGIN/../lib';
  sh('make', ['-j', jobs, rpath], { cwd: src, env });
  sh('make', ['install', rpath], { cwd: src, env });
  for (const ext of EXTENSIONS) { sh('make', ['-j', jobs, rpath], { cwd: path.join(src, 'contrib', ext), env }); sh('make', ['install', rpath], { cwd: path.join(src, 'contrib', ext), env }); }
  for (const name of fs.readdirSync(path.join(out, 'bin'))) {
    const file = path.join(out, 'bin', name);
    if (fs.lstatSync(file).isSymbolicLink()) continue;
    const dynamic = execFileSync('readelf', ['-d', file], { encoding: 'utf8' });
    if (/NEEDED.*libpq/.test(dynamic) && !dynamic.includes('$ORIGIN/../lib')) fail(`${name} links libpq without a relative search path:\n${dynamic}`, 1);
  }
  opensslVersion = execFileSync('openssl', ['version'], { encoding: 'utf8' }).trim();
  extra = { opensslLinkage: 'system', glibc: execFileSync('ldd', ['--version'], { encoding: 'utf8' }).split('\n')[0].trim() };
}

fs.copyFileSync(path.join(src, 'COPYRIGHT'), path.join(out, 'COPYRIGHT'));
for (const dir of ['include', 'share/doc', 'share/man', 'lib/pkgconfig', 'lib/pgxs', 'lib/postgresql/pgxs']) fs.rmSync(path.join(out, dir), { recursive: true, force: true });
for (const name of fs.readdirSync(path.join(out, 'lib'))) if (name.endsWith('.a')) fs.rmSync(path.join(out, 'lib', name));

// Refuse a folder that still depends on a library outside the system or the folder.
const foreign = [];
const files = [...under(path.join(out, 'lib')).filter(f => /\.(dylib|so)(\.\d+)*$/.test(f)), ...under(path.join(out, 'bin'))];
const systemLib = process.platform === 'darwin'
  ? dep => dep.startsWith('/usr/lib/') || dep.startsWith('/System/') || dep.startsWith('@')
  : dep => /^(linux-vdso|ld-linux[\w-]*|libc|libm|libdl|libpthread|librt|libz|libssl|libcrypto)\.so/.test(path.basename(dep)) || dep.startsWith(out + '/');
for (const file of files) {
  let deps = [];
  try {
    deps = process.platform === 'darwin'
      ? execFileSync('otool', ['-L', file], { encoding: 'utf8' }).split('\n').slice(1).map(l => l.trim().split(' ')[0]).filter(Boolean)
      : execFileSync('ldd', [file], { encoding: 'utf8' }).split('\n').map(l => l.trim()).filter(l => l && !l.includes('statically linked')).map(l => {
        if (l.includes('not found')) return l.split(' ')[0] + ' (not found)';
        return l.includes('=>') ? l.split('=>')[1].trim().split(' ')[0] : l.split(' ')[0];
      });
  } catch { continue; }
  for (const dep of deps) if (dep && !systemLib(dep)) foreign.push(`${path.relative(out, file)} -> ${dep}`);
}
if (foreign.length) fail('The folder still depends on libraries outside the system:\n' + foreign.join('\n'), 1);

const mark = { version, sourceSha256: actual, openssl: opensslVersion, extensions: EXTENSIONS, builtAt: new Date().toISOString(), platform: process.platform, arch: process.arch, ...extra };
fs.writeFileSync(path.join(out, 'postgres.json'), JSON.stringify(mark, null, 2) + '\n');
fs.rmSync(work, { recursive: true, force: true });
console.log(`Built Postgres ${version} at ${out}`);
