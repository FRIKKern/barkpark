<!-- doc-tier: agent | canonical-for: studio-web-components | budget: 600tok -->
# Studio Web Components — decision record

> v1 prototype. First widget: `bp-rich-text-editor` (Task #11 WI4). Field-bridge picker set shipped: `bp-media-picker`, `bp-reference-picker`. `bp-document-preview` ships alongside them but is READ-ONLY — it emits no `bp-change` and has no `BarkparkFieldBridge` dependency, because it never writes back. All live in `api/priv/static/assets/`. Further `bp-*` widgets (e.g. `bp-asset-browser`, `bp-asset-explorer`, `bp-overflow-menu`, `bp-search-intel`) don't all use the field-bridge pattern below.

## Key decisions

**`composed: false` on `bp-change` events.** Events are `{ bubbles: true, composed: false }`. Crossing a Shadow DOM boundary is explicitly not supported in v1. The wrapper div lives in the LV-managed DOM, not inside a shadow root — `composed: false` is sufficient.

**`phx-update="ignore"` on the wrapper.** Without it, LV re-renders the inner DOM on every autosave reply, resetting the WC's internal state and dropping unsent keystrokes. This is the single most common pitfall; it is non-optional.

**`execCommand("insertText")` for paste (v1 richText).** Strips formatting, inserts plain text. Safe XSS default. v2 will migrate to ProseMirror / TipTap or a manual paste sanitiser. The deprecated status is accepted for v1; document if a publisher complains.

**`<script defer>` BEFORE `phoenix.js`.** Custom element scripts must be loaded with `defer` and placed BEFORE `phoenix.js` in `root.html.heex`. Without `defer`, LV may mount before the element is registered — the unupgraded element renders empty until late upgrade fires.

**v2 deferral: `setValue(v)` for server-pushed updates.** `phx-update="ignore"` blocks server-driven value sync. v1 defers collaborative editing; if needed, a `bp-set-value` `push_event` channel would let the WC reflect updates via `setValue(v)`.

## Field-bridge pattern

`BarkparkFieldBridge` hook — field-agnostic, mounts on a wrapper `<div>` containing both the hidden input and the WC.

The bridge listens for `bp-change` on the wrapper, reads `event.target.dataset.bridgeTarget` to find the hidden input by id, writes `event.detail.value` into the input, dispatches a synthetic `input` event → LV's existing debounce + serialize + push round-trip fires exactly as for native inputs.

Required wrapper attributes:
- `id` — required by `phx-hook` (LV reconciliation) and `phx-update="ignore"` (element lookup)
- `phx-update="ignore"` — see above
- `phx-hook="BarkparkFieldBridge"`

WC contract: `customElements.define`, read initial state from `value` attribute, emit `CustomEvent("bp-change", { bubbles: true, composed: false, detail: { value } })`, implement `disconnectedCallback` with defensive guards.

## Adding a new bp-* widget

1. `api/priv/static/assets/bp-<name>.js` — custom element class + `customElements.define("bp-<name>", …)`.
2. `<script src="/assets/bp-<name>.js" defer></script>` in `root.html.heex` BEFORE `phoenix.js`.
3. Wrapper + hidden input + WC in the relevant `field_inputs.ex` clause (use `richText` clause as template).
4. Reuse `BarkparkFieldBridge` — no new hook needed.
5. Add a render test at `api/test/barkpark_web/components/fields/<name>_test.exs`.

## Code anchors

- `api/lib/barkpark_web/components/field_inputs.ex` — `input/1` clause per field type
- `api/priv/static/assets/bp-rich-text-editor.js` — canonical WC example
- `api/lib/barkpark_web/layouts/root.html.heex` — script loading order
- `api/lib/barkpark_web/layouts/root.html.heex` — `Hooks.BarkparkFieldBridge` hook definition (grep the symbol; line numbers drift)
