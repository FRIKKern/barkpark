defmodule Barkpark.Content.MutateDraftForkRaceTest do
  @moduledoc """
  task-128cda41162676e3, the mutate side. A field op forks `drafts.<id>` of a
  published document; a mutate patch on the same document reads the published
  row a moment later and tries to fork the same draft. It lost the INSERT in
  the unique index and answered a changeset error (422 `invalid_op`). The
  document moved under the batch, so the batch runs once more: fenced on the
  published rev it is refused with the draft's rev (412, `details.actual`),
  unfenced it lands on the draft the op made.

  The interleaving is forced as in `BlockOpsIfRevLockTest`: the op inserts its
  draft and parks on the held audit-chain lock, draft uncommitted; the mutate
  then runs until Postgres shows it waiting on the op's row in the unique index.
  """
  use Barkpark.ConcurrencyCase, async: false

  alias Barkpark.{Audit, Content}
  alias Barkpark.Content.{Document, Errors}

  @type_name "forkrace_post"

  setup %{dataset: dataset} do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Fork race post",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "body",
              "type" => "richText",
              "editor" => "blocks",
              "blocks" => %{"styles" => ["normal"]}
            }
          ]
        },
        dataset,
        scope
      )

    {:ok, %{ws_id: ws.id, scope: scope}}
  end

  defp para(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp patch_text(id, text),
    do: %{"op" => "patch-block", "id" => id, "patch" => %{"content" => para(id, text)["content"]}}

  # A published document with no draft: the shape where both writers fork the
  # draft. Asserted, not assumed.
  defp published!(dataset, scope, content) do
    id = "forkrace-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => id, "title" => "race", "content" => content},
        dataset,
        scope
      )

    {:ok, _} = Content.publish_document(id, @type_name, dataset, scope)

    {:ok, %Document{status: "published", rev: rev}} =
      Content.get_document(id, @type_name, dataset, scope)

    assert {:error, :not_found} =
             Content.get_document("drafts." <> id, @type_name, dataset, scope)

    {id, rev}
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

  defp assert_412_with_actual(result, expected, actual) do
    assert {:error, {:rev_mismatch, %{expected: ^expected, actual: ^actual}}} = result

    assert %{status: 412, code: "precondition_failed", details: %{actual: ^actual}} =
             Errors.to_envelope(result)
  end

  defp op(id, r0, dataset, scope) do
    fn ->
      Content.apply_field_block_ops(
        id,
        @type_name,
        "body",
        [patch_text("p1", "mine")],
        dataset,
        scope ++ [if_rev: r0]
      )
    end
  end

  defp mutate(patch, dataset, scope) do
    fn -> Content.apply_mutations([%{"patch" => patch}], dataset, scope) end
  end

  test "a mutate fenced on the published rev that loses the draft fork to a field op gets 412 with the draft's rev, not 422",
       %{dataset: dataset, ws_id: ws_id, scope: scope} do
    {id, r0} = published!(dataset, scope, %{"body" => %{"blocks" => [para("p1", "start")]}})

    patch = %{
      "id" => id,
      "type" => @type_name,
      "ifRevisionID" => r0,
      "set" => %{"title" => "theirs"}
    }

    {op_result, mutate_result} =
      race!(ws_id, op(id, r0, dataset, scope), mutate(patch, dataset, scope))

    assert {:ok, _} = op_result
    {:ok, draft} = Content.get_document("drafts." <> id, @type_name, dataset, scope)
    assert_412_with_actual(mutate_result, r0, draft.rev)
    assert draft.title == "race"
    assert [%{"content" => [%{"value" => "mine"}]}] = draft.content["body"]["blocks"]
  end

  test "an unfenced mutate that loses the draft fork to a field op lands on the op's draft",
       %{dataset: dataset, ws_id: ws_id, scope: scope} do
    {id, r0} = published!(dataset, scope, %{"body" => %{"blocks" => [para("p1", "start")]}})
    patch = %{"id" => id, "type" => @type_name, "set" => %{"title" => "theirs"}}

    {op_result, mutate_result} =
      race!(ws_id, op(id, r0, dataset, scope), mutate(patch, dataset, scope))

    assert {:ok, _} = op_result
    assert {:ok, _} = mutate_result
    {:ok, draft} = Content.get_document("drafts." <> id, @type_name, dataset, scope)
    assert draft.title == "theirs"
    assert [%{"content" => [%{"value" => "mine"}]}] = draft.content["body"]["blocks"]
  end
end
