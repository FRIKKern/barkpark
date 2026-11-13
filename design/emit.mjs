#!/usr/bin/env node
// design/emit.mjs — the W1.2 emitter. design/tokens.json is the ONE source of the
// Barkpark Unified Aesthetic; this regenerates EVERY per-surface artifact from it.
// Dependency-free (Node built-ins only), deterministic output. Trusts
// design/validate.mjs to have proven the source well-formed.
//
//   node design/emit.mjs            # default: report drift, write nothing (== --check)
//   node design/emit.mjs --check    # same as default
//   node design/emit.mjs --write    # rewrite every artifact in place
//   node design/emit.mjs --write --force   # rewrite even where content is UNATTRIBUTED
//   node design/emit.mjs --adopt    # bless what is on disk as generated; write nothing
//
// THE WRITE FENCE (charter D21). `--write` used to replace a generated region
// unconditionally, so any hand-written line a developer had put INSIDE the marker
// vanished with no diff, no warning, and no log line naming it — and check.mjs
// then printed a clean PASS, because it compares build() against a file build()
// had just written (a tautology: `current` IS `expected` by construction). That is
// not hypothetical: commit 1d928b3bf deleted 33 hand-written `.bp-lc-*` rules this
// way. The fix lives HERE, at the point of loss, because evaluate() already knows
// `current` and `expected` in the same pass and therefore already knows the delta
// BEFORE writeFileSync — it costs zero new I/O and no external dependency.
//
// The missing ingredient is MEMORY: nothing on disk records what the emitter last
// produced, so a region full of hand-written CSS is indistinguishable from a
// region that is merely stale. design/emit-manifest.json supplies it (the
// side-channel-attribution pattern design/status-manifest.json already
// establishes next door): one SHA-256 per artifact over the GENERATED REGION ONLY,
// rewritten by every successful --write. A region whose digest matches is
// attributable to a prior generation and is safe to replace; a region whose digest
// does not match holds bytes this emitter never wrote, and replacing it destroys
// them. The fence refuses that write, names every line it would have deleted, and
// exits non-zero. `--force` performs it anyway, `--adopt` re-blesses the tree.
//
// THE LEDGER KEY IS `<path>#<artifact name>`, NOT the path alone. One file may
// carry TWO generated regions (the registry below explicitly invites it via
// markerBegin/markerEnd — the cloud SPA's app.js is the first case), and a ledger
// keyed by path alone gives both regions ONE slot: last write wins, the loser
// reads "unattributed" forever, check.mjs reds permanently and --write refuses
// all-or-nothing. The chosen shape is the flat composite `${path}#${name}` (over a
// nested {path: {name: digest}}) because it keeps the manifest one sorted level
// deep — greppable, and a stale entry is one visibly deleted line. The artifact
// `name` is the same string the CLI prints, so a manifest line names the surface a
// refusal names. A unit with NO name (check.mjs' Part I synthetic fixtures, which
// exercise attribute() on invented paths) keys by the bare path.
//
// CSS surfaces are spliced into a BEGIN/END GENERATED: tokens marker block that
// must already exist (mirrors the status-tones precedent). Go surfaces are whole
// generated *_gen.go files. check.mjs imports the builders here for the drift gate
// and the §6 cross-surface parity assertion.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { evaluateMirror } from "./paper-editor-mirror.mjs";
import { ASSET_MANIFEST, assembleAsset, validateFragmentSizes } from "../api/assets/paper-editor/scripts/source-assets.mjs";
import "./derive.mjs"; // loaded here, before the modules below, as before the split
import { repoRoot } from "./emit/source.mjs";
import { ACTION_LABELS_MARKER_BEGIN, ACTION_LABELS_MARKER_END, BP_THEMES_MARKER_BEGIN, BP_THEMES_MARKER_END, GRAPH_PALETTE_MARKER_BEGIN, GRAPH_PALETTE_MARKER_END, MARKER_BEGIN, MARKER_END } from "./emit/vocab.mjs";
import { cloudBlock, styleguideSwatches } from "./emit/cloud.mjs";
import { paperBlock } from "./emit/paper.mjs";
import { studioBlock } from "./emit/studio.mjs";
import { TEMPLATE_TOKENS_MARKER_BEGIN, TEMPLATE_TOKENS_MARKER_END, webBlock, webTokensTs } from "./emit/web.mjs";
import { mobileStatusVocabTs, reactStatusVocabTs, webStatusLadderTs } from "./emit/status-vocab.mjs";
import { taskboardGo } from "./emit/go-board.mjs";
import { pdrenderGo } from "./emit/go-pdrender.mjs";
import { cliChromeGo, semroleGo } from "./emit/go-semrole.mjs";
import { elixirTokensGen, studioTokensGen } from "./emit/elixir.mjs";
import { errorPageBlock, sessionAuthBlock, sheetsBlock, statusChromeBlock } from "./emit/pages.mjs";
import { bulldocsBlock } from "./emit/bulldocs.mjs";
import { bpThemesList, graphPaletteBlock } from "./emit/graph.mjs";
import { auditActionLabels } from "./emit/audit.mjs";
import { attribute, lostLines, MANIFEST_PATH, readManifest, regionDigest, regionKey, writeManifest } from "./emit/fence.mjs";

