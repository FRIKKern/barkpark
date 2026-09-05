// task-list-node.js — the LIVE-DATA editable WIDGET: an EDITABLE-QUERY + server-
// painted-ROWS ATOM (`bpTaskList`).
//
// This is the LIVE-DATA sibling of figure-node.js. Where figure carries a verbatim
// read-only CHILD + an editable CAPTION, a task-list carries an editable QUERY
// (+ optional title + config) and its ROWS are a SERVER-PAINTED, resolve-at-read
// PROJECTION — never persisted onto the node. The QUERY is the authored datum
// (composition-doctrine P2: "LIVE DATA is bound through an EDITABLE QUERY, never
// baked chrome"); the rows are the reader's OWN producer, painted read-only.
//
// ── WHY AN ATOM (editable query + server-painted rows), NOT a container ────────
//
// The rows are LIVE `bp` tasks resolved through TaskResolver — they have no stable
// authored identity to edit in-canvas (editing a live-data mirror is meaningless).
// So they ride the SAME server-paint pipeline the fleet atom uses: the block's
// `query` is resolved server-side (shared/paper.ex push_block_renders →
// task_previews → apply_preview → Render.render_block), pushed on `bp:block-html`
// keyed by the block id, and injected into a `[data-bp-fleet-body]` paint hole with
// ZERO hook change. The QUERY (and title/config) is the editable surface: a non-PM
// <input> island (the figure caption pattern) that emits ONE patch-block{query} on
// edit. The server re-resolves the NEW query and REPAINTS the hole, so the rows are
// a LIVE BOUND PROJECTION of the edited query — not baked chrome.
//
// An atom holds NO PM interior, so it structurally cannot nest another canvas node
// (the v1 no-nesting rule, free) and the rows-hole innerHTML never becomes PM doc.
//
// ── THE ROWS PAINT HOLE (reuses the shipped fleet hook, ZERO hook change) ──────
//
// The node-view builds a wrapper carrying (1) the query/title edit islands and (2)
// a `[data-bp-fleet-body]` paint hole keyed by `[data-bp-fleet-id]` — the EXACT
// selector the shipped `bp:block-html` hook (root.html.heex) targets, so the server
// injects the resolved-rows reader HTML with NO hook change. The edit inputs are
// SIBLINGS of the paint hole, so the hook's innerHTML write never touches them.
//
// ── THE EDIT ISLANDS (ported from figure-node.js caption) ─────────────────────
//
// Each <input> is INVISIBLE to ProseMirror (stopEvent / ignoreMutation), so a
// keystroke never becomes a PM transaction. On `input` (debounced DEBOUNCE_MS) the
// view writes the new query/title back to the node attrs via setNodeMarkup →
// onUpdate → run-convert emits ONE patch-block{query}. Empty title → null
// (byte-fidelity, mirrors the callout title). The query control edits `query.label`;
// the rest of the query map (parent_id / labels / status) round-trips VERBATIM.
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in plain
// Node: it imports ONLY @tiptap/core (+ the pure contract.js helpers) and references
// `document` lazily inside addNodeView, which never runs in the pure-Node harness.
// So __tasklist.test.mjs imports run-convert.js (which names only the "bpTaskList"
// TYPE, never this NodeView) without a browser.

import { Node, mergeAttributes } from "@tiptap/core";
import { DEBOUNCE_MS, configControlHidden } from "../contract.js";
import { wireAtomAccessibility } from "./embed-node.js";

// The TipTap node NAME is `bpTaskList`; the portable-doc `bpType` stays "task-list"
// (run-convert.js maps a block.type "task-list" WITH a query to this node and back).
// A snapshot-only task-list (no query) is NOT this node — it falls through to the
// read-only bpFleet atom (the additive discriminant).
export const BP_TASK_LIST_NODE_NAME = "bpTaskList";

// Read the `label` off a query map (nil-safe). The v1 query control edits ONLY this
// field; every other query key (parent_id / labels / status) rides verbatim.
function queryLabel(query) {
  return query && typeof query === "object" ? query.label || "" : "";
}

// Build the NEXT query map from a prev query + an edited label. An empty label DROPS
// the `label` key (a live widget with other selectors keeps working); a query that
// EMPTIES entirely (no keys left) becomes null (the "configure me" empty state).
// Never mutates prev.
function nextQueryFromLabel(prevQuery, rawLabel) {
  const base =
    prevQuery && typeof prevQuery === "object" && !Array.isArray(prevQuery)
      ? { ...prevQuery }
      : {};
  const label = rawLabel == null ? "" : rawLabel;
  if (label === "") {
    delete base.label;
  } else {
    base.label = label;
  }
  return Object.keys(base).length ? base : null;
}

