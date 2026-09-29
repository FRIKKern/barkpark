defmodule Barkpark.DeletedWorkspaceResidue do
  @moduledoc """
  Delete the `audit_events` and `oban_jobs` rows an unboxed test commits for a
  workspace it then deletes.

  A test inside `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` that creates a
  workspace, writes a paper in it and ends with `Tenancy.delete_workspace/1`
  still leaves rows behind. Measured on a fresh partition (2026-09-25), each
  such test left one `document.delete` audit event and two scheduled
  `EdgeProjector.ProjectorWorker` jobs, all carrying the deleted workspace's id.

  Call `purge_on_exit/0` at the top of the test, before any unboxed write. It
  reads each table's id watermark, and on exit deletes the rows above it whose
  workspace no longer exists. That predicate cannot reach a live workspace's
  rows, and an audit chain is per workspace, so deleting a gone workspace's
  rows removes whole chains and breaks none. `audit_events` rejects a plain
  DELETE by trigger, so the purge runs with `session_replication_role =
  replica`, the method `cycle_fleet_test` uses. The purge then fails the test
  if any such row remains.
  """

  alias Barkpark.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @orphaned %{
    "audit_events" =>
      "id > $1 AND workspace_id IS NOT NULL AND NOT EXISTS " <>
        "(SELECT 1 FROM workspaces w WHERE w.id = audit_events.workspace_id)",
    "oban_jobs" =>
      "id > $1 AND args ? 'workspace_id' AND NOT EXISTS " <>
        "(SELECT 1 FROM workspaces w WHERE w.id::text = oban_jobs.args ->> 'workspace_id')"
  }

  def purge_on_exit do
    marks =
      Sandbox.unboxed_run(Repo, fn ->
        Map.new(@orphaned, fn {table, _where} ->
          %{rows: [[n]]} = Repo.query!("SELECT coalesce(max(id), 0) FROM #{table}")
          {table, n}
        end)
      end)

    ExUnit.Callbacks.on_exit(fn -> purge!(marks) end)
  end

  defp purge!(marks) do
    Sandbox.unboxed_run(Repo, fn ->
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL session_replication_role = replica")

          for {table, where} <- @orphaned do
            Repo.query!("DELETE FROM #{table} WHERE #{where}", [marks[table]])
          end
        end)

      left =
        for {table, where} <- @orphaned,
            %{rows: [[n]]} =
              Repo.query!("SELECT count(*) FROM #{table} WHERE #{where}", [marks[table]]),
            n > 0,
            into: %{},
            do: {table, n}

      if left != %{} do
        raise "rows committed for a deleted workspace are still there after the purge: " <>
                inspect(left)
      end
    end)
  end
end
