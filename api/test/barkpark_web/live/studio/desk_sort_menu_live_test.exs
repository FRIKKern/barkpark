defmodule BarkparkWeb.Studio.DeskSortMenuLiveTest do
  @moduledoc """
  task-fa57815041bead3d: the desk list renders a sort menu from the schema's
  `desk.sortOrderings`, opens in the default order, and `select-sort` reorders
  that list. A type without sortOrderings renders no menu. Synthetic fixtures.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "shelf",
          "title" => "Shelf",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "rank", "title" => "Rank", "type" => "number"}
          ],
          "desk" => %{
            "sortOrderings" => [
              %{
                "name" => "manual",
                "title" => "Manual order",
                "by" => [%{"field" => "rank", "direction" => "asc"}]
              }
            ]
          }
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "plainshelf",
          "title" => "Plain shelf",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    for {id, title, rank} <- [{"s-a", "Alpha", 3}, {"s-b", "Bravo", 1}, {"s-c", "Charlie", 2}] do
      {:ok, _} =
        Content.create_document(
          "shelf",
          %{"doc_id" => id, "title" => title, "content" => %{"rank" => rank}},
          @dataset
        )

      Process.sleep(10)
    end

    {:ok, _} =
      Content.create_document("plainshelf", %{"doc_id" => "ps-1", "title" => "Lone"}, @dataset)

    :ok
  end

  defp row_order(html, ids) do
    ids
    |> Enum.map(fn id -> {id, :binary.match(html, ~s(id="doc-#{id}"))} end)
    |> Enum.reject(fn {_id, m} -> m == :nomatch end)
    |> Enum.sort_by(fn {_id, {pos, _}} -> pos end)
    |> Enum.map(&elem(&1, 0))
  end

  test "the list opens in the default order with a sort menu, and a pick reorders it",
       %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/shelf"))

    assert html =~ ~s(data-test-id="desk-sort")
    assert html =~ "Manual order"
    assert row_order(html, ["s-a", "s-b", "s-c"]) == ["s-c", "s-b", "s-a"]

    html =
      view
      |> element(~s([data-test-id="desk-sort"]))
      |> render_change(%{"type" => "shelf", "sort" => "manual"})

    assert row_order(html, ["s-a", "s-b", "s-c"]) == ["s-b", "s-c", "s-a"]
    assert html =~ ~r/<option[^>]*value="manual"[^>]*selected/

    html =
      view
      |> element(~s([data-test-id="desk-sort"]))
      |> render_change(%{"type" => "shelf", "sort" => ""})

    assert row_order(html, ["s-a", "s-b", "s-c"]) == ["s-c", "s-b", "s-a"]
  end

  test "a type without sortOrderings renders no sort menu", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/plainshelf"))
    assert html =~ ~s(id="doc-ps-1")
    refute html =~ ~s(data-test-id="desk-sort")
  end
end
