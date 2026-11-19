// Contrast the tokens sheet does not deliver yet. Each wait is bound to one
// place: a skin, a scheme, a surface, and the pair of tokens a text is drawn in
// there (its fill and its ground), with the ratio the check measured for it.
//
// The lights are proved on every surface. A drawn text under 4.5:1 is let
// through only where a wait names its skin, scheme and surface and the text's
// fill and ground resolve to the wait's two tokens, and only while it measures
// no worse than `measured`. Any other text under 4.5:1, any control boundary
// under 3:1, and any label gone, cut or not drawn as itself, on any surface,
// turns the lights off. The showroom prints each wait as "waiting on the sheet"
// while it measures under `needs`; `task` is the sheet's work that ends it.
const MUTED_ON_PRIMARY = { surface: 'primary', text: '--ui-muted-foreground', ground: '--ui-background', needs: 4.5, task: 'task-6617f9ae509c43d9' }

export const SHEET_WAITS = [
  { skin: 'evergreen', scheme: 'light', measured: 3.78 },
  { skin: 'charple', scheme: 'light', measured: 3.76 },
  { skin: 'charple', scheme: 'dark', measured: 3.77 },
  { skin: 'ember', scheme: 'light', measured: 3.75 },
  { skin: 'ember', scheme: 'dark', measured: 3.77 },
  { skin: 'fjord', scheme: 'light', measured: 3.75 },
  { skin: 'iris', scheme: 'light', measured: 3.75 },
  { skin: 'iris', scheme: 'dark', measured: 3.75 },
].map((w) => ({ ...MUTED_ON_PRIMARY, ...w }))

/** The waits of one view. */
export const waitsFor = (skin, scheme, surface) => SHEET_WAITS.filter((w) => w.skin === skin && w.scheme === scheme && w.surface === surface)

/** The line the showroom prints for a wait, with what the last run measured there. */
export const waitLine = (w, now) =>
  `waiting on the sheet: ${w.text} on ${w.ground}, ${w.skin} ${w.scheme} on ${w.surface}, ${now.toFixed(2)}:1, needs ${w.needs}:1 (${w.task})`
