// design/check/part-h2.mjs — Part H2 of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { contrast } from "../derive.mjs";
import { repoRoot, tokens } from "../emit.mjs";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { fail, FAULT } from "./state.mjs";

// ── Part H2: WCAG contrast of the bp-graph Canvas palette, keyed ON THE COLOUR ─
// Part H above gates the Studio DOM. The bp-graph.js force-graph paints on a
// <canvas>: `ctx.fillStyle` cannot consume var(), so its palette is concrete
// bytes and NO CSS-level gate can ever see it — every node fill, edge stroke,
// focus ring and error colour could move with every gate green.
//
// THIS PART IS A RE-LAND, and the thing it re-lands differently is its KEY.
// The first version (#18162) keyed a pairing on the two NAMES it derived from,
// and the palette then moved house into design/tokens.json (#18109). Neither
// tree ever held both — they share no file, so git never conflicted and both
// were green — but on main together every colour derived TWICE, once under its
// renderer var and once under its token path. 46 failures covering NINETEEN
// distinct colour pairs; one hex appeared five times under five names. A name
// is not a colour. So:
//
//   THE KEY IS THE RESOLVED PAIR OF PAINTED COLOUR VALUES, `<ink>|<ground>`,
//   lowercased. Names are carried for the MESSAGE only. Moving a colour between
//   design/tokens.json and the renderer changes its names and changes nothing
//   here — which is also what makes an entry in KNOWN_SUB_AA below survive the
//   palette moving house, the property the first version lacked.
//
// The second thing it re-lands differently is WHAT VALUE IT MEASURES. A pairing
// that never reaches the screen is not a finding, it is noise that buys a
// waiver. 32 of those 46 were `typeHues` node fills scored at their RAW token
// value on the light ground — but `nodeFill()` paints `shiftL(hex, -0.22)` on
// light, never the raw hue, and the legend swatch mirrors that exact transform
// so the key cannot lie about the dot. Measured AS PAINTED all sixteen clear the
// non-text floor on both grounds (worst: project, 3.15 light / 11.97 dark). See
// the TYPE-HUE rule below for the in-scope argument.
//
// SCOPE DECISION — typeHues node fills ARE in scope, at WCAG 1.4.11's non-text
// floor of 3.0. Written down because it is most of this gate's surface and
// because letting the derivation decide it by accident is what produced 46
// blessings for 19 facts. 1.4.11 covers "Graphical Objects: parts of graphics
// required to understand the content"; a node dot IS the graphic, and the
// content is unreadable if the dot is invisible against the canvas. What is NOT
// in scope is hue-versus-hue separation: 1.4.11 asks for contrast against the
// adjacent colour, not for one node type to be distinguishable from another, and
// the type distinction is independently carried by the node label and by the
// legend the "Full color" toggle raises. So each hue is measured against its
// ground and never against a sibling hue.
//
// ADMITTED GAPS, stated rather than smoothed over:
//   - `isText` is NAME-keyed (label/tooltip/title/text/row) and therefore scores
//     SLATE and AMBER at the 3.0 non-text floor, though drawCenterMessage()
//     paints both as 14px text. Those two land on a translucent toast plate, not
//     on the canvas ground, so no pairing derived here is the one that would
//     need 4.5; raising them is a real question and belongs to its own row.
//   - Overlay chrome (the `chrome` subtree / CHROME_PALETTE) is EXCLUDED: it is
//     inline style on injected DOM sitting over a translucent glass panel, so
//     the canvas ground is not its ground and it has no single resolved ratio.
//   - Translucent inks are excluded for the same reason the first version
//     excluded them: rgba() over a ground has no one ratio.
//
// ┌─ ACCEPTED-EXPOSURE RECORD: green-apart/red-together (BEGIN) ───────────
// This row (task-4462bbaf17f63ec1) exists because #18162 and #18109 were each
// green on their own branch and red only once main held both. Its last criterion
// offers two answers and forbids blurring them. OPTION (b) IS CHOSEN: no
// standing guard against that class is in scope here, and the exposure goes on
// the record as ACCEPTED rather than quietly closed. The reason is mechanical,
// not a preference.
//
// A guard catches a class BEFORE main only if it can stop a merge. This file has
// exactly one CI venue: `node design/check.mjs` in .github/workflows/
// doc-gates.yml, and there is no second invocation anywhere in .github. That
// workflow publishes ONE check-run context, `Doc budgets + anchors`, and that
// context is not in the required set of .github/required-checks.json — it sits in
// that file's `exclusions` array as "S4 PATHS-FILTERED", and doc-gates.yml's own
// header says of its red, in those words, that "none of it stops a merge". So no
// code added to this file can catch anything before main. It can only make
// main's red louder and better named, which is a different and smaller promise.
//
// The mechanism that would actually catch the class is not a checker at all: it
// is re-evaluating a pull request's checks against the CURRENT tip before the
// merge lands — "require branches to be up to date", or a merge queue. Both are
// branch protection settings on the repository: owner-only, outside every lane
// fence, and outside this file. .github/required-checks.json records that this
// repo is user-owned with no merge queue today, so neither is switched on.
// Writing a checker here and calling it the remedy would put the fix in the one
// place that provably cannot deliver it, and would read afterwards as though the
// class had been guarded.
//
// What IS in scope, and is shipped above: the KEY. The collision produced 46
// blessings for 19 facts only because pairings were keyed on NAMES. They are
// keyed on the resolved `<ink>|<ground>` bytes now, so the same colour arriving
// under a second name from a second source is the SAME pair rather than a new
// failure. That removes this file's own contribution to the class. It does not
// guard the class, and this record exists so that nobody reads it as if it did.
//
// FINALLY, AND THIS IS WHAT KEEPS THE PARAGRAPH HONEST: none of the three facts
// above is restated from memory. Part H2 reads them back from their sources every
// run — the one invocation site in .github/workflows, this context's absence from
// the required set, and the strict flag — and reds if any has moved. Two of those
// checks fire when the repository gets BETTER, which is deliberate: an exposure
// that has quietly been guarded must stop being carried as accepted just as
// loudly as one whose reasoning rotted.
// └─ ACCEPTED-EXPOSURE RECORD: green-apart/red-together (END) ─────────────
console.log("\ndesign/check.mjs — Part H2: WCAG contrast of the bp-graph Canvas palette (keyed on the resolved colour)");
{
  // Part H2 counts its OWN failures. `failed` is a shared, sticky boolean, so
  // `failed === failedBeforeH2` goes true again the moment any EARLIER part has
  // tripped, and the ok line then prints beside this part's own FAILs. Part K
  // carries the same own-counter idiom and the same reason.
  let h2Failed = 0;
  const failH2 = (msg) => { h2Failed++; fail(msg); };
  // Set by the accepted-exposure record arm below, and printed on the ok line so
  // a reader can see that the arm RAN rather than inferring it from silence.
  let recordWords = 0;
  // Set by the premise arm below, on the same principle: an arm that ran must say
  // so on the ok line, so "the premise held" is never inferred from silence.
  let premiseNote = "premise NOT measured";

  const FAMILY = "color.graphCanvas";
  const GRAPH_JS = "web/public/bp-graph.js";
  // A moved or renamed renderer must reach a NAMED refusal, not an ENOENT stack
  // trace two parts away from the sentence that says what went wrong.
  let graphSrc = "";
  try { graphSrc = readFileSync(join(repoRoot, GRAPH_JS), "utf8"); }
  catch (e) { failH2(`  Part H2 FAIL: cannot read ${GRAPH_JS} (${e.code || e.message}) — the shipped renderer is one of this gate's two derivation sources; if it moved, update GRAPH_JS.`); }

  // ── the two sources, unioned. Neither alone is complete: the token family is
  // the authority on WHICH colours exist (add one and it is evaluated with no
  // edit here), and the renderer is the authority on WHEN each is painted.
  const entries = []; // { name, value, origin }
  const addColour = (name, value, origin) => {
    if (typeof value !== "string") return;
    const v = value.trim();
    if (!/^(#[0-9a-fA-F]{3,8}|rgba?\(|hsla?\()/.test(v)) return;
    entries.push({ name, value: v, origin });
  };
  // source 1 — every leaf colour under the token family, recursively.
  (function walk(node, path) {
    if (!node || typeof node !== "object") return;
    for (const [k, v] of Object.entries(node)) {
      if (k.startsWith("_")) continue; // _note and friends are prose, not colour
      const p = path ? `${path}.${k}` : k;
      if (v && typeof v === "object") walk(v, p);
      else addColour(p, v, FAMILY);
    }
  })(tokens?.color?.graphCanvas, "");
  const fromFamily = entries.length;

  // source 2 — the SHIPPED renderer, read live off disk (Part H's own idiom, so
  // reverting a fix reds this gate). Both `var NAME = "<colour>";` and the
  // `key: "<colour>"` members of the object literals inside the generated block
  // (TYPE_HEX, CHROME_PALETTE) — the first version read only the `var` form,
  // which is precisely why the per-type hues reached it from the token side
  // ONLY, with no renderer call site to bind their theme.
  const declLines = new Map(); // renderer identifier -> declaration line index
  const srcLines = graphSrc.split("\n");
  {
    let objPath = null, depth = 0;
    srcLines.forEach((line, i) => {
      const vm = line.match(/^\s*var\s+([A-Za-z_$][\w$]*)\s*=\s*"([^"]+)"\s*;/);
      if (vm) { declLines.set(vm[1], i); addColour(vm[1], vm[2], GRAPH_JS); return; }
      const om = line.match(/^\s*var\s+([A-Za-z_$][\w$]*)\s*=\s*\{\s*$/);
      if (om) { objPath = om[1]; depth = 1; declLines.set(om[1], i); return; }
      if (objPath === null) return;
      const pm = line.match(/^\s*"?([A-Za-z_$][\w$-]*)"?\s*:\s*"([^"]+)"\s*,?\s*$/);
      if (pm) { addColour(`${objPath}.${pm[1]}`, pm[2], GRAPH_JS); return; }
      const nm = line.match(/^\s*"?([A-Za-z_$][\w$-]*)"?\s*:\s*\{\s*$/);
      if (nm) { objPath = `${objPath}.${nm[1]}`; depth++; return; }
      if (/^\s*\}/.test(line)) { depth--; objPath = depth > 0 ? objPath.split(".").slice(0, depth).join(".") : null; }
    });
  }
  const fromRenderer = entries.length - fromFamily;

  // ── the paint model. Each rule is a PREDICATE over the name, never a list of
  // names, and the last rule is the conservative one: a colour nothing claims is
  // measured on BOTH grounds. That default is what keeps this gate able to fail
  // — narrowing the derivation until it goes quiet is the failure mode being
  // fixed here, not a fix.
  const shortName = (n) => n.split(".").pop();
  const isGround = (n) => /^(canvas|bg|BG)/.test(shortName(n)) || /^BG_/.test(shortName(n));
  const isChrome = (n) => /(^|\.)(chrome|CHROME_PALETTE)(\.|$)/.test(n);
  const isTypeHue = (n) => /(^|\.)(typeHues|TYPE_HEX)\./.test(n);
  // A SLOT is the one thing the two sources genuinely share. design/emit.mjs
  // writes the token path `graph.<k>` out as the renderer's SCREAMING_SNAKE var
  // and `graph.typeHues.<k>` into TYPE_HEX, so `graph.a11yRing` and `A11Y_RING`
  // are one slot under two spellings, while `graph.amber` and
  // `graph.typeHues.book` are two slots that happen to share #FBBF24. Paint
  // evidence pools per SLOT for exactly that reason: pooling per VALUE would let
  // the amber slot's theme binding silently delete the book hue's light pairing.
  // The slot is derivation-internal and fails SAFE — two spellings that fail to
  // unify fall through to the both-grounds default below and red loudly; it is
  // never the key anything is waived under.
  const slot = (n) => {
    const s = shortName(n).toLowerCase().replace(/_/g, "");
    return isTypeHue(n) ? `typehue:${s}` : isChrome(n) ? `chrome:${s}` : `root:${s}`;
  };
  const isText = (n) => /label|tooltip|title|text|row/i.test(shortName(n));
  const OPAQUE = (v) => /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(v);

  // theme evidence, strongest first.
  //  (a) the name says so: `…Light` / `…Dark`, `BG_LIGHT`, `LABEL_COLOR_DARK`.
  const nameTheme = (n) => { const s = shortName(n); return /light/i.test(s) ? "light" : /dark/i.test(s) ? "dark" : null; };
  //  (b) the SIBLING-PAIR convention this palette already runs on: bgDark/bgLight,
  //      monoDark/monoLight, labelDark/labelLight — a colour whose `<name>Light`
  //      sibling exists is the DARK member of a pair, because the renderer's job
  //      is to choose between them. This is the rule that keeps the gate honest
  //      across an a11y fix: while `accent` stands alone it is painted on both
  //      grounds and its light ratio is a real finding; the day an `accentLight`
  //      sibling lands beside it, the same rule retires that pairing with no edit
  //      here and no waiver ever written.
  const allSlots = new Set(entries.map((e) => slot(e.name)));
  const hasLightSibling = (n) => allSlots.has(`${slot(n)}light`);
  const hasDarkSibling = (n) => allSlots.has(`${slot(n)}dark`);
  //  (c) the renderer's own branch: an identifier used ONLY inside the dark (or
  //      only the light) arm of a `theme === "light" ? A : B` is painted only
  //      there. That is how NODE_WHITE is dark-only despite its name.
  const sourceTheme = (n) => {
    const decl = declLines.get(n);
    if (decl === undefined) return null;
    const word = new RegExp(`\\b${n.replace(/[$]/g, "\\$")}\\b`);
    let uses = 0, light = 0, dark = 0;
    srcLines.forEach((line, i) => {
      if (i === decl || !word.test(line)) return;
      uses++;
      const t = line.match(/theme\s*===\s*"light"\s*\?([^:]*):(.*)$/);
      if (!t) return;
      if (word.test(t[1])) light++;
      else if (word.test(t[2])) dark++;
    });
    if (uses === 0) return null;
    if (light === uses && dark === 0) return "light";
    if (dark === uses && light === 0) return "dark";
    return null;
  };
  const definiteTheme = (n) =>
    nameTheme(n) || (hasLightSibling(n) ? "dark" : hasDarkSibling(n) ? "light" : null) || sourceTheme(n);

  // ── grounds, deduplicated ON THE VALUE. `canvas` and `bgDark` are the same
  // #16161a under two names; one ground, once. A ground's theme is read off its
  // own luminance, not its name — a ground nearer black IS the dark ground.
  const groundByTheme = new Map();
  for (const e of entries) {
    if (!isGround(e.name) || !OPAQUE(e.value) || isChrome(e.name)) continue;
    const theme = contrast(e.value, "#000000") > contrast(e.value, "#ffffff") ? "light" : "dark";
    const g = groundByTheme.get(theme);
    if (!g) groundByTheme.set(theme, { value: e.value.toLowerCase(), names: new Set([e.name]) });
    else if (g.value === e.value.toLowerCase()) g.names.add(e.name);
    else failH2(`  Part H2 FAIL: two different ${theme} grounds — ${[...g.names][0]} is ${g.value} but ${e.name} is ${e.value}; the canvas has one ground per theme, so one of these is not a ground or the palette has drifted.`);
  }

  // ── theme evidence is pooled PER SLOT, not per name. `NODE_WHITE` proves
  // #f2f3f8 is dark-only; the token path `graph.nodeWhite` carries the same
  // bytes and simply cannot say. A name that is SILENT is not evidence of
  // "both" — otherwise the token-side copy of every colour re-fabricates on the
  // light ground exactly the pairings the renderer-side copy just ruled out.
  // Only INK names vote. A ground is not an ink: #16161a is both the dark
  // canvas and the light tooltip's title colour, and letting the ground's own
  // "dark" reach the ink pool would pair that title against itself.
  const themesBySlot = new Map();
  for (const e of entries) {
    if (isGround(e.name) || isChrome(e.name)) continue;
    const t = definiteTheme(e.name);
    if (!t) continue;
    const k = slot(e.name);
    if (!themesBySlot.has(k)) themesBySlot.set(k, new Set());
    themesBySlot.get(k).add(t);
  }
  const themesOf = (name) => {
    const s = themesBySlot.get(slot(name));
    return s && s.size ? [...s] : ["light", "dark"];
  };

  // ── what the renderer actually PAINTS for a given ink in a given theme.
  // The per-type hues are the one transformed family: nodeFill() paints
  // `theme === "light" ? shiftL(hex, -0.22) : hex`, and the legend swatch
  // repeats that transform so the key matches the dot. Scoring the raw hue on
  // the light ground measures a colour that never reaches the screen.
  const hexToRgb = (h) => { let s = h.replace("#", ""); if (s.length === 3) s = s.split("").map((c) => c + c).join(""); return [parseInt(s.slice(0, 2), 16), parseInt(s.slice(2, 4), 16), parseInt(s.slice(4, 6), 16)]; };
  const rgbToHex = (r, g, b) => "#" + [r, g, b].map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, "0")).join("");
  // HSL lightness shift — a byte-for-byte port of shiftL() in bp-graph.js. It is
  // duplicated rather than imported because the renderer is a browser artifact
  // with no module surface; Part A's emit fence keeps the PALETTE in lockstep,
  // and this function's own fixture below keeps THIS copy honest.
  const shiftL = (hex, dl) => {
    const [R, G, B] = hexToRgb(hex).map((v) => v / 255);
    const max = Math.max(R, G, B), min = Math.min(R, G, B);
    let l = (max + min) / 2, h = 0, s = 0;
    if (max !== min) {
      const d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      if (max === R) h = (G - B) / d + (G < B ? 6 : 0);
      else if (max === G) h = (B - R) / d + 2;
      else h = (R - G) / d + 4;
      h /= 6;
    }
    l = Math.max(0, Math.min(1, l + dl));
    const hue2rgb = (p, q, t) => { if (t < 0) t += 1; if (t > 1) t -= 1; if (t < 1 / 6) return p + (q - p) * 6 * t; if (t < 1 / 2) return q; if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6; return p; };
    if (s === 0) return rgbToHex(l * 255, l * 255, l * 255);
    const q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
    return rgbToHex(hue2rgb(p, q, h + 1 / 3) * 255, hue2rgb(p, q, h) * 255, hue2rgb(p, q, h - 1 / 3) * 255);
  };
  // Fixture for the port above: a hand-checked value from the renderer's own
  // transform. If this drifts, every typeHue verdict below is measuring a colour
  // bp-graph.js does not paint, so it refuses rather than reports.
  if (shiftL("#A3E635", -0.22) !== "#669813")
    failH2(`  Part H2 FAIL: the shiftL() port disagrees with its fixture — shiftL("#A3E635", -0.22) gave ${shiftL("#A3E635", -0.22)}, expected #669813 (bp-graph.js nodeFill()'s light-ground transform). Every per-type hue verdict rests on this; REFUSING rather than reporting.`);
  const paintedValue = (name, value, theme) => (isTypeHue(name) && theme === "light" ? shiftL(value, -0.22) : value);

  // ── Known sub-AA pairings. AUTHORED EMPTY, and the key it would take is the
  // resolved pair `"<ink>|<ground>"` — two colours, no variable name, no file:
  // the only key that survives the palette moving house. It is empty because on
  // a tree carrying the graph a11y fix nothing here is sub-AA; a pairing that IS
  // sub-AA is a defect to fix, and an entry added to buy a green is the stale
  // exemption this part exists to prevent. The table reds in BOTH directions —
  // an unlisted failure reds, and an entry whose pairing has risen to AA or no
  // longer exists reds as stale, so it cannot outlive its subject.
  const KNOWN_SUB_AA = {};
  const seenKnown = new Set();

  const AA_GRAPH = { text: 4.5, nontext: 3.0 };
  // One record per RESOLVED pair. Names accumulate into it for the message; the
  // strictest need any contributor implies governs. Nineteen facts read as
  // nineteen however many names carry them.
  const pairs = new Map();
  let inkNames = 0, translucent = 0, chromeSkipped = 0;
  for (const e of entries) {
    if (isGround(e.name)) continue;
    if (isChrome(e.name)) { chromeSkipped++; continue; }
    if (!OPAQUE(e.value)) { translucent++; continue; }
    inkNames++;
    for (const theme of themesOf(e.name)) {
      const ground = groundByTheme.get(theme);
      if (!ground) continue;
      const ink = paintedValue(e.name, e.value, theme).toLowerCase();
      const id = `${ink}|${ground.value}`;
      let rec = pairs.get(id);
      if (!rec) { rec = { ink, ground: ground.value, theme, names: new Set(), need: AA_GRAPH.nontext }; pairs.set(id, rec); }
      rec.names.add(e.name);
      if (isText(e.name)) rec.need = AA_GRAPH.text;
    }
  }

  for (const [id, rec] of pairs) {
    let ratio;
    try { ratio = contrast(rec.ink, rec.ground); }
    catch (err) { failH2(`  Part H2 FAIL: ${id} — contrast() threw (${err.message})`); continue; }
    const known = Object.prototype.hasOwnProperty.call(KNOWN_SUB_AA, id);
    if (known) seenKnown.add(id);
    const who = [...rec.names].sort().join(", ");
    if (ratio < rec.need - 1e-9) {
      if (known) console.log(`  known ${id} = ${ratio.toFixed(2)} < ${rec.need} — ${KNOWN_SUB_AA[id]}`);
      else failH2(`  Part H2 FAIL: ${id} (${rec.theme} ground, ${rec.need === AA_GRAPH.text ? "text" : "nontext"}) = ${ratio.toFixed(2)} < ${rec.need} — painted by ${who}; raise the value in ${FAMILY} / ${GRAPH_JS}, or give it a per-theme sibling, or justify the PAIR in KNOWN_SUB_AA`);
    } else if (known) {
      failH2(`  Part H2 FAIL: ${id} = ${ratio.toFixed(2)} ≥ ${rec.need} but is still listed in KNOWN_SUB_AA — the defect is FIXED, delete the entry (a stale exemption hides the next regression)`);
    }
  }
  for (const id of Object.keys(KNOWN_SUB_AA))
    if (!seenKnown.has(id)) failH2(`  Part H2 FAIL: KNOWN_SUB_AA lists ${id}, which the derivation never produced — the exemption names a pair nothing paints; delete it`);

  // ── the refusals. A guard that resolves nothing is theatre, not a pass, and a
  // derivation that quietly narrowed to zero looks exactly like a clean tree.
  if (pairs.size === 0)
    failH2(`  Part H2 FAIL: REFUSING — derived ZERO pairings from ${FAMILY} (${fromFamily} names) ∪ ${GRAPH_JS} (${fromRenderer} names). An empty read is a broken derivation, never a pass.`);
  if (fromFamily === 0) failH2(`  Part H2 FAIL: REFUSING — the token family ${FAMILY} yielded no colours; the family was renamed, emptied, or moved.`);
  if (fromRenderer === 0) failH2(`  Part H2 FAIL: REFUSING — ${GRAPH_JS} yielded no colours; the generated palette block was renamed, emptied, or moved.`);
  if (groundByTheme.size < 2) failH2(`  Part H2 FAIL: REFUSING — grounds cover only [${[...groundByTheme.keys()].join(", ")}]; both light and dark must resolve or half the palette is unevaluated.`);
  // The floor that catches a derivation narrowing without going empty: every
  // per-type hue must produce a pairing on BOTH grounds, and the token family
  // declares how many there are. A regex that stops matching TYPE_HEX, or a
  // theme rule that over-binds, drops this below the count and reds here rather
  // than presenting as a quieter green.
  const hueNames = new Set(entries.filter((e) => isTypeHue(e.name) && OPAQUE(e.value)).map((e) => e.name));
  const hueValues = new Set(entries.filter((e) => isTypeHue(e.name) && OPAQUE(e.value)).map((e) => e.value.toLowerCase()));
  const huePairs = [...pairs.values()].filter((r) => [...r.names].some(isTypeHue));
  if (hueNames.size < 2)
    failH2(`  Part H2 FAIL: REFUSING — ${hueNames.size} per-type hue name(s) matched; the "Full color" node fills are most of this gate's surface and cannot be one colour.`);
  if (huePairs.length < hueValues.size * 2)
    failH2(`  Part H2 FAIL: REFUSING — ${hueValues.size} distinct per-type hues produced only ${huePairs.length} pairings, not the ${hueValues.size * 2} a both-grounds evaluation owes. A hue bound to one theme is a derivation that narrowed, which is how a gate goes quiet without going empty.`);


  // ── the accepted-exposure record, ENFORCED rather than trusted ────────────
  // A written finding does not fire by itself. The record above the part header
  // is the WHOLE of this row's answer to the green-apart/red-together class, and
  // a comment block is deletable by anyone editing this file for an unrelated
  // reason — which is exactly how an ACCEPTED exposure turns back into a SILENT
  // one, with nothing anywhere reporting the change. So Part H2 reads its own
  // source and refuses to pass without it. This arm guards the RECORD, not the
  // class; the record itself says why no guard on the class is landable here.
  {
    const MARK = "ACCEPTED-EXPOSURE RECORD: green-apart/red-together";
    const SELF = fileURLToPath(import.meta.url);
    let selfSrc = null;
    try { selfSrc = readFileSync(SELF, "utf8"); }
    catch (err) { failH2(`  Part H2 FAIL: cannot read own source ${SELF} (${err.code || err.message}) — the accepted-exposure record is verified by reading this file, so an unreadable self is a REFUSAL, never a pass.`); }
    if (selfSrc !== null) {
      const srcLines = selfSrc.split("\n");
      const isComment = (l) => l.trim().startsWith("//");
      // Markers are matched only on COMMENT lines, so the literals in this arm
      // (which necessarily spell the same words) can never be mistaken for the
      // block they delimit.
      const markerAt = (tag) => srcLines.flatMap((l, i) => (isComment(l) && l.includes(`${MARK} (${tag})`) ? [i] : []));
      const begins = markerAt("BEGIN"), ends = markerAt("END");
      if (begins.length !== 1 || ends.length !== 1 || ends[0] <= begins[0] + 1) {
        failH2(`  Part H2 FAIL: the accepted-exposure record is missing or unbalanced — ${begins.length} BEGIN and ${ends.length} END comment marker(s) for "${MARK}" in ${SELF}, needing exactly one of each with prose between them. Criterion c4 of task-4462bbaf17f63ec1 chose option (b), a WRITTEN statement, so the statement IS the deliverable: restore it rather than deleting this arm.`);
      } else {
        const body = srcLines.slice(begins[0] + 1, ends[0]);
        const stray = body.filter((l) => l.trim() !== "" && !isComment(l));
        if (stray.length)
          failH2(`  Part H2 FAIL: the accepted-exposure record holds ${stray.length} non-comment line(s) — the block is prose only, so code inside it means the markers have drifted onto something they do not delimit.`);
        const prose = body.map((l) => l.trim().replace(/^\/\/ ?/, "")).join(" ").replace(/\s+/g, " ").trim();
        const words = prose.split(" ").filter(Boolean).length;
        const MIN_WORDS = 120;
        if (words < MIN_WORDS)
          failH2(`  Part H2 FAIL: the accepted-exposure record is ${words} words, under the ${MIN_WORDS}-word floor — an exposure accepted in one sentence is not on the record, it is waved through. Restore the reasoning, or re-open the criterion.`);
        // Each phrase carries one load-bearing half of the statement: WHICH
        // option was taken, WHAT is being accepted, WHY no venue reachable from
        // this file can catch the class, WHERE the real remedy lives, and WHICH
        // row owns the decision. Lose one and the record stops saying the thing
        // it was stamped for while still looking like a paragraph.
        const REQUIRED = ["OPTION (b) IS CHOSEN", "no standing guard", "Doc budgets + anchors", "required-checks.json", "branch protection", "task-4462bbaf17f63ec1"];
        const missing = REQUIRED.filter((phrase) => !prose.includes(phrase));
        if (missing.length)
          failH2(`  Part H2 FAIL: the accepted-exposure record no longer states ${missing.map((m) => JSON.stringify(m)).join(", ")} — each names one load-bearing half of the decision (which option, what is accepted, why no venue here can catch it, where the remedy lives, which row owns it), so a record that has lost one has stopped saying what it was stamped for.`);
        recordWords = words;
      }
    }
  }

  // ── the record's PREMISE, read from the repo instead of restated ──────────
  // The arm above proves the record is PRESENT and still SAYS its five load-
  // bearing things. It cannot tell whether any of them is still TRUE. That gap is
  // the whole risk of an option-(b) answer: the record is not a preference, it is
  // a DERIVATION from three facts about this repository, and if any of them
  // changes the record keeps reading like a reasoned decision while having become
  // a false sentence committed to main. The assertion is where people stop
  // looking, so the three facts are checked here, at their sources:
  //
  //   1. VENUE. `node design/check.mjs` is invoked from exactly one workflow.
  //      A second invocation — especially from a workflow that publishes a
  //      REQUIRED context — is precisely the venue the record says does not
  //      exist, and code added to this file would then be able to stop a merge.
  //   2. AUTHORITY. That workflow's context is not in branch protection's
  //      required set, and is still carried in required-checks.json's own
  //      `exclusions`.
  //   3. THE REAL REMEDY. `required_status_checks.strict` is false — that flag IS
  //      "require branches to be up to date before merging", the mechanism the
  //      record names as the thing that would actually catch the class.
  //
  // Note the direction: 2 and 3 red when the world gets BETTER. That is intended.
  // A ratchet has two failure directions, and an exposure that has quietly BEEN
  // guarded must stop being carried as accepted just as loudly as one whose
  // reasoning rotted. Every message below says which way it went.
  {
    const REQ_PATH = ".github/required-checks.json";
    const WF_DIR = ".github/workflows";
    const CTX = "Doc budgets + anchors";
    const HOME_WF = "doc-gates.yml";
    // `node design/check.mjs` on a real command line, never in a YAML comment and
    // never inside the `paths:` list that merely NAMES the file.
    const INVOKES = /(?:^|[\s;&|(])node\s+design\/check\.mjs(?![\w./-])/;

    let wfFiles = null;
    try { wfFiles = readdirSync(join(repoRoot, WF_DIR)).filter((n) => /\.ya?ml$/.test(n)).sort(); }
    catch (err) { failH2(`  Part H2 FAIL: cannot read ${WF_DIR} (${err.code || err.message}) — the accepted-exposure record's first premise is "this file has exactly one CI venue", and an unreadable workflow directory means that premise is UNMEASURED, which is a REFUSAL rather than a pass.`); }

    let venues = null;
    if (wfFiles !== null) {
      if (wfFiles.length === 0) {
        failH2(`  Part H2 FAIL: REFUSING — ${WF_DIR} lists ZERO workflow files. An empty read is a broken derivation, never a pass: it would report "one venue" as "no second venue" and the premise check would measure nothing.`);
      } else {
        venues = [];
        for (const n of wfFiles) {
          let src = null;
          try { src = readFileSync(join(repoRoot, WF_DIR, n), "utf8"); }
          catch (err) { failH2(`  Part H2 FAIL: cannot read ${WF_DIR}/${n} (${err.code || err.message}) — one unreadable workflow is one unsearched venue, so the "exactly one CI venue" premise cannot be answered from ${wfFiles.length - 1} of ${wfFiles.length} files.`); continue; }
          if (src.split("\n").some((l) => !/^\s*#/.test(l) && INVOKES.test(l))) venues.push(n);
        }
        if (venues.length === 0) {
          failH2(`  Part H2 FAIL: REFUSING — no workflow in ${WF_DIR} (${wfFiles.length} file(s)) invokes \`node design/check.mjs\` at all. Either this gate stopped running in CI, or the invocation was reworded past ${INVOKES} — both leave the venue premise unmeasurable, and "zero venues" must never read as "one venue".`);
        } else if (venues.length !== 1 || venues[0] !== HOME_WF) {
          failH2(`  Part H2 FAIL: the accepted-exposure record's VENUE premise no longer holds — \`node design/check.mjs\` is invoked from [${venues.join(", ")}], not from ${HOME_WF} alone. The record (option (b)) rests on this file having exactly one CI venue, publishing one non-required context; a second venue may be able to stop a merge, in which case a standing guard here IS landable and criterion c4 of task-4462bbaf17f63ec1 must be re-opened and re-answered as (a).`);
        } else {
          let home = null;
          try { home = readFileSync(join(repoRoot, WF_DIR, HOME_WF), "utf8"); } catch { /* unreachable: read above succeeded */ }
          if (home !== null && !home.includes(`name: ${CTX}`)) {
            failH2(`  Part H2 FAIL: ${WF_DIR}/${HOME_WF} no longer declares \`name: ${CTX}\` — the record names that exact context as the one thing this file's venue publishes, and required-checks.json is keyed on the same string. A renamed job silently detaches the record's authority premise from the check it is about; re-point both, or re-open c4.`);
          }
        }
      }
    }

    let req = null;
    try { req = JSON.parse(readFileSync(join(repoRoot, REQ_PATH), "utf8")); }
    catch (err) { failH2(`  Part H2 FAIL: cannot read or parse ${REQ_PATH} (${err.code || err.message}) — the record cites this file BY NAME for both its authority premise and its "no merge queue, no strict" remedy premise. Unreadable means UNMEASURED, which is a refusal.`); }

    let strict = null, requiredNames = null;
    if (req !== null) {
      const checks = req?.protection?.required_status_checks?.checks;
      if (!Array.isArray(checks) || checks.length === 0) {
        failH2(`  Part H2 FAIL: REFUSING — ${REQ_PATH} has no non-empty protection.required_status_checks.checks array (got ${JSON.stringify(checks)}). An empty or missing required set would make "${CTX} is not required" true VACUOUSLY, which is the shape of a premise check that has stopped measuring.`);
      } else {
        requiredNames = checks.map((c) => c?.context);
        if (requiredNames.includes(CTX)) {
          failH2(`  Part H2 FAIL: the accepted-exposure record's AUTHORITY premise has FLIPPED — "${CTX}" is now in ${REQ_PATH}'s required set [${requiredNames.join(", ")}]. This is the world getting BETTER: a red from this file can now stop a merge, so a standing guard against the green-apart/red-together class IS landable here and option (b) is no longer the honest answer. Re-open criterion c4 of task-4462bbaf17f63ec1 and answer it as (a); do not restore the old setting to quiet this line.`);
        }
      }
      const excl = req?.exclusions;
      if (!Array.isArray(excl) || excl.length === 0) {
        failH2(`  Part H2 FAIL: REFUSING — ${REQ_PATH} has no non-empty \`exclusions\` array (got ${Array.isArray(excl) ? "[]" : JSON.stringify(excl)}); the record quotes that array's reason for "${CTX}" verbatim, so its absence leaves the citation unverifiable rather than false.`);
      } else if (!excl.some((e) => e?.context === CTX)) {
        failH2(`  Part H2 FAIL: ${REQ_PATH} no longer carries "${CTX}" in \`exclusions\` (${excl.length} row(s): ${excl.map((e) => e?.context).filter(Boolean).slice(0, 6).join(", ")}…). The record cites that row as the reason this file's context holds no merge authority; with the row gone the citation points at nothing, whichever way the underlying fact went. Re-ground the record or re-open c4.`);
      }
      strict = req?.protection?.required_status_checks?.strict;
      if (strict !== false) {
        failH2(`  Part H2 FAIL: the accepted-exposure record's REMEDY premise has FLIPPED — ${REQ_PATH} now records protection.required_status_checks.strict = ${JSON.stringify(strict)}, not false. That flag IS "require branches to be up to date before merging", which the record names as the mechanism that would actually catch this class. If it is on, the class is guarded at the repository and the record must stop claiming it is accepted-and-unguarded. Re-open criterion c4 of task-4462bbaf17f63ec1; this is a BETTER world, not a regression to revert.`);
      }
    }

    if (venues !== null && requiredNames !== null && strict === false) {
      premiseNote = `premise live-checked (1 venue ${venues.join("")} of ${wfFiles.length} workflow(s), "${CTX}" absent from the ${requiredNames.length} required context(s), strict=false)`;
    }
  }

  // The one hook this part lacked until task-e33b3fc1a5fc921b. It goes through
  // failH2, not the shared fail(), so the injected failure is counted by the
  // SAME counter the ok line below is gated on — a hook that bypassed h2Failed
  // would red the gate and still print this part's ok, which is precisely the
  // false-reassurance shape --selftest exists to catch.
  if (FAULT.has("H2")) failH2("  Part H2 FAIL: injected fault (--selftest)");

  if (h2Failed === 0)
    console.log(`  ok   ${pairs.size} distinct colour pairs (keyed on the resolved ink|ground, from ${inkNames} ink names × ${groundByTheme.size} grounds; ${translucent} translucent and ${chromeSkipped} overlay-chrome names out of scope) derived from ${FAMILY} (${fromFamily}) ∪ ${GRAPH_JS} (${fromRenderer}), all ≥ AA (text 4.5 / nontext 3.0), ${Object.keys(KNOWN_SUB_AA).length} waived; accepted-exposure record present and intact (${recordWords} words, option (b), ${premiseNote})`);
}
