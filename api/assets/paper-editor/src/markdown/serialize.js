// Markdown serializer — PortableDoc blocks to dependency-free Markdown text.
// PortableDoc BLOCK-AST (the system of record) and Markdown text.
//
//   blocksToMarkdown(blocks) -> string
//   markdownToBlocks(md)     -> blocks
//
// NO DOM, NO server, NO CDN, NO npm deps — the editor vendors everything, so the
// scanner + inline tokenizer are hand-rolled. This is the Phase-5 source-mode
// FOUNDATION (a Markdown view of a paper) and is independently useful (export /
// copy-as-markdown / AI round-trips). It is NOT wired into any editor yet — only
// the test imports it, so the committed bundle is byte-identical with it present.
//
// ── the shapes it serializes (verified against the real code) ────────────────
//
// INLINE TREE (convert.js:12-21, :141-177; compose.ex render):
//   { type:"text",  value }                     leaf
//   { type:"code",  value }                     leaf — inline code
//   { type:"strong",        children:[ … ] }    **x**
//   { type:"em",            children:[ … ] }    *x*
//   { type:"strikethrough", children:[ … ] }    ~~x~~
//   { type:"underline",     children:[ … ] }    NO clean markdown → LOSSY
//   { type:"link", href, children:[ … ] }       [text](href)
//   { type:"wikilink", target, alias?, docId?, children:[ … ] }
//                                               [[target]] / [[target|alias]];
//                                               a carried docId is LOSSY
//   { type:"tag", name }                        leaf-token → #name
//   { type:"blockref", target, anchor }         leaf-token → target NOT in md → LOSSY
//
// BLOCKS (blocks.ex default_block/2; compose.ex/walk.ex render):
//   heading   { id, type:"heading", level:1..3, text }        "#"*level + " " + text
//   paragraph { id, type:"paragraph", content:[inline] }      the inline tree
//   list      { id, type:"list", ordered, items:[[inline],…] } "- "/"1. " per item
//   callout   { id, type:"callout", tone, title?, collapsible?, collapsed?, content:[inline] }
//                                                             Obsidian admonition (> [!tone])
//   code      { id, type:"code", value, lang? }                ```lang fence
//   diagram   { id, type:"diagram", source, caption? }         ```mermaid fence (+ caption)
//   divider   { id, type:"divider" }                           ---
//
// EVERYTHING ELSE — the 7 field-* + field-image/field-reference, sheet, embed,
// section/composite/arrayOf/codelist/localizedText, AND any prose block whose
// natural markdown would be LOSSY (underline, wikilink-with-docId, blockref) —
// is emitted as a one-line HTML-comment JSON SENTINEL carrying the WHOLE block
// verbatim:  <!--bp:block {…the exact block JSON…}-->  . Markdown passes raw HTML
// comments through, so a sentinel round-trips byte-lossless. CORRECTNESS BEATS
// PRETTINESS: any block we cannot serialize+parse faithfully uses the sentinel.

import { clampLevel, EMPTY_PARAGRAPH_MARKER, SENTINEL_CLOSE, SENTINEL_OPEN } from "./shared.js";

// The prose block kinds with a natural markdown rendering (everything else →
// sentinel). A prose block STILL falls back to the sentinel when its inline tree
// carries a non-representable node (see inlineIsLossless).
const NATURAL_BLOCK_TYPES = new Set([
  "heading",
  "paragraph",
  "list",
  "callout",
  "blockquote",
  "code",
  "diagram",
  "divider",
  "image",
]);

// ═══════════════════════════════════════════════════════════════════════════
// blocksToMarkdown
// ═══════════════════════════════════════════════════════════════════════════

export function blocksToMarkdown(blocks) {
  const out = [];
  (blocks || []).forEach((block) => {
    out.push(serializeBlock(block));
  });
  // One blank line between blocks; trailing newline-free (a stable fixed point).
  return out.join("\n\n");
}

