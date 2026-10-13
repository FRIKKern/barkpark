defmodule BarkparkWeb.ResetClearsAddedCredentialsTest do
  @moduledoc """
  Owner ruling #13 (task-f4cfc3e2ab4bd6b8, item 1): a password reset clears
  every passkey, social link and owned personal token, and minting a personal
  token needs a recent password or MFA.

  A session thief could add a passkey or mint a personal token, and both
  survived the owner's forgot-password recovery, which was meant to fully
  recover a hijacked account.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.AccountsFixtures
  import Ecto.Query

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Accounts.WebauthnCredential
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Sso.SocialIdentity

  @password "correct-horse-battery"

  defp uniq_email(p), do: "#{p}-#{System.unique_integer([:positive])}@example.com"

  defp session_bearer(user, opts \\ []) do
    {:ok, raw} = Accounts.create_user_session_token(user, opts)
    raw
  end

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp passkey!(user) do
    Repo.insert!(%WebauthnCredential{
      user_id: user.id,
      credential_id: :crypto.strong_rand_bytes(16),
      cose_key: :erlang.term_to_binary(%{}),
      nickname: "added by a thief"
    })
  end

  defp count(query), do: Repo.aggregate(query, :count)

  describe "forgot-password reset" do
    test "removes passkeys, social links and owned personal tokens; keeps what the user does not own" do
      user = register_user(uniq_email("reset-clear"))
      passkey!(user)
      Repo.insert!(%SocialIdentity{user_id: user.id, provider: "github", external_id: "gh-thief"})

      {:ok, {pat_raw, pat}} =
        Auth.create_personal_access_token("thief cli", ["read"], owner_user_id: user.id)

      # A machine token nobody owns (e.g. the credential Cloud holds) survives.
      machine_raw = "machine-token-#{System.unique_integer([:positive])}"

      {:ok, machine} =
        Auth.create_token(machine_raw, "barkpark cloud admin", "production", ["admin"])

      assert {:ok, _} = Auth.verify_token(pat_raw)

      {:ok, raw} = Accounts.build_email_token(user, "reset")

      assert {:ok, _} =
               Accounts.reset_user_password(raw, %{password: "a-new-correct-horse-battery"})

      assert count(from c in WebauthnCredential, where: c.user_id == ^user.id) == 0
      assert count(from i in SocialIdentity, where: i.user_id == ^user.id) == 0
      assert Repo.get(ApiToken, pat.id).revoked_at
      assert {:error, :unauthorized} = Auth.verify_token(pat_raw)

      refute Repo.get(ApiToken, machine.id).revoked_at
      assert {:ok, _} = Auth.verify_token(machine_raw)
    end

    test "an authenticated password change keeps passkeys and tokens" do
      user = register_user(uniq_email("change-keeps"))
      passkey!(user)

      {:ok, {_raw, pat}} =
        Auth.create_personal_access_token("mine", ["read"], owner_user_id: user.id)

      assert {:ok, _} =
               Accounts.update_user_password(user, @password, %{
                 password: "another-correct-horse-battery"
               })

      assert count(from c in WebauthnCredential, where: c.user_id == ^user.id) == 1
      refute Repo.get(ApiToken, pat.id).revoked_at
    end
  end

  describe "POST /v1/auth/tokens needs recent authentication" do
    test "a session alone is refused with 401 reauth_required and mints nothing", %{conn: conn} do
      user = register_user(uniq_email("mint-stale"))

      resp = conn |> bearer(session_bearer(user)) |> post("/v1/auth/tokens", %{"name" => "cli"})

      assert json_response(resp, 401)["error"]["code"] == "reauth_required"
      assert count(from t in ApiToken, where: t.owner_user_id == ^user.id) == 0
    end

    test "a wrong current_password is refused too", %{conn: conn} do
      user = register_user(uniq_email("mint-wrong"))

      resp =
        conn
        |> bearer(session_bearer(user))
        |> post("/v1/auth/tokens", %{"name" => "cli", "current_password" => "nope-nope-nope"})

      assert json_response(resp, 401)["error"]["code"] == "reauth_required"
    end

    test "the current password mints", %{conn: conn} do
      user = register_user(uniq_email("mint-pw"))

      resp =
        conn
        |> bearer(session_bearer(user))
        |> post("/v1/auth/tokens", %{"name" => "cli", "current_password" => @password})

      assert json_response(resp, 201)["personal_access_token"]["owner_user_id"] == user.id
    end

    test "a session that presented an MFA factor mints without the password", %{conn: conn} do
      user = register_user(uniq_email("mint-mfa"))

      resp =
        conn
        |> bearer(session_bearer(user, mfa_verified: true))
        |> post("/v1/auth/tokens", %{"name" => "cli"})

      assert json_response(resp, 201)["personal_access_token"]["owner_user_id"] == user.id
    end
  end
end
