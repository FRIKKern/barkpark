#!/usr/bin/env python3
"""
paper_to_blocks.py — convert a paper article HTML doc into a
portable-doc block list that Barkpark.PortableDoc.Render.compose_block accepts.

Dep-light: Python 3 stdlib only (html.parser, html, json, hashlib, re).

Maps the paper article grammar to the EXACT block shapes the Elixir
renderer's `compose_block/2` clauses pattern-match on (see
api/lib/barkpark/portable_doc/render.ex):

  .eyebrow                          -> eyebrow   {text}
  h1                                -> heading   {level:1, text}
  h2 / h3                           -> heading   {level:2|3, text}
  .byline (span/b/text children)    -> byline    {items:[...]}
  .ingress                          -> ingress   {content:[inline]}
  p                                 -> paragraph {content:[inline]}
  ul / ol                           -> list      {ordered, items:[[inline],...]}
  table                             -> table     {rows:[[ [inline], ...], ...]}
  <figure><pre class="mermaid">..   -> diagram   {source (decoded), caption}
  <pre class="code"> / other <pre>  -> code      {value}
  .pullquote                        -> pullquote {content:[inline]}
  hr.section / hr                   -> divider   {}

Inline marks inside p / ingress / list-item / table-cell / pullquote:
  text            -> {type:"text",   value}
  <strong>/<b>    -> {type:"strong", children:[inline]}
  <em>/<i>        -> {type:"em",     children:[inline]}
  <code>          -> {type:"code",   value}            (leaf, text only)
  <a href>        -> {type:"link",   href, children:[inline]}
  <del>           -> emitted as plain text (no strike pd-node; render.ex
                     drops strike on the article path) — flattened to text.

Skips the doc.css <link>, the mermaid/doc.js <script> tail, <head>, and any
chrome. Each block gets a stable id derived from its index + a content hash.

Usage:
  paper_to_blocks.py INPUT.html            # prints {"style","rev","blocks"} JSON
  paper_to_blocks.py INPUT.html --blocks   # prints just the blocks array
"""

import sys
import re
import json
import html
import hashlib
from html.parser import HTMLParser

# ── inline parser ───────────────────────────────────────────────────────────
# Parses the *inner* HTML of a block element into a flat list of inline nodes.
# strong/em/link nest children; code is a text-only leaf.

INLINE_TAGS = {"strong", "b", "em", "i", "code", "a", "del", "span"}


