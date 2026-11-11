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
