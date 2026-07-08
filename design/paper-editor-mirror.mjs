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

// True for the paper-surface TOKEN scopes only (not element/class rules): every
// comma-part resolves to `.bp-paper-surface` / `.bp-paper-body`, optionally under
// an `html[data-theme=…]` ancestor.
function isTokenSelector(sel) {
  sel = stripComments(sel).trim();
  if (!sel) return false;
  for (let part of sel.split(",")) {
    part = part.trim().replace(/^html\[data-theme="(?:light|dark)"\]\s+/, "");
    if (part !== ".bp-paper-surface" && part !== ".bp-paper-body") return false;
  }
  return true;
}

// Ordered [name, value] custom-property declarations. A token scope must be PURE
// custom properties: a non-custom declaration is a hard error, never a silent skip
// (a skipped block would mean its tokens NEVER reach the mirror while the gate
// stays green — the exact drift this exists to prevent).
function parseDecls(sel, body) {
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
      throw new MirrorError(
        `paper-surface.css token scope \`${sel.trim()}\` carries a non-custom-property ` +
          `declaration (\`${decl}\`).\n  Token scopes (.bp-paper-surface/.bp-paper-body, ` +
          `themed or not) must hold ONLY \`--*\` custom properties — move element/chrome ` +
          `declarations to an element selector, or the generated mirror cannot represent it.`
      );
    }
    const m = value.match(/^var\((--font[\w-]*)\)$/);
    if (m) value = FONT_LITERALS[m[1]] ?? value;
    out.push([name, value]);
  }
  return out;
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
  const light = new Map();
  const dark = new Map();
  const lightOrder = [];
  const darkOrder = [];

  for (const m of surface.matchAll(/([^{}]*)\{([^{}]*)\}/g)) {
    const sel = m[1];
    const body = m[2];
    if (!isTokenSelector(sel)) continue;
    const decls = parseDecls(sel, body);
    const darkScope = sel.includes('data-theme="dark"');
    const bucket = darkScope ? dark : light;
    const order = darkScope ? darkOrder : lightOrder;
    for (const [name, value] of decls) {
      if (!bucket.has(name)) order.push(name);
      bucket.set(name, value); // last write wins
    }
  }

  const generated =
    emitScope(":root, :host", lightOrder, light) +
    "\n\n" +
    emitScope(
      ':root[data-theme="dark"], :host([data-theme="dark"])',
      darkOrder,
      dark
    );

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
//   node design/paper-editor-mirror.mjs            # check (byte-compare)
//   node design/paper-editor-mirror.mjs --write    # regenerate the marked region
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const write = process.argv.includes("--write");
  const r = evaluateMirror(repoRoot);
  if (r.error) {
    console.error(`paper-editor-mirror: FAILED — ${r.error}`);
    process.exit(1);
  }
  const drift = r.current !== r.expected;
  if (write) {
    if (drift) {
      writeFileSync(r.abs, r.expected);
      console.log(
        `paper-editor-mirror: WROTE — regenerated ${r.tokenCount} paper-surface ` +
          `tokens in ${r.path} from paper-surface.css.`
      );
    } else {
      console.log("paper-editor-mirror: up to date — nothing to write.");
    }
    process.exit(0);
  }
  if (!drift) {
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