// serializeBlock(block) → the markdown chunk for ONE block (no surrounding blank
// lines). Falls back to the sentinel for any non-natural kind OR any natural
// prose block whose inline tree is not losslessly representable.
function serializeBlock(block) {
  if (!block || typeof block !== "object" || typeof block.type !== "string") {
    return sentinel(block);
  }
  const type = block.type;

  if (!NATURAL_BLOCK_TYPES.has(type)) return sentinel(block);
  // Author alignment has no markdown; the sentinel carries the block byte-identically.
  if ((type === "paragraph" || type === "heading") && block.align != null) return sentinel(block);

  switch (type) {
    case "heading":
      return serializeHeading(block);
    case "paragraph":
      return serializeParagraph(block);
    case "list":
      return serializeList(block);
    case "callout":
      return serializeCallout(block);
    case "blockquote":
      return serializeBlockquote(block);
    case "code":
      return serializeCode(block);
    case "diagram":
      return serializeDiagram(block);
    case "divider":
      return "---";
    case "image":
      return serializeImage(block);
    default:
      return sentinel(block);
  }
}

// ![alt](src) — only for a plain image (id/type/src/alt and nothing else) whose src
// and alt cannot break the syntax; a sized, locked or otherwise decorated image
// rides the sentinel so it comes back byte-identical.
function serializeImage(block) {
  const keys = Object.keys(block).filter((k) => k !== "id" && k !== "type");
  if (keys.some((k) => k !== "src" && k !== "alt")) return sentinel(block);
  const src = typeof block.src === "string" ? block.src : "";
  const alt = typeof block.alt === "string" ? block.alt : "";
  if (src === "" || /[\s()]/.test(src) || /[\]\[\n\r]/.test(alt)) return sentinel(block);
  return "![" + alt + "](" + src + ")";
}

// The sentinel: a one-line HTML comment carrying the whole block JSON verbatim.
// JSON.stringify never emits a literal "-->" (">" is not escaped, but the close
// sequence "--" only appears if the data contains it). We guard the close by
// splitting any literal "--" run that could prematurely terminate the comment;
// the parser reverses it. In practice block JSON rarely contains "--", but the
// guard makes the sentinel bullet-proof for arbitrary content.
function sentinel(block) {
  const json = JSON.stringify(block);
  return SENTINEL_OPEN + escapeSentinelPayload(json) + SENTINEL_CLOSE;
}

// "-->" cannot appear inside an HTML comment. JSON of a block can in theory carry
// the substring "--" (e.g. text "a--b") or even "-->" inside a string value. We
// zero-width-guard every "--" by inserting a sentinel escape the parser strips,
// so the comment can never close early. We use the rare token \u0000 (NUL) which
// JSON.stringify emits as the 6-char "\u0000" escape — so a real NUL in the data
// is already "\u0000" and never collides with our raw-NUL guard token.
function escapeSentinelPayload(json) {
  // Insert a raw NUL between any two hyphens so "-->" / "--" can never close the
  // comment. JSON.stringify of the payload escapes a DATA NUL to "\u0000", so a
  // raw NUL here is unambiguously OUR guard.
  return json.replace(/--/g, "-\u0000-");
}

function serializeHeading(block) {
  const level = clampLevel(block.level);
  const text = typeof block.text === "string" ? block.text : "";
  // ATX headings can't preserve leading/trailing whitespace or a newline — the
  // parser's "#{1,6}\s+" eats leading space and a trailing "###" closer / blank
  // is ambiguous. A heading whose text would not survive that normalization falls
  // back to the sentinel (correctness over prettiness). A clean single-line text
  // with no edge whitespace renders naturally.
  if (text !== text.trim() || /[\n\r]/.test(text)) return sentinel(block);
  // Heading is a FLAT string (no inline marks) — escape so a literal "#"/"*" in
  // the text round-trips as text, and a "# " prefix in the text is not re-read as
  // a deeper heading.
  const escaped = escapeHeadingText(text);
  // An all-escaped-empty heading ("# ") would parse back with empty text, which is
  // fine; but a heading whose escaped text is empty (text was "") still round-trips
  // as "# " → text "" via the parser, so no special-case needed.
  return "#".repeat(level) + " " + escaped;
}

