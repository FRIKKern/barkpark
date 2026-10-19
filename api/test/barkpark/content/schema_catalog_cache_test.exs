defmodule Barkpark.Content.SchemaCatalogCacheTest do
  @moduledoc """
  task-cca3c6d48e57097e: the inlined schema catalog is kept across requests
  per schema version, so a Studio document open and `GET /v1/structure` stop
  rebuilding it. These tests pin what the cache may never do: answer after a
  schema change, answer another workspace, or keep a grant-scoped or
  in-transaction read.

  Synthetic fixtures only.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, QueryCounter, Repo}
  alias Barkpark.Content.{SchemaCatalogCache, WriteScope}
  alias Barkpark.TenancyFixtures

  @ds "production"

  setup do
    previous = Application.get_env(:barkpark, :schema_catalog_cache)
    Application.put_env(:barkpark, :schema_catalog_cache, true)
    SchemaCatalogCache.init_cache()
    SchemaCatalogCache.invalidate()

    on_exit(fn ->
      SchemaCatalogCache.invalidate()

      case previous do
        nil -> Application.delete_env(:barkpark, :schema_catalog_cache)
        value -> Application.put_env(:barkpark, :schema_catalog_cache, value)
      end
    end)

    ws_a = TenancyFixtures.create_workspace!()
    ws_b = TenancyFixtures.create_workspace!()

    put_schemas!(ws_a, "cat_a")
    put_schemas!(ws_b, "cat_b")

    WriteScope.reset_request_memo()
    %{ws_a: ws_a, ws_b: ws_b}
  end

  # A document type that names an object type, so the catalog read inlines.
  defp put_schemas!(ws, prefix, extra_field \\ nil) do
    scope = [workspace_id: ws.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "#{prefix}_seo",
          "title" => "Seo",
          "kind" => "object",
          "fields" => [%{"name" => "metaTitle", "type" => "string"}]
        },
        @ds,
        scope
      )

    fields =
      [
        %{"name" => "title", "type" => "string"},
        %{"name" => "seo", "type" => "#{prefix}_seo"}
      ] ++ List.wrap(extra_field)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "#{prefix}_doc", "title" => "Doc", "fields" => fields},
        @ds,
        scope
      )
  end

  defp catalog(ws, extra \\ []) do
    # A fresh request each time: the per-request memo must not be what answers.
    WriteScope.reset_request_memo()
    Content.list_schemas(@ds, [include_global: true, workspace_id: ws.id] ++ extra)
  end

  defp names(catalog), do: catalog |> Enum.map(& &1.name) |> Enum.sort()

  defp field_names(catalog, name) do
    catalog |> Enum.find(&(&1.name == name)) |> Map.fetch!(:fields) |> Enum.map(& &1["name"])
  end

  defp schema_reads(fun) do
    {result, count} = QueryCounter.count_source(fun, "schema_definitions")
    {result, count}
  end

  test "a repeat read across requests is answered from the cache", %{ws_a: ws_a} do
    {first, cold} = schema_reads(fn -> catalog(ws_a) end)
    {second, warm} = schema_reads(fn -> catalog(ws_a) end)

    assert second == first
    assert "cat_a_doc" in names(first)

    # The named type is inlined in the cached copy too.
    seo = first |> Enum.find(&(&1.name == "cat_a_doc")) |> Map.fetch!(:fields) |> Enum.at(1)
    assert seo["type"] == "composite"

    # Warm: the version read only. Cold: the catalog, plus its named types.
    assert warm == 1, "a warm catalog read ran #{warm} schema_definitions statements"
    assert cold > warm
  end

  test "a schema write is seen by the next read", %{ws_a: ws_a} do
    assert field_names(catalog(ws_a), "cat_a_doc") == ["title", "seo"]

    put_schemas!(ws_a, "cat_a", %{"name" => "subtitle", "type" => "string"})

    assert field_names(catalog(ws_a), "cat_a_doc") == ["title", "seo", "subtitle"]
  end

  test "a deleted schema leaves the catalog", %{ws_a: ws_a} do
    assert "cat_a_doc" in names(catalog(ws_a))

    {:ok, _} = Content.delete_schema("cat_a_doc", @ds, workspace_id: ws_a.id)

    refute "cat_a_doc" in names(catalog(ws_a))
  end

  test "one workspace never reads another's catalog", %{ws_a: ws_a, ws_b: ws_b} do
    a = names(catalog(ws_a))
    b = names(catalog(ws_b))

    assert "cat_a_doc" in a
    refute "cat_b_doc" in a
    assert "cat_b_doc" in b
    refute "cat_a_doc" in b

    # Warm, in the other order.
    assert names(catalog(ws_b)) == b
    assert names(catalog(ws_a)) == a
  end

  test "a grant-scoped read is never kept", %{ws_a: ws_a} do
    SchemaCatalogCache.invalidate()

    {_, reads} = schema_reads(fn -> catalog(ws_a, grant_scoped: true, caller_context: nil) end)
    {_, again} = schema_reads(fn -> catalog(ws_a, grant_scoped: true, caller_context: nil) end)

    # Built both times, never stored.
    assert again == reads
    assert :ets.tab2list(:barkpark_schema_catalog_cache) == []
  end

  test "a read inside a transaction is not kept", %{ws_a: ws_a} do
    SchemaCatalogCache.invalidate()

    {:ok, inside} =
      Repo.transaction(fn ->
        put_schemas!(ws_a, "cat_a", %{"name" => "uncommitted", "type" => "string"})
        catalog(ws_a)
      end)

    assert "uncommitted" in field_names(inside, "cat_a_doc")
    assert :ets.tab2list(:barkpark_schema_catalog_cache) == []
  end

  test "the cache is a pass-through when it is off", %{ws_a: ws_a} do
    Application.put_env(:barkpark, :schema_catalog_cache, false)

    _ = catalog(ws_a)
    {_, reads} = schema_reads(fn -> catalog(ws_a) end)

    assert reads > 1
    assert :ets.tab2list(:barkpark_schema_catalog_cache) == []
  end
end
