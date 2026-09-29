// shoot-guards.mjs — the regression harness for shoot.sh's four guards.
//
//   node cloud/priv/static/__preview__/shoot-guards.mjs
//   node cloud/priv/static/__preview__/shoot-guards.mjs --only scen-validation
//   node cloud/priv/static/__preview__/shoot-guards.mjs --green-only
//
// WHY THIS FILE EXISTS
// ────────────────────
// shoot.sh grew four guards, each one filed after a measured false green:
//
//   · the REAP WATCHDOG — bash `wait` has no timeout, and a Chrome that ignores
//     TERM parked the harness in __wait4 four separate times (~28min, 7h18m,
//     7h46m, 10h30m+). The bound has to come from OUTSIDE the wait.
//   · PER-SHOT SERVER LIVENESS — when node died mid-run every remaining shot
//     captured Chrome's ERR_CONNECTION_REFUSED page: non-empty bytes, so the
//     old size-only gate printed `ok` for each and shipped a full-count matrix
//     of wrong images.
//   · $OUT MUST BE OURS — two runs sharing one $OUT interleave silently
//     (measured: 49 files against 44 `ok` lines). A concurrent writer is now
//     refused by a lock, and a merely pre-populated $OUT is disclosed.
//   · SCEN VALIDATION — an unknown SCEN name matched nothing, was silently
//     dropped, and the run still printed ">> Done" over a short matrix.
//
// And one SEAM that is not a refusal (modal-by-field, gr-backlog-scenario-
// drive-field): the `&modal=` query comes from the scenario's declared `modal`
// field. It used to come from an `account-modal*` NAME, so a renamed scenario
// shot the bare shell. Its mutant restores that deleted line verbatim.
//
// Every one of those four was proven to fire BY HAND, once, and the proof lived
// only in a task ledger and a commit message. shoot.sh itself says, at its
// accent tripwire, that having no automated coverage "is exactly how the
// original bug survived long enough to void every accent proof this epic ever
// cited". A guard nobody re-fires is on that same trajectory: the merge gate
// only ever runs the HAPPY path, so a refactor can silence any of the four and
// every gate stays green. This file re-fires them.
//
// THE SHAPE OF A CHECK HERE
// ─────────────────────────
// Each check runs the REAL shoot.sh — byte-for-byte the shipped file — from a
// throwaway sandbox, drives it into one failure shape with a fixture, and
// asserts BOTH halves: a non-zero exit AND the guard's own naming message. A
// non-zero exit alone proves nothing (there are a dozen ways to exit 1); the
// message is what says WHICH guard spoke.
//
// And every check is then run a SECOND time against a copy of shoot.sh with
// its guard CUT OUT, where it must go RED. That is the half that makes this
// file worth its runtime: a check that stays green when its subject is deleted
// has not been built. The cut goes through `replaceUnique` from
// anchored-replace.mjs, which REFUSES unless the anchor resolves exactly once,
// so "the mutation applied" is proven rather than assumed — and the cut text is
// then grepped for the guard's message to prove, independently, that it is gone.
//
// THREE OF THE FOUR NEED NO BROWSER. The fixtures are a fake Chrome (a ~20-line
// bash script that either writes a stub PNG or ignores TERM and hangs) and a
// scoped kill of the run's own preview server. Only pixel fidelity needs real
// Chrome, and that is what `make cloud-shots` is for — this file is about
// shoot.sh's CONTROL FLOW, which is where all four defects lived.
//
// KILL SCOPING — READ BEFORE ADDING A CHECK
// ─────────────────────────────────────────
// Many sessions share this host and several run their own serve.mjs, Chrome and
// node right now. There is NO pattern kill anywhere in this file: no pkill, no
// killall, no `-f` match. Everything this harness signals is either a pid it
// spawned itself (held in a variable from the moment of spawn) or a pid it
// proved is a DESCENDANT of one it spawned, by walking a ppid snapshot down
// from its own child. `descendantsOf` is the only way a pid enters a kill here,
// and it starts from `child.pid`. If you cannot scope a kill that way, do not
// write the check.
//
// RUNTIME: ~3.5 minutes for the full run. The watchdog arm is the expensive one
// — shoot.sh's PNG-settle poll has a hard 15s cap per shot and the fixture
// never writes a PNG, so its green arm pays 4 x ~17s and its mutant arm pays
// the whole budget by hanging, which is precisely the wedge being proven. Use
// `--only <id>` while iterating.

