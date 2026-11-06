defmodule Barkpark.Content.TypeCensusCacheTest do
  @moduledoc """
  The type census behind the Studio desk's …Rest tier is kept between document
  writes. These tests pin when a kept census may answer: never after a
  document of its workspace was announced, never for another workspace, and
  never for a grant-scoped caller.

  Synthetic fixtures only.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.{Analytics, Document, TypeCensusCache}
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures

  @ds "production"

  setup do
    previous = Application.get_env(:barkpark, :type_census_cache)
    Application.put_env(:barkpark, :type_census_cache, true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:barkpark, :type_census_cache)
        value -> Application.put_env(:barkpark, :type_census_cache, value)
      end
    end)

    ws = TenancyFixtures.create_workspace!()
    {:ok, _} = TenancyFixtures.create_document_in!(ws, nil, "census_note", %{}, @ds)
    %{ws: ws}
  end

  # A row written straight to the table: no announcement reaches the cache.
  defp insert_silently!(ws, type) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Document{
      doc_id: "#{type}-silent-#{n}",
      type: type,
      dataset: @ds,
      title: "silent #{n}",
      status: "published",
      content: %{},
      rev: "r#{n}",
      workspace_id: ws.id
    })
  end

  # Let the cache process handle every announcement already in its mailbox.
  defp settle, do: :sys.get_state(TypeCensusCache)

  defp total(rows, type), do: Enum.find_value(rows, 0, &(&1.type == type and &1.total))

  test "a second census between writes answers from the cache", %{ws: ws} do
    assert total(Analytics.type_census(@ds, workspace_id: ws.id), "census_note") == 1

    insert_silently!(ws, "census_note")

    assert total(Analytics.type_census(@ds, workspace_id: ws.id), "census_note") == 1
  end

  test "an announced write in the workspace is counted on the next census", %{ws: ws} do
    assert total(Analytics.type_census(@ds, workspace_id: ws.id), "census_note") == 1

    {:ok, _} = TenancyFixtures.create_document_in!(ws, nil, "census_note", %{}, @ds)
    settle()

    assert total(Analytics.type_census(@ds, workspace_id: ws.id), "census_note") == 2
  end

  test "a write announced in another workspace keeps the entry", %{ws: ws} do
    other = TenancyFixtures.create_workspace!()
    assert total(Analytics.type_census(@ds, workspace_id: ws.id), "census_note") == 1

    insert_silently!(ws, "census_note")
    {:ok, _} = TenancyFixtures.create_document_in!(other, nil, "census_note", %{}, @ds)
    settle()

    assert total(Analytics.type_census(@ds, workspace_id: ws.id), "census_note") == 1
    assert total(Analytics.type_census(@ds, workspace_id: other.id), "census_note") == 1
  end

  test "a grant-scoped census or one without a workspace is never kept", %{ws: ws} do
    for {ws_id, opts} <- [{ws.id, [grant_scoped: true]}, {nil, []}] do
      assert TypeCensusCache.fetch(ws_id, @ds, opts, fn -> [:first] end) == [:first]
      assert TypeCensusCache.fetch(ws_id, @ds, opts, fn -> [:second] end) == [:second]
    end

    # The same workspace without the flag keeps its entry.
    assert TypeCensusCache.fetch(ws.id, @ds, [], fn -> [:first] end) == [:first]
    assert TypeCensusCache.fetch(ws.id, @ds, [], fn -> [:second] end) == [:first]
  end

  test "off by config, every census reads the table", %{ws: ws} do
    Application.put_env(:barkpark, :type_census_cache, false)
    assert total(Analytics.type_census(@ds, workspace_id: ws.id), "census_note") == 1

    insert_silently!(ws, "census_note")

    assert total(Analytics.type_census(@ds, workspace_id: ws.id), "census_note") == 2
  end
end
