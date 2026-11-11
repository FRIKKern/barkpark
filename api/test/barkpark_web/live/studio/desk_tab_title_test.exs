defmodule BarkparkWeb.Studio.DeskTabTitleTest do
  @moduledoc """
  J01 J02 (ruling R23): the desk's tab reads "X | Barkpark", as the TanStack
  Studio's does. Every other page keeps "X · Barkpark".
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "dtt_post"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Title posts",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => "dtt-one", "title" => "Tab one"},
        @dataset
      )

    raw = "dtt-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "dtt", @dataset, ["read", "write", "admin"], ws.id)
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     studio: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"}
  end

  defp dead_title(html),
    do: hd(Regex.run(~r{<title[^>]*>([^<]*)</title>}, html, capture: :all_but_first))

  test "the desk's tab reads \"X | Barkpark\", in the first render and once connected", %{
    conn: conn,
    studio: studio
  } do
    {:ok, view, html} = live(conn, "#{studio}/_desk/#{@type_name}")
    render_async(view, 5_000)

    assert dead_title(html) =~ ~r/ \| Barkpark$/
    # The browser keeps the suffix for every later title (`live_title`).
    assert html =~ ~s(data-suffix=" | Barkpark")
    assert page_title(view) == "Title posts"
  end

  test "a Studio page that is not the desk keeps \" · Barkpark\"", %{conn: conn, studio: studio} do
    {:ok, view, html} = live(conn, studio)

    assert dead_title(html) =~ ~r/ · Barkpark$/
    assert html =~ ~s(data-suffix=" · Barkpark")
    assert render(view)
  end
end
