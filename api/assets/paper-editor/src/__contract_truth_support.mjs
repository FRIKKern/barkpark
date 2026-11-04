import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";
import { declaredInContract, declaredInTypes, reachInsInContract } from "./contract-surface.mjs";
import { schemaAttributes, writtenAttributes } from "../scripts/writes.mjs";

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const read = (rel) => readFileSync(path.join(root, rel), "utf8");
export const pkg = JSON.parse(read("package.json"));
export const md = read("EMBED-CONTRACT.md");
export const types = declaredInTypes(read("index.d.ts"));
export const contract = declaredInContract(md);

export const walk = (dir) => readdirSync(dir).flatMap((name) => {
  const file = path.join(dir, name);
  return statSync(file).isDirectory() ? walk(file) : [file];
});
export const stripComments = (text) => text.replace(/(^|\s)\/\*[\s\S]*?\*\//g, "$1").replace(/(^|[\s;{}),])\/\/.*$/gm, "$1");
export const sourceFiles = walk(path.join(root, "src")).filter((file) => /\.(js|css)$/.test(file) && !path.basename(file).startsWith("__"));
export const rawJs = sourceFiles.filter((file) => file.endsWith(".js")).map((file) => readFileSync(file, "utf8")).join("\n");
export const js = stripComments(rawJs).replace(/\?\.(?=[(\[])/g, "").replace(/\?\.(?!\d)/g, ".").replace(/\n\s*(?=\.(?!\.))/g, "");
export const packageCss = stripComments(read("src/styles.css"));
export const packageSource = `${js}\n${packageCss}`;

const escape = (name) => name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
export const appears = (name, text) => new RegExp(`(?<![\\w-])${escape(name)}(?![\\w-])`).test(text);

export const EDITOR_INTERNAL = new Set(["bp-canvas-image-pick", "bp-activate-field-editor", "data-action", "data-bp-opaque", "data-bp-text-boundary", "data-test-id", "data-bp-paste-notice", "bp-canvas-image-chrome"]);
export const reachIns = new Set([...reachInsInContract(md)].map((key) => key.split("|")[1]));
export const NO_ON_PROPERTY = new Set(["DOMCharacterDataModified", "DOMContentLoaded", "compositionend", "compositionstart", "compositionupdate", "focusin", "focusout", "gotpointercapture", "lostpointercapture", "pointercancel", "pointerdown", "pointerenter", "pointerleave", "pointermove", "pointerout", "pointerover", "pointerup", "selectionchange", "animationend", "animationstart", "transitionend"]);
export const UNREFLECTED_GLOBAL_ATTRIBUTES = new Set(["inert"]);

export const declaredNames = new Set([...types].map((key) => key.split("|")[2]));
export const names = (kind, element) => [...types].filter((key) => key.startsWith(`${kind}|${element}|`)).map((key) => key.split("|")[2]);
export const missing = (from, to) => [...from].filter((key) => !to.has(key)).sort();

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
export const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("./index.js");

const LIFECYCLE = new Set(["constructor", "connectedCallback", "disconnectedCallback", "attributeChangedCallback", "adoptedCallback"]);
const STATIC_BUILTINS = new Set(["length", "name", "prototype", "observedAttributes"]);
export const publicMembers = (cls) => Object.getOwnPropertyNames(cls.prototype).filter((name) => !name.startsWith("_") && !LIFECYCLE.has(name));
export const publicStatics = (cls) => Object.getOwnPropertyNames(cls).filter((name) => !name.startsWith("_") && !STATIC_BUILTINS.has(name));
const ownPublic = (element) => Object.getOwnPropertyNames(element).filter((name) => !name.startsWith("_"));
export const instances = {};
export const schemas = {};
for (const tag of ["bp-paper-canvas", "bp-paper-editor"]) {
  const created = window.document.createElement(tag);
  const connected = window.document.createElement(tag);
  if (tag === "bp-paper-editor") connected.setAttribute("data-block", JSON.stringify({ id: "p1", type: "paragraph", content: [] }));
  window.document.body.append(connected);
  await new Promise((resolve) => setTimeout(resolve, 50));
  instances[tag] = { created: ownPublic(created), connected: ownPublic(connected), mounted: !!connected.querySelector("[contenteditable]") };
  schemas[tag] = schemaAttributes(connected._editor.schema);
  connected.remove();
}

export const dispatched = (event) => new RegExp(`CustomEvent\\(\\s*["'\`]${event}["'\`]`).test(js);
export const listened = (event) => new RegExp(`(addEventListener\\(\\s*["'\`]${event}["'\`]|["'\`]${event}["'\`]\\s*:\\s*on)`).test(js);
export const dataName = (key) => `data-${key.replace(/[A-Z]/g, (character) => `-${character.toLowerCase()}`)}`;
export const sourceWrites = new Set([...writtenAttributes(rawJs), ...Object.values(schemas).flat()]);
export const known = (name) => declaredNames.has(name) || EDITOR_INTERNAL.has(name) || reachIns.has(name);
export const isDomEvent = (event) => `on${event}` in window.HTMLElement.prototype || `on${event}` in window || `on${event}` in window.document || NO_ON_PROPERTY.has(event);

const DOCUMENT = String.raw`(?:\bdocument|\.ownerDocument)`;
export const ancestorReadNames = (cssText) => {
  const selectors = [...js.matchAll(new RegExp(String.raw`(?:\.closest|${DOCUMENT}\.querySelector(?:All)?)\(\s*(?:"([^"]*)"|'([^']*)'|\`([^\`]*)\`)`, "g"))].map((match) => match[1] ?? match[2] ?? match[3]);
  const rules = [...cssText.matchAll(/([^{}]+)\{/g)].flatMap((match) => match[1].split(",").map((part) => part.trim()));
  const leading = rules.flatMap((rule) => /^(?::root|html|:host|body)?((?:\[[^\]]+\])+)(?=[\s>~+]|$)/.exec(rule)?.[1] ?? []);
  return new Set([...selectors, ...leading].flatMap((selector) => [...selector.matchAll(/\[(data-[\w-]+)|\.(bp-[\w-]+)/g)].map((match) => match[1] ?? match[2])));
};

const READ = /^\.\s*(?:(?:getAttribute|hasAttribute|getAttributeNode)\s*\(\s*["'`]([\w-]+)["'`]|(?:getAttributeNS|hasAttributeNS)\s*\([^,)]*,\s*["'`]([\w-]+)["'`]|attributes\s*(?:\[\s*["'`]([\w-]+)["'`]|\.getNamedItem\(\s*["'`]([\w-]+)["'`])|dataset\s*(?:\.(\w+)|\[\s*["'`](\w+)["'`])|(?:matches|closest)\s*\(\s*["'`]([^"'`]*)["'`])/;
const readNames = (match) => match[1] ?? match[2] ?? match[3] ?? match[4] ? [match[1] ?? match[2] ?? match[3] ?? match[4]] : match[5] ?? match[6] ? [dataName(match[5] ?? match[6])] : [...match[7].matchAll(/\[\s*([\w-]+)/g)].map((attribute) => attribute[1]);
const readsInTail = (tail) => [...tail.matchAll(/\.\s*(?:getAttribute|hasAttribute|getAttributeNode|getAttributeNS|hasAttributeNS|attributes|dataset|matches|closest)\b[^;\n]*/g)].flatMap((match) => {
  const read = READ.exec(match[0]);
  return read ? readNames(read) : [];
});
const PARENT = String.raw`(?:\.(?:parentElement|parentNode|offsetParent)\b|\.getRootNode\(\s*\)|${DOCUMENT}\.(?:documentElement|body)\b|${DOCUMENT}\.(?:getElementById|querySelector(?:All)?)\([^)]*\))`;
const destructured = (sourceText, receiver) => [...sourceText.matchAll(new RegExp(String.raw`\{([^{}]*)\}\s*=\s*${receiver}\.dataset\b`, "g"))]
  .flatMap((match) => match[1].split(",").map((part) => part.split(":")[0].trim()).filter(Boolean).map(dataName));
const inDataset = (sourceText, receiver) => [...sourceText.matchAll(new RegExp(String.raw`["'\`](\w+)["'\`]\s+in\s+${receiver}\.dataset\b`, "g"))].map((match) => dataName(match[1]));
export const ownOrParentReads = (sourceText) => ({
  own: new Set([
    ...[...sourceText.matchAll(/\bthis(?=\s*\.)/g)].flatMap((match) => {
      const read = READ.exec(sourceText.slice(match.index + 4, match.index + 400));
      return read ? readNames(read) : [];
    }),
    ...destructured(sourceText, String.raw`\bthis`),
    ...inDataset(sourceText, String.raw`this`),
  ]),
  parents: new Set([
    ...[...sourceText.matchAll(new RegExp(`${PARENT}[^;\\n]*`, "g"))].flatMap((match) => readsInTail(match[0])),
    ...destructured(sourceText, String.raw`[\w$.]*${PARENT}`),
    ...inDataset(sourceText, String.raw`[\w$.]*${PARENT}`),
  ]),
});

export const selectorAttributes = (cssText) => {
  const rules = [...cssText.replace(/@[\w-]+[^{;]*;/g, "").matchAll(/([^{}]+)\{/g)].flatMap((match) => match[1].split(",").map((part) => part.trim()));
  const selectors = rules.flatMap((rule) => !rule.startsWith("@") ? [rule]
    : rule.startsWith("@supports") ? [...rule.matchAll(/selector\(((?:[^()]|\([^()]*\))*)\)/g)].map((match) => match[1])
    : rule.startsWith("@scope") ? [...rule.matchAll(/\(((?:[^()]|\([^()]*\))*)\)/g)].map((match) => match[1])
    : []);
  return new Set(selectors.flatMap((rule) => [...rule.matchAll(/\[\s*([\w-]+)/g)].map((match) => match[1])));
};

export const globalAttribute = (name) => name in window.HTMLElement.prototype || UNREFLECTED_GLOBAL_ATTRIBUTES.has(name);
