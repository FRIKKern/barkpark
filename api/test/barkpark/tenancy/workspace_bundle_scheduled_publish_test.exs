defmodule Barkpark.Tenancy.WorkspaceBundleScheduledPublishTest do
  @moduledoc """
  Scheduled publishes travel in a workspace bundle, their Oban jobs do not
  (task-8e88b5539acafdae, lead ruling (a)). After an import, a future pending
  schedule has its job again and a past-due one ends `missed`: never a
  schedule that will not fire, never a late publish nobody decided on.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content.{ScheduledPublish, ScheduledPublishes}
  alias Barkpark.Tenancy.WorkspaceBundle

  @worker "Barkpark.Content.Workers.ScheduledPublishWorker"

  defp row!(ws, publish_at) do
    %ScheduledPublish{}
    |> Ecto.Changeset.change(%{
      workspace_id: ws.id,
      dataset: "production",
      type: "notice",
      doc_id: "sp-bundle-#{System.unique_integer([:positive])}",
      publish_at: publish_at,
      principal_type: "api_token",
      principal_id: Ecto.UUID.generate(),
      status: "scheduled"
    })
    |> Repo.insert!()
  end

  defp jobs_for(id) do
    Repo.all(
      from j in Oban.Job,
        where: j.worker == @worker and fragment("?->>'id' = ?", j.args, ^id),
        select: j.id
    )
  end

  setup do
    ws = create_workspace!("sp-bundle-#{System.unique_integer([:positive])}")
    _proj = create_project!(ws, "default")
    future = row!(ws, DateTime.add(DateTime.utc_now(), 3600))
    past = row!(ws, DateTime.add(DateTime.utc_now(), -3600))
    %{ws: ws, future: future, past: past}
  end

  test "an import re-arms future schedules and marks past-due ones missed",
       %{ws: ws, future: future, past: past} do
    # The rows exist, no job does: exactly what a restore leaves behind.
    assert jobs_for(future.id) == []
    {:ok, bundle} = WorkspaceBundle.export(ws.id)

    {:ok, _stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)

    assert %{status: "scheduled"} = Repo.get!(ScheduledPublish, future.id)
    assert [_one] = jobs_for(future.id)

    assert %{status: "missed", reason: reason} = Repo.get!(ScheduledPublish, past.id)
    assert reason =~ "restore"
    assert jobs_for(past.id) == []
  end

  test "re-arming twice never doubles a job", %{ws: ws, future: future} do
    assert %{rearmed: 1} = ScheduledPublishes.rearm(ws.id)
    assert %{rearmed: 1} = ScheduledPublishes.rearm(ws.id)
    assert [_one] = jobs_for(future.id)
  end
end
