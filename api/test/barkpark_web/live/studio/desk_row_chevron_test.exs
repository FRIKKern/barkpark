defmodule BarkparkWeb.Studio.DeskRowChevronTest do
  @moduledoc """
  A row that opens a pane carries one chevron, Sanity's thin `chevron-right`
  (`Barkpark.DeskIcons`, the TanStack Studio's ChevronRight: a 1.2 stroke;
  LOOKS A4, main 11-13), hidden from the accessibility tree. The same glyph at every depth: it is drawn by the one
  row template every pane uses. (singleton.spec.ts: the row's `svg` is its
  chevron.)
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    for {name, title, singleton} <- [
          {"drc_note", "Chevron notes", false},
          {"drc_prefs", "Chevron prefs", true}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => title,
            "singleton" => singleton,
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          @dataset
        )
    end

    {:ok, _} =
      Content.create_document("drc_prefs", %{"doc_id" => "drc_prefs", "title" => "P"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "drc-token-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "drc", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"}
  end

  defp chevron(view, pane, href) do
    view
    |> element(
      ~s([data-pane-index="#{pane}"] a[data-desk-row][href="#{href}"] .pane-item-chevron)
    )
    |> render()
  end

  defp sanity_chevron?(html) do
    html =~ ~s(aria-hidden="true") and length(Regex.scan(~r/<svg/, html)) == 1 and
      html =~ ~s(d="M10 8L14.5 12.5L10 17") and html =~ ~s(stroke-width="1.2") and
      not (html =~ "›")
  end

  test "every chevron is Sanity's thin svg, at every depth, and no text glyph", %{
    conn: conn,
    base: base
  } do
    {:ok, view, _html} = live(conn, "#{base}/content-types")
    render_async(view, 5_000)

    # The root: a menu, and a singleton's document. (Only rows this test's own
    # data declares: the root's other rows depend on the dataset.)
    for href <- ["#{base}/content-types", "#{base}/drc_prefs"] do
      assert sanity_chevron?(chevron(view, 0, href)), href
    end

    # A menu one pane in, a row that opens a type's list: the same glyph.
    assert sanity_chevron?(chevron(view, 1, "#{base}/content-types;drc_note"))

    refute view |> element("#desk-panes") |> render() =~ "›"
  end
end
