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

      # Optional deterministic dwell. `post/3` runs inside the INNER
      # `WebhookDeliverySupervisor` task, which the OUTER `fan_out/3` task is
      # blocked on — so sleeping here guarantees the outer supervised task is
      # still alive to be INSPECTED. The attribution positive control needs
      # that; without it the task can die between `start_child` returning and
      # `Process.info/2` sampling, and the control would pass vacuously.
      case Application.get_env(:barkpark, :audit_dispatch_test_dwell_ms) do
        ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
        _ -> :ok
      end

      {:ok, 200}
    end
  end

  setup do
    prev = Application.get_env(:barkpark, :webhook_http_adapter)

    # `fetch_env/2`, not `get_env/2`. The SSRF kill switch is a BOOLEAN: a
    # `false` default is indistinguishable from "never set", and putting an
    # explicit `false` back where there was no key leaves the guard in a state
    # this module chose rather than the one it found.
    prev_private = Application.fetch_env(:barkpark, :allow_private_outbound)

    Application.put_env(:barkpark, :webhook_http_adapter, PidEcho)
    Application.put_env(:barkpark, :audit_dispatch_test_pid, self())
    Application.put_env(:barkpark, :allow_private_outbound, true)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :webhook_http_adapter, prev),
        else: Application.delete_env(:barkpark, :webhook_http_adapter)

      # Application env is VM-global. Leaked ON, the SSRF guard is disarmed for
      # whatever module ExUnit shuffles in next, and one of its tests can then
      # pass for the wrong reason.
      case prev_private do
        {:ok, v} -> Application.put_env(:barkpark, :allow_private_outbound, v)
        :error -> Application.delete_env(:barkpark, :allow_private_outbound)
      end

      Application.delete_env(:barkpark, :audit_dispatch_test_pid)
      Application.delete_env(:barkpark, :audit_dispatch_test_dwell_ms)
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

  # `Barkpark.TaskSupervisor` is SHARED — 20+ production spawners use it. A
  # bracket-and-diff is robust against tasks that were ALREADY there when we
  # sampled, but NOT against one another spawner starts INSIDE the measured
  # window: that lands in the diff and reds this file on work the audit path
  # never did. No budget fixes that; only ATTRIBUTION does.
  defp supervisor_children do
    Barkpark.TaskSupervisor |> Task.Supervisor.children() |> MapSet.new()
  end

  # Raw diff — kept ONLY so the negative control below can show the
  # interference is real (a decoy DOES land here) before showing that
  # attribution ignores it.
  defp new_tasks(before) do
    Barkpark.TaskSupervisor
    |> Task.Supervisor.children()
    |> MapSet.new()
    |> MapSet.difference(before)
  end

  # The new tasks ATTRIBUTABLE to the audit fan-out, by the code identity of
  # the function each task was spawned with.
  #
  # `Task.Supervisor.start_child(sup, fun)` makes `Task.Supervised` stash
  # `{module, name, 0}` of that fun under `:"$initial_call"` in the child's
  # process dictionary (this is what `:proc_lib.initial_call/1` reads). The
  # audit fan-out's task is the closure defined in
  # `Barkpark.Webhooks.Dispatcher.fan_out/3`, so its module is the Dispatcher
  # — and a task spawned by any OTHER caller (or by a test decoy) carries that
  # other module and is correctly ignored.
  @dispatcher Barkpark.Webhooks.Dispatcher

  defp audit_dispatch_tasks(before) do
    before |> new_tasks() |> Enum.filter(&spawned_by_dispatcher?/1)
  end

  defp spawned_by_dispatcher?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        # `List.keyfind/3`, not `Keyword.get/2`: a process dictionary is a plain
        # 2-tuple list whose keys are not all atoms.
        case List.keyfind(dict, :"$initial_call", 0) do
          {_key, {mod, _fun, _arity}} -> mod == @dispatcher
          _ -> false
        end

      # Already exited between `children/0` and this sample — it cannot be a
      # live leak past the sandbox owner, which is the whole point of the
      # assertion. `:audit_dispatch_test_dwell_ms` keeps a task we DO want to
      # inspect alive; see the positive control.
      nil ->
        false
    end
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
      before = supervisor_children()

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

      # NO fire-and-forget task was spawned BY THE AUDIT FAN-OUT → nothing of
      # ours can outlive the sandbox owner and deadlock a concurrent DDL test.
      # Attribution, not a raw count: `Barkpark.TaskSupervisor` is shared with
      # 20+ production spawners, and a task one of THEM starts inside this
      # window is not evidence about this code path. The positive control in
      # the async describe proves this filter still catches a real audit spawn.
      assert audit_dispatch_tasks(before) == [],
             "the audit fan-out spawned a supervised task under the sync toggle"

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
      before = supervisor_children()
      assert :ok = Dispatcher.dispatch_audit_async(event_for(org))

      refute_received {:delivered, _, _}
      assert audit_dispatch_tasks(before) == []
    end

    test "a concurrent UNRELATED task on the shared supervisor is not attributed here",
         %{org: org} do
      # NEGATIVE CONTROL for the attribution filter. This is the interference
      # that reds the raw-count form of the assertion above: `Audit.emit` is
      # not the only caller of `Barkpark.TaskSupervisor`, and a task another
      # spawner starts inside the bracketed window lands in the diff.
      _wh = audit_sub(org)
      before = supervisor_children()

      {:ok, decoy} =
        Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn -> Process.sleep(5_000) end)

      on_exit(fn -> Process.exit(decoy, :kill) end)

      {:ok, _event} =
        Audit.emit(%{
          category: "auth",
          action: "sso_login",
          subject: "u-decoy",
          metadata: %{"organization_id" => org.id}
        })

      # The interference is REAL: the raw diff this assertion used to be sees
      # the decoy and would report a leak the audit path never caused.
      assert decoy in new_tasks(before),
             "decoy did not land on the shared supervisor — this control proves nothing"

      # Attribution ignores it: the decoy's `$initial_call` names THIS module,
      # not Barkpark.Webhooks.Dispatcher.
      assert audit_dispatch_tasks(before) == []
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

    test "POSITIVE CONTROL: attribution still SEES a genuine audit spawn", %{org: org} do
      # Without this, `audit_dispatch_tasks/1 == []` in the sync describe could
      # be vacuous — a filter that matches nothing passes for the wrong reason.
      # Here the audit path REALLY spawns, and the same filter must catch it.
      _wh = audit_sub(org)
      Application.put_env(:barkpark, :audit_dispatch_async, true)
      # Hold the inner delivery so the OUTER fan-out task is guaranteed alive
      # while we inspect its `$initial_call` — otherwise a fast task could die
      # first and this control would "pass" on an empty diff.
      Application.put_env(:barkpark, :audit_dispatch_test_dwell_ms, 300)

      on_exit(fn ->
        Application.put_env(:barkpark, :audit_dispatch_async, false)
        Application.delete_env(:barkpark, :audit_dispatch_test_dwell_ms)
      end)

      before = supervisor_children()
      assert {:ok, pid} = Dispatcher.dispatch_audit_async(event_for(org))

      assert pid in audit_dispatch_tasks(before),
             "the attribution filter missed a task the audit fan-out really spawned — " <>
               "the sync-path assertion it guards would then be unfailable"

      assert_receive {:delivered, "https://sink.example/hook", _body}, 2000
    end
  end
end
