// markdown.js — pure, dependency-free bidirectional converter between the
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

// The sentinel marker. A whole-block JSON payload rides between the open/close so
// markdown passes it through verbatim and JSON.parse rebuilds the EXACT block.
const SENTINEL_OPEN = "<!--bp:block ";
const SENTINEL_CLOSE = "-->";

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

function unescapeSentinelPayload(payload) {
  return payload.replace(/-\u0000-/g, "--");
}

// ── heading ──────────────────────────────────────────────────────────────────
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

const EMPTY_PARAGRAPH_MARKER = "<!--bp:empty-->";

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
// markdownToBlocks — the inverse: a line-oriented block scanner + inline tokenizer
// ═══════════════════════════════════════════════════════════════════════════

export function markdownToBlocks(md) {
  const text = typeof md === "string" ? md : "";
  const lines = text.split("\n");
  const blocks = [];
  let i = 0;

  while (i < lines.length) {
    let line = lines[i];

    // Skip blank separator lines between blocks.
    if (line.trim() === "") {
      i += 1;
      continue;
    }

    // 1) SENTINEL — a whole-block JSON comment. Highest priority: it carries the
    //    exact block (with its original id) verbatim.
    const sentinelBlock = tryParseSentinel(line);
    if (sentinelBlock !== undefined) {
      blocks.push(sentinelBlock);
      i += 1;
      continue;
    }

    // 1b) EMPTY-PARAGRAPH marker.
    if (line.trim() === EMPTY_PARAGRAPH_MARKER) {
      blocks.push({ id: mintId(), type: "paragraph", content: [] });
      i += 1;
      continue;
    }

    // 2) FENCED code / mermaid — ``` (or longer) optionally with an info string.
    const fence = matchFenceOpen(line);
    if (fence) {
      const { block, next } = scanFence(lines, i, fence);
      blocks.push(block);
      i = next;
      continue;
    }

    // 3) ATX heading — 1..6 "#" then a space.
    const heading = matchHeading(line);
    if (heading) {
      blocks.push({
        id: mintId(),
        type: "heading",
        level: heading.level,
        text: heading.text,
      });
      i += 1;
      continue;
    }

    // 3b) IMAGE — a line that is exactly ![alt](src) becomes an image block (the
    //     inverse of serializeImage); an image inside a sentence stays inline text.
    const image = /^!\[([^\]\n]*)\]\(([^\s()]+)\)\s*$/.exec(line);
    if (image) {
      const block = { id: mintId(), type: "image", src: image[2] };
      if (image[1] !== "") block.alt = image[1];
      blocks.push(block);
      i += 1;
      continue;
    }

    // 4) THEMATIC BREAK — a line of only ---, ***, or ___ (3+).
    if (isThematicBreak(line)) {
      blocks.push({ id: mintId(), type: "divider" });
      i += 1;
      continue;
    }

    // 5) CALLOUT admonition — > [!tone]…  (consumes the > [! header + > body lines)
    const calloutHead = matchCalloutHeader(line);
    if (calloutHead) {
      const { block, next } = scanCallout(lines, i, calloutHead);
      blocks.push(block);
      i = next;
      continue;
    }

    // 6) BLOCKQUOTE — > lines that are NOT a callout become the plain `blockquote`
    //    block (the server element the BPML parser and Studio write; the canvas
    //    mounts it as a role-shaped node). `> [!tone]` above still wins as a callout.
    if (/^>\s?/.test(line)) {
      const { block, next } = scanBlockquote(lines, i);
      blocks.push(block);
      i = next;
      continue;
    }

    // 7) LIST — a run of bullet ("- "/"+ "/"* ") or ordered ("1. ") items.
    const listItem = matchListItem(line);
    if (listItem) {
      const { block, next } = scanList(lines, i, listItem.ordered, listItem.task === true);
      blocks.push(block);
      i = next;
      continue;
    }

    // 7b) TABLE — a GFM pipe table: a header row, a delimiter row (| --- | :-: |) that
    //     itself contains a pipe, then body rows until a blank line or another block.
    if (isTableStart(lines, i)) {
      const { block, next } = scanTable(lines, i);
      blocks.push(block);
      i = next;
      continue;
    }

    // 8) PARAGRAPH — consume consecutive non-blank lines that don't START a new
    //    block, join with a newline, tokenize as inline.
    const { para, next } = scanParagraph(lines, i);
    blocks.push(para);
    i = next;
  }

  return blocks;
}

