defmodule Barkpark.Search.PipelineEngineDispatchTest do
  @moduledoc """
  Proves the engine-neutral SEAM is actually wired into the pipeline: a
  `documents` surface whose config carries `engine: "fake"` must route through
  the registered fake retriever (sentinel hit appears), NOT through the default
  Postgres `DocumentsRetriever`. The default-engine path is covered (and held
  byte-identical) by query_pipeline_test.exs.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Search.{QueryPipeline, SurfaceConfigs}

  defmodule FakeRetriever do
    @behaviour Barkpark.Search.Retriever
    @impl true
    # Sentinel: a doc_id no Postgres seed could produce, total 1. Carries the
    # fields the downstream highlighter reads (title/content) so the full
    # pipeline runs end to end through the fake engine.
    def search(_scope, _parsed, _config, _opts),
      do: {[%{doc_id: "FAKE-ENGINE-HIT", title: "Fake Engine Hit", content: %{}}], 1}
  end

  setup do
    prior = Application.get_env(:barkpark, :search_retrievers)
    Application.put_env(:barkpark, :search_retrievers, %{"fake" => FakeRetriever})

    # Persist a documents surface config carrying engine "fake" for this scope.
    {:ok, _} = SurfaceConfigs.upsert("documents", "engine-dispatch", %{"engine" => "fake"})

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, :search_retrievers, prior)
      else
        Application.delete_env(:barkpark, :search_retrievers)
      end
    end)

    :ok
  end

  test "documents search with engine \"fake\" routes through the registered retriever" do
    context = %{query: "phoenix", filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search("documents", "engine-dispatch", context,
               perspective: :published,
               limit: 10
             )

    assert result.total == 1
    assert Enum.map(result.hits, & &1.doc_id) == ["FAKE-ENGINE-HIT"]
  end
end
