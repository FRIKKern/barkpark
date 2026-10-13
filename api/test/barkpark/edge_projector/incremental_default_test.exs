defmodule Barkpark.EdgeProjector.IncrementalDefaultTest do
  @moduledoc """
  task-6e2552cdeb223fa2: incremental edge projection is the default, and
  `EDGE_PROJECTOR_INCREMENTAL=0` turns it off.

  With it on, a save of a published row enqueues a per-document upsert and a
  draft save enqueues nothing (the table is the published graph). With it off,
  every save enqueues the type-wide rebuild, as before.
  """
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.EdgeProjector.{Lifecycle, ProjectorWorker, Settings}

  @dataset "incremental_default_test"

  setup do
    prev = System.get_env("EDGE_PROJECTOR_INCREMENTAL")
    System.delete_env("EDGE_PROJECTOR_INCREMENTAL")

    on_exit(fn ->
      if prev,
        do: System.put_env("EDGE_PROJECTOR_INCREMENTAL", prev),
        else: System.delete_env("EDGE_PROJECTOR_INCREMENTAL")
    end)

    :ok
  end

  defp save(doc_id) do
    Lifecycle.enqueue_rebuild(%{
      event: :after_save,
      doc: %{doc_id: doc_id, type: "inc_post", dataset: @dataset},
      dataset: @dataset,
      ctx: %{source: :api}
    })
  end

  defp edge_jobs, do: all_enqueued(worker: ProjectorWorker) |> Enum.map(& &1.args)

  defp scoped(jobs), do: Enum.filter(jobs, &(&1["scope"] == @dataset))

  test "the default is on" do
    assert Settings.get().incremental_project == true
  end

  test "EDGE_PROJECTOR_INCREMENTAL=0 turns it off" do
    System.put_env("EDGE_PROJECTOR_INCREMENTAL", "0")
    assert Settings.get().incremental_project == false
  end

  test "on: a published save upserts one document, a draft save enqueues nothing" do
    save("drafts.inc-1")
    assert scoped(edge_jobs()) == []

    save("inc-1")
    assert [%{"op" => "upsert", "_id" => "inc-1"}] = scoped(edge_jobs())
  end

  test "off: a save enqueues the type-wide rebuild" do
    System.put_env("EDGE_PROJECTOR_INCREMENTAL", "0")
    save("drafts.inc-2")
    assert [%{"op" => "rebuild", "types" => ["inc_post"]}] = scoped(edge_jobs())
  end
end
