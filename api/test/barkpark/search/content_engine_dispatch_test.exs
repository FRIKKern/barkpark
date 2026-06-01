defmodule Barkpark.Search.ContentEngineDispatchTest do
  @moduledoc """
  Proves the engine-neutral SEAM is wired into PROD's actual document-search
  entry point, `Barkpark.Content.search_documents/3`.

  PROD's main has no `QueryPipeline`/`SurfaceConfig` scaffolding — the search
  surface is `Content.search_documents/3` directly (used by
  `BarkparkWeb.SearchController`). The seam was layered in there: the function
  resolves the retriever for the request's engine (default `"postgres"`) and
  dispatches.

    * `engine: "fake"` (a registered plugin engine) routes through the
      registered retriever — sentinel hit appears, NOT a Postgres result.
    * the DEFAULT (no engine) and `engine: "postgres"` route through PROD's
      unchanged Postgres search (`search_documents_postgres/3`), which the
      existing search suite (synonyms, sanitizer, intelligence) covers.

  The indirection is purely additive: with no surface opting into another
  engine, behaviour is byte-identical to the pre-seam direct call.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Search.{DocumentsRetriever, Retrievers}

  defmodule FakeRetriever do
    @behaviour Barkpark.Search.Retriever
    @impl true
    # Sentinel: a doc no Postgres seed could produce, total 1. Returns the
    # {hits, total} shape Content.search_documents/3 hands back.
    def search(_scope, _parsed, _config, _opts),
      do: {[%{doc_id: "FAKE-ENGINE-HIT", title: "Fake Engine Hit", content: %{}}], 1}
  end

  setup do
    prior = Application.get_env(:barkpark, :search_retrievers)
    Application.put_env(:barkpark, :search_retrievers, %{"fake" => FakeRetriever})

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, :search_retrievers, prior)
      else
        Application.delete_env(:barkpark, :search_retrievers)
      end
    end)

    :ok
  end

  test "resolve/1: default + postgres stay on the Postgres DocumentsRetriever" do
    assert Retrievers.resolve(%{}) == DocumentsRetriever
    assert Retrievers.resolve(%{"engine" => "postgres"}) == DocumentsRetriever
  end

  test "search_documents/3 with engine \"fake\" routes through the registered retriever" do
    {hits, total} =
      Content.search_documents("phoenix", "engine-dispatch", engine: "fake", limit: 10)

    assert total == 1
    assert Enum.map(hits, & &1.doc_id) == ["FAKE-ENGINE-HIT"]
  end

  test "search_documents/3 default engine runs PROD's Postgres search (no sentinel)" do
    {:ok, _doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "eng-default-1", "title" => "Phoenix Rising"},
        "engine-default"
      )

    {:ok, _pub} = Content.publish_document("eng-default-1", "post", "engine-default")

    # Default (no :engine) → Postgres. A real Postgres hit, never the sentinel.
    {hits, total} = Content.search_documents("phoenix", "engine-default", limit: 10)

    assert total >= 1
    refute "FAKE-ENGINE-HIT" in Enum.map(hits, & &1.doc_id)
    assert Enum.any?(hits, &(&1.doc_id == "eng-default-1"))
  end
end
