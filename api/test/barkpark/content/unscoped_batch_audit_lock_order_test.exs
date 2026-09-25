defmodule Barkpark.Content.UnscopedBatchAuditLockOrderTest do
  @moduledoc """
  task-59136713cece112c — two UNSCOPED mutate batches spanning the same two
  workspaces cannot deadlock on the audit-chain locks.

  `Audit.emit/1` takes the audit-chain lock of the DOCUMENT's workspace and
  holds it to the end of the batch transaction. A batch whose opts carry no
  workspace reads unscoped, so a `delete` (or `publish`) of rows in W1 and W2
  audits under both chains, in mutation order:

      A: delete a1 (W1) ── holds chain(W1) ── parked ──▶ delete a2 (W2): wants chain(W2)
      B: delete b2 (W2) ── holds chain(W2) ── parked ──▶ delete b1 (W1): wants chain(W1)

  Without a serializer that is a 40P01. The fix: an unscoped batch takes the
  GLOBAL audit-chain lock before its first mutation, so B blocks there while A
  runs, and never holds chain(W2) while A needs it.

  Door batches carry a workspace (the /mutate door refuses a key-absent write
  with `workspace_scope_required`) and their reads are fail-closed to it, so
  they audit under one chain and are untouched.

  Deterministic: each batch is parked by the test-only between-mutations
  barrier in `Barkpark.Content.Mutations`, after its first delete. A does not
  continue until B has parked, or 500 ms have passed with B blocked (the fixed
  behaviour). Both batches run inside an outer transaction that is rolled back,
  so the seeded drafts survive the batches and are removed in `on_exit`. The
  seeding's own audit rows are committed; `audit_events` is append-only.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.{Content, Repo, Tenancy}
  alias Barkpark.Content.Document
  alias Ecto.Adapters.SQL.Sandbox

  @dataset "production"
  @type_name "post"
  @barrier :barkpark_mutations_between_barrier

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    tag = System.unique_integer([:positive])

    {:ok, w1} = Tenancy.create_workspace(%{slug: "xws-lock-a-#{tag}", name: "xws a #{tag}"})
    {:ok, w2} = Tenancy.create_workspace(%{slug: "xws-lock-b-#{tag}", name: "xws b #{tag}"})

    ids =
      for {name, ws} <- [a1: w1, a2: w2, b1: w1, b2: w2], into: %{} do
        id = "xws-lock-#{name}-#{tag}"

        {:ok, doc} =
          Content.create_document(
            @type_name,
            %{"doc_id" => id, "title" => "xws #{name}"},
            @dataset,
            workspace_id: ws.id
          )

        assert doc.workspace_id == ws.id
        {name, id}
      end

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      doc_ids = Enum.flat_map(Map.values(ids), &[&1, "drafts." <> &1])
      Repo.delete_all(from(d in Document, where: d.doc_id in ^doc_ids))

      for ws <- [w1, w2] do
        try do
          Repo.delete(ws)
        rescue
          _ -> :ok
        end
      end
    end)

    {:ok, ids: ids, chain_keys: %{w1: chain_key(w1.id), w2: chain_key(w2.id)}}
  end

  # `Audit.lock_chain/1`'s key, so a red names the two locks it deadlocked on.
  defp chain_key(ws_id), do: :erlang.crc32("barkpark.audit.chain:" <> ws_id)

  defp delete(id), do: %{"delete" => %{"id" => id, "type" => @type_name}}

  # An unscoped batch (opts carry no workspace), parked after its first
  # mutation, inside an outer transaction that is rolled back.
  defp parked_batch(parent, name, mutations) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Process.put(@barrier, fn ->
        send(parent, {:parked, name})

        receive do
          {:go, ^name} -> :ok
        end
      end)

      try do
        Repo.transaction(fn ->
          send(parent, {:batch_result, name, Content.apply_mutations(mutations, @dataset, [])})
          Repo.rollback(:done)
        end)
      rescue
        # A deadlock victim's aborted transaction can surface as a raise from a
        # later statement; return it so the assertions below can name it.
        e -> {:raised, Exception.message(e) |> String.slice(0, 300)}
      end
    end)
  end

  test "two unscoped batches over W1 and W2 in opposite order do not deadlock",
       %{ids: ids, chain_keys: keys} do
    parent = self()

    {outcome, log} =
      with_log(fn ->
        a = parked_batch(parent, :a, [delete(ids.a1), delete(ids.a2)])
        assert_receive {:parked, :a}, 10_000

        b = parked_batch(parent, :b, [delete(ids.b2), delete(ids.b1)])

        # Old behaviour: B takes chain(W2) at once and parks. New: B waits on
        # the global serializer A holds, so it cannot park yet.
        b_parked_while_a_held? =
          receive do
            {:parked, :b} -> true
          after
            500 -> false
          end

        send(a.pid, {:go, :a})
        send(b.pid, {:go, :b})

        {Task.await(a, 20_000), Task.await(b, 20_000), b_parked_while_a_held?}
      end)

    {a_txn, b_txn, b_parked_while_a_held?} = outcome
    results = for name <- [:a, :b], do: receive_result(name)

    refute log =~ "deadlock_detected",
           "the two unscoped batches deadlocked (40P01) on the audit-chain locks " <>
             "(chain(W1) = #{keys.w1}, chain(W2) = #{keys.w2}):\n" <> deadlock_lines(log)

    assert {a_txn, b_txn} == {{:error, :done}, {:error, :done}}
    assert Enum.all?(results, &match?({:ok, _}, &1)), "batch results: #{inspect(results)}"

    refute b_parked_while_a_held?,
           "B ran its first mutation while A held its own — the unscoped batches are not serialized"
  end

  defp receive_result(name) do
    receive do
      {:batch_result, ^name, result} -> result
    after
      0 -> :no_result
    end
  end

  defp deadlock_lines(log) do
    log
    |> String.split("\n")
    |> Enum.flat_map(&Regex.scan(~r/detail: "[^"]*"/, &1))
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.join("\n")
  end
end
