#!/usr/bin/env node
//
// font-zero-advance.mjs — read a font's `0` advance STRAIGHT OUT OF THE BINARY.
//
// WHY THIS EXISTS. Every `ch` figure in the studio-space epic is the advance of
// the digit ZERO in whichever family the platform resolved, so "which face wins"
// and "how wide is its 0" together decide the reading measure. D145 derived
// Iowan, Georgia and Source Serif 4 that way and the numbers held. One member of
// the shipped stack has never been derived at all: `Palatino Linotype`, which
// wins on Windows and is not installable on the measuring Mac
// (spd-palatino-linotype-unmeasured).
//
// So the blocker is a MACHINE, not a method — and a blocker that needs a machine
// deserves a tool that runs there in one command with nothing to install. This
// file has ZERO dependencies (no fontTools, no npm install): plain Node reading
// the OpenType tables. On a Windows box the whole gate is:
//
//     node scripts/font-zero-advance.mjs "C:\Windows\Fonts\pala.ttf"
//
// ── WHAT IT READS, and why each table ────────────────────────────────────────
//   head  unitsPerEm       — the em square the advance is expressed in
//   cmap  U+0030 -> glyph  — the '0' GLYPH ID; never assume a glyph index
//   hhea  numberOfHMetrics — where hmtx stops repeating
//   hmtx  advanceWidth[gid]
//   name  family/subfamily — so a .ttc face is IDENTIFIED, not guessed at
//
// A .ttc (macOS ships Iowan, Palatino and Charter as collections) holds many
// faces; the ROMAN/REGULAR one is the reading face, and printing every face with
// its name is what stops a Bold advance being recorded as the body figure —
// Iowan's Bold is 1217/2048 against Roman's 1139/2048, a 7% error that would
// look entirely plausible in a table.
//
// ── THE CHROME CONVERSION, which is not just advance x px ────────────────────
// Chrome floors `1ch` to LayoutUnit, 1/64px. D145: Iowan's 1139/2048 em is
// 10.0107px at 18px, and 10.0107 x 64 = 640.688 -> 640 -> 10.0000 exactly, which
// is why the instrument reports a suspiciously round 10. `--self-test` asserts
// that model against all three faces D145 published, so a wrong build of this
// tool cannot quietly produce plausible numbers.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');

const U8 = (b, o) => b.readUInt8(o);
const U16 = (b, o) => b.readUInt16BE(o);
const I16 = (b, o) => b.readInt16BE(o);
const U32 = (b, o) => b.readUInt32BE(o);

/** The 55ch criterion, and the size the reading surface sets type at. */
const CRITERION_CH = 55;
const READING_FONT_SIZE_PX = 18;
/** Chrome's LayoutUnit: 1/64 px. `1ch` is floored to it. */
const LAYOUT_UNIT = 64;

const chromeCh = (px) => Math.floor(px * LAYOUT_UNIT) / LAYOUT_UNIT;

// ── OpenType ────────────────────────────────────────────────────────────────

function tableDirectory(buf, base) {
  const numTables = U16(buf, base + 4);
  const tables = {};
  for (let i = 0; i < numTables; i++) {
    const rec = base + 12 + i * 16;
    tables[buf.toString('latin1', rec, rec + 4)] = {
      off: U32(buf, rec + 8),
      len: U32(buf, rec + 12),
    };
  }
  return tables;
}

/**
 * A name record is platformID(2) encodingID(2) languageID(2) nameID(2)
 * length(2) offset(2). nameID lives at +6 — reading it at +2 yields encodingID,
 * which silently labels every face with a copyright string instead of a name
 * (measured while building this: every row came back "Copyright 1990-2005
 * Bitstream Inc." and the metrics beside them were correct, so nothing looked
 * broken). Windows (platform 3) records are UTF-16BE and Mac (platform 1) are
 * latin1, so "whichever record came first" mixes encodings into mojibake.
 */
