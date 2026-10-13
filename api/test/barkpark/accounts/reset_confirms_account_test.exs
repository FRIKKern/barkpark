defmodule Barkpark.Accounts.ResetConfirmsAccountTest do
  @moduledoc """
  task-5adb9639803f4fb7 — left over from #22522 (reverted) / #22535 (re-landed
  the rest). A password reset proves control of the email address exactly as
  the confirm link does, so it should stamp `confirmed_at` the same way.
  Source: the reset-confirms hunk in reverted c8b37d2c.

  Without this, an account that lost its confirm mail could reset its
  password and still be refused at login (`email_unconfirmed`); worse, a
  LATER member-add would still see `confirmed_at: nil` and reclaim the
  account (`Privacy.reclaim_unconfirmed/1`), silently replacing the password
  this reset just set — see `Barkpark.Tenancy.MembersSeatUnconfirmedTest`'s
  own "seating a CONFIRMED account keeps its password" control, which this
  file mirrors for the reset-confirms path instead of the register-confirms
  one.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.AccountsFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Accounts.UserEmailToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Members

  @password "correct-horse-battery"
  @new_password "a-new-strong-password"

  describe "reset_user_password/2 confirms an unconfirmed account" do
    test "an unconfirmed account that completes a password reset is confirmed afterwards" do
      email = "reset-confirms-#{System.unique_integer([:positive])}@example.com"
      user = register_unconfirmed_user(email, @password)
      refute user.confirmed_at

      {:ok, raw} = Accounts.build_email_token(user, "reset")
      assert {:ok, reset_user} = Accounts.reset_user_password(raw, %{password: @new_password})

      assert reset_user.confirmed_at, "the reset must stamp confirmed_at"

      # Re-read from storage, not just the struct the call handed back.
      reread = Repo.get!(Accounts.User, user.id)
      assert reread.confirmed_at
    end

    test "an already-confirmed account's confirmed_at is untouched by a reset" do
      email = "reset-already-confirmed-#{System.unique_integer([:positive])}@example.com"
      user = register_user(email, @password)
      assert %DateTime{} = original = user.confirmed_at

      {:ok, raw} = Accounts.build_email_token(user, "reset")
      assert {:ok, reset_user} = Accounts.reset_user_password(raw, %{password: @new_password})

      assert DateTime.compare(reset_user.confirmed_at, original) == :eq
    end

    test "a later member-add keeps the password a reset just set" do
      email = "reset-then-seat-#{System.unique_integer([:positive])}@example.com"
      user = register_unconfirmed_user(email, @password)
      {:ok, raw} = Accounts.build_email_token(user, "reset")
      assert {:ok, _} = Accounts.reset_user_password(raw, %{password: @new_password})

      ws = create_workspace!("reset-then-seat-#{System.unique_integer([:positive])}")
      assert {:ok, _} = Members.add_user_member(ws.id, email, "member")

      assert Accounts.get_user_by_email_and_password(email, @new_password),
             "the reset's password must survive the member-add"

      refute Accounts.get_user_by_email_and_password(email, @password),
             "the pre-reset password must stay dead"
    end

    test "a wrong reset token confirms nothing" do
      email = "reset-wrong-token-#{System.unique_integer([:positive])}@example.com"
      user = register_unconfirmed_user(email, @password)

      assert :error = Accounts.reset_user_password("not-a-real-token", %{password: @new_password})

      refute Repo.get!(Accounts.User, user.id).confirmed_at
    end

    test "an expired reset token confirms nothing" do
      email = "reset-expired-token-#{System.unique_integer([:positive])}@example.com"
      user = register_unconfirmed_user(email, @password)
      {:ok, raw} = Accounts.build_email_token(user, "reset")

      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      UserEmailToken
      |> Ecto.Query.where(user_id: ^user.id, context: "reset")
      |> Repo.update_all(set: [expires_at: past])

      assert :error = Accounts.reset_user_password(raw, %{password: @new_password})

      refute Repo.get!(Accounts.User, user.id).confirmed_at
      refute Accounts.get_user_by_email_and_password(email, @new_password)
    end

    test "a confirm-context token cannot be used to reset-and-confirm (context-bound)" do
      email = "reset-wrong-context-#{System.unique_integer([:positive])}@example.com"
      user = register_unconfirmed_user(email, @password)
      {:ok, raw} = Accounts.build_email_token(user, "confirm")

      assert :error = Accounts.reset_user_password(raw, %{password: @new_password})

      refute Repo.get!(Accounts.User, user.id).confirmed_at
    end
  end
end
