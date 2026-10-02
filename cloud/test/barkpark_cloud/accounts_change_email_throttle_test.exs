defmodule BarkparkCloud.AccountsChangeEmailThrottleTest do
  @moduledoc """
  task-e347bde0b83592fa — the change-email send throttle ({3, 3600}) counted only
  UNREVOKED rows while every new code revokes the previous one, so at most one
  row ever counted and the throttle could never fire: unlimited code mails to
  any address, and a per-code attempt lockout that reset with every re-mint.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Accounts

  test "the fourth send inside the hour is refused, although each send revoked the last code" do
    {:ok, user} =
      Accounts.register_user(%{email: "mover@example.com", password: "right horse battery"})

    results =
      for i <- 1..4 do
        user = Accounts.get_user(user.id)
        Accounts.deliver_user_update_email_instructions(user, "target-#{i}@example.com")
      end

    assert [{:ok, _}, {:ok, _}, {:ok, _}, {:error, :throttled}] = results
  end
end
