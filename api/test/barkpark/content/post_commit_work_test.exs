defmodule Barkpark.Content.PostCommitWorkTest do
  @moduledoc """
  task-6e2552cdeb223fa2: a write's post-commit work runs outside the request.

    * The webhook selection query runs on a supervised task after commit, not
      in the writing process.
    * A `visibility: :async` batch writes its published documents' graph edges
      on that task too; a `:sync` batch (the default) has them when it returns.
    * The task re-reads each document before projecting it, so an upsert that
      runs late projects the newest committed row, not the one it was queued
      with.

  `config/test.exs` runs post-commit work inline; this file turns the task on
  and waits for it, so nothing outlives a test.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.Document
  alias Barkpark.EdgeProjector.Lifecycle, as: EdgeLifecycle

  @dataset "post_commit_work_test"

  setup do
    Application.put_env(:barkpark, :post_commit_async, true)
    on_exit(fn -> Application.put_env(:barkpark, :post_commit_async, false) end)

    for schema <- [
          %{
            "name" => "pcw_author",
            "title" => "Author",
            "visibility" => "public",
            "fields" => []
          },
          %{
            "name" => "pcw_post",
            "title" => "Post",
            "visibility" => "public",
            "fields" => [%{"name" => "author", "type" => "reference", "refType" => "pcw_author"}]
          }
        ] do
      {:ok, _} = Content.upsert_schema(schema, @dataset)
    end

    me = self()
    handler = "post-commit-work-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:barkpark, :webhooks, :fan_out, :selected], [:barkpark, :repo, :query]],
      fn
        [_, :webhooks, :fan_out, :selected], _m, meta, _ ->
          send(me, {:selected, self(), meta[:doc_id]})

        [_, :repo, :query], _m, %{source: "content_edges", query: "INSERT" <> _}, _ ->
          send(me, {:edge_insert, self()})

        _, _, _, _ ->
          :ok
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp publish_direct(type, id, fields, opts) do
    mutation = %{
      "createOrReplace" => Map.merge(%{"_id" => id, "_type" => type, "title" => id}, fields),
      "publish" => true
    }

    {:ok, _} = Content.apply_mutations([mutation], @dataset, opts)
  end

  defp pk(id), do: Repo.get_by!(Document, doc_id: id, dataset: @dataset).id
  defp targets(from_pk), do: from_pk |> Content.list_outbound_edges() |> Enum.map(& &1.to_id)

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  test "the webhook selection runs on a task, not in the writing process" do
    publish_direct("pcw_author", "pcw-a1", %{}, [])

    assert_receive {:selected, pid, "pcw-a1"}, 2_000
    refute pid == self()
  end

  test "a sync batch has its edges when it returns" do
    publish_direct("pcw_author", "pcw-sync-author", %{}, [])
    publish_direct("pcw_post", "pcw-sync-post", %{"author" => "pcw-sync-author"}, [])

    assert pk("pcw-sync-author") in targets(pk("pcw-sync-post"))
  end

  test "an async batch writes its edges after it returns, on another process" do
    publish_direct("pcw_author", "pcw-async-author", %{}, [])
    flush_edge_inserts()

    publish_direct(
      "pcw_post",
      "pcw-async-post",
      %{"author" => "pcw-async-author"},
      visibility: :async
    )

    assert_receive {:edge_insert, pid}, 2_000
    refute pid == self()

    assert eventually(fn -> pk("pcw-async-author") in targets(pk("pcw-async-post")) end)
  end

  test "a late upsert projects the newest committed row" do
    publish_direct("pcw_author", "pcw-late-a", %{}, [])
    publish_direct("pcw_author", "pcw-late-b", %{}, [])
    publish_direct("pcw_post", "pcw-late-post", %{"author" => "pcw-late-a"}, [])
    stale = Repo.get_by!(Document, doc_id: "pcw-late-post", dataset: @dataset)

    publish_direct("pcw_post", "pcw-late-post", %{"author" => "pcw-late-b"}, [])

    # The first write's upsert, arriving after the second write committed.
    :ok = EdgeLifecycle.run_upserts([{stale, "pcw-late-post", @dataset}])

    assert targets(pk("pcw-late-post")) == [pk("pcw-late-b")]
  end

  defp flush_edge_inserts do
    receive do
      {:edge_insert, _} -> flush_edge_inserts()
    after
      100 -> :ok
    end
  end
end
