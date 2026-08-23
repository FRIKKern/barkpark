defmodule Barkpark.AccountsTest do
  @moduledoc "Phase 1 — user accounts, sessions, email tokens, TOTP MFA."
  use Barkpark.DataCase, async: true

  # TOTP codes come from the window-stable helper ONLY — a code minted inline
  # can expire in the gap before the server validates it (honest-gates S1).
  import Barkpark.TotpTestHelper

  alias Barkpark.Accounts
  alias Barkpark.Accounts.{User, UserSession}
  alias Barkpark.Tenancy.Auth
  alias Barkpark.TenancyFixtures

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

      assert {:ok, 1} = Accounts.revoke_user_session_token(token)
      assert is_nil(Accounts.verify_user_session_token(token))
    end

    # PDS-D523: the revoke used to hardcode `:ok` over `Repo.update_all`, so the
    # count died at the source and no caller could tell a live session's death
    # from a no-op. The count now reaches the caller, and the stored row is what
    # proves it — the assertion reads `revoked_at` back through Repo rather than
    # trusting the return value it is checking.
    test "revoke_user_session_token returns the rows it actually stamped, and 0 the second time" do
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user)

      assert {:ok, 1} = Accounts.revoke_user_session_token(token)

      row = Repo.one(from s in UserSession, where: s.user_id == ^user.id)
      refute is_nil(row.revoked_at)

      # Idempotent, not an error: nothing left to revoke answers 0, and the
      # already-stamped row is not re-stamped.
      first_revoked_at = row.revoked_at
      assert {:ok, 0} = Accounts.revoke_user_session_token(token)

      assert Repo.one(from s in UserSession, where: s.user_id == ^user.id).revoked_at ==
               first_revoked_at

      # An unknown token was never a live session: 0, never a raise.
      assert {:ok, 0} = Accounts.revoke_user_session_token("no-such-session-token")
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
      assert {:ok, 2} = Accounts.revoke_all_user_sessions(user)
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

    test "last_used_at write is throttled to a 60s window (perf: no per-request stamp)" do
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user)
      hash = UserSession.hash_token(token)

      # Freeze last_used_at to 5s ago — well inside the 60s throttle window.
      recent = DateTime.add(DateTime.utc_now(), -5, :second) |> DateTime.truncate(:microsecond)

      from(s in UserSession, where: s.token_hash == ^hash)
      |> Repo.update_all(set: [last_used_at: recent])

      # A verify inside the window resolves the user but must NOT rewrite the stamp.
      assert %User{} = Accounts.verify_user_session_token(token)
      inside = Repo.one(from s in UserSession, where: s.token_hash == ^hash)
      assert DateTime.compare(inside.last_used_at, recent) == :eq

      # Push it outside the window → the next verify DOES refresh the stamp.
      old = DateTime.add(DateTime.utc_now(), -120, :second) |> DateTime.truncate(:microsecond)

      from(s in UserSession, where: s.token_hash == ^hash)
      |> Repo.update_all(set: [last_used_at: old])

      assert %User{} = Accounts.verify_user_session_token(token)
      outside = Repo.one(from s in UserSession, where: s.token_hash == ^hash)
      assert DateTime.compare(outside.last_used_at, old) == :gt
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

    # clk-w4-mfa-recency-floor. `mfa_verified_at` is a RECENCY anchor stamped in
    # the past by the issuer, unlike the DEADLINE predicates above, whose anchor
    # is SUPPOSED to be in the future. Under a backward wall-clock step the
    # unfloored predicate reads a future anchor as fresh and keeps the step-up
    # window open forever — `RequireRecentMfa` (plugs/require_recent_mfa.ex:35)
    # is the only enforcement reader, so this predicate covers every path.
    test "mfa_fresh?/3 rejects a mfa_verified_at in the FUTURE" do
      now = DateTime.utc_now()
      future = DateTime.add(now, 100_000, :second)

      # On the unfloored predicate this returns TRUE (a future anchor is
      # trivially inside `now < at + window`).
      refute UserSession.mfa_fresh?(%UserSession{mfa_verified_at: future}, 600, now)
    end

    test "mfa_fresh?/3 still accepts an in-window anchor and rejects a stale one" do
      now = DateTime.utc_now()

      assert UserSession.mfa_fresh?(
               %UserSession{mfa_verified_at: DateTime.add(now, -10, :second)},
               600,
               now
             )

      # The floor is inclusive at the anchor itself.
      assert UserSession.mfa_fresh?(%UserSession{mfa_verified_at: now}, 600, now)

      refute UserSession.mfa_fresh?(
               %UserSession{mfa_verified_at: DateTime.add(now, -1000, :second)},
               600,
               now
             )

      # Never stepped up ⇒ never fresh.
      refute UserSession.mfa_fresh?(%UserSession{mfa_verified_at: nil}, 600, now)
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

    test "a policy-failing password leaves the reset token usable; a valid retry then succeeds" do
      user = user_fixture(%{email: "weakthenstrong@example.com"})
      {:ok, raw} = Accounts.build_email_token(user, "reset")

      # A weak password must NOT consume the token — the reset runs first inside
      # a transaction, so a validation failure rolls back and the link survives.
      # (Before the fix the token was deleted before validating, bricking the link.)
      assert {:error, %Ecto.Changeset{}} = Accounts.reset_user_password(raw, %{password: "short"})

      # The link still works: a strong password now succeeds.
      assert {:ok, _} = Accounts.reset_user_password(raw, %{password: "a-new-strong-password"})

      assert Accounts.get_user_by_email_and_password(
               "weakthenstrong@example.com",
               "a-new-strong-password"
             )
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
      code = totp_code_stable!(secret)

      assert {:ok, user, codes} = Accounts.enable_totp(user, secret, code)
      assert user.totp_enabled
      assert length(codes) == 10
      assert Accounts.valid_totp?(user, totp_code_stable!(secret))
    end

    test "enable fails on a bad code" do
      user = user_fixture()
      assert :error = Accounts.enable_totp(user, Accounts.totp_secret(), "000000")
    end

    test "recovery codes are one-time" do
      user = user_fixture()
      secret = Accounts.totp_secret()

      {:ok, user, [code | _]} =
        Accounts.enable_totp(user, secret, totp_code_stable!(secret))

      assert {:ok, user} = Accounts.consume_recovery_code(user, code)
      assert :error = Accounts.consume_recovery_code(user, code)
    end

    test "TOCTOU: concurrent consumes of the SAME recovery code yield exactly one success" do
      user = user_fixture()
      secret = Accounts.totp_secret()

      {:ok, user, [code | _]} =
        Accounts.enable_totp(user, secret, totp_code_stable!(secret))

      # Two racers hold the SAME stale `user` struct — both pass the in-memory
      # membership check; only the atomic array_remove UPDATE that lands first
      # removes the hash (1 row), the other matches 0 rows and is rejected.
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Barkpark.Repo, parent, self())
            Accounts.consume_recovery_code(user, code)
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, :infinity))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == :error)) == 1

      # The code was removed exactly once (10 → 9, no lost-update leaving it back)
      # and is genuinely one-time: a subsequent consume fails.
      fresh = Repo.get(User, user.id)
      assert length(fresh.recovery_codes_hashed) == 9
      assert :error = Accounts.consume_recovery_code(fresh, code)
    end

    test "MEDIUM-6: verify_totp consumes the step — a code cannot be replayed" do
      user = user_fixture()
      secret = Accounts.totp_secret()
      {:ok, user, _} = Accounts.enable_totp(user, secret, totp_code_stable!(secret))

      code = totp_code_stable!(secret)
      # First use succeeds and stamps last_totp_at …
      assert {:ok, consumed} = Accounts.verify_totp(user, code)
      assert consumed.last_totp_at

      # … a replay of the SAME code (same 30s step) is now rejected.
      assert :error = Accounts.verify_totp(consumed, code)
      # … and the non-consuming predicate also reads it as invalid now.
      refute Accounts.valid_totp?(consumed, code)
    end

    test "LOW TOCTOU: a stale-read replay loses the compare-and-swap" do
      user = user_fixture()
      secret = Accounts.totp_secret()
      {:ok, user, _} = Accounts.enable_totp(user, secret, totp_code_stable!(secret))

      code = totp_code_stable!(secret)

      # Two racers both hold the SAME stale `user` (the last_totp_at they read
      # before either stamped). Both pass NimbleTOTP.valid? against that stale
      # value — the read-then-write window the red-team flagged. The CAS on the
      # read value lets ONLY the first stamp land; the second is a replay.
      assert {:ok, _} = Accounts.verify_totp(user, code)
      assert :error = Accounts.verify_totp(user, code)
    end

    test "MEDIUM-8: a token reset disables TOTP and clears recovery codes" do
      user = user_fixture(%{email: "hijacked@example.com"})
      secret = Accounts.totp_secret()

      {:ok, user, _codes} =
        Accounts.enable_totp(user, secret, totp_code_stable!(secret))

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
      {:ok, user, _} = Accounts.enable_totp(user, secret, totp_code_stable!(secret))

      assert {:ok, changed} =
               Accounts.update_user_password(user, @password, %{password: "another-strong-pass"})

      assert changed.totp_enabled
      refute is_nil(changed.totp_secret)
    end

    test "the TOTP secret is encrypted at rest (no plaintext in the row)" do
      user = user_fixture()
      secret = Accounts.totp_secret()
      {:ok, _user, _} = Accounts.enable_totp(user, secret, totp_code_stable!(secret))

      %{rows: [[raw]]} =
        Repo.query!("SELECT totp_secret FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])

      refute raw == secret
      assert is_binary(raw)
    end
  end

  # ── The TOTP fences (honest-gates charter, D4) ─────────────────────────────
  #
  # These two tests exist because the TOTP code in `accounts.ex` looks wrong in
  # two specific, tempting ways and is right in both. A verifier applied each
  # "obvious fix", RAN the suite, and it stayed 61 tests / 0 failures — the
  # existing tests were structurally incapable of noticing. A comment saying
  # "don't do this" is not a gate. These are.
  #
  # Both fences use the window-stable helper: a protective test that is itself
  # wall-clock flaky teaches readers to dismiss it, which is the disease this
  # epic exists to remove.
  describe "TOTP MFA — protective fences" do
    # FENCE A — `enable_totp/3` deliberately calls the BARE
    # `NimbleTOTP.valid?(secret, code)` with no `since:` option, unlike
    # `valid_totp?/2` and `verify_totp/2` which both pass `totp_opts(user)`.
    # That asymmetry reads like an oversight. It is not.
    #
    # If `enable_totp/3` passed `totp_opts(user)`, a `last_totp_at` left on the
    # row would arrive as `since:` and reject a perfectly valid code minted from
    # a BRAND NEW secret — a permanent enrolment lockout.
    #
    # THE FENCE'S SOURCE OF THAT STAMP CHANGED, and this is why the setup below
    # is explicit rather than incidental. It used to arrive for free:
    # `disable_totp/1` cleared `totp_secret`/`totp_enabled`/`recovery_codes_hashed`
    # but NOT `last_totp_at`, so a disable handed this test the hazardous state
    # by accident. That disagreement between the MFA-wipe paths was itself the
    # defect (`hg-bl-disable-totp-stale-last-totp-at`) and is now fixed, so a
    # disable leaves the stamp nil, `totp_opts/1` returns `[]`, and the tempting
    # mutation would look harmless HERE while still being a lockout wherever a
    # stamp does survive.
    #
    # So the fence now BUILDS the stamp itself. What it guards is
    # `enable_totp/3`'s contract — enrolment validates against the candidate
    # secret alone — not any other function's field set. Constructing the state
    # directly is what keeps that guarantee testable after the only accidental
    # producer of it went away.
    test "FENCE A: re-enrolling a NEW secret after disable_totp accepts a valid code" do
      user = user_fixture(%{email: "re-enrol@example.com"})
      first_secret = Accounts.totp_secret()

      {:ok, user, _codes} =
        Accounts.enable_totp(user, first_secret, totp_code_stable!(first_secret))

      # Consume a step so `last_totp_at` is stamped — this is the state that
      # turns the tempting fix into a lockout. Without it the row's stamp is
      # nil, `totp_opts/1` returns `[]`, and the mutation looks harmless.
      assert {:ok, user} = Accounts.verify_totp(user, totp_code_stable!(first_secret))
      refute is_nil(user.last_totp_at)

      {:ok, user} = Accounts.disable_totp(user)
      refute user.totp_enabled

      # The disable now clears the stamp — that is the fix, and it is asserted
      # here so this fence reds if the two wipe paths ever drift apart again.
      assert is_nil(user.last_totp_at)

      # Re-attach a consumed step directly. This is the hazardous state the
      # fence is about: whatever puts a stamp on a row, `enable_totp/3` must not
      # read it as `since:`.
      {:ok, user} =
        user
        |> User.totp_changeset(%{last_totp_at: DateTime.utc_now()})
        |> Barkpark.Repo.update()

      refute is_nil(user.last_totp_at)

      # A brand new secret and a freshly minted, valid code for it. This MUST
      # enrol. It goes RED the moment `enable_totp/3` starts honouring the
      # stale `since:` stamp from the secret that no longer exists.
      new_secret = Accounts.totp_secret()
      refute new_secret == first_secret

      assert {:ok, re_enrolled, codes} =
               Accounts.enable_totp(user, new_secret, totp_code_stable!(new_secret))

      assert re_enrolled.totp_enabled
      assert length(codes) == 10
    end

    # FENCE B — NimbleTOTP's own moduledoc PRESCRIBES a grace-period recipe
    # (`valid?(secret, otp, time: t) or valid?(secret, otp, time: t - 30)`),
    # which makes adding one to `valid_totp?/2` and `verify_totp/2` look like
    # following the library's guidance. It is not free: it DOUBLES the live
    # acceptance window on two internet-facing endpoints (`mfa_factor_ok?/3`
    # and `login_with_mfa/4`).
    #
    # The careless copy of that recipe drops `since:` and is already caught by
    # the MEDIUM-6 replay test above. The CAREFUL variant — which threads
    # `since:` through both `valid?` calls — passes every other test in this
    # tree silently, because `grep -rn 'verification_code(.*time:' api/test/`
    # returned ZERO before this fence: the suite generated no off-period codes
    # at all and could not observe window width. This is the eye that was
    # missing.
    test "FENCE B: a previous-period code is refused by BOTH valid_totp?/2 and verify_totp/2" do
      user = user_fixture(%{email: "window-width@example.com"})
      secret = Accounts.totp_secret()

      {:ok, user, _codes} = Accounts.enable_totp(user, secret, totp_code_stable!(secret))
      assert user.totp_enabled
      # Enrolment does not stamp a step, so `totp_opts/1` is `[]` here: the
      # ONLY thing that can reject the code below is the acceptance WINDOW, not
      # replay protection. That isolation is what makes this fence honest.
      assert is_nil(user.last_totp_at)

      # Mint a code for the PREVIOUS period, boundary-guarded so the period does
      # not roll between minting and checking. Without the guard a roll would
      # make this a two-periods-old code, which even a grace window rejects —
      # the fence would then pass for the wrong reason, which is worse than
      # failing.
      stale = code_for_period_offset!(secret, -1)
      # Sanity: the previous period's code really is a different code. If the
      # two collide (1 in 10^6) the assertions below would be vacuous.
      assert stale != totp_code_stable!(secret)

      refute Accounts.valid_totp?(user, stale)
      assert :error = Accounts.verify_totp(user, stale)

      # And the rejection above is not a blanket "nothing is ever valid": the
      # CURRENT period's code still works. A fence that cannot be green is as
      # dishonest as one that cannot be red.
      assert Accounts.valid_totp?(user, totp_code_stable!(secret))
    end
  end

  describe "search_by_email_prefix/3 (Share-access recipient typeahead)" do
    # Register a user AND bind it as a `user`-principal member of `ws`.
    defp member_of(ws, email) do
      {:ok, user} = Accounts.register_user(%{email: email, password: @password})
      {:ok, _m} = Auth.create_membership(ws.id, user.id, "member", "user")
      user
    end

    test "returns matching workspace-member emails, ordered, email strings only" do
      ws = TenancyFixtures.create_workspace!()
      member_of(ws, "alice@example.com")
      member_of(ws, "alan@example.com")
      member_of(ws, "bob@example.com")

      result = Accounts.search_by_email_prefix("al", ws.id)

      # bare list of email STRINGS (no ids/structs/other columns), sorted
      assert result == ["alan@example.com", "alice@example.com"]
      assert Enum.all?(result, &is_binary/1)
    end

    test "case-insensitive prefix (downcases input)" do
      ws = TenancyFixtures.create_workspace!()
      member_of(ws, "carol@example.com")

      assert Accounts.search_by_email_prefix("CAR", ws.id) == ["carol@example.com"]
    end

    test "LIMIT is respected (opts[:limit], default 8)" do
      ws = TenancyFixtures.create_workspace!()
      for n <- 1..10, do: member_of(ws, "user#{n}@example.com")

      assert length(Accounts.search_by_email_prefix("user", ws.id)) == 8
      assert length(Accounts.search_by_email_prefix("user", ws.id, limit: 3)) == 3
    end

    test "cross-workspace isolation — a member of ws_B is NOT returned when searching ws_A" do
      ws_a = TenancyFixtures.create_workspace!()
      ws_b = TenancyFixtures.create_workspace!()

      member_of(ws_a, "insider@example.com")
      # Same prefix, but only a member of ws_B — must NOT leak into ws_A results.
      member_of(ws_b, "intruder@example.com")

      result = Accounts.search_by_email_prefix("in", ws_a.id)

      assert result == ["insider@example.com"]
      refute "intruder@example.com" in result
    end

    test "a registered user with NO membership in the workspace is not returned" do
      ws = TenancyFixtures.create_workspace!()
      # Registered but never bound to the workspace.
      {:ok, _} = Accounts.register_user(%{email: "orphan@example.com", password: @password})

      assert Accounts.search_by_email_prefix("orphan", ws.id) == []
    end

    test "blank / whitespace prefix returns [] (no member dump)" do
      ws = TenancyFixtures.create_workspace!()
      member_of(ws, "dana@example.com")

      assert Accounts.search_by_email_prefix("", ws.id) == []
      assert Accounts.search_by_email_prefix("   ", ws.id) == []
    end

    test "nil / blank workspace_id returns [] (fail closed)" do
      assert Accounts.search_by_email_prefix("a", nil) == []
      assert Accounts.search_by_email_prefix("a", "") == []
    end

    test "LIKE wildcards in the prefix are escaped — a '%' does not dump the roster" do
      ws = TenancyFixtures.create_workspace!()
      member_of(ws, "eve@example.com")
      member_of(ws, "frank@example.com")

      # If '%' were unescaped it would match every member; escaped, it matches
      # only an email that literally begins with '%' (none here).
      assert Accounts.search_by_email_prefix("%", ws.id) == []
      assert Accounts.search_by_email_prefix("_", ws.id) == []
    end
  end
end
