import { PLACEHOLDER } from "../contract.js";
import { HeadingSource } from "../heading-source.js";

// P4 S-slash: the SAME caret-anchored "/" insert popup the per-block editor uses
// (slash-menu.js), REUSED verbatim — only the WC-side wiring differs. SLASH_ITEMS
// is the per-block menu's item list, imported INTACT (never edited): the canvas
// filters it to CANVAS_SLASH_TYPES (the insertable-into-a-run set) via an allowlist
// so the per-block menu's items stay untouched. UNLIKE the per-block editor (which,
// on a pick, wipes the origin block + dispatches `bp-slash-insert` for the SERVER's
// default_block/2 to build), the canvas inserts the default NODE DIRECTLY into the
// ProseMirror doc — so runToOps emits an insert-after carrying the reconstructed
// block and the S4a echo stamps the server id. See _maybeSlash / _chooseSlash below.
import { t } from "../i18n.js";
import { PortableLink as Link } from "../link-mark.js";
import { ListItemSource } from "../list-item-source.js";

// Internal-link marks — schema registration only, so the canvas holds existing
// wikilink/blockref/tag inline marks through a setContent->getJSON round-trip
// (identical role to ../index.js). The [[ / # autocomplete UI lands on top of
// these marks in P4: a pick inserts a wikilink/tag MARK, which runToOps emits as
// a patch-block for that block (the existing prose patch path).
import { Blockref, InlineOpaque, Tag, Valueref, Wikilink } from "../marks.js";
import { OpaqueMark } from "../opaque-mark.js";
import { ParagraphSource } from "../paragraph-source.js";
import { portableTextBoundary } from "../portable-text-boundary.js";

// editable-action: the CTA `action` block as a canvas CONTROL-ATOM node — a LEAF
// (href/label/priority) edited by native controls in a stopEvent/ignoreMutation island,
// byte-modelled on field-node.js's native branch. Its node-view renders the reader's own
// bp-button anchor byte-identically as a live preview. ONE bpType ("action"), no
// StarterKit collision. See ./action-node.js.
import { Action } from "./action-node.js";
import { BlockBoundary } from "./block-boundary.js";

// The attr-preservation extension — the make-or-break of S1 (see ./bp-attrs.js).
import { BpAttrs } from "./bp-attrs.js";

// S3.2: the callout as a canvas CONTENT node — the first non-prose block with an
// EDITABLE body to live INSIDE the canvas document (so a prose run can CONTAIN
// callouts, body and all). A node-view renders the tone-framed chrome + fold
// toggle around a contentDOM body hole. See ./callout-node.js.
import { Callout } from "./callout-node.js";
import {
  ownDomReadback, ReaderTextAlign, transactionVetoesFigureSingleton,
} from "./canvas-editor-policy.js";
import { CardKeys } from "./card-menu.js";

// STEP 4: the card WIDGET as a canvas node (bpCard) — a slots-native block whose
// body slot is an editable inline contentDOM, with title (an attr island) + tone/
// media/action (present-only attrs) as chrome. Its node-view carries the reader's
// own bp-card/__t/__d classes so the reader cascade paints it for free (the callout
// precedent). See ./card-node.js.
import { Card } from "./card-node.js";
import { CaretBeforeKeys } from "./caret-before-keys.js";
import { stripPastedImages } from "./clipboard-paste-policy.js";
import { exactClipboardSerializer, sliceWithFreshIds } from "./clipboard-slice.js";

// S3.3: the code block as a canvas ATTR-ATOM node — an atom (no PM-managed body,
// like the divider) whose code TEXT rides in the `value` attr and is edited by a
// NON-PM <textarea> island (stopEvent/ignoreMutation so PM never sees its
// keystrokes). UNLIKE the divider it carries a mutable value/lang and CAN emit a
// patch-block. The node is named `bpCode` to avoid the StarterKit inline `code`
// MARK; StarterKit's `codeBlock` NODE is disabled below so only this node owns
// <pre>. See ./code-node.js.
import { Code } from "./code-node.js";

// S10: the columns CONTAINER nodes — the FIRST canvas node whose interior is a
// nested block tree. bpColumns (grid wrapper, content "bpColumn+") > bpColumn
// (one column, content = prose+divider+bpColumnAtom, container-in-container
// FORBIDDEN) > bpColumnAtom (verbatim read-only carrier for any non-first-class
// child). bpColumns/bpColumn are DOM-free (renderHTML content holes); bpColumnAtom's
// node-view references `document` lazily. run-convert.js maps the block ⇄ nodes and
// diffs the whole `columns` array coarsely. See ./columns-node.js.
import { Column, ColumnAtom, Columns } from "./columns-node.js";
import { commentRanges } from "./comment-ranges.js";

// pdd-t20c: the PURE constraint-vocabulary veto — the calm lock veto GENERALIZED to
// cardinality (a remove dropping a required/min-N kind below its floor) + relative
// order (a move misplacing a positioned kind against its before/after relation).
// Wired into the SAME filterTransaction plugin below, reading the JSON declarations
// LIVE off the host's data-constraints (twin of data-locked-tail). DOM-free so it
// unit-tests in plain Node like locks.js.
import { parseConstraints, transactionVetoesConstraints } from "./constraints.js";

