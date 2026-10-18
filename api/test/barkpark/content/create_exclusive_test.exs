defmodule Barkpark.Content.CreateExclusiveTest do
  @moduledoc """
  task-b6f9ff71d96c42aa — two creates of one new id, a moment apart, both answered 200:
  the second was applied as an update over the first (two CI shards both took one
  dataset lease, 2026-10-16). The mutate door's `create` checks the id is free and the
  writer then writes, so a create racing it can land in between, either before the
  writer's own lookup (it updated that row) or while its insert is in flight (the unique
  index refused it, a 422). Either way the loser is the 409 a create of an existing id
  gets, and the winner's document stands.

  The second order is forced, not timed, as in block_ops_if_rev_lock_test.exs: a holder
  takes the workspace's audit-chain lock, writer A inserts and parks on it uncommitted,
  writer B runs until Postgres reports it waiting, then the holder lets go.
  """
  use Barkpark.ConcurrencyCase, async: false

  alias Barkpark.{Audit, Content}

  @type_name "create_excl_post"

  setup %{dataset: dataset} do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Create excl",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        dataset,
        scope
      )

    {:ok, %{ws_id: ws.id, scope: scope}}
  end

  # Runs `fun` on one held connection and reports that connection's backend pid
  # first, so the test can ask Postgres what the writer is waiting on.
  defp writer(fun) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
          send(parent, {:backend, self(), pid})
          fun.()
        end)
      end)

    receive do
      {:backend, tpid, pid} when tpid == task.pid -> {task, pid}
    after
      5_000 -> flunk("writer never reported its backend")
    end
  end

  defp hold_audit_chain!(ws_id) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          :ok = Audit.lock_chain!(ws_id)
          send(parent, :chain_held)

          receive do
            :release -> Repo.rollback(:released)
          after
            30_000 -> Repo.rollback(:holder_timeout)
          end
        end)
      end)

    receive do
      :chain_held -> task
    after
      5_000 -> flunk("holder never took the audit-chain lock")
    end
  end

  defp wait_until_blocked!(_pid, 0), do: flunk("writer never blocked on a lock")

  defp wait_until_blocked!(pid, tries) do
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid]) do
      %{rows: [["Lock"]]} ->
        :ok

      _ ->
        Process.sleep(20)
        wait_until_blocked!(pid, tries - 1)
    end
  end

  defp race!(ws_id, op_a, op_b) do
    holder = hold_audit_chain!(ws_id)
    {a, a_pid} = writer(op_a)
    wait_until_blocked!(a_pid, 250)
    {b, b_pid} = writer(op_b)
    wait_until_blocked!(b_pid, 250)
    send(holder.pid, :release)
    assert {:error, :released} = Task.await(holder, 15_000)
    {Task.await(a, 15_000), Task.await(b, 15_000)}
  end

  defp race!(ws_id, op_a, op_b) do
    holder = hold_audit_chain!(ws_id)
    {a, a_pid} = writer(op_a)
    wait_until_blocked!(a_pid, 250)
    {b, b_pid} = writer(op_b)
    wait_until_blocked!(b_pid, 250)
    send(holder.pid, :release)
    assert {:error, :released} = Task.await(holder, 15_000)
    {Task.await(a, 15_000), Task.await(b, 15_000)}
  end

  defp create(id, title, dataset, scope),
    do: fn ->
      Content.apply_mutations(
        [%{"create" => %{"_id" => "drafts." <> id, "_type" => @type_name, "title" => title}}],
        dataset,
        scope
      )
    end

  test "an exclusive create of an id that exists by the time it writes is a conflict, and changes nothing",
       %{dataset: dataset, scope: scope} do
    id = "excl-#{System.unique_integer([:positive])}"

    {:ok, first} =
      Content.create_document(@type_name, %{"doc_id" => id, "title" => "first"}, dataset, scope)

    assert {:error, :conflict} =
             Content.create_document(
               @type_name,
               %{"doc_id" => id, "title" => "second"},
               dataset,
               scope ++ [exclusive: true]
             )

    {:ok, now} = Content.get_document(first.doc_id, @type_name, dataset, scope)
    assert now.rev == first.rev
    assert now.title == "first"
  end

  test "two mutate creates of one id racing: one lands, the other is a conflict, not an update",
       %{dataset: dataset, ws_id: ws_id, scope: scope} do
    id = "excl-race-#{System.unique_integer([:positive])}"

    {a_result, b_result} =
      race!(ws_id, create(id, "from A", dataset, scope), create(id, "from B", dataset, scope))

    assert {:ok, _} = a_result
    assert {:error, :conflict} = b_result
    {:ok, doc} = Content.get_document("drafts." <> id, @type_name, dataset, scope)
    assert doc.title == "from A"
  end
end
