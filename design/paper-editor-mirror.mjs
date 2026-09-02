#!/usr/bin/env node
// design/paper-editor-mirror.mjs — the ONE owner of the paper-editor token-mirror
// transform. The paper editor's standalone bundle
// (api/assets/paper-editor/src/styles.css) carries a GENERATED region that
// de-scopes the paper-surface token layer (api/assets/paper-surface/paper-surface.css,
// itself emitted from design/tokens.json). So the chain is:
//
//     design/tokens.json  →(design/emit.mjs)→  paper-surface.css  →(this)→  styles.css mirror
//
// Three callers share THIS one transform so they can never disagree:
//   • design/emit.mjs                    — after emitting paper-surface.css, writes the mirror
//   • design/check.mjs                   — the drift gate: byte-diffs the committed mirror
//   • scripts/paper-editor-mirror-check.sh (part 3) — delegates here (CLI parity: --write / none)
//
// Dependency-free (Node built-ins only), deterministic output. Ported byte-for-byte
// from the former in-script python transform; the committed styles.css is the fixture
// that pins that equivalence (emit --write must leave it git-clean).
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
// The attribution fence helpers, imported from their ONE owner (design/emit.mjs)
// rather than re-implemented here — see the CLI block at the bottom. emit.mjs
// imports `evaluateMirror` from this module, so the two form an ES-module cycle;
// that is safe because NEITHER touches the other's bindings during module
// evaluation (emit.mjs calls evaluateMirror only inside run(), and the helpers
// below are reached only from this file's CLI branch). A `await import()` here
// would NOT be safe: a top-level await inside a cycle deadlocks (node exits 13).
import {
  readManifest, writeManifest, attribute, lostLines, regionDigest, regionKey,
  MANIFEST_PATH,
} from "./emit.mjs";

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, "..");

export const SURFACE_PATH = "api/assets/paper-surface/paper-surface.css";
export const BUNDLE_PATH = "api/assets/paper-editor/src/styles.css";
export const MIRROR_NAME = "paper-editor mirror";

// A structural problem the transform can't represent (bad token scope, missing
// markers). Surfaced as a check failure, never a silent skip.
export class MirrorError extends Error {}

// Literal font stacks for any host-app-only `var(--font*)` a token scope might
// carry (Studio resolves those through host vars that don't exist in a bare
// host). The source is literal-fonts today, so this is a passthrough guard.
const FONT_LITERALS = {
  "--paper-font-serif":
    '"Iowan Old Style", "Palatino Linotype", Palatino, Charter, Georgia, \'Source Serif 4\', serif',
  "--paper-font-sans":
    '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
  "--paper-font-mono":
    'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace',
};

const stripComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, " ");

// The ONE non-custom-property exception on the bare `.bp-paper-surface` scope:
// the reading surface's own TYPE (pe-w1-reader-editorial-typography). It has to
// live on that exact selector because three sinks carry the class ALONE and
// nothing else — the sheets export `<div>`, the quiz `<body>` and the standalone
// PortableDoc export `<body>` — so a wrapper-qualified selector would silently
// leave those three at the browser's 16px, which is the very defect that slice
// exists to close.
//
// The mirror cannot DE-SCOPE these to `:root` (inherited type on the root would
// repaint an embedder's whole host page), so they are not copied — they are
// CHECKED. The bundle's own `.bp-paper-editor-body` wrapper is the standalone
// equivalent of the surface, and `assertBundleCarriesType` proves it declares
// every one of them byte-identically. That keeps the guard's contract intact:
// nothing here is skipped in silence, and a type declaration added to the reader
// without the bundle twin fails the mirror instead of shipping a bundle whose
// prose is a different size than the reader's.
const SURFACE_TYPE_PROPS = new Set([
  "font-size",
  "line-height",
  "letter-spacing",
  "font-feature-settings",
  "text-rendering",
  "-webkit-font-smoothing",
  "-moz-osx-font-smoothing",
]);

const isBareSurfaceScope = (sel) =>
  stripComments(sel)
    .split(",")
    .every((p) => p.trim() === ".bp-paper-surface");

