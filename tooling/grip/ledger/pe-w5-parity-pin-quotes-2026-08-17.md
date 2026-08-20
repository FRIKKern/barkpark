# pe-w5 parity-pin-quotes — re-derivation recipe (verifier)

Rules on view_edit_parity_test.exs (origin/main) for D29 display-scale + slab-fix slices.
The test byte-compares CSS *sources* (not rendered output) producer-exhaustively.

## Re-derive the three decisive facts

```sh
# (a) heading font-weight is a GROUP rule folded into h1/h2/h3, value = var(--bp-heading-weight),
#     mirrored byte-identical in BOTH editor copies; NOT in @documented_divergences.
git show origin/main:api/assets/paper-surface/paper-surface.css        | sed -n '323,326p;343,345p;109p;730p'
git show origin/main:api/lib/barkpark_web/layouts/root.html.heex       | sed -n '4596,4598p'   # .bp-paper-editor-body h1/h2/h3
git show origin/main:api/assets/paper-editor/src/styles.css            | sed -n '509,511p'      # bundle twin
git show origin/main:api/test/barkpark/portable_doc/render/view_edit_parity_test.exs | sed -n '213,226p'  # divergences: only color+font-family

# (b) monitored breakout class is .bp-stats (plural, container); .bp-stat (cell) is NOT monitored.
git show origin/main:api/test/barkpark/portable_doc/render/view_edit_parity_test.exs | sed -n '74p;98,100p;428p'
git show origin/main:api/assets/paper-surface/paper-surface.css | grep -n '\.bp-stat'    # 1339 cell vs 1352 .bp-stats container

# (c) the two editor twins = @root_heex + @bundle_css
git show origin/main:api/test/barkpark/portable_doc/render/view_edit_parity_test.exs | sed -n '76,92p'
```

## Verdicts

- (a) BYTE-PINNED. `declarations_for` splits the comma-group `.bp-paper-surface h1,h2,h3,...`
  and folds `font-weight: var(--bp-heading-weight)` into each. §2 (view↔root) + §5 (root↔bundle)
  are producer-exhaustive; font-weight has NO divergence entry. => a D29 h2 override
  (`.bp-paper-surface h2 { font-weight: X }`, later rule wins in the parser) must land byte-identical
  in ALL THREE: paper-surface.css h2, root.html.heex `.bp-paper-editor-body h2`, styles.css bundle h2.
  A per-step weight needs a NEW token/literal (var(--bp-heading-weight) resolves to 600); this test
  pins the TOKEN STRING, separate from validate.mjs:293's ===600 numeric pin.

- (b) DOES NOT trip §2/§5 IF it lands on `.bp-stat`/`.bp-stat__*` cells (exact-match selectors,
  never in @parity_elements/@mirror_elements) — cell-level rules pass surface-only.
  BUT if the slab remedy touches the CONTAINER `.bp-stats` grid (monitored), any added property
  must be mirrored three-way or §2/§5 red.

- (c) two editor twins = `api/lib/barkpark_web/layouts/root.html.heex` (.bp-paper-editor-body inline)
  + `api/assets/paper-editor/src/styles.css` (bundle). §5 gates them byte-identical for h1/h2/h3.
  text-wrap:balance as editor-only is mirror-only-legal for §2; for reader parity add it to
  paper-surface.css too (then it becomes three-surface producer-exhaustive again).
