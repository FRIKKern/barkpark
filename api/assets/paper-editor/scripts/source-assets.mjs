// The package's assembled CSS authorities and its safe source reads. No side
// effects and no dependencies: design/ tooling imports this from a bare checkout.
//
// Two stylesheets are authored as ordered fragments: the raw paper surface
// (src/paper-surface) and the editor shell (src/editor-shell). The assembled bytes
// are the fragments concatenated with an empty separator, nothing added. The
// manifest below is the order, so a directory listing never decides it.
//
// Every read is a regular file at its direct package path. A symlink is refused,
// because that is how a package source would quietly start reading a Barkpark host
// asset. Every cut between fragments must fall at CSS depth zero: outside comments,
// strings, url() and braces, so a fragment can be read and edited on its own.
import { lstatSync, readFileSync, realpathSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const PACKAGE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const MAX_FRAGMENT_LINES = 800;

const fragment = (name, floorBytes, capBytes) => Object.freeze({ name, floorBytes, capBytes });

export const ASSET_MANIFEST = Object.freeze({
  "paper-surface": Object.freeze({
    dir: "src/paper-surface",
    fragments: Object.freeze([
      fragment("00-foundation-type.css", 25000, 70000),
      fragment("01-components-generated-theme.css", 28000, 70000),
      fragment("02-chat-code-story-layout.css", 22000, 56000),
      fragment("03-data-viz-forms-media.css", 34000, 86000),
    ]),
    // The generated spans design/emit.mjs and scripts/status-manifest-check.sh write.
    markerFragment: "01-components-generated-theme.css",
    markers: Object.freeze([
      "/* BEGIN GENERATED: status-tones",
      "/* END GENERATED: status-tones */",
      "/* BEGIN GENERATED: tokens",
      "/* END GENERATED: tokens */",
    ]),
  }),
  "editor-shell": Object.freeze({
    dir: "src/editor-shell",
    fragments: Object.freeze([
      fragment("00-editor-shell-core.css", 24000, 60000),
      fragment("01-canvas-blocks-fields.css", 29000, 72000),
      fragment("02-native-blocks-link-preview.css", 14000, 36000),
      fragment("03-contextual-editors.css", 19000, 48000),
      fragment("04-contextual-panels-gutter.css", 12000, 32000),
    ]),
    markerFragment: null,
    markers: Object.freeze([]),
  }),
});

const manifestFor = (id) => {
  const manifest = ASSET_MANIFEST[id];
  if (!manifest) throw new Error(`source assets: unknown asset ${JSON.stringify(id)}`);
  return manifest;
};

// One package file as bytes. Refuses a symlink anywhere on the way, a directory,
// and anything that does not resolve to the direct path under the package root.
export function readPackageFile(rel, { root = PACKAGE_ROOT } = {}) {
  const direct = path.join(realpathSync(root), rel);
  const stat = lstatSync(direct);
  if (stat.isSymbolicLink() || !stat.isFile())
    throw new Error(`source assets: ${rel} must be a regular file, not a symlink or directory`);
  if (realpathSync(direct) !== direct)
    throw new Error(`source assets: ${rel} must resolve to its direct package path`);
  return readFileSync(direct);
}

// Walks the fragments as one stylesheet and refuses a cut inside a comment, a
// string, an unquoted url() or a brace. Byte-safe: every token it reads is ASCII.
export function validateCuts(parts, label = "css") {
  let depth = 0;
  let mode = null; // null | "comment" | "url" | a quote character
  parts.forEach(({ name, bytes }, index) => {
    const css = Buffer.from(bytes).toString("latin1");
    for (let i = 0; i < css.length; i++) {
      const ch = css[i];
      if (mode === "comment") {
        if (ch === "*" && css[i + 1] === "/") { mode = null; i++; }
      } else if (mode === "url") {
        if (ch === "\\") i++;
        else if (ch === ")") mode = null;
      } else if (mode) {
        if (ch === "\\") i++;
        else if (ch === mode) mode = null;
      } else if (ch === "/" && css[i + 1] === "*") { mode = "comment"; i++; }
      else if (ch === '"' || ch === "'") mode = ch;
      else if (ch === "{") depth++;
      else if (ch === "}") {
        if (--depth < 0) throw new Error(`source assets: ${label}: ${name} closes a brace it never opened`);
      } else if (/^url\(\s*[^"'\s]/i.test(css.slice(i, i + 40))) { mode = "url"; i += 3; }
    }
    const end = index === parts.length - 1 ? "the end of the stylesheet" : `the cut after ${name}`;
    if (mode) throw new Error(`source assets: ${label}: ${end} is inside ${mode === "comment" ? "a comment" : mode === "url" ? "a url()" : "a string"}`);
    if (depth !== 0) throw new Error(`source assets: ${label}: ${end} is inside ${depth} open brace(s)`);
  });
}

// Each generated marker exactly once in the whole stylesheet, in its named fragment.
export function validateMarkers(parts, { markers, markerFragment }, label = "css") {
  for (const marker of markers) {
    const holders = parts.flatMap(({ name, bytes }) => Array(Buffer.from(bytes).toString("latin1").split(marker).length - 1).fill(name));
    if (holders.length !== 1) throw new Error(`source assets: ${label}: marker ${JSON.stringify(marker)} appears ${holders.length} times, expected 1`);
    if (holders[0] !== markerFragment) throw new Error(`source assets: ${label}: marker ${JSON.stringify(marker)} is in ${holders[0]}, expected ${markerFragment}`);
  }
}

export function validateFragmentSizes(parts, manifest, label = "css") {
  for (const { name, bytes } of parts) {
    const spec = manifest.fragments.find((f) => f.name === name);
    if (!spec) throw new Error(`source assets: ${label}: ${name} is not in the manifest`);
    if (bytes.length < spec.floorBytes || bytes.length > spec.capBytes)
      throw new Error(`source assets: ${label}: ${name} is ${bytes.length} bytes, outside ${spec.floorBytes}..${spec.capBytes}`);
    if (bytes.at(-1) !== 10) throw new Error(`source assets: ${label}: ${name} must end with its final newline`);
    const lines = bytes.reduce((count, byte) => count + (byte === 10 ? 1 : 0), 0);
    if (lines > MAX_FRAGMENT_LINES) throw new Error(`source assets: ${label}: ${name} has ${lines} physical lines (max ${MAX_FRAGMENT_LINES})`);
  }
}

export function readFragments(id, { root = PACKAGE_ROOT } = {}) {
  const { dir, fragments } = manifestFor(id);
  return fragments.map(({ name }) => ({ name, bytes: readPackageFile(`${dir}/${name}`, { root }) }));
}

// The assembled bytes: validated fragments, empty separator, final newline kept.
export function assembleAsset(id, { root = PACKAGE_ROOT } = {}) {
  const manifest = manifestFor(id);
  const parts = readFragments(id, { root });
  validateFragmentSizes(parts, manifest, id);
  validateCuts(parts, id);
  validateMarkers(parts, manifest, id);
  return Buffer.concat(parts.map(({ bytes }) => bytes));
}

export const assembledText = (id, options) => assembleAsset(id, options).toString("utf8");