class InlineParser(HTMLParser):
    """Collect inline nodes from a block's children."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        # Stack of (tag, node) frames. The bottom frame is the synthetic root
        # whose "children" is the result list.
        self.root = {"type": "_root", "children": []}
        self.stack = [self.root]

    # current node we are appending text/children into
    def _cur(self):
        return self.stack[-1]

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ("strong", "b"):
            node = {"type": "strong", "children": []}
            self._cur()["children"].append(node)
            self.stack.append(node)
        elif tag in ("em", "i"):
            node = {"type": "em", "children": []}
            self._cur()["children"].append(node)
            self.stack.append(node)
        elif tag == "a":
            node = {"type": "link", "href": attrs.get("href", ""), "children": []}
            self._cur()["children"].append(node)
            self.stack.append(node)
        elif tag == "code":
            # code is a text-only leaf; buffer its text into "value".
            node = {"type": "code", "value": ""}
            self._cur()["children"].append(node)
            self.stack.append(node)
        elif tag == "del":
            # No strike pd-node — flatten del to a passthrough wrapper that
            # contributes its text/children to the current flow as plain text.
            node = {"type": "_passthrough", "children": []}
            self._cur()["children"].append(node)
            self.stack.append(node)
        elif tag == "span":
            # spans carry no semantics inline — passthrough.
            node = {"type": "_passthrough", "children": []}
            self._cur()["children"].append(node)
            self.stack.append(node)
        elif tag == "br":
            self._append_text("\n")
        # any other inline-ish tag: ignore the tag, keep its text (no push)

    def handle_endtag(self, tag):
        # Pop the matching frame if we pushed one for this tag.
        if len(self.stack) > 1:
            top = self.stack[-1]
            ttype = top["type"]
            match = (
                (tag in ("strong", "b") and ttype == "strong")
                or (tag in ("em", "i") and ttype == "em")
                or (tag == "a" and ttype == "link")
                or (tag == "code" and ttype == "code")
                or (tag == "del" and ttype == "_passthrough")
                or (tag == "span" and ttype == "_passthrough")
            )
            if match:
                self.stack.pop()

    def handle_data(self, data):
        self._append_text(data)

    def _append_text(self, data):
        cur = self._cur()
        if cur["type"] == "code":
            cur["value"] += data
        else:
            cur["children"].append({"type": "text", "value": data})

    def result(self):
        return _normalize_inline(self.root["children"])


def _normalize_inline(nodes):
    """Flatten _passthrough wrappers, collapse whitespace in text runs, merge
    adjacent text nodes, and drop empty text. Recurse into strong/em/link."""
    out = []
    for n in nodes:
        t = n.get("type")
        if t == "_passthrough":
            out.extend(_normalize_inline(n["children"]))
        elif t == "text":
            value = _collapse_ws(n["value"])
            if value:
                if out and out[-1].get("type") == "text":
                    out[-1]["value"] += value
                else:
                    out.append({"type": "text", "value": value})
        elif t in ("strong", "em", "link"):
            children = _normalize_inline(n["children"])
            if not children:
                continue
            node = {"type": t}
            if t == "link":
                node["href"] = n.get("href", "")
            node["children"] = children
            out.append(node)
        elif t == "code":
            value = _collapse_ws(n.get("value", ""))
            if value:
                out.append({"type": "code", "value": value})
        else:
            out.append(n)
    # Trim leading/trailing whitespace-only edges of text runs.
    if out and out[0].get("type") == "text":
        out[0]["value"] = out[0]["value"].lstrip()
        if not out[0]["value"]:
            out.pop(0)
    if out and out[-1].get("type") == "text":
        out[-1]["value"] = out[-1]["value"].rstrip()
        if not out[-1]["value"]:
            out.pop()
    return out


def _collapse_ws(s):
    # Collapse runs of whitespace (incl. newlines) to a single space, the way
    # HTML inline flow renders. Preserves a single leading/trailing space so
    # mark boundaries don't glue words together.
    return re.sub(r"\s+", " ", s)


def parse_inline(inner_html):
    p = InlineParser()
    p.feed(inner_html)
    p.close()
    return p.result()


def inline_text(inner_html):
    """Plain-text flatten of inline html (for eyebrow / heading / byline)."""
    nodes = parse_inline(inner_html)
    return _flatten_text(nodes).strip()


def _flatten_text(nodes):
    parts = []
    for n in nodes:
        t = n.get("type")
        if t == "text":
            parts.append(n["value"])
        elif t == "code":
            parts.append(n.get("value", ""))
        elif t in ("strong", "em", "link"):
            parts.append(_flatten_text(n["children"]))
    return "".join(parts)


# ── block parser ──────────────────────────────────────────────────────────
# Walks the document, captures raw inner-HTML of each block-level element, and
# defers inline parsing to InlineParser. Tables and figures need structural
# handling, so we track those with small state machines.

BLOCK_TAGS = {"p", "h1", "h2", "h3", "ul", "ol", "table", "figure", "pre", "hr"}


class BlockParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)  # keep entities raw for mermaid
        self.blocks = []
        self.in_body = False
        self.skip_depth = 0  # inside <head>, <script>, <style>
        self.skip_tag = None

        # capture buffer for the current top-level block
        self.capture = None  # dict describing what we're capturing
        self.depth = 0  # nesting depth within the captured block

    # -- helpers to (re)build raw html of captured sub-content --
    def _raw_starttag(self, tag, attrs):
        parts = [tag]
        for k, v in attrs:
            if v is None:
                parts.append(k)
            else:
                parts.append('%s="%s"' % (k, v))
        return "<" + " ".join(parts) + ">"

    def handle_starttag(self, tag, attrs):
        attrs_d = dict(attrs)

        # global skips
        if tag in ("head", "script", "style"):
            self.skip_depth += 1
            self.skip_tag = tag
            return
        if self.skip_depth > 0:
            return

        if tag == "body":
            self.in_body = True
            return
        if not self.in_body:
            return

        # If we are currently capturing a block, just record raw markup of
        # nested start tags (for inline content of p/li/td, mermaid pre, etc).
        if self.capture is not None:
            self.depth += 1
            self._cap_append(self._raw_starttag(tag, attrs))
            # Track structural sub-elements for tables / lists / figures.
            self._cap_structural_start(tag, attrs_d)
            return

        # Not capturing — decide whether this opens a new block.
        cls = (attrs_d.get("class") or "").split()

        if tag == "p":
            role = (
                "eyebrow"
                if "eyebrow" in cls
                else "byline"
                if "byline" in cls
                else "ingress"
                if "ingress" in cls
                else "pullquote"
                if "pullquote" in cls
                else "paragraph"
            )
            self._begin_capture(tag, role=role)
        elif tag in ("h1", "h2", "h3"):
            self._begin_capture(tag, role="heading", level=int(tag[1]))
        elif tag in ("ul", "ol"):
            self._begin_capture(tag, role="list", ordered=(tag == "ol"), items=[], cur_item=None)
        elif tag == "table":
            self._begin_capture(tag, role="table", rows=[], cur_row=None, cur_cell=None)
        elif tag == "figure":
            self._begin_capture(
                tag, role="figure", mermaid=None, in_mermaid=False, caption=None, in_caption=False
            )
        elif tag == "pre":
            # standalone <pre> (not inside a figure) → code block
            self._begin_capture(tag, role="code", value="")
        elif tag == "hr":
            section = "section" in cls
            self.blocks.append({"_role": "divider"})

    def handle_startendtag(self, tag, attrs):
        # self-closing (e.g. <br/>, <img/>) — treat as start+immediate end of
        # a void; inside a capture, just record raw.
        if self.skip_depth > 0 or not self.in_body:
            return
        if self.capture is not None:
            self._cap_append(self.get_starttag_text() or self._raw_starttag(tag, attrs))

    def handle_endtag(self, tag):
        if tag in ("head", "script", "style") and self.skip_depth > 0:
            self.skip_depth -= 1
            return
        if self.skip_depth > 0:
            return
        if tag == "body":
            self.in_body = False
            return
        if not self.in_body:
            return

        if self.capture is None:
            return

        # closing a nested tag within the captured block
        if self.depth > 0:
            self._cap_structural_end(tag)
            self._cap_append("</%s>" % tag)
            self.depth -= 1
            return

        # depth == 0: this closes the captured block itself
        if tag == self.capture["tag"]:
            self._finish_capture()

    def handle_data(self, data):
        if self.skip_depth > 0 or not self.in_body or self.capture is None:
            return
        self._cap_append(data)

    def handle_entityref(self, name):
        if self.capture is not None:
            self._cap_append("&%s;" % name)

    def handle_charref(self, name):
        if self.capture is not None:
            self._cap_append("&#%s;" % name)

    # -- capture lifecycle --
    def _begin_capture(self, tag, **state):
        self.capture = {"tag": tag, "buf": [], **state}
        self.depth = 0

    def _cap_append(self, s):
        c = self.capture
        # figure: route text into mermaid source or caption buffers
        if c["role"] == "figure":
            if c.get("in_mermaid"):
                c.setdefault("mermaid_buf", []).append(s)
            elif c.get("in_caption"):
                c.setdefault("caption_buf", []).append(s)
            return
        # table: route into the active cell buffer
        if c["role"] == "table":
            if c.get("cur_cell") is not None:
                c["cur_cell"].append(s)
            return
        # list: route into the active item buffer
        if c["role"] == "list":
            if c.get("cur_item") is not None:
                c["cur_item"].append(s)
            return
        c["buf"].append(s)

    def _cap_structural_start(self, tag, attrs_d):
        c = self.capture
        if c["role"] == "figure":
            cls = (attrs_d.get("class") or "").split()
            if tag == "pre" and "mermaid" in cls:
                c["in_mermaid"] = True
            elif tag == "pre":
                # a non-mermaid pre inside a figure: treat as mermaid-less code
                c["in_mermaid"] = True  # still capture its text as source
            elif tag == "figcaption":
                c["in_caption"] = True
        elif c["role"] == "table":
            if tag == "tr":
                c["cur_row"] = []
            elif tag in ("td", "th"):
                c["cur_cell"] = []
        elif c["role"] == "list":
            if tag == "li":
                c["cur_item"] = []

    def _cap_structural_end(self, tag):
        c = self.capture
        if c["role"] == "figure":
            if tag == "pre" and c.get("in_mermaid"):
                c["in_mermaid"] = False
            elif tag == "figcaption" and c.get("in_caption"):
                c["in_caption"] = False
        elif c["role"] == "table":
            if tag in ("td", "th") and c.get("cur_cell") is not None:
                cell_html = "".join(c["cur_cell"])
                c["cur_row"].append(parse_inline(cell_html))
                c["cur_cell"] = None
            elif tag == "tr" and c.get("cur_row") is not None:
                if c["cur_row"]:
                    c["rows"].append(c["cur_row"])
                c["cur_row"] = None
        elif c["role"] == "list":
            if tag == "li" and c.get("cur_item") is not None:
                item_html = "".join(c["cur_item"])
                c["items"].append(parse_inline(item_html))
                c["cur_item"] = None

    def _finish_capture(self):
        c = self.capture
        self.capture = None
        role = c["role"]

        if role == "eyebrow":
            self.blocks.append({"_role": "eyebrow", "text": inline_text("".join(c["buf"]))})
        elif role == "heading":
            self.blocks.append(
                {"_role": "heading", "level": c["level"], "text": inline_text("".join(c["buf"]))}
            )
        elif role == "byline":
            self.blocks.append({"_role": "byline", "items": _byline_items("".join(c["buf"]))})
        elif role == "ingress":
            self.blocks.append({"_role": "ingress", "content": parse_inline("".join(c["buf"]))})
        elif role == "paragraph":
            self.blocks.append({"_role": "paragraph", "content": parse_inline("".join(c["buf"]))})
        elif role == "pullquote":
            self.blocks.append({"_role": "pullquote", "content": parse_inline("".join(c["buf"]))})
        elif role == "list":
            self.blocks.append({"_role": "list", "ordered": c["ordered"], "items": c["items"]})
        elif role == "table":
            self.blocks.append({"_role": "table", "rows": c["rows"]})
        elif role == "code":
            self.blocks.append({"_role": "code", "value": _decode_pre("".join(c["buf"]))})
        elif role == "figure":
            mermaid = "".join(c.get("mermaid_buf", []))
            caption = "".join(c.get("caption_buf", []))
            if mermaid.strip():
                self.blocks.append(
                    {
                        "_role": "diagram",
                        "source": _decode_mermaid(mermaid),
                        "caption": inline_text(caption),
                    }
                )
            else:
                # figure with no mermaid/pre → fall back to a caption-only divider-ish
                # (rare in this grammar); emit a paragraph of the caption.
                self.blocks.append(
                    {"_role": "paragraph", "content": parse_inline(caption)}
                )


def _byline_items(inner_html):
    """The .byline carries date/topic/status/device separated by ' · '. We
    flatten to text then split on the middot, dropping empties. Bold/span
    wrappers contribute their text only."""
    text = inline_text(inner_html)
    items = [seg.strip() for seg in text.split("·")]
    return [s for s in items if s]


def _decode_mermaid(raw):
    """Mermaid <pre> text is entity-encoded (&amp; &lt; &gt;). Decode back to
    raw and strip the surrounding indentation/newlines the source uses."""
    decoded = html.unescape(raw)
    return decoded.strip("\n").strip()


def _decode_pre(raw):
    """Code <pre> text: decode entities, strip leading/trailing blank lines."""
    return html.unescape(raw).strip("\n")


# ── block → final shape with stable ids ──────────────────────────────────────


def _stable_id(idx, payload):
    h = hashlib.sha1(json.dumps(payload, sort_keys=True).encode("utf-8")).hexdigest()[:8]
    return "blk-%02d-%s" % (idx, h)


def finalize(raw_blocks):
    out = []
    for idx, b in enumerate(raw_blocks):
        role = b.pop("_role")
        if role == "eyebrow":
            block = {"type": "eyebrow", "text": b["text"]}
        elif role == "heading":
            block = {"type": "heading", "level": b["level"], "text": b["text"]}
        elif role == "byline":
            block = {"type": "byline", "items": b["items"]}
        elif role == "ingress":
            block = {"type": "ingress", "content": b["content"]}
        elif role == "paragraph":
            block = {"type": "paragraph", "content": b["content"]}
        elif role == "pullquote":
            block = {"type": "pullquote", "content": b["content"]}
        elif role == "list":
            block = {"type": "list", "ordered": b["ordered"], "items": b["items"]}
        elif role == "table":
            block = {"type": "table", "rows": b["rows"]}
        elif role == "code":
            block = {"type": "code", "value": b["value"]}
        elif role == "diagram":
            block = {"type": "diagram", "source": b["source"], "caption": b["caption"]}
        elif role == "divider":
            block = {"type": "divider"}
        else:
            raise ValueError("unknown role %r" % role)
        block["id"] = _stable_id(idx, block)
        out.append(block)
    return out


def convert(html_text):
    p = BlockParser()
    p.feed(html_text)
    p.close()
    return finalize(p.blocks)


def main():
    args = sys.argv[1:]
    blocks_only = "--blocks" in args
    paths = [a for a in args if not a.startswith("--")]
    if not paths:
        sys.stderr.write("usage: paper_to_blocks.py INPUT.html [--blocks]\n")
        sys.exit(2)
    with open(paths[0], "r", encoding="utf-8") as f:
        html_text = f.read()
    blocks = convert(html_text)
    if blocks_only:
        print(json.dumps(blocks, ensure_ascii=False, indent=2))
    else:
        doc = {"style": "article", "rev": 1, "blocks": blocks}
        print(json.dumps(doc, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
