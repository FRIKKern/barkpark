defmodule Barkpark.Webhooks.AuditDispatchTest do
  @moduledoc """
  Protective gate for the audit-webhook fan-out MODE (`:audit_dispatch_async`).

  ## The failure this pins closed

  `Audit.emit/1` post-commit bridges to any matching audit-webhook subscription
  via `Dispatcher.dispatch_audit_async/1`. The old (and prod) path spawns an
  UNAWAITED `Task.Supervisor.start_child` on the shared `Barkpark.TaskSupervisor`
  so a slow endpoint never blocks emit. In the SUITE that fire-and-forget task is
  a menace: the `DataCase` drain is scoped to the ORIGINATING test, and ExUnit
  gives no ordering guarantee the leaked task finishes before a CONCURRENT raw-DDL
  test (`extend_workspace_delete_cascade_test`, which `ALTER TABLE`s webhooks /
  search_synonyms) opens its window. The leaked audit SELECT holds an
  AccessShareLock on those very tables; the DDL wants an AccessExclusiveLock →
  Postgrex `40P01` (deadlock detected), a rare (<1-in-2) but real flake.

  The fix wires `:audit_dispatch_async` (default TRUE; config/test.exs sets it
  FALSE) so under test the fan-out runs SYNCHRONOUSLY in the caller's process —
  owner-scoped, joins the sandbox connection, dies with the test, leaks nothing.

  This test proves the sync toggle: after an `Audit.emit` that matches a
  subscription, delivery ran INLINE (the message is already in the mailbox with
  zero wait) and NO new task was spawned on `Barkpark.TaskSupervisor`.

  Fail-before (revert the sync branch and this file goes RED): under the async
  spawn the inline `assert_received` finds no message yet (delivery is deferred to
  the spawned task) and a fresh task appears on the supervisor.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Audit, Tenancy, Webhooks}
  alias Barkpark.Webhooks.Dispatcher

  # An adapter whose post/3 echoes to a pid in config so a synchronous delivery
  # is observable in-mailbox the instant the fan-out returns.
  defmodule PidEcho do
    def post(url, body, _headers) do
      case Application.get_env(:barkpark, :audit_dispatch_test_pid) do
        pid when is_pid(pid) -> send(pid, {:delivered, url, body})
        _ -> :ok
      end

      {:ok, 200}
    end
  end

  setup do
    prev = Application.get_env(:barkpark, :webhook_http_adapter)
    Application.put_env(:barkpark, :webhook_http_adapter, PidEcho)
    Application.put_env(:barkpark, :audit_dispatch_test_pid, self())
    Application.put_env(:barkpark, :allow_private_outbound, true)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :webhook_http_adapter, prev),
        else: Application.delete_env(:barkpark, :webhook_http_adapter)

      Application.delete_env(:barkpark, :audit_dispatch_test_pid)
    end)

    {:ok, org} = Tenancy.create_organization(%{slug: "auditdisp", name: "Audit Disp"})
    %{org: org}
  end

  defp audit_sub(org) do
    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => "audit-disp-sub",
        "url" => "https://sink.example/hook",
        "secret" => "sek",
        "audit_categories" => ["auth"],
        "organization_id" => org.id
      })

    wh
  end

  # A hand-built %Audit.Event{} (NOT via Audit.emit) so a test can call
  # `dispatch_audit_async/1` in isolation — emit ITSELF post-commit-dispatches
  # (inline, under the test's sync toggle), which would double-deliver if a test
  # then dispatched the returned event again.
  defp event_for(org) do
    %Barkpark.Audit.Event{
      id: System.unique_integer([:positive]),
      category: "auth",
      action: "sso_login",
      subject: "u-direct",
      metadata: %{"organization_id" => org.id},
      occurred_at: DateTime.utc_now()
    }
  end

  # Only the tasks THIS dispatch adds — robust against any pre-existing task on
  # the shared supervisor at the moment we sample.
  defp new_tasks(before) do
    Barkpark.TaskSupervisor
    |> Task.Supervisor.children()
    |> MapSet.new()
    |> MapSet.difference(before)
  end

  describe "sync toggle (:audit_dispatch_async false) — the leak-proof path" do
    test "the test env runs the audit fan-out synchronously", _ do
      # The whole point: config/test.exs pins this false. If a future edit flips
      # it (or drops the key), the sync guarantees below evaporate — pin it here.
      refute Application.get_env(:barkpark, :audit_dispatch_async, true),
             ":audit_dispatch_async must be false in test.exs so the audit fan-out " <>
               "runs inline (no leaked task to deadlock a concurrent DDL test)"
    end

    test "Audit.emit delivers INLINE and spawns NO supervised task", %{org: org} do
      wh = audit_sub(org)

      # Bracket the WHOLE emit: under the sync toggle its post-commit bridge runs
      # the fan-out inline, so no fire-and-forget task should ever land on the
      # shared supervisor.
      before = Barkpark.TaskSupervisor |> Task.Supervisor.children() |> MapSet.new()

      {:ok, _event} =
        Audit.emit(%{
          category: "auth",
          action: "sso_login",
          subject: "u-inline",
          metadata: %{"organization_id" => org.id}
        })

      # INLINE delivery: the echo is already in the mailbox with ZERO wait — the
      # sync toggle delivered before emit returned. Under the async spawn this
      # message would NOT have arrived yet → fail-before.
      assert_received {:delivered, "https://sink.example/hook", body}
      assert Jason.decode!(body)["action"] == "sso_login"

      # NO fire-and-forget task was spawned → nothing can outlive the sandbox
      # owner and deadlock a concurrent DDL test.
      assert MapSet.size(new_tasks(before)) == 0

      # Exactly ONE durable audit delivery row (source_kind "audit"), proving the
      # inline path went through the same state machine as the async one.
      import Ecto.Query

      assert [d] =
               Barkpark.Repo.all(
                 from d in Barkpark.Webhooks.Delivery, where: d.endpoint_id == ^wh.id
               )

      assert d.source_kind == "audit"
      assert d.status == "ok"
    end

    test "dispatch on a no-subscription event is an inline no-op", %{org: org} do
      # No matching audit webhook exists — audit_targets returns []; the inline
      # fan-out is a no-op: no delivery, no task.
      before = Barkpark.TaskSupervisor |> Task.Supervisor.children() |> MapSet.new()
      assert :ok = Dispatcher.dispatch_audit_async(event_for(org))

      refute_received {:delivered, _, _}
      assert MapSet.size(new_tasks(before)) == 0
    end

    test "dispatch returns :ok (inline), never a spawned-task tuple", %{org: org} do
      _wh = audit_sub(org)
      # The sync toggle's return contract: :ok (ran inline), distinct from the
      # async path's start_child {:ok, pid}.
      assert :ok = Dispatcher.dispatch_audit_async(event_for(org))
      assert_received {:delivered, "https://sink.example/hook", _body}
    end
  end

  describe "async toggle (:audit_dispatch_async true) — the prod path still fans out" do
    test "with the flag true the dispatch spawns a supervised task (not inline)", %{org: org} do
      _wh = audit_sub(org)
      Application.put_env(:barkpark, :audit_dispatch_async, true)
      on_exit(fn -> Application.put_env(:barkpark, :audit_dispatch_async, false) end)

      # Direct dispatch of a hand-built event so we observe the raw return: the
      # start_child {:ok, pid} tuple, NOT :ok, and delivery deferred to the
      # spawned task. The task carries this test's $callers, so the DataCase
      # drain still awaits it before stopping the sandbox owner.
      assert {:ok, pid} = Dispatcher.dispatch_audit_async(event_for(org))
      assert is_pid(pid)
      # Not delivered synchronously — it runs on the spawned task.
      refute_received {:delivered, _, _}
      assert_receive {:delivered, "https://sink.example/hook", _body}, 2000
    end
  end
end
