// section-node.js — Phase-4: the FIRST canvas CONTAINER node-view.
//
// Brings the `section` block INTO the continuous canvas as a ProseMirror CONTAINER
// node (`bpSection`) — a block whose BODY is a nested `block+` region of ordinary
// portable-doc blocks, wrapped by editable/read-only CHROME (two rules + an optional
// bold title on its own line). This is the FOURTH node-view shape:
//   * divider — an ATOM leaf (no interior).
//   * callout — a CONTENT node with a PM-managed INLINE body.
//   * code    — an ATOM whose text rides in an attr, edited by a NON-PM island.
//   * section — a CONTAINER whose body is a PM-managed BLOCK+ region (nested blocks),
//               with an EDITABLE title chrome (a contentEditable island writing
//               node.attrs.title) rendered OUTSIDE the contentDOM.
//
// ── READER GROUND TRUTH (compose.ex:201-214 → walk.ex box()/hr()/text()) ──────
//
//   <div style="display:flex;flex-direction:column">   ← PdBox, flexDirection:column
//     <hr class="bp-hr" style="border-top-width:1px">   ← leading PdHr
//     <span style="font-weight:bold">TITLE</span>       ← title PdText (ONLY when set)
//     …inner children (each compose_block→walk, in column order)…
//     <hr class="bp-hr" style="border-top-width:1px">   ← trailing PdHr
//   </div>
//
//   There is NO `bp-section` reader class — the wrapper is a generic flex-column
//   div with INLINE styles and the title is a bare bold <span> on its OWN LINE (flex
//   column stacks it ABOVE the body, NOT run-in). Only `bp-hr` is a shared reader
//   class (paper-surface.css + the styles.css/root.html.heex mirror), so the two HRs
//   inherit reader-identical rules for free. The node-view hand-matches the rest as
//   inline style (route a — no reader change).
//
// ── PERSIST SHAPE (unchanged; backend nests + recurses — compose.ex:201, patch.ex) ─
//
//   { id, type:"section", title?, blocks:[child, …] }
//   * title  — PRESENT-ONLY string. A null/absent title round-trips as ABSENT (never
//     ""), byte-mirroring callout.title (renderHTML omits data-title when null).
//   * blocks — an ordered child block list; each child is a normal portable-doc block.
//
// ── V1 NESTING POLICY (reconciles arbitrary backend nesting with "forbid container-
//    in-container" for v1) ──────────────────────────────────────────────────────
//   A TOP-LEVEL section projects to this editable bpSection container. A section
//   encountered as a CHILD (depth>=1) projects to bpOpaque (verbatim read-only carry;
//   see run-convert.js sectionBlockToNode's depth-guard), so a legacy nested section
//   round-trips byte-identical and is NEVER restructured. The CONTENT expression below
//   FORBIDS bpSection as a child, so PM cannot AUTHOR a section-in-section — the schema
//   is the guard against the silent-lift trap.
//
//   `bpOpaque` IS in the content expression: a section body can legitimately hold a
//   non-canvas child (a nested section, or a composite/codelist/localizedText that is
//   not canvas-eligible), which run-convert projects to a bpOpaque verbatim carry. If
//   bpOpaque were NOT an allowed child, PM would LIFT it out of the section on
//   setContent → data restructuring on OPEN. Allowing it keeps such a child as a
//   read-only carry INSIDE the section, round-tripping byte-identical.
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in plain
// Node (imports ONLY @tiptap/core; references `document` lazily inside the NodeView
// factory, which never runs in the pure-Node smoke harness). So __smoke.mjs imports
// run-convert.js (which references the bpSection TYPE only, never the NodeView)
// without a browser.

import { Node, mergeAttributes } from "@tiptap/core";

// The TipTap node NAME is `bpSection` (avoids any StarterKit collision — StarterKit
// ships no `section` node). Its portable-doc `bpType` stays "section" (run-convert.js
// maps a block.type "section" to this node and back via node.attrs.bpType), so the
// persist contract is unchanged — the SAME node/bpType indirection bpCode/bpDiagram use.
export const BP_SECTION_NODE_NAME = "bpSection";