// S3.4: the diagram block as a canvas ATTR-ATOM node — MIRRORS the S3.3 code node
// (an atom whose body text rides in an attr, edited by a non-PM <textarea> island)
// with two field differences: the body is `source` (the Mermaid text, not `value`)
// and there is an extra optional `caption` (where code had `lang`). The node is
// named `bpDiagram`; UNLIKE code/divider there is NO StarterKit collision (StarterKit
// ships no `diagram` node), so NO StarterKit node is disabled for it. See
// ./diagram-node.js.
import { Diagram } from "./diagram-node.js";

// S3: the divider as a canvas ATOM node — the first non-prose block to live
// INSIDE the canvas document (so a prose run can CONTAIN dividers). A leaf with
// no edit UI; PM's atom selection + Backspace-delete come free. See ./divider-node.js.
import { Divider } from "./divider-node.js";

// S3.6: the sheet + embed blocks as canvas READ-ONLY ATOM nodes — the FIFTH (and LAST
// S3) node-view variant. Both are REFERENCES, NOT editable text: a sheet is edited in
// its own surface (its cached snapshot renders read-only); an embed transcludes at
// VIEW render (walk.ex). So in the canvas they are read-only atoms that carry the WHOLE
// block verbatim on `bpBlock` (the bpOpaque verbatim-carry, made canvas-eligible) and
// NEVER emit a value/content patch — they render a read-only chip (sheet summary /
// embed reference) with contentEditable false, are selectable so Backspace deletes the
// atom → remove-block, and DO participate in structural ops. See ./embed-node.js.
import { Embed, Fleet, Sheet } from "./embed-node.js";

// The expandable (native toggle) container: a summary island over a block+ body.
import { Expandable } from "./expandable-node.js";

// S3.5: the 7 native-control field-* blocks as a canvas CONTROL-ATOM node — the
// FOURTH node-view variant. A SINGLE `bpField` node serves all 7 native field types
// (string/slug/text/boolean/select/datetime/color), discriminated by bpType; the
// value is edited by a NATIVE control (input/textarea/checkbox/select/datetime-local
// /color) wrapped in a stopEvent/ignoreMutation island, and COERCED by field type
// exactly like the per-block BarkparkFieldBlockBridge. field-image/field-reference
// (pickers) stay run boundaries (bpOpaque). See ./field-node.js.
import { Field } from "./field-node.js";
import { Figure } from "./figure-node.js";
import { findReplace } from "./find-replace.js";

// editable-image: the `image` block as a self-painting atom with alt + url inputs.
import { Image } from "./image-node.js";
import { inlineObjects } from "./inline-object.js";

// The "data + island" atoms: equation, footnotes, contents, video.
import { Equation, Footnote, Toc, Video } from "./island-node.js";

// pdd-t2: the PURE doctrine template-lock veto predicate — wired into the editor's
// filterTransaction below so a locked mandated block (title @0 / featured @1) can
// never be deleted or moved live (the FELT half of the server backstop). Split into
// its own DOM-free module so it unit-tests in plain Node (this file can't be
// imported DOM-free — it calls customElements.define at load).
import { isLockedTitle, transactionVetoesLock } from "./locks.js";

// The notes-grid split: the singular `note` WIDGET as a canvas CONTENT node — a
// callout SUPERSET whose body is an editable inline contentDOM, with label + lead as
// non-PM <input> islands (all three fields editable, P2). Its node-view uses
// `bp-canvas-note*` chrome ONLY (the DELIBERATE non-class-share; reader parity is
// proven by compose byte-identity, not shared classes). See ./note-node.js.
import { Note } from "./note-node.js";

// The MOUNTABLE bpOpaque carry — the schema twin of run-convert.js's opaque
// projection. Needed so a bpSection body can hold a NON-canvas child (a nested
// section, or a composite/codelist/localizedText) as a read-only verbatim carry
// instead of PM lifting it out of the section. See ./opaque-node.js.
import { Opaque } from "./opaque-node.js";
import { cleanPastedHTML } from "./paste-html.js";

// Find in the paper + replace one/all: a decoration plugin driven by the host's bar.
import { remoteSelections } from "./remote-selections.js";
import { restingScaffolds } from "./resting-scaffolds.js";
import { RestingSelection } from "./resting-selection.js";

// article-chrome roles: the eyebrow / byline / ingress / pullquote blocks as PLAIN
// canvas PROSE nodes (NO node-view — chrome-free, the reader emits one styled
// element with a bp-role-* class). Each renders `["p", {class:"bp-role-*"}, 0]` so
// PM derives the contentDOM from the content hole; getJSON round-trips the styled
// element + bpId/bpType, and run-convert.js maps the block ⇄ node. See ./role-nodes.js.
import { Blockquote, Byline, Eyebrow, Ingress, Pullquote } from "./role-nodes.js";

// steps / tabs: containers of titled rows (a title input over a block+ body each).
import { Step, Steps, Tab, Tabs } from "./rows-node.js";

// The section CONTAINER node — a top-level `section` block projects to this editable
// bpSection (a nested block+ body wrapped by two rules + an editable title chrome).
// A nested (depth>=1) section stays a verbatim bpOpaque carry (V1 forbid-nesting).
// See ./section-node.js.
import { Section } from "./section-node.js";

// The stage WIDGET as a canvas node (bpStage) — the editable per-node twin of ONE
// legacy `pipeline` node. A control-atom: five scalars (kind/title/detail text +
// files/source chrome) ride node.attrs, edited by native controls. See ./stage-node.js.
import { Stage } from "./stage-node.js";

