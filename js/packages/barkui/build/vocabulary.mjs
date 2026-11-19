// What part.css may say. The check reads every view part.css can target and
// every pixel a part draws, so part.css keeps to properties whose effect the
// check can see and judge. A property outside this list needs an entry in the
// part's part.json, "allow": { "<property>": "<one-line reason>" }; the
// showroom prints each one beside the part.
//
// Started from what base.css and the button use, plus ordinary layout, type,
// paint and motion. Left out on purpose (each needs a reason): filter,
// backdrop-filter, mix-blend-mode, clip-path, clip, mask and its longhands,
// text-indent, visibility, -webkit-text-fill-color, -webkit-text-stroke,
// background-clip, text-shadow, zoom, contain, content-visibility, the font
// shorthand.

const LAYOUT = `display position inset top right bottom left inset-inline inset-inline-start inset-inline-end inset-block
inset-block-start inset-block-end z-index float clear box-sizing width height min-width min-height max-width max-height
inline-size block-size min-inline-size min-block-size max-inline-size max-block-size aspect-ratio
margin margin-top margin-right margin-bottom margin-left margin-inline margin-inline-start margin-inline-end margin-block
margin-block-start margin-block-end padding padding-top padding-right padding-bottom padding-left padding-inline
padding-inline-start padding-inline-end padding-block padding-block-start padding-block-end
flex flex-direction flex-wrap flex-flow flex-grow flex-shrink flex-basis order gap row-gap column-gap
align-items align-self align-content justify-content justify-items justify-self place-items place-content place-self
grid grid-template grid-template-columns grid-template-rows grid-template-areas grid-auto-flow grid-auto-columns
grid-auto-rows grid-column grid-column-start grid-column-end grid-row grid-row-start grid-row-end grid-area
vertical-align overflow overflow-x overflow-y overflow-inline overflow-block text-overflow object-fit object-position
transform transform-origin translate rotate scale list-style list-style-type list-style-position table-layout
border-collapse border-spacing`

const TYPE = `font-family font-size font-weight font-style font-stretch font-variant font-variant-numeric font-feature-settings
line-height letter-spacing word-spacing text-align text-transform text-decoration text-decoration-line
text-decoration-style text-decoration-thickness text-decoration-color text-underline-offset white-space word-break
overflow-wrap hyphens text-wrap tab-size -webkit-font-smoothing`

const PAINT = `color background background-color background-image background-size background-position background-repeat
border border-width border-style border-color border-top border-right border-bottom border-left
border-top-width border-right-width border-bottom-width border-left-width border-top-style border-right-style
border-bottom-style border-left-style border-top-color border-right-color border-bottom-color border-left-color
border-inline border-inline-start border-inline-end border-block border-block-start border-block-end
border-inline-color border-inline-start-color border-inline-end-color border-block-color border-block-start-color
border-block-end-color border-inline-width border-inline-start-width border-inline-end-width border-block-width
border-block-start-width border-block-end-width border-inline-style border-block-style
border-radius border-top-left-radius border-top-right-radius border-bottom-left-radius border-bottom-right-radius
border-start-start-radius border-start-end-radius border-end-start-radius border-end-end-radius
box-shadow opacity fill stroke stroke-width stroke-linecap stroke-linejoin accent-color caret-color
cursor pointer-events user-select appearance content quotes resize`

const MOTION = `transition transition-property transition-duration transition-timing-function transition-delay transition-behavior
animation animation-name animation-duration animation-timing-function animation-delay animation-iteration-count
animation-direction animation-fill-mode animation-play-state scroll-behavior`

const words = (s) => s.split(/\s+/).filter(Boolean)
export const VOCABULARY = new Set([...words(LAYOUT), ...words(TYPE), ...words(PAINT), ...words(MOTION)])
export const MOTION_ONLY = new Set(words(MOTION))

// The one phone breakpoint part.css may use. The phone light renders the part
// at 390px, inside it, and reads it in full.
export const PHONE = '(max-width: 600px)'

// The sheet carries no type tokens yet, so a font size is read from a --bark-*
// or --ui-* variable, and every value part.css gives that variable must be a
// rem size at or above this floor.
export const SMALLEST_TEXT_REM = 0.75
