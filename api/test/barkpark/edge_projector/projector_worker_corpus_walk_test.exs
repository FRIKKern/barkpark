defmodule Barkpark.EdgeProjector.ProjectorWorkerCorpusWalkTest do
  @moduledoc """
  `ProjectorWorker`'s rebuild must WALK the scope corpus, and must never report
  a cut-short walk as a clean rebuild.

  THE DEFECT. The rebuild listed its corpus with
  `Content.list_documents(type, scope, limit: 1000)`. `list_documents/3` CLAMPS
  `:limit` to 1000 and hands back a bare list, so a scope with more than 1000
  published docs of a type was rebuilt from a 1000-row PREFIX.
  `Projector.rebuild_scope/3` deletes outbound edges only for the docs IN the
  corpus it is given — so every doc past the cap kept its pre-rebuild edges
  FOREVER, while the worker logged `rebuilt scope=… added=… deleted=…` as
  though nothing were missing. `rebuild_scope/3`'s own transaction budget is
  sized for "the largest measured corpus (~4k docs)", four times the cap, so
  the capped read was never the intended contract.

  These tests drive the documented `"content"` / `"projector"` test seams, so
  they assert the WORKER's contract with the walk (that it asks for one, and
  what it does with a `:cap`) without a 1000-document fixture. The walk itself
  is proved against a real 1001-row corpus in
  `Barkpark.Content.QueryCollectAllDocumentsTest`.
  """
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import ExUnit.CaptureLog

  alias Barkpark.EdgeProjector.ProjectorWorker

  # Content seam that reports an EXHAUSTED walk of two documents.
  defmodule FakeContentExhausted do
    @moduledoc false
    def collect_all_documents(_type, _scope, _opts) do
      {[%{"doc_id" => "walked-1"}, %{"doc_id" => "walked-2"}], nil}
    end
  end

  # Content seam that reports a walk STOPPED BY ITS BOUND — a prefix.
  defmodule FakeContentCapped do
    @moduledoc false
    def collect_all_documents(_type, _scope, _opts) do
      {[%{"doc_id" => "walked-1"}], :cap}
    end
  end

  # Content seam that records the opts the worker asked the walk for.
  defmodule FakeContentRecording do
    @moduledoc false
    def collect_all_documents(_type, _scope, opts) do
      send(:corpus_walk_probe, {:walk_opts, opts})
      {[], nil}
    end
  end

  defmodule FakeProjectorOk do
    @moduledoc false
    def rebuild_scope(_scope, docs, _opts), do: {:ok, %{added: length(docs), deleted: 0}}
  end

  # config/test.exs pins the logger at :warning, so the rebuild's INFO summary
  # is filtered before capture. Lift the level for the duration of the capture
  # so both arms of the log — the routine summary and the truncation warning —
  # are actually observable, then put it back.
  defp capture_at_info(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp rebuild(args) do
    perform_job(
      ProjectorWorker,
      Map.merge(
        %{
          "op" => "rebuild",
          "scope" => "corpus_walk_test",
          "types" => ["post"],
          "workspace_id" => Ecto.UUID.generate(),
          "projector" => "Barkpark.EdgeProjector.ProjectorWorkerCorpusWalkTest.FakeProjectorOk"
        },
        args
      )
    )
  end

  test "the rebuild asks for a bounded WALK, not a single capped page" do
    Process.register(self(), :corpus_walk_probe)

    assert :ok =
             rebuild(%{
               "content" =>
                 "Barkpark.EdgeProjector.ProjectorWorkerCorpusWalkTest.FakeContentRecording",
               "page_size" => 7,
               "max_pages" => 3
             })

    assert_received {:walk_opts, opts}

    assert Keyword.get(opts, :page_size) == 7
    assert Keyword.get(opts, :max_pages) == 3

    refute Keyword.has_key?(opts, :limit),
           "a bare :limit is the capped read this fix retires — the walk owns paging"
  end

  test "an exhausted walk logs a clean rebuild with truncated=false" do
    log =
      capture_at_info(fn ->
        assert :ok =
                 rebuild(%{
                   "content" =>
                     "Barkpark.EdgeProjector.ProjectorWorkerCorpusWalkTest.FakeContentExhausted"
                 })
      end)

    assert log =~ "rebuilt scope=corpus_walk_test"
    assert log =~ "docs=2"
    assert log =~ "truncated=false"
    refute log =~ "INCOMPLETE"
  end

  test "a walk stopped by its bound WARNS that the scope is incomplete" do
    log =
      capture_at_info(fn ->
        assert :ok =
                 rebuild(%{
                   "content" =>
                     "Barkpark.EdgeProjector.ProjectorWorkerCorpusWalkTest.FakeContentCapped"
                 })
      end)

    assert log =~ "corpus walk hit its page cap",
           "a prefix rebuild must SAY it is a prefix — the silent success is the defect"

    assert log =~ "INCOMPLETE"
    assert log =~ "keep their pre-rebuild edges"
    assert log =~ "truncated=true"
  end
end
