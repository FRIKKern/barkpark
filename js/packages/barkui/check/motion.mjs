// Where motion may live on a checked page, and every change the checker makes to a page's look: one list each.
// Both go into the check's isolated worlds with installHelpers (probes.mjs), which reads them there:
//   - PLACES: the CSS reader (motionOffList) is red at any sheet that declares a transition or an animation
//     anywhere else; restyle's hold sheet holds exactly these off; the gate names a mover anywhere else.
//   - CHANGES: restyle takes only these, by name; a test holds the list to restyle's callers and prints the count.

/** Where a transition or an animation may be declared: an element itself, its ::before, ::after or ::backdrop. */
export const PLACES = ['', '::before', '::after', '::backdrop']

const said = (p) => (p ? `its ${p}` : 'an element itself')
/** docs/PARTS.md's sentence, made from PLACES; a test holds the doc to it. */
export const MOTION_SENTENCE = `A sheet on a checked page may declare a transition or an animation only on ${PLACES.map(said).join(', ').replace(/, ([^,]*)$/, ' or $1')}: the check reads motion there and nowhere else, so motion declared anywhere else is red by name.`

/** Every change the checker makes to a page's look, each made through restyle under this name. Focus moved and
    a box scrolled into view are the checker's acts, not changes: the motion they start is the part's own, and the
    next call waits for it (isolate, guard.mjs). */
export const CHANGES = [
  'the open boxes hidden or drawn again',
  'glyphs or graphics unpainted or painted again',
  'the caret hidden or shown again',
  "the selection's paint made neutral or shown again",
  'a pin let go for a reading at rest',
  'pins set or taken off',
  'a pin set for one snapshot and put back',
  'checkboxes and radios put back',
  'a skin and scheme set',
  'a surface set',
  'the reference page laid out',
]

/** The checker's acts on a page, made as plain calls: each is followed by a call that waits for rest first. */
export const ACTS = { 'focus moved': /\.focus\(/g, 'a box scrolled into view': /\.scrollIntoView\(/g }

/** What installHelpers is given in each world. */
export const LISTS = { places: PLACES, changes: CHANGES }
