defmodule BarkparkCloud.AccountsResetRevokesRecoveryCredentialsTest do
  @moduledoc """
  task-2cf2d783832c12e9 — a password RESET is account recovery, possibly after a
  compromise, so every credential an attacker could have minted must die with
  it. `reset_password_by_token/2` revoked only session and sse rows; a PAT (and
  2fa_pending / oauth_exchange / change_email rows) survived the recovery. A
  voluntary password CHANGE keeps sparing PATs — that carve-out is unchanged.
  """
  use BarkparkCloud.DataCase, async: false

  import Ecto.Query

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.Repo

  setup do
    {:ok, user} =
      Accounts.register_user(%{email: "recover@example.com", password: "old horse battery 1"})

    {:ok, team} = Accounts.create_team(%{name: "Recover Co", slug: "recover-co"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, pat, _row} = Accounts.create_personal_access_token(user, team, %{name: "attacker-pat"})
    %{user: user, pat: pat}
  end

  defp live(user_id, context) do
    Repo.aggregate(
      from(t in UserToken,
        where: t.user_id == ^user_id and t.context == ^context and is_nil(t.revoked_at)
      ),
      :count
    )
  end

  test "a reset revokes the user's PATs", %{user: user, pat: pat} do
    assert Accounts.verify_personal_access_token(pat)

    {:ok, {_user, reset}} = Accounts.request_password_reset("recover@example.com")
    assert {:ok, _} = Accounts.reset_password_by_token(reset, "new horse battery 22")

    refute Accounts.verify_personal_access_token(pat)
    assert live(user.id, "pat") == 0
  end

  test "a reset revokes a pending email-change code", %{user: user} do
    {:ok, _} = Accounts.deliver_user_update_email_instructions(user, "elsewhere@example.com")
    assert live(user.id, "change_email") == 1

    {:ok, {_user, reset}} = Accounts.request_password_reset("recover@example.com")
    assert {:ok, _} = Accounts.reset_password_by_token(reset, "new horse battery 22")

    assert live(user.id, "change_email") == 0
  end

  # r3b sweep: revoke_recovery_credentials/2 stamps `revoked_at` on 2fa_pending
  # rows, but the verifier never read the stamp — an attacker who had already
  # cleared the PASSWORD leg kept a live second-factor challenge for the rest of
  # its 5-minute TTL after the victim reset. The revoke has to mean something.
  test "a reset kills an in-flight 2FA challenge (the pending token stops verifying)", %{
    user: user
  } do
    {:ok, pending} = Accounts.create_two_factor_pending_token(user)
    assert %{id: id} = Accounts.verify_two_factor_pending_token(pending)
    assert id == user.id

    {:ok, {_user, reset}} = Accounts.request_password_reset("recover@example.com")
    assert {:ok, _} = Accounts.reset_password_by_token(reset, "new horse battery 22")

    assert live(user.id, "2fa_pending") == 0
    assert Accounts.verify_two_factor_pending_token(pending) == nil
    assert Accounts.two_factor_pending_first_factor(pending) == nil
  end

  test "CONTROL: an unrevoked pending challenge still verifies", %{user: user} do
    {:ok, pending} = Accounts.create_two_factor_pending_token(user, "github")
    assert %{id: id} = Accounts.verify_two_factor_pending_token(pending)
    assert id == user.id
    assert Accounts.two_factor_pending_first_factor(pending) == "github"
  end

  test "CONTROL: sign-out-everywhere (the password-CHANGE path) still spares PATs", %{
    pat: pat,
    user: user
  } do
    {:ok, _} = Accounts.revoke_all_user_sessions(user)
    assert Accounts.verify_personal_access_token(pat)
  end
end
