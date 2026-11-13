defmodule BarkparkWeb.Studio.DeskHeaderTest do
  @moduledoc """
  The desk's pane headers and root, as the TanStack Studio's (LOOKS A3,
  2026-11-13): no line between plain type rows (only declared dividers), and
  Sanity's own Add, Ellipsis and Search glyphs in a list pane.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "dhd_post"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Header posts",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "dhd-token-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "dhd",
        @dataset,
        ["read", "write", "admin"],
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"}
  end

  test "the root draws no line between its groups of plain rows", %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, base)
    root = view |> element(~s([data-pane-index="0"])) |> render()

    # Barkpark.Structure joins its groups with positional dividers; the
    # desk's root has more than one group here, and no line between them.
    assert Barkpark.Structure.build(@dataset).items
           |> Enum.any?(&match?(%{type: :divider, id: "div-" <> _}, &1))

    refute root =~ "pane-divider"
  end

  test "a list pane's header and search carry Sanity's glyphs", %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, "#{base}/#{@type_name}")
    render_async(view, 5_000)
    pane = view |> element(~s([data-pane-index="1"])) |> render()

    assert pane =~ ~s(data-desk-glyph="add")
    assert pane =~ ~s(data-desk-glyph="ellipsis-horizontal")
    assert pane =~ ~r/class="search-icon"[^>]*>\s*<svg[^>]*data-desk-glyph="search"/
  end
end
