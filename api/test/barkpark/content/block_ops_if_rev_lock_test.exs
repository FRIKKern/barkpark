defmodule Barkpark.Content.BlockOpsIfRevLockTest do
  @moduledoc """
  task-6dd00e5b6b33c3c3 — two block-op batches on one document, both fenced on
  the same `ifRev`. One lands; the other must answer
  `{:rev_mismatch, %{actual: <the winner's rev>}}` (HTTP 412
  `precondition_failed` with `details.actual`), never a 422 `invalid_op`.

  The ops paths read the document, compared `ifRev`, folded the ops and only
  then wrote. Nothing held the document between the compare and the write, so
  two batches on a published document with no draft yet both passed the
  compare and both tried to INSERT `drafts.<id>`. The second INSERT hit
  `documents_doc_id_type_dataset_id_index` and came back as a changeset error,
  which the controller answers as 422 "the op could not be applied".

  The interleaving is forced, not timed. A holder transaction takes the
  workspace's audit-chain lock (`Audit.lock_chain!/1`). Writer A inserts its
  draft and then parks on that lock inside its write transaction, draft
  uncommitted. Writer B then runs until Postgres reports it waiting on a lock.
  Releasing the holder lets A commit, and B's answer is the assertion.

  Without the fix B is parked on A's uncommitted draft row in the unique index
  and gets the constraint error. With the fix B is parked on the per-document
  block-ops lock before its read, so it reads after A commits and is refused
  with A's rev.
  """
  use Barkpark.ConcurrencyCase, async: false

  alias Barkpark.{Audit, Content}
  alias Barkpark.Content.{Document, Errors}

  @type_name "blockrev_post"

  setup %{dataset: dataset} do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Block rev post",
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
    id = "blockrev-#{System.unique_integer([:positive])}"

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

  test "field ops: the loser of two same-ifRev batches gets 412 with the winner's rev, not 422",
       %{dataset: dataset, ws_id: ws_id, scope: scope} do
    {id, r0} = published!(dataset, scope, %{"body" => %{"blocks" => [para("p1", "start")]}})

    apply = fn text ->
      fn ->
        Content.apply_field_block_ops(
          id,
          @type_name,
          "body",
          [patch_text("p1", text)],
          dataset,
          scope ++ [if_rev: r0]
        )
      end
    end

    {a_result, b_result} = race!(ws_id, apply.("from A"), apply.("from B"))

    assert {:ok, %{rev: r1, written_doc_id: "drafts." <> ^id}} = a_result
    assert_412_with_actual(b_result, r0, r1)

    {:ok, draft} = Content.get_document("drafts." <> id, @type_name, dataset, scope)
    assert draft.rev == r1
    assert [%{"content" => [%{"value" => "from A"}]}] = draft.content["body"]["blocks"]
  end

  test "document ops: the loser of two same-ifRev batches gets 412 with the winner's rev, not 422",
       %{dataset: dataset, ws_id: ws_id, scope: scope} do
    {id, r0} = published!(dataset, scope, %{"blocks" => [para("p1", "start")]})

    apply = fn text ->
      fn ->
        Content.apply_document_block_ops(
          id,
          @type_name,
          [patch_text("p1", text)],
          dataset,
          scope ++ [if_rev: r0]
        )
      end
    end

    {a_result, b_result} = race!(ws_id, apply.("from A"), apply.("from B"))

    assert {:ok, %{rev: r1, written_doc_id: "drafts." <> ^id}} = a_result
    assert_412_with_actual(b_result, r0, r1)
  end
end
