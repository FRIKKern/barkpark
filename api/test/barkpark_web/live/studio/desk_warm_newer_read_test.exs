defmodule BarkparkWeb.Studio.DeskWarmNewerReadTest do
  @moduledoc """
  A list's page read ahead of it (a hover's, or the first render's
  `ListFirst` hand-off) is kept for 30 s and fills the pane when it opens.
  It never takes the place of a newer read of a pane that already shows
  rows: a search or a "more" read out when the page re-draws (a hover
  anywhere re-draws it) lands as read.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Rows

  @dataset "production"
  @type_name "dwn_note"
  @list ~s([data-pane-index="1"])

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Newer notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "dwn-token-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "dwn", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    on_exit(fn -> Application.delete_env(:barkpark, PaneComponent) end)

    {:ok, conn: conn, base: base}
  end

  defp seed(titles) do
    for {title, i} <- Enum.with_index(titles) do
      {:ok, _} =
        Content.create_document(
          @type_name,
          %{"doc_id" => "dwn-#{i}", "title" => title},
          @dataset
        )
    end
  end

  # Reads matching `held?` say so and wait to be let go; the rest read as ever.
  defp hold(held?) do
    test = self()

    Application.put_env(:barkpark, PaneComponent,
      reader: fn pane, node, dataset, scope, title ->
        if held?.(pane) do
          send(test, {:reading, self()})
          receive do: (:go -> :ok)
        end

        PaneComponent.read(pane, node, dataset, scope, title)
      end
    )
  end

  # The list opened from a hover's read of it: that read is kept.
  defp open_warm(conn, base) do
    {:ok, view, _html} = live(conn, base)
    render_async(view, 5_000)
    list = "#{base}/#{@type_name}"
    view |> element("#desk-panes") |> render_hook("warm", %{"href" => list})
    render_async(view, 5_000)
    render_patch(view, list)
    render_async(view, 5_000)
    view
  end

  # A hover on a row: the page re-draws, its panes with it.
  defp hover_row(view, base, i) do
    href = "#{base}/#{@type_name};dwn-#{i}"
    view |> element("#desk-panes") |> render_hook("warm", %{"href" => href})
  end

  defp rows(view) do
    view
    |> element(@list <> " .pane-body")
    |> render()
    |> then(&Regex.scan(~r/<span class="dk-row-title">([^<]+?)</, &1))
    |> Enum.map(fn [_, title] -> title end)
  end

  test "a list search out when the page re-draws shows its hits, not the page read ahead", %{
    conn: conn,
    base: base
  } do
    seed(["Alpha note", "Beta note", "Zebra note"])
    view = open_warm(conn, base)
    assert Enum.sort(rows(view)) == ["Alpha note", "Beta note", "Zebra note"]

    hold(&is_binary(&1[:search]))
    view |> element(@list <> " .dk-list-search form") |> render_change(%{"q" => "zebra"})
    assert_receive {:reading, search}, 5_000

    hover_row(view, base, 0)
    send(search, :go)
    render_async(view, 5_000)

    assert rows(view) == ["Zebra note"]
  end

  test "a \"more\" read out when the page re-draws grows the list, not back to the page read ahead",
       %{conn: conn, base: base} do
    seed(for n <- 1..(Rows.page() + 20), do: "Note #{String.pad_leading("#{n}", 3, "0")}")
    view = open_warm(conn, base)
    assert length(rows(view)) == Rows.page()

    hold(&(&1[:kind] == :list and &1.query.limit > Rows.page()))
    view |> element(@list <> " [phx-viewport-bottom]") |> render_hook("more", %{})
    assert_receive {:reading, more}, 5_000

    hover_row(view, base, 0)
    send(more, :go)
    render_async(view, 5_000)

    assert length(rows(view)) == Rows.page() + 20
  end
end
