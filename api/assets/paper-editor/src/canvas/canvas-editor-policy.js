import { isFigureSingletonCanvas } from "./figure-context.js";
import { Extension } from "@tiptap/core";

// Text alignment on paragraphs and headings: the portable-doc `align` attribute.
import TextAlign from "@tiptap/extension-text-align";
import { DOMParser as PMDOMParser } from "@tiptap/pm/model";
import { Plugin } from "@tiptap/pm/state";



// Left is the model's "no alignment" (convert.js stores only center/right; run-convert
// treats left and absent as one), so Edit paints it as NO alignment too. Stock TextAlign
// writes an inline `text-align: left` for its default on every paragraph and heading,
// overriding the inherited `start` the reader paints: a View/Edit divergence on every
// block, and the wrong edge in right-to-left text.
export const ReaderTextAlign = TextAlign.extend({
  addGlobalAttributes() {
    return this.parent().map((group) => ({
      ...group,
      attributes: {
        ...group.attributes,
        textAlign: {
          ...group.attributes.textAlign,
          renderHTML: ({ textAlign }) =>
            textAlign === "center" || textAlign === "right" ? { style: `text-align: ${textAlign}` } : {},
        },
      },
    }));
  },
});

// A Figure owns one singular child MAP, while a normal canvas owns a list. Keep
// ProseMirror from manufacturing list-shaped operations for that one special host:
// content edits may change the child, but the direct node and its authored identity
// must survive. Programmatic server echoes bypass this alongside the other vetoes.
function transactionVetoesFigureSingleton(tr, state, host) {
  if (!tr.docChanged || !isFigureSingletonCanvas(host)) return false;
  if (tr.doc.childCount !== 1) {
    host._showFigureConstraint();
    return true;
  }

  const expectedId = host._blocks[0]?.id ?? state.doc.firstChild?.attrs?.bpId;
  const after = tr.doc.firstChild;
  const replacesChild = expectedId != null && expectedId !== after.attrs?.bpId;
  if (replacesChild) host._showFigureConstraint();
  return replacesChild;
}

// ProseMirror reads the editor's OWN DOM back after native typing, and when it
// cannot localise the change inside one textblock it re-parses from the parent,
// reading each block element's inline `style` through the schema's style rules.
// The pullquote paints the reader's role italic as `style="font-style:italic"` on
// its <p>, so that re-parse turned the role styling into an Italic MARK over the
// whole quote and saved it as data (task-7f5c6a3c94ab82cc). The editor paints
// every italic mark it owns as <em>, so reading its own DOM needs no font-style
// style rule. Drop those rules from the DOM-readback parser only; pasted and
// dropped HTML keep the full schema parser (clipboardParser), where a Google Docs
// `<span style="font-style:italic">` is still italic.
const ownDomReadback = Extension.create({
  name: "bpOwnDomReadback",
  addProseMirrorPlugins() {
    const schema = this.editor.schema;
    const full = PMDOMParser.fromSchema(schema);
    const readback = new PMDOMParser(
      schema,
      full.rules.filter((rule) => !(typeof rule.style === "string" && /^font-style\b/.test(rule.style))),
    );
    return [new Plugin({ props: { domParser: readback, clipboardParser: full } })];
  },
});

export { ownDomReadback, transactionVetoesFigureSingleton };
