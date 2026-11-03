// A single-pass recursive tokenizer over the active Markdown inline set.
// Adjacent text leaves are coalesced and equivalent emphasis delimiters are
// normalized, so a parsed-then-serialized document is a stable fixed point.
export function tokenizeInline(src) {
  const text = typeof src === "string" ? src : "";
  const nodes = parseInline(text, 0, text.length);
  return coalesce(nodes);
}

// parseInline(s, start, end) → an inline node array for s[start, end).
function parseInline(s, start, end) {
  const out = [];
  let i = start;
  let buf = "";

  const flush = () => {
    if (buf.length) {
      out.push({ type: "text", value: buf });
      buf = "";
    }
  };

  while (i < end) {
    const ch = s[i];

    // Escaped literal.
    if (ch === "\\" && i + 1 < end) {
      // LEADER-ESCAPED FENCE: escapeBlockLeader prefixes a single "\" to a leading
      // run of 3+ backticks (an inline-code span whose fence would otherwise open a
      // block code-fence). A LITERAL text backtick run is escaped per-char ("\`\`\`"),
      // so a "\" immediately before 3+ UN-escaped backticks can ONLY be this leader-
      // escape. Drop the "\" and let scanInlineCode parse the full fence as code.
      if (s[i + 1] === "`") {
        let r = 0;
        while (i + 1 + r < end && s[i + 1 + r] === "`") r += 1;
        if (r >= 3) {
          const res = scanInlineCode(s, i + 1, end);
          if (res) {
            flush();
            out.push({ type: "code", value: res.value });
            i = res.next;
            continue;
          }
        }
      }
      buf += s[i + 1];
      i += 2;
      continue;
    }

    // Inline code — a run of backticks; close on the SAME-length run.
    if (ch === "`") {
      const res = scanInlineCode(s, i, end);
      if (res) {
        flush();
        out.push({ type: "code", value: res.value });
        i = res.next;
        continue;
      }
      // No closing run — literal backtick.
      buf += ch;
      i += 1;
      continue;
    }

    // Wikilink [[t]] / [[t|a]].
    if (ch === "[" && s[i + 1] === "[") {
      const res = scanWikilink(s, i, end);
      if (res) {
        flush();
        out.push(res.node);
        i = res.next;
        continue;
      }
      // not a wikilink — fall through to link / literal
    }

    // Link [text](href).
    if (ch === "[") {
      const res = scanLink(s, i, end);
      if (res) {
        flush();
        out.push(res.node);
        i = res.next;
        continue;
      }
      buf += ch;
      i += 1;
      continue;
    }

    // Strong / em — ** or * (and __ / _).
    if (ch === "*" || ch === "_") {
      const res = scanEmphasis(s, i, end, ch);
      if (res) {
        flush();
        out.push(res.node);
        i = res.next;
        continue;
      }
      buf += ch;
      i += 1;
      continue;
    }

    // Highlight ==x==.
    if (ch === "=" && s[i + 1] === "=") {
      const res = scanDelimited(s, i, end, "==");
      if (res) {
        flush();
        out.push({ type: "highlight", children: coalesce(parseInline(s, res.innerStart, res.innerEnd)) });
        i = res.next;
        continue;
      }
      buf += ch;
      i += 1;
      continue;
    }

    // Strikethrough ~~x~~.
    if (ch === "~" && s[i + 1] === "~") {
      const res = scanDelimited(s, i, end, "~~");
      if (res) {
        flush();
        out.push({ type: "strikethrough", children: coalesce(parseInline(s, res.innerStart, res.innerEnd)) });
        i = res.next;
        continue;
      }
      buf += ch;
      i += 1;
      continue;
    }

    // Tag #name — only at a word boundary (start, or after whitespace/punct).
    if (ch === "#") {
      const res = scanTag(s, i, end);
      if (res) {
        flush();
        out.push(res.node);
        i = res.next;
        continue;
      }
      buf += ch;
      i += 1;
      continue;
    }

    buf += ch;
    i += 1;
  }
  flush();
  return out;
}

// scanInlineCode(s, i, end) → { value, next } | null. Opens on a run of N
// backticks; closes on the next run of EXACTLY N backticks. A one-space pad on
// each side is stripped (the CommonMark rule the serializer applies).
function scanInlineCode(s, i, end) {
  let n = 0;
  let k = i;
  while (k < end && s[k] === "`") {
    n += 1;
    k += 1;
  }
  // find a closing run of exactly n backticks
  let j = k;
  while (j < end) {
    if (s[j] === "`") {
      let m = 0;
      let p = j;
      while (p < end && s[p] === "`") {
        m += 1;
        p += 1;
      }
      if (m === n) {
        let value = s.slice(k, j);
        // strip a single symmetric space pad
        if (
          value.length >= 2 &&
          value[0] === " " &&
          value[value.length - 1] === " " &&
          value.trim().length > 0
        ) {
          value = value.slice(1, -1);
        }
        return { value, next: p };
      }
      j = p;
    } else {
      j += 1;
    }
  }
  return null;
}