// ── sentinel parse ───────────────────────────────────────────────────────────
function tryParseSentinel(line) {
  const trimmed = line.trim();
  if (!trimmed.startsWith(SENTINEL_OPEN)) return undefined;
  if (!trimmed.endsWith(SENTINEL_CLOSE)) return undefined;
  const payload = trimmed.slice(
    SENTINEL_OPEN.length,
    trimmed.length - SENTINEL_CLOSE.length,
  );
  try {
    const block = JSON.parse(unescapeSentinelPayload(payload));
    if (block && typeof block === "object") return block;
  } catch (_e) {
    // Not a valid sentinel payload — treat the line as ordinary markdown.
  }
  return undefined;
}

// ── fenced code / mermaid ─────────────────────────────────────────────────────
// matchFenceOpen(line) → { ticks, info } when the line opens a fence; else null.
function matchFenceOpen(line) {
  const m = /^(`{3,})(.*)$/.exec(line);
  if (!m) return null;
  return { ticks: m[1], info: m[2].trim() };
}

// scanFence(lines, i, fence) → a code or diagram block + the next line index.
// The closing fence is a line of >= the same number of backticks and nothing
// else (trimmed). Everything between is the verbatim body.
function scanFence(lines, i, fence) {
  const open = fence.ticks;
  const info = fence.info;
  const bodyLines = [];
  let j = i + 1;
  let closed = false;
  while (j < lines.length) {
    const l = lines[j];
    const cm = /^(`{3,})\s*$/.exec(l);
    if (cm && cm[1].length >= open.length) {
      closed = true;
      j += 1;
      break;
    }
    bodyLines.push(l);
    j += 1;
  }
  // An unterminated fence consumes to EOF (still lossless on re-serialize since
  // the body is preserved and a fresh fence will close it).
  void closed;
  const value = bodyLines.join("\n");

  // info "mermaid" (optionally "mermaid caption=<enc>") → a diagram block.
  if (info === "mermaid" || info.startsWith("mermaid ")) {
    const block = { id: mintId(), type: "diagram", source: value };
    const capMatch = /^mermaid\s+caption=(\S*)$/.exec(info);
    if (capMatch) {
      try {
        const cap = decodeURIComponent(capMatch[1]);
        if (cap !== "") block.caption = cap;
      } catch (_e) {
        // bad encoding → no caption (degrade gracefully)
      }
    }
    return { block, next: j };
  }

  // Otherwise a code block; the info string (if any) is the lang.
  const block = { id: mintId(), type: "code", value };
  if (info !== "") block.lang = info;
  return { block, next: j };
}

