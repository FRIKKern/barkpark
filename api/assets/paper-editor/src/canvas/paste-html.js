// paste-html.js — clean pasted HTML into the shapes the canvas means, before it
// is parsed (task-68314b1d334213e8, Sanity parity). Runs on every HTML paste path:
// transformPastedHTML (native) and _pasteHTMLTables.
//
//   <blockquote>…</blockquote>   → the canvas quote block (data-bp-type="blockquote");
//                                  in a field, paste-vocabulary.js then makes it the
//                                  field's quote style. Several paragraphs inside
//                                  one quote become one quote block each.
//   underline on a link's text   → dropped: it is the source app's link styling
//                                  (Google Docs puts text-decoration:underline on
//                                  the span inside <a>), not an author's underline.
//   a <br> between two blocks    → dropped: Google Docs separates blocks with a bare
//                                  <br>, which parsed into a paragraph holding "\n".
//                                  A <br> inside a line of text is kept.

const BLOCK = new Set([
  "P", "DIV", "UL", "OL", "LI", "H1", "H2", "H3", "H4", "H5", "H6", "TABLE", "BLOCKQUOTE",
  "PRE", "FIGURE", "HR", "SECTION", "ARTICLE", "HEADER", "FOOTER", "ASIDE", "DL",
]);
const isBlock = (el) => !!el && BLOCK.has(el.tagName);
const blank = (node) => node && node.nodeType === 3 && !node.textContent.trim();

function quotes(doc) {
  for (const quote of [...doc.querySelectorAll("blockquote:not([data-bp-type])")]) {
    if (quote.parentElement?.closest("blockquote")) continue; // nested: the outer quote holds its text
    // One quote block per paragraph, as Sanity stores a multi-paragraph quote: a
    // line break is not allowed inside a quote block (portable-text-boundary.js).
    const paras = [...quote.children].filter(isBlock);
    const groups = paras.length ? paras.map((block) => [...block.childNodes]) : [[...quote.childNodes]];
    const out = groups.map((nodes) => {
      const q = doc.createElement("blockquote");
      q.setAttribute("data-bp-type", "blockquote");
      const p = doc.createElement("p");
      for (const n of nodes) p.appendChild(n);
      q.appendChild(p);
      return q;
    });
    quote.replaceWith(...out);
  }
}

function linkUnderlines(doc) {
  for (const link of doc.querySelectorAll("a[href]")) {
    for (const el of [link, ...link.querySelectorAll("*")]) {
      const style = el.getAttribute("style");
      if (style && /text-decoration[^;]*underline/i.test(style)) {
        el.setAttribute("style", style.replace(/text-decoration(-line)?\s*:[^;]*;?/gi, ""));
      }
    }
    for (const u of [...link.querySelectorAll("u")]) u.replaceWith(...u.childNodes);
  }
}

function strayBreaks(doc) {
  for (const br of [...doc.querySelectorAll("br")]) {
    if (br.classList.contains("Apple-interchange-newline")) { br.remove(); continue; }
    let prev = br.previousSibling;
    while (blank(prev)) prev = prev.previousSibling;
    let next = br.nextSibling;
    while (blank(next)) next = next.nextSibling;
    const edge = (n) => !n || (n.nodeType === 1 && isBlock(n));
    if (edge(prev) && edge(next) && (prev || next)) br.remove();
  }
}

export function cleanPastedHTML(html) {
  if (!html) return html;
  const doc = new DOMParser().parseFromString(html, "text/html");
  quotes(doc);
  linkUnderlines(doc);
  strayBreaks(doc);
  return doc.body.innerHTML;
}