function readNames(buf, tables) {
  if (!tables.name) return {};
  const b = tables.name.off;
  const count = U16(buf, b + 2);
  const strOff = b + U16(buf, b + 4);
  const best = {};
  for (let i = 0; i < count; i++) {
    const r = b + 6 + i * 12;
    const platID = U16(buf, r);
    const nameID = U16(buf, r + 6);
    const len = U16(buf, r + 8);
    const off = U16(buf, r + 10);
    if (![1, 2, 4, 6, 16, 17].includes(nameID)) continue;
    const raw = Buffer.from(buf.subarray(strOff + off, strOff + off + len));
    const s = (platID === 3 || platID === 0)
      ? (raw.length % 2 ? '' : Buffer.from(raw).swap16().toString('utf16le'))
      : raw.toString('latin1');
    const rank = platID === 3 ? 2 : platID === 0 ? 1 : 0;
    if (!best[nameID] || rank > best[nameID].rank) best[nameID] = { s, rank };
  }
  const out = {};
  for (const k of Object.keys(best)) out[k] = best[k].s;
  return out;
}

/** cmap lookup. Formats 4/12/6/0 cover every face this repo's stack names. */
function glyphForCodepoint(buf, tables, cp) {
  if (!tables.cmap) return 0;
  const b = tables.cmap.off;
  const n = U16(buf, b + 2);
  let best = null;
  for (let i = 0; i < n; i++) {
    const r = b + 4 + i * 8;
    const plat = U16(buf, r);
    const enc = U16(buf, r + 2);
    const off = U32(buf, r + 4);
    const score = (plat === 3 && enc === 10) ? 5 : (plat === 3 && enc === 1) ? 4
      : (plat === 0) ? 3 : (plat === 3 && enc === 0) ? 2 : 1;
    if (!best || score > best.score) best = { score, sub: b + off };
  }
  if (!best) return 0;
  const s = best.sub;
  const fmt = U16(buf, s);
  if (fmt === 4) {
    const segX2 = U16(buf, s + 6);
    const seg = segX2 / 2;
    const endB = s + 14;
    const startB = endB + segX2 + 2;
    const deltaB = startB + segX2;
    const rangeB = deltaB + segX2;
    for (let i = 0; i < seg; i++) {
      if (cp > U16(buf, endB + i * 2)) continue;
      const start = U16(buf, startB + i * 2);
      if (cp < start) return 0;
      const delta = I16(buf, deltaB + i * 2);
      const ro = U16(buf, rangeB + i * 2);
      if (ro === 0) return (cp + delta) & 0xffff;
      const g = U16(buf, rangeB + i * 2 + ro + (cp - start) * 2);
      return g === 0 ? 0 : (g + delta) & 0xffff;
    }
    return 0;
  }
  if (fmt === 12) {
    const nGroups = U32(buf, s + 12);
    for (let i = 0; i < nGroups; i++) {
      const g = s + 16 + i * 12;
      const sc = U32(buf, g);
      const ec = U32(buf, g + 4);
      if (cp >= sc && cp <= ec) return U32(buf, g + 8) + (cp - sc);
    }
    return 0;
  }
  if (fmt === 6) {
    const first = U16(buf, s + 6);
    const cnt = U16(buf, s + 8);
    return (cp >= first && cp < first + cnt) ? U16(buf, s + 10 + (cp - first) * 2) : 0;
  }
  if (fmt === 0) return cp > 255 ? 0 : U8(buf, s + 6 + cp);
  return 0;
}

function advanceFor(buf, tables, gid) {
  const numH = U16(buf, tables.hhea.off + 34);
  return U16(buf, tables.hmtx.off + Math.min(gid, numH - 1) * 4);
}

