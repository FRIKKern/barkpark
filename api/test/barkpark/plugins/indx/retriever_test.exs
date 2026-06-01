defmodule Barkpark.Plugins.Indx.RetrieverTest do
  @moduledoc """
  `Barkpark.Plugins.Indx.Retriever` maps Indx `documentKey` search results
  back to authoritative Barkpark `%Document{}` structs and returns the same
  `{hits, total}` shape as `Barkpark.Search.DocumentsRetriever`.

  An injected fake client supplies the Indx search records + hydrated docs
  (the docs carry the embedded `_id` / `_type`); the retriever re-reads the
  real row from Postgres via `Content.get_document/3`. No live Indx needed.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Indx.{Indexer, Retriever}

  @ds "production"

  # Fake client: search returns the canned records; get_json returns the
  # canned hydrated docs. Set per-test via the process dictionary.
  defmodule FakeClient do
    def put(records, docs) do
      Process.put(:indx_fake_records, records)
      Process.put(:indx_fake_docs, docs)
    end

    def search(_ds, _text, _opts), do: {:ok, Process.get(:indx_fake_records, [])}
    def get_json(_ds, _keys, _opts), do: {:ok, Process.get(:indx_fake_docs, [])}
  end

  defp parsed(terms), do: %{terms: terms, phrases: [], prefixes: [], excludes: []}

  setup do
    scope = "production"
    # Point the live pointer at a dataset so the retriever proceeds past the
    # "no dataset" short-circuit. Clean up after.
    Indexer.swap(scope, %{new_dataset: "bp_production_v1", key_map: %{}})
    :ok
  end

  test "maps documentKey results back to a real Postgres Document, {hits, total}" do
    {:ok, %Document{} = doc} =
      Content.create_document("post", %{"doc_id" => "ix1", "title" => "Indexed Hit"}, @ds)

    FakeClient.put(
      [%{"documentKey" => 1, "score" => 220}],
      [%{"_id" => doc.doc_id, "_type" => "post"}]
    )

    {hits, total} =
      Retriever.search(@ds, parsed(["indexed"]), %{"engine" => "indx"}, client: FakeClient)

    assert total == 1
    assert [%Document{} = hit] = hits
    assert hit.doc_id == doc.doc_id
    assert hit.type == "post"
  end

  test "drops keys whose embedded _id/_type does not resolve in Postgres" do
    {:ok, %Document{} = doc} =
      Content.create_document("post", %{"doc_id" => "ix2", "title" => "Real"}, @ds)

    FakeClient.put(
      [%{"documentKey" => 1}, %{"documentKey" => 2}],
      [
        %{"_id" => doc.doc_id, "_type" => "post"},
        %{"_id" => "ghost-does-not-exist", "_type" => "post"}
      ]
    )

    {hits, total} =
      Retriever.search(@ds, parsed(["real"]), %{"engine" => "indx"}, client: FakeClient)

    assert total == 1
    assert [%Document{doc_id: hit_id}] = hits
    assert hit_id == doc.doc_id
  end

  test "returns {[], 0} for an empty query without calling Indx" do
    assert {[], 0} = Retriever.search(@ds, parsed([]), %{}, client: FakeClient)
  end

  test "returns {[], 0} when no live dataset is set for the scope" do
    assert {[], 0} =
             Retriever.search("never-indexed-scope", parsed(["x"]), %{}, client: FakeClient)
  end
end
