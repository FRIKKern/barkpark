// view-edit-parity-compare.js — the pure comparison half of the View/Edit
// computed-style parity matrix (src/__view_edit_parity_matrix.mjs).
//
// The browser half collects, per fixture, an OWNER map: visible text (or a form
// control's value) -> the computed style of the element that paints it. This
// module diffs a View owner map against an Edit owner map and sorts every
// divergence into KNOWN (listed in view-edit-parity.known.json with a reason)
// or UNEXPECTED. It has no DOM and no browser, so `npm test` can prove the
// comparison reds on a planted change (src/__view_edit_parity_compare.test.mjs)
// on a machine that has neither Chromium nor Elixir.

// Every axis that changes how a run of text is drawn. `white-space` is left
// out on purpose: ProseMirror requires pre-wrap, and the #16092 harness
// already proves the line breaks are identical.
export const AXES = [
  "fontFamily", "fontSize", "fontWeight", "lineHeight", "letterSpacing", "color",
  "fontStyle", "textTransform", "textAlign", "hyphens", "textDecorationLine",
  "backgroundColor", "listStyleType", "wordSpacing", "textIndent",
  "fontVariantNumeric", "fontFeatureSettings", "fontVariantLigatures",
  "fontKerning", "textRendering", "webkitFontSmoothing",
];

export const MISSING = "text-owner-missing-in-edit";

const clip = (text) => String(text).slice(0, 40);

// The key a known-divergence entry is matched by. Scenario is deliberately NOT
// part of it: a divergence that is accepted is accepted at every viewport and
// theme, and one that shows at only some of them is still one finding.
export const keyOf = ({ surface, fixture, text, axis }) =>
  `${surface}|${fixture}|${clip(text)}|${axis}`;

// Edit owners for one View text. An Edit surface can paint the same text more
// than once — a resting paint button AND the textarea that replaces it on
// focus — and both must match the reader, so every owner is compared.
function editOwnersFor(text, edit) {
  if (edit[text]) return edit[text];
  // ProseMirror and the reader can split a run differently (a mark boundary);
  // fall back to the longest Edit text that the View text starts with.
  const prefix = Object.keys(edit)
    .filter((k) => k.length > 8 && !k.startsWith("li::") && text.startsWith(k))
    .sort((a, b) => b.length - a.length)[0];
  return prefix ? edit[prefix] : null;
}

// view/edit: { [fixtureId]: { missing?: true, owners: { [text]: style | style[] } } }
// A View owner is one style object; an Edit owner is a list of them.
export function diffSurface({ surface, fixtures, view, edit }) {
  const differences = [];
  let compared = 0;
  for (const fixture of fixtures) {
    const v = view[fixture];
    const e = edit[fixture];
    if (!v || v.missing || !e || e.missing) {
      differences.push({ surface, fixture, text: "(block)", axis: "mounted", view: !v?.missing, edit: !e?.missing });
      continue;
    }
    for (const [text, vStyle] of Object.entries(v.owners)) {
      const owners = editOwnersFor(text, e.owners);
      if (!owners || owners.length === 0) {
        differences.push({ surface, fixture, text: clip(text), axis: MISSING, view: vStyle.tag || "li", edit: "(none)" });
        continue;
      }
      for (const eStyle of owners) {
        compared++;
        for (const axis of Object.keys(vStyle)) {
          if (axis === "tag" || axis === "role") continue;
          if (vStyle[axis] !== eStyle[axis]) {
            differences.push({
              surface, fixture, text: clip(text), axis,
              view: vStyle[axis], edit: eStyle[axis],
              viewTag: vStyle.tag, editTag: eStyle.tag, editRole: eStyle.role,
            });
          }
        }
      }
    }
  }
  return { differences, compared };
}

// Split divergences against the known ledger. `seen` accumulates the keys that
// fired, so the caller can name ledger entries no longer observed (stale): a
// fixed divergence left on the ledger would silently re-admit its regression.
export function classify(differences, known, seen = new Set()) {
  const knownKeys = new Map(known.map((entry) => [keyOf(entry), entry]));
  const out = { known: [], unexpected: [] };
  for (const diff of differences) {
    const key = keyOf(diff);
    if (knownKeys.has(key)) {
      seen.add(key);
      out.known.push(diff);
    } else out.unexpected.push(diff);
  }
  return out;
}

export function staleEntries(known, seen) {
  return known.filter((entry) => !seen.has(keyOf(entry)));
}