/** Every face in a file — one for a .ttf/.otf, many for a .ttc collection. */
export function facesIn(file) {
  const buf = fs.readFileSync(file);
  const tag = buf.toString('latin1', 0, 4);
  const bases = [];
  if (tag === 'ttcf') {
    const n = U32(buf, 8);
    for (let i = 0; i < n; i++) bases.push(U32(buf, 12 + i * 4));
  } else if (tag === 'wOFF' || tag === 'wOF2') {
    throw new Error(
      `${path.basename(file)} is WOFF/WOFF2 (compressed). This reader takes ` +
      'uncompressed TTF/OTF/TTC only — point it at the system-installed face.',
    );
  } else {
    bases.push(0);
  }
  return bases.map((base) => {
    const t = tableDirectory(buf, base);
    for (const need of ['head', 'hhea', 'hmtx', 'cmap']) {
      if (!t[need]) throw new Error(`${path.basename(file)}: no '${need}' table`);
    }
    const names = readNames(buf, t);
    const unitsPerEm = U16(buf, t.head.off + 18);
    const gid = glyphForCodepoint(buf, t, 0x30);
    const zeroAdvance = gid ? advanceFor(buf, t, gid) : null;
    const em = zeroAdvance === null ? null : zeroAdvance / unitsPerEm;
    return {
      file,
      family: names[16] || names[1] || '(unnamed)',
      subfamily: names[17] || names[2] || '',
      full: names[4] || `${names[1] || '?'} ${names[2] || ''}`.trim(),
      postscript: names[6] || '',
      unitsPerEm,
      zeroGlyphId: gid,
      zeroAdvance,
      em,
      pxAt18: em === null ? null : em * READING_FONT_SIZE_PX,
      chromeCh: em === null ? null : chromeCh(em * READING_FONT_SIZE_PX),
      variable: !!t.fvar,
    };
  });
}

// ── the per-width verdict ───────────────────────────────────────────────────
//
// D107 fixes the desktop rows at 1440, 1280, 1024, 900, 800, 764, 700. At each,
// the reading column's content width is FACE-INDEPENDENT — measured, not
// assumed: all three forced faces report the SAME content_px at every one of the
// seven, which is what makes a single per-width threshold legitimate. The em at
// which a face lands exactly on 55ch is content_px / (55 x 18) = content_px/990,
// and a face MEETS iff its `0` advance em is at or below it.
//
// The widths are READ from a committed run, never typed here: a threshold typed
// into a script has no producer and goes stale in its own commit.

export function thresholdsFromArtifact(artifactPath) {
  const d = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
  const D107 = [1440, 1280, 1024, 900, 800, 764, 700];
  const widths = [];
  for (const w of D107) {
    const rows = (d.rows || []).filter(
      (r) => r.viewport_px === w && r.inspector_state === 'default' && r.content_px,
    );
    if (!rows.length) continue;
    const pxs = [...new Set(rows.map((r) => r.content_px))];
    widths.push({
      width: w,
      contentPx: pxs[0],
      faceIndependent: pxs.length === 1,
      emThreshold: pxs[0] / (CRITERION_CH * READING_FONT_SIZE_PX),
    });
  }
  return { artifact: path.basename(artifactPath), widths };
}

function newestArtifact() {
  const dir = path.join(REPO, 'scripts', 'measurements');
  const files = fs.readdirSync(dir)
    .filter((f) => f.endsWith('.json') && f.includes('bracketed'))
    .sort();
  if (!files.length) throw new Error('no bracketed measurement artifact found');
  return path.join(dir, files[files.length - 1]);
}

function printVerdict(em, label) {
  const { artifact, widths } = thresholdsFromArtifact(newestArtifact());
  console.log(`\nVERDICT for ${label} — ${CRITERION_CH}ch bar, type at ${READING_FONT_SIZE_PX}px`);
  console.log(`thresholds read from ${artifact} (default state)\n`);
  console.log('  width  content_px  em_threshold  this_face_ch  verdict');
  console.log('  ' + '-'.repeat(58));
  let fails = 0;
  const ppc = chromeCh(em * READING_FONT_SIZE_PX);
  for (const w of widths) {
    const ch = w.contentPx / ppc;
    const meets = em <= w.emThreshold;
    if (!meets) fails++;
    console.log(
      `  ${String(w.width).padEnd(6)} ${String(w.contentPx).padEnd(11)} ` +
      `${w.emThreshold.toFixed(4).padEnd(13)} ${ch.toFixed(2).padEnd(13)} ` +
      `${meets ? 'MEET' : 'FAIL'}` +
      (w.faceIndependent ? '' : '   (content_px face-DEPENDENT here — threshold unsafe)'),
    );
  }
  console.log(`\n  ${fails === 0
    ? "MEETS at all seven of D107's desktop widths."
    : `FAILS at ${fails} of 7.`}`);
  console.log(
    '\n  STALENESS, named rather than silently inherited:\n' +
    '  spd-w13-1280-prior-observations-stale records content_px at 1280 moving\n' +
    '  596 -> 640 on deployed bc64d869a (deterministic over three runs). If the\n' +
    '  artifact above still reads 596 at 1280, THAT ROW IS STALE and its real\n' +
    '  threshold is 640/990 = 0.6465, i.e. looser. Every other width matched the\n' +
    '  frozen prediction exactly, so the TIGHTEST row (700, 0.5727) is unaffected\n' +
    '  and the overall verdict turns on it.',
  );
}