// The emitter's code lives in design/emit/, one module per concern, in the order
// it had in this file. This file keeps the artifact registry, the --check/--write/
// --adopt run and the CLI switch, and re-exports every public name, so every
// importer of design/emit.mjs keeps working unchanged.
export { loadThemes, rawTokens, repoRoot, statusManifest, themeBlocks, themePalette, THEMES_DIR, tokens } from "./emit/source.mjs";
export { AIR_ROW_SPLIT, AIR_STEPS, airRows, BASE_ROLES, CALLOUT_TONES, EVIDENCE_KEYS, EVIDENCE_UNITS, glyphOf, GRAPH_PALETTE_PATHS, hslToHex, INST_ORDER, INST_ROLE_CSS, instRoleChannels, LADDER_REFUSE, LIFE_ORDER, MOTION_STEPS, MOTION_SURFACES, motionVarLines, PAPER_ROLES, PROVIDERS, READING_STEPS, RULE_HEAVY_PX, RULE_KEYS, RULE_UNITS, ruleGlyph, SECTION_KEYS, SECTION_UNITS, STATUS_ROLES, TYPE_STEPS, typeLadderFrom } from "./emit/vocab.mjs";
export { CC_ROLES } from "./emit/cloud.mjs";
export { TEMPLATE_TOKENS_MARKER_BEGIN, TEMPLATE_TOKENS_MARKER_END } from "./emit/web.mjs";
export { MOBILE_OVERRIDE_SURFACE, mobileGlyphFor, mobileStatusOverrides, mobileStatusVocabTs, reactStatusVocabTs, webStatusLadderTs } from "./emit/status-vocab.mjs";
export { bpThemesList, graphPaletteBlock } from "./emit/graph.mjs";
export { AUDIT_ACTIONS_PATH, auditActionLabels, auditActions } from "./emit/audit.mjs";
export { attribute, lostLines, MANIFEST_PATH, readManifest, regionDigest, regionKey, writeManifest } from "./emit/fence.mjs";

// The raw surface sink sync-barkpark owns. Named here because a bare design tree may not hold that script.
const RAW_SURFACE_SINK = "api/assets/paper-surface/paper-surface.css";

