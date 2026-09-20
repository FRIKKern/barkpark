// badcode-freeze.test.mjs — THE GUARD FOR THE SHOT FREEZE IN mock.js.
//
//   node --test cloud/priv/static/__preview__/badcode-freeze.test.mjs
//   BP_FREEZE_SHOOT=1 node --test …        # force the browser arm on
//   BP_FREEZE_SHOOT=0 node --test …        # force it off
//
// WHY THIS FILE EXISTS
// ────────────────────
// `account-modal-2fa-badcode` was the only preview scenario ending on a FOCUSED
// text input, and a focused text input is the one thing in this harness that is
// not a function of the DOM: it carries a blinking caret on a wall clock that
// Chrome's --virtual-time-budget does not freeze, plus a focus-ring CSS
// transition whose phase depends on when the capture poll happens to fire. Two
// clean shoots at origin/main 2ff0d2c1a therefore disagreed on 3 of its 4 PNGs
// while every plain `account-modal` shot was byte-identical across the same two
// runs (PR #19583 — `magick compare` put every differing pixel inside one
// 228x88 device-pixel box, the #a2f-otp input).
//
// #19583 fixed it with `freezeShotSurface()` in mock.js and shipped NO guard,
// saying so honestly in its own "what I did NOT run". This file is that guard.
//
// TWO ARMS, AND ONLY ONE OF THEM IS THE POINT
// ───────────────────────────────────────────
// The static arms below read mock.js and would red on a rename or a deletion —
// cheap, browserless, and NOT sufficient: they are present-in-file checks, and
// a freeze that is present but ineffective passes every one of them. The arm
// that can actually lose is `two clean shoots … byte-identical`: it runs the
// REAL shoot.sh twice, into two different $OUTs on two different ports, and
// compares the badcode PNGs byte for byte. Removing the `freezeShotSurface`
// call reds it — measured, both directions, in the PR that added this file.
//
// THE CONTROL, AND WHY A DIFFERING CONTROL IS NOT A RED
// ────────────────────────────────────────────────────
// Each run also shoots the PLAIN `account-modal` scenario. Those four PNGs have
// no caret and no focus ring, so they are stable by construction; if THEY move
// across two runs, this host is producing noise that has nothing to do with the
// freeze and blaming mock.js for it would be a false accusation. That case
// prints INCONCLUSIVE and passes. It is the precondition, asserted rather than
// assumed — a control that fires tells you the measurement is void, not that
// the subject is fine.
//
// STATED HONESTLY: the instability is a COIN FLIP per shot, not an always-
// differ (#19583 measured 3 of 4 in one pair). A single pair of runs can
// therefore miss a removed freeze; four shots make that unlikely, not
// impossible. This arm is a detector, not a proof of absence.
//
// SKIP-AS-COUNTED, NEVER `t.skip()`
// ─────────────────────────────────
// The workflow step that runs this suite ("__preview__ suites no other step
// runs") tallies `# pass N` against an EXACT two-sided pin. A `t.skip()` lands
// in `# skip`, not `# pass`, so a skipping host and a running host would report
// different tallies and the pin could not be right on both. So the browser arm
// never skips: when it cannot run it PRINTS WHY, by name, and passes. It is off
// by default under CI because the job that selects this suite is the
// BROWSERLESS one — this workflow keeps Chrome bring-up to its own jobs.
//
// HISTORY
// ───────
// 2026-09-20  created (task-f8318f7734a52c52). Preview-suite pin re-measured in
//             the same PR: 225 -> 230 over 15 suites, node 22.22.0.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const MOCK = fs.readFileSync(join(HERE, 'mock.js'), 'utf8');
const SHOOT = join(HERE, 'shoot.sh');

const BADCODE = 'account-modal-2fa-badcode';
const CONTROL = 'account-modal';
const SHOTS = ['light-1440', 'light-768', 'dark-1440', 'dark-768'];

// ── the static arms ─────────────────────────────────────────────────────────

test('mock.js installs the freeze at the badcode drive\'s OWN arrival point', () => {
  assert.match(
    MOCK,
    /whenPresent\("#a2f-error",\s*freezeShotSurface\)/,
    'the 422 arrival callback no longer calls freezeShotSurface — the shot goes back to ' +
      'catching an arbitrary caret phase. See the browser arm below for what that costs.',
  );
});

test('the freeze kills BOTH sources the shot was catching', () => {
  const body = MOCK.slice(MOCK.indexOf('function freezeShotSurface'));
  assert.ok(body.length > 0, 'freezeShotSurface() is gone from mock.js entirely');
  for (const decl of ['caret-color:transparent', 'transition:none', 'animation:none']) {
    assert.ok(
      body.includes(decl),
      `freezeShotSurface() no longer declares ${decl} — the caret and the focus-ring ` +
        'transition were TWO sources, and dropping either one re-opens the shot.',
    );
  }
});

