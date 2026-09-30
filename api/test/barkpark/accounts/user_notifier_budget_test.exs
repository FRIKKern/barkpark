defmodule Barkpark.Accounts.UserNotifierBudgetTest do
  @moduledoc """
  task-7943350f12d1d5e1: auth mail has a per-RECIPIENT budget.

  POST /login/reset and POST /login/magic mount no RateLimit, and the JSON
  twins are metered per IP only, so nothing bounded how many reset or
  sign-in mails one address received. Each kind now gets a burst of 3 per
  recipient, then about one per 10 minutes; a throttled send is skipped.
  """
  # async: false — the burst is pinned to its production value through the
  # application env for this module only, and restored after.
  use ExUnit.Case, async: false

  alias Barkpark.Accounts.UserNotifier

  setup do
    prior = Application.fetch_env(:barkpark, :auth_mail_burst)
    Application.put_env(:barkpark, :auth_mail_burst, 3)

    on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(:barkpark, :auth_mail_burst, v)
        :error -> Application.delete_env(:barkpark, :auth_mail_burst)
      end
    end)
  end

  defp addr, do: "bomb-#{System.unique_integer([:positive])}@example.com"

  test "a fourth reset mail to the same address inside the window is throttled" do
    to = addr()

    for _ <- 1..3, do: assert({:ok, _} = UserNotifier.deliver_reset(to, "https://x/r/1"))

    assert {:error, :throttled} = UserNotifier.deliver_reset(to, "https://x/r/2")
    # The recipient is normalised: case and whitespace do not buy a new budget.
    assert {:error, :throttled} =
             UserNotifier.deliver_reset("  " <> String.upcase(to) <> " ", "https://x/r/3")
  end

  test "the budget is per recipient AND per kind" do
    to = addr()
    for _ <- 1..4, do: UserNotifier.deliver_reset(to, "https://x/r")

    # Another address is untouched.
    assert {:ok, _} = UserNotifier.deliver_reset(addr(), "https://x/r")
    # Another kind to the same address is untouched.
    assert {:ok, _} = UserNotifier.deliver_magic_link(to, "https://x/m")
  end

  test "magic-link and already-registered mail are bounded too" do
    to = addr()
    for _ <- 1..3, do: assert({:ok, _} = UserNotifier.deliver_magic_link(to, "https://x/m"))
    assert {:error, :throttled} = UserNotifier.deliver_magic_link(to, "https://x/m")

    for _ <- 1..3, do: assert({:ok, _} = UserNotifier.deliver_already_registered(to))
    assert {:error, :throttled} = UserNotifier.deliver_already_registered(to)
  end
end
