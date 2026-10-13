defmodule Barkpark.Plugins.Github.OutboxMultiWorkspaceWarningTest do
  @moduledoc """
  Owner ruling #12 (task-803343b8cce8bfb7): with `BARKPARK_GITHUB_INTAKE_WORKSPACE_ID`
  unset, `Outbox.fetch/3` keeps mirroring every workspace's task events, by
  design, so a single-workspace install sees no change. That default is NOT
  changed here.

  What IS new: a one-time `Logger.warning` when the var is unset AND the
  mirrored dataset(s) already hold task events from more than one workspace —
  the exact scenario ruling #12 flagged as an open question and left for a
  human to notice later. This suite proves both directions: a single-workspace
  install gets no warning, a multi-workspace one gets it exactly once, and
  `fetch/3`'s return value is unchanged either way.

  `async: false` — the env var is process-global and the warning flag is a
  `persistent_term`.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog
  import Barkpark.TenancyFixtures

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.Outbox
  alias Barkpark.Repo

  @env "BARKPARK_GITHUB_INTAKE_WORKSPACE_ID"
  @dataset "outbox-multi-ws-warn"

  setup do
    prior = System.get_env(@env)

    on_exit(fn ->
      if prior, do: System.put_env(@env, prior), else: System.delete_env(@env)
      Outbox.reset_multi_workspace_warning()
    end)

    System.delete_env(@env)
    Outbox.reset_multi_workspace_warning()

    %{ws_a: create_workspace!(), ws_b: create_workspace!()}
  end

  defp event!(doc_id, workspace_id) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: @dataset,
      type: "task",
      doc_id: doc_id,
      mutation: "create",
      rev: "r-#{doc_id}",
      document: %{"_id" => doc_id, "_type" => "task"},
      source: "api",
      workspace_id: workspace_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  test "a single workspace's tasks produce no warning", %{ws_a: a} do
    event!("task-a1", a.id)
    event!("task-a2", a.id)

    log =
      capture_log(fn ->
        ids = Outbox.fetch(@dataset, 0, 100) |> Enum.map(& &1.doc_id) |> Enum.sort()
        assert ids == ["task-a1", "task-a2"]
      end)

    refute log =~ "github outbox"
  end

  test "tasks across two workspaces produce the warning exactly once, and the mirror window is unchanged",
       %{ws_a: a, ws_b: b} do
    event!("task-a", a.id)
    event!("task-b", b.id)

    log =
      capture_log(fn ->
        # Called three times, as a drain loop would across ticks/datasets.
        for _ <- 1..3 do
          ids = Outbox.fetch(@dataset, 0, 100) |> Enum.map(& &1.doc_id) |> Enum.sort()
          # Zero behaviour change: both workspaces' tasks still mirror.
          assert ids == ["task-a", "task-b"]
        end
      end)

    occurrences =
      log
      |> String.split("github outbox")
      |> length()
      |> Kernel.-(1)

    assert occurrences == 1,
           "expected the warning exactly once across 3 fetch/3 calls, got #{occurrences}"

    assert log =~ "BARKPARK_GITHUB_INTAKE_WORKSPACE_ID"
    assert log =~ "task-803343b8cce8bfb7"
  end

  test "setting the intake workspace still scopes the mirror and never warns", %{ws_a: a, ws_b: b} do
    event!("task-a", a.id)
    event!("task-b", b.id)
    System.put_env(@env, a.id)

    log =
      capture_log(fn ->
        ids = Outbox.fetch(@dataset, 0, 100) |> Enum.map(& &1.doc_id) |> Enum.sort()
        assert ids == ["task-a"]
      end)

    refute log =~ "github outbox"
  end
end
