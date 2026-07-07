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
  "(paragraph | heading | bulletList | orderedList | divider | callout | " +
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
      const body = document.createElement("div");
      body.className = "bp-section__body";

      const hrBot = hrTop.cloneNode();

      // Reader column order: HR, title, children, HR.
      dom.append(hrTop, titleEl, body, hrBot);

      // Guards the paint→titleEl write from re-entering the input listener.
      let syncingTitle = false;

      const paint = (n) => {
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
          // Events originating in the editable title are handled by the island (they
          // write node.attrs.title), NOT by PM — so PM must not turn them into
          // transactions / caret jumps.
          return !!(e && e.target && titleEl.contains(e.target));
        },
        ignoreMutation: (m) => {
          if (m.type === "selection") return false; // let PM own selection
          if (m.type === "attributes" && m.target === dom) return true;
          if (titleEl.contains(m.target)) return true; // title edits are attr writes
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
        },
      };
    };
  },
});
