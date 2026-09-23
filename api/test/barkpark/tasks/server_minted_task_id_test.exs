defmodule Barkpark.Tasks.ServerMintedTaskIdTest do
  @moduledoc """
  Concurrent id-less task creates get DISTINCT server-minted ids
  (spd-b44-slug-allocator-assigns-not-guesses, criterion 0).

  The row asked that the SERVER assign a task's identity on create instead of
  builders in isolated worktrees guessing the next free `spd-bNN` short number
  and colliding. That now holds: a create that sends no `doc_id` gets one from
  `Content.Writer.generate_id/1` — `"task-" <> 16 hex chars` drawn from
  `:crypto.strong_rand_bytes(8)` inside the writer. There is no counter to race
  on, so allocation is collision-free without any coordination between callers.
  `bp task create` sends no `doc_id` by default, so it gets this path.

  `writer_fence_test.exs` already checks the id SHAPE and 2000 serial draws.
  What was missing is the property the row states: CONCURRENT creates, through
  the same create → publish door `bp task create --publish` uses, both land as
  separate published tasks.

  ## What "concurrent" means here

  Both creates run in their own process and are released together from a
  rendezvous, so both mint an id before either inserts. The SQL sandbox (shared
  mode) serializes their statements onto one connection. That does not weaken
  the test: the id comes from process-local entropy, not from the database, so
  the property under test is fully settled before either INSERT runs.

  ## Deletion proof

  Replacing `generate_id/1`'s body with a constant (`"task-0000000000000000"`
  for a task) reds this test: both creators mint the same id, one insert lands,
  and the other is refused by the `documents_doc_id_type_dataset_id_index`
  unique index ("has already been taken"), so only one task exists.
  """
  # sync: registers schemas/tags into a shared dataset and needs the shared sandbox for spawned creators
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, LabelFixtures, TaskBriefFixtures, Tasks, TenancyFixtures}
  alias Barkpark.Content.DraftId

  @dataset "server_minted_task_id_test"
  @minted ~r/\Atask-[0-9a-f]{16}\z/

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  # An id-less create followed by a publish, i.e. what `bp task create --publish`
  # does. The titles and labels are unique per call so the near-duplicate gates
  # never mistake the two creators for twins; this test is about identity only.
  defp create_and_publish(n, scope) do
    content =
      %{"kind" => "task", "lifecycle_status" => "open"}
      |> Map.merge(LabelFixtures.with_registered_labels(%{}, @dataset))
      |> TaskBriefFixtures.with_brief()

    title = "Concurrent id-less creator #{n} qx#{System.unique_integer([:positive])}"

    with {:ok, draft} <-
           Content.create_document(
             "task",
             %{"title" => title, "content" => content},
             @dataset,
             scope
           ),
         published_id = DraftId.published_id(draft.doc_id),
         {:ok, _} <- Content.publish_document(published_id, "task", @dataset, scope) do
      {:ok, published_id}
    end
  end

  test "two concurrent id-less creates get distinct task-<16 hex> ids and both publish",
       %{scope: scope} do
    parent = self()

    creators =
      for n <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> create_and_publish(n, scope)
          end
        end)
      end

    # Rendezvous: release both creators only once both are parked, so neither
    # has finished its create before the other starts.
    pids =
      for _ <- creators do
        receive do
          {:ready, pid} -> pid
        after
          5_000 -> flunk("a creator never reached the rendezvous")
        end
      end

    Enum.each(pids, &send(&1, :go))

    results = Task.await_many(creators, 30_000)
    ids = for {:ok, id} <- results, do: id

    assert length(ids) == 2, "both creates must succeed, got: #{inspect(results)}"
    assert Enum.uniq(ids) == ids, "server-minted ids collided: #{inspect(ids)}"

    for id <- ids do
      assert Regex.match?(@minted, id), "#{id} is not a server-minted task-<16 hex> id"

      {:ok, doc} = Content.get_document(id, "task", @dataset, scope)
      assert doc.status == "published"
    end
  end
end
