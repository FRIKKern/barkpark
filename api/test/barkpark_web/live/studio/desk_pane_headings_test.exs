defmodule BarkparkWeb.Studio.DeskPaneHeadingsTest do
  @moduledoc """
  Every desk pane is named by a level-2 heading, so a screen reader's
  heading keys go pane to pane. Feel walk 2026-11-13, Chrome's accessibility
  tree of each pane kind: each pane was a labelled region, but its title was
  a plain span, and the desk had no heading at all.

  The root, a list and a read-only document draw their title in one place
  (`PaneComponent`); the document being edited draws its own (`EditorHost`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "pane_heading_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Heading notes #{n}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "ph-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Headed"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-heading-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-heading",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     type: type,
     id: id,
     n: n}
  end

  # Poll for a value the view reaches after a message, never right after a send.
  defp eventually(fun) do
    Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)
  end

  @heading ".pane-header > h2.pane-header-title"

  test "the root, a list and the document being edited are each named by a heading", ctx do
    {:ok, view, _html} = live(ctx.conn, "#{ctx.base}/#{ctx.type};#{ctx.id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)

    assert has_element?(view, ~s(#desk-panes > [data-pane-index="0"] ) <> @heading)

    assert has_element?(
             view,
             ~s(#desk-panes > [data-pane-index="1"] ) <> @heading,
             "Heading notes #{ctx.n}"
           )

    assert has_element?(view, "section[data-pane-editing] > " <> @heading, "Headed")
  end

  test "a heading sits in the header as the span did: no margin of its own" do
    css = BarkparkWeb.Studio.Desk.Style.sheet(%{}) |> rendered_to_string()
    assert css =~ ".dk h2.pane-header-title { margin: 0; }"
  end
end
