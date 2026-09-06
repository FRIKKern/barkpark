defmodule BarkparkWeb.Layouts.BulldocsEditorAssetsGateTest do
  @moduledoc """
  The public paper reader's layout may now paint the Studio Beta block editor in
  place, so it carries that editor's browser half: the shell stylesheet, the
  custom-element bundles and the LiveView hooks — every one of them the SAME
  asset `root.html.heex` loads, never a reader-local copy.

  This pins the two halves of that contract:

    * GATING — the bootstrap inspects the server-authorized Edit-toggle hook in
      the static LiveView HTML. Anonymous/read-only pages create no editor asset
      elements and retain the zero-editor-fetch path.
    * REGISTRATION ORDER — an editable page awaits CSS, custom elements and the
      hooks asset before folding `window.BarkparkPaperEditorHooks` into
      PaperHooks and constructing the one public LiveSocket.

  Rendered through the layout function directly, so the assertions are about the
  layout and cannot be moved by anything the LiveView does.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  @eager_editor_tags [
    ~s(href="/assets/bp-paper-editor-shell.css"),
    ~s(src="/assets/bp-paper-editor.bundle.js"),
    ~s(src="/assets/bp-media-picker.js"),
    ~s(src="/assets/bp-reference-picker.js"),
    ~s(src="/assets/bp-rich-text-editor.js"),
    ~s(src="/assets/bp-paper-editor-hooks.js")
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

  test "the root layout never emits eager editor asset tags" do
    html = render_layout(%{})

    for tag <- @eager_editor_tags do
      refute html =~ tag, "the runtime authorization gate must own #{tag}"
    end

    assert html =~ ~s(src="/assets/phoenix.js")
    assert html =~ ~s(src="/assets/bp-paper-mermaid.js")
  end

  test "the loader uses the server-authorized edit hook as its runtime gate" do
    html = render_layout(%{})

    assert html =~ ~s(data-bp-paper-editor-loader)
    assert html =~ "document.querySelector('[phx-hook=\"BarkparkPaperEditToggle\"]')"
    assert html =~ "window.BP_PAPER_EDITOR_NO_INJECT = true"

    for asset <- [
          "/assets/bp-paper-editor-shell.css",
          "/assets/bp-paper-editor.bundle.js",
          "/assets/bp-media-picker.js",
          "/assets/bp-reference-picker.js",
          "/assets/bp-rich-text-editor.js",
          "/assets/bp-paper-editor-hooks.js"
        ] do
      assert html =~ asset
    end
  end

  test "editor assets finish before hook registration and LiveSocket construction" do
    html = render_layout(%{})

    [load, connect] =
      for needle <- [
            "await ensurePaperEditorAssets();",
            "new LiveView.LiveSocket("
          ] do
        idx = :binary.match(html, needle)
        refute idx == :nomatch, "reader layout no longer contains #{needle}"
        elem(idx, 0)
      end

    assert load < connect, "static editor assets must finish before the LiveSocket connects"

    assert html =~
             "paperEditorAssetsReady = loadPaperEditorAssets().then(installPaperEditorDefinitions);"

    assert html =~ "Object.assign(PaperHooks, window.BarkparkPaperEditorHooks);"
    assert html =~ "script.async = false;"

    assert length(:binary.matches(html, "new LiveView.LiveSocket(")) == 1,
           "the asset loader must not create a second public LiveSocket"
  end

  test "an editor dependency failure disables Edit and gives a visible recovery instruction" do
    html = render_layout(%{})

    assert html =~ "connectPublicLiveView().catch(showPaperEditorLoadError);"
    assert html =~ ~s(toggle.disabled = true;)
    assert html =~ "message.setAttribute(\"role\", \"alert\")"
    assert html =~ "Your paper is still readable; reload to try editing again."
  end

  test "the merge is guarded, so a missing asset cannot break the reader's hooks" do
    assert render_layout(%{}) =~
             "Object.assign(PaperHooks, window.BarkparkPaperEditorHooks || {});"
  end
end
