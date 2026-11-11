defmodule BarkparkWeb.Studio.DeskEditorPaneTest do
  @moduledoc """
  The frame of the desk's edit pane (`EditorHost.pane/2`): the names the
  TanStack Studio's specs know a document pane by (`section.pane.doc`, its
  `.pane-header`, `.pane-body`, `.doc-form`), and a header row of its own
  for the close link, so the link covers none of the Studio's toolbar.

  Measured in a browser first (1440 px and 500 px): the close link sits in
  the header row and overlaps no button; at 500 px it reads as Back.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "pane_frame_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Pane frame #{n}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "pf-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Framed"}, @dataset)
    {:ok, _} = Content.publish_document(id, type, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    raw = "desk-pane-frame-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-pane", @dataset, ["read", "write", "admin"], ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, view, _html} = live(conn, "#{base}/#{type};#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)

    {:ok, view: view, base: base, type: type}
  end

  # Poll for a value the view reaches after a message, never right after a send.
  defp eventually(fun) do
    Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)
  end

  test "the edit pane is a document pane by the names the specs use", %{view: view} do
    assert has_element?(view, "section.pane.doc[data-pane-editing]")
    assert has_element?(view, "section.pane.doc[data-pane-editing] > .pane-body.doc-form")
    assert has_element?(view, "section.pane.doc > .pane-body.doc-form #editor-form")
  end

  # Measured in a browser on guerrilla: "Open another" dimmed the edit pane
  # only (the backdrop was the pane's own box, 800 px wide, in a 1440 px
  # window) and the list pane to its left stayed clickable. The Studio's
  # `.modal-backdrop` is `position: absolute; inset: 0` and means the page,
  # so the desk's sheet must not position the edit pane. With the rule gone
  # the backdrop is the whole window, the list under it. LiveViewTest has no
  # layout, so this reads the dialog's markup and the sheet.
  test "a dialog the Studio draws in the edit pane is not boxed in by the pane", %{view: view} do
    view
    |> element(~s([data-pane-editing] [data-test-id="open-secondary-picker"]))
    |> render_click()

    assert has_element?(view, "section[data-pane-editing] .modal-backdrop [role=dialog]")

    css = rendered_to_string(BarkparkWeb.Studio.Desk.Style.sheet(%{}))
    rules = Regex.scan(~r/([^{}]*\.dk-edit\b[^{}]*)\{([^}]*)\}/, css)
    assert rules != [], "the sheet has no .dk-edit rule to read"

    for [_, selector, body] <- rules, String.match?(selector, ~r/\.dk-edit\s*$/) do
      refute body =~ ~r/position:\s*(relative|absolute|fixed|sticky)/,
             "#{String.trim(selector)} is positioned: the Studio's backdrop covers the pane, not the page"
    end
  end

  test "the close link is in the pane's own header row, above the editor", ctx do
    pane = "section[data-pane-editing]"
    close = "#{pane} > .pane-header > a.dk-close"

    assert has_element?(ctx.view, "#{pane} > .pane-header > .pane-header-title", "Framed")
    assert has_element?(ctx.view, ~s(#{close}[href="#{ctx.base}/#{ctx.type}"]))
    # Not inside the form region, where the Studio's toolbar is.
    refute has_element?(ctx.view, "#{pane} .pane-body a.dk-close")

    ctx.view |> element(close) |> render_click()
    assert_patch(ctx.view, "#{ctx.base}/#{ctx.type}")
  end
end
