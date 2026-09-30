defmodule Barkpark.AccountsTotpAttemptBudgetTest do
  @moduledoc """
  task-4d52cfb35cbb0b08: a per-account TOTP attempt budget.

  POST /login/mfa sits in the :browser pipeline, which mounts no RateLimit,
  and a correct password resets the password lockout. So a password holder
  could guess 6-digit codes as fast as the box answered. Every TOTP check now
  spends from a per-USER bucket (burst 10, refill about 30 a day); past it
  even the right code is refused, and the key is the account, not the IP.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TotpTestHelper

  alias Barkpark.Accounts

  @password "correct-horse-battery-staple-9"

  defp totp_user do
    email = "totp-budget-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    secret = Accounts.totp_secret()
    {:ok, user, _codes} = Accounts.enable_totp(user, secret, totp_code_stable!(secret))
    {user, secret}
  end

  defp wrong(secret) do
    right = totp_code_stable!(secret)
    # Any 6 digits that are not the live code.
    if right == "000000", do: "111111", else: "000000"
  end

  test "ten wrong codes spend the budget, and then the RIGHT code is refused" do
    {user, secret} = totp_user()

    for _ <- 1..10, do: assert(:error = Accounts.verify_totp(user, wrong(secret)))

    assert :error = Accounts.verify_totp(user, totp_code_stable!(secret))
    refute Accounts.valid_totp?(user, totp_code_stable!(secret))
  end

  test "the budget is per ACCOUNT: another user's right code still passes" do
    {spent, spent_secret} = totp_user()
    {other, other_secret} = totp_user()

    for _ <- 1..10, do: Accounts.verify_totp(spent, wrong(spent_secret))

    assert {:ok, _} = Accounts.verify_totp(other, totp_code_stable!(other_secret))
  end

  test "CONTROL: a right code inside the budget still passes" do
    {user, secret} = totp_user()

    for _ <- 1..3, do: Accounts.verify_totp(user, wrong(secret))

    assert {:ok, _} = Accounts.verify_totp(user, totp_code_stable!(secret))
  end
end
