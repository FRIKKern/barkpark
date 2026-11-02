// writes.mjs — which classes and attributes a script writes onto the DOM, read the
// same way for the minified bundle (scripts/surface.mjs) and for the source
// (src/__contract_truth.test.mjs). Node only; not part of the bundle.
//
// The lexer splits a script into string literals and template chunks, skipping
// comments and regex literals. A template keeps its `${…}` expressions, so
// `${base}__head` is read as `<the string base holds>__head`.

const REGEX_AFTER = new Set([..."(,=:[!&|?{};+-*%<>~^"]);
const REGEX_KEYWORDS = new Set(["return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw", "instanceof", "yield", "await"]);

export function lex(js) {
  const strings = [];
  const templates = [];
  const stack = [];
  let last = "";
  let word = "";
  let i = 0;
  const templateText = (parts) => {
    for (; i < js.length; i++) {
      const ch = js[i];
      if (ch === "\\") parts[parts.length - 1] += js[++i];
      else if (ch === "`") {
        i++;
        templates.push(parts);
        return;
      } else if (ch === "$" && js[i + 1] === "{") {
        stack.push({ parts, depth: 0, start: i + 2 });
        i += 2;
        return;
      } else parts[parts.length - 1] += ch;
    }
  };
  while (i < js.length) {
    const ch = js[i];
    const top = stack.at(-1);
    if (ch === '"' || ch === "'") {
      let text = "";
      for (i++; i < js.length && js[i] !== ch; i++) text += js[i] === "\\" ? js[++i] : js[i];
      i++;
      strings.push(text);
      last = '"';
    } else if (ch === "`") {
      i++;
      templateText([""]);
      last = '"';
    } else if (ch === "}" && top?.depth === 0) {
      stack.pop();
      top.parts.push(js.slice(top.start, i), "");
      i++;
      templateText(top.parts);
      last = '"';
    } else if (ch === "/" && js[i + 1] === "/") {
      while (i < js.length && js[i] !== "\n") i++;
    } else if (ch === "/" && js[i + 1] === "*") {
      const end = js.indexOf("*/", i + 2);
      i = end === -1 ? js.length : end + 2;
    } else if (ch === "/" && (last === "" || REGEX_AFTER.has(last) || REGEX_KEYWORDS.has(word))) {
      let inClass = false;
      for (i++; i < js.length && (js[i] !== "/" || inClass); i++) {
        if (js[i] === "\\") i++;
        else if (js[i] === "[") inClass = true;
        else if (js[i] === "]") inClass = false;
      }
      i++;
      last = "/re";
    } else {
      if (top && ch === "{") top.depth++;
      if (top && ch === "}") top.depth--;
      if (/[\w$]/.test(ch)) {
        word = /[\w$]/.test(js.charAt(i - 1)) ? word + ch : ch;
        last = "w";
      } else if (!/\s/.test(ch)) {
        last = ch;
        word = "";
      }
      i++;
      continue;
    }
    word = "";
  }
  if (stack.length) throw new Error(`lexer ended inside ${stack.length} template expression(s)`);
  return { strings, templates };
}

