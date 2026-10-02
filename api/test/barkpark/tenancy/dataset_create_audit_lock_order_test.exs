defmodule Barkpark.Tenancy.DatasetCreateAuditLockOrderTest do
  @moduledoc """
  A first write into a NEW dataset cannot deadlock against a writer that holds
  the workspace's audit-chain lock (Run-4 Lane B deadlock hunt).

  The dominant 40P01 in the local Postgres log (261 of 327 logged deadlocks):

      T_row:   INSERT INTO datasets … ON CONFLICT (project_id, slug) DO NOTHING
               (holds the not-yet-committed row) ─────▶ wants audit(ws)
      T_audit: pg_advisory_xact_lock(audit(ws)) ─────▶ the SAME dataset insert,
               which waits for T_row's transaction

  Both orders are production paths in one workspace:

    * row → audit: any write into a dataset string the project has not seen yet
      (`WriteScope` → `Tenancy.get_or_create_dataset/2` inside the write
      transaction), whose `Audit.emit/1` runs after the row insert;
    * audit → row: a writer that pre-takes the chain lock and then writes into
      the same new dataset — `DedupWall.lock_publish_scope!/3` (publish / the
      authoring wall, which takes audit(ws) FIRST by design) or an unscoped
      mutate batch (`serialize_unscoped_batch/1`), followed in the same
      transaction by a create into the new dataset.

  The fix keeps ONE order: inserting a dataset row takes the workspace's
  audit-chain lock first (`Audit.lock_chain!/1` is re-entrant, so the later
  emit in the same transaction does not wait on itself). This test drives the
  two orders with real transactions (no sandbox) and a barrier: on main one of
  them dies with 40P01.
  """
  use ExUnit.Case, async: false

  alias Barkpark.{Audit, Repo, Tenancy}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    tag = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "dsaudit-#{tag}", name: "dsaudit #{tag}"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "dsaudit-p-#{tag}", name: "p"})

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      for q <- [
            "DELETE FROM datasets WHERE project_id = $1::text::uuid",
            "DELETE FROM projects WHERE id = $1::text::uuid"
          ] do
        try do
          Repo.query!(q, [proj.id])
        rescue
          _ -> :ok
        end
      end

      try do
        Repo.delete(ws)
      rescue
        _ -> :ok
      end
    end)

    %{ws: ws, proj: proj, slug: "fresh-#{tag}"}
  end

  test "dataset-row-first and audit-first writers into one new dataset never deadlock", %{
    ws: ws,
    proj: proj,
    slug: slug
  } do
    parent = self()

    row_first =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          {:ok, _} = Tenancy.get_or_create_dataset(proj.id, slug)
          send(parent, :row_inserted)
          # Wait until the other writer holds the audit lock (on main) — or
          # give up after 500 ms when it is blocked behind us (the fix).
          receive do
            :audit_held -> :ok
          after
            500 -> :ok
          end

          Audit.lock_chain!(ws.id)
          :row_first_done
        end)
      end)

    audit_first =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        receive do
          :go -> :ok
        end

        Repo.transaction(fn ->
          Audit.lock_chain!(ws.id)
          send(parent, :audit_held)
          {:ok, _} = Tenancy.get_or_create_dataset(proj.id, slug)
          :audit_first_done
        end)
      end)

    assert_receive :row_inserted, 5_000
    send(audit_first.pid, :go)

    receive do
      :audit_held -> send(row_first.pid, :audit_held)
    after
      600 -> :ok
    end

    results =
      for t <- [row_first, audit_first] do
        try do
          Task.await(t, 15_000)
        catch
          :exit, reason -> {:exit, reason}
        end
      end

    refute Enum.any?(results, &match?({:exit, _}, &1)),
           "a writer died (40P01 deadlock on dataset-row vs audit-chain order): #{inspect(results)}"

    assert results == [{:ok, :row_first_done}, {:ok, :audit_first_done}]
  end
end