// ── paragraph ────────────────────────────────────────────────────────────────
function serializeParagraph(block) {
  const content = block.content || [];
  if (!inlineIsLossless(content)) return sentinel(block);
  const md = inlineToMarkdown(content);
  // An empty paragraph serializes to a single zero-width sentinel-free marker so
  // it round-trips as an empty paragraph (a bare blank line would be swallowed by
  // the blank-line block separator). We use the HTML comment <!--bp:empty-->.
  if (md.length === 0) return EMPTY_PARAGRAPH_MARKER;
  // A paragraph whose inline produced an embedded newline (a text leaf with "\n")
  // would split across block lines on parse → sentinel (rare; fuzz prose has none).
  if (/[\n\r]/.test(md)) return sentinel(block);
  // Escape a leading marker so a paragraph that LOOKS like a heading/list/quote/
  // fence/divider is not re-parsed as one. A markup leader we CANNOT neutralize
  // (a leading "* " from an em whose content starts with a space) returns null →
  // sentinel (correctness over prettiness).
  const escaped = escapeBlockLeader(md);
  if (escaped === null) return sentinel(block);
  return escaped;
}

// ── list ─────────────────────────────────────────────────────────────────────
// A list item's inline array, whatever carrier the wire used ({content|text, checked} maps
// for checklist items, JSON-encoded strings, plain strings).
function listItemInline(item) {
  if (Array.isArray(item)) return item;
  if (item && typeof item === "object") {
    if (Array.isArray(item.content)) return item.content;
    return typeof item.text === "string" ? [{ type: "text", value: item.text }] : [];
  }
  if (typeof item === "string") return [{ type: "text", value: item }];
  return null;
}

function serializeList(block) {
  const ordered = block.ordered === true;
  const task = block.task === true;
  const rawItems = block.items || [];
  const items = rawItems.map(listItemInline);
  // A checklist item must be a map to carry `checked`; anything else is lossy here.
  if (task && rawItems.some((item) => !(item && typeof item === "object" && !Array.isArray(item)))) return sentinel(block);
  // If ANY item's inline is lossy, sentinel the whole list (correctness first).
  for (const item of items) {
    if (!inlineIsLossless(item)) return sentinel(block);
  }
  if (items.length === 0) {
    // An empty list has no natural markdown line — sentinel it so it round-trips.
    return sentinel(block);
  }
  // A list-item body whose markdown begins (or ends) with whitespace can't round-
  // trip: the marker regex "\d+[.)]\s+" / "[-+*]\s+" swallows leading whitespace,
  // and a trailing space on a line is not significant. Sentinel the whole list in
  // that case (correctness over prettiness). Also catch a body that ends in a
  // backslash (an escape that would consume the newline join).
  const bodies = items.map(inlineToMarkdown);
  for (const body of bodies) {
    if (body.length > 0 && (/^\s/.test(body) || /\s$/.test(body))) {
      return sentinel(block);
    }
    if (/[\n\r]/.test(body)) return sentinel(block);
  }
  const lines = bodies.map((body, i) => {
    const marker = task ? (rawItems[i].checked === true ? "- [x] " : "- [ ] ") : ordered ? `${i + 1}. ` : "- ";
    // NO leader-escaping needed: the marker prefix means the parser consumes the
    // marker first and inline-tokenizes the REST of the line (never block-scans
    // it), so a body that itself begins with "* "/"- "/"#" round-trips verbatim.
    return marker + body;
  });
  return lines.join("\n");
}