// editable table: the `table` block as FOUR hand-rolled NESTED nodes (bpTable >
// bpTableRow > bpTableHeaderCell|bpTableCell), NOT @tiptap/extension-table. Cell bodies
// are PM `inline*` holes reusing the shared inline serializer (marks round-trip); the
// bpTable node-view paints the reader <table> + add/remove row/col chrome around a
// <tbody> contentDOM. run-convert.js maps the block ⇄ node tree. NO StarterKit collision
// (StarterKit ships no table/tr/td/th node). See ./table-node.js.
import { BpTable, BpTableCell, BpTableHeaderCell, BpTableRow } from "./table-node.js";

// live-data task-list: the EDITABLE-QUERY + server-painted-ROWS atom (`bpTaskList`).
import { TaskList } from "./task-list-node.js";

// scaffy-backlog-blocks-editable-studio: the `diff` + `filetree` blocks as canvas
// ATTR-ATOM nodes — the code/diagram shape GENERALIZED to one verbatim-body attr
// plus optional scalar metadata. UNLIKE code/diagram their PREVIEW is the reader's
// OWN server-pushed HTML (bp:block-html), because no client runtime can produce
// diff/filetree markup and the parity gate forbids hand-mirroring it. Named
// `bpDiff` / `bpFiletree`; NO StarterKit collision, so no StarterKit node is
// disabled for them. See ./technical-node.js.
import { Diff, Filetree } from "./technical-node.js";

// The terminal CONTAINER nodes (bpTerminal > body children + bpTerminalAtom). A
// terminal block ⇄ a bpTerminal node: a SINGLE editable body wrapped in reader chrome
// (title bar + optional live badge + optional footer); any non-first-class body child
// rides a read-only bpTerminalAtom. bpTerminal's node-view references `document` lazily
// (imports DOM-free). No StarterKit collision. See ./terminal-node.js.
import { Terminal, TerminalAtom } from "./terminal-node.js";
import { parseVocabulary, transactionVetoesVocabulary } from "./vocabulary.js";

// A typed or pasted [[Title]] that names a known document becomes a link; see ./wikilink-input.js.
import { wikilinkInput } from "./wikilink-input.js";

// A document link's words painted live from the host's wikilinkResolve; see ./wikilink-titles.js.
import { wikilinkTitles } from "./wikilink-titles.js";
import { normalizeWordListHTML } from "./word-paste.js";
import { Editor, Extension } from "@tiptap/core";

// The highlight mark: `==text==` shorthand and Mod-Shift-h come with the extension; it persists as the
// portable-doc `highlight` wrapper (convert.js) and renders as <mark> on both surfaces.
import Highlight from "@tiptap/extension-highlight";
import Placeholder from "@tiptap/extension-placeholder";

// Subscript (Mod-,) and superscript (Mod-.): the portable-doc `sub` / `sup` wrappers.
import Subscript from "@tiptap/extension-subscript";
import Superscript from "@tiptap/extension-superscript";
import TaskItem from "@tiptap/extension-task-item";
import TiptapTaskList from "@tiptap/extension-task-list";
import Typography from "@tiptap/extension-typography";
import Underline from "@tiptap/extension-underline";

// ProseMirror selection constructors — used by the slash direct-insert to place the
// caret naturally after the swap (TextSelection INTO a prose/callout body;
// NodeSelection ONTO a divider/code/diagram/field atom). @tiptap/pm re-exports the
// PM core modules, so this is the canonical TipTap-vanilla import (no extra dep).
import { Plugin } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import StarterKit from "@tiptap/starter-kit";


