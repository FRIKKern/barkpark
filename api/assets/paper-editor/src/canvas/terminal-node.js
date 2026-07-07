// terminal-node.js — the SECOND canvas CONTAINER node — an in-canvas, recursively-
// editable `terminal` block. Modeled on columns-node.js (container recursion +
// verbatim child-atom) fused with callout-node.js/table-node.js (reader-shaped
// chrome OUTSIDE a contentDOM).
//
// UNLIKE columns (a grid of N columns) a terminal has a SINGLE body — ONE editable
// recursive region wrapped in terminal chrome (a traffic-light title bar with an
// optional `live` badge, plus an optional keybind `footer`). It brings a portable-
// doc `terminal` block INTO the continuous canvas as TWO cooperating ProseMirror
// nodes (mirroring bpColumn + bpColumnAtom, minus the grid wrapper):
//
//   bpTerminal (the container)  content:"(paragraph | heading | bulletList |
//     orderedList | divider | bpTerminalAtom)+"  — the `.bp-term` frame; its body
//     becomes a real editable PM region (prose + leaf divider) with any non-first-
//     class child carried VERBATIM/read-only on a bpTerminalAtom. defining +
//     isolating keep the caret inside the body (Backspace at body-start lifts OUT,
//     never dissolves the chrome; a paragraph can't merge IN). The content allow-
//     list DELIBERATELY OMITS bpTerminal/bpColumns/bpTable — schema-level
//     "no container-in-container" (the V1 greenlit decision).
//   bpTerminalAtom (verbatim read-only carrier)  atom:true — IDENTICAL to
//     bpColumnAtom: a body child can be ANY block type (callout/code/sheet/fleet/
//     image/nested-container/table). Those are NOT valid bpTerminal children by
//     name, so a non-representable child rides VERBATIM on this atom (the whole
//     child block deep-cloned onto `bpBlock`), shown as a read-only "· <bpType> ·"
//     chip. It emits ZERO ops of its own and round-trips the child byte-identically
//     through the coarse `terminal` patch.
//
// V1 COARSE round-trip: any interior change (a keystroke in the body, a child add/
// delete, a chrome title/footer/live edit) re-emits ONE `patch-block` REPLACING the
// whole body child array + the three chrome scalars. An UNEDITED terminal emits
// ZERO ops (run-convert.js terminalNodeChanged). See run-convert.js.
//
// DOM discipline: the bpTerminal / bpTerminalAtom Node SCHEMAS load in plain Node —
// they import ONLY @tiptap/core and reference `document` LAZILY (only inside
// addNodeView, which never runs in the pure-Node smoke harness), exactly like
// callout/table/columns. So run-convert.js (which references the terminal TYPE
// only, never the node-view) imports cleanly DOM-free.
//
// Reader parity: the node-view root carries the READER's own classes (`bp-term` +
// `bp-term__bar/__dots/__title/__body/__foot/__live`) so paper-surface.css paints it
// byte-for-byte through the ancestor `.bp-paper-surface` cascade (the canvas mounts
// inside `.bp-paper-surface`). `bp-canvas-term*` stays a thin edit-only layout hook,
// the bp-canvas-callout / bp-canvas-table precedent. ZERO reader CSS drift.

import { Node, mergeAttributes } from "@tiptap/core";

// Node NAMES (the canvas bp-prefix convention). No StarterKit collision (StarterKit
// ships no terminal node), so NO StarterKit node is disabled. Keep aligned with
// run-convert.js:CANVAS_CONTAINER_NODE_NAMES / BP_TERMINAL_ATOM_NODE_NAME.
export const BP_TERMINAL_NODE_NAME = "bpTerminal";
export const BP_TERMINAL_ATOM_NODE_NAME = "bpTerminalAtom";

