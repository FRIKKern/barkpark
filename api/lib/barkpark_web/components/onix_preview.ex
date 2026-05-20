defmodule BarkparkWeb.Components.OnixPreview do
  @moduledoc """
  Side-pane content preview component. Doc-type-agnostic (Goal
  `barkpark-G1`, task s3) — receives pre-rendered iodata from the
  parent LiveView and dumps it into a `<pre>`. The parent obtains
  the iodata via `Barkpark.Plugins.Registry.collect_content_renderer/3`
  which walks registered plugins first-wins; with plugins=[] the
  parent returns `:none` and the component is never mounted.

  The legacy file name `onix_preview.ex` is preserved to keep the diff
  small (the on-disk path is referenced in screenshots, docs, and
  external bookmarks). The exported function is `content_preview/1`
  — that's the doc-type-agnostic entrypoint used by
  `studio_editor_shell/1`. The thin `onix_preview/1` shim still exists
  for the test file in `test/barkpark_web/components/onix_preview_test.exs`,
  which pins the visual contract (root class, test id, error badge,
  empty state) for the original Book / ONIX-specific shape; it
  delegates to `content_preview/1` with a hard-coded `"ONIX 3.0
  preview"` header so the legacy class names + copy survive.

  Pure server-render — no JS, no syntax highlighting.

  Render contract (`content_preview/1`):

    * `:rendered` — pre-rendered iodata from the winning plugin
                     renderer. The component renders the `<pre>`
                     wrapper. Required.
    * `:type`     — doc-type discriminator (passed through to the
                     `data-bp-type` attr for test selectors). Required.
    * `:title`    — header text shown in the preview pane. Defaults
                     to `"Preview"`; pass an OnixEdit / publisher-
                     specific string when the renderer wants
                     prominent branding.
  """

  use Phoenix.Component

  attr :rendered, :any,
    required: true,
    doc: "pre-rendered iodata from Plugins.Registry.collect_content_renderer/3"

  attr :type, :string, required: true, doc: "doc type discriminator (data-bp-type attr)"
  attr :title, :string, default: "Preview"

  def content_preview(assigns) do
    binary = if assigns.rendered, do: IO.iodata_to_binary(assigns.rendered), else: nil
    assigns = assign(assigns, :binary, binary)

    ~H"""
    <aside class="bp-onix-preview" data-test-id="onix-preview" data-bp-type={@type}>
      <header class="bp-onix-preview-header">
        <span class="bp-onix-preview-title"><%= @title %></span>
        <span :if={@binary} class="bp-onix-preview-meta">
          <%= byte_size(@binary) %> bytes
        </span>
      </header>
      <pre :if={@binary} class="bp-onix-preview-body"><code><%= @binary %></code></pre>
      <div :if={!@binary} class="bp-onix-preview-empty">
        Start editing to see preview
      </div>
    </aside>
    """
  end

  # ── Legacy shim ────────────────────────────────────────────────────
  # Pre-s3 contract: `xml` / `error` assigns + the literal "ONIX 3.0
  # preview" header + "Start editing to see ONIX" empty-state copy.
  # Kept alive for the existing component test; new call sites go
  # through `content_preview/1`.

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
