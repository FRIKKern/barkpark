// rows-node.js — `steps` and `tabs` as canvas containers of titled rows.
//
//   steps { id, type:"steps", steps:[ { id?, title?, blocks|children:[…] }, … ] }
//   tabs  { id, type:"tabs",  tabs:[  { id?, label?, blocks|children:[…] }, … ] }
//
// Both are a LIST OF ROWS, each row a titled nested block tree (compose.ex
// steps_row_html / tab_entries; patch.ex visible_child_container resolves nested ids
// for both). One factory makes the two node pairs: a CONTAINER node (bpSteps / bpTabs,
// content: row+) and a ROW node (bpStep / bpTab, content: the section's child roster,
// so a container child rides bpOpaque — V1 forbid-nesting). The row's title/label is
// a reader-shaped title plus an <input> island (the expandable precedent:
// ProseMirror's focus handler pulls the caret out of a contentEditable island; an
// input keeps its own), the body is the contentDOM. The steps title is the resting
// surface; pointer/keyboard activation swaps it for the input without duplicating
// visible authored text. Chrome: a "×" per row and an "add" button on the container,
// both plain PM transactions.
//
// The canvas uses the reader tab strip and keeps all panels mounted and visible
// so authors can move the caret across panels. Each panel has a label editor.
// Steps use the reader's own <ol class="bp-steps"> / <li class="bp-steps__step"> /
// .bp-steps__title / .bp-steps__body markup, so the counters and rail paint by class.
//
// DOM-aware node views; the schema objects load in plain Node.

import { Node, mergeAttributes } from "@tiptap/core";
import { BP_SECTION_CONTENT } from "./section-node.js";

export const ROWS_SPECS = {
  steps: {
    bpType: "steps",
    rowsKey: "steps",
    titleKey: "title",
    containerName: "bpSteps",
    rowName: "bpStep",
    containerTag: "ol",
    rowTag: "li",
    containerClass: "bp-steps bp-canvas-rows bp-canvas-steps",
    rowClass: "bp-steps__step bp-canvas-row",
    titleClass: "bp-steps__title bp-canvas-row__title",
    bodyClass: "bp-steps__body bp-canvas-row__body",
    titlePlaceholder: "Step title",
    addLabel: "+ step",
    rowWord: "step",
  },
  tabs: {
    bpType: "tabs",
    rowsKey: "tabs",
    titleKey: "label",
    containerName: "bpTabs",
    rowName: "bpTab",
    containerTag: "div",
    rowTag: "div",
    containerClass: "bp-tabs bp-canvas-rows bp-canvas-tabs",
    rowClass: "bp-tabs__panel bp-canvas-row",
    titleClass: "bp-tabs__tab bp-tabs__tab--active bp-canvas-row__title",
    bodyClass: "bp-canvas-row__body",
    titlePlaceholder: "Tab label",
    addLabel: "+ tab",
    rowWord: "tab",
  },
};

function idAttributes(defaultType) {
  return {
    bpId: {
      default: null,
      parseHTML: (el) => el.getAttribute("data-bp-id"),
      renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
    },
    bpType: {
      default: defaultType,
      parseHTML: (el) => el.getAttribute("data-bp-type") || defaultType,
      renderHTML: (attrs) => ({ "data-bp-type": attrs.bpType || defaultType }),
    },
  };
}

