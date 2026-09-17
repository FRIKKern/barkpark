<!-- doc-tier: agent | canonical-for: malformed-notes-item-tolerance | budget: 900tok -->
# 0009 — Malformed `notes` items across surfaces (2026-09-17)

**Status:** accepted for the TUI leg (shipped, PR #19094), 2026-09-17; the web
leg is OPEN and belongs to the studio lane (section 3).

Row: `pe-bl-notes-malformed-shapes-followup`. Worker: cli-r21-w53. Predecessor:
`tooling/grip/ledger/pe-w6-notes-grammar-freeze-dossier-2026-08-17.md`.

Filed here, not beside its predecessor in `tooling/grip/ledger/`, because that
tree is FENCED: `tooling/pds/rerun-adjudicate.test.mjs` check 1.1 asserts "zero
bytes changed under tooling/grip/" against origin/main, so a PR cannot add a
ledger row there. Measured, not assumed — the first push of this ruling red that
check with `1 file changed, 98 insertions(+)`.

## 0. The premises the row was filed on are both STALE

Re-read today (`GET /papers/<slug>/source`, production):

| block | dossier 2026-08-17 | measured 2026-09-17 |
|---|---|---|
| `heggemsnes-act` / `hga-remedies` | 5 BARE STRING items | 5 `{"text": …}` dicts |
| `epic-paper-beauty-reference-wave-2026-07-31` / `local-suite-note` | 2 INLINE-NODE LIST items | 2 `{"text": …}` dicts |

Control on the second read: the walker saw 105 blocks and found `local-suite-note`
present, so this is a measured change of shape, not a failed lookup.

**Both malformed specimens have left the live corpus.** Whether that came from a
document WRITE or from a read-path normalization added between those dates is
UNRESOLVED — it was not settled here and it matters, because a write to
`heggemsnes-act` is exactly the act criterion 3 forbids without a steward ruling.
That question is handed to the steward, not answered by this row.

Consequence for the engineering: the shapes are still RECEIVABLE (nothing in the
block grammar refuses them on ingest), so the renderers must still handle them,
and `internal/pdrender/testdata/notes_malformed_items.json` is now the only
committed record of what either shape looks like.

## 1. What each surface does with a malformed item (measured on origin/main)

| surface | bare string | inline-node list |
|---|---|---|
| BPML printer (`bpml/printer.ex` `note_item/1`) | `<note>…</note>`, escaped verbatim — lossless TOLERANCE | one typed `UnprintableError` — REFUSES |
| web reader (`portable_doc/render/components.ex` `note_item_html/1`) | empty-field `<div class="bp-note">` row — silent loss, visible artifact | same empty-field row |
| TUI (`internal/pdrender` `notesRenderer`) | dropped by `itemMaps` — silent AND invisible | dropped by `itemMaps` |

## 2. RULING (TUI half — decided and shipped here)

A READER tolerates both shapes; it does not inherit the PRINTER's refusal.

- **Bare string → `{text: …}`.** The printer already ruled this lossless and
  tolerable. Matching it is grammar-consistent, not a widening.
- **Inline-node list → `{text: inlineNodesText(item)}`.** Deliberately MORE
  tolerant than the printer. The printer refuses because it cannot round-trip
  the shape; a reader carries no round-trip obligation, and deleting prose a
  human authored is the worse of the two failures.
- **No prose at all (number, bool, nil, `[]`, `""`) → still dropped.** Tolerance
  is for content, never for chrome.

Three states, and which pairs differ after the change:

    absent     items missing / [] ........... one blank line
    malformed  string / inline-node list .... the prose renders — DIFFERS from
                                              absent and from empty (before this
                                              change all three were identical)
    empty      {label:"",lead:"",text:""} ... dropped; alone → one blank line,
                                              i.e. SAME as absent

`absent` and `empty` stay indistinguishable ON PURPOSE: an author who wrote a row
with nothing in it said nothing. It is `malformed` that must never read as
`empty`, because that is where a false "the author wrote nothing here" is
manufactured out of a shape mismatch. `TestNotesMalformedDiffersFromEmptyAndAbsent`
pins both the difference and the sameness.

## 3. Web half — NOT mine to build; recorded with costs

`web/`, `js/` and `api/lib/barkpark/portable_doc/render/components.ex` are the
studio lane's fence. Options for `note_item_html/1`, with what each costs:

1. **Mirror this ruling** — read a bare string and an inline-node list into the
   body before the `Slots.note_*_text/1` accessors. Cost: the function's
   docstring asserts BYTE-FIDELITY with the old `notes_html/1` loop ("a
   malformed non-map item emits the SAME empty-field row"); that assertion and
   any test pinned to it must be retracted in the same change. Benefit: the
   three surfaces agree, and 5 testimony remedies become visible on the web with
   NO write to the document.
2. **Leave the empty-field row.** Cost: web and TUI now disagree (the TUI shows
   the prose, the web shows an empty row), so the three-surface law is broken in
   the other direction, and a reader who sees the empty row cannot tell it from
   an authored-empty row. Cheapest in diff, most expensive in trust.
3. **Drop the row entirely on a non-map item** — match the TUI's OLD behaviour.
   Strictly worse than both: it re-manufactures the false "empty".

Recommendation: option 1. The decision is the studio lane's to take; this row
records it rather than reaching across the fence.

## 4. Criterion 3 — explicit NO-WRITE statement

**No write of any kind was issued against `heggemsnes-act`.** Every access to it
in this row was a read (`GET /papers/heggemsnes-act/source`). No steward ruling
was sought because none was needed: the remedy this row shipped is READ-SIDE, so
the terminal surfaces the testimony's prose WITHOUT canonicalizing the document.
That is the point — the read-side fix makes the round-trip PUSH that criterion 3
guards against UNNECESSARY, and nothing here authorizes one.

The one open steward question is §0's: the stored shape changed between
2026-08-17 and 2026-09-17, and whoever or whatever changed it did so outside this
row.