// ── ATX heading ────────────────────────────────────────────────────────────
function matchHeading(line) {
  const m = /^(#{1,6})\s+(.*)$/.exec(line);
  if (!m) return null;
  const level = clampLevel(m[1].length);
  const text = unescapeInline(m[2].replace(/\s+#*\s*$/, "")); // drop a trailing ### closer
  return { level, text };
}

// ── thematic break ───────────────────────────────────────────────────────────
function isThematicBreak(line) {
  const t = line.trim();
  if (t.length < 3) return false;
  return /^(-{3,}|\*{3,}|_{3,})$/.test(t);
}

// ── callout admonition ───────────────────────────────────────────────────────
// matchCalloutHeader(line) → { tone, collapsible, collapsed, title? } | null.
// Grammar:  > [!tone]([+-]?)( title)?   (Obsidian; mirrors the editor regex).
function matchCalloutHeader(line) {
  const m = /^>\s*\[!(\w+)\]([+-]?)(?:\s+(.*))?$/.exec(line);
  if (!m) return null;
  const tone = m[1];
  const suffix = m[2];
  const titleRaw = m[3];
  const head = { tone };
  if (suffix === "+") {
    head.collapsible = true;
  } else if (suffix === "-") {
    head.collapsible = true;
    head.collapsed = true;
  }
  if (titleRaw != null && titleRaw.trim() !== "") {
    head.title = unescapeInline(titleRaw.trim());
  }
  return head;
}

// scanCallout(lines, i, head) → a callout block + next index. Consumes the header
// line, then every following "> "-prefixed line as the body (inline-tokenized).
function scanCallout(lines, i, head) {
  const bodyLines = [];
  let j = i + 1;
  while (j < lines.length) {
    const l = lines[j];
    const bm = /^>\s?(.*)$/.exec(l);
    if (!bm) break;
    // A nested callout header inside the body ends THIS callout (rare; keep simple).
    if (/^>\s*\[!\w+\]/.test(l)) break;
    bodyLines.push(bm[1]);
    j += 1;
  }
  const block = { id: mintId(), type: "callout", tone: head.tone };
  if (head.title != null) block.title = head.title;
  if (head.collapsible === true) block.collapsible = true;
  if (head.collapsed === true) block.collapsed = true;
  block.content = tokenizeInline(bodyLines.join("\n"));
  return { block, next: j };
}

// ── blockquote (no [! header) → a neutral callout ────────────────────────────
function scanBlockquote(lines, i) {
  const bodyLines = [];
  let j = i;
  while (j < lines.length) {
    const l = lines[j];
    const bm = /^>\s?(.*)$/.exec(l);
    if (!bm) break;
    if (/^>\s*\[!\w+\]/.test(l)) break; // a callout header starts a new block
    bodyLines.push(bm[1]);
    j += 1;
  }
  const block = {
    id: mintId(),
    type: "blockquote",
    content: tokenizeInline(bodyLines.join("\n")),
  };
  return { block, next: j };
}

// ── list ─────────────────────────────────────────────────────────────────────
// matchListItem(line) → { ordered, body } | null for a TOP-LEVEL list marker.
function matchListItem(line) {
  const ol = /^(\d+)[.)]\s+(.*)$/.exec(line);
  if (ol) return { ordered: true, task: false, body: ol[2] };
  const todo = /^[-+*]\s+\[( |x|X)\]\s+(.*)$/.exec(line);
  if (todo) return { ordered: false, task: true, checked: todo[1] !== " ", body: todo[2] };
  const ul = /^[-+*]\s+(.*)$/.exec(line);
  if (ul) return { ordered: false, task: false, body: ul[1] };
  return null;
}

// scanList(lines, i, ordered) → a list block + next index. Consumes a run of
// items of the SAME ordered-ness; each item's body is inline-tokenized.
function scanList(lines, i, ordered, task = false) {
  const items = [];
  let j = i;
  while (j < lines.length) {
    const l = lines[j];
    if (l.trim() === "") break;
    const item = matchListItem(l);
    if (!item || item.ordered !== ordered || item.task !== task) break;
    items.push(task ? { content: tokenizeInline(item.body), checked: item.checked === true } : tokenizeInline(item.body));
    j += 1;
  }
  return {
    block: { id: mintId(), type: "list", ordered, ...(task ? { task: true } : {}), items },
    next: j,
  };
}

// ── paragraph ────────────────────────────────────────────────────────────────
// scanParagraph(lines, i) → a paragraph block + next index. Consumes consecutive
// non-blank lines that do NOT start another block, joined by newline.
function scanParagraph(lines, i) {
  const para = [];
  let j = i;
  while (j < lines.length) {
    const l = lines[j];
    if (l.trim() === "") break;
    if (j !== i && (startsNewBlock(l) || isTableStart(lines, j))) break;
    para.push(l);
    j += 1;
  }
  const joined = para.join("\n");
  return {
    para: { id: mintId(), type: "paragraph", content: tokenizeInline(joined) },
    next: j,
  };
}

// ── GFM pipe tables ──────────────────────────────────────────────────────────
// `| a | b |` (or `a | b`) as the header, a delimiter row of dashes with optional
// colons that MUST contain a pipe (a bare `---` under a line is a setext heading or
// a thematic break, not a table), then body rows. Cells split on unescaped pipes
// (`\|` is a literal pipe) and are tokenized as inline. The block is the server's
// table shape (compose.ex): { type:"table", head:[cell…], rows:[[cell…]…] }, one
// header row.
const TABLE_DELIMITER = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;

function splitTableRow(line) {
  let s = line.trim();
  if (s.startsWith("|")) s = s.slice(1);
  if (s.endsWith("|") && !s.endsWith("\\|")) s = s.slice(0, -1);
  const cells = [];
  let cur = "";
  for (let k = 0; k < s.length; k += 1) {
    const ch = s[k];
    if (ch === "\\" && s[k + 1] === "|") {
      cur += "|";
      k += 1;
      continue;
    }
    if (ch === "|") {
      cells.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  cells.push(cur);
  return cells.map((c) => c.trim());
}

function isTableRowLine(line) {
  return typeof line === "string" && line.trim() !== "" && line.includes("|");
}

function isTableStart(lines, i) {
  if (i + 1 >= lines.length) return false;
  const head = lines[i];
  const delim = lines[i + 1];
  if (!isTableRowLine(head) || !delim.includes("|") || !TABLE_DELIMITER.test(delim)) return false;
  return splitTableRow(head).length === splitTableRow(delim).length;
}

function scanTable(lines, i) {
  const head = splitTableRow(lines[i]).map((c) => tokenizeInline(c));
  const width = head.length;
  const rows = [];
  let j = i + 2;
  while (j < lines.length && isTableRowLine(lines[j]) && !startsNewBlock(lines[j])) {
    const cells = splitTableRow(lines[j]);
    while (cells.length < width) cells.push("");
    rows.push(cells.slice(0, width).map((c) => tokenizeInline(c)));
    j += 1;
  }
  // The server refuses a table with no body rows; a header-only paste gets one empty row.
  if (rows.length === 0) rows.push(Array.from({ length: width }, () => []));
  return { block: { id: mintId(), type: "table", head, rows }, next: j };
}

// True when a line (NOT the first of a paragraph) would START a new block — so a
// paragraph stops before it.
function startsNewBlock(line) {
  if (tryParseSentinel(line) !== undefined) return true;
  if (line.trim() === EMPTY_PARAGRAPH_MARKER) return true;
  if (matchFenceOpen(line)) return true;
  if (matchHeading(line)) return true;
  if (isThematicBreak(line)) return true;
  if (matchCalloutHeader(line)) return true;
  if (/^>\s?/.test(line)) return true;
  if (matchListItem(line)) return true;
  return false;
}

// ═══════════════════════════════════════════════════════════════════════════
// INLINE tokenizer — markdown inline → portable-doc inline tree
// ═══════════════════════════════════════════════════════════════════════════
//
// A single-pass recursive tokenizer over the active set:
//   \x        — escaped literal x (text)
//   `code`    — inline code (delimiter run length matched; one-space pad stripped)
//   **x** / __x__   — strong
//   *x* / _x_       — em
//   ~~x~~     — strikethrough
//   [text](href)    — link
//   [[t]] / [[t|a]] — wikilink
//   #name     — tag (at a word boundary)
// Adjacent text leaves are coalesced. Both _x_/*x* mean em (normalization), both
// __x__/**x** mean strong — so a parsed-then-serialized doc is a fixed point.

function tokenizeInline(src) {
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
function unescapeInline(text) {
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

// ═══════════════════════════════════════════════════════════════════════════
// helpers
// ═══════════════════════════════════════════════════════════════════════════

function clampLevel(level) {
  const n = Number(level);
  if (!Number.isFinite(n)) return 1;
  if (n < 1) return 1;
  if (n > 6) return 6;
  return Math.trunc(n);
}

// Mint an id for a block the user typed in source mode (no carried id). Unique
// within a process run; high-entropy so it never collides with a server id. The
// "m-" prefix marks a markdown-minted id (parallels run-convert.js's "c-").
let mintCounter = 0;
function mintId() {
  mintCounter += 1;
  return "m-" + mintCounter.toString(36) + "-" + randomNonce();
}

function randomNonce() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID().slice(0, 8);
  }
  return Math.random().toString(36).slice(2, 10);
}
