defmodule Barkpark.Sync.OutboxTest do
  @moduledoc """
  The push outbox reader — the single place echo-suppression is enforced on the
  read side (invariant #4): `source:"sync"` rows (PULL-applied) are EXCLUDED so a
  pulled mutation is never pushed back. No network. Events are inserted directly
  into `mutation_events` so the test controls `source` precisely.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Sync.Outbox

  @dataset "test"

  defp insert_event!(doc_id, source) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: @dataset,
      type: "post",
      doc_id: doc_id,
      mutation: "create",
      rev: "r-#{doc_id}",
      document: %{"_id" => doc_id, "_type" => "post"},
      source: source,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  test "EXCLUDES source:\"sync\" rows, returns only local-origin events (echo-suppression)" do
    sync_ev = insert_event!("from-pull", "sync")
    api_ev = insert_event!("local-write", "api")

    rows = Outbox.fetch(@dataset, 0, 50)
    ids = Enum.map(rows, & &1.id)

    assert api_ev.id in ids
    refute sync_ev.id in ids
    assert Enum.all?(rows, &(&1.source != "sync"))
  end

  test "returns rows id ASC and respects after_id + limit" do
    a = insert_event!("a", "api")
    b = insert_event!("b", "studio")
    c = insert_event!("c", "cli")

    # id ASC
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
