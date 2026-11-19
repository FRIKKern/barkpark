# @barkpark/barkui

BarkUI is one look for UI SDK's parts (`@ui-sdk/web`, pinned to `0.1.0-beta.10`). It reads only the
`--ui-*` and `--bark-*` variables of `api/priv/barkui/tokens.css`, the one source of the skins.
Private; not published.

```
parts/<name>/
  part.json     name (= folder), family, element, imports, summary, paint (selector -> variable per property),
                optional textOnly (selectors of controls that draw no boundary, such as a ghost button),
                optional allow (property -> one-line reason, for a property outside the vocabulary)
  part.css      the look over UI SDK's default: reads only --ui-* / --bark-* colours; no literal, no
                color-mix, no skin or scheme rule, no focus rule or outline; keeps to the properties in
                build/vocabulary.mjs, and to @media for the phone breakpoint and reduced motion only
  example.html  the part in each state worth seeing, in UI SDK's printed markup (works with no script);
                every id starts with "<name>-"
  press.mjs     setup(root, h) and steps: real keys or a click, then expect(root, h) -> true | reason,
                and optional ax: what a screen reader must get for an element (role, name, states)
  demo.mjs      optional: `export default function (root)`, called with this part's own root
```

Adding a part is adding a folder. The build, the check and the tests find parts by reading `parts/`;
no other file changes.

`css/base.css` holds what every part shares: the page ground and type, and the one focus ring (a 2px
gap in `--ui-background`, a 2px `--ui-ring-border` edge, the `--ui-ring` halo). Hover and pressed fills
are the sheet's (`--ui-primary-hover`, `--ui-muted-pressed`, `--bark-danger-soft-hover` and so on);
neither base.css nor a part mixes a tint of its own.