// ── artifact registry ────────────────────────────────────────────────────────
// kind "css"             : splice content between a marker block. The shared
//                          BEGIN/END GENERATED: tokens marker by default; an
//                          artifact may override with markerBegin/markerEnd to
//                          own a DISTINCT marker in a file that also carries the
//                          tokens block elsewhere (the cloud SPA's app.js).
// kind "go"/"ts"/"elixir": the build() is the WHOLE file.
export const ARTIFACTS = [
  { name: "cloud SPA", path: "cloud/priv/static/app.css", kind: "css", build: cloudBlock },
  { name: "cloud SPA theme ids", path: "cloud/priv/static/app.js", kind: "css",
    markerBegin: BP_THEMES_MARKER_BEGIN, markerEnd: BP_THEMES_MARKER_END, build: bpThemesList },
  { name: "cloud SPA audit action labels", path: "cloud/priv/static/app.js", kind: "css",
    markerBegin: ACTION_LABELS_MARKER_BEGIN, markerEnd: ACTION_LABELS_MARKER_END, build: auditActionLabels },
  { name: "paper-surface", path: "api/assets/paper-editor/src/paper-surface/01-components-generated-theme.css", kind: "css", build: paperBlock },
  { name: "Studio", path: "api/lib/barkpark_web/layouts/root.html.heex", kind: "css", build: studioBlock },
  { name: "/papers reader skin", path: "api/lib/barkpark_web/layouts/bulldocs.html.heex", kind: "css", build: bulldocsBlock },
  { name: "web demo", path: "web/app/globals.css", kind: "css", build: webBlock },
  { name: "web TS tokens", path: "web/lib/tokens.gen.ts", kind: "ts", build: webTokensTs },
  { name: "react status vocabulary", path: "js/packages/react/src/status-vocab.gen.ts", kind: "ts", build: reactStatusVocabTs },
  { name: "web status ladder", path: "web/lib/status-ladder.gen.ts", kind: "ts", build: webStatusLadderTs },
  { name: "mobile status vocabulary", path: "apps/mobile/src/papers/portabledoc/blocks/status-vocab.gen.ts",
    kind: "ts", build: mobileStatusVocabTs },
  { name: "Go board", path: "internal/taskboard/tokens_gen.go", kind: "go", build: taskboardGo },
  { name: "Go pdrender", path: "internal/pdrender/tokens_gen.go", kind: "go", build: pdrenderGo },
  { name: "Go semrole", path: "internal/semrole/tokens_gen.go", kind: "go", build: semroleGo },
  { name: "Go CLI chrome", path: "internal/semrole/chrome_gen.go", kind: "go", build: cliChromeGo },
  { name: "Elixir render tokens", path: "api/lib/barkpark/portable_doc/render/tokens_gen.ex", kind: "elixir", build: elixirTokensGen },
  { name: "Elixir Studio categorical tokens", path: "api/lib/barkpark_web/studio/tokens_gen.ex", kind: "elixir", build: studioTokensGen },
  { name: "login (session_html)", path: "api/lib/barkpark_web/controllers/session_html.ex", kind: "css", build: sessionAuthBlock },
  { name: "error page (error_html)", path: "api/lib/barkpark_web/controllers/error_html.ex", kind: "css", build: errorPageBlock },
  { name: "studio refusal page (studio_refusal_html)", path: "api/lib/barkpark_web/plugs/studio_refusal_html.ex", kind: "css", build: errorPageBlock },
  { name: "status page chrome", path: "api/lib/barkpark_web/controllers/status_controller.ex", kind: "css", build: statusChromeBlock },
  { name: "/sheets reader", path: "api/lib/barkpark_web/layouts/sheets.html.heex", kind: "css", build: sheetsBlock },
  { name: "living styleguide swatches", path: "cloud/priv/static/styleguide.html", kind: "html", build: styleguideSwatches },
  { name: "search-starter theme tokens", path: "templates/search-starter/app/globals.css", kind: "css",
    markerBegin: TEMPLATE_TOKENS_MARKER_BEGIN, markerEnd: TEMPLATE_TOKENS_MARKER_END, build: webBlock },
  { name: "astro-search-starter theme tokens", path: "templates/astro-search-starter/src/styles/globals.css", kind: "css",
    markerBegin: TEMPLATE_TOKENS_MARKER_BEGIN, markerEnd: TEMPLATE_TOKENS_MARKER_END, build: webBlock },
  { name: "bp-graph palette (1/4)", path: "api/priv/static/assets/bp-graph.js", kind: "css",
    markerBegin: GRAPH_PALETTE_MARKER_BEGIN, markerEnd: GRAPH_PALETTE_MARKER_END, build: graphPaletteBlock },
  { name: "bp-graph palette (2/4)", path: "web/public/bp-graph.js", kind: "css",
    markerBegin: GRAPH_PALETTE_MARKER_BEGIN, markerEnd: GRAPH_PALETTE_MARKER_END, build: graphPaletteBlock },
  { name: "bp-graph palette (3/4)", path: "templates/search-starter/public/bp-graph.js", kind: "css",
    markerBegin: GRAPH_PALETTE_MARKER_BEGIN, markerEnd: GRAPH_PALETTE_MARKER_END, build: graphPaletteBlock },
  { name: "bp-graph palette (4/4)", path: "templates/astro-search-starter/public/bp-graph.js", kind: "css",
    markerBegin: GRAPH_PALETTE_MARKER_BEGIN, markerEnd: GRAPH_PALETTE_MARKER_END, build: graphPaletteBlock },
];