// Classify a paper-surface TOKEN scope (not an element/class rule): every
// comma-part must resolve to `.bp-paper-surface` / `.bp-paper-body`, optionally
// under an `html[data-theme=…]` mode ancestor AND/OR an `html[data-bp-theme="X"]`
// THEME-identity ancestor (theme-system Wave 4, D27). Returns `{ theme, dark }`
// (theme === "" for the bare/evergreen fallback scope) or `null` for a non-token
// rule. All comma-parts must agree on the same (theme, dark) — a mixed scope is a
// structural error the caller surfaces, never a silent bucket.
//
// A theme-scoped block that this did NOT understand would be dropped (its tokens
// never reach the mirror) OR collapsed into the light/dark buckets last-write-
// wins across themes — the exact drift D27 exists to prevent.
function tokenScope(sel) {
  sel = stripComments(sel).trim();
  if (!sel) return null;
  let agreed = null;
  for (let part of sel.split(",")) {
    part = part.trim();
    let theme = "";
    let dark = false;
    // Optional theme-identity ancestor, itself optionally carrying a mode.
    let m = part.match(/^html\[data-bp-theme="([\w-]+)"\](\[data-theme="(light|dark)"\])?\s+/);
    if (m) {
      theme = m[1];
      if (m[3]) dark = m[3] === "dark";
      part = part.slice(m[0].length);
    } else {
      // Bare mode ancestor (no theme identity) — today's structure.
      m = part.match(/^html\[data-theme="(light|dark)"\]\s+/);
      if (m) {
        dark = m[1] === "dark";
        part = part.slice(m[0].length);
      }
    }
    if (part !== ".bp-paper-surface" && part !== ".bp-paper-body") return null;
    const here = { theme, dark };
    if (agreed === null) agreed = here;
    else if (agreed.theme !== here.theme || agreed.dark !== here.dark)
      throw new MirrorError(
        `paper-surface.css token scope \`${sel}\` mixes theme/mode across its ` +
          `comma-parts (${JSON.stringify(agreed)} vs ${JSON.stringify(here)}) — ` +
          `each token scope must resolve to ONE (theme, mode) so the mirror can ` +
          `de-scope it deterministically.`,
      );
  }
  return agreed;
}

// Ordered [name, value] custom-property declarations, plus the surface-type
// declarations the bare scope is allowed to carry (returned separately, for
// checking rather than copying — see SURFACE_TYPE_PROPS). A token scope is
// otherwise PURE custom properties: any other non-custom declaration is a hard
// error, never a silent skip (a skipped block would mean its tokens NEVER reach
// the mirror while the gate stays green — the exact drift this exists to prevent).
function parseDecls(sel, body, type) {
  const out = [];
  for (let decl of stripComments(body).split(";")) {
    decl = decl.trim();
    if (!decl) continue;
    const i = decl.indexOf(":");
    let name = i === -1 ? decl : decl.slice(0, i);
    let value = i === -1 ? "" : decl.slice(i + 1);
    name = name.trim();
    value = value.trim();
    if (!name.startsWith("--")) {
      if (SURFACE_TYPE_PROPS.has(name) && isBareSurfaceScope(sel)) {
        type.set(name, value);
        continue;
      }
      throw new MirrorError(
        `paper-surface.css token scope \`${sel.trim()}\` carries a non-custom-property ` +
          `declaration (\`${decl}\`).\n  Token scopes (.bp-paper-surface/.bp-paper-body, ` +
          `themed or not) must hold ONLY \`--*\` custom properties — move element/chrome ` +
          `declarations to an element selector, or the generated mirror cannot represent it.` +
          `\n  (The one exception is the reading surface's own type — ` +
          `${[...SURFACE_TYPE_PROPS].join(", ")} — and only on a bare ` +
          `\`.bp-paper-surface\` selector.)`
      );
    }
    const m = value.match(/^var\((--font[\w-]*)\)$/);
    if (m) value = FONT_LITERALS[m[1]] ?? value;
    out.push([name, value]);
  }
  return out;
}

