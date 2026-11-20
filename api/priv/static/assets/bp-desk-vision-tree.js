// The desk's Vision (bp-desk-vision.js), its result: Sanity Vision's folding JSON tree,
// drawn in steps of a hundred with "Show n more", and the page's words (data-t-*) it
// says how much each branch holds in. bp-desk-vision.js uses it as
// window.BarkparkDeskVisionTree.
(function () {
  if (window.BarkparkDeskVisionTree) return;

  // A big array or object draws this many entries, then "Show n more".
  var CHUNK = 100;
  var word = function (root, name, values) {
    var text = root.getAttribute("data-t-" + name) || "";
    return text.replace(/%\{(\w+)\}/g, function (all, key) {
      return values && key in values ? String(values[key]) : all;
    });
  };
  var el = function (doc, tag, cls, text) {
    var node = doc.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  // Sanity Vision's tree: objects and arrays fold, each saying how much it holds.
  var node = function (root, name, value, depth, open) {
    var doc = root.ownerDocument;
    var li = el(doc, "li");
    li.setAttribute("role", "treeitem");
    var key = name === undefined ? null : el(doc, "span", "json-key", name + ": ");
    if (value === null || typeof value !== "object") {
      li.className = "json-leaf";
      if (key) li.appendChild(key);
      var type = value === null ? "null" : typeof value;
      li.appendChild(el(doc, "span", "json-" + type, type === "string" ? value : String(value)));
      return li;
    }
    var array = Array.isArray(value);
    var entries = array
      ? value.map(function (v, i) { return [String(i), v]; })
      : Object.keys(value).map(function (k) { return [k, value[k]]; });
    var n = entries.length;
    var count = array ? (n === 1 ? word(root, "item") : word(root, "items", { count: n })) : n === 1 ? word(root, "property") : word(root, "properties", { count: n });
    var button = el(doc, "button", "json-toggle");
    button.type = "button";
    var arrow = el(doc, "span", "json-arrow");
    arrow.setAttribute("aria-hidden", "true");
    if (depth > 0) button.appendChild(arrow);
    if (key) button.appendChild(key);
    button.appendChild(el(doc, "span", "json-brace", array ? (n ? "[…]" : "[]") : n ? "{…}" : "{}"));
    button.appendChild(doc.createTextNode(" "));
    button.appendChild(el(doc, "span", "json-count", count));
    li.appendChild(button);
    if (!n) {
      button.disabled = true;
      return li;
    }
    li.__entries = entries;
    li.__depth = depth;
    li.__open = open;
    setOpen(root, li, depth < open);
    return li;
  };

  var setOpen = function (root, li, open) {
    li.setAttribute("aria-expanded", open ? "true" : "false");
    var arrow = li.firstChild.querySelector(".json-arrow");
    if (arrow) arrow.textContent = open ? "▾" : "▸";
    var group = li.querySelector(":scope > ul");
    if (!open) {
      if (group) group.remove();
      return;
    }
    if (group) return;
    group = el(root.ownerDocument, "ul");
    group.setAttribute("role", "group");
    li.appendChild(group);
    drawFrom(root, li, group, 0);
  };

  var drawFrom = function (root, li, group, from) {
    var entries = li.__entries;
    var to = Math.min(entries.length, from + CHUNK);
    for (var i = from; i < to; i++) group.appendChild(node(root, entries[i][0], entries[i][1], li.__depth + 1, li.__open));
    if (to < entries.length) {
      var more = el(root.ownerDocument, "li");
      more.setAttribute("role", "none");
      var button = el(root.ownerDocument, "button", "json-more", word(root, "more", { count: entries.length - to }));
      button.type = "button";
      button.__more = { li: li, group: group, from: to };
      more.appendChild(button);
      group.appendChild(more);
    }
  };

  var tree = function (root, value, open) {
    var ul = el(root.ownerDocument, "ul", "json-tree");
    ul.setAttribute("role", "tree");
    ul.appendChild(node(root, undefined, value, 0, open));
    return ul;
  };

  // Show n more: the next entries drawn, and focus on to the first of them before the button
  // leaves, not to the body.
  var more = function (root, hit) {
    var m = hit.__more;
    drawFrom(root, m.li, m.group, m.from);
    // The button's own row is still at m.from: the first drawn is after it.
    var first = m.group.children[m.from + 1];
    var to = first.querySelector(":scope > button:not([disabled])");
    if (!to) (to = first).tabIndex = -1;
    to.focus();
    hit.parentNode.remove();
  };

  window.BarkparkDeskVisionTree = { word: word, el: el, tree: tree, setOpen: setOpen, more: more };
})();
