<!-- doc-tier: human | canonical-for: barkui-parts | budget: 7500tok -->
# The part folder and the check

BarkUI is one look for UI SDK's parts (`@ui-sdk/web`, pinned to `0.1.0-beta.10`). It reads only the
`--ui-*` and `--bark-*` variables of `api/priv/barkui/tokens.css`, the one source of the skins.
Private; not published.

```
parts/<name>/
  part.json     name (= folder), family, element, imports, summary; optional paint (selector -> variable
                per property: a wrong entry turns "every skin" off, and with none the trace still holds every
                colour to one skin variable); optional textOnly (selectors of controls that draw no
                boundary, such as a ghost button); optional layers (each box the part opens in the top
                layer, with the real input that opens and closes it: see "The top layer"); optional
                notCovered ({ name, why } for each thing of its element the part does not style or prove,
                printed under the part; a summary or part.css note that says something is not covered
                must name a row of it: the build reads exactly the words in NOT_COVERED_WORDS
                (build/parts.mjs), in any case and across line breaks, in the summary and part.css's
                comments; a row names a sentence where its name stands in it as whole words, in any
                case and across line breaks; null, another shape, an empty name or reason, and a name
                given twice in any case are refused. Two limits: a sentence that says it in other words
                is not caught, and the row reads that the name stands in the sentence, not that the
                sentence is about that thing; the list is printed under the part, so a reader sees it)
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

Adding a part is adding a folder, up to 40 parts (`MOST_PARTS` in `check/jobs.mjs`). The build, the
check and the tests find parts by reading `parts/`, and no script writes a tracked file when one lands.
By hand, outside its folder, a part adds only a changeset (`js/.changeset/`, which every change to a
package carries). Once a job holding it has been timed on CI's hosted runner, that reading may go into
`check/capacity.mjs` and `node check/capacity.mjs` rewrites the passage on capacity below; no test asks
for it. Past that, the line after that passage says what else changes.

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
  limit, or more parts than one CI job holds (see "How many parts the check holds"). `node check/run.mjs
  --group k --parts …` is one CI job: it checks only that group's parts, on the page built from all of them.
- `pnpm run check:selftest` plants breaks in a scratch copy of a part and fails unless the check fails
  for the right reason, naming the planted control. One plant per reading; plants on different controls
  share a run. Breaks in paint go in through a sheet only the selftest can add
  (`runCheck({ plantCss })`); other cases prove demo.mjs cannot be that route. To keep within CI's
  limit, a case reads the four other surfaces, the reading with motion allowed, and real states against
  their pins, only when its plant is there; the check itself always reads all three.
- In CI (`.github/workflows/barkui.yml`, which runs on every change) the showroom check and the
  selftest run only when a change touches `js/packages/barkui/**` (either side of a move), the sheet
  (`api/priv/barkui/**`), `barkui.yml` itself or `js/package.json`, or changes lines of
  `js/pnpm-lock.yaml` that name one of BarkUI's own dependencies (a Playwright bump brings a new
  Chromium), and whenever the changed files cannot be worked out. The check runs as one job per group
  of parts, the selftest as six jobs of its own ("BarkUI selftest, views" runs `--job views`,
  "BarkUI selftest, surfaces" runs `--job surfaces`,
  "BarkUI selftest, presses, states and refusals" runs `--job rest`, "BarkUI selftest, top layer
  and direct readings" runs `--job layers`, "BarkUI selftest, states with their own sheet or part"
  runs `--job states`, and "BarkUI selftest, named boxes read open" runs `--job open`), and one
  closing check reads them all (see "How many parts the check holds"). A top-layer case (`layers` in
  `check/layer-cases.mjs`) presses or hovers to open its boxes or holds a refusal, so the one rule in
  `check/jobs.mjs` runs it in the layers job, with the direct readings that read no views, or, when it
  brings a sheet of its own to read named boxes open, in the open job. Each selftest job reports, by
  name, every case it ran and every case that held, and the closing check is red, naming the case,
  unless the jobs together ran every case of the list once and each held (`check/selftest-report.mjs`). On any other
  change only the plan and the closing check run. The fast tests run with
  the rest of the js suite (`js-tests.yml`).
- `build/sheet-waits.mjs` lists the contrast the tokens sheet does not deliver yet, each wait bound to one
  skin, scheme, surface and pair of tokens, with the ratio measured there (see "Surfaces" below).
- `pnpm test` runs the fast tests: discovery, refusals, and the part.css lint.
- `node check/shots.mjs <dir>` writes light and dark shots of the built page.

In the showroom only, `data-pin="hover"` (or `active`, `focus-visible`, `checked`) holds that state for viewing (a
pressed row pins `hover active`, as a real pointer press is both), and `data-paint-free` marks an
element that carries no paint of its own. It excuses that element (never
its children) from the "takes the skin's values" comparison only. It must truly carry none: transparent
background, no border, shadow, outline or image, and its parent's text colour; otherwise the light
fails and names it. Every such element is listed in `proof.json` and counted under the part. Every other
light applies to it.

The rule: **nothing a person can see inside a part's stage, in the views listed under "What part.css
may condition on", goes unread, and nothing but `part.css` and the base styles can style it.**
Every rule in part.css, on every stage element it can match, is judged as drawn at a moment when it
matches; a rule or a pair nobody judges fails the part by name.

- Coverage is checked, not assumed (`check/coverage.mjs`). Every drawn reading, in every light, first
  asks the browser which of the part's rules apply right then and to which stage elements
  (`element.matches` with the selector the page holds, inside the media conditions that hold in that
  page). After a full run, a rule that sets anything and applied at no judged moment fails the part as
  "a rule nothing read", naming its selector, and so does a state pair (below) that no reading saw.
- States, per pair (`check/states.mjs`). For every rule that holds `:hover`, `:active` or `:checked`, and every live
  control (outside the inert rows, not a pinned row) that matches the rest of its selector, the check
  produces that state on that control with the real pointer, at its centre or held down there (a real
  press is both), or for `:checked` a click there, in the first skin, light, on base at 1440px. Only a
  checkbox or a radio is driven to `:checked`, and only one not checked at rest: one checked at rest is
  read in every view as it stands, and the check puts every box and radio back as it was after a click. A
  drive is judged, not kept: what it leaves changed in the stage beyond that (an attribute, `indeterminate`, a
  value, a child or its text, as a demo's handler might) fails the part by name. Every computed property of the control,
  its `::before` and `::after` and everything inside it must then be what the same control shows with
  that state pinned, and nothing from the control up to the stage may change: so the control pinned is
  the control in that state. Its change must also be exactly the change of some pinned row with the same
  `data-pin` (the check finds the row by comparing). The two are compared by computed value in that
  one view, so a value that computes alike there can differ elsewhere: then, per state, every live
  control it was proven on is pinned at once and the stage is read as drawn in light and in dark, so
  each pair is judged as drawn, in both schemes, while its rule applies. A real state unlike its pin, or one no
  pinned row shows, fails by name. Which controls are driven comes from `element.matches`, never from a
  name or an attribute.
- States the steps reach. Each press step ends with the stage read as drawn, in the first skin, light,
  on base at 1440px, so a state only an action reaches (pending, after Enter on a live button) is read
  while it holds. A reading takes real time, so on the pressed page the page's own timers run on a clock
  that stands still while the check reads: a step's wait moves it that far, and a pending that lasts
  2.5 s lasts 2.5 s of the page's time whatever the readings cost. `example.html` also shows pending at
  rest, in its own row, so every view reads it; under reduced motion (`css/base.css`) an animation runs
  one round, so its spinner stands still.

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
  paint entries. A stage with controls and no boundary reading fails. One pair is read on another element,
  by name: UI SDK's slider takes focus on a range input it hides inside each `ui-slider-thumb`, so that input,
  while no one sees it, is read on its thumb for its boundary, for whether it shows anything, and for the focus
  ring, which base.css draws on the thumb in place of UI SDK's own outline there. Every other control is read
  on itself.
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
  A part sheet keeps to a few forms: a `url(` has a quoted string straight after it, a string closes on
  the line it opens, and a comment stands only between declarations and between rules; outside them the
  sheet is refused by name. Inside them, every rule the text writes must be one the browser read
  (`check/sheet-text.mjs`): a rule it drops, for a selector or condition it does not know, is refused by
  name, since nothing would judge it.
  Selectors are read as the browser writes them back: a pinned state (`:hover`, `:active`,
  `:focus-visible`, `:checked`, in any case) may stand only on the element the rule styles, never on a host,
  ancestor or sibling or inside another pseudo-class, where no `data-pin` reaches; other pseudo-classes
  come from a short list of structure (`check/selectors.mjs`): any other a person changes by clicking or
  typing (`:placeholder-shown`, `:user-invalid`, `:focus-within`, `:enabled` and the like) is refused until a
  part needs it, when it joins the pinned states with a way for the check to drive it, as `:checked` did;
  `:is()`, `:where()` and `:has()` take one selector each (why: "every branch", below). Pseudo-elements are the four the check
  reads. Then the check parses the page's own `barkui.css`, every part in one sheet as
  the page loads it, in the same browser, and each part's section must hold, rule by rule and with its
  states pinned, what was read from that part alone; a difference refuses the run, naming the part.
- Motion: a part defines no keyframes. It may name the shared ones in `css/base.css` (today one,
  `bark-spin`, which only turns its element; a test holds base.css to that), by name as the browser
  reads it. Transitions are free, because both ends are states the lights read anyway. Where motion is
  read: "What part.css may condition on". A sheet on a checked page may declare a transition or an
  animation only on an element itself, its ::before, its ::after or its ::backdrop: the check reads
  motion there and nowhere else, so motion declared anywhere else is red by name.
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
  after the demo has run, after every press step and at the end of each light's run, every value a
  `style` attribute in a stage has held holds placement only (see "Placement"), the stylesheets, their
  rules and the adopted sheets must be the build's own, and no animation may run from script. A failure
  names what changed.

## Surfaces

The surface switch sets `data-surface` (base, raised, sunken, primary, inverse) on each part's stage.
The check reads every surface in every skin and scheme, at 1440px and at 390px, and the lights are
proved on all five; the page says so. Each view, a skin in a scheme, is read on one of two pages of
the one browser at once, by one rule over the list of views (`check/view-pages.mjs`), and what each
view finds is made in the list's order, so the lights read the same as on one page. The check prints
"views the skins light read: N of N; on two pages: 0; on none: 0" from the list, and the same for the
phone light; a view on no page or on two, or a page that cannot open, is red by name. A drawn text under 4.5:1 is let through only by a wait in `build/sheet-waits.mjs` that
names its skin, scheme and surface, whose two tokens its fill and ground resolve to, and only while it
measures no worse than the wait records. Any other text under 4.5:1, any control boundary under 3:1, and
any label gone, cut or not drawn as itself, on any surface, turns "every skin" (light views), "light
and dark" (dark views) or "phone" (390px) off. Each wait prints as "waiting on the sheet" with what the last run measured,
and the sheet's work that ends it. Today eight wait, all `--ui-muted-foreground` on `--ui-background` on
primary (the demo labels), at 3.75 to 3.78:1. For each surface the check also records, as numbers only,
a disabled control's fill against its ground and against the primary fill.

## The top layer

An open popover or a modal dialog is drawn in the top layer: over the page, not inside its DOM parent, and
often outside the stage's box. A part names each such box in part.json `layers` as `{ box, open, close }`:
the box's selector, and the real input that opens and closes it (`focus`, `click` or `hover` at the control's
centre only if it is on top there, `leave` to take the pointer off the page, `keys`). In every view the stage is read in (every skin, scheme and surface at
1440px, and at 390px) the check reads the stage closed, then opens each layer by its input, reads the stage
again with the capture covering the stage and the open box, and closes it by its input. A layer that does
not open or does not close fails by name. While a box is open, the ground behind it is its `::backdrop`,
then what the page draws there, read from a capture taken with the open boxes hidden, never its DOM parent;
what the box covers or a modal box blocks is read in the closed reading.

Every element that can open in the top layer (a `dialog`, or an element that carries `popover`) must be
named by a layer, whether or not it ever opens. The check watches each page from its first frame, so it sees
such an element in the document at load, added later, or given `popover` later, even one that is gone again
before the check looks, and in each open shadow root. Every element the check sees arrive is read with its
open shadow root, so a host that arrives carrying one (parsed by `setHTMLUnsafe`, cloned, adopted) is read
on arrival. A root comes to exist on a host already in the page in these ways only, each seen at once or
refused by name: a script calls `attachShadow` (a hook the check sets in the page before any of its script
tells it at once, wherever the host stands); the parser meets a declared root in `example.html` (refused,
"a declared shadow root"); markup is written into the parsed page (`document.write`, `writeln`, `open`:
refused by name); another window attaches one (every frame in the page and `window.open`, refused by
name; the part's context holds the check's own two pages and no other: any other page is refused by name). Markup parsed into a host
already in the page (`setHTMLUnsafe`, `innerHTML`) cannot give that host a root: a declared root at the
top of the markup stays a plain `template`, and one deeper is on a new host, read on arrival. One no layer names fails by name, once per page ("… can open in the top layer (a
dialog, or it carries popover), and no layer in part.json names it"), at the first reading or look after
real input that follows. A box open in the top layer that no layer names also fails by name ("… is open in
the top layer during the reading, and no layer in part.json names it") at every moment the check judges or
drives the part: each reading, each Tab stop of the focus walk, each press step, each driven state, and
each layer's open and close input. The one limit: a box the page never holds while the check has it open,
up to the check's last look (one made only after an input the check never gives), or one only inside a
closed shadow root, is not seen.

A layer's box opens at once on its input. One that is not open once its input settles fails by name ("… is
not open in the top layer once its "open" input settles: it opened later than the check waits, or not at
all; a layer opens at once on its input"), so a part's tooltip shows with no delay. A
box a layer names is read by that layer: the check opens it by the layer's own input in every view, so when
a Tab stop or a driven state opens it as well, it is not read again there. A part whose box opens only on
focus or hover names that input as the layer's `open` (`focus`, or `hover` with the pointer at the control's
centre), and as its `close` the input that moves away (`keys: ["Tab"]`, or `leave: true`, the pointer taken
off the page).

## Placement

UI SDK places a popup by writing where it sits into the box's own `style` attribute, and names the control it
hangs from in that control's. That is all a `style` attribute in a stage may hold: placement is where a box sits,
never how it looks. A box is an element the check has seen can open in the top layer in the part's stage (a
`dialog`, or an element that carries `popover`; see "The top layer"). The list, in `check/placement.mjs`, with
where each may stand and what writes it:

- `anchor-name`: only on an element whose anchor name a box's `position-anchor` names. UI SDK select and menu, on
  the trigger.
- `position-anchor`, `position`, `top`, `right`, `bottom`, `left`, `margin-top`, `margin-right`, `margin-bottom`,
  `margin-left`, `position-try-fallbacks`, `position-visibility`, `--available-height`, `--available-width`,
  `--anchor-width`, `--anchor-height`, `--transform-origin`, `--arrow-offset`: only on a box. UI SDK select and
  menu, on the box.
- `--dialog-stack`, `--keyboard-inset`, `--visual-viewport-height`: only on a box. UI SDK dialog, on the box.

Of the values, the check reads transition's, the names anchor-name gives, and the scroll lock's (below). Apart from
the list, one more entry has its own reason: UI SDK switches motion off on a box while it measures where to put
it, and `none` takes motion away and adds no look. UI SDK writes it when it first places a select or menu box and
puts the old value back in the same task, so a reading taken now and then does not see it; the log below does:

- `transition`, all five longhands `none`: only on a box. UI SDK select and menu, on the box.

Apart from both, a third list has its own reason: UI SDK lays out the pieces of a control and sets how they take a
press at run time, and that is where a piece sits and how it behaves, not how it looks. A piece is the element it
is, inside its control (a `ui-slider`, a `ui-number-input`, a `ui-tabs` or a `ui-segmented-control`), and carries
only what UI SDK writes on it, each property by its lines in the file that writes it (`components/slider/slider.js`,
`components/number-input/number-input.js`, `components/tabs/tabs.js`,
`components/segmented-control/segmented-control.js`, or the file named before the lines, in
`foundation/direct-manipulation/`), and only as one of the values UI SDK writes there, read as the browser gives it
back. In a value, `{p}` is a place on the track, a number from 0 to 100: UI SDK writes every place as a percentage
it clamps to that range (`percentOf`, in `components/slider/slider-values.js`). `{px}` is a number of pixels, as
JavaScript prints a number: the tabs and the segmented control measure the chosen item against its list
(`layoutBox`, in `foundation/platform/layout.js`) and write the six sides of that box on their sliding indicator, and
take them away while nothing is chosen. Every entry names its values; none takes any value. Which way the slider runs is not read: a piece may carry what UI SDK writes on it running across or
running down. A number input's step button is the first `button` in its piece, the one UI SDK writes on
(`el.querySelector("button")`, in `@ui-sdk/web`); a second button there carries nothing. It holds a press for the
400 ms `repeat.js` gives it; `hold.js` also writes `-webkit-touch-callout: none` there, which the browser the check
runs drops, so it is not on the list.

- On `ui-slider-control`: `touch-action` as `none` (179). UI SDK slider, on its pieces.
- On `ui-slider-track`: `position` as `relative` (187). UI SDK slider, on its pieces.
- On `ui-slider-indicator`: `position` as `absolute` (79), `inset-inline-start` as `{p}%` (80), `width` as `{p}%`
  (81), `height` as `{p}%` (81), `top` as `0` (82), `bottom` as `0` or `{p}%` (80, 82), `left` as `0` (82), `right`
  as `0` (82), `--slider-indicator-start` as `{p}%` (83), `--slider-indicator-size` as `{p}%` (84). UI SDK slider,
  on its pieces.
- On `ui-slider-thumb`: `position` as `absolute` (59), `bottom` as `{p}%` (60), `left` as `50%` (60), `translate`
  as `-50% 50%` or `0 -50%` (60, 65), `inset-inline` as `calc({p}% - 50%) calc(50% - {p}%)` (61), `margin-inline`
  as `auto` (62), `justify-self` as `center` (63), `top` as `50%` (64), `z-index` as `1` or `2` (67),
  `--slider-thumb-position` as `{p}%` (68). UI SDK slider, on its pieces.
- On the range input in `ui-slider-thumb-input`: `position` as `absolute` (88), `inset` as `0` (89), `width` as
  `100%` (90), `height` as `100%` (91), `margin` as `0` (92), `padding` as `0` (93), `border` as `0` (94),
  `opacity` as `0` (95), `overflow` as `hidden` (96), `clip-path` as `inset(50%)` (97), `white-space` as `nowrap`
  (98), `pointer-events` as `none` (99). UI SDK slider, on its pieces.
- On the first button in `ui-number-input-increment` or `ui-number-input-decrement`: `user-select` as `none` (71),
  `-webkit-user-select` as `none` (71), `touch-action` as `manipulation` (71), `--hold-delay` as `400ms` (hold.js 9).
  UI SDK number input, on its step buttons and scrub area.
- On `ui-number-input-scrub-area`: `touch-action` as `none` (237), `user-select` as `none` (237),
  `-webkit-user-select` as `none` (237). UI SDK number input, on its step buttons and scrub area.
- On `ui-tabs-indicator`: `--active-tab-left` as `{px}px` (47), `--active-tab-right` as `{px}px` (47),
  `--active-tab-top` as `{px}px` (47), `--active-tab-bottom` as `{px}px` (47), `--active-tab-width` as `{px}px` (47),
  `--active-tab-height` as `{px}px` (47). UI SDK tabs, on its indicator.
- On `ui-segmented-control-indicator`: `--segmented-control-indicator-left` as `{px}px` (105),
  `--segmented-control-indicator-right` as `{px}px` (105), `--segmented-control-indicator-top` as `{px}px` (105),
  `--segmented-control-indicator-bottom` as `{px}px` (105), `--segmented-control-indicator-width` as `{px}px` (105),
  `--segmented-control-indicator-height` as `{px}px` (105). UI SDK segmented control, on its indicator.

Any other property, a box's property on an element that is not a box, a piece's property on any other element
or on another piece, an anchor name no box hangs from, any other transition value, and a value UI SDK does not
write on a piece, a place past 100% among them, fail by name ("… was given opacity in a style attribute, which is
not placement: the look belongs in part.css"; "… was given top: 10px in a style attribute, and UI SDK writes top on
ui-slider-thumb only as "50%""). What is read is each declaration the browser applies, by its name: a shorthand by its
longhands (`inset` is `top`, `right`, `bottom` and `left`), and `all` by its own name. From the page's first
frame, a log in the check's own world takes each change to a `style`
attribute in the document and in each open shadow root, however it is written (the attribute, `el.style`,
`attributeStyleMap`), with where the element stood as the browser's record of the change shows it, and the values
held in a stage are judged; so a property written while a box is open and taken away as it closes fails by name.
A hook set before any of the page's script makes `removeAttribute` bring the attribute up to date first, since the
browser does not. On the stage with no script, any `style` attribute fails: nothing there can write one.

The values the same log holds for an element that holds a stage, up to and including the root element, are judged
too, since a stage inherits from it. Two more rules are read at every look, so the
order in which the page attaches and moves things cannot matter: a stage whose root node is not the document fails
by name, and so does an element that holds a stage and hosts a shadow root of any mode. For that, the check asks the
browser's own tree, element by element, and an element it gets no answer for fails by name too.

In the style attribute of an element that holds a stage nothing may stand, with one closed list apart, in the same
file, with its own reason: UI SDK stops the page scrolling behind an open dialog, which is behaviour, not look. It
writes the lock on the root element, `scrollbar-gutter` and `--scrollbar-width` only when the page has a scrollbar
that takes room. The list is what UI SDK writes in the browser the check runs (where `scrollbar-gutter` is missing
it writes `padding-right` instead, which is not on the list):

- `overflow-x`, `overflow-y`: only as `hidden`, only on the root element or body, while a dialog box is open. UI SDK
  dialog, on the root element.
- `scroll-behavior`: only as `auto`, only on the root element or body, while a dialog box is open. UI SDK dialog, on
  the root element.
- `scrollbar-gutter`: only as `stable`, only on the root element or body, while a dialog box is open. UI SDK dialog,
  on the root element.
- `--scrollbar-width`: only as a `px` length, only on the root element or body, while a dialog box is open. UI SDK
  dialog, on the root element.

UI SDK writes the lock a frame after the box enters the top layer, and takes it away before the box leaves it, in
the same task; with two dialogs open, the lock stays until the last one closes. A dialog box is a box that is a
`dialog`, or carries the role `dialog` or `alertdialog`, or holds one. Each write is judged by whether one is open
when the browser hands the write over, and the writes waiting are taken at each `beforetoggle`, before a box opens or
closes, so a lock written before a dialog opens, or left after the last one closes, fails by name. `--scrollbar-width`
reaches every stage, since a custom property inherits; no shipped sheet reads it, and part.css may not (it reads
only `--ui-*` and `--bark-*`). Another value on a listed property, any other property on the root element or
body, the lock while no dialog box is open, and any property on another element that holds a stage fail by name
("… holds a stage, which inherits from it: nothing may stand there"). What is read, and when: the log of `style`
attributes, kept from the first frame and judged at each look, and the two rules on a stage's root node and the
shadow roots above it, read at each look.

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
| State | as `example.html` shows it, and as the real pointer and the press steps make it | selectors on the part's own markup (`[data-disabled]` and the like); `:hover`, `:active`, `:checked` only on the element a rule styles | each pinned row (`data-pin`) and each state shown at rest (the pending row) with every skin, scheme, surface and width. Each real state, on every live control a state rule matches, held to equal that control pinned and read as drawn so in the first skin, light, on base at 1440px, and held to change exactly as a pinned row changes, which carries it to every other view ("every skin"). Each press step's result read as drawn in that same view ("pressed by real keys") |
| Script | on, off | not at all (`@media (scripting)` is refused) | "printed with no script" reads the page as it opens with no script: base surface, 1440px |

What this leaves unread, said plainly. Widths between 390px and 1440px are not rendered; paint cannot
differ there, layout can. A moment partway through a transition is not read: both its ends are. A
real state is driven and compared in that one view and read as drawn in light and dark there (one skin,
base, 1440px); the pinned row that changes the same way carries the change, not the control it is on,
to the other skins, surfaces and widths. A state only the steps reach (the live
button's pending) is read in that one view only: the pending row shows pending at rest in every view,
but nothing holds the live button's pending to that row. The focus ring is base.css's and is measured on every
Tab stop, below. The motion pass reads one skin in light on purpose:
part.css cannot tell skins or schemes apart, and with motion allowed it can change only timing and,
through the shared keyframes, turn an element, so what motion changes is the same in every skin. The
focus ring's edge is measured on every Tab stop on the base surface at 1440px, in every skin and scheme.
A rule counts as read only when every branch of its selector list applied at a judged moment. A branch
is one selector of the rule's own list; a nested rule's branches are each of its own crossed with each of
its parent's. In
`[inert] [data-slot="button"]:not([data-pin]), #x-save[data-pending]:hover { --bark-button-hover-fg: … }`
the first branch applies at every reading, but the second (a live button pending under the pointer) is
never driven, because no live control is pending when the states are planned, so the rule fails as
"a branch nothing read". A list inside `:is()`, `:where()` or `:has()` is a choice the branches would not
show, so part.css may not hold one: write each arm as a branch. `:not(a, b)` is one negation, not a choice.
The list is read from the text, since the browser drops an arm it does not know from `:is()` and
`:where()` and keeps the rule; and each arm the text writes, a branch or the one selector inside
`:is()` or `:where()`, is read alone by the browser, and the one inside is read where it stands as well,
the rule's selector beside the same selector with that `:is()` or `:where()` emptied, so an arm it drops
is refused by name.

## How many parts the check holds

<!-- capacity: made by check/capacity.mjs; run `node check/capacity.mjs` to write it -->
On CI's hosted runner one job of the check took 570 s for 5 parts, with 14 parts in the folder; a job may take at most 1.5 times its reading, scaled linearly past the most parts read (171 s a part), and stops, failing, once it passes that, so one job's 15-minute check step in CI holds 5 parts, whose ceiling of 855 s is 95% of it. The ceilings are made from readings (`check/capacity.mjs`): each is one job's whole run on CI's hosted runner, and each ceiling is 1.5 times the slowest reading for its number of parts. The readings: the check, 1 part of 1 in 135 s (run 44623848758 at ddb4ba55b6); 4 parts of 14 in 430 s (run 44642580444 at fa14e54128); 4 parts of 14 in 432 s (run 44642580444 at fa14e54128); 3 parts of 14 in 252 s (run 44642580444 at fa14e54128); 3 parts of 14 in 211 s (run 44642580444 at fa14e54128); 5 parts of 14 in 570 s (run 44662694458 at d9d277ad73); 5 parts of 14 in 567 s (run 44662694458 at d9d277ad73); the selftest, its views job in 201 s (job 137754186448 of run 45192291440 at ff599196ef) and its rest job in 63 s (job 137754186506 of run 45192291440 at ff599196ef) and its layers job in 133 s (job 137754186372 of run 45192291440 at ff599196ef) and its surfaces job in 185 s (job 137754186425 of run 45192291440 at ff599196ef) and its states job in 137 s (job 137754186267 of run 45192291440 at ff599196ef) and its open job in 108 s (job 137754186386 of run 45192291440 at ff599196ef). A job checks 3 parts at a time, lightest first by the weights below (`check/jobs.mjs`, `startOrder`), so its heaviest part starts last, as the others end. A run stops, failing with its sentence, the moment it passes its ceiling, wherever it is then (`check/ceiling.mjs`, one timer for the check and the selftest; `BARKUI_CEILING_SECONDS` can lower a ceiling, down to 0 s, for a test, never raise it). Given more than 5 parts, a job refuses to run, naming that sentence, before any light is read. When a part lands, its hosted reading goes into `check/capacity.mjs` and the numbers move by measurement; a test holds the steps' minutes to `barkui.yml`, the ceiling of 5 parts under the check step and of one more over it, and this passage word for word.

In CI the check runs as jobs side by side. `check/jobs.mjs` splits the part folders into the fewest groups of at most 5 parts, their sizes within one of each other, and the job matrix in `barkui.yml` reads that list; no list is written by hand. The heaviest parts are spread apart: each part weighs its seconds on CI's hosted runner in one run (`check/part-weights.mjs`, run 45710017441), a part with no reading weighs the median reading, and the parts are dealt out heaviest first (equal weights by name), each to the lightest group by summed weight among those that hold the fewest parts so far (equal loads: the lower group number), each group listing its parts in name order. So the heaviest parts go one to a group before any group takes a second, and a new part never ties them; the plan job names each part with no reading on its log, and its reading is written into `check/part-weights.mjs` by hand. The plan, each job and the closing check compute the split again from the same checkout and must agree. Every job builds the page of every part folder, so each folder builds and every id is unique page-wide, and then presses and reads its own parts on a page that prints its group's stages, and the stage that follows each of them there, and loads that page's `barkui.css`, every part's sheet, so each part wears every rule it wears on the page of every part and has what follows it there, and a part's time does not grow with the folder. Each part is read on a copy of that page whose other stages carry `hidden` but the one that follows it (`check/part-page.mjs`): every stage's elements still connect and its demo runs, and only the part's own stage and the one after it are drawn, so a part's time does not grow with the stages beside it; each part's lines give its seconds against its limit, and the job's last lines name every part that used more than two thirds of it. A job's ceiling stays where it is whatever the folder holds. One closing check (its name is `AGGREGATE` in `check/jobs.mjs`) always runs and is red when the plan, any group or any selftest job is red, cancelled, missing, or skipped while the plan said BarkUI was touched.

The selftest copies one part, so its time does not grow with the parts folder. It runs as 6 jobs side by side, and one rule in `check/jobs.mjs` (`selftestJob`) puts each case in exactly one: the `views` job runs the cases that read the wide or phone views and drive no states, direct readings among them, but for those that read every surface, which the `surfaces` job runs; the `layers` job the other direct readings and the top layer's cases but for the named boxes read open, which the `open` job runs; the `states` job the states cases that bring a sheet or a part of their own; the `rest` job every other case. A test holds that the jobs together run every case, each once. On CI's hosted runner the selftest's views job took 201 s; it may take at most 1.5 times that, 302 s, 50% of its 10-minute step in CI, and stops, failing, once it passes that. On CI's hosted runner the selftest's rest job took 63 s; it may take at most 1.5 times that, 95 s, 16% of its 10-minute step in CI, and stops, failing, once it passes that. On CI's hosted runner the selftest's layers job took 133 s; it may take at most 1.5 times that, 200 s, 33% of its 10-minute step in CI, and stops, failing, once it passes that. On CI's hosted runner the selftest's surfaces job took 185 s; it may take at most 1.5 times that, 278 s, 46% of its 10-minute step in CI, and stops, failing, once it passes that. On CI's hosted runner the selftest's states job took 137 s; it may take at most 1.5 times that, 206 s, 34% of its 10-minute step in CI, and stops, failing, once it passes that. On CI's hosted runner the selftest's open job took 108 s; it may take at most 1.5 times that, 162 s, 27% of its 10-minute step in CI, and stops, failing, once it passes that. Each ceiling stays at or under 80% of its step, and no reading makes a job's ceiling higher than the one that stands (views 315 s, rest 252 s, layers 218 s; a job split off another stands under the ceiling of the job it came from): a test holds each reading to it, and a job that would pass it is split again, never given a higher ceiling or a longer step. Every case runs under one limit of 60 s (`CASE_SECONDS`), and none carries its own; each case's reading on CI's hosted runner (`check/case-readings.mjs`) sits under 80% of it, 48 s, and a test names any case that does not. A case that outgrows that share is unfolded into runs, each of its rows in exactly one, never given a longer limit.
<!-- /capacity -->

The check runs at most 8 groups (`MOST_GROUPS` in `check/jobs.mjs`), so at most 40 parts, and
`.github/required-checks.json` has one row for each of groups 1 to 8; the proof knob stops there too. Past
40 parts the plan job refuses, red, and names the fix: raise `MOST_GROUPS`, add a row for each new group to
`.github/required-checks.json` and its acknowledgement line to `scripts/required-checks.test.sh` (from
`scripts/required-checks-ack-derive.sh`), in one change. A test holds the rows to `MOST_GROUPS`.

## What the check proves about a label, and no more

Every label in the showroom, as built, matches its reference at 0.995 or more on macOS and on Linux, on
every surface, at 1440px and at 390px (the check prints the lowest on every run; in the last runs it was
1.000 on macOS and 0.995 on Linux, the "Sizes" heading at 390px). A label must match at 0.975 or more. What that limit costs is measured by the
selftest's ladder, which cuts and covers one label step by step, and the selftest fails until this
sentence moves with it: a ten-letter label 74 px wide (in CI, on Linux; 70 px on macOS) turns the
lights off when its last 3 px are cut away, when a 5 px square of its ground covers its end, or when a
4 px square of its ink is laid over its end; 2 px, 4 px and 3 px leave them on. A smaller loss or gain
than that, and a way of hiding a label that leaves its pixels as they are, is outside this claim.
