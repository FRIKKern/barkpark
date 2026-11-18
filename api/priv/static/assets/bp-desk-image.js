// bp-desk-image.js: the desk image field's own parts, as the TanStack
// Studio's (ImageInput.tsx HotspotDialog, lib/image.ts).
//
// THE DIALOG. "Edit hotspot and crop" (the picker's crop button, chrome="bar"
// with `hotspot`) draws the image with Sanity's hotspot, an ellipse, and its
// crop, a rectangle with a handle at each corner and edge. The mouse moves
// either, resizes the hotspot by its handle and pulls the crop's sides; the
// ellipse and the rectangle are focusable sliders (the hotspot first) whose
// arrows move them by 0.5% of the image, with Shift by 2.5%. The hotspot is
// kept inside the crop. Each release and each key press is written: the
// picker puts both on the image object (`setHotspotCrop`) and its hidden
// input saves them as any other edit of the field, so the form's own guards
// hold (the revision view's refusal, the document's mark). The dialog covers
// the form only, as Sanity's: the footer stays as it is. Tab stays inside;
// Escape, the close button or a click beside it closes it, and the focus goes
// back to the button that opened it.
//
// THE IMAGE'S FIELDS. An input marked `data-desk-image-part` (the field's
// `alt`, Desk.ImageParts) is not a form input of its own: what is typed goes
// to its picker (`setPart`), which writes it on the image object.
//
// A document-level listener, no phx-hook: bp-desk.js loads it when the desk
// mounts (the address is on the desk's root, `data-desk-image`).
(function () {
  "use strict";

  var doc = window.document;
  var SVG = "http://www.w3.org/2000/svg";
  var W = 560;
  var MIN = 0.05;
  var PREVIEWS = [["3:4", "3:4", 3 / 4], ["crop_square", "Square", 1], ["16:9", "16:9", 16 / 9], ["crop_panorama", "Panorama", 4]];
  var SIDES = ["top", "bottom", "left", "right", "topLeft", "topRight", "bottomLeft", "bottomRight"];
  var CORNER = { topLeft: 0, topRight: 90, bottomRight: 180, bottomLeft: 270 };
  var CORNER_PATH = "M -4 12 L -4 -4 L 12 -4 L 12 4 L 4 4 L 4 12 Z";
  var FOCUSABLE = 'button:not([disabled]), [tabindex="0"]';

  // ── The geometry (lib/image.ts), fractions of the image ─────────────────
  var clamp = function (v, lo, hi) { return Math.min(hi, Math.max(lo, v)); };
  var round = function (v) { return Math.round(v * 1e6) / 1e6; };

  function moveHotspot(h, dx, dy) {
    return { x: round(clamp(h.x + dx, h.width / 2, 1 - h.width / 2)), y: round(clamp(h.y + dy, h.height / 2, 1 - h.height / 2)), width: h.width, height: h.height };
  }
  function resizeHotspot(h, dx, dy) {
    var width = clamp(h.width + 2 * dx, MIN, 2 * Math.min(h.x, 1 - h.x));
    var height = clamp(h.height + 2 * dy, MIN, 2 * Math.min(h.y, 1 - h.y));
    return { x: h.x, y: h.y, width: round(width), height: round(height) };
  }
  // The hotspot kept inside the crop: narrowed to its size and moved in.
  function fitHotspot(h, c) {
    var l = c.left, r = 1 - c.right, t = c.top, b = 1 - c.bottom;
    var width = Math.min(h.width, r - l);
    var height = Math.min(h.height, b - t);
    var x = clamp(h.x, l + width / 2, r - width / 2);
    var y = clamp(h.y, t + height / 2, b - height / 2);
    if (x === h.x && y === h.y && width === h.width && height === h.height) return h;
    return { x: round(x), y: round(y), width: round(width), height: round(height) };
  }
  function moveCrop(c, dx, dy) {
    var ddx = clamp(dx, -c.left, c.right);
    var ddy = clamp(dy, -c.top, c.bottom);
    return { top: round(c.top + ddy), bottom: round(c.bottom - ddy), left: round(c.left + ddx), right: round(c.right - ddx) };
  }
  function dragCrop(c, side, px, py) {
    var out = { top: c.top, bottom: c.bottom, left: c.left, right: c.right };
    if (/^top/.test(side)) out.top = round(clamp(py, 0, 1 - c.bottom - MIN));
    if (/^bottom/.test(side)) out.bottom = round(clamp(1 - py, 0, 1 - c.top - MIN));
    if (/left$/i.test(side)) out.left = round(clamp(px, 0, 1 - c.right - MIN));
    if (/right$/i.test(side)) out.right = round(clamp(1 - px, 0, 1 - c.left - MIN));
    return out;
  }
  // The part a frame of `ratio` shows: the crop cut to the ratio around the hotspot.
  function frame(c, h, n, ratio) {
    var cw = (1 - c.left - c.right) * n.width, ch = (1 - c.top - c.bottom) * n.height;
    var w = cw, hh = ch;
    if (cw / ch > ratio) w = ch * ratio;
    else hh = cw / ratio;
    var left = clamp(h.x * n.width - w / 2, c.left * n.width, c.left * n.width + cw - w);
    var top = clamp(h.y * n.height - hh / 2, c.top * n.height, c.top * n.height + ch - hh);
    return { left: left / n.width, top: top / n.height, width: w / n.width, height: hh / n.height };
  }
  // One key press: [dx, dy], or null for a key that is not an arrow.
  function step(key, shift) {
    var s = shift ? 0.025 : 0.005;
    return { ArrowLeft: [-s, 0], ArrowRight: [s, 0], ArrowUp: [0, -s], ArrowDown: [0, s] }[key] || null;
  }
  function keyed(target, h, c, d) {
    if (target === "hotspot") return { h: fitHotspot(moveHotspot(h, d[0], d[1]), c), c: c };
    var nc = moveCrop(c, d[0], d[1]);
    return { h: fitHotspot(h, nc), c: nc };
  }

  // ── The dialog ────────────────────────────────────────────────────────────
  var open = null;

  var el = function (ns, tag, attrs, parent) {
    var n = ns ? doc.createElementNS(SVG, tag) : doc.createElement(tag);
    for (var k in attrs) if (attrs[k] != null) n.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(n);
    return n;
  };
  var set = function (n, attrs) { for (var k in attrs) n.setAttribute(k, attrs[k]); };
  var pct = function (v) { return Math.round(v * 100) + "%"; };
  var fill = function (text, vars) { return String(text).replace(/%\{(\w+)\}/g, function (m, k) { return k in vars ? vars[k] : m; }); };

  function openDialog(picker, opener) {
    if (open) close(false);
    var t = function (k, fallback) { return typeof picker._t === "function" ? picker._t(k, fallback) : fallback; };
    var start = picker.hotspotCrop();
    var s = { picker: picker, opener: opener, h: start.hotspot, c: start.crop, natural: null, dragging: null, unit: 1 };
    var url = picker.dialogImageUrl();
    var field = picker.closest(".field");
    var legend = field && field.querySelector("legend");
    var title = (legend && legend.firstChild && legend.firstChild.textContent.trim()) || picker.id || "";
    var id = "dk-crop-" + (picker.id || "image").replace(/[^\w-]/g, "_");

    // The layer covers the form between the title bar and the footer.
    var layer = el(false, "div", { class: "dk dk-crop-layer" }, doc.body);
    var box = el(false, "div", { class: "dk-crop-dialog dialog hotspot-dialog", role: "dialog", "aria-modal": "true", "aria-labelledby": id + "-title" }, layer);
    var head = el(false, "header", { class: "dk-dialog-head" }, box);
    el(false, "h2", { id: id + "-title" }, head).textContent = t("crop_title", "Edit hotspot and crop");
    var closer = el(false, "button", { type: "button", class: "dk-dialog-close icon-btn", "aria-label": t("crop_close", "Close dialog") }, head);
    closer.innerHTML = '<svg width="21" height="21" viewBox="0 0 25 25" fill="none" aria-hidden="true"><path stroke="currentColor" stroke-width="1.2" d="M18 7L7 18M7 7L18 18"/></svg>';
    var body = el(false, "div", { class: "dialog-body" }, box);
    el(false, "p", { class: "label" }, body).textContent = t("crop_label", "Hotspot & Crop");
    el(false, "p", { class: "muted" }, body).textContent = t("crop_help", "Adjust the rectangle to crop image. Adjust the circle to specify the area that should always be visible.");
    var tool = el(false, "div", { class: "hotspot-tool", "aria-label": fill(t("crop_tool", "%{title}: hotspot and crop"), { title: title }) }, body);
    var svg = el(true, "svg", { width: W, height: 350, viewBox: "0 0 " + W + " 350", style: "touch-action: none" }, tool);
    var faint = el(true, "image", { href: url, width: W, height: 350, opacity: "0.25" }, svg);
    var win = el(true, "svg", { overflow: "hidden" }, svg);
    var sharp = el(true, "image", { href: url, width: W, height: 350 }, win);
    var mask = el(true, "mask", { id: id + "-m" }, svg);
    var maskAll = el(true, "rect", { fill: "#fff" }, mask);
    var maskHole = el(true, "ellipse", { fill: "#000" }, mask);
    var dim = el(true, "rect", { class: "crop-dim", mask: "url(#" + id + "-m)", "pointer-events": "none" }, svg);
    var guides = el(true, "g", { class: "hotspot-guides" }, svg);
    var lines = [0, 1, 2, 3, 4, 5].map(function () { return el(true, "line", {}, guides); });
    var area = el(true, "rect", { class: "crop-area" }, svg);
    var spot = el(true, "ellipse", { class: "hotspot", "data-handle": "hotspot", tabindex: "0", role: "slider", "aria-label": t("crop_hotspot", "Hotspot: arrow keys move it") }, svg);
    var grabH = el(true, "circle", { class: "handle-grab" }, svg);
    var knob = el(true, "circle", { class: "hotspot-handle", "pointer-events": "none" }, svg);
    var hitH = el(true, "circle", { class: "handle-hit", "data-handle": "hotspotHandle" }, svg);
    var rect = el(true, "rect", { class: "crop-rect", "data-handle": "crop", tabindex: "0", role: "slider", "aria-label": t("crop_crop", "Crop: arrow keys move it") }, svg);
    var handles = SIDES.map(function (side) {
      var g = el(true, "g", {}, svg);
      return {
        side: side,
        grab: el(true, "circle", { class: "handle-grab" }, g),
        mark: el(true, CORNER[side] === undefined ? "rect" : "path", { class: "crop-handle", "pointer-events": "none", d: CORNER[side] === undefined ? null : CORNER_PATH }, g),
        hit: el(true, "rect", { class: "handle-hit", "data-handle": "crop-" + side }, g)
      };
    });
    var badge = el(true, "g", { class: "crop-size", "pointer-events": "none" }, svg);
    var badgeTitle = el(true, "title", {}, badge);
    var badgeBox = el(true, "rect", {}, badge);
    var badgeText = el(true, "text", { "text-anchor": "middle", "dominant-baseline": "central" }, badge);
    var previews = el(false, "div", { class: "crop-previews", hidden: "" }, body);
    var shots = PREVIEWS.map(function (p) {
      var fig = el(false, "figure", {}, previews);
      el(false, "figcaption", {}, fig).textContent = p[0] === p[1] ? p[1] : t(p[0], p[1]);
      var frameEl = el(false, "div", { class: "crop-preview", style: "aspect-ratio: " + p[2] }, fig);
      return { ratio: p[2], img: el(false, "img", { src: url, alt: "" }, frameEl) };
    });

    function draw() {
      var H = s.natural ? (W * s.natural.height) / s.natural.width : 350;
      var u = s.unit, h = s.h, c = s.c;
      var cx = h.x * W, cy = h.y * H, rx = (h.width * W) / 2, ry = (h.height * H) / 2;
      var cr = { x: c.left * W, y: c.top * H, w: (1 - c.left - c.right) * W, h: (1 - c.top - c.bottom) * H };
      set(svg, { viewBox: "0 0 " + W + " " + H, height: H });
      set(faint, { height: H });
      set(sharp, { height: H });
      set(win, { x: cr.x, y: cr.y, width: cr.w, height: cr.h, viewBox: cr.x + " " + cr.y + " " + cr.w + " " + cr.h });
      set(maskAll, { width: W, height: H });
      set(maskHole, { cx: cx, cy: cy, rx: rx, ry: ry });
      [dim, area, rect].forEach(function (n) { set(n, { x: cr.x, y: cr.y, width: cr.w, height: cr.h }); });
      [cx - rx, cx, cx + rx].forEach(function (x, i) { set(lines[i], { x1: x, y1: 0, x2: x, y2: H }); });
      [cy - ry, cy, cy + ry].forEach(function (y, i) { set(lines[i + 3], { x1: 0, y1: y, x2: W, y2: y }); });
      set(spot, { cx: cx, cy: cy, rx: rx, ry: ry, "aria-valuetext": fill(t("crop_hotspot_value", "centre %{x} across, %{y} down; %{width} wide, %{height} high"), { x: pct(h.x), y: pct(h.y), width: pct(h.width), height: pct(h.height) }) });
      set(rect, { "aria-valuetext": fill(t("crop_crop_value", "left %{left}, top %{top}, right %{right}, bottom %{bottom}"), { left: pct(c.left), top: pct(c.top), right: pct(c.right), bottom: pct(c.bottom) }) });
      var hx = cx + rx * Math.SQRT1_2, hy = cy + ry * Math.SQRT1_2;
      set(grabH, { cx: hx, cy: hy, r: 22 * u });
      set(knob, { cx: hx, cy: hy, r: 8 * u });
      set(hitH, { cx: hx, cy: hy, r: 12 * u });
      var at = { top: [cr.x + cr.w / 2, cr.y], bottom: [cr.x + cr.w / 2, cr.y + cr.h], left: [cr.x, cr.y + cr.h / 2], right: [cr.x + cr.w, cr.y + cr.h / 2], topLeft: [cr.x, cr.y], topRight: [cr.x + cr.w, cr.y], bottomLeft: [cr.x, cr.y + cr.h], bottomRight: [cr.x + cr.w, cr.y + cr.h] };
      handles.forEach(function (hd) {
        var p = at[hd.side], x = p[0], y = p[1];
        set(hd.grab, { cx: x, cy: y, r: 22 * u });
        set(hd.hit, { x: x - 12 * u, y: y - 12 * u, width: 24 * u, height: 24 * u });
        if (CORNER[hd.side] !== undefined) set(hd.mark, { transform: "translate(" + x + " " + y + ") rotate(" + CORNER[hd.side] + ") scale(" + u + ")" });
        else {
          var bw = /^(top|bottom)$/.test(hd.side) ? 16 * u : 8 * u, bh = /^(top|bottom)$/.test(hd.side) ? 8 * u : 16 * u;
          set(hd.mark, { x: x - bw / 2, y: y - bh / 2, width: bw, height: bh });
        }
      });
      tool.toggleAttribute("data-dragging", !!s.dragging);
      if (s.dragging) tool.setAttribute("data-dragging", s.dragging);
      if (!s.natural) return;
      var size = Math.round((1 - c.left - c.right) * s.natural.width) + " × " + Math.round((1 - c.top - c.bottom) * s.natural.height);
      var bw2 = (size.length * 7.8 + 12) * u;
      badgeTitle.textContent = fill(t("crop_size", "Cropped image size: %{size} pixels"), { size: size });
      set(badgeBox, { x: cr.x + cr.w / 2 - bw2 / 2, y: cr.y + cr.h + 8 * u, width: bw2, height: 19 * u, rx: 3 * u });
      set(badgeText, { x: cr.x + cr.w / 2, y: cr.y + cr.h + 17.5 * u, style: "font-size: " + 10 * u + "px" });
      badgeText.textContent = size;
      shots.forEach(function (sh) {
        var f = frame(c, h, s.natural, sh.ratio);
        sh.img.style.cssText = "width: " + 100 / f.width + "%; height: " + 100 / f.height + "%; left: " + (-f.left / f.width) * 100 + "%; top: " + (-f.top / f.height) * 100 + "%";
      });
    }

    var write = function () { picker.setHotspotCrop(s.h, s.c); };
    var pointAt = function (e) {
      var r = svg.getBoundingClientRect();
      return { x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height };
    };
    // A drag from `node`: `apply` maps the pointer to a new hotspot and crop.
    var drag = function (node, what, apply, before) {
      node.addEventListener("pointerdown", function (e) {
        if (e.button !== 0) return;
        e.preventDefault();
        e.stopPropagation();
        if (before) before();
        var from = { h: s.h, c: s.c }, p0 = pointAt(e);
        s.dragging = what;
        var move = function (ev) {
          var next = apply(pointAt(ev), p0, from);
          s.h = fitHotspot(next.h, next.c);
          s.c = next.c;
          draw();
        };
        var up = function () {
          window.removeEventListener("pointermove", move);
          window.removeEventListener("pointerup", up);
          s.dragging = null;
          draw();
          write();
        };
        window.addEventListener("pointermove", move);
        window.addEventListener("pointerup", up);
      });
    };
    drag(area, "crop", function (p, p0, f) { return { h: f.h, c: moveCrop(f.c, p.x - p0.x, p.y - p0.y) }; }, function () { rect.focus(); });
    drag(spot, "hotspot", function (p, p0, f) { return { h: moveHotspot(f.h, p.x - p0.x, p.y - p0.y), c: f.c }; });
    [grabH, hitH].forEach(function (n) { drag(n, "hotspot", function (p, p0, f) { return { h: resizeHotspot(f.h, p.x - p0.x, p.y - p0.y), c: f.c }; }); });
    handles.forEach(function (hd) {
      [hd.grab, hd.hit].forEach(function (n) { drag(n, "crop", function (p, _p0, f) { return { h: f.h, c: dragCrop(f.c, hd.side, p.x, p.y) }; }); });
    });
    [[spot, "hotspot"], [rect, "crop"]].forEach(function (pair) {
      pair[0].addEventListener("keydown", function (e) {
        var d = step(e.key, e.shiftKey);
        if (!d) return;
        e.preventDefault();
        var next = keyed(pair[1], s.h, s.c, d);
        s.h = next.h;
        s.c = next.c;
        draw();
        write();
      });
    });

    closer.addEventListener("click", function () { close(true); });
    // A press on the backdrop closes it. Its default action would move the
    // focus to <body> after `close` gave it back to the opener: prevent it.
    layer.addEventListener("mousedown", function (e) {
      if (e.target !== layer) return;
      e.preventDefault();
      close(true);
    });
    var onKey = function (e) {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        close(true);
      } else if (e.key === "Tab") {
        var all = Array.prototype.slice.call(box.querySelectorAll(FOCUSABLE));
        var i = all.indexOf(doc.activeElement);
        if (i === -1 || (e.shiftKey && i === 0) || (!e.shiftKey && i === all.length - 1)) {
          e.preventDefault();
          all[e.shiftKey ? (i <= 0 ? all.length - 1 : i - 1) : (i === -1 || i === all.length - 1 ? 0 : i + 1)].focus();
        }
      }
    };
    var place = function () {
      var host = opener.closest(".dk-edit");
      var form = host && host.querySelector(".dk-edit-body");
      var r = (form || host || doc.body).getBoundingClientRect();
      layer.style.cssText = "left: " + r.left + "px; top: " + r.top + "px; width: " + r.width + "px; height: " + r.height + "px";
      var w = svg.getBoundingClientRect().width;
      if (w) s.unit = W / w;
      draw();
    };
    doc.addEventListener("keydown", onKey, true);
    window.addEventListener("resize", place);
    var img = new Image();
    img.onload = function () {
      if (open !== s) return;
      s.natural = { width: img.naturalWidth, height: img.naturalHeight };
      previews.hidden = false;
      place();
    };
    img.src = url;
    s.layer = layer;
    s.cleanup = function () {
      doc.removeEventListener("keydown", onKey, true);
      window.removeEventListener("resize", place);
    };
    open = s;
    place();
    closer.focus();
  }

  function close(restore) {
    var s = open;
    if (!s) return;
    open = null;
    s.cleanup();
    s.layer.remove();
    if (!restore) return;
    // The opener, or the same picker's button if a render replaced it; never <body>.
    var back = s.opener.isConnected ? s.opener : s.picker.querySelector(".bp-mp-crop") || s.picker.querySelector(".bp-mp-frame");
    if (back) back.focus();
  }

  // ── The image's fields ────────────────────────────────────────────────────
  doc.addEventListener("input", function (e) {
    var input = e.target && e.target.closest ? e.target.closest("[data-desk-image-part]") : null;
    if (!input) return;
    var picker = doc.getElementById(input.getAttribute("data-desk-image-for") || "");
    if (picker && typeof picker.setPart === "function") picker.setPart(input.getAttribute("data-desk-image-part"), input.value);
  });

  window.BarkparkDeskImage = {
    open: openDialog,
    close: function () { close(true); },
    geometry: { moveHotspot: moveHotspot, resizeHotspot: resizeHotspot, fitHotspot: fitHotspot, moveCrop: moveCrop, dragCrop: dragCrop, frame: frame, step: step, keyed: keyed }
  };
})();