- `pnpm run build` writes `dist/showroom/index.html`, which opens from disk with no server and no network.
- `pnpm run check` builds, presses every part in headless Chromium, and writes `dist/proof.json`:
  pressed by real keys, every skin (each element takes one skin variable in every skin and scheme;
  the focus ring's edge is at least 3:1 on every Tab stop), light and dark, a 390px window read in full
  in every skin and scheme, printed and seen with no script. The page shows a light only when the last run passed and proved it for the
  same part folder, tokens, base styles, UI SDK version and check code. It exits non-zero on an
  incomplete folder, a failed step, an unlit light, any page error or network request, or a step
  (5s) or part (120s) past its time limit.
- `pnpm run check:selftest` plants one break per case in a scratch copy of a part and fails unless the
  check fails for the right reason. Breaks in paint go in through a sheet only the selftest can add
  (`runCheck({ plantCss })`); other cases prove demo.mjs cannot be that route.
- In CI (`js-tests.yml`) the fast tests and the showroom check run on every js-tests run; the selftest
  runs only when a change touches `js/packages/barkui/**` (either side of a move), `api/priv/barkui/**`,
  that workflow, `js/pnpm-lock.yaml`, `js/pnpm-workspace.yaml` or `js/package.json`, and whenever the
  changed files cannot be worked out.
- `build/sheet-waits.mjs` lists values the tokens sheet does not deliver yet. The check records each
  measure; the page prints "waiting on the sheet: ..." while it is short, and `hard: true` makes it fail.
- `pnpm test` runs the fast tests: discovery, refusals, and the part.css lint.
- `node check/shots.mjs <dir>` writes light and dark shots of the built page.

In the showroom only, `data-pin="hover"` (or `active`, `focus-visible`) holds that state for viewing,
and `data-paint-free` marks an element that carries no paint of its own. It excuses that element (never
its children) from the "takes the skin's values" comparison only. It must truly carry none: transparent
background, no border, shadow, outline or image, and its parent's text colour; otherwise the light
fails and names it. Every such element is listed in `proof.json` and counted under the part. Every other
light applies to it.

The rule: **nothing a person can see inside a part's stage goes unread, and nothing but `part.css`
and the base styles can style it.**

- Read: the check walks every element in the stage (not only `[data-slot]`) and every `::before`,
  `::after`, `::marker` and `::placeholder` that draws. Each colour it shows must be one skin variable
  in every skin and scheme: text and its fill, background colour and gradients, all four borders,
  outline, column rule, shadows (box, text, drop), decoration, emphasis, text stroke, caret, accent,
  scrollbar, SVG fill, stroke, stop, flood and lighting colours.
- Drawn in full. Every visible thing in the stage is read from pixels: each run of text, and each
  graphic (an `svg`, an `img`, a `::before` or `::after` with a box; `content: ""` is a graphic, not
  text). The check captures the stage over CDP as drawn, with every glyph unpainted, and with every
  graphic unpainted (each a first-layer `!important` sheet put there from the isolated world), once per
  skin, scheme and surface, and at 390px. A thing's ink is the pixels that differ with it toggled off,
  each weighed by how far it moved, so a colour or a fade does not change the amount. It must be at
  least 90% of the same thing drawn alone by the check, unclipped and uncovered (the same string in the
  same font, or a copy of the node); under that it fails as "label is cut: 41% of it draws". Contrast
  is the core of the ink (the strongest tenth, not the anti-aliased rim) against what is drawn there
  without it: 4.5:1 for text, 3:1 for a graphic. A run with text and no ink fails as "text does not
  draw", and a control whose text and graphics add up to nothing fails as "control has nothing to
  show". Covers, filters, blend modes, opacity anywhere above, masks, clips, overflow, transforms and
  font sizes all show in the pixels. Disabled things must draw in full but are not held to contrast.
  The computed-colour reading stays as a fast first pass; a light goes on only from the drawn one.
- A control's boundary is measured whatever token draws it. Every interactive element in the stage
  (button, input, select, textarea, summary, a link, anything with a control role or a tabindex) must
  mark where it is at 3:1 or more against the ground next to it: the best of its fill and its drawn
  edge (border, outline, inset ring), at the opacity it is drawn at. Nothing is read from part.json's
  paint entries. A stage with controls and no boundary reading fails.
- Text-only is a fact the check verifies. A control named in part.json's `textOnly` is left out of the
  boundary only if, at rest (its showroom pin let go), it draws no fill and no edge that differs from
  its ground, and it has a drawn text label. One that draws an edge or a fill is held to 3:1 like any
  other ("text-only … draws its edge at 1.01:1; drop it or meet 3:1"); one with no text fails. The
  showroom prints the controls that pass ("text-only, no boundary, label held to text rules").
- Every view part.css can target is rendered: `@media` only for reduced motion (and inside it only
  transition, animation and scroll-behavior properties) and for the one phone breakpoint named in
  `build/vocabulary.mjs`, which the phone light reads in full. `@container`, `@supports` and every
  other condition are refused.
- part.css keeps to a small vocabulary, `build/vocabulary.mjs`: layout, type, paint and motion
  properties. A font size is read from a variable set to a rem size of 0.75rem or more (the sheet has
  no type tokens yet). Anything else (filter, mix-blend-mode, clip-path, mask, text-indent, visibility,
  `-webkit-text-fill-color`, background-clip, zoom and the like) needs an entry in part.json's `allow`
  with a one-line reason, and the showroom prints it beside the part.
- Read where the page cannot reach: every reading the lights rest on (computed styles, boxes, text,
  pseudo-elements, the paint trace, contrast, focus, the phone width) runs in an isolated world over
  CDP. It shares the DOM with the page but none of its script, so a demo that patches
  `getComputedStyle`, a prototype or `querySelector` changes nothing the check reads. press.mjs runs
  in a second isolated world with its own copy of the helpers, so it cannot reach the check either.
  Keys, clicks and the screen-reader tree go through the browser's own CDP domains.
- Styled only by part.css: `example.html` is markup only (no `<style>`, `<script>`, `style=`,
  `on*=`, `<font>`, `bgcolor=` or other colour attributes, a declared shadow root, or a `<canvas>`,
  `<iframe>`, `<video>`, `<audio>`, `<object>` or `<embed>`), and `demo.mjs` wires behaviour only. Its
  lint refuses inline styles, style attributes, new
  `<style>`/`<link>`, stylesheet edits, adopted sheets, script animations and classes part.css does
  not declare, naming the line. (Patching the page's globals is not refused: the check never reads
  through them.) At run time a guard, reading from
  an isolated world the page cannot touch, compares the page with the same build run without any demo:
  after the demo has run, after every press step and at the end of each light's run, no element in a
  stage may carry a `style` attribute, the stylesheets, their rules and the adopted sheets must be the
  build's own, and no animation may run from script. A failure names what changed.

The surface switch sets `data-surface` (base, raised, sunken, primary, inverse) on each part's stage.
The lights are proved on base and say so; on any other surface they show grey, "not proved on
<surface>", never on. The check also measures drawn text and every control's boundary on the other
four surfaces and records them per surface in `proof.json`; a short one prints as a "waiting on the
sheet" line and turns no light off until its `hard` switch is set. The boundary is hard on every
surface, so a control under 3:1 anywhere turns "every skin" off. Text on the other surfaces still
waits until every surface clears it. For each surface the check also records, as numbers only, a disabled
control's fill against its ground and against the primary fill. It will prove every surface.
