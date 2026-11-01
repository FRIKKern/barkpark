// contract-surface.mjs — reads the declared surface out of index.d.ts and out of
// EMBED-CONTRACT.md's "Surface index", as sets of "kind|element|name" keys, so
// __contract_truth.test.mjs can compare the two with each other and with the
// element classes. Node only; not part of the bundle.

const body = (src, open) => {
  const start = src.indexOf(open);
  if (start === -1) throw new Error(`index.d.ts has no ${open}`);
  let depth = 0;
  for (let i = src.indexOf("{", start); i < src.length; i++) {
    if (src[i] === "{") depth++;
    if (src[i] === "}" && --depth === 0) return src.slice(src.indexOf("{", start) + 1, i);
  }
  throw new Error(`unclosed ${open}`);
};

const topLevel = (block) => {
  let depth = 0;
  const lines = [];
  for (const line of block.split("\n")) {
    if (depth === 0) lines.push(line);
    for (const ch of line) {
      if (ch === "{" || ch === "(") depth++;
      if (ch === "}" || ch === ")") depth--;
    }
  }
  return lines;
};

const names = (block, pattern) =>
  topLevel(block).flatMap((line) => {
    const m = pattern.exec(line);
    return m ? [m[1]] : [];
  });

const MEMBER = /^\s{2}(?:readonly\s+)?([A-Za-z_$][\w$]*)\??\s*[:(]/;
const KEY = /^\s{2}"?([\w-]+)"?\??\s*:/;
const EVENT = /^\s{2}"(bp-[a-z-]+)"\s*:/;
const LISTENERS = new Set(["addEventListener", "removeEventListener", "new", "prototype"]);

export function declaredInTypes(dts) {
  const keys = new Set();
  const add = (kind, element, list) => list.forEach((n) => keys.add(`${kind}|${element}|${n}`));
  const members = (open) => names(body(dts, open), MEMBER).filter((n) => !LISTENERS.has(n));
  add("member", "canvas", members("export interface BpPaperCanvasElement "));
  add("member", "editor", members("export interface BpPaperEditorElement "));
  add("static", "both", members("export interface BpPaperBuildInfo "));
  add("attribute", "canvas", names(body(dts, "export interface BpPaperCanvasAttributes "), KEY));
  add("attribute", "editor", names(body(dts, "export interface BpPaperEditorAttributes "), KEY));
  add("ancestor attribute", "canvas", names(body(dts, "export interface BpPaperAncestorAttributes "), KEY));
  add("DOM attribute", "canvas", names(body(dts, "export interface BpPaperDomAttributes "), KEY));
  add("event", "canvas", names(body(dts, "export interface BpPaperCanvasEventMap "), EVENT));
  add("event", "editor", names(body(dts, "export interface BpPaperEditorEventMap "), EVENT));
  add("inbound event", "canvas", names(body(dts, "export interface BpPaperInboundEventMap "), EVENT));
  add("global", "window", names(body(body(dts, "declare global "), "interface Window "), /^\s+([A-Za-z_$][\w$]*)\??\s*:/));
  const union = (name) => {
    const at = dts.indexOf(`export type ${name} =`);
    if (at === -1) throw new Error(`index.d.ts has no ${name}`);
    return [...dts.slice(at, dts.indexOf(";", at)).matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  };
  add("class", "canvas", union("BpPaperPublicClass"));
  add("token", "css", union("BpPaperThemeToken"));
  return keys;
}

export function declaredInContract(md) {
  const keys = new Set();
  const index = md.slice(md.indexOf("## Surface index"));
  const section = index.slice(0, index.indexOf("\n## ", 4) > 0 ? index.indexOf("\n## ", 4) : undefined);
  for (const row of section.split("\n")) {
    const cells = row.split("|").map((c) => c.trim());
    if (cells.length < 5) continue;
    for (const m of cells[3].matchAll(/`([^`]+)`/g)) keys.add(`${cells[1]}|${cells[2]}|${m[1]}`);
  }
  for (const m of md.matchAll(/`(--(?:paper|bp)-[a-z0-9-]+)`/g)) keys.add(`token|css|${m[1]}`);
  return keys;
}
