// Composes host-profile/surface.json: what a build offers a host, what it needs
// from one, the page vocabulary it shares with the reader, what it keeps to itself,
// and the reach-ins between them.
//   declared  index.d.ts's names for the editor's elements (canvas, editor, both,
//             window, css); __contract_truth.test.mjs holds it equal to
//             EMBED-CONTRACT.md's Surface index.
//   host      index.d.ts's names the host supplies (picker, mermaid).
//   reachIns  EMBED-CONTRACT.md's Known reach-ins, by kind.
//   reader    PortableDoc's page vocabulary: the classes and data-* attributes the
//             reader writes (lib/barkpark/portable_doc/render), which the editor
//             paints too and bp-paper-surface.css styles. A host may style them.
//   internal  read off the build a host loads, minus declared, reachIns and reader:
//             - private members of each element: the prototype's, a mounted
//               element's own, and every `this._x` in the element's class body,
//               which also finds the ones set later;
//             - classes in bp-paper-editor.css and in every string and template
//               chunk of the bundle (scripts/writes.mjs), less tags and ids;
//             - data-* attributes the bundle writes (every one its TipTap schema
//               renders is declared, reader vocabulary or a bundle string too;
//               __surface.test.mjs holds that);
//             - events the bundle dispatches.
// A host profile checks a host's sources against this file.
//
// This module writes nothing. packageSurface() reads one build directory and the
// package's own sources. surface() adds the live Barkpark reader. The one writer of
// the tracked file is scripts/sync-barkpark.mjs; the host surface test holds it
// byte-equal to this composition.
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { canvasSourceLeafNames, elementClassBody, extractPackageSurfaceEvidence } from "./surface-package.mjs";
import { readerAttributes, readerClasses } from "./writes.mjs";

export {
  bundleEvents,
  canvasMethodLeafNames,
  canvasSourceLeafNames,
  elementClassBody,
  mountedMembers,
  notClasses,
  sourceMembers,
  stylesheetClasses,
} from "./surface-package.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const readerDir = path.join(root, "../../lib/barkpark/portable_doc/render");
const localDist = path.join(root, "dist");
export const surfacePath = path.join(root, "host-profile/surface.json");

const sorted = (list) => [...new Set(list)].sort();
const leaves = (value) => Array.isArray(value) ? value : Object.values(value).flatMap(leaves);

export async function packageSurface({ dir = localDist } = {}) {
  const canvasDir = path.join(root, "src/canvas");
  return extractPackageSurfaceEvidence({
    bundleSource: readFileSync(path.join(dir, "bp-paper-editor.bundle.js"), "utf8"),
    editorCssSource: readFileSync(path.join(dir, "bp-paper-editor.css"), "utf8"),
    typesSource: readFileSync(path.join(root, "index.d.ts"), "utf8"),
    contractSource: readFileSync(path.join(root, "EMBED-CONTRACT.md"), "utf8"),
    elementSources: {
      canvas: [
        elementClassBody(readFileSync(path.join(canvasDir, "index.js"), "utf8")),
        ...canvasSourceLeafNames(readdirSync(canvasDir)).map((name) => readFileSync(path.join(canvasDir, name), "utf8")),
      ],
      editor: [
        elementClassBody(readFileSync(path.join(root, "src/index.js"), "utf8")),
        readFileSync(path.join(root, "src/paper-editor-runtime.js"), "utf8"),
        readFileSync(path.join(root, "src/paper-editor-autocomplete.js"), "utf8"),
      ],
    },
  });
}

export function composeBarkparkSurface(packageEvidence, readerSource) {
  if (typeof readerSource !== "string" || readerSource.length === 0)
    throw new Error("surface: Barkpark reader source must be a non-empty string");
  const classes = readerClasses(readerSource);
  const attributes = readerAttributes(readerSource);
  if (classes.length === 0) throw new Error("surface: Barkpark reader source has no class evidence");
  if (attributes.length === 0) throw new Error("surface: Barkpark reader source has no attribute evidence");
  const { candidates, ...evidence } = packageEvidence;
  const names = new Set(leaves({ declared: evidence.declared, host: evidence.host, reachIns: evidence.reachIns }));
  const outside = (list) => sorted(list).filter((name) => !names.has(name));
  const page = { classes: outside(classes), attributes: outside(attributes) };
  const internal = (list) => sorted(list).filter((name) => !page.attributes.includes(name));
  return {
    ...evidence,
    reader: page,
    internal: {
      members: {
        canvas: internal(candidates.members.canvas),
        editor: internal(candidates.members.editor),
      },
      classes: internal(candidates.classes.filter((name) => !page.classes.includes(name))),
      attributes: internal(candidates.attributes),
      events: internal(candidates.events),
    },
  };
}

export const liveReaderSource = () => readdirSync(readerDir).map((name) => readFileSync(path.join(readerDir, name), "utf8")).join("\n");

// The whole profile for a build directory. With none it makes a temporary build, so
// `npm test` on a clean checkout has no dist/ to need and no host asset to read.
export async function surface({ dir } = {}) {
  if (dir) return composeBarkparkSurface(await packageSurface({ dir }), liveReaderSource());
  const { buildLocal } = await import("./build-local.mjs");
  const outDir = mkdtempSync(path.join(tmpdir(), "bp-surface-"));
  try {
    const { evidence } = await buildLocal({ outDir, logLevel: "warning" });
    return composeBarkparkSurface(evidence, liveReaderSource());
  } finally {
    rmSync(outDir, { recursive: true, force: true });
  }
}

export const render = (value) => `${JSON.stringify(value, null, 2)}\n`;
