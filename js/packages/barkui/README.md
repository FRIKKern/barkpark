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
  check turns the right light off.
- In CI (`js-tests.yml`) the fast tests and the showroom check run on every js-tests run; the selftest
  runs only when a change touches `js/packages/barkui/**`, `api/priv/barkui/**` or that workflow, and
  also whenever the changed files cannot be worked out.
- `build/sheet-waits.mjs` lists values the tokens sheet does not deliver yet. The check records each
  measure; the page prints "waiting on the sheet: ..." while it is short, and `hard: true` makes it fail.
- `pnpm test` runs the fast tests: discovery, refusals, and the part.css colour lint.
- `node check/shots.mjs <dir>` writes light and dark shots of the built page.

In the showroom only, `data-pin="hover"` (or `active`, `focus-visible`) holds that state for viewing,
and `data-paint-free` marks an element that is meant to take no skin colour.
