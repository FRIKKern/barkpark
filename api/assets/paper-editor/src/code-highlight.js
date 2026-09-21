// code-highlight.js — THE tokenizer for code blocks, shared by the canvas (the code node's highlight
// layer, canvas/code-node.js) and the `/papers` reader (reader-code.js → /assets/bp-paper-code.js).
// Doctrine rule 3 (view and edit are one producer): one grammar set, one HTML serializer, one class
// vocabulary (`hljs-*`, highlight.js's), so a JavaScript or an Elixir block paints the same tokens in
// the editor and on the page — Barkdown plan #27. The server emits `data-lang` on the reader's <pre>
// and nothing else; the tokens are a client pass on both surfaces.
//
// Grammars are a curated set (the languages a note reaches for), not the whole of highlight.js:
// the bundle stays small and the set is the same on both sides by construction.
import { createLowlight } from "lowlight";
import javascript from "highlight.js/lib/languages/javascript";
import typescript from "highlight.js/lib/languages/typescript";
import elixir from "highlight.js/lib/languages/elixir";
import erlang from "highlight.js/lib/languages/erlang";
import bash from "highlight.js/lib/languages/bash";
import shell from "highlight.js/lib/languages/shell";
import json from "highlight.js/lib/languages/json";
import xml from "highlight.js/lib/languages/xml";
import css from "highlight.js/lib/languages/css";
import python from "highlight.js/lib/languages/python";
import go from "highlight.js/lib/languages/go";
import sql from "highlight.js/lib/languages/sql";
import markdown from "highlight.js/lib/languages/markdown";
import yaml from "highlight.js/lib/languages/yaml";
import rust from "highlight.js/lib/languages/rust";
import java from "highlight.js/lib/languages/java";
import c from "highlight.js/lib/languages/c";
import cpp from "highlight.js/lib/languages/cpp";
import ruby from "highlight.js/lib/languages/ruby";
import php from "highlight.js/lib/languages/php";
import diff from "highlight.js/lib/languages/diff";
import dockerfile from "highlight.js/lib/languages/dockerfile";
import ini from "highlight.js/lib/languages/ini";
import plaintext from "highlight.js/lib/languages/plaintext";

const GRAMMARS = { javascript, typescript, elixir, erlang, bash, shell, json, xml, css, python, go, sql, markdown, yaml, rust, java, c, cpp, ruby, php, diff, dockerfile, ini, plaintext };
// Spellings an author types in the lang field, mapped onto the registered names.
const ALIASES = {
  js: "javascript", mjs: "javascript", cjs: "javascript", jsx: "javascript", node: "javascript",
  ts: "typescript", tsx: "typescript",
  ex: "elixir", exs: "elixir", heex: "elixir", erl: "erlang",
  sh: "bash", zsh: "bash", console: "shell", shellsession: "shell",
  html: "xml", svg: "xml", xhtml: "xml", vue: "xml",
  py: "python", golang: "go", md: "markdown", yml: "yaml", rs: "rust",
  "c++": "cpp", cc: "cpp", h: "c", hpp: "cpp", rb: "ruby", docker: "dockerfile", toml: "ini", text: "plaintext", txt: "plaintext",
};

export const lowlight = createLowlight(GRAMMARS);

// The registered grammar a lang spelling resolves to, or null (→ plain text, no tokens).
export function resolveLang(lang) {
  const raw = String(lang || "").trim().toLowerCase();
  if (!raw) return null;
  const name = ALIASES[raw] || raw;
  return lowlight.registered(name) ? name : null;
}

export function languages() {
  return Object.keys(GRAMMARS);
}

const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
export function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (ch) => ESC[ch]);
}

// HAST (lowlight's tree) → HTML: text escaped, elements as <span class="…">.
function hastToHtml(node) {
  if (!node) return "";
  if (node.type === "text") return escapeHtml(node.value || "");
  if (node.type === "root") return (node.children || []).map(hastToHtml).join("");
  if (node.type === "element") {
    const cls = node.properties && node.properties.className;
    const classes = Array.isArray(cls) ? cls.join(" ") : cls ? String(cls) : "";
    const inner = (node.children || []).map(hastToHtml).join("");
    return classes ? `<span class="${escapeHtml(classes)}">${inner}</span>` : inner;
  }
  return "";
}

// Highlight `code` as `lang`: HTML with hljs-* spans, or the escaped text when the lang is unknown or
// empty (so the caller can always set innerHTML). The text content of the result is always `code`.
export function highlightHtml(code, lang) {
  const name = resolveLang(lang);
  const source = String(code == null ? "" : code);
  if (!name) return escapeHtml(source);
  try {
    return hastToHtml(lowlight.highlight(name, source));
  } catch (_e) {
    return escapeHtml(source);
  }
}

// The token signature: the sequence of (class, text) pairs, the thing the parity row compares between
// the canvas and the reader. Computed from HTML so both sides go through the same serializer.
export function tokenSignature(html, doc) {
  const d = doc || (typeof document !== "undefined" ? document : null);
  if (!d) return null;
  const host = d.createElement("div");
  host.innerHTML = html;
  const out = [];
  const walk = (el, cls) => {
    for (const child of Array.from(el.childNodes)) {
      if (child.nodeType === 3) { if (child.nodeValue) out.push([cls, child.nodeValue]); }
      else if (child.nodeType === 1) walk(child, child.getAttribute("class") || cls);
    }
  };
  walk(host, "");
  return out;
}

// The reader pass: a <pre data-lang="…"> whose text is the code (the server renders it escaped, with
// optional per-line emphasis spans). Tokens are painted INSIDE each existing element (an emphasis
// span keeps its class), so the server's line markup survives and the text is byte-identical.
export function highlightPre(pre) {
  if (!pre || pre.getAttribute("data-hl") === "1") return false;
  const lang = resolveLang(pre.getAttribute("data-lang"));
  pre.setAttribute("data-hl", "1");
  if (!lang) return false;
  const paintTextNodes = (el) => {
    for (const child of Array.from(el.childNodes)) {
      if (child.nodeType === 3) {
        const span = el.ownerDocument.createElement("span");
        span.className = "hljs";
        span.innerHTML = highlightHtml(child.nodeValue, lang);
        // A single text child of the pre paints in place of itself; otherwise keep siblings.
        el.replaceChild(span, child);
      } else if (child.nodeType === 1) {
        paintTextNodes(child);
      }
    }
  };
  paintTextNodes(pre);
  return true;
}