// ── bpTerminal: the container (a SINGLE editable body wrapped in chrome) ──────
export const Terminal = Node.create({
  name: BP_TERMINAL_NODE_NAME,
  group: "block",
  // The FORBID-NESTING allow-list (identical to bpColumn): prose + leaf divider +
  // the verbatim carrier. bpTerminal/bpColumns/bpTable are DELIBERATELY ABSENT
  // (schema-level no-container-in-container, the V1 decision).
  content:
    "(paragraph | heading | bulletList | orderedList | divider | " +
    BP_TERMINAL_ATOM_NODE_NAME +
    ")+",
  defining: true,
  isolating: true,
  selectable: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by. data-bp-id survives the
      // setContent->getJSON round-trip (same role as callout/divider bpId).
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — the original portable-doc block kind ("terminal").
      bpType: {
        default: "terminal",
        parseHTML: (el) => el.getAttribute("data-bp-type"),
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
      },
      // title — the optional bar title. null when absent (the callout title-fidelity
      // contract): present→string, absent→null; a null title round-trips ABSENT,
      // never "" (compose reads Map.get(b,"title","") so null/"" render identically,
      // but we keep the byte contract of the callout precedent).
      title: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-title") ? el.getAttribute("data-title") : null,
        renderHTML: (attrs) =>
          attrs.title != null ? { "data-title": attrs.title } : {},
      },
      // footer — the optional keybind footer, same null/present shape as title.
      footer: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-footer") ? el.getAttribute("data-footer") : null,
        renderHTML: (attrs) =>
          attrs.footer != null ? { "data-footer": attrs.footer } : {},
      },
      // live — the `live` badge flag. Boolean; data-live="true" only when true
      // (absent otherwise so a non-live terminal round-trips ABSENT). Mirrors the
      // compose `Map.get(b,"live") in [true,"true","live"]` gate.
      live: {
        default: false,
        parseHTML: (el) => el.getAttribute("data-live") === "true",
        renderHTML: (attrs) =>
          attrs.live === true ? { "data-live": "true" } : {},
      },
    };
  },

  // Specific parse rule (data-bp-type='terminal') so a bare <div> stays unclaimed.
  parseHTML() {
    return [{ tag: "div[data-bp-type='terminal']" }];
  },

  // Schema-level fallback render (the pure-Node / non-node-view path — keeps the
  // schema self-describing + gives parseHTML a target). The reader shell with a `0`
  // body content-hole nested in `.bp-term__body`, so setContent->getJSON round-trips.
  // The node-view (below) OVERRIDES this live.
  renderHTML({ node, HTMLAttributes }) {
    const attrs = (node && node.attrs) || {};
    const bar = [
      "div",
      { class: "bp-term__bar" },
      ["span", { class: "bp-term__dots" }, ["i"], ["i"], ["i"]],
      [
        "span",
        { class: "bp-term__title" },
        attrs.title != null ? attrs.title : "",
      ],
      ...(attrs.live === true
        ? [["span", { class: "bp-term__live" }, "live"]]
        : []),
    ];
    const body = ["div", { class: "bp-term__body" }, 0];
    const foot =
      attrs.footer != null && attrs.footer !== ""
        ? [["div", { class: "bp-term__foot" }, attrs.footer]]
        : [];
    return [
      "div",
      mergeAttributes(HTMLAttributes, {
        "data-bp-type": "terminal",
        class: "bp-term",
      }),
      bar,
      body,
      ...foot,
    ];
  },

  // ── the NodeView: reader-shaped terminal chrome around an editable body ──────
  addNodeView() {
    return ({ node, editor, getPos }) => {
      // Apply an attrs patch to THIS node via a PM transaction (the callout toggle
      // pattern). Reads the live node at getPos each time so a stale closure never
      // clobbers a concurrent edit.
      const setAttrs = (patch) => {
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== BP_TERMINAL_NODE_NAME) return;
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, { ...cur.attrs, ...patch });
            return true;
          })
          .run();
      };

      const dom = document.createElement("div");
      dom.className = "bp-term bp-canvas-term";
      dom.setAttribute("data-bp-type", "terminal");

      // ── bar (chrome, contenteditable=false) ──
      const bar = document.createElement("div");
      bar.className = "bp-term__bar";
      bar.contentEditable = "false";

      const dots = document.createElement("span");
      dots.className = "bp-term__dots";
      dots.innerHTML = "<i></i><i></i><i></i>";

      // title affordance: an <input> styled to inherit the reader's mono/soft-ink so
      // the canvas LOOKS like the reader span. Empty clears the attr to null.
      const titleInput = document.createElement("input");
      titleInput.className = "bp-term__title bp-canvas-term__title-input";
      titleInput.setAttribute("type", "text");
      titleInput.setAttribute("placeholder", "title");
      titleInput.addEventListener("input", () => {
        const v = titleInput.value;
        setAttrs({ title: v === "" ? null : v });
      });

      // live affordance: a hover-revealed edit-only toggle button + (when live) the
      // reader's own <span class="bp-term__live">live</span> so the resting canvas
      // == the reader.
      const liveBadge = document.createElement("span");
      liveBadge.className = "bp-term__live";
      liveBadge.textContent = "live";

      const liveToggle = document.createElement("button");
      liveToggle.type = "button";
      liveToggle.className = "bp-canvas-term__live-toggle";
      liveToggle.contentEditable = "false";
      liveToggle.addEventListener("mousedown", (e) => e.preventDefault());
      liveToggle.addEventListener("click", (e) => {
        e.preventDefault();
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== BP_TERMINAL_NODE_NAME) return;
        setAttrs({ live: !(cur.attrs && cur.attrs.live) });
      });

      bar.appendChild(dots);
      bar.appendChild(titleInput);
      bar.appendChild(liveBadge);
      bar.appendChild(liveToggle);

      // ── body (THE contentDOM — the editable recursive region) ──
      const body = document.createElement("div");
      body.className = "bp-term__body";

      // ── foot (chrome, contenteditable=false) ──
      // footWrap holds the reader-shaped foot + its edit input; when footer==null the
      // "+ footer" affordance (addFootBtn) shows instead (both hover-revealed).
      const footChrome = document.createElement("div");
      footChrome.className = "bp-canvas-term__foot-chrome";
      footChrome.contentEditable = "false";

      const footWrap = document.createElement("div");
      footWrap.className = "bp-term__foot bp-canvas-term__foot";
      const footInput = document.createElement("input");
      footInput.className = "bp-canvas-term__foot-input";
      footInput.setAttribute("type", "text");
      footInput.setAttribute("placeholder", "footer");
      footInput.addEventListener("input", () => {
        const v = footInput.value;
        setAttrs({ footer: v === "" ? null : v });
      });
      footWrap.appendChild(footInput);

      const addFootBtn = document.createElement("button");
      addFootBtn.type = "button";
      addFootBtn.className = "bp-canvas-term__add-foot";
      addFootBtn.textContent = "+ footer";
      addFootBtn.contentEditable = "false";
      addFootBtn.addEventListener("mousedown", (e) => e.preventDefault());
      addFootBtn.addEventListener("click", (e) => {
        e.preventDefault();
        // Seed an empty footer ("" != null → the input shows) and focus it.
        setAttrs({ footer: "" });
        // Focus after the transaction repaints the chrome.
        setTimeout(() => footInput.focus(), 0);
      });

      footChrome.appendChild(footWrap);
      footChrome.appendChild(addFootBtn);

      dom.appendChild(bar);
      dom.appendChild(body);
      dom.appendChild(footChrome);

      // Paint the chrome from the node's current attrs. Guard input.value writes so a
      // repaint never resets the caret while the author is typing (only write when the
      // value actually differs).
      const paint = (n) => {
        const a = (n && n.attrs) || {};
        const title = a.title != null ? a.title : "";
        if (titleInput.value !== title) titleInput.value = title;

        const isLive = a.live === true;
        liveBadge.style.display = isLive ? "" : "none";
        liveToggle.textContent = isLive ? "live ✓" : "live";
        liveToggle.classList.toggle("is-on", isLive);

        const hasFooter = a.footer != null;
        footWrap.style.display = hasFooter ? "" : "none";
        addFootBtn.style.display = hasFooter ? "none" : "";
        if (hasFooter) {
          const f = a.footer;
          if (footInput.value !== f) footInput.value = f;
        }
      };

      paint(node);

      return {
        dom,
        contentDOM: body,
        update: (updated) => {
          if (updated.type.name !== BP_TERMINAL_NODE_NAME) return false;
          paint(updated);
          return true;
        },
        // A chrome event (title/footer typing, live toggle, +footer) must NEVER
        // become a PM transaction; body events MUST reach PM (typing/selection).
        stopEvent: (event) => {
          const t = event.target;
          return bar.contains(t) || footChrome.contains(t);
        },
        // PM only sees contentDOM (body) mutations — the callout/table rule. Chrome
        // mutations (badge toggle, foot show/hide) are ignored.
        ignoreMutation: (mutation) => {
          if (mutation.type === "selection") return false;
          return !body.contains(mutation.target);
        },
      };
    };
  },
});