// ── callout (Obsidian admonition) ────────────────────────────────────────────
//
// > [!tone] Title          (title optional, on the same line)
// > body line 1
// > body line 2
//
// collapsible adds a "+"/"-" suffix after the ]: "+" = expandable-but-open,
// "-" = collapsed. A non-collapsible callout has NO suffix. Mirrors the editor's
// _maybeCalloutShorthand regex  ^>\s*\[!(\w+)\]([+-]?)\s$  (canvas/index.js:1096).
// A plain quote is `> ` lines. A quote carrying a cite/attribution has no markdown
// form that survives the round trip, so it rides the sentinel like any other extra.
function serializeBlockquote(block) {
  const cite = block.cite ?? block.attribution;
  if (typeof cite === "string" && cite.trim() !== "") return sentinel(block);
  const content = Array.isArray(block.content) ? block.content : [];
  if (!inlineIsLossless(content)) return sentinel(block);
  const md = inlineToMarkdown(content);
  return md.split("\n").map((line) => (line ? "> " + line : ">")).join("\n");
}

function serializeCallout(block) {
  const content = block.content || [];
  if (!inlineIsLossless(content)) return sentinel(block);
  // The tone must be a single \w+ token to round-trip through the [!tone] syntax;
  // anything weird (spaces, punctuation) falls back to the sentinel.
  const tone = typeof block.tone === "string" && block.tone !== "" ? block.tone : "info";
  if (!/^\w+$/.test(tone)) return sentinel(block);

  // The title rides the header line. A title containing a newline can't live on
  // one header line → sentinel. A title is OPTIONAL: absent vs "" differ in the
  // block (compose maybe_put drops nil but keeps ""), so we must round-trip the
  // distinction. We encode: absent → no title; present (incl "") → a title we can
  // re-read. An empty-string title is not expressible after "[!tone] " (trailing
  // space would be trimmed), so a present-but-empty title forces the sentinel.
  const hasTitle = block.title != null;
  if (hasTitle) {
    if (typeof block.title !== "string") return sentinel(block);
    if (block.title.length === 0) return sentinel(block);
    if (/[\n\r]/.test(block.title)) return sentinel(block);
    // The parser trims the header-line title, so a title with edge whitespace
    // would not round-trip → sentinel it.
    if (block.title !== block.title.trim()) return sentinel(block);
  }

  const collapsible = block.collapsible === true;
  const collapsed = block.collapsed === true;
  // collapsed without collapsible is not expressible in the +/- grammar (the
  // suffix implies collapsible) → sentinel that odd shape.
  if (collapsed && !collapsible) return sentinel(block);
  const suffix = collapsible ? (collapsed ? "-" : "+") : "";

  let header = `> [!${tone}]${suffix}`;
  if (hasTitle) header += " " + escapeCalloutTitle(block.title);

  const bodyMd = inlineToMarkdown(content);
  // Prefix every body line with "> ". An empty body → header only.
  const bodyLines = bodyMd.length === 0 ? [] : bodyMd.split("\n");
  const lines = [header, ...bodyLines.map((l) => "> " + l)];
  return lines.join("\n");
}

