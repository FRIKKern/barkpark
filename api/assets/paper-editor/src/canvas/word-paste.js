// word-paste.js — turn Microsoft Word's list paragraphs into real HTML lists
// before ProseMirror parses a paste.
//
// Word does not put lists on the clipboard as <ul>/<ol>. Each item is a <p>
// carrying `mso-list:l<id> level<n> lfo<m>` in its style, and the bullet or
// number is literal text inside an `<![if !supportLists]> … <![endif]>`
// conditional (marked `mso-list:Ignore`). Parsed as-is, a bulleted list
// becomes plain paragraphs that start with "·   " (dogfood 2026-10-03), so the
// list structure is lost and junk glyphs land in the text.
//
// normalizeWordListHTML rewrites runs of such paragraphs into nested <ul>/<ol>
// with the markers removed. Anything that is not Word list markup passes
// through unchanged: the function returns its input when there is nothing to
// rewrite.
//
// DOM-only (DOMParser); no editor imports, so it is unit-testable on its own.

const MSO_LIST = /mso-list:\s*(l\d+)\s+level(\d+)/i;
const ORDERED_MARKER = /^\s*(?:\d+|[a-z]|[ivxlcdm]+)[.)]\s*$/i;

function listInfo(el) {
  if (el.nodeType !== 1 || el.tagName !== "P") return null;
  const match = MSO_LIST.exec(el.getAttribute("style") || "");
  if (!match) return null;
  return { list: match[1].toLowerCase(), level: Math.max(1, Number(match[2]) || 1) };
}

// Remove the marker Word renders for non-list-aware readers and return its
// text, so the caller can tell a numbered item from a bulleted one.
function stripMarker(p) {
  let marker = "";
  let inMarker = false;
  for (const node of [...p.childNodes]) {
    if (node.nodeType === 8) {
      const data = node.data.trim();
      if (/^\[if\s+!supportLists\]/i.test(data)) {
        inMarker = true;
        node.remove();
        continue;
      }
      if (/^\[endif\]/i.test(data)) {
        if (inMarker) {
          inMarker = false;
          node.remove();
          continue;
        }
      }
    }
    if (inMarker) {
      marker += node.textContent || "";
      node.remove();
    }
  }
  for (const ignored of [...p.querySelectorAll("span")]) {
    if (/mso-list:\s*ignore/i.test(ignored.getAttribute("style") || "")) {
      marker += ignored.textContent || "";
      ignored.remove();
    }
  }
  return marker.replace(/ /g, " ").trim();
}

export function normalizeWordListHTML(html) {
  if (typeof html !== "string" || !/mso-list/i.test(html)) return html;
  if (typeof DOMParser === "undefined") return html;
  const doc = new DOMParser().parseFromString(html, "text/html");
  const items = [...doc.body.querySelectorAll("p")].filter((p) => listInfo(p));
  if (!items.length) return html;

  const done = new Set();
  for (const first of items) {
    if (done.has(first)) continue;
    // A run: the item and its following element siblings that are items of the
    // same Word list (whitespace text between them is skipped).
    const run = [];
    for (let node = first; node; node = node.nextSibling) {
      if (node.nodeType === 3 && !node.textContent.trim()) continue;
      if (node.nodeType === 8) continue;
      const info = listInfo(node);
      if (!info || info.list !== listInfo(first).list) break;
      run.push(node);
    }
    const host = doc.createElement("div");
    first.parentNode.insertBefore(host, first);
    // stack[i] is the list element open at level i + 1.
    const stack = [];
    for (const p of run) {
      done.add(p);
      const { level } = listInfo(p);
      const marker = stripMarker(p);
      const tag = ORDERED_MARKER.test(marker) ? "ol" : "ul";
      while (stack.length > level) stack.pop();
      while (stack.length < level) {
        const list = doc.createElement(tag);
        if (stack.length === 0) {
          host.appendChild(list);
        } else {
          const parentList = stack[stack.length - 1];
          let lastItem = parentList.lastElementChild;
          if (!lastItem) {
            lastItem = doc.createElement("li");
            parentList.appendChild(lastItem);
          }
          lastItem.appendChild(list);
        }
        stack.push(list);
      }
      const li = doc.createElement("li");
      const para = doc.createElement("p");
      while (p.firstChild) para.appendChild(p.firstChild);
      li.appendChild(para);
      stack[stack.length - 1].appendChild(li);
      p.remove();
    }
    host.replaceWith(...host.childNodes);
  }
  return doc.body.innerHTML;
}