// Tolerant of leading indentation on the marker lines (Studio's markers sit
// indented inside a <style> block); the captured groups preserve that whitespace.
const markerRe = new RegExp(
  `([ \\t]*${escapeRe(MARKER_BEGIN)}\\n)([\\s\\S]*?)(\\n[ \\t]*${escapeRe(MARKER_END)})`
);
function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

// The kind "html" splice target: an HTML-comment marker (the swatch grid lives
// inside styleguide.html's [data-sg-swatches] host, not a <style> block, so a CSS
// comment can't mark it). Same tolerant leading-indent capture as markerRe.
const HTML_MARKER_BEGIN =
  "<!-- BEGIN GENERATED: swatches (design/tokens.json — regenerate: node design/emit.mjs --write; do not hand-edit) -->";
const HTML_MARKER_END = "<!-- END GENERATED: swatches -->";
const htmlMarkerRe = new RegExp(
  `([ \\t]*${escapeRe(HTML_MARKER_BEGIN)}\\n)([\\s\\S]*?)(\\n[ \\t]*${escapeRe(HTML_MARKER_END)})`
);

// Compute {expected, current, path, kind, name} for one artifact. `expected` is
// the desired full file text; `current` is what's on disk. A missing marker for a
// css artifact is a hard error (surface not prepared with the marker block).
//
// Also returns the GENERATED REGION on both sides — `currentRegion` (what the
// marker holds on disk right now) and `expectedRegion` (what build() produced).
// The write fence attributes on the REGION, never the whole file: for a css/html
// artifact everything outside the marker is legitimately hand-written and must not
// affect attribution, and for a whole-file (go/ts/elixir) artifact the region IS
// the file. Both are always the exact bytes that a --write would swap.
export function evaluate(a) {
  const abs = join(repoRoot, a.path);
  let current;
  try { current = readFileSync(abs, "utf8"); }
  catch { current = null; }
  const content = a.build();

  if (a.kind === "html") {
    // html: splice into the HTML-comment marker of the CURRENT file (same
    // mechanism as css, different marker). A missing marker is a hard error.
    const base = current == null ? "" : current;
    const m = base.match(htmlMarkerRe);
    if (!m) {
      return { ...a, abs, current, expected: null, error: `no BEGIN/END GENERATED: swatches marker in ${a.path}` };
    }
    const expected = base.slice(0, m.index) + m[1] + content + m[3] + base.slice(m.index + m[0].length);
    return { ...a, abs, current, expected, currentRegion: m[2], expectedRegion: content };
  }
  if (a.kind !== "css") {
    // whole-file artifacts (Go, TS): the build() output IS the entire file, so
    // the generated region is the file — nothing here is hand-writable, and a
    // --write overwrites more bluntly than any marker splice.
    return { ...a, abs, current, expected: content, currentRegion: current, expectedRegion: content };
  }
  // css: splice into the marker block of the CURRENT file. Most surfaces share
  // the tokens marker; an artifact may name its OWN marker (markerBegin/End) to
  // splice a distinct region in a file that carries the tokens block elsewhere.
  const base = current == null ? "" : current;
  const re = a.markerBegin
    ? new RegExp(`([ \\t]*${escapeRe(a.markerBegin)}\\n)([\\s\\S]*?)(\\n[ \\t]*${escapeRe(a.markerEnd)})`)
    : markerRe;
  const m = base.match(re);
  if (!m) {
    return { ...a, abs, current, expected: null, error: `no ${a.markerBegin || "BEGIN/END GENERATED: tokens"} marker in ${a.path}` };
  }
  const expected = base.slice(0, m.index) + m[1] + content + m[3] + base.slice(m.index + m[0].length);
  return { ...a, abs, current, expected, currentRegion: m[2], expectedRegion: content };
}

export function evaluateAll() { return ARTIFACTS.map(evaluate); }

function reportUnattributed(u, label = "REFUSED") {
  console.error(`  ${label} ${u.name} (${u.path})`);
  const why = u.attribution === "unknown"
    ? `no entry in ${MANIFEST_PATH} — this emitter has no record of ever generating this region`
    : `the region on disk does not match what this emitter last wrote there`;
  console.error(`    ${why}.`);
  const lost = lostLines(u.currentRegion, u.expectedRegion);
  if (lost.length === 0) {
    console.error(`    A --write would rewrite it, dropping no whole line — but the bytes are still unattributed.`);
  } else {
    console.error(`    A --write would DELETE ${lost.length} line(s) that do not appear in the regenerated output:`);
    for (const l of lost.slice(0, 12)) console.error(`      - ${l}`);
    if (lost.length > 12) console.error(`      … and ${lost.length - 12} more`);
  }
}

