defmodule Barkpark.Plugins.Github.CursorTest do
  @moduledoc """
  Unit tests for the OUTBOUND GitHub mirror high-water mark
  (`Barkpark.Plugins.Github.Cursor`): monotonic advance (a lower id is a no-op),
  and `bootstrap_if_absent/1` seeding the cursor to `MAX(mutation_events.id)` so
  ALL pre-enable history is skipped (first enable never mass-mirrors the backlog),
  idempotent/never-rewinding once a row exists. DB-only, no network.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.{Cursor, Outbox}
  alias Barkpark.Repo

  @dataset "test"

  defp insert_event!(doc_id, source, type \\ "task", dataset \\ @dataset) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: dataset,
      type: type,
      doc_id: doc_id,
      mutation: "create",
      rev: "r-#{doc_id}",
      document: %{"_id" => doc_id, "_type" => type, "_rev" => "r-#{doc_id}"},
      source: source,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  test "reuses the sync_push_cursors table under the reserved github:outbound source key" do
    assert Cursor.source() == "github:outbound"
  end

  test "bootstrap seeds the cursor to MAX(id) over pre-enable rows; they are NOT mirrored" do
    _e1 = insert_event!("a", "api")
    _e2 = insert_event!("b", "api")
    e3 = insert_event!("c", "api")

    assert :ok = Cursor.bootstrap_if_absent(@dataset)
    assert Cursor.get(@dataset) == e3.id

    # The Outbox window starts strictly above the cursor → nothing pre-enable mirrors.
    assert Outbox.fetch(@dataset, Cursor.get(@dataset), 50) == []
  end

  test "bootstrap counts non-task pre-enable rows toward the head (no non-task replay either)" do
    _e1 = insert_event!("a", "api", "task")
    # A higher-id NON-task row must still raise the bootstrap head so first enable
    # skips it too (Outbox will filter type anyway, but the head must not sit below it).
    top = insert_event!("p", "api", "post")

    assert :ok = Cursor.bootstrap_if_absent(@dataset)
    assert Cursor.get(@dataset) == top.id
  end

  test "put advances monotonically; a lower id is a no-op" do
    :ok = Cursor.put(@dataset, 100)
    assert Cursor.get(@dataset) == 100

    :ok = Cursor.put(@dataset, 50)
    assert Cursor.get(@dataset) == 100, "put with a lower id must not rewind"

    :ok = Cursor.put(@dataset, 150)
    assert Cursor.get(@dataset) == 150
  end

  test "bootstrap is idempotent / never rewinds an already-advanced cursor" do
    e1 = insert_event!("a", "api")
    head = e1.id

    assert :ok = Cursor.bootstrap_if_absent(@dataset)
    assert Cursor.get(@dataset) == head

    :ok = Cursor.put(@dataset, head + 5)
    assert :ok = Cursor.bootstrap_if_absent(@dataset)
    assert Cursor.get(@dataset) == head + 5, "second bootstrap must be a no-op"
  end

  test "no events → cursor seeds to 0" do
    other = "empty-#{System.unique_integer([:positive])}"
    assert :ok = Cursor.bootstrap_if_absent(other)
    assert Cursor.get(other) == 0
  end

  test "dataset-scoped: events in another dataset don't move this dataset's head" do
    other = "other-#{System.unique_integer([:positive])}"
    mine = insert_event!("m", "api")
    _theirs = insert_event!("o", "api", "task", other)

    assert :ok = Cursor.bootstrap_if_absent(@dataset)
    assert Cursor.get(@dataset) == mine.id
  end
end
