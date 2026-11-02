// contract-surface.mjs — reads the declared surface out of index.d.ts and out of
// EMBED-CONTRACT.md's "Surface index", as sets of "kind|element|name" keys, so
// __contract_truth.test.mjs can compare the two with each other and with the
// element classes. The declared surface has the names the editor offers (canvas,
// editor, both, window, css) and the names it needs the host to supply (picker,
// mermaid). It also reads the reach-ins EMBED-CONTRACT.md's "Known reach-ins" lists
// by kind. Node only; not part of the bundle.

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
  for (const tag of names(body(body(dts, "declare global "), "interface HTMLElementTagNameMap "), /^\s+"(bp-paper-[\w-]+)"\s*:/)) add("tag", tag.slice("bp-paper-".length), [tag]);
  add("tag", "picker", union("BpHostPickerTag"));
  add("member", "picker", names(body(dts, "export interface BpHostPickerElement "), MEMBER));
  add("attribute", "picker", names(body(dts, "export interface BpHostPickerAttributes "), KEY));
  add("member", "mermaid", names(body(dts, "export interface BarkparkPaperMermaidRuntime "), MEMBER));
  add("class", "canvas", union("BpPaperPublicClass"));
  add("host class", "canvas", union("BpPaperHostClass"));
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

export const HOST_SUPPLIED = new Set(["picker", "mermaid"]);
export const REACH_IN_KINDS = new Set(["member", "expando", "attribute", "class", "event"]);

export function reachInsInContract(md) {
  const start = md.indexOf("## Known reach-ins");
  if (start === -1) throw new Error("EMBED-CONTRACT.md has no Known reach-ins");
  const section = md.slice(start, md.indexOf("\n## ", start + 4));
  const keys = new Set();
  for (const row of section.split("\n")) {
    const cells = row.split("|").map((c) => c.trim());
    if (cells.length !== 4 || !REACH_IN_KINDS.has(cells[1])) continue;
    for (const m of cells[2].matchAll(/`([^`]+)`/g)) keys.add(`${cells[1]}|${m[1]}`);
  }
  return keys;
}
