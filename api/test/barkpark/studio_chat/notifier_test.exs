defmodule Barkpark.StudioChat.NotifierTest do
  @moduledoc """
  The Studio-chat notification seam (wave 12, charter D69): send, debounce, and
  per-event-kind opt-out, proven against the Swoosh Test adapter (no live mail).

  `async: false` — the seam reads global `Barkpark.StudioChat.Notifier` config
  (recipient / quiet period / opted-out kinds) and shares one supervised debounce
  GenServer, so the config flips + `reset/0` must not race a sibling test.
  """

  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias Barkpark.StudioChat.Notifier

  @to "operator@example.com"

  setup do
    prior = Application.get_env(:barkpark, Notifier)

    Application.put_env(:barkpark, Notifier,
      to: @to,
      # Large window so two rapid calls in one test collide (debounce), unless a
      # test overrides it.
      quiet_period_ms: 60_000,
      opted_out_kinds: []
    )

    Notifier.reset()

    on_exit(fn ->
      if prior, do: Application.put_env(:barkpark, Notifier, prior),
        else: Application.delete_env(:barkpark, Notifier)
    end)

    :ok
  end

  defp event(kind, session_id, extra \\ %{}) do
    Map.merge(%{kind: kind, session_id: session_id}, extra)
  end

  describe "notify/1 — send" do
    test "a needs-you event delivers a mail with a public-origin deep link" do
      sid = "sess-needs-#{System.unique_integer([:positive])}"
      assert :ok = Notifier.notify(event(:needs_you, sid, %{title: "Ship it", line: "asking you"}))

      assert_email_sent(fn email ->
        assert {"Barkpark", "no-reply@barkpark.cloud"} = email.from
        assert [{_, @to}] = email.to
        assert email.subject =~ "Claude needs you"
        assert email.subject =~ "Ship it"
        # Deep link fronted by the public Endpoint URL, ending in the session id
        # (never an internal port — #1190).
        assert email.text_body =~ BarkparkWeb.Endpoint.url() <> "/studio/chat/" <> sid
        assert email.text_body =~ "asking you"
      end)
    end

    test "a finished-while-away event delivers its own subject" do
      sid = "sess-fin-#{System.unique_integer([:positive])}"
      assert :ok = Notifier.notify(event(:finished_while_away, sid, %{title: "Nightly"}))

      assert_email_sent(fn email ->
        assert email.subject =~ "finished while you were away"
        assert email.subject =~ "Nightly"
        assert email.text_body =~ "/studio/chat/" <> sid
      end)
    end

    test "an unknown event kind is rejected, no mail" do
      assert {:error, :invalid_event} = Notifier.notify(event(:bogus, "sess-x"))
      refute_email_sent()
    end

    test "a missing recipient skips fail-soft, no mail" do
      Application.put_env(:barkpark, Notifier, to: nil, quiet_period_ms: 60_000)
      Notifier.reset()

      assert {:skipped, :no_recipient} = Notifier.notify(event(:needs_you, "sess-nore"))
      refute_email_sent()
    end
  end

  describe "notify/1 — debounce (one mail per session per quiet period)" do
    test "a second event for the same session inside the window is suppressed" do
      sid = "sess-debounce-#{System.unique_integer([:positive])}"

      assert :ok = Notifier.notify(event(:needs_you, sid, %{title: "First"}))

      assert {:skipped, :debounced} =
               Notifier.notify(event(:finished_while_away, sid, %{title: "Second"}))

      # Exactly one mail — the second (different kind, same session) is throttled.
      assert_email_sent(fn email -> assert email.subject =~ "First" end)
      # The mailbox is now empty: the Second never reached a channel.
      refute_email_sent()
    end

    test "a different session inside the window still delivers" do
      sid_a = "sess-a-#{System.unique_integer([:positive])}"
      sid_b = "sess-b-#{System.unique_integer([:positive])}"

      assert :ok = Notifier.notify(event(:needs_you, sid_a))
      assert :ok = Notifier.notify(event(:needs_you, sid_b))

      assert_email_sent(fn email -> email.text_body =~ sid_a end)
      assert_email_sent(fn email -> email.text_body =~ sid_b end)
    end

    test "the same session sends again once the quiet period is zero" do
      Application.put_env(:barkpark, Notifier, to: @to, quiet_period_ms: 0)
      Notifier.reset()
      sid = "sess-zero-#{System.unique_integer([:positive])}"

      assert :ok = Notifier.notify(event(:needs_you, sid, %{title: "One"}))
      assert :ok = Notifier.notify(event(:needs_you, sid, %{title: "Two"}))

      assert_email_sent(fn email -> email.subject =~ "One" end)
      assert_email_sent(fn email -> email.subject =~ "Two" end)
    end
  end

  describe "notify/1 — per-event-kind opt-out" do
    test "an opted-out kind is suppressed while a sibling kind still delivers" do
      Application.put_env(:barkpark, Notifier,
        to: @to,
        quiet_period_ms: 60_000,
        opted_out_kinds: [:finished_while_away]
      )

      Notifier.reset()

      sid_fin = "sess-optout-#{System.unique_integer([:positive])}"
      sid_needs = "sess-still-#{System.unique_integer([:positive])}"

      assert {:skipped, :opted_out} = Notifier.notify(event(:finished_while_away, sid_fin))
      refute_email_sent()

      assert :ok = Notifier.notify(event(:needs_you, sid_needs))
      assert_email_sent(fn email -> assert email.subject =~ "Claude needs you" end)
    end
  end

  describe "channel extensibility" do
    test "channels/0 default is the built-in email channel; a config list overrides it" do
      # Wave-13 (Web Push / webhook) slots a {module, function} in without
      # touching the policy layer — prove the seam dispatches to configured
      # channels, not a hardwired email call.
      defmodule EchoChannel do
        def deliver(event, recipient, deep_link) do
          send(Application.get_env(:barkpark, :notifier_echo_pid), {:echoed, event.kind, recipient, deep_link})
          {:ok, :echoed}
        end
      end

      Application.put_env(:barkpark, :notifier_echo_pid, self())
      on_exit(fn -> Application.delete_env(:barkpark, :notifier_echo_pid) end)

      Application.put_env(:barkpark, Notifier,
        to: @to,
        quiet_period_ms: 60_000,
        channels: [{EchoChannel, :deliver}]
      )

      Notifier.reset()
      sid = "sess-echo-#{System.unique_integer([:positive])}"

      assert :ok = Notifier.notify(event(:needs_you, sid))
      assert_receive {:echoed, :needs_you, @to, deep_link}
      assert deep_link =~ "/studio/chat/" <> sid
      # No email channel ran — the config replaced it.
      refute_email_sent()
    end
  end
end