// scanWikilink(s, i, end) → { node, next } | null for [[t]] / [[t|a]].
function scanWikilink(s, i, end) {
  // i points at the first "[" of "[[".
  const close = s.indexOf("]]", i + 2);
  if (close === -1 || close >= end) return null;
  const inner = s.slice(i + 2, close);
  if (/\n|\r/.test(inner)) return null;
  const pipe = inner.indexOf("|");
  let target;
  let alias = null;
  if (pipe === -1) {
    target = inner;
  } else {
    target = inner.slice(0, pipe);
    alias = inner.slice(pipe + 1);
  }
  const label = alias != null ? alias : target;
  const node = {
    type: "wikilink",
    target,
    children: label === "" ? [] : [{ type: "text", value: label }],
  };
  if (alias != null) node.alias = alias;
  return { node, next: close + 2 };
}

// scanLink(s, i, end) → { node, next } | null for [text](href).
function scanLink(s, i, end) {
  // i points at "[". Find the matching "]" (no nested brackets in our output).
  let depth = 0;
  let j = i;
  let textEnd = -1;
  for (; j < end; j++) {
    const c = s[j];
    if (c === "\\") {
      j += 1;
      continue;
    }
    if (c === "[") depth += 1;
    else if (c === "]") {
      depth -= 1;
      if (depth === 0) {
        textEnd = j;
        break;
      }
    }
  }
  if (textEnd === -1) return null;
  if (s[textEnd + 1] !== "(") return null;
  const hrefEnd = s.indexOf(")", textEnd + 2);
  if (hrefEnd === -1 || hrefEnd >= end) return null;
  const href = s.slice(textEnd + 2, hrefEnd);
  if (/\s/.test(href)) return null;
  const inner = s.slice(i + 1, textEnd);
  return {
    node: { type: "link", href, children: coalesce(parseInline(inner, 0, inner.length)) },
    next: hrefEnd + 1,
  };
}

// scanEmphasis(s, i, end, marker) → { node, next } | null. Handles ** / __ (strong)
// and * / _ (em). Closes on the matching run; the inner is parsed recursively.
function scanEmphasis(s, i, end, marker) {
  // double?
  const isDouble = s[i + 1] === marker;
  const delim = isDouble ? marker + marker : marker;
  const res = scanDelimited(s, i, end, delim);
  if (!res) return null;
  const children = coalesce(parseInline(s, res.innerStart, res.innerEnd));
  // An empty emphasis (** **) shouldn't occur from our serializer; guard anyway.
  const node = isDouble
    ? { type: "strong", children }
    : { type: "em", children };
  return { node, next: res.next };
}

// scanDelimited(s, i, end, delim) → { innerStart, innerEnd, next } | null. Opens
// with `delim` at i; closes on the next `delim` not immediately following the
// open. Non-greedy minimal match. Skips escaped chars in the search.
function scanDelimited(s, i, end, delim) {
  const dl = delim.length;
  const innerStart = i + dl;
  let j = innerStart;
  while (j < end) {
    if (s[j] === "\\") {
      j += 2;
      continue;
    }
    if (s.startsWith(delim, j)) {
      // Avoid matching a longer run as the close (e.g. *** for *). For a single
      // marker, ensure the close isn't part of a longer same-char run that the
      // open also wasn't. Simplicity: accept the first close >= innerStart+1.
      if (j > innerStart) {
        return { innerStart, innerEnd: j, next: j + dl };
      }
    }
    j += 1;
  }
  return null;
}

// scanTag(s, i, end) → { node, next } | null for a #name tag.
//
// NO word-boundary guard. The serializer ALWAYS backslash-escapes a literal "#"
// in plain text (escapeInlineText), so an UNESCAPED "#" reaching the tokenizer
// can ONLY be a tag the serializer emitted — even when it directly abuts the
// previous run (e.g. "#a#b" = two adjacent tags, or "✨#x" = text then tag). A
// boundary rule would mis-read the second of two abutting tags as literal text
// and break the fixed point. "C#" (literal) never gets here: its "#" is escaped.
function scanTag(s, i, end) {
  let j = i + 1;
  let name = "";
  while (j < end) {
    const c = s[j];
    // Stop at whitespace, "#", or ANY markdown-active delimiter so a tag adjacent
    // to markup (#tag**bold**) does not swallow the markup into the name. Matches
    // the serializer's tag-name gate (inlineNodeIsLossless) exactly.
    if (/[\s#*_~`\[\]\\<|()]/.test(c)) break;
    name += c;
    j += 1;
  }
  if (name.length === 0) return null;
  return { node: { type: "tag", name }, next: j };
}

// Coalesce adjacent text leaves (a tokenizer may emit several) and drop empty
// text leaves — matching the projection fixed-point shape (empty text dropped).
function coalesce(nodes) {
  const out = [];
  for (const n of nodes) {
    if (n.type === "text") {
      if (n.value === "") continue;
      const last = out[out.length - 1];
      if (last && last.type === "text") {
        last.value += n.value;
        continue;
      }
      out.push({ type: "text", value: n.value });
    } else {
      out.push(n);
    }
  }
  return out;
}

// unescapeInline — strip backslash escapes from a FLAT string (heading text /
// callout title), where there are no marks to parse, just literal escaping.
export function unescapeInline(text) {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "\\" && i + 1 < text.length) {
      out += text[i + 1];
      i += 1;
    } else {
      out += text[i];
    }
  }
  return out;
}