import { spawn } from 'node:child_process';
import { execFileSync } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { replaceUnique } from './anchored-replace.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const STATIC = path.resolve(HERE, '..');
const SHOOT = path.join(HERE, 'shoot.sh');
const SHOOT_SRC = fs.readFileSync(SHOOT, 'utf8');

// ── the cut ──────────────────────────────────────────────────────────────────
// A guard is removed by span, not by line number: an anchor that resolves twice
// is a coin flip decided by file order, and an anchor that resolves zero times
// is an unapplied mutation reporting green. `replaceUnique` refuses both, so a
// drifted anchor here fails LOUDLY and names itself instead of quietly turning
// this whole file into a memory of shoot.sh rather than a measurement of it.
const countOf = (haystack, needle) => {
  let n = 0;
  for (let at = haystack.indexOf(needle); at !== -1; at = haystack.indexOf(needle, at + 1)) n++;
  return n;
};

const cutBlock = (text, startAnchor, endAnchor, replacement, what) => {
  const starts = countOf(text, startAnchor);
  if (starts !== 1) {
    throw new Error(`${what}: the START anchor resolves ${starts} times in shoot.sh, not once: ${JSON.stringify(startAnchor)}`);
  }
  const from = text.indexOf(startAnchor);
  const endAt = text.indexOf(endAnchor, from + startAnchor.length);
  if (endAt === -1) {
    throw new Error(`${what}: the END anchor never appears after the start anchor: ${JSON.stringify(endAnchor)}`);
  }
  const span = text.slice(from, endAt + endAnchor.length);
  return replaceUnique(text, span, replacement, { what });
};

// ── the sandbox ──────────────────────────────────────────────────────────────
// shoot.sh reads four things relative to itself: scenarios.mjs and serve.mjs
// beside it, and ../app.css and ../app.js for the stale-server canary. So the
// sandbox is a symlink farm around ONE real file: the shoot.sh copy under test.
// Node resolves a symlinked module to its real path, so serve.mjs still roots
// itself at the real cloud/priv/static and the canary `cmp` compares the shipped
// bytes with themselves — the sandbox changes shoot.sh, and nothing else.
const FAKE_CHROME = `#!/usr/bin/env bash
# fake Chrome. Two shapes, both of which a real headless Chrome has produced on
# this host: write the PNG and exit, or wedge and ignore TERM.
png=""
for a in "$@"; do
  case "$a" in --screenshot=*) png="\${a#--screenshot=}" ;; esac
done
case "\${FAKE_MODE:-write}" in
  write)
    # The URL is recorded INTO the stub PNG (it is always the last argument),
    # so a check can read back exactly what shoot.sh asked Chrome to load.
    printf 'fake-png-bytes-for-the-shoot-guards-harness-%s\\nurl=%s\\n' "$png" "\${@: -1}" > "$png"
    exit 0
    ;;
  hang-nopng)
    # Ignores TERM and never writes a PNG: the measured wedge. Only the reap
    # watchdog's SIGKILL of the tree can end this process.
    trap '' TERM INT HUP
    while :; do sleep 1; done
    ;;
esac
exit 0
`;

// `scenarios`, when a check passes one, REPLACES the scenarios.mjs symlink with
// that module text — the one check that needs a scenario the corpus does not
// carry (modal-by-field) gets it here, and every other check still reads the
// shipped file through the symlink.
const makeSandbox = (shootText, { scenarios } = {}) => {
  const sand = fs.mkdtempSync(path.join(os.tmpdir(), 'shoot-guards-'));
  const prev = path.join(sand, '__preview__');
  fs.mkdirSync(prev);
  fs.mkdirSync(path.join(sand, 'out'));
  for (const f of ['app.css', 'app.js']) fs.symlinkSync(path.join(STATIC, f), path.join(sand, f));
  fs.symlinkSync(path.join(HERE, 'serve.mjs'), path.join(prev, 'serve.mjs'));
  if (scenarios) fs.writeFileSync(path.join(prev, 'scenarios.mjs'), scenarios);
  else fs.symlinkSync(path.join(HERE, 'scenarios.mjs'), path.join(prev, 'scenarios.mjs'));
  const shoot = path.join(prev, 'shoot.sh');
  fs.writeFileSync(shoot, shootText, { mode: 0o755 });
  const chrome = path.join(sand, 'fake-chrome.sh');
  fs.writeFileSync(chrome, FAKE_CHROME, { mode: 0o755 });
  return { sand, shoot, chrome, out: path.join(sand, 'out') };
};

