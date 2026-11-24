// Where motion may live on a checked page, and every change the checker makes to a page's look: one list each.
// Both go into the check's isolated worlds with installHelpers (probes.mjs), which reads them there:
//   - PLACES: the CSS reader (motionOffList) is red at any sheet that declares a transition or an animation
//     anywhere else; restyle's hold sheet holds exactly these off; the gate names a mover anywhere else.
//   - CHANGES: restyle takes only these, by name; a test holds the list to restyle's callers and prints the count.
//   - MOTION: every motion property part.css may write (build/vocabulary.mjs, read from there), each with the
//     motion reader's rule for it; a property with no rule is red by name when this module loads.
//   - ACTS: the checker's acts on a page, each made with the option that leaves the page at rest before a read.
import { MOTION_ONLY } from '../build/vocabulary.mjs'

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

/** The motion reader's rule for each kind of motion property. Every kind is declared only at PLACES. `still` is
    what the page shows at rest under reduced motion: for a transition or an animation, nothing running (the gate
    waits for it, then reads); for any other kind, that computed value on every element. */
export const MOTION_RULES = {
  transition: { still: 'nothing running' },
  animation: { still: 'nothing running' },
  'scroll-behavior': { still: 'auto' },
}
const kindOf = (p) => Object.keys(MOTION_RULES).find((k) => p === k || p.startsWith(`${k}-`))
/** Each of `props` with the reader's rule for it, and a red by name for each the reader has no rule for. */
export function motionRead(props) {
  const read = Object.fromEntries(props.filter(kindOf).map((p) => [p, MOTION_RULES[kindOf(p)]]))
  const unread = props.filter((p) => !kindOf(p)).map((p) => `the motion property ${p} (build/vocabulary.mjs MOTION) has no rule in the motion reader (check/motion.mjs MOTION_RULES)`)
  return { read, unread }
}
export const MOTION = motionRead([...MOTION_ONLY])
if (MOTION.unread.length) throw new Error(MOTION.unread.join('; '))

/** The checker's acts on a page, each made so that the page is at rest before the next read. Focus and scrolls
    are plain calls with the option that keeps them so (`holds`, read on the call's arguments). A key or the
    pointer is used only through check/acts.mjs (`through`), whose every act is followed by its rest step; the wall
    round a page the check opens (check/wall.mjs) refuses it from anywhere else. A test names each act without its
    option, at file and line. */
export const ACTS = {
  'focus moved': { call: /\.focus\(([^)]*)\)/g, holds: /preventScroll: true/ },
  'a box scrolled into view': { call: /\.scrollIntoView\(([^)]*)\)/g, holds: /behavior: 'instant'/ },
  'a box scrolled to a point': { call: /\.scroll(?:To|By)?\(([^)]*)\)/g, holds: /behavior: 'instant'/ },
  'a scroll position set': { call: /\.scroll(?:Top|Left)\s*(?:[-+]?=)(?!=)()/g, holds: /$^/ },
  'a key or the pointer used': { call: /\b(?:press|click|pointTo|pointerDown|pointerUp)\(page\b()/g, through: 'acts.mjs' },
}

/** What installHelpers is given in each world. */
export const LISTS = { places: PLACES, changes: CHANGES, motion: MOTION.read }