// The surface type is CHECKED into the bundle, not copied into it. The bundle's
// `.bp-paper-editor-body` wrapper is the standalone host's paper surface — it
// already declares this set by hand — so assert it declares every one of them
// with the same value. A reader-side type change without the bundle twin fails
// here, which is the whole reason the exception above is allowed to exist.
function assertBundleCarriesType(type, bundleText) {
  if (type.size === 0) return;
  const bundle = stripComments(bundleText);
  let wrapper = null;
  for (const m of bundle.matchAll(/([^{}]*)\{([^{}]*)\}/g)) {
    if (m[1].split(",").every((p) => p.trim() === ".bp-paper-editor-body")) wrapper = m[2];
  }
  if (wrapper === null) {
    throw new MirrorError(
      "styles.css has no bare `.bp-paper-editor-body` rule, so the reading surface's " +
        "own type has nowhere to be mirrored. The bundle wrapper is the standalone " +
        "host's paper surface; it must carry the same type the reader does."
    );
  }
  const have = new Map();
  for (const decl of wrapper.split(";")) {
    const i = decl.indexOf(":");
    if (i === -1) continue;
    have.set(decl.slice(0, i).trim(), decl.slice(i + 1).trim());
  }
  const drift = [];
  for (const [prop, value] of type) {
    if (have.get(prop) !== value) drift.push(`  ${prop}: reader \`${value}\`, bundle \`${have.get(prop) ?? "(absent)"}\``);
  }
  if (drift.length) {
    throw new MirrorError(
      "the reading surface's type is not mirrored on the bundle wrapper " +
        "(`.bp-paper-editor-body` in styles.css). An embedded editor would set its " +
        "prose at a different size than the /papers reader:\n" +
        drift.join("\n")
    );
  }
}

function emitScope(selector, order, bucket) {
  const lines = order.map((name) => `  ${name}: ${bucket.get(name)};`);
  return `${selector} {\n${lines.join("\n")}\n}`;
}

// Pure transform: (paper-surface.css text, styles.css text) →
// { generated, current, newBundle, tokenCount }. `generated` is the de-scoped
// token block; `current` is what sits between the markers today; `newBundle` is
// the full styles.css with the marked region replaced. Throws MirrorError on a
// structural problem.
export function computeMirror(surfaceText, bundleText) {
  const surface = stripComments(surfaceText);

  // One (light,dark) bucket pair PER theme identity. Key "" is the bare/evergreen
  // fallback (de-scoped to :root); a named theme de-scopes to :root[data-bp-theme].
  // Insertion order is preserved so the emitted scopes track the source order.
  const themes = new Map(); // theme -> { light, dark, lightOrder, darkOrder }
  const bucketFor = (theme) => {
    if (!themes.has(theme))
      themes.set(theme, { light: new Map(), dark: new Map(), lightOrder: [], darkOrder: [] });
    return themes.get(theme);
  };
  bucketFor(""); // the base fallback scope always exists (and emits first)

  // Non-custom type declarations lifted off the bare surface scope. Not copied
  // into the generated region — checked against the bundle wrapper below.
  const surfaceType = new Map();

  for (const m of surface.matchAll(/([^{}]*)\{([^{}]*)\}/g)) {
    const sel = m[1];
    const body = m[2];
    const scope = tokenScope(sel);
    if (scope === null) continue;
    const decls = parseDecls(sel, body, surfaceType);
    const b = bucketFor(scope.theme);
    const bucket = scope.dark ? b.dark : b.light;
    const order = scope.dark ? b.darkOrder : b.lightOrder;
    for (const [name, value] of decls) {
      if (!bucket.has(name)) order.push(name);
      bucket.set(name, value); // last write wins (within one theme+mode)
    }
  }

  // De-scope each theme to its :root/:host equivalent. The bare fallback ("") maps
  // to today's exact `:root, :host` + `:root[data-theme="dark"], …` (byte-stable);
  // a theme "X" adds the orthogonal `:root[data-bp-theme="X"]` identity scopes.
  const parts = [];
  for (const [theme, b] of themes) {
    const lightSel = theme === "" ? ":root, :host" : `:root[data-bp-theme="${theme}"], :host([data-bp-theme="${theme}"])`;
    const darkSel = theme === ""
      ? ':root[data-theme="dark"], :host([data-theme="dark"])'
      : `:root[data-bp-theme="${theme}"][data-theme="dark"], :host([data-bp-theme="${theme}"][data-theme="dark"])`;
    parts.push(emitScope(lightSel, b.lightOrder, b.light));
    parts.push(emitScope(darkSel, b.darkOrder, b.dark));
  }
  const generated = parts.join("\n\n");

  assertBundleCarriesType(surfaceType, bundleText);

  const markerRe =
    /(\/\* BEGIN GENERATED: paper-surface[^\n]*\*\/\n)([\s\S]*?)(\n\/\* END GENERATED: paper-surface \*\/)/;
  const marker = bundleText.match(markerRe);
  if (!marker) {
    throw new MirrorError(
      "BEGIN/END GENERATED: paper-surface markers not found in styles.css."
    );
  }
  if ((bundleText.match(/BEGIN GENERATED: paper-surface/g) || []).length > 1) {
    throw new MirrorError(
      "multiple 'BEGIN GENERATED: paper-surface' markers in styles.css; the " +
        "generated section must be exactly one marked region."
    );
  }

  const current = marker[2];
  const newBundle =
    bundleText.slice(0, marker.index) +
    marker[1] +
    generated +
    marker[3] +
    bundleText.slice(marker.index + marker[0].length);
  const tokenCount = (generated.match(/--/g) || []).length;
  return { generated, current, newBundle, tokenCount };
}

