defmodule Barkpark.Content.DedupAuditLockOrderTest do
  @moduledoc """
  task-0c397ec87de1f924 — the publish-scope lock and the audit-chain lock are
  taken in ONE order.

  Two transactions in the same workspace, each on its own unboxed connection:

      A: Audit.emit(ws)            ── holds audit(ws)
                                       B: recheck_dedup(doc in ws) ── holds dedup?
      A: recheck_dedup(doc in ws)  ── wants dedup
                                       B: Audit.emit(ws)           ── wants audit(ws)

  A is a mutate batch that audited an earlier mutation and then publishes; B is
  a plain publish (scope lock, then the audit emit in `tap_broadcast`). With the
  scope lock taken before the audit lock, B gets the scope lock and the four
  steps deadlock (Postgres 40P01). With the audit lock taken first (inside
  `DedupWall.lock_publish_scope!/3`, keyed on the workspace
  `AuthoringWall.recheck_dedup_under_scope_lock/5` passes), B blocks on
  audit(ws) before it can hold the scope lock, A finishes, then B finishes.

  The caller opts carry NO workspace, only the document does, as on a publish
  whose request scope is unset: the audit emit keys on the document's
  workspace, so the pre-lock must too. Keying it on the opts instead turned the
  cycle into audit(ws) against audit(global) in the papers suite.

  Deterministic: A does not request the scope lock until B has reported holding
  it, or 500 ms have passed with B blocked (the fixed ordering). Both
  transactions roll back, so no audit row is committed.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Audit
  alias Barkpark.Content.{AuthoringWall, Document}
  alias Barkpark.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @dataset "production"

  defp publish_recheck!(ws, title) do
    ref = %Document{
      doc_id: "lock-order-#{System.unique_integer([:positive])}",
      type: "paper",
      dataset: @dataset,
      title: title,
      content: %{},
      workspace_id: ws
    }

    :ok = AuthoringWall.recheck_dedup_under_scope_lock(ref, "paper", ref.doc_id, @dataset, [])
  end

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

          publish_recheck!(ws, "Batch publish #{ws}")
        end)
      end)

    assert_receive :a_holds_audit, 5_000

    b =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        in_rolled_back_txn(fn ->
          publish_recheck!(ws, "Plain publish #{ws}")
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

defmodule Barkpark.Content.PublishAuditChainKeyTest do
  @moduledoc """
  task-962637a90e406961 — a publish takes ONE audit-chain lock, and the global
  and Default chains share it.

  THE PUBLISH. A workspace-less draft publishes into the workspace
  `WriteScope` resolves for it. The dedup re-check pre-locked the chain of the
  DRAFT's workspace (global), and `tap_broadcast` then emitted on the PUBLISHED
  row's workspace: two chains in one transaction. The plugins-off weekly run
  hit it (run 36650351431) with the Default as the destination:

      Process 10354 waits for ... advisory lock [16384,0,485729316,1]  audit(Default)
      Process 10353 waits for ... advisory lock [16384,0,2301988177,1] audit(global)
      audit emit crashed for repair-legacy: ... deadlock_detected

  The re-check now keys on the destination. The tests below publish into a
  workspace of their own, because global and the Default now share a lock
  (next paragraph) and would hide the two-chain shape.

  THE SHARED LOCK. Global and the Default are two hash chains that writers
  touch together, so `Audit.lock_chain!/1` takes one lock for both. An async
  test is one open sandbox transaction to its end, so two tests that touched
  them in opposite orders deadlocked each other too.

  Each process below checks out its OWN sandbox connection, so each is one
  open transaction to the end of its turn, exactly as two async tests are.
  """
  use ExUnit.Case, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Audit
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.LabelFixtures
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Ecto.Adapters.SQL.Sandbox

  @dataset "publish_audit_chain_key_test"

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  defp chain_key(ws), do: :erlang.crc32("barkpark.audit.chain:" <> (ws || "\x00global"))

  defp held_advisory_keys do
    Repo.query!(
      "SELECT objid FROM pg_locks WHERE locktype = 'advisory' AND classid = 0 " <>
        "AND pid = pg_backend_pid()"
    ).rows
    |> List.flatten()
  end

  # A one-workspace principal: a workspace-less draft published with only
  # `user_id` in opts is INFERRED into that workspace (WriteScope), a
  # destination other than the Default.
  defp tenant! do
    ws = create_workspace!()
    _ = create_project!(ws, "default")

    user =
      Barkpark.AccountsFixtures.register_user(
        "chain-key-#{System.unique_integer([:positive])}@example.com"
      )

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    {ws.id, [user_id: user.id]}
  end

  defp insert_unscoped_draft!(id) do
    block = %{
      "type" => "table",
      "id" => "t1",
      "head" => [[%{"type" => "text", "value" => "A"}], [%{"type" => "text", "value" => "B"}]],
      "rows" => [[[%{"type" => "text", "value" => id}], [%{"type" => "text", "value" => "d"}]]]
    }

    content = LabelFixtures.with_registered_labels(%{"blocks" => [block]}, @dataset)

    %Document{}
    |> Document.changeset(%{
      "doc_id" => "drafts." <> id,
      "type" => "paper",
      "dataset" => @dataset,
      "title" => "Unscoped draft #{id}",
      "status" => "draft",
      "content" => content,
      "rev" => "rev-" <> id
    })
    |> Repo.insert!()
  end

  test "the global chain and the seated Default's chain take one lock" do
    default_ws = Tenancy.get_default_workspace().id

    {:ok, _} = Audit.emit(%{category: "content_mutation", action: "probe.g", workspace_id: nil})
    assert held_advisory_keys() == [chain_key(default_ws)]

    {:ok, _} =
      Audit.emit(%{category: "content_mutation", action: "probe.d", workspace_id: default_ws})

    assert held_advisory_keys() == [chain_key(default_ws)]
  end

  test "publishing a workspace-less draft locks only the audit chain it emits on" do
    {ws, opts} = tenant!()
    id = "chain-key-#{System.unique_integer([:positive])}"
    draft = insert_unscoped_draft!(id)
    assert draft.workspace_id == nil

    assert {:ok, published} = Content.publish_document(id, "paper", @dataset, opts)
    assert published.workspace_id == ws

    held = held_advisory_keys()
    shared = chain_key(Tenancy.get_default_workspace().id)

    assert chain_key(published.workspace_id) in held

    refute shared in held,
           "the publish took the global/Default audit lock for a row it audits under " <>
             "#{published.workspace_id}: two audit chains in one transaction"
  end

  test "a workspace-less publish and a writer holding the destination's chain do not deadlock" do
    parent = self()

    # B: seats its own tenant (no audit emitted), inserts a workspace-less
    # draft, and publishes it into that tenant when told to.
    b =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo)
        {ws, opts} = tenant!()
        id = "chain-key-dl-#{System.unique_integer([:positive])}"
        insert_unscoped_draft!(id)
        %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:b_ready, ws, pid, held_advisory_keys()})

        receive do
          :go_b -> :ok
        end

        result = Content.publish_document(id, "paper", @dataset, opts)
        Sandbox.checkin(Repo)
        result
      end)

    assert_receive {:b_ready, ws, b_pid, b_held}, 10_000
    assert b_held == [], "B's setup already holds advisory locks: #{inspect(b_held)}"

    # A: holds audit(ws) first, then needs audit(global). audit_events has no
    # FK, so A can emit on B's uncommitted workspace id.
    a =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo)

        result =
          try do
            {:ok, _} =
              Audit.emit(%{category: "content_mutation", action: "probe.a1", workspace_id: ws})

            send(parent, :a_holds_ws)

            receive do
              :go_a -> :ok
            end

            {:ok, _} =
              Audit.emit(%{category: "content_mutation", action: "probe.a2", workspace_id: nil})

            :ok
          rescue
            e in Postgrex.Error -> {:postgres_error, e.postgres[:code]}
          end

        Sandbox.checkin(Repo)
        result
      end)

    assert_receive :a_holds_ws, 5_000
    send(b.pid, :go_b)

    # Release A only once B is parked on a lock A holds, so the interleaving
    # is fixed: B waits on audit(ws) either way — before the fix it already
    # holds audit(global) while it waits.
    wait_until_blocked!(b_pid, 100)
    send(a.pid, :go_a)

    a_result = Task.await(a, 15_000)
    b_result = Task.await(b, 15_000)

    refute a_result == {:postgres_error, :deadlock_detected},
           "A was the 40P01 victim: B held audit(global) while waiting for audit(ws)"

    assert a_result == :ok
    assert {:ok, %Document{}} = b_result
  end

  defp wait_until_blocked!(_pid, 0), do: flunk("the publish never blocked on audit(ws)")

  defp wait_until_blocked!(pid, tries) do
    %{rows: rows} =
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid])

    if rows == [["Lock"]] do
      :ok
    else
      Process.sleep(50)
      wait_until_blocked!(pid, tries - 1)
    end
  end
end
