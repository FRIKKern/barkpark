defmodule Barkpark.Sync.PushCursorTest do
  @moduledoc """
  Unit tests for the PUSH high-water mark, with focus on F1's
  `bootstrap_if_absent/2`: a first-enable seed to the dataset head that skips ALL
  pre-enablement history (so it is never replayed to the remote — invariant #4),
  is idempotent/never-rewinding (invariant #3), and is dataset-scoped. No worker,
  no network (invariant #7).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Sync.{Outbox, PushCursor}

  @dataset "test"

  defp insert_event!(doc_id, source, dataset \\ @dataset) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: dataset,
      type: "post",
      doc_id: doc_id,
      mutation: "create",
      rev: "r-#{doc_id}",
      document: %{"_id" => doc_id, "_type" => "post", "_rev" => "r-#{doc_id}"},
      source: source,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp src, do: "pc-#{System.unique_integer([:positive])}"

  test "bootstrap seeds the cursor to MAX(id) over pre-existing rows (incl. \"api\" clones); they are NOT re-pushed" do
    source = src()
    # Pre-enablement history: some "api"-stamped (possibly pulled clones).
    _e1 = insert_event!("a", "api")
    _e2 = insert_event!("b", "api")
    e3 = insert_event!("c", "api")

    assert :ok = PushCursor.bootstrap_if_absent(source, @dataset)
    assert PushCursor.get(source, @dataset) == e3.id

    # The Outbox window starts strictly above the cursor → nothing pre-enable replays.
    assert Outbox.fetch(@dataset, PushCursor.get(source, @dataset), 50) == []
  end

  test "idempotent / never rewinds an already-advanced cursor" do
    source = src()
    e1 = insert_event!("a", "api")
    head = e1.id

    assert :ok = PushCursor.bootstrap_if_absent(source, @dataset)
    assert PushCursor.get(source, @dataset) == head

    # Advance well past head, then call bootstrap again: it must be a NO-OP.
    :ok = PushCursor.put(source, @dataset, head + 5)
    assert :ok = PushCursor.bootstrap_if_absent(source, @dataset)
    assert PushCursor.get(source, @dataset) == head + 5
  end

  test "no events → cursor seeds to 0" do
    source = src()
    other_dataset = "empty-#{System.unique_integer([:positive])}"
    assert :ok = PushCursor.bootstrap_if_absent(source, other_dataset)
    assert PushCursor.get(source, other_dataset) == 0
  end

  test "dataset-scoped: events in another dataset don't move this dataset's head" do
    source = src()
    other = "other-#{System.unique_integer([:positive])}"
    mine = insert_event!("m", "api")
    # A higher-id event in a DIFFERENT dataset must not raise our head.
    _theirs = insert_event!("o", "api", other)

    assert :ok = PushCursor.bootstrap_if_absent(source, @dataset)
    assert PushCursor.get(source, @dataset) == mine.id
  end
end