function run(mode, { force = false } = {}) {
  const results = evaluateAll();
  const regions = readManifest() ?? {};
  let changed = 0, errored = 0;
  let surfaceWritten = false;

  // The mirror is a SECOND generation hop off the just-emitted surface fragment,
  // so its write must run after the artifact loop. Its attribution, however, is a
  // property of the bundle on disk (a different file the loop never touches), so
  // it is safe — and necessary — to pre-flight it here with everything else.
  const mr = evaluateMirror(repoRoot);
  const mirrorUnit = mr.error ? null : {
    ...mr, currentRegion: mr.currentBlock, expectedRegion: mr.generatedBlock,
  };

  // ── the orphan predicate (charter D21 hygiene) ──────────────────────────────
  // A ledger slot is ORPHANED iff NO unit in this run claims its key. The claimed
  // set is DERIVED from the units themselves — never from a path prefix, a name
  // pattern, or a list — so a rename that leaves a same-path sibling behind prunes
  // only the slot whose artifact actually went away (cloud/priv/static/app.js owns
  // two slots; losing one must not cost the other). It deliberately INCLUDES units
  // that ERRORED: `mr` is used here rather than `mirrorUnit` because
  // evaluateMirror() always returns name+path, so the mirror keeps its slot even
  // when its region failed to evaluate. Pruning is for ABSENCE, never for failure.
  const claimedKeys = new Set([...results, mr].map(regionKey));
  const orphanKeys = Object.keys(regions).filter((k) => !claimedKeys.has(k));

  // ── --adopt: bless what is on disk as this emitter's own output ─────────────
  // The one sanctioned escape from a refusal that is NOT a destructive write:
  // after relocating hand-written rules outside the marker (the fix 55d61ab4c
  // applied by hand), or after a merge left the ledger behind its artifacts.
  if (mode === "adopt") {
    const next = { ...regions };
    let adopted = 0;
    for (const u of [...results, ...(mirrorUnit ? [mirrorUnit] : [])]) {
      if (u.error || u.currentRegion == null) { console.error(`  skip  ${u.name}: ${u.error ?? "region unreadable"}`); continue; }
      const d = regionDigest(u.currentRegion);
      const k = regionKey(u);
      if (next[k] !== d) { next[k] = d; console.log(`  adopt ${u.name} (${u.path})`); adopted++; }
      else console.log(`  ok    ${u.name} (already blessed)`);
    }
    // --adopt NAMES an orphan and KEEPS it. It cannot safely prune: it is the
    // escape hatch used precisely when the tree is in an odd state (a merge, a
    // half-relocated region), and a unit that errored above was skipped without
    // its key ever reaching `next`. Dropping a slot here would delete the record
    // of a surface that merely failed to read. --write, which enumerates the
    // complete unit set, is the one mode allowed to remove a key.
    for (const k of orphanKeys) {
      console.error(`  ORPHAN ${k} — no artifact claims this slot (kept; remove it with: node design/emit.mjs --write)`);
    }
    writeManifest(next);
    console.log(`\nemit --adopt: ${adopted} region(s) newly blessed in ${MANIFEST_PATH}${orphanKeys.length ? `, ${orphanKeys.length} orphan slot(s) named above and KEPT` : ""}. Nothing was rewritten.`);
    return;
  }

  // ── the write fence: pre-flight EVERY unit before writing ANY of them ───────
  // All-or-nothing on purpose. A per-artifact refusal mid-loop would leave the
  // tree half-regenerated, which is its own honesty problem: some surfaces new,
  // some old, and a check.mjs run that cannot tell you which.
  const units = [...results, ...(mirrorUnit ? [mirrorUnit] : [])];
  for (const u of units) {
    u.drift = !u.error && u.current !== u.expected;
    u.attribution = u.error ? "unknown" : attribute(u, regions);
    // Only a write that REPLACES bytes can destroy them. A region already equal to
    // what we would emit is not at risk, whatever the ledger says about it.
    u.blocked = u.drift && u.attribution !== "attributed";
  }
  // A surface fragment has a size limit, and past it nothing can assemble the surface.
  // Refuse here, before any file is written, and name the limit.
  const surfaceUnit = results.find((r) => r.name === "paper-surface" && !r.error);
  if (surfaceUnit) {
    try {
      validateFragmentSizes([{ name: surfaceUnit.path.split("/").at(-1), bytes: Buffer.from(surfaceUnit.expected) }], ASSET_MANIFEST["paper-surface"], "paper-surface");
    } catch (error) {
      console.error(`emit: REFUSED, nothing written. The regenerated ${surfaceUnit.path} would break its limit: ${error.message}`);
      console.error(`  Move hand-written rules out of that fragment into another one in ASSET_MANIFEST, then run emit again.`);
      process.exit(1);
    }
  }
  if (mode === "write") {
    const blocked = units.filter((u) => u.blocked);
    if (blocked.length && !force) {
      console.error(`emit --write: REFUSED — ${blocked.length} region(s) hold content this emitter cannot attribute to a prior generation.\n`);
      for (const u of blocked) reportUnattributed(u);
      console.error(`
  Nothing was written. ${units.filter((u) => u.drift).length} artifact(s) drifted; none were touched.

  This is the fence that commit 1d928b3bf drove through: hand-written rules placed
  INSIDE a generated marker are deleted by regeneration, and the drift gate then
  passes over the wreckage. Pick one:

    • Hand-written content?  MOVE it outside the BEGIN/END GENERATED marker, then
      re-run. That is the durable fix (precedent: 55d61ab4c).
    • Legitimately generated, just unrecorded (new artifact, or a merge that left
      ${MANIFEST_PATH} behind)?  node design/emit.mjs --adopt
    • Certain the listed lines are expendable?  node design/emit.mjs --write --force
`);
      process.exit(1);
    }
    if (blocked.length && force) {
      console.error(`emit --write --force: OVERRIDING the fence on ${blocked.length} region(s) — the lines below are being DELETED.\n`);
      for (const u of blocked) reportUnattributed(u, "DELETING");
      console.error("");
    }
  }

  // The ledger --write emits holds ONLY keys claimed in this run: spreading the old
  // regions object (what this did before) meant a renamed or removed artifact left
  // a dead digest behind forever, and a reader could not tell that slot from a live
  // one. A claimed unit that could not be evaluated carries its EXISTING digest
  // forward untouched — the loops below overwrite the ones they actually write.
  const nextRegions = {};
  for (const k of claimedKeys) if (k in regions) nextRegions[k] = regions[k];
  if (mode === "write") {
    for (const k of orphanKeys) console.log(`  PRUNE ${k} (no artifact claims this slot)`);
  }
  for (const r of results) {
    if (r.error) { console.error(`  ERROR ${r.name}: ${r.error}`); errored++; continue; }
    if (mode === "write") {
      if (r.drift) {
        writeFileSync(r.abs, r.expected); console.log(`  WROTE ${r.name} (${r.path})`); changed++;
        if (r.name === "paper-surface") surfaceWritten = true;
      }
      else { console.log(`  ok    ${r.name} (already current)`); }
      nextRegions[regionKey(r)] = regionDigest(r.expectedRegion);
    } else {
      if (r.drift) { console.error(`  DRIFT ${r.name} (${r.path})`); changed++; }
      else if (r.attribution !== "attributed") { console.error(`  UNATTRIBUTED ${r.name} (${r.path}) — in sync with tokens.json, but ${MANIFEST_PATH} has no matching record`); changed++; }
      else { console.log(`  ok    ${r.name}`); }
    }
  }
  // Post-step: the paper-editor token mirror. It is DERIVED from the just-emitted
  // surface fragment (a second generation hop), so it runs AFTER the artifact
  // loop has written that fragment to disk. One shared transform with
  // design/check.mjs + scripts/paper-editor-mirror-check.sh — they can't disagree.
  // Re-evaluated here (not reusing the pre-flight copy) because the surface it
  // derives from may have just changed on disk.
  if (mr.error) {
    console.error(`  ERROR ${mr.name}: ${mr.error}`);
    errored++;
  } else {
    const post = evaluateMirror(repoRoot);
    if (post.error) { console.error(`  ERROR ${post.name}: ${post.error}`); process.exit(1); }
    const drift = post.current !== post.expected;
    if (mode === "write") {
      if (drift) { writeFileSync(post.abs, post.expected); console.log(`  WROTE ${post.name} (${post.path})`); changed++; surfaceWritten = true; }
      else { console.log(`  ok    ${post.name} (already current)`); }
      nextRegions[regionKey(post)] = regionDigest(post.generatedBlock);
    } else {
      if (drift) { console.error(`  DRIFT ${post.name} (${post.path})`); changed++; }
      else if (mirrorUnit.attribution !== "attributed") { console.error(`  UNATTRIBUTED ${post.name} (${post.path}) — in sync, but ${MANIFEST_PATH} has no matching record`); changed++; }
      else { console.log(`  ok    ${post.name}`); }
    }
  }

  if (errored) { console.error(`emit: ${errored} artifact(s) could not be evaluated; see the ERROR lines above.`); process.exit(1); }
  if (mode === "write") writeManifest(nextRegions);
  // The package owns the surface; the raw host sink and the profile follow it through
  // the one outward path. --surface-only leaves the six browser assets to a full sync.
  // A rerun that regenerates nothing still repairs (--write) or reports (--check) a raw
  // sink left behind, for example by a sync that failed. Only a build can compare the
  // profile, so a --write with a toolchain always syncs and --check leaves it to that gate.
  const packageRoot = join(repoRoot, "api/assets/paper-editor");
  const rawSink = join(repoRoot, RAW_SURFACE_SINK);
  const rawSinkMissing = !existsSync(rawSink);
  const rawSinkStale = !rawSinkMissing && !readFileSync(rawSink).equals(assembleAsset("paper-surface", { root: packageRoot }));
  if (mode === "check" && rawSinkMissing) { console.error(`  MISSING ${RAW_SURFACE_SINK}`); changed++; }
  if (mode === "check" && rawSinkStale) { console.error(`  STALE ${RAW_SURFACE_SINK} differs from the assembled package surface`); changed++; }
  if (mode === "write" && (surfaceWritten || rawSinkStale || existsSync(join(packageRoot, "node_modules")))) {
    syncSurface(changed);
  } else if (mode === "write" && rawSinkMissing) {
    console.error(`emit --write: ${RAW_SURFACE_SINK} is missing and this tree has no toolchain. Fix: cd api/assets/paper-editor && npm ci && npm run sync:barkpark:write`);
    process.exit(1);
  }
  if (mode !== "write" && changed) {
    console.error(`\nemit --check: ${changed} artifact(s) DRIFTED from design/tokens.json or are UNATTRIBUTED. Fix: node design/emit.mjs --write`);
    process.exit(1);
  }
  const total = results.length + 1; // + paper-editor mirror
  console.log(mode === "write"
    ? `emit --write: ${changed} artifact(s) regenerated, ${total - changed} already current; ${MANIFEST_PATH} updated${orphanKeys.length ? ` (${orphanKeys.length} orphan slot(s) pruned)` : ""}.`
    : `emit --check: all ${total} artifacts in sync (${results.length} surfaces + paper-editor mirror), every generated region attributed.`);
}