const STRING_CONST = /(?<![\w$.])([A-Za-z_$][\w$]*)\s*=\s*(["'])([\w-]+)\2/g;
const constants = (js) => new Map([...js.matchAll(STRING_CONST)].map((m) => [m[1], m[3]]));

const chunks = (js) => {
  const { strings, templates } = lex(js);
  const consts = constants(js);
  const expanded = templates.map((parts) => {
    let text = parts[0];
    for (let p = 1; p < parts.length; p += 2) {
      const expr = parts[p].trim();
      text += (consts.has(expr) ? consts.get(expr) : " ") + parts[p + 1];
    }
    return text;
  });
  return [...strings, ...expanded];
};

const CLASS_WORD = /(?<![\w#-])(?:bp-|ProseMirror|prosemirror-|tiptap|hljs)[\w-]*/g;

export function classWords(js) {
  return [...new Set(chunks(js).flatMap((text) => text.match(CLASS_WORD) ?? []).filter((word) => !/[-_]$/.test(word)))];
}

const camelToData = (key) => `data-${key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`;

const addAttributesBodies = (js) => {
  const bodies = [];
  for (const m of js.matchAll(/addAttributes\s*\(\s*\)\s*\{/g)) {
    let depth = 0;
    for (let i = m.index + m[0].length - 1; i < js.length; i++) {
      if (js[i] === "{") depth++;
      if (js[i] === "}" && --depth === 0) {
        bodies.push(js.slice(m.index, i + 1));
        break;
      }
    }
  }
  return bodies;
};

export function writtenAttributes(js) {
  const consts = constants(js);
  const name = (literal, ident) => literal ?? consts.get(ident);
  const found = [
    ...[...js.matchAll(/(?:set|toggle)Attribute(?:NS)?\(\s*(?:null\s*,\s*)?(?:["'`]([\w-]+)["'`$]|([A-Za-z_$][\w$]*)\s*[,)])/g)].map((m) => name(m[1], m[2])),
    ...[...js.matchAll(/["'`]([\w-]+)["'`]\s*:/g)].map((m) => m[1]).filter((n) => n.startsWith("data-")),
    ...chunks(js).flatMap((text) => [...text.matchAll(/(?<![\w-])(data-[\w-]+)=/g)].map((m) => m[1])),
    ...[...js.matchAll(/\.dataset\.(\w+)\s*=(?!=)/g)].map((m) => camelToData(m[1])),
    ...[...js.matchAll(/\.dataset\[\s*["'`](\w+)["'`]\s*\]\s*=(?!=)/g)].map((m) => camelToData(m[1])),
    ...[...js.matchAll(/Object\.assign\(\s*[\w$.]+\.dataset\s*,\s*\{([^}]*)\}/g)].flatMap((m) => [...m[1].matchAll(/([A-Za-z_$][\w$]*)\s*:/g)].map((k) => camelToData(k[1]))),
    ...addAttributesBodies(js).flatMap((body) => [
      ...[...body.matchAll(/["'`](data-[\w-]+)["'`]/g)].map((m) => m[1]),
      ...[...body.matchAll(/(?<![\w$.-])([a-z][\w-]*)\s*:\s*\{\s*default/g)].map((m) => m[1].toLowerCase()),
    ]),
  ];
  return [...new Set(found.filter((name) => name && !name.endsWith("-")))];
}

export function readerAttributes(ex) {
  return [...new Set([
    ...[...ex.matchAll(/(?<![\w-])(data-[\w-]+)=/g)].map((m) => m[1]),
    ...[...ex.matchAll(/["'](data-[\w-]+)["']\s*(?::|=>)/g)].map((m) => m[1]),
  ])];
}

export function readerClasses(ex) {
  return [...new Set([...ex.matchAll(/class=\\?"([^"\\]*)/g)].flatMap((m) => m[1].split(/\s+/).filter(Boolean)))];
}

export function schemaAttributes(schema) {
  const attributes = new Set();
  const visit = (spec) => {
    if (typeof spec.nodeType === "number") {
      for (const el of [spec, ...spec.querySelectorAll("*")]) for (const a of el.attributes) attributes.add(a.name);
      return;
    }
    if (spec.dom) return visit(spec.dom);
    if (!Array.isArray(spec)) return;
    const [, second, ...rest] = spec;
    const attrs = second && typeof second === "object" && !Array.isArray(second) ? second : null;
    for (const key of Object.keys(attrs ?? {})) attributes.add(key.replace(/^\S+\s/, "").toLowerCase());
    for (const child of attrs ? rest : [second, ...rest]) if (Array.isArray(child)) visit(child);
  };
  for (const type of Object.values(schema.nodes)) if (type.spec.toDOM) visit(type.spec.toDOM(type.createAndFill()));
  for (const type of Object.values(schema.marks)) if (type.spec.toDOM) visit(type.spec.toDOM(type.create(), true));
  return [...attributes];
}
