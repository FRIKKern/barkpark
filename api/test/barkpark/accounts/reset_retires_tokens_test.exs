defmodule Barkpark.Accounts.ResetRetiresTokensTest do
  @moduledoc """
  A password reset or change consumed only the ONE reset token it was given.
  Every other outstanding reset link (1h) and magic-login link (15m) kept
  working, so someone who once read the victim's mailbox could reset the
  password again (wiping TOTP) or sign in after the victim recovered the
  account (task-07f85a21a3119c40). A successful reset or change now retires
  them.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.AccountsFixtures

  alias Barkpark.Accounts

  @password "correct-horse-battery"
  @new_password "new-horse-battery-staple-1"
  @newer_password "newer-horse-battery-staple-2"

  defp token!(user, context) do
    {:ok, plaintext} = Accounts.build_email_token(user, context)
    plaintext
  end

  test "a reset retires the other outstanding reset and magic-login links" do
    user = register_user("reset-retire-#{System.unique_integer([:positive])}@example.com")
    used = token!(user, "reset")
    leftover_reset = token!(user, "reset")
    leftover_login = token!(user, "login")

    assert {:ok, _} = Accounts.reset_user_password(used, %{"password" => @new_password})

    assert :error =
             Accounts.reset_user_password(leftover_reset, %{"password" => @newer_password})

    assert Accounts.get_user_by_email_and_password(user.email, @new_password)
    refute match?({:ok, _}, Accounts.consume_login_token(leftover_login))
  end

  test "a password change retires outstanding reset links" do
    user = register_user("change-retire-#{System.unique_integer([:positive])}@example.com")
    leftover_reset = token!(user, "reset")

    assert {:ok, _} =
             Accounts.update_user_password(user, @password, %{"password" => @new_password})

    assert :error =
             Accounts.reset_user_password(leftover_reset, %{"password" => @newer_password})
  end

  test "a reset that fails the password policy keeps its own link usable (control)" do
    user = register_user("reset-keep-#{System.unique_integer([:positive])}@example.com")
    link = token!(user, "reset")

    assert {:error, _} = Accounts.reset_user_password(link, %{"password" => "x"})
    assert {:ok, _} = Accounts.reset_user_password(link, %{"password" => @new_password})
  end
end
