# @barkpark/barkui

BarkUI is one look for UI SDK's parts (`@ui-sdk/web`, pinned to `0.1.0-beta.10`). It reads only the
`--ui-*` and `--bark-*` variables of `api/priv/barkui/tokens.css`, the one source of the skins.
Private; not published.

```
parts/<name>/
  part.json     name (= folder), family, element, imports, summary, paint (selector -> variable per property)
  part.css      the look over UI SDK's default: reads only --ui-* / --bark-* colours; no literal, no
                color-mix, no skin or scheme rule, no focus rule or outline
  example.html  the part in each state worth seeing, in UI SDK's printed markup (works with no script);
                every id starts with "<name>-"
  press.mjs     setup(root, h) and steps: real keys or a click, then expect(root, h) -> true | reason,
                and optional ax: what a screen reader must get for an element (role, name, states)
  demo.mjs      optional: `export default function (root)`, called with this part's own root
```

Adding a part is adding a folder. The build, the check and the tests find parts by reading `parts/`;
no other file changes.

`css/base.css` holds what every part shares: the state tints (`--bark-hover`, `--bark-hover-primary`,
`--bark-destructive-*` and so on, computed once from the skin until the sheet owns them) and the one
focus ring (a 2px gap in `--ui-background`, a 2px `--ui-ring-border` edge, the `--ui-ring` halo).

- `pnpm run build` writes `dist/showroom/index.html`, which opens from disk with no server and no network.
- `pnpm run check` builds, presses every part in headless Chromium, and writes `dist/proof.json`:
  pressed by real keys, every skin (each element takes one skin variable in every skin and scheme;
  the focus ring's edge is at least 3:1 on every Tab stop), light and dark, a 390px window, printed
  and seen with no script. The page shows a light only when the last run passed and proved it for the
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
- `pnpm test` runs the fast tests: discovery, refusals, and the part.css colour lint.
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
  scrollbar, SVG fill, stroke, stop, flood and lighting colours. Each run of text is measured in the
  colour it is filled with, at the opacity it is drawn at, against the ground actually behind it.
- Styled only by part.css: `example.html` is markup only (no `<style>`, `<script>`, `style=` or
  `on*=`), and `demo.mjs` wires behaviour only. Its lint refuses inline styles, style attributes, new
  `<style>`/`<link>`, stylesheet edits, adopted sheets, script animations, classes part.css does not
  declare, and reaching into the page or the check, naming the line. At run time a guard, reading from
  an isolated world the page cannot touch, compares the page with the same build run without any demo:
  after the demo has run, after every press step and at the end of each light's run, no element in a
  stage may carry a `style` attribute, the stylesheets, their rules and the adopted sheets must be the
  build's own, and no animation may run from script. A failure names what changed.

The surface switch sets `data-surface` (base, raised, sunken, primary, inverse) on each part's stage.
The lights are proved on base and say so; on any other surface they show grey, "not proved on
<surface>", never on. The check also measures text and the control edge on the other four surfaces
and records them per surface in `proof.json`; a short one prints as a "waiting on the sheet" line and
turns no light off until its `hard` switch is set. It will prove every surface.