// D145's published derivations. If this tool is right, it reproduces all three.
const SELF_TEST = [
  { face: 'Iowan Old Style Roman', em: 1139 / 2048, px: 10.0107, ch: 10.0 },
  { face: 'Georgia', em: 1257 / 2048, px: 11.047852, ch: 11.046875 },
  { face: 'Source Serif 4', em: 587 / 64 / 18, px: 9.171875, ch: 9.171875 },
];

function selfTest() {
  console.log("SELF-TEST — reproduce D145's three published derivations\n");
  let bad = 0;
  for (const t of SELF_TEST) {
    const px = t.em * READING_FONT_SIZE_PX;
    const ch = chromeCh(px);
    const okPx = Math.abs(px - t.px) < 0.0005;
    const okCh = Math.abs(ch - t.ch) < 1e-7;
    if (!okPx || !okCh) bad++;
    console.log(
      `  ${t.face.padEnd(24)} em=${t.em.toFixed(6)} px=${px.toFixed(6)} ` +
      `(want ${t.px}) ch=${ch.toFixed(6)} (want ${t.ch}) ${okPx && okCh ? 'OK' : 'MISMATCH'}`,
    );
  }
  console.log(bad === 0
    ? '\nself-test: PASS — the LayoutUnit model matches the charter on all three.'
    : `\nself-test: FAIL — ${bad} mismatch(es).`);
  return bad === 0;
}

// ── cli ─────────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2);

if (argv.includes('--help') || argv.length === 0) {
  console.log(`font-zero-advance.mjs — the '0' advance, read from the font binary.

  node scripts/font-zero-advance.mjs <font-file>...   metrics for every face in each file
  node scripts/font-zero-advance.mjs --self-test      reproduce D145's three derivations
  node scripts/font-zero-advance.mjs --verdict <em>   MEET/FAIL over D107's seven widths

THE OPEN GATE — spd-palatino-linotype-unmeasured. Palatino Linotype is second in
the shipped stack and wins on Windows; it is not on the measuring Mac and is not
freely licensable onto it. On any Windows box:

  node scripts/font-zero-advance.mjs "C:\\Windows\\Fonts\\pala.ttf"

and paste the Roman row. Then --verdict <em> settles the reading-width question
for Windows.`);
  process.exit(0);
}

if (argv.includes('--self-test')) process.exit(selfTest() ? 0 : 1);

const vIdx = argv.indexOf('--verdict');
if (vIdx >= 0) {
  const em = Number(argv[vIdx + 1]);
  if (!Number.isFinite(em) || em <= 0) {
    console.error('--verdict needs a positive em value, e.g. --verdict 0.5');
    process.exit(2);
  }
  printVerdict(em, `em ${em.toFixed(4)}`);
  process.exit(0);
}

let exit = 0;
for (const f of argv) {
  if (f.startsWith('--')) continue;
  let faces;
  try {
    faces = facesIn(f);
  } catch (e) {
    console.error(`ERROR ${f}: ${e.message}`);
    exit = 1;
    continue;
  }
  console.log(`\n${f}`);
  for (const face of faces) {
    if (face.em === null) {
      console.log(`  ${face.full.padEnd(30)} no '0' glyph in cmap — cannot derive`);
      continue;
    }
    console.log(
      `  ${face.full.padEnd(30)} upem=${String(face.unitsPerEm).padEnd(5)} ` +
      `zeroAdv=${String(face.zeroAdvance).padEnd(5)} em=${face.em.toFixed(4)} ` +
      `${READING_FONT_SIZE_PX}px=${face.pxAt18.toFixed(4)} chrome1ch=${face.chromeCh.toFixed(4)}` +
      (face.variable ? '  [VARIABLE — default instance]' : ''),
    );
  }
}
process.exit(exit);
