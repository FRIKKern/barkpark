defmodule BarkparkCloud.AccountsTest do
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{Team, TeamMembership, User}

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
      assert "user is already a member of this team" in errors_on(changeset).user_id
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
end
