// Bounded TeX-to-MathML parser matching the server and React renderers. It is
// intentionally not a full TeX engine: unsupported macros remain visible as
// literal text instead of being guessed or dropped.
const MACROS = {
  "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ",
  "\\epsilon": "ε", "\\theta": "θ", "\\lambda": "λ", "\\mu": "μ",
  "\\pi": "π", "\\sigma": "σ", "\\phi": "φ", "\\omega": "ω",
  "\\Delta": "Δ", "\\Gamma": "Γ", "\\Sigma": "Σ", "\\Omega": "Ω",
  "\\infty": "∞", "\\sum": "∑", "\\int": "∫", "\\prod": "∏",
  "\\partial": "∂", "\\nabla": "∇", "\\cdot": "·", "\\times": "×",
  "\\div": "÷", "\\pm": "±", "\\mp": "∓", "\\leq": "≤",
  "\\geq": "≥", "\\neq": "≠", "\\approx": "≈", "\\equiv": "≡",
  "\\to": "→", "\\rightarrow": "→", "\\leftarrow": "←", "\\in": "∈",
  "\\notin": "∉", "\\subset": "⊂", "\\cup": "∪", "\\cap": "∩",
  "\\forall": "∀", "\\exists": "∃", "\\sqrt": "√",
};
const OPERATORS = new Set(["+", "-", "=", "*", "/", "(", ")", "<", ">", ","]);
const escapeHtml = (value) => String(value)
  .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;").replaceAll("'", "&#39;");

function tokenize(tex) {
  const tokens = [];
  let index = 0;
  while (index < tex.length) {
    const char = tex[index];
    if (/\s/.test(char)) { index += 1; continue; }
    if (char === "\\") {
      const macro = /^\\[a-zA-Z]+/.exec(tex.slice(index));
      if (macro) { tokens.push({ kind: "macro", name: macro[0] }); index += macro[0].length; continue; }
    }
    if (char === "{") tokens.push({ kind: "lbrace" });
    else if (char === "}") tokens.push({ kind: "rbrace" });
    else if (char === "^") tokens.push({ kind: "caret" });
    else if (char === "_") tokens.push({ kind: "underscore" });
    else tokens.push({ kind: "char", value: char });
    index += 1;
  }
  return tokens;
}

const peek = (cursor) => cursor.tokens[cursor.pos];

function parseAtom(cursor) {
  const token = peek(cursor);
  if (!token) return "";
  if (token.kind === "lbrace") {
    cursor.pos += 1;
    const inner = parseRow(cursor);
    if (peek(cursor)?.kind === "rbrace") cursor.pos += 1;
    return `<mrow>${inner}</mrow>`;
  }
  if (token.kind === "macro") {
    cursor.pos += 1;
    if (token.name === "\\frac") {
      return `<mfrac><mrow>${parseGroup(cursor)}</mrow><mrow>${parseGroup(cursor)}</mrow></mfrac>`;
    }
    const symbol = MACROS[token.name];
    return symbol === undefined
      ? `<mtext>${escapeHtml(token.name)}</mtext>`
      : `<mi>${escapeHtml(symbol)}</mi>`;
  }
  if (token.kind === "char") {
    if (/[0-9]/.test(token.value)) {
      let digits = "";
      while (peek(cursor)?.kind === "char" && /[0-9.]/.test(peek(cursor).value)) {
        digits += cursor.tokens[cursor.pos].value;
        cursor.pos += 1;
      }
      return `<mn>${escapeHtml(digits)}</mn>`;
    }
    cursor.pos += 1;
    const tag = OPERATORS.has(token.value) ? "mo" : "mi";
    return `<${tag}>${escapeHtml(token.value)}</${tag}>`;
  }
  cursor.pos += 1;
  return "";
}

const parseGroup = (cursor) => parseAtom(cursor);

function parseRow(cursor) {
  let output = "";
  while (cursor.pos < cursor.tokens.length && peek(cursor)?.kind !== "rbrace") {
    let base = parseAtom(cursor);
    let superscript = "";
    let subscript = "";
    while (["caret", "underscore"].includes(peek(cursor)?.kind)) {
      const kind = cursor.tokens[cursor.pos].kind;
      cursor.pos += 1;
      if (kind === "caret") superscript = parseGroup(cursor);
      else subscript = parseGroup(cursor);
    }
    if (superscript && subscript) base = `<msubsup><mrow>${base}</mrow><mrow>${subscript}</mrow><mrow>${superscript}</mrow></msubsup>`;
    else if (superscript) base = `<msup><mrow>${base}</mrow><mrow>${superscript}</mrow></msup>`;
    else if (subscript) base = `<msub><mrow>${base}</mrow><mrow>${subscript}</mrow></msub>`;
    output += base;
  }
  return output;
}

export function texToMathMlRow(tex) {
  return parseRow({ tokens: tokenize(String(tex || "")), pos: 0 });
}
