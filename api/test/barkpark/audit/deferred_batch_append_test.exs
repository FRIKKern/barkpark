defmodule Barkpark.Audit.DeferredBatchAppendTest do
  @moduledoc """
  task-6e2552cdeb223fa2: a mutate batch buffers its audit rows and appends
  them in one insert at commit, so two batches into ONE workspace run their
  writes at the same time, and the workspace's hash chain still verifies.

  Before the change each write appended under the workspace's chain lock and
  held it to commit, so batch B could not finish its first write while batch A
  was still open. The test parks both batches inside their transactions after
  their first mutation (the between-mutations barrier in
  `Barkpark.Content.Mutations`) and asserts that B reaches its park while A is
  parked. Then both commit, and the chain is checked.

  Both batches commit for real, outside the sandbox, in a fresh workspace, so
  the chain under test holds only rows this test wrote. Documents are deleted in
  `on_exit`; `audit_events` is append-only and keeps its rows.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Barkpark.{Audit, Content, Repo, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Content.Document
  alias Ecto.Adapters.SQL.Sandbox

  @dataset "production"
  @type_name "post"
  @barrier :barkpark_mutations_between_barrier

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    tag = System.unique_integer([:positive])

    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "audit-defer-#{tag}", name: "audit defer #{tag}"})

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from(d in Document, where: d.workspace_id == ^ws.id))
    end)

    {:ok, ws: ws, tag: tag}
  end

  defp doc(id), do: %{"createOrReplace" => %{"_id" => id, "_type" => @type_name, "title" => id}}

  # One scoped batch, parked after its first mutation until the test says go.
  defp parked_batch(parent, name, ws, mutations) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Process.put(@barrier, fn ->
        send(parent, {:parked, name})

        receive do
          {:go, ^name} -> :ok
        end
      end)

      Content.apply_mutations(mutations, @dataset, workspace_id: ws.id, source: :api)
    end)
  end

  test "two batches into one workspace overlap, and the chain verifies", %{ws: ws, tag: tag} do
    parent = self()
    ids_a = for i <- 1..3, do: "audit-defer-a-#{tag}-#{i}"
    ids_b = for i <- 1..3, do: "audit-defer-b-#{tag}-#{i}"

    a = parked_batch(parent, :a, ws, Enum.map(ids_a, &doc/1))
    assert_receive {:parked, :a}, 10_000

    b = parked_batch(parent, :b, ws, Enum.map(ids_b, &doc/1))

    # A is open and has written a row. B must still get through its own first
    # write; under a lock held from the first write to commit it waits on A.
    b_parked_while_a_open? =
      receive do
        {:parked, :b} -> true
      after
        3_000 -> false
      end

    send(a.pid, {:go, :a})
    send(b.pid, {:go, :b})

    assert {:ok, _} = Task.await(a, 20_000)
    assert {:ok, _} = Task.await(b, 20_000)

    assert b_parked_while_a_open?,
           "batch B could not write while batch A was open: the batches into one workspace are serialised"

    assert Audit.verify_chain(ws.id) == :ok

    rows =
      Repo.all(
        from(e in Event,
          where: e.workspace_id == type(^ws.id, Ecto.UUID) and e.category == "content_mutation",
          order_by: [asc: e.id],
          select: e.subject
        )
      )

    # Each batch's rows are one contiguous run, appended at its commit.
    assert Enum.sort(rows) == Enum.sort(Enum.map(ids_a ++ ids_b, &("drafts." <> &1)))
    assert Enum.chunk_by(rows, &String.contains?(&1, "-a-")) |> length() == 2
  end

  test "a rolled-back batch appends nothing and leaves the chain valid", %{ws: ws, tag: tag} do
    before =
      Repo.aggregate(from(e in Event, where: e.workspace_id == type(^ws.id, Ecto.UUID)), :count)

    assert {:ok, _} =
             Content.apply_mutations([doc("audit-defer-ok-#{tag}")], @dataset,
               workspace_id: ws.id
             )

    assert {:error, _} =
             Content.apply_mutations(
               [
                 doc("audit-defer-rb-#{tag}"),
                 %{"publish" => %{"id" => "missing-#{tag}", "type" => @type_name}}
               ],
               @dataset,
               workspace_id: ws.id
             )

    after_count =
      Repo.aggregate(from(e in Event, where: e.workspace_id == type(^ws.id, Ecto.UUID)), :count)

    assert after_count == before + 1
    assert Audit.verify_chain(ws.id) == :ok
    refute Audit.deferring?()
  end
end