function makeRow(spec) {
  return Node.create({
    name: spec.rowName,
    content: BP_SECTION_CONTENT,
    defining: true,
    isolating: true,
    selectable: true,

    addAttributes() {
      return {
        ...idAttributes(spec.rowName),
        // The row's title (steps) or label (tabs). Present-only.
        title: {
          default: null,
          parseHTML: (el) => (el.hasAttribute("data-title") ? el.getAttribute("data-title") : null),
          renderHTML: (attrs) => (attrs.title != null ? { "data-title": attrs.title } : {}),
        },
        // Which key the persisted row keeps its body under ("blocks" | "children").
        bodyKey: {
          default: "blocks",
          parseHTML: (el) => el.getAttribute("data-body-key") || "blocks",
          renderHTML: (attrs) => (attrs.bodyKey && attrs.bodyKey !== "blocks" ? { "data-body-key": attrs.bodyKey } : {}),
        },
        // Internal provenance: an authored tabs row may validly omit `id`.
        // Keep that omission through full-document reconstruction; a new row
        // has the default false value and still receives a client id.
        bpSourceIdMissing: {
          default: false,
          rendered: false,
        },
      };
    },

    parseHTML() {
      // Above StarterKit's generic `li` (list item) rule, which otherwise claims a
      // pasted step row and the steps block comes back empty; the row's children
      // live in its body element (task-d175b72aba4d5cd6).
      return [{
        tag: `${spec.rowTag}[data-bp-type='${spec.rowName}']`,
        priority: 80,
        contentElement: (dom) => dom.querySelector(":scope > [data-row-body]") || dom,
      }];
    },

    renderHTML({ HTMLAttributes }) {
      return [
        spec.rowTag,
        mergeAttributes(HTMLAttributes, { "data-bp-type": spec.rowName, class: spec.rowClass }),
        ["div", { class: spec.bodyClass, "data-row-body": "" }, 0],
      ];
    },

    addNodeView() {
      return ({ node, editor, getPos }) => {
        const dom = document.createElement(spec.rowTag);
        dom.className = spec.rowClass;
        dom.setAttribute("data-bp-type", spec.rowName);

        const head = document.createElement("div");
        head.className = "bp-canvas-row__head";
        head.setAttribute("contenteditable", "false");

        const readerTitle = spec.bpType === "steps" ? document.createElement("div") : null;
        if (readerTitle) {
          readerTitle.className = "bp-steps__title";
          readerTitle.setAttribute("contenteditable", "false");
          readerTitle.setAttribute("role", "button");
          readerTitle.setAttribute("aria-label", `Edit ${spec.rowWord} title`);
          head.classList.add("bp-canvas-row__head--semantic");
        }

        const titleEl = document.createElement("input");
        titleEl.type = "text";
        titleEl.className = readerTitle ? "bp-canvas-row__title bp-canvas-row__title-editor" : spec.titleClass;
        titleEl.placeholder = spec.titlePlaceholder;
        titleEl.spellcheck = false;
        titleEl.setAttribute("aria-label", `${spec.rowWord} title`);
        titleEl.setAttribute("data-test-id", `paper-${spec.rowWord}-title`);

        const removeBtn = document.createElement("button");
        removeBtn.type = "button";
        removeBtn.className = "bp-canvas-row__remove";
        removeBtn.textContent = "×";
        removeBtn.title = `Remove this ${spec.rowWord}`;
        removeBtn.setAttribute("aria-label", `Remove this ${spec.rowWord}`);

        head.append(titleEl, removeBtn);

        const body = document.createElement("div");
        body.className = spec.bodyClass;

        if (readerTitle) dom.append(readerTitle);
        dom.append(head, body);

        let syncing = false;
        let dirty = false;
        let editingTitle = !readerTitle;
        const showTitleEditor = () => {
          if (!readerTitle || !editor.isEditable) return;
          editingTitle = true;
          readerTitle.hidden = true;
          titleEl.hidden = false;
          head.classList.add("bp-canvas-row__head--editing");
          titleEl.focus({ preventScroll: true });
          titleEl.select();
        };
        const showReaderTitle = () => {
          if (!readerTitle) return;
          editingTitle = false;
          readerTitle.hidden = false;
          titleEl.hidden = true;
          head.classList.remove("bp-canvas-row__head--editing");
        };
        const paint = (n) => {
          const t = n.attrs && n.attrs.title;
          const shown = t != null && t !== "" ? t : "";
          if (readerTitle) {
            readerTitle.textContent = shown;
            readerTitle.tabIndex = editor.isEditable ? 0 : -1;
          }
          if (titleEl.value !== shown) {
            syncing = true;
            titleEl.value = shown;
            syncing = false;
          }
          titleEl.readOnly = !editor.isEditable;
          removeBtn.style.display = editor.isEditable ? "" : "none";
          if (readerTitle && (!editor.isEditable || !editingTitle)) showReaderTitle();
        };

        const commitWrite = () => {
          if (typeof getPos !== "function") return;
          const pos = getPos();
          if (pos == null) return;
          const cur = editor.state.doc.nodeAt(pos);
          if (!cur || cur.type.name !== spec.rowName) return;
          const raw = titleEl.value || "";
          const next = raw === "" ? null : raw;
          dirty = false;
          if ((cur.attrs.title || null) === next) return;
          editor
            .chain()
            .command(({ tr }) => {
              tr.setNodeMarkup(pos, undefined, { ...cur.attrs, title: next });
              return true;
            })
            .run();
        };
        const onInput = () => { if (!syncing && editor.isEditable) dirty = true; };
        const flushWrite = () => { if (dirty) commitWrite(); };
        const onBlur = () => {
          flushWrite();
          showReaderTitle();
        };
        const onKeydown = (e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            titleEl.blur();
          }
        };
        const onReaderTitleClick = () => showTitleEditor();
        const onReaderTitleKeydown = (e) => {
          if (e.key !== "Enter" && e.key !== " " && e.key !== "F2") return;
          e.preventDefault();
          showTitleEditor();
        };
        const onRemove = () => {
          if (!editor.isEditable || typeof getPos !== "function") return;
          const pos = getPos();
          if (pos == null) return;
          const cur = editor.state.doc.nodeAt(pos);
          if (!cur) return;
          editor
            .chain()
            .command(({ tr }) => {
              tr.delete(pos, pos + cur.nodeSize);
              return true;
            })
            .run();
        };
        titleEl.addEventListener("input", onInput);
        titleEl.addEventListener("blur", onBlur);
        titleEl.addEventListener("keydown", onKeydown);
        readerTitle?.addEventListener("click", onReaderTitleClick);
        readerTitle?.addEventListener("keydown", onReaderTitleKeydown);
        removeBtn.addEventListener("click", onRemove);
        dom.addEventListener("bp-flush-node", flushWrite);

        paint(node);

        return {
          dom,
          contentDOM: body,
          update: (updated) => {
            if (updated.type.name !== spec.rowName) return false;
            paint(updated);
            return true;
          },
          stopEvent: (e) => {
            const t = e && e.target;
            return !!(t && head.contains(t));
          },
          ignoreMutation: (m) => {
            if (m.type === "selection") return false;
            if (m.type === "attributes" && (m.target === dom || m.target === body)) return true;
            if (head.contains(m.target)) return true;
            return !body.contains(m.target);
          },
          destroy: () => {
            dom.removeEventListener("bp-flush-node", flushWrite);
            titleEl.removeEventListener("input", onInput);
            titleEl.removeEventListener("blur", onBlur);
            titleEl.removeEventListener("keydown", onKeydown);
            readerTitle?.removeEventListener("click", onReaderTitleClick);
            readerTitle?.removeEventListener("keydown", onReaderTitleKeydown);
            removeBtn.removeEventListener("click", onRemove);
          },
        };
      };
    },
  });
}