// ── bpTerminalAtom: the generic verbatim READ-ONLY child carrier ─────────────
// IDENTICAL to bpColumnAtom. A body child can be ANY block type; only prose +
// divider are valid bpTerminal children by NAME, so every other kind is projected
// onto this atom, carrying the WHOLE child block VERBATIM on `bpBlock` (deep-cloned),
// rendered as a read-only "· <bpType> ·" chip. It emits ZERO ops of its own and
// rides the coarse `terminal` patch. Named bp-canvas-term__atom (edit-only, NOT a
// reader class) so it needs NO gate exemption — the reader renders the real child
// fully on /papers; this chip never competes as a producer.
function terminalAtomBlockAttribute() {
  return {
    bpBlock: {
      default: null,
      parseHTML: (el) => {
        const raw = el.getAttribute("data-bp-block");
        if (raw == null || raw === "") return null;
        try {
          return JSON.parse(raw);
        } catch (_) {
          return null;
        }
      },
      renderHTML: (attrs) =>
        attrs.bpBlock != null
          ? { "data-bp-block": JSON.stringify(attrs.bpBlock) }
          : {},
    },
  };
}

export const TerminalAtom = Node.create({
  name: BP_TERMINAL_ATOM_NODE_NAME,

  // No group — valid ONLY as a bpTerminal child by name, never top-level/free.
  atom: true,
  selectable: true,
  defining: true,

  addAttributes() {
    return {
      // bpType — the CARRIED child's kind (so the chip can label it and run-convert.js
      // can read it back). data-bp-child-type (NOT data-bp-type, which is the atom's
      // own marker). default null.
      bpType: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-child-type"),
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-child-type": attrs.bpType } : {},
      },
      // bpId — carried for symmetry (non-load-bearing; the reader ignores child ids).
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      ...terminalAtomBlockAttribute(),
    };
  },

  // Parse ONLY our own editor-only marker (never the child's real type).
  parseHTML() {
    return [{ tag: "div[data-bp-type='terminal-atom']" }];
  },

  // Schema-level fallback render (no node-view mounted — pure-Node round-trip). The
  // whole block rides the typed bpBlock attr; data-bp-type is the parse anchor.
  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, { "data-bp-type": "terminal-atom" }),
    ];
  },

  // The NodeView: a read-only "· <bpType> ·" chip (the embed-node.js pattern).
  addNodeView() {
    return ({ node }) => {
      const block = (node.attrs && node.attrs.bpBlock) || {};
      const bpType =
        (node.attrs && node.attrs.bpType) || (block && block.type) || "block";

      const dom = document.createElement("div");
      dom.className = "bp-canvas-term__atom";
      dom.setAttribute("contenteditable", "false");
      dom.setAttribute("data-bp-type", "terminal-atom");
      dom.setAttribute("data-test-id", "paper-terminal-atom");
      dom.textContent = `· ${bpType} ·`;

      return {
        dom,
        update: (updated) => {
          if (updated.type.name !== BP_TERMINAL_ATOM_NODE_NAME) return false;
          const b = (updated.attrs && updated.attrs.bpBlock) || {};
          const t =
            (updated.attrs && updated.attrs.bpType) || (b && b.type) || "block";
          dom.textContent = `· ${t} ·`;
          return true;
        },
        stopEvent: () => true,
        ignoreMutation: () => true,
      };
    };
  },
});
