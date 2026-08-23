defmodule BarkparkCloud.TwoFactorTest do
  @moduledoc """
  Context-level coverage of two-factor-auth: enroll → confirm → verify →
  consume-recovery → disable / regenerate, the two-phase login token and its
  verify_user_session_token/1 regression guard, and the TOTP REPLAY GUARD
  (a valid OTP is single-use even inside its ±1 tolerance window). Mirrors
  accounts_test.exs (DataCase async, user_fixture/1).
  """
  use BarkparkCloud.DataCase, async: true

  import BarkparkCloud.TotpTestHelper

  import Ecto.Query

  alias BarkparkCloud.Repo
  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{TwoFactor, User, UserToken}

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

  # Enroll a user and return {user, raw_secret} so tests can compute valid codes.
  defp enrolled(user) do
    {:ok, %{user: user, secret_base32: b32}} = Accounts.start_two_factor_enrollment(user)
    {:ok, secret} = Base.decode32(b32, padding: false)
    {user, secret}
  end

  # Enroll + confirm; return {user, raw_secret, recovery_codes}.
  defp confirmed(user) do
    {user, secret} = enrolled(user)
    code = totp_code_stable!(secret)
    {:ok, recovery} = Accounts.confirm_two_factor(user, code)
    {Accounts.get_user(user.id), secret, recovery}
  end

  describe "start_two_factor_enrollment/1" do
    test "persists an ENCRYPTED secret, leaves confirmed_at nil, returns provisioning material" do
      user = user_fixture()

      assert {:ok, %{user: stored, otpauth_uri: uri, secret_base32: b32}} =
               Accounts.start_two_factor_enrollment(user)

      assert is_binary(stored.two_factor_secret)
      assert is_nil(stored.two_factor_confirmed_at)
      assert Accounts.two_factor_enabled?(stored) == false
      assert String.starts_with?(uri, "otpauth://totp/")
      assert {:ok, _raw} = Base.decode32(b32, padding: false)

      # The stored column is ciphertext, NOT the raw secret.
      {:ok, raw} = Base.decode32(b32, padding: false)
      assert stored.two_factor_secret != raw
      assert {:ok, ^raw} = TwoFactor.decrypt_secret(stored.two_factor_secret)
    end

    test "redacts secret + codes from inspect (never serialized in logs)" do
      user = user_fixture()
      {:ok, %{user: stored}} = Accounts.start_two_factor_enrollment(user)
      dump = inspect(stored)
      # The ciphertext value never appears...
      refute dump =~ stored.two_factor_secret
      # ...and `redact: true` drops the sensitive columns from the Inspect
      # derivation entirely (like :hashed_password), so not even the key leaks.
      refute dump =~ "two_factor_secret"
      refute dump =~ "two_factor_recovery_codes"
      refute dump =~ "hashed_password"
    end
  end

  describe "confirm_two_factor/2" do
    test "a valid OTP stamps confirmed_at and returns 8 plaintext recovery codes" do
      {user, secret} = enrolled(user_fixture())
      code = totp_code_stable!(secret)

      assert {:ok, recovery} = Accounts.confirm_two_factor(user, code)
      assert length(recovery) == 8
      assert Enum.all?(recovery, &is_binary/1)

      reloaded = Accounts.get_user(user.id)
      assert %DateTime{} = reloaded.two_factor_confirmed_at
      assert Accounts.two_factor_enabled?(reloaded)
    end

    test "a wrong OTP returns :invalid_otp and leaves 2FA off" do
      {user, _secret} = enrolled(user_fixture())
      assert {:error, :invalid_otp} = Accounts.confirm_two_factor(user, "000000")
      assert is_nil(Accounts.get_user(user.id).two_factor_confirmed_at)
    end

    test "a user who never enrolled returns :not_enrolled" do
      assert {:error, :not_enrolled} = Accounts.confirm_two_factor(user_fixture(), "123456")
    end

    test "(g) the enrollment OTP cannot then clear the FIRST login challenge" do
      {user, secret} = enrolled(user_fixture())
      code = totp_code_stable!(secret)
      assert {:ok, _recovery} = Accounts.confirm_two_factor(user, code)

      # Confirm consumed the enrollment step and seeded the replay high-water
      # mark. Verifying the SAME code (same step) is now a replay, not a fresh
      # challenge — the enrollment OTP is spent.
      reloaded = Accounts.get_user(user.id)
      assert is_integer(reloaded.two_factor_last_step)
      refute Accounts.verify_two_factor_otp(reloaded, code)
    end
  end

  describe "verify_two_factor_otp/2" do
    test "true for the current code, false for garbage" do
      {user, secret, _codes} = confirmed(user_fixture())
      # confirm spent the enrollment step, so a login challenge uses the NEXT
      # window's code (the same-step enrollment code is gone — see test (g)).
      fresh = code_for_period_offset!(secret, +1)
      assert Accounts.verify_two_factor_otp(user, fresh)
      refute Accounts.verify_two_factor_otp(user, "000000")
    end

    test "false when 2FA is not confirmed" do
      {user, secret} = enrolled(user_fixture())
      refute Accounts.verify_two_factor_otp(user, totp_code_stable!(secret))
    end
  end

  describe "verify_two_factor_otp/2 replay guard" do
    test "(a) the SAME valid OTP is rejected on its second use" do
      {user, secret, _codes} = confirmed(user_fixture())
      # A fresh login-challenge code (next window past the spent enrollment step).
      code = code_for_period_offset!(secret, +1)

      # First use clears; the step is now the persisted high-water mark.
      assert Accounts.verify_two_factor_otp(user, code)
      reloaded = Accounts.get_user(user.id)
      assert is_integer(reloaded.two_factor_last_step)

      # Replaying the SAME code (still inside its ±1 tolerance window) is refused
      # against the reloaded (guard-bearing) user. Without the guard this second
      # verification would succeed — this assertion is the guard's tripwire.
      refute Accounts.verify_two_factor_otp(reloaded, code)
    end

    test "(b) a fresh adjacent-step code is accepted exactly once, and time cannot run backwards" do
      {user, secret, _codes} = confirmed(user_fixture())
      # ONE pinned base for the seeded step AND all three codes below. Headroom is
      # established once, here; deriving each code from this instant is what stops
      # a period roll from turning "next step" into "this step" mid-test.
      now = stable_period_base!(min_headroom_ms: 5_000)

      # confirm seeds the high-water mark at the enrollment step, and matching_step
      # only accepts codes within ±1 window of real time — so to consume TWO
      # ascending fresh steps we start from a user whose last challenge was a
      # couple windows ago (a realistic returning-user state).
      {:ok, user} =
        user
        |> Ecto.Changeset.change(two_factor_last_step: div(now, 30) - 2)
        |> Repo.update()

      # Consume step N.
      code_n = code_at_period_offset(secret, now, 0)
      assert Accounts.verify_two_factor_otp(user, code_n)
      u1 = Accounts.get_user(user.id)

      # A code from the NEXT step (N+1) is a distinct code and is accepted once.
      code_next = code_at_period_offset(secret, now, +1)
      assert Accounts.verify_two_factor_otp(u1, code_next)
      u2 = Accounts.get_user(user.id)

      # Reusing that N+1 code is now a replay — rejected.
      refute Accounts.verify_two_factor_otp(u2, code_next)

      # And an OLDER step (N-1) can never be replayed after N+1 was consumed.
      code_prev = code_at_period_offset(secret, now, -1)
      refute Accounts.verify_two_factor_otp(u2, code_prev)
    end

    test "(d) a STALE (pre-update) struct cannot replay a just-consumed OTP" do
      {user, secret, _codes} = confirmed(user_fixture())
      # Fresh login code (next window past the spent enrollment step).
      code = code_for_period_offset!(secret, +1)

      # First use clears; the DB row now carries the high-water mark, but the
      # `user` struct in memory still holds the pre-update (nil) step.
      assert Accounts.verify_two_factor_otp(user, code)

      # Replaying against that SAME stale struct must still be refused — the
      # single-use guard lives in the atomic UPDATE's WHERE clause, not the
      # in-memory struct. Without atomicity this second call would succeed.
      refute Accounts.verify_two_factor_otp(user, code)
    end

    test "(e) an undecryptable secret returns false without crashing (fail closed)" do
      {user, _secret, _codes} = confirmed(user_fixture())

      {:ok, corrupted} =
        user
        |> Ecto.Changeset.change(two_factor_secret: "not-valid-ciphertext!!")
        |> Repo.update()

      refute Accounts.verify_two_factor_otp(corrupted, "123456")
    end
  end

  describe "consume_recovery_code/2" do
    test "a valid code works exactly once and shrinks the stored set by one" do
      {user, _secret, codes} = confirmed(user_fixture())
      [code | _] = codes

      assert {:ok, after_use} = Accounts.consume_recovery_code(user, code)

      # The same code now fails (consumed); an unknown code always fails.
      assert {:error, :invalid} = Accounts.consume_recovery_code(after_use, code)
      assert {:error, :invalid} = Accounts.consume_recovery_code(after_use, "nope")

      # Stored array shrank by one and is still encrypted (decryptable).
      remaining = TwoFactor.decrypt_codes(after_use.two_factor_recovery_codes)
      assert length(remaining) == length(codes) - 1
      assert after_use.two_factor_recovery_codes != Jason.encode!(remaining)
    end

    test "(f) a STALE struct cannot replay a just-consumed recovery code" do
      {user, _secret, codes} = confirmed(user_fixture())
      [code | _] = codes

      assert {:ok, _} = Accounts.consume_recovery_code(user, code)

      # The original struct still carries the code in its in-memory blob, but the
      # FOR UPDATE re-read inside the txn sees it already gone and refuses. Never
      # trust the passed-in struct.
      assert {:error, :invalid} = Accounts.consume_recovery_code(user, code)
    end

    test "invalid when 2FA is not enabled" do
      assert {:error, :invalid} = Accounts.consume_recovery_code(user_fixture(), "anything")
    end
  end

  describe "disable_two_factor/1 and regenerate_recovery_codes/1" do
    test "disable nulls all columns and flips enabled? false" do
      {user, secret, _codes} = confirmed(user_fixture())
      # Advance the high-water mark with a fresh step, then prove disable nulls it.
      fresh = code_for_period_offset!(secret, +1)
      assert Accounts.verify_two_factor_otp(user, fresh)
      user = Accounts.get_user(user.id)
      assert is_integer(user.two_factor_last_step)

      assert {:ok, disabled} = Accounts.disable_two_factor(user)
      assert is_nil(disabled.two_factor_secret)
      assert is_nil(disabled.two_factor_recovery_codes)
      assert is_nil(disabled.two_factor_confirmed_at)
      assert is_nil(disabled.two_factor_last_step)
      refute Accounts.two_factor_enabled?(disabled)
    end

    test "regenerate invalidates every old code and returns a fresh 8" do
      {user, _secret, old_codes} = confirmed(user_fixture())
      assert {:ok, new_codes} = Accounts.regenerate_recovery_codes(user)
      assert length(new_codes) == 8
      assert MapSet.disjoint?(MapSet.new(old_codes), MapSet.new(new_codes))

      reloaded = Accounts.get_user(user.id)
      # Every OLD code is now rejected.
      assert {:error, :invalid} = Accounts.consume_recovery_code(reloaded, hd(old_codes))
      # A NEW code works.
      assert {:ok, _} = Accounts.consume_recovery_code(reloaded, hd(new_codes))
    end

    test "regenerate is :not_enabled before confirmation" do
      assert {:error, :not_enabled} = Accounts.regenerate_recovery_codes(user_fixture())
    end
  end

  describe "two-phase login token" do
    test "create → verify resolves the user; an expired/garbage token does not" do
      user = user_fixture()
      assert {:ok, pending} = Accounts.create_two_factor_pending_token(user)
      assert %User{id: id} = Accounts.verify_two_factor_pending_token(pending)
      assert id == user.id
      assert is_nil(Accounts.verify_two_factor_pending_token("garbage"))
    end

    test "(c) an EXPIRED pending token no longer resolves" do
      user = user_fixture()
      {:ok, pending} = Accounts.create_two_factor_pending_token(user)
      hash = UserToken.hash_token(pending)
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      {1, _} =
        from(t in UserToken, where: t.token_hash == ^hash)
        |> Repo.update_all(set: [expires_at: past])

      assert is_nil(Accounts.verify_two_factor_pending_token(pending))
    end

    test "a session token does NOT resolve as pending, and vice-versa" do
      user = user_fixture()
      {:ok, session} = Accounts.create_user_session_token(user)
      {:ok, pending} = Accounts.create_two_factor_pending_token(user)

      assert is_nil(Accounts.verify_two_factor_pending_token(session))
      # REGRESSION GUARD: a pending token must never authenticate a session.
      assert is_nil(Accounts.verify_user_session_token(pending))

      # Each resolves through its own context.
      assert %User{} = Accounts.verify_two_factor_pending_token(pending)
      assert %User{} = Accounts.verify_user_session_token(session)
    end

    test "delete_two_factor_pending_tokens removes them" do
      user = user_fixture()
      {:ok, pending} = Accounts.create_two_factor_pending_token(user)
      assert {1, nil} = Accounts.delete_two_factor_pending_tokens(user)
      assert is_nil(Accounts.verify_two_factor_pending_token(pending))
    end
  end
end
