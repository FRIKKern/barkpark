defmodule BarkparkCloud.MailerDeliverabilityTest do
  @moduledoc """
  The control plane's mail-deadness predicate.

  THE SHAPE UNDER TEST is not the instance's. On an instance the mail-dead
  configuration is `Swoosh.Adapters.Local`, because `api/config/config.exs`
  defaults to it. On the control plane `cloud/config/runtime.exs` sets
  `Swoosh.Adapters.SMTP` UNCONDITIONALLY in prod and pipes
  `System.get_env("SMTP_HOST")` straight into `:relay`, so the mail-dead plane
  holds a DELIVERING adapter with a nil relay. An adapter-only check calls that
  healthy. These tests pin the relay arm so it cannot be optimised back into
  one.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BarkparkCloud.Mailer

  @key BarkparkCloud.Mailer

  setup do
    original = Application.get_env(:barkpark_cloud, @key)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark_cloud, @key)
        cfg -> Application.put_env(:barkpark_cloud, @key, cfg)
      end
    end)

    :ok
  end

  defp configure(cfg), do: Application.put_env(:barkpark_cloud, @key, cfg)

  describe "deliverability/0" do
    test "a configured SMTP relay is deliverable" do
      configure(adapter: Swoosh.Adapters.SMTP, relay: "mail.barkpark.cloud")

      assert %{adapter: Swoosh.Adapters.SMTP, deliverable?: true, reason: :ok} =
               Mailer.deliverability()

      refute Mailer.drops_mail?()
    end

    # THE REGRESSION THIS FILE EXISTS FOR. `SMTP_HOST` unset makes `relay` nil
    # while the adapter still says SMTP; gen_smtp then dies in option validation
    # with `:no_relay` on every single send.
    test "SMTP with a nil relay is NOT deliverable" do
      configure(adapter: Swoosh.Adapters.SMTP, relay: nil)

      assert %{deliverable?: false, reason: :relay_unset} = Mailer.deliverability()
      assert Mailer.drops_mail?()
    end

    # `SMTP_HOST=$UNSET_VAR` in a shell yields "" rather than an absent var, so
    # the blank string is a SEPARATE production shape, not a variant spelling of
    # nil.
    test "SMTP with a blank or whitespace relay is NOT deliverable" do
      for relay <- ["", "   ", "\t"] do
        configure(adapter: Swoosh.Adapters.SMTP, relay: relay)

        assert %{deliverable?: false, reason: :relay_unset} = Mailer.deliverability(),
               "relay #{inspect(relay)} should read as unset"

        assert Mailer.drops_mail?()
      end
    end

    test "the Local mailbox accepts and discards" do
      configure(adapter: Swoosh.Adapters.Local)

      assert %{deliverable?: false, reason: :local_mailbox} = Mailer.deliverability()
      assert Mailer.drops_mail?()
    end

    test "an absent mailer config is unconfigured" do
      Application.delete_env(:barkpark_cloud, @key)

      assert %{adapter: nil, deliverable?: false, reason: :unconfigured} = Mailer.deliverability()
      assert Mailer.drops_mail?()
    end

    # The exclusion that keeps the banner readable: the Test adapter is not
    # deliverable, but nobody was waiting on that mail, so it must not alarm.
    test "the Test adapter is not deliverable but does NOT drop a person's mail" do
      configure(adapter: Swoosh.Adapters.Test)

      assert %{deliverable?: false, reason: :test_capture} = Mailer.deliverability()
      refute Mailer.drops_mail?()
    end
  end

  describe "warn_if_undeliverable/0" do
    test "warns, naming the reason, when the relay is unset" do
      configure(adapter: Swoosh.Adapters.SMTP, relay: nil)

      log = capture_log(fn -> assert %{reason: :relay_unset} = Mailer.warn_if_undeliverable() end)

      assert log =~ "MAIL IS NOT DELIVERABLE"
      assert log =~ "relay_unset"
      assert log =~ "SMTP_HOST"
    end

    test "stays silent when the relay is configured" do
      configure(adapter: Swoosh.Adapters.SMTP, relay: "mail.barkpark.cloud")

      log = capture_log(fn -> assert %{reason: :ok} = Mailer.warn_if_undeliverable() end)

      refute log =~ "MAIL IS NOT DELIVERABLE"
    end

    # The suite itself is the control: if the Test adapter warned, every run of
    # every file would carry this banner.
    test "stays silent under the test adapter" do
      configure(adapter: Swoosh.Adapters.Test)

      log =
        capture_log(fn -> assert %{reason: :test_capture} = Mailer.warn_if_undeliverable() end)

      refute log =~ "MAIL IS NOT DELIVERABLE"
    end
  end
end