// The surface-only sync, the one outward step. A failure names that step and its cause,
// not a stack, because emit may have had nothing to do with the code that broke.
function syncSurface(changed) {
  const { status, signal, stderr } = spawnSync(process.execPath, [join(repoRoot, "api/assets/paper-editor/scripts/sync-barkpark.mjs"), "--write", "--surface-only"], { stdio: ["ignore", "inherit", "pipe"], encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (status === 0) {
    process.stderr.write(stderr);
    return;
  }
  const lines = (stderr ?? "").split("\n");
  const start = lines.findIndex((line) => /^\w*Error\b|^sync-barkpark:/.test(line));
  const stack = lines.findIndex((line, at) => at > start && /^\s+at /.test(line));
  // No recognised error line: show the last lines the sync printed rather than nothing.
  const cause = start < 0 ? lines.filter((line) => line.trim()).slice(-8) : lines.slice(start, stack < 0 ? undefined : stack).filter((line) => line.trim());
  console.error(`emit --write: ${changed} artifact(s) regenerated, but the sync step failed: sync-barkpark --surface-only exited ${status ?? signal}.`);
  for (const line of cause) console.error(`  ${line}`);
  console.error("Fix that, then rerun emit --write.");
  process.exit(1);
}

// CLI
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const mode = process.argv.includes("--adopt") ? "adopt"
    : process.argv.includes("--write") ? "write"
    : "check";
  run(mode, { force: process.argv.includes("--force") });
}
