defmodule Barkpark.Sync.QuarantineExitTest do
  @moduledoc """
  task-b2b871424bd184eb — both sync quarantine tables were entered
  automatically and left by nothing: `sync_dead_letters.status` only ever
  moved `pending → dead`, `sync_push_conflicts.status` was only ever `"open"`.
  `resolve/3` is the exit. On origin/main these tests red (no exit exists);
  mutation: make either `resolve/3` a no-op `:ok` and the "leaves quarantine"
  assertions red with the row still quarantined.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Repo
  alias Barkpark.Sync.{DeadLetter, PushConflict}

  @source "qx-source"
  @dataset "qx-dataset"

  defp ws_id do
    Barkpark.Tenancy.get_default_workspace().id
  end

  test "a dead-lettered event leaves quarantine through resolve/3, envelope kept" do
    envelope = %{"result" => %{"_id" => "poison", "_type" => "post"}}
    assert 1 == DeadLetter.record_failure(ws_id(), @source, @dataset, 41, envelope, :boom)
    :ok = DeadLetter.mark_dead(@source, @dataset, 41)
    assert [%{event_id: 41}] = DeadLetter.list_dead(@source, @dataset)

    assert :ok = DeadLetter.resolve(@source, @dataset, 41)

    assert DeadLetter.list_dead(@source, @dataset) == []
    row = Repo.get_by!(DeadLetter, source: @source, dataset: @dataset, event_id: 41)
    assert row.status == "resolved"
    assert row.envelope == envelope

    # Idempotent refusal: a resolved row is no longer quarantined.
    assert {:error, :not_found} = DeadLetter.resolve(@source, @dataset, 41)
    assert {:error, :not_found} = DeadLetter.resolve(@source, @dataset, 999)
  end

  test "a pending (below-threshold) dead letter can be resolved too" do
    DeadLetter.record_failure(ws_id(), @source, @dataset, 42, %{}, :boom)
    assert :ok = DeadLetter.resolve(@source, @dataset, 42)
    assert Repo.get_by!(DeadLetter, event_id: 42, source: @source).status == "resolved"
  end

  test "an open push conflict leaves quarantine through resolve/3, loser kept" do
    loser = %{"_id" => "doc-1", "title" => "local loser"}

    :ok =
      PushConflict.record(ws_id(), @source, @dataset, 7, %{
        doc_id: "doc-1",
        type: "post",
        kind: "rev_mismatch",
        local_document: loser,
        last_error: "rev_mismatch"
      })

    assert [%{event_id: 7}] = PushConflict.list_open(@source, @dataset)

    assert :ok = PushConflict.resolve(@source, @dataset, 7)

    assert PushConflict.list_open(@source, @dataset) == []
    row = Repo.get_by!(PushConflict, source: @source, dataset: @dataset, event_id: 7)
    assert row.status == "resolved"
    assert row.local_document == loser
    assert {:error, :not_found} = PushConflict.resolve(@source, @dataset, 7)
  end
end