// ── code (fenced) ────────────────────────────────────────────────────────────
function serializeCode(block) {
  const value = typeof block.value === "string" ? block.value : "";
  const lang = typeof block.lang === "string" ? block.lang : "";
  // A lang with whitespace/backticks can't ride the fence info string → sentinel.
  if (lang !== "" && /[\s`]/.test(lang)) return sentinel(block);
  // A code block whose lang is exactly "mermaid" would re-parse as a DIAGRAM (the
  // fence info "mermaid" is the diagram marker). Sentinel it so a code/mermaid
  // block never silently becomes a diagram block.
  if (lang === "mermaid") return sentinel(block);
  const fence = pickFence(value);
  return fence + lang + "\n" + value + "\n" + fence;
}

// ── diagram (fenced mermaid) ─────────────────────────────────────────────────
//
// ```mermaid<newline><source><newline>```  — plus an OPTIONAL caption. A caption
// is carried losslessly on the fence info string AFTER "mermaid" as a percent-
// encoded token: ```mermaid caption=<enc>  . Round-trips any caption (spaces,
// punctuation, unicode) without a sentinel. An absent/empty caption emits no
// token (compose defaults a missing caption to "", so absent == "").
function serializeDiagram(block) {
  const source = typeof block.source === "string" ? block.source : "";
  const caption = typeof block.caption === "string" ? block.caption : "";
  const fence = pickFence(source);
  let info = "mermaid";
  if (caption !== "") info += " caption=" + encodeURIComponent(caption);
  return fence + info + "\n" + source + "\n" + fence;
}

// pickFence(value) → a backtick fence at least 3 long AND longer than the longest
// backtick run inside the value, so a value containing ``` survives unambiguously
// (the fence-length bump the prompt calls out). Pure string scan.
function pickFence(value) {
  let longest = 0;
  let cur = 0;
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "`") {
      cur += 1;
      if (cur > longest) longest = cur;
    } else {
      cur = 0;
    }
  }
  const len = Math.max(3, longest + 1);
  return "`".repeat(len);
}

// ═══════════════════════════════════════════════════════════════════════════
// INLINE serialization — the portable-doc inline tree → markdown
// ═══════════════════════════════════════════════════════════════════════════

// True when EVERY node in an inline array is losslessly representable in readable
// markdown. underline (no md), wikilink WITH a docId (not in [[…]] syntax), and
// blockref (target not in md) are NOT — a block carrying any of them sentinels.
function inlineIsLossless(inline) {
  if (!Array.isArray(inline)) return false;
  if (!inline.every(inlineNodeIsLossless)) return false;
  // ARRAY-LEVEL gates — boundary ambiguities that don't round-trip:
  for (let i = 1; i < inline.length; i++) {
    const prev = inline[i - 1];
    const cur = inline[i];
    if (!prev || !cur) continue;
    // (a) Two adjacent inline-code leaves produce ambiguous abutting backtick runs
    //     (`x``y` reads as ONE span). Sentinel rather than emit ambiguous markdown.
    if (cur.type === "code" && prev.type === "code") return false;
    // (b) A #tag has NO closing delimiter, so a following node that begins with a
    //     tag-name character would be absorbed into the tag name (#café + "hello"
    //     → "#caféhello"). It is safe ONLY when the next node begins with a tag
    //     TERMINATOR (whitespace / # / markdown-active char) — i.e. another tag,
    //     emphasis/strike (*_~), code (`), link/wikilink ([), or a text leaf whose
    //     first char is a terminator or gets backslash-escaped. A text leaf
    //     starting with a plain name char is the unsafe case.
    if (prev.type === "tag" && !nodeStartsWithTagTerminator(cur)) return false;
  }
  return true;
}

// True when `node`, serialized, begins with a character that TERMINATES a tag-name
// scan — so a preceding #tag stays its own token. Markup nodes start with an
// active delimiter (`*_~`[`) which terminates. A text node is safe iff its first
// markdown character is a terminator: whitespace, or an active char that
// escapeInlineText turns into "\X" (and "\" is itself a terminator). The only
// unsafe text is one starting with a plain name char (letter/digit/-/etc.).
function nodeStartsWithTagTerminator(node) {
  if (!node || typeof node !== "object") return true;
  if (node.type === "text") {
    const v = node.value || "";
    if (v.length === 0) return true; // empty leaves are coalesced away
    const c0 = v[0];
    if (/\s/.test(c0)) return true; // whitespace terminates
    // escapeInlineText escapes this set with a leading "\" (a terminator). Any
    // OTHER first char is a plain name char → would merge into the tag → unsafe.
    return /[\\*_~`\[\]#|<]/.test(c0);
  }
  // strong/em/strike → "*"/"_"/"~"; code → "`"; link/wikilink → "["; tag → "#".
  // Every one of these first chars is a tag terminator.
  return true;
}

function inlineNodeIsLossless(node) {
  if (!node || typeof node !== "object") return false;
  switch (node.type) {
    case "text":
      // A literal "==" would read back as a highlight delimiter; sentinel that leaf.
      return typeof node.value === "string" && !node.value.includes("==");
    case "code": {
      if (typeof node.value !== "string") return false;
      // An inline-code value containing a newline can't ride a single-line span.
      if (/[\n\r]/.test(node.value)) return false;
      // An all-whitespace (non-empty) value can't be expressed: CommonMark's pad-
      // strip rule never strips an all-space content, so the pad would survive.
      if (node.value.length > 0 && node.value.trim() === "") return false;
      return true;
    }
    case "strong":
    case "em":
      return inlineIsLossless(node.children || []);
    case "strikethrough": {
      // A strike DIRECTLY inside a strike would emit "~~~~…~~~~" — an ambiguous
      // abutting "~~" run the tokenizer can't split (strike has no alternate
      // delimiter the way *-emphasis has "*"/"_"). Sentinel that shape (rare; a
      // reachable projection fixed point via strike>em>strike etc.).
      const kids = node.children || [];
      if (kids.some((k) => k && k.type === "strikethrough")) return false;
      return inlineIsLossless(kids);
    }
    case "highlight": {
      const kids = node.children || [];
      if (kids.some((k) => k && k.type === "highlight")) return false;
      return inlineIsLossless(kids);
    }
    case "link":
      // An href containing ")" or whitespace would break [text](href); fall back
      // to the sentinel for those rare cases.
      if (typeof node.href !== "string") return false;
      if (/[\s)]/.test(node.href)) return false;
      return inlineIsLossless(node.children || []);
    case "wikilink": {
      // docId is not expressible in [[target|alias]] → lossy.
      if (node.docId != null) return false;
      if (typeof node.target !== "string") return false;
      // A target/alias containing "]" or "|" would break the [[…]] syntax.
      if (/[\]\|\n\r]/.test(node.target)) return false;
      if (node.alias != null) {
        if (typeof node.alias !== "string") return false;
        if (/[\]\|\n\r]/.test(node.alias)) return false;
      }
      // The visible children must EXACTLY equal the rendered label ([[t]] shows t,
      // [[t|a]] shows a) — otherwise parsing back loses the custom child text.
      return wikilinkChildrenMatchLabel(node);
    }
    case "tag":
      // #name — a tag is written bare (NOT escaped), so a name with whitespace,
      // "#", or any markdown-active delimiter can't round-trip → sentinel it. The
      // allowed set matches scanTag's terminator set exactly.
      return typeof node.name === "string" && /^[^\s#*_~`\[\]\\<|()]+$/.test(node.name);
    case "underline":
      return false; // no clean markdown for underline
    case "sub":
    case "sup":
      return false; // no clean markdown for sub/superscript either — the sentinel carries them
    case "blockref":
      return false; // target/anchor not expressible inline
    default:
      return false;
  }
}

// A wikilink's children render the LABEL. [[target]] shows `target`; [[target|alias]]
// shows `alias`. For a lossless round-trip the children must be exactly one text
// leaf equal to that label (the convert.js inline serializer produces this shape).
function wikilinkChildrenMatchLabel(node) {
  const label = node.alias != null ? node.alias : node.target;
  const children = node.children || [];
  if (children.length === 0) {
    // No children: only lossless when the label is empty (nothing to show).
    return label === "";
  }
  if (children.length !== 1) return false;
  const c = children[0];
  return c && c.type === "text" && c.value === label;
}

// inlineToMarkdown(inline, parentEmphChar) → the markdown string for an inline
// array. Plain text is markdown-escaped so a literal *, _, `, [, ], etc. round-
// trips as text. `parentEmphChar` is the delimiter CHAR ("*" or "_") of the
// nearest enclosing *-family emphasis (strong/em), or null when the nearest
// enclosing emphasis is a strike / there is none — it drives the same-family
// delimiter ALTERNATION below.
function inlineToMarkdown(inline, parentEmphChar) {
  return (inline || []).map((n) => inlineNodeToMarkdown(n, parentEmphChar)).join("");
}

// The two *-family emphasis delimiters. CommonMark reads ** / __ as STRONG and
// * / _ as EM, so a nested strong/em can use the OTHER char to avoid an ambiguous
// abutting run. We escape every LITERAL "*"/"_" in text (escapeInlineText), so the
// only un-escaped "*"/"_" the tokenizer sees is a delimiter WE chose here.
function emDelims(ch) {
  return ch === "_" ? { strong: "__", em: "_" } : { strong: "**", em: "*" };
}

function inlineNodeToMarkdown(node, parentEmphChar) {
  if (!node || typeof node !== "object") return "";
  switch (node.type) {
    case "text":
      return escapeInlineText(node.value || "");
    case "code":
      return inlineCode(node.value || "");
    case "strong":
    case "em": {
      // A *-family emphasis directly inside another *-family emphasis would emit an
      // abutting same-char run ("***x***" / "****x****") the tokenizer mis-reads.
      // ALTERNATE the delimiter char: use the OTHER of "*"/"_" than the enclosing
      // *-family emphasis used (top level / inside a strike → "*"). Consecutive
      // nesting levels therefore alternate "*"↔"_" and never merge.
      const ch = parentEmphChar === "*" ? "_" : "*";
      const d = emDelims(ch);
      const delim = node.type === "strong" ? d.strong : d.em;
      return delim + inlineToMarkdown(node.children || [], ch) + delim;
    }
    case "strikethrough":
      // strike's "~~" never abuts a "*"/"_"; reset parentEmphChar to null so a
      // *-family emphasis INSIDE the strike starts fresh at "*". (A strike DIRECTLY
      // inside a strike is gated to a sentinel by inlineNodeIsLossless — "~~" has
      // no alternate delimiter, so "~~~~" can't be disambiguated.)
      return "~~" + inlineToMarkdown(node.children || [], null) + "~~";
    case "highlight":
      // "==" has no alternate delimiter either; a highlight directly inside a highlight is
      // gated to a sentinel by inlineNodeIsLossless, like strike-in-strike.
      return "==" + inlineToMarkdown(node.children || [], null) + "==";
    case "link":
      return "[" + inlineToMarkdown(node.children || [], null) + "](" + (node.href || "") + ")";
    case "wikilink": {
      const target = node.target || "";
      return node.alias != null ? `[[${target}|${node.alias}]]` : `[[${target}]]`;
    }
    case "tag":
      return "#" + (node.name || "");
    default:
      // Should be unreachable (inlineIsLossless gates the block first), but never
      // garble: emit nothing rather than wrong markup.
      return "";
  }
}

// inlineCode(value) → a backtick-delimited inline code span. The delimiter is a
// backtick run one longer than the longest run inside the value; a space pad is
// added when the value starts/ends with a backtick (CommonMark rule) so e.g.
// "`x`" round-trips. We keep it simple+lossless: pad with one space each side
// when needed and strip it back on parse.
function inlineCode(value) {
  let longest = 0;
  let cur = 0;
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "`") {
      cur += 1;
      if (cur > longest) longest = cur;
    } else cur = 0;
  }
  const ticks = "`".repeat(Math.max(1, longest + 1));
  // CommonMark: a code span's content has ONE leading + ONE trailing space stripped
  // iff BOTH edges are spaces AND the content is not all-spaces. So to encode a
  // value whose own edge is a space or a backtick, we pad ONE space each side; the
  // parser strips exactly that pad. (An all-whitespace value is gated upstream by
  // inlineNodeIsLossless → sentinel, since the strip rule won't restore it.)
  const needsPad =
    value.length > 0 &&
    (value[0] === " " ||
      value[value.length - 1] === " " ||
      value[0] === "`" ||
      value[value.length - 1] === "`");
  const inner = needsPad ? " " + value + " " : value;
  return ticks + inner + ticks;
}

// ── escaping ─────────────────────────────────────────────────────────────────

// escapeInlineText — backslash-escape the markdown-active characters in PLAIN
// text so they round-trip as literal text, not markup. The inverse is the
// tokenizer's backslash handling. We escape the minimal set our serializer +
// tokenizer recognize: \ * _ ~ ` [ ] # | < (plus a leading run handled by
// escapeBlockLeader at the line level).
function escapeInlineText(text) {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (
      ch === "\\" ||
      ch === "*" ||
      ch === "_" ||
      ch === "~" ||
      ch === "`" ||
      ch === "[" ||
      ch === "]" ||
      ch === "#" ||
      ch === "|" ||
      ch === "<"
    ) {
      out += "\\" + ch;
    } else {
      out += ch;
    }
  }
  return out;
}

