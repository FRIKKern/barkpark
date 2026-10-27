defmodule Barkpark.EdgeProjector.ReprojectLinkersTest do
  @moduledoc """
  task-4ec7e38d85c07ab7: when a target is unpublished or deleted, every
  `content_edges` row pointing at it goes (FK cascade + `delete_record/2`),
  and publishing it again re-projected only its own outbound edges. The
  documents linking to it kept no edges until each was saved again.

  A published row that is BORN now enqueues `ReprojectLinkersWorker`, which
  finds the linkers in live content and re-projects them.
  """
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Ecto.Query

  alias Barkpark.{Content, Repo, TenancyFixtures}
  alias Barkpark.Content.{Document, Edge}
  alias Barkpark.EdgeProjector.ReprojectLinkersWorker

  @ds "reproject_linkers_test"
  @ds2 "reproject_linkers_test_2"

  setup do
    ws = TenancyFixtures.create_workspace!()
    scope = [workspace_id: ws.id, project_id: TenancyFixtures.create_project!(ws).id]
    schemas!(scope, @ds)
    %{scope: scope}
  end

  defp schemas!(scope, ds) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "rl_author", "title" => "A", "visibility" => "public", "fields" => []},
        ds,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "rl_post",
          "title" => "P",
          "visibility" => "public",
          "fields" => [
            %{"name" => "author", "type" => "reference", "refType" => "rl_author"},
            %{"name" => "body", "type" => "richText"}
          ]
        },
        ds,
        scope
      )
  end

  defp body(id),
    do: %{
      "blocks" => [
        %{
          "type" => "paragraph",
          "content" => [
            %{"type" => "text", "value" => "see "},
            %{
              "type" => "wikilink",
              "docId" => id,
              "target" => id,
              "children" => [%{"type" => "text", "value" => id}]
            }
          ]
        }
      ]
    }

  defp publish!(type, id, attrs, scope, ds \\ @ds) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), ds, scope)

    {:ok, doc} = Content.publish_document(id, type, ds, scope)
    doc
  end

  defp post!(id, author, scope, ds \\ @ds),
    do: publish!("rl_post", id, %{"author" => author, "body" => body(author)}, scope, ds)

  defp kinds(id, scope, ds \\ @ds) do
    {:ok, %Document{id: pk}} = Content.get_document(id, "rl_post", ds, scope)

    from(e in Edge, where: e.from_id == ^pk, select: e.kind)
    |> Repo.all()
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&(&1 in ["author", "body"]))
  end

  # The publish's own projection may ride the debounced :edge_projector job
  # inside the test's sandbox transaction; drain it first, then the linkers.
  defp drain do
    Oban.drain_queue(queue: :edge_projector, with_scheduled: true)
    Oban.drain_queue(queue: :edge_linkers, with_scheduled: true, with_recursion: true)
  end

  test "unpublish then republish a target restores its linkers' edges", %{scope: scope} do
    publish!("rl_author", "rl-a1", %{}, scope)
    post!("rl-p1", "rl-a1", scope)
    drain()
    assert kinds("rl-p1", scope) == ["author", "body"]

    {:ok, _} = Content.unpublish_document("rl-a1", "rl_author", @ds, scope)
    assert kinds("rl-p1", scope) == []

    {:ok, _} = Content.publish_document("rl-a1", "rl_author", @ds, scope)
    drain()
    assert kinds("rl-p1", scope) == ["author", "body"]
  end

  test "delete then re-create a target restores its linkers' edges", %{scope: scope} do
    publish!("rl_author", "rl-a2", %{}, scope)
    post!("rl-p2", "rl-a2", scope)
    drain()

    {:ok, _} = Content.delete_document("rl-a2", "rl_author", @ds, scope)
    assert kinds("rl-p2", scope) == []

    publish!("rl_author", "rl-a2", %{}, scope)
    drain()
    assert kinds("rl-p2", scope) == ["author", "body"]
  end

  test "a link published while its target is absent appears when the target is published",
       %{scope: scope} do
    post!("rl-p3", "rl-a3", scope)
    assert kinds("rl-p3", scope) == []

    publish!("rl_author", "rl-a3", %{}, scope)
    drain()
    assert kinds("rl-p3", scope) == ["author", "body"]
  end

  test "a publish over an existing published row enqueues nothing", %{scope: scope} do
    publish!("rl_author", "rl-a4", %{}, scope)
    drain()

    {:ok, _} =
      Content.create_document(
        "rl_author",
        %{"_id" => "rl-a4", "title" => "again"},
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document("rl-a4", "rl_author", @ds, scope)
    assert all_enqueued(worker: ReprojectLinkersWorker) == []
  end

  test "the same id in another workspace or dataset is never re-projected", %{scope: scope} do
    other_ws = TenancyFixtures.create_workspace!()
    other = [workspace_id: other_ws.id, project_id: TenancyFixtures.create_project!(other_ws).id]
    schemas!(other, @ds)
    schemas!(scope, @ds2)

    for {sc, ds} <- [{scope, @ds}, {other, @ds}, {scope, @ds2}] do
      publish!("rl_author", "rl-same", %{}, sc, ds)
      post!("rl-ps", "rl-same", sc, ds)
    end

    drain()

    # The other tenant's and the other dataset's linkers lose their edges by
    # hand, so a stray re-projection there would show.
    for {sc, ds} <- [{other, @ds}, {scope, @ds2}] do
      {:ok, %Document{id: pk}} = Content.get_document("rl-ps", "rl_post", ds, sc)
      Repo.delete_all(from(e in Edge, where: e.from_id == ^pk))
    end

    {:ok, _} = Content.unpublish_document("rl-same", "rl_author", @ds, scope)
    {:ok, _} = Content.publish_document("rl-same", "rl_author", @ds, scope)
    drain()

    assert kinds("rl-ps", scope) == ["author", "body"]
    assert kinds("rl-ps", other) == []
    assert kinds("rl-ps", scope, @ds2) == []
  end

  test "a target with exactly a page of linkers enqueues no empty continuation",
       %{scope: scope} do
    Application.put_env(:barkpark, ReprojectLinkersWorker, page: 3)
    on_exit(fn -> Application.delete_env(:barkpark, ReprojectLinkersWorker) end)

    {:ok, _} = Content.create_document("rl_author", %{"_id" => "rl-a5"}, @ds, scope)
    for i <- 1..3, do: post!("rl-p5-#{i}", "rl-a5", scope)
    drain()
    {:ok, _} = Content.publish_document("rl-a5", "rl_author", @ds, scope)

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(queue: :edge_linkers, with_scheduled: true, with_recursion: true)

    for i <- 1..3, do: assert(kinds("rl-p5-#{i}", scope) == ["author", "body"])
  end

  test "a bulk publish of 200 targets enqueues one bounded job each on its own queue",
       %{scope: scope} do
    Application.put_env(:barkpark, ReprojectLinkersWorker, page: 3)
    on_exit(fn -> Application.delete_env(:barkpark, ReprojectLinkersWorker) end)

    ids = for i <- 1..200, do: "rl-bulk-#{i}"
    for id <- ids, do: {:ok, _} = Content.create_document("rl_author", %{"_id" => id}, @ds, scope)
    # Seven linkers of one target, so its job pages (page 3) and continues.
    for i <- 1..7, do: post!("rl-bulk-post-#{i}", "rl-bulk-1", scope)

    {:ok, _} =
      Content.Mutations.apply_mutations(
        Enum.map(ids, &%{"publish" => %{"id" => &1, "type" => "rl_author"}}),
        @ds,
        scope
      )

    # Each post's own birth enqueued a job too; count the authors'.
    jobs =
      ReprojectLinkersWorker
      |> then(&all_enqueued(worker: &1))
      |> Enum.filter(&(&1.args["type"] == "rl_author"))

    assert length(jobs) == 200
    assert Enum.all?(jobs, &(&1.queue == "edge_linkers"))
    assert jobs |> Enum.map(& &1.args["_id"]) |> Enum.uniq() |> length() == 200

    # Unique: the same birth enqueued again adds no second job.
    {:ok, a1} = Content.get_document("rl-bulk-1", "rl_author", @ds, scope)
    ReprojectLinkersWorker.enqueue(a1)

    assert length(
             Enum.filter(
               all_enqueued(worker: ReprojectLinkersWorker),
               &(&1.args["type"] == "rl_author")
             )
           ) == 200

    assert %{failure: 0, success: success} = drain()
    # 200 first pages plus the continuations of the paged target.
    assert success > 200
    for i <- 1..7, do: assert(kinds("rl-bulk-post-#{i}", scope) == ["author", "body"])

    # Its own queue, at concurrency 1, so a burst never crowds another queue.
    assert Application.get_env(:barkpark, Oban)[:queues][:edge_linkers] == 1
  end
end