// ── process scoping ──────────────────────────────────────────────────────────
// The ONLY way a pid becomes killable in this file. It starts from a pid this
// harness spawned and walks a single `ps` snapshot downwards by ppid, so a
// foreign shoot.sh, serve.mjs or Chrome on this host can never be selected —
// not even accidentally, because nothing here ever matches on a name.
const psSnapshot = () => {
  const out = execFileSync('ps', ['-A', '-o', 'pid=,ppid=,command='], { encoding: 'utf8' });
  const rows = [];
  for (const line of out.split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line);
    if (m) rows.push({ pid: Number(m[1]), ppid: Number(m[2]), cmd: m[3] });
  }
  return rows;
};

const descendantsOf = (rootPid, rows) => {
  const kids = new Map();
  for (const r of rows) {
    if (!kids.has(r.ppid)) kids.set(r.ppid, []);
    kids.get(r.ppid).push(r);
  }
  const found = [];
  const walk = (pid) => {
    for (const r of kids.get(pid) || []) { found.push(r); walk(r.pid); }
  };
  walk(rootPid);
  return found;
};

const killTree = (rootPid) => {
  let rows;
  try { rows = psSnapshot(); } catch { return; }
  const kin = descendantsOf(rootPid, rows);
  // Deepest first, then the root itself — every pid here was proven to descend
  // from a pid this harness spawned.
  for (const r of kin.reverse()) { try { process.kill(r.pid, 'SIGKILL'); } catch { /* already gone */ } }
  try { process.kill(rootPid, 'SIGKILL'); } catch { /* already gone */ }
};

const freePort = () => new Promise((resolve, reject) => {
  const srv = net.createServer();
  srv.once('error', reject);
  srv.listen(0, '127.0.0.1', () => {
    const { port } = srv.address();
    srv.close(() => resolve(port));
  });
});