function createCanvasEditor() {
  // ONE Editor over the WHOLE run. Mirrors ../index.js's Editor config; the
  // KEY differences: (1) content is runToTiptap(this._blocks) — MANY top-level
  // blocks, not blockToTiptap of one; StarterKit's doc is block+, so the
  // siblings are native and cross-block caret/selection/split/merge come free.
  // (2) BpAttrs is in the extension list so getJSON() preserves bpId/bpType.
  // pdd-t14: lexical handle for the lock-veto plugin below — `this` (the WC
  // host) is not reachable from inside Extension.create's plugin factory.
  const host = this;
  return new Editor({
    element: this._mount,
    editable: this._editable,
    extensions: [
    ListItemSource,
    HeadingSource,
    ParagraphSource,
      portableTextBoundary(this),
      // pdd-t2/t14: the doctrine template-lock veto as a REAL ProseMirror
      // plugin. `filterTransaction` is a PLUGIN-spec option — as an
      // editorProps entry it is silently ignored by the view (found live in
      // the browser polish pass: Enter in the locked title split the doc).
      // Returning false drops the whole tx: no local mutation, no op, no
      // flash — the calm no-op the doctrine demands. Content edits inside a
      // locked block pass; papers without locked blocks are untouched (D3).
      // data-locked-tail is read LIVE off the host so hook/upgrade ordering
      // can never race Editor construction.
      Extension.create({
        name: "bpLockVeto",
        addProseMirrorPlugins: () => [
          new Plugin({
            filterTransaction: (tr, state) =>
              // Programmatic applies (initial seed via the blocks setter,
              // foreign-echo setContent, ghost-slot materialization via
              // _programmaticApply) legitimately grow/replace the doc — the veto
              // guards USER edits only (found live: the plugin vetoed its own
              // initial content seed on locked-tail runs). pdd-t20c: the
              // constraint veto rides the SAME exemption + the SAME plugin,
              // reading declarations LIVE off data-constraints.
              host._programmaticApply === true ||
              (!transactionVetoesLock(
                tr,
                state,
                host.getAttribute("data-locked-tail") === "true",
              ) &&
                !transactionVetoesConstraints(
                  tr,
                  state,
                  parseConstraints(host.getAttribute("data-constraints")),
                ) &&
                !transactionVetoesFigureSingleton(tr, state, host) &&
                // Gyldendal parity E1: a FIELD canvas carries the field's declared
                // vocabulary on data-vocabulary (twin of data-constraints). A user
                // edit that would introduce an out-of-vocabulary node / heading
                // level / list kind / mark is a calm no-op; the server refuses the
                // same by name. Absent attribute → nothing vetoed (paper canvas
                // byte-unchanged).
                !transactionVetoesVocabulary(
                  tr,
                  state,
                  parseVocabulary(host.getAttribute("data-vocabulary")),
                )),
          }),
        ],
      }),
      ownDomReadback,
      StarterKit.configure({
        // Same as ../index.js: heading levels 1–6 (owner ruling 2026-10-03 #63),
        // lists, history on. The levels drive the `# `…`###### ` input rules and
        // the Mod-Alt-1..6 turn-into chords.
        heading: { levels: [1, 2, 3, 4, 5, 6] },
        // Authored quotes have a dedicated PortableDoc editor. Native nested
        // quotes lose their body on save and preempt `> [!note] ` shorthand.
        blockquote: false,
        // Disable StarterKit's built-in horizontalRule so ONLY the canvas
        // `divider` node owns the <hr> parse rule + insert command. Otherwise
        // two nodes claim <hr> (ambiguous on paste/setContent) and
        // setHorizontalRule would insert a `horizontalRule` that runToOps —
        // which only knows `divider` as a canvas atom — mis-diffs as a paragraph.
        horizontalRule: false,
        // S3.3: disable StarterKit's built-in codeBlock NODE (name:'codeBlock',
        // parses <pre> with preserveWhitespace:'full') so ONLY the canvas
        // `bpCode` node owns the <pre> parse rule. Same lesson as horizontalRule:
        // two nodes claiming <pre> is ambiguous on paste/setContent, and
        // setCodeBlock would insert a `codeBlock` runToOps — which knows `code`
        // (the bpCode node) as a canvas attr-atom — mis-diffs as unknown. NOTE we
        // do NOT disable the inline `code` MARK (extension-code, parses <code>) —
        // the canvas KEEPS it so inline-code round-trips (convert.js inline path).
        codeBlock: false,
        // tiptap 3 folded Link, Underline, ListKeymap and TrailingNode into
        // StarterKit. Link and Underline are registered below with their own
        // config; ListKeymap and TrailingNode would change list keyboard
        // behaviour and append an empty paragraph the run never authored.
        link: false,
        underline: false,
        listKeymap: false,
        trailingNode: false,
      }),
      // Link mark — same config as ../index.js so existing `link` inline nodes
      // render/edit and the format bubble's link button works.
      Link.configure({ openOnClick: false, autolink: true }),
      // Empty-block ghost text — same contract as ../index.js. includeChildren
      // :false so one placeholder shows on the focused top-level textblock only.
      Placeholder.configure({
        includeChildren: false,
        showOnlyWhenEditable: true,
        placeholder: ({ node }) => {
          // contract.js holds the English (import-free); shown translated.
          if (isLockedTitle(node)) return t(PLACEHOLDER.title);
          if (node.type.name === "heading") {
            return t("Heading %{level}", { level: (node.attrs && node.attrs.level) || 1 });
          }
          return t(PLACEHOLDER[node.type.name] || PLACEHOLDER.paragraph);
        },
      }),
      // The empty locked title reads "Title" wherever the caret is (owner ruling
      // 2026-10-03 #54). The Placeholder extension above marks only the caret's
      // node; this keeps the title's ghost text up at rest. Same `is-empty` +
      // data-placeholder pair, so the existing placeholder CSS paints it.
      Extension.create({
        name: "bpTitlePlaceholder",
        addProseMirrorPlugins: () => [
          new Plugin({
            props: {
              decorations: (state) => {
                if (!host._editable) return null;
                const decorations = [];
                state.doc.forEach((node, pos) => {
                  if (isLockedTitle(node) && node.content.size === 0) {
                    decorations.push(Decoration.node(pos, pos + node.nodeSize, {
                      class: "is-empty",
                      "data-placeholder": t(PLACEHOLDER.title),
                    }));
                  }
                });
                return decorations.length ? DecorationSet.create(state.doc, decorations) : null;
              },
            },
          }),
        ],
      }),
      // Smart typography — parity with ../index.js. A prose run holds no code
      // block, so nothing to exclude.
      Typography,
      // Underline (Mod-u) — the PortableDoc inline wire already carries an `underline`
      // wrapper (convert.js), so this only adds the mark the schema was missing.
      Underline,
      Highlight.configure({ HTMLAttributes: { class: "bp-highlight" } }),
      Subscript,
      Superscript,
      // A stored flat mark with no editor (smallcaps, annotations) — carried verbatim.
      OpaqueMark,
      ReaderTextAlign.configure({ types: ["heading", "paragraph"], alignments: ["left", "center", "right"], defaultAlignment: "left" }),
      // Checklist: the list block with task:true (convert.js listToTiptap). `[ ] ` typed at the
      // start of a paragraph wraps it; the checkbox is a native control whose toggle is an
      // ordinary transaction, so runToOps patches the item's `checked`.
      TiptapTaskList,
      TaskItem.configure({ nested: true }),
      // Internal-link marks — schema registration only (see import note). This
      // keeps existing inline wikilink/blockref/tag marks round-tripping; the
      // [[ / # autocomplete UI is OUT of S1.
      Wikilink,
      Blockref,
      Tag,
      Valueref,
      InlineOpaque,
      // Declared inline objects (blocks.inline): accessible names on the atoms,
      // Enter / double-click opens the field dialog. See ./inline-object.js.
      inlineObjects(this),
      // No keystroke at a block boundary deletes a block the author did not
      // Backspace/Delete. See ./block-boundary.js.
      BlockBoundary,
      // THE make-or-break: declares bpId/bpType on the block nodes so the run's
      // ids survive the setContent->getJSON round-trip runToOps depends on.
      BpAttrs,
      restingScaffolds(this),
      findReplace(),
      // Shared carets: the host's remote selections as decorations. See
      // ./remote-selections.js.
      remoteSelections(),
      // Comments on a span of text: the host's ranges as decorations that follow
      // edits. See ./comment-ranges.js.
      commentRanges(this),
      wikilinkTitles(this),
      wikilinkInput(this),
      // A hydrated run rests on a caret, not on an AllSelection a first keystroke would
      // replace wholesale. See ./resting-selection.js.
      RestingSelection,
      // A key acts on the caret a click just put down, not the one before it. See
      // ./caret-before-keys.js.
      CaretBeforeKeys,
      // S3: the divider atom node — a non-prose leaf living INSIDE the canvas
      // document. Registers the `divider` node type (toDOM <hr>, bpId/bpType
      // attrs) so runToTiptap's { type:"divider" } node mounts as an atom and
      // getJSON() round-trips it (instead of dropping it as an unknown node).
      Divider,
      // S3.2: the callout content node + its node-view. Registers the `callout`
      // node type (content:"inline*", tone/title/collapsible/collapsed data-*
      // attrs, a NodeView rendering tone-framed chrome around a contentDOM body)
      // so runToTiptap's { type:"callout", content:[…] } node mounts with an
      // editable body that JOINS the run, and getJSON() round-trips body+chrome.
      Callout,
      // STEP 4: the card WIDGET node + its node-view. Registers the `bpCard` node
      // type (content:"inline*" body, title/tone/media/action data-* attrs, a
      // NodeView painting the reader's bp-card chrome around a contentDOM body) so
      // runToTiptap's { type:"bpCard", content:[…] } node mounts with an editable
      // body that JOINS the run, and getJSON() round-trips body+chrome.
      Card,
      // The notes-grid split: the `note` WIDGET node + its node-view. Registers the
      // `note` node type (content:"inline*" body, label/lead data-* attrs, a NodeView
      // with two <input> islands around a contentDOM body) so runToTiptap's
      // { type:"note", content:[…] } node mounts with an editable body that JOINS the
      // run + label/lead islands, and getJSON() round-trips body+label+lead.
      Note,
      // The stage WIDGET node + its node-view. Registers the `bpStage` node (atom,
      // attrs kind/title/detail/files/source via data-*, a NodeView rendering a cell of
      // native inputs + a source toggle in a stopEvent/ignoreMutation island so PM never
      // turns a keystroke into a transaction) so runToTiptap's { type:"bpStage",
      // attrs:{…} } node mounts as an editable pipeline-node twin whose scalars round-
      // trip through getJSON() and emit a patch-block on edit. ONE bpType; NO StarterKit
      // collision. bpStage parses ONLY its own <div data-bp-type='stage'>. See
      // ./stage-node.js.
      Stage,
      // S3.3: the code attr-atom node + its node-view. Registers the `bpCode`
      // node type (atom, attrs value/lang via data-*, a NodeView rendering a
      // <pre> with a non-PM <textarea> island that uses stopEvent/ignoreMutation
      // so PM never turns code keystrokes into transactions) so runToTiptap's
      // { type:"bpCode", attrs:{value,lang?} } node mounts as an editable code
      // block whose value/lang round-trip through getJSON(). StarterKit's
      // codeBlock is disabled above so only this node owns <pre>.
      Code,
      // S3.4: the diagram attr-atom node + its node-view. Registers the `bpDiagram`
      // node type (atom, attrs source/caption via data-*, a NodeView rendering a
      // <pre> with a non-PM <textarea> island that uses stopEvent/ignoreMutation so
      // PM never turns Mermaid-source keystrokes into transactions) so runToTiptap's
      // { type:"bpDiagram", attrs:{source,caption?} } node mounts as an editable
      // diagram block whose source/caption round-trip through getJSON(). MIRRORS the
      // code node; UNLIKE code there is no StarterKit node to disable (StarterKit
      // ships no `diagram` node), and bpDiagram parses ONLY its own
      // <pre data-bp-type='diagram'> (it does NOT claim the bare <pre> the code node
      // already owns).
      Diagram,
      // scaffy-backlog-blocks-editable-studio: the diff + filetree attr-atom nodes
      // + their shared node-view. Registers the `bpDiff` / `bpFiletree` node types
      // (atoms; the verbatim body + optional metadata ride data-* attrs; a NodeView
      // pairing a SERVER-PAINTED reader preview hole with a non-PM <textarea>
      // island that uses stopEvent/ignoreMutation so PM never turns diff keystrokes
      // into transactions) so runToTiptap's { type:"bpDiff", attrs:{diff,file?,lang?} }
      // / { type:"bpFiletree", attrs:{text,legend?} } nodes mount as editable blocks
      // whose fields round-trip through getJSON(). Each parses ONLY its own
      // <div data-bp-type='diff'|'filetree'>.
      Diff,
      Filetree,
      // S3.5 + run-splitter tail: the field CONTROL-ATOM node + its node-view.
      // Registers the SINGLE `bpField` node type serving ALL 9 field-* kinds — the 7
      // NATIVE controls (field-string / field-slug / field-text / field-boolean /
      // field-select / field-datetime / field-color), edited by a NATIVE control
      // (input / textarea / checkbox / select / datetime-local / color), PLUS the 2
      // PICKER fields (field-image → bp-media-picker, field-reference →
      // bp-reference-picker), edited by the EXISTING client-side picker WC. Both
      // variants are atoms whose VALUE rides an attr and whose edit surface is wrapped
      // in a stopEvent/ignoreMutation island so PM never turns its keystrokes / toggles
      // / selections / picker-fetches into transactions. On change the value is COERCED
      // exactly like the per-block BarkparkFieldBlockBridge — native: boolean →
      // control.checked, else control.value; picker: identity on the bp-change
      // detail.value — so a canvas field edit persists IDENTICALLY to the per-block
      // path. The pickers are CLIENT-SIDE (no LiveView / pushEvent dependency), so they
      // mount inside the node-view exactly like a native control. bpField parses ONLY
      // its own <div data-bp-type='field'>. Only the nested-structure fields
      // (composite / arrayOf / codelist / localizedText / section) remain bpOpaque.
      Field,
      // editable-action: the CTA `action` CONTROL-ATOM node + its node-view. Registers
      // the `bpAction` node (atom, attrs href/label/priority via data-*, a NodeView
      // rendering a live bp-button preview + label/href/priority native controls in a
      // stopEvent/ignoreMutation island so PM never turns a keystroke/select into a
      // transaction) so runToTiptap's { type:"bpAction", attrs:{href,label,priority} }
      // node mounts as an editable CTA whose attrs round-trip through getJSON() and
      // emit a COARSE patch-block on edit. ONE bpType; NO StarterKit collision. bpAction
      // parses ONLY its own <div data-bp-type='action'>. See ./action-node.js.
      Action,
      // S3.6: the sheet + embed READ-ONLY ATOM nodes + their node-views. Registers
      // the `bpSheet` and `bpEmbed` node types (atom, NO edit surface; the WHOLE
      // block rides the bpBlock attr via data-bp-block, a NodeView rendering a
      // read-only chip — the sheet summary "Sheet · <ref> · NxM"; the embed
      // reference "↪ <target>" — with contentEditable false + stopEvent/
      // ignoreMutation so PM never turns a click into a transaction) so runToTiptap's
      // { type:"bpSheet"|"bpEmbed", attrs:{bpBlock} } node mounts as a read-only
      // reference that round-trips the block VERBATIM through getJSON() and emits ZERO
      // value/content ops. UNLIKE bpField, nothing is edited; they carry the whole
      // block, not just a value. Each parses ONLY its own <div data-bp-type='sheet'>
      // / <div data-bp-type='embed'>. After S3.6 sheet/embed no longer split a run —
      // only field-image/field-reference (pickers) remain boundaries.
      Sheet,
      Embed,
      // pdd-t8 (fleet-in-canvas): the component-fleet SERVER-PAINTED read-only
      // atom. Registers the SINGLE `bpFleet` node (atom, NO edit surface; the
      // WHOLE block rides the bpBlock attr via data-bp-block) for EVERY fleet kind
      // (tasks / task-board / roadmap / cards / pipeline / notes / status-legend /
      // form / asciicast / …, discriminated by bpType). Its node-view paints an
      // empty `.bp-paper-surface` hole keyed by data-bp-fleet-id; the Studio hook
      // (root.html.heex `bp:block-html`) injects the reader's OWN server-rendered
      // HTML into that hole (rule 3 / D8 — one producer, byte for byte), with a
      // loading chip until it arrives. Structurally identical to Sheet/Embed: emits
      // ZERO value/content ops, participates only in structural ops. bpFleet parses
      // ONLY its own <div data-bp-fleet='true'>.
      Fleet,
      // editable-figure: the SERVER-PAINTED read-only-child + editable-caption ATOM
      // (`bpFigure`). Registers the single node so runToTiptap's { type:"bpFigure",
      // attrs:{caption, bpChild} } mounts as a reader <figure> whose CHILD paint hole
      // (data-bp-fleet-id/body, reusing the shipped bp:block-html hook — ZERO hook
      // change) is filled server-side with the child's OWN reader HTML, and whose
      // <figcaption> input is the SOLE edit affordance (patch-block{caption}).
      // Structurally an atom (holds no PM children → cannot nest another canvas node
      // by construction). Parses ONLY its own <figure data-bp-type='figure'>. See
      // ./figure-node.js.
      Figure,
      Image,
      // A selected card's keys on a block-cards canvas (card-menu.js), ahead of all others.
      CardKeys,
      // live-data task-list: the EDITABLE-QUERY + server-painted-ROWS atom
      // (`bpTaskList`). Registers the single node so runToTiptap's { type:"bpTaskList",
      // attrs:{query, title, config} } mounts as a widget whose ROWS paint hole
      // (data-bp-fleet-id/body, reusing the shipped bp:block-html hook — ZERO hook
      // change) is filled server-side with the reader's OWN resolved-rows HTML
      // (query → TaskResolver.preview → apply_preview → render_block), and whose
      // query/title <input> islands are the edit affordance (patch-block{query}).
      // MOUNTS ONLY for a query-carrying task-list; a snapshot-only task-list falls
      // through to the read-only bpFleet atom (the additive discriminant). Parses
      // ONLY its own <div data-bp-tasklist='true'>. See ./task-list-node.js.
      TaskList,
      // Article-chrome ROLE prose nodes (eyebrow / byline / ingress / pullquote).
      // Registers the four node types so runToTiptap's { type:"eyebrow"|… } nodes
      // mount as styled prose (a `<p class="bp-role-*">` matching the reader) and
      // getJSON() round-trips them (an unregistered type is dropped by PM). Each
      // parses ONLY its own <p data-bp-type='<role>'> so paragraph keeps the bare
      // <p>; eyebrow/byline are plain-string surfaces (content:"text*", marks:""),
      // ingress/pullquote inline surfaces (content:"inline*"). NO node-view — no
      // chrome to paint. See ./role-nodes.js.
      Eyebrow,
      Byline,
      Ingress,
      Pullquote,
      Blockquote,
      // editable table: the four nested nodes (bpTable > bpTableRow >
      // bpTableHeaderCell|bpTableCell). Registers the container + row/cell types so
      // runToTiptap's { type:"bpTable", content:[rows…] } tree mounts with editable
      // inline cell bodies that JOIN the run, and getJSON() round-trips the grid.
      // The bpTable node-view paints the reader <table> + row/col chrome around a
      // <tbody> contentDOM; rows/cells are plain nodes (renderHTML content holes, no
      // node-view). NO StarterKit node is disabled (no table/tr/td/th collision).
      BpTable,
      BpTableRow,
      BpTableCell,
      BpTableHeaderCell,
      // S10: the columns CONTAINER nodes (bpColumns > bpColumn+ > child). Registers
      // the three node types so runToTiptap's { type:"bpColumns", content:[bpColumn…] }
      // node mounts as an editable grid whose columns hold real editable prose/divider
      // (any non-first-class child rides a read-only bpColumnAtom), and getJSON()
      // round-trips the whole nested tree. bpColumns' `--bp-cols:N` + the reader's
      // .bp-cols grid CSS (ancestor .bp-paper-surface cascade) paint the layout; NO
      // StarterKit collision. Order after the role nodes; the doc's block+ accepts
      // bpColumns (group:"block"), never a bare bpColumn/bpColumnAtom. See
      // ./columns-node.js.
      Columns,
      Column,
      ColumnAtom,
      // The section CONTAINER node + its node-view. Registers `bpSection`
      // (content: the canvas child roster MINUS bpSection PLUS bpOpaque; a NodeView
      // rendering two `bp-hr` rules + an editable bold title around a contentDOM
      // block+ body) so a top-level section block mounts as an editable container
      // whose nested children JOIN the doc and round-trip through getJSON. isolating
      // seals the boundary (Backspace/select-all stay inside); the content
      // expression FORBIDS bpSection-in-bpSection (v1 no-nested-container). See
      // ./section-node.js.
      Section,
      Expandable,
      Steps,
      Step,
      Tabs,
      Tab,
      Equation,
      Footnote,
      Toc,
      Video,
      // The mountable bpOpaque verbatim carry. Registers `bpOpaque` (atom, bpBlock
      // whole-block attr, a read-only chip) so run-convert's opaque projection —
      // a section's non-canvas child (nested section / composite / codelist / …) —
      // MOUNTS as a read-only carry inside a bpSection body instead of being lifted
      // out by PM. See ./opaque-node.js.
      Opaque,
      // The terminal CONTAINER nodes (bpTerminal > body children + bpTerminalAtom).
      // Registers the container + verbatim-carrier atom so runToTiptap's
      // { type:"bpTerminal", content:[child…] } node mounts as an editable body wrapped
      // in reader-shaped chrome (title bar / live badge / footer), and getJSON()
      // round-trips the whole nested tree. bp-term* reader classes + paper-surface.css
      // (ancestor .bp-paper-surface cascade) paint the frame; NO StarterKit collision.
      // The doc's block+ accepts bpTerminal (group:"block"), never a bare bpTerminalAtom.
      // See ./terminal-node.js.
      Terminal,
      TerminalAtom,
    ],
    content: this._rt(this._blocks),
    editorProps: {
      // The editable root is ProseMirror's role=textbox: name it, or a screen
      // reader lands in an unnamed "edit text" (axe aria-input-field-name,
      // task-3dbe834e19630e74).
      attributes: { "aria-label": t("Paper text"), "aria-multiline": "true" },
      // P4: while a `[[` / `#` / `/` popup is open it OWNS the navigation keys
      // (↑/↓/Enter/Tab/Esc) — _onKeyDown returns true so ProseMirror does not also
      // act on them (Enter must PICK the active item, NOT split the doc, while a
      // menu is open). When ALL popups are closed every keystroke falls through to
      // TipTap unchanged, so cross-block caret / split / merge are untouched.
      handleKeyDown: (_view, event) => this._onKeyDown(event),
      // ProseMirror prevents the default of every Escape. Hand a bare Escape
      // to the host instead, unless one of the canvas's menus is open to use it.
      // Mod+Enter goes to the host too, and edits nothing if the host leaves it.
      handleDOMEvents: {
        keydown: (view, event) => this._modEnterForHost(view, event) || this._escapeForHost(view, event),
        beforeinput: (_view, event) => this._swallowModEnter(event),
        drop: (view, event) => this._noteDropMoves(view, event),
      },
      handlePaste: (view, event, slice) => this._onPaste(view, event, slice),
      // The canvas's own copy carries the exact fragment, so its paste rebuilds
      // the very nodes copied instead of re-parsing their HTML. See
      // ./clipboard-slice.js.
      clipboardSerializer: exactClipboardSerializer(() => this._editor.schema),
      // Word puts list items on the clipboard as <p style="mso-list:…"> with the
      // bullet as literal text; rebuild them as real lists before parsing, or
      // they land as paragraphs starting "·   ". See ./word-paste.js.
      // Then images the schema cannot hold are left out (counted, and named in
      // a notice by _fitPastedSlice) instead of refusing the whole paste.
      transformPastedHTML: (html) => {
        const { html: clean, count } = stripPastedImages(cleanPastedHTML(normalizeWordListHTML(html)));
        this._pasteImagesLeftOut = count;
        return clean;
      },
      // A copy of a block this doc holds reads as new (clipboard-slice.js); then
      // a field canvas fits the pasted slice to its vocabulary, node by node.
      transformPasted: (slice, view) => this._fitPastedSlice(this._dropMoves ? slice : sliceWithFreshIds(view.state.schema, slice, view.state.doc)),
      // Image files dropped onto the canvas land as image nodes at the drop point
      // and upload through the host's mediaUploader (see _insertImageFiles).
      handleDrop: (view, event, _slice, moved) => this._onDrop(view, event, moved),
      // pdd-t2: the doctrine template-lock veto. Reject any transaction that
      // deletes or moves a locked mandated block (returning false from
      // filterTransaction drops the whole tx). Content edits inside a locked
      // block pass. Additive: no-op on papers without locked blocks (D3).
      // data-locked-tail (stamped by the BarkparkPaperCanvas hook when the
      // block AFTER this run in the full document is locked — e.g. the
      // featured image right after the title run) additionally vetoes any
      // run GROWTH, since a new node here would displace that locked
      // follower. Read live off the attribute so hook/upgrade ordering can
      // never race the Editor construction.
    },
    onUpdate: ({ transaction }) => {
      this._restoreUploadResults();
      this._clearFigureConstraint(transaction);
      this._scheduleEmit();
      // P4 mutual-exclusion chain (ported from ../index.js's onUpdate ~174-193):
      // callout shorthand FIRST → wikilink → tag → slash. AT MOST ONE fires per
      // mutation. The callout `> [!type]` shorthand runs first and short-circuits
      // the rest when it consumes the update (it REPLACES the paragraph with a
      // bpCallout node rather than opening a popup); its leading '>' is already
      // disjoint from '[[' / '#' / '/', but the explicit `consumed` gate makes the
      // contract code-enforced. When NOT consumed, the three popups chain by
      // priority: wikilink, then tag, then slash — whichever opens forces the
      // others shut so a stale popup never lingers (triggers disjoint by leading
      // token "[[" vs "#" vs "/", but the gate makes the single-popup invariant
      // code-enforced rather than incidental).
      // An object editor open over the canvas (the popover, or the host's): its slash
      // line stays until the answer, and an update meanwhile (the save echo stamping
      // ids) must not reopen a menu behind it.
      if (this._objectEditorOpen()) {
        this._closeWikilink();
        this._closeTag();
        this._closeEmoji();
        this._closeSlash();
        if (this._bubble) this._bubble.update();
        return;
      }
      const consumed = this._maybeBlockShorthand() || this._maybeCalloutShorthand();
      if (!consumed) {
        if (this._maybeWikilink()) {
          this._closeTag();
          this._closeEmoji();
          this._closeSlash();
        } else if (this._maybeTag()) {
          this._closeEmoji();
          this._closeSlash();
        } else if (this._maybeEmoji()) {
          this._closeSlash();
        } else {
          this._maybeSlash();
        }
      }
      if (this._bubble) this._bubble.update();
    },
    // Selection-only changes (drag-select, shift-arrow, cross-block click)
    // don't fire onUpdate — drive the format bubble from selectionUpdate too.
    // This is what makes the bubble track a MULTI-BLOCK selection.
    onSelectionUpdate: () => {
      if (this._bubble) this._bubble.update();
      this._scheduleSelectionEmit();
    },
    // Every transaction may change what a host toolbar shows (a stored mark, a
    // block turned into a heading): bp-selection-change, one per frame at most.
    onTransaction: ({ transaction }) => {
      if (this._compStart != null) this._compStart = transaction.mapping.map(this._compStart, -1);
      this._scheduleToolbarState();
      this._emitHistory(transaction);
    },
    onBlur: () => {
      const version = ++this._richFocusIntentVersion;
      queueMicrotask(() => {
        if (this._richFocusIntentVersion === version && !this._editor?.isFocused) {
          this._richFocusIntent = false;
        }
      });
      if (this._bubble) this._bubble.update();
      this._scheduleSelectionEmit();
    },
    onFocus: () => {
      this._richFocusIntentVersion += 1;
      this._richFocusIntent = true;
      if (this._bubble) this._bubble.update();
      this._scheduleSelectionEmit();
    },
  });
}


export { createCanvasEditor };
