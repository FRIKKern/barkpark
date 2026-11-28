defmodule BarkparkWeb.Studio.DeskHeaderTitleTest do
  @moduledoc """
  A document pane's header says one name from its first frame on
  (task-32a5956065c81200). The list row names an unnamed document apart from
  the others ("Untitled <type> · <id tail>"); its editor's header says
  "Untitled", as the Studio's does. The row carries the header's name for
  the frame `bp-desk.js` draws at the click (`data-desk-title`), and a
  read-only document pane is named by the same rule (`DocTitle.header/2`),
  not by its id.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content

  @dataset "production"
  @type_name "desk_header_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk header notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    n = System.unique_integer([:positive])
    unnamed = "dhn-u-#{n}"
    named = "dhn-n-#{n}"

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => unnamed, "content" => %{"summary" => "No title yet"}},
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => named, "title" => "Named note", "content" => %{}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-header-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "desk-header", @dataset, ["read", "write", "admin"], ws.id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     unnamed: unnamed,
     named: named}
  end

  defp row(c, id),
    do: ~s([data-pane-index="1"] a[data-desk-row][href="#{c.base}/#{@type_name};#{id}"])

  test "an unnamed document's row carries the name its editor's header gives it", c do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{@type_name}")
    render_async(view, 5_000)

    # The row tells it apart; the header, and so the frame, says "Untitled".
    assert has_element?(view, row(c, c.unnamed), "Untitled")
    assert has_element?(view, row(c, c.unnamed) <> ~s([data-desk-title="Untitled"]))
    assert has_element?(view, row(c, c.named) <> ~s([data-desk-title="Named note"]))

    view |> element(row(c, c.unnamed)) |> render_click()
    render_async(view, 5_000)

    assert has_element?(view, ~s([data-pane-editing] .pane-header-title), "Untitled")
    refute has_element?(view, ~s([data-pane-editing] .pane-header-title), c.unnamed)
  end

  test "a read-only document pane is named as its editor would name it, not by its id", c do
    chain = "#{@type_name};#{c.unnamed};#{c.named},type=#{@type_name},parentRefPath=more"
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{chain}")
    render_async(view, 5_000)

    pane = ~s(#desk-panes > [data-pane-index="2"])
    assert has_element?(view, pane <> " .pane-header-title", "Untitled")
    refute has_element?(view, pane <> " .pane-header-title", c.unnamed)
  end
end