// Read both files under repoRoot and evaluate the mirror. Shape mirrors
// design/emit.mjs `evaluate`: { name, path, abs, current, expected, ... } with a
// whole-file `current`/`expected` so callers can byte-compare uniformly; file or
// structural problems come back as `{ ..., error }`.
export function evaluateMirror(root = repoRoot) {
  const surfaceAbs = join(root, SURFACE_PATH);
  const bundleAbs = join(root, BUNDLE_PATH);
  let surfaceText;
  try {
    surfaceText = readFileSync(surfaceAbs, "utf8");
  } catch {
    return {
      name: MIRROR_NAME,
      path: BUNDLE_PATH,
      abs: bundleAbs,
      current: null,
      error: `canonical source missing: ${SURFACE_PATH} (the ONE source the mirror is generated from)`,
    };
  }
  let bundleText;
  try {
    bundleText = readFileSync(bundleAbs, "utf8");
  } catch {
    return {
      name: MIRROR_NAME,
      path: BUNDLE_PATH,
      abs: bundleAbs,
      current: null,
      error: `bundle missing: ${BUNDLE_PATH}`,
    };
  }
  try {
    const { generated, current, newBundle, tokenCount } = computeMirror(
      surfaceText,
      bundleText
    );
    return {
      name: MIRROR_NAME,
      path: BUNDLE_PATH,
      abs: bundleAbs,
      current: bundleText,
      expected: newBundle,
      generatedBlock: generated,
      currentBlock: current,
      tokenCount,
    };
  } catch (e) {
    if (e instanceof MirrorError) {
      return {
        name: MIRROR_NAME,
        path: BUNDLE_PATH,
        abs: bundleAbs,
        current: bundleText,
        error: e.message,
      };
    }
    throw e;
  }
}