// Run shoot.sh once. Resolves with its exit code (null when the budget killed
// it), its combined output, and the pid it ran under.
const runShoot = (box, { env = {}, budgetMs, onLine }) => new Promise((resolve) => {
  const child = spawn('bash', [box.shoot], {
    cwd: box.sand,
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  let timedOut = false;
  let pending = '';
  const feed = (buf) => {
    const s = String(buf);
    out += s;
    if (!onLine) return;
    pending += s;
    const lines = pending.split('\n');
    pending = lines.pop();
    for (const l of lines) onLine(l, child);
  };
  child.stdout.on('data', feed);
  child.stderr.on('data', feed);
  const timer = setTimeout(() => { timedOut = true; killTree(child.pid); }, budgetMs);
  child.on('close', (code, signal) => {
    clearTimeout(timer);
    // Belt and braces: a shot's Chrome or the preview server can outlive the
    // script when the script itself was killed. Same scoping, same snapshot.
    killTree(child.pid);
    resolve({ code, signal, out, timedOut, pid: child.pid });
  });
});

// The ONE kill that targets something this harness did not spawn directly: the
// preview server shoot.sh started. It is selected by PPID — it must be a direct
// child of the shoot.sh pid we hold — and only THEN by what it is running, and
// it refuses unless exactly one row qualifies. A `pkill -f serve.mjs` would
// have hit every concurrent worktree on this host; this cannot reach one.
const killOwnPreviewServer = (shootPid) => {
  const rows = psSnapshot();
  const mine = rows.filter((r) => r.ppid === shootPid && r.cmd.includes('serve.mjs'));
  if (mine.length !== 1) {
    return { killed: null, why: `expected exactly one serve.mjs child of pid ${shootPid}, found ${mine.length}` };
  }
  try { process.kill(mine[0].pid, 'SIGKILL'); } catch (e) { return { killed: null, why: String(e) }; }
  return { killed: mine[0].pid, why: null };
};

// ── the checks ───────────────────────────────────────────────────────────────
// Each `run` returns { ok, why, out }. `ok` false is the RED this file's mutant
// arm demands. Each `cut` removes that guard and nothing else; `gone` is the
// string that must vanish from the cut source — an independent second reader on
// top of replaceUnique's own refusal.

// modal-by-field's fixture: the shipped corpus with `account-modal-2fa-badcode`
// MOVED to a name that shares nothing with the old prefix — the old key is
// DELETED, so no name match anywhere in shoot.sh can be what supplies the modal.
// Imported from the real file by absolute URL, so the fixture is the shipped
// scenario object under a new key and cannot drift into a hand copy.
const RENAMED_BADCODE = 'twofactor-rejected-code';
const RENAMED_BADCODE_FIXTURE = `import { SCENARIOS as REAL } from ${JSON.stringify(pathToFileURL(path.join(HERE, 'scenarios.mjs')).href)};
export const SCENARIOS = { ...REAL, ${JSON.stringify(RENAMED_BADCODE)}: REAL["account-modal-2fa-badcode"] };
delete SCENARIOS["account-modal-2fa-badcode"];
`;

const ok = (out) => ({ ok: true, why: null, out });
const bad = (why, out) => ({ ok: false, why, out });

const CHECKS = [
  {
    id: 'scen-validation',
    guard: 'SCEN validation',
    message: 'SCEN names match no scenario',
    gone: 'SCEN names match no scenario',
    cut: (src) => cutBlock(src, '  if [[ -n "$unknown" ]]; then', '\n  fi', '  :', 'cut SCEN validation'),
    async run(box) {
      const r = await runShoot(box, {
        env: { CHROME: box.chrome, OUT: box.out, PORT: String(await freePort()), SCEN: 'no-such-scenario-zzz' },
        budgetMs: 60_000,
      });
      if (r.code === 0 || r.code === null) return bad(`expected a non-zero exit, got code=${r.code} signal=${r.signal}`, r.out);
      if (!r.out.includes('SCEN names match no scenario')) return bad('exited non-zero but never named the SCEN guard', r.out);
      if (!r.out.includes('no-such-scenario-zzz')) return bad('named the guard but not the offending entry', r.out);
      return ok(r.out);
    },
  },
  {
    id: 'out-lock',
    guard: '$OUT must be OURS — the concurrent-writer lock',
    message: 'another shoot.sh (pid N) is ALREADY writing into $OUT',
    gone: 'ALREADY writing into',
    cut: (src) => cutBlock(src, 'if [[ -f "$LOCK" ]]; then', '\nfi', ':', 'cut the $OUT lock'),
    async run(box) {
      // The "other run" is a process THIS harness spawned and holds the pid of.
      const other = spawn('bash', ['-c', 'while :; do sleep 1; done'], { stdio: 'ignore' });
      fs.writeFileSync(path.join(box.out, '.shoot.lock'), `${other.pid}\n`);
      try {
        const r = await runShoot(box, {
          env: { CHROME: box.chrome, OUT: box.out, PORT: String(await freePort()), SCEN: 'account-modal' },
          budgetMs: 60_000,
        });
        if (r.code === 0 || r.code === null) return bad(`expected a non-zero exit, got code=${r.code} signal=${r.signal}`, r.out);
        if (!r.out.includes('ALREADY writing into')) return bad('exited non-zero but never named the $OUT lock', r.out);
        if (!r.out.includes(`pid ${other.pid}`)) return bad('named the lock but not the pid holding it', r.out);
        return ok(r.out);
      } finally {
        try { process.kill(other.pid, 'SIGKILL'); } catch { /* already gone */ }
      }
    },
  },
  {
    id: 'out-reuse-notice',
    guard: '$OUT must be OURS — the pre-populated-$OUT disclosure',
    message: '>> note: $OUT already holds N PNG(s) from an earlier run.',
    // NOT 'already holds' — the header's own Env block names OUT_REUSE=1 as the
    // way to silence "$OUT already holds N PNGs", so that phrase survives the
    // cut in a comment and the check would report the guard alive forever.
    gone: 'PNG(s) from an earlier run',
    cut: (src) => cutBlock(src, 'existing_png="$(find "$OUT"', '\nfi', ':', 'cut the $OUT reuse notice'),
    async run(box) {
      // Not a refusal — a disclosure, deliberately: `make cloud-shots` shoots
      // into the same $OUT every time, so refusing a non-empty dir would fail
      // every second run for no safety gain. The REFUSAL half of this guard is
      // the lock check above; this half asserts the run still DISCLOSES.
      fs.writeFileSync(path.join(box.out, 'stale-from-an-earlier-run.png'), 'not really a png');
      const r = await runShoot(box, {
        env: { CHROME: box.chrome, OUT: box.out, PORT: String(await freePort()), SCEN: 'account-modal' },
        budgetMs: 120_000,
      });
      if (!r.out.includes('already holds 1 PNG(s) from an earlier run')) {
        return bad('the run never disclosed the PNG already sitting in $OUT', r.out);
      }
      if (!r.out.includes('counts only its own')) return bad('disclosed the count but not what it means', r.out);
      return ok(r.out);
    },
  },
  {
    id: 'server-liveness',
    guard: 'per-shot server liveness',
    message: 'preview server on :PORT stopped answering mid-run.',
    gone: 'stopped answering mid-run',
    cut: (src) => cutBlock(src, '  if ! server_alive; then', '\n  fi', '  :', 'cut per-shot liveness'),
    async run(box) {
      let killedPid = null;
      let killWhy = null;
      let fired = false;
      const r = await runShoot(box, {
        env: { CHROME: box.chrome, OUT: box.out, PORT: String(await freePort()), SCEN: 'account-modal' },
        budgetMs: 120_000,
        onLine: (line, child) => {
          // ">> Chrome:" is the first line printed AFTER every boot-time check
          // has passed, so killing here proves the MID-RUN guard rather than
          // the boot one, which has its own, different message.
          if (fired || !line.startsWith('>> Chrome:')) return;
          fired = true;
          const res = killOwnPreviewServer(child.pid);
          killedPid = res.killed;
          killWhy = res.why;
        },
      });
      if (!fired) return bad('shoot.sh never reached ">> Chrome:", so the fixture never armed', r.out);
      if (killedPid === null) return bad(`could not scope the kill to this run's own preview server: ${killWhy}`, r.out);
      if (r.code === 0 || r.code === null) return bad(`expected a non-zero exit, got code=${r.code} signal=${r.signal}`, r.out);
      if (!r.out.includes('stopped answering mid-run')) return bad('exited non-zero but never named the liveness guard', r.out);
      if (!r.out.includes('ERR_CONNECTION_REFUSED')) return bad('named the guard but not what the PNGs would have been', r.out);
      return ok(r.out);
    },
  },
  {
    id: 'reap-watchdog',
    guard: 'the reap watchdog',
    message: 'watchdog: chrome <pid> ignored TERM for Ns — killing tree',
    gone: 'watchdog: chrome',
    // `sleep 0 &` keeps the shape — a backgrounded job whose pid `local wd=$!`
    // reads, so every line after it still works — while removing the bound.
    cut: (src) => cutBlock(src, '  (\n    exec 2>', '\n  ) &', '  sleep 0 &', 'cut the reap watchdog'),
    async run(box) {
      // A Chrome that ignores TERM and never writes its PNG. Without the
      // watchdog, `wait "$cpid"` never returns and this run never ends — which
      // is the whole measured defect, four times, up to 10h30m.
      const r = await runShoot(box, {
        env: {
          CHROME: box.chrome, OUT: box.out, PORT: String(await freePort()),
          SCEN: 'account-modal', FAKE_MODE: 'hang-nopng', REAP_BUDGET: '2',
        },
        budgetMs: 150_000,
      });
      if (r.timedOut) return bad('shoot.sh never exited inside the budget — it wedged in the reap, exactly as it did before the watchdog', r.out);
      if (r.code === 0 || r.code === null) return bad(`expected a non-zero exit, got code=${r.code} signal=${r.signal}`, r.out);
      if (!r.out.includes('watchdog: chrome')) return bad('exited non-zero but the watchdog never spoke', r.out);
      if (!r.out.includes('ignored TERM for 2s — killing tree')) return bad('the watchdog spoke but did not name the budget it enforced', r.out);
      if (!r.out.includes('>> Done with FAILURES')) return bad('the watchdog fired but the run did not report the shots as failed', r.out);
      return ok(r.out);
    },
  },
  {
    id: 'modal-by-field',
    guard: 'the modal query is the scenario\'s declared `modal` field, never its NAME',
    message: '&modal=<driver> on a scenario named outside account-modal*',
    gone: 'modal_q="&modal=$smodal"',
    // THE MUTANT IS THE DELETED CONVENTION, restored verbatim — not a blank.
    // gr-backlog-scenario-drive-field asks for proof that the name convention is
    // GONE rather than widened, and the only honest red for that is the old
    // line itself coming back: under it, a scenario named outside the prefix
    // shoots with no dialog, and the badcode driver collapses to plain
    // `account` — the byte-identical-twin defect gr-p5r5 was spent fixing.
    cut: (src) => replaceUnique(
      src,
      'if [[ -n "$smodal" ]]; then modal_q="&modal=$smodal"; fi',
      'case "$scen" in account-modal*) modal_q="&modal=account" ;; esac',
      { what: 'restore the account-modal* name convention' },
    ),
    scenarios: RENAMED_BADCODE_FIXTURE,
    async run(box) {
      const r = await runShoot(box, {
        env: { CHROME: box.chrome, OUT: box.out, PORT: String(await freePort()), SCEN: RENAMED_BADCODE },
        budgetMs: 120_000,
      });
      if (r.code !== 0) return bad(`expected exit 0 on the renamed scenario, got code=${r.code} signal=${r.signal}`, r.out);
      const pngs = fs.readdirSync(box.out).filter((f) => f.startsWith(`${RENAMED_BADCODE}-`) && f.endsWith('.png')).sort();
      if (pngs.length !== 4) return bad(`expected 4 shots of ${RENAMED_BADCODE} (2 themes x 2 widths), found ${pngs.length}`, r.out);
      for (const f of pngs) {
        const url = (/^url=(.*)$/m.exec(fs.readFileSync(path.join(box.out, f), 'utf8')) || [])[1] || '';
        if (!url.includes(`scen=${RENAMED_BADCODE}&`)) return bad(`${f}: the fake Chrome recorded no URL for this scenario: ${JSON.stringify(url)}`, r.out);
        if (!/[?&]modal=account-2fa-badcode(&|#|$)/.test(url)) {
          return bad(`${f}: shot WITHOUT its declared driver (modal=account-2fa-badcode) — url ${url}`, r.out);
        }
      }
      return ok(r.out);
    },
  },
];

// The happy path — the control that makes every RED above mean something. If
// this goes red, the four checks are refusing for a reason that has nothing to
// do with their guards.
const HAPPY = {
  id: 'happy-path',
  guard: 'the happy path (control)',
  async run(box) {
    const r = await runShoot(box, {
      env: { CHROME: box.chrome, OUT: box.out, PORT: String(await freePort()), SCEN: 'account-modal' },
      budgetMs: 120_000,
    });
    if (r.code !== 0) return bad(`expected exit 0, got code=${r.code} signal=${r.signal}`, r.out);
    const okLines = (r.out.match(/^ {2}ok {2}account-modal-/gm) || []).length;
    if (okLines !== 4) return bad(`expected 4 "ok" shots (2 themes x 2 widths), saw ${okLines}`, r.out);
    if (!r.out.includes('>> Done. 4 PNG(s) shot this run')) return bad('the completion line did not report this run\'s own 4 shots', r.out);
    const pngs = fs.readdirSync(box.out).filter((f) => f.endsWith('.png')).sort();
    if (pngs.length !== 4) return bad(`expected 4 PNGs on disk, found ${pngs.length}: ${pngs.join(', ')}`, r.out);
    return ok(r.out);
  },
};

// ── the runner ───────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const only = argv.includes('--only') ? argv[argv.indexOf('--only') + 1] : null;
const greenOnly = argv.includes('--green-only');
const verbose = argv.includes('--verbose');

const tail = (out, n = 24) => out.trimEnd().split('\n').slice(-n).map((l) => `      | ${l}`).join('\n');

const rmSandbox = (box) => { try { fs.rmSync(box.sand, { recursive: true, force: true }); } catch { /* best effort */ } };

const main = async () => {
  const selected = CHECKS.filter((c) => !only || c.id === only);
  if (only && selected.length === 0 && only !== HAPPY.id) {
    console.error(`!! no check named '${only}'. Known: ${[...CHECKS.map((c) => c.id), HAPPY.id].join(', ')}`);
    process.exit(2);
  }
  const failures = [];

  const runOne = async (check, shootText, label) => {
    const box = makeSandbox(shootText, { scenarios: check.scenarios });
    try {
      const started = Date.now();
      const res = await check.run(box);
      const secs = ((Date.now() - started) / 1000).toFixed(1);
      return { ...res, secs, label };
    } finally {
      rmSandbox(box);
    }
  };

  // 1 — the happy path first: a red here invalidates everything after it.
  if (!only || only === HAPPY.id) {
    const res = await runOne(HAPPY, SHOOT_SRC, 'green');
    console.log(`${res.ok ? 'PASS' : 'FAIL'}  ${HAPPY.id.padEnd(18)} happy path, ${res.secs}s`);
    if (!res.ok) { failures.push(`${HAPPY.id}: ${res.why}`); console.log(tail(res.out)); }
    else if (verbose) console.log(tail(res.out, 8));
  }

  for (const check of selected) {
    // 2 — the check must be GREEN against the shipped shoot.sh.
    const green = await runOne(check, SHOOT_SRC, 'green');
    console.log(`${green.ok ? 'PASS' : 'FAIL'}  ${check.id.padEnd(18)} ${check.guard} fires, ${green.secs}s`);
    if (!green.ok) failures.push(`${check.id} (green): ${green.why}`);
    if (!green.ok || verbose) console.log(tail(green.out));

    if (greenOnly) continue;

    // 3 — and RED when its guard is cut out. replaceUnique refuses unless the
    // span resolved exactly once, so the cut is proven APPLIED; the `gone`
    // assertion below proves, independently, that the guard's own words left
    // with it.
    let cutSrc;
    try {
      cutSrc = check.cut(SHOOT_SRC);
    } catch (e) {
      console.log(`FAIL  ${check.id.padEnd(18)} the cut could not be applied: ${e.message}`);
      failures.push(`${check.id} (cut): ${e.message}`);
      continue;
    }
    if (cutSrc === SHOOT_SRC) {
      console.log(`FAIL  ${check.id.padEnd(18)} the cut changed nothing`);
      failures.push(`${check.id} (cut): changed nothing`);
      continue;
    }
    if (cutSrc.includes(check.gone)) {
      console.log(`FAIL  ${check.id.padEnd(18)} the cut left ${JSON.stringify(check.gone)} in shoot.sh — the guard is still there`);
      failures.push(`${check.id} (cut): ${check.gone} survived`);
      continue;
    }
    const mutant = await runOne(check, cutSrc, 'mutant');
    const proven = !mutant.ok;
    console.log(`${proven ? 'PASS' : 'FAIL'}  ${check.id.padEnd(18)} MUTATION: with the guard cut the check goes ${proven ? `RED — ${mutant.why}` : 'GREEN, so it asserts nothing'}, ${mutant.secs}s`);
    if (!proven) { failures.push(`${check.id} (mutant): stayed green with its guard removed`); console.log(tail(mutant.out)); }
    else if (verbose) console.log(tail(mutant.out, 8));
  }

  console.log('');
  if (failures.length) {
    console.log(`!! shoot-guards: ${failures.length} failure(s)`);
    for (const f of failures) console.log(`   - ${f}`);
    process.exit(1);
  }
  console.log('shoot-guards: every guard fired, and every check went red without its guard.');
};

main().catch((e) => { console.error(e); process.exit(2); });
