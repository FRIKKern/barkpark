defmodule Barkpark.Plugins.Bulldocs.EventFkTest do
  @moduledoc """
  FK-abort containment for Bulldocs `Event.changeset/2` (Felix W16, the W13
  changeset-FK-abort scar-class W14 opened on MediaFile).

  `paper_events.workspace_id/project_id` are real CASCADE Postgres FKs
  (default-derived constraint names `paper_events_<col>_fkey`, migration
  20260527170000). Without `foreign_key_constraint/2` in the changeset, an
  insert referencing a vanished row — a workspace/project deleted concurrently
  after its id was resolved but before the event insert — RAISES
  Ecto.ConstraintError out of `Repo.insert`. That raise escapes
  `block_ops.ex maybe_append_paper_event/3`, whose stated contract is
  "Failures are logged, never raised" (it matches only `{:ok,_}`/`{:error,_}`),
  so paper ingest 500s instead of degrading gracefully.

  Each bad-FK insert lives in its OWN test: a Postgres FK violation aborts the
  sandbox transaction, so nothing may run after it in the same test.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Plugins.Bulldocs.Event
  alias Barkpark.Repo

  defp attrs(overrides) do
    Map.merge(
      %{
        event_type: "goal-snapshot",
        paper_slug: "fk-probe-#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  defp insert(overrides) do
    %Event{} |> Event.changeset(attrs(overrides)) |> Repo.insert()
  end

  describe "bad FK references return {:error, changeset} (never a raise)" do
    test "non-existent workspace_id" do
      assert {:error, %Ecto.Changeset{} = cs} = insert(%{workspace_id: Ecto.UUID.generate()})
      assert {"does not exist", _} = cs.errors[:workspace_id]
    end

    test "non-existent project_id" do
      assert {:error, %Ecto.Changeset{} = cs} = insert(%{project_id: Ecto.UUID.generate()})
      assert {"does not exist", _} = cs.errors[:project_id]
    end
  end

  describe "valid FK references still insert" do
    test "insert with live workspace/project succeeds" do
      ws = create_workspace!()
      project = create_project!(ws)

      assert {:ok, %Event{} = event} =
               insert(%{workspace_id: ws.id, project_id: project.id})

      assert event.workspace_id == ws.id
      assert event.project_id == project.id
    end
  end
end