export const TaskList = Node.create({
  name: BP_TASK_LIST_NODE_NAME,

  // A top-level block sibling inside the ONE canvas document (doc content is
  // block+), so it joins the run.
  group: "block",

  // An atom leaf: NO PM interior. The rows are server-painted (read-only) and the
  // query/title are non-PM islands, so PM treats the whole node as one indivisible
  // unit (caret-select + Backspace-of-a-selected-atom come free, like the
  // fleet/figure atom). An atom holds NO PM children — structurally dodges the v1
  // no-nesting problem.
  atom: true,

  // Clickable/selectable so the caret can select the whole atom and delete it.
  selectable: true,

  // A leaf container, not a textblock — defining keeps PM from merging an adjacent
  // textblock into it on backspace-at-edge.
  defining: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by AND the paint-hole
      // selector key (data-bp-fleet-id).
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — the original portable-doc block kind ("task-list").
      bpType: {
        default: "task-list",
        parseHTML: (el) => el.getAttribute("data-bp-type") || "task-list",
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
      },
      // query — the PRIMARY editable datum (the filter that selects live tasks).
      // A JSON attr (like figure's bpChild), carried WHOLE so non-label keys
      // (parent_id/labels/status) round-trip verbatim. null when the query empties.
      query: {
        default: null,
        parseHTML: (el) => {
          const raw = el.getAttribute("data-bp-query");
          if (raw == null || raw === "") return null;
          try {
            return JSON.parse(raw);
          } catch (_) {
            return null;
          }
        },
        renderHTML: (attrs) =>
          attrs.query != null
            ? { "data-bp-query": JSON.stringify(attrs.query) }
            : {},
      },
      // title — an optional string. null when absent/empty: render data-bp-title
      // ONLY when non-null-non-"" so an empty title round-trips as ABSENT
      // (byte-fidelity, mirrors the callout title). The canonical compare treats
      // ""/null/absent EQUAL → a no-op edit emits zero ops.
      title: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-bp-title") ? el.getAttribute("data-bp-title") : null,
        renderHTML: (attrs) =>
          attrs.title != null && attrs.title !== ""
            ? { "data-bp-title": attrs.title }
            : {},
      },
      // config — optional `{limit, fields}`. Rides as a JSON attr and round-trips
      // VERBATIM in v1 (no control yet; a small select/number is a later increment).
      config: {
        default: null,
        parseHTML: (el) => {
          const raw = el.getAttribute("data-bp-config");
          if (raw == null || raw === "") return null;
          try {
            return JSON.parse(raw);
          } catch (_) {
            return null;
          }
        },
        renderHTML: (attrs) =>
          attrs.config != null
            ? { "data-bp-config": JSON.stringify(attrs.config) }
            : {},
      },
    };
  },

  // Parse ONLY our own data-attributed wrapper (a <div data-bp-tasklist='true'>).
  // No bare-tag claim, so we never contend with the bpFleet atom (which anchors on
  // data-bp-fleet) or the reader's own row markup.
  parseHTML() {
    return [{ tag: "div[data-bp-tasklist='true']" }];
  },

  // Schema-level fallback render (no node-view mounted — pure-Node round-trip /
  // non-editable export). All data rides the typed attrs; data-bp-tasklist is the
  // parse anchor. The node-view (below) OVERRIDES this in the live editor.
  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, {
        "data-bp-tasklist": "true",
        "data-bp-type": "task-list",
      }),
    ];
  },

  // ── the NodeView: an editable query/title + a server-painted rows hole ─────────
  //
  //   <div class="bp-canvas-readonly bp-canvas-tasklist" data-bp-type="task-list"
  //        data-bp-fleet-id="<bpId>" contenteditable="false">
  //     <input class="bp-canvas-tasklist-title" …/>   ← optional title island
  //     <input class="bp-canvas-tasklist-query" …/>   ← the PRIMARY edit surface
  //     <div class="bp-paper-surface" data-bp-fleet-body>   ← ROWS paint hole
  //       <div class="bp-canvas-readonly-chip">Task list</div>  ← loading chip
  //     </div>
  //   </div>
  //
  // data-bp-fleet-id / data-bp-fleet-body are reused EXACTLY so the SHIPPED
  // `bp:block-html` hook paints the resolved rows with ZERO hook change. The
  // query/title inputs are SIBLINGS of the paint hole, so the hook's innerHTML write
  // never touches them. Chrome is `bp-canvas-*` ONLY — the node-view NEVER writes a
  // reader fleet class literal, so the parity gate §3 stays green.
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const bpId = (node.attrs && node.attrs.bpId) || "";

      const dom = document.createElement("div");
      dom.className = "bp-canvas-readonly bp-canvas-tasklist";
      dom.setAttribute("data-bp-type", "task-list");
      dom.setAttribute("data-bp-fleet-id", bpId);
      dom.setAttribute("contenteditable", "false");
      dom.setAttribute("data-test-id", "paper-tasklist");

      // The TITLE island: an optional heading-styled input.
      const titleInput = document.createElement("input");
      titleInput.type = "text";
      titleInput.className = "bp-canvas-tasklist-title";
      titleInput.placeholder = "Task list title";
      titleInput.setAttribute("aria-label", "task list title");
      titleInput.setAttribute("contenteditable", "false");

      // The QUERY island: the PRIMARY editable datum (the filter label). Shown with a
      // small "filter:" affordance via placeholder; the value is the query.label.
      const queryInput = document.createElement("input");
      queryInput.type = "text";
      queryInput.className = "bp-canvas-tasklist-query";
      queryInput.placeholder = "filter (e.g. proj:x)";
      queryInput.setAttribute("aria-label", "task list query filter");
      queryInput.setAttribute("contenteditable", "false");

      dom.appendChild(titleInput);
      dom.appendChild(queryInput);

      // The ROWS paint hole: a `.bp-paper-surface` sink (the injected reader HTML is
      // styled by the ONE canonical stylesheet exactly as /papers renders it — D8),
      // keyed by data-bp-fleet-id, filled by the server hook. Until that HTML arrives
      // it shows an honest loading chip (never a blank strip).
      const body = document.createElement("div");
      body.className = "bp-paper-surface";
      body.setAttribute("data-bp-fleet-body", "");
      const chip = document.createElement("div");
      chip.className = "bp-canvas-readonly-chip";
      chip.textContent = "Task list";
      body.appendChild(chip);
      dom.appendChild(body);

      // Resting-chrome gate (ported from figure-node.js): an empty input hides at
      // rest and reveals only while the widget is hovered or focus is inside it (both
      // gated on editability — view mode surfaces nothing). A live task-list carries a
      // query.label, so its query input shows; an empty title stays hidden until
      // hover/focus.
      let hovered = false;
      let focused = false;
      const syncChrome = () => {
        const hovEd = hovered && editor.isEditable;
        const focEd = focused && editor.isEditable;
        titleInput.style.display = configControlHidden({
          value: titleInput.value,
          hovered: hovEd,
          focused: focEd,
        })
          ? "none"
          : "";
        queryInput.style.display = configControlHidden({
          value: queryInput.value,
          hovered: hovEd,
          focused: focEd,
        })
          ? "none"
          : "";
      };

      const paint = (n) => {
        const attrs = (n && n.attrs) || {};
        const title = attrs.title || "";
        const label = queryLabel(attrs.query);
        if (titleInput.value !== title) titleInput.value = title;
        if (queryInput.value !== label) queryInput.value = label;
        titleInput.readOnly = !editor.isEditable;
        queryInput.readOnly = !editor.isEditable;
        syncChrome();
      };

      const onEnter = () => {
        hovered = true;
        syncChrome();
      };
      const onLeave = () => {
        hovered = false;
        syncChrome();
      };
      const onFocusIn = () => {
        focused = true;
        syncChrome();
      };
      const onFocusOut = (e) => {
        // Focus-within guard (figure-node.js): focusout fires BEFORE the next element
        // receives focus; relatedTarget is the element gaining focus — when it is
        // still inside this atom, keep the chrome revealed.
        if (e && e.relatedTarget && dom.contains(e.relatedTarget)) return;
        focused = false;
        syncChrome();
      };
      dom.addEventListener("mouseenter", onEnter);
      dom.addEventListener("mouseleave", onLeave);
      dom.addEventListener("focusin", onFocusIn);
      dom.addEventListener("focusout", onFocusOut);

      paint(node);

      // a11y: a tab stop with a role + accessible name ("Task list") and Enter/Space →
      // NodeSelection → Backspace deletes. The e.target !== dom guard (inside
      // wireAtomAccessibility) keeps a query/title keystroke from triggering
      // atom-select.
      wireAtomAccessibility(dom, {
        block: (node.attrs && node.attrs.query) || {},
        chipText: "Task list",
        editor,
        getPos,
      });

      // Debounced write-back of the QUERY to the node attr. setNodeMarkup changes ONLY
      // the attr (the node stays the same atom in the same place), so onUpdate →
      // run-convert emits ONE patch-block{query}. The rows are NEVER touched (the
      // server repaints them on the NEW query).
      let queryTimer = null;
      const commitQueryWrite = (label = queryInput.value) => {
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur) return;
        const nextQuery = nextQueryFromLabel(cur.attrs.query, label);
        if (
          JSON.stringify(cur.attrs.query || null) === JSON.stringify(nextQuery)
        )
          return;
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, { ...cur.attrs, query: nextQuery });
            return true;
          })
          .run();
      };
      const scheduleQueryWrite = () => {
        if (!editor.isEditable) return;
        if (queryTimer) clearTimeout(queryTimer);
        queryTimer = setTimeout(() => {
          queryTimer = null;
          commitQueryWrite();
        }, DEBOUNCE_MS);
      };

      // Debounced write-back of the TITLE ("" → null so an absent title round-trips
      // as ABSENT; the canonical compare treats ""/null/absent equal → a no-op edit
      // emits nothing).
      let titleTimer = null;
      const commitTitleWrite = (raw = titleInput.value) => {
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur) return;
        const nextTitle = raw === "" ? null : raw;
        if ((cur.attrs.title || null) === nextTitle) return;
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, { ...cur.attrs, title: nextTitle });
            return true;
          })
          .run();
      };
      const scheduleTitleWrite = () => {
        if (!editor.isEditable) return;
        if (titleTimer) clearTimeout(titleTimer);
        titleTimer = setTimeout(() => {
          titleTimer = null;
          commitTitleWrite();
        }, DEBOUNCE_MS);
      };
      const flushWrites = () => {
        const flushQuery = !!queryTimer;
        const flushTitle = !!titleTimer;
        if (!flushQuery && !flushTitle) return;

        // Snapshot both fields before either transaction triggers update() → paint().
        // The repaint can restore the sibling input from attrs while it is unfocused;
        // captured values ensure both pending edits still land in this flush.
        const queryLabel = queryInput.value;
        const title = titleInput.value;
        if (flushQuery) {
          clearTimeout(queryTimer);
          queryTimer = null;
        }
        if (flushTitle) {
          clearTimeout(titleTimer);
          titleTimer = null;
        }
        if (flushQuery) commitQueryWrite(queryLabel);
        if (flushTitle) commitTitleWrite(title);
      };

      queryInput.addEventListener("input", scheduleQueryWrite);
      queryInput.addEventListener("input", syncChrome);
      titleInput.addEventListener("input", scheduleTitleWrite);
      titleInput.addEventListener("input", syncChrome);
      dom.addEventListener("bp-flush-node", flushWrites);

      return {
        dom,
        // NO contentDOM — this is an atom; the rows are server-painted and the
        // query/title live on attrs, edited entirely outside ProseMirror.

        // KEEP the existing DOM across attr updates (echo / undo): repaint the
        // inputs + chrome, never rebuild — so the server-painted rows HTML in the hole
        // is untouched (no flash back to the loading chip). Return false for a
        // different node type so PM rebuilds the view.
        update: (updated) => {
          if (updated.type.name !== BP_TASK_LIST_NODE_NAME) return false;
          paint(updated);
          return true;
        },

        // THE ISLAND CONTRACT: PM must NOT turn the inputs' OR the paint hole's events
        // into transactions (a query keystroke never splits the doc; a rows click only
        // selects the atom).
        stopEvent: () => true,
        // PM must NOT read the interior's DOM mutations into the document — the hook
        // mutates the paint hole's innerHTML directly and PM must ignore it.
        ignoreMutation: () => true,

        destroy: () => {
          if (queryTimer) clearTimeout(queryTimer);
          if (titleTimer) clearTimeout(titleTimer);
          dom.removeEventListener("bp-flush-node", flushWrites);
          queryInput.removeEventListener("input", scheduleQueryWrite);
          queryInput.removeEventListener("input", syncChrome);
          titleInput.removeEventListener("input", scheduleTitleWrite);
          titleInput.removeEventListener("input", syncChrome);
          dom.removeEventListener("mouseenter", onEnter);
          dom.removeEventListener("mouseleave", onLeave);
          dom.removeEventListener("focusin", onFocusIn);
          dom.removeEventListener("focusout", onFocusOut);
        },
      };
    };
  },
});
