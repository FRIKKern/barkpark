defmodule BarkparkCloud.AccountsTest do
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{Team, TeamMembership, User, UserToken}
  alias BarkparkCloud.Billing
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Repo

  @valid_password "correct-horse-battery"
  @valid_email "ada@example.com"

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @valid_password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  describe "register_user/1" do
    test "hashes the password and never stores plaintext" do
      assert {:ok, %User{} = user} =
               Accounts.register_user(%{email: @valid_email, password: @valid_password})

      assert user.email == @valid_email
      # The plaintext is gone; only the bcrypt hash is persisted.
      assert is_binary(user.hashed_password)
      assert user.hashed_password != @valid_password
      assert String.starts_with?(user.hashed_password, "$2")
      # The virtual :password field is cleared after hashing.
      assert is_nil(user.password)

      reloaded = Accounts.get_user(user.id)
      assert reloaded.hashed_password == user.hashed_password
      refute reloaded.hashed_password =~ @valid_password
    end

    test "downcases the email" do
      assert {:ok, user} =
               Accounts.register_user(%{email: "Ada@Example.COM", password: @valid_password})

      assert user.email == "ada@example.com"
    end

    test "requires email and password" do
      assert {:error, changeset} = Accounts.register_user(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.email
      assert "can't be blank" in errors.password
    end

    test "validates email format" do
      assert {:error, changeset} =
               Accounts.register_user(%{email: "not-an-email", password: @valid_password})

      assert "must have the @ sign and no spaces" in errors_on(changeset).email
    end

    test "enforces a minimum password length" do
      assert {:error, changeset} =
               Accounts.register_user(%{email: @valid_email, password: "short"})

      assert "should be at least #{User.min_password_length()} character(s)" in errors_on(
               changeset
             ).password
    end

    test "enforces email uniqueness (case-insensitive)" do
      assert {:ok, _} = Accounts.register_user(%{email: @valid_email, password: @valid_password})

      # Same email, different case — citext makes this a collision.
      assert {:error, changeset} =
               Accounts.register_user(%{email: "ADA@example.com", password: @valid_password})

      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "get_user_by_email_and_password/2" do
    setup do
      {:ok, user: user_fixture(%{email: @valid_email, password: @valid_password})}
    end

    test "returns the user on the correct password", %{user: user} do
      assert authed = Accounts.get_user_by_email_and_password(@valid_email, @valid_password)
      assert authed.id == user.id
    end

    test "authenticates case-insensitively on the email", %{user: user} do
      assert authed = Accounts.get_user_by_email_and_password("ADA@EXAMPLE.COM", @valid_password)
      assert authed.id == user.id
    end

    test "returns nil on the wrong password" do
      assert is_nil(Accounts.get_user_by_email_and_password(@valid_email, "wrong-password"))
    end

    test "returns nil for a missing user (and does not raise)" do
      assert is_nil(
               Accounts.get_user_by_email_and_password("nobody@example.com", @valid_password)
             )
    end
  end

  describe "create_team/1" do
    test "creates a team with a valid slug" do
      assert {:ok, %Team{} = team} = Accounts.create_team(%{name: "Acme", slug: "acme"})
      assert team.slug == "acme"
    end

    test "rejects an invalid slug format" do
      assert {:error, changeset} = Accounts.create_team(%{name: "Acme", slug: "Acme Inc"})
      assert "must be lowercase alphanumeric with hyphens" in errors_on(changeset).slug
    end

    test "rejects a reserved slug" do
      assert {:error, changeset} = Accounts.create_team(%{name: "Admin", slug: "admin"})
      assert "is reserved" in errors_on(changeset).slug
    end

    test "enforces slug uniqueness" do
      assert {:ok, _} = Accounts.create_team(%{name: "Acme", slug: "acme"})
      assert {:error, changeset} = Accounts.create_team(%{name: "Acme Two", slug: "acme"})
      assert "has already been taken" in errors_on(changeset).slug
    end
  end

  describe "add_member/3" do
    setup do
      {:ok, user: user_fixture(), team: team_fixture()}
    end

    test "defaults the role to member", %{user: user, team: team} do
      assert {:ok, %TeamMembership{} = m} = Accounts.add_member(team, user)
      assert m.role == "member"
      assert m.user_id == user.id
      assert m.team_id == team.id
    end

    test "accepts an explicit owner role", %{user: user, team: team} do
      assert {:ok, m} = Accounts.add_member(team, user, "owner")
      assert m.role == "owner"
    end

    test "rejects an invalid role", %{user: user, team: team} do
      assert {:error, changeset} = Accounts.add_member(team, user, "superuser")
      assert "is invalid" in errors_on(changeset).role
    end

    test "enforces the (user, team) unique constraint", %{user: user, team: team} do
      assert {:ok, _} = Accounts.add_member(team, user, "owner")

      assert {:error, changeset} = Accounts.add_member(team, user, "member")
      assert "is already a member of this team" in errors_on(changeset).user_id
    end

    test "the same user can belong to two different teams", %{user: user, team: team} do
      other_team = team_fixture()
      assert {:ok, _} = Accounts.add_member(team, user)
      assert {:ok, _} = Accounts.add_member(other_team, user)
    end

    test "accepts raw binary ids for team and user", %{user: user, team: team} do
      assert {:ok, m} = Accounts.add_member(team.id, user.id, "admin")
      assert m.role == "admin"
    end
  end

  describe "user session tokens (cloud-12a)" do
    test "mint returns a plaintext that verifies back to the user" do
      user = user_fixture()
      assert {:ok, plaintext} = Accounts.create_user_session_token(user)
      assert is_binary(plaintext)

      authed = Accounts.verify_user_session_token(plaintext)
      assert authed.id == user.id
    end

    test "only the hash is stored — the plaintext is unrecoverable" do
      user = user_fixture()
      {:ok, plaintext} = Accounts.create_user_session_token(user)

      [stored] = Repo.all(BarkparkCloud.Accounts.UserToken)
      refute stored.token_hash == plaintext
      assert stored.token_hash == BarkparkCloud.Accounts.UserToken.hash_token(plaintext)
    end

    test "a bogus / unknown token verifies to nil" do
      assert is_nil(Accounts.verify_user_session_token("not-a-token"))
    end

    test "an expired token verifies to nil" do
      user = user_fixture()
      {:ok, plaintext} = Accounts.create_user_session_token(user)

      # Backdate the expiry past now.
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

      Repo.update_all(BarkparkCloud.Accounts.UserToken, set: [expires_at: past])

      assert is_nil(Accounts.verify_user_session_token(plaintext))
    end
  end

  describe "list_user_teams/1 + primary_team/1" do
    test "primary_team is the first team the user joined" do
      user = user_fixture()
      first = team_fixture()
      second = team_fixture()

      {:ok, _} = Accounts.add_member(first, user, "owner")
      {:ok, _} = Accounts.add_member(second, user)

      assert [a, b] = Accounts.list_user_teams(user)
      assert a.id == first.id
      assert b.id == second.id
      assert Accounts.primary_team(user).id == first.id
    end

    test "a user in no team has nil primary_team" do
      user = user_fixture()
      assert Accounts.list_user_teams(user) == []
      assert is_nil(Accounts.primary_team(user))
    end
  end

  ## Session lifecycle (account-sessions) ----------------------------------

  describe "revoke_user_session_token/1 (single-device logout kill switch)" do
    test "a revoked token no longer verifies" do
      user = user_fixture()
      {:ok, plaintext} = Accounts.create_user_session_token(user)
      assert Accounts.verify_user_session_token(plaintext).id == user.id

      assert {:ok, %UserToken{} = revoked} = Accounts.revoke_user_session_token(plaintext)
      assert revoked.revoked_at != nil
      # The kill switch: the same plaintext is now dead.
      assert is_nil(Accounts.verify_user_session_token(plaintext))
    end

    test "revoking an already-revoked token is idempotent" do
      user = user_fixture()
      {:ok, plaintext} = Accounts.create_user_session_token(user)
      assert {:ok, _} = Accounts.revoke_user_session_token(plaintext)
      assert {:ok, _} = Accounts.revoke_user_session_token(plaintext)
    end

    test "an unknown plaintext is {:error, :not_found}" do
      assert {:error, :not_found} = Accounts.revoke_user_session_token("not-a-real-token")
    end
  end

  describe "create_user_session_token/2 device metadata + list_user_sessions/1" do
    test "captures ip_address / user_agent at mint" do
      user = user_fixture()

      {:ok, plaintext} =
        Accounts.create_user_session_token(user, ip_address: "203.0.113.7", user_agent: "Chrome")

      [row] = Accounts.list_user_sessions(user)
      assert row.ip_address == "203.0.113.7"
      assert row.user_agent == "Chrome"
      assert row.last_used_at != nil
      # Sanity: the plaintext still resolves.
      assert Accounts.verify_user_session_token(plaintext).id == user.id
    end

    test "list returns only LIVE rows (revoked excluded)" do
      user = user_fixture()
      {:ok, keep} = Accounts.create_user_session_token(user)
      {:ok, kill} = Accounts.create_user_session_token(user)

      {:ok, _} = Accounts.revoke_user_session_token(kill)

      ids = user |> Accounts.list_user_sessions() |> Enum.map(& &1.token_hash)
      assert UserToken.hash_token(keep) in ids
      refute UserToken.hash_token(kill) in ids
    end

    test "verify_user_session_token bumps last_used_at" do
      user = user_fixture()
      {:ok, plaintext} = Accounts.create_user_session_token(user)
      [before] = Accounts.list_user_sessions(user)

      # Backdate so the verify-time touch is observably newer.
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)
      Repo.update_all(UserToken, set: [last_used_at: past])

      assert Accounts.verify_user_session_token(plaintext).id == user.id
      [after_touch] = Accounts.list_user_sessions(user)
      assert DateTime.compare(after_touch.last_used_at, before.last_used_at) in [:eq, :gt]
      assert DateTime.compare(after_touch.last_used_at, past) == :gt
    end

    # The backdate above is EXACTLY the throttle window (60s), and it stays that
    # way on purpose: it pins the boundary as STALE (`>=`), which is what
    # `touch_last_used/2`'s `last_used_at <= now - 60s` clause encodes. A `>`
    # predicate would leave this test red at left: :lt.

    test "touch: false verifies WITHOUT stamping — the plug pipeline owns the stamp" do
      user = user_fixture()
      {:ok, plaintext} = Accounts.create_user_session_token(user)

      past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:microsecond)
      Repo.update_all(UserToken, set: [last_used_at: past])

      assert Accounts.verify_user_session_token(plaintext, touch: false).id == user.id

      [row] = Accounts.list_user_sessions(user)

      assert DateTime.compare(row.last_used_at, past) == :eq,
             "verify stamped anyway — Web.Auth could not then withhold it from a refused request"
    end

    test "the stamp is throttled: a second touch inside the 60s window writes nothing" do
      user = user_fixture()
      {:ok, plaintext} = Accounts.create_user_session_token(user)

      past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:microsecond)
      Repo.update_all(UserToken, set: [last_used_at: past])

      :ok = Accounts.touch_session_last_used(plaintext)
      [first] = Accounts.list_user_sessions(user)
      assert DateTime.compare(first.last_used_at, past) == :gt

      :ok = Accounts.touch_session_last_used(plaintext)
      [second] = Accounts.list_user_sessions(user)

      assert DateTime.compare(second.last_used_at, first.last_used_at) == :eq,
             "the second stamp wrote inside the window — every request is an UPDATE again"
    end

    test "touching an unknown plaintext is a no-op, not a raise" do
      assert Accounts.touch_session_last_used("not-a-real-token") == :ok
    end
  end

  describe "create_user_session_token/2 origin (gr-p5-session-provenance)" do
    # THE ROUND TRIP. Column existence proves nothing here: the migration, the
    # schema field and the write-site keyword all land happily while `cast/3`
    # silently DISCARDS `:origin` — no Ecto warning, no compiler warning — and
    # the whole suite stays green while every row is written NULL. So this reads
    # the value back TWICE: off the loaded struct, and via raw SQL against the
    # actual column. The raw-SQL leg is the one a struct default could never
    # satisfy, and it is what reds when `:origin` leaves UserToken.changeset/2's
    # cast allowlist (`left: nil, right: "device_link"`).
    test "a real mint round-trips the origin to the COLUMN, not just the struct" do
      user = user_fixture()

      {:ok, plaintext} =
        Accounts.create_user_session_token(user, user_agent: "bp/agent", origin: "device_link")

      hash = UserToken.hash_token(plaintext)

      # Leg 1 — off the struct, through the normal read path the UI uses.
      [row] = Accounts.list_user_sessions(user)
      assert row.origin == "device_link"

      # Leg 2 — the column itself, bypassing Ecto's field defaults entirely.
      assert %Postgrex.Result{rows: [["device_link"]]} =
               Repo.query!("SELECT origin FROM user_tokens WHERE token_hash = $1", [hash])
    end

    test "omitting :origin stores NULL — it is never inferred from the other opts" do
      user = user_fixture()

      {:ok, plaintext} =
        Accounts.create_user_session_token(user, ip_address: "203.0.113.7", user_agent: "Chrome")

      [row] = Accounts.list_user_sessions(user)
      assert is_nil(row.origin)

      assert %Postgrex.Result{rows: [[nil]]} =
               Repo.query!("SELECT origin FROM user_tokens WHERE token_hash = $1", [
                 UserToken.hash_token(plaintext)
               ])
    end

    test "nothing backfills: a pre-existing NULL row stays NULL when a NEW row is minted" do
      user = user_fixture()
      {:ok, legacy} = Accounts.create_user_session_token(user)
      {:ok, _fresh} = Accounts.create_user_session_token(user, origin: "password")

      assert %Postgrex.Result{rows: [[nil]]} =
               Repo.query!("SELECT origin FROM user_tokens WHERE token_hash = $1", [
                 UserToken.hash_token(legacy)
               ])
    end

    test "a PAT can neither receive nor expose an origin (separate cast list)" do
      {user, team} = user_with_team()

      {:ok, _plaintext, pat} =
        Accounts.create_personal_access_token(user, team, %{
          name: "ci-token",
          origin: "device_link"
        })

      assert is_nil(Repo.get!(UserToken, pat.id).origin)
    end

    # The CLOSED-SET guard. Three of the six mint sites (login, password change,
    # device link) carry end-to-end round-trip probes above, and since cch-w10 the
    # OAuth site has two of its own in router_oauth_test.exs (a github code yields
    # origin "oauth:github", a google code "oauth:google"); only `register/4` still
    # has none — it needs the full billing/trial transaction. This reads the source
    # instead, so a
    # seventh mint site added without an origin, or a literal typo'd at either
    # untested site, reds HERE rather than shipping a silently-NULL column.
    # Source-text by construction: it is refactor-brittle on purpose, and the
    # failure message is its documentation.
    test "every Accounts.create_user_session_token/2 call site stamps an origin (closed set of six)" do
      lib = Path.expand("../../lib/barkpark_cloud", __DIR__)

      sources =
        for f <- ["web/router.ex", "device_auth.ex"], do: File.read!(Path.join(lib, f))

      calls =
        sources
        |> Enum.flat_map(&(String.split(&1, "Accounts.create_user_session_token(") |> tl()))

      assert length(calls) == 6,
             "the mint-site set moved (#{length(calls)} call sites, expected 6) — a NEW site must " <>
               "stamp its own origin, and this count must move with it"

      for {tail, i} <- Enum.with_index(calls) do
        assert String.contains?(String.slice(tail, 0, 400), "origin:"),
               "mint call site ##{i} passes no :origin — it would write NULL silently"
      end

      router = hd(sources)

      for literal <- ~w(password two_factor password_change register),
          do:
            assert(
              String.contains?(router, "origin: \"#{literal}\""),
              "the #{literal} origin literal is gone from router.ex"
            )

      # cch-w10 — the OAuth origin no longer has a literal in router.ex. The mint
      # moved off the callback (whose 302's `location` header was handing out a
      # live session token) to POST /v1/auth/oauth/exchange, and the provider
      # travels there on the exchange code's own `sent_to`, so the router now
      # forwards a BOUND value. That makes the seam — not a literal — the thing to
      # guard, in three links, each of which fails silently on its own: the
      # callback must name its provider, the mint must carry it, and the exchange
      # must forward what it consumed.
      assert String.contains?(router, ~S|Accounts.create_oauth_exchange_code(user, provider)|),
             "the callback stopped handing its own provider to the exchange code"

      assert String.contains?(router, "session_opts(conn) ++ [origin: origin]"),
             "the exchange stopped forwarding the consumed code's own origin"

      assert String.contains?(
               File.read!(Path.join(lib, "accounts.ex")),
               ~S|sent_to: "oauth:#{provider}"|
             ),
             "the exchange code stopped carrying the provider that authenticated the user"

      assert String.contains?(List.last(sources), ~s|origin: "device_link"|),
             "device_auth stopped stamping device_link"
    end
  end

  describe "revoke_user_session/2 (ownership-scoped row revoke)" do
    test "revokes the caller's own row by id" do
      user = user_fixture()
      {:ok, plaintext} = Accounts.create_user_session_token(user)
      [row] = Accounts.list_user_sessions(user)

      assert {:ok, _} = Accounts.revoke_user_session(user, row.id)
      assert is_nil(Accounts.verify_user_session_token(plaintext))
    end

    test "another user's row id is :not_found (no existence leak)" do
      owner = user_fixture()
      other = user_fixture()
      {:ok, _} = Accounts.create_user_session_token(owner)
      [row] = Accounts.list_user_sessions(owner)

      assert {:error, :not_found} = Accounts.revoke_user_session(other, row.id)
      # The owner's session is untouched.
      assert [_] = Accounts.list_user_sessions(owner)
    end
  end

  describe "revoke_all_user_sessions/2 (sign out everywhere)" do
    test "revokes every live session" do
      user = user_fixture()
      {:ok, _} = Accounts.create_user_session_token(user)
      {:ok, _} = Accounts.create_user_session_token(user)
      {:ok, _} = Accounts.create_user_session_token(user)

      assert {:ok, 3} = Accounts.revoke_all_user_sessions(user)
      assert Accounts.list_user_sessions(user) == []
    end

    test ":except keeps the named plaintext alive" do
      user = user_fixture()
      {:ok, keep} = Accounts.create_user_session_token(user)
      {:ok, _} = Accounts.create_user_session_token(user)
      {:ok, _} = Accounts.create_user_session_token(user)

      assert {:ok, 2} = Accounts.revoke_all_user_sessions(user, except: keep)
      # The excepted token still authenticates; the other two are dead.
      assert Accounts.verify_user_session_token(keep).id == user.id
      assert [survivor] = Accounts.list_user_sessions(user)
      assert survivor.token_hash == UserToken.hash_token(keep)
    end

    # cch-w53-s4. The sweep is `context in ["session", "sse"]`, and the two tests
    # below are the fences on each side of that widening: everything a signed-out
    # user could still stream with must die, and NOTHING else may.
    test "it also burns the user's live SSE stream tickets" do
      user = user_fixture()
      {:ok, _} = Accounts.create_user_session_token(user)
      ticket = elem(Accounts.create_sse_ticket(user), 1)

      # Without this, a ticket minted a second before "sign out everywhere"
      # opened a fresh authenticated /v1/events stream for the rest of its 60s
      # TTL — the row-level half of the "signed out immediately" claim.
      assert {:ok, 1} = Accounts.revoke_all_user_sessions(user)
      assert Accounts.consume_sse_ticket(ticket) == nil
    end

    test "the count it reports is SESSIONS only — tickets are not padding" do
      # The number goes straight to the console as `{revoked: N}` ("N sessions
      # signed out"). Counting swept tickets would inflate it into a new number
      # the product cannot support, which is the exact defect class this wave is
      # closing. Two sessions + two tickets is still 2.
      user = user_fixture()
      {:ok, _} = Accounts.create_user_session_token(user)
      {:ok, _} = Accounts.create_user_session_token(user)
      {:ok, _} = Accounts.create_sse_ticket(user)
      {:ok, _} = Accounts.create_sse_ticket(user)

      assert {:ok, 2} = Accounts.revoke_all_user_sessions(user)
    end
  end

  describe "update_user_password/4 (change password ⇒ sign out everywhere)" do
    @new_password "fresh-horse-battery-staple"

    test "wrong current password leaves the hash unchanged" do
      user = user_fixture(%{password: @valid_password})
      before = user.hashed_password

      assert {:error, :invalid_current_password} =
               Accounts.update_user_password(user, "wrong-current", @new_password)

      assert Accounts.get_user(user.id).hashed_password == before
    end

    test "a weak new password is rejected with a changeset" do
      user = user_fixture(%{password: @valid_password})

      assert {:error, %Ecto.Changeset{} = cs} =
               Accounts.update_user_password(user, @valid_password, "short")

      assert "should be at least #{User.min_password_length()} character(s)" in errors_on(cs).password
    end

    test "success: the new password authenticates" do
      user = user_fixture(%{email: "pw@example.com", password: @valid_password})

      assert {:ok, %User{}} =
               Accounts.update_user_password(user, @valid_password, @new_password)

      assert Accounts.get_user_by_email_and_password("pw@example.com", @new_password)
      refute Accounts.get_user_by_email_and_password("pw@example.com", @valid_password)
    end

    test "success revokes OTHER sessions but keeps the :keep token alive" do
      user = user_fixture(%{password: @valid_password})
      {:ok, acting} = Accounts.create_user_session_token(user)
      {:ok, other} = Accounts.create_user_session_token(user)

      assert {:ok, _} =
               Accounts.update_user_password(user, @valid_password, @new_password, keep: acting)

      # The acting tab survives; the other device is signed out.
      assert Accounts.verify_user_session_token(acting).id == user.id
      assert is_nil(Accounts.verify_user_session_token(other))
    end

    test "success revokes the user's teams' agent tokens" do
      user = user_fixture(%{password: @valid_password})
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "owner")

      {:ok, bp} =
        Registry.register_barkpark(team, %{
          name: "Box",
          slug: "box-#{System.unique_integer([:positive])}"
        })

      {:ok, agent_plain, _} = Registry.mint_agent_token(bp, "deploy")
      assert Registry.verify_agent_token(agent_plain).id == bp.id

      assert {:ok, _} = Accounts.update_user_password(user, @valid_password, @new_password)

      # The control-plane half of the kill switch: agent creds are dead too.
      assert is_nil(Registry.verify_agent_token(agent_plain))
    end
  end

  ## Personal access tokens

  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  describe "create_personal_access_token/3" do
    test "returns the plaintext ONCE and stores only the hash" do
      {user, team} = user_with_team()

      assert {:ok, plaintext, %UserToken{} = pat} =
               Accounts.create_personal_access_token(user, team, %{
                 name: "ci-key",
                 abilities: ["read"]
               })

      assert String.starts_with?(plaintext, "bpc_pat_")
      assert pat.context == "pat"
      assert pat.name == "ci-key"
      assert pat.token_hash == UserToken.hash_token(plaintext)
      # The plaintext is unrecoverable — the row holds only the hash.
      reloaded = Repo.get(UserToken, pat.id)
      assert reloaded.token_hash == pat.token_hash
      refute reloaded.token_hash == plaintext
    end

    test "defaults to a 30-day expiry; :expires_in_days nil means never" do
      {user, team} = user_with_team()

      {:ok, _pt, default_pat} =
        Accounts.create_personal_access_token(user, team, %{name: "default-exp"})

      assert default_pat.expires_at
      days = DateTime.diff(default_pat.expires_at, DateTime.utc_now(), :second) / 86_400
      assert_in_delta days, 30, 1

      {:ok, _pt2, never_pat} =
        Accounts.create_personal_access_token(user, team, %{
          name: "never-exp",
          expires_in_days: nil
        })

      assert is_nil(never_pat.expires_at)
    end

    test "normalizes ability exclusivity: root collapses to [root]" do
      {user, team} = user_with_team()

      {:ok, _pt, pat} =
        Accounts.create_personal_access_token(user, team, %{
          name: "root-key",
          abilities: ["read", "write", "root"]
        })

      assert pat.abilities == ["root"]
    end

    test "normalizes ability exclusivity: deploy collapses to [deploy]" do
      {user, team} = user_with_team()

      {:ok, _pt, pat} =
        Accounts.create_personal_access_token(user, team, %{
          name: "deploy-key",
          abilities: ["read", "deploy"]
        })

      assert pat.abilities == ["deploy"]
    end

    test "dedupes non-exclusive abilities" do
      {user, team} = user_with_team()

      {:ok, _pt, pat} =
        Accounts.create_personal_access_token(user, team, %{
          name: "rw-key",
          abilities: ["read", "read", "write"]
        })

      assert Enum.sort(pat.abilities) == ["read", "write"]
    end

    test "rejects an unknown ability" do
      {user, team} = user_with_team()

      assert {:error, changeset} =
               Accounts.create_personal_access_token(user, team, %{
                 name: "bad-key",
                 abilities: ["bogus"]
               })

      assert %{abilities: _} = errors_on(changeset)
    end

    test "rejects a too-short name" do
      {user, team} = user_with_team()

      assert {:error, changeset} =
               Accounts.create_personal_access_token(user, team, %{name: "ab"})

      assert %{name: _} = errors_on(changeset)
    end

    test "M8: a plain member may mint only a read PAT; deploy/root/write → :forbidden" do
      {owner, team} = user_with_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      # read is fine for a member.
      assert {:ok, _pt, %UserToken{abilities: ["read"]}} =
               Accounts.create_personal_access_token(member, team, %{
                 name: "ro-key",
                 abilities: ["read"]
               })

      # deploy / root / write are owner/admin-only.
      for ability <- ["deploy", "root", "write"] do
        assert {:error, :forbidden} =
                 Accounts.create_personal_access_token(member, team, %{
                   name: "esc-key",
                   abilities: [ability]
                 })
      end

      # an owner may mint an elevated PAT.
      assert {:ok, _pt, %UserToken{abilities: ["root"]}} =
               Accounts.create_personal_access_token(owner, team, %{
                 name: "root-key",
                 abilities: ["root"]
               })
    end

    test "M8: a non-member is also capped at read" do
      {_owner, team} = user_with_team()
      stranger = user_fixture()

      assert {:error, :forbidden} =
               Accounts.create_personal_access_token(stranger, team, %{
                 name: "dep-key",
                 abilities: ["deploy"]
               })
    end
  end

  describe "session kill-switches preserve PATs (B4 context scoping)" do
    test "sign out everywhere revokes sessions but NOT the user's PATs" do
      {user, team} = user_with_team()
      {:ok, _s1} = Accounts.create_user_session_token(user)
      {:ok, _s2} = Accounts.create_user_session_token(user)

      {:ok, pat_plain, _} =
        Accounts.create_personal_access_token(user, team, %{name: "ci-key", abilities: ["read"]})

      assert {:ok, 2} = Accounts.revoke_all_user_sessions(user)
      assert Accounts.list_user_sessions(user) == []
      # The PAT still verifies.
      assert {%User{}, %UserToken{}} = Accounts.verify_personal_access_token(pat_plain)
    end

    test "the SSE widening stops at 'sse' — a PAT row is not swept with it" do
      # cch-w53-s4 widened the sweep from `context == "session"` to
      # `context in ["session", "sse"]`. One character further ("pat" in the same
      # list, or dropping the context filter for a plain user_id sweep) kills the
      # user's programmatic credentials on a password change and nothing in the
      # UI would say so. Assert on the ROWS, not just on verify/2, so a future
      # verify that tolerates revoked_at cannot hide it.
      {user, team} = user_with_team()
      {:ok, _s} = Accounts.create_user_session_token(user)
      {:ok, _ticket} = Accounts.create_sse_ticket(user)

      {:ok, _pat_plain, pat} =
        Accounts.create_personal_access_token(user, team, %{name: "ci-key", abilities: ["read"]})

      assert {:ok, 1} = Accounts.revoke_all_user_sessions(user)

      live = fn context ->
        Repo.one(
          from t in UserToken,
            where: t.user_id == ^user.id and t.context == ^context and is_nil(t.revoked_at),
            select: count(t.id)
        )
      end

      assert live.("session") == 0
      assert live.("sse") == 0
      assert live.("pat") == 1
      assert is_nil(Repo.get!(UserToken, pat.id).revoked_at)
    end

    test "a password change does NOT revoke the user's PATs" do
      {user, team} = user_with_team()

      {:ok, pat_plain, _} =
        Accounts.create_personal_access_token(user, team, %{name: "ci-key", abilities: ["read"]})

      assert {:ok, %User{}} =
               Accounts.update_user_password(
                 user,
                 @valid_password,
                 "fresh-horse-battery-staple"
               )

      assert {%User{}, %UserToken{}} = Accounts.verify_personal_access_token(pat_plain)
    end

    test "list_user_sessions excludes PAT rows" do
      {user, team} = user_with_team()
      {:ok, _s} = Accounts.create_user_session_token(user)
      {:ok, _pt, _} = Accounts.create_personal_access_token(user, team, %{name: "pat-key"})

      rows = Accounts.list_user_sessions(user)
      assert length(rows) == 1
      assert Enum.all?(rows, &(&1.context == "session"))
    end

    # The session eviction PRIMITIVE never touches PATs. Membership removal
    # itself does end them, but through the separate, team-scoped
    # `revoke_team_pats/2` step — see the describe block below.
    test "delete_user_session_tokens/1 alone preserves the user's PATs" do
      {user, team} = user_with_team()

      {:ok, pat_plain, _} =
        Accounts.create_personal_access_token(user, team, %{name: "keep-key", abilities: ["read"]})

      {:ok, _s} = Accounts.create_user_session_token(user)

      assert {:ok, 1} = Accounts.delete_user_session_tokens(user)
      assert {%User{}, %UserToken{}} = Accounts.verify_personal_access_token(pat_plain)
    end

    test "revoke_user_session by id will not revoke a PAT row" do
      {user, team} = user_with_team()
      {:ok, _pt, pat} = Accounts.create_personal_access_token(user, team, %{name: "by-id-key"})

      # The PAT's row id is not a session → :not_found (no cross-context revoke).
      assert {:error, :not_found} = Accounts.revoke_user_session(user, pat.id)
      refute Repo.get(UserToken, pat.id).revoked_at
    end
  end

  describe "membership changes revoke team-scoped PATs (cch-w30-s6)" do
    test "remove_member/2 revokes every PAT the ex-member held on THAT team" do
      {_owner, team} = user_with_team()
      user = user_fixture()
      {:ok, _} = Accounts.add_member(team, user, "admin")
      other_team = team_fixture()
      {:ok, _} = Accounts.add_member(other_team, user, "admin")

      {:ok, here, _} =
        Accounts.create_personal_access_token(user, team, %{name: "here", abilities: ["read"]})

      {:ok, elsewhere, _} =
        Accounts.create_personal_access_token(user, other_team, %{
          name: "elsewhere",
          abilities: ["read"]
        })

      assert {:ok, :removed} = Accounts.remove_member(team, user)

      assert Accounts.verify_personal_access_token(here) == nil
      # Team-scoped: the other team's credential is NOT collateral.
      assert {%User{}, %UserToken{}} = Accounts.verify_personal_access_token(elsewhere)
    end

    test "update_member_role/3 demotion revokes only the PATs the new role could not mint" do
      {owner, team} = user_with_team()
      admin = user_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "admin")
      # Keep the owner around so the last-owner guard is not what we measure.
      assert Accounts.team_role(owner, team) == "owner"

      {:ok, deploy, _} =
        Accounts.create_personal_access_token(admin, team, %{
          name: "deploy",
          abilities: ["deploy"]
        })

      {:ok, read, _} =
        Accounts.create_personal_access_token(admin, team, %{name: "read", abilities: ["read"]})

      assert {:ok, %TeamMembership{role: "member"}} =
               Accounts.update_member_role(team, admin, "member")

      assert Accounts.verify_personal_access_token(deploy) == nil
      assert {%User{}, %UserToken{}} = Accounts.verify_personal_access_token(read)
    end

    test "a promotion (member -> admin) revokes nothing" do
      {_owner, team} = user_with_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      {:ok, read, _} =
        Accounts.create_personal_access_token(member, team, %{name: "read", abilities: ["read"]})

      assert {:ok, %TeamMembership{role: "admin"}} =
               Accounts.update_member_role(team, member, "admin")

      assert {%User{}, %UserToken{}} = Accounts.verify_personal_access_token(read)
    end

    test "revoked PAT rows survive as tombstones (stamped, never deleted)" do
      {_owner, team} = user_with_team()
      user = user_fixture()
      {:ok, _} = Accounts.add_member(team, user, "member")
      {:ok, _plain, pat} = Accounts.create_personal_access_token(user, team, %{name: "audit-me"})

      assert {:ok, :removed} = Accounts.remove_member(team, user)

      row = Repo.get(UserToken, pat.id)
      assert row, "the PAT row must remain for audit"
      refute is_nil(row.revoked_at)
    end

    test "a PAT cannot be minted without a team — the revoke filter's own precondition" do
      # cch-w30-s6 review. `revoke_team_pats/2` is scoped `team_id == ^tid`
      # (team-scoped on purpose: a user_id-only sweep would cross tenants), so a
      # PAT row with a NULL team_id is INVISIBLE to it and would outlive the
      # membership it was minted under — the very defect this slice fixes,
      # reintroduced through the back door.
      #
      # The column is nullable (session rows legitimately leave it NULL) and the
      # only thing binding PATs to a team was one cond branch at POST /v1/tokens
      # (`is_nil(current_team)` → 422). That is a property of a ROUTE, not of the
      # row: a second minting call site would have produced credentials nothing
      # could revoke. The changeset now refuses, so the precondition holds for
      # every caller present and future.
      {user, _team} = user_with_team()

      cs =
        UserToken.pat_changeset(%UserToken{}, %{
          token_hash: :crypto.strong_rand_bytes(32),
          name: "teamless",
          abilities: ["read"],
          user_id: user.id
        })

      refute cs.valid?, "a PAT with no team_id must not be mintable"
      assert %{team_id: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "verify_personal_access_token/1" do
    test "round-trips {user, pat} for a valid token" do
      {user, team} = user_with_team()

      {:ok, plaintext, pat} =
        Accounts.create_personal_access_token(user, team, %{name: "verify-key"})

      assert {%User{id: uid}, %UserToken{id: tid}} =
               Accounts.verify_personal_access_token(plaintext)

      assert uid == user.id
      assert tid == pat.id
    end

    test "stamps last_used_at on first verify, throttled on a quick re-verify" do
      {user, team} = user_with_team()

      {:ok, plaintext, _pat} =
        Accounts.create_personal_access_token(user, team, %{name: "lu-key"})

      assert {_u, %UserToken{id: id}} = Accounts.verify_personal_access_token(plaintext)
      first = Repo.get(UserToken, id).last_used_at
      assert first

      # A second verify within the throttle window does NOT move the stamp.
      assert {_u2, _t2} = Accounts.verify_personal_access_token(plaintext)
      assert Repo.get(UserToken, id).last_used_at == first
    end

    test "a revoked token fails verify" do
      {user, team} = user_with_team()

      {:ok, plaintext, pat} =
        Accounts.create_personal_access_token(user, team, %{name: "rev-key"})

      assert {:ok, _} = Accounts.revoke_personal_access_token(user, pat.id)
      assert is_nil(Accounts.verify_personal_access_token(plaintext))
    end

    test "an expired token fails verify" do
      {user, team} = user_with_team()

      {:ok, plaintext, pat} =
        Accounts.create_personal_access_token(user, team, %{name: "exp-key"})

      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)
      pat |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      assert is_nil(Accounts.verify_personal_access_token(plaintext))
    end

    test "a session token is NOT a PAT (context isolation)" do
      {user, _team} = user_with_team()
      {:ok, session_plaintext} = Accounts.create_user_session_token(user)

      assert is_nil(Accounts.verify_personal_access_token(session_plaintext))
    end
  end

  describe "revoke_personal_access_token/2" do
    test "is idempotent and scoped to the owner" do
      {user, team} = user_with_team()
      {other, _} = user_with_team()
      {:ok, _pt, pat} = Accounts.create_personal_access_token(user, team, %{name: "scoped-key"})

      # Another user cannot revoke it — same not_found shape (no existence leak).
      assert {:error, :not_found} = Accounts.revoke_personal_access_token(other, pat.id)

      assert {:ok, revoked} = Accounts.revoke_personal_access_token(user, pat.id)
      assert revoked.revoked_at
      # Idempotent — a second revoke returns ok with the same stamp.
      assert {:ok, again} = Accounts.revoke_personal_access_token(user, pat.id)
      assert again.revoked_at == revoked.revoked_at
    end
  end

  describe "list_personal_access_tokens/1" do
    test "lists the user's PATs newest-first and excludes session rows" do
      {user, team} = user_with_team()
      {:ok, _} = Accounts.create_user_session_token(user)
      {:ok, _p1, a} = Accounts.create_personal_access_token(user, team, %{name: "first"})
      {:ok, _p2, b} = Accounts.create_personal_access_token(user, team, %{name: "second"})

      ids = Accounts.list_personal_access_tokens(user) |> Enum.map(& &1.id)
      assert b.id in ids
      assert a.id in ids
      assert length(ids) == 2
    end
  end

  describe "verify_user_session_token/1 with revoked_at (shared win)" do
    test "a session row with revoked_at set fails verify" do
      {user, _team} = user_with_team()
      {:ok, plaintext} = Accounts.create_user_session_token(user)

      assert %User{} = Accounts.verify_user_session_token(plaintext)

      # Stamp revoked_at directly (logout/member-removal would do this).
      hash = UserToken.hash_token(plaintext)
      now = DateTime.truncate(DateTime.utc_now(), :microsecond)

      {1, _} =
        Repo.update_all(
          from(t in UserToken, where: t.token_hash == ^hash),
          set: [revoked_at: now]
        )

      assert is_nil(Accounts.verify_user_session_token(plaintext))
    end
  end

  defp onboarding_step(status, key), do: Enum.find(status.steps, &(&1.key == key))

  describe "onboarding" do
    test "a fresh team is onboarding: incomplete, all steps not done" do
      team = team_fixture()
      status = Accounts.onboarding_status(team)

      assert status.completed? == false
      assert is_nil(status.completed_at)
      assert is_nil(status.last_step)
      assert status.all_done? == false
      assert Enum.map(status.steps, & &1.key) == ~w(subscription instance published_doc)
      assert Enum.all?(status.steps, &(&1.done == false))
    end

    test "subscription step flips done once Billing.active_subscription exists" do
      team = team_fixture()
      refute onboarding_step(Accounts.onboarding_status(team), "subscription").done

      {:ok, _sub} = Billing.subscribe(team, "supporter")
      assert onboarding_step(Accounts.onboarding_status(team), "subscription").done
    end

    test "instance step flips done once a barkpark is registered" do
      team = team_fixture()
      refute onboarding_step(Accounts.onboarding_status(team), "instance").done

      {:ok, _bp} =
        Registry.register_barkpark(team, %{
          name: "BP",
          slug: "bp-#{System.unique_integer([:positive])}"
        })

      assert onboarding_step(Accounts.onboarding_status(team), "instance").done
    end

    test "published_doc step done via ack_onboarding_step/2 (user-ack path)" do
      team = team_fixture()
      refute onboarding_step(Accounts.onboarding_status(team), "published_doc").done

      {:ok, team} = Accounts.ack_onboarding_step(team, "published_doc")
      assert onboarding_step(Accounts.onboarding_status(team), "published_doc").done
      assert Accounts.get_team(team.id).onboarding_state["acked"] == ["published_doc"]
    end

    test "published_doc step done via a 'content' agent_event with published_count > 0" do
      team = team_fixture()

      {:ok, bp} =
        Registry.register_barkpark(team, %{
          name: "BP",
          slug: "bp-#{System.unique_integer([:positive])}"
        })

      refute onboarding_step(Accounts.onboarding_status(team), "published_doc").done

      {:ok, _ev} = Registry.record_event(bp, "content", %{"published_count" => 3})
      assert onboarding_step(Accounts.onboarding_status(team), "published_doc").done
    end

    test "a 'content' event with published_count 0 does NOT mark published_doc done" do
      team = team_fixture()

      {:ok, bp} =
        Registry.register_barkpark(team, %{
          name: "BP",
          slug: "bp-#{System.unique_integer([:positive])}"
        })

      {:ok, _ev} = Registry.record_event(bp, "content", %{"published_count" => 0})
      refute onboarding_step(Accounts.onboarding_status(team), "published_doc").done
    end

    test "a 'content' event on ANOTHER team's barkpark does NOT flip this team's published_doc" do
      team_a = team_fixture()
      team_b = team_fixture()

      {:ok, _bp_a} =
        Registry.register_barkpark(team_a, %{
          name: "A",
          slug: "a-#{System.unique_integer([:positive])}"
        })

      {:ok, bp_b} =
        Registry.register_barkpark(team_b, %{
          name: "B",
          slug: "b-#{System.unique_integer([:positive])}"
        })

      # Team B's instance publishes content...
      {:ok, _ev} = Registry.record_event(bp_b, "content", %{"published_count" => 9})

      # ...team A's published_doc step must NOT be satisfied by it (no
      # cross-tenant leak: the derivation is scoped to team A's own instances).
      refute onboarding_step(Accounts.onboarding_status(team_a), "published_doc").done
      # And team B's IS satisfied.
      assert onboarding_step(Accounts.onboarding_status(team_b), "published_doc").done
    end

    test "all_done? is true once every step is satisfied" do
      team = team_fixture()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      {:ok, bp} =
        Registry.register_barkpark(team, %{
          name: "BP",
          slug: "bp-#{System.unique_integer([:positive])}"
        })

      {:ok, _ev} = Registry.record_event(bp, "content", %{"published_count" => 1})

      assert Accounts.onboarding_status(team).all_done?
    end

    test "advance_onboarding/2 persists last_step" do
      team = team_fixture()
      {:ok, team} = Accounts.advance_onboarding(team, "instance")

      assert team.onboarding_state["last_step"] == "instance"
      assert Accounts.onboarding_status(Accounts.get_team(team.id)).last_step == "instance"
    end

    test "advance_onboarding/2 with an unknown step is sanitized to nil last_step" do
      team = team_fixture()
      {:ok, team} = Accounts.advance_onboarding(team, "bogus")

      assert is_nil(team.onboarding_state["last_step"])
    end

    test "complete_onboarding/1 stamps completed_at once and is idempotent" do
      team = team_fixture()
      {:ok, team} = Accounts.complete_onboarding(team)

      assert %DateTime{} = ts = team.onboarding_completed_at
      assert Accounts.onboarding_status(team).completed?

      # Second call is a no-op: the same timestamp survives, never rewritten.
      {:ok, team2} = Accounts.complete_onboarding(team)
      assert team2.onboarding_completed_at == ts
    end

    test "skip_onboarding/1 stamps completed_at even with steps incomplete (early dismiss)" do
      team = team_fixture()
      refute Accounts.onboarding_status(team).all_done?

      {:ok, team} = Accounts.skip_onboarding(team)
      assert %DateTime{} = team.onboarding_completed_at
      assert Accounts.onboarding_status(team).completed?
    end

    test "onboarding_changeset rejects a non-map onboarding_state" do
      team = team_fixture()
      changeset = Team.onboarding_changeset(team, %{onboarding_state: "nope"})

      # Ecto's :map cast rejects a non-map at cast time ("is invalid"); the
      # column can never take a scalar. Either way it is rejected.
      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :onboarding_state)
    end

    test "onboarding_changeset normalizes state: filters unknown acked, sanitizes last_step" do
      team = team_fixture()

      changeset =
        Team.onboarding_changeset(team, %{
          onboarding_state: %{
            "last_step" => "junk",
            "acked" => ["published_doc", "junk", "published_doc"]
          }
        })

      assert changeset.valid?
      normalized = Ecto.Changeset.get_change(changeset, :onboarding_state)
      assert normalized["version"] == 1
      assert is_nil(normalized["last_step"])
      assert normalized["acked"] == ["published_doc"]
    end
  end

  describe "update_user_email/2 brute-force lockout" do
    # Stage `pending` on the user and mint a live change_email token whose code is
    # `code`. Returns the user reloaded WITH pending_email set (the shape the
    # confirm path receives). Mirrors deliver_user_update_email_instructions/2 but
    # inline so the test knows the code and skips the mailer.
    defp stage_email_change(user, pending, code) do
      {:ok, staged} =
        Repo.update(User.email_change_changeset(user, %{pending_email: pending}))

      {:ok, _token} =
        %UserToken{}
        |> UserToken.changeset(%{
          user_id: user.id,
          context: "change_email",
          token_hash: UserToken.hash_token(code),
          sent_to: pending,
          failed_attempts: 0,
          expires_at:
            DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.truncate(:microsecond)
        })
        |> Repo.insert()

      staged
    end

    defp change_email_token(user, pending) do
      Repo.one(
        from t in UserToken,
          where: t.user_id == ^user.id and t.context == "change_email" and t.sent_to == ^pending
      )
    end

    test "a single wrong code just increments failed_attempts (leaves the change open)" do
      user = user_fixture()

      staged =
        stage_email_change(
          user,
          "next-#{System.unique_integer([:positive])}@example.com",
          "111111"
        )

      assert {:error, :invalid_code} = Accounts.update_user_email(staged, "999999")

      token = change_email_token(user, staged.pending_email)
      assert token.failed_attempts == 1
      assert is_nil(token.revoked_at)
      assert Repo.get!(User, user.id).pending_email == staged.pending_email
    end

    test "max_code_attempts wrong codes in a row trip the lockout (serial)" do
      user = user_fixture()

      staged =
        stage_email_change(
          user,
          "next-#{System.unique_integer([:positive])}@example.com",
          "111111"
        )

      for _ <- 1..UserToken.max_code_attempts() do
        Accounts.update_user_email(staged, "999999")
      end

      token = change_email_token(user, staged.pending_email)
      refute is_nil(token.revoked_at)
      assert is_nil(Repo.get!(User, user.id).pending_email)
    end

    # THE REGRESSION GUARD: N concurrent wrong-code confirmations must NOT be able
    # to slip past the lockout. Pre-fix each parallel call read the same
    # failed_attempts baseline and wrote baseline+1 (a lost update), so the counter
    # survived at ~1 and max_code_attempts never tripped — an attacker could fan out
    # ~10^6 guesses at a 6-digit code. Post-fix the FOR UPDATE row lock serializes
    # the read-modify-write, so the counter climbs monotonically and the change is
    # locked/dropped. Shared sandbox mode lets the spawned tasks reach the DB.
    test "concurrent wrong codes cannot outrun the failed_attempts lockout" do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      user = user_fixture()
      pending = "next-#{System.unique_integer([:positive])}@example.com"
      staged = stage_email_change(user, pending, "111111")

      # More concurrent wrong guesses than the lockout threshold. Every one is the
      # SAME wrong code so, absent serialization, they all read baseline 0.
      guesses = UserToken.max_code_attempts() + 1

      1..guesses
      |> Task.async_stream(fn _ -> Accounts.update_user_email(staged, "999999") end,
        max_concurrency: guesses,
        ordered: false
      )
      |> Stream.run()

      # The lockout must have tripped: token revoked AND the pending change dropped,
      # and a subsequent code (even the CORRECT one) can no longer confirm.
      token = change_email_token(user, pending)
      refute is_nil(token.revoked_at)
      assert is_nil(Repo.get!(User, user.id).pending_email)
      assert {:error, reason} = Accounts.update_user_email(staged, "111111")
      assert reason in [:invalid_code, :locked]
    end
  end
end
