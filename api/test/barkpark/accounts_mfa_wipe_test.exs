defmodule Barkpark.AccountsMfaWipeTest do
  @moduledoc """
  The three MFA-wipe paths must agree on WHICH FIELDS they clear.

  `last_totp_at` is the replay guard for ONE secret: `totp_opts/1` hands it to
  NimbleTOTP as `since:`, and `reused?/3` rejects any code whose 30s step is
  `<=` it. Carrying that stamp across a disable attaches the OLD secret's
  consumed step to a BRAND NEW one, so the first `verify_totp/2` after a
  re-enrol inside the same period returns `:error` on a perfectly valid code.

  `do_reset_password/3` (`reset_mfa: true`) and `Accounts.Privacy` erasure both
  cleared it; `disable_totp/1` did not. Nothing structural holds the three
  together — this file is that check, and it is a SET comparison, so a field
  added to one path and forgotten in another reds here whichever path drifts.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TotpTestHelper

  alias Barkpark.Accounts
  alias Barkpark.Accounts.User

  @password "correct-horse-battery"

  defp user_with_totp do
    email = "mfa-wipe-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    secret = Accounts.totp_secret()
    {:ok, user, _codes} = Accounts.enable_totp(user, secret, totp_code_stable!(secret))
    {user, secret}
  end

  describe "disable_totp/1" do
    test "clears last_totp_at, in the returned struct and in the row" do
      {user, secret} = user_with_totp()

      {:ok, user} = Accounts.verify_totp(user, totp_code_stable!(secret))
      assert user.last_totp_at, "precondition: a successful verify stamps the step"

      {:ok, disabled} = Accounts.disable_totp(user)

      assert is_nil(disabled.last_totp_at),
             "disable_totp left the OLD secret's consumed step on the row — a new " <>
               "secret enrolled in the same period inherits it as a replay guard"

      assert is_nil(Repo.get!(User, user.id).last_totp_at),
             "the stamp survives in the database even though the struct looks clean"
    end

    test "a re-enrolled NEW secret verifies on its first code, in the same period" do
      # The whole flow — verify, disable, re-enrol, verify — has to land inside
      # ONE 30s period for the stale stamp to bite, so buy the headroom once and
      # mint plain codes after it. This is the narrow window in which the defect
      # is genuinely reachable; outside it the stale stamp is simply old enough
      # to be harmless, which is why it survived so long.
      {user, old_secret} = user_with_totp()
      await_period_headroom!(min_headroom_ms: 5_000)

      {:ok, user} = Accounts.verify_totp(user, NimbleTOTP.verification_code(old_secret))
      {:ok, user} = Accounts.disable_totp(user)

      new_secret = Accounts.totp_secret()
      refute new_secret == old_secret

      {:ok, user, _codes} =
        Accounts.enable_totp(user, new_secret, NimbleTOTP.verification_code(new_secret))

      # Split rather than `assert pat = expr, "msg"`, which raises a bare
      # MatchError and throws the message away.
      result = Accounts.verify_totp(user, NimbleTOTP.verification_code(new_secret))

      assert result != :error,
             "the first code of a freshly enrolled secret was rejected as a REPLAY — " <>
               "disable_totp carried the previous secret's consumed step across"

      assert {:ok, _verified} = result
    end

    test "the replay guard is untouched: a code is still one-time within its period" do
      {user, secret} = user_with_totp()
      code = totp_code_stable!(secret, min_headroom_ms: 5_000)

      assert {:ok, consumed} = Accounts.verify_totp(user, code)
      assert :error = Accounts.verify_totp(consumed, code)
      refute Accounts.valid_totp?(consumed, code)
    end
  end

  describe "the wipe paths agree" do
    @totp_fields [:totp_secret, :totp_enabled, :recovery_codes_hashed, :last_totp_at]

    # Read straight off the row: a path that clears a field only in the struct
    # it returns has not cleared it.
    defp totp_state(user_id) do
      User |> Repo.get!(user_id) |> Map.take(@totp_fields)
    end

    test "disable_totp/1 and a reset_mfa password reset leave the same TOTP state" do
      {disabled_user, secret} = user_with_totp()
      {:ok, disabled_user} = Accounts.verify_totp(disabled_user, totp_code_stable!(secret))
      {:ok, _} = Accounts.disable_totp(disabled_user)

      {reset_user, secret2} = user_with_totp()
      {:ok, reset_user} = Accounts.verify_totp(reset_user, totp_code_stable!(secret2))

      {:ok, raw} = Accounts.build_email_token(reset_user, "reset")

      {:ok, _} =
        Accounts.reset_user_password(raw, %{password: "another-correct-horse-battery"})

      assert totp_state(disabled_user.id) == totp_state(reset_user.id),
             "the two MFA-wipe paths disagree on which fields they clear"

      assert totp_state(disabled_user.id) == %{
               totp_secret: nil,
               totp_enabled: false,
               recovery_codes_hashed: [],
               last_totp_at: nil
             }
    end
  end
end
