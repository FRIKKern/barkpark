defmodule Barkpark.Content.CancelledScheduleRetentionTest do
  @moduledoc """
  task-44cfe871ea0edc30: cancelled schedules past the window are purged, and
  nothing else is. Design: /papers/cancelled-schedules-purge. Ships disabled;
  the census is the dry run.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureIO

  alias Barkpark.Content.CancelledScheduleRetention, as: Retention
  alias Barkpark.Content.Workers.CancelledScheduleSweeper
  alias Barkpark.{BootModeSandbox, TenancyFixtures}
  alias Mix.Tasks.Barkpark.CancelledSchedules, as: CensusTask

  defp scope! do
    ws = TenancyFixtures.create_workspace!()
    %{ws: ws.id, project: TenancyFixtures.create_project!(ws).id}
  end

  defp row!(scope, status, days_ago) do
    now = DateTime.utc_now()
    at = DateTime.add(now, -days_ago * 86_400, :second)
    id = Ecto.UUID.generate()

    Repo.insert_all("scheduled_publishes", [
      %{
        id: Ecto.UUID.dump!(id),
        workspace_id: Ecto.UUID.dump!(scope.ws),
        project_id: Ecto.UUID.dump!(scope.project),
        dataset: "production",
        type: "post",
        doc_id: "d-#{System.unique_integer([:positive])}",
        publish_at: at,
        principal_type: "api_token",
        principal_id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        status: status,
        completed_at: if(status in ["scheduled", "paused"], do: nil, else: at),
        inserted_at: at,
        updated_at: at
      }
    ])

    id
  end

  defp ids do
    from(s in "scheduled_publishes", select: s.id)
    |> Repo.all()
    |> MapSet.new(&Ecto.UUID.load!/1)
  end

  test "only cancelled rows past the window go, in every workspace" do
    a = scope!()
    b = scope!()

    gone = for s <- [a, b], do: row!(s, "cancelled", 31)

    kept =
      for s <- [a, b],
          {status, age} <- [
            {"cancelled", 29},
            {"published", 60},
            {"refused", 60},
            {"failed", 60},
            {"missed", 60},
            {"paused", 60},
            {"scheduled", 60}
          ],
          do: row!(s, status, age)

    assert %{count: 2} = Retention.census(days: 30)
    assert {:ok, %{deleted: 2}} = Retention.sweep(days: 30)

    left = ids()
    assert Enum.all?(kept, &MapSet.member?(left, &1))
    refute Enum.any?(gone, &MapSet.member?(left, &1))
    assert %{count: 0} = Retention.census(days: 30)
  end

  test "a sweep deletes in bounded batches" do
    s = scope!()
    for _ <- 1..5, do: row!(s, "cancelled", 40)

    assert {:ok, %{deleted: 5, passes: 3}} = Retention.sweep(days: 30, batch_size: 2)
  end

  test "the scheduled sweep is off by default: it counts and deletes nothing" do
    s = scope!()
    id = row!(s, "cancelled", 40)

    refute Retention.enabled?()

    assert {:ok, %{skipped: :disabled, would_delete: n}} =
             perform_job(CancelledScheduleSweeper, %{})

    assert n >= 1
    assert MapSet.member?(ids(), id)
  end

  test "the mix task is a dry run unless --apply" do
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(prev_shell) end)

    s = scope!()
    id = row!(s, "cancelled", 40)

    dry = capture_io(fn -> run_task([]) end)
    assert dry =~ "scheduled sweep disabled"
    assert dry =~ "Dry run — nothing was written"
    assert MapSet.member?(ids(), id)

    applied = capture_io(fn -> run_task(["--apply"]) end)
    assert applied =~ ~r/Deleted [1-9]\d* cancelled schedule/
    refute MapSet.member?(ids(), id)
  end

  defp run_task(argv), do: BootModeSandbox.protecting(fn -> CensusTask.run(argv) end)

  defp perform_job(worker, args), do: worker.perform(%Oban.Job{args: args})
end
