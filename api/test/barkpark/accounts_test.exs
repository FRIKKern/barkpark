defmodule Barkpark.AccountsTest do
  @moduledoc "Phase 1 — user accounts, sessions, email tokens, TOTP MFA."
  use Barkpark.DataCase, async: false

  alias Barkpark.Accounts
  alias Barkpark.Accounts.{User, UserSession}

  @password "correct-horse-battery"

  defp user_fixture(attrs \\ %{}) do
    email = Map.get(attrs, :email, "u#{System.unique_integer([:positive])}@example.com")
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  describe "register_user/1" do
    test "creates a user with an argon2 hash, never storing the plaintext" do
      {:ok, user} = Accounts.register_user(%{email: "Ada@Example.com", password: @password})
      assert user.email == "ada@example.com"
      assert is_nil(user.password)
      assert String.starts_with?(user.hashed_password, "$argon2")
      refute user.hashed_password =~ @password
    end

    test "rejects short passwords and duplicate emails" do
      assert {:error, cs} = Accounts.register_user(%{email: "a@b.com", password: "short"})
      assert %{password: _} = errors_on(cs)

      _ = user_fixture(%{email: "dup@example.com"})

      assert {:error, cs} =
               Accounts.register_user(%{email: "dup@example.com", password: @password})

      assert %{email: _} = errors_on(cs)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "returns the user only on a correct password" do
      user = user_fixture(%{email: "login@example.com"})

      assert %User{id: id} =
               Accounts.get_user_by_email_and_password("login@example.com", @password)

      assert id == user.id
      assert is_nil(Accounts.get_user_by_email_and_password("login@example.com", "wrong"))
    end

    test "returns nil for an unknown email (and does not raise — constant-time dummy)" do
      assert is_nil(Accounts.get_user_by_email_and_password("nobody@example.com", @password))
    end
  end

  describe "sessions" do
    test "mint → verify → revoke lifecycle" do
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user)
      assert %User{id: id} = Accounts.verify_user_session_token(token)
      assert id == user.id

      :ok = Accounts.revoke_user_session_token(token)
      assert is_nil(Accounts.verify_user_session_token(token))
    end

    test "only the SHA-256 hash is stored, never the plaintext" do
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user)
      row = Repo.one(from s in UserSession, where: s.user_id == ^user.id)
      refute row.token_hash == token
      assert row.token_hash == UserSession.hash_token(token)
    end

    test "revoke_all_user_sessions kills every live session" do
      user = user_fixture()
      {:ok, t1} = Accounts.create_user_session_token(user)
      {:ok, t2} = Accounts.create_user_session_token(user)
      :ok = Accounts.revoke_all_user_sessions(user)
      assert is_nil(Accounts.verify_user_session_token(t1))
      assert is_nil(Accounts.verify_user_session_token(t2))
    end

    test "an expired session does not verify" do
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user)
      past = DateTime.add(DateTime.utc_now(), -10, :second) |> DateTime.truncate(:microsecond)
      hash = UserSession.hash_token(token)

      from(s in UserSession, where: s.token_hash == ^hash)
      |> Repo.update_all(set: [expires_at: past])

      assert is_nil(Accounts.verify_user_session_token(token))
    end
  end

  describe "UserSession expiry predicates (Phase 5, pure)" do
    test "expired?/2 honours absolute expires_at" do
      now = DateTime.utc_now()
      past = DateTime.add(now, -10, :second)
      future = DateTime.add(now, 10, :second)

      assert UserSession.expired?(%UserSession{expires_at: past}, now)
      refute UserSession.expired?(%UserSession{expires_at: future}, now)
      # nil expires_at ⇒ unbounded ⇒ never expired
      refute UserSession.expired?(%UserSession{expires_at: nil}, now)
    end

    test "idle_expired?/2 is disabled by default (idle_timeout_seconds is nil)" do
      assert is_nil(UserSession.idle_timeout_seconds())

      now = DateTime.utc_now()
      stale = %UserSession{last_used_at: DateTime.add(now, -86_400, :second)}
      refute UserSession.idle_expired?(stale, now)
    end

    test "active?/2 is false when revoked or absolutely expired, true otherwise" do
      now = DateTime.utc_now()
      future = DateTime.add(now, 10, :second)
      past = DateTime.add(now, -10, :second)

      assert UserSession.active?(%UserSession{expires_at: future, revoked_at: nil}, now)
      refute UserSession.active?(%UserSession{expires_at: future, revoked_at: now}, now)
      refute UserSession.active?(%UserSession{expires_at: past, revoked_at: nil}, now)
    end
  end

  describe "email verification + password reset" do
    test "confirm_user stamps confirmed_at and consumes the token (single-use)" do
      user = user_fixture()
      refute user.confirmed_at
      {:ok, raw} = Accounts.build_email_token(user, "confirm")
      assert {:ok, confirmed} = Accounts.confirm_user(raw)
      assert confirmed.confirmed_at
      assert :error = Accounts.confirm_user(raw)
    end

    test "a confirm token cannot be used for reset (context-bound)" do
      user = user_fixture()
      {:ok, raw} = Accounts.build_email_token(user, "confirm")
      assert :error = Accounts.reset_user_password(raw, %{password: "a-new-strong-password"})
    end

    test "reset_user_password changes the hash and revokes all sessions" do
      user = user_fixture(%{email: "reset@example.com"})
      {:ok, sess} = Accounts.create_user_session_token(user)
      {:ok, raw} = Accounts.build_email_token(user, "reset")

      assert {:ok, _} = Accounts.reset_user_password(raw, %{password: "a-new-strong-password"})
      assert is_nil(Accounts.verify_user_session_token(sess))
      assert Accounts.get_user_by_email_and_password("reset@example.com", "a-new-strong-password")
      assert is_nil(Accounts.get_user_by_email_and_password("reset@example.com", @password))
    end
  end

  describe "TOTP MFA" do
    test "enable with a valid code, then validate live codes" do
      user = user_fixture()
      secret = Accounts.totp_secret()
      assert Accounts.totp_uri(user, secret) =~ "otpauth://"
      code = NimbleTOTP.verification_code(secret)

      assert {:ok, user, codes} = Accounts.enable_totp(user, secret, code)
      assert user.totp_enabled
      assert length(codes) == 10
      assert Accounts.valid_totp?(user, NimbleTOTP.verification_code(secret))
    end

    test "enable fails on a bad code" do
      user = user_fixture()
      assert :error = Accounts.enable_totp(user, Accounts.totp_secret(), "000000")
    end

    test "recovery codes are one-time" do
      user = user_fixture()
      secret = Accounts.totp_secret()

      {:ok, user, [code | _]} =
        Accounts.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      assert {:ok, user} = Accounts.consume_recovery_code(user, code)
      assert :error = Accounts.consume_recovery_code(user, code)
    end

    test "MEDIUM-6: verify_totp consumes the step — a code cannot be replayed" do
      user = user_fixture()
      secret = Accounts.totp_secret()
      {:ok, user, _} = Accounts.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      code = NimbleTOTP.verification_code(secret)
      # First use succeeds and stamps last_totp_at …
      assert {:ok, consumed} = Accounts.verify_totp(user, code)
      assert consumed.last_totp_at

      # … a replay of the SAME code (same 30s step) is now rejected.
      assert :error = Accounts.verify_totp(consumed, code)
      # … and the non-consuming predicate also reads it as invalid now.
      refute Accounts.valid_totp?(consumed, code)
    end

    test "MEDIUM-8: a token reset disables TOTP and clears recovery codes" do
      user = user_fixture(%{email: "hijacked@example.com"})
      secret = Accounts.totp_secret()

      {:ok, user, _codes} =
        Accounts.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      assert user.totp_enabled

      {:ok, raw} = Accounts.build_email_token(user, "reset")

      assert {:ok, recovered} =
               Accounts.reset_user_password(raw, %{password: "a-fresh-strong-pass"})

      refute recovered.totp_enabled
      assert is_nil(recovered.totp_secret)
      assert recovered.recovery_codes_hashed == []
      assert is_nil(recovered.last_totp_at)
    end

    test "an authenticated password change keeps MFA intact (no surprise disable)" do
      user = user_fixture(%{email: "keepmfa@example.com"})
      secret = Accounts.totp_secret()
      {:ok, user, _} = Accounts.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      assert {:ok, changed} =
               Accounts.update_user_password(user, @password, %{password: "another-strong-pass"})

      assert changed.totp_enabled
      refute is_nil(changed.totp_secret)
    end

    test "the TOTP secret is encrypted at rest (no plaintext in the row)" do
      user = user_fixture()
      secret = Accounts.totp_secret()
      {:ok, _user, _} = Accounts.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      %{rows: [[raw]]} =
        Repo.query!("SELECT totp_secret FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])

      refute raw == secret
      assert is_binary(raw)
    end
  end
end
