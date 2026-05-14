defmodule BarkparkWeb.Components.OnixPreview do
  @moduledoc """
  Side-pane ONIX 3.0 XML preview for the currently-edited book. Renders
  the result of `Barkpark.Plugins.OnixEdit.Export.to_string/2` on every
  autosave (debounced upstream by the parent LiveView via the existing
  `phx-debounce` on the editor form inputs).

  Pure server-render — no JS, no syntax highlighting. The pane is only
  mounted when the editor's `editor_type` is `"book"`; other schemas
  keep the existing single-pane editor for back-compat (Task #16 scope,
  matches the v1 ONIX-only constraint declared in the project CLAUDE.md).

  Render contract:
    * `:doc`   — current document content map (raw, unsaved values OK).
                 Currently unused inside the component (the parent
                 recomputes XML upstream) but kept on the attr list so
                 the call sites stay self-documenting.
    * `:type`  — schema type name; component is mounted only when this
                 is `"book"` but the attr is kept for symmetry / debug.
    * `:xml`   — pre-rendered XML binary (or `nil` before the first
                 autosave). Component owns the `<pre>` wrapper.
    * `:error` — any export/validation error term (any-typed by design —
                 the upstream `Export.to_string/2` may return
                 `{:xsd_invalid, reasons}` today and could surface other
                 envelopes later; the component renders a soft badge).
  """

  use Phoenix.Component

  attr :doc, :map, required: true, doc: "the current document content (raw map)"
  attr :type, :string, required: true
  attr :error, :any, default: nil, doc: "validation/export error if any"
  attr :xml, :string, default: nil, doc: "pre-rendered XML; component renders the <pre>"

  def onix_preview(assigns) do
    ~H"""
    <aside class="bp-onix-preview" data-test-id="onix-preview" data-bp-type={@type}>
      <header class="bp-onix-preview-header">
        <span class="bp-onix-preview-title">ONIX 3.0 preview</span>
        <span :if={@error} class="bp-onix-preview-error" title={inspect(@error)}>export failed</span>
        <span :if={!@error && @xml} class="bp-onix-preview-meta">
          <%= byte_size(@xml) %> bytes
        </span>
      </header>
      <pre :if={@xml} class="bp-onix-preview-body"><code><%= @xml %></code></pre>
      <div :if={!@xml && !@error} class="bp-onix-preview-empty">
        Start editing to see ONIX
      </div>
    </aside>
    """
  end
end
