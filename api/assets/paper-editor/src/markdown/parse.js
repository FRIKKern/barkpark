import { tokenizeInline, unescapeInline } from "./inline-parse.js";
import {
  clampLevel,
  EMPTY_PARAGRAPH_MARKER,
  mintId,
  SENTINEL_CLOSE,
  SENTINEL_OPEN,
  unescapeSentinelPayload,
} from "./shared.js";

export function markdownToBlocks(md) {
  return markdownToBlockSpans(md).blocks;
}

// The same parse, plus where each block came from: spans[k] = [first, next) LINE
// indices of blocks[k] in md.split("\n") (1.20.0: a source sync keeps the writer's
// own text for the blocks a server change did not touch). Every pass of the loop
// pushes one block or skips one blank line, so the loop's update records the span.
export function markdownToBlockSpans(md) {
  const text = typeof md === "string" ? md : "";
  const lines = text.split("\n");
  const blocks = [];
  const spans = [];
  let i = 0;

  for (let from = 0; i < lines.length; blocks.length > spans.length && spans.push([from, i]), from = i) {
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

  return { blocks, spans };
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
    // The same grammar the dispatcher uses: a `>[!x]y` that is no header stays body.
    if (matchCalloutHeader(l)) break;
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
    // A callout header starts a new block. The same grammar the dispatcher uses, so
    // the first line (never a header here) is always consumed: `>[!e]O` once broke
    // here at j === i and the parse loop never advanced.
    if (matchCalloutHeader(l)) break;
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
  const alignments = splitTableRow(lines[i + 1]).map((delimiter) =>
    delimiter.startsWith(":") && delimiter.endsWith(":") ? "center"
      : delimiter.endsWith(":") ? "right" : null,
  );
  const cell = (value, column) => {
    const content = tokenizeInline(value);
    return alignments[column] ? { content, align: alignments[column] } : content;
  };
  const head = splitTableRow(lines[i]).map(cell);
  const width = head.length;
  const rows = [];
  let j = i + 2;
  while (j < lines.length && isTableRowLine(lines[j]) && !startsNewBlock(lines[j])) {
    const cells = splitTableRow(lines[j]);
    while (cells.length < width) cells.push("");
    rows.push(cells.slice(0, width).map(cell));
    j += 1;
  }
  // The server refuses a table with no body rows; a header-only paste gets one empty row.
  if (rows.length === 0) rows.push(Array.from({ length: width }, (_, column) => cell("", column)));
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
// ═══════════════════════════════════════════════════════════════════════════
//
