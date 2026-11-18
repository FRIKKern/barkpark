# @barkpark/barkui

BarkUI is one look for UI SDK's parts (`@ui-sdk/web`, pinned to `0.1.0-beta.10`). It reads only the
`--ui-*` and `--bark-*` variables of `api/priv/barkui/tokens.css`, the one source of the skins.
Private; not published.

```
parts/<name>/
  part.json     name (= folder), family, element, imports, summary, paint (selector -> variable per property)
  part.css      the look over UI SDK's default; only --ui-* / --bark-* colours, no literal, no skin rule
  example.html  the part in each state worth seeing, in UI SDK's printed markup (works with no script)
  press.mjs     setup(root, h) and steps: real keys or a click, then expect(root, h) -> true | reason
  demo.mjs      optional: showroom-only wiring for a demo (never a look)
```

Adding a part is adding a folder. The build, the check and the tests find parts by reading `parts/`;
no other file changes.

- `pnpm run build` writes `dist/showroom/index.html`, which opens from disk with no server and no network.
- `pnpm run check` builds, presses every part in headless Chromium, and writes `dist/proof.json`:
  pressed by real keys, every skin, light and dark, a 390px window, printed with no script. The page
  shows a light only when the last run proved it for the same part folder, tokens, base styles and
  UI SDK version. It exits non-zero on an incomplete folder, a failed step, an unlit light, or any
  page error or network request.
- `pnpm test` runs the fast tests: discovery, refusals, and the part.css colour lint.
- `node check/shots.mjs <dir>` writes light and dark shots of the built page.

In the showroom only, `data-pin="hover"` (or `active`, `focus-visible`) holds that state for viewing.
