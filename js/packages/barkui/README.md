# @barkpark/barkui

BarkUI is one look for UI SDK's parts (`@ui-sdk/web`, pinned to `0.1.0-beta.10`). It reads only the
`--ui-*` and `--bark-*` variables of `api/priv/barkui/tokens.css`, the one source of the skins.
Private; not published.

```
parts/<name>/
  part.json     name (= folder), family, element, imports, summary; optional paint (selector -> variable
                per property: a wrong entry turns "every skin" off, and with none the trace still holds every
                colour to one skin variable); optional textOnly (selectors of controls that draw no
                boundary, such as a ghost button)
  part.css      the look over UI SDK's default: reads only --ui-* / --bark-* colours; no literal, no
                color-mix, no skin or scheme rule, no focus rule or outline; keeps to the properties in
                build/vocabulary.mjs, and to @media for the phone breakpoint and reduced motion only;
                no escape, no keyframes of its own (see "part.css is judged as the browser parses it")
  example.html  the part in each state worth seeing, in UI SDK's printed markup (works with no script);
                every id starts with "<name>-"
  press.mjs     setup(root, h) and steps: real keys or a click (the real pointer, pressed at the control's
                centre only if the control is what is on top there), then expect(root, h) -> true | reason,
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
  pressed by real keys, every skin (each element takes one skin variable in every skin and scheme, and
  everything in the stage is drawn in full, as itself, at contrast, on every surface; the focus ring's
  edge is at least 3:1 on every Tab stop), light and dark (the same, in dark), a 390px window read in
  full in every skin, scheme and surface, printed and seen with no script (see "What part.css may
  condition on" for which light crosses what). The page shows a light only when the
  last run passed and proved it for the same part folder, tokens, base styles, UI SDK version and check
  code. It exits non-zero on an incomplete folder, a failed step, an unlit light, any page error or
  network request, a step (5s) or part (120s for each part running at the same time) past its time
  limit, or more parts than CI's check step holds (see "How many parts the check holds").
- `pnpm run check:selftest` plants breaks in a scratch copy of a part and fails unless the check fails
  for the right reason, naming the planted control. One plant per reading; plants on different controls
  share a run. Breaks in paint go in through a sheet only the selftest can add
  (`runCheck({ plantCss })`); other cases prove demo.mjs cannot be that route. To keep within CI's
  limit, a case reads the four other surfaces, the reading with motion allowed, and real states against
  their pins, only when its plant is there; the check itself always reads all three.
- In CI (`js-tests.yml`) the showroom check and the selftest run only when a change touches
  `js/packages/barkui/**` (either side of a move), the sheet (`api/priv/barkui/**`), `js-tests.yml`
  itself or `js/package.json`, or changes lines of `js/pnpm-lock.yaml` that name one of BarkUI's own
  dependencies (a Playwright bump brings a new Chromium), and whenever the changed files cannot be
  worked out. The fast tests run with the rest of the js suite.
- `build/sheet-waits.mjs` lists the contrast the tokens sheet does not deliver yet, each wait bound to one
  skin, scheme, surface and pair of tokens, with the ratio measured there (see "Surfaces" below).
- `pnpm test` runs the fast tests: discovery, refusals, and the part.css lint.
- `node check/shots.mjs <dir>` writes light and dark shots of the built page.

In the showroom only, `data-pin="hover"` (or `active`, `focus-visible`) holds that state for viewing (a
pressed row pins `hover active`, as a real pointer press is both), and `data-paint-free` marks an element that carries no paint of its own. It excuses that element (never
its children) from the "takes the skin's values" comparison only. It must truly carry none: transparent
background, no border, shadow, outline or image, and its parent's text colour; otherwise the light
fails and names it. Every such element is listed in `proof.json` and counted under the part. Every other
light applies to it.

The rule: **nothing a person can see inside a part's stage, in the views listed under "What part.css
may condition on", goes unread, and nothing but `part.css` and the base styles can style it.**

- Read: the check walks every element in the stage (not only `[data-slot]`) and every `::before`,
  `::after`, `::marker` and `::placeholder` that draws. Each colour it shows must be one skin variable
  in every skin and scheme: text and its fill, background colour and gradients, all four borders,
  outline, column rule, shadows (box, text, drop), decoration, emphasis, text stroke, caret, accent,
  scrollbar, SVG fill, stroke, stop, flood and lighting colours.
- Drawn in full, as itself. Every visible thing in the stage is read from pixels: each line of text,
  and each graphic (an `svg`, an `img`, a `::before` or `::after` with a box). The check captures the
  stage as drawn, with every glyph unpainted, and with every graphic unpainted (each a first-layer
  `!important` sheet put there from the isolated world), once per skin, scheme and surface, at 1440px
  and at 390px, at a pixel ratio of 2; the browser draws text in grayscale, never LCD. For reference it draws
  each thing alone, in a blank tab of its own: the same words in the same font, or a copy of the node,
  in its own colours, on its own ground, at its own place within a pixel.
  - A label (each line a text node is laid out in) is its picture against its reference. The picture is
    every pixel in the line's box, padded by 1px, that differs from the label's ground: all that is
    painted there, by anyone. A pixel counts when it moved at least half as far as the most any pixel
    there moved (the outline at half cover), in the picture and in the reference alike, so a colour, a
    fade or a text gamma does not change it. The score is the pixels in both over the pixels in either;
    a pixel is in both when the other has ink there or one device pixel to its side (where a glyph
    lands within a pixel is rounded per glyph). Missing ink lowers it (cut, clipped, covered, shrunk,
    mirrored) and so does extra ink (a bar, a box, another word, a ghost copy). Under 0.975
    (`MATCH_MIN`, `check/reading.mjs`) it fails as "label is not drawn as itself".
  - A graphic, or the text of a pseudo-element, must draw at least 90% of its footprint drawn alone,
    or it fails as "graphic is cut: 41% of it draws" ("label is cut" for a pseudo-element's text).
  - Contrast is the core of the ink (the strongest tenth, not the anti-aliased rim) against what is
    drawn there without it: 4.5:1 for text, 3:1 for a graphic. A thing with no ink fails as "does not
    draw", and a control whose text and graphics add up to nothing fails as "control has nothing to
    show". Disabled things must draw in full but are not held to contrast. The computed-colour reading
    stays as a fast first pass; a light goes on only from the drawn one.
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
- part.css is judged as the browser parses it, not only as text. The text lint refuses any backslash
  (so no escape can spell a name one way for the lint and another for the browser), braces that do not
  balance, and any at-rule but the three `@media` conditions below. Then the check parses part.css in
  its own Chromium, wrapped in the `bark-parts` layer exactly as the build places it, and walks the
  rules that come out (`check/cssom.mjs`). It allows one `bark-parts` layer block and nothing beside
  it, and part.css must end where its rules end: a rule placed after it must come back as a rule of its
  own, so no open bracket, parenthesis, string or comment runs on into the next part on the page. Inside it, style rules, their nested declarations, and `@media` whose condition, as the browser
  writes it, is `(max-width: 600px)` (the phone breakpoint: inside it only layout and type may change),
  `(prefers-reduced-motion: reduce)` or `(prefers-reduced-motion: no-preference)`. Inside a
  reduced-motion query only transition, animation and scroll-behavior properties may change. Every
  other rule type (`@keyframes`, `@layer`, `@container`, `@supports`, `@property`, `@font-face`, and
  any the browser adds later) and every other condition refuses the run before a light is read, and so
  do `!important`, a `var()` with a fallback, and a custom property inside a reduced-motion query.
  Selectors are read as the browser writes them back: a pinned state (`:hover`, `:active`,
  `:focus-visible`, in any case) may stand only on the element the rule styles, never on a host,
  ancestor or sibling or inside another pseudo-class, where no `data-pin` reaches; other pseudo-classes
  come from a short list of structure and attributes (`check/selectors.mjs`), and pseudo-elements are the
  four the check reads. Then the check parses the page's own `barkui.css`, every part in one sheet as
  the page loads it, in the same browser, and each part's section must hold, rule by rule and with its
  states pinned, what was read from that part alone; a difference refuses the run, naming the part.
- Motion: a part defines no keyframes. It may name the shared ones in `css/base.css` (today one,
  `bark-spin`, which only turns its element; a test holds base.css to that), by name as the browser
  reads it. Transitions are free, because both ends are states the lights read anyway. Where motion is
  read: "What part.css may condition on".
- part.css keeps to a small vocabulary, `build/vocabulary.mjs`: layout, type, paint and motion
  properties, held both as written and as the browser expands them (each longhand a shorthand sets
  must belong to a property in the vocabulary, or be left at its initial value). A longhand the
  vocabulary leaves out but a shorthand in it can set (`LEFT_OUT_INITIAL`: background-clip,
  text-decoration-thickness, the border-image longhands, animation-timeline and its range) is read again
  as computed on every element in the stage and its `::before` and `::after`, in every skin, scheme and
  surface, so a value that arrives through a `var()` is held to its initial value too. A font size is read from a variable set to a rem size of 0.75rem or more (the sheet has
  no type tokens yet). A part cannot excuse itself: anything else (mix-blend-mode, clip-path, mask,
  text-indent, visibility, `-webkit-text-fill-color`, background-clip, text-shadow,
  text-decoration-thickness, zoom and the like) is refused. The one way past is `EXTRA` in that shared
  file, a property with the exact values it may take, today one row: `filter` may be `none`. A row comes
  with a selftest plant showing the lights still see the property misused. `content` may only be `""`
  or `none`, so words live in `example.html`, and the `text-decoration` shorthand may not set a
  thickness.
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

## Surfaces

The surface switch sets `data-surface` (base, raised, sunken, primary, inverse) on each part's stage.
The check reads every surface in every skin and scheme, at 1440px and at 390px, and the lights are
proved on all five; the page says so. A drawn text under 4.5:1 is let through only by a wait in `build/sheet-waits.mjs` that
names its skin, scheme and surface, whose two tokens its fill and ground resolve to, and only while it
measures no worse than the wait records. Any other text under 4.5:1, any control boundary under 3:1, and
any label gone, cut or not drawn as itself, on any surface, turns "every skin" (light views), "light
and dark" (dark views) or "phone" (390px) off. Each wait prints as "waiting on the sheet" with what the last run measured,
and the sheet's work that ends it. Today eight wait, all `--ui-muted-foreground` on `--ui-background` on
primary (the demo labels), at 3.75 to 3.78:1. For each surface the check also records, as numbers only,
a disabled control's fill against its ground and against the primary fill.

## What part.css may condition on

These are the only things a part's look can depend on in the showroom, and where each is read. A
condition not listed here (another `@media`, `@container`, `@supports`, a skin or scheme selector) is
refused on the sheet as the browser parses it (`check/cssom.mjs`) before any light is read.

| Axis | Values read | How part.css reaches it | Read with |
|---|---|---|---|
| Skin | all 5 | only through `--ui-*` / `--bark-*` values; a skin selector is refused | every scheme, surface and width: "every skin" and "light and dark" at 1440px, "phone" at 390px |
| Scheme | light, dark | only through those values; `prefers-color-scheme` and a scheme selector are refused | the same |
| Surface | base, raised, sunken, primary, inverse | those values, and `[data-surface]` selectors | every skin and scheme, at 1440px and at 390px |
| Width | 1440px, 390px | `@media (max-width: 600px)`, inside which only layout and type may change: no paint, no decoration, no custom property | 390px with every skin, scheme and surface ("phone") |
| Motion | reduced, allowed | `@media (prefers-reduced-motion: …)`, inside which only transition, animation and scroll-behavior may change; animation names from the shared keyframes, which only turn their element | every light reads with motion reduced; the drawn readings run again with motion allowed in one skin, light, on every surface at 1440px and on base at 390px, animations held finished and halfway |
| State | as `example.html` shows it | selectors on the part's own markup (`[data-disabled]` and the like); `:hover`, `:active` only on the element a rule styles | each pinned row (`data-pin`) is read with every skin, scheme, surface and width. Each real state (the pointer at a live control's centre, held down there, or Tab to it) is compared with its pin, on the live control of the same kind, in one skin, light, on base at 1440px: every computed property of the control and its `::before` and `::after` must change as the pin changes it, nothing up to the stage may change, and the stage is read as drawn ("every skin"); the pin carries it across skins, schemes, surfaces and widths. "Pressed by real keys" steps the live states |
| Script | on, off | not at all (`@media (scripting)` is refused) | "printed with no script" reads the page as it opens with no script: base surface, 1440px |

What this leaves unread, said plainly. Widths between 390px and 1440px are not rendered; paint cannot
differ there, layout can. A moment partway through a transition is not read: both its ends are. A
state `example.html` never shows is not read, and a real state is compared with its pin in that one view. The motion pass reads one skin in light on purpose:
part.css cannot tell skins or schemes apart, and with motion allowed it can change only timing and,
through the shared keyframes, turn an element, so what motion changes is the same in every skin. The
focus ring's edge is measured on every Tab stop on the base surface at 1440px, in every skin and scheme.

## How many parts the check holds

The check runs 3 parts at a time; on Linux with 4 CPUs the first 3 take about 100 s and each further 3
about 145 s more, so the 15-minute check step in CI holds 12 parts with at least 40% of its time to
spare. That is about 48 s for each part past the first three. Past that number the check refuses to run,
naming this sentence, before any light is read; raise `STEP_MINUTES` in `check/capacity.mjs` and the
step's limit in `js-tests.yml` together (a test holds them equal), or split the check, and measure
again. The selftest copies one part, so its time does not grow with the parts folder.

## What the check proves about a label, and no more

Every label in the showroom, as built, matches its reference at 0.995 or more on macOS and on Linux, on
every surface, at 1440px and at 390px (the check prints the lowest on every run; in the last runs it was
1.000 on macOS and 0.995 on Linux, the "Sizes" heading at 390px). A label must match at 0.975 or more. What that limit costs is measured by the
selftest's ladder, which cuts and covers one label step by step, and the selftest fails until this
sentence moves with it: a ten-letter label 74 px wide (in CI, on Linux; 70 px on macOS) turns the
lights off when its last 3 px are cut away, when a 5 px square of its ground covers its end, or when a
4 px square of its ink is laid over its end; 2 px, 4 px and 3 px leave them on. A smaller loss or gain
than that, and a way of hiding a label that leaves its pixels as they are, is outside this claim.
