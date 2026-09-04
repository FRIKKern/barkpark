defmodule BarkparkWeb.Layouts.BulldocsEditorAssetsGateTest do
  @moduledoc """
  The public paper reader's layout may now paint the Studio Beta block editor in
  place, so it carries that editor's browser half: the shell stylesheet, the
  custom-element bundles and the LiveView hooks — every one of them the SAME
  asset `root.html.heex` loads, never a reader-local copy.

  This pins the two halves of that contract:

    * GATING — every tag is `:if={assigns[:can_edit?]}`, so an ANONYMOUS page
      load (the overwhelming majority) fetches nothing new. `can_edit?` is
      `BulldocsLive.mount`'s fail-closed verdict; absent (a dead controller
      render) reads the same as `false`.
    * REGISTRATION ORDER — the hooks asset is non-defer and sits ABOVE the
      inline boot script, which folds `window.BarkparkPaperEditorHooks` into
      PaperHooks BEFORE `new LiveSocket(...)`. Registering after the connect
      would leave every `phx-hook` on the editor inert.

  Rendered through the layout function directly, so the assertions are about the
  layout and cannot be moved by anything the LiveView does.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  # The tags the reader gains ONLY for a viewer who may edit.
  @editor_assets [
    ~s(href="/assets/bp-paper-editor-shell.css"),
    ~s(src="/assets/bp-paper-editor.bundle.js"),
    ~s(src="/assets/bp-media-picker.js"),
    ~s(src="/assets/bp-reference-picker.js"),
    ~s(src="/assets/bp-paper-editor-hooks.js"),
    "window.BP_PAPER_EDITOR_NO_INJECT = true"
  ]

  defp render_layout(extra) do
    assigns =
      Map.merge(
        %{
          inner_content: {:safe, "<main>reader</main>"},
          page_title: "t",
          conn: nil,
          csp_nonce: "test-nonce"
        },
        extra
      )

    render_component(&BarkparkWeb.Layouts.bulldocs/1, assigns)
  end

  test "an anonymous render (no :can_edit? assign) carries no editor asset" do
    html = render_layout(%{})

    for tag <- @editor_assets do
      refute html =~ tag, "an anonymous reader page must not load #{tag}"
    end

    # The reader's own assets are untouched by the gate.
    assert html =~ ~s(src="/assets/phoenix.js")
    assert html =~ ~s(src="/assets/bp-paper-mermaid.js")
  end

  test "a read-only viewer (can_edit? false) carries no editor asset" do
    html = render_layout(%{can_edit?: false})

    for tag <- @editor_assets do
      refute html =~ tag, "a read-only reader page must not load #{tag}"
    end
  end

  test "a writable viewer (can_edit? true) carries every editor asset" do
    html = render_layout(%{can_edit?: true})

    for tag <- @editor_assets do
      assert html =~ tag, "a writable reader page must load #{tag}"
    end
  end

  test "the hooks asset loads before the boot script that registers it" do
    html = render_layout(%{can_edit?: true})

    [asset, merge, connect] =
      for needle <- [
            ~s(src="/assets/bp-paper-editor-hooks.js"),
            "Object.assign(PaperHooks, window.BarkparkPaperEditorHooks",
            "new LiveView.LiveSocket("
          ] do
        idx = :binary.match(html, needle)
        refute idx == :nomatch, "reader layout no longer contains #{needle}"
        elem(idx, 0)
      end

    assert asset < merge, "the hooks asset must load before the merge reads its global"
    assert merge < connect, "hooks must be registered before the LiveSocket connects"
  end

  test "the merge is guarded, so a missing asset cannot break the reader's hooks" do
    assert render_layout(%{can_edit?: true}) =~
             "Object.assign(PaperHooks, window.BarkparkPaperEditorHooks || {});"
  end
end
