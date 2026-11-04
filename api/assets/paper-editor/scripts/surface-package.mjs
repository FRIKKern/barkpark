import { JSDOM } from "jsdom";
import { declaredInTypes, HOST_SUPPLIED, reachInsInContract } from "../src/contract-surface.mjs";
import { classWords, writtenAttributes } from "./writes.mjs";

const sorted = (list) => [...new Set(list)].sort();

const grouped = (keys) => {
  const out = {};
  for (const key of [...keys].sort()) {
    const [kind, element, name] = key.split("|");
    ((out[element] ??= {})[kind] ??= []).push(name);
  }
  return out;
};

const byKind = (keys) => {
  const out = {};
  for (const key of [...keys].sort()) {
    const [kind, name] = key.split("|");
    (out[kind] ??= []).push(name);
  }
  return out;
};

export const stylesheetClasses = (css) =>
  [...css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{/g)].flatMap((m) => [...m[1].matchAll(/\.(-?[_a-zA-Z][\w-]*)/g)].map((c) => c[1]));

export const bundleEvents = (js) => [...js.matchAll(/new\s+(?:Custom)?Event\(\s*["'`]([\w-]+)["'`]/g)].map((m) => m[1]);

export const notClasses = (js) => [
  ...[...js.matchAll(/(?:customElements\.define|createElement|getElementById)\(\s*["'`]([\w-]+)["'`]/g)].map((m) => m[1]),
  ...[...js.matchAll(/\.id\s*=\s*["'`]([\w-]+)["'`]/g)].map((m) => m[1]),
];

export const sourceMembers = (text) => [...text.matchAll(/\bthis\.(_[A-Za-z]\w*)/g)].map((m) => m[1]);

export async function mountedMembers(window, tag) {
  const element = window.customElements.get(tag);
  if (!element) throw new Error(`package surface: bundle does not define ${tag}`);
  const el = window.document.createElement(tag);
  window.document.body.append(el);
  await new Promise((resolve) => setTimeout(resolve, 50));
  const members = [...Object.getOwnPropertyNames(element.prototype), ...Object.getOwnPropertyNames(el)].filter((name) => name.startsWith("_"));
  el.remove();
  return members;
}

export const elementClassBody = (text) => {
  const start = text.search(/^class \w+ extends HTMLElement \{/m);
  if (start === -1) throw new Error("no custom element class at column 0");
  return text.slice(start, text.indexOf("\n}", start) + 2);
};

const requireText = (name, value) => {
  if (typeof value !== "string" || value.length === 0)
    throw new Error(`package surface: ${name} must be a non-empty string`);
};

const requireSources = (elementSources) => {
  if (!elementSources || typeof elementSources !== "object")
    throw new Error("package surface: elementSources must contain canvas and editor arrays");
  for (const element of ["canvas", "editor"]) {
    const sources = elementSources[element];
    if (!Array.isArray(sources) || sources.length === 0 || sources.some((source) => typeof source !== "string" || source.length === 0))
      throw new Error(`package surface: elementSources.${element} must be a non-empty array of non-empty strings`);
  }
};

export async function extractPackageSurfaceEvidence({
  bundleSource,
  editorCssSource,
  typesSource,
  contractSource,
  elementSources,
} = {}) {
  requireText("bundleSource", bundleSource);
  requireText("editorCssSource", editorCssSource);
  requireText("typesSource", typesSource);
  requireText("contractSource", contractSource);
  requireSources(elementSources);

  const types = declaredInTypes(typesSource);
  const reachIns = reachInsInContract(contractSource);
  const names = new Set([...types, ...reachIns].map((key) => key.split("|").at(-1)));
  const outside = (list) => sorted(list).filter((name) => !names.has(name));
  const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { runScripts: "outside-only", pretendToBeVisual: true, url: "http://localhost/" });
  try {
    dom.window.BP_PAPER_EDITOR_NO_INJECT = true;
    dom.window.eval(bundleSource);
    const canvas = await mountedMembers(dom.window, "bp-paper-canvas");
    const editorElement = await mountedMembers(dom.window, "bp-paper-editor");
    const editor = dom.window.customElements.get("bp-paper-editor");
    requireText("CONTRACT_VERSION", editor.CONTRACT_VERSION);
    requireText("EDITOR_VERSION", editor.EDITOR_VERSION);
    if (typeof editor.BUILD_SHA !== "string" || !/^[0-9a-f]{12}$/.test(editor.BUILD_SHA))
      throw new Error("package surface: BUILD_SHA must be 12 lowercase hex characters");
    const notClass = new Set(notClasses(bundleSource));
    return {
      contract: editor.CONTRACT_VERSION,
      editor: editor.EDITOR_VERSION,
      build: editor.BUILD_SHA,
      declared: grouped([...types].filter((key) => !HOST_SUPPLIED.has(key.split("|")[1]))),
      host: grouped([...types].filter((key) => HOST_SUPPLIED.has(key.split("|")[1]))),
      reachIns: byKind(reachIns),
      candidates: {
        members: {
          canvas: outside([...canvas, ...sourceMembers(elementSources.canvas.join("\n"))]),
          editor: outside([...editorElement, ...sourceMembers(elementSources.editor.join("\n"))]),
        },
        classes: outside([...stylesheetClasses(editorCssSource), ...classWords(bundleSource)].filter((name) => !notClass.has(name))),
        attributes: outside(writtenAttributes(bundleSource).filter((name) => name.startsWith("data-"))),
        events: outside(bundleEvents(bundleSource)),
      },
    };
  } finally {
    dom.window.close();
  }
}
