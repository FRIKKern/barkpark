# Studio Web Components — integration recipe

> Status: v1 prototype. The first widget shipped under this contract is
> `bp-rich-text-editor` (Task #11 WI4). The pattern is designed so the next
> four widgets — `bp-media-picker`, `bp-reference-picker`,
> `bp-document-preview`, `bp-json-inspector` — can be added with no
> changes to the bridge or the server.

## Pattern

Phoenix LiveView renders HEEx and a thin LiveView hook
(`BarkparkFieldBridge`). The Web Component owns its internal DOM
under `phx-update="ignore"`. The hook bridges custom DOM events from
the WC into the LiveView form pipeline so the server stays unaware
of the WC.

The LV form pipeline is the single source of truth for autosave
(`phx-change="autosave"` on `<form id="editor-form">` in
`StudioComponents.studio_editor_shell/1`). A bridged WC writes its
value into a sibling `<input type="hidden" name="doc[<field>]">` and
dispatches a synthetic `input` event so LV's existing debounce +
serialize + push round-trip fires exactly as it does for any native
input.

## Custom element API contract

Every `bp-*` widget MUST:

- Be a `customElements.define`'d class extending `HTMLElement`.
- Read initial state from a `value` attribute (string).
- Emit `CustomEvent("bp-change", { bubbles: true, composed: false, detail: { value } })`
  on user-driven changes. `bubbles: true` is required so the parent
  wrapper's hook can catch the event without being attached to the
  WC itself.
- Implement `disconnectedCallback` to release internal listeners /
  engine instances. Defensive: guard with `if (this._editor)` etc.
  because LV's hook `destroyed()` may run before the browser fires
  `disconnectedCallback`.
- Optionally accept a `setValue(v)` method for server-pushed updates
  (out of scope for v1; required if collaborative editing lands in
  v2).

## Hook bridge contract

`BarkparkFieldBridge` is **field-agnostic**. Mount on a wrapper
`<div>` that contains both the hidden input AND the WC:

```heex
<div id={"bp-{name}-wrap-#{@field_name}"}
     phx-update="ignore"
     phx-hook="BarkparkFieldBridge">
  <input type="hidden"
         id={"bp-{name}-hidden-#{@field_name}"}
         name={"doc[#{@field_name}]"}
         value={@v}
         phx-debounce="500" />
  <bp-{name}
    value={@v}
    data-bridge-target={"bp-{name}-hidden-#{@field_name}"}
  ></bp-{name}>
</div>
```

The bridge listens for `bp-change` events on the wrapper, reads
`event.target.dataset.bridgeTarget` to find the hidden input by id,
writes `event.detail.value` into the input's `.value`, and dispatches
a synthetic `new Event("input", { bubbles: true })` on the input.

Mandatory wrapper attributes:

- `id` — required by both `phx-hook` (for LV reconciliation across
  patches) and `phx-update="ignore"` (for LV element lookup).
- `phx-update="ignore"` — without it, LV would re-render the inner
  DOM on every autosave reply, resetting the WC's internal state and
  dropping unsent keystrokes.
- `phx-hook="BarkparkFieldBridge"` — binds the bridge to this
  wrapper. The hook's `mounted()` runs once when the wrapper first
  appears in the LV-managed DOM.

## `bp-change` event shape

```typescript
type BpChangeEvent = CustomEvent<{ value: string }>;
```

For v1, `value` is a string. The hidden input is always a string —
serialise complex values to JSON in the WC if needed, then
`JSON.parse` server-side.

## Adding a new bp-* widget — recipe

1. **Add `api/priv/static/assets/bp-<name>.js`** defining the custom
   element class and calling `customElements.define("bp-<name>", …)`
   at file end. Keep it self-contained — no globals leaked.
2. **Add `<script src="/assets/bp-<name>.js" defer></script>`** to
   `api/lib/barkpark_web/layouts/root.html.heex` next to the
   existing WC script tags. `defer` is mandatory — see "Common
   pitfalls". Place BEFORE the `phoenix.js` script.
3. **Render the wrapper + hidden input + WC** in the relevant
   `field_inputs.ex` clause. Use the `richText` clause as the
   template:
   ```elixir
   def input(%{field: %{"type" => "<type>", "name" => name}} = assigns) do
     val = Map.get(assigns.editor_form, name, "")
     assigns = assign(assigns, n: name, v: val)
     ~H"""
     <div id={"bp-<name>-wrap-#{@n}"}
          phx-update="ignore"
          phx-hook="BarkparkFieldBridge">
       <input type="hidden"
              id={"bp-<name>-hidden-#{@n}"}
              name={"doc[#{@n}]"}
              value={@v}
              phx-debounce="500" />
       <bp-<name>
         value={@v}
         data-bridge-target={"bp-<name>-hidden-#{@n}"}
       ></bp-<name>>
     </div>
     """
   end
   ```
4. **Reuse `BarkparkFieldBridge`** — no new hook required.
5. **Add a focused render test** at
   `api/test/barkpark_web/components/fields/<name>_test.exs`
   asserting (a) wrapper attributes, (b) hidden input attributes,
   (c) WC tag attributes.
6. **Optional CSS placeholder** in `root.html.heex`'s `<style>`
   block:
   ```css
   bp-<name> {
     display: block;
     min-height: 80px;
   }
   ```
   Prevents zero-height flash before the custom element upgrades.

## Common pitfalls

- **Forgetting `phx-update="ignore"`** — LV clobbers the WC's inner
  DOM on every autosave reply, dropping the user's in-flight typing.
- **Forgetting the hidden input** — the LV form payload omits the
  field entirely; `Content.upsert_draft/5` saves an empty value.
- **Wrong hidden input name** (`name="body"` instead of
  `name="doc[body]"`) — params land outside `params["doc"]` and
  `Content.build_content/2` doesn't see the field.
- **Custom element script loaded AFTER `phoenix_live_view.js` without
  `defer`** — race: LV mounts before the element is registered, so
  the unupgraded element renders empty until the late upgrade fires.
  Always use `<script defer>` and place the tag BEFORE
  `phoenix.js`.
- **Empty-string semantics** — `Content.build_content/2` drops
  empty-string values from `content`. WC emitting `""` (or empty
  `<div></div>` HTML) silently deletes the field on save. Acceptable
  for v1; document if it matters for the widget.
- **Collaborative editing** — `phx-update="ignore"` blocks
  server-driven value sync. v1 prototype defers this; v2 may need a
  `bp-set-value` `push_event` channel that the WC listens for and
  reflects via its `setValue(v)` method.
- **Multiple widgets on one page** — give each wrapper a unique
  `id="bp-<name>-wrap-#{field_name}"`. Each WC instance keeps
  independent state.
- **Cache invalidation** — without `mix phx.digest`, browsers may
  serve a stale `bp-<name>.js` after edits. In dev: DevTools "Disable
  cache". In prod: rely on `phx.digest` fingerprints (when added) or
  bump a version query string on the script tag.

## Format choice for richText (v1)

`bp-rich-text-editor` saves the contenteditable's `innerHTML` (HTML
string). Plain-text seed values render correctly because plain text
is valid HTML. API-direct edits with raw HTML are re-interpreted on
the next render — accept for v1, revisit if a publisher complains.

Paste handling: the v1 WC strips formatting and inserts plain text
via the deprecated `document.execCommand("insertText")`. This is the
safe XSS default. v2 will migrate to ProseMirror / TipTap or a
manual paste sanitiser.