// ── CLI (parity with scripts/paper-editor-mirror-check.sh part 3) ─────────────
//   node design/paper-editor-mirror.mjs                    # check (byte-compare)
//   node design/paper-editor-mirror.mjs --write            # FENCED regenerate
//   node design/paper-editor-mirror.mjs --write --force    # regenerate anyway
//   node design/paper-editor-mirror.mjs --adopt            # bless what is on disk
//
// THE FENCE. This CLI writes the SAME generated region design/emit.mjs writes
// (`api/assets/paper-editor/src/styles.css#paper-editor mirror`), so it must obey
// the SAME attribution rule: never replace a region whose SHA-256 does not match
// design/emit-manifest.json, and name every line the replacement would drop.
// Before this block existed, `--write` here (and its shell wrapper) was a side
// door around the emit.mjs fence — hand-written CSS placed inside the BEGIN/END
// GENERATED: paper-surface marker was deleted in silence, which is exactly the
// loss commit 1d928b3bf caused and the fence was built to stop.
//
// The helpers are IMPORTED from design/emit.mjs (readManifest / attribute /
// lostLines / regionDigest / writeManifest / regionKey), never re-implemented: a
// second copy of the rule is a second thing to drift (see the import note at the
// top for why the cycle with emit.mjs is safe).
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const adopt = process.argv.includes("--adopt");
  const write = process.argv.includes("--write");
  const force = process.argv.includes("--force");
  const r = evaluateMirror(repoRoot);
  if (r.error) {
    console.error(`paper-editor-mirror: FAILED — ${r.error}`);
    process.exit(1);
  }
  // The unit shape emit.mjs' fence helpers read: attribution is a property of the
  // GENERATED REGION (the marker interior), never the whole file — everything
  // outside the marker in styles.css is legitimately hand-written.
  const unit = { ...r, currentRegion: r.currentBlock, expectedRegion: r.generatedBlock };
  const regions = readManifest() ?? {};
  const key = regionKey(unit);
  const attribution = attribute(unit, regions);
  const drift = r.current !== r.expected;

  if (adopt) {
    const next = { ...regions, [key]: regionDigest(r.currentBlock) };
    writeManifest(next);
    console.log(
      `paper-editor-mirror --adopt: blessed the region on disk in ${MANIFEST_PATH} ` +
        `(${key}). Nothing was rewritten.`
    );
    process.exit(0);
  }

  if (write) {
    // Only a write that REPLACES bytes can destroy them: a region already equal to
    // what we would emit is not at risk, whatever the ledger says about it.
    const blocked = drift && attribution !== "attributed";
    if (blocked && !force) {
      console.error(
        `paper-editor-mirror --write: REFUSED — the generated region in ${r.path} ` +
          `holds content this transform cannot attribute to a prior generation.\n`
      );
      console.error(`  REFUSED ${r.name} (${r.path})`);
      console.error(
        `    ${attribution === "unknown"
          ? `no entry in ${MANIFEST_PATH} — there is no record of ever generating this region`
          : `the region on disk does not match what was last written there`}.`
      );
      const lost = lostLines(r.currentBlock, r.generatedBlock);
      if (lost.length === 0) {
        console.error(`    A --write would rewrite it, dropping no whole line — but the bytes are still unattributed.`);
      } else {
        console.error(`    A --write would DELETE ${lost.length} line(s) that do not appear in the regenerated output:`);
        for (const l of lost.slice(0, 12)) console.error(`      - ${l}`);
        if (lost.length > 12) console.error(`      … and ${lost.length - 12} more`);
      }
      console.error(`
  Nothing was written. Pick one:

    • Hand-written content?  MOVE it outside the BEGIN/END GENERATED: paper-surface
      marker in ${r.path}, then re-run. That is the durable fix.
    • Legitimately generated, just unrecorded (a merge that left ${MANIFEST_PATH}
      behind)?  node design/paper-editor-mirror.mjs --adopt  (or node design/emit.mjs --adopt)
    • Certain the listed lines are expendable?  node design/paper-editor-mirror.mjs --write --force
`);
      process.exit(1);
    }
    if (blocked && force) {
      console.error(
        `paper-editor-mirror --write --force: OVERRIDING the fence — the lines below are being DELETED.\n`
      );
      console.error(`  DELETING ${r.name} (${r.path})`);
      const lost = lostLines(r.currentBlock, r.generatedBlock);
      for (const l of lost.slice(0, 12)) console.error(`      - ${l}`);
      if (lost.length > 12) console.error(`      … and ${lost.length - 12} more`);
      console.error("");
    }
    if (drift) {
      writeFileSync(r.abs, r.expected);
      console.log(
        `paper-editor-mirror: WROTE — regenerated ${r.tokenCount} paper-surface ` +
          `tokens in ${r.path} from paper-surface.css.`
      );
    } else {
      console.log("paper-editor-mirror: up to date — nothing to write.");
    }
    // A successful write is this writer's own generation: record it in the SHARED
    // ledger, so a later `node design/check.mjs` / `node design/emit.mjs` reads the
    // region as ATTRIBUTED without an --adopt.
    const digest = regionDigest(r.generatedBlock);
    if (regions[key] !== digest) {
      writeManifest({ ...regions, [key]: digest });
      console.log(`paper-editor-mirror: ${MANIFEST_PATH} updated (${key}).`);
    }
    process.exit(0);
  }

  if (!drift) {
    if (attribution !== "attributed") {
      console.error(
        `paper-editor-mirror: FAILED — the generated region in ${r.path} matches ` +
          `paper-surface.css, but ${MANIFEST_PATH} has no matching record ` +
          `(UNATTRIBUTED).\n  Fix: node design/emit.mjs --adopt`
      );
      process.exit(1);
    }
    console.log(
      `paper-editor-mirror: PASS — ${r.tokenCount} generated paper-surface tokens ` +
        `in ${r.path} match paper-surface.css.`
    );
    process.exit(0);
  }
  console.error(
    `paper-editor-mirror: FAILED — the generated paper-surface token layer in ` +
      `${r.path} is STALE vs paper-surface.css.`
  );
  const a = r.currentBlock.split("\n");
  const b = r.generatedBlock.split("\n");
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) {
      console.error(
        `  first diff at generated line ${i + 1}:\n` +
          `    - committed:    ${JSON.stringify(a[i])}\n` +
          `    + regenerated:  ${JSON.stringify(b[i])}`
      );
      break;
    }
  }
  console.error(
    "\n  Fix: run  node design/emit.mjs --write  (or scripts/paper-editor-mirror-check.sh --write)  and commit\n" +
      "  the result (the mirror is GENERATED from paper-surface.css — never hand-edit between the markers)."
  );
  process.exit(1);
}
