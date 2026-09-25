defmodule Barkpark.Content.DedupAuditLockOrderTest do
  @moduledoc """
  task-0c397ec87de1f924 — the publish-scope lock and the audit-chain lock are
  taken in ONE order.

  Two transactions in the same workspace, each on its own unboxed connection:

      A: Audit.emit(ws)            ── holds audit(ws)
                                       B: lock_publish_scope!(ws) ── holds dedup(ws)?
      A: lock_publish_scope!(ws)   ── wants dedup(ws)
                                       B: Audit.emit(ws)          ── wants audit(ws)

  A is a mutate batch that audited an earlier mutation and then publishes; B is
  a plain publish (scope lock, then the audit emit in `tap_broadcast`). With the
  scope lock taken before the audit lock, B gets dedup(ws) and the four steps
  deadlock (Postgres 40P01). With the audit lock taken first inside
  `lock_publish_scope!/3`, B blocks on audit(ws) before it can hold dedup(ws),
  A finishes, then B finishes.

  Deterministic: A does not request the scope lock until B has reported holding
  it, or 500 ms have passed with B blocked (the fixed ordering). Both
  transactions roll back, so no audit row is committed.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Audit
  alias Barkpark.Content.DedupWall
  alias Barkpark.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @dataset "production"

  defp emit!(ws, subject) do
    {:ok, _} =
      Audit.emit(%{
        category: "content_mutation",
        action: "document.lock_order_probe",
        subject: subject,
        workspace_id: ws
      })

    :ok
  end

  # Run `fun` in a transaction on this process's unboxed connection and roll it
  # back. A deadlock victim's Postgrex error is returned, not raised, so the
  # test can assert on it.
  defp in_rolled_back_txn(fun) do
    Repo.transaction(fn ->
      fun.()
      Repo.rollback(:done)
    end)
  rescue
    e in Postgrex.Error -> {:postgres_error, e.postgres[:code]}
  end

  test "a batch that audited first and a plain publish do not deadlock on the same workspace" do
    ws = Ecto.UUID.generate()
    parent = self()

    a =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        in_rolled_back_txn(fn ->
          emit!(ws, "batch-earlier-mutation")
          send(parent, :a_holds_audit)

          receive do
            :go_a -> :ok
          end

          DedupWall.lock_publish_scope!("paper", @dataset, workspace_id: ws)
        end)
      end)

    assert_receive :a_holds_audit, 5_000

    b =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        in_rolled_back_txn(fn ->
          DedupWall.lock_publish_scope!("paper", @dataset, workspace_id: ws)
          send(parent, :b_holds_scope)
          emit!(ws, "plain-publish")
        end)
      end)

    # Old order: B takes the scope lock at once and reports it. New order: B is
    # blocked on the audit-chain lock A holds, so nothing arrives.
    b_held_scope_first? =
      receive do
        :b_holds_scope -> true
      after
        500 -> false
      end

    send(a.pid, :go_a)

    results = [Task.await(a, 15_000), Task.await(b, 15_000)]

    refute Enum.any?(results, &match?({:postgres_error, :deadlock_detected}, &1)),
           "the two transactions deadlocked (40P01): #{inspect(results)}"

    assert results == [{:error, :done}, {:error, :done}]

    refute b_held_scope_first?,
           "B took the publish-scope lock while A held the audit-chain lock — the " <>
             "scope lock is not ordered after the audit-chain lock"
  end
end
