defmodule Barkpark.Accounts.UserNotifierTest do
  @moduledoc """
  NAMED FAILURE MODE: synchronous external I/O in a request path. The core-auth
  transactional emails used to call `Mailer.deliver` inline, so a stalled SMTP
  relay would block login / registration / reset up to gen_smtp's timeout. They
  now offload delivery to `Barkpark.TaskSupervisor` and return `{:ok, email}`
  immediately.

  These tests guard the offload contract:

    * the email is STILL delivered — through the supervised task, not inline
      (the offload isn't a silent drop);
    * a *failed* deliver still leaves a diagnostic log line (email type + reason),
      now emitted INSIDE the task;
    * that failure log never leaks the recipient address (PII);
    * the caller-visible return is fail-soft (`{:ok, _}` regardless of relay
      health) so the controller's anti-enumeration 200 is unchanged — and the
      request can no longer even observe the delivery outcome.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  alias Barkpark.Accounts.UserNotifier

  describe "delivery offload (success path, real Swoosh test adapter)" do
    # config/test.exs already sets adapter: Swoosh.Adapters.Test, which delivers
    # {:email, email} to every process in the $callers chain. `Task.*` propagates
    # $callers, so the task's delivery lands in THIS test process.

    test "the email is delivered through the supervised offload, not inline" do
      assert {:ok, email} =
               UserNotifier.deliver_reset("user@example.com", "https://x/auth/reset/tok")

      # Delivery rides a background task — assert_receive (with a timeout) waits
      # for it rather than assert_received (zero-timeout), which would race the
      # offload and prove nothing.
      assert_receive {:email, delivered}, 1_000
      assert delivered == email
      assert {_, "user@example.com"} = hd(delivered.to)
      assert delivered.subject == "Reset your Barkpark password"
      assert delivered.text_body =~ "https://x/auth/reset/tok"
    end
  end

  describe "failure observability (down relay)" do
    # A Swoosh adapter that always fails, simulating a down relay. It also pings
    # the $callers chain so the test can deterministically await the offload task
    # having *attempted* delivery before it inspects the captured log.
    defmodule DownRelayAdapter do
      def validate_config(_config), do: :ok
      def validate_dependency, do: :ok

      def deliver(_email, _config) do
        for pid <- Enum.uniq([self() | List.wrap(Process.get(:"$callers"))]),
            do: send(pid, :relay_attempted)

        {:error, :relay_down}
      end

      def deliver_many(_emails, _config), do: {:error, :relay_down}
    end

    setup do
      original = Application.get_env(:barkpark, Barkpark.Mailer)
      Application.put_env(:barkpark, Barkpark.Mailer, adapter: DownRelayAdapter)
      on_exit(fn -> Application.put_env(:barkpark, Barkpark.Mailer, original) end)
      :ok
    end

    test "a failed deliver logs a diagnostic line (subject + reason) from inside the task, and stays fail-soft" do
      log =
        capture_log(fn ->
          base = length(Task.Supervisor.children(Barkpark.TaskSupervisor))

          # Fail-soft: the caller sees {:ok, _} even though the relay is down —
          # the request can't observe the failure, so it can't leak existence.
          assert {:ok, _email} =
                   UserNotifier.deliver_reset("user@example.com", "https://x/auth/reset/tok")

          # The offload actually ran the delivery (positive proof), then drained.
          assert_receive :relay_attempted, 1_000
          await_offload_drained(base)
          Logger.flush()
        end)

      assert log =~ "transactional email delivery failed"
      assert log =~ "Reset your Barkpark password"
      assert log =~ ":relay_down"
    end

    test "the failure log does NOT leak the recipient address (PII)" do
      log =
        capture_log(fn ->
          base = length(Task.Supervisor.children(Barkpark.TaskSupervisor))

          UserNotifier.deliver_confirmation("secret-person@example.com", "https://x/confirm/tok")

          assert_receive :relay_attempted, 1_000
          await_offload_drained(base)
          Logger.flush()
        end)

      assert log =~ "transactional email delivery failed"
      refute log =~ "secret-person@example.com"
    end
  end

  # Poll until the supervised offload task has exited (child count back to the
  # pre-delivery baseline). `start_child` returns only after the child is
  # registered, so a lingering child means the task is still running; once it
  # drops the task has finished and its Logger.error is enqueued (Logger.flush
  # then guarantees it is captured).
  defp await_offload_drained(baseline, retries \\ 400)
  defp await_offload_drained(_baseline, 0), do: flunk("offload task did not drain in time")

  defp await_offload_drained(baseline, retries) do
    if length(Task.Supervisor.children(Barkpark.TaskSupervisor)) <= baseline do
      :ok
    else
      Process.sleep(5)
      await_offload_drained(baseline, retries - 1)
    end
  end

  describe "undeliverable configuration (no relay at all)" do
    # The asymmetry this closes: the DownRelayAdapter block above already proved
    # a configured-but-broken relay is logged. An instance that never set
    # SMTP_HOST runs Swoosh.Adapters.Local, whose deliver/2 returns {:ok, _} —
    # so the notifier took the success branch and produced NO log line at all.
    # The transient failure was observable; the permanent one was not.
    setup do
      original = Application.get_env(:barkpark, Barkpark.Mailer)
      Application.put_env(:barkpark, Barkpark.Mailer, adapter: Swoosh.Adapters.Local)
      Swoosh.Adapters.Local.Storage.Memory.delete_all()
      on_exit(fn -> Application.put_env(:barkpark, Barkpark.Mailer, original) end)
      :ok
    end

    test "a send with no deliverable adapter logs that it was NOT delivered" do
      log =
        capture_log(fn ->
          base = length(Task.Supervisor.children(Barkpark.TaskSupervisor))

          assert {:ok, _email} =
                   UserNotifier.deliver_magic_link("user@example.com", "https://x/auth/magic/tok")

          await_offload_drained(base)
          Logger.flush()
        end)

      assert log =~ "NOT DELIVERED"
      assert log =~ "Your Barkpark sign-in link"
      assert log =~ "SMTP_HOST"
      # Same PII rule as the failure path: the type is logged, the person is not.
      refute log =~ "user@example.com"
    end
  end
end
