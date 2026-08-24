defmodule BarkparkCloud.AccountsPasswordResetTest do
  @moduledoc """
  The forgot-password context flow: `request_password_reset/1` (enumeration-safe
  mint) + `reset_password_by_token/2` (single-use consume + sign-out-everywhere).
  Mirrors accounts_test.exs's DataCase + fixtures.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{User, UserToken}
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Repo

  import Ecto.Query

  @password "correct-horse-battery"
  @new_password "fresh-horse-battery-staple"

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

  defp reset_token_count(user_id) do
    from(t in UserToken,
      where: t.user_id == ^user_id and t.context == "reset" and is_nil(t.revoked_at)
    )
    |> Repo.aggregate(:count)
  end

  describe "request_password_reset/1" do
    test "mints a live reset token for an existing user and returns the plaintext once" do
      user = user_fixture()

      assert {:ok, {%User{id: id}, raw}} = Accounts.request_password_reset(user.email)
      assert id == user.id
      assert is_binary(raw) and raw != ""
      # Only the hash is stored — the plaintext is unrecoverable from the row.
      assert reset_token_count(user.id) == 1
      assert Repo.get_by(UserToken, token_hash: UserToken.hash_token(raw), context: "reset")
    end

    test "is enumeration-safe: an unknown email returns {:ok, nil} and mints nothing" do
      assert {:ok, nil} = Accounts.request_password_reset("nobody@example.com")
    end

    test "is case-insensitive on the email" do
      user = user_fixture(email: "ada@example.com")
      assert {:ok, {%User{id: id}, _raw}} = Accounts.request_password_reset("ADA@Example.com")
      assert id == user.id
    end

    test "a re-request supersedes the previous link (only the newest works)" do
      user = user_fixture()
      {:ok, {_u, first}} = Accounts.request_password_reset(user.email)
      {:ok, {_u, second}} = Accounts.request_password_reset(user.email)

      assert first != second
      # Exactly one live reset token — the first was revoked.
      assert reset_token_count(user.id) == 1
      # The superseded link no longer resets.
      assert {:error, :invalid_token} = Accounts.reset_password_by_token(first, @new_password)
      assert {:ok, %User{}} = Accounts.reset_password_by_token(second, @new_password)
    end
  end

  describe "reset_password_by_token/2" do
    test "sets the new password, consumes the token, and is single-use" do
      user = user_fixture()
      {:ok, {_u, raw}} = Accounts.request_password_reset(user.email)

      assert {:ok, %User{id: id}} = Accounts.reset_password_by_token(raw, @new_password)
      assert id == user.id

      # New password authenticates; old one no longer does.
      assert %User{} = Accounts.get_user_by_email_and_password(user.email, @new_password)
      refute Accounts.get_user_by_email_and_password(user.email, @password)

      # Replaying the same link fails closed.
      assert {:error, :invalid_token} = Accounts.reset_password_by_token(raw, @new_password)
      assert reset_token_count(user.id) == 0
    end

    test "signs the user out everywhere (existing sessions are revoked)" do
      user = user_fixture()
      {:ok, session} = Accounts.create_user_session_token(user)
      assert %User{} = Accounts.verify_user_session_token(session)

      {:ok, {_u, raw}} = Accounts.request_password_reset(user.email)
      assert {:ok, %User{}} = Accounts.reset_password_by_token(raw, @new_password)

      # The pre-reset session is dead.
      refute Accounts.verify_user_session_token(session)
    end

    test "an unknown / malformed token is {:error, :invalid_token}" do
      assert {:error, :invalid_token} =
               Accounts.reset_password_by_token("not-a-real-token", @new_password)
    end

    test "a weak new password is rejected and leaves the token usable for a retry" do
      user = user_fixture()
      {:ok, {_u, raw}} = Accounts.request_password_reset(user.email)

      assert {:error, %Ecto.Changeset{}} = Accounts.reset_password_by_token(raw, "short")
      # The failed attempt rolled back — the link still works with a valid password.
      assert reset_token_count(user.id) == 1
      assert {:ok, %User{}} = Accounts.reset_password_by_token(raw, @new_password)
    end

    test "an expired token does not reset" do
      user = user_fixture()
      {:ok, {_u, raw}} = Accounts.request_password_reset(user.email)

      # Backdate the token's expiry past now.
      from(t in UserToken, where: t.user_id == ^user.id and t.context == "reset")
      |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)])

      assert {:error, :invalid_token} = Accounts.reset_password_by_token(raw, @new_password)
      # The old password still stands.
      assert %User{} = Accounts.get_user_by_email_and_password(user.email, @password)
    end

    # ONE-WAY STATE, and this is the sharper of the two entries: the reset route
    # (`POST /v1/auth/reset`) is UNAUTHENTICATED — proving control of the mailbox
    # IS the authentication. Until this was removed, anyone who could read a team
    # member's email could permanently disarm the agent credential of every box
    # that member's teams owned, with no way back short of re-provisioning each
    # box. See the twin in accounts_test.exs ("machine creds are not user creds")
    # for the full reasoning; the short version is that nothing anywhere clears
    # an AgentToken's `revoked_at`, and the only minter sits behind
    # `Auth.require_worker`.
    test "does NOT revoke the user's teams' agent tokens (machine creds are not user creds)" do
      user = user_fixture()

      {:ok, team} =
        Accounts.create_team(%{
          name: "Team #{System.unique_integer([:positive])}",
          slug: "team-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Accounts.add_member(team, user, "owner")

      {:ok, bp} =
        Registry.register_barkpark(team, %{
          name: "Box",
          slug: "box-#{System.unique_integer([:positive])}"
        })

      {:ok, agent_plain, _} = Registry.mint_agent_token(bp, "report")
      assert Registry.verify_agent_token(agent_plain).id == bp.id

      {:ok, {_u, raw}} = Accounts.request_password_reset(user.email)
      assert {:ok, %User{}} = Accounts.reset_password_by_token(raw, @new_password)

      # The reset signed the human out everywhere; the box stayed reachable.
      assert Registry.verify_agent_token(agent_plain).id == bp.id
    end
  end
end