test('the freeze KEEPS focus — the shot must still show the rejected field', () => {
  const body = MOCK.slice(
    MOCK.indexOf('function freezeShotSurface'),
    MOCK.indexOf('function freezeShotSurface') + 800,
  );
  assert.ok(
    !/\.blur\(|document\.activeElement\s*=/.test(body),
    'freezeShotSurface() blurs the field. That would make the PNG stable by photographing ' +
      'the WRONG state: the scenario is a focused, rejected OTP input.',
  );
});

test('the freeze stays in the PREVIEW harness — app.js is not touched', () => {
  const app = fs.readFileSync(join(HERE, '..', 'app.js'), 'utf8');
  assert.ok(
    !app.includes('data-preview-shot-freeze'),
    'the shot freeze leaked into app.js — real users would lose their caret so a ' +
      'screenshot harness could be tidy.',
  );
});

// ── the arm that can lose ───────────────────────────────────────────────────

function shootInto(out, port) {
  const env = { ...process.env, OUT: out, PORT: String(port), SCEN: `${BADCODE},${CONTROL}`, ACCENT: 'iris', OUT_REUSE: '1' };
  delete env.CHROME_BIN;
  return execFileSync('bash', [SHOOT], { env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

function digest(file) {
  const bytes = fs.readFileSync(file);
  return `${createHash('sha256').update(bytes).digest('hex').slice(0, 16)}  ${bytes.length} B`;
}

test('two clean shoots of the badcode drive produce byte-identical PNGs', { timeout: 600000 }, () => {
  const why = (reason) => console.log(`# SKIP-AS-COUNTED (this test passes without measuring): ${reason}`);

  if (process.env.BP_FREEZE_SHOOT === '0') {
    why('BP_FREEZE_SHOOT=0 — the browser arm was switched off explicitly.');
    return;
  }
  if (process.env.CI && process.env.BP_FREEZE_SHOOT !== '1') {
    why(
      'CI is set and BP_FREEZE_SHOOT is not 1. The step that selects this suite runs in the ' +
        'BROWSERLESS job; Chrome bring-up lives in its own jobs in this workflow. Run it ' +
        'locally, or set BP_FREEZE_SHOOT=1 in a job that has a browser.',
    );
    return;
  }

  const runs = [];
  for (const i of [1, 2]) {
    const out = fs.mkdtempSync(join(os.tmpdir(), `badcode-freeze-${i}-`));
    const port = 4300 + Math.floor(Math.random() * 600);
    let log;
    try {
      log = shootInto(out, port);
    } catch (err) {
      const text = `${err.stdout || ''}${err.stderr || ''}`;
      if (text.includes('No Chrome/Chromium found')) {
        why('shoot.sh found no Chrome/Chromium on this host. Install one, or set CHROME=.');
        return;
      }
      if (/failed:|no PNG after/.test(text)) {
        why(
          'shoot.sh could not produce PNGs on this host — it names the binary it tried in ' +
            `its own log:\n${text.split('\n').filter((l) => l.includes('!!')).slice(0, 8).join('\n')}`,
        );
        return;
      }
      throw err;
    }
    runs.push({ out, log });
  }

  // THE PRECONDITION, asserted: the control shots must be stable on this host.
  const controlMoved = SHOTS.filter(
    (s) => digest(join(runs[0].out, `${CONTROL}-${s}-iris.png`)) !== digest(join(runs[1].out, `${CONTROL}-${s}-iris.png`)),
  );
  if (controlMoved.length > 0) {
    why(
      `the CONTROL scenario (${CONTROL}) also moved across the two runs at ${controlMoved.join(', ')} — ` +
        'this host is producing capture noise unrelated to the freeze, so the badcode ' +
        'comparison would be an accusation the measurement cannot support. INCONCLUSIVE.',
    );
    return;
  }

  const moved = SHOTS.map((s) => {
    const a = digest(join(runs[0].out, `${BADCODE}-${s}-iris.png`));
    const b = digest(join(runs[1].out, `${BADCODE}-${s}-iris.png`));
    return a === b ? null : `  ${BADCODE}-${s}-iris.png\n    run 1: ${a}\n    run 2: ${b}`;
  }).filter(Boolean);

  assert.deepEqual(
    moved,
    [],
    'the badcode shot is NON-DETERMINISTIC again — two clean shoots disagreed while the ' +
      `plain ${CONTROL} control held:\n${moved.join('\n')}\n` +
      'That is the caret/transition freeze in mock.js gone or ineffective ' +
      '(freezeShotSurface, task gr-p5r7-badcode-shot-nondeterministic).',
  );
  console.log(`# freeze held: 4 badcode PNGs byte-identical across two clean shoots, control stable`);
});
