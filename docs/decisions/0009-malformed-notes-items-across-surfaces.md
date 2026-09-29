<!-- doc-tier: agent | canonical-for: malformed-notes-item-tolerance | budget: 900tok -->
# 0009 — Malformed `notes` items across surfaces (2026-09-17)

**Status:** accepted for the TUI leg (shipped, PR #19094), 2026-09-17. The web
leg is OPEN and belongs to the studio lane (section 3). Row:
`pe-bl-notes-malformed-shapes-followup`.

A `notes` item is MALFORMED when it is not a `{label, lead, text}` map. Two such
shapes — a bare string, and an inline-node list — are RECEIVABLE, since nothing
in the block grammar refuses them on ingest, so every reader must handle them.
Both have left the live Paper corpus, leaving
`internal/pdrender/testdata/notes_malformed_items.json` the only committed record
of either shape.

## 1. What each surface does with one (measured on origin/main)

| surface | bare string | inline-node list |
|---|---|---|
| BPML printer (`bpml/printer.ex` `note_item/1`) | `<note>…</note>`, escaped verbatim — lossless TOLERANCE | one typed `UnprintableError` — REFUSES |
| web reader (`portable_doc/render/components.ex` `note_item_html/1`) | empty-field `<div class="bp-note">` row — silent loss, visible artifact | same empty-field row |
| TUI (`internal/pdrender` `notesRenderer`) | dropped by `itemMaps` — silent AND invisible | dropped by `itemMaps` |

## 2. Ruling (TUI half — decided and shipped here)

A READER tolerates both shapes; it does not inherit the PRINTER's refusal.

- **Bare string → `{text: …}`.** The printer already ruled this lossless, so
  matching it is grammar-consistent, not a widening.
- **Inline-node list → `{text: inlineNodesText(item)}`.** Deliberately MORE
  tolerant than the printer, which refuses only because it cannot round-trip the
  shape. A reader carries no round-trip obligation, and deleting prose a human
  authored is the worse failure.
- **No prose at all (number, bool, nil, `[]`, `""`) → still dropped.** Tolerance
  is for content, never for chrome.

Three states, and which pairs differ after the change:

    absent     items missing / [] ........... one blank line
    malformed  string / inline-node list .... the prose renders — DIFFERS from
                                              absent and from empty
    empty      {label:"",lead:"",text:""} ... dropped; alone → one blank line,
                                              i.e. SAME as absent

`absent` and `empty` stay indistinguishable ON PURPOSE: an author who wrote a row
with nothing in it said nothing. It is `malformed` that must never read as
`empty` — that is where a shape mismatch manufactures a false "the author wrote
nothing here". `TestNotesMalformedDiffersFromEmptyAndAbsent` pins both the
difference and the sameness.

## 3. Web half — open, and the studio lane's to take

`web/`, `js/` and the `components.ex` named above are the studio lane's fence, so
this row records the option rather than reaching across it. Recommendation:
mirror section 2 in `note_item_html/1`, reading both shapes into the body before
the `Slots.note_*_text/1` accessors. Its cost: that
function's docstring asserts BYTE-FIDELITY with the old `notes_html/1` loop ("a
malformed non-map item emits the SAME empty-field row"), so the assertion and any
test pinned to it must be retracted in the same change. Keeping the empty-field
row instead breaks the surface agreement in the other direction and still leaves
a reader unable to tell a malformed row from an authored-empty one.

The remedy shipped here is READ-SIDE: the terminal surfaces the prose WITHOUT
canonicalizing the document. It authorizes no write to any Paper.
