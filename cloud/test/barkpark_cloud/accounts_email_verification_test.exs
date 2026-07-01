defmodule BarkparkCloud.AccountsEmailVerificationTest do
  @moduledoc """
  Security-focused coverage of the email-verification-recovery context slice:
  email confirmation (single-use / replay / expiry / cross-context) and the
  verified email-change flow (6-digit brute-force LOCKOUT, code↔target binding,
  and enumeration/takeover safety). Mail is captured via Swoosh.Adapters.Test.

  Each test asserts a guard that would BREAK if the protection were removed —
  they are not vacuous.
  """
  use BarkparkCloud.DataCase, async: true
  import Swoosh.TestAssertions
  import Ecto.Query

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{User, UserToken}
  alias BarkparkCloud.Repo

  @password "correct-horse-battery"

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  # Drive a confirm-instruction send and pull the one-time token back out of the
  # emailed `?confirm=` link (the real mint→deliver→verify round trip).
  defp confirm_token(user) do
    assert {:ok, _} = Accounts.deliver_user_confirmation_instructions(user)
    assert_receive {:email, email}
    [_, token] = Regex.run(~r/\?confirm=([^\s]+)/, email.text_body)
    token
  end

  # Stage an email change and pull the 6-digit code out of the email to the NEW
  # address. Returns {reloaded_user (pending_email set), code}.
  defp stage_change(user, new_email) do
    assert {:ok, _} = Accounts.deliver_user_update_email_instructions(user, new_email)
    assert_receive {:email, email}
    [code] = Regex.run(~r/\b\d{6}\b/, email.text_body)
    {Repo.get!(User, user.id), code}
  end

  defp change_token_count(user_id) do
    from(t in UserToken,
      where: t.user_id == ^user_id and t.context == "change_email" and is_nil(t.revoked_at)
    )
    |> Repo.aggregate(:count)
  end

  defp wrong_code(code), do: if(code == "000000", do: "111111", else: "000000")

  describe "email confirmation — single-use / replay / expiry" do
    test "a confirm token confirms once, then is spent (replay fails closed)" do
      user = user_fixture()
      token = confirm_token(user)

      assert {:ok, %User{} = confirmed} = Accounts.confirm_user(token)
      assert confirmed.confirmed_at

      # Replay of the exact same link finds it already revoked → fails closed.
      assert :error = Accounts.confirm_user(token)
    end

    test "a revoked confirm token cannot confirm (single-use enforced by revoked_at)" do
      user = user_fixture()
      token = confirm_token(user)

      # Simulate the token being revoked out from under the click.
      Repo.update_all(
        from(t in UserToken, where: t.user_id == ^user.id and t.context == "confirm"),
        set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)]
      )

      assert :error = Accounts.confirm_user(token)
      refute Repo.get!(User, user.id).confirmed_at
    end

    test "the confirm token carries a 7-day window, and an expired one fails closed" do
      user = user_fixture()
      token = confirm_token(user)

      row = Repo.get_by!(UserToken, user_id: user.id, context: "confirm")
      # ~7 days out (allow a minute of slop).
      secs = DateTime.diff(row.expires_at, DateTime.utc_now(), :second)
      assert_in_delta secs, 7 * 24 * 3600, 60

      # Force it past expiry → confirm must reject.
      Repo.update_all(
        from(t in UserToken, where: t.id == ^row.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :day)]
      )

      assert :error = Accounts.confirm_user(token)
      refute Repo.get!(User, user.id).confirmed_at
    end

    test "already-confirmed user is refused a resend (no new token minted)" do
      user = user_fixture()
      token = confirm_token(user)
      {:ok, _} = Accounts.confirm_user(token)

      user = Repo.get!(User, user.id)
      assert {:error, :already_confirmed} = Accounts.deliver_user_confirmation_instructions(user)
    end
  end

  describe "cross-context safety" do
    test "a confirm token NEVER authenticates as a session" do
      user = user_fixture()
      token = confirm_token(user)

      # The bearer path is scoped to context == \"session\"; a confirm token
      # must not resolve a user there.
      assert Accounts.verify_user_session_token(token) == nil
    end

    test "a change_email code NEVER authenticates as a session" do
      user = user_fixture()
      {_user, code} = stage_change(user, "new-#{System.unique_integer([:positive])}@example.com")

      assert Accounts.verify_user_session_token(code) == nil
    end
  end

  describe "verified email change — happy path" do
    test "proving the 6-digit code swaps the email and clears pending" do
      user = user_fixture()
      target = "changed-#{System.unique_integer([:positive])}@example.com"
      {user, code} = stage_change(user, target)

      assert user.pending_email == target
      assert {:ok, %User{} = updated} = Accounts.update_user_email(user, code)
      assert updated.email == target
      assert updated.pending_email == nil

      # Single-use: the change token is spent afterwards.
      assert change_token_count(updated.id) == 0
    end
  end

  describe "verified email change — 6-digit brute-force lockout" do
    test "N wrong codes LOCK the pending change (a hard cap, not just a throttle)" do
      user = user_fixture()
      target = "target-#{System.unique_integer([:positive])}@example.com"
      {user, code} = stage_change(user, target)
      bad = wrong_code(code)

      max = UserToken.max_code_attempts()

      # The first max-1 wrong codes are rejected but keep the change alive.
      for _ <- 1..(max - 1) do
        assert {:error, :invalid_code} = Accounts.update_user_email(user, bad)
      end

      # The max-th wrong code LOCKS it: token revoked + pending dropped.
      assert {:error, :locked} = Accounts.update_user_email(user, bad)

      locked = Repo.get!(User, user.id)
      assert locked.pending_email == nil
      assert change_token_count(user.id) == 0

      # Even the CORRECT code cannot resurrect the locked change.
      assert {:error, :no_pending_email} = Accounts.update_user_email(locked, code)
    end
  end

  describe "verified email change — code is bound to its target address" do
    test "a code minted for one target cannot confirm a change to a different one" do
      user = user_fixture()
      a = "a-#{System.unique_integer([:positive])}@example.com"
      b = "b-#{System.unique_integer([:positive])}@example.com"

      {_user, code_a} = stage_change(user, a)
      # Re-stage to B: supersedes A's token and re-points pending_email to B.
      {user_b, code_b} = stage_change(user, b)

      # A's code must NOT confirm the change now targeting B (sent_to binding).
      assert {:error, :invalid_code} = Accounts.update_user_email(user_b, code_a)

      # B's own code still works.
      assert {:ok, updated} = Accounts.update_user_email(Repo.get!(User, user.id), code_b)
      assert updated.email == b
    end
  end

  describe "verified email change — enumeration / takeover safety" do
    test "staging an already-registered address leaks nothing and takes nothing over" do
      victim = user_fixture(email: "victim-#{System.unique_integer([:positive])}@example.com")
      attacker = user_fixture()

      # Same {:ok, _} shape as a real send — but no stage, no code, no email.
      assert {:ok, :noop} =
               Accounts.deliver_user_update_email_instructions(attacker, victim.email)

      assert_no_email_sent()
      assert change_token_count(attacker.id) == 0
      assert Repo.get!(User, attacker.id).pending_email == nil
      # The victim's account is entirely untouched.
      assert Repo.get!(User, victim.id).email == victim.email
    end
  end
end
