defmodule Barkpark.Plugins.Github.OutboxTest do
  @moduledoc """
  The outbound-mirror outbox reader — the single place loop-cut #2 (epic D4) is
  enforced on the read side: `source = "github"` rows (inbound-applied writes) are
  EXCLUDED so an intaken issue is never mirrored back out. It also restricts the
  window to `type = "task"` (repo issues map to TASKS, never Tickets). No network.
  Events are inserted directly into `mutation_events` so the test controls
  `source`/`type` precisely.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.Outbox
  alias Barkpark.Repo

  @dataset "test"

  defp insert_event!(doc_id, source, type \\ "task") do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: @dataset,
      type: type,
      doc_id: doc_id,
      mutation: "create",
      rev: "r-#{doc_id}",
      document: %{"_id" => doc_id, "_type" => type},
      source: source,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  test "returns only source!=github task rows; excludes github-origin (loop guard) and non-task" do
    api_task = insert_event!("local-task", "api", "task")
    studio_task = insert_event!("studio-task", "studio", "task")
    github_task = insert_event!("intaken", "github", "task")
    api_post = insert_event!("a-post", "api", "post")
    github_post = insert_event!("gh-post", "github", "post")

    rows = Outbox.fetch(@dataset, 0, 50)
    ids = Enum.map(rows, & &1.id)

    # local-origin task rows are IN
    assert api_task.id in ids
    assert studio_task.id in ids

    # loop-cut #2: a task stamped source="github" is EXCLUDED
    refute github_task.id in ids

    # non-task rows never appear, regardless of source
    refute api_post.id in ids
    refute github_post.id in ids

    # every returned row is a non-github task
    assert Enum.all?(rows, &(&1.type == "task" and &1.source != "github"))
  end

  test "default source (unset → \"api\") task rows are included" do
    # The `mutation_events.source` column is NOT NULL with a DB/schema default of
    # "api", so a write that omits source is local-origin and must be mirrored.
    # (The query's `is_nil(e.source)` clause stays as defensive parity with
    # Sync.Outbox; the DB constraint makes an actual NULL unreachable here.)
    default_task =
      %MutationEvent{}
      |> Ecto.Changeset.change(%{
        dataset: @dataset,
        type: "task",
        doc_id: "default-src",
        mutation: "create",
        rev: "r-default-src",
        document: %{"_id" => "default-src", "_type" => "task"},
        inserted_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert default_task.source == "api"
    ids = Outbox.fetch(@dataset, 0, 50) |> Enum.map(& &1.id)
    assert default_task.id in ids
  end

  test "returns rows id ASC and respects after_id + limit" do
    a = insert_event!("a", "api")
    b = insert_event!("b", "studio")
    c = insert_event!("c", "cli")

    rows = Outbox.fetch(@dataset, 0, 50)
    ids = Enum.map(rows, & &1.id)
    assert ids == Enum.sort(ids)
    assert [a.id, b.id, c.id] -- ids == []

    # after_id excludes <= cursor
    after_a = Outbox.fetch(@dataset, a.id, 50) |> Enum.map(& &1.id)
    refute a.id in after_a
    assert b.id in after_a and c.id in after_a

    # limit caps the batch and takes the LOWEST ids first (causal replay)
    assert [first] = Outbox.fetch(@dataset, 0, 1)
    assert first.id == a.id
  end
end