// The section's persisted bpType.
export const BP_SECTION_BP_TYPE = "section";

// STEP-2 LAYOUT ENGINE (canvas side). The gap token → CSS-var vocabulary MIRRORS
// the ONE Elixir helper (compose.ex gap_token_var/1) so the reader and the canvas
// resolve gaps identically (RISK #5). Default (absent/unknown) → md.
const GAP_VARS = {
  none: "var(--bp-space-none,0)",
  sm: "var(--bp-space-sm,0.8rem)",
  md: "var(--bp-space-md,1.6rem)",
  lg: "var(--bp-space-lg,2.4rem)",
};
const gapVar = (token) => GAP_VARS[token] || GAP_VARS.md;

// The grid predicate — the JS twin of compose.ex grid_layout/1. A layout is a grid
// ONLY when mode === "grid"; absence, null, or any other mode is stack (byte-parity).
const isGridLayout = (layout) => !!(layout && layout.mode === "grid");

// The EXACT JS twin of Elixir `Integer.parse/1` + the reader's `{i, ""}` remainder
// guard: a string is accepted ONLY when it is a WHOLE integer (no trailing chars, no
// trim — `"2px"` / `"2 "` / `" 2"` are DROPPED, matching the reader which requires an
// empty remainder). A real number passes through iff integral. `parseInt` was too
// lenient (`"2px" -> 2`), so the canvas applied a value the strict reader dropped —
// breaking the reader↔canvas "resolve identically" invariant.
export const strictInt = (v) => {
  if (typeof v === "number") return Number.isInteger(v) ? v : null;
  if (typeof v === "string" && /^-?\d+$/.test(v)) return parseInt(v, 10);
  return null;
};

// tracks → a positive integer (default 2, matching the CSS --bp-tracks fallback).
const gridTracks = (layout) => {
  const n = strictInt(layout && layout.tracks);
  return n !== null && n > 0 ? n : 2;
};

// STEP-6 per-child placement clamps — the JS twins of compose.ex span_int/order_int
// (reader and canvas resolve IDENTICALLY, via strictInt above). A child `span` is a
// POSITIVE int → CSS `grid-column: span N`; a child `order` is ANY int (0 / negatives
// are legal CSS `order`). Anything else → null → NO inline style (fail-soft, exactly
// as the reader drops a malformed value).
const cellSpan = (v) => {
  const n = strictInt(v);
  return n !== null && n > 0 ? n : null;
};
const cellOrder = (v) => strictInt(v);

// CONTENT EXPRESSION (V1 forbid nested containers). The allowed child roster is the
// canvas node roster MINUS bpSection (so a section cannot hold a section), PLUS
// bpOpaque (the verbatim read-only carry for a non-canvas or nested-section child —
// without it those children would be LIFTED out of the section by PM on setContent).
//
// LOCKSTEP SEAM: this enumeration must track the canvas node roster (@canvas_types
// minus section, expressed as NODE names). It is pinned by a test
// (src/smoke/sections.mjs). The group-based alternative (a shared `group:"block
// bpSectionChild"` on every allowed node + content:"bpSectionChild+") is cleaner
// long-term but touches every node file + StarterKit globals — rejected for v1.
export const BP_SECTION_CONTENT =
  "(paragraph | heading | bulletList | orderedList | divider | callout | bpCard | bpStage | " +
  "bpCode | bpDiagram | bpField | bpSheet | bpEmbed | bpFleet | " +
  "eyebrow | byline | ingress | pullquote | bpOpaque)+";

