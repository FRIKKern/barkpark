defmodule Barkpark.Content.CycleFleetReleaseRestoreScopeTest do
  @moduledoc """
  THE cycle_fleet RAW-REPO SEAT (task-d507d3d83476b57d, ruling clause (d)).

  `CycleFleet.restore_release_document/3` is the one seat of the five that never
  passes through `Document.changeset`: it is a bare
  `Repo.update_all(from(d in Document, where: d.id == ^document.id), set: [...])`
  keyed on a UUID replayed out of a stored promotion event's
  `release_materialization["documents"]`. It writes no scope column, so it can
  neither create a row nor null one's workspace — the harm the other four carry
  does not apply to it. Its harm is the other direction: the statement rewrote
  whatever row held that id in ANY workspace.

  Per the ruling that is CLASS (a) — a scope context (the root wave's own
  `workspace_id`) EXISTS and was not consulted — so the remedy is a REFUSAL, not
  a Default stamp. This pins the guard's decision surface; the end-to-end
  rollback path it sits in is covered by `cycle_fleet_test.exs`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Document
  alias Barkpark.CycleFleet
  alias Barkpark.CycleFleet.Wave

  test "a document in the root wave's OWN workspace is in scope" do
    ws = Ecto.UUID.generate()

    assert CycleFleet.release_document_in_scope?(
             %Document{workspace_id: ws},
             %Wave{workspace_id: ws}
           )
  end

  test "a document in a FOREIGN workspace is refused" do
    refute CycleFleet.release_document_in_scope?(
             %Document{workspace_id: Ecto.UUID.generate()},
             %Wave{workspace_id: Ecto.UUID.generate()}
           )
  end

  test "a NULL-workspace document is refused against a scoped wave" do
    refute CycleFleet.release_document_in_scope?(
             %Document{workspace_id: nil},
             %Wave{workspace_id: Ecto.UUID.generate()}
           )
  end

  test "RESIDUAL: a wave with no workspace of its own does not start refusing" do
    assert CycleFleet.release_document_in_scope?(
             %Document{workspace_id: Ecto.UUID.generate()},
             %Wave{workspace_id: nil}
           )
  end
end
