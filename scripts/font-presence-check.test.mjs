#!/usr/bin/env node
//
// font-presence-check.test.mjs — does studio-desk-measure's font-presence test
// tell the truth?
//
// NOT A CI GATE, for the same reason studio-desk-measure.mjs is not one: it
// needs a real browser. It is the proof that the instrument's `face_available`
// column means something, committed so the claim can be re-run rather than
// believed.
//
// WHAT IT PROVES. The predicate is EXTRACTED FROM studio-desk-measure.mjs at run
// time rather than copied here, so the thing under test cannot drift from the
// thing that ships. It is then run in headless Chromium against ground truth
// from CDP CSS.getPlatformFontsForNode, which names the family the engine
// actually rasterised.
//
// WHY IT EXISTS. The column used to be document.fonts.check(), which is not a
// presence test: it returns true for every local family, including a font name
// invented for this test. Every committed artifact in scripts/measurements/
// therefore records loaded true for all seven families and false for none —
// including Palatino Linotype, which is not installed on the measuring Mac and
// is the entire subject of spd-palatino-linotype-unmeasured.
//
//   node scripts/font-presence-check.test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INSTRUMENT = path.join(HERE, 'studio-desk-measure.mjs');

// ── extract the predicate from the shipping instrument ──────────────────────
const src = fs.readFileSync(INSTRUMENT, 'utf8');
const m = src.match(
  /const PRESENCE_GENERICS = (\[[^\]]*\]);[\s\S]*?const familyIsPresent = \(fam\) =>([\s\S]*?\n  \);)/,
);
if (!m) {
  console.error(
    'FAIL: could not find PRESENCE_GENERICS / familyIsPresent in studio-desk-measure.mjs.\n' +
    'Either the predicate was renamed, or the presence test was reverted to\n' +
    'document.fonts.check(). Both need a human — this test refuses to guess.',
  );
  process.exit(1);
}
const genericsLiteral = m[1];
const bodyLiteral = m[2].trim().replace(/,?\s*\);$/, ')');

console.log('extracted from studio-desk-measure.mjs:');
console.log('  PRESENCE_GENERICS =', genericsLiteral);
console.log('');

const require_ = createRequire('/Volumes/SATECHI/github/barkpark/js/package.json');
let chromium;
try {
  ({ chromium } = require_('playwright'));
} catch {
  console.error('SKIP: playwright not resolvable (see studio-desk-measure.mjs resolution notes).');
  process.exit(0);
}

const CANDIDATES = [
  'Iowan Old Style',
  'Palatino Linotype',
  'Palatino',
  'Charter',
  'Georgia',
  'Source Serif 4',
  'Times New Roman',
  // The control. If a presence test says this is present, it is not a presence
  // test. document.fonts.check() says it is.
  'Definitely Not A Real Font XYZQ',
];

const browser = await chromium.launch();
const page = await browser.newPage();
const cdp = await page.context().newCDPSession(page);
await cdp.send('DOM.enable');
await cdp.send('CSS.enable');

const body = CANDIDATES.map(
  (f, i) => `<div id="c${i}" style="font-family:'${f}';font-size:40px;white-space:pre">Hamburgefonstiv 0123456789</div>`,
).join('');
await page.setContent(`<body style="margin:0">${body}</body>`);
await page.evaluate(() => document.fonts.ready);

// ── ground truth: what did the engine actually rasterise? ───────────────────
const { root } = await cdp.send('DOM.getDocument');
const truth = {};
for (let i = 0; i < CANDIDATES.length; i++) {
  const { nodeId } = await cdp.send('DOM.querySelector', {
    nodeId: root.nodeId, selector: '#c' + i,
  });
  const { fonts } = await cdp.send('CSS.getPlatformFontsForNode', { nodeId });
  const used = (fonts || []).map((x) => x.familyName).join('+');
  const norm = (x) => x.toLowerCase().replace(/\s+/g, '');
  truth[CANDIDATES[i]] = { used, present: norm(used).startsWith(norm(CANDIDATES[i])) };
}

// ── run BOTH predicates in the page ─────────────────────────────────────────
const results = await page.evaluate(
  ({ cands, generics, bodySrc }) => {
    const surface = document.body;
    const probeText = 'mmmmmmmmmm0123456789';
    // advanceOf, matching studio-desk-measure.mjs's own helper
    const advanceOf = (family) => {
      const s = document.createElement('span');
      s.textContent = probeText;
      s.style.cssText = 'position:absolute;visibility:hidden;white-space:pre;left:-9999px;';
      s.style.fontSize = '18px';
      s.style.fontFamily = family;
      surface.appendChild(s);
      const w = s.getBoundingClientRect().width;
      s.remove();
      return w;
    };
    const PRESENCE_GENERICS = JSON.parse(generics.replace(/'/g, '"'));
    // eslint-disable-next-line no-new-func
    const familyIsPresent = new Function(
      'fam', 'advanceOf', 'PRESENCE_GENERICS', 'return ' + bodySrc + ';',
    );
    const out = {};
    for (const f of cands) {
      let check = false;
      try { check = document.fonts.check('18px "' + f + '"'); } catch { /* keep false */ }
      out[f] = {
        fonts_check: check,
        measured: !!familyIsPresent(f, advanceOf, PRESENCE_GENERICS),
      };
    }
    return out;
  },
  { cands: CANDIDATES, generics: genericsLiteral, bodySrc: bodyLiteral },
);

await browser.close();

const pad = (s, n) => (String(s) + ' '.repeat(n)).slice(0, n);
console.log(pad('CANDIDATE', 34) + pad('CDP USED', 20) + pad('TRUTH', 9) + pad('fonts.check', 13) + 'MEASURED');
console.log('-'.repeat(90));
let checkWrong = 0;
let measuredWrong = 0;
for (const f of CANDIDATES) {
  const t = truth[f];
  const r = results[f];
  const cOk = r.fonts_check === t.present;
  const mOk = r.measured === t.present;
  if (!cOk) checkWrong++;
  if (!mOk) measuredWrong++;
  console.log(
    pad(f, 34) + pad(t.used, 20) + pad(t.present ? 'present' : 'ABSENT', 9) +
    pad(r.fonts_check + (cOk ? '' : ' WRONG'), 13) +
    r.measured + (mOk ? '' : '  <-- WRONG'),
  );
}

console.log('');
console.log(`document.fonts.check(): wrong on ${checkWrong}/${CANDIDATES.length}  (why it was replaced)`);
console.log(`shipped predicate     : wrong on ${measuredWrong}/${CANDIDATES.length}`);

if (measuredWrong > 0) {
  console.error('\nFAIL: the shipped presence predicate disagrees with CDP ground truth.');
  process.exit(1);
}
if (checkWrong === 0) {
  console.error(
    '\nFAIL (vacuous): document.fonts.check() got everything right here, so this\n' +
    'run does not demonstrate the defect and cannot show the fix beats it. The\n' +
    'control font must resolve to a fallback for this test to mean anything.',
  );
  process.exit(1);
}
console.log('\nPASS — the shipped predicate matches ground truth on every candidate,');
console.log('and the method it replaced does not.');
