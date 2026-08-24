defmodule Barkpark.MailerDeliverabilityTest do
  @moduledoc """
  NAMED FAILURE MODE: a configuration that cannot deliver reports success.

  `config/config.exs` defaults `Barkpark.Mailer` to `Swoosh.Adapters.Local`, an
  in-memory mailbox. Its `deliver/2` returns `{:ok, %{id: id}}`, so every caller
  that matched `{:ok, _}` counted a discarded message as a sent one. The
  asymmetry that made this durable: a relay that is configured but DOWN returns
  `{:error, _}` and was already logged, while an instance with NO relay at all
  — the state every box is in until someone sets `SMTP_HOST` — produced no log,
  no bounce and no status signal. The loud failure lasted minutes; the silent
  one lasted forever.

  These tests pin the three surfaces that now make it observable:

    * `deliverability/0` + `drops_mail?/0` — the single source of truth;
    * `deliver_checked/1` — the send path REFUSES to call it a delivery, while
      still handing the message to the adapter (the dev mailbox keeps working);
    * `warn_if_undeliverable/0` — the boot banner, which warns and does NOT
      raise, because a box with no relay is a legitimate configuration.
  """
  # NOT async: every test swaps the process-global `Barkpark.Mailer` adapter.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Swoosh.Email

  alias Barkpark.Mailer

  setup do
    original = Application.get_env(:barkpark, Barkpark.Mailer)
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Mailer, original) end)
    :ok
  end

  defp put_adapter(mod), do: Application.put_env(:barkpark, Barkpark.Mailer, adapter: mod)

  defp mail do
    new()
    |> to("user@example.com")
    |> from({"Barkpark", "no-reply@barkpark.cloud"})
    |> subject("Your Barkpark sign-in link")
    |> text_body("https://example.test/auth/magic/tok")
  end

  # A stand-in for a real relay: not in the mailer's non-delivering set, so it
  # is classified deliverable exactly as Swoosh.Adapters.SMTP would be.
  defmodule WorkingRelayAdapter do
    def validate_config(_config), do: :ok
    def validate_dependency, do: :ok
    def deliver(_email, _config), do: {:ok, %{id: "accepted-by-relay"}}
    def deliver_many(emails, _config), do: {:ok, Enum.map(emails, fn _ -> %{id: "x"} end)}
  end

  defmodule DownRelayAdapter do
    def validate_config(_config), do: :ok
    def validate_dependency, do: :ok
    def deliver(_email, _config), do: {:error, :relay_down}
    def deliver_many(_emails, _config), do: {:error, :relay_down}
  end

  describe "deliverability/0 classification" do
    test "the Local mailbox is not deliverable — it is the compile-time default a real box runs" do
      put_adapter(Swoosh.Adapters.Local)

      assert %{adapter: Swoosh.Adapters.Local, deliverable?: false, reason: :local_mailbox} =
               Mailer.deliverability()
    end

    test "the test-capture adapter is not deliverable either (strict truth)" do
      put_adapter(Swoosh.Adapters.Test)

      assert %{adapter: Swoosh.Adapters.Test, deliverable?: false, reason: :test_capture} =
               Mailer.deliverability()
    end

    test "a real relay adapter is deliverable" do
      put_adapter(WorkingRelayAdapter)

      assert %{adapter: WorkingRelayAdapter, deliverable?: true, reason: :ok} =
               Mailer.deliverability()
    end

    test "no adapter at all is unconfigured, not silently fine" do
      Application.put_env(:barkpark, Barkpark.Mailer, [])

      assert %{adapter: nil, deliverable?: false, reason: :unconfigured} = Mailer.deliverability()
    end
  end

  describe "drops_mail?/0 (the operational predicate)" do
    test "true for the Local mailbox — a real person's email is discarded" do
      put_adapter(Swoosh.Adapters.Local)
      assert Mailer.drops_mail?()
    end

    test "true when no adapter is configured" do
      Application.put_env(:barkpark, Barkpark.Mailer, [])
      assert Mailer.drops_mail?()
    end

    test "false for the test-capture adapter — no one was withheld from under MIX_ENV=test" do
      # Deliberately narrower than `not deliverable?`. Counting the test adapter
      # would warn on every email in the suite and degrade every test run's
      # health probe, training people to ignore the one line that matters.
      put_adapter(Swoosh.Adapters.Test)
      refute Mailer.drops_mail?()
    end

    test "false for a real relay" do
      put_adapter(WorkingRelayAdapter)
      refute Mailer.drops_mail?()
    end
  end

  describe "deliver_checked/1 — a mute configuration must not report success" do
    test "under the Local mailbox the send does NOT report success" do
      # THE SPEC. Swoosh's own `deliver/1` returns {:ok, _} here; that {:ok} is
      # the defect. Nothing downstream may read this as a delivery.
      put_adapter(Swoosh.Adapters.Local)
      Swoosh.Adapters.Local.Storage.Memory.delete_all()

      assert {:error, {:not_deliverable, Swoosh.Adapters.Local, :local_mailbox}} =
               Mailer.deliver_checked(mail())
    end

    test "the raw Swoosh deliver still says {:ok, _} — proving the refusal is ours, not the adapter's" do
      put_adapter(Swoosh.Adapters.Local)
      Swoosh.Adapters.Local.Storage.Memory.delete_all()

      assert {:ok, _meta} = Mailer.deliver(mail())
    end

    test "the message is STILL written to the local mailbox — no new silent drop" do
      # Refusing to write would replace one invisible failure with another; the
      # dev mailbox at /dev/mailbox is how a developer reads this mail. What
      # changes is the claim, not the wire.
      put_adapter(Swoosh.Adapters.Local)
      Swoosh.Adapters.Local.Storage.Memory.delete_all()

      assert {:error, {:not_deliverable, _, _}} = Mailer.deliver_checked(mail())

      stored = Swoosh.Adapters.Local.Storage.Memory.all()
      assert length(stored) == 1
      assert hd(stored).subject == "Your Barkpark sign-in link"
    end

    test "under no adapter at all the send does not report success" do
      Application.put_env(:barkpark, Barkpark.Mailer, [])

      assert {:error, {:not_deliverable, nil, :unconfigured}} = Mailer.deliver_checked(mail())
    end

    test "a real relay that accepts the message reports :ok" do
      put_adapter(WorkingRelayAdapter)
      assert :ok = Mailer.deliver_checked(mail())
    end

    test "a real relay that fails passes the reason through unchanged" do
      # The pre-existing loud path must stay loud and keep its shape — the
      # notifiers still log {:error, reason} as a delivery failure.
      put_adapter(DownRelayAdapter)
      assert {:error, :relay_down} = Mailer.deliver_checked(mail())
    end

    test "the test-capture adapter reports :ok and still delivers to the caller" do
      put_adapter(Swoosh.Adapters.Test)

      assert :ok = Mailer.deliver_checked(mail())
      assert_received {:email, delivered}
      assert delivered.subject == "Your Barkpark sign-in link"
    end
  end

  describe "warn_if_undeliverable/0 — the boot banner" do
    test "warns loudly under the Local mailbox and names the remedy" do
      put_adapter(Swoosh.Adapters.Local)

      log = capture_log(fn -> Mailer.warn_if_undeliverable() end)

      assert log =~ "MAIL IS NOT DELIVERABLE"
      assert log =~ "Swoosh.Adapters.Local"
      assert log =~ "SMTP_HOST"
      # It must say what a person loses, not just name a module.
      assert log =~ "password reset"
    end

    test "does NOT raise — a box with no relay is a legitimate configuration" do
      # The deliberate asymmetry with Mailer.from/0, which DOES raise: a
      # malformed From is always a typo, whereas 'no relay' is every laptop.
      put_adapter(Swoosh.Adapters.Local)

      status = capture_log(fn -> send(self(), Mailer.warn_if_undeliverable()) end)
      assert status =~ "MAIL IS NOT DELIVERABLE"
      assert_received %{deliverable?: false}
    end

    test "stays quiet for a real relay" do
      put_adapter(WorkingRelayAdapter)

      log = capture_log(fn -> Mailer.warn_if_undeliverable() end)

      refute log =~ "MAIL IS NOT DELIVERABLE"
    end

    test "stays quiet under the test-capture adapter" do
      put_adapter(Swoosh.Adapters.Test)

      log = capture_log(fn -> Mailer.warn_if_undeliverable() end)

      refute log =~ "MAIL IS NOT DELIVERABLE"
    end
  end
end