function makeContainer(spec, RowNode) {
  return Node.create({
    name: spec.containerName,
    group: "block",
    content: spec.rowName + "+",
    defining: true,
    isolating: true,
    selectable: true,

    addAttributes() {
      return idAttributes(spec.bpType);
    },

    parseHTML() {
      // Above the generic `ol`/`ul` list rules (task-d175b72aba4d5cd6).
      return [{ tag: `${spec.containerTag}[data-bp-type='${spec.bpType}']`, priority: 80 }];
    },

    renderHTML({ HTMLAttributes }) {
      return [
        spec.containerTag,
        mergeAttributes(HTMLAttributes, { "data-bp-type": spec.bpType, class: spec.containerClass }),
        0,
      ];
    },

    addNodeView() {
      return ({ node, editor, getPos }) => {
        const tabs = spec.bpType === "tabs";
        const wrap = document.createElement("div");
        wrap.className = tabs ? spec.containerClass : "bp-canvas-rows__wrap";
        wrap.setAttribute("data-bp-type", spec.bpType);

        const dom = document.createElement(spec.containerTag);
        dom.className = tabs ? "bp-tabs__panels" : spec.containerClass;
        const strip = tabs ? document.createElement("div") : null;
        if (strip) {
          strip.className = "bp-tabs__strip";
          strip.setAttribute("role", "tablist");
          strip.contentEditable = "false";
          wrap.appendChild(strip);
        }
        if (spec.bpType === "steps") {
          dom.setAttribute("data-bp-type", spec.bpType);
          dom.setAttribute("data-bp-conformance-root", "");
        }

        const foot = document.createElement("div");
        foot.className = "bp-canvas-rows__foot";
        foot.setAttribute("contenteditable", "false");
        const addBtn = document.createElement("button");
        addBtn.type = "button";
        addBtn.className = "bp-canvas-rows__add";
        addBtn.textContent = spec.addLabel;
        addBtn.setAttribute("data-test-id", `paper-${spec.rowWord}-add`);
        foot.appendChild(addBtn);

        wrap.append(dom, foot);

        const onAdd = () => {
          if (!editor.isEditable || typeof getPos !== "function") return;
          const pos = getPos();
          if (pos == null) return;
          const cur = editor.state.doc.nodeAt(pos);
          if (!cur) return;
          editor
            .chain()
            .command(({ tr, state }) => {
              const rowType = state.schema.nodes[spec.rowName];
              const paragraph = state.schema.nodes.paragraph;
              if (!rowType || !paragraph) return false;
              const fresh = rowType.create({ bpId: null, title: null, bpSourceIdMissing: false }, paragraph.create());
              tr.insert(pos + cur.nodeSize - 1, fresh);
              return true;
            })
            .run();
        };
        addBtn.addEventListener("click", onAdd);

        let activeTab = 0;
        const paint = (current) => {
          foot.style.display = editor.isEditable ? "" : "none";
          if (!strip) return;
          activeTab = Math.min(activeTab, current.childCount - 1);
          current.forEach((row, _offset, index) => {
            let button = strip.children[index];
            if (!button) {
              button = document.createElement("button");
              button.type = "button";
              button.setAttribute("role", "tab");
              button.dataset.tabIndex = String(index);
              button.addEventListener("click", () => {
                if (selectTab(index)) dom.children[index]?.querySelector("input")?.focus();
              });
              strip.appendChild(button);
            }
            const selected = index === activeTab;
            button.className = selected ? "bp-tabs__tab bp-tabs__tab--active" : "bp-tabs__tab";
            button.setAttribute("aria-selected", String(selected));
            button.tabIndex = selected ? 0 : -1;
            button.textContent = row.attrs.title || "";
          });
          while (strip.children.length > current.childCount) strip.lastElementChild.remove();
          queueMicrotask(() => {
            Array.from(dom.children).forEach((panel, index) => {
              panel.dataset.tabIndex = String(index);
            });
          });
        };
        const selectTab = (index) => {
          const pos = getPos?.();
          const current = pos == null ? null : editor.state.doc.nodeAt(pos);
          if (current?.type.name !== spec.containerName || index >= current.childCount) return false;
          activeTab = index;
          paint(current);
          return true;
        };
        const onTabKeydown = (event) => {
          const count = strip.children.length;
          const destinations = {
            ArrowLeft: (activeTab + count - 1) % count,
            ArrowRight: (activeTab + 1) % count,
            Home: 0,
            End: count - 1,
          };
          const index = destinations[event.key];
          if (!Number.isInteger(index) || !selectTab(index)) return;
          event.preventDefault();
          strip.children[index].focus();
        };
        strip?.addEventListener("keydown", onTabKeydown);
        paint(node);

        return {
          dom: wrap,
          contentDOM: dom,
          update: (updated) => {
            if (updated.type.name !== spec.containerName) return false;
            paint(updated);
            return true;
          },
          stopEvent: (e) => {
            const t = e && e.target;
            return !!(t && (foot.contains(t) || strip?.contains(t)));
          },
          ignoreMutation: (m) => {
            if (m.type === "selection") return false;
            if (m.type === "attributes" && (m.target === wrap || m.target === dom)) return true;
            if (foot.contains(m.target) || strip?.contains(m.target)) return true;
            return !dom.contains(m.target);
          },
          destroy: () => {
            addBtn.removeEventListener("click", onAdd);
            strip?.removeEventListener("keydown", onTabKeydown);
          },
        };
      };
    },
  });
}

export const Step = makeRow(ROWS_SPECS.steps);
export const Steps = makeContainer(ROWS_SPECS.steps, Step);
export const Tab = makeRow(ROWS_SPECS.tabs);
export const Tabs = makeContainer(ROWS_SPECS.tabs, Tab);

export const BP_STEPS_NODE_NAME = ROWS_SPECS.steps.containerName;
export const BP_STEP_NODE_NAME = ROWS_SPECS.steps.rowName;
export const BP_TABS_NODE_NAME = ROWS_SPECS.tabs.containerName;
export const BP_TAB_NODE_NAME = ROWS_SPECS.tabs.rowName;