// Heading/callout-title text is a FLAT string (no inline marks). We escape the
// same active set so a "#"/"*"/etc. in the text is literal, plus we don't need to
// worry about block leaders (handled by the "# " prefix / "> " prefix).
function escapeHeadingText(text) {
  return escapeInlineText(text);
}
function escapeCalloutTitle(text) {
  return escapeInlineText(text);
}

// escapeBlockLeader — when an inline-serialized line BEGINS with a sequence the
// block scanner would read as a different block (heading "#", list "-"/"*"/"1.",
// quote ">", fence "```", divider "---"), backslash-escape the first char so the
// line is read as a paragraph/list-body. The text content is already inline-
// escaped; this guards the FIRST visible char. Because escapeInlineText already
// escapes a leading "#"/"["/"*"/"~"/"`", the only un-escaped leaders left are
// produced by MARKUP (e.g. a paragraph that is just a link starting "[") — those
// are already escaped — or by a digit-dot / "-"/">"/" " from literal text, which
// escapeInlineText does NOT touch. Handle those here.
function escapeBlockLeader(line) {
  if (line.length === 0) return line;
  // Leading BACKTICK FENCE: a line beginning with a run of 3+ backticks is read by
  // the block scanner (matchFenceOpen, /^`{3,}/) as a FENCED CODE BLOCK. This
  // happens when the paragraph's first inline node is an inline-code span whose
  // value forces a 3+-backtick delimiter (e.g. value contains "``" → fence "```").
  // Backslash-escape the FIRST backtick so the line no longer opens with a bare
  // "```" run → the block scanner skips it and the line is inline-tokenized. The
  // tokenizer inverts this: a single "\" before a 3+-backtick run is the leader-
  // escape (a LITERAL text backtick run is escaped per-char as "\`\`\`", never as
  // "\```"), so it drops the "\" and parses the full fence as the code span.
  if (/^`{3,}/.test(line)) {
    return "\\" + line;
  }
  // Ordered-list leader: digits then ". " or ") " at line start. The digits are
  // literal text (un-escaped), so backslash-escaping the "."/"" neutralizes it.
  const olMatch = /^(\d+)([.)])(\s|$)/.exec(line);
  if (olMatch) {
    return olMatch[1] + "\\" + olMatch[2] + line.slice(olMatch[1].length + 1);
  }
  const first = line[0];
  // A leading "* "/"+ "/"- " bullet. Distinguish MARKUP from literal text:
  //   * a literal "-"/"+" from text is NOT inline-escaped, so it is safe to
  //     backslash-escape here ("\-" → literal "-" on parse).
  //   * a leading "*" reaching here is ALWAYS an emphasis DELIMITER (escapeInlineText
  //     escapes a literal "*" to "\*"). When that em's content starts with a space
  //     ("* x*") the line looks like a bullet, and we CANNOT escape the "*" without
  //     breaking the emphasis → signal sentinel (null).
  if (first === "*") {
    // Only "* " (star + whitespace) collides with the bullet syntax. "*x*" (em with
    // no leading space) is safe.
    if (/^\*\s/.test(line)) return null;
    return line;
  }
  if (first === "-" || first === "+") {
    // Escape the leading marker char (literal text leader). Also covers "---".
    return "\\" + line;
  }
  if (first === ">") {
    return "\\" + line;
  }
  return line;
}

// ═══════════════════════════════════════════════════════════════════════════
// End of the Markdown serializer.
// ═══════════════════════════════════════════════════════════════════════════