export const Section = Node.create({
  name: BP_SECTION_NODE_NAME,

  // A top-level block sibling inside the one canvas document. group:"block" lets it
  // sit in the doc's `block+` content.
  group: "block",

  // The body is a nested BLOCK+ region of the allowed children (see BP_SECTION_CONTENT).
  content: BP_SECTION_CONTENT,

  // defining — PM won't merge the container into an adjacent textblock on
  // backspace-at-edge.
  defining: true,

  // isolating — seals the boundary: the caret can't escape/join across it, Backspace
  // at the first-child start stays inside, and select-all inside selects the section
  // unit. These are the container gate behaviors.
  isolating: true,

  // Selectable as a whole unit (NodeSelection).
  selectable: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by. data-bp-id survives the
      // setContent->getJSON round-trip (same role as BpAttrs.bpId / callout / code).
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — the original portable-doc block kind ("section"). Carried for
      // symmetry so runToOps/classifyNode read the type back off node.attrs.
      bpType: {
        default: BP_SECTION_BP_TYPE,
        parseHTML: (el) => el.getAttribute("data-bp-type") || BP_SECTION_BP_TYPE,
        renderHTML: (attrs) => ({
          "data-bp-type": attrs.bpType || BP_SECTION_BP_TYPE,
        }),
      },
      // title — the optional bold title. null when absent (compose.ex maybe_put only
      // threads it when present), so we render NO data-title for a null title — a null
      // title must round-trip as ABSENT, never "" (byte-fidelity, byte-mirrors
      // callout.title).
      title: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-title") ? el.getAttribute("data-title") : null,
        renderHTML: (attrs) =>
          attrs.title != null ? { "data-title": attrs.title } : {},
      },
      // FRAMED-FINALE (charter D34) — variant, a SCALAR string ("framed"). PRESENT-ONLY
      // (null/absent round-trips ABSENT, byte-mirrors title). This declaration is
      // LOAD-BEARING: ProseMirror STRIPS undeclared attrs on setContent, so even with
      // the run-convert threads in place an undeclared variant dies at the schema.
      variant: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-variant") ? el.getAttribute("data-variant") : null,
        renderHTML: (attrs) =>
          attrs.variant != null ? { "data-variant": attrs.variant } : {},
      },
      // STEP-2 LAYOUT ENGINE — two PRESENT-ONLY JSON data-attrs (the bpColumnAtom
      // bpBlock precedent: a JSON object survives setContent→getJSON because it rides
      // a data-attr, not a dropped node key).
      //
      // layout — { mode:"stack"|"grid", tracks?, gap?, breakpoints? }. null/absent
      // round-trips ABSENT (present-only). run-convert lowers it to block.layout and
      // grid_layout(mode=="grid") gates the reader's grid path.
      layout: {
        default: null,
        parseHTML: (el) => {
          const raw = el.getAttribute("data-layout");
          if (raw == null) return null;
          try {
            return JSON.parse(raw);
          } catch {
            return null;
          }
        },
        renderHTML: (attrs) =>
          attrs.layout != null ? { "data-layout": JSON.stringify(attrs.layout) } : {},
      },
      // cells — a bpId-keyed OBJECT map `{ [childBpId]: { span?, order? } }`, the
      // getJSON-safe transport for child span/order (prose/canvas child nodes drop
      // unknown keys). run-convert hoists/splits it; persisted layout stays cells-free.
      // STEP-6 (RISK #1 FIXED): keyed by child bpId — a canvas reorder leaves
      // attrs.cells untouched, so bpId keying pulls each child's OWN cell regardless
      // of position (a positional array misassigned on reorder). paint() reads this
      // map and applies grid-column/order per child. null/absent round-trips ABSENT.
      cells: {
        default: null,
        parseHTML: (el) => {
          const raw = el.getAttribute("data-cells");
          if (raw == null) return null;
          try {
            return JSON.parse(raw);
          } catch {
            return null;
          }
        },
        renderHTML: (attrs) =>
          attrs.cells != null ? { "data-cells": JSON.stringify(attrs.cells) } : {},
      },
    };
  },

  // Parse a rendered section shell back into a bpSection node (so a setContent of the
  // node-view's own DOM round-trips). We match ONLY our own data-attributed wrapper;
  // the body children are parsed from the data-section-body content hole. The title
  // rides the data-title attr, not DOM text, so parseHTML never mis-parses the title
  // chrome as a body child.
  parseHTML() {
    return [{ tag: "div[data-bp-type='section']" }];
  },

  // A schema-level fallback render (used when NO node-view is mounted — e.g. the
  // pure-Node round-trip, or a non-editable export). The node-view (below) OVERRIDES
  // this in the live editor. The `0` is the block+ content hole; chrome (HRs/title)
  // lives ONLY in the node-view (callout precedent), so parseHTML never mis-parses
  // chrome as content; title rides the data-title attr.
  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, { "data-bp-type": "section" }),
      ["div", { "data-section-body": "" }, 0],
    ];
  },

  // ── the NodeView: reader-shaped flex-column chrome around a contentDOM body ───
  //
  //   <div class="bp-canvas-section" data-bp-type="section"
  //        style="display:flex;flex-direction:column">
  //     <hr class="bp-hr" style="border-top-width:1px">       ← leading rule (chrome)
  //     <div class="bp-section__title" style="font-weight:bold"
  //          contenteditable="true">TITLE</div>               ← EDITABLE title chrome
  //     <div class="bp-section__body">…block+ children…</div>  ← contentDOM (editable)
  //     <hr class="bp-hr" style="border-top-width:1px">       ← trailing rule (chrome)
  //   </div>
  //
  // The title is contentEditable chrome OUTSIDE the PM content: it writes
  // node.attrs.title via a debounced, re-entrancy-guarded setNodeMarkup, and its
  // events/mutations are hidden from PM (stopEvent / ignoreMutation). Enter is
  // suppressed (a title is single-line). A cleared title writes null so it round-trips
  // ABSENT.
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.className = "bp-canvas-section";
      dom.setAttribute("data-bp-type", "section");
      // Match the reader's inline flex-column (route a — no reader change).
      dom.style.display = "flex";
      dom.style.flexDirection = "column";

      const hrTop = document.createElement("hr");
      hrTop.className = "bp-hr";
      hrTop.contentEditable = "false";
      hrTop.style.borderTopWidth = "1px";

      // The EDITABLE title chrome — a contentEditable island writing node.attrs.title.
      // It is NOT PM content (the code/diagram non-PM-island precedent, but editable
      // and contentEditable rather than a <textarea>).
      const titleEl = document.createElement("div");
      titleEl.className = "bp-section__title";
      titleEl.style.fontWeight = "bold";
      titleEl.setAttribute("data-test-id", "paper-section-title");

      // The editable BODY: the contentDOM hole PM fills with the block+ children.
      // In grid mode paint() swaps its class to `bp-section__grid` + sets --bp-tracks
      // (the SHARED reader class — parity by construction, no competing producer).
      const body = document.createElement("div");
      body.className = "bp-section__body";

      const hrBot = hrTop.cloneNode();

      // ── STEP-2 layout controls (hover-revealed bp-canvas-* chrome; the table/
      // terminal rail precedent). A mode toggle (stack⇄grid) + a tracks stepper,
      // writing node.attrs.layout via the SAME debounced/re-entrancy-guarded
      // setNodeMarkup the title uses. NOT PM content (stopEvent/ignoreMutation hide
      // it). No new competing HTML producer — the grid itself is the shared CSS class.
      const controls = document.createElement("div");
      controls.className = "bp-canvas-section__controls";
      controls.contentEditable = "false";

      const modeBtn = document.createElement("button");
      modeBtn.type = "button";
      modeBtn.className = "bp-canvas-section__btn";
      modeBtn.setAttribute("data-test-id", "paper-section-mode");

      const tracksDec = document.createElement("button");
      tracksDec.type = "button";
      tracksDec.className = "bp-canvas-section__btn";
      tracksDec.textContent = "−";
      tracksDec.setAttribute("data-test-id", "paper-section-tracks-dec");

      const tracksLabel = document.createElement("span");
      tracksLabel.className = "bp-canvas-section__tracks";

      const tracksInc = document.createElement("button");
      tracksInc.type = "button";
      tracksInc.className = "bp-canvas-section__btn";
      tracksInc.textContent = "+";
      tracksInc.setAttribute("data-test-id", "paper-section-tracks-inc");

      controls.append(modeBtn, tracksDec, tracksLabel, tracksInc);

      // Reader column order: HR, title, children, HR. Controls ride at the top,
      // OUTSIDE the reader order (edit-only chrome, hidden at rest via CSS).
      dom.append(controls, hrTop, titleEl, body, hrBot);

      // Guards the paint→titleEl write from re-entering the input listener.
      let syncingTitle = false;

      // STEP-6: write per-child grid-column/order onto the DIRECT grid items from the
      // bpId-keyed cells map, and mirror the reader cell's `min-width:0`. Passing
      // grid=false (the grid→stack strip) CLEARS all placement AND the min-width so
      // the flex-column child DOM is restored byte-for-byte. These are `el.style.*`
      // writes only — NO reader class literal (`bp-section__cell`) is introduced, so
      // the canvas⇄reader parity gate §3 stays green.
      //
      // PARITY (divergence c): the reader wraps each grid child in a
      // `<div class="bp-section__cell">` carrying `min-width:0` (paper-surface.css:691
      // + root.html.heex) so a wide child (a <pre>, a long word) cannot blow out its
      // `minmax(0,1fr)` track. The canvas CANNOT add that wrapper — a PM contentDOM
      // child is the block itself, and emitting the `bp-section__cell` class would be
      // a second HTML producer (§3 RED). So it mirrors the wrapper's RESOLVED geometry
      // (grid-column/order) AND its `min-width:0` onto the wrapper-less grid item.
      const applyCellPlacement = (cells, grid) => {
        const map =
          cells && typeof cells === "object" && !Array.isArray(cells) ? cells : null;
        for (const el of Array.from(body.children)) {
          if (!el || !el.style) continue;
          // Mirror `.bp-section__cell { min-width: 0 }` onto the wrapper-less grid
          // item; stack mode has no cell, so strip it (restores default min-width).
          el.style.minWidth = grid ? "0" : "";
          const id = el.getAttribute ? el.getAttribute("data-bp-id") : null;
          const cell = map && id != null ? map[id] : null;
          const span = cell ? cellSpan(cell.span) : null;
          const order = cell ? cellOrder(cell.order) : null;
          el.style.gridColumn = span != null ? `span ${span}` : "";
          el.style.order = order != null ? String(order) : "";
        }
      };

      const paint = (n) => {
        // ── FRAMED-FINALE (charter D34): show the frame in the canvas. The reader's
        // `.bp-section--framed` class rides the canvas wrapper too (root.html.heex
        // inline editor styles + styles.css carry the rule pair: hairline border,
        // direct-child .bp-hr hidden). ignoreMutation already swallows attribute
        // mutations on `dom`, so this class write never churns PM.
        dom.classList.toggle(
          "bp-section--framed",
          (n.attrs && n.attrs.variant) === "framed",
        );
        dom.classList.toggle(
          "bp-section--wide",
          (n.attrs && n.attrs.variant) === "wide",
        );
        // ── STEP-2: paint the body layout. Grid mode swaps the body to the SHARED
        // `bp-section__grid` class + sets --bp-tracks/--bp-grid-gap; stack mode keeps
        // today's `bp-section__body` flex-column (byte-unchanged DOM). PM lays the
        // block+ children into whichever the body class is.
        const layout = n.attrs && n.attrs.layout;
        const grid = isGridLayout(layout);
        if (grid) {
          const tracks = gridTracks(layout);
          body.className = "bp-section__grid";
          body.style.setProperty("--bp-tracks", String(tracks));
          body.style.setProperty("--bp-grid-gap", gapVar(layout && layout.gap));
          modeBtn.textContent = "grid";
          tracksLabel.textContent = `${tracks} col`;
          tracksLabel.style.display = "";
          tracksDec.style.display = "";
          tracksInc.style.display = "";
          // STEP-6: apply per-child grid-column/order from the bpId-keyed cells map
          // onto the DIRECT grid items (body.children). Keyed by each child's own
          // data-bp-id (the SAME key run-convert/reader use) → reorder-safe. The
          // reader emits `grid-column:span N;order:K` on its .bp-section__cell wrapper;
          // the canvas has no wrapper, so we mirror the placement onto the grid item
          // itself — parity of the resolved geometry (RISK #5).
          applyCellPlacement(n.attrs && n.attrs.cells, true);
        } else {
          body.className = "bp-section__body";
          body.style.removeProperty("--bp-tracks");
          body.style.removeProperty("--bp-grid-gap");
          modeBtn.textContent = "stack";
          // The tracks stepper is meaningless in stack mode — hide it.
          tracksLabel.style.display = "none";
          tracksDec.style.display = "none";
          tracksInc.style.display = "none";
          // STEP-6: a grid→stack flip must STRIP any per-child placement left on the
          // body children (else a stale grid-column/order survives into stack mode).
          applyCellPlacement(null, false);
        }
        // Controls are edit-only: hidden entirely in view mode.
        controls.style.display = editor.isEditable ? "" : "none";

        const title = n.attrs && n.attrs.title;
        const hasTitle = title != null && title !== "";
        // Only write when the DOM disagrees, so we never clobber the caret mid-edit.
        const shown = hasTitle ? title : "";
        if (titleEl.textContent !== shown) {
          syncingTitle = true;
          titleEl.textContent = shown;
          syncingTitle = false;
        }
        // Hide the title line when there is no title — the reader emits NO title node
        // when absent, so at rest an untitled section shows only the two rules + body.
        // While the editor is editable we still allow focusing an empty title via the
        // reveal below; at rest / view mode an empty title is hidden.
        const editable = editor.isEditable;
        titleEl.contentEditable = editable ? "true" : "false";
        titleEl.style.display = hasTitle || (editable && titleFocused) ? "" : "none";
      };

      // Reveal an empty title line on hover/focus so a section can GAIN a title in the
      // editor, while an untitled section still reads byte-identically at rest.
      let titleFocused = false;
      const onTitleFocus = () => {
        titleFocused = true;
        if (editor.isEditable) titleEl.style.display = "";
      };
      const onTitleBlur = () => {
        titleFocused = false;
        paint(currentNode());
      };
      titleEl.addEventListener("focus", onTitleFocus);
      titleEl.addEventListener("blur", onTitleBlur);

      // A single-line title: swallow Enter so it never inserts a newline / splits.
      const onTitleKeydown = (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          titleEl.blur();
        }
      };
      titleEl.addEventListener("keydown", onTitleKeydown);

      // Debounced write-back of the title to node.attrs.title. setNodeMarkup changes
      // ONLY the attrs (the node stays the same container with the same body), so
      // onUpdate → run-convert diffs it. A cleared title writes null (round-trips
      // ABSENT). Re-entrancy-guarded: never fire while paint() is the one writing.
      let writeTimer = null;
      const scheduleWrite = () => {
        if (syncingTitle) return;
        if (!editor.isEditable) return;
        if (writeTimer) clearTimeout(writeTimer);
        writeTimer = setTimeout(() => {
          writeTimer = null;
          if (typeof getPos !== "function") return;
          const pos = getPos();
          if (pos == null) return;
          const cur = editor.state.doc.nodeAt(pos);
          if (!cur || cur.type.name !== BP_SECTION_NODE_NAME) return;
          const raw = titleEl.textContent || "";
          const nextTitle = raw === "" ? null : raw;
          if ((cur.attrs.title || null) === nextTitle) return; // nothing changed
          editor
            .chain()
            .command(({ tr }) => {
              tr.setNodeMarkup(pos, undefined, { ...cur.attrs, title: nextTitle });
              return true;
            })
            .run();
        }, 250);
      };
      titleEl.addEventListener("input", scheduleWrite);

      // ── STEP-2: write node.attrs.layout via the SAME re-entrancy-guarded
      // setNodeMarkup the title uses. `mutate` receives the current layout (or a
      // stack default) and returns the next layout object (or null to clear → stack).
      const writeLayout = (mutate) => {
        if (!editor.isEditable) return;
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== BP_SECTION_NODE_NAME) return;
        const nextLayout = mutate(cur.attrs.layout || { mode: "stack" });
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, { ...cur.attrs, layout: nextLayout });
            return true;
          })
          .run();
      };

      // Mode toggle: stack ⇄ grid. Flipping TO grid seeds mode + tracks (2) so the
      // grid paints immediately; flipping TO stack writes an explicit {mode:"stack"}
      // (compose grid_layout gates on "grid" only, so this renders byte-identical to
      // absent — the callout maybe_put_true precedent).
      const onModeToggle = () => {
        writeLayout((cur) =>
          isGridLayout(cur)
            ? { ...cur, mode: "stack" }
            : { ...cur, mode: "grid", tracks: gridTracks(cur) },
        );
      };
      modeBtn.addEventListener("click", onModeToggle);

      // Tracks stepper (grid only): clamp to 1..6.
      const stepTracks = (delta) => {
        writeLayout((cur) => {
          if (!isGridLayout(cur)) return cur;
          const next = Math.min(6, Math.max(1, gridTracks(cur) + delta));
          return { ...cur, mode: "grid", tracks: next };
        });
      };
      const onTracksInc = () => stepTracks(1);
      const onTracksDec = () => stepTracks(-1);
      tracksInc.addEventListener("click", onTracksInc);
      tracksDec.addEventListener("click", onTracksDec);

      // Read the current node at getPos (for the blur repaint).
      const currentNode = () => {
        if (typeof getPos !== "function") return node;
        const pos = getPos();
        if (pos == null) return node;
        return editor.state.doc.nodeAt(pos) || node;
      };

      paint(node);

      return {
        dom,
        // PM manages the block+ children inside `body`; the chrome (HRs/title) is
        // OUTSIDE contentDOM so it is not part of the PM content.
        contentDOM: body,

        update: (updated) => {
          if (updated.type.name !== BP_SECTION_NODE_NAME) return false;
          paint(updated);
          return true;
        },

        // PM must NOT treat chrome events/mutations as content edits, but MUST own the
        // body (contentDOM). Title keystrokes write the attr, not PM content.
        stopEvent: (e) => {
          // Events originating in the editable title OR the layout controls are handled
          // by the islands (they write node.attrs.title / .layout), NOT by PM — so PM
          // must not turn them into transactions / caret jumps.
          const t = e && e.target;
          return !!(t && (titleEl.contains(t) || controls.contains(t)));
        },
        ignoreMutation: (m) => {
          if (m.type === "selection") return false; // let PM own selection
          if (m.type === "attributes" && m.target === dom) return true;
          // STEP-2: paint() rewrites the body's OWN class/style (bp-section__body ⇄
          // bp-section__grid + --bp-tracks) — that is view-only chrome, NOT a content
          // edit, so PM must ignore attribute mutations on the body element itself.
          if (m.type === "attributes" && m.target === body) return true;
          // STEP-6: applyCellPlacement writes `style` (grid-column/order) onto the
          // body's DIRECT child elements — view-only placement chrome, NOT a content
          // edit. Without this guard PM churns on every paint (the subtlest
          // correctness point). Must sit BEFORE the final body.contains fall-through,
          // which would otherwise let PM see the style mutation as a body edit.
          if (
            m.type === "attributes" &&
            m.attributeName === "style" &&
            m.target &&
            m.target.parentElement === body
          )
            return true;
          if (titleEl.contains(m.target)) return true; // title edits are attr writes
          if (controls.contains(m.target)) return true; // layout controls are attr writes
          if (hrTop.contains(m.target) || hrBot.contains(m.target)) return true;
          // Let PM handle mutations inside the editable body (contentDOM); ignore all
          // other chrome.
          return !body.contains(m.target);
        },

        destroy: () => {
          if (writeTimer) clearTimeout(writeTimer);
          titleEl.removeEventListener("focus", onTitleFocus);
          titleEl.removeEventListener("blur", onTitleBlur);
          titleEl.removeEventListener("keydown", onTitleKeydown);
          titleEl.removeEventListener("input", scheduleWrite);
          modeBtn.removeEventListener("click", onModeToggle);
          tracksInc.removeEventListener("click", onTracksInc);
          tracksDec.removeEventListener("click", onTracksDec);
        },
      };
    };
  },
});
