defmodule Barkpark.Accounts.UserNotifierTest do
  @moduledoc """
  Observability guard for the core-auth transactional emails: a *failed* deliver
  must leave a diagnostic log line (email type + reason) instead of vanishing
  silently, while the fail-soft return contract is preserved so the controller's
  anti-enumeration 200 is unchanged.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Accounts.UserNotifier

  # A Swoosh adapter that always fails, simulating a down relay.
  defmodule DownRelayAdapter do
    def validate_config(_config), do: :ok
    def validate_dependency, do: :ok
    def deliver(_email, _config), do: {:error, :relay_down}
    def deliver_many(_emails, _config), do: {:error, :relay_down}
  end

  setup do
    original = Application.get_env(:barkpark, Barkpark.Mailer)
    Application.put_env(:barkpark, Barkpark.Mailer, adapter: DownRelayAdapter)
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Mailer, original) end)
    :ok
  end

  test "a failed deliver logs a diagnostic line (subject + reason) and stays fail-soft" do
    log =
      capture_log(fn ->
        assert {:error, :relay_down} =
                 UserNotifier.deliver_reset("user@example.com", "https://x/auth/reset/tok")
      end)

    assert log =~ "transactional email delivery failed"
    assert log =~ "Reset your Barkpark password"
    assert log =~ ":relay_down"
  end

  test "the failure log does NOT leak the recipient address (PII)" do
    log =
      capture_log(fn ->
        UserNotifier.deliver_confirmation("secret-person@example.com", "https://x/confirm/tok")
      end)

    assert log =~ "transactional email delivery failed"
    refute log =~ "secret-person@example.com"
  end
end
